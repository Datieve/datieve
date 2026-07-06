#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

"${ROOT}/agent/build.sh"
"${ROOT}/app-flutter/build.sh"

echo "bins contents:"
ls -la "${ROOT}/bins/"
ls -la "${ROOT}/bins/lib/" 2>/dev/null || true