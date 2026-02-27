#!/usr/bin/env bash

set -euo pipefail

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
EOF
  exit 0
fi

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

    echo "Migration Triggered: $CM_NAMESPACE/$CM_NAME (DryRun: $DRY_RUN, Providers: $PROVIDERS, Selector: $NS_SELECTOR, MigrateEndpoints: $MIGRATE_ENDPOINTS, GatewayClass: ${GATEWAY_CLASS:-<default>})"

    # Gather namespaces based on selector
    TARGET_NAMESPACES=""
    if [ -n "$NS_SELECTOR" ]; then
        TARGET_NAMESPACES=$(kubectl get ns -l "$NS_SELECTOR" -o jsonpath='{.items[*].metadata.name}' || echo "")
        if [ -z "$TARGET_NAMESPACES" ]; then
            echo "No namespaces matched the selector $NS_SELECTOR. Exiting..."
            # Update status
            kubectl patch configmap "$CM_NAME" -n "$CM_NAMESPACE" --type merge -p "{\"data\": {\"error\": \"No matching namespaces\", \"lastRun\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}"
            continue
        fi
    fi

    COUNT=0
    ENDPOINT_COUNT=0
    APPLIED="false"
    ERROR_MSG="none"

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
        args=(print "--providers=$PROVIDERS")

        if [ -n "$ns" ]; then
            echo "Converting in namespace: $ns"
            args+=("--namespace=$ns")
        else
            echo "Converting cluster-wide"
        fi

        # Execute ingress2gateway
        OUT=$("$ingress2gateway_bin" "${args[@]}" 2>&1) || {
            echo "Error running ingress2gateway: $OUT"
            ERROR_MSG="generation_failed"
            return 1
        }

        # Override gatewayClassName if the trigger specifies a target class
        if [ -n "${GATEWAY_CLASS:-}" ]; then
            OUT=$(
                printf '%s\n' "$OUT" | while IFS= read -r line; do
                    if [[ "$line" == gatewayClassName:* ]]; then
                        printf 'gatewayClassName: %s\n' "$GATEWAY_CLASS"
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

    if [ -n "$TARGET_NAMESPACES" ]; then
        for namespace in $TARGET_NAMESPACES; do
            run_migration "$namespace" || break
            if [ "$MIGRATE_ENDPOINTS" = "true" ]; then
                migrate_endpoints "$namespace"
            fi
        done
    else
        run_migration ""
        if [ "$MIGRATE_ENDPOINTS" = "true" ]; then
            migrate_endpoints ""
        fi
    fi

    if [ "$DRY_RUN" == "false" ] && [ "$ERROR_MSG" == "none" ]; then
        APPLIED="true"
    fi

    # Patch Status back on the trigger ConfigMap
    echo "Updating status in ConfigMap: $CM_NAME"
    STATUS_PAYLOAD=$(jq -n \
      --arg count "$COUNT" \
      --arg epcount "$ENDPOINT_COUNT" \
      --arg applied "$APPLIED" \
      --arg error "$ERROR_MSG" \
      --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{data: {convertedResources: $count, migratedEndpoints: $epcount, applied: $applied, error: $error, lastRun: $date}}')
      
    kubectl patch configmap "$CM_NAME" -n "$CM_NAMESPACE" --type merge -p "$STATUS_PAYLOAD"
    echo "Migration processing complete for $CM_NAME."
  fi
done
