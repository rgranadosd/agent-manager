#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.amp-local"
PID_DIR="${STATE_DIR}/pids"
STATUS_FILE="${STATE_DIR}/status.txt"

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

stop_pid_file() {
    local pid_file="$1"
    local name="$2"

    if [[ ! -f "${pid_file}" ]]; then
        warn "No pid file for ${name}"
        return
    fi

    local pid
    pid=$(cat "${pid_file}")

    if kill -0 "${pid}" >/dev/null 2>&1; then
        info "Stopping ${name} (pid ${pid})"
        kill "${pid}" >/dev/null 2>&1 || true
        sleep 1
        if kill -0 "${pid}" >/dev/null 2>&1; then
            warn "Force stopping ${name} (pid ${pid})"
            kill -9 "${pid}" >/dev/null 2>&1 || true
        fi
    else
        warn "Process for ${name} is no longer running"
    fi

    rm -f "${pid_file}"
}

main() {
    if [[ ! -d "${PID_DIR}" ]]; then
        info "No local AMP pid directory found at ${PID_DIR}"
        exit 0
    fi

    stop_pid_file "${PID_DIR}/amp-console.pid" "amp-console port-forward"
    stop_pid_file "${PID_DIR}/amp-api.pid" "amp-api port-forward"
    stop_pid_file "${PID_DIR}/obs-gateway-http.pid" "observability gateway port-forward"
    stop_pid_file "${PID_DIR}/amp-thunder.pid" "amp-thunder port-forward"
    stop_pid_file "${PID_DIR}/amp-api-gateway-manager.pid" "amp-api-gateway-manager port-forward"
    stop_pid_file "${PID_DIR}/gateway-connector.pid" "gateway connector"

    mkdir -p "${STATE_DIR}"
    cat >"${STATUS_FILE}" <<EOF
status=stopped
step=stopped
time=$(date '+%Y-%m-%d %H:%M:%S')
EOF

    info "Local AMP port-forwards stopped"
}

main "$@"