#!/usr/bin/env bash
# =============================================================================
#  demo/01-ingress.sh — Step 1: Deploy the app and verify NGINX Ingress works
#
#  Story: "We have a production app running behind NGINX Ingress.
#          This is the starting point — before Gateway API migration."
# =============================================================================
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ── Main ──────────────────────────────────────────────────────────────────────
section "Step 1 — Deploy the demo app with NGINX Ingress"

info "We have an echo app that returns request details."
info "It is exposed via a classic NGINX Ingress rule:"
echo ""
cat "$DEMO_DIR/manifests/ingress.yaml"
echo ""

wait_for_enter

# ── Deploy the application ────────────────────────────────────────────────────
section "Deploying: Namespace, Deployment, Service"

info "Namespace 'demo-prod' is labeled env=prod."
info "This label is how the migration operator selects which namespaces to migrate."
echo ""

cmd "kubectl apply -f $DEMO_DIR/manifests/app.yaml"
echo ""

info "Waiting for the app pod to be ready..."
cmd "kubectl rollout status deployment/demo-app -n demo-prod --timeout=90s"
success "App is running."

wait_for_enter

# ── Deploy the Ingress ────────────────────────────────────────────────────────
section "Deploying: NGINX Ingress"

cmd "kubectl apply -f $DEMO_DIR/manifests/ingress.yaml"
echo ""

info "Verifying the Ingress was accepted..."
cmd "kubectl get ingress demo-ingress -n demo-prod"

wait_for_enter

# ── Test via Ingress ──────────────────────────────────────────────────────────
section "Testing: curl via NGINX Ingress"

info "Getting the ingress-nginx controller LoadBalancer address..."
NGINX_IP=""
for i in $(seq 1 30); do
  NGINX_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -n "$NGINX_IP" ]; then break; fi
  echo -n "."
  sleep 2
done
echo ""

if [ -z "$NGINX_IP" ]; then
  warn "LoadBalancer IP not yet assigned. Try running again in a few seconds."
  warn "Or check: kubectl get svc -n ingress-nginx ingress-nginx-controller"
  exit 1
fi

success "NGINX LoadBalancer IP: ${NGINX_IP}"
echo ""

info "Sending a request via NGINX Ingress..."
info "  curl --resolve demo.prod.example:80:${NGINX_IP} http://demo.prod.example/"
echo ""

# Retry in case pods are still warming up
for attempt in 1 2 3; do
  if curl -sf --max-time 5 \
       --resolve "demo.prod.example:80:${NGINX_IP}" \
       http://demo.prod.example/ \
       | jq '{path, host, namespace, pod}' 2>/dev/null; then
    break
  fi
  if [ "$attempt" -eq 3 ]; then
    warn "Curl failed 3 times. The app may still be starting."
    warn "Try: curl --resolve demo.prod.example:80:${NGINX_IP} http://demo.prod.example/"
  fi
  sleep 3
done

echo ""
success "App is live via NGINX Ingress! ✓"
echo ""
echo -e "${BOLD}Current state:${RESET}"
echo -e "  ┌──────────────┐    Ingress/nginx    ┌─────────┐"
echo -e "  │  curl client │ ─────────────────▶ │ demo-app│"
echo -e "  └──────────────┘                     └─────────┘"
echo ""
echo -e "${BOLD}Next:${RESET} bash demo/02-dry-run.sh"
echo ""
