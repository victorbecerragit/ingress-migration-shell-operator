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
| 3 | `03-apply.sh` | Resources applied, Gateway gets an IP, **same `curl` works via Gateway API** |
| — | `teardown.sh` | Full cleanup — one command |

---

## Prerequisites

| Tool | Install |
|------|---------|
| `docker` | https://docs.docker.com/get-docker/ |
| `kind` | https://kind.sigs.k8s.io/docs/user/quick-start/#installation |
| `kubectl` | https://kubernetes.io/docs/tasks/tools/ |
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

## How it works under the hood

### The trigger ConfigMap

`demo/manifests/trigger.yaml` is a ConfigMap with a special label:

```yaml
labels:
  ingress-migration.flant.com/trigger: "true"
annotations:
  ingress-migration.flant.com/providers: "ingress-nginx"
  ingress-migration.flant.com/dry-run: "true"          # start safe
  ingress-migration.flant.com/namespace-selector: "env=prod"
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
name). In `03-apply.sh` we patch this at apply time:

```bash
ingress2gateway print --providers=ingress-nginx --namespace=demo-prod \
  | sed 's/gatewayClassName: nginx/gatewayClassName: cloud-provider-kind/' \
  | kubectl apply -f -
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
    └── trigger.yaml       ← Migration operator trigger ConfigMap
```
