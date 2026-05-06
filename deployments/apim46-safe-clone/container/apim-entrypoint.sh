#!/usr/bin/env bash
set -euo pipefail

WSO2_SERVER_HOME="${WSO2_SERVER_HOME:-/home/wso2carbon/wso2am-4.6.0}"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-/opt/wso2/bootstrap}"

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

require_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    echo "Missing required file: ${path}" >&2
    exit 1
  fi
}

copy_dir_contents() {
  local src="$1"
  local dest="$2"

  if [ ! -d "$src" ]; then
    return 0
  fi

  mkdir -p "$dest"

  find "$src" -mindepth 1 -maxdepth 1 -exec cp -R {} "$dest"/ \;
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\\/&|]/\\&/g'
}

render_template() {
  local template_path="$BOOTSTRAP_DIR/deployment.toml.tpl"
  local target_path="$WSO2_SERVER_HOME/repository/conf/deployment.toml"
  local rendered

  require_file "$template_path"

  require_env APIM_PUBLIC_HOSTNAME
  require_env APIM_INTERNAL_MGMT_DNS
  require_env SUPER_ADMIN_USERNAME
  require_env SUPER_ADMIN_PASSWORD
  require_env TLS_KEYSTORE_PASSWORD
  require_env TLS_KEY_ALIAS
  require_env TLS_KEY_PASSWORD
  require_env MOESIF_KEY
  require_env OPENAI_API_KEY
  require_env AZURE_CONTENT_SAFETY_ENDPOINT
  require_env AZURE_CONTENT_SAFETY_KEY
  require_env MCP_SERVER_URL
  require_env ZILLIZ_URI
  require_env ZILLIZ_TOKEN
  require_env OTLP_GRPC_ENDPOINT
  require_env OTLP_HOSTNAME
  require_env OTLP_PORT

  rendered="$(cat "$template_path")"

  rendered="$(printf '%s' "$rendered" | sed "s|__APIM_PUBLIC_HOSTNAME__|$(escape_sed_replacement "$APIM_PUBLIC_HOSTNAME")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__APIM_INTERNAL_MGMT_DNS__|$(escape_sed_replacement "$APIM_INTERNAL_MGMT_DNS")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__SUPER_ADMIN_USERNAME__|$(escape_sed_replacement "$SUPER_ADMIN_USERNAME")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__SUPER_ADMIN_PASSWORD__|$(escape_sed_replacement "$SUPER_ADMIN_PASSWORD")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__TLS_KEYSTORE_PASSWORD__|$(escape_sed_replacement "$TLS_KEYSTORE_PASSWORD")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__TLS_KEY_ALIAS__|$(escape_sed_replacement "$TLS_KEY_ALIAS")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__TLS_KEY_PASSWORD__|$(escape_sed_replacement "$TLS_KEY_PASSWORD")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__MOESIF_KEY__|$(escape_sed_replacement "$MOESIF_KEY")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__OPENAI_API_KEY__|$(escape_sed_replacement "$OPENAI_API_KEY")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__AZURE_CONTENT_SAFETY_ENDPOINT__|$(escape_sed_replacement "$AZURE_CONTENT_SAFETY_ENDPOINT")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__AZURE_CONTENT_SAFETY_KEY__|$(escape_sed_replacement "$AZURE_CONTENT_SAFETY_KEY")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__MCP_SERVER_URL__|$(escape_sed_replacement "$MCP_SERVER_URL")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__ZILLIZ_URI__|$(escape_sed_replacement "$ZILLIZ_URI")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__ZILLIZ_TOKEN__|$(escape_sed_replacement "$ZILLIZ_TOKEN")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__OTLP_GRPC_ENDPOINT__|$(escape_sed_replacement "$OTLP_GRPC_ENDPOINT")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__OTLP_HOSTNAME__|$(escape_sed_replacement "$OTLP_HOSTNAME")|g")"
  rendered="$(printf '%s' "$rendered" | sed "s|__OTLP_PORT__|$(escape_sed_replacement "$OTLP_PORT")|g")"

  printf '%s\n' "$rendered" > "$target_path"
}

main() {
  require_file "$BOOTSTRAP_DIR/security/wso2carbon-new.jks"
  require_file "$BOOTSTRAP_DIR/security/client-truststore.jks"

  render_template
  copy_dir_contents "$BOOTSTRAP_DIR/security" "$WSO2_SERVER_HOME/repository/resources/security"
  copy_dir_contents "$BOOTSTRAP_DIR/sequences" "$WSO2_SERVER_HOME/repository/deployment/server/synapse-configs/default/sequences"

  exec "$WSO2_SERVER_HOME/bin/api-manager.sh"
}

main "$@"