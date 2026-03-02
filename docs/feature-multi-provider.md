# Feature: Multi-Provider Extensibility & Production Hardening

**Branch:** `feature/multi-provider-architecture`  
**Status:** In Progress  
**Author:** kubernetes-specialist analysis

---

## Overview

`ingress-migration-shell-operator` is a Flant shell-operator–based Kubernetes controller that watches trigger ConfigMaps and runs `ingress2gateway` to convert Ingress resources to Gateway API (HTTPRoute/Gateway) objects.

The goal of this feature branch is to:
1. Make provider selection explicit and extensible (APISIX, Kong, future providers)
2. Extract duplicated status-patching into a shared library with retry logic
3. Harden the Dockerfile for multi-arch builds (arm64/amd64) and add smoke-tests
4. Lay the groundwork for a real validation hook

---

## Architecture: Provider Dispatch

### Current State
The migration hook reads `ingress-migration.flant.com/providers` from the trigger ConfigMap.
If you pass an unsupported provider name (or a common alias), the hook needs to normalise it (or fail fast) before calling `ingress2gateway`.

### Target State
A `dispatch_provider` function validates the annotation value, normalises provider aliases, and returns the canonical `--providers=` flag value.
In the current codebase, this function lives in `scripts/lib/provider.sh` and is sourced by `scripts/migrate.sh`.

```
trigger ConfigMap
  └── annotation: ingress-migration.flant.com/providers: "apisix"
        │
        ▼
  dispatch_provider("apisix")
        │
        ├── ingress-nginx   →  --providers=ingress-nginx  (ingress2gateway)
      ├── apisix          →  --providers=apisix         (ingress2gateway)
      ├── apisix-ingress  →  --providers=apisix         (ingress2gateway)
        ├── kong           →  --providers=kong          (ingress2gateway)
        └── kong-ingress    →  --providers=kong          (ingress2gateway)
```

**Supported providers (v1):**

| Annotation value     | ingress2gateway flag    | Notes                              |
|----------------------|-------------------------|------------------------------------|
| `ingress-nginx`      | `--providers=ingress-nginx`  | Default; NGINX community ingress  |
| `apisix`             | `--providers=apisix` | Apache APISIX provider              |
| `apisix-ingress`     | `--providers=apisix` | Alias for apisix                    |
| `kong`               | `--providers=kong`  | Kong Ingress Controller              |
| `kong-ingress`        | `--providers=kong`  | Alias for kong                      |

**Adding a new provider:** Add a case to `dispatch_provider()` in `scripts/lib/provider.sh`. If the provider requires different flags/behavior, adjust the `ingress2gateway` invocation in `scripts/migrate.sh`.

**Namespace scoping:** `ingress-migration.flant.com/namespace-selector` is a **Namespace label selector** (e.g. `team=platform`). The hook selects namespaces first, then processes objects inside them.

### Trigger ConfigMap example — APISIX
See [examples/trigger-apisix.yaml](../examples/trigger-apisix.yaml) for a runnable example.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: trigger-apisix-migration
  labels:
    ingress-migration.flant.com/trigger: "true"
  annotations:
    ingress-migration.flant.com/providers: "apisix"
    ingress-migration.flant.com/namespace-selector: "team=platform"
    ingress-migration.flant.com/dry-run: "false"
```

### Trigger ConfigMap example — Kong
Copy the APISIX example and set `ingress-migration.flant.com/providers: "kong"`.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: trigger-kong-migration
  labels:
    ingress-migration.flant.com/trigger: "true"
  annotations:
    ingress-migration.flant.com/providers: "kong"
    ingress-migration.flant.com/dry-run: "true"
```

---

## Shared Library: `scripts/lib/status.sh`

### Problem
All three hooks (`migrate.sh`, `validate.sh`, `rollback.sh`) duplicate the same `kubectl patch configmap` invocation inline.  
- No retry on transient API server failures  
- Changes to the patch format require 3-place updates  
- errors are silently swallowed  

### Solution
Extract to `scripts/lib/status.sh` with exponential back-off retry:

```bash
patch_status <cm_name> <cm_namespace> <json_payload>
```

Retry schedule: attempt 1 → 2 s → attempt 2 → 4 s → attempt 3, then warn and continue.

### Deployment wiring
The ConfigMap template key is `status.sh` (ConfigMap keys cannot contain `/`), but the repo source lives at `scripts/lib/status.sh`. It is mounted into the pod at `/hooks/status.sh`. Each hook sources it:

```bash
source /hooks/status.sh
```

---

## Multi-Arch Dockerfile

### Problem
The current Dockerfile hardcodes `linux/amd64` and `x86_64` in all download URLs.  
This fails on:
- EKS Graviton nodes (arm64)
- Azure / GCP ARM instances
- Apple Silicon CI runners (`linux/arm64` emulation)

### Solution
Use Docker `--platform` build args to select the correct binary:

```dockerfile
ARG TARGETARCH          # injected by Docker buildx: amd64 | arm64
ARG BUILDPLATFORM       # injected by Docker buildx: linux/amd64 | linux/arm64
```

`kubectl` releases are at `bin/linux/${TARGETARCH}/kubectl`.  
`ingress2gateway` releases use `x86_64` vs `arm64` suffix — mapped at build time.

### Smoke-test
The Dockerfile copies scripts into the image at build time (`COPY scripts/ /hooks/`) and runs each hook's `--config` path to verify JSON output and exit 0 before the image is pushed:

```dockerfile
RUN bash /hooks/migrate.sh  --config >/dev/null && \
    bash /hooks/validate.sh --config >/dev/null && \
    bash /hooks/rollback.sh --config >/dev/null
```

Broken/syntactically-invalid scripts now fail the build rather than shipping silently.

---

## File Change Matrix

| File | Change | Priority |
|------|--------|----------|
| `scripts/lib/status.sh` | **New** — shared patch_status with retry | 🔴 High |
| `scripts/migrate.sh` | Source status.sh; add dispatch_provider(); use patch_status | 🔴 High |
| `scripts/validate.sh` | Source status.sh; use patch_status | 🔴 High |
| `scripts/rollback.sh` | Source status.sh; use patch_status | 🔴 High |
| `Dockerfile` | Multi-arch TARGETARCH; smoke-test in RUN | 🔴 High |
| `templates/configmap-scripts.yaml` | Add `status.sh` key from `scripts/lib/status.sh` | 🔴 High |
| `examples/trigger-apisix.yaml` | New example trigger for APISIX | 🟡 Medium |
| `examples/trigger-kgateway.yaml` | New example trigger for kgateway-dev controller | 🟡 Medium |
| `scripts/validate.sh` | Real HTTPRoute `.status.conditions` check | 🟡 Medium |
| `.github/workflows/ci.yml` | Multi-arch build + Trivy scan | 🟡 Medium |
| `values.yaml` | Add `providers:` section | 🟢 Low |
| `README.md` | Document provider dispatch, multi-arch, new triggers | 🟢 Low |

---

## Priority Backlog

### 🔴 High (this branch)

| # | Task | Acceptance Criteria |
|---|------|---------------------|
| H1 | Extract `scripts/lib/status.sh` with retry | All 3 hooks call `patch_status`; inline kubectl patch removed |
| H2 | Multi-arch Dockerfile (`linux/amd64` + `linux/arm64`) | `docker buildx build --platform linux/amd64,linux/arm64` succeeds |
| H3 | Smoke-test in Dockerfile | `docker build` fails if any hook's `--config` exits non-zero |
| H4 | Add `dispatch_provider()` to migrate.sh | Unknown provider sets ERROR_MSG and exits; aliases normalised |
| H5 | Update `configmap-scripts.yaml` to include `status.sh` key | Helm renders ConfigMap with 4 keys; pod can source `/hooks/status.sh` |

### 🟡 Medium (follow-up)

| # | Task |
|---|------|
| M1 | Real validate.sh: check HTTPRoute `.status.conditions[type=Accepted]` |
| M2 | GitHub Actions workflow: matrix build + Trivy vulnerability scan |
| M3 | Example trigger ConfigMaps for APISIX and kgateway-dev |
| M4 | Helm `values.yaml` `providers:` section with documentation |

### 🟢 Low (backlog)

| # | Task |
|---|------|
| L1 | README update: provider table, multi-arch note, new annotation docs |
| L2 | Unit-style bats tests for dispatch_provider() |
| L3 | Per-provider RBAC annotations in Chart |

---

## Open Questions

1. **ingress2gateway version**: v0.5.0 supports `apisix` and `kong` — confirm with the ingress2gateway release notes before enabling these in production.
2. **Gateway CR ownership**: When a trigger applies the migration, should the operator also create the Gateway CR, or assume it pre-exists? Currently it assumes pre-existence.
3. **Status history**: The current patch overwrites `data.lastRun`. Should we keep a ring-buffer of recent runs (e.g., `lastRuns` as a JSON array)?
