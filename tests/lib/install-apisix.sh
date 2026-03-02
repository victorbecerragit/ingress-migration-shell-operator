#!/usr/bin/env bash

set -euo pipefail

APISIX_NAMESPACE=${E2E_APISIX_NAMESPACE:-apisix}
APISIX_RELEASE=${E2E_APISIX_RELEASE:-apisix}
APISIX_CHART=${E2E_APISIX_CHART:-apisix/apisix}
APISIX_CHART_VERSION=${E2E_APISIX_CHART_VERSION:-2.13.0}
APISIX_HELM_REPO_NAME=${E2E_APISIX_HELM_REPO_NAME:-apisix}
APISIX_HELM_REPO_URL=${E2E_APISIX_HELM_REPO_URL:-https://charts.apiseven.com}
APISIX_WAIT_TIMEOUT=${E2E_APISIX_WAIT_TIMEOUT:-300s}

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

if kubectl get namespace "$APISIX_NAMESPACE" >/dev/null 2>&1; then
  :
else
  log "Creating namespace: $APISIX_NAMESPACE"
  kubectl create namespace "$APISIX_NAMESPACE" >/dev/null
fi

if helm -n "$APISIX_NAMESPACE" status "$APISIX_RELEASE" >/dev/null 2>&1; then
  log "APISIX Helm release '$APISIX_RELEASE' already installed in namespace '$APISIX_NAMESPACE'"
else
  log "Adding Helm repo: $APISIX_HELM_REPO_NAME ($APISIX_HELM_REPO_URL)"
  helm repo add "$APISIX_HELM_REPO_NAME" "$APISIX_HELM_REPO_URL" >/dev/null 2>&1 || true
  helm repo update "$APISIX_HELM_REPO_NAME" >/dev/null

  log "Installing APISIX (+ ingress controller) via Helm: $APISIX_CHART@$APISIX_CHART_VERSION"
  helm upgrade --install "$APISIX_RELEASE" "$APISIX_CHART" \
    --namespace "$APISIX_NAMESPACE" \
    --version "$APISIX_CHART_VERSION" \
    --set ingress-controller.enabled=true \
    >/dev/null
fi

log "Waiting for APISIX components to become ready (timeout: $APISIX_WAIT_TIMEOUT)..."

kubectl rollout status -n "$APISIX_NAMESPACE" statefulset/apisix-etcd --timeout="$APISIX_WAIT_TIMEOUT"
kubectl rollout status -n "$APISIX_NAMESPACE" deployment/apisix --timeout="$APISIX_WAIT_TIMEOUT"
kubectl rollout status -n "$APISIX_NAMESPACE" deployment/apisix-ingress-controller --timeout="$APISIX_WAIT_TIMEOUT"

kubectl get ingressclass apisix >/dev/null 2>&1 || {
  echo "Expected IngressClass 'apisix' to exist after install" >&2
  exit 1
}

log "APISIX is ready (namespace=$APISIX_NAMESPACE, release=$APISIX_RELEASE)"
