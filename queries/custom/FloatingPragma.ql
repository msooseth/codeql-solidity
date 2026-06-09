/**
 * @name Floating (unpinned) compiler version pragma
 * @description A `pragma solidity` directive that does not pin an exact compiler
 *              version lets the contract be compiled with a range of compilers,
 *              so the deployed bytecode may differ from what was audited. Either
 *              pin an exact version (`pragma solidity =0.8.20;`) or use a bounded
 *              range with an explicit upper bound (`>=0.8.0 <0.9.0`).
 * @kind problem
 * @problem.severity warning
 * @precision high
 * @id solidity/floating-pragma
 * @tags maintainability
 *       security
 *       solidity
 *       reproducible-builds
 */

import codeql.solidity.ast.internal.TreeSitter

/** Gets the trimmed value of an operator token directly under pragma `p`. */
string pragmaOperator(Solidity::PragmaDirective p) {
  exists(Solidity::AstNode t |
    t.getParent+() = p and
    result = t.getValue().trim() and
    result in ["^", "~", ">", ">=", "<", "<="]
  )
}

/** Gets the version constraint of `p` as a readable string, e.g. `^ 0.8.0`. */
string constraintText(Solidity::PragmaDirective p) {
  result =
    concat(Solidity::AstNode t |
      t.getParent+() = p and
      (t.getValue().trim() in ["^", "~", ">", ">=", "<", "<="] or t instanceof Solidity::SolidityVersion)
    |
      t.getValue() , " " order by t.getLocation().getStartColumn()
    )
}

/**
 * Holds if `p` is a version pragma (carries a concrete version) whose constraint
 * floats: a caret/tilde, or a lower bound with no matching upper bound.
 */
predicate isFloating(Solidity::PragmaDirective p) {
  exists(Solidity::SolidityVersion v | v.getParent+() = p) and
  (
    pragmaOperator(p) in ["^", "~"]
    or
    // open-ended lower bound with no upper bound
    pragmaOperator(p) in [">", ">="] and
    not pragmaOperator(p) in ["<", "<="]
  )
}

from Solidity::PragmaDirective p
where isFloating(p)
select p,
  "Floating compiler version pragma (" + constraintText(p).trim() +
    "): pin an exact version or add an upper bound."
