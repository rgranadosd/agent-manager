# WSO2 API Manager 4.6 Safe Clone for K3s Lab

This bundle creates an isolated APIM 4.6 lab clone for K3s/k3d without reusing the live installation or the live database in place.

## Design choice

- Keep the live APIM installation untouched.
- Build a lab image from the official WSO2 APIM 4.6 base image.
- Keep secrets and keystores out of the image.
- Restore the database only from an offline H2 copy or from an existing backup snapshot.
- Run a single replica with a `Recreate` strategy to avoid concurrent H2 access.
- Fail startup if the cloned database files are missing, so the lab never silently initializes against a fresh or wrong database.

## What was verified from the current installation

See `CURRENT-LIVE-INVENTORY.md` in this same folder. The important verified facts are:

- Exact version: WSO2 API Manager 4.6.0.
- Live `APIM_HOME`: `/Users/rafagranados/Develop/wso2/wso2am-4.6.0`.
- Effective database mode: local H2 files under `repository/database`.
- Port offset: `10`.
- Active TLS keystore: `wso2carbon-new.jks`.
- Custom Synapse artifacts present: `InputSanitizationPolicy.xml` and `WSO2AM--Ext--In.xml`.
- Custom mediator JARs present in `repository/components/dropins`.

## Safe source material to extract from the live install

Copy these items only. Do not run the lab directly against the live paths.

### Non-sensitive artifacts safe to copy into the image

- `repository/components/dropins/*.jar`
- `repository/components/lib/*.jar`

Use the helper script:

```bash
export APIM_HOME=/Users/rafagranados/Develop/wso2/wso2am-4.6.0
cd /Users/rafagranados/Develop/wso2/agent-manager/agent-manager
bash deployments/apim46-safe-clone/scripts/extract-safe-overlay.sh
```

### Sensitive or stateful artifacts that must stay outside the image

- `repository/conf/deployment.toml`
- `repository/resources/security/wso2carbon-new.jks`
- `repository/resources/security/wso2carbon-new.cer`
- `repository/resources/security/client-truststore.jks`
- `repository/resources/security/client-truststore-temp.jks`
- `repository/resources/security/wso2carbon.jks`
- `repository/database/WSO2AM_DB.mv.db`
- `repository/database/WSO2SHARED_DB.mv.db`
- `repository/database/WSO2CARBON_DB.mv.db`
- `repository/database/WSO2MB_DB.mv.db`
- `repository/database/WSO2METRICS_DB.mv.db`

### Preferred database copy method

Because the live setup uses H2, the least risky lab restore is a cold copy from an already stopped instance or from a frozen backup snapshot. Do not copy the live `*.mv.db` files while APIM is running.

If the existing backup tree is current enough for your lab, prefer that over touching the live database files.

## What not to copy directly from production or from the live instance

- Live H2 files while APIM is running.
- Access tokens, refresh tokens, and active client secrets for real consumers.
- Analytics credentials unless the lab must emit to the same analytics backend.
- External provider API keys unless the lab actually needs them.
- Private keys and keystore passwords unless preserving trust compatibility is a hard requirement.
- User data or API subscriptions containing PII unless the lab is isolated and the data is authorized for lab use.

## What is safe to copy as-is

- Product version and binary layout.
- Non-sensitive JAR customizations.
- Non-sensitive Synapse sequences.
- Public certificates.
- Database schema and API metadata, but only inside a separate lab database copy.

## What should be regenerated or rotated if possible

- `SUPER_ADMIN_PASSWORD` after the first successful lab boot.
- OAuth client secrets used by real integrations.
- API keys for OpenAI, Azure Content Safety, Zilliz, and analytics providers.
- Private keys and JKS passwords if external token signature compatibility is not required.

## Build the lab image

The default Dockerfile uses the official WSO2 private registry image as the least risky base because it preserves the supported APIM runtime layout.

```bash
export REPO_ROOT=/Users/rafagranados/Develop/wso2/agent-manager/agent-manager
cd "$REPO_ROOT"

podman login registry.wso2.com

podman build \
  --platform linux/amd64 \
  --build-arg WSO2_APIM_BASE=registry.wso2.com/wso2-apim/am:4.6.0.0 \
  -t localhost/apim46-lab:4.6.0-safe \
  -f deployments/apim46-safe-clone/Dockerfile \
  .

podman save \
  --format docker-archive \
  -o /tmp/apim46-lab_4.6.0-safe.tar \
  localhost/apim46-lab:4.6.0-safe

k3d image import /tmp/apim46-lab_4.6.0-safe.tar -c amp-local
```

## Fallback build without WSO2 registry login

If `registry.wso2.com` login is not available, you can still build a lab image from a sanitized local copy of the existing APIM 4.6.0 product home.

This fallback keeps the same safety model:

- no live database files in the image,
- no keystores or truststores in the image,
- no `deployment.toml` from the live instance in the image.

Prepare the local product-home staging area:

```bash
export APIM_HOME=/Users/rafagranados/Develop/wso2/wso2am-4.6.0
cd /Users/rafagranados/Develop/wso2/agent-manager/agent-manager
bash deployments/apim46-safe-clone/scripts/stage-local-product-home.sh
```

Build the fallback image:

```bash
podman build \
  --platform linux/amd64 \
  -t localhost/apim46-lab:4.6.0-safe-local \
  -f deployments/apim46-safe-clone/Dockerfile.local-source \
  .

podman save \
  --format docker-archive \
  -o /tmp/apim46-lab_4.6.0-safe-local.tar \
  localhost/apim46-lab:4.6.0-safe-local

k3d image import /tmp/apim46-lab_4.6.0-safe-local.tar -c amp-local
```

## Prepare secrets and the cloned database

Create the namespace first.

```bash
kubectl apply -f deployments/apim46-safe-clone/k8s/00-namespace.yaml
```

Create the literal secret from the example manifest after replacing the placeholders, or use direct commands like this:

```bash
kubectl -n apim46-lab create secret generic apim46-lab-env \
  --from-literal=SUPER_ADMIN_USERNAME=admin \
  --from-literal=SUPER_ADMIN_PASSWORD='replace-with-the-cloned-admin-password' \
  --from-literal=TLS_KEYSTORE_PASSWORD='replace-with-keystore-password' \
  --from-literal=TLS_KEY_ALIAS='wso2carbon' \
  --from-literal=TLS_KEY_PASSWORD='replace-with-key-password' \
  --from-literal=MOESIF_KEY='replace-if-you-need-moesif' \
  --from-literal=OPENAI_API_KEY='replace-if-you-need-openai' \
  --from-literal=AZURE_CONTENT_SAFETY_ENDPOINT='https://replace-me.cognitiveservices.azure.com/' \
  --from-literal=AZURE_CONTENT_SAFETY_KEY='replace-if-you-need-azure-content-safety' \
  --from-literal=MCP_SERVER_URL='http://mcp-service.default.svc.cluster.local:8080/mcp' \
  --from-literal=ZILLIZ_URI='http://milvus.default.svc.cluster.local:19530' \
  --from-literal=ZILLIZ_TOKEN='replace-if-you-need-zilliz' \
  --from-literal=OTLP_GRPC_ENDPOINT='http://otel-collector.openchoreo-observability-plane.svc.cluster.local:4317' \
  --from-literal=OTLP_HOSTNAME='otel-collector.openchoreo-observability-plane.svc.cluster.local' \
  --from-literal=OTLP_PORT='4317'
```

Create the keystore secret from copied files, not from the live path mounted into the cluster:

```bash
kubectl -n apim46-lab create secret generic apim46-lab-keystores \
  --from-file=wso2carbon-new.jks="$APIM_HOME/repository/resources/security/wso2carbon-new.jks" \
  --from-file=wso2carbon-new.cer="$APIM_HOME/repository/resources/security/wso2carbon-new.cer" \
  --from-file=client-truststore.jks="$APIM_HOME/repository/resources/security/client-truststore.jks" \
  --from-file=client-truststore-temp.jks="$APIM_HOME/repository/resources/security/client-truststore-temp.jks" \
  --from-file=wso2carbon.jks="$APIM_HOME/repository/resources/security/wso2carbon.jks"
```

Create the PVC and a temporary loader pod.

```bash
kubectl apply -f deployments/apim46-safe-clone/k8s/03-db-pvc.yaml
kubectl apply -f deployments/apim46-safe-clone/k8s/04-db-loader-pod.yaml
kubectl -n apim46-lab wait --for=condition=Ready pod/apim46-lab-db-loader --timeout=120s
```

Only after you have an offline DB copy, upload it into the PVC:

```bash
mkdir -p /tmp/apim46-lab-db-snapshot
cp "$APIM_HOME/repository/database/WSO2AM_DB.mv.db" /tmp/apim46-lab-db-snapshot/
cp "$APIM_HOME/repository/database/WSO2SHARED_DB.mv.db" /tmp/apim46-lab-db-snapshot/
cp "$APIM_HOME/repository/database/WSO2CARBON_DB.mv.db" /tmp/apim46-lab-db-snapshot/
cp "$APIM_HOME/repository/database/WSO2MB_DB.mv.db" /tmp/apim46-lab-db-snapshot/
cp "$APIM_HOME/repository/database/WSO2METRICS_DB.mv.db" /tmp/apim46-lab-db-snapshot/

kubectl -n apim46-lab cp /tmp/apim46-lab-db-snapshot/. apim46-lab-db-loader:/restore/
kubectl -n apim46-lab delete pod apim46-lab-db-loader
```

If the live APIM is running, do not use the commands above directly. Replace the source with a stopped-instance copy or with the existing backup snapshot.

## Deploy in K3s or k3d

```bash
cd /Users/rafagranados/Develop/wso2/agent-manager/agent-manager

kubectl apply -k deployments/apim46-safe-clone/k8s
kubectl -n apim46-lab rollout status deployment/apim46-lab --timeout=15m
```

## Access the lab APIM

Use port-forward instead of exposing it publicly by default.

```bash
kubectl -n apim46-lab port-forward svc/apim46-lab-mgmt 9453:9453
kubectl -n apim46-lab port-forward svc/apim46-lab-gateway 8253:8253 8290:8290
```

Publisher, DevPortal, and Admin will then be reachable through `https://localhost:9453`.

## Smoke tests

### Startup and health

```bash
kubectl -n apim46-lab get pods
kubectl -n apim46-lab logs deployment/apim46-lab --tail=200
curl -k https://localhost:9453/services/Version
```

Success criteria:

- Pod reaches `Ready`.
- Logs show normal Carbon startup.
- `services/Version` returns successfully.

### Publisher, DevPortal, Admin

```bash
curl -k -I https://localhost:9453/publisher
curl -k -I https://localhost:9453/devportal
curl -k -I https://localhost:9453/admin
```

Success criteria:

- All three endpoints respond over HTTPS.

### Database clone loaded

```bash
kubectl -n apim46-lab exec deploy/apim46-lab -- ls -1 /home/wso2carbon/wso2am-4.6.0/repository/database
```

Success criteria:

- The restored `WSO2AM_DB.mv.db`, `WSO2SHARED_DB.mv.db`, and `WSO2CARBON_DB.mv.db` files are present in the mounted path.

### APIs, applications, and subscriptions visible

- Sign in to Publisher and DevPortal.
- Confirm the expected APIs, applications, and subscriptions exist in the lab clone.
- If tenant-scoped artifacts are missing, stop and audit the restored DB copy before changing any config.

### Token issuance and validation

- Use a lab-only application if possible.
- Mint a token from the lab APIM.
- Invoke a simple API through `https://localhost:8253`.

Success criteria:

- Token creation succeeds in the lab.
- A known API returns the expected response through the lab gateway.

### Custom agent connectivity inside K3s

From the agent namespace, target the gateway service directly:

```bash
kubectl -n wso2-amp run apim46-test-client \
  --rm -it --restart=Never \
  --image=curlimages/curl:8.12.1 \
  -- curl -k https://apim46-lab-gateway.apim46-lab.svc.cluster.local:8253/
```

Success criteria:

- The agent namespace can reach the gateway service on `8253`.

## Rollback

This bundle is reversible because it never mutates the live APIM installation.

```bash
kubectl delete -k deployments/apim46-safe-clone/k8s
kubectl -n apim46-lab delete secret apim46-lab-env apim46-lab-keystores
kubectl delete namespace apim46-lab
```

Delete the image from the lab only if you no longer need it:

```bash
podman rmi localhost/apim46-lab:4.6.0-safe
```

## Known risk points and mitigations

- Risk: copying live H2 files while APIM is running.
  Mitigation: only use a cold copy or an existing snapshot.

- Risk: lab clone accidentally booting with an empty DB.
  Mitigation: init container blocks startup unless the expected H2 files exist.

- Risk: exposing live secrets in git or in the container image.
  Mitigation: keystores and secret values stay in Kubernetes Secrets and are never baked into the image.

- Risk: H2 is not a production-grade clustered database.
  Mitigation: single replica, `Recreate` strategy, PVC-backed lab clone only.

- Risk: external AI and analytics integrations sending real traffic from the lab.
  Mitigation: use lab-scoped credentials or disable these integrations until the clone is validated.