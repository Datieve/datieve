#!/usr/bin/env bash
# Build the Tier-1 agent with an OLLVM-enabled rustc toolchain.
#
# Prerequisites:
#   - OLLVM rustc installed and available as the compiler named below
#   - cargo and the usual Datieve build dependencies
#
# Usage:
#   OLLVM_RUSTC=/path/to/ollvm-rustc ./scripts/build-ollvm.sh
#
# Override the compiler:
#   OLLVM_RUSTC=rustc-ollvm cargo build --release

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export RUSTC="${OLLVM_RUSTC:-rustc-ollvm}"
export CARGO_BUILD_RUSTC="${RUSTC}"

echo "Building datieve with OLLVM rustc: ${RUSTC}"
cargo build --release "$@"