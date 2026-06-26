#!/bin/bash
# AMP / OpenChoreo local status
CTX=k3d-amp-local
G="\033[32m"; R="\033[31m"; Y="\033[33m"; B="\033[1m"; N="\033[0m"
ok(){ echo -e "  ${G}OK  $1${N}"; }; bad(){ echo -e "  ${R}NO  $1${N}"; }; warn(){ echo -e "  ${Y}..  $1${N}"; }
kc(){ kubectl --context $CTX --request-timeout=8s "$@" 2>/dev/null; }

echo -e "${B}========== AMP STATUS  $(date '+%H:%M:%S') ==========${N}"

echo -e "\n${B}1) CLUSTER (amp-local)${N}"
if kc get nodes | grep -q Ready; then
    ok "k8s API OK"
else
    bad "Cluster no responde — usa: bash deployments/amp.sh start"
fi

UNHEALTHY=$(kc get pods -A 2>/dev/null | grep -ivE "Running|Completed|NAME" | grep -v "^$")
[ -n "$UNHEALTHY" ] && echo "$UNHEALTHY" | head -8 | sed 's/^/    /' || echo "    (todos los pods Running/Completed)"

echo -e "\n${B}2) AMP (namespace wso2-amp)${N}"
kc get pods -n wso2-amp 2>/dev/null | grep -v "^NAME" | sed 's/^/    /'
kc get pods -n wso2-amp 2>/dev/null | grep -q "amp-api.*1/1.*Running"        && ok "amp-api"     || bad "amp-api"
kc get pods -n wso2-amp 2>/dev/null | grep -q "amp-console.*1/1.*Running"    && ok "amp-console" || bad "amp-console"
kc get pods -n wso2-amp 2>/dev/null | grep -q "amp-postgresql.*1/1.*Running" && ok "postgresql"  || bad "postgresql"

echo -e "\n${B}3) GATEWAY${N}"
kc get apigateway -A -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Programmed")].status}{end}' 2>/dev/null | grep -q True && ok "Gateway Programmed=True" || warn "Gateway no Programmed aún"
curl -s -m 5 -o /dev/null -w "%{http_code}" http://localhost:9000/healthz 2>/dev/null | grep -q 200 && ok "API :9000 OK" || bad "API :9000 no responde"
curl -s -m 5 -o /dev/null -w "%{http_code}" http://localhost:3000 2>/dev/null | grep -q "200\|304" && ok "Console :3000 OK" || bad "Console :3000 no responde"

echo -e "\n${B}4) AGENTES${N}"
for NS in $(kc get ns 2>/dev/null | grep -oE "dp-default-[^ ]+"); do
    kc get pods -n "$NS" 2>/dev/null | grep -q "1/1.*Running" && ok "Running: $NS" || warn "No Running: $NS"
done
[ -z "$(kc get ns 2>/dev/null | grep 'dp-default-')" ] && warn "Sin agentes desplegados aún"

echo -e "${B}=================================================${N}"
