#!/usr/bin/env bash

set -euo pipefail

# nginx_gotchas.sh
#
# Lightweight preflight warnings for common Ingress-NGINX behavioral gotchas
# that can bite during migration to Gateway API implementations.
#
# Input: a Kubernetes IngressList JSON on stdin.
# Output: a JSON array of warning objects on stdout.
#
# Optional env:
#   NGINX_GOTCHAS_NAMESPACES_JSON: JSON array of namespaces to include.

nginx_gotchas_warnings_from_ingress_list() {
  local namespaces_json
  namespaces_json=${NGINX_GOTCHAS_NAMESPACES_JSON:-}

  jq -c --argjson nsAllowlist "${namespaces_json:-null}" '
    def truthy: . == true or . == "true" or . == "True";

    def has_nginx_class($ing):
      (($ing.spec.ingressClassName // "") == "nginx")
      or (($ing.metadata.annotations["kubernetes.io/ingress.class"] // "") == "nginx");

    def has_nginx_annotations($ing):
      ($ing.metadata.annotations // {} | to_entries | any(.key | startswith("nginx.ingress.kubernetes.io/")));

    def ns_allowed($ing):
      if $nsAllowlist == null then true
      else ($nsAllowlist | index(($ing.metadata.namespace // ""))) != null
      end;

    def relevant($ing):
      ns_allowed($ing) and (has_nginx_class($ing) or has_nginx_annotations($ing));

    def ingress_id($ing):
      ($ing.metadata.namespace // "") + "/" + ($ing.metadata.name // "");

    def hosts($ing):
      [($ing.spec.rules // [])[]? | .host?] | map(select(. != null and . != "")) | unique;

    def paths_for_host($ing; $host):
      [($ing.spec.rules // [])[]? | select((.host // "") == $host) | (.http.paths // [])[]? |
        {
          host: $host,
          path: (.path // ""),
          pathType: (.pathType // "")
        }
      ];

    def paths($ing):
      [hosts($ing)[] as $h | paths_for_host($ing; $h)[]];

    def use_regex($ing):
      ($ing.metadata.annotations["nginx.ingress.kubernetes.io/use-regex"] // "false" | truthy);

    def rewrite_target($ing):
      (($ing.metadata.annotations // {}) | has("nginx.ingress.kubernetes.io/rewrite-target"));

    def regex_enabled($ing):
      use_regex($ing) or rewrite_target($ing);

    def warning($code; $severity; $message; $host; $ingress; $path; $pathType):
      {
        code: $code,
        severity: $severity,
        message: $message
      }
      + (if $host != null then {host: $host} else {} end)
      + (if $ingress != null then {ingress: $ingress} else {} end)
      + (if $path != null then {path: $path} else {} end)
      + (if $pathType != null then {pathType: $pathType} else {} end);

    def upper_in_path($p):
      ($p | test("[A-Z]"));

    def trailing_slash_path($p):
      ($p | length > 1) and ($p | endswith("/"));

    # Normalize ingresses and compute per-host aggregates.
    (.items // [])
    | map(select(relevant(.)))
    | map({
        id: ingress_id(.),
        annotations: (.metadata.annotations // {}),
        regexEnabled: regex_enabled(.),
        useRegex: use_regex(.),
        rewriteTarget: rewrite_target(.),
        hosts: hosts(.),
        paths: paths(.)
      }) as $ings

    | (
        $ings
        | map(.hosts[]?)
        | unique
      ) as $allHosts

    | (
        $allHosts
        | map({
            host: .,
            ingressCount: ($ings | map(select(.hosts | index(.) != null)) | length),
            regexEnabled: ($ings | any(select(.hosts | index(.) != null) | .regexEnabled))
          })
      ) as $hostAgg

    | (
        # 1) Regex semantics mismatch (prefix-based and case-insensitive).
        ($hostAgg
          | map(select(.regexEnabled))
          | map(warning(
              "NGINX_REGEX_PREFIX_CASE_INSENSITIVE";
              "warning";
              "Ingress-NGINX regex path matching is prefix-based and case-insensitive; your Gateway API controller may treat regex differently. Review regex paths carefully.";
              .host;
              null;
              null;
              null
            ))
        )

        +

        # 2) use-regex/rewrite-target apply host-wide across ingresses.
        ($hostAgg
          | map(select(.regexEnabled and .ingressCount > 1))
          | map(warning(
              "NGINX_REGEX_HOST_WIDE";
              "warning";
              "Ingress-NGINX enables regex semantics for all paths of the same host across all Ingresses when any Ingress for that host uses use-regex or rewrite-target.";
              .host;
              null;
              null;
              null
            ))
        )

        +

        # 3) rewrite-target implies regex behavior.
        ($ings
          | map(select(.rewriteTarget))
          | map(warning(
              "NGINX_REWRITE_TARGET_IMPLIES_REGEX";
              "warning";
              "Ingress-NGINX rewrite-target implies regex-style path matching for the host; this can change how other paths are interpreted.";
              (if (.hosts | length) > 0 then (.hosts[0]) else null end);
              .id;
              null;
              null
            ))
        )

        +

        # 4) Trailing-slash redirect behavior.
        ($ings
          | map(select(.paths | length > 0))
          | map(. as $ing |
              ($ing.paths
                | map(select((.pathType == "Exact" or .pathType == "Prefix") and trailing_slash_path(.path)))
                | map(warning(
                    "NGINX_TRAILING_SLASH_REDIRECT";
                    "warning";
                    "Ingress-NGINX may redirect when paths end with a trailing slash. Verify redirect behavior after migrating.";
                    .host;
                    $ing.id;
                    .path;
                    .pathType
                  ))
              )
            )
          | add
        )

        +

        # Extra: when regex is enabled for a host, Exact/Prefix paths that contain uppercase characters
        # can become effectively case-insensitive under Ingress-NGINX behavior.
        ($hostAgg
          | map(select(.regexEnabled))
          | map(.host) as $regexHosts
          | (
              $ings
              | map(select(.regexEnabled))
              | map(. as $ing |
                  ($ing.paths
                    | map(select((.pathType == "Exact" or .pathType == "Prefix") and (upper_in_path(.path))))
                    | map(warning(
                        "NGINX_REGEX_MAKES_PATH_CASE_INSENSITIVE";
                        "info";
                        "This path contains uppercase characters, but Ingress-NGINX regex matching is case-insensitive when regex is enabled for the host. Ensure your Gateway API behavior matches expectations.";
                        .host;
                        $ing.id;
                        .path;
                        .pathType
                      ))
                  )
                )
              | add
            )
        )
      )
    | map(select(. != null))
    | unique
  '
}
