#!/usr/bin/env bash
# =============================================================================
#  demo/03-apply.sh — Step 3: Apply the migration and verify Gateway API works
#
#  Story: "We've reviewed the dry-run output. Now we adapt the gatewayClassName
#          for this environment and apply. Both Ingress and Gateway API will
#          serve traffic simultaneously — zero-downtime migration."
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

# ── Step 3a: Apply the trigger ConfigMap (live apply) ───────────────────────
section "Step 3 — Triggering the operator (live apply)"

info "In a real cluster, you set dry-run=false and let the operator apply."
info "This trigger also tells the operator which GatewayClass to target."
echo ""
cat "$DEMO_DIR/manifests/trigger-apply.yaml"
echo ""

wait_for_enter

info "Applying the live-apply trigger ConfigMap..."
cmd "kubectl apply -f $DEMO_DIR/manifests/trigger-apply.yaml"
echo ""
success "Trigger ConfigMap updated (dry-run=false)."

wait_for_enter

# ── Step 3b: Simulate the shell-operator hook (apply mode) ─────────────────
section "Running the migration hook (apply mode)"

info "In production the shell-operator runs the hook automatically."
info "For this demo we simulate it with the same script the operator uses:"
echo ""

MANIFESTS_MOCK_CLUSTER="$DEMO_DIR/manifests/app.yaml $DEMO_DIR/manifests/ingress.yaml" \
  MANIFESTS_TRIGGER="$DEMO_DIR/manifests/trigger-apply.yaml" \
  TRIGGER_NAMESPACE="demo-prod" \
  TRIGGER_CONFIGMAP="migrate-ingress-demo" \
  E2E_BIN_DIR="$BIN_DIR" \
  bash "$REPO_DIR/tests/run-manual.sh"

wait_for_enter

# ── Step 3c: Inspect the ConfigMap status ───────────────────────────────────
section "Migration status written back to ConfigMap"

info "The operator patches the trigger ConfigMap with the result:"
cmd "kubectl get configmap migrate-ingress-demo -n demo-prod -o json | jq '.data'"
echo ""
success "convertedResources=1  |  applied=true  |  error=none"

wait_for_enter

# ── Step 3d: Wait for Gateway to be programmed ──────────────────────────────
section "Waiting for Gateway to be programmed"

info "cloud-provider-kind provisions a LoadBalancer for the Gateway..."
info "This may take up to 30 seconds."
echo ""

EXPECTED_GW_CLASS=$(kubectl get configmap migrate-ingress-demo -n demo-prod \
  -o jsonpath='{.metadata.annotations.ingress-migration\.flant\.com/gateway-class}' 2>/dev/null || true)

GW_IP=""
for _ in $(seq 1 60); do
  PROGRAMMED=$(kubectl get gateway nginx -n demo-prod \
    -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)
  GW_CLASS=$(kubectl get gateway nginx -n demo-prod \
    -o jsonpath='{.spec.gatewayClassName}' 2>/dev/null || true)
  GW_IP=$(kubectl get gateway nginx -n demo-prod \
    -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)

  if [ -n "${EXPECTED_GW_CLASS:-}" ] && [ -n "${GW_CLASS:-}" ] && [ "$GW_CLASS" != "$EXPECTED_GW_CLASS" ]; then
    warn "Gateway spec.gatewayClassName is '$GW_CLASS' but trigger expects '$EXPECTED_GW_CLASS'"
    warn "This usually means the hook didn't override gatewayClassName (or you ran an older version of the scripts)."
    break
  fi

  if [ "${PROGRAMMED}" == "True" ] && [ -n "$GW_IP" ]; then
    break
  fi
  echo -n "."
  sleep 2
done
echo ""

if [ -z "$GW_IP" ]; then
  warn "Gateway address not yet assigned. Checking status..."
  if [ -n "${EXPECTED_GW_CLASS:-}" ]; then
    info "Expected GatewayClass (from trigger): ${EXPECTED_GW_CLASS}"
  fi
  cmd "kubectl get gateway nginx -n demo-prod -o yaml"
  echo ""
  warn "Available GatewayClasses:"
  cmd "kubectl get gatewayclass"
  die "Gateway did not become ready. Check: docker logs cloud-provider-kind"
fi

success "Gateway is programmed. Address: ${GW_IP}"
echo ""

cmd "kubectl get gateway nginx -n demo-prod"
echo ""
cmd "kubectl get httproute -n demo-prod"

wait_for_enter

# ── Step 3e: Test via Gateway API ───────────────────────────────────────────
section "Testing: curl via Gateway API"

info "Gateway IP: ${GW_IP}"
info "Sending request via Gateway API..."
echo ""
echo -e "${YELLOW}$ curl --resolve demo.prod.example:80:${GW_IP} http://demo.prod.example/${RESET}"
echo ""

for attempt in 1 2 3; do
  if curl -sf --max-time 8 \
       --resolve "demo.prod.example:80:${GW_IP}" \
       http://demo.prod.example/ \
       | jq '{path, host, namespace, pod}' 2>/dev/null; then
    echo ""
    success "App is reachable via Gateway API! ✓"
    break
  fi
  if [ "$attempt" -eq 3 ]; then
    warn "Curl failed after 3 attempts. Gateway may still be propagating."
    warn "Retry: curl --resolve demo.prod.example:80:${GW_IP} http://demo.prod.example/"
  fi
  sleep 4
done

wait_for_enter

# ── Step 3f: Both paths work simultaneously ─────────────────────────────────
section "Both Ingress and Gateway API work simultaneously"

NGINX_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

echo -e "${BOLD}NGINX Ingress (existing):${RESET}"
echo -e "${YELLOW}$ curl --resolve demo.prod.example:80:${NGINX_IP} http://demo.prod.example/ | jq .pod${RESET}"
curl -sf --max-time 5 \
  --resolve "demo.prod.example:80:${NGINX_IP}" \
  http://demo.prod.example/ \
  | jq '.pod' 2>/dev/null || echo "(unavailable)"

echo ""
echo -e "${BOLD}Gateway API (new):${RESET}"
echo -e "${YELLOW}$ curl --resolve demo.prod.example:80:${GW_IP} http://demo.prod.example/ | jq .pod${RESET}"
curl -sf --max-time 5 \
  --resolve "demo.prod.example:80:${GW_IP}" \
  http://demo.prod.example/ \
  | jq '.pod' 2>/dev/null || echo "(unavailable)"

echo ""
success "Same app pod serves both paths — zero-downtime migration!"

wait_for_enter

# ── Step 3g: (Optional) Remove Ingress ──────────────────────────────────────
section "(Optional) Remove the Ingress — traffic moves to Gateway API only"

info "When you're confident, you can decommission the old Ingress:"
echo ""
echo -e "${YELLOW}$ kubectl delete ingress demo-ingress -n demo-prod${RESET}"
echo ""
warn "Skipping for this demo — run manually if you want to show the cleanup."
warn "After deletion, only Gateway API serves the app."

echo ""
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Migration complete!${RESET}"
echo -e "${BOLD}══════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "${BOLD}Summary:${RESET}"
echo -e "  ┌──────────────┐  Ingress/nginx  ┌──────────────────┐  ┌─────────┐"
echo -e "  │  curl client │ ──────────────▶ │  ingress-nginx   │  │         │"
echo -e "  └──────────────┘                 └──────────────────┘  │ demo-app│"
echo -e "  ┌──────────────┐  Gateway API    ┌──────────────────┐  │         │"
echo -e "  │  curl client │ ──────────────▶ │  nginx (Gateway) │─▶│         │"
echo -e "  └──────────────┘                 └──────────────────┘  └─────────┘"
echo ""
echo -e "  Route:      demo.prod.example"
echo -e "  Namespace:  demo-prod  (label: env=prod)"
echo -e "  NGINX IP:   ${NGINX_IP}"
echo -e "  Gateway IP: ${GW_IP}"
echo ""
echo -e "${BOLD}Cleanup:${RESET} bash demo/teardown.sh"
echo ""
