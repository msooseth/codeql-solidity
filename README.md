# CodeQL Solidity

[![Test](https://github.com/lucasamorimca/codeql-solidity/actions/workflows/test.yml/badge.svg)](https://github.com/lucasamorimca/codeql-solidity/actions/workflows/test.yml)
[![Release](https://github.com/lucasamorimca/codeql-solidity/actions/workflows/release.yml/badge.svg)](https://github.com/lucasamorimca/codeql-solidity/releases)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

CodeQL extractor and queries for Solidity smart contract security analysis.

## Features

- Tree-sitter based Solidity parsing
- Dataflow and taint tracking
- Call graph and inheritance analysis

## Installation

Build from this repo and reference the packs locally — see
[Setup on Arch Linux (from source)](#setup-on-arch-linux-from-source) below
(the steps are the same on any Linux x86_64 host; only the CLI install in
step 1 is Arch-specific).

> **Not yet available: registry install.** These packs are **not** published to
> a CodeQL package registry, so the following do **not** work today — they fail
> with *"not found in the registry"* (`pack download`) or *"path does not
> exist"* (`pack install <name>`, which treats its argument as a local path):
>
> ```bash
> # Does NOT work — packs are unpublished
> codeql pack download lucasamorimca/solidity-all
> codeql pack download lucasamorimca/solidity-queries
> ```
>
> The prebuilt extractor binaries on the
> [Releases](https://github.com/lucasamorimca/codeql-solidity/releases) page are
> real and can be downloaded instead of building the Rust extractor yourself
> (step 3 below), but the QL packs still have to come from this repo.

## Setup on Arch Linux (from source)

This walks through a complete, registry-free setup on Arch Linux (x86_64),
building the extractor natively and running everything from this clone.

### 1. Install the CodeQL CLI

The CLI is not in the official repos. Use the AUR package
[`codeql-cli-bin`](https://aur.archlinux.org/packages/codeql-cli-bin), which
pulls the prebuilt CLI from `github/codeql-cli-binaries`:

```bash
pikaur -S codeql-cli-bin
```

If the AUR `pkgver` lags behind, edit the `PKGBUILD` to the version you want
(e.g. `2.25.6`), refresh the checksum, and build it:

```bash
updpkgsums          # recompute sha256sums for the new pkgver
makepkg -si         # build and install (installs to /opt/codeql, symlinks /usr/bin/codeql)
```

Verify:

```bash
codeql --version    # CodeQL command-line toolchain release 2.25.6
```

### 2. Install Rust

```bash
sudo pacman -S --needed rust          # or: rustup default stable
rustc --version                       # needs >= 1.82
```

### 3. Clone and build the extractor

```bash
git clone https://github.com/lucasamorimca/codeql-solidity.git
cd codeql-solidity
cargo build --release                 # builds target/release/codeql-extractor-solidity
```

### 4. Install the binary into the extractor pack

The extractor scripts look for the native binary in two places — `index-files.sh`
expects `tools/codeql-extractor-solidity`, and `autobuild.sh` (used by
`database create` on Linux x64) expects `tools/linux64/extractor`:

```bash
BIN="$PWD/target/release/codeql-extractor-solidity"
install -m755 "$BIN" extractor-pack/tools/codeql-extractor-solidity
install -D -m755 "$BIN" extractor-pack/tools/linux64/extractor
```

### 5. Generate the dbscheme and QL library

These are `.gitignore`'d build artifacts (regenerated on every build), so you
must produce them before any query can compile or any database can be finalized:

```bash
./target/release/codeql-extractor-solidity generate \
  --dbscheme ql/lib/solidity.dbscheme \
  --library ql/lib/codeql/solidity/ast/internal/TreeSitter.qll
cp ql/lib/solidity.dbscheme extractor-pack/solidity.dbscheme
```

### 6. Point CodeQL at the local extractor pack

```bash
export CODEQL_EXTRACTOR_SOLIDITY_ROOT="$PWD/extractor-pack"
```

### 7. Create a database and analyze

Because the packs are resolved locally, pass `--search-path` when creating the
database (it locates the extractor) and `--additional-packs` when analyzing (it
resolves the `solidity-all` dependency from this clone — `--search-path` is
ignored once a pack lock file is present):

```bash
# Create a database from your contracts
codeql database create my-db \
  --language=solidity \
  --source-root=/path/to/contracts \
  --search-path="$PWD"

# Run the query pack
codeql database analyze my-db "$PWD/queries" \
  --format=sarif-latest \
  --output=results.sarif \
  --additional-packs="$PWD"
```

The same end-to-end flow runs in CI — see
[`.github/workflows/build.yml`](.github/workflows/build.yml).

## Usage

```bash
# Create database
export CODEQL_EXTRACTOR_SOLIDITY_ROOT=/path/to/extractor-pack
codeql database create db --language=solidity --source-root=/path/to/contracts

# Run analysis
codeql database analyze db lucasamorimca/solidity-queries --format=sarif-latest --output=results.sarif
```

## Project Structure

```
codeql-solidity/
├── extractor/           # Rust extractor binary
├── ql/lib/              # QL library (lucasamorimca/solidity-all)
├── queries/             # Security queries (lucasamorimca/solidity-queries)
├── extractor-pack/      # CodeQL extractor configuration
└── tests/               # Test fixtures
```

## Building from Source

```bash
cd extractor
cargo build --release

# Generate schema and QL library
./target/release/codeql-extractor-solidity generate \
  --dbscheme ../ql/lib/solidity.dbscheme \
  --library ../ql/lib/codeql/solidity/ast/internal/TreeSitter.qll
```

## License

Apache-2.0
