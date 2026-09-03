# lmstudio-local

Template para LM Studio corriendo en el Mac anfitrion, fuera del k3s.

## Hacen falta DOS registros con el mismo handle

Al desplegar un provider, AMP le manda al gateway **solo el handle** de la
template, no su contenido (`services/llm_deployment_service.go:503-505`). El
gateway la resuelve contra su propio almacen. Son almacenes independientes:

| Registro | Para que sirve | Si falta |
|---|---|---|
| Gateway (`:9090/api/management/v0.9`) | extraccion de tokens en runtime | el gateway no reconoce el handle |
| AMP (`/orgs/{org}/llm-provider-templates`) | que salga en el desplegable de la consola | no puedes elegirla al crear el provider |

## Ficheros

| Fichero | Destino | Formato |
|---|---|---|
| `lmstudio-local.yaml` | gateway | `LlmProviderTemplate`, YAML + Basic auth |
| `lmstudio-local-provider.yaml` | gateway | `LlmProvider`, YAML + Basic auth |
| `lmstudio-local-amp.json` | AMP | JSON + Bearer |

Los dos formatos difieren a proposito: el esquema de AMP anade
`metadata.endpointUrl` y `metadata.auth`, que la doc del gateway no contempla
porque alli el endpoint vive en el `LlmProvider` (`spec.upstream`). En AMP
sirven para prerellenar el formulario del provider en la consola.

## Red

Se usa **`192.168.5.2`**, la direccion con la que la VM de Colima ve al Mac.

No es una IP de DHCP: Colima la fija en `gatewayAddress` de
`~/.colima/<perfil>/colima.yaml` (default documentado 192.168.5.2). Sobrevive a
cambios de Wi-Fi, a `colima stop/start` y a reiniciar el Mac. El script la
detecta en tiempo de ejecucion en vez de codificarla.

Descartadas:

- `192.168.1.162` (IP de LAN): esa si la negocia el DHCP y cambia de red en red.
- `host.k3d.internal`: resuelve a `172.18.0.1`, el bridge Docker dentro de la VM.
- `host.lima.internal`: resuelve bien hoy, pero **no esta en el NodeHosts de
  CoreDNS**, asi que depende de una cadena de reenvio DNS que puede variar al
  cambiar de red. Con la IP no hay nada que resolver.

Verificado desde el pod `gateway-runtime`: alcanza el Mac incluso para servicios
atados solo a `127.0.0.1`, asi que LM Studio se queda en su `127.0.0.1:1234` por
defecto. De hecho LM Studio **no** es alcanzable por la IP de LAN (conexion
rechazada), lo que demuestra que el trafico no pasa por la red local.

## Dos fallos de la consola con templates custom

Al crear el provider desde la UI fallo dos veces, y en ambos casos por lo mismo:
la consola no envia campos que AMP espera.

1. **`upstream.main.url` vacio.** El formulario bloquea el Endpoint URL (candado)
   porque la template trae `endpointUrl`, pero manda cadena vacia. El alta muere
   con `upstream.main must have either url or ref`. Curiosamente el provider SI
   se crea en BD; lo que falla es el despliegue, asi que queda a medias.
2. **`accessControl` ausente.** AMP entonces aplica `deny_all` sin excepciones
   (`llm_deployment_service.go:528`) y el gateway bloquea todas las rutas. Los
   providers creados sobre templates de sistema salen con `allow_all`.

Conclusion: **una template custom no se puede dar de alta desde el formulario**.
Hay que ir por API, que es lo que hace `setup-lmstudio.sh`.

Ojo con la API: el `GET` de un provider acepta el handle, pero el `PUT` exige el
UUID. Con handle devuelve 500 `invalid UUID length`.

## Estado (2026-09-03)

Ambos registros hechos y verificados, org `default`:

- Gateway: `POST /api/management/v0.9/llm-provider-templates` -> 201. `count` 7 -> 8.
- AMP: `POST /api/v1/orgs/default/llm-provider-templates` -> 201,
  uuid `4e227cdd-b6cc-4837-85b2-03b4723dd314`. `count` 7 -> 8.

Pendiente: arrancar LM Studio, crear el provider desde la consola eligiendo
`lmstudio-local`, y probar end-to-end.

Para hablar con la API de AMP se compilo el CLI del repo en un contenedor Go
(no hay Go instalado en el Mac):

    docker run --rm -v $PWD:/src -w /src/cli \
      -e GOOS=darwin -e GOARCH=arm64 -e CGO_ENABLED=0 \
      golang:1.25 go build -o /src/amctl ./cmd/amctl

    ./amctl login --url http://api.amp.localhost:8080

El token queda en `~/.amctl/config`. Si `amctl` dice "Browser opened" y no se
abre nada, relanzalo con `env PATH=/var/empty ./amctl login ...`: solo imprime
la URL cuando falla al abrir el navegador.

## setup-lmstudio.sh

Alta reproducible de toda la cadena. Idempotente: cada paso comprueba antes de
crear, asi que se puede relanzar sin duplicar nada.

    ./setup-lmstudio.sh --dry-run    # no escribe nada, dice que haria
    ./setup-lmstudio.sh              # interactivo, pide lo que necesita
    ./setup-lmstudio.sh --yes        # acepta todos los valores por defecto

Que hace, en orden:

1. Comprueba curl, python3, kubectl y que el cluster responde.
2. Localiza `amctl`; si no esta, lo compila (con Go, o en contenedor si no hay Go).
3. Renueva el token si hace falta, abriendo el navegador y **enseniando la URL**.
4. Detecta LM Studio, lista los modelos de chat y propone el primero.
5. Verifica desde el pod `gateway-runtime` que alcanza LM Studio antes de seguir.
6. Crea la template en el gateway (si falta).
7. Crea la template en AMP (si falta).
8. Crea el provider con sus modelos y lo despliega al gateway detectado.

Escrito para bash 3.2, el que trae macOS: sin arrays asociativos, con el idioma
`${1+"$@"}` y sin expansiones que revienten bajo `set -u`.

Nota: el provider se crea por API y no con `amctl llm-provider create`, porque
el CLI no expone flag para los modelos y dejaria el provider a medias.

## Verificacion end-to-end

Provider `lm-studio-local`, uuid `e82ebd1f-4c85-4c0f-ad72-88ae691da343`,
contexto `/lmstudio`, desplegado y con ack del gateway (`newStatus: DEPLOYED`).

Llamada real a traves del gateway:

    kubectl port-forward -n default-default \
      svc/api-platform-default-default-gateway-gateway-runtime 22893:22893

    curl http://127.0.0.1:22893/lmstudio/chat/completions \
      -H "Content-Type: application/json" \
      -d '{"model":"qwen/qwen3-vl-8b","messages":[{"role":"user","content":"Responde solo: OK"}],"max_tokens":10}'

HTTP 200, y el `usage` de la respuesta trae `prompt_tokens`, `completion_tokens`
y `total_tokens`, que son las tres rutas que declara la template.
