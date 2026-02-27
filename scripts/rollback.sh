#!/usr/bin/env bash
# rollback.sh
# Hook to quickly delete HTTPRoutes if there's an issue with the migration

set -euo pipefail

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
     CM_NAME=$(echo "$event" | jq -r '.object.metadata.name')
     CM_NAMESPACE=$(echo "$event" | jq -r '.object.metadata.namespace')
     NS_SELECTOR=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/namespace-selector"] // ""')
     
     echo "Rolling back HTTPRoutes triggered by $CM_NAME..."
     
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
     kubectl patch configmap "$CM_NAME" -n "$CM_NAMESPACE" --type merge -p "{\"data\": {\"rollback\": \"completed\", \"rolledBackAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
  fi
done
