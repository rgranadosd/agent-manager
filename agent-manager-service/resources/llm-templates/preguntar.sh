#!/usr/bin/env bash
# Pregunta al modelo local A TRAVES del gateway de AMP.
#
#   ./preguntar.sh                 # usa la pregunta por defecto
#   ./preguntar.sh "tu pregunta"
#
# Requiere que el provider lmstudio-local este creado y desplegado.
# Ver setup-lmstudio.sh y README.md en esta misma carpeta.

set -euo pipefail

NS="default-default"
SVC="svc/api-platform-default-default-gateway-gateway-runtime"
PORT=22893
CONTEXT="/lmstudio"
MODEL="qwen/qwen3-vl-8b"
PREGUNTA="${1:-Dime quien eres, en una frase corta.}"

PF_PID=""
cleanup() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; }
trap cleanup EXIT

echo "  Abriendo tunel al gateway ($NS)..."
kubectl port-forward -n "$NS" "$SVC" "$PORT:$PORT" >/dev/null 2>&1 &
PF_PID=$!
disown "$PF_PID" 2>/dev/null || true

i=0
while [ $i -lt 30 ]; do
  curl -s -o /dev/null -m 1 "http://127.0.0.1:$PORT/" && break
  i=$((i + 1))
done

echo "  Preguntando: $PREGUNTA"
echo ""

BODY=$(python3 -c "
import json,sys
print(json.dumps({'model': sys.argv[1],
                  'messages': [{'role':'user','content': sys.argv[2]}],
                  'max_tokens': 200}))
" "$MODEL" "$PREGUNTA")

RESP=$(curl -s -m 180 -w '\n%{http_code}' \
  "http://127.0.0.1:$PORT$CONTEXT/chat/completions" \
  -H "Content-Type: application/json" -d "$BODY")

CODE=$(printf '%s' "$RESP" | tail -1)
JSON=$(printf '%s' "$RESP" | sed '$d')

if [ "$CODE" != "200" ]; then
  echo "  FALLO: HTTP $CODE"
  printf '%s\n' "$JSON" | head -20
  exit 1
fi

printf '%s' "$JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('  ── RESPUESTA ' + '─'*52)
print()
for line in d['choices'][0]['message']['content'].strip().splitlines():
    print('   ', line)
print()
print('  ── DATOS QUE EXTRAE LA TEMPLATE ' + '─'*33)
u=d.get('usage',{})
print('     \$.model                   =', d.get('model'))
print('     \$.usage.prompt_tokens     =', u.get('prompt_tokens'))
print('     \$.usage.completion_tokens =', u.get('completion_tokens'))
print('     \$.usage.total_tokens      =', u.get('total_tokens'))
"
echo ""
echo "  OK — la llamada ha ido: tu Mac -> gateway en k3s -> 192.168.5.2 -> LM Studio"
