#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.amp-local"
LOG_DIR="${STATE_DIR}/logs"
PID_DIR="${STATE_DIR}/pids"
STATUS_FILE="${STATE_DIR}/status.txt"
LOCAL_ENV_FILE="${SCRIPT_DIR}/.amp-local.env"

if [[ -f "${LOCAL_ENV_FILE}" ]]; then
    set -a
    # Allow local overrides for ports and Thunder test credentials without
    # editing the script on every machine.
    . "${LOCAL_ENV_FILE}"
    set +a
fi

CLUSTER_NAME="${CLUSTER_NAME:-amp-local}"
CLUSTER_CONTEXT="${CLUSTER_CONTEXT:-k3d-${CLUSTER_NAME}}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-600}"
THUNDER_VERIFY_USERNAME="${THUNDER_VERIFY_USERNAME:-rgranadosd@gmail.com}"
THUNDER_VERIFY_PASSWORD="${THUNDER_VERIFY_PASSWORD:-Patata1!}"
THUNDER_VERIFY_GIVEN_NAME="${THUNDER_VERIFY_GIVEN_NAME:-Rafa}"
THUNDER_VERIFY_FAMILY_NAME="${THUNDER_VERIFY_FAMILY_NAME:-Granados}"
CONSOLE_LOCAL_PORT="${CONSOLE_LOCAL_PORT:-13000}"
API_LOCAL_PORT="${API_LOCAL_PORT:-19000}"
OTEL_LOCAL_PORT="${OTEL_LOCAL_PORT:-22893}"
THUNDER_LOCAL_PORT="${THUNDER_LOCAL_PORT:-8082}"
CONSOLE_DISABLE_AUTH="${CONSOLE_DISABLE_AUTH:-false}"
THUNDER_MGMT_CLIENT_ID="${THUNDER_MGMT_CLIENT_ID:-amp-api-client}"
THUNDER_MGMT_CLIENT_SECRET="${THUNDER_MGMT_CLIENT_SECRET:-amp-api-client-secret}"
THUNDER_CONSOLE_CLIENT_ID="${THUNDER_CONSOLE_CLIENT_ID:-amp-console-client}"
THUNDER_DEFAULT_ORG_HANDLE="${THUNDER_DEFAULT_ORG_HANDLE:-default}"
THUNDER_LOCAL_BASE_URL="http://localhost:${THUNDER_LOCAL_PORT}"
GATEWAY_CONNECTOR_ENABLED="${GATEWAY_CONNECTOR_ENABLED:-true}"
GATEWAY_CONNECTOR_NAMESPACE="${GATEWAY_CONNECTOR_NAMESPACE:-wso2-amp}"
GATEWAY_CONNECTOR_SERVICE="${GATEWAY_CONNECTOR_SERVICE:-amp-api-gateway-manager}"
GATEWAY_CONNECTOR_LOCAL_PORT="${GATEWAY_CONNECTOR_LOCAL_PORT:-19243}"
GATEWAY_CONNECTOR_REMOTE_PORT="${GATEWAY_CONNECTOR_REMOTE_PORT:-9243}"
GATEWAY_CONNECTOR_WS_PATH="${GATEWAY_CONNECTOR_WS_PATH:-/api/internal/v1/ws/gateways/connect}"
GATEWAY_CONNECTOR_API_KEY="${GATEWAY_CONNECTOR_API_KEY:-}"
GATEWAY_CONNECTOR_PYTHON_BIN="${GATEWAY_CONNECTOR_PYTHON_BIN:-python3}"
GATEWAY_CONNECTOR_VENV_DIR="${GATEWAY_CONNECTOR_VENV_DIR:-${STATE_DIR}/gateway-connector-venv}"
GATEWAY_CONNECTOR_AUTO_SETUP="${GATEWAY_CONNECTOR_AUTO_SETUP:-true}"

mkdir -p "${LOG_DIR}" "${PID_DIR}"

CURRENT_STEP="initializing"

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

is_true() {
    case "$1" in
        true|TRUE|True|1|yes|YES|Yes|y|Y)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

error() {
    log ERROR "$1" >&2
}

die() {
    printf 'status=failed\nstep=%s\ntime=%s\n' "${CURRENT_STEP}" "$(date '+%Y-%m-%d %H:%M:%S')" >"${STATUS_FILE}"
    error "$1"
    exit 1
}

set_step() {
    CURRENT_STEP="$1"
    info "Step: ${CURRENT_STEP}"
}

write_success_status() {
    local gateway_connector_url="disabled"
    if is_true "${GATEWAY_CONNECTOR_ENABLED}"; then
        gateway_connector_url="wss://localhost:${GATEWAY_CONNECTOR_LOCAL_PORT}${GATEWAY_CONNECTOR_WS_PATH}"
    fi

    cat >"${STATUS_FILE}" <<EOF
status=ready
step=completed
time=$(date '+%Y-%m-%d %H:%M:%S')
cluster_name=${CLUSTER_NAME}
cluster_context=${CLUSTER_CONTEXT}
console_url=http://localhost:${CONSOLE_LOCAL_PORT}
api_url=http://localhost:${API_LOCAL_PORT}
otel_url=http://localhost:${OTEL_LOCAL_PORT}/otel
thunder_url=${THUNDER_LOCAL_BASE_URL}
gateway_connector_url=${gateway_connector_url}
thunder_user=${THUNDER_VERIFY_USERNAME}
log_dir=${LOG_DIR}
EOF
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

wait_for_local_tcp() {
    local name="$1"
    local host="$2"
    local port="$3"
    local elapsed=0

    info "Checking ${name} at ${host}:${port}"

    while true; do
        if nc -zw5 "${host}" "${port}" >/dev/null 2>&1; then
            info "${name} is reachable on ${host}:${port}"
            return 0
        fi

        if (( elapsed >= WAIT_TIMEOUT_SECONDS )); then
            die "${name} at ${host}:${port} did not become reachable within ${WAIT_TIMEOUT_SECONDS}s"
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done
}

wait_for_cluster() {
    local elapsed=0

    until kubectl cluster-info --context "${CLUSTER_CONTEXT}" >/dev/null 2>&1; do
        if (( elapsed >= WAIT_TIMEOUT_SECONDS )); then
            die "Cluster context ${CLUSTER_CONTEXT} did not become reachable within ${WAIT_TIMEOUT_SECONDS}s"
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
}

wait_for_rollout() {
    local namespace="$1"
    local deployment="$2"

    info "Waiting for ${namespace}/${deployment} rollout"
    kubectl --context "${CLUSTER_CONTEXT}" rollout status deployment/"${deployment}" -n "${namespace}" --timeout="${WAIT_TIMEOUT_SECONDS}s" >/dev/null
}

ensure_platform_resources() {
    local release_name="amp-platform-resources"
    local chart_dir="${SCRIPT_DIR}/deployments/helm-charts/wso2-amp-platform-resources-extension"

    if helm --kube-context "${CLUSTER_CONTEXT}" status "${release_name}" -n default >/dev/null 2>&1; then
        info "Platform resources extension already installed (release ${release_name})"
        return 0
    fi

    if [[ ! -d "${chart_dir}" ]]; then
        warn "Chart directory not found: ${chart_dir}; skipping platform resources install"
        return 0
    fi

    info "Installing platform resources extension (default org/project/environment)"
    if ! helm --kube-context "${CLUSTER_CONTEXT}" install "${release_name}" "${chart_dir}" \
        -n default --wait --timeout 5m >/dev/null 2>&1; then
        warn "Failed to install ${release_name}; create org via 'helm install' manually"
        return 0
    fi
    info "Platform resources extension installed"
}

cleanup_unhealthy_pods() {
    local pods_to_delete

    pods_to_delete=$(kubectl --context "${CLUSTER_CONTEXT}" get pods -A --no-headers 2>/dev/null \
        | awk '$4 ~ /^(ContainerStatusUnknown|Error|ImagePullBackOff|ErrImagePull|CrashLoopBackOff)$/ {print $1 " " $2}')

    if [[ -z "${pods_to_delete}" ]]; then
        info "No unhealthy pods found after cluster start"
        return 0
    fi

    info "Deleting unhealthy pods before waiting for rollouts"
    while IFS=' ' read -r namespace pod_name; do
        [[ -n "${namespace}" && -n "${pod_name}" ]] || continue
        kubectl --context "${CLUSTER_CONTEXT}" delete pod -n "${namespace}" "${pod_name}" --ignore-not-found >/dev/null 2>&1 || true
    done <<< "${pods_to_delete}"
}

get_thunder_token() {
    local token_response

    token_response=$(kubectl --context "${CLUSTER_CONTEXT}" exec -n amp-thunder deployment/amp-thunder-extension-deployment -- sh -lc \
        "wget -qO- --post-data='grant_type=client_credentials&client_id=${THUNDER_MGMT_CLIENT_ID}&client_secret=${THUNDER_MGMT_CLIENT_SECRET}&scope=openid system' --header='Content-Type: application/x-www-form-urlencoded' http://localhost:8090/oauth2/token")

    printf '%s' "${token_response}" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p'
}

get_thunder_resource() {
    local path="$1"
    local access_token

    access_token=$(get_thunder_token)
    [[ -n "${access_token}" ]] || die "Failed to obtain Thunder management token"

    kubectl --context "${CLUSTER_CONTEXT}" exec -n amp-thunder deployment/amp-thunder-extension-deployment -- sh -lc \
        "wget -qO- --header='Authorization: Bearer ${access_token}' http://localhost:8090${path}"
}

get_thunder_console_app_id() {
    local applications_json

    applications_json=$(get_thunder_resource "/applications")
    printf '%s' "${applications_json}" \
        | grep -o '"client_id":"'"${THUNDER_CONSOLE_CLIENT_ID}"'"[^}]*"id":"[^"]*"\|"id":"[^"]*"[^}]*"client_id":"'"${THUNDER_CONSOLE_CLIENT_ID}"'"' \
        | grep -o '"id":"[^"]*"' \
        | head -1 \
        | cut -d'"' -f4
}

get_default_org_unit_id() {
    local org_units_json

    org_units_json=$(get_thunder_resource "/organization-units")
    printf '%s' "${org_units_json}" \
        | grep -o '"handle":"'"${THUNDER_DEFAULT_ORG_HANDLE}"'"[^}]*"id":"[^"]*"\|"id":"[^"]*"[^}]*"handle":"'"${THUNDER_DEFAULT_ORG_HANDLE}"'"' \
        | grep -o '"id":"[^"]*"' \
        | head -1 \
        | cut -d'"' -f4
}

get_thunder_user_id() {
    local username="$1"
    local users_json

    users_json=$(get_thunder_resource "/users")
    printf '%s' "${users_json}" \
        | grep -o '"id":"[^"]*"[^}]*"username":"'"${username}"'"\|"username":"'"${username}"'"[^}]*"id":"[^"]*"' \
        | grep -o '"id":"[^"]*"' \
        | head -1 \
        | cut -d'"' -f4
}
ensure_thunder_user() {
    local users_response
    local org_unit_id
    local payload
    local access_token

    info "Ensuring Thunder user ${THUNDER_VERIFY_USERNAME}"
    org_unit_id=$(get_default_org_unit_id)
    [[ -n "${org_unit_id}" ]] || die "Failed to resolve Thunder default organization unit"

    access_token=$(get_thunder_token)
    [[ -n "${access_token}" ]] || die "Failed to obtain Thunder management token"

    users_response=$(get_thunder_resource "/users")
    if printf '%s' "${users_response}" | grep -q '"username":"'"${THUNDER_VERIFY_USERNAME}"'"'; then
        warn "Thunder user ${THUNDER_VERIFY_USERNAME} already exists; preserving it to avoid duplicate Thunder username indexes"
        return 0
    fi

    payload=$(cat <<EOF
{"type":"engineer","organizationUnit":"${org_unit_id}","attributes":{"username":"${THUNDER_VERIFY_USERNAME}","password":"${THUNDER_VERIFY_PASSWORD}","given_name":"${THUNDER_VERIFY_GIVEN_NAME}","family_name":"${THUNDER_VERIFY_FAMILY_NAME}","groups":["platformEngineer"]}}
EOF
)

    kubectl --context "${CLUSTER_CONTEXT}" exec -n amp-thunder deployment/amp-thunder-extension-deployment -- sh -lc \
        "wget -qO- --post-data='${payload}' --header='Authorization: Bearer ${access_token}' --header='accept: application/json' --header='Content-Type: application/json' http://localhost:8090/users" >/dev/null

    info "Thunder user ${THUNDER_VERIFY_USERNAME} created"
}

patch_console_config() {
    local redirect_url="http://localhost:${CONSOLE_LOCAL_PORT}/login"
    local api_url="http://localhost:${API_LOCAL_PORT}"
    local auth_url="${THUNDER_LOCAL_BASE_URL}"
    local disable_auth_value="${CONSOLE_DISABLE_AUTH}"
    local needs_restart=false
    local thunder_console_app_id

    # 1. Patch redirect URLs if needed
    local current_sign_in
    current_sign_in=$(kubectl --context "${CLUSTER_CONTEXT}" get configmap amp-console -n wso2-amp -o jsonpath='{.data.SIGN_IN_REDIRECT_URL}' 2>/dev/null || true)
    local current_api_url
    current_api_url=$(kubectl --context "${CLUSTER_CONTEXT}" get configmap amp-console -n wso2-amp -o jsonpath='{.data.API_BASE_URL}' 2>/dev/null || true)
    local current_auth_url
    current_auth_url=$(kubectl --context "${CLUSTER_CONTEXT}" get configmap amp-console -n wso2-amp -o jsonpath='{.data.AUTH_BASE_URL}' 2>/dev/null || true)
    local current_disable_auth
    current_disable_auth=$(kubectl --context "${CLUSTER_CONTEXT}" get configmap amp-console -n wso2-amp -o jsonpath='{.data.DISABLE_AUTH}' 2>/dev/null || true)

    if [[ "${current_sign_in}" != "${redirect_url}" ]] || [[ "${current_api_url}" != "${api_url}" ]] || [[ "${current_auth_url}" != "${auth_url}" ]] || [[ "${current_disable_auth}" != "${disable_auth_value}" ]]; then
        info "Patching console configmap (redirects → ${redirect_url}, API → ${api_url}, AUTH → ${auth_url}, DISABLE_AUTH → ${disable_auth_value})"
        kubectl --context "${CLUSTER_CONTEXT}" patch configmap amp-console -n wso2-amp --type merge \
            -p '{"data":{"SIGN_IN_REDIRECT_URL":"'"${redirect_url}"'","SIGN_OUT_REDIRECT_URL":"'"${redirect_url}"'","API_BASE_URL":"'"${api_url}"'","AUTH_BASE_URL":"'"${auth_url}"'","DISABLE_AUTH":"'"${disable_auth_value}"'"}}' >/dev/null
        needs_restart=true
    fi

    if [[ "${needs_restart}" == "true" ]]; then
        kubectl --context "${CLUSTER_CONTEXT}" rollout restart deployment/amp-console -n wso2-amp >/dev/null
        kubectl --context "${CLUSTER_CONTEXT}" rollout status deployment/amp-console -n wso2-amp --timeout="${WAIT_TIMEOUT_SECONDS}s" >/dev/null
        info "Console deployment restarted with updated config"
    fi

    # 2. Patch Thunder OAuth client redirect_uris
    local access_token
    access_token=$(get_thunder_token)
    [[ -n "${access_token}" ]] || die "Failed to obtain Thunder management token for redirect URL patch"

    thunder_console_app_id=$(get_thunder_console_app_id)
    [[ -n "${thunder_console_app_id}" ]] || die "Failed to resolve Thunder console application ID"

    local app_json
    app_json=$(kubectl --context "${CLUSTER_CONTEXT}" exec -n amp-thunder deployment/amp-thunder-extension-deployment -- sh -lc \
        "wget -qO- --header='Authorization: Bearer ${access_token}' http://localhost:8090/applications/${thunder_console_app_id}")

    if ! printf '%s' "${app_json}" | grep -q "localhost:${CONSOLE_LOCAL_PORT}/login"; then
        info "Patching Thunder OAuth client redirect_uris to port ${CONSOLE_LOCAL_PORT}"
        local updated_json
        updated_json=$(printf '%s' "${app_json}" | sed 's|localhost:[0-9]*/login|localhost:'"${CONSOLE_LOCAL_PORT}"'/login|g')
        kubectl --context "${CLUSTER_CONTEXT}" run -i --rm thunder-redirect-patch --image=curlimages/curl --restart=Never -- \
            -s -X PUT "http://amp-thunder-extension-service.amp-thunder.svc.cluster.local:8090/applications/${thunder_console_app_id}" \
            -H "Authorization: Bearer ${access_token}" \
            -H "Content-Type: application/json" \
            -d "${updated_json}" >/dev/null 2>&1
        info "Thunder OAuth client redirect_uris updated"
    fi
}

patch_thunder_runtime_config() {
    local console_url="http://localhost:${CONSOLE_LOCAL_PORT}"
    local expected_public_url="${THUNDER_LOCAL_BASE_URL}"
    local current_deployment_yaml
    local updated_deployment_yaml
    local current_gate_js
    local updated_gate_js
    local current_develop_js
    local updated_develop_js

    current_deployment_yaml=$(kubectl --context "${CLUSTER_CONTEXT}" get configmap amp-thunder-extension-config-map -n amp-thunder -o jsonpath='{.data.deployment\.yaml}' 2>/dev/null || true)
    [[ -n "${current_deployment_yaml}" ]] || die "Failed to read amp-thunder-extension-config-map deployment.yaml"

    updated_deployment_yaml=$(printf '%s' "${current_deployment_yaml}" | awk -v thunder_url="${expected_public_url}" -v thunder_port="${THUNDER_LOCAL_PORT}" -v console_url="${console_url}" '
        BEGIN { in_gate=0; in_jwt=0; in_cors=0; in_passkey=0 }
        {
            if ($0 ~ /^gate_client:/) { in_gate=1; in_jwt=0; in_cors=0; in_passkey=0 }
            else if ($0 ~ /^jwt:/) { in_gate=0; in_jwt=1; in_cors=0; in_passkey=0 }
            else if ($0 ~ /^cors:/) { in_gate=0; in_jwt=0; in_cors=1; in_passkey=0 }
            else if ($0 ~ /^passkey:/) { in_gate=0; in_jwt=0; in_cors=0; in_passkey=1 }
            else if ($0 ~ /^[a-z_]+:/ && $0 !~ /^gate_client:/ && $0 !~ /^jwt:/ && $0 !~ /^cors:/ && $0 !~ /^passkey:/) { in_gate=0; in_jwt=0; in_cors=0; in_passkey=0 }

            gsub(/public_url: "[^"]+"/, "public_url: \"" thunder_url "\"")
            if (in_gate && $0 ~ /^  hostname: /) { print "  hostname: \"localhost\""; next }
            if (in_gate && $0 ~ /^  port: /) { print "  port: " thunder_port; next }
            if (in_jwt && $0 ~ /^  issuer: /) { print "  issuer: \"" thunder_url "\""; next }
            if (in_cors && $0 ~ /^    - "http:\/\/localhost:[0-9]+"$/) { print "    - \"" console_url "\""; next }
            if (in_passkey && $0 ~ /^    - "https:\/\/localhost:[0-9]+"$/) { print "    - \"https://localhost:" thunder_port "\""; next }
            print
        }
    ')

    current_gate_js=$(kubectl --context "${CLUSTER_CONTEXT}" get configmap amp-thunder-extension-config-map -n amp-thunder -o jsonpath='{.data.gate-config\.js}' 2>/dev/null || true)
    current_develop_js=$(kubectl --context "${CLUSTER_CONTEXT}" get configmap amp-thunder-extension-config-map -n amp-thunder -o jsonpath='{.data.develop-config\.js}' 2>/dev/null || true)
    updated_gate_js=$(printf '%s' "${current_gate_js}" | sed -E 's|public_url: "http://[^"]+"|public_url: "'"${expected_public_url}"'"|g')
    updated_develop_js=$(printf '%s' "${current_develop_js}" | sed -E 's|public_url: "http://[^"]+"|public_url: "'"${expected_public_url}"'"|g')

    if [[ "${updated_deployment_yaml}" == "${current_deployment_yaml}" ]] && [[ "${updated_gate_js}" == "${current_gate_js}" ]] && [[ "${updated_develop_js}" == "${current_develop_js}" ]]; then
        info "Thunder runtime config already points to ${expected_public_url}"
        return 0
    fi

    info "Patching Thunder runtime config (public/auth URL → ${expected_public_url})"
    local tmp_payload
    tmp_payload=$(mktemp)
    cat >"${tmp_payload}" <<EOF
{
  "data": {
    "deployment.yaml": $(jq -Rs . <<<"${updated_deployment_yaml}"),
    "gate-config.js": $(jq -Rs . <<<"${updated_gate_js}"),
    "develop-config.js": $(jq -Rs . <<<"${updated_develop_js}")
  }
}
EOF
    kubectl --context "${CLUSTER_CONTEXT}" patch configmap amp-thunder-extension-config-map -n amp-thunder --type merge --patch-file "${tmp_payload}" >/dev/null
    rm -f "${tmp_payload}"

    kubectl --context "${CLUSTER_CONTEXT}" rollout restart deployment/amp-thunder-extension-deployment -n amp-thunder >/dev/null
    kubectl --context "${CLUSTER_CONTEXT}" rollout status deployment/amp-thunder-extension-deployment -n amp-thunder --timeout="${WAIT_TIMEOUT_SECONDS}s" >/dev/null
    info "Thunder deployment restarted with updated runtime config"
}

verify_thunder_user() {
    local users_response

    info "Verifying Thunder user ${THUNDER_VERIFY_USERNAME}"
    users_response=$(get_thunder_resource "/users")

    if ! printf '%s' "${users_response}" | grep -q '"username":"'"${THUNDER_VERIFY_USERNAME}"'"'; then
        die "Thunder user ${THUNDER_VERIFY_USERNAME} was not found after startup"
    fi
}

cleanup_stale_pid() {
    local pid_file="$1"

    if [[ -f "${pid_file}" ]]; then
        local pid
        pid=$(cat "${pid_file}")
        if kill -0 "${pid}" >/dev/null 2>&1; then
            kill "${pid}" >/dev/null 2>&1 || true
            sleep 1
        fi
        rm -f "${pid_file}"
    fi
}

port_served_by_k3d_lb() {
    local port="$1"
    lsof -iTCP:"${port}" -sTCP:LISTEN -Pn 2>/dev/null | grep -q gvproxy
}

ensure_port_free_or_known_forward() {
    local port="$1"
    local pattern="$2"

    if lsof -iTCP:"${port}" -sTCP:LISTEN -Pn >/dev/null 2>&1; then
        if pgrep -f "${pattern}" >/dev/null 2>&1; then
            info "Replacing existing port-forward on localhost:${port}"
            pkill -f "${pattern}" >/dev/null 2>&1 || true
            sleep 1
        else
            die "Port ${port} is already in use by another process"
        fi
    fi
}

start_port_forward() {
    local name="$1"
    local namespace="$2"
    local service="$3"
    local local_port="$4"
    local remote_port="$5"
    local pid_file="${PID_DIR}/${name}.pid"
    local log_file="${LOG_DIR}/${name}.log"
    local pattern="kubectl --context ${CLUSTER_CONTEXT} port-forward -n ${namespace} svc/${service} ${local_port}:${remote_port}"

    # If the port is already exposed by k3d's load balancer (gvproxy),
    # skip the port-forward — k3d is already routing traffic correctly.
    if port_served_by_k3d_lb "${local_port}"; then
        info "Port ${local_port} already served by k3d load balancer — skipping port-forward for ${name}"
        return 0
    fi

    cleanup_stale_pid "${pid_file}"
    ensure_port_free_or_known_forward "${local_port}" "${pattern}"

    info "Starting port-forward ${name} on localhost:${local_port}"
    nohup kubectl --context "${CLUSTER_CONTEXT}" port-forward -n "${namespace}" "svc/${service}" "${local_port}:${remote_port}" >"${log_file}" 2>&1 &
    echo $! >"${pid_file}"
    sleep 2

    if ! kill -0 "$(cat "${pid_file}")" >/dev/null 2>&1; then
        rm -f "${pid_file}"
        die "Failed to start port-forward ${name}. Check ${log_file}"
    fi
}

ensure_gateway_connector_python() {
    if "${GATEWAY_CONNECTOR_PYTHON_BIN}" -c "import websockets" >/dev/null 2>&1; then
        return 0
    fi

    if ! is_true "${GATEWAY_CONNECTOR_AUTO_SETUP}"; then
        die "Python runtime ${GATEWAY_CONNECTOR_PYTHON_BIN} is missing websockets and GATEWAY_CONNECTOR_AUTO_SETUP=false"
    fi

    need_cmd python3

    info "Preparing gateway connector Python runtime in ${GATEWAY_CONNECTOR_VENV_DIR}"
    if [[ ! -x "${GATEWAY_CONNECTOR_VENV_DIR}/bin/python3" ]]; then
        python3 -m venv "${GATEWAY_CONNECTOR_VENV_DIR}" >/dev/null 2>&1 || die "Failed to create venv at ${GATEWAY_CONNECTOR_VENV_DIR}"
    fi

    "${GATEWAY_CONNECTOR_VENV_DIR}/bin/python3" -m pip install --quiet --upgrade pip websockets >/dev/null 2>&1 || die "Failed to install websockets in ${GATEWAY_CONNECTOR_VENV_DIR}"
    GATEWAY_CONNECTOR_PYTHON_BIN="${GATEWAY_CONNECTOR_VENV_DIR}/bin/python3"
}

start_gateway_connector() {
    local pid_file="${PID_DIR}/gateway-connector.pid"
    local log_file="${LOG_DIR}/gateway-connector.log"
    local ws_url="wss://localhost:${GATEWAY_CONNECTOR_LOCAL_PORT}${GATEWAY_CONNECTOR_WS_PATH}"

    if ! is_true "${GATEWAY_CONNECTOR_ENABLED}"; then
        info "Gateway connector disabled (GATEWAY_CONNECTOR_ENABLED=${GATEWAY_CONNECTOR_ENABLED})"
        return 0
    fi

    [[ -n "${GATEWAY_CONNECTOR_API_KEY}" ]] || die "GATEWAY_CONNECTOR_API_KEY is required when GATEWAY_CONNECTOR_ENABLED=true"
    need_cmd "${GATEWAY_CONNECTOR_PYTHON_BIN}"
    ensure_gateway_connector_python

    cleanup_stale_pid "${pid_file}"

    info "Starting gateway connector to ${ws_url}"
    AMP_WS_URL="${ws_url}" \
    AMP_GATEWAY_API_KEY="${GATEWAY_CONNECTOR_API_KEY}" \
    nohup "${GATEWAY_CONNECTOR_PYTHON_BIN}" "${SCRIPT_DIR}/scripts/gateway_ws_connector.py" >"${log_file}" 2>&1 &

    echo $! >"${pid_file}"
    sleep 2

    if ! kill -0 "$(cat "${pid_file}")" >/dev/null 2>&1; then
        rm -f "${pid_file}"
        die "Gateway connector exited immediately. Check ${log_file}"
    fi
}

maybe_start_podman_machine() {
    need_cmd podman

    if podman info >/dev/null 2>&1; then
        info "Podman is already available"
        return
    fi

    info "Starting Podman machine"
    podman machine start >/dev/null 2>&1 || podman machine start podman-machine-default >/dev/null 2>&1 || true

    podman info >/dev/null 2>&1 || die "Podman is not available after attempting to start the machine"
}

start_cluster() {
    need_cmd k3d
    need_cmd kubectl

    if ! k3d cluster list | awk '{print $1}' | grep -qx "${CLUSTER_NAME}"; then
        die "k3d cluster ${CLUSTER_NAME} does not exist"
    fi

    info "Starting k3d cluster ${CLUSTER_NAME}"
    k3d cluster start "${CLUSTER_NAME}" >/dev/null 2>&1 || true

    wait_for_cluster
    kubectl config use-context "${CLUSTER_CONTEXT}" >/dev/null 2>&1
    kubectl --context "${CLUSTER_CONTEXT}" wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
}

warn_hosts_entry() {
    if ! grep -qE '(^|[[:space:]])thunder\.amp\.localhost([[:space:]]|$)' /etc/hosts; then
        warn "Missing thunder.amp.localhost in /etc/hosts"
    fi
}

main() {
    need_cmd lsof
    need_cmd jq

    set_step preparing-environment
    info "Preparing local AMP environment in ${SCRIPT_DIR}"

    set_step starting-podman
    maybe_start_podman_machine

    set_step starting-cluster
    start_cluster

    set_step cleaning-unhealthy-pods
    cleanup_unhealthy_pods

    set_step checking-hosts-entry
    warn_hosts_entry

    set_step waiting-for-thunder
    wait_for_rollout amp-thunder amp-thunder-extension-deployment

    set_step waiting-for-api
    wait_for_rollout wso2-amp amp-api

    set_step waiting-for-console
    wait_for_rollout wso2-amp amp-console

    set_step ensuring-platform-resources
    ensure_platform_resources

    set_step patching-thunder-config
    patch_thunder_runtime_config

    set_step patching-console-config
    patch_console_config

    set_step ensuring-thunder-user
    ensure_thunder_user

    set_step starting-console-port-forward
    start_port_forward amp-console wso2-amp amp-console "${CONSOLE_LOCAL_PORT}" 3000

    set_step starting-api-port-forward
    start_port_forward amp-api wso2-amp amp-api "${API_LOCAL_PORT}" 9000

    set_step starting-observability-port-forward
    start_port_forward obs-gateway-http openchoreo-data-plane obs-gateway-gateway-gateway-runtime "${OTEL_LOCAL_PORT}" 22893

    set_step starting-thunder-port-forward
    start_port_forward amp-thunder amp-thunder amp-thunder-extension-service "${THUNDER_LOCAL_PORT}" 8090

    set_step starting-gateway-manager-port-forward
    start_port_forward amp-api-gateway-manager "${GATEWAY_CONNECTOR_NAMESPACE}" "${GATEWAY_CONNECTOR_SERVICE}" "${GATEWAY_CONNECTOR_LOCAL_PORT}" "${GATEWAY_CONNECTOR_REMOTE_PORT}"

    set_step starting-gateway-connector
    start_gateway_connector

    set_step verifying-console-tcp
    wait_for_local_tcp console localhost "${CONSOLE_LOCAL_PORT}"

    set_step verifying-api-tcp
    wait_for_local_tcp api localhost "${API_LOCAL_PORT}"

    set_step verifying-otel-tcp
    wait_for_local_tcp otel localhost "${OTEL_LOCAL_PORT}"

    set_step verifying-thunder-tcp
    wait_for_local_tcp thunder localhost "${THUNDER_LOCAL_PORT}"

    set_step verifying-gateway-manager-tcp
    wait_for_local_tcp gateway-manager localhost "${GATEWAY_CONNECTOR_LOCAL_PORT}"

    set_step verifying-thunder-user
    verify_thunder_user

    set_step writing-status-file
    write_success_status

    info "AMP local stack is ready"
    info "Console: http://localhost:${CONSOLE_LOCAL_PORT}"
    info "API:     http://localhost:${API_LOCAL_PORT}"
    info "OTel:    http://localhost:${OTEL_LOCAL_PORT}/otel"
    info "Thunder: ${THUNDER_LOCAL_BASE_URL}"
    if is_true "${GATEWAY_CONNECTOR_ENABLED}"; then
        info "Gateway connector: wss://localhost:${GATEWAY_CONNECTOR_LOCAL_PORT}${GATEWAY_CONNECTOR_WS_PATH}"
    fi
    info "Port-forward logs: ${LOG_DIR}"
    info "Status file: ${STATUS_FILE}"
}

main "$@"