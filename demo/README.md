# Demo — Live Ingress → Gateway API Migration

This directory contains everything needed to record a live demo of the
ingress migration shell-operator against a local [Kind](https://kind.sigs.k8s.io/) cluster.

Based on the Kubernetes blog post:
[Experimenting with Gateway API using kind (Jan 2026)](https://kubernetes.io/blog/2026/01/28/experimenting-gateway-api-with-kind/)

---

## What you'll show

| # | Script | What the audience sees |
|---|--------|----------------------|
| 0 | `setup.sh` | Kind cluster + cloud-provider-kind + ingress-nginx installed |
| 1 | `01-ingress.sh` | App running behind NGINX Ingress — `curl` returns JSON |
| 2 | `02-dry-run.sh` | Migration operator triggered in **dry-run** mode — shows generated `Gateway` + `HTTPRoute` YAML |
| 3 | `03-apply.sh` | Operator triggered with **dry-run=false** — resources applied, Gateway gets an IP, **same `curl` works via Gateway API** |
| — | `teardown.sh` | Full cleanup — one command |

---

## Prerequisites

| Tool | Install |
|------|---------|
| `docker` | https://docs.docker.com/get-docker/ |
| `kind` | https://kind.sigs.k8s.io/docs/user/quick-start/#installation |
| `kubectl` | https://kubernetes.io/docs/tasks/tools/ |
| `helm` | https://helm.sh/docs/intro/install/ (required only for APISIX install) |
| `curl`, `jq` | system package manager |

---

## Cluster architecture

```
┌─────────────────────────────────────────────────────────┐
│  Kind cluster  (ingress-migration-demo)                 │
│                                                         │
│  ┌───────────────┐        ┌──────────────────────────┐  │
│  │ ingress-nginx │        │  Gateway "nginx"          │  │
│  │  (controller) │        │  gatewayClassName:        │  │
│  │               │        │    cloud-provider-kind    │  │
│  └───────┬───────┘        └────────────┬─────────────┘  │
│          │  Ingress                    │  HTTPRoute      │
│          └──────────────┬──────────────┘                 │
│                         ▼                               │
│                  ┌─────────────┐                        │
│                  │  demo-app   │  (echo-basic, port 3000)│
│                  │  demo-prod  │                        │
│                  └─────────────┘                        │
│                                                         │
│  cloud-provider-kind (Docker sidecar)                   │
│    • Assigns real IPs to LoadBalancer Services          │
│    • Installs Gateway API CRDs                          │
│    • Manages GatewayClass "cloud-provider-kind"         │
└─────────────────────────────────────────────────────────┘
```

---

## Quick start

### Pre-demo (run once, can fast-forward in video)

```bash
bash demo/setup.sh
```

This takes 2–3 minutes. Do it before the live recording.

### Optional — Install Apache APISIX (for APISIX provider demos)

If you want to run migrations for the `apisix` provider (Ingress resources with `spec.ingressClassName: apisix`), install APISIX + the APISIX Ingress Controller into the demo Kind cluster:

```bash
bash demo/install-apisix.sh
```

### Step-by-step — Test the APISIX provider

The default demo scripts (`01-ingress.sh`, `02-dry-run.sh`, `03-apply.sh`) are written around **NGINX Ingress**.
If you want to specifically test the `apisix` provider end-to-end, use this walkthrough.

#### 0) Create the demo Kind cluster

```bash
bash demo/setup.sh
```

#### 1) Install APISIX + APISIX Ingress Controller into the cluster

```bash
bash demo/install-apisix.sh
kubectl get ingressclass apisix
kubectl get pods -n apisix
```

#### 2) Deploy the demo app (same as the NGINX demo)

```bash
kubectl apply -f demo/manifests/app.yaml
kubectl rollout status deployment/demo-app -n demo-prod --timeout=90s
```

#### 3) Create an APISIX Ingress in `demo-prod`

This is the “before migration” state for APISIX.

```bash
cat > /tmp/ingress-apisix.yaml <<'YAML'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo-ingress-apisix
  namespace: demo-prod
spec:
  ingressClassName: apisix
  rules:
  - host: demo.prod.example
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: demo-app
            port:
              number: 80
YAML

kubectl apply -f /tmp/ingress-apisix.yaml
kubectl get ingress demo-ingress-apisix -n demo-prod
```

#### 4) (Optional) Verify APISIX is actually serving the Ingress

Depending on the Helm chart defaults and your environment, the APISIX gateway Service may or may not be `LoadBalancer`.
Try the LoadBalancer IP first, and fall back to port-forward if needed.

```bash
kubectl get svc -n apisix

# If you see a LoadBalancer external IP on apisix-gateway:
APISIX_IP=$(kubectl get svc -n apisix apisix-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
echo "APISIX_IP=$APISIX_IP"

if [ -n "$APISIX_IP" ]; then
  curl --resolve "demo.prod.example:80:${APISIX_IP}" http://demo.prod.example/ | jq '{path, host, namespace, pod}'
else
  # Fallback: port-forward and curl locally
  kubectl -n apisix port-forward svc/apisix-gateway 9080:80
  # In another terminal:
  curl -H 'Host: demo.prod.example' http://127.0.0.1:9080/ | jq '{path, host, namespace, pod}'
fi
```

If your gateway Service is not called `apisix-gateway`, run `kubectl get svc -n apisix` and adjust the name.

#### 5) Run the migration in dry-run mode (APISIX provider)

This uses the same “manual hook simulation” the demo uses, but with `providers: apisix`.

```bash
cat > /tmp/trigger-apisix-dryrun.yaml <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: migrate-ingress-demo
  namespace: demo-prod
  labels:
    ingress-migration.flant.com/trigger: "true"
  annotations:
    ingress-migration.flant.com/providers: "apisix"
    ingress-migration.flant.com/dry-run: "true"
    ingress-migration.flant.com/namespace-selector: "env=prod"
    ingress-migration.flant.com/migrate-endpoints: "true"
data:
  note: "Trigger ConfigMap — dry-run for APISIX provider"
YAML

kubectl apply -f /tmp/trigger-apisix-dryrun.yaml

MANIFESTS_MOCK_CLUSTER="demo/manifests/app.yaml /tmp/ingress-apisix.yaml" \
  MANIFESTS_TRIGGER="/tmp/trigger-apisix-dryrun.yaml" \
  TRIGGER_NAMESPACE="demo-prod" \
  TRIGGER_CONFIGMAP="migrate-ingress-demo" \
  E2E_BIN_DIR="demo/.bin" \
  bash tests/run-manual.sh

kubectl get configmap migrate-ingress-demo -n demo-prod -o json | jq '.data'
```

#### 6) Apply the generated Gateway API resources (optional)

Even though you're migrating *from* the `apisix` provider, `ingress-migration.flant.com/gateway-class` is the **target Gateway API implementation**.
In this demo cluster, that target GatewayClass is `cloud-provider-kind` (it provisions LoadBalancer IPs inside Kind).

```bash
cat > /tmp/trigger-apisix-apply.yaml <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: migrate-ingress-demo
  namespace: demo-prod
  labels:
    ingress-migration.flant.com/trigger: "true"
  annotations:
    ingress-migration.flant.com/providers: "apisix"
    ingress-migration.flant.com/dry-run: "false"
    ingress-migration.flant.com/namespace-selector: "env=prod"
    ingress-migration.flant.com/migrate-endpoints: "true"
    ingress-migration.flant.com/gateway-class: "cloud-provider-kind"
data:
  note: "Trigger ConfigMap — apply mode for APISIX provider"
YAML

kubectl apply -f /tmp/trigger-apisix-apply.yaml

MANIFESTS_MOCK_CLUSTER="demo/manifests/app.yaml /tmp/ingress-apisix.yaml" \
  MANIFESTS_TRIGGER="/tmp/trigger-apisix-apply.yaml" \
  TRIGGER_NAMESPACE="demo-prod" \
  TRIGGER_CONFIGMAP="migrate-ingress-demo" \
  E2E_BIN_DIR="demo/.bin" \
  bash tests/run-manual.sh

kubectl get gateway -n demo-prod
kubectl get httproute -n demo-prod
```

At this point you can test the Gateway address the same way the default demo does (see `demo/03-apply.sh`).

### Live demo steps

```bash
# Step 1 — show the app running via NGINX Ingress
bash demo/01-ingress.sh

# Step 2 — trigger the migration operator in dry-run (inspect output)
bash demo/02-dry-run.sh

# Step 3 — apply Gateway API resources, verify end-to-end
bash demo/03-apply.sh
```

Each script **pauses at key moments** (press `Enter` to continue) so you can
explain what just happened.

### Cleanup

```bash
bash demo/teardown.sh
```

---

## Troubleshooting

### Gateway/HTTPRoute appear even in dry-run

This demo uses `spec.ingressClassName: nginx` in `demo/manifests/ingress.yaml`.
In some environments, an Ingress without `spec.ingressClassName` may be treated
as a "default" Ingress and can trigger automatic Gateway API translation by the
cluster. That can make it look like the migration operator applied resources
even in dry-run.

If you see `Gateway`/`HTTPRoute` created unexpectedly:
- Verify the Ingress has `spec.ingressClassName: nginx`
- Delete any auto-created resources: `kubectl delete gateway,httproute -n demo-prod --all`
```

---

## How it works under the hood

### The trigger ConfigMap

The demo uses two trigger manifests:

- `demo/manifests/trigger.yaml` — **dry-run=true** (inspect only)
- `demo/manifests/trigger-apply.yaml` — **dry-run=false** (live apply)

Both are ConfigMaps with a special label:

```yaml
labels:
  ingress-migration.flant.com/trigger: "true"
annotations:
  ingress-migration.flant.com/providers: "ingress-nginx"
  ingress-migration.flant.com/dry-run: "true"          # start safe
  ingress-migration.flant.com/namespace-selector: "env=prod"

# (Apply mode only)
# ingress-migration.flant.com/dry-run: "false"
# ingress-migration.flant.com/gateway-class: "cloud-provider-kind"
```

When the shell-operator sees this ConfigMap it runs `scripts/migrate.sh`,
which:
1. Calls `ingress2gateway print --providers=ingress-nginx --namespace=<ns>`
2. For each namespace matching `env=prod`
3. Patches the result back into the ConfigMap's `.data` fields

### What ingress2gateway generates

For our `demo.prod.example` Ingress:

```yaml
# Gateway (gatewayClassName patched for Kind)
kind: Gateway
metadata: {name: nginx, namespace: demo-prod}
spec:
  gatewayClassName: cloud-provider-kind   # ← patched from "nginx"
  listeners:
  - {name: demo-prod-example-http, hostname: demo.prod.example, port: 80, protocol: HTTP}

# HTTPRoute
kind: HTTPRoute
metadata: {name: demo-ingress-demo-prod-example, namespace: demo-prod}
spec:
  parentRefs: [{name: nginx}]
  hostnames: [demo.prod.example]
  rules:
  - backendRefs: [{name: demo-app, port: 80}]
    matches: [{path: {type: PathPrefix, value: /}}]
```

### GatewayClass adaptation

`ingress2gateway` generates `gatewayClassName: nginx` (inherits the IngressClass
name). For Kind, the real GatewayClass is `cloud-provider-kind`, so in apply mode
we set this on the trigger ConfigMap and the operator overrides `gatewayClassName`
before applying:

```yaml
metadata:
  annotations:
    ingress-migration.flant.com/dry-run: "false"
    ingress-migration.flant.com/gateway-class: "cloud-provider-kind"
```

In a real cluster you would match the `gatewayClassName` to whichever
[Gateway API implementation](https://gateway-api.sigs.k8s.io/implementations/)
you have installed (Cilium, Envoy Gateway, Istio, etc.).

---

## Customisation

| Environment variable | Default | Description |
|---------------------|---------|-------------|
| `KIND_CLUSTER_NAME` | `ingress-migration-demo` | Name of the Kind cluster |
| `INGRESS2GW_VERSION` | `v0.5.0` | ingress2gateway version to download |
| `GATEWAY_CLASS` | `cloud-provider-kind` | Override GatewayClass in `03-apply.sh` |

---

## File listing

```
demo/
├── README.md              ← you are here
├── setup.sh               ← one-time cluster setup
├── 01-ingress.sh          ← deploy app + verify NGINX Ingress
├── 02-dry-run.sh          ← trigger migration (dry-run)
├── 03-apply.sh            ← apply conversion, verify Gateway API
├── teardown.sh            ← full cleanup
└── manifests/
    ├── app.yaml           ← Namespace (env=prod) + Deployment + Service
    ├── ingress.yaml       ← NGINX Ingress rule
  ├── trigger.yaml       ← Trigger ConfigMap (dry-run=true)
  └── trigger-apply.yaml ← Trigger ConfigMap (dry-run=false)
```
