#!/usr/bin/env bats

@test "nginx_gotchas: empty ingress list => no warnings" {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  ingress_list='{"items":[]}'
  run bash -c "source \"$ROOT_DIR/scripts/lib/nginx_gotchas.sh\"; nginx_gotchas_warnings_from_ingress_list" <<<"$ingress_list"

  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "nginx_gotchas: use-regex on shared host => host-wide warnings" {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  ingress_list=$(cat <<'JSON'
{
  "items": [
    {
      "metadata": {
        "namespace": "a",
        "name": "one",
        "annotations": {
          "nginx.ingress.kubernetes.io/use-regex": "true"
        }
      },
      "spec": {
        "ingressClassName": "nginx",
        "rules": [
          {
            "host": "example.com",
            "http": {
              "paths": [
                {"path": "/foo.*", "pathType": "ImplementationSpecific", "backend": {"service": {"name": "s", "port": {"number": 80}}}}
              ]
            }
          }
        ]
      }
    },
    {
      "metadata": {"namespace": "b", "name": "two"},
      "spec": {
        "ingressClassName": "nginx",
        "rules": [
          {
            "host": "example.com",
            "http": {
              "paths": [
                {"path": "/bar", "pathType": "Prefix", "backend": {"service": {"name": "s", "port": {"number": 80}}}}
              ]
            }
          }
        ]
      }
    }
  ]
}
JSON
)

  run bash -c "source \"$ROOT_DIR/scripts/lib/nginx_gotchas.sh\"; nginx_gotchas_warnings_from_ingress_list" <<<"$ingress_list"
  [ "$status" -eq 0 ]

  run jq -r 'map(.code) | sort | unique | join("\n")' <<<"$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NGINX_REGEX_PREFIX_CASE_INSENSITIVE"* ]]
  [[ "$output" == *"NGINX_REGEX_HOST_WIDE"* ]]
}

@test "nginx_gotchas: rewrite-target => implies-regex warning" {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  ingress_list=$(cat <<'JSON'
{
  "items": [
    {
      "metadata": {
        "namespace": "a",
        "name": "rt",
        "annotations": {
          "nginx.ingress.kubernetes.io/rewrite-target": "/$1"
        }
      },
      "spec": {
        "ingressClassName": "nginx",
        "rules": [
          {
            "host": "rt.example.com",
            "http": {
              "paths": [
                {"path": "/(.*)", "pathType": "ImplementationSpecific", "backend": {"service": {"name": "s", "port": {"number": 80}}}}
              ]
            }
          }
        ]
      }
    }
  ]
}
JSON
)

  run bash -c "source \"$ROOT_DIR/scripts/lib/nginx_gotchas.sh\"; nginx_gotchas_warnings_from_ingress_list" <<<"$ingress_list"
  [ "$status" -eq 0 ]

  run jq -r 'map(.code) | sort | unique | join("\n")' <<<"$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NGINX_REWRITE_TARGET_IMPLIES_REGEX"* ]]
}

@test "nginx_gotchas: trailing slash with Exact/Prefix => trailing-slash warning" {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  ingress_list=$(cat <<'JSON'
{
  "items": [
    {
      "metadata": {"namespace": "a", "name": "ts"},
      "spec": {
        "ingressClassName": "nginx",
        "rules": [
          {
            "host": "ts.example.com",
            "http": {
              "paths": [
                {"path": "/foo/", "pathType": "Prefix", "backend": {"service": {"name": "s", "port": {"number": 80}}}}
              ]
            }
          }
        ]
      }
    }
  ]
}
JSON
)

  run bash -c "source \"$ROOT_DIR/scripts/lib/nginx_gotchas.sh\"; nginx_gotchas_warnings_from_ingress_list" <<<"$ingress_list"
  [ "$status" -eq 0 ]

  run jq -r 'map(.code) | sort | unique | join("\n")' <<<"$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NGINX_TRAILING_SLASH_REDIRECT"* ]]
}

@test "nginx_gotchas: namespace allowlist filters warnings" {
  ROOT_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

  ingress_list=$(cat <<'JSON'
{
  "items": [
    {
      "metadata": {"namespace": "allowed", "name": "ok", "annotations": {"nginx.ingress.kubernetes.io/use-regex": "true"}},
      "spec": {
        "ingressClassName": "nginx",
        "rules": [
          {"host": "allowed.example.com", "http": {"paths": [{"path": "/a.*", "pathType": "ImplementationSpecific", "backend": {"service": {"name": "s", "port": {"number": 80}}}}]}}
        ]
      }
    },
    {
      "metadata": {"namespace": "denied", "name": "nope", "annotations": {"nginx.ingress.kubernetes.io/use-regex": "true"}},
      "spec": {
        "ingressClassName": "nginx",
        "rules": [
          {"host": "denied.example.com", "http": {"paths": [{"path": "/b.*", "pathType": "ImplementationSpecific", "backend": {"service": {"name": "s", "port": {"number": 80}}}}]}}
        ]
      }
    }
  ]
}
JSON
)

  run env NGINX_GOTCHAS_NAMESPACES_JSON='["allowed"]' bash -c "source \"$ROOT_DIR/scripts/lib/nginx_gotchas.sh\"; nginx_gotchas_warnings_from_ingress_list" <<<"$ingress_list"
  [ "$status" -eq 0 ]

  run jq -r 'map(.host // "") | join("\n")' <<<"$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"allowed.example.com"* ]]
  [[ "$output" != *"denied.example.com"* ]]
}
