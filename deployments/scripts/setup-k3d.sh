#!/bin/bash
set -e
# Get the absolute directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Change to script directory to ensure consistent working directory
cd "$SCRIPT_DIR"
source "$SCRIPT_DIR/env.sh"
source "$SCRIPT_DIR/utils.sh"

echo "=== Setting up k3d Cluster for OpenChoreo ==="

# Check if cluster already exists
if k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
    echo "✅ k3d cluster '${CLUSTER_NAME}' already exists"

    ensure_cluster_accessible

    echo ""
    echo "Cluster info:"
    kubectl cluster-info --context ${CLUSTER_CONTEXT}
    echo ""
    echo "✅ Using existing cluster"
else
    # Check port availability before creating cluster
    if ! check_required_ports; then
        exit 1
    fi

    # Create /tmp/k3d-shared directory for OpenChoreo
    echo "📁 Creating shared directory for OpenChoreo..."
    mkdir -p /tmp/k3d-shared

    # Create k3d cluster with OpenChoreo configuration
    echo "🚀 Creating k3d cluster with OpenChoreo configuration..."
    k3d cluster create --config ../k3d-local-config.yaml

    echo ""
    echo "✅ k3d cluster created successfully!"

    # Fix static IP on server-0 so k3s always starts with the same node-ip.
    # Without this, podman assigns a random DHCP IP on each VM restart; k3s
    # records the first IP as --node-ip and crashes when it changes (crash loop).
    echo "📌 Assigning static IP 10.89.0.3 to server-0..."
    SERVER_NODE="k3d-${CLUSTER_NAME}-server-0"
    NETWORK="k3d-${CLUSTER_NAME}"
    podman stop "$SERVER_NODE" 2>/dev/null || true
    podman network disconnect "$NETWORK" "$SERVER_NODE" 2>/dev/null || true
    podman network connect --ip 10.89.0.3 "$NETWORK" "$SERVER_NODE"
    podman start "$SERVER_NODE"
    echo "✅ Static IP 10.89.0.3 assigned to $SERVER_NODE"

    refresh_kubeconfig

    if ! wait_for_cluster; then
        echo "❌ Cluster failed to become ready after 30 attempts"
        echo "   Try running: k3d kubeconfig merge ${CLUSTER_NAME} --kubeconfig-merge-default --kubeconfig-switch-context"
        exit 1
    fi
fi

# Apply CoreDNS custom configuration for *.openchoreo.localhost and *.amp.localhost resolution
echo ""
echo "🔧 Applying CoreDNS custom configuration..."
if ! kubectl apply --context "${CLUSTER_CONTEXT}" -f "$SCRIPT_DIR/../k8s/coredns-amp-custom.yaml"; then
    echo "❌ Failed to apply CoreDNS custom configuration"
    exit 1
fi
if ! kubectl get configmap coredns-custom -n kube-system --context "${CLUSTER_CONTEXT}" &>/dev/null; then
    echo "❌ CoreDNS custom ConfigMap not found after apply"
    exit 1
fi

# Add host.k3d.internal / host.docker.internal to the coredns NodeHosts file.
# This must run BEFORE the rollout restart below: the coredns Deployment mounts
# NodeHosts as a non-optional configmap key, and on a freshly (re)started k3s
# server that key may not exist yet, leaving the restarted pod stuck in
# ContainerCreating until the rollout times out.
if ! ensure_coredns_host_aliases; then
    exit 1
fi

# CoreDNS's reload plugin can miss the override files if the configmap is mounted
# after the pod's initial parse. Restart CoreDNS so the rewrite rules take effect
# before any client (e.g. observer) caches a wrong resolution.
if ! kubectl rollout restart deployment/coredns -n kube-system --context "${CLUSTER_CONTEXT}"; then
    echo "❌ Failed to restart CoreDNS deployment"
    exit 1
fi
if ! kubectl rollout status deployment/coredns -n kube-system --context "${CLUSTER_CONTEXT}" --timeout=60s; then
    echo "❌ CoreDNS deployment failed to become ready"
    exit 1
fi
echo "✅ CoreDNS configured to resolve *.openchoreo.localhost and *.amp.localhost"

# Generate Machine IDs for observability
echo ""
generate_machine_ids "$CLUSTER_NAME"
echo ""
