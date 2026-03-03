#!/usr/bin/env bats
# Tests for scripts/lib/status.sh — build_migration_report()

setup() {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$ROOT_DIR/scripts/lib/status.sh"
}

# ---------------------------------------------------------------------------
# Helper: minimal valid entry JSON (dryRun=true, no warnings, no namespaces)
# ---------------------------------------------------------------------------
_entry() {
  local overrides="${1:-}"
  jq -n --argjson ov "${overrides:-null}" '
    {
      ts:        "2024-01-01T00:00:00Z",
      action:    "migrate",
      clusterId: "ci-cluster",
      initiator: "ci",
      trigger:   {namespace: "demo", name: "trigger-test"},
      config: {
        providers:         "ingress-nginx",
        dryRun:            "true",
        namespaceSelector: "",
        migrateEndpoints:  "false",
        gatewayClass:      ""
      },
      before: {
        ingressCount:  "3",
        ingressSample: ["demo/ing-a", "demo/ing-b"]
      },
      after: {
        httpRoutes:                    "3",
        gateways:                      "1",
        endpointSlicesConverted:       "0",
        applied:                       "false",
        error:                         "",
        manifestHash:                  "abc123def456abcd",
        nginxPreflightWarningsCount:   "0",
        nginxPreflightWarnings:        ""
      },
      namespaces: []
    } | if $ov != null then . * $ov else . end
  '
}

# ---------------------------------------------------------------------------
# Basic rendering
# ---------------------------------------------------------------------------

@test "build_migration_report: outputs the report header" {
  run build_migration_report "$(_entry)"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "=== Ingress -> Gateway API Migration Report ==="
}

@test "build_migration_report: shows trigger name and namespace" {
  run build_migration_report "$(_entry)"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "demo/trigger-test"
}

@test "build_migration_report: shows DRY RUN when dryRun=true" {
  run build_migration_report "$(_entry)"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "DRY RUN"
}

@test "build_migration_report: shows LIVE RUN when dryRun=false" {
  run build_migration_report "$(_entry '{"config":{"dryRun":"false"}}')"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "LIVE RUN"
}

@test "build_migration_report: shows (all) when namespaces is empty" {
  run build_migration_report "$(_entry)"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "(all)"
}

@test "build_migration_report: lists specific namespaces when set" {
  run build_migration_report "$(_entry '{"namespaces":["prod","staging"]}')"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "prod"
  echo "$output" | grep -q "staging"
}

@test "build_migration_report: shows ingress sample entries" {
  run build_migration_report "$(_entry)"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "demo/ing-a"
}

# ---------------------------------------------------------------------------
# NGINX warnings section
# ---------------------------------------------------------------------------

@test "build_migration_report: no NGINX warnings section when count=0" {
  run build_migration_report "$(_entry)"
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "NGINX Preflight Warnings"
}

@test "build_migration_report: shows NGINX warnings section when count>0" {
  entry=$(_entry '{
    "after": {
      "nginxPreflightWarningsCount": "2",
      "nginxPreflightWarnings":      "[NGINX_REWRITE_TARGET_IMPLIES_REGEX] rewrite-target on demo/ing-a\n[NGINX_REGEX_HOST_WIDE] host-wide regex on demo/ing-b"
    }
  }')
  run build_migration_report "$entry"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "NGINX Preflight Warnings (2)"
  echo "$output" | grep -q "NGINX_REWRITE_TARGET_IMPLIES_REGEX"
}

@test "build_migration_report: truncates NGINX warnings beyond 10 with ellipsis" {
  # Build a warnings string with 12 actual newline-separated lines.
  local warnings
  warnings=$(for i in $(seq 1 12); do printf '[CODE_%d] warning %d\n' "$i" "$i"; done)
  # Remove trailing newline so jq --arg stores exactly 12 lines.
  warnings="${warnings%$'\n'}"

  entry=$(jq -n --arg w "$warnings" '
    {
      ts: "2024-01-01T00:00:00Z", action: "migrate", clusterId: "c", initiator: "ci",
      trigger: {namespace: "ns", name: "tr"},
      config: {providers: "ingress-nginx", dryRun: "true", namespaceSelector: "",
               migrateEndpoints: "false", gatewayClass: ""},
      before: {ingressCount: "1", ingressSample: []},
      after: {httpRoutes: "1", gateways: "1", endpointSlicesConverted: "0",
              applied: "false", error: "", manifestHash: "",
              nginxPreflightWarningsCount: "12",
              nginxPreflightWarnings: $w},
      namespaces: []
    }
  ')
  run build_migration_report "$entry"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "NGINX Preflight Warnings (12)"
  echo "$output" | grep -q "... and 2 more"
}
