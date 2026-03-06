.PHONY: lint test-unit test-golden test-e2e test-e2e-all test help

# ── provider → trigger manifest mapping ───────────────────────────────────────
# nginx uses the legacy non-prefixed name; all other providers follow the
# trigger-<provider>-dryrun.yaml convention.
PROVIDER ?= nginx
ifeq ($(PROVIDER),nginx)
  E2E_TRIGGER := trigger-dryrun.yaml
else ifeq ($(PROVIDER),kgateway-dev)
  # kgateway-dev is the nightly channel; reuses the same trigger manifest as kgateway
  E2E_TRIGGER := trigger-kgateway-dryrun.yaml
else
  E2E_TRIGGER := trigger-$(PROVIDER)-dryrun.yaml
endif

# ── lint ───────────────────────────────────────────────────────────────────────
# Requires: shellcheck ≥ 0.9, helm ≥ 3
lint:
	@echo "→ shellcheck"
	shellcheck --severity=warning \
	  scripts/migrate.sh \
	  scripts/rollback.sh \
	  scripts/validate.sh \
	  scripts/lib/common.sh \
	  scripts/lib/history.sh \
	  scripts/lib/nginx_gotchas.sh \
	  scripts/lib/provider.sh \
	  scripts/lib/status.sh
	@echo "→ helm lint"
	helm lint .

# ── unit tests ────────────────────────────────────────────────────────────────
# Requires: bats-core on PATH  (or installed via tests/run-bats.sh bootstrap)
test-unit:
	@echo "→ bats unit tests"
	bash tests/run-bats.sh

# ── golden tests ──────────────────────────────────────────────────────────────
# Cluster-independent: pipes testdata/*-input.json through the nginx_gotchas
# scanner and compares output against testdata/*-warnings.json.
# Requires: jq
test-golden:
	@echo "→ golden tests"
	bash tests/run-golden.sh

# ── e2e tests ─────────────────────────────────────────────────────────────────
# Creates a Kind cluster (E2E_KIND=1), installs the selected gateway provider,
# applies the dry-run trigger manifest, and validates the hook output.
#
# Usage:
#   make test-e2e                    # nginx (default)
#   make test-e2e PROVIDER=kgateway
#   make test-e2e PROVIDER=apisix
#   make test-e2e PROVIDER=kong
#
# Requires: kind, kubectl, helm, docker
test-e2e:
	@echo "→ e2e tests (provider=$(PROVIDER), trigger=$(E2E_TRIGGER))"
	E2E_KIND=1 \
	  E2E_KIND_CLUSTER_NAME=ingress-e2e-$(PROVIDER) \
	  E2E_TRIGGER_MANIFEST=$(E2E_TRIGGER) \
	  bash tests/run-e2e.sh

# ── e2e all providers ─────────────────────────────────────────────────────────
# Runs all four providers in sequence (useful for full local validation before
# pushing to CI).  Each provider spins up its own named Kind cluster and tears
# it down after the test.
test-e2e-all:
	$(MAKE) test-e2e PROVIDER=nginx
	$(MAKE) test-e2e PROVIDER=kgateway
	$(MAKE) test-e2e PROVIDER=apisix
	$(MAKE) test-e2e PROVIDER=kong

# ── test (default suite, generic cluster) ─────────────────────────────────────
# Runs unit + golden + nginx e2e.  For full cross-provider coverage use
# test-e2e-all instead.
test: test-unit test-golden test-e2e

# ── help ───────────────────────────────────────────────────────────────────────
help:
	@echo "Targets:"
	@echo "  lint            shellcheck all scripts + helm lint"
	@echo "  test-unit       bats unit tests (no cluster)"
	@echo "  test-golden     golden fixture tests (no cluster)"
	@echo "  test-e2e        e2e via Kind cluster  [PROVIDER=nginx|kgateway|apisix|kong]"
	@echo "  test-e2e-all    e2e for all four providers in sequence"
	@echo "  test            test-unit + test-golden + test-e2e (nginx)"
