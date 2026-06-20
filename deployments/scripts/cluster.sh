#!/bin/bash
# Unified AMP cluster lifecycle management.
# Usage: cluster.sh <command> [--help]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

SELF="$(basename "$0")"
COMPOSE_FILE="$SCRIPT_DIR/../docker-compose.yml"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Help ─────────────────────────────────────────────────────────────────────

usage_global() {
    cat << EOF
Usage: ${SELF} <command> [--help]

Manage the AMP local k3d environment (k3d + podman + docker-compose).

Commands:
  init       Full init from scratch — k3d cluster + all AMP components
  start      Resume a previously stopped cluster (no rebuild)
  stop       Soft stop — preserves cluster state and docker volumes
  destroy    Full teardown — deletes cluster and ALL data (irreversible)

Options:
  -h, --help   Show this help message

Run '${SELF} <command> --help' for details on a specific command.

Examples:
  ${SELF} init          # First time on a new machine (takes ~20 min)
  ${SELF} stop          # End of day
  ${SELF} start         # Next morning
  ${SELF} destroy       # Wipe everything and start over
EOF
}

usage_init() {
    cat << EOF
Usage: ${SELF} init [--help]

Full environment initialization from scratch.

Runs the following steps in order:
  1. setup-k3d.sh          — Create k3d cluster (${CLUSTER_NAME})
  2. setup-prerequisites.sh — cert-manager, external-secrets, etc.
  3. setup-platform.sh      — Build eval-job image + start docker-compose
  4. setup-openchoreo.sh    — OpenChoreo planes + AMP extensions
                              (includes Thunder PVC seeding + bootstrap)
  5. setup-gateway.sh       — API Platform Gateway

Prerequisites:
  - podman machine must be running
  - Ports 6550, 8080, 8443, 9000, 19080, 22893 must be free

Use this on a fresh machine or after '${SELF} destroy'.
For a stopped cluster, use '${SELF} start' instead.

Options:
  -h, --help   Show this help message
EOF
}

usage_start() {
    cat << EOF
Usage: ${SELF} start [--help]

Resume a previously stopped cluster. Does NOT reinstall anything.

Steps:
  1. Starts the podman machine (if not running)
  2. Starts the k3d cluster (${CLUSTER_NAME})
  3. Starts docker-compose services (agent-manager, postgres, console)
  4. Waits for Agent Manager health check (http://localhost:9000/healthz)

Requires the cluster to already exist ('${SELF} init' must have run before).

Options:
  -h, --help   Show this help message
EOF
}

usage_stop() {
    cat << EOF
Usage: ${SELF} stop [--help]

Soft stop — preserves all cluster state and docker volumes.

Steps:
  1. Stops docker-compose services (volumes NOT removed)
  2. Stops the k3d cluster (k8s state preserved on disk)

All databases, PVCs, and k8s resources are retained.
Resume with '${SELF} start'.

To wipe everything instead, use '${SELF} destroy'.

Options:
  -h, --help   Show this help message
EOF
}

usage_destroy() {
    cat << EOF
Usage: ${SELF} destroy [--help]

Full teardown — ALL DATA IS LOST. This cannot be undone.

Steps:
  1. docker compose down -v  — stops services AND removes volumes
  2. k3d cluster delete      — deletes cluster and all k8s state
  3. Podman machine is NOT touched (shared with other projects)

After destroy, run '${SELF} init' to start fresh.

Options:
  -h, --help   Show this help message
EOF
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

wait_for_healthz() {
    local url="$1"
    local label="$2"
    local max_attempts="${3:-30}"
    local interval="${4:-2}"

    echo "⏳ Waiting for ${label}..."
    local i=1
    while [ "$i" -le "$max_attempts" ]; do
        if curl -sf "$url" &>/dev/null; then
            echo "✅ ${label} is healthy"
            return 0
        fi
        i=$((i + 1))
        sleep "$interval"
    done
    return 1
}

wait_for_cluster() {
    echo "⏳ Waiting for cluster API server..."
    local i=1
    while [ "$i" -le 30 ]; do
        if kubectl cluster-info --context "${CLUSTER_CONTEXT}" &>/dev/null; then
            echo "✅ Cluster is accessible"
            return 0
        fi
        i=$((i + 1))
        sleep 2
    done
    return 1
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_init() {
    case "${1:-}" in -h|--help) usage_init; exit 0 ;; esac

    echo "=================================================="
    echo "=== AMP Full Environment Init                  ==="
    echo "=================================================="
    echo ""

    echo "1️⃣  k3d cluster"
    bash "$SCRIPT_DIR/setup-k3d.sh"
    echo ""

    echo "2️⃣  Prerequisites"
    bash "$SCRIPT_DIR/setup-prerequisites.sh"
    echo ""

    echo "3️⃣  Platform services"
    bash "$SCRIPT_DIR/setup-platform.sh"
    echo ""

    if ! wait_for_healthz "http://localhost:9000/healthz" "Agent Manager" 30 2; then
        echo "❌ Agent Manager not healthy after 60s — check: docker logs agent-manager-service"
        exit 1
    fi
    echo ""

    echo "4️⃣  OpenChoreo + AMP extensions"
    bash "$SCRIPT_DIR/setup-openchoreo.sh" "$PROJECT_ROOT"
    echo ""

    echo "5️⃣  API Platform Gateway"
    bash "$SCRIPT_DIR/setup-gateway.sh"
    echo ""

    echo "=================================================="
    echo "✅ Init complete!"
    echo ""
    echo "   API:     http://localhost:9000"
    echo "   Console: http://localhost:3000  (amp-admin / amp-admin)"
    echo ""
    echo "   ${SELF} stop     — stop for the night"
    echo "   ${SELF} start    — resume tomorrow"
    echo "   ${SELF} destroy  — wipe everything"
    echo "=================================================="
}

cmd_start() {
    case "${1:-}" in -h|--help) usage_start; exit 0 ;; esac

    echo "=== Starting AMP Environment ==="
    echo ""

    echo "1️⃣  Podman machine"
    if command -v podman &>/dev/null; then
        if podman machine list --format '{{.Running}}' 2>/dev/null | grep -q true; then
            echo "✅ Podman machine already running"
        else
            echo "🚀 Starting podman machine..."
            podman machine start
            echo "✅ Podman machine started"
        fi
    else
        echo "⚠️  podman not found — assuming container runtime is available"
    fi
    echo ""

    echo "2️⃣  k3d cluster"
    if ! command -v k3d &>/dev/null; then
        echo "❌ k3d not installed"; exit 1
    fi
    if ! k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
        echo "❌ Cluster '${CLUSTER_NAME}' not found — run: ${SELF} init"
        exit 1
    fi
    k3d cluster start "${CLUSTER_NAME}"
    if ! wait_for_cluster; then
        echo "❌ Cluster API server not accessible after 60s"
        exit 1
    fi
    echo ""

    echo "3️⃣  docker-compose services"
    export CONSOLE_HOST_PATH="$(cd "$SCRIPT_DIR/../../console" && pwd)"
    docker compose -f "$COMPOSE_FILE" up -d
    echo ""

    echo "4️⃣  Agent Manager health check"
    if ! wait_for_healthz "http://localhost:9000/healthz" "Agent Manager" 30 2; then
        echo "⚠️  Agent Manager not responding — check: docker logs agent-manager-service"
    fi
    echo ""

    echo "✅ AMP environment started"
    echo ""
    echo "   API:     http://localhost:9000"
    echo "   Console: http://localhost:3000  (amp-admin / amp-admin)"
}

cmd_stop() {
    case "${1:-}" in -h|--help) usage_stop; exit 0 ;; esac

    echo "=== Stopping AMP Environment ==="
    echo "(state preserved — use '${SELF} destroy' for a full wipe)"
    echo ""

    echo "1️⃣  docker-compose services"
    if [ -f "$COMPOSE_FILE" ]; then
        docker compose -f "$COMPOSE_FILE" down
        echo "✅ Services stopped (volumes preserved)"
    else
        echo "⚠️  docker-compose.yml not found, skipping"
    fi
    echo ""

    echo "2️⃣  k3d cluster"
    if command -v k3d &>/dev/null && k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
        k3d cluster stop "${CLUSTER_NAME}"
        echo "✅ Cluster '${CLUSTER_NAME}' stopped (state preserved)"
    else
        echo "⚠️  Cluster '${CLUSTER_NAME}' not found or already stopped"
    fi
    echo ""

    echo "✅ AMP environment stopped"
    echo "   Resume with: ${SELF} start"
}

cmd_destroy() {
    case "${1:-}" in -h|--help) usage_destroy; exit 0 ;; esac

    echo "=== AMP Full Teardown (IRREVERSIBLE) ==="
    echo ""

    echo "1️⃣  docker-compose services + volumes"
    if [ -f "$COMPOSE_FILE" ]; then
        docker compose -f "$COMPOSE_FILE" down -v
        echo "✅ Services and volumes removed"
    else
        echo "⚠️  docker-compose.yml not found, skipping"
    fi
    echo ""

    echo "2️⃣  k3d cluster"
    if command -v k3d &>/dev/null && k3d cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
        k3d cluster delete "${CLUSTER_NAME}"
        echo "✅ Cluster '${CLUSTER_NAME}' deleted"
    else
        echo "⚠️  Cluster '${CLUSTER_NAME}' not found"
    fi
    echo ""

    echo "3️⃣  Podman machine"
    echo "ℹ️  The podman machine is shared — not stopped automatically."
    echo "   To stop it:   podman machine stop"
    echo "   To delete it: podman machine rm"
    echo ""

    echo "✅ Teardown complete!"
    echo "   Rebuild with: ${SELF} init"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

COMMAND="${1:-}"
shift 2>/dev/null || true

case "$COMMAND" in
    init)         cmd_init    "$@" ;;
    start)        cmd_start   "$@" ;;
    stop)         cmd_stop    "$@" ;;
    destroy)      cmd_destroy "$@" ;;
    -h|--help|help|"") usage_global; exit 0 ;;
    *)
        echo "Error: unknown command '${COMMAND}'"
        echo ""
        usage_global
        exit 1
        ;;
esac
