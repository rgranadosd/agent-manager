# Current Live APIM Inventory

This inventory was collected in read-only mode from the local APIM installation that exists outside the cluster.

## Verified runtime identity

- Product: WSO2 API Manager.
- Exact version: 4.6.0.
- Release date in `release-notes.html`: 4th November 2025.
- `APIM_HOME`: `/Users/rafagranados/Develop/wso2/wso2am-4.6.0`.

## Effective deployment.toml findings

- `server.hostname = "localhost"`
- `offset = 10`
- `server_role = "default"`
- `super_admin.username = "admin"`
- `super_admin.password` present in plaintext and must move to a lab secret.
- `user_store.type = "database_unique_id"`

### Databases

- `database.apim_db.type = "h2"`
- `database.apim_db.url = jdbc:h2:./repository/database/WSO2AM_DB;DB_CLOSE_ON_EXIT=FALSE`
- `database.shared_db.type = "h2"`
- `database.shared_db.url = jdbc:h2:./repository/database/WSO2SHARED_DB;DB_CLOSE_ON_EXIT=FALSE`
- `database.local.url = jdbc:h2:./repository/database/WSO2CARBON_DB;DB_CLOSE_ON_EXIT=FALSE`

### Keystores and truststores

- Active TLS keystore file: `wso2carbon-new.jks`
- TLS keystore type: `JKS`
- TLS alias: `wso2carbon`
- TLS keystore password and key password are present in plaintext and must move to a secret.

Files found under `repository/resources/security`:

- `client-truststore-temp.jks`
- `client-truststore.jks`
- `wso2carbon-new.cer`
- `wso2carbon-new.jks`
- `wso2carbon.jks`

### Gateway and portal endpoints

- Gateway type list: `Regular, APK, AWS, Azure, Kong, Envoy`
- Default gateway label: `Default`
- `service_url` points to the local management endpoint.
- `http_endpoint` and `https_endpoint` point to localhost with the live port offset.
- DevPortal URL points to the local management endpoint.

### Analytics and AI dependencies

- Analytics enabled.
- Analytics type: `moesif`.
- `moesifKey` present in plaintext and must move to a secret.
- AI enabled.
- Embedding provider: OpenAI.
- OpenAI API key present in plaintext and must move to a secret.
- Guardrail provider: Azure Content Safety.
- Azure Content Safety endpoint configured.
- Azure Content Safety key present in plaintext and must move to a secret.
- External MCP server configured over HTTP.
- Vector DB provider: Zilliz.
- Zilliz token present in plaintext and must move to a secret.
- OpenTelemetry remote tracer enabled and configured to send to OTLP on localhost.

### Identity and directory dependencies

- No external LDAP or AD configuration was found in the effective `deployment.toml`.
- User store is DB-backed.
- No SMTP section is enabled in the effective `deployment.toml`.
- Internal key manager settings are active with lightweight API key generation enabled.

## On-disk database files found

Files under `repository/database`:

- `WSO2AM_DB.mv.db`
- `WSO2AM_DB.trace.db`
- `WSO2CARBON_DB.mv.db`
- `WSO2CARBON_DB.trace.db`
- `WSO2MB_DB.mv.db`
- `WSO2MB_DB.mv.db.bak`
- `WSO2METRICS_DB.mv.db`
- `WSO2SHARED_DB.mv.db`
- `WSO2SHARED_DB.mv.db.bak`
- `WSO2SHARED_DB.trace.db`

Important: a previous trace file already recorded H2 file locking against the live `WSO2SHARED_DB.mv.db`, which is strong evidence that the lab clone must only use an offline copy and not direct live access.

## Custom libraries and extensions found

### repository/components/dropins

- `InputSanitizationMediator.jar`
- `InputSanitizationMediator_1.0.0.jar`
- `andes_client_3.3.36_1.0.0.jar`
- `aspectjweaver_1.8.7_1.0.0.jar`
- `encoder_1.1_1.0.0.jar`
- `httpmime_4.3.6_1.0.0.jar`
- `javax.jms_api_2.0.1_1.0.0.jar`
- `org.wso2.carbon.identity.oauth2.grant.jwt-2.2.4.jar`
- `org.wso2.carbon.identity.oauth2.token.handler.clientauth.mutualtls-2.4.38.jar`
- `org.wso2.charon3.core-4.0.23.jar`
- `org.wso2.securevault_1.1.3_1.0.0.jar`

### repository/components/lib

- `andes-client-3.3.36.jar`
- `aspectjweaver-1.8.7.jar`
- `encoder-1.1.jar`
- `httpmime-4.3.6.jar`
- `javax.jms-api-2.0.1.jar`
- `org.wso2.securevault-1.1.3.jar`

## Synapse and deployment artifacts found

Under `repository/deployment/server/synapse-configs/default/sequences`:

- `InputSanitizationPolicy.xml`
- `WSO2AM--Ext--In.xml`
- Standard built-in fault and dispatch sequences.

Observed custom sequence behavior:

- `WSO2AM--Ext--In.xml` invokes `InputSanitizationPolicy` globally.
- `InputSanitizationPolicy.xml` loads the custom class `com.example.apim.guardrails.InputSanitizationMediator`.

## Webapps and custom web applications

Under `repository/deployment/server/webapps` only default APIM webapps and sample apps were observed. No additional custom webapp package was identified from this quick inventory.

## Tenants and DB-resident artifacts

- `repository/tenants` is empty on disk.
- Tenant, API, application, and subscription inventory is therefore expected to live in the H2 databases.
- To avoid touching the live H2 files, tenants and DB-resident policies were not enumerated directly from the running live database.
- The correct place to audit those objects is the restored lab database copy.

## External dependencies currently implied by the live config

- Local H2 database files.
- Moesif analytics.
- OpenAI embeddings.
- Azure Content Safety.
- External MCP server.
- External Zilliz vector database.
- OTLP collector.

## Safe cloning conclusion

The live installation is a single-node, H2-backed APIM 4.6.0 with custom mediator and Synapse artifacts. The least risky clone path is:

1. Copy configuration and custom artifacts.
2. Copy keystores into a separate lab secret.
3. Restore an offline H2 snapshot into a separate PVC.
4. Boot a single lab instance inside K3s using that copied state only.