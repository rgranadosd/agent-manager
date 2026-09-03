# LM Studio local como LLM provider

Cómo exponer un modelo servido por **LM Studio en el Mac anfitrión** a través del
AI Gateway de Agent Manager, con el cluster k3s corriendo en Colima.

El caso tiene dos dificultades que no son evidentes: el LLM vive **fuera** del
cluster, y la template es **custom**, lo que destapa dos fallos de la consola.

---

## Ficheros

| Fichero | Qué es | Destino |
|---|---|---|
| `setup-lmstudio.sh` | Alta completa e idempotente | ejecutable |
| `preguntar.sh` | Llamada de prueba al gateway | ejecutable |
| `lmstudio-local.yaml` | `LlmProviderTemplate` conforme a la doc | gateway (YAML + Basic) |
| `lmstudio-local-provider.yaml` | `LlmProvider` de referencia | gateway (YAML + Basic) |
| `lmstudio-local-amp.json` | Payload de la template | AMP (JSON + Bearer) |

Los formatos de gateway y AMP difieren a propósito: el esquema de AMP añade
`metadata.endpointUrl` y `metadata.auth`, que la doc del gateway no contempla
porque allí el endpoint vive en el `LlmProvider` (`spec.upstream`).

---

## Arranque rápido

```bash
# 1. Arranca LM Studio, carga un modelo y pulsa "Start Server".
#    Déjalo en su 127.0.0.1:1234 por defecto: no hace falta exponerlo a la red.

# 2. Alta completa. Idempotente: comprueba antes de crear, se puede relanzar.
./setup-lmstudio.sh --dry-run    # no escribe nada, dice qué haría
./setup-lmstudio.sh              # interactivo, pide lo que necesita
./setup-lmstudio.sh --yes        # acepta todos los valores por defecto

# 3. Comprobación
./preguntar.sh
./preguntar.sh "cuánto es 2+2"
```

`setup-lmstudio.sh`, en orden:

1. Comprueba `curl`, `python3`, `kubectl` y que el cluster responde.
2. Localiza `amctl`; si falta lo compila (con Go, o en contenedor si no hay Go).
3. Renueva el token si hace falta, **mostrando la URL de autorización**.
4. Detecta LM Studio, lista los modelos de chat y propone el primero.
5. Verifica **desde el pod `gateway-runtime`** que alcanza LM Studio.
6. Crea la template en el gateway.
7. Crea la template en AMP.
8. Crea el provider con sus modelos y lo despliega.

Escrito para **bash 3.2**, el que trae macOS: sin arrays asociativos, con el
idioma `${1+"$@"}` y sin expansiones que revienten bajo `set -u`.

---

## Por qué hacen falta DOS registros de la misma template

Al desplegar un provider, AMP le manda al gateway **solo el handle** de la
template, nunca su contenido — `services/llm_deployment_service.go:503-505`:

```go
// Template handle is already stored in provider.TemplateHandle
// No need to fetch the template itself - handle is sufficient for gateway config
```

El gateway la resuelve contra **su propio** almacén. Son almacenes independientes:

| Registro | Endpoint | Si falta |
|---|---|---|
| Gateway | `:9090/api/management/v0.9/llm-provider-templates` | el gateway no reconoce el handle y no extrae tokens |
| AMP | `/api/v1/orgs/{org}/llm-provider-templates` | no sale en la consola y el alta del provider rechaza el handle |

Lo segundo está verificado en `services/llm_provider_service.go:167-178`: el alta
del provider valida el handle contra el almacén de AMP.

El gateway se alcanza con `kubectl port-forward` al `gateway-controller`, que
expone el puerto `9090/rest`.

---

## Red: por qué `192.168.5.2`

Es la dirección con la que la VM de Colima ve al Mac. **No es una IP de DHCP**:
Colima la fija en `gatewayAddress` de `~/.colima/<perfil>/colima.yaml`, con
192.168.5.2 como valor por defecto documentado. Sobrevive a cambios de Wi-Fi, a
`colima stop/start` y a reiniciar el Mac. `setup-lmstudio.sh` la **detecta** en
tiempo de ejecución en lugar de codificarla, por si algún día cambia el default.

Alternativas descartadas, y por qué:

| Candidata | Problema |
|---|---|
| `192.168.1.162` (IP de LAN) | Esa sí la negocia el DHCP: cambia al mudar de red |
| `host.k3d.internal` | Resuelve a `172.18.0.1`, el bridge Docker **dentro** de la VM, no el Mac |
| `host.lima.internal` | Resuelve bien hoy, pero **no está en el `NodeHosts` de CoreDNS**, así que depende de una cadena de reenvío DNS que puede variar al cambiar de red |

### La red local no interviene

Verificado, y es la prueba de que un cambio de red no puede romperlo:

| Ruta | Resultado |
|---|---|
| LM Studio desde `192.168.1.162:1234` (LAN) | **conexión rechazada** |
| LM Studio desde `127.0.0.1:1234` | HTTP 200 |
| Desde el pod, vía `192.168.5.2:1234` | HTTP 200 |

LM Studio escucha **solo en loopback**. Un servicio así no es alcanzable por la
LAN, por definición. El pod llega igualmente, luego el tráfico va por el enlace
privado VM↔host. Por eso LM Studio puede quedarse en su configuración por
defecto: no hay que exponerlo a la red ni pelearse con el firewall de macOS.

---

## Dos fallos de la consola con templates custom

El alta del provider desde la UI falló dos veces, y en ambos casos por lo mismo:
**la consola no envía campos que AMP espera**.

### 1. `upstream.main.url` vacío

El formulario bloquea el campo *Endpoint URL* (aparece con candado) porque la
template trae `endpointUrl`, pero luego manda cadena vacía. El alta muere con:

```
upstream.main must have either url or ref: invalid input
```

Peor aún: **el provider sí se crea en base de datos**; lo que falla es el
despliegue. La consola da error y te deja un provider a medias.

### 2. `accessControl` ausente

Sin ese campo AMP aplica `deny_all` sin excepciones
(`llm_deployment_service.go:528`) y el gateway bloquea **todas** las rutas. Este
no se ve en el alta: el provider parece correcto y simplemente no responde.

Comparación que lo destapó:

| Provider | modo |
|---|---|
| `lm-studio-local` (custom) | `deny_all` con excepciones vacías |
| `mistral-codestral` (sistema) | `allow_all` |
| `azure-ai-foundry` (sistema) | `allow_all` |

### Conclusión

**Una template custom no se puede dar de alta desde el formulario.** Hay que ir
por API, que es lo que hace `setup-lmstudio.sh`.

Queda **sin confirmar la causa raíz**: se sabe *qué* manda mal, no *por qué*. El
código del formulario vive en chunks que se cargan bajo demanda y no se
localizaron desde los bundles servidos. Antes de reportarlo como bug conviene
capturar la petición real con las DevTools abiertas.

---

## Rarezas de la API

- El `GET` de un provider acepta el **handle**, pero el `PUT` exige el **UUID**.
  Con handle devuelve 500 `invalid UUID length`.
- `amctl llm-provider create` **no expone flag para los modelos**, así que deja
  el provider sin `modelProviders`. Por eso el script crea el provider por API.
- Los modelos **nunca llegan al gateway**: `LLMProviderDeploymentSpec`
  (`llm_deployment_service.go:87-98`) no tiene campo de modelos. Solo los
  consume el catálogo (`catalog_repository.go:298`).

---

## Estado verificado (2026-09-03)

Org `default`, gateway `97b9786a-1ed5-44df-8690-68f5ff3eb3c1`.

| Recurso | Estado |
|---|---|
| Template en el gateway | creada, `count` 7 → 8 |
| Template en AMP | creada, uuid `4e227cdd-b6cc-4837-85b2-03b4723dd314` |
| Provider `lm-studio-local` | uuid `e82ebd1f-4c85-4c0f-ad72-88ae691da343`, **DEPLOYED** con ack del gateway |
| Contexto | `/lmstudio` |
| Upstream | `http://192.168.5.2:1234/v1` |
| accessControl | `allow_all` |
| Modelo | `qwen/qwen3-vl-8b` |

Llamada end-to-end a través del gateway:

```bash
kubectl port-forward -n default-default \
  svc/api-platform-default-default-gateway-gateway-runtime 22893:22893

curl http://127.0.0.1:22893/lmstudio/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen/qwen3-vl-8b","messages":[{"role":"user","content":"Dime quien eres"}],"max_tokens":200}'
```

HTTP 200, y el `usage` de la respuesta trae `prompt_tokens`, `completion_tokens`
y `total_tokens` — las tres rutas que declara la template. Si esos contadores
aparecen, la extracción funciona.

---

## Pendiente

Ninguno bloquea, pero conviene no perderlos de vista:

1. **La template en AMP apunta a `host.lima.internal`** mientras el provider usa
   `192.168.5.2`. Hoy es inocuo porque la consola ignora ese campo (el fallo 1 de
   arriba). Si lo arreglan, volvería a colarse la dependencia de DNS.
2. **El provider va con `allow_all` y sin API key.** Se puso así para igualarlo a
   los otros providers de la instancia. Para una demo de gobierno de LLMs es lo
   contrario de lo que se quiere enseñar: tocaría `deny_all` con excepciones
   (`/chat/completions`, `/models`, `/models/{modelId}`, como el ejemplo de la
   doc y como está en `lmstudio-local-provider.yaml`) o exigir key de consumidor.
3. **`inCatalog: true`** en el provider. Sin decidir si debe publicarse.
4. **Causa raíz de los fallos de la consola**, sin confirmar (ver arriba).

---

## Apéndice: el CLI `amctl`

No hay Go instalado en el Mac, así que se compila en contenedor:

```bash
docker run --rm -v $PWD:/src -w /src/cli \
  -e GOOS=darwin -e GOARCH=arm64 -e CGO_ENABLED=0 \
  golang:1.25 go build -o /src/amctl ./cmd/amctl

./amctl login --url http://api.amp.localhost:8080
```

El token queda en `~/.amctl/config` y **caduca en 1 hora**.

Si `amctl` dice `Browser opened` y no se abre nada, relánzalo así:

```bash
env PATH=/var/empty ./amctl login --url http://api.amp.localhost:8080
```

En macOS usa `exec.Command("open", url).Start()` (`pkg/browser/browser.go:29`),
que devuelve OK aunque no se vea nada, y **solo imprime la URL cuando falla al
abrir el navegador** (`pkg/auth/pkce.go:82`). Vaciar el `PATH` fuerza ese fallo.
`setup-lmstudio.sh` ya lo hace por su cuenta.
