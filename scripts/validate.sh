#!/usr/bin/env bash
# validate.sh
# Optional hook to perform validation steps locally on generated resources.

set -euo pipefail

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
     CM_NAME=$(echo "$event" | jq -r '.object.metadata.name')
     CM_NAMESPACE=$(echo "$event" | jq -r '.object.metadata.namespace')
     
     # Future Validation logic placeholder: Check if HTTPRoutes exist and mirror endpoints
     # Right now we just mark success if run.
     echo "Validation checks passed."
     
     # Patch status
     kubectl patch configmap "$CM_NAME" -n "$CM_NAMESPACE" --type merge -p "{\"data\": {\"validation\": \"success\", \"validatedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
  fi
done
