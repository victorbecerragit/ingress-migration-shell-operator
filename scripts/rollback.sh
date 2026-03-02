#!/usr/bin/env bash
# rollback.sh
# Hook to quickly delete HTTPRoutes if there's an issue with the migration

set -euo pipefail

# Shared libraries.
# shellcheck source=/dev/null
if [[ -f /hooks/status.sh ]]; then
  source /hooks/status.sh
else
  source "$(dirname "$0")/lib/status.sh"
fi

# shellcheck source=/dev/null
if [[ -f /hooks/history.sh ]]; then
  source /hooks/history.sh
else
  source "$(dirname "$0")/lib/history.sh"
fi

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

     HISTORY_ENABLED=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/history-enabled"] // "true"')
     HISTORY_CM=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/history-configmap"] // "ingress-migration-history"')
     HISTORY_MAX=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/history-max-entries"] // "100"')
     INITIATOR=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/initiator"] // ""')
     CLUSTER_ID=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/cluster-id"] // ""')
     if [[ -z "$CLUSTER_ID" ]]; then
       CLUSTER_ID="${KUBERNETES_SERVICE_HOST:-}"
     fi
     if [[ -z "$CLUSTER_ID" ]]; then
       CLUSTER_ID=$(kubectl config current-context 2>/dev/null || true)
     fi
     if [[ -z "$CLUSTER_ID" ]]; then
       CLUSTER_ID="unknown"
     fi
     
    echo "Rolling back HTTPRoutes triggered by $CM_NAME/$CM_NAMESPACE..."
     
    if [ -n "$NS_SELECTOR" ]; then
        	NAMESPACES=$(kubectl get namespace -l "$NS_SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' || true)
        	ROUTES=""
        	for ns in $NAMESPACES; do
            	if [ -z "$ns" ]; then
              	continue
            	fi
            	ROUTES+=$(kubectl get httproute -n "$ns" -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
        	done
    else
        	ROUTES=$(kubectl get httproute -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' || true)
    fi
     
     DELETED_COUNT=0
     for route in $ROUTES; do
         ns=$(echo "$route" | cut -d'/' -f1)
         name=$(echo "$route" | cut -d'/' -f2)
         if [ -n "$ns" ] && [ -n "$name" ]; then
            echo "Deleting HTTPRoute: $ns/$name"
            kubectl delete httproute "$name" -n "$ns" --ignore-not-found=true
        DELETED_COUNT=$((DELETED_COUNT + 1))
         fi
     done
     
     echo "Rollback completed."
     patch_status "$CM_NAME" "$CM_NAMESPACE" \
       "{\"data\": {\"rollback\": \"completed\", \"rolledBackAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"

     if [[ "$HISTORY_ENABLED" == "true" ]]; then
       cluster_key=$(history_sanitize_key "$CLUSTER_ID")
       data_key="history.${cluster_key}.jsonl"
       entry=$(jq -n -c \
         --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg action "rollback" \
         --arg clusterId "$CLUSTER_ID" \
         --arg initiator "$INITIATOR" \
         --arg triggerNs "$CM_NAMESPACE" \
         --arg triggerName "$CM_NAME" \
         --arg nsSelector "$NS_SELECTOR" \
         --arg deleted "$DELETED_COUNT" \
         '{ts:$ts, action:$action, clusterId:$clusterId, initiator:$initiator,
           trigger:{namespace:$triggerNs, name:$triggerName},
           config:{namespaceSelector:$nsSelector},
           result:{deletedHttpRoutes:$deleted}
         }')
       history_append_jsonl "$CM_NAMESPACE" "$HISTORY_CM" "$data_key" "$entry" "$HISTORY_MAX" || true
     fi
  fi
done
