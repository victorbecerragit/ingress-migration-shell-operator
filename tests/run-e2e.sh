#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST_DIR="$ROOT_DIR/tests/manifests"

CLUSTER_NAME=${E2E_KIND_CLUSTER_NAME:-ingress-migration-e2e}
USE_KIND=${E2E_KIND:-0}
VERBOSE=${E2E_VERBOSE:-0}

CM_NAMESPACE=${E2E_CM_NAMESPACE:-ingress-migration-mock}
CM_NAME=${E2E_CM_NAME:-migrate-ingress-mock}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing dependency: $1" >&2
    return 1
  fi
}

die() {
  echo "$*" >&2
  exit 1
}

if ! require_cmd kubectl; then
  die "kubectl is required"
fi
if ! require_cmd jq; then
  die "jq is required"
fi

INGRESS2GATEWAY_VERSION=${E2E_INGRESS2GATEWAY_VERSION:-v0.5.0}
INGRESS2GATEWAY_BIN_DIR="$ROOT_DIR/tests/.bin"

ensure_ingress2gateway() {
  if command -v ingress2gateway >/dev/null 2>&1; then
    return 0
  fi

  if ! command -v curl >/dev/null 2>&1; then
    die "ingress2gateway not found and curl is missing (install ingress2gateway or curl)"
  fi
  if ! command -v tar >/dev/null 2>&1; then
    die "ingress2gateway not found and tar is missing (install ingress2gateway or tar)"
  fi

  mkdir -p "$INGRESS2GATEWAY_BIN_DIR"
  local bin_path="$INGRESS2GATEWAY_BIN_DIR/ingress2gateway"
  if [[ -x "$bin_path" ]]; then
    export PATH="$INGRESS2GATEWAY_BIN_DIR:$PATH"
    return 0
  fi

  local arch
  arch=$(uname -m)
  local asset_arch
  case "$arch" in
    x86_64|amd64) asset_arch="x86_64" ;;
    aarch64|arm64) asset_arch="arm64" ;;
    *) die "Unsupported architecture for auto-download: $arch (set ingress2gateway on PATH manually)" ;;
  esac

  local url="https://github.com/kubernetes-sigs/ingress2gateway/releases/download/${INGRESS2GATEWAY_VERSION}/ingress2gateway_Linux_${asset_arch}.tar.gz"
  echo "ingress2gateway not found; downloading ${INGRESS2GATEWAY_VERSION} to tests/.bin/..."
  local tmp
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/ingress2gateway.tgz" "$url" || die "Failed to download: $url"
  tar -xzf "$tmp/ingress2gateway.tgz" -C "$tmp" || die "Failed to extract ingress2gateway"
  if [[ ! -f "$tmp/ingress2gateway" ]]; then
    die "Downloaded archive did not contain ingress2gateway binary"
  fi
  mv "$tmp/ingress2gateway" "$bin_path"
  chmod +x "$bin_path"
  rm -rf "$tmp"
  export PATH="$INGRESS2GATEWAY_BIN_DIR:$PATH"
}

ensure_ingress2gateway

if [[ "$VERBOSE" == "1" ]]; then
  echo "Using ingress2gateway at: $(command -v ingress2gateway)"
fi

KIND_CREATED=0
if [[ "$USE_KIND" == "1" ]]; then
  require_cmd kind || die "kind is required when E2E_KIND=1"

  if kind get clusters | grep -qx "$CLUSTER_NAME"; then
    echo "Kind cluster '$CLUSTER_NAME' already exists; reusing it."
  else
    echo "Creating kind cluster '$CLUSTER_NAME'..."
    kind create cluster --name "$CLUSTER_NAME" >/dev/null
    KIND_CREATED=1
  fi
fi

cleanup() {
  rm -f "${OBJ_FILE:-}" "${CTX_FILE:-}" "${HOOK_LOG:-}" 2>/dev/null || true
  if [[ "$KIND_CREATED" == "1" ]]; then
    echo "Deleting kind cluster '$CLUSTER_NAME'..."
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null || true
  fi
}
trap cleanup EXIT

echo "Applying mock cluster resources..."
kubectl apply -f "$MANIFEST_DIR/mock-cluster.yaml" >/dev/null
kubectl apply -f "$MANIFEST_DIR/trigger-dryrun.yaml" >/dev/null

OBJ_FILE=$(mktemp)
CTX_FILE=$(mktemp)

kubectl get configmap "$CM_NAME" -n "$CM_NAMESPACE" -o json > "$OBJ_FILE"

# Build a synthetic Flant binding context file.
# The hook script expects an array where each element has a top-level `type` and `object`.
jq -n --slurpfile o "$OBJ_FILE" '[{type:"Event", object:$o[0]}]' > "$CTX_FILE"

echo "Running migration hook (dry-run) via synthetic binding context..."
HOOK_LOG=$(mktemp)
if [[ "$VERBOSE" == "1" ]]; then
  BINDING_CONTEXT_PATH="$CTX_FILE" bash "$ROOT_DIR/scripts/migrate.sh" | tee "$HOOK_LOG"
else
  if ! BINDING_CONTEXT_PATH="$CTX_FILE" bash "$ROOT_DIR/scripts/migrate.sh" >"$HOOK_LOG" 2>&1; then
    echo "Hook execution failed. Output:" >&2
    cat "$HOOK_LOG" >&2
    exit 1
  fi
fi

convertedResources=$(kubectl get configmap "$CM_NAME" -n "$CM_NAMESPACE" -o jsonpath='{.data.convertedResources}' 2>/dev/null || true)
error=$(kubectl get configmap "$CM_NAME" -n "$CM_NAMESPACE" -o jsonpath='{.data.error}' 2>/dev/null || true)
applied=$(kubectl get configmap "$CM_NAME" -n "$CM_NAMESPACE" -o jsonpath='{.data.applied}' 2>/dev/null || true)

if [[ -z "$convertedResources" ]]; then
  die "Expected .data.convertedResources to be set on ConfigMap $CM_NAMESPACE/$CM_NAME"
fi

if ! [[ "$convertedResources" =~ ^[0-9]+$ ]]; then
  die "Expected convertedResources to be an integer, got: '$convertedResources'"
fi

if [[ "$error" != "none" ]]; then
  die "Expected error=none, got: '$error'"
fi

if [[ "$applied" != "false" ]]; then
  die "Expected applied=false for dry-run, got: '$applied'"
fi

if [[ "$convertedResources" -lt 1 ]]; then
  die "Expected convertedResources >= 1, got: '$convertedResources'"
fi

echo "PASS: convertedResources=$convertedResources applied=$applied error=$error"
