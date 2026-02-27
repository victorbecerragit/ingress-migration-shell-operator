#!/usr/bin/env bash
# =============================================================================
#  demo/teardown.sh — Full cleanup after the demo
# =============================================================================
set -euo pipefail

CLUSTER_NAME="${KIND_CLUSTER_NAME:-ingress-migration-demo}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}▸ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
section() { echo -e "\n${BOLD}══════════════════════════════════${RESET}"; \
            echo -e "${BOLD}  $*${RESET}"; \
            echo -e "${BOLD}══════════════════════════════════${RESET}\n"; }

section "Demo Teardown"

# 1. Delete the Kind cluster
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  info "Deleting Kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "$CLUSTER_NAME"
  success "Kind cluster deleted."
else
  warn "Kind cluster '${CLUSTER_NAME}' not found — already deleted?"
fi

# 2. Stop cloud-provider-kind
if docker ps --filter "name=^cloud-provider-kind$" --format '{{.Names}}' | grep -q "cloud-provider-kind"; then
  info "Stopping cloud-provider-kind container..."
  docker stop cloud-provider-kind
  success "cloud-provider-kind stopped (auto-removed due to --rm flag)."
else
  warn "cloud-provider-kind container not found — already stopped?"
fi

section "Teardown complete"
success "All demo resources have been removed."
