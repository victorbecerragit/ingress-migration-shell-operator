#!/usr/bin/env bash

set -euo pipefail

# dispatch_provider: validate provider alias, normalise to ingress2gateway
# --providers= flag value.
dispatch_provider() {
  local alias="${1:?provider name required}"
  case "$alias" in
    ingress-nginx)         echo "ingress-nginx" ;;
    apisix|apisix-ingress) echo "apisix" ;;
    kgateway)              echo "kgateway" ;;
    *)
      echo "ERROR: Unknown provider '${alias}'." \
           "Supported: ingress-nginx, apisix, apisix-ingress, kgateway" >&2
      return 1 ;;
  esac
}
