#!/usr/bin/env bash
# Install Traefik Ingress Controller via Helm for E2E tests.
# Mirrors the structure of tests/lib/install-kong.sh.
#
# Configurable via env vars:
#   E2E_TRAEFIK_NAMESPACE      (default: traefik)
#   E2E_TRAEFIK_RELEASE        (default: traefik)
#   E2E_TRAEFIK_CHART          (default: traefik/traefik)
#   E2E_TRAEFIK_CHART_VERSION  (default: 28.3.0)
#   E2E_TRAEFIK_HELM_REPO_NAME (default: traefik)
#   E2E_TRAEFIK_HELM_REPO_URL  (default: https://traefik.github.io/charts)
#   E2E_TRAEFIK_WAIT_TIMEOUT   (default: 300s)

set -euo pipefail

TRAEFIK_NAMESPACE=${E2E_TRAEFIK_NAMESPACE:-traefik}
TRAEFIK_RELEASE=${E2E_TRAEFIK_RELEASE:-traefik}
TRAEFIK_CHART=${E2E_TRAEFIK_CHART:-traefik/traefik}
TRAEFIK_CHART_VERSION=${E2E_TRAEFIK_CHART_VERSION:-28.3.0}
TRAEFIK_HELM_REPO_NAME=${E2E_TRAEFIK_HELM_REPO_NAME:-traefik}
TRAEFIK_HELM_REPO_URL=${E2E_TRAEFIK_HELM_REPO_URL:-https://traefik.github.io/charts}
TRAEFIK_WAIT_TIMEOUT=${E2E_TRAEFIK_WAIT_TIMEOUT:-300s}

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

if kubectl get namespace "$TRAEFIK_NAMESPACE" >/dev/null 2>&1; then
  :
else
  log "Creating namespace: $TRAEFIK_NAMESPACE"
  kubectl create namespace "$TRAEFIK_NAMESPACE" >/dev/null
fi

if helm -n "$TRAEFIK_NAMESPACE" status "$TRAEFIK_RELEASE" >/dev/null 2>&1; then
  log "Traefik Helm release '$TRAEFIK_RELEASE' already installed in namespace '$TRAEFIK_NAMESPACE'"
else
  log "Adding Helm repo: $TRAEFIK_HELM_REPO_NAME ($TRAEFIK_HELM_REPO_URL)"
  helm repo add "$TRAEFIK_HELM_REPO_NAME" "$TRAEFIK_HELM_REPO_URL" >/dev/null 2>&1 || true
  helm repo update "$TRAEFIK_HELM_REPO_NAME" >/dev/null

  log "Installing Traefik Ingress Controller via Helm: $TRAEFIK_CHART@$TRAEFIK_CHART_VERSION"
  helm upgrade --install "$TRAEFIK_RELEASE" "$TRAEFIK_CHART" \
    --namespace "$TRAEFIK_NAMESPACE" \
    --version "$TRAEFIK_CHART_VERSION" \
    --set ingressClass.enabled=true \
    --set ingressClass.isDefaultClass=false \
    >/dev/null
fi

log "Waiting for Traefik components to become ready (timeout: $TRAEFIK_WAIT_TIMEOUT)..."
kubectl rollout status deployment \
  -n "$TRAEFIK_NAMESPACE" \
  --timeout="$TRAEFIK_WAIT_TIMEOUT" \
  >/dev/null

log "Traefik Ingress Controller is ready."
