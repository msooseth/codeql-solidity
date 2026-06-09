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

### Example

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

Then run:

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

## Project structure

```
extractor/       Rust extractor (tree-sitter based)
ql/lib/          QL library — pack lucasamorimca/solidity-all
queries/         Security queries — pack lucasamorimca/solidity-queries
extractor-pack/  CodeQL extractor config + tools
tests/           Test fixtures
```

CI builds the extractor and runs this full pipeline on every push —
see [`.github/workflows/build.yml`](.github/workflows/build.yml).

## License

Apache-2.0
