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

---

## Manual Hook Run

Reproduces hook execution outside the operator using a synthetic binding
context — useful for debugging without deploying to a cluster.

```bash
bash tests/run-manual.sh
```

---

## Adding / Modifying Tests

| What to change | Where |
|---|---|
| NGINX preflight logic | `scripts/lib/nginx_gotchas.sh` → `tests/bats/nginx_gotchas.bats` |
| Provider dispatch | `scripts/lib/provider.sh` → `tests/bats/providers.bats` |
| E2E Ingress fixtures | `tests/manifests/nginx/` (one YAML per scenario) |
| Trigger ConfigMap fixtures | `tests/manifests/trigger-*.yaml` |
| E2E assertions | `tests/run-e2e.sh` (bottom of file, `assert_*` calls) |

Run `bash tests/run-bats.sh` after every change to the library scripts; it
completes in under 5 seconds and requires no cluster.
