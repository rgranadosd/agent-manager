#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STOP_SCRIPT="${SCRIPT_DIR}/stop-local-amp.sh"
START_SCRIPT="${SCRIPT_DIR}/start-local-amp.sh"
LOCAL_ENV_FILE="${SCRIPT_DIR}/.amp-local.env"
QUICK_START_INSTALL_SCRIPT="${SCRIPT_DIR}/deployments/quick-start/install.sh"

if [[ -f "${LOCAL_ENV_FILE}" ]]; then
    set -a
    . "${LOCAL_ENV_FILE}"
    set +a
fi

CLUSTER_NAME="${CLUSTER_NAME:-amp-local}"
PODMAN_MACHINE_NAME="${PODMAN_MACHINE_NAME:-podman-machine-default}"
REPROVISION_CLUSTER=false

if [[ -t 1 ]]; then
    COLOR_INFO=$'\033[0;32m'
    COLOR_WARN=$'\033[0;33m'
    COLOR_ERROR=$'\033[0;31m'
    COLOR_RESET=$'\033[0m'
else
    COLOR_INFO=''
    COLOR_WARN=''
    COLOR_ERROR=''
    COLOR_RESET=''
fi

log() {
    local level="$1"
    local message="$2"
    local color="${COLOR_RESET}"

    case "${level}" in
        INFO) color="${COLOR_INFO}" ;;
        WARN) color="${COLOR_WARN}" ;;
        ERROR) color="${COLOR_ERROR}" ;;
    esac

    printf '%s[%s] %s%s\n' "${color}" "${level}" "${message}" "${COLOR_RESET}"
}

info() {
    log INFO "$1"
}

warn() {
    log WARN "$1"
}

error() {
    log ERROR "$1" >&2
}

print_help() {
    cat <<EOF
Usage: ./restart-local-amp.sh [options]

Restart modes:
  Default                 Stop local port-forwards, stop k3d, stop Podman,
                          and start the local AMP stack again.
  --reprovision           Delete the k3d cluster, rerun deployments/quick-start/install.sh,
                          and then start the local AMP helper flow.

Options:
  --reprovision           Recreate the local cluster and reinstall the platform.
  --help, -h              Show this help.

Notes:
  - --reprovision is intended for the default cluster name 'amp-local'.
  - Local overrides can still be provided in .amp-local.env.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --reprovision)
                REPROVISION_CLUSTER=true
                ;;
            --help|-h)
                print_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                echo
                print_help
                exit 1
                ;;
        esac
        shift
    done
}

start_podman_machine() {
    if ! command -v podman >/dev/null 2>&1; then
        error "podman not found; cannot start Podman machine"
        exit 1
    fi

    if podman machine list --format '{{.Name}} {{.Running}}' 2>/dev/null | grep -q "^${PODMAN_MACHINE_NAME} true$"; then
        info "Podman machine ${PODMAN_MACHINE_NAME} is already running"
        return
    fi

    info "Starting Podman machine ${PODMAN_MACHINE_NAME}"
    podman machine start "${PODMAN_MACHINE_NAME}" >/dev/null 2>&1 || podman machine start >/dev/null 2>&1 || {
        error "Unable to start Podman machine ${PODMAN_MACHINE_NAME}"
        exit 1
    }
}

stop_cluster() {
    if ! command -v k3d >/dev/null 2>&1; then
        warn "k3d not found; skipping cluster stop"
        return
    fi

    if ! k3d cluster list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qx "${CLUSTER_NAME}"; then
        info "k3d cluster ${CLUSTER_NAME} does not exist; skipping cluster stop"
        return
    fi

    info "Stopping k3d cluster ${CLUSTER_NAME}"
    k3d cluster stop "${CLUSTER_NAME}" >/dev/null 2>&1 || warn "Unable to stop k3d cluster ${CLUSTER_NAME}"
}

delete_cluster() {
    if ! command -v k3d >/dev/null 2>&1; then
        error "k3d not found; cannot delete cluster"
        exit 1
    fi

    if ! k3d cluster list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -qx "${CLUSTER_NAME}"; then
        info "k3d cluster ${CLUSTER_NAME} does not exist; skipping cluster deletion"
        return
    fi

    info "Deleting k3d cluster ${CLUSTER_NAME}"
    k3d cluster delete "${CLUSTER_NAME}" >/dev/null 2>&1 || {
        error "Unable to delete k3d cluster ${CLUSTER_NAME}"
        exit 1
    }
}

stop_podman_machine() {
    if ! command -v podman >/dev/null 2>&1; then
        warn "podman not found; skipping Podman machine stop"
        return
    fi

    if ! podman machine list --format '{{.Name}} {{.Running}}' 2>/dev/null | grep -q "^${PODMAN_MACHINE_NAME} true$"; then
        info "Podman machine ${PODMAN_MACHINE_NAME} is not running; skipping machine stop"
        return
    fi

    info "Stopping Podman machine ${PODMAN_MACHINE_NAME}"
    podman machine stop "${PODMAN_MACHINE_NAME}" >/dev/null 2>&1 || warn "Unable to stop Podman machine ${PODMAN_MACHINE_NAME}"
}

reprovision_cluster() {
    if [[ "${CLUSTER_NAME}" != "amp-local" ]]; then
        error "--reprovision currently supports only CLUSTER_NAME=amp-local because deployments/quick-start/install.sh is hard-coded to that cluster"
        exit 1
    fi

    if [[ ! -f "${QUICK_START_INSTALL_SCRIPT}" ]]; then
        error "Missing quick-start installer: ${QUICK_START_INSTALL_SCRIPT}"
        exit 1
    fi

    start_podman_machine
    delete_cluster

    info "Reprovisioning AMP platform with deployments/quick-start/install.sh"
    bash "${QUICK_START_INSTALL_SCRIPT}"
}

if [[ ! -f "${STOP_SCRIPT}" ]]; then
    error "Missing stop script: ${STOP_SCRIPT}"
    exit 1
fi

if [[ ! -f "${START_SCRIPT}" ]]; then
    error "Missing start script: ${START_SCRIPT}"
    exit 1
fi

parse_args "$@"

if [[ $# -eq 0 ]]; then
    info "No options provided; using standard restart. Run ./restart-local-amp.sh --help to see available options"
fi

info "Stopping local AMP port-forwards"
bash "${STOP_SCRIPT}"

if [[ "${REPROVISION_CLUSTER}" == "true" ]]; then
    reprovision_cluster
else
    stop_cluster
    stop_podman_machine
fi

info "Starting local AMP stack"
bash "${START_SCRIPT}"