/**
 * @name High storage-layout base in an inheriting contract
 * @description Flags a contract that both inherits from another contract and pins
 *              its storage layout (`layout at <expr>`) to a base near the top of the
 *              256-bit slot space (>= 2**256 - 2**64). Such high bases combined with
 *              inheritance are worth reviewing for storage-collision / overflow risk.
 * @kind problem
 * @problem.severity warning
 * @precision medium
 * @id solidity/high-layout-with-inheritance
 * @tags analysis
 *       storage
 *       solidity
 */

import codeql.solidity.ast.internal.TreeSitter

/** Holds if `c` declares at least one inheritance specifier (`is Base`). */
predicate hasInheritance(Solidity::ContractDeclaration c) {
  exists(Solidity::InheritanceSpecifier spec | spec.getParent() = c)
}

/** Strips any `parenthesized_expression` wrappers (these are NOT collapsed by the extractor). */
Solidity::AstNode unparen(Solidity::AstNode e) {
  not e instanceof Solidity::ParenthesizedExpression and result = e
  or
  result =
    unparen(any(Solidity::AstNode inner |
        inner.getParent() = e.(Solidity::ParenthesizedExpression) and
        not inner.getValue() = ["(", ")"]
      ))
}

/** Gets the value expression of a contract's `layout at <expr>` specifier, with parentheses stripped. */
Solidity::AstNode getLayoutExpr(Solidity::ContractDeclaration c) {
  exists(Solidity::LayoutSpecifier ls, Solidity::AstNode raw |
    ls.getParent() = c and
    raw.getParent() = ls and
    // the layout specifier's children are the `layout`/`at` keyword tokens plus the value expression
    not raw.getValue() = ["layout", "at"] and
    result = unparen(raw)
  )
}

/** Gets the exponent `a` when `e` is the power expression `2 ** a` with a literal exponent. */
int powerOfTwoExp(Solidity::AstNode e) {
  exists(Solidity::BinaryExpression b | b = unparen(e) |
    b.getOperator().getValue().trim() = "**" and
    unparen(b.getLeft()).(Solidity::NumberLiteral).getValue().trim() = "2" and
    result = unparen(b.getRight()).(Solidity::NumberLiteral).getValue().trim().toInt()
  )
}

/**
 * Holds if the pure decimal literal `s` denotes a value >= 2**256 - 2**64.
 * Lexicographic comparison of equal-length, leading-zero-free digit strings equals numeric comparison.
 */
bindingset[s0]
predicate decimalAtLeastThreshold(string s0) {
  exists(string s | s = s0.replaceAll("_", "") and s.regexpMatch("[0-9]+") |
    s.length() > 78
    or
    s.length() = 78 and
    s >= "115792089237316195423570985008687907853269984665640564039439137263839420088320"
  )
}

/**
 * Holds if the hex literal `s` denotes a value >= 2**256 - 2**64.
 * 2**256 - 2**64 = 0x<48 F's><16 0's>; a 64-hex-digit value reaches it iff its top 48 nibbles are all F.
 */
bindingset[s0]
predicate hexAtLeastThreshold(string s0) {
  exists(string h | h = s0.replaceAll("_", "").regexpCapture("0[xX]([0-9a-fA-F]+)", 1) |
    h.length() = 64 and h.prefix(48).regexpMatch("[fF]{48}")
  )
}

/** Holds if the constant expression `e` evaluates to a value >= 2**256 - 2**64. */
predicate meetsThreshold(Solidity::AstNode e) {
  // 2 ** a  with a >= 256
  powerOfTwoExp(e) >= 256
  or
  // 2 ** a - X
  exists(Solidity::BinaryExpression b, int a |
    b = unparen(e) and
    b.getOperator().getValue().trim() = "-" and
    a = powerOfTwoExp(b.getLeft())
  |
    a > 256
    or
    a = 256 and
    (
      // ... - 2 ** k  with k <= 64
      powerOfTwoExp(b.getRight()) <= 64
      or
      // ... - k  with k a literal that fits in a 63-bit QL int, hence k < 2**64
      exists(unparen(b.getRight()).(Solidity::NumberLiteral).getValue().trim().toInt())
    )
  )
  or
  // a bare numeric literal at or above the threshold
  decimalAtLeastThreshold(e.(Solidity::NumberLiteral).getValue().trim())
  or
  hexAtLeastThreshold(e.(Solidity::NumberLiteral).getValue().trim())
}

from Solidity::ContractDeclaration c, Solidity::AstNode layoutExpr
where
  hasInheritance(c) and
  layoutExpr = getLayoutExpr(c) and
  meetsThreshold(layoutExpr)
select c,
  "Contract '" + c.getName().(Solidity::AstNode).getValue() +
    "' inherits and pins its storage layout to a base >= 2**256 - 2**64 (see $@).", layoutExpr,
  "layout expression"
