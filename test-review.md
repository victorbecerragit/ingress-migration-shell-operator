# Ingress Migration Shell Operator - Review Checklist

This document reviews the generated repository against the production-ready requirements and functional specifications.

## Test Plan

### A. Static Checks (no cluster)
1. Hook configs render:
  - `bash scripts/migrate.sh --config`
  - `bash scripts/validate.sh --config`
  - `bash scripts/rollback.sh --config`

2. Helm template sanity:
  - `helm template ./` renders without errors

### B. Mock Cluster E2E (dry-run)

Goal: validate that a real Ingress + Service can be converted to Gateway API output and that the migration hook patches status back to the trigger ConfigMap.

Run:
```bash
bash ./tests/run-e2e.sh
```

Manual repro (synthetic binding context):
```bash
bash ./tests/run-manual.sh
```

Notes:
- If `ingress2gateway` is missing locally, the runner downloads it into `tests/.bin/`.
- The mock E2E trigger uses `providers=ingress-nginx` so it can run without Kong CRDs installed.

What it asserts:
- Trigger ConfigMap `.data.convertedResources` is set and is an integer
- `.data.convertedResources >= 1`
- `.data.error == "none"`
- `.data.applied == "false"` (dry-run)

Optional (ephemeral Kind cluster):
```bash
E2E_KIND=1 bash ./tests/run-e2e.sh
```

### 1. Top-Level Layout
**✅ Yes, fully structured.** The scaffolding includes all requested directories:
*   `Chart.yaml`, `values.yaml`, `templates/` (Helm Chart)
*   `scripts/` (Main logic hooks for the operator)
*   `examples/` (Triggers)
*   `Dockerfile` (Container spec)
*   `.github/workflows/ci.yaml` (Action definitions)
*   `README.md` (Viral marketing + quickstart)

### 2. Concrete Hook Definition
**✅ Yes.** Flant Shell Operator hooks demand a `--config` flag response. We implemented this in all three scripts natively in Bash (no go-bindata or external dependencies). 
For example, the top of `scripts/migrate.sh` natively binds to ConfigMap events:
```bash
if [[ $1 == "--config" ]] ; then
  cat <<EOF
configVersion: v1
kubernetes:
- name: MigrationTrigger
  apiVersion: v1
  kind: ConfigMap
  executeHookOnEvent:
  - Added
  - Modified
  labelSelector:
    matchLabels:
      ingress-migration.flant.com/trigger: "true"
EOF
  exit 0
fi
```

### 3. Realistic Docker Base
**✅ Yes.** The Docker image natively extends Flant's operator, pulling in exactly what is needed for this workflow without bloated SDKs.
*   **Base:** `ghcr.io/flant/shell-operator:v1.4.16` (Alpine based)
*   **Packages:** native `bash`, `curl`, `jq` (crucial for Flant context parsing).
*   **Binaries:** Downloads execution-ready binaries for `kubectl` (latest stable) and `ingress2gateway` (v0.5.0).

### 4. Bash Scripts: Idempotency, Dry-Runs, and Error Handling
**✅ Yes. They correctly implement all three patterns:**

*   **Idempotency:** `ingress2gateway` safely generates declarative YAML on every run. Applying it via `echo "$OUT" | kubectl apply -f -` is completely idempotent. Furthermore, the `rollback.sh` script executes with `--ignore-not-found=true`.
*   **Handling Dry-Run vs Apply:** The parsed boolean flag safely skips execution in `migrate.sh`:
    ```bash
    if [ "$DRY_RUN" == "false" ]; then
        echo "Applying $C HTTPRoutes..."
        echo "$OUT" | kubectl apply -n "$ns" -f -
    else
        echo "Dry run enabled. Skipping apply. Generated $C HTTPRoutes..."
    fi
    ```
*   **Meaningful Exits & Status:** Internal functions trap `eval` logic with `set -e`. If `ingress2gateway` panics or generation fails, exit codes trigger robust JSON status updates patched straight back into the triggering ConfigMap:
    ```bash
    # Patches error back to the user config map dynamically formatting with jq
    STATUS_PAYLOAD=$(jq -n \
      --arg count "$COUNT" \
      --arg applied "$APPLIED" \
      --arg error "$ERROR_MSG" \ ...
    kubectl patch configmap "$CM_NAME" -n "$CM_NAMESPACE" --type merge -p "$STATUS_PAYLOAD"
    ```

### 5. Helm & RBAC
**✅ Yes, rigorously scoped:**
*   **Proper RBAC:** `templates/role.yaml` tightly targets networking and gateway API resources specifically (with Kong configurations):
    *   *"networking.k8s.io"*: `ingresses`, `ingressclasses` (`get, list, watch`)
    *   *"gateway.networking.k8s.io"*: `gateways`, `httproutes` (`get, list, watch, create, update, patch, delete`)
    *   *"configuration.konghq.com"*: `kongingresses`, `tcpingresses`... plugins
*   **Values/Configuration:** 
    *   **Helm Values** (`values.yaml`) focuses purely on infrastructure (replica counts, image tags, RBAC toggles). 
    *   **Migration Configuration** (Providers, Selectors, Dry-run) was intentionally left on the *Triggering ConfigMap Annotations* (`examples/migration-prod.yaml`) as you outlined in the functional spec section, enabling true Multi-Tenant safety since different triggers deploy in different environments dynamically.
