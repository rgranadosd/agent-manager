#!/bin/bash
# ============================================================================
# AMP — Agent Management Platform v0.16.0
# Cluster: amp-local (k3d + Podman)
#
# USAGE (desde deployments/):
#   bash amp.sh start   — arrancar cluster pausado
#   bash amp.sh stop    — pausar cluster (conserva datos)
#   bash amp.sh init    — reinstalar desde cero
#   bash amp.sh status  — ver estado
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="amp-local"
QUICK_START="$SCRIPT_DIR/quick-start"

G="\033[32m"; Y="\033[33m"; R="\033[31m"; B="\033[1m"; N="\033[0m"
ok()  { echo -e "${G}✓ $1${N}"; }
warn(){ echo -e "${Y}⚠ $1${N}"; }
fail(){ echo -e "${R}✗ $1${N}"; exit 1; }

CMD="${1:-}"

case "$CMD" in

stop)
    echo -e "${B}Parando cluster $CLUSTER...${N}"
    k3d cluster stop "$CLUSTER" && ok "Cluster pausado (datos conservados)" || fail "Error al parar el cluster"
    ;;

start)
    echo -e "${B}Arrancando cluster $CLUSTER...${N}"
    k3d cluster start "$CLUSTER"
    RC=$?
    if [ $RC -ne 0 ]; then
        warn "Fallo al arrancar — reiniciando Podman VM (fix conocido)..."
        podman machine stop podman-machine-default
        podman machine start podman-machine-default
        for i in $(seq 1 20); do docker info >/dev/null 2>&1 && break; sleep 3; done
        k3d cluster start "$CLUSTER" || fail "Error al arrancar el cluster tras reinicio de Podman"
    fi
    ok "Cluster arrancado"
    echo ""
    echo "  Console:  http://localhost:3000  (amp-admin / amp-admin)"
    echo "  API:      http://localhost:9000"
    ;;

init)
    echo -e "${B}Reinstalando AMP v0.16.0 desde cero...${N}"
    echo ""
    if k3d cluster list 2>/dev/null | grep -q "$CLUSTER"; then
        warn "Borrando cluster existente..."
        k3d cluster delete "$CLUSTER"
    fi
    cd "$QUICK_START"
    export VERSION=0.16.0
    if bash install.sh; then
        echo ""
        ok "AMP v0.16.0 instalado"
        echo ""
        echo "  Console:  http://localhost:3000  (amp-admin / amp-admin)"
        echo "  API:      http://localhost:9000"
    else
        fail "install.sh falló — revisa el output"
    fi
    ;;

status)
    bash "$SCRIPT_DIR/amp-status.sh"
    ;;

*)
    echo "Uso: bash deployments/amp.sh {start|stop|init|status}"
    echo ""
    echo "  start   Arranca el cluster pausado"
    echo "  stop    Pausa el cluster (conserva datos)"
    echo "  init    Borra y reinstala desde cero (VERSION=0.16.0)"
    echo "  status  Muestra el estado actual"
    ;;
esac
