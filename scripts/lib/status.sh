#!/usr/bin/env bash
# lib/status.sh — shared status-patching helper for ingress-migration hooks
#
# Provides: patch_status <cm_name> <cm_namespace> <json_payload>
#
# Retries up to 3 times with exponential back-off (2 s, 4 s) before giving
# up. On final failure it prints a warning to stderr and returns 0 so the
# calling hook can still report a clean exit rather than crashing the
# shell-operator process.
#
# Usage:
#   source /hooks/status.sh        # runtime (ConfigMap mounted to /hooks/)
#   source "$(dirname "$0")/lib/status.sh"  # local / test environment
#
# Dependencies: kubectl (must be on PATH)

patch_status() {
  local cm_name="${1:?cm_name required}"
  local cm_ns="${2:?cm_namespace required}"
  local payload="${3:?json payload required}"
  local attempt

  for attempt in 1 2 3; do
    if kubectl patch configmap "$cm_name" \
         -n "$cm_ns" \
         --type merge \
         -p "$payload" \
         2>/dev/null; then
      return 0
    fi
    if [[ $attempt -lt 3 ]]; then
      local backoff=$(( attempt * 2 ))
      echo "WARNING: patch_status attempt ${attempt} failed for ${cm_ns}/${cm_name} — retrying in ${backoff}s" >&2
      sleep "$backoff"
    fi
  done

  echo "WARNING: patch_status gave up after 3 attempts for ${cm_ns}/${cm_name}" >&2
  # Return 0: a status-patch failure should not abort the migration itself.
  return 0
}
