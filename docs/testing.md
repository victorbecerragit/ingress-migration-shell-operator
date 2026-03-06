# Testing Guide

This document covers all test options for `ingress-migration-shell-operator`:
unit tests, end-to-end tests, and manual hook runs.

---

## Unit Tests (BATS)

Uses [bats-core](https://github.com/bats-core/bats-core) to test individual
library functions in isolation — no cluster required.

```bash
bash tests/run-bats.sh
```

Test files are under `tests/bats/`. They cover:

- `nginx_gotchas.bats` — NGINX preflight warning detection
  (trailing-slash redirect, rewrite-target implies-regex, use-regex host-wide,
  regex prefix case-insensitive, namespace allowlist filtering)
- `providers.bats` — provider dispatch: `ingress-nginx`, `apisix` / `apisix-ingress`,
  `kong` / `kong-ingress`, unknown provider rejection
  (also asserts that invalid aliases `kong-gw`, `kong-gateway`, `Kong` are rejected)
- `status.bats` — `build_migration_report()` output: header, DRY/LIVE run label,
  namespace list, NGINX warnings section

---

## E2E Tests

End-to-end tests apply real Kubernetes resources, execute
`scripts/migrate.sh` via a synthetic Shell Operator binding context, and
then assert the trigger ConfigMap is patched correctly.

**Shared prereqs**

- `kubectl` and `jq` on your PATH
- A working kubeconfig pointing at a cluster, **or** Kind (see below)
- `ingress2gateway` — auto-downloaded to `tests/.bin/` if not found on PATH

> **Fixture note** — E2E paths use plain `Prefix` pathType to avoid
> `ingress-nginx` webhook rejections. Annotations like `use-regex` and
> `rewrite-target` are retained so the NGINX preflight scanner still fires.

### Run against your current cluster

```bash
bash tests/run-e2e.sh
```

### Run inside a temporary Kind cluster

```bash
E2E_KIND=1 bash tests/run-e2e.sh
```

### APISIX provider (`apisix`)

Validates provider dispatch and conversion for the `apisix` provider.
When `E2E_KIND=1` the test runner installs Apache APISIX + the APISIX
Ingress Controller automatically.

```bash
E2E_KIND=1 \
  E2E_TRIGGER_MANIFEST=trigger-apisix-dryrun.yaml \
  bash tests/run-e2e.sh
```

Set `E2E_INSTALL_APISIX=1` to force installation on an existing cluster.

### kgateway provider (`kgateway-dev`)

Validates the kgateway-dev controller path. The test runner installs
`kgateway-dev/kgateway` into Kind, runs `ingress2gateway` with the
`ingress-nginx` provider, and overrides the output `gatewayClassName`
via the `ingress-migration.flant.com/gateway-class: "kgateway"` annotation.

```bash
E2E_KIND=1 \
  E2E_TRIGGER_MANIFEST=trigger-kgateway-dryrun.yaml \
  bash tests/run-e2e.sh
```

Set `E2E_INSTALL_KGATEWAY=1` to force installation on an existing cluster.

### Kong provider (`kong`)

Validates provider dispatch and conversion for the `kong` provider using the
[Kong Ingress Controller](https://docs.konghq.com/kubernetes-ingress-controller/).
When `E2E_KIND=1` the test runner installs `kong/ingress` via Helm automatically.
`ingress2gateway` requires Kong's CRDs (`TCPIngress`, etc.) to be present in the
cluster — without them the conversion fails. Running with `E2E_INSTALL_KONG=1`
(or `E2E_KIND=1`) ensures the CRDs are available before the hook executes.

The `tests/manifests/mock-cluster.yaml` fixture includes a `demo-ingress-kong`
Ingress (`ingressClassName: kong`) so `ingress2gateway --providers=kong` always
finds at least one resource to convert.

```bash
# Existing cluster — install Kong then run
E2E_INSTALL_KONG=1 \
  E2E_TRIGGER_MANIFEST=trigger-kong-dryrun.yaml \
  bash tests/run-e2e.sh

# Temporary Kind cluster (installs Kong automatically)
E2E_KIND=1 \
  E2E_TRIGGER_MANIFEST=trigger-kong-dryrun.yaml \
  bash tests/run-e2e.sh
```

Expected output on success:

```
Kong is ready (namespace=kong, release=kong)
...
PASS: convertedResources=1 applied=false error=none
Used trigger manifest: trigger-kong-dryrun.yaml
```

Set `E2E_INSTALL_KONG=0` to skip controller installation (CRDs must already exist).

**Environment variables**

| Variable | Default | Description |
|---|---|---|
| `E2E_INSTALL_KONG` | `auto` | `auto` installs when `E2E_KIND=1`; `1` forces install; `0` skips |
| `E2E_KONG_NAMESPACE` | `kong` | Namespace for the Kong release |
| `E2E_KONG_RELEASE` | `kong` | Helm release name |
| `E2E_KONG_CHART_VERSION` | `0.4.0` | `kong/ingress` chart version |
| `E2E_KONG_WAIT_TIMEOUT` | `300s` | Rollout wait timeout |

---

## Manual Hook Run

Reproduces hook execution outside the operator using a synthetic binding
context — useful for debugging without deploying to a cluster.

```bash
bash tests/run-manual.sh
```

---

## Golden Tests

Golden test fixtures live in `testdata/` at the repository root. Each file
is a multi-document YAML combining two sections:

| Section | Content |
|---|---|
| **Section 1 — Input** | `Namespace`, `Service`, and `Ingress` manifests — `kubectl apply`-able to a real cluster |
| **Section 2 — Golden ConfigMap** | `expected-warnings` (JSON) and `expected-httproute-*` (YAML snippet) documenting expected outputs and known conversion gaps |

The golden ConfigMap is **not** a real workload resource; it exists solely as
structured documentation that can be read programmatically or compared manually.

### `nginx-regex-gotcha` — use-regex + rewrite-target + shared host

File: [`testdata/nginx-regex-gotcha.yaml`](../testdata/nginx-regex-gotcha.yaml)

**Scenario:** Two Ingresses (`api-main`, `api-shared`) share host `api.example.com`
in namespace `golden-test`. `api-main` sets `use-regex: "true"` and
`rewrite-target: /$1`; `api-shared` has no annotations but silently inherits
regex semantics host-wide — the `NGINX_REGEX_HOST_WIDE` gotcha.

**Step 1 — Apply the input resources:**

```bash
kubectl apply -f testdata/nginx-regex-gotcha.yaml
kubectl get ingress -n golden-test
```

**Step 2 — Run the preflight scanner:**

```bash
kubectl get ingress -n golden-test -o json | \
  bash -c "source scripts/lib/nginx_gotchas.sh; nginx_gotchas_warnings_from_ingress_list" | \
  jq 'sort_by(.code)'
```

**Expected warnings (3):**

| # | Code | Severity | Host | Ingress |
|---|---|---|---|---|
| 1 | `NGINX_REGEX_PREFIX_CASE_INSENSITIVE` | warning | `api.example.com` | — |
| 2 | `NGINX_REGEX_HOST_WIDE` | warning | `api.example.com` | — |
| 3 | `NGINX_REWRITE_TARGET_IMPLIES_REGEX` | warning | `api.example.com` | `golden-test/api-main` |

Compare jq output against the `expected-warnings` field in the golden ConfigMap:

```bash
kubectl get cm nginx-regex-gotcha-expected -n golden-test \
  -o go-template='{{index .data "expected-warnings"}}'
```

**Step 3 — Observe the HTTPRoute conversion gap:**

```bash
ingress2gateway print --providers=ingress-nginx --namespace golden-test
```

The generated HTTPRoute for `api-main` will carry `path.type: RegularExpression`
correctly but will **omit the `URLRewrite` filter** — `rewrite-target: /$1` is
silently dropped by `ingress2gateway`. Without the filter, requests to `/api/foo`
reach the backend as `/api/foo` rather than `/foo`.

The `expected-httproute-api-main` field in the golden ConfigMap documents this
gap and shows the `URLRewrite` filter block that the provider-extras
post-processing stub (tracked in the [Roadmap](../README.md#roadmap)) must inject.

**Clean up:**

```bash
kubectl delete namespace golden-test
```

---

## Adding / Modifying Tests

| What to change | Where |
|---|---|
| NGINX preflight logic | `scripts/lib/nginx_gotchas.sh` → `tests/bats/nginx_gotchas.bats` |
| Provider dispatch | `scripts/lib/provider.sh` → `tests/bats/providers.bats` |
| E2E Ingress fixtures | `tests/manifests/nginx/` (one YAML per scenario) |
| Kong / APISIX fixtures | `tests/manifests/mock-cluster.yaml` (`demo-ingress-kong`, `demo-ingress-apisix`) |
| Trigger ConfigMap fixtures | `tests/manifests/trigger-*.yaml` |
| Controller install scripts | `tests/lib/install-{apisix,kgateway,kong}.sh` |
| E2E assertions | `tests/run-e2e.sh` (bottom of file, `assert_*` calls) |

Run `bash tests/run-bats.sh` after every change to the library scripts; it
completes in under 5 seconds and requires no cluster.
