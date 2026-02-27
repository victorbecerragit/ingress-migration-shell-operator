#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

MANIFESTS_MOCK_CLUSTER=${MANIFESTS_MOCK_CLUSTER:-"$ROOT_DIR/tests/manifests/mock-cluster.yaml"}
MANIFESTS_TRIGGER=${MANIFESTS_TRIGGER:-"$ROOT_DIR/tests/manifests/trigger-dryrun.yaml"}

TRIGGER_NAMESPACE=${TRIGGER_NAMESPACE:-"ingress-migration-mock"}
TRIGGER_CONFIGMAP=${TRIGGER_CONFIGMAP:-"migrate-ingress-mock"}

E2E_BIN_DIR=${E2E_BIN_DIR:-"$ROOT_DIR/tests/.bin"}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

ensure_ingress2gateway() {
  if command -v ingress2gateway >/dev/null 2>&1; then
    return 0
  fi

  if [[ -x "$E2E_BIN_DIR/ingress2gateway" ]]; then
    export PATH="$E2E_BIN_DIR:$PATH"
    return 0
  fi

  echo "ingress2gateway not found. Tip: run 'bash tests/run-e2e.sh' once to auto-download it into tests/.bin/." >&2
  echo "Or install ingress2gateway globally." >&2
  exit 1
}

main() {
  need_cmd kubectl
  need_cmd jq

  echo "Applying manifests..."
  # MANIFESTS_MOCK_CLUSTER may be a space-separated list of files; build -f flags accordingly.
  read -ra _mock_files <<< "$MANIFESTS_MOCK_CLUSTER"
  _apply_args=()
  for f in "${_mock_files[@]}"; do
    _apply_args+=(-f "$f")
  done
  kubectl apply "${_apply_args[@]}" -f "$MANIFESTS_TRIGGER"

  ensure_ingress2gateway

  echo "Building synthetic binding context..."
  local obj_file ctx_file
  obj_file=$(mktemp)
  ctx_file=$(mktemp)
  # Use immediate expansion so cleanup still works at EXIT even though locals go out of scope.
  trap "rm -f '$obj_file' '$ctx_file'" EXIT

  kubectl get configmap "$TRIGGER_CONFIGMAP" -n "$TRIGGER_NAMESPACE" -o json > "$obj_file"
  jq -n --slurpfile o "$obj_file" '[{type:"Event", object:$o[0]}]' > "$ctx_file"

  echo "CTX=$ctx_file"
  echo "Running migration hook..."
  PATH="$E2E_BIN_DIR:$PATH" BINDING_CONTEXT_PATH="$ctx_file" bash "$ROOT_DIR/scripts/migrate.sh"

  echo "Trigger status (.data):"
  kubectl get configmap "$TRIGGER_CONFIGMAP" -n "$TRIGGER_NAMESPACE" -o json \
    | jq -r '.data | {convertedResources, migratedEndpoints, applied, error, lastRun}'
}

main "$@"
