#!/usr/bin/env bash

set -euo pipefail

# Shared libraries — bootstrapped via common.sh.
# shellcheck source=scripts/lib/common.sh
if [[ -f /usr/local/lib/hooks/common.sh ]]; then
    source /usr/local/lib/hooks/common.sh
else
    source "$(dirname "$0")/lib/common.sh"
fi
source_lib status.sh
source_lib history.sh
source_lib provider.sh
source_lib nginx_gotchas.sh

# Flant shell-operator binding configuration
if [[ ${1:-} == "--config" ]] ; then
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
  jqFilter: '.metadata.annotations'
EOF
  exit 0
fi


preflight_nginx_gotchas() {
    local provider_flag
    if ! provider_flag=$(dispatch_provider "$PROVIDERS"); then
        return 0
    fi
    if [[ "$provider_flag" != "ingress-nginx" ]]; then
        return 0
    fi

    local ingress_list
    ingress_list=$(kubectl get ingress -A -o json 2>/dev/null || echo '{"items":[]}')

    local namespaces_json=""
    if [[ -n "${TARGET_NAMESPACES:-}" ]]; then
        namespaces_json=$(printf '%s' "$TARGET_NAMESPACES" | xargs -n1 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length>0))')
    fi

    local warnings_json
    if ! warnings_json=$(NGINX_GOTCHAS_NAMESPACES_JSON="$namespaces_json" nginx_gotchas_warnings_from_ingress_list <<<"$ingress_list" 2>/dev/null); then
        warnings_json="[]"
    fi

    NGINX_WARNINGS_COUNT=$(jq -r 'length' <<<"$warnings_json" 2>/dev/null || echo "0")
    if [[ "$NGINX_WARNINGS_COUNT" != "0" ]]; then
        NGINX_WARNINGS_TEXT=$(jq -r '.[0:20][] | "[" + .code + "] " + .message + (if .host then " host=" + .host else "" end) + (if .ingress then " ingress=" + .ingress else "" end) + (if .path then " path=" + .path else "" end)' <<<"$warnings_json" 2>/dev/null || true)
    fi
}

# Migration Execution Function
run_migration() {
    local ns=$1
    local ingress2gateway_bin="${INGRESS2GATEWAY_BIN:-ingress2gateway}"

    if ! command -v "$ingress2gateway_bin" >/dev/null 2>&1; then
        echo "Error: ingress2gateway not found. Set PATH or INGRESS2GATEWAY_BIN."
        ERROR_MSG="ingress2gateway_not_found"
        return 1
    fi

    local -a args
    local provider_flag
    if ! provider_flag=$(dispatch_provider "$PROVIDERS"); then
      echo "Error: unsupported provider '$PROVIDERS'"
      ERROR_MSG="unknown_provider"
      return 1
    fi
    args=(print "--providers=${provider_flag}")

    if [ -n "$ns" ]; then
        echo "Converting in namespace: $ns"
        args+=("--namespace=$ns")
    else
        echo "Converting cluster-wide"
    fi

    # Execute ingress2gateway.
    # Capture stdout (YAML) and stderr (warnings) separately so that any
    # informational/warning lines printed to stderr do NOT corrupt the YAML
    # that is later piped to `kubectl apply -f -`.
    local _i2g_err
    _i2g_err=$(mktemp)
    # Guarantee cleanup even if set -e triggers an unexpected early exit between
    # mktemp and the explicit rm calls below.  RETURN fires on every exit path
    # of this function; rm -f is a no-op if the file was already removed.
    # shellcheck disable=SC2064
    trap "rm -f '${_i2g_err}'" RETURN
    OUT=$("$ingress2gateway_bin" "${args[@]}" 2>"$_i2g_err") || {
        echo "Error running ingress2gateway: $(cat "$_i2g_err")"
        rm -f "$_i2g_err"
        ERROR_MSG="generation_failed"
        return 1
    }
    if [[ -s "$_i2g_err" ]]; then
        local _i2g_warnings
        _i2g_warnings=$(cat "$_i2g_err")
        echo "ingress2gateway warnings: ${_i2g_warnings}"
        # Surface ingress2gateway stderr (annotation-drop notices, unsupported
        # field warnings, etc.) in the migration report alongside NGINX preflight
        # output so all conversion warnings appear together in the status ConfigMap.
        if [[ -n "${NGINX_WARNINGS_TEXT}" ]]; then
            NGINX_WARNINGS_TEXT+=$'\n'"${_i2g_warnings}"
        else
            NGINX_WARNINGS_TEXT="${_i2g_warnings}"
        fi
    fi
    rm -f "$_i2g_err"

            # Hash the generated manifests for history tracking
            local out_hash
            out_hash=$(printf '%s' "$OUT" | history_sha256_stdin)
            if [[ -n "$out_hash" ]]; then
                MANIFEST_HASH_INPUT+="$out_hash\n"
            fi

    # Override gatewayClassName if the trigger specifies a target class.
    # Note: ingress2gateway prints YAML with indentation (e.g. "  gatewayClassName: nginx").
    # Preserve indentation when overriding.
    if [ -n "${GATEWAY_CLASS:-}" ]; then
        OUT=$(
            printf '%s\n' "$OUT" | while IFS= read -r line; do
                if [[ "$line" =~ ^([[:space:]]*)gatewayClassName:[[:space:]]*.*$ ]]; then
                    indent="${BASH_REMATCH[1]}"
                    printf '%sgatewayClassName: %s\n' "$indent" "$GATEWAY_CLASS"
                else
                    printf '%s\n' "$line"
                fi
            done
        )
        echo "  gatewayClassName overridden → $GATEWAY_CLASS"
    fi

    # Count the generated routes
    local C
    C=$(echo "$OUT" | grep -c "kind: HTTPRoute" || true)
    COUNT=$((COUNT + C))

    local G
    G=$(echo "$OUT" | grep -c "kind: Gateway" || true)
    GW_COUNT=$((GW_COUNT + G))

    if [ "$C" -gt 0 ]; then
        if [ "$DRY_RUN" == "false" ]; then
            echo "Applying $C HTTPRoutes..."
            if [ -n "$ns" ]; then
                if ! echo "$OUT" | kubectl apply -n "$ns" -f -; then
                    ERROR_MSG="apply_failed_ns_$ns"
                    return 1
                fi
            else
                if ! echo "$OUT" | kubectl apply -f -; then
                    ERROR_MSG="apply_failed_cluster"
                    return 1
                fi
            fi
        else
            echo "Dry run enabled. Skipping apply. Generated $C HTTPRoutes:"
            echo "$OUT" | head -n 30
            echo "..."
        fi
    else
        echo "No HTTPRoutes generated for providers: $PROVIDERS."
    fi
    return 0
}

# Endpoint migration: converts manually-managed v1 Endpoints (deprecated in k8s 1.33+)
# to discovery.k8s.io/v1 EndpointSlice.
#
# Skips:
#   - The built-in 'kubernetes' endpoint
#   - Endpoints that have ownerReferences (controller-managed)
#   - Endpoints whose Service has spec.selector (the EndpointSlice controller
#     already manages slices for those automatically)
migrate_endpoints() {
    local ns=$1
    echo "Checking for deprecated v1 Endpoints in namespace: ${ns:-<cluster-wide>}"

    local ep_list kube_ns_args
    if [ -n "$ns" ]; then
        kube_ns_args=(-n "$ns")
    else
        kube_ns_args=(-A)
    fi

    # Use 2>/dev/null: kubectl 1.33+ prints a deprecation warning for v1 Endpoints
    # to stderr; captured via 2>&1 it would corrupt the JSON we parse with jq.
    if ! ep_list=$(kubectl get endpoints "${kube_ns_args[@]}" -o json 2>/dev/null); then
        echo "  Warning: Could not list Endpoints"
        return 0
    fi

    local total
    total=$(echo "$ep_list" | jq '.items | length')
    if [ "$total" -eq 0 ]; then
        echo "  No Endpoints found."
        return 0
    fi

    local converted=0
    while IFS= read -r ep_json; do
        local ep_name ep_ns
        ep_name=$(echo "$ep_json" | jq -r '.metadata.name')
        ep_ns=$(echo "$ep_json" | jq -r '.metadata.namespace')

        # Always skip the kubernetes master endpoint
        [ "$ep_name" = "kubernetes" ] && continue

        # Skip controller-managed endpoints (ownerReferences present)
        local owner_count
        owner_count=$(echo "$ep_json" | jq '(.metadata.ownerReferences // []) | length')
        if [ "$owner_count" -gt 0 ]; then
            echo "  Skipping $ep_ns/$ep_name (controller-managed via ownerReferences)"
            continue
        fi

        # Skip if the corresponding Service has spec.selector — EndpointSlice
        # controller auto-creates slices for selector-based Services.
        local svc_has_selector
        svc_has_selector=$(kubectl get service "$ep_name" -n "$ep_ns" -o json 2>/dev/null \
            | jq '(.spec.selector // {} | length) > 0' || echo "false")
        if [ "$svc_has_selector" = "true" ]; then
            echo "  Skipping $ep_ns/$ep_name (Service has pod selector — EndpointSlice auto-managed)"
            continue
        fi

        local subset_count
        subset_count=$(echo "$ep_json" | jq '(.subsets // []) | length')
        if [ "$subset_count" -eq 0 ]; then
            echo "  Skipping $ep_ns/$ep_name: no subsets defined"
            continue
        fi

        echo "  Converting Endpoints $ep_ns/$ep_name ($subset_count subset(s)) → EndpointSlice"

        # Each subset becomes one EndpointSlice (subsets model different port sets).
        local subset_idx=0
        while [ "$subset_idx" -lt "$subset_count" ]; do
            local slice_name
            if [ "$subset_count" -gt 1 ]; then
                slice_name="${ep_name}-eps-${subset_idx}"
            else
                slice_name="${ep_name}-eps"
            fi

            local es_json
            es_json=$(echo "$ep_json" | jq \
                --argjson idx "$subset_idx" \
                --arg slicename "$slice_name" '
                .metadata.name as $svcname |
                .metadata.namespace as $ns |
                (.subsets // [])[$idx] as $subset |
                {
                    apiVersion: "discovery.k8s.io/v1",
                    kind: "EndpointSlice",
                    metadata: {
                        name: $slicename,
                        namespace: $ns,
                        labels: {
                            "kubernetes.io/service-name": $svcname
                        },
                        annotations: {
                            "ingress-migration.flant.com/migrated-from": ("v1/Endpoints/" + $svcname)
                        }
                    },
                    addressType: "IPv4",
                    endpoints: [
                        ($subset.addresses // [])[] |
                        { addresses: [.ip], conditions: { ready: true } }
                        + if .hostname then { hostname: .hostname } else {} end
                        + if .nodeName  then { nodeName:  .nodeName  } else {} end
                    ],
                    ports: [
                        ($subset.ports // [])[] |
                        { protocol: (.protocol // "TCP"), port: .port }
                        + if ((.name // "") != "") then { name: .name } else {} end
                    ]
                }
            ')

            if [ "$DRY_RUN" = "true" ]; then
                echo "  [DRY RUN] Would create EndpointSlice '$slice_name' in $ep_ns:"
                echo "$es_json" | jq .
                echo "---"
            else
                echo "  Applying EndpointSlice '$slice_name' in $ep_ns..."
                if ! echo "$es_json" | kubectl apply -f -; then
                    ERROR_MSG="endpoint_apply_failed_${ep_ns}_${ep_name}"
                    echo "  Error applying EndpointSlice for $ep_name"
                fi
            fi

            subset_idx=$((subset_idx + 1))
        done

        converted=$((converted + 1))
    done < <(echo "$ep_list" | jq -c '.items[]')

    echo "  Endpoints summary ($ns): $converted converted to EndpointSlice(s)"
    ENDPOINT_COUNT=$((ENDPOINT_COUNT + converted))
}

# ---------------------------------------------------------------------------
# Provider-specific post-processing hooks (run after ingress2gateway conversion)
# ---------------------------------------------------------------------------

# generate_kong_plugins_from_nginx_annotations
#   Walks original Ingress objects and emits KongPlugin CRs for annotations
#   that ingress2gateway does not translate automatically.
#
# Future mappings to implement:
#   nginx.ingress.kubernetes.io/limit-rps         → KongPlugin (rate-limiting)
#   nginx.ingress.kubernetes.io/limit-connections → KongPlugin (rate-limiting)
#   nginx.ingress.kubernetes.io/auth-url          → KongPlugin (oidc/oauth2)
#   nginx.ingress.kubernetes.io/proxy-body-size   → KongPlugin (request-size-limiting)
#   nginx.ingress.kubernetes.io/ssl-redirect      → HTTPRoute redirect filter (no KongPlugin needed)
#   konghq.com/plugins                            → preserve KongPlugin refs on generated HTTPRoute
generate_kong_plugins_from_nginx_annotations() {
    local ns=$1
    # TODO: implement annotation-to-KongPlugin translation.
    echo "TODO: map nginx.ingress.kubernetes.io/limit-rps → KongPlugin (ns=${ns:-<cluster-wide>})"
}

# generate_apisix_plugins_from_annotations
#   Walks original Ingress objects and emits APISix-native CRs for annotations
#   that ingress2gateway does not translate automatically.
#
# Future mappings to implement:
#   k8s.apisix.apache.org/plugin-config-name  → ApisixPluginConfig ref on generated ApisixRoute
#   k8s.apisix.apache.org/blocklist-source-range → ApisixPlugin (ip-restriction)
#   k8s.apisix.apache.org/allowlist-source-range → ApisixPlugin (ip-restriction)
#   k8s.apisix.apache.org/upstream-scheme       → ApisixUpstream upstream scheme override
#   k8s.apisix.apache.org/http-to-https         → HTTPRoute redirect filter (no ApisixPlugin needed)
#   nginx.ingress.kubernetes.io/limit-rps        → ApisixPlugin (limit-count) when provider=apisix
generate_apisix_plugins_from_annotations() {
    local ns=$1
    # TODO: implement annotation-to-ApisixPlugin/ApisixPluginConfig translation.
    echo "TODO: map k8s.apisix.apache.org/plugin-config-name → ApisixPluginConfig (ns=${ns:-<cluster-wide>})"
}

# generate_kgateway_policies_from_annotations
#   Walks original Ingress objects and emits kgateway policy-attachment CRs for
#   annotations that ingress2gateway does not translate automatically.
#
# Future mappings to implement:
#   nginx.ingress.kubernetes.io/limit-rps            → RouteOption (rateLimit policy)
#   nginx.ingress.kubernetes.io/limit-connections    → RouteOption (connectionLimit policy)
#   nginx.ingress.kubernetes.io/auth-url             → RouteOption (extAuth policy)
#   nginx.ingress.kubernetes.io/proxy-body-size      → RouteOption (bufferPolicy)
#   nginx.ingress.kubernetes.io/configuration-snippet → RouteOption (transformations)
#   nginx.ingress.kubernetes.io/rewrite-target       → RouteOption (transformations) or HTTPRoute pathRewrite
#   nginx.ingress.kubernetes.io/ssl-redirect         → HTTPRoute redirect filter (no RouteOption needed)
generate_kgateway_policies_from_annotations() {
    local ns=$1
    # TODO: implement annotation-to-RouteOption/VirtualHostOption translation.
    echo "TODO: map nginx.ingress.kubernetes.io/limit-rps → kgateway RouteOption (ns=${ns:-<cluster-wide>})"
}

# generate_gateway_native_extensions_from_nginx_annotations
#   Walks original Ingress objects and emits standard Gateway API resources
#   (HTTPRoute filter patches, BackendLBPolicy, BackendTLSPolicy) for nginx
#   annotations that ingress2gateway does not translate automatically.
#
# Future mappings to implement:
#   nginx.ingress.kubernetes.io/ssl-redirect        → HTTPRoute redirect filter (code 301/308)
#   nginx.ingress.kubernetes.io/permanent-redirect  → HTTPRoute redirect filter (code 301)
#   nginx.ingress.kubernetes.io/temporal-redirect   → HTTPRoute redirect filter (code 302)
#   nginx.ingress.kubernetes.io/rewrite-target      → HTTPRoute URLRewrite filter
#   nginx.ingress.kubernetes.io/use-regex           → HTTPRoute path RegularExpression match
#   nginx.ingress.kubernetes.io/enable-cors         → HTTPRoute ResponseHeaderModifier filter (experimental)
#   nginx.ingress.kubernetes.io/cors-allow-origin   → HTTPRoute ResponseHeaderModifier filter (experimental)
#   nginx.ingress.kubernetes.io/proxy-read-timeout  → BackendLBPolicy timeout (experimental)
#   nginx.ingress.kubernetes.io/proxy-send-timeout  → BackendLBPolicy timeout (experimental)
#   nginx.ingress.kubernetes.io/proxy-body-size     → no standard GA equivalent yet
generate_gateway_native_extensions_from_nginx_annotations() {
    local ns=$1
    # TODO: implement annotation-to-HTTPRoute-filter / BackendLBPolicy translation.
    echo "TODO: map nginx annotations → native Gateway API HTTPRoute filters (ns=${ns:-<cluster-wide>})"
}

CONTEXT_FILE="$BINDING_CONTEXT_PATH"
echo "Processing hook context from $CONTEXT_FILE"

# Parse the Flant shell-operator event context payload
jq -c '.[]' "$CONTEXT_FILE" | while read -r event; do
  EVENT_TYPE=$(echo "$event" | jq -r '.type')
  if [[ "$EVENT_TYPE" == "Synchronization" ]] || [[ "$EVENT_TYPE" == "Event" ]]; then
        CM_NAME=$(echo "$event" | jq -r '.object.metadata.name // empty')
        CM_NAMESPACE=$(echo "$event" | jq -r '.object.metadata.namespace // empty')

        # Defensive: in some edge-cases shell-operator can produce events without an object.
        # Avoid retry loops by skipping those payloads.
        if [[ -z "$CM_NAME" || -z "$CM_NAMESPACE" ]]; then
            echo "Skipping event without ConfigMap object (type=$EVENT_TYPE)"
            continue
        fi

    # Read annotations configured by the user
    PROVIDERS=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/providers"] // "ingress-nginx"')
    DRY_RUN=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/dry-run"] // "true"')
    NS_SELECTOR=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/namespace-selector"] // ""')
    MIGRATE_ENDPOINTS=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/migrate-endpoints"] // "false"')
    GATEWAY_CLASS=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/gateway-class"] // ""')

        # History configuration (enabled by default)
        HISTORY_ENABLED=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/history-enabled"] // "true"')
        HISTORY_CM=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/history-configmap"] // "ingress-migration-history"')
        HISTORY_MAX=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/history-max-entries"] // "100"')
        INITIATOR=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/initiator"] // ""')
        _cluster_id_annotation=$(echo "$event" | jq -r '.object.metadata.annotations["ingress-migration.flant.com/cluster-id"] // ""')
        CLUSTER_ID=$(resolve_cluster_id "$_cluster_id_annotation")

    echo "Migration Triggered: $CM_NAMESPACE/$CM_NAME (DryRun: $DRY_RUN, Providers: $PROVIDERS, Selector: $NS_SELECTOR, MigrateEndpoints: $MIGRATE_ENDPOINTS, GatewayClass: ${GATEWAY_CLASS:-<default>})"

    # Gather namespaces based on selector
    TARGET_NAMESPACES=""
    if [ -n "$NS_SELECTOR" ]; then
        TARGET_NAMESPACES=$(kubectl get ns -l "$NS_SELECTOR" -o jsonpath='{.items[*].metadata.name}' || echo "")
        if [ -z "$TARGET_NAMESPACES" ]; then
            echo "No namespaces matched the selector $NS_SELECTOR. Exiting..."
            # Update status
            patch_status "$CM_NAME" "$CM_NAMESPACE" \
              "{\"data\": {\"error\": \"No matching namespaces\", \"lastRun\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
            continue
        fi
    fi

    COUNT=0
    GW_COUNT=0
    ENDPOINT_COUNT=0
    APPLIED="false"
    ERROR_MSG="none"
    NGINX_WARNINGS_COUNT="0"
    NGINX_WARNINGS_TEXT=""
    BEFORE_INGRESS_COUNT=0
    BEFORE_INGRESS_SAMPLE=""
    NS_LIST=""
    MANIFEST_HASH_INPUT=""

    if [ -n "$TARGET_NAMESPACES" ]; then
        preflight_nginx_gotchas || true
        for namespace in $TARGET_NAMESPACES; do
            NS_LIST+="$namespace "
            # Snapshot existing ingresses (best-effort, bounded sample)
            local_ing_count=$(kubectl get ingress -n "$namespace" -o name 2>/dev/null | wc -l | tr -d ' ' || echo "0")
            BEFORE_INGRESS_COUNT=$((BEFORE_INGRESS_COUNT + local_ing_count))
            if [[ $(printf '%s' "$BEFORE_INGRESS_SAMPLE" | wc -l) -lt 20 ]]; then
              BEFORE_INGRESS_SAMPLE+=$(kubectl get ingress -n "$namespace" -o name 2>/dev/null | head -n 5 | sed "s|^|$namespace/|" || true)
              BEFORE_INGRESS_SAMPLE+="\n"
            fi
            run_migration "$namespace" || break
            # Provider-specific post-processing: generate supplemental resources
            # that ingress2gateway does not produce (e.g. KongPlugin CRs).
            if [[ "$PROVIDERS" == kong* ]]; then
                generate_kong_plugins_from_nginx_annotations "$namespace"
            elif [[ "$PROVIDERS" == "apisix" ]]; then
                generate_apisix_plugins_from_annotations "$namespace"
            elif [[ "$PROVIDERS" == kgateway* ]]; then
                generate_kgateway_policies_from_annotations "$namespace"
            elif [[ "$PROVIDERS" == "ingress-nginx" ]]; then
                generate_gateway_native_extensions_from_nginx_annotations "$namespace"
            fi
            if [ "$MIGRATE_ENDPOINTS" = "true" ]; then
                migrate_endpoints "$namespace"
            fi
        done
    else
        NS_LIST+="<cluster-wide> "
        preflight_nginx_gotchas || true
        local_ing_count=$(kubectl get ingress -A -o name 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        BEFORE_INGRESS_COUNT=$((BEFORE_INGRESS_COUNT + local_ing_count))
        BEFORE_INGRESS_SAMPLE=$(kubectl get ingress -A -o name 2>/dev/null | head -n 10 || true)
        run_migration ""
        # Provider-specific post-processing (cluster-wide).
        if [[ "$PROVIDERS" == kong* ]]; then
            generate_kong_plugins_from_nginx_annotations ""
        elif [[ "$PROVIDERS" == "apisix" ]]; then
            generate_apisix_plugins_from_annotations ""
        elif [[ "$PROVIDERS" == kgateway* ]]; then
            generate_kgateway_policies_from_annotations ""
        elif [[ "$PROVIDERS" == "ingress-nginx" ]]; then
            generate_gateway_native_extensions_from_nginx_annotations ""
        fi
        if [ "$MIGRATE_ENDPOINTS" = "true" ]; then
            migrate_endpoints ""
        fi
    fi

    if [ "$DRY_RUN" == "false" ] && [ "$ERROR_MSG" == "none" ]; then
        APPLIED="true"
    fi

    # Compute manifest hash and normalise array fields.
    # Done here (not inside the history block) so the report can include them too.
    manifest_hash=""
    if [[ -n "$MANIFEST_HASH_INPUT" ]]; then
        manifest_hash=$(printf '%b' "$MANIFEST_HASH_INPUT" | history_sha256_stdin)
    fi
    ingress_sample_json=$(printf '%b' "$BEFORE_INGRESS_SAMPLE" | sed '/^\s*$/d' | head -n 20 | jq -R -s -c 'split("\n") | map(select(length>0))')
    ns_list_json=$(printf '%s' "$NS_LIST" | xargs -n1 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length>0))')

    # Build the structured event record once — reused for the report, the status
    # patch, and the history append.
    entry=$(jq -n -c \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg action "migrate" \
        --arg clusterId "$CLUSTER_ID" \
        --arg initiator "$INITIATOR" \
        --arg triggerNs "$CM_NAMESPACE" \
        --arg triggerName "$CM_NAME" \
        --arg providers "$PROVIDERS" \
        --arg dryRun "$DRY_RUN" \
        --arg nsSelector "$NS_SELECTOR" \
        --arg migrateEndpoints "$MIGRATE_ENDPOINTS" \
        --arg gatewayClass "$GATEWAY_CLASS" \
        --arg convertedResources "$COUNT" \
        --arg convertedGateways "$GW_COUNT" \
        --arg migratedEndpoints "$ENDPOINT_COUNT" \
        --arg applied "$APPLIED" \
        --arg error "$ERROR_MSG" \
        --arg nginxWarningsCount "$NGINX_WARNINGS_COUNT" \
        --arg nginxWarnings "$NGINX_WARNINGS_TEXT" \
        --arg manifestHash "$manifest_hash" \
        --arg beforeIngressCount "$BEFORE_INGRESS_COUNT" \
        --argjson beforeIngressSample "$ingress_sample_json" \
        --argjson namespaces "$ns_list_json" \
        '{ts:$ts, action:$action, clusterId:$clusterId, initiator:$initiator,
            trigger:{namespace:$triggerNs, name:$triggerName},
            config:{providers:$providers, dryRun:$dryRun, namespaceSelector:$nsSelector, migrateEndpoints:$migrateEndpoints, gatewayClass:$gatewayClass},
            before:{ingressCount:$beforeIngressCount, ingressSample:$beforeIngressSample},
            after:{httpRoutes:$convertedResources, gateways:$convertedGateways, endpointSlicesConverted:$migratedEndpoints, applied:$applied, error:$error, manifestHash:$manifestHash, nginxPreflightWarningsCount:$nginxWarningsCount, nginxPreflightWarnings:$nginxWarnings},
            namespaces:$namespaces
        }')

    # Render the human-readable before/after report.
    REPORT_TEXT=$(build_migration_report "$entry")

    # Patch status (includes the formatted report) back onto the trigger ConfigMap.
    echo "Updating status in ConfigMap: $CM_NAME"
    STATUS_PAYLOAD=$(jq -n \
      --arg count        "$COUNT" \
      --arg gwcount      "$GW_COUNT" \
      --arg epcount      "$ENDPOINT_COUNT" \
      --arg applied      "$APPLIED" \
      --arg error        "$ERROR_MSG" \
      --arg warnings     "$NGINX_WARNINGS_COUNT" \
      --arg warningstext "$NGINX_WARNINGS_TEXT" \
      --arg date         "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg report       "$REPORT_TEXT" \
      '{data: {
          convertedResources:          $count,
          convertedGateways:           $gwcount,
          migratedEndpoints:           $epcount,
          applied:                     $applied,
          error:                       $error,
          lastRun:                     $date,
          nginxPreflightWarningsCount: $warnings,
          nginxPreflightWarnings:      $warningstext,
          report:                      $report
      }}')

    patch_status "$CM_NAME" "$CM_NAMESPACE" "$STATUS_PAYLOAD"

    # Append history entry (best-effort).
    if [[ "$HISTORY_ENABLED" == "true" ]]; then
        cluster_key=$(history_sanitize_key "$CLUSTER_ID")
        data_key="history.${cluster_key}.jsonl"
        history_append_jsonl "$CM_NAMESPACE" "$HISTORY_CM" "$data_key" "$entry" "$HISTORY_MAX" || true
    fi
    echo "Migration processing complete for $CM_NAME."
  fi
done
