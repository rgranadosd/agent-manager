#!/bin/bash
set -e

# Removes an environment and uninstalls its API Platform Gateway.
#
# Usage:
#   remove-environment.sh staging
#
# This script is idempotent — safe to run multiple times.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Parse arguments ---
if [ -z "$1" ]; then
    echo "Usage: $0 <environment-name>"
    echo "  Example: $0 staging"
    exit 1
fi

ENV_NAME="$1"

if [ "$ENV_NAME" = "default" ]; then
    echo "❌ Cannot remove the default environment"
    exit 1
fi

# --- Configuration ---
ORG_NAME="${ORG_NAME:-default}"
AGENT_MANAGER_URL="${AGENT_MANAGER_URL:-http://localhost:9000}"
AGENT_MANAGER_API_URL="${AGENT_MANAGER_API_URL:-${AGENT_MANAGER_URL}/api/v1}"
IDP_TOKEN_URL="${IDP_TOKEN_URL:-http://thunder.amp.localhost:8080/oauth2/token}"
IDP_CLIENT_ID="${IDP_CLIENT_ID:-amp-api-client}"
IDP_CLIENT_SECRET="${IDP_CLIENT_SECRET:-amp-api-client-secret}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openchoreo-data-plane}"

RELEASE_NAME="api-platform-${ORG_NAME}-${ORG_NAME}-${ENV_NAME}"
RELEASE_NAME=$(echo "$RELEASE_NAME" | head -c 53 | sed 's/-$//')

echo "=== Removing Environment: ${ENV_NAME} ==="
echo ""

# --- Step 1: Uninstall the gateway helm release ---
echo "🌐 Uninstalling API Platform Gateway..."
if helm status "${RELEASE_NAME}" --namespace "${GATEWAY_NAMESPACE}" > /dev/null 2>&1; then
    helm uninstall "${RELEASE_NAME}" --namespace "${GATEWAY_NAMESPACE}"
    echo "✅ Gateway helm release uninstalled"
else
    echo "ℹ️  Gateway helm release '${RELEASE_NAME}' not found, skipping..."
fi

# Wait for gateway operator to clean up resources
GATEWAY_NAME="api-platform-${ORG_NAME}-${ENV_NAME}"
echo ""
echo "⏳ Waiting for gateway resources to be cleaned up..."
kubectl wait --for=delete "apigateway/${GATEWAY_NAME}" -n "${GATEWAY_NAMESPACE}" --timeout=120s 2>/dev/null || true
echo "✅ Gateway resources cleaned up"

# --- Step 2: Delete the environment via API ---
echo ""
echo "⏳ Checking Agent Manager is healthy..."
MAX_WAIT=30
ELAPSED=0
until curl -sf "${AGENT_MANAGER_URL}/healthz" > /dev/null 2>&1; do
    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        echo "❌ Agent Manager not reachable at ${AGENT_MANAGER_URL}/healthz after ${MAX_WAIT}s"
        exit 1
    fi
    sleep 3
    ELAPSED=$((ELAPSED + 3))
done

echo "🔑 Obtaining JWT..."
BASIC_AUTH=$(echo -n "${IDP_CLIENT_ID}:${IDP_CLIENT_SECRET}" | base64 | tr -d '\n')
TOKEN_RESPONSE=$(curl -sf -X POST "${IDP_TOKEN_URL}" \
    -H "Authorization: Basic ${BASIC_AUTH}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&scope=openid")

JWT=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)
if [ -z "$JWT" ]; then
    echo "❌ Failed to obtain JWT from ${IDP_TOKEN_URL}"
    exit 1
fi

echo ""
echo "🌍 Deleting environment '${ENV_NAME}'..."
DEL_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
    "${AGENT_MANAGER_API_URL}/orgs/${ORG_NAME}/environments/${ENV_NAME}" \
    -H "Authorization: Bearer ${JWT}")

if [ "$DEL_HTTP_CODE" = "204" ]; then
    echo "✅ Environment '${ENV_NAME}' deleted"
elif [ "$DEL_HTTP_CODE" = "404" ]; then
    echo "ℹ️  Environment '${ENV_NAME}' not found, already deleted"
else
    echo "⚠️  Failed to delete environment (HTTP ${DEL_HTTP_CODE})"
fi

echo ""
echo "=== Environment '${ENV_NAME}' removed ==="
