[server]
hostname = "__APIM_PUBLIC_HOSTNAME__"
offset = 10
base_path = "https://__APIM_PUBLIC_HOSTNAME__:9453"
server_role = "default"

[super_admin]
username = "__SUPER_ADMIN_USERNAME__"
password = "__SUPER_ADMIN_PASSWORD__"
create_admin_account = true

[user_store]
type = "database_unique_id"

[database.apim_db]
type = "h2"
url = "jdbc:h2:./repository/database/WSO2AM_DB;DB_CLOSE_ON_EXIT=FALSE"
username = "wso2carbon"
password = "wso2carbon"

[database.shared_db]
type = "h2"
url = "jdbc:h2:./repository/database/WSO2SHARED_DB;DB_CLOSE_ON_EXIT=FALSE"
username = "wso2carbon"
password = "wso2carbon"

[database.local]
url = "jdbc:h2:./repository/database/WSO2CARBON_DB;DB_CLOSE_ON_EXIT=FALSE"

[keystore.tls]
file_name = "wso2carbon-new.jks"
type = "JKS"
password = "__TLS_KEYSTORE_PASSWORD__"
alias = "__TLS_KEY_ALIAS__"
key_password = "__TLS_KEY_PASSWORD__"

[keystore.listener_profile]
bind_address = "0.0.0.0"

[apim]
gateway_type = "Regular,APK,AWS,Azure,Kong,Envoy"

[[apim.gateway.environment]]
name = "Default"
type = "hybrid"
gateway_type = "Regular"
provider = "wso2"
display_in_api_console = true
description = "Lab-safe cloned gateway environment."
show_as_token_endpoint_url = true
service_url = "https://__APIM_INTERNAL_MGMT_DNS__:9453/services/"
username = "${admin.username}"
password = "${admin.password}"
ws_endpoint = "ws://__APIM_PUBLIC_HOSTNAME__:9099"
wss_endpoint = "wss://__APIM_PUBLIC_HOSTNAME__:8099"
http_endpoint = "http://__APIM_PUBLIC_HOSTNAME__:8290"
https_endpoint = "https://__APIM_PUBLIC_HOSTNAME__:8253"
websub_event_receiver_http_endpoint = "http://__APIM_PUBLIC_HOSTNAME__:9021"
websub_event_receiver_https_endpoint = "https://__APIM_PUBLIC_HOSTNAME__:8021"

# Match local APIM config: keep gateway labels list. Removing this triggers the
# GatewayStartupListener NPE that we saw when the cluster booted with enable=false.
[apim.sync_runtime_artifacts.gateway]
gateway_labels = ["Default"]

[apim.analytics]
enable = true
type = "moesif"

[apim.analytics.properties]
moesifKey = "__MOESIF_KEY__"

[apim.key_manager]
enable_lightweight_apikey_generation = true

[apim.cors]
allow_origins = "*"
allow_methods = ["GET", "PUT", "POST", "DELETE", "PATCH", "OPTIONS"]
allow_headers = ["authorization", "Access-Control-Allow-Origin", "Content-Type", "SOAPAction", "apikey", "Internal-Key"]
allow_credentials = false

[apim.devportal]
url = "https://__APIM_PUBLIC_HOSTNAME__:9453/devportal"

[[event_handler]]
name = "userPostSelfRegistration"
subscriptions = ["POST_ADD_USER"]

[service_provider]
sp_name_regex = "^[\\sa-zA-Z0-9._-]*$"

[[event_listener]]
id = "token_revocation"
type = "org.wso2.carbon.identity.core.handler.AbstractIdentityHandler"
name = "org.wso2.is.notification.ApimOauthEventInterceptor"
order = 1

[event_listener.properties]
notification_endpoint = "https://__APIM_INTERNAL_MGMT_DNS__:9453/internal/data/v1/notify"
username = "${admin.username}"
password = "${admin.password}"
'header.X-WSO2-KEY-MANAGER' = "default"

[oauth.grant_type.token_exchange]
enable = true
allow_refresh_tokens = true
iat_validity_period = "1h"

[apim.ai]
enable = true

[apim.ai.embedding_provider]
type = "openai"

[apim.ai.embedding_provider.properties]
embedding_endpoint = "https://api.openai.com/v1/embeddings"
apikey = "__OPENAI_API_KEY__"
embedding_model = "text-embedding-ada-002"

[[apim.ai.guardrail_provider]]
type = "azure-contentsafety"

[apim.ai.guardrail_provider.properties]
endpoint = "__AZURE_CONTENT_SAFETY_ENDPOINT__"
key = "__AZURE_CONTENT_SAFETY_KEY__"

[[apim.ai.mcp_server]]
name = "weather_mcp"
enabled = true

[apim.ai.mcp_server.properties]
url = "__MCP_SERVER_URL__"
protocol = "streamable-http"

[apim.ai.vector_db_provider]
type = "zilliz"

[apim.ai.vector_db_provider.properties]
uri = "__ZILLIZ_URI__"
token = "__ZILLIZ_TOKEN__"
embedding_dimension = "1536"
ttl = "3600"

[apim.open_telemetry.remote_tracer]
enable = true
name = "otlp"
url = "__OTLP_GRPC_ENDPOINT__"
hostname = "__OTLP_HOSTNAME__"
port = "__OTLP_PORT__"

[apim.open_telemetry.log_tracer]
enable = false

[[apim.open_telemetry.resource_attributes]]
name = "service.name"
value = "wso2-apim-gateway"

[[apim.open_telemetry.resource_attributes]]
name = "deployment.environment"
value = "lab"