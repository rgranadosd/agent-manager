# Local Access Map

This local setup keeps port `3000` free for your existing service and exposes AMP on alternate host ports.

## Host URLs

- Console: `http://localhost:13000`
- API: `http://localhost:19000`
- Thunder: `http://localhost:8082`
- Existing service on `3000`: `http://localhost:3000`

## Host To Cluster Mapping

- `localhost:13000` -> local `kubectl port-forward` -> `amp-console:3000`
- `localhost:19000` -> local `kubectl port-forward` -> `amp-api:9000`
- `localhost:8082` -> local `kubectl port-forward` -> `amp-thunder-extension-service:8090`
- `localhost:19080` -> k3d load balancer -> OpenChoreo data plane gateway
- `localhost:22893` -> k3d load balancer -> observability gateway

## Why Thunder Uses 8082

Thunder is the identity provider used by the console. In local mode, the console can redirect to Thunder for authentication, then return to the console callback on `13000`.

## Current Local Workaround

The current local helper supports `CONSOLE_DISABLE_AUTH=true` in `.amp-local.env`.

This is useful when the local Thunder OIDC flow is unstable but you still need to get into the Agent Manager console quickly.

## Important Files

- `.amp-local.env`
- `start-local-amp.sh`
- `stop-local-amp.sh`
- `restart-local-amp.sh`