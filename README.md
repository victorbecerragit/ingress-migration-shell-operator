# Ingress Migration Shell Operator

[![CI](https://img.shields.io/github/actions/workflow/status/victorbecerragit/ingress-migration-shell-operator/ci.yaml?branch=main&logo=github&label=CI)](https://github.com/victorbecerragit/ingress-migration-shell-operator/actions/workflows/ci.yaml)
[![Release](https://img.shields.io/github/release/victorbecerragit/ingress-migration-shell-operator.svg)](https://github.com/victorbecerragit/ingress-migration-shell-operator/releases)
[![Helm Chart](https://img.shields.io/badge/helm--chart-v0.3.0-blue?logo=helm)](https://github.com/victorbecerragit/ingress-migration-shell-operator/releases)
[![Shell Operator](https://img.shields.io/badge/shell--operator-v1.4.16-informational?logo=linux)](https://github.com/flant/shell-operator)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Kubernetes-native tool to convert Ingress resources to Gateway API (HTTPRoutes + Gateways)
using [`ingress2gateway`](https://github.com/kubernetes-sigs/ingress2gateway) and
[Shell Operator](https://github.com/flant/shell-operator). No Go, no controllers to write —
migration is driven by an annotated ConfigMap trigger.

> **Why?** The [ingress-nginx controller is deprecated](https://kubernetes.github.io/ingress-nginx/) and the Kubernetes project recommends migrating to the Gateway API. This tool automates that migration.

## Features

- **Declarative trigger** — a single ConfigMap with annotations controls scope, provider, dry-run, and rollback. GitOps / ArgoCD friendly.
- **Dry-run gate** — preview converted resources before applying anything to the cluster.
- **Before/after report** — each run writes a human-readable report directly into the trigger ConfigMap.
- **NGINX preflight warnings** — detects risky patterns (regex paths, rewrite-target, trailing-slash redirects) before conversion.
- **Rollback hook** — removes applied HTTPRoutes on demand.
- **Audit history** — append-only JSONL log of every run stored in a ConfigMap.
- **Multi-provider** — `ingress-nginx`, `apisix`, `kong`, `kgateway` (gateway class override).

> **Note — Traefik:** Traefik is not currently supported by `ingress2gateway` (the upstream conversion tool). Passing `providers: traefik` will fail fast with a clear error. Track support in [kubernetes-sigs/ingress2gateway](https://github.com/kubernetes-sigs/ingress2gateway).


## Prerequisites

- Kubernetes cluster with [Gateway API CRDs](https://gateway-api.sigs.k8s.io/guides/#installing-gateway-api) installed
- Helm v3
- A supported Gateway API controller installed and running (e.g. [`kgateway`](https://kgateway.dev), [`kong`](https://docs.konghq.com/kubernetes-ingress-controller/), [`cloud-provider-kind`](https://github.com/kubernetes-sigs/cloud-provider-kind) for local Kind clusters)

## Install

### Using Helm (Recommended)

Add the repository and install:

```bash
helm repo add ingress-migration https://victorbecerragit.github.io/ingress-migration-shell-operator
helm repo update
helm install ingress-migration ingress-migration/ingress-migration-shell-operator \
  --namespace ingress-migration-system \
  --create-namespace
```

Preview rendered manifests before installing:

```bash
helm upgrade --install ingress-migration ingress-migration/ingress-migration-shell-operator \
  --namespace ingress-migration-system \
  --create-namespace \
  --dry-run
```

Pin to a specific version:

```bash
helm install ingress-migration ingress-migration/ingress-migration-shell-operator \
  --namespace ingress-migration-system \
  --create-namespace \
  --version 0.3.0
```

### Development / Local Install

```bash
git clone https://github.com/victorbecerragit/ingress-migration-shell-operator.git
cd ingress-migration-shell-operator
helm upgrade --install ingress-migration ./ \
  --namespace ingress-migration-system \
  --create-namespace
```

## Trigger a Migration

Create a ConfigMap with the `ingress-migration.flant.com/migrate` label:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: migrate-ingress-demo
  namespace: demo-prod
  labels:
    ingress-migration.flant.com/trigger: "true"
  annotations:
    ingress-migration.flant.com/providers: "ingress-nginx"
    ingress-migration.flant.com/namespace-selector: "env=prod"
    ingress-migration.flant.com/dry-run: "true"        # change to "false" to apply
    ingress-migration.flant.com/migrate-endpoints: "true"
    ingress-migration.flant.com/cluster-id: "my-cluster"
    ingress-migration.flant.com/initiator: "you@example.com"
```

```bash
kubectl apply -f trigger.yaml

Or use the manifest directly from /demo/manifests/ to create the app/ingress to migrate from:
kubectl apply -f demo/manifests/app.yaml
kubectl apply -f demo/manifests/ingress.yaml
kubectl apply -f demo/manifests/trigger-apply.yaml

```

## Read the Report

After the operator runs, a human-readable before/after report is written directly into the trigger ConfigMap:

```bash
kubectl get cm migrate-ingress-demo -n demo-prod \
  -o go-template='{{index .data "report"}}'
```

Example output:

```
=== Ingress -> Gateway API Migration Report ===

  Timestamp : 2026-03-03T07:58:23Z
  Trigger   : demo-prod/migrate-ingress-demo
  Mode      : DRY RUN  (no resources changed)
  Initiator : you@example.com

--- Configuration ---
  Provider      : ingress-nginx
  NS Selector   : env=prod
  Gateway Class : (default)
  Endpoints     : enabled

--- Before ---
  Ingresses : 9
    demo-prod/ingress.networking.k8s.io/demo-ingress
    ingress-migration-mock/ingress.networking.k8s.io/app-rewrite
    ...

--- After ---
  HTTPRoutes     : 6
  Gateways       : 2
  EndpointSlices : 2
  Applied        : no
  Error          : none
  Manifest SHA   : 0d728c345cfd0980...

--- NGINX Preflight Warnings (14) ---
  [NGINX_TRAILING_SLASH_REDIRECT] host=foo.bar.com ...
  [NGINX_REWRITE_TARGET_IMPLIES_REGEX] host=rewrite.bar.com ...
  ... and 12 more

--- Namespaces ---
  demo-prod
```

The flat status keys (`convertedResources`, `convertedGateways`, `migratedEndpoints`, `applied`, `error`, `lastRun`, `nginxPreflightWarningsCount`) remain available for programmatic use.

## Rollback

Delete applied HTTPRoutes by creating a ConfigMap with the `ingress-migration.flant.com/rollback` label:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: rollback-demo
  namespace: demo-prod
  labels:
    ingress-migration.flant.com/rollback: "true"
  annotations:
    ingress-migration.flant.com/namespace-selector: "env=prod"
```

## Audit History

Each run appends a compact JSON record to a JSONL buffer in a ConfigMap (default `ingress-migration-history`, bounded to 100 entries). Read it with:

```bash
kubectl get cm ingress-migration-history -n demo-prod \
  -o json | jq -r '.data["history.my-cluster.jsonl"]'
```

## Trigger Annotation Reference

| Annotation | Default | Description |
|---|---|---|
| `ingress-migration.flant.com/providers` | — | Comma-separated providers: `ingress-nginx`, `apisix`, `kong` — **Traefik is not yet supported by `ingress2gateway`** |
| `ingress-migration.flant.com/namespace-selector` | (all) | Namespace label selector to scope migration |
| `ingress-migration.flant.com/dry-run` | `"true"` | Set to `"false"` to apply resources |
| `ingress-migration.flant.com/gateway-class` | (provider default) | Override `gatewayClassName` in output |
| `ingress-migration.flant.com/migrate-endpoints` | `"false"` | Also migrate EndpointSlices |
| `ingress-migration.flant.com/cluster-id` | — | Stable ID used to partition history per cluster |
| `ingress-migration.flant.com/initiator` | — | Free-text label stored in history (user, team, CI job) |
| `ingress-migration.flant.com/history-enabled` | `"true"` | Disable history writes per trigger |
| `ingress-migration.flant.com/history-configmap` | `ingress-migration-history` | Name of the history ConfigMap |
| `ingress-migration.flant.com/history-max-entries` | `"100"` | Rolling window size for history |

## Testing & Development

See [docs/testing.md](docs/testing.md) for unit tests, E2E tests, provider-specific test suites, and guidance on adding or modifying test fixtures.
