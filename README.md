# 🚀 Ingress Migration Shell Operator

**NGINX Ingress dies March 2026. Migrate to Gateway API in 5 minutes, zero Go required.**

`ingress-migration-shell-operator` is a Kubernetes-native, GitOps-ready, zero-code tool to automatically convert NGINX Ingress resources to Kubernetes Gateway API (specifically Kong provider). It harnesses the power of [Flant Shell Operator](https://github.com/flant/shell-operator) and `ingress2gateway` to execute dynamic migrations via declarative triggers.

## ✨ Features
* **Zero Downtime**: Generates and applies `HTTPRoute` resources side-by-side with your existing Ingresses.
* **Declarative Trigger**: Uses a simple annotated `ConfigMap` trigger format. Ideal for ArgoCD/GitOps!
* **Multi-Tenant Safe**: Filter migrations targeting namespace label selectors dynamically.
* **Review & Apply Gates**: Built-in dry-run flag allows you to safely check the generation logic on the fly before applying resources to your cluster.
* **Status Reporting**: The Shell Operator automatically patches back the converted resources count, success/error states directly into your trigger `ConfigMap`.
* **Rollback & Validate**: Equipped with additional hooks to quickly delete applied routes or smoke-test logic.

## 📦 Quickstart

### Prerequisites
* Kubernetes Cluster (tested on `minikube`)
* Helm v3
* Kong Ingress Controller with Gateway API support

### Installation

Install via Helm:

```bash
helm upgrade --install ingress-migrator ./ \
  --namespace ingress-system \
  --create-namespace \
  --set replicaCount=1
```

### ⛵ Minikube Test Drive
1. Apply the demo NGINX resources in a simulated `prod` environment:
   ```bash
   kubectl apply -f examples/minikube-test.yaml
   ```

2. Trigger the migration with `dry-run: "true"` to preview:
   ```bash
   kubectl apply -f examples/migration-prod.yaml
   ```

3. Check the results in the ConfigMap:
   ```bash
   kubectl get configmap migrate-ingress-prod -n demo-prod -o yaml
   ```
   *Look for the `convertedResources` and `applied` tracking annotations under data!*

4. Apply for Real:
   Change `dry-run: "false"` inside `examples/migration-prod.yaml` and re-apply:
   ```bash
   kubectl apply -f examples/migration-prod.yaml
   ```

## ✅ E2E Tests (Mock Cluster)

This repo includes an end-to-end test that:
- Applies a mock namespace + Service + Ingress
- Runs `scripts/migrate.sh` using a synthetic Shell-Operator binding context
- Asserts the trigger ConfigMap is patched with `convertedResources >= 1`, `error=none`, and `applied=false` (dry-run)

### Prereqs
- `kubectl` and `jq` on your PATH
- A working cluster in your current kubeconfig, OR use Kind

Notes:
- If `ingress2gateway` is not installed, the test runner auto-downloads the pinned version into `tests/.bin/`.
- The mock E2E trigger uses `providers=ingress-nginx` so it can run on a plain cluster without Kong CRDs installed.

### Run against your current cluster
```bash
bash ./tests/run-e2e.sh
```

### Manual hook run (synthetic binding context)
If you want to reproduce the hook execution without remembering Fish vs Bash syntax:
```bash
bash ./tests/run-manual.sh
```

### Run with a temporary Kind cluster
```bash
E2E_KIND=1 bash ./tests/run-e2e.sh
```

### 🧠 How does it work?
The tool intercepts `ConfigMap` Create/Update events annotated with `ingress-migration.flant.com/*` using Flant Shell operator events and safely processes them using inline Bash executing `ingress2gateway`. No massive Go builds, purely composable binaries!
