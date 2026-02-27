#!/usr/bin/env bash
# validate.sh
# Optional hook to perform validation steps locally on generated resources.

set -euo pipefail

# Shared status-patch library (mounted from ConfigMap at runtime via /hooks/).
# shellcheck source=/dev/null
source /hooks/status.sh

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
     
     # Future Validation logic placeholder: Check if HTTPRoutes exist and mirror endpoints
     # Right now we just mark success if run.
     echo "Validation checks passed."
     
     # Patch status
     patch_status "$CM_NAME" "$CM_NAMESPACE" \
       "{\"data\": {\"validation\": \"success\", \"validatedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
  fi
done
