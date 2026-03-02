#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

BATS_BIN=${BATS_BIN:-}
if [[ -z "${BATS_BIN}" ]]; then
  if command -v bats >/dev/null 2>&1; then
    BATS_BIN="bats"
  elif [[ -x "$ROOT_DIR/tests/.tools/bin/bats" ]]; then
    BATS_BIN="$ROOT_DIR/tests/.tools/bin/bats"
  fi
fi
if [[ -z "${BATS_BIN}" ]]; then
  echo "bats is required. Install bats-core or run: git clone --depth 1 https://github.com/bats-core/bats-core.git tests/.tools/bats-core && tests/.tools/bats-core/install.sh tests/.tools" >&2
  exit 1
fi

exec "$BATS_BIN" "$ROOT_DIR/tests/bats"
