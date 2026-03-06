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

@test "dispatch_provider: kong" {
  run dispatch_provider "kong"
  [ "$status" -eq 0 ]
  [ "$output" = "kong" ]
}

@test "dispatch_provider: kong-ingress alias maps to kong" {
  run dispatch_provider "kong-ingress"
  [ "$status" -eq 0 ]
  [ "$output" = "kong" ]
}

@test "dispatch_provider: kong and kong-ingress both normalise to the same value" {
  run dispatch_provider "kong"
  [ "$status" -eq 0 ]
  local out_kong="$output"
  run dispatch_provider "kong-ingress"
  [ "$status" -eq 0 ]
  [ "$output" = "$out_kong" ]
}

@test "dispatch_provider: kong-gw is not a valid alias" {
  run dispatch_provider "kong-gw"
  [ "$status" -ne 0 ]
}

@test "dispatch_provider: kong-gateway is not a valid alias" {
  run dispatch_provider "kong-gateway"
  [ "$status" -ne 0 ]
}

@test "dispatch_provider: Kong (uppercase) is not a valid alias" {
  run dispatch_provider "Kong"
  [ "$status" -ne 0 ]
}

@test "dispatch_provider: kgateway-dev is an alias for kgateway" {
  run dispatch_provider "kgateway-dev"
  [ "$status" -eq 0 ]
  [ "$output" = "kgateway" ]
}

@test "dispatch_provider: unknown provider fails" {
  run dispatch_provider "totally-unknown"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Traefik — ingress2gateway does not support Traefik as a provider yet.
# All aliases must be rejected so the hook fails fast with a clear message
# rather than passing an invalid --providers flag to ingress2gateway.
# ---------------------------------------------------------------------------

@test "dispatch_provider: traefik is not a supported provider" {
  run dispatch_provider "traefik"
  [ "$status" -ne 0 ]
  [[ "$output" == *"traefik"* ]]
}

@test "dispatch_provider: traefik-ingress is not a supported provider" {
  run dispatch_provider "traefik-ingress"
  [ "$status" -ne 0 ]
  [[ "$output" == *"traefik"* ]]
}

@test "dispatch_provider: Traefik (uppercase) is not a valid alias" {
  run dispatch_provider "Traefik"
  [ "$status" -ne 0 ]
}

@test "dispatch_provider: traefik-proxy is not a valid alias" {
  run dispatch_provider "traefik-proxy"
  [ "$status" -ne 0 ]
}
