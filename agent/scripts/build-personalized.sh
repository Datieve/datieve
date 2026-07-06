#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${DATIEVE_PERSONAL_WATERMARK_ID:?DATIEVE_PERSONAL_WATERMARK_ID is required}"
: "${DATIEVE_PERSONAL_DISK_SERIAL:?DATIEVE_PERSONAL_DISK_SERIAL is required}"

export DATIEVE_PERSONAL_BUILD_ID="${DATIEVE_PERSONAL_BUILD_ID:-$(date -u +%Y%m%d%H%M%S)-$(printf '%s:%s' "$DATIEVE_PERSONAL_WATERMARK_ID" "$DATIEVE_PERSONAL_DISK_SERIAL" | sha256sum | cut -c1-12)}"

if [[ -n "${OLLVM_RUSTC:-}" ]]; then
  export RUSTC="$OLLVM_RUSTC"
  export CARGO_BUILD_RUSTC="$RUSTC"
  echo "Building personalized Datieve agent with OLLVM rustc: $RUSTC"
else
  echo "Building personalized Datieve agent with default rustc"
fi

echo "Build id: $DATIEVE_PERSONAL_BUILD_ID"

# Must match Agent-main/build.rs and license-server computePersonalBindingHash:
# label || watermark || 0x00 || disk_serial || 0x00 || build_id
DATIEVE_PERSONAL_BINDING_HASH="$(
  printf '%s%s\0%s\0%s' \
    "DATIEVE-PERSONAL-BINDING-V1" \
    "$DATIEVE_PERSONAL_WATERMARK_ID" \
    "$DATIEVE_PERSONAL_DISK_SERIAL" \
    "$DATIEVE_PERSONAL_BUILD_ID" \
    | sha256sum | awk '{print $1}'
)"
echo "Binding hash: $DATIEVE_PERSONAL_BINDING_HASH"

cargo build --release --locked
cargo build --release --locked --bin datieve-sentinel --features sentinel-bin

mkdir -p target/personalized
install -m 0755 target/release/datieve "target/personalized/datieve-$DATIEVE_PERSONAL_BUILD_ID"
install -m 0755 target/release/datieve-sentinel "target/personalized/datieve-sentinel-$DATIEVE_PERSONAL_BUILD_ID"

sha256sum \
  "target/personalized/datieve-$DATIEVE_PERSONAL_BUILD_ID" \
  "target/personalized/datieve-sentinel-$DATIEVE_PERSONAL_BUILD_ID" \
  > "target/personalized/SHA256SUMS-$DATIEVE_PERSONAL_BUILD_ID.txt"

echo "Personalized outputs:"
echo "  target/personalized/datieve-$DATIEVE_PERSONAL_BUILD_ID"
echo "  target/personalized/datieve-sentinel-$DATIEVE_PERSONAL_BUILD_ID"
echo "  target/personalized/SHA256SUMS-$DATIEVE_PERSONAL_BUILD_ID.txt"

if [[ -n "${DATIEVE_BUILD_REQUEST_ID:-}" && -n "${DATIEVE_BUILD_COMPLETE_URL:-}" && -n "${DATIEVE_BUILD_QUEUE_TOKEN:-}" ]]; then
  echo "Recording completed build with license server..."
  curl -fsS -X POST "$DATIEVE_BUILD_COMPLETE_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $DATIEVE_BUILD_QUEUE_TOKEN" \
    --data "$(printf '{"request_id":"%s","personal_build_id":"%s","personal_binding_hash":"%s","disk_serial":"%s"}' \
      "$DATIEVE_BUILD_REQUEST_ID" \
      "$DATIEVE_PERSONAL_BUILD_ID" \
      "$DATIEVE_PERSONAL_BINDING_HASH" \
      "$DATIEVE_PERSONAL_DISK_SERIAL")"
  echo
  echo "Build recorded as sent."
fi
