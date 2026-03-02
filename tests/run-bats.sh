#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if ! command -v bats >/dev/null 2>&1; then
  echo "bats is required (https://github.com/bats-core/bats-core)" >&2
  exit 1
fi

exec bats "$ROOT_DIR/tests/bats"
