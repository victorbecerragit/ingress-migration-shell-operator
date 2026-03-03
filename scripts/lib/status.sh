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

# --------------------------------------------------------------------------
# build_migration_report <entry_json>
#
# Renders a human-readable before/after migration report from the structured
# event JSON produced by migrate.sh.  Prints the formatted text to stdout.
#
# The caller stores the output as the `report` key in the trigger ConfigMap
# so operators can read it with:
#   kubectl get cm <trigger-name> -o jsonpath='{.data.report}'
# or view it as a single block with:
#   kubectl get cm <trigger-name> -o go-template='{{index .data "report"}}'
# --------------------------------------------------------------------------
build_migration_report() {
    local entry_json="${1:?entry_json required}"

    if ! command -v jq >/dev/null 2>&1; then
        echo "(report unavailable: jq not found)"
        return 0
    fi

    jq -r '
        def yn: if . == "true" then "yes" else "no" end;
        def na: if (. // "") == "" then "(none)" else . end;

        "=== Ingress -> Gateway API Migration Report ===",
        "",
        "  Timestamp : " + .ts,
        "  Trigger   : " + .trigger.namespace + "/" + .trigger.name,
        "  Mode      : " + (if .config.dryRun == "false" then "LIVE RUN" else "DRY RUN  (no resources changed)" end),
        "  Initiator : " + (.initiator | na),
        "",
        "--- Configuration ---",
        "  Provider      : " + .config.providers,
        "  NS Selector   : " + (.config.namespaceSelector | na),
        "  Gateway Class : " + (if (.config.gatewayClass // "") == "" then "(default)" else .config.gatewayClass end),
        "  Endpoints     : " + (if .config.migrateEndpoints == "true" then "enabled" else "disabled" end),
        "",
        "--- Before ---",
        "  Ingresses : " + .before.ingressCount,
        (if (.before.ingressSample | length) > 0 then
            (.before.ingressSample[] | "    " + .)
        else empty end),
        "",
        "--- After ---",
        "  HTTPRoutes     : " + .after.httpRoutes,
        "  Gateways       : " + .after.gateways,
        "  EndpointSlices : " + .after.endpointSlicesConverted,
        "  Applied        : " + (.after.applied | yn),
        "  Error          : " + .after.error,
        (if (.after.manifestHash // "") != "" then
            "  Manifest SHA   : " + .after.manifestHash[:16] + "..."
        else empty end),
        (if ((.after.nginxPreflightWarningsCount // "0") | tonumber) > 0 then
            "",
            "--- NGINX Preflight Warnings (" + .after.nginxPreflightWarningsCount + ") ---",
            ((.after.nginxPreflightWarnings
                | split("\n")
                | map(select(length > 0))) as $w |
                ($w[0:10][] | "  " + .),
                if ($w | length) > 10 then
                    "  ... and " + (($w | length) - 10 | tostring) + " more"
                else empty end)
        else empty end),
        "",
        "--- Namespaces ---",
        (if (.namespaces | length) > 0 then
            (.namespaces[] | "  " + .)
        else
            "  (all)"
        end)
    ' <<< "$entry_json"
}
