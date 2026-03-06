#!/usr/bin/env bash

set -euo pipefail

# dispatch_provider: validate provider alias, normalise to ingress2gateway
# --providers= flag value.
dispatch_provider() {
  local alias="${1:?provider name required}"
  case "$alias" in
    ingress-nginx)         echo "ingress-nginx" ;;
    apisix|apisix-ingress) echo "apisix" ;;
    kong|kong-ingress)     echo "kong" ;;
    # kgateway and kgateway-dev both map to ingress2gateway's "kgateway" emitter.
    # "kgateway-dev" is the dev/nightly channel of the same project; the emitter
    # name is identical so no separate case is needed in ingress2gateway itself.
    kgateway|kgateway-dev) echo "kgateway" ;;
    *)
      echo "ERROR: Unknown provider '${alias}'." \
           "Supported: ingress-nginx, apisix, apisix-ingress, kong, kong-ingress," \
           "kgateway, kgateway-dev" >&2
      return 1 ;;
  esac
}
