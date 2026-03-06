# Ingress Migration Shell Operator

[![CI](https://img.shields.io/github/actions/workflow/status/victorbecerragit/ingress-migration-shell-operator/ci.yaml?branch=main&logo=github&label=CI)](https://github.com/victorbecerragit/ingress-migration-shell-operator/actions/workflows/ci.yaml)
[![Release](https://img.shields.io/github/release/victorbecerragit/ingress-migration-shell-operator.svg)](https://github.com/victorbecerragit/ingress-migration-shell-operator/releases)
[![Helm Chart](https://img.shields.io/badge/helm--chart-v0.3.0-blue?logo=helm)](https://github.com/victorbecerragit/ingress-migration-shell-operator/releases)
[![Shell Operator](https://img.shields.io/badge/shell--operator-v1.4.16-informational?logo=linux)](https://github.com/flant/shell-operator)
[![ingress2gateway](https://img.shields.io/badge/ingress2gateway-v0.5.0-brightgreen?logo=kubernetes)](https://github.com/kubernetes-sigs/ingress2gateway/releases/tag/v0.5.0)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

Kubernetes-native tool to convert Ingress resources to Gateway API (HTTPRoutes + Gateways)
using [`ingress2gateway`](https://github.com/kubernetes-sigs/ingress2gateway) and
[Shell Operator](https://github.com/flant/shell-operator). No Go, no controllers to write —
migration is driven by an annotated ConfigMap trigger.

## Why?

The [ingress-nginx controller is deprecated](https://kubernetes.github.io/ingress-nginx/) and the Kubernetes project recommends migrating to the Gateway API. This tool automates that migration.

## Comparison

This project builds **on top of** [`ingress2gateway`](https://github.com/kubernetes-sigs/ingress2gateway),
adding a Kubernetes-native, ConfigMap-driven trigger layer that turns a one-shot CLI command
into a live operator: declare migration intent in a labeled ConfigMap, let shell-operator react,
and get a before/after report written back into the same object — all version-controllable and
GitOps/ArgoCD-compatible without writing a line of Go.

| Feature | **ingress-migration-shell-operator** *(this project)* | [ingress2gateway](https://github.com/kubernetes-sigs/ingress2gateway) | [IBM iks-ingress-migration-tool](https://github.com/IBM/iks-ingress-migration-tool) |
|---|---|---|---|
| **Language** | Bash — no build toolchain required | Go | Go |
| **Trigger model** | **Annotated ConfigMap** — label a ConfigMap; shell-operator fires the hook automatically. Fully declarative, GitOps/ArgoCD-native, version-controllable | CLI — one-shot `ingress2gateway print` command | CLI — one-shot command |
| **Built on ingress2gateway** | ✅ Wraps `ingress2gateway` for conversion | — *(is* ingress2gateway*)* | ❌ Custom converter |
| **Multi-provider support** | ✅ ingress-nginx, apisix, kong, kgateway | ✅ ingress-nginx, apisix, kong, kgateway, Istio, … | ❌ IBM ALB only |
| **Preflight warnings** | ✅ NGINX-specific gotchas: `use-regex`, `rewrite-target` capture groups, trailing-slash redirects | ❌ | ❌ |
| **Dry-run gate** | ✅ `dry-run: "true"` annotation; report written to ConfigMap | ✅ `print` subcommand (stdout only) | ❌ |
| **Audit history** | ✅ Append-only JSONL in a ConfigMap, bounded rolling window | ❌ | ❌ |
| **Rollback** | ✅ Dedicated rollback hook (delete applied HTTPRoutes) | ❌ | ❌ |

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

## Quickstart (Kind + kgateway-dev)

End-to-end walkthrough on a local Kind cluster with the kgateway-dev (nightly) channel.
Every command below is copy-paste testable; the whole sequence takes ~5 minutes.

### 1. Create a Kind cluster

```bash
kind create cluster --name migration-demo
kubectl cluster-info --context kind-migration-demo
```

### 2. Install Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
```

### 3. Install kgateway-dev (nightly channel)

```bash
helm repo add kgateway-dev https://storage.googleapis.com/kgateway-dev-helm
helm repo update
helm install kgateway kgateway-dev/kgateway \
  --namespace kgateway-system \
  --create-namespace \
  --set image.tag=latest \
  --wait
```

Verify the controller is running:

```bash
kubectl get pods -n kgateway-system
```

### 4. Install this operator

```bash
helm repo add ingress-migration https://victorbecerragit.github.io/ingress-migration-shell-operator
helm repo update
helm install ingress-migration ingress-migration/ingress-migration-shell-operator \
  --namespace ingress-migration-system \
  --create-namespace \
  --wait
```

### 5. Deploy the demo app and Ingress

```bash
kubectl apply -f demo/manifests/app.yaml
kubectl apply -f demo/manifests/ingress.yaml
```

Confirm the Ingress is created:

```bash
kubectl get ingress -A
```

### 6. Trigger a dry-run migration

```bash
kubectl apply -f demo/manifests/trigger-apply.yaml
```

Watch the operator hook execute:

```bash
kubectl logs -n ingress-migration-system \
  -l app.kubernetes.io/name=shell-operator --follow
```

### 7. Read the migration report

```bash
kubectl get cm migrate-ingress-demo -n demo-prod \
  -o go-template='{{index .data "report"}}'
```

### 8. Apply for real (optional)

Edit the trigger ConfigMap to set `dry-run: "false"` and re-apply:

```bash
kubectl annotate cm migrate-ingress-demo -n demo-prod \
  ingress-migration.flant.com/dry-run="false" --overwrite
kubectl label cm migrate-ingress-demo -n demo-prod \
  ingress-migration.flant.com/trigger=true --overwrite
```

Then check the created HTTPRoutes and Gateways:

```bash
kubectl get httproute,gateway -A
```

### 9. Clean up

```bash
kind delete cluster --name migration-demo
```

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

## Roadmap

Contributions and feedback welcome — open an issue on [GitHub](https://github.com/victorbecerragit/ingress-migration-shell-operator/issues).

- [x] **NGINX warnings** — preflight scanner detects risky annotation patterns (`use-regex`, `rewrite-target`, trailing-slash redirects) before conversion and surfaces counts in the report and ConfigMap status
- [ ] **Provider extras** — implement the post-processing stubs to preserve provider-native annotations dropped by `ingress2gateway`:
  - `ingress-nginx` → native HTTPRoute filters (ssl-redirect, rewrite-target, use-regex, CORS, BackendLBPolicy timeouts)
  - `kong` → `KongPlugin` CRs (rate-limiting, auth-url, proxy-body-size)
  - `apisix` → `ApisixPluginConfig` CRs (plugin-config-name, allowlist/blocklist)
  - `kgateway` → `RouteOption` / `VirtualHostOption` policy attachments (rate-limit, extAuth, rewrite)
- [ ] **Rollback providers** — extend the rollback hook to also delete provider-specific CRs (`KongPlugin`, `ApisixPluginConfig`, `RouteOption`, etc.) created by the provider-extras step
- [ ] **Webhook** — optional admission webhook to block Ingress creation once migration is complete (enforce no-new-Ingress policy)
- [ ] **Metrics** — expose Prometheus metrics: `ingress_migration_runs_total`, `ingress_migration_httproutes_converted`, `ingress_migration_warnings_total`, `ingress_migration_errors_total`

## Testing & Development

See [docs/testing.md](docs/testing.md) for unit tests, E2E tests, provider-specific test suites, and guidance on adding or modifying test fixtures.

## Contributing

Contributions are welcome! The project is intentionally plain Bash — no build
toolchain required to extend it.

### Adding a new provider emitter

Provider post-processing lives in `scripts/lib/`. Each provider has a dedicated
file (e.g. `scripts/lib/apisix.sh`) with a single entry-point function
`postprocess_<provider>`. To add support for a new ingress controller:

1. Create `scripts/lib/<provider>.sh` with a `postprocess_<provider>` function.
2. Register the provider alias in `scripts/lib/provider.sh` (the `case` block
   that maps ingress class names to canonical provider names).
3. Add a dry-run trigger manifest `tests/manifests/trigger-<provider>-dryrun.yaml`.
4. Add a controller installer `tests/lib/install-<provider>.sh` for Kind-based E2E.
5. Add `<provider>` to the `matrix.provider` list in `.github/workflows/ci.yaml`.
6. Run `make test-e2e PROVIDER=<provider>` locally before opening a PR.

### Adding a new NGINX annotation mapping or gotcha

NGINX preflight detection lives in `scripts/lib/nginx_gotchas.sh`. Each gotcha
is a self-contained check that receives parsed Ingress JSON and emits a warning
object `{ code, severity, host, ingress, message }`.

1. Add a function `_check_<WARNING_CODE>` inside `nginx_gotchas.sh`.
2. Call it from `nginx_gotchas_warnings_from_ingress_list`.
3. Add a golden fixture pair in `testdata/`:
   - `testdata/<scenario>-input.json` — an `IngressList` in JSON
   - `testdata/<scenario>-warnings.json` — the expected warnings array (sorted by `.code`)
4. Verify with `make test-golden`.

### Providers we'd love contributions for

| Provider | Status | Notes |
|---|---|---|
| **Traefik** | Blocked upstream | `ingress2gateway` does not yet support Traefik |
| **HAProxy** | Open | Widely deployed; no migration tooling today |
| **Istio VirtualService** | Open | Common migration path to HTTPRoute |

Open an [issue](https://github.com/victorbecerragit/ingress-migration-shell-operator/issues)
to discuss before starting large changes.
