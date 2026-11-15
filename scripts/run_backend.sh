#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
cargo build --locked --manifest-path backend/Cargo.toml --bin stairclimb-server
exec backend/target/debug/stairclimb-server \
  --host "${STAIRCLIMB_HOST:-127.0.0.1}" \
  --port "${STAIRCLIMB_PORT:-8787}" \
  "$@"
