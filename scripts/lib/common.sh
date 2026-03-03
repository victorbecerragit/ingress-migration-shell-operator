#!/usr/bin/env bash
# lib/common.sh — shared bootstrap helpers for ingress-migration hooks
#
# Provides:
#   source_lib <name>        — source a lib file from the in-cluster mount or the
#                              local lib/ directory next to this file
#   resolve_cluster_id <v>   — resolve CLUSTER_ID with the canonical fallback chain
#
# Do NOT set shell options here; this file is sourced by hook scripts and must
# not mutate the caller's execution environment.

# Absolute path to the directory containing this file, resolved at source-time.
# source_lib uses this as the fallback when the in-cluster mount is absent.
_COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# source_lib <filename>
# Sources a lib script from /usr/local/lib/hooks/ (in-cluster ConfigMap mount)
# or from the same directory as common.sh (local / test environment).
source_lib() {
  local name="${1:?lib filename required}"
  if [[ -f "/usr/local/lib/hooks/${name}" ]]; then
    # shellcheck source=/dev/null
    source "/usr/local/lib/hooks/${name}"
  else
    # shellcheck source=/dev/null
    source "${_COMMON_LIB_DIR}/${name}"
  fi
}

# resolve_cluster_id <annotation_value>
# Prints the resolved cluster ID to stdout.
# Fallback chain (first non-empty wins):
#   1. annotation value passed as $1
#   2. CLUSTER_ID_ENV environment variable
#   3. KUBERNETES_SERVICE_HOST (in-cluster API server IP)
#   4. kubectl config current-context (local dev)
#   5. literal "unknown"
resolve_cluster_id() {
  local from_annotation="${1:-}"
  if [[ -n "$from_annotation" ]]; then
    printf '%s' "$from_annotation"
    return 0
  fi
  if [[ -n "${CLUSTER_ID_ENV:-}" ]]; then
    printf '%s' "$CLUSTER_ID_ENV"
    return 0
  fi
  if [[ -n "${KUBERNETES_SERVICE_HOST:-}" ]]; then
    printf '%s' "$KUBERNETES_SERVICE_HOST"
    return 0
  fi
  local ctx
  ctx=$(kubectl config current-context 2>/dev/null || true)
  if [[ -n "$ctx" ]]; then
    printf '%s' "$ctx"
    return 0
  fi
  printf 'unknown'
}
