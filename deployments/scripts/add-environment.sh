#!/bin/bash
set -e

# Creates a new environment and installs its API Platform Gateway.
#
# Usage:
#   add-environment.sh "Staging Environment"
#   add-environment.sh "Production" --production
#
# The environment name is derived from the display name by lowercasing
# and replacing spaces/special characters with hyphens (e.g. "Staging Environment" → "staging-environment").
#
# Prerequisites:
#   - Agent Manager must be running (docker-compose or in-cluster)
#   - The default environment and gateway must already be set up (via setup-gateway.sh)
#   - kubectl and helm must be configured

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Parse arguments ---
if [ -z "$1" ]; then
    echo "Usage: $0 <display-name> [--production]"
    echo "  Example: $0 \"Staging Environment\""
    echo "  Example: $0 \"Production\" --production"
    exit 1
fi

DISPLAY_NAME="$1"
IS_PRODUCTION=false
if [ "$2" = "--production" ]; then
    IS_PRODUCTION=true
fi

# Derive environment name from display name: lowercase, replace non-alphanumeric with hyphens, trim
ENV_NAME=$(echo "$DISPLAY_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//')

if [ -z "$ENV_NAME" ]; then
    echo "❌ Could not derive environment name from display name: $DISPLAY_NAME"
    exit 1
fi

if [ ${#ENV_NAME} -gt 25 ]; then
    echo "❌ Environment name '${ENV_NAME}' is ${#ENV_NAME} characters (max 25)"
    echo "   Use a shorter display name."
    exit 1
fi

# --- Configuration (can be overridden via env vars) ---
ORG_NAME="${ORG_NAME:-default}"
DATAPLANE_REF="${DATAPLANE_REF:-default}"
AGENT_MANAGER_URL="${AGENT_MANAGER_URL:-http://localhost:9000}"
AGENT_MANAGER_API_URL="${AGENT_MANAGER_API_URL:-${AGENT_MANAGER_URL}/api/v1}"
IDP_TOKEN_URL="${IDP_TOKEN_URL:-http://thunder.amp.localhost:8080/oauth2/token}"
IDP_CLIENT_ID="${IDP_CLIENT_ID:-amp-api-client}"
IDP_CLIENT_SECRET="${IDP_CLIENT_SECRET:-amp-api-client-secret}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openchoreo-data-plane}"

# For helm: how the gateway controller reaches agent-manager
AGENT_MANAGER_INTERNAL_API="${AGENT_MANAGER_INTERNAL_API:-http://host.docker.internal:9000/api/v1}"
AGENT_MANAGER_INTERNAL_CP="${AGENT_MANAGER_INTERNAL_CP:-host.docker.internal:9243}"
AGENT_MANAGER_INTERNAL_JWKS="${AGENT_MANAGER_INTERNAL_JWKS:-http://host.docker.internal:9000/auth/external/jwks.json}"

echo "=== Adding Environment: ${DISPLAY_NAME} (${ENV_NAME}) ==="
echo ""

# --- Step 0: Verify Agent Manager is reachable ---
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
echo "✅ Agent Manager is healthy"

# --- Step 1: Get JWT from Thunder IDP ---
echo ""
echo "🔑 Obtaining JWT..."
BASIC_AUTH=$(echo -n "${IDP_CLIENT_ID}:${IDP_CLIENT_SECRET}" | base64 | tr -d '\n')
TOKEN_RESPONSE=$(curl -sf -X POST "${IDP_TOKEN_URL}" \
    -H "Authorization: Basic ${BASIC_AUTH}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&scope=openid")

JWT=$(echo "$TOKEN_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)
if [ -z "$JWT" ]; then
    echo "❌ Failed to obtain JWT from ${IDP_TOKEN_URL}"
    echo "   Response: ${TOKEN_RESPONSE}"
    exit 1
fi
echo "✅ JWT obtained"

AUTH_HEADER="Authorization: Bearer ${JWT}"

# --- Step 2: Create environment ---
echo ""
echo "🌍 Creating environment '${ENV_NAME}'..."
ENV_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${AGENT_MANAGER_API_URL}/orgs/${ORG_NAME}/environments" \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "{
        \"name\": \"${ENV_NAME}\",
        \"displayName\": \"${DISPLAY_NAME}\",
        \"dataplaneRef\": \"${DATAPLANE_REF}\",
        \"dnsPrefix\": \"${ENV_NAME}\",
        \"isProduction\": ${IS_PRODUCTION}
    }")

ENV_HTTP_CODE=$(echo "$ENV_RESPONSE" | tail -1)
ENV_BODY=$(echo "$ENV_RESPONSE" | sed '$d')

if [ "$ENV_HTTP_CODE" = "201" ]; then
    echo "✅ Environment '${ENV_NAME}' created"
elif [ "$ENV_HTTP_CODE" = "409" ]; then
    echo "ℹ️  Environment '${ENV_NAME}' already exists, continuing..."
else
    echo "❌ Failed to create environment (HTTP ${ENV_HTTP_CODE})"
    echo "   Response: ${ENV_BODY}"
    exit 1
fi

# --- Step 3: Helm install the gateway ---

echo ""
echo "🌐 Installing API Platform Gateway for '${ENV_NAME}'..."

RELEASE_NAME="api-platform-${ORG_NAME}-${ORG_NAME}-${ENV_NAME}"
# Truncate to 53 chars to stay within Helm's 53-char release name limit
RELEASE_NAME=$(echo "$RELEASE_NAME" | head -c 53 | sed 's/-$//')

helm upgrade --install "${RELEASE_NAME}" \
    "${SCRIPT_DIR}/../helm-charts/wso2-amp-api-platform-gateway-extension" \
    --namespace "${GATEWAY_NAMESPACE}" \
    --set agentManager.orgName="${ORG_NAME}" \
    --set gateway.environment="${ENV_NAME}" \
    --set gateway.displayName="${DISPLAY_NAME} API Platform Gateway" \
    --set gateway.vhost="http://${ENV_NAME}-${ORG_NAME}.gateway.localhost:19080" \
    --set agentManager.apiUrl="${AGENT_MANAGER_INTERNAL_API}" \
    --set apiGateway.controlPlane.host="${AGENT_MANAGER_INTERNAL_CP}" \
    --set apiGateway.controlPlane.tls.insecureSkipVerify=true \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].name=agent-manager-service" \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].issuer=agent-manager-service" \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].jwks.remote.uri=${AGENT_MANAGER_INTERNAL_JWKS}" \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[0].jwks.remote.skipTlsVerify=true" \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].name=ThunderKeyManager" \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].issuer=http://thunder.amp.localhost:8080" \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].jwks.remote.uri=http://amp-thunder-extension-service.amp-thunder:8090/oauth2/jwks" \
    --set "apiGateway.config.policyConfigurations.jwtauth_v1.keymanagers[1].jwks.remote.skipTlsVerify=true"

# --- Step 4: Wait for gateway to be ready ---
GATEWAY_NAME="api-platform-${ORG_NAME}-${ENV_NAME}"
echo ""
echo "⏳ Waiting for gateway '${GATEWAY_NAME}' to be ready..."
if kubectl wait --for=condition=Programmed "apigateway/${GATEWAY_NAME}" -n "${GATEWAY_NAMESPACE}" --timeout=180s 2>/dev/null; then
    echo "✅ Gateway is programmed"
else
    echo "⚠️  Gateway did not become ready in time — check: kubectl get apigateway ${GATEWAY_NAME} -n ${GATEWAY_NAMESPACE}"
fi

echo ""
echo "=== Environment '${ENV_NAME}' setup complete ==="
echo ""
echo "  Environment:  ${ENV_NAME}"
echo "  Display Name: ${DISPLAY_NAME}"
echo "  Gateway Host: ${ENV_NAME}-${ORG_NAME}.gateway.localhost:19080"
echo "  Promotion:    default → ${ENV_NAME}"
echo ""
