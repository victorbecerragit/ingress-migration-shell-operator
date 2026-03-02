#!/usr/bin/env bash

set -euo pipefail

KGATEWAY_NAMESPACE=${E2E_KGATEWAY_NAMESPACE:-kgateway-system}
KGATEWAY_CRDS_RELEASE=${E2E_KGATEWAY_CRDS_RELEASE:-kgateway-crds}
KGATEWAY_RELEASE=${E2E_KGATEWAY_RELEASE:-kgateway}
KGATEWAY_VERSION=${E2E_KGATEWAY_VERSION:-v2.2.1}

KGATEWAY_CRDS_CHART=${E2E_KGATEWAY_CRDS_CHART:-oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds}
KGATEWAY_CHART=${E2E_KGATEWAY_CHART:-oci://cr.kgateway.dev/kgateway-dev/charts/kgateway}

GATEWAY_API_VERSION=${E2E_GATEWAY_API_VERSION:-v1.4.0}
WAIT_TIMEOUT=${E2E_KGATEWAY_WAIT_TIMEOUT:-300s}

log() {
  echo "[$(date +%H:%M:%S)] $*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing dependency: $1" >&2
    return 1
  fi
}

require_cmd kubectl
require_cmd helm

log "Creating namespace (if needed): $KGATEWAY_NAMESPACE"
kubectl get namespace "$KGATEWAY_NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$KGATEWAY_NAMESPACE" >/dev/null

if kubectl get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1; then
  log "Gateway API CRDs already present"
else
  log "Installing Gateway API CRDs: $GATEWAY_API_VERSION"
  kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null
fi

if helm -n "$KGATEWAY_NAMESPACE" status "$KGATEWAY_CRDS_RELEASE" >/dev/null 2>&1; then
  log "kgateway-dev CRDs Helm release '$KGATEWAY_CRDS_RELEASE' already installed in namespace '$KGATEWAY_NAMESPACE'"
else
  log "Installing kgateway-dev CRDs via Helm: $KGATEWAY_CRDS_CHART@$KGATEWAY_VERSION"
  helm upgrade --install "$KGATEWAY_CRDS_RELEASE" "$KGATEWAY_CRDS_CHART" \
    --namespace "$KGATEWAY_NAMESPACE" \
    --version "$KGATEWAY_VERSION" \
    >/dev/null
fi

if helm -n "$KGATEWAY_NAMESPACE" status "$KGATEWAY_RELEASE" >/dev/null 2>&1; then
  log "kgateway-dev Helm release '$KGATEWAY_RELEASE' already installed in namespace '$KGATEWAY_NAMESPACE'"
else
  log "Installing kgateway-dev via Helm: $KGATEWAY_CHART@$KGATEWAY_VERSION"
  helm upgrade --install "$KGATEWAY_RELEASE" "$KGATEWAY_CHART" \
    --namespace "$KGATEWAY_NAMESPACE" \
    --version "$KGATEWAY_VERSION" \
    >/dev/null
fi

log "Waiting for kgateway-dev components to become ready (timeout: $WAIT_TIMEOUT)..."
kubectl wait -n "$KGATEWAY_NAMESPACE" --for=condition=available deployment --all --timeout="$WAIT_TIMEOUT" >/dev/null

log "kgateway-dev is ready (namespace=$KGATEWAY_NAMESPACE, release=$KGATEWAY_RELEASE)"
