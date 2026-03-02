#!/usr/bin/env bash

set -euo pipefail

# Backwards-compatible wrapper.
# The canonical demo installer lives in demo/install-kgateway.sh.
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

exec bash "$ROOT_DIR/demo/install-kgateway.sh" "$@"
