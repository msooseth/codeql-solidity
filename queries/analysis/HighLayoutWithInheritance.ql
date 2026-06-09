/**
 * @name High storage-layout base in an inheriting contract
 * @description Flags a contract that both inherits from another contract and pins
 *              its storage layout (`layout at <expr>`) to a base near the top of the
 *              256-bit slot space (>= 2**256 - 2**64). Such high bases combined with
 *              inheritance are worth reviewing for storage-collision / overflow risk.
 * @kind problem
 * @problem.severity warning
 * @precision high
 * @id solidity/high-layout-with-inheritance
 * @tags analysis
 *       storage
 *       solidity
 */

import codeql.solidity.ast.internal.TreeSitter
import codeql.solidity.ast.Constants

/** The threshold 2**256 - 2**64, as a canonical decimal string. */
private string threshold() {
  result = "115792089237316195423570985008687907853269984665640564039439137263839420088320"
}

/** Holds if `c` declares at least one inheritance specifier (`is Base`). */
predicate hasInheritance(Solidity::ContractDeclaration c) {
  exists(Solidity::InheritanceSpecifier spec | spec.getParent() = c)
}

/** Gets the value expression of a contract's `layout at <expr>` specifier. */
Solidity::AstNode getLayoutExpr(Solidity::ContractDeclaration c) {
  exists(Solidity::LayoutSpecifier ls |
    ls.getParent() = c and
    result.getParent() = ls and
    // the layout specifier's children are the `layout`/`at` keyword tokens plus the value expression
    not result.getValue() = ["layout", "at"]
  )
}

from Solidity::ContractDeclaration c, Solidity::AstNode layoutExpr, string value
where
  hasInheritance(c) and
  layoutExpr = getLayoutExpr(c) and
  // The extractor folds the constant expression to its 256-bit integer value;
  // we just compare the decimal strings numerically.
  value = layoutExpr.getConstantValue() and
  BigIntComparison::geq(value, threshold())
select c,
  "Contract '" + c.getName().(Solidity::AstNode).getValue() +
    "' inherits and pins its storage layout to a high base (" + value + " >= 2**256 - 2**64), see $@.",
  layoutExpr, "layout expression"
