#!/usr/bin/env bash
# tests/run-golden.sh
#
# Golden tests: pipe a stored IngressList JSON through nginx_gotchas scanner
# and compare the sorted output to expected-warnings.json.
#
# No cluster required — all tests run entirely in-process with jq + bash.
#
# Layout convention (one sub-test per fixture basename in testdata/):
#
#   testdata/<name>-input.json     IngressList JSON fed to the scanner on stdin
#   testdata/<name>-warnings.json  Expected JSON array (order-independent; sorted by .code)
#
# Add a new golden test by dropping two files matching the pattern above.
# The fixture YAML in testdata/<name>.yaml is the human-readable source of truth
# and documentation — the JSON files are the machine-checkable derivatives.
#
# Usage:
#   bash tests/run-golden.sh          # run all golden tests
#   GOLDEN_FILTER=regex bash tests/run-golden.sh  # run tests whose name contains "regex"

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# ── dependencies ──────────────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required for golden tests" >&2
  exit 1
fi

# ── source scanner ────────────────────────────────────────────────────────────
# shellcheck source=../scripts/lib/nginx_gotchas.sh
source "$ROOT_DIR/scripts/lib/nginx_gotchas.sh"

GOLDEN_FILTER=${GOLDEN_FILTER:-}

PASS=0
FAIL=0
SKIP=0

# ── helper ────────────────────────────────────────────────────────────────────
run_golden_test() {
  local name="$1"
  local input_file="$ROOT_DIR/testdata/${name}-input.json"
  local expected_file="$ROOT_DIR/testdata/${name}-warnings.json"

  if [[ -n "$GOLDEN_FILTER" ]] && [[ "$name" != *"$GOLDEN_FILTER"* ]]; then
    return
  fi

  if [[ ! -f "$input_file" ]]; then
    echo "SKIP  $name  (missing ${name}-input.json)"
    SKIP=$((SKIP + 1))
    return
  fi
  if [[ ! -f "$expected_file" ]]; then
    echo "SKIP  $name  (missing ${name}-warnings.json)"
    SKIP=$((SKIP + 1))
    return
  fi

  # Run scanner; sort output by .code for stable comparison.
  local actual
  actual=$(nginx_gotchas_warnings_from_ingress_list < "$input_file" | jq 'sort_by(.code)')

  local expected
  expected=$(jq 'sort_by(.code)' "$expected_file")

  if [[ "$actual" == "$expected" ]]; then
    echo "PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $name"
    # Show a side-by-side diff when diff is available; fall back to inline print.
    if command -v diff >/dev/null 2>&1; then
      diff <(echo "$expected") <(echo "$actual") \
        --label "expected (${name}-warnings.json)" \
        --label "actual   (scanner output)" \
        --unified 4 || true
    else
      echo "  ── expected ──────────────────────────────────────────────────"
      echo "$expected" | sed 's/^/  /'
      echo "  ── actual ────────────────────────────────────────────────────"
      echo "$actual" | sed 's/^/  /'
    fi
    FAIL=$((FAIL + 1))
  fi
}

# ── discover and run all fixtures ─────────────────────────────────────────────
# Iterate over *-input.json files; strip the suffix to get the fixture name.
any=0
for input_file in "$ROOT_DIR/testdata/"*-input.json; do
  [[ -f "$input_file" ]] || continue
  any=1
  fixture_name=$(basename "$input_file" -input.json)
  run_golden_test "$fixture_name"
done

if [[ "$any" -eq 0 ]]; then
  echo "No golden test fixtures found in testdata/" >&2
  exit 0
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Golden tests: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"

[[ "$FAIL" -eq 0 ]]
