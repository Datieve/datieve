#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$(cd "$(dirname "$0")" && pwd)/build/linux/x64/release/bundle"
export PATH="${HOME}/bin:${HOME}/flutter/bin:${PATH}"

cd "$(dirname "$0")"
flutter clean
flutter build linux --release

mkdir -p "${ROOT}/bins/lib" "${ROOT}/bins/data"
cp -f "${BUNDLE}/datieve" "${ROOT}/bins/app"
cp -a "${BUNDLE}/lib/." "${ROOT}/bins/lib/"
cp -a "${BUNDLE}/data/." "${ROOT}/bins/data/"
chmod +x "${ROOT}/bins/app"

echo "Built ${ROOT}/bins/app (+ lib/, data/)"