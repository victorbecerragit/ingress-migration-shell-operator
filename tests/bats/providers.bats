#!/usr/bin/env bats

setup() {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # shellcheck source=/dev/null
  source "$ROOT_DIR/scripts/lib/provider.sh"
}

@test "dispatch_provider: ingress-nginx" {
  run dispatch_provider "ingress-nginx"
  [ "$status" -eq 0 ]
  [ "$output" = "ingress-nginx" ]
}

@test "dispatch_provider: apisix alias maps to apisix" {
  run dispatch_provider "apisix"
  [ "$status" -eq 0 ]
  [ "$output" = "apisix" ]
}

@test "dispatch_provider: apisix-ingress alias maps to apisix" {
  run dispatch_provider "apisix-ingress"
  [ "$status" -eq 0 ]
  [ "$output" = "apisix" ]
}

@test "dispatch_provider: unknown provider fails" {
  run dispatch_provider "totally-unknown"
  [ "$status" -ne 0 ]
}
