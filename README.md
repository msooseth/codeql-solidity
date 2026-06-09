# CodeQL Solidity
Originally by @lucasamorimca, see https://github.com/lucasamorimca/codeql-solidity

[![Test](https://github.com/lucasamorimca/codeql-solidity/actions/workflows/test.yml/badge.svg)](https://github.com/lucasamorimca/codeql-solidity/actions/workflows/test.yml)
[![Build](https://github.com/lucasamorimca/codeql-solidity/actions/workflows/build.yml/badge.svg)](https://github.com/lucasamorimca/codeql-solidity/actions/workflows/build.yml)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

A CodeQL extractor and query pack for analyzing Solidity smart contracts:
tree-sitter parsing, dataflow/taint tracking, and call-graph & inheritance
analysis.

## Setup

**1. Install the CodeQL CLI.** On Arch, via the AUR (`/opt/codeql`, symlinked to
`/usr/bin/codeql`):

```bash
pikaur -S codeql-cli-bin
codeql --version
```

**2. Install Rust** (≥ 1.82): `sudo pacman -S --needed rust` (or `rustup`).

**3. Build the extractor and generate the schema.** The dbscheme, QL library,
and compiled binary are build artifacts (not committed), so generate them once:

```bash
git clone https://github.com/lucasamorimca/codeql-solidity.git
cd codeql-solidity
cargo build --release

# Place the native binary where the extractor scripts expect it
BIN="$PWD/target/release/codeql-extractor-solidity"
install -m755    "$BIN" extractor-pack/tools/codeql-extractor-solidity
install -D -m755 "$BIN" extractor-pack/tools/linux64/extractor

# Generate the dbscheme + QL library from the grammar
"$BIN" generate \
  --dbscheme ql/lib/solidity.dbscheme \
  --library  ql/lib/codeql/solidity/ast/internal/TreeSitter.qll
cp ql/lib/solidity.dbscheme extractor-pack/solidity.dbscheme

export CODEQL_EXTRACTOR_SOLIDITY_ROOT="$PWD/extractor-pack"
```

## Usage

Build a database from your contracts, then run the queries against it. Pass
`--search-path` on `create` (to locate the extractor) and `--additional-packs`
on `analyze`/`query run` (to resolve the `solidity-all` dependency from this
clone):

```bash
codeql database create my-db \
  --language=solidity \
  --source-root=/path/to/contracts \
  --search-path="$PWD"

codeql database analyze my-db "$PWD/queries" \
  --format=sarif-latest --output=results.sarif \
  --additional-packs="$PWD"
```

## Example: Vault.sol

Let's put this contract under `contracts/Vault.sol`:
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
contract Vault {
    mapping(address => uint) public balances;
    function withdraw() public {
        uint amount = balances[msg.sender];

        // external call before state update
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok);
        balances[msg.sender] = 0;
    }
}
```

Then run this to parse the code:

```bash
codeql database create vault-db --language=solidity \
    --source-root=contracts --search-path="$PWD"
```

Run a single query interactively to see results as a table:

```bash
codeql query run queries/analysis/FunctionList.ql \
  --database=vault-db --additional-packs="$PWD"
```

```markdown
| function|Vault|withdraw|public|nonpayable||0|2|1|true|false|contracts/Vault.sol:5 |
```

Swap in `queries/analysis/ReentrancyPatterns.ql` (or any file under
`queries/analysis/`) to run a specific check, or use `database analyze` above to
run the whole pack into SARIF.

## Example: Uniswap v2 & v3

To exercise the pack against real-world code, clone the Uniswap core
repositories into `contracts/` and build a database over the lot. The extractor
is tree-sitter based (`build_modes: none`), so it parses `.sol` source directly
— no `npm install`, compiler, or build step required.

```bash
mkdir -p contracts && cd contracts
git clone --depth 1 https://github.com/Uniswap/v2-core.git uniswap-v2-core
git clone --depth 1 https://github.com/Uniswap/v3-core.git uniswap-v3-core
cd ..

codeql database create vault-db --language=solidity \
    --source-root=contracts --search-path="$PWD"
```

That extracts **81 `.sol` files** (Uniswap V2 + V3 core). The queries below live
in [`queries/analysis/`](queries/analysis/); run
one with `codeql query run queries/analysis/<name>.ql --database=vault-db
--additional-packs="$PWD"`.

> Note: a freshly created database has no `*.dbscheme.stats`, which the query
> compiler needs. `query run`/`database analyze` generate it on first use; if you
> hit `NoSuchFileException ... solidity.dbscheme.stats`, run
> `codeql dataset measure -j8 -o vault-db/db-solidity/solidity.dbscheme.stats vault-db/db-solidity`.

### `FloatingPragma.ql` — unpinned compiler versions

Flags `pragma solidity` directives that float: a caret/tilde, or an open-ended
lower bound (`>=`) with no upper bound. **29 of 84 pragmas** are flagged:

| Constraint          | Files | Example                                     |
|---------------------|------:|---------------------------------------------|
| `>=0.5.0`           |    25 | `interfaces/IUniswapV3Pool.sol:2`           |
| `>=0.4.0`           |     2 | V3 libs `FixedPoint96.sol`, `FixedPoint128.sol` |
| `>=0.6.0`/`>=0.7.0` |     2 | V3 libs `TransferHelper.sol`, `LowGasSafeMath.sol` |

The interesting finding is the **split between interface/library files and the
implementation contracts**: the flagged open-ended `>=` pragmas are all in
`interfaces/` and `libraries/`, while every core implementation contract pins an
*exact* version — `UniswapV2Pair.sol` uses `=0.5.16`, `UniswapV3Pool.sol` uses
`=0.7.6` — and is correctly **not** flagged. Five files that use a bounded range
(`>=0.5.0 <0.8.0`) are also correctly ignored.

### `RequireWithoutReason.ql` — reverts with no message

Flags `require(condition)` calls with no reason-string argument. **107 of 162**
`require` calls have no message. Broken down by area:

| Area     | with reason | bare (no reason) |
|----------|------------:|-----------------:|
| V2 core  |          21 |                0 |
| V3 core  |          25 |               38 |
| V3 tests |           9 |               69 |

This cleanly captures a real **stylistic difference between the two codebases**:
Uniswap V2 always supplies a namespaced reason string (e.g.
`require(unlocked == 1, 'UniswapV2: LOCKED')` at `UniswapV2Pair.sol:32`), whereas
V3 core frequently reverts bare for gas (e.g.
`require(msg.sender == IUniswapV3Factory(factory).owner())` at
`UniswapV3Pool.sol:113`).

### `AssertInProductionCode.ql` — `assert` outside test harnesses

`assert` should guard invariants, not validate input. This query flags `assert`
calls outside of test / property-checking paths. The corpus contains **151
`assert` calls, and the query reports 0**: every one lives in an Echidna/Manticore
property harness under `test/`, `echidna/`, `crytic/`, or `audits/`. In other
words, Uniswap reserves `assert` for fuzzing invariants and uses `require` in
production — a clean bill of health that the query confirms.

### `CalleeKinds.ql` — how calls resolve to their target

The extractor collapses the grammar's generic `expression` wrapper node, so a
call's `function` field (`CallExpression.getFunction()`) returns the real callee
directly. This query classifies all **1124 call expressions** by that callee
kind:

| Inner callee node  | Count | Example                  |
|--------------------|------:|--------------------------|
| `Identifier`       |   605 | `require(x)`, `foo(x)`    |
| `MemberExpression` |   487 | `a.b(x)` → callee `b`     |
| `NewExpression`    |    30 | `new Foo(x)`             |
| `StructExpression` |     2 | `new T{salt: …}()` deploy |

Every call has a resolvable callee (605 + 487 + 30 + 2 = 1124) — the call→callee
link is complete. A naïve callee lookup that only matches a direct `Identifier`
would still miss the 487 member calls, so resolution must handle both the
`Identifier` and `MemberExpression` cases (see the library's
[`CallResolution.qll`](ql/lib/codeql/solidity/callgraph/CallResolution.qll)).

## Project structure

```
extractor/       Rust extractor (tree-sitter based)
ql/lib/          QL library — pack lucasamorimca/solidity-all
queries/         Security queries — pack lucasamorimca/solidity-queries
  analysis/      Analysis & security checks (incl. the "Example: Uniswap" queries)
extractor-pack/  CodeQL extractor config + tools
tests/           Test fixtures
```

CI builds the extractor and runs this full pipeline on every push —
see [`.github/workflows/build.yml`](.github/workflows/build.yml).

## License

Apache-2.0
