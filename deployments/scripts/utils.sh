# Util: Check if a port is in use
is_port_in_use() {
    local port="$1"
    if lsof -i :"$port" -sTCP:LISTEN &>/dev/null; then
        return 0
    fi
    return 1
}

# Util: Check all required ports for k3d cluster are available
check_required_ports() {
    local ports=(
        "6550:Kubernetes API"
        "8080:Control Plane HTTP"
        "8443:Control Plane HTTPS"
        "22893:API Platform Gateway HTTP"
        "22894:API Platform Gateway HTTPS"
        "19080:Data Plane HTTP"
        "19443:Data Plane HTTPS"
        "10081:Argo Workflows UI"
        "10082:Container Registry"
        "11080:Observability HTTP"
        "11085:OpenSearch HTTPS"
        "11081:OpenSearch Dashboard"
        "11082:OpenSearch API"
    )

    local blocked_ports=()
    echo "🔍 Checking port availability..."

    for port_info in "${ports[@]}"; do
        local port="${port_info%%:*}"
        local desc="${port_info#*:}"
        if is_port_in_use "$port"; then
            blocked_ports+=("$port ($desc)")
        fi
    done

    if [ ${#blocked_ports[@]} -gt 0 ]; then
        echo "❌ The following ports are already in use:"
        for blocked in "${blocked_ports[@]}"; do
            echo "   - $blocked"
        done
        echo ""
        echo "Please free these ports before creating the cluster."
        echo "You can find processes using a port with: lsof -i :<port>"
        return 1
    fi

    echo "✅ All required ports are available"
    return 0
}

# Util: Get minimum required version for a command (bash 3.x compatible)
get_min_version() {
    case "$1" in
        docker)  echo "26" ;;
        k3d)     echo "5.8" ;;
        kubectl) echo "1.32" ;;
        helm)    echo "3.12" ;;
        *)       echo "" ;;
    esac
}

# Util: check version is greater than or equal by comparing two version strings (returns 0 if $1 >= $2)
version_gte() {
    local ver1="$1"
    local ver2="$2"
    # Use sort -V for version comparison
    [ "$(printf '%s\n%s' "$ver2" "$ver1" | sort -V | head -n1)" = "$ver2" ]
}

# Util: Extract version number from command output
get_version() {
    "$1" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1
}

# Util: Check if a command is installed and version is compatible
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        echo "❌ $cmd is not installed. Please install it first:"
        echo "   brew install $cmd"
        exit 1
    fi

    # Check version compatibility
    local min_version
    min_version=$(get_min_version "$cmd")
    if [ -n "$min_version" ]; then
        local current_version
        current_version=$(get_version "$cmd")

        if [ -n "$current_version" ]; then
            if ! version_gte "$current_version" "$min_version"; then
                echo "⚠️  Warning: $cmd version $current_version is below minimum required v$min_version+"
            fi
        fi
    fi
}

# Util: Install helm chart only if not already installed
helm_install_if_not_exists() {
    local release_name="$1"
    local namespace="$2"
    local chart="$3"
    shift 3
    local extra_args=("$@")

    if helm status "$release_name" -n "$namespace" --kube-context "${CLUSTER_CONTEXT}" &>/dev/null; then
        echo "⏭️  $release_name already installed in $namespace, skipping..."
        return 0
    fi

    echo "📦 Installing $release_name..."
    helm install "$release_name" "$chart" \
        --namespace "$namespace" \
        --create-namespace \
        --kube-context "${CLUSTER_CONTEXT}" \
        "${extra_args[@]}"
    echo "✅ $release_name installed successfully"
}

# Util: Generate machine IDs for k3d nodes (required for Fluent Bit observability)
generate_machine_ids() {
    local cluster_name="$1"
    echo "🆔 Generating Machine IDs for Fluent Bit observability..."

    # Extract node names from k3d node list JSON output
    local json_output
    json_output=$(k3d node list -o json)

    local nodes
    nodes=$(echo "$json_output" \
        | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed 's/"name"[[:space:]]*:[[:space:]]*"//;s/"$//' \
        | grep "^k3d-${cluster_name}-")

    if [[ -z "$nodes" ]]; then
        echo "⚠️  Could not retrieve node list"
        return 1
    fi

    for node in $nodes; do
        echo "   🔧 Generating machine ID for ${node}..."
        if docker exec "${node}" sh -c "cat /proc/sys/kernel/random/uuid | tr -d '-' > /etc/machine-id" 2>/dev/null; then
            echo "   ✅ Machine ID generated for ${node}"
        else
            echo "   ⚠️  Could not generate Machine ID for ${node} (it may not be running)"
        fi
    done

    echo "✅ Machine ID generation complete"
}

# Util: Make host.k3d.internal / host.docker.internal resolve inside pods
#
# k3d injects these aliases only into the nodes' /etc/hosts, not into pod DNS,
# so in-cluster clients (gateway controller, observability, helm bootstrap
# Jobs) cannot reach the host through them. We add both to the CoreDNS
# NodeHosts file, which the k3s node controller preserves across restarts.
#
# This also closes a setup race: NodeHosts is NOT shipped in the coredns Addon
# manifest — k3s populates it asynchronously after a server (re)start. The
# coredns Deployment mounts NodeHosts as a *non-optional* configmap key, so
# until k3s writes it a freshly restarted CoreDNS pod cannot mount and the
# rollout times out. Writing the key here guarantees it exists before the
# subsequent `kubectl rollout restart deployment/coredns`.
ensure_coredns_host_aliases() {
    echo "🔧 Ensuring host.k3d.internal resolves in-cluster..."

    local host_ip
    host_ip=$(docker network inspect "k3d-${CLUSTER_NAME}" \
        --format '{{ (index .IPAM.Config 0).Gateway }}' 2>/dev/null)
    # Podman exposes the gateway under subnets[0].gateway, not IPAM.Config
    if [[ -z "$host_ip" ]]; then
        host_ip=$(podman network inspect "k3d-${CLUSTER_NAME}" 2>/dev/null \
            | python3 -c "import json,sys; d=json.load(sys.stdin); n=d[0] if isinstance(d,list) else d; print(n.get('subnets',[{}])[0].get('gateway',''))" 2>/dev/null)
    fi
    if [[ -z "$host_ip" ]]; then
        echo "❌ Could not determine k3d host gateway IP for network k3d-${CLUSTER_NAME}"
        return 1
    fi

    # Node entries already written by k3s's node controller. Empty during the
    # post-restart race window — that is fine: k3s re-adds them later and keeps
    # the alias lines we append.
    local existing
    existing=$(kubectl get configmap coredns -n kube-system \
        --context "${CLUSTER_CONTEXT}" -o jsonpath='{.data.NodeHosts}' 2>/dev/null)

    # Drop any alias lines from a previous run so re-runs stay idempotent.
    # host.docker.internal is managed separately by ensure_agent_manager_host_service()
    # (maps to the agent-manager-host Service ClusterIP, not the gateway).
    local node_lines
    node_lines=$(printf '%s\n' "$existing" \
        | grep -vE '[[:space:]]host\.k3d\.internal$' \
        | sed '/^[[:space:]]*$/d' || true)

    local desired
    desired=$(printf '%s\n%s host.k3d.internal\n' \
        "$node_lines" "$host_ip" \
        | sed '/^[[:space:]]*$/d')

    # Escape each line into a literal \n for the JSON merge patch (awk keeps
    # this portable across BSD/macOS and GNU sed). out ends with a trailing \n
    # to match the file format coredns writes.
    local patch_value
    patch_value=$(printf '%s\n' "$desired" | awk '{ out = out $0 "\\n" } END { printf "%s", out }')

    if ! kubectl patch configmap coredns -n kube-system --context "${CLUSTER_CONTEXT}" \
        --type merge -p "{\"data\":{\"NodeHosts\":\"${patch_value}\"}}"; then
        echo "❌ Failed to patch CoreDNS NodeHosts"
        return 1
    fi
    echo "✅ CoreDNS NodeHosts updated (host.k3d.internal -> ${host_ip})"
}

# Apply the agent-manager-host Service+Endpoints and override host.docker.internal
# in CoreDNS NodeHosts to point to the Service's ClusterIP.
#
# This routes in-cluster calls to host.docker.internal:9000 (Thunder bootstrap,
# Gateway bootstrap) through kube-proxy to the docker-compose agent-manager-service
# container at its static k3d IP (10.89.0.20, defined in docker-compose.yml).
#
# Must run after the openchoreo-data-plane namespace exists (after step 2).
ensure_agent_manager_host_service() {
    echo "🔧 Applying agent-manager-host Service + Endpoints (static IP 10.89.0.20)..."
    local manifest="${SCRIPT_DIR}/../k8s/agent-manager-host.yaml"
    if [[ ! -f "$manifest" ]]; then
        echo "❌ agent-manager-host.yaml not found at ${manifest}"
        return 1
    fi
    if ! kubectl apply --context "${CLUSTER_CONTEXT}" -f "$manifest"; then
        echo "❌ Failed to apply agent-manager-host Service+Endpoints"
        return 1
    fi

    local clusterip
    clusterip=$(kubectl get svc agent-manager-host -n openchoreo-data-plane \
        --context "${CLUSTER_CONTEXT}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    if [[ -z "$clusterip" ]]; then
        echo "❌ Could not read ClusterIP for agent-manager-host Service"
        return 1
    fi

    echo "🔧 Overriding CoreDNS host.docker.internal → ${clusterip} (agent-manager-host)..."
    local existing
    existing=$(kubectl get configmap coredns -n kube-system \
        --context "${CLUSTER_CONTEXT}" -o jsonpath='{.data.NodeHosts}' 2>/dev/null)

    local node_lines
    node_lines=$(printf '%s\n' "$existing" \
        | grep -vE '[[:space:]]host\.docker\.internal$' \
        | sed '/^[[:space:]]*$/d' || true)

    local desired
    desired=$(printf '%s\n%s host.docker.internal\n' "$node_lines" "$clusterip" \
        | sed '/^[[:space:]]*$/d')

    local patch_value
    patch_value=$(printf '%s\n' "$desired" | awk '{ out = out $0 "\\n" } END { printf "%s", out }')

    if ! kubectl patch configmap coredns -n kube-system --context "${CLUSTER_CONTEXT}" \
        --type merge -p "{\"data\":{\"NodeHosts\":\"${patch_value}\"}}"; then
        echo "❌ Failed to patch CoreDNS NodeHosts for host.docker.internal"
        return 1
    fi
    echo "✅ agent-manager-host ready: host.docker.internal → ${clusterip} → 10.89.0.20:8080"
}

# Util: Refresh kubeconfig for k3d cluster
refresh_kubeconfig() {
    echo "🔄 Refreshing kubeconfig..."
    k3d kubeconfig merge ${CLUSTER_NAME} --kubeconfig-merge-default --kubeconfig-switch-context
}

# Util: Wait for cluster to be ready (max 30 attempts, 2s interval)
wait_for_cluster() {
    echo "⏳ Waiting for cluster to be ready..."
    for i in {1..30}; do
        if kubectl cluster-info --context ${CLUSTER_CONTEXT} --request-timeout=5s &>/dev/null; then
            echo "✅ Cluster is now ready"
            return 0
        fi
        echo "   Attempt $i/30..."
        sleep 2
    done
    return 1
}

# Util: Ensure cluster is accessible (refresh kubeconfig + wait)
ensure_cluster_accessible() {
    refresh_kubeconfig

    echo "🔍 Checking cluster accessibility..."
    if kubectl cluster-info --context ${CLUSTER_CONTEXT} --request-timeout=10s &>/dev/null; then
        echo "✅ Cluster is running and accessible"
        return 0
    fi

    echo "⚠️  Cluster not accessible. Restarting..."
    k3d cluster stop ${CLUSTER_NAME} 2>/dev/null || true
    k3d cluster start ${CLUSTER_NAME}

    refresh_kubeconfig
    wait_for_cluster
}

# Util: Register DataPlane
register_data_plane() {
    # $1: CA (already base64 decoded)
    # $2: planeID (e.g. "default")
    # $3: secretStoreRef name (required)
    local ca_cert="$1"
    local plane_id="$2"
    local secret_store="$3"

    if [ -z "$ca_cert" ]; then
        echo "❌ CA certificate not found. Cannot register DataPlane."
        echo "   Ensure cluster-agent-tls secret exists in openchoreo-data-plane namespace."
        exit 1
    fi

    echo "Registering DataPlane ..."
    cat <<EOF | kubectl apply -f -
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterDataPlane
metadata:
  name: default
  namespace: default
spec:
  planeID: "$plane_id"
  secretStoreRef:
    name: "$secret_store"
  clusterAgent:
    clientCA:
      value: |
$(echo "$ca_cert" | sed 's/^/        /')
  gateway:
    ingress:
      external:
        name: gateway-default
        namespace: openchoreo-data-plane
        http:
          host: "agentmanager.localhost"
          listenerName: http
          port: 19080
        https:
          host: "agentmanager.localhost"
          listenerName: https
          port: 19443
EOF
    echo "✅ DataPlane registered successfully"
}

# Util: Register WorkflowPlane
register_workflow_plane() {
    # $1: CA (already base64 decoded)
    # $2: planeID (e.g. "default")
    # $3: secretStoreRef name (required)
    local ca_cert="$1"
    local plane_id="$2"
    local secret_store="$3"

    if [ -z "$ca_cert" ]; then
        echo "❌ CA certificate not found. Cannot register WorkflowPlane."
        echo "   Ensure cluster-agent-tls secret exists in openchoreo-workflow-plane namespace."
        exit 1
    fi

    echo "Registering WorkflowPlane ..."
    cat <<EOF | kubectl apply -f -
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterWorkflowPlane
metadata:
  name: default
  namespace: default
spec:
  planeID: "$plane_id"
  secretStoreRef:
    name: "$secret_store"
  clusterAgent:
    clientCA:
      value: |
$(echo "$ca_cert" | sed 's/^/        /')
EOF
    echo "✅ WorkflowPlane registered successfully"
}

# Util: Register ObservabilityPlane
register_observability_plane() {
    # $1: CA (already base64 decoded)
    # $2: planeID (e.g. "default")
    # $3: observerURL (required)
    local ca_cert="$1"
    local plane_id="$2"
    local observer_url="$3"

    if [ -z "$ca_cert" ]; then
        echo "❌ CA certificate not found. Cannot register ObservabilityPlane."
        echo "   Ensure cluster-agent-tls secret exists in openchoreo-observability-plane namespace."
        exit 1
    fi

    echo "Registering ObservabilityPlane ..."
    cat <<EOF | kubectl apply -f -
apiVersion: openchoreo.dev/v1alpha1
kind: ObservabilityPlane
metadata:
  name: default
  namespace: default
spec:
  planeID: "$plane_id"
  clusterAgent:
    clientCA:
      value: |
$(echo "$ca_cert" | sed 's/^/        /')
  observerURL: $observer_url
EOF
    echo "✅ ObservabilityPlane registered successfully"
}

# Util to create/external secrets for OpenChoreo Observability Plane
create_external_secrets_obs_plane() {
    local ns="openchoreo-observability-plane"
    kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: opensearch-admin-credentials
  namespace: $ns
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: default
  target:
    name: opensearch-admin-credentials
  data:
  - secretKey: username
    remoteRef:
      key: opensearch-username
      property: value
  - secretKey: password
    remoteRef:
      key: opensearch-password
      property: value
EOF
    
    kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: observer-secret
  namespace: $ns
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: default
  target:
    name: observer-secret
  data:
  - secretKey: OPENSEARCH_USERNAME
    remoteRef:
      key: opensearch-username
      property: value
  - secretKey: OPENSEARCH_PASSWORD
    remoteRef:
      key: opensearch-password
      property: value
  - secretKey: UID_RESOLVER_OAUTH_CLIENT_SECRET
    remoteRef:
      key: observer-oauth-client-secret
      property: value
EOF
    echo "✅ External secrets for OpenChoreo Observability Plane created"

}

create_plane_cert_resources() {
  local PLANE_NAMESPACE="$1"
  echo "Setting up certificate resources in namespace '$PLANE_NAMESPACE'..."
  # 1. Create namespace if not exists
  kubectl create namespace "$PLANE_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  # 2. Wait for cert-manager to issue the cluster-gateway CA
    kubectl wait -n openchoreo-control-plane --for=condition=Ready certificate/cluster-gateway-ca --timeout=120s

  # 3. Copy cluster-gateway-ca ConfigMap from control-plane to desired namespace
  CA_CRT=$(kubectl get secret cluster-gateway-ca \
    -n openchoreo-control-plane -o jsonpath='{.data.ca\.crt}'| base64 -d)

  kubectl create configmap cluster-gateway-ca \
    --from-literal=ca.crt="$CA_CRT" \
    -n "$PLANE_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

}

# Util: Run multiple tasks in parallel and collect results
# Usage: run_parallel_tasks "task1_name:task1_func" "task2_name:task2_func" ...
# Each task is a "name:function" pair. Function args can be passed after the function name.
run_parallel_tasks() {
    local tasks=("$@")
    local pids=()
    local logs=()
    local names=()

    # Start all tasks in background
    for task in "${tasks[@]}"; do
        local name="${task%%:*}"
        local func="${task#*:}"
        local log_file
        log_file=$(mktemp)

        names+=("$name")
        logs+=("$log_file")

        # Run function in background, capturing output
        eval "$func" > "$log_file" 2>&1 &
        local pid=$!
        pids+=("$pid")
        echo "   Started: $name (PID: $pid)"
    done

    echo ""

    # Wait for all tasks and collect exit statuses
    local statuses=()
    local status
    for pid in "${pids[@]}"; do
        wait "$pid" && status=0 || status=$?
        statuses+=("$status")
    done

    # Output all logs
    echo ""
    for i in "${!names[@]}"; do
        echo "========== ${names[$i]} =========="
        cat "${logs[$i]}"
        echo ""
    done

    # Cleanup temp files
    for log_file in "${logs[@]}"; do
        rm -f "$log_file"
    done

    # Check for failures
    local failed=0
    for i in "${!statuses[@]}"; do
        if [ "${statuses[$i]}" -ne 0 ]; then
            echo "❌ ${names[$i]} failed with exit code: ${statuses[$i]}"
            failed=1
        fi
    done

    return $failed
}

# Util: Wait for all deployments in a namespace to be ready
# Usage: wait_for_namespace_ready "namespace" "label" [timeout_seconds]
wait_for_namespace_ready() {
    local namespace="$1"
    local label="$2"
    local timeout="${3:-300}"

    echo "⏳ Waiting for $label deployments..."
    if kubectl wait -n "$namespace" --for=condition=available --timeout="${timeout}s" deployment --all 2>&1; then
        echo "✅ $label ready"
        return 0
    else
        echo "⚠️  $label: some deployments may not be ready"
        return 1
    fi
}

# Util: Wait for pods with a specific label to be ready (for StatefulSets)
# Usage: wait_for_pods_ready "namespace" "label_selector" "display_name" [timeout_seconds]
wait_for_pods_ready() {
    local namespace="$1"
    local selector="$2"
    local display_name="$3"
    local timeout="${4:-120}"

    echo "⏳ Waiting for $display_name pods..."
    if kubectl wait -n "$namespace" --for=condition=ready pod -l "$selector" --timeout="${timeout}s" 2>&1; then
        echo "✅ $display_name ready"
        return 0
    else
        echo "⚠️  $display_name: some pods may not be ready"
        return 1
    fi
}

# Util: Wait for a secret to exist (created by cert-manager)
# Usage: wait_for_secret "namespace" "secret_name" [timeout_seconds]
wait_for_secret() {
    local namespace="$1"
    local secret_name="$2"
    local timeout="${3:-120}"
    local interval=5
    local elapsed=0

    echo "⏳ Waiting for secret '$secret_name' in namespace '$namespace'..."
    while [ $elapsed -lt $timeout ]; do
        if kubectl get secret "$secret_name" -n "$namespace" &>/dev/null; then
            echo "✅ Secret '$secret_name' is ready"
            return 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
        echo "   Waiting... ($elapsed/${timeout}s)"
    done

    echo "❌ Timeout waiting for secret '$secret_name' in namespace '$namespace'"
    return 1
}

# Patch the Thunder Deployment with a seed-db initContainer, then run the bootstrap Job.
# Call this AFTER 'helm install amp-thunder-extension --no-hooks' so the Deployment
# exists but the PVC is empty and the bootstrap Job hasn't run yet.
#
# Why --no-hooks:
#   The pre-install hooks include PVC, SA, Secret, ConfigMaps, and a Job.
#   The Job runs Thunder itself in setup/bootstrap mode.  On ARM64 the overall
#   hook orchestration times-out before the Deployment ever starts (the PVC that
#   the Deployment needs is also a hook).  We break the cycle by:
#     1. Applying the PVC / SA / Secret manually so the Deployment can schedule.
#     2. Patching the Deployment to seed the PVC via an initContainer.
#     3. Waiting for Thunder to be healthy.
#     4. Applying the bootstrap ConfigMaps + Job manually (renamed to avoid
#        conflicts with future helm upgrades).
#     5. Restarting Thunder so it picks up the bootstrapped configdb.db.
patch_and_bootstrap_thunder() {
    local chart="${SCRIPT_DIR}/../helm-charts/wso2-amp-thunder-extension"
    local ns="amp-thunder"
    local deploy="amp-thunder-extension-deployment"
    local job_name="amp-thunder-bootstrap-init"

    # ── 0. Apply hook resources the Deployment needs (PVC, SA, Secret) ───────
    echo "🔧 Applying Thunder pre-req hooks (PVC, ServiceAccount, Secret)..."
    local py_prereq
    py_prereq=$(mktemp /tmp/amp-prereq-XXXXXX.py)
    cat > "$py_prereq" << 'PYEOF'
import sys, re
content = sys.stdin.read()
docs = re.split(r'(?m)^---[ \t]*$', content)
for doc in docs:
    if not doc.strip():
        continue
    if 'helm.sh/hook' not in doc:
        continue
    # Skip Job and ConfigMap — those come later (after Thunder is running)
    if re.search(r'^kind: (Job|ConfigMap)', doc, re.M):
        continue
    doc = re.sub(r'(?m)^[ \t]+"?helm\.sh/hook[^\n]*\n', '', doc)
    print('---')
    print(doc.strip())
PYEOF
    helm template amp-thunder-extension "$chart" --namespace "$ns" 2>/dev/null \
        | python3 "$py_prereq" \
        | kubectl apply -n "$ns" --context "${CLUSTER_CONTEXT}" -f -
    rm -f "$py_prereq"
    echo "✅ Pre-req resources applied"

    # ── 1. Patch Deployment: add seed-db initContainer ───────────────────────
    # The initContainer copies the SQLite seed DBs from the image into the
    # (empty) PVC so Thunder has a valid database on first start.
    # Uses .initialized sentinel to stay idempotent across pod restarts.
    echo "🔧 Patching Thunder Deployment: seed-db initContainer..."
    local patch_tmp
    patch_tmp=$(mktemp /tmp/amp-thunder-patch-XXXXXX.yaml)
    cat > "$patch_tmp" << PATCHEOF
spec:
  template:
    spec:
      initContainers:
      - name: seed-db
        image: ${THUNDER_IMAGE}
        command: [sh, -c]
        args:
        - |
          if [ ! -f /pvcroot/.initialized ]; then
            S=/opt/thunder/repository/database
            cp \$S/configdb.db /pvcroot/
            cp \$S/runtimedb.db /pvcroot/
            cp \$S/userdb.db /pvcroot/
            mkdir -p /pvcroot/consent
            C=/opt/thunder/consent/repository/database
            cp \$C/consentdb.db /pvcroot/consent/
            touch /pvcroot/.initialized
            echo seeded PVC
          else
            echo PVC already seeded
          fi
        volumeMounts:
        - name: database-storage
          mountPath: /pvcroot
PATCHEOF
    if ! kubectl patch deployment "$deploy" -n "$ns" \
            --context "${CLUSTER_CONTEXT}" \
            --type strategic --patch-file "$patch_tmp"; then
        rm -f "$patch_tmp"
        echo "❌ Failed to patch Thunder initContainer"
        return 1
    fi
    rm -f "$patch_tmp"
    echo "✅ Thunder initContainer patched"

    # ── 2. Wait for Thunder rollout ──────────────────────────────────────────
    echo "⏳ Waiting for Thunder rollout (up to 3 min)..."
    if ! kubectl rollout status "deployment/$deploy" -n "$ns" \
            --context "${CLUSTER_CONTEXT}" --timeout=180s; then
        echo "❌ Thunder rollout timed out"
        kubectl describe pod -n "$ns" --context "${CLUSTER_CONTEXT}" | tail -30
        return 1
    fi
    echo "✅ Thunder is running"

    # ── 3. Apply bootstrap ConfigMaps + Job ───────────────────────────────────
    echo "🔧 Applying Thunder bootstrap ConfigMaps and Job..."
    local py_job
    py_job=$(mktemp /tmp/amp-job-XXXXXX.py)
    cat > "$py_job" << 'PYEOF'
import sys, re
content = sys.stdin.read()
docs = re.split(r'(?m)^---[ \t]*$', content)
for doc in docs:
    if not doc.strip():
        continue
    if 'helm.sh/hook' not in doc:
        continue
    # Only ConfigMap and Job hook resources
    if not re.search(r'^kind: (Job|ConfigMap)', doc, re.M):
        continue
    doc = re.sub(r'(?m)^[ \t]+"?helm\.sh/hook[^\n]*\n', '', doc)
    print('---')
    print(doc.strip())
PYEOF

    kubectl delete job "$job_name" -n "$ns" \
        --context "${CLUSTER_CONTEXT}" --ignore-not-found --wait=false 2>/dev/null || true

    helm template amp-thunder-extension "$chart" --namespace "$ns" 2>/dev/null \
        | python3 "$py_job" \
        | sed "s/^  name: amp-thunder-extension-setup$/  name: ${job_name}/" \
        | kubectl apply -n "$ns" --context "${CLUSTER_CONTEXT}" -f -
    rm -f "$py_job"

    # ── 4. Wait for bootstrap Job ────────────────────────────────────────────
    echo "⏳ Waiting for bootstrap Job (up to 5 min)..."
    if ! kubectl wait "job/$job_name" -n "$ns" \
            --context "${CLUSTER_CONTEXT}" \
            --for=condition=complete --timeout=300s; then
        echo "❌ Bootstrap job failed or timed out"
        kubectl logs "job/$job_name" -n "$ns" --context "${CLUSTER_CONTEXT}" 2>/dev/null | tail -30
        return 1
    fi
    echo "✅ Thunder bootstrap completed"

    # ── 5. Restart Thunder (picks up bootstrapped configdb.db) ───────────────
    echo "🔄 Restarting Thunder (picks up bootstrap data)..."
    kubectl rollout restart "deployment/$deploy" -n "$ns" --context "${CLUSTER_CONTEXT}"
    if ! kubectl rollout status "deployment/$deploy" -n "$ns" \
            --context "${CLUSTER_CONTEXT}" --timeout=120s; then
        echo "❌ Thunder restart timed out"
        return 1
    fi
    echo "✅ Thunder ready"
}
