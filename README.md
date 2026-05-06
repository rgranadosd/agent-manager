# WSO2 Agent Manager

[![Go Report Card](https://goreportcard.com/badge/github.com/wso2/ai-agent-management-platform/agent-manager-service)](https://goreportcard.com/report/github.com/wso2/ai-agent-management-platform/agent-manager-service)
[![Platform Release](https://img.shields.io/github/v/release/wso2/ai-agent-management-platform?filter=amp/*&label=platform&color=orange)](https://github.com/wso2/agent-manager/releases?q=amp)
[![Python Instrumentation](https://img.shields.io/github/v/release/wso2/ai-agent-management-platform?filter=amp-instrumentation/*&label=python-instrumentation&color=blue)](https://github.com/wso2/agent-manager/releases?q=amp-instrumentation)

An open control plane designed for enterprises to deploy, manage, and govern AI agents at scale.

## Nota sobre pruebas de importación de agentes desde repositorio externo

Para probar la funcionalidad de importación y despliegue de agentes desde un repositorio externo, se ha utilizado el siguiente repositorio público como ejemplo de agente compatible:

- https://github.com/kooljo/poc-agent-sdk (rama: main, commit: 8de1694693c4dea1220dbb1397b00a227fd23e98)

Este repositorio se usó para validar la integración y el despliegue automático de agentes internos a partir de código fuente alojado en GitHub.

## Overview

WSO2 Agent Manager provides a comprehensive platform for enterprise AI agent management. It enables organizations to deploy AI agents (both internally hosted and externally deployed), monitor their behavior through full-stack observability, and enforce governance policies at scale.

Built on [OpenChoreo](https://github.com/openchoreo/openchoreo) for internal agent deployments, the platform leverages OpenTelemetry for extensible instrumentation across multiple AI frameworks.

## Key Features

- **Deploy at Scale** - Deploy and run AI agents on Kubernetes with production-ready configurations
- **Lifecycle Management** - Manage agent versions, configurations, and deployments from a unified control plane
- **Governance** - Enforce policies, manage access controls, and ensure compliance across all agents
- **Full Observability** - Capture traces, metrics, and logs for complete visibility into agent behavior
- **Auto-Instrumentation** - OpenTelemetry-based instrumentation for AI frameworks with zero code changes
- **External Agent Support** - Monitor and govern externally deployed agents alongside internal ones

## Components

| Component | Description |
|-----------|-------------|
| **amp-instrumentation** | Python auto-instrumentation package for AI frameworks | 
| **amp-console** | Web-based management console for the platform |
| **amp-api** | Backend API powering the control plane | 
| **amp-trace-observer** | API for querying and analyzing trace data | 
| **amp-python-instrumentation-provider** | Kubernetes init container for automatic Python instrumentation |

## Helm Charts

Deploy WSO2 Agent Manager on Kubernetes using our Helm charts:

| Chart | Description |
|-------|-------------|
| `wso2-agent-manager` | Main platform deployment |
| `wso2-amp-build-extension` | Build extension for OpenChoreo |
| `wso2-amp-observability-extension` | Observability stack extension for OpenChoreo |

## Getting Started

For installation instructions and a step-by-step guide, see the [Quick Start Guide](https://wso2.github.io/agent-manager/docs/getting-started/quick-start/).

## Local AMP Scripts

The local helper scripts at the repository root (`start-local-amp.sh`, `stop-local-amp.sh`, `restart-local-amp.sh`) support an optional `.amp-local.env` file next to them.

An example is available in `.amp-local.env.example`.

Use it to override local-only values without editing the scripts directly, for example:

```bash
THUNDER_VERIFY_USERNAME=rgranadosd@gmail.com
THUNDER_VERIFY_PASSWORD=Patata1!
CONSOLE_LOCAL_PORT=3000
API_LOCAL_PORT=9000
OTEL_LOCAL_PORT=22893
GATEWAY_CONNECTOR_ENABLED=true
GATEWAY_CONNECTOR_API_KEY=<gateway_token>
```

The file is ignored by git.

Script behavior:

- `start-local-amp.sh` starts the Podman machine and k3d cluster, removes pods stuck in transient error states such as `ContainerStatusUnknown` or `ImagePullBackOff`, waits for AMP rollouts, patches local console URLs, and restores the local port-forwards.
- `start-local-amp.sh` also starts a dedicated port-forward for `amp-api-gateway-manager` and a local WebSocket connector (`scripts/gateway_ws_connector.py`) that keeps gateways in `ACTIVE` state.
- `stop-local-amp.sh` stops the local port-forwards and the gateway connector process.
- `restart-local-amp.sh` performs a full local runtime restart by default: it stops the helper port-forwards, stops the k3d cluster, stops the Podman machine, and then calls `start-local-amp.sh`.

Gateway connector notes:

- The connector is enabled by default (`GATEWAY_CONNECTOR_ENABLED=true`).
- Set `GATEWAY_CONNECTOR_API_KEY` in `.amp-local.env` with a valid gateway token.
- If enabled and `GATEWAY_CONNECTOR_API_KEY` is missing, `start-local-amp.sh` fails fast to avoid a silently `INACTIVE` gateway.
- By default, `start-local-amp.sh` auto-creates a local venv under `.amp-local/gateway-connector-venv` and installs `websockets`.
- You can disable this bootstrap with `GATEWAY_CONNECTOR_AUTO_SETUP=false` and provide a ready interpreter via `GATEWAY_CONNECTOR_PYTHON_BIN`.

Available restart options:

```bash
./restart-local-amp.sh --help
./restart-local-amp.sh --reprovision
```

- `--help` shows the available parameters.
- `--reprovision` performs a destructive reset for the default local cluster: it deletes the k3d cluster, reruns `deployments/quick-start/install.sh`, and then runs `start-local-amp.sh`.

`--reprovision` currently supports only the default `amp-local` cluster because `deployments/quick-start/install.sh` is hard-coded to that cluster name.

## Contributing

We welcome contributions from the community! Here's how you can help:

1. **Report Issues** - Found a bug or have a feature request? Open an issue on GitHub
2. **Submit Pull Requests** - Fork the repository, make your changes, and submit a PR
3. **Improve Documentation** - Help us improve docs, tutorials, and examples

Please ensure your contributions adhere to our coding standards and include appropriate tests.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Support

- **Issues**: [GitHub Issues](https://github.com/wso2/agent-manager/issues)
- **Community**: [WSO2 Community](https://wso2.com/community/)

---
(c) Copyright 2012 - 2026 [WSO2 LLC](https://wso2.com/).
