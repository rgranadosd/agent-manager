# Heavy-tier deploy contract

The heavy tier deploys one agent per heavy-subset cell against a live AMP
stack, invokes it, polls `traces-observer-service`, and validates the
resulting spans against the contract. This doc captures the deploy mechanism
and the operational contract — what the driver assumes, what env it consumes,
what timeouts it enforces.

## Bring-up: build-from-source, not the released quick-start

The CI heavy job stands up AMP from the **working tree** via the dev
`make setup` chain (encapsulated in the `amp-dev-stack` composite action):
`setup-k3d` → `setup-openchoreo` (builds + `k3d image import`s the
traces-observer + python-instrumentation-provider images from source) →
`setup-platform` (agent-manager-service via docker-compose) → migrate →
port-forward → gateway.

This is deliberately **not** `deployments/quick-start/install.sh`, which
deploys *released* images at a pinned `VERSION` (that's what the e2e suite
uses). The matrix exists to catch regressions in the PR's observer +
instrumentation code, so it must run the PR's images.

## Why not raw Workload manifests

The original Phase 7 sketch suggested rendering a `kind: Workload` YAML and
`kubectl apply`-ing it. AMP doesn't expose agents that way. Agents are
created through `agent-manager-service`'s REST API, which:

1. Reads its embedded instrumentation catalog (`baseline.json`, generated
   from `release-config.json`) to validate the requested
   `instrumentation_version`.
2. Renders the right init-container image
   (`ghcr.io/wso2/amp-python-instrumentation-provider:<instr>-python<X.Y>`)
   into the agent's pod spec.
3. Mints an API key, exposes a `/chat` endpoint, returns both to the caller.

`test/e2e/framework/shared_agent.go` is the canonical Go reference. The
heavy-tier Python driver mirrors that flow via `heavy.amp_client.AmpClient`.

## Environment

The only real **secrets** are the LLM keys. Everything else defaults to the
values the dev bring-up exposes (the same defaults the e2e config uses) and
is overridable but never required.

| Variable | Kind | Default / source |
|---|---|---|
| `OPENAI_API_KEY` | **secret** | repo secret; forwarded into each deployed agent so it can make real calls |
| `ANTHROPIC_API_KEY` | **secret** | repo secret; for the anthropic-direct cell |
| `AMP_API_BASE_URL` | default | `http://localhost:9000` |
| `TRACES_OBSERVER_BASE_URL` | default | `http://localhost:9098` |
| `IDP_TOKEN_URL` | default | `http://thunder.amp.localhost:8080/oauth2/token` |
| `IDP_CLIENT_ID` | default | `amp-api-client` |
| `IDP_CLIENT_SECRET` | default | `amp-api-client-secret` |

The LLM keys are forwarded into the agent at create time as sensitive env
vars — that's how the deployed pod makes real provider calls (the emission
tier replays cassettes instead; heavy makes real calls on purpose). A cell
whose framework needs a key that isn't set will fail its call, which the
matrix surfaces. Manual-provider cells are skipped (emission-only).

AMP authenticates via Thunder IDP using the OAuth2 `client_credentials`
grant — no static admin token. The driver fetches a short-lived access token
at startup and refreshes as needed, mirroring
`test/e2e/framework/auth.go::FetchToken`.

### Token fetch sequence

```
POST <IDP_TOKEN_URL>
  Authorization: Basic <base64(IDP_CLIENT_ID:IDP_CLIENT_SECRET)>
  Content-Type: application/x-www-form-urlencoded

  grant_type=client_credentials

→ 200 { "access_token": "...", "token_type": "Bearer", "expires_in": 3600 }
```

The access token goes into the `Authorization: Bearer <token>` header on
every subsequent call to `agent-manager-service`. Tokens expire — the
client refreshes proactively if `expires_in - elapsed < 30s`, again
mirroring the e2e Go reference.

## Deploy flow (per cell)

```
for cell in heavy_subset:
    if cell.instrumentation_version is None:    # manual provider
        skip
        continue

    k3d.reset_opensearch_indices()              # clean slate per cell

    deployed = client.deploy_agent(
        cell_id                  = cell.id,
        instrumentation_version  = cell.instrumentation_version,
        framework_package        = cell.framework_package,
        framework_version        = cell.framework_version,
        python_version           = cell.python,
    )                                            # blocks until build is Ready
    try:
        invoke_agent(deployed)                   # POST /chat — fixed prompt
        spans = observer.poll_traces(deployed)   # blocks until spans land
    finally:
        client.teardown_agent(deployed)          # always; even on validation fail

    validate(spans, cell.span_kinds)
    write_cell_report(...)
```

The `DeployedAgent` record carries `(org, project_name, agent_name,
environment)` so the observer poll can form its query without re-discovery.

## Observer query shape

Span fetch is three calls (mirrors `test/e2e/operations/trace/`):

```
# 1. list traces for the agent
GET /api/v1/traces?organization=&project=&agent=&environment=&startTime=&endTime=&limit=&sortOrder=desc

# 2. list span summaries (spanIds) for each trace
GET /api/v1/traces/{traceId}/spans?...

# 3. fetch each span's detail (carries name/kind/attributes/resource)
GET /api/v1/traces/{traceId}/spans/{spanId}
```

The list call uses `organization`/`project`/`agent`/`environment` (the names
the e2e `ListTraces` client uses). The per-trace `/spans` call's exact param
names (`namespace`/`component` vs `organization`/`agent`) are first-run-
tunable — see "Implementation status". Step 3 returns `opensearch.Span`,
whose raw `attributes` map is exactly what the emission-tier validator
consumes, so the heavy tier reuses the `traceloop/v1` contract. The driver
anchors the time window to invocation time, widened ±5m for clock skew +
indexing lag.

## Timeout budget

- **Build readiness**: 600s. AMP's buildpack run + image push + pod start
  can take several minutes. Cells that don't reach `Ready` in time are
  reported as `pipeline-error`.
- **Span emission**: 120s after the first `/chat` call returns 200. Most
  cells emit within 10s; the long tail accommodates OpenSearch indexing
  lag.
- **Teardown**: 60s. Best-effort; failures here log but don't fail the cell.

Total per-cell wall time is bounded by ~7 min in the worst case; the heavy
subset is currently 1–4 cells, so the whole tier fits inside a single
ubuntu-latest 60-minute budget.

## Implementation status

`heavy/amp_client.py`, `heavy/observer.py`, and `driver._invoke_agent` are
**implemented** against the Go e2e reference (`test/e2e/framework/` +
`test/e2e/operations/`) — token fetch, project/agent create with
`instrumentationVersion`, build poll, deploy poll, API-key mint, `/chat`
invoke, and the list→summaries→detail span fetch. Mocked-HTTP unit tests
cover the control flow (`tests/test_heavy_client.py`).

They have **not** run against a live AMP stack, so three things are
first-run-tunable:

1. **The `amp-dev-stack` bring-up** (`.github/actions/amp-dev-stack`). The
   `make setup` chain hasn't been exercised on a CI runner — watch
   `setup-platform.sh`'s Node check, whether docker-compose tries to start
   the console (not needed), and the background port-forwards binding
   9000/9098.
2. **Timing constants** (build 600s, deploy 300s) — adjust to real build
   times once observed.
3. **The observer summaries-endpoint params.** `poll_traces` sends both the
   list-traces names (`organization`/`project`/`agent`) and best-effort
   `namespace`/`component` on the per-trace `/spans` call; confirm the exact
   mapping against a live observer.

The heavy CI jobs stay `continue-on-error: true` until a real run validates
this end to end — then drop that flag.
