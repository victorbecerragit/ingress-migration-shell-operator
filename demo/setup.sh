#!/usr/bin/env bash
# =============================================================================
#  demo/setup.sh — One-time cluster setup for the ingress→Gateway API demo
#
#  What this does:
#    1. Creates a named Kind cluster ("ingress-migration-demo")
#    2. Starts cloud-provider-kind (Docker) — installs Gateway API CRDs +
#       GatewayClass "cloud-provider-kind" + LoadBalancer support
#    3. Installs the ingress-nginx controller (so our Ingress works)
#    4. Downloads the ingress2gateway binary to demo/.bin/
#
#  Run once, then use the step scripts (01-*, 02-*, 03-*) for the live demo.
#
#  Reference: https://kubernetes.io/blog/2026/01/28/experimenting-gateway-api-with-kind/
# =============================================================================
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$DEMO_DIR")"
BIN_DIR="$DEMO_DIR/.bin"
CLUSTER_NAME="${KIND_CLUSTER_NAME:-ingress-migration-demo}"
INGRESS2GW_VERSION="${INGRESS2GW_VERSION:-v0.5.0}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}▸ $*${RESET}"; }
success() { echo -e "${GREEN}✓ $*${RESET}"; }
warn()    { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()     { echo -e "${RED}✗ $*${RESET}" >&2; exit 1; }
section() { echo -e "\n${BOLD}══════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}  $*${RESET}"; \
            echo -e "${BOLD}══════════════════════════════════════════${RESET}\n"; }

# ── Prerequisite check ────────────────────────────────────────────────────────
section "Checking prerequisites"
for cmd in docker kind kubectl curl jq; do
  if command -v "$cmd" >/dev/null 2>&1; then
    success "$cmd found ($(command -v "$cmd"))"
  else
    die "$cmd is required but not found. Please install it before running this script."
  fi
done

# ── Step 1: Kind cluster ──────────────────────────────────────────────────────
section "Step 1/4 — Creating Kind cluster"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Kind cluster '${CLUSTER_NAME}' already exists — skipping creation."
  warn "To recreate: kind delete cluster --name ${CLUSTER_NAME}"
else
  info "Creating Kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --name "$CLUSTER_NAME"
  success "Kind cluster created."
fi

# Make sure kubectl points at our new cluster
kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
success "kubectl context: kind-${CLUSTER_NAME}"

# ── Step 2: cloud-provider-kind ───────────────────────────────────────────────
section "Step 2/4 — Starting cloud-provider-kind"
info "cloud-provider-kind provides:"
info "  • LoadBalancer address assignment for Services"
info "  • Gateway API CRD installation"
info "  • GatewayClass 'cloud-provider-kind'"

if docker ps --filter "name=^cloud-provider-kind$" --format '{{.Names}}' | grep -q "cloud-provider-kind"; then
  warn "cloud-provider-kind container already running — skipping."
else
  info "Fetching latest cloud-provider-kind version..."
  CPK_VERSION="$(basename "$(curl -s -L -o /dev/null -w '%{url_effective}' \
    https://github.com/kubernetes-sigs/cloud-provider-kind/releases/latest)")"
  info "Version: ${CPK_VERSION}"

  info "Starting cloud-provider-kind container..."
  docker run -d \
    --name cloud-provider-kind \
    --rm \
    --network host \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "registry.k8s.io/cloud-provider-kind/cloud-controller-manager:${CPK_VERSION}"
  success "cloud-provider-kind started."
fi

info "Waiting for Gateway API CRDs to be installed by cloud-provider-kind..."
for i in $(seq 1 30); do
  if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
    success "Gateway API CRDs are ready."
    break
  fi
  if [ "$i" -eq 30 ]; then
    die "Timed out waiting for Gateway API CRDs. Check: docker logs cloud-provider-kind"
  fi
  echo -n "."
  sleep 3
done

info "Waiting for GatewayClass 'cloud-provider-kind' to appear..."
for i in $(seq 1 20); do
  if kubectl get gatewayclass cloud-provider-kind >/dev/null 2>&1; then
    success "GatewayClass 'cloud-provider-kind' is available."
    break
  fi
  if [ "$i" -eq 20 ]; then
    die "Timed out waiting for GatewayClass. Check: docker logs cloud-provider-kind"
  fi
  echo -n "."
  sleep 3
done

echo ""

# ── Step 3: ingress-nginx ─────────────────────────────────────────────────────
section "Step 3/4 — Installing ingress-nginx"
info "Deploying ingress-nginx controller (Kind-specific manifest)..."

kubectl apply -f \
  https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

info "Waiting for ingress-nginx controller to be ready (up to 120s)..."
kubectl wait \
  --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

NGINX_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
success "ingress-nginx controller is ready. LoadBalancer IP: ${NGINX_IP}"

# ── Step 4: ingress2gateway binary ────────────────────────────────────────────
section "Step 4/4 — Ensuring ingress2gateway binary"

# Check if already available from the main test suite download
if [ -x "${REPO_DIR}/tests/.bin/ingress2gateway" ]; then
  mkdir -p "$BIN_DIR"
  ln -sf "${REPO_DIR}/tests/.bin/ingress2gateway" "$BIN_DIR/ingress2gateway"
  success "Linked ingress2gateway from tests/.bin → demo/.bin"
elif [ -x "${BIN_DIR}/ingress2gateway" ]; then
  success "ingress2gateway already exists in demo/.bin — skipping download."
else
  mkdir -p "$BIN_DIR"
  ARCHIVE="ingress2gateway_Linux_x86_64.tar.gz"
  URL="https://github.com/kubernetes-sigs/ingress2gateway/releases/download/${INGRESS2GW_VERSION}/${ARCHIVE}"
  info "Downloading ingress2gateway ${INGRESS2GW_VERSION}..."
  curl -fsSL "$URL" | tar -xz -C "$BIN_DIR" ingress2gateway
  chmod +x "$BIN_DIR/ingress2gateway"
  success "ingress2gateway ${INGRESS2GW_VERSION} installed to demo/.bin/"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Setup Complete"
echo -e "${GREEN}${BOLD}Your Kind demo cluster is ready!${RESET}\n"
echo -e "  Cluster :  kind-${CLUSTER_NAME}"

NGINX_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<pending>")
echo -e "  nginx IP:  ${NGINX_IP}"
echo ""
echo -e "${BOLD}Next steps (live demo):${RESET}"
echo -e "  bash demo/01-ingress.sh    # Deploy app + verify Ingress"
echo -e "  bash demo/02-dry-run.sh    # Inspect migration output (dry-run)"
echo -e "  bash demo/03-apply.sh      # Apply Gateway API resources & verify"
echo -e "  bash demo/teardown.sh      # Clean up everything when done"
echo ""
