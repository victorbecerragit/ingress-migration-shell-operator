#!/usr/bin/env bash
# Install Kong Ingress Controller via Helm for E2E tests.
# Mirrors the structure of tests/lib/install-apisix.sh.
#
# Configurable via env vars:
#   E2E_KONG_NAMESPACE      (default: kong)
#   E2E_KONG_RELEASE        (default: kong)
#   E2E_KONG_CHART          (default: kong/ingress)
#   E2E_KONG_CHART_VERSION  (default: 0.4.0)
#   E2E_KONG_HELM_REPO_NAME (default: kong)
#   E2E_KONG_HELM_REPO_URL  (default: https://charts.konghq.com)
#   E2E_KONG_WAIT_TIMEOUT   (default: 300s)

set -euo pipefail

KONG_NAMESPACE=${E2E_KONG_NAMESPACE:-kong}
KONG_RELEASE=${E2E_KONG_RELEASE:-kong}
KONG_CHART=${E2E_KONG_CHART:-kong/ingress}
KONG_CHART_VERSION=${E2E_KONG_CHART_VERSION:-0.4.0}
KONG_HELM_REPO_NAME=${E2E_KONG_HELM_REPO_NAME:-kong}
KONG_HELM_REPO_URL=${E2E_KONG_HELM_REPO_URL:-https://charts.konghq.com}
KONG_WAIT_TIMEOUT=${E2E_KONG_WAIT_TIMEOUT:-300s}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing dependency: $1" >&2
    return 1
  fi
}

log() {
  echo "$*"
}

require_cmd helm
require_cmd kubectl

if kubectl get namespace "$KONG_NAMESPACE" >/dev/null 2>&1; then
  :
else
  log "Creating namespace: $KONG_NAMESPACE"
  kubectl create namespace "$KONG_NAMESPACE" >/dev/null
fi

if helm -n "$KONG_NAMESPACE" status "$KONG_RELEASE" >/dev/null 2>&1; then
  log "Kong Helm release '$KONG_RELEASE' already installed in namespace '$KONG_NAMESPACE'"
else
  log "Adding Helm repo: $KONG_HELM_REPO_NAME ($KONG_HELM_REPO_URL)"
  helm repo add "$KONG_HELM_REPO_NAME" "$KONG_HELM_REPO_URL" >/dev/null 2>&1 || true
  helm repo update "$KONG_HELM_REPO_NAME" >/dev/null

  log "Installing Kong Ingress Controller via Helm: $KONG_CHART@$KONG_CHART_VERSION"
  helm upgrade --install "$KONG_RELEASE" "$KONG_CHART" \
    --namespace "$KONG_NAMESPACE" \
    --version "$KONG_CHART_VERSION" \
    >/dev/null
fi

log "Waiting for Kong components to become ready (timeout: $KONG_WAIT_TIMEOUT)..."

# The deployment name varies slightly between chart versions; try both.
kubectl rollout status -n "$KONG_NAMESPACE" deployment/kong-controller --timeout="$KONG_WAIT_TIMEOUT" 2>/dev/null \
  || kubectl rollout status -n "$KONG_NAMESPACE" deployment/"$KONG_RELEASE" --timeout="$KONG_WAIT_TIMEOUT"

kubectl get ingressclass kong >/dev/null 2>&1 || {
  echo "Expected IngressClass 'kong' to exist after install" >&2
  exit 1
}

# The kong/ingress chart does not auto-create a GatewayClass; create it if absent.
# The annotation marks it as unmanaged so KIC accepts an externally-created Gateway.
if kubectl get gatewayclass kong >/dev/null 2>&1; then
  log "GatewayClass 'kong' already exists"
else
  log "Creating GatewayClass 'kong' for KIC..."
  kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: kong
  annotations:
    konghq.com/gatewayclass-unmanaged: "true"
spec:
  controllerName: konghq.com/kic-gateway-controller
EOF
fi

# Wait up to 30 s for KIC to accept the GatewayClass.
for i in $(seq 1 30); do
  accepted=$(kubectl get gatewayclass kong \
    -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
  if [ "$accepted" = "True" ]; then
    break
  fi
  sleep 1
done
kubectl get gatewayclass kong \
  -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' | grep -q "True" || {
  echo "GatewayClass 'kong' was not accepted by KIC within 30s" >&2
  exit 1
}

log "Kong is ready (namespace=$KONG_NAMESPACE, release=$KONG_RELEASE)"
