#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$(dirname "$0")"
cargo build --release
mkdir -p "${ROOT}/bins"
cp -f target/release/datieve "${ROOT}/bins/agent"
chmod +x "${ROOT}/bins/agent"
echo "Built ${ROOT}/bins/agent"