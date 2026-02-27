#!/usr/bin/env bash
# rollback.sh
# Hook to quickly delete HTTPRoutes if there's an issue with the migration

set -euo pipefail

# Shared status-patch library (mounted from ConfigMap at runtime via /hooks/).
# shellcheck source=/dev/null
source /hooks/status.sh

if [[ ${1:-} == "--config" ]] ; then
  cat <<EOF
configVersion: v1
kubernetes:
- name: RollbackTrigger
  apiVersion: v1
  kind: ConfigMap
  executeHookOnEvent:
  - Added
  - Modified
  labelSelector:
    matchLabels:
      ingress-migration.flant.com/rollback: "true"
EOF
  exit 0
fi

CONTEXT_FILE="$BINDING_CONTEXT_PATH"
jq -c '.[]' "$CONTEXT_FILE" | while read -r event; do
  EVENT_TYPE=$(echo "$event" | jq -r '.type')
  if [[ "$EVENT_TYPE" == "Synchronization" ]] || [[ "$EVENT_TYPE" == "Event" ]]; then
     CM_NAME=$(echo "$event" | jq -r '.object.metadata.name // empty')
     CM_NAMESPACE=$(echo "$event" | jq -r '.object.metadata.namespace // empty')

     # Defensive: skip malformed payloads without a ConfigMap object.
     if [[ -z "$CM_NAME" || -z "$CM_NAMESPACE" ]]; then
       echo "Skipping event without ConfigMap object (type=$EVENT_TYPE)"
       continue
     fi
     NS_SELECTOR=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/namespace-selector"] // ""')
     
    echo "Rolling back HTTPRoutes triggered by $CM_NAME/$CM_NAMESPACE..."
     
     if [ -n "$NS_SELECTOR" ]; then
         ROUTES=$(kubectl get httproute -l "$NS_SELECTOR" -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' || true)
     else
         ROUTES=$(kubectl get httproute -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' || true)
     fi
     
     for route in $ROUTES; do
         ns=$(echo "$route" | cut -d'/' -f1)
         name=$(echo "$route" | cut -d'/' -f2)
         if [ -n "$ns" ] && [ -n "$name" ]; then
            echo "Deleting HTTPRoute: $ns/$name"
            kubectl delete httproute "$name" -n "$ns" --ignore-not-found=true
         fi
     done
     
     echo "Rollback completed."
     patch_status "$CM_NAME" "$CM_NAMESPACE" \
       "{\"data\": {\"rollback\": \"completed\", \"rolledBackAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
  fi
done
