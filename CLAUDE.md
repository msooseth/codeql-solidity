# Working notes for codeql-solidity

Non-obvious things learned working in this repo. The README covers setup/usage and
the Uniswap example; this file is the gotchas that bite you when **writing queries
and touching the extractor/library**. (This file is gitignored.)

## Layout & packs

- `ql/lib/` → pack **`lucasamorimca/solidity-all`** (library). `queries/` → pack
  **`lucasamorimca/solidity-queries`** (depends on `solidity-all`).
- Generated build artifacts (gitignored, regenerate via the extractor's `generate`
  subcommand — see README step 3): `ql/lib/solidity.dbscheme`,
  `ql/lib/codeql/solidity/ast/internal/TreeSitter.qll`,
  `extractor-pack/solidity.dbscheme`, and the compiled binaries under
  `extractor-pack/tools/`.
- The extractor is tree-sitter based, `build_modes: none`: it parses `.sol` source
  directly — **no npm/solc/compilation**, just source files. Extracting the 81-file
  Uniswap corpus takes ~0.2s.
- Pinned grammar: `JoranHonig/tree-sitter-solidity` rev `4e938a4` (see
  `extractor/Cargo.toml`). Its `node-types.json` lives at
  `~/.cargo/git/checkouts/tree-sitter-solidity-*/4e938a4/src/node-types.json` —
  read it to see fields/children for a node type. **The grammar has zero
  tree-sitter supertypes.**

## Running queries (the friction points)

- **Fresh DB has no `*.dbscheme.stats`**, and the query *compiler* needs it.
  Cached pack queries hide this; any fresh/standalone query fails with
  `NoSuchFileException ... solidity.dbscheme.stats`. Fix once per DB:
  `codeql dataset measure -j8 -o vault-db/db-solidity/solidity.dbscheme.stats vault-db/db-solidity`.
- **Scratch queries must live inside `queries/`** (e.g. a temp file under
  `queries/analysis/`) so the `solidity-all` dependency resolves via
  `--additional-packs="$PWD"`. A `.ql` in `/tmp` can't resolve
  `codeql.solidity.*` imports. Delete scratch `.ql` files when done — `.gitignore`
  does not cover them.
- Iterate with `codeql query run <file> --database=vault-db --additional-packs="$PWD"`.
  `database analyze --format=csv` gave an **empty CSV** for ad-hoc problem queries
  in practice (BQRS written, interpretation empty); prefer `query run`.
- `query run`'s table prints only the `select` columns. For a `@kind problem`
  query it shows the entity class + message, **not** file:line — add explicit
  location columns (`...getLocation().getStartLine()`) when you need locations.
- Rebuild loop: `rm -rf vault-db && codeql database create vault-db
  --language=solidity --source-root=contracts --search-path="$PWD"` then re-measure
  stats. `CODEQL_EXTRACTOR_SOLIDITY_ROOT` must point at `extractor-pack/`.

## QL gotchas

- **`count(x)` where `x` is the `from` variable is always 1** (it counts a
  singleton per row). For grouped counts you must write
  `count(T y | predicate(y))`, not `select expr, count(x)`. This silently produced
  "1 of everything" census tables — the single biggest time-sink here.
- `File` has `getName()` (absolute path) but **no `getBaseName()` /
  `getRelativePath()`**. Shorten with
  `getName().regexpReplaceAll(".*/contracts/", "")`.
- QL `select` can't take inline `(if ...) + (if ...)`; factor into a string-valued
  predicate. `limit N` is not valid in `query run` scripts.

## AST shape: the `expression` (and other) wrapper nodes

This is the #1 source of "my query matches nothing." The grammar wraps things in
generic nodes; the real content is a **child**.

- **`CallExpression.getFunction()` returns a generic `Expression` wrapper for all
  calls** (verified 1124/1124), never the callee directly. The real callee is
  `getFunction().getAChild()` and is one of: `Identifier` (`f(x)`),
  `MemberExpression` (`a.b(x)` → name is `getProperty()`), `NewExpression`
  (`new T(x)`), `StructExpression` (`new T{salt: …}()` / `x.call{value: …}(…)`).
  Robust callee-name resolution: descend `getFunction().getAChild*()` and handle
  both `Identifier.getValue()` and `MemberExpression.getProperty()...getValue()`.
  `ql/lib/codeql/solidity/callgraph/CallResolution.qll` is the reference pattern.
- `CallExpression.getChild(0)` is **unpopulated** (0 results) — use `getAChild()`
  / `getAFieldOrChild()` / `getFunction()`, not indexed `getChild(i)`.
- **`Visibility` and `StateMutability` are wrapper nodes too**: the keyword
  (`public`/`external`/`view`/`pure`/`payable`) is the value of their *child*
  token, not the node. So `solidity_tokeninfo(visibilityNode, …)` returns nothing;
  use `wrapper.getAChild().getValue()`. (This was the bug fixed in
  `Function.qll` on this branch.)
- **Pragma operators** (`^ >= > < <= =`) are plain `AstNode` tokens whose
  `getValue()` has leading whitespace — `.trim()` it. The typed
  `SolidityVersionComparisonOperator` node has **no** `getValue()`. The version
  string lives in `SolidityVersion` nodes.
- `require`/`assert`/`revert` are `CallExpression`s; the callee `Identifier`'s
  parent is the wrapper, i.e. `id.getParent() = c.getFunction()`. Argument count =
  `count(CallArgument a | a.getParent() = c)` — `require(cond)` = 1,
  `require(cond, "msg")` = 2.

## Library reliability

The convenience helpers in `ql/lib` are uneven — several predate/ignore the
wrapper-node shape and silently match nothing. Treat them as suspect and verify
counts against a known corpus before relying on them.

- Fixed on this branch: `FunctionDef.getVisibility()` / `isView` / `isPure` /
  `isPayable` (all returned empty due to the wrapper bug).
- Still suspect: `dataflow/TaintTracking.qll` and `callgraph/ExternalCalls.qll`
  match `call.getFunction()` directly against `MemberExpression`, but
  `getFunction() instanceof MemberExpression` is **0** (it's always the wrapper),
  so their low-level-call / `.transfer` / `.send` sink detection likely under-fires.
  The `ExternalCall` heuristic found only ~3 calls across all of Uniswap; the
  wrapper-aware pattern (`getFunction().getAChild*()` + property in
  `call/delegatecall/staticcall/transfer/send`) finds 10. Don't treat
  `ExternalCall` as complete.
- When unsure, model directly on raw `TreeSitter` following
  `queries/analysis/FunctionList.ql`, which has verified-working
  visibility/mutability/state-access patterns.

## Harness note

`git mv`-ing a file makes this agent harness lose its "already read" state for the
new path — re-`Read` before `Edit`, or the edit errors.
