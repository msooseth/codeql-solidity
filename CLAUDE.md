# Working notes for codeql-solidity

Non-obvious things learned working in this repo. The README covers setup/usage and
the Uniswap example; this file is the gotchas that bite you when **writing queries
and touching the extractor/library**. (This file is gitignored.)

## Git workflow

- **Never create a branch to commit.** Commit directly to `main`. Do not branch
  "first" before committing, do not open PRs unless explicitly asked. When the
  user says "commit", commit to whatever branch is checked out (normally `main`).

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

## AST shape: the `expression` wrapper is now collapsed in the extractor

The grammar exposes `expression` as a visible choice rule, so every expression
*used* to sit inside a generic `expression` wrapper node (the #1 source of "my
query matches nothing"). **The extractor now collapses that wrapper**
(`is_collapsible_wrapper`/`resolve_wrapper` in `extractor/src/extraction/extractor.rs`),
re-parenting the inner node directly. So after re-extraction:

- **`CallExpression.getFunction()` returns the real callee directly** — one of
  `Identifier` (`f(x)`), `MemberExpression` (`a.b(x)` → name is `getProperty()`),
  `NewExpression` (`new T(x)`), `StructExpression` (`new T{salt: …}()` /
  `x.call{value: …}(…)`). Callee-name resolution: cast `getFunction()` to
  `Identifier` (`getValue()`) or `MemberExpression`
  (`getProperty()...getValue()`). No `getAChild*()` unwrap needed.
  `ql/lib/codeql/solidity/callgraph/CallResolution.qll` is the reference pattern.
- Likewise **binary/assignment operands (`getLeft()`/`getRight()`), array index
  (`getIndex()`), and call-argument values are now the real expression directly**
  — `CallArgument`'s single child is the argument expression (no inner wrapper).
  `MemberExpression.getObject()` was never wrapped.
- Only `expression` is collapsed (single-child, so `#keyset[parent,index]` is
  preserved). `statement`, `boolean_literal`, `expression_statement`,
  `parenthesized_expression`, etc. are **not** collapsed.
- Still wrappers (NOT collapsed): **`Visibility` and `StateMutability`** — the
  keyword (`public`/`external`/`view`/`pure`/`payable`) is the value of their
  *child* token, so `solidity_tokeninfo(visibilityNode, …)` is empty; use
  `wrapper.getAChild().getValue()`. (Bug fixed in `Function.qll` on this branch.)
- `CallExpression.getChild(i)` is still **dead** — the codegen emits a per-type
  `getChild` override backed by an unpopulated `solidity_<kind>_child` relation
  (see Library reliability below). Use `getAChild()` / `getAFieldOrChild()` / the
  typed field accessors / `getFunction()`, not indexed `getChild(i)`.
- **Pragma operators** (`^ >= > < <= =`) are plain `AstNode` tokens whose
  `getValue()` has leading whitespace — `.trim()` it. The typed
  `SolidityVersionComparisonOperator` node has **no** `getValue()`. The version
  string lives in `SolidityVersion` nodes.
- `require`/`assert`/`revert` are `CallExpression`s; the callee is
  `c.getFunction().(Identifier)` directly (its `getValue()` is the name). Argument
  count = `count(CallArgument a | a.getParent() = c)` — `require(cond)` = 1,
  `require(cond, "msg")` = 2.

## Library reliability

The convenience helpers in `ql/lib` are uneven — verify counts against a known
corpus before relying on them.

- Fixed on this branch: `FunctionDef.getVisibility()` / `isView` / `isPure` /
  `isPayable` (all returned empty due to the `Visibility`/`StateMutability`
  wrapper bug — those wrappers are *not* collapsed).
- Fixed on this branch: `dataflow/TaintTracking.qll`. All sinks/sanitizers
  previously returned **0** from three stacked bugs: (1) `member =
  call.getFunction()` matched the (then-present) wrapper, not the
  `MemberExpression`; (2) `.getProperty()...toString()` / `Identifier.toString()`
  return the **QL class name**, not source text (→ `.getValue()`); (3) argument
  access via `call.getChild(0)` is dead. Now written against the **collapsed** AST
  (`getFunction()`/`getLeft()`/`getRight()`/`getIndex()`/`CallArgument` child are
  the real expression directly) and firing on Uniswap (ExternalCallTargetSink 10,
  CallDataSink 5, EtherTransferAmountSink 10, StorageWriteSink 154,
  RequireCheckSanitizer 368, BoundsCheckSanitizer 85, etc.).
  `ReentrancyGuardSanitizer` left as-is — separate bug (unbound `this`; needs a
  design decision), documented inline.
- The `expression` wrapper collapse was done in the **extractor** (see the AST
  shape section). `getAChild*()`-based callee/operand unwraps in the lib
  (`CallResolution.qll`, `ExternalCalls.qll`, etc.) still work afterward because
  `getAChild*()` is reflexive — they are now over-broad but correct. New code
  should use the direct field accessors.
- Queries broken by the collapse and fixed on this branch: `CalleeKinds.ql`
  (`getFunction().getAChild()` → `getFunction()`), `RequireWithoutReason.ql` /
  `AssertInProductionCode.ql` (the `id.getParent() = c.getFunction()` idiom →
  `c.getFunction().(Identifier)`). README CalleeKinds prose updated. Documented
  corpus numbers unchanged (FloatingPragma 29, RequireWithoutReason 107/162,
  CalleeKinds 1124, AssertInProductionCode 0/151).
- Still-dead `getChild(i)` (separate, NOT fixed): codegen
  (`extractor/src/codegen/mod.rs` `generate_child_accessor`) emits per-type
  `getChild` **overrides** backed by `solidity_<kind>_child` relations that the
  extractor never populates (only `solidity_ast_node_parent` + fields). The
  override shadows the working base `AstNode.getChild`, so `getChild(i)` is dead
  for overridden types (CallExpression, CallArgument, …) but works for
  non-overridden ones (ArrayAccess). Note: much of `controlflow/` and
  `dataflow/internal/` leans on `getChild(i)` and so is pre-existingly broken.
- When unsure, model directly on raw `TreeSitter` following
  `queries/analysis/FunctionList.ql`, which has verified-working
  visibility/mutability/state-access patterns.

## Harness note

`git mv`-ing a file makes this agent harness lose its "already read" state for the
new path — re-`Read` before `Edit`, or the edit errors.
