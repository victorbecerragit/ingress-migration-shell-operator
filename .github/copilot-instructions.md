# Copilot Review Instructions

This is a shell-operator-based Kubernetes migration tool. Hook scripts run inside a container
with `bash`, `kubectl`, `jq`, and `ingress2gateway` available. No Go, no controllers — all
logic is plain Bash.

## Project layout

- `scripts/migrate.sh` — main migration hook (convert Ingress → HTTPRoute/Gateway, patch status, write report, append history)
- `scripts/rollback.sh` — rollback hook (delete applied HTTPRoutes)
- `scripts/validate.sh` — dry-run validation helper
- `scripts/lib/provider.sh` — provider dispatch (`ingress-nginx`, `apisix`, `kong`)
- `scripts/lib/status.sh` — `patch_status()` and `build_migration_report()`
- `scripts/lib/history.sh` — `history_put_jsonl()` append-only JSONL log
- `scripts/lib/nginx_gotchas.sh` — NGINX preflight warning scanner
- `tests/bats/` — BATS unit tests for lib functions
- `tests/run-e2e.sh` — E2E test against a real cluster or Kind

## Focus areas

- **Shell correctness**: always quote variables (`"$VAR"`), guard against empty strings, check
  exit codes explicitly where failures should be fatal
- **ARG_MAX safety**: never pass large strings as CLI arguments to `kubectl`; pipe JSON payloads
  via stdin (e.g. `echo "$json" | kubectl apply -f -`)
- **kubectl usage**: prefer `kubectl patch --type=merge` with stdin for status updates; avoid
  `kubectl annotate` for payloads that may exceed shell limits
- **jq pipelines**: access `.data` keys with `// ""` or `// null` fallbacks; validate that
  filters handle missing fields gracefully
- **Idempotency**: hook scripts must be safe to re-run; dry-run mode (`DRY_RUN=true`) must
  never apply or delete any cluster resources
- **BATS coverage**: new logic added to `scripts/lib/` should have a corresponding test case
  in `tests/bats/`; tests use `bats-core` and source lib files directly
- **Report readability**: `build_migration_report()` output is human-facing; prefer alignment
  and consistent indentation over terseness
