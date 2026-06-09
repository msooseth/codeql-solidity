/**
 * @name Call callee kinds
 * @description Classifies every call expression by the syntactic kind of its
 *              callee. Useful for understanding how calls resolve to their
 *              targets and for sanity-checking that call -> callee linking is
 *              complete.
 * @kind problem
 * @problem.severity recommendation
 * @precision high
 * @id solidity/callee-kinds
 * @tags analysis
 *       callgraph
 *       solidity
 */

import codeql.solidity.ast.internal.TreeSitter

/**
 * Gets the callee node of `c`, i.e. the expression in its `function` position
 * (an `Identifier` for `f(...)`, a `MemberExpression` for `a.b(...)`, a
 * `NewExpression` for `new T(...)`, etc.). The extractor collapses the grammar's
 * generic `expression` wrapper, so `getFunction()` is the concrete callee.
 */
Solidity::AstNode getCallee(Solidity::CallExpression c) { result = c.getFunction() }

/** Gets the syntactic kind of `c`'s callee (e.g. `Identifier`, `MemberExpression`). */
string calleeKind(Solidity::CallExpression c) { result = getCallee(c).getAPrimaryQlClass() }

/**
 * Gets a human-readable name for `c`'s callee where one is resolvable: the
 * identifier for a direct call, or the member/property name for a member call.
 */
string calleeName(Solidity::CallExpression c) {
  result = getCallee(c).(Solidity::Identifier).getValue()
  or
  result = getCallee(c).(Solidity::MemberExpression).getProperty().(Solidity::AstNode).getValue()
}

from Solidity::CallExpression c
select c,
  "Call via " + calleeKind(c) + " callee" +
    concat(" '" + calleeName(c) + "'") + "."
