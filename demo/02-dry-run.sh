#!/usr/bin/env bash
# =============================================================================
#  demo/02-dry-run.sh — Step 2: Run the migration operator in dry-run mode
#
#  Story: "The migration operator watches for a special ConfigMap trigger.
#          In dry-run mode it converts the Ingress to Gateway API objects
#          and shows us what WOULD be created — without touching the cluster."
# =============================================================================
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$DEMO_DIR")"
BIN_DIR="$DEMO_DIR/.bin"

# ── Colours & helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}▸ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }
section() { echo -e "\n${BOLD}══════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}  $*${RESET}"; \
            echo -e "${BOLD}══════════════════════════════════════${RESET}\n"; }
cmd()     { echo -e "${YELLOW}$ $*${RESET}"; eval "$*"; }

wait_for_enter() {
  echo ""
  echo -e "${YELLOW}━━━━━  Press ENTER to continue  ━━━━━${RESET}"
  read -r
}

# ── Sanity check ──────────────────────────────────────────────────────────────
if [ ! -x "$BIN_DIR/ingress2gateway" ]; then
  die "ingress2gateway not found in $BIN_DIR. Did you run bash demo/setup.sh?"
fi

# ── Step 2a: Show & apply the trigger ConfigMap ───────────────────────────────
section "Step 2 — The migration trigger ConfigMap"

info "The shell-operator watches ConfigMaps with this label:"
info "  ingress-migration.flant.com/trigger: \"true\""
echo ""
info "This ConfigMap tells the operator:"
echo -e "  providers:          ingress-nginx"
echo -e "  dry-run:            ${BOLD}true${RESET}         ← inspect before applying"
echo -e "  namespace-selector: env=prod    ← only migrate namespaces with this label"
echo ""
cat "$DEMO_DIR/manifests/trigger.yaml"
echo ""

wait_for_enter

info "Applying the trigger ConfigMap..."
cmd "kubectl apply -f $DEMO_DIR/manifests/trigger.yaml"
echo ""
success "Trigger ConfigMap created in demo-prod."

wait_for_enter

# ── Step 2b: Simulate the shell-operator hook ─────────────────────────────────
section "Running the migration hook (dry-run)"

info "In production the shell-operator runs the hook automatically."
info "For this demo we simulate it with the same script the operator uses:"
echo ""

MANIFESTS_MOCK_CLUSTER="$DEMO_DIR/manifests/app.yaml $DEMO_DIR/manifests/ingress.yaml" \
  MANIFESTS_TRIGGER="$DEMO_DIR/manifests/trigger.yaml" \
  TRIGGER_NAMESPACE="demo-prod" \
  TRIGGER_CONFIGMAP="migrate-ingress-demo" \
  E2E_BIN_DIR="$BIN_DIR" \
  bash "$REPO_DIR/tests/run-manual.sh"

wait_for_enter

# ── Step 2c: Inspect the ConfigMap status ────────────────────────────────────
section "Migration status written back to ConfigMap"

info "The operator patches the trigger ConfigMap with the result:"
cmd "kubectl get configmap migrate-ingress-demo -n demo-prod -o json | jq '.data'"
echo ""
success "convertedResources=1  |  applied=false (dry-run)  |  error=none"

wait_for_enter

# ── Step 2d: Show the raw ingress2gateway output ──────────────────────────────
section "Full ingress2gateway output — what will be created"

info "Let's look at the complete YAML that will be applied:"
echo ""

PATH="$BIN_DIR:$PATH" ingress2gateway print \
  --providers=ingress-nginx \
  --namespace=demo-prod

echo ""
warn "Notice:  gatewayClassName: nginx"
warn "This must match your cluster's actual GatewayClass."
warn "In our Kind cluster it is: cloud-provider-kind"
echo ""
info "In step 3 we will patch this and apply."

wait_for_enter

echo ""
echo -e "${BOLD}Current state:${RESET}"
echo -e "  ┌──────────────┐    Ingress/nginx    ┌─────────┐"
echo -e "  │  curl client │ ─────────────────▶ │ demo-app│"
echo -e "  └──────────────┘                     └─────────┘"
echo -e "                                            ${YELLOW}↑${RESET}"
echo -e "                                    ${YELLOW}migration planned (not applied yet)${RESET}"
echo ""
echo -e "${BOLD}Next:${RESET} bash demo/03-apply.sh"
echo ""
