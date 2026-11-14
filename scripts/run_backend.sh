#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
exec python3 -m backend.server \
  --host "${STAIRCLIMB_HOST:-127.0.0.1}" \
  --port "${STAIRCLIMB_PORT:-8787}" \
  --database "${STAIRCLIMB_DATABASE:-.runtime/stairclimb.sqlite3}" "$@"
