#!/usr/bin/env bash
# validate.sh
# Optional hook to perform validation steps locally on generated resources.

set -euo pipefail

# Shared libraries — bootstrapped via common.sh.
# shellcheck source=scripts/lib/common.sh
if [[ -f /usr/local/lib/hooks/common.sh ]]; then
  source /usr/local/lib/hooks/common.sh
else
  source "$(dirname "$0")/lib/common.sh"
fi
source_lib status.sh
source_lib history.sh
source_lib provider.sh
source_lib nginx_gotchas.sh

if [[ ${1:-} == "--config" ]] ; then
  cat <<EOF
configVersion: v1
kubernetes:
- name: ValidationTrigger
  apiVersion: v1
  kind: ConfigMap
  executeHookOnEvent:
  - Added
  - Modified
  labelSelector:
    matchLabels:
      ingress-migration.flant.com/validate: "true"
  jqFilter: '.metadata.annotations'
EOF
  exit 0
fi

CONTEXT_FILE="$BINDING_CONTEXT_PATH"
jq -c '.[]' "$CONTEXT_FILE" | while read -r event; do
  EVENT_TYPE=$(echo "$event" | jq -r '.type')
  if [[ "$EVENT_TYPE" == "Synchronization" ]] || [[ "$EVENT_TYPE" == "Event" ]]; then
     echo "Validating converted HTTPRoutes..."
     CM_NAME=$(echo "$event" | jq -r '.object.metadata.name // empty')
     CM_NAMESPACE=$(echo "$event" | jq -r '.object.metadata.namespace // empty')

     # Defensive: skip malformed payloads without a ConfigMap object.
     if [[ -z "$CM_NAME" || -z "$CM_NAMESPACE" ]]; then
       echo "Skipping event without ConfigMap object (type=$EVENT_TYPE)"
       continue
     fi

     PROVIDERS=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/providers"] // "ingress-nginx"')
     NS_SELECTOR=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/namespace-selector"] // ""')

     HISTORY_ENABLED=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/history-enabled"] // "true"')
     HISTORY_CM=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/history-configmap"] // "ingress-migration-history"')
     HISTORY_MAX=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/history-max-entries"] // "100"')
     INITIATOR=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/initiator"] // ""')
     _cluster_id_annotation=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/cluster-id"] // ""')
     CLUSTER_ID=$(resolve_cluster_id "$_cluster_id_annotation")
     
     NGINX_WARNINGS_COUNT="0"
     NGINX_WARNINGS_TEXT=""

     provider_flag=""
     if provider_flag=$(dispatch_provider "$PROVIDERS" 2>/dev/null); then
       if [[ "$provider_flag" == "ingress-nginx" ]]; then
         TARGET_NAMESPACES=""
         if [[ -n "$NS_SELECTOR" ]]; then
           TARGET_NAMESPACES=$(kubectl get ns -l "$NS_SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
         fi

         ingress_list=$(kubectl get ingress -A -o json 2>/dev/null || echo '{"items":[]}')
         namespaces_json=""
         if [[ -n "$TARGET_NAMESPACES" ]]; then
           namespaces_json=$(printf '%s' "$TARGET_NAMESPACES" | xargs -n1 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length>0))')
         fi

         warnings_json="[]"
         if warnings_json=$(NGINX_GOTCHAS_NAMESPACES_JSON="$namespaces_json" nginx_gotchas_warnings_from_ingress_list <<<"$ingress_list" 2>/dev/null); then
           true
         fi

         NGINX_WARNINGS_COUNT=$(jq -r 'length' <<<"$warnings_json" 2>/dev/null || echo "0")
         if [[ "$NGINX_WARNINGS_COUNT" != "0" ]]; then
           NGINX_WARNINGS_TEXT=$(jq -r '.[0:20][] | "[" + .code + "] " + .message + (if .host then " host=" + .host else "" end) + (if .ingress then " ingress=" + .ingress else "" end) + (if .path then " path=" + .path else "" end)' <<<"$warnings_json" 2>/dev/null || true)
         fi
       fi
     fi

     echo "Validation checks passed."
     
     # Patch status
     STATUS_PAYLOAD=$(jq -n \
       --arg validation "success" \
       --arg validatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg nginxWarningsCount "$NGINX_WARNINGS_COUNT" \
       --arg nginxWarnings "$NGINX_WARNINGS_TEXT" \
       '{data: {validation: $validation, validatedAt: $validatedAt, nginxPreflightWarningsCount: $nginxWarningsCount, nginxPreflightWarnings: $nginxWarnings}}')
     patch_status "$CM_NAME" "$CM_NAMESPACE" "$STATUS_PAYLOAD"

     if [[ "$HISTORY_ENABLED" == "true" ]]; then
       cluster_key=$(history_sanitize_key "$CLUSTER_ID")
       data_key="history.${cluster_key}.jsonl"
       entry=$(jq -n -c \
         --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg action "validate" \
         --arg clusterId "$CLUSTER_ID" \
         --arg initiator "$INITIATOR" \
         --arg triggerNs "$CM_NAMESPACE" \
         --arg triggerName "$CM_NAME" \
         --arg nginxWarningsCount "$NGINX_WARNINGS_COUNT" \
         --arg nginxWarnings "$NGINX_WARNINGS_TEXT" \
         '{ts:$ts, action:$action, clusterId:$clusterId, initiator:$initiator,
           trigger:{namespace:$triggerNs, name:$triggerName},
           result:{validation:"success", nginxPreflightWarningsCount:$nginxWarningsCount, nginxPreflightWarnings:$nginxWarnings}
         }')
       history_append_jsonl "$CM_NAMESPACE" "$HISTORY_CM" "$data_key" "$entry" "$HISTORY_MAX" || true
     fi
  fi
done
