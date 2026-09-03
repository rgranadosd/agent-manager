#!/usr/bin/env bash
#
# Alta reproducible de un LLM provider apuntando a LM Studio en el Mac anfitrion.
#
# Cubre la cadena completa y es idempotente: cada paso comprueba antes de crear,
# asi que se puede relanzar sin miedo.
#
#   1. Template en el gateway  (necesaria para la extraccion de tokens)
#   2. Template en AMP         (necesaria para que salga en la consola)
#   3. Provider en AMP         (con modelos y desplegado al gateway)
#
# Compatible con bash 3.2, que es el que trae macOS: sin arrays asociativos
# ni expansiones de arrays vacios bajo `set -u`.
#
# Uso:
#   ./setup-lmstudio.sh              # interactivo
#   ./setup-lmstudio.sh --dry-run    # no escribe nada, solo dice que haria
#   ./setup-lmstudio.sh --yes        # acepta todos los valores por defecto

set -euo pipefail

DRY_RUN=""
ASSUME_YES=""
for arg in ${1+"$@"}; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --help|-h) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "opcion desconocida: $arg (prueba --help)" >&2; exit 2 ;;
  esac
done

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)

# ---------------------------------------------------------------- utilidades

c_ok()   { printf "\033[32m  OK\033[0m   %s\n" "$1"; }
c_skip() { printf "\033[33m SKIP\033[0m  %s\n" "$1"; }
c_do()   { printf "\033[36m  ->\033[0m   %s\n" "$1"; }
c_err()  { printf "\033[31m FAIL\033[0m  %s\n" "$1" >&2; }
step()   { printf "\n\033[1m%s\033[0m\n" "$1"; }

die() { c_err "$1"; exit 1; }

# ask <nombre-variable> <texto> <valor-por-defecto>
ask() {
  local __var="$1" __prompt="$2" __default="$3" __ans
  if [ -n "$ASSUME_YES" ]; then
    __ans="$__default"
  else
    printf "  %s [%s]: " "$__prompt" "$__default" >&2
    read -r __ans || __ans=""
    [ -z "$__ans" ] && __ans="$__default"
  fi
  eval "$__var=\$__ans"
}

confirm() {
  local __c
  [ -n "$ASSUME_YES" ] && return 0
  printf "  %s [s/N]: " "$1" >&2
  read -r __c || __c=""
  case "$__c" in [sSyY]*) return 0 ;; *) return 1 ;; esac
}

need() { command -v "$1" >/dev/null 2>&1 || die "falta '$1' en el PATH"; }

# --------------------------------------------------------------- requisitos

step "0. Requisitos"
need curl; need python3; need kubectl
c_ok "curl, python3 y kubectl disponibles"

kubectl cluster-info >/dev/null 2>&1 || die "kubectl no conecta con ningun cluster"
c_ok "cluster alcanzable ($(kubectl config current-context))"

# ------------------------------------------------------------------- amctl

step "1. CLI amctl"
AMCTL=""
for cand in "$REPO_ROOT/amctl" "./amctl" "$(command -v amctl 2>/dev/null || true)"; do
  if [ -n "$cand" ] && [ -x "$cand" ]; then AMCTL="$cand"; break; fi
done

if [ -z "$AMCTL" ]; then
  c_do "amctl no encontrado"
  if command -v go >/dev/null 2>&1; then
    if [ -n "$DRY_RUN" ]; then c_skip "compilaria con go build"; else
      (cd "$REPO_ROOT/cli" && go build -o "$REPO_ROOT/amctl" ./cmd/amctl) || die "fallo al compilar amctl"
      AMCTL="$REPO_ROOT/amctl"
    fi
  elif command -v docker >/dev/null 2>&1; then
    c_do "no hay Go instalado; compilando en contenedor"
    if [ -n "$DRY_RUN" ]; then c_skip "compilaria con docker"; else
      docker run --rm -v "$REPO_ROOT":/src -w /src/cli \
        -e GOOS="$(uname -s | tr '[:upper:]' '[:lower:]')" \
        -e GOARCH="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')" \
        -e CGO_ENABLED=0 \
        golang:1.25 go build -o /src/amctl ./cmd/amctl || die "fallo al compilar amctl"
      AMCTL="$REPO_ROOT/amctl"
    fi
  else
    die "hace falta Go o Docker para compilar amctl"
  fi
fi
[ -n "$AMCTL" ] && c_ok "amctl: $AMCTL"

# -------------------------------------------------------------------- token

step "2. Autenticacion en AMP"
ask AMP_URL "URL de la API de AMP" "http://api.amp.localhost:8080"

token_state() {
  python3 - <<'PY' 2>/dev/null || echo missing
import sys, os, datetime
try:
    import yaml
except ImportError:
    print("noyaml"); sys.exit(0)
p = os.path.expanduser("~/.amctl/config")
if not os.path.exists(p): print("missing"); sys.exit(0)
d = yaml.safe_load(open(p)) or {}
inst = (d.get("instances") or {}).get(d.get("current_instance") or "", {})
auth = inst.get("auth") or {}
tok = auth.get("access_token")
if not tok: print("missing"); sys.exit(0)
exp = auth.get("expires_at")
if isinstance(exp, str):
    exp = datetime.datetime.fromisoformat(exp)
if exp and exp <= datetime.datetime.now(exp.tzinfo) + datetime.timedelta(minutes=2):
    print("expired"); sys.exit(0)
print("ok")
PY
}

read_token() {
  python3 - <<'PY'
import os, yaml
d = yaml.safe_load(open(os.path.expanduser("~/.amctl/config")))
inst = d["instances"][d["current_instance"]]
print(inst["auth"]["access_token"])
PY
}

read_org() {
  python3 - <<'PY' 2>/dev/null || true
import os, yaml
d = yaml.safe_load(open(os.path.expanduser("~/.amctl/config")))
inst = d["instances"][d["current_instance"]]
print(inst.get("current_org") or "")
PY
}

# amctl solo imprime la URL de autorizacion cuando falla al abrir el navegador
# (pkce.go:82). En macOS usa `open ... .Start()`, que devuelve OK aunque no se
# vea nada. Por eso lo lanzamos con el PATH vacio: forzamos el fallo, cazamos
# la URL del log y la abrimos nosotros.
do_login() {
  LOGIN_LOG=$(mktemp -t amctl-login)
  env PATH=/var/empty "$AMCTL" login --url "$AMP_URL" >"$LOGIN_LOG" 2>&1 &
  LOGIN_PID=$!
  AUTH_URL=""
  i=0
  while [ $i -lt 100 ]; do
    AUTH_URL=$(grep -oE 'https?://[^ ]*/oauth2/authorize\?[^ ]*' "$LOGIN_LOG" 2>/dev/null | head -1 || true)
    [ -n "$AUTH_URL" ] && break
    kill -0 "$LOGIN_PID" 2>/dev/null || break
    i=$((i + 1))
  done
  if [ -n "$AUTH_URL" ]; then
    echo ""
    echo "  Abriendo el navegador. Si no aparece, pega esta URL a mano:"
    echo ""
    echo "  $AUTH_URL"
    echo ""
    command -v open >/dev/null 2>&1 && open "$AUTH_URL" >/dev/null 2>&1 || true
  fi
  wait "$LOGIN_PID" || die "el login fallo (revisa $LOGIN_LOG)"
  rm -f "$LOGIN_LOG"
}

STATE=$(token_state)
case "$STATE" in
  noyaml)  die "falta el modulo python 'yaml' (pip3 install pyyaml)" ;;
  ok)      c_ok "token vigente en ~/.amctl/config" ;;
  missing) c_do "sin token, hay que hacer login"
           [ -n "$DRY_RUN" ] && c_skip "haria amctl login" || do_login ;;
  expired) c_do "token caducado, renovando"
           [ -n "$DRY_RUN" ] && c_skip "haria amctl login" || do_login ;;
esac

if [ -n "$DRY_RUN" ] && [ "$STATE" != "ok" ]; then
  TOKEN="DRY-RUN"; ORG_DEFAULT="default"
else
  TOKEN=$(read_token)
  ORG_DEFAULT=$(read_org)
  [ -z "$ORG_DEFAULT" ] && ORG_DEFAULT="default"
fi

ask ORG "Organizacion" "$ORG_DEFAULT"
API="$AMP_URL/api/v1/orgs/$ORG"

# ---------------------------------------------------------------- LM Studio

step "3. LM Studio"
ask LLM_PORT "Puerto de LM Studio en el Mac" "1234"

if curl -s -m 4 "http://127.0.0.1:$LLM_PORT/v1/models" >/tmp/lms-models.$$ 2>/dev/null; then
  c_ok "LM Studio responde en 127.0.0.1:$LLM_PORT"
  echo "     modelos de chat disponibles:"
  python3 - /tmp/lms-models.$$ <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for m in d.get("data", []):
    if "embed" in m["id"]:
        continue
    print("       -", m["id"])
PY
  MODEL_DEFAULT=$(python3 - /tmp/lms-models.$$ <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for m in d.get("data", []):
    if "embed" not in m["id"]:
        print(m["id"]); break
PY
)
  rm -f /tmp/lms-models.$$
else
  c_err "LM Studio no responde en 127.0.0.1:$LLM_PORT"
  echo "     arranca LM Studio, carga un modelo y pulsa 'Start Server'."
  MODEL_DEFAULT=""
  confirm "seguir de todas formas?" || exit 1
fi

# Direccion con la que la VM ve al Mac. NO es una IP de DHCP: Colima la fija en
# `gatewayAddress` de ~/.colima/<perfil>/colima.yaml (por defecto 192.168.5.2),
# asi que sobrevive a cambios de red, a colima stop/start y a reiniciar el Mac.
#
# Se detecta en vez de codificarse, por si algun dia cambia el default.
# Se usa la IP y no `host.lima.internal` a proposito: ese nombre NO esta fijado
# en el NodeHosts de CoreDNS, asi que depende de una cadena de reenvio DNS.
# Con la IP no hay nada que resolver.
# host.k3d.internal NO vale: resuelve al bridge Docker dentro de la VM, no al Mac.
detect_host_addr() {
  local prof addr
  prof=$(colima list 2>/dev/null | awk '$2=="Running"{print $1; exit}')
  if [ -n "$prof" ]; then
    addr=$(awk '/^ *gatewayAddress:/ {print $2; exit}' \
             "$HOME/.colima/$prof/colima.yaml" 2>/dev/null)
    [ -z "$addr" ] && addr=$(colima ssh --profile "$prof" -- \
             getent hosts host.lima.internal 2>/dev/null | awk '{print $1; exit}')
  fi
  [ -z "$addr" ] && addr="192.168.5.2"
  printf '%s' "$addr"
}
HOST_ADDR_DEFAULT=$(detect_host_addr)
c_ok "direccion del Mac vista desde la VM: $HOST_ADDR_DEFAULT"
ask LLM_HOST "Direccion con la que el pod ve tu Mac" "$HOST_ADDR_DEFAULT"
UPSTREAM_URL="http://$LLM_HOST:$LLM_PORT/v1"
ask MODEL_ID "Id del modelo (literal, con la barra)" "$MODEL_DEFAULT"
[ -z "$MODEL_ID" ] && die "hace falta un id de modelo"

step "4. Comprobando que el pod del gateway alcanza LM Studio"
GW_POD=$(kubectl get pods -n default-default --no-headers 2>/dev/null \
         | awk '$3=="Running" && /gateway-runtime/ {print $1; exit}')
if [ -z "$GW_POD" ]; then
  c_err "no encuentro ningun pod gateway-runtime en Running"
else
  if kubectl exec -n default-default "$GW_POD" -- \
       curl -s -m 6 -o /dev/null -w '' "$UPSTREAM_URL/models" 2>/dev/null; then
    c_ok "$GW_POD alcanza $UPSTREAM_URL"
  else
    c_err "el pod NO alcanza $UPSTREAM_URL"
    echo "     comprueba que LM Studio esta arrancado y que '$LLM_HOST' resuelve al Mac:"
    echo "       kubectl exec -n default-default $GW_POD -- getent hosts $LLM_HOST"
    confirm "seguir de todas formas?" || exit 1
  fi
fi

# --------------------------------------------------------------- parametros

step "5. Datos del provider"
ask TEMPLATE_HANDLE "Handle de la template"  "lmstudio-local"
ask TEMPLATE_NAME   "Nombre de la template"  "LM Studio (local)"
ask PROVIDER_ID     "Id del provider"        "lm-studio-local"
ask PROVIDER_NAME   "Nombre del provider"    "LM Studio Local"
ask PROVIDER_CTX    "Contexto"               "/lmstudio"
ask PROVIDER_VER    "Version"                "v1.0"
ask API_KEY         "API key (LM Studio la ignora)" "lm-studio"

# --------------------------------------------- 6. template en el gateway

step "6. Template en el gateway"
PF_PID=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

GW_SVC="svc/api-platform-default-default-gateway-controller"
GW_PORT=19090
GW_API="http://127.0.0.1:$GW_PORT/api/management/v0.9"
GW_AUTH="Authorization: Basic YWRtaW46YWRtaW4="

kubectl port-forward -n default-default "$GW_SVC" "$GW_PORT:9090" >/dev/null 2>&1 &
PF_PID=$!
# sin disown, bash anuncia "Terminated: 15" al matarlo
disown "$PF_PID" 2>/dev/null || true
i=0
while [ $i -lt 40 ]; do
  curl -s -o /dev/null -m 1 "http://127.0.0.1:$GW_PORT/" && break
  i=$((i + 1))
done

GW_CODE=$(curl -s -o /dev/null -m 8 -w '%{http_code}' \
  "$GW_API/llm-provider-templates/$TEMPLATE_HANDLE" -H "$GW_AUTH" || echo 000)

if [ "$GW_CODE" = "200" ]; then
  c_skip "'$TEMPLATE_HANDLE' ya existe en el gateway"
elif [ -n "$DRY_RUN" ]; then
  c_skip "crearia '$TEMPLATE_HANDLE' en el gateway (HTTP actual: $GW_CODE)"
else
  c_do "creando '$TEMPLATE_HANDLE' en el gateway"
  RESP=$(curl -s -m 15 -w '\n%{http_code}' -X POST \
    "$GW_API/llm-provider-templates" \
    -H "Content-Type: application/yaml" -H "$GW_AUTH" \
    --data-binary @- <<YAML
apiVersion: gateway.api-platform.wso2.com/v1alpha1
kind: LlmProviderTemplate
metadata:
  name: $TEMPLATE_HANDLE
spec:
  displayName: $TEMPLATE_NAME
  promptTokens:
    location: payload
    identifier: \$.usage.prompt_tokens
  completionTokens:
    location: payload
    identifier: \$.usage.completion_tokens
  totalTokens:
    location: payload
    identifier: \$.usage.total_tokens
  requestModel:
    location: payload
    identifier: \$.model
  responseModel:
    location: payload
    identifier: \$.model
YAML
)
  CODE=$(printf '%s' "$RESP" | tail -1)
  case "$CODE" in
    201|200) c_ok "template creada en el gateway (HTTP $CODE)" ;;
    409)     c_skip "ya existia (HTTP 409)" ;;
    *)       c_err "el gateway devolvio HTTP $CODE"
             printf '%s\n' "$RESP" | sed '$d' | head -5
             die "abortado" ;;
  esac
fi

kill "$PF_PID" 2>/dev/null || true
PF_PID=""

# ------------------------------------------------------- 7. template en AMP

step "7. Template en AMP"
AMP_CODE=$(curl -s -o /dev/null -m 8 -w '%{http_code}' \
  "$API/llm-provider-templates/$TEMPLATE_HANDLE" \
  -H "Authorization: Bearer $TOKEN" || echo 000)

if [ "$AMP_CODE" = "200" ]; then
  c_skip "'$TEMPLATE_HANDLE' ya existe en AMP"
elif [ -n "$DRY_RUN" ]; then
  c_skip "crearia '$TEMPLATE_HANDLE' en AMP (HTTP actual: $AMP_CODE)"
else
  c_do "creando '$TEMPLATE_HANDLE' en AMP"
  BODY=$(python3 - "$TEMPLATE_HANDLE" "$TEMPLATE_NAME" "$UPSTREAM_URL" <<'PY'
import json, sys
h, n, url = sys.argv[1], sys.argv[2], sys.argv[3]
def ex(p): return {"location": "payload", "identifier": p}
print(json.dumps({
    "id": h, "name": n,
    "description": "LM Studio en el Mac anfitrion, fuera del cluster",
    "metadata": {
        "endpointUrl": url,
        "auth": {"type": "api-key", "header": "Authorization", "valuePrefix": "Bearer "},
    },
    "promptTokens":     ex("$.usage.prompt_tokens"),
    "completionTokens": ex("$.usage.completion_tokens"),
    "totalTokens":      ex("$.usage.total_tokens"),
    "requestModel":     ex("$.model"),
    "responseModel":    ex("$.model"),
}))
PY
)
  RESP=$(curl -s -m 15 -w '\n%{http_code}' -X POST "$API/llm-provider-templates" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "$BODY")
  CODE=$(printf '%s' "$RESP" | tail -1)
  case "$CODE" in
    201|200) c_ok "template creada en AMP (HTTP $CODE)" ;;
    409)     c_skip "ya existia (HTTP 409)" ;;
    *)       c_err "AMP devolvio HTTP $CODE"
             printf '%s\n' "$RESP" | sed '$d' | head -5
             die "abortado" ;;
  esac
fi

# ---------------------------------------------------------- 8. el provider

step "8. Provider en AMP"
GW_UUID=$(curl -s -m 10 "$API/gateways" -H "Authorization: Bearer $TOKEN" 2>/dev/null \
  | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
gs=d.get('gateways') or d.get('data') or (d if isinstance(d,list) else [])
if len(gs)==1: print(gs[0].get('id') or gs[0].get('uuid') or '')
elif gs:
    for g in gs: print('   -', g.get('id') or g.get('uuid'), g.get('name'), file=sys.stderr)
" 2>/dev/null || true)

if [ -z "$GW_UUID" ]; then
  ask GW_UUID "UUID del gateway al que desplegar (vacio = no desplegar)" ""
else
  c_ok "gateway detectado: $GW_UUID"
fi

P_CODE=$(curl -s -o /dev/null -m 8 -w '%{http_code}' \
  "$API/llm-providers/$PROVIDER_ID" -H "Authorization: Bearer $TOKEN" || echo 000)

if [ "$P_CODE" = "200" ]; then
  c_skip "el provider '$PROVIDER_ID' ya existe"
elif [ -n "$DRY_RUN" ]; then
  c_skip "crearia el provider '$PROVIDER_ID' (HTTP actual: $P_CODE)"
  echo "       template : $TEMPLATE_HANDLE"
  echo "       upstream : $UPSTREAM_URL"
  echo "       modelo   : $MODEL_ID"
  echo "       gateway  : ${GW_UUID:-ninguno}"
else
  c_do "creando el provider '$PROVIDER_ID'"
  BODY=$(python3 - "$PROVIDER_ID" "$PROVIDER_NAME" "$PROVIDER_VER" "$PROVIDER_CTX" \
                   "$TEMPLATE_HANDLE" "$UPSTREAM_URL" "$API_KEY" "$MODEL_ID" "$GW_UUID" <<'PY'
import json, sys
pid, name, ver, ctx, tpl, url, key, model, gw = sys.argv[1:10]
body = {
    "id": pid, "name": name, "version": ver, "context": ctx, "template": tpl,
    "description": "LM Studio corriendo en el Mac anfitrion",
    "upstream": {"main": {"url": url, "auth": {
        "type": "api-key", "header": "Authorization", "value": "Bearer " + key}}},
    # Sin accessControl explicito AMP aplica deny_all sin excepciones y el
    # gateway bloquea todas las rutas (llm_deployment_service.go:528).
    "accessControl": {"mode": "allow_all", "exceptions": []},
    "modelProviders": [{"id": "lmstudio", "name": "LM Studio",
                        "models": [{"id": model, "name": model}]}],
}
if gw:
    body["gateways"] = [gw]
print(json.dumps(body))
PY
)
  RESP=$(curl -s -m 30 -w '\n%{http_code}' -X POST "$API/llm-providers" \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "$BODY")
  CODE=$(printf '%s' "$RESP" | tail -1)
  case "$CODE" in
    201|200) c_ok "provider creado (HTTP $CODE)" ;;
    409)     c_skip "ya existia (HTTP 409)" ;;
    *)       c_err "AMP devolvio HTTP $CODE"
             printf '%s\n' "$RESP" | sed '$d' | head -10
             die "abortado" ;;
  esac
fi

# ---------------------------------------------------------------- resumen

step "Resumen"
if [ -n "$DRY_RUN" ]; then
  echo "  (dry-run: no se ha escrito nada)"
else
  curl -s -m 10 "$API/llm-providers" -H "Authorization: Bearer $TOKEN" 2>/dev/null \
    | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
ps=d.get('providers') or d.get('data') or (d if isinstance(d,list) else [])
print('  providers en la org:',len(ps))
for p in ps:
    print('   -',(p.get('id') or '').ljust(26), p.get('template',''), p.get('status',''))
" 2>/dev/null || true
fi

echo ""
echo "  Prueba end-to-end desde el pod del gateway:"
echo ""
echo "    kubectl exec -n default-default \$(kubectl get pods -n default-default \\"
echo "      --no-headers | awk '\$3==\"Running\" && /gateway-runtime/ {print \$1; exit}') -- \\"
echo "      curl -s $UPSTREAM_URL/models"
echo ""
