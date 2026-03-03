#!/usr/bin/env bash
# lib/history.sh — append-only history buffer stored in a ConfigMap.
#
# Provides:
#   history_append_jsonl <ns> <cm_name> <data_key> <entry_json> <max_entries>
#
# This keeps a rolling buffer of the last N JSONL entries in a single
# ConfigMap data key. Intended for light-weight audit/history tracking.


# Important: this file is sourced by hook scripts.
# Do not set shell options here (e.g., `set -euo pipefail`) because that would
# mutate the caller's execution environment.

history_sanitize_key() {
  # ConfigMap data keys must consist of alphanumeric, '-', '_' or '.'.
  # Replace other chars with '_' and clamp length.
  local raw="${1:-unknown}"
  local sanitized
  sanitized=$(printf '%s' "$raw" | tr -cs 'A-Za-z0-9_.-' '_' | cut -c1-60)
  if [[ -z "$sanitized" ]]; then
    sanitized="unknown"
  fi
  printf '%s' "$sanitized"
}

history_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
    return 0
  fi
  # Hash tool not available; return empty hash.
  cat >/dev/null
  printf ''
}

history_get_jsonl() {
  local ns="${1:?namespace required}"
  local cm_name="${2:?configmap name required}"
  local data_key="${3:?data key required}"

  kubectl get configmap "$cm_name" -n "$ns" -o json 2>/dev/null \
    | jq -r --arg k "$data_key" '.data[$k] // ""' \
    || true
}

history_put_jsonl() {
  local ns="${1:?namespace required}"
  local cm_name="${2:?configmap name required}"
  local data_key="${3:?data key required}"
  local content="${4:-}"

  # Write content to a temp file and use --from-file so that large histories
  # do not hit the OS "Argument list too long" limit that --from-literal hits.
  local _tmp_dir _tmp_file
  _tmp_dir=$(mktemp -d)
  _tmp_file="$_tmp_dir/$data_key"
  printf '%s' "$content" > "$_tmp_file"

  kubectl create configmap "$cm_name" \
    -n "$ns" \
    --from-file="$data_key=$_tmp_file" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f - >/dev/null

  rm -rf "$_tmp_dir"
}

history_append_jsonl() {
  local ns="${1:?namespace required}"
  local cm_name="${2:?configmap name required}"
  local data_key="${3:?data key required}"
  local entry_json="${4:?entry json required}"
  local max_entries="${5:-100}"

  # Best-effort: history must never break the hook.
  if ! command -v kubectl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    return 0
  fi

  local existing combined trimmed
  existing=$(history_get_jsonl "$ns" "$cm_name" "$data_key")

  # Ensure JSONL: one entry per line.
  combined=$(printf '%s\n%s\n' "$existing" "$entry_json" | sed '/^\s*$/d')
  trimmed=$(printf '%s\n' "$combined" | tail -n "$max_entries")

  history_put_jsonl "$ns" "$cm_name" "$data_key" "$trimmed" || true
}
