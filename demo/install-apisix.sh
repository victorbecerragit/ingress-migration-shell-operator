#!/usr/bin/env bash
# =============================================================================
# demo/install-apisix.sh — Optional: install Apache APISIX + APISIX Ingress
# Controller into the demo Kind cluster.
#
# This is only needed if you want to try migrations for the `apisix` provider
# (Ingress resources with `spec.ingressClassName: apisix`).
# =============================================================================

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$DEMO_DIR")"

APISIX_NAMESPACE=${APISIX_NAMESPACE:-apisix}
APISIX_RELEASE=${APISIX_RELEASE:-apisix}
APISIX_CHART_VERSION=${APISIX_CHART_VERSION:-2.13.0}
APISIX_WAIT_TIMEOUT=${APISIX_WAIT_TIMEOUT:-300s}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing dependency: $1" >&2
    exit 1
  fi
}

for cmd in kubectl helm; do
  require_cmd "$cmd"
done

echo "Installing APISIX into namespace '$APISIX_NAMESPACE' (chart version: $APISIX_CHART_VERSION)"

E2E_APISIX_NAMESPACE="$APISIX_NAMESPACE" \
E2E_APISIX_RELEASE="$APISIX_RELEASE" \
E2E_APISIX_CHART_VERSION="$APISIX_CHART_VERSION" \
E2E_APISIX_WAIT_TIMEOUT="$APISIX_WAIT_TIMEOUT" \
bash "$REPO_DIR/tests/lib/install-apisix.sh"

echo "Done. IngressClass 'apisix' should now exist."
