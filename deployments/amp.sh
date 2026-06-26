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

bootstrap)
    echo -e "${B}Bootstrap — máquina limpia → AMP v0.16.0${N}"
    echo ""

    # ── 1. Homebrew ───────────────────────────────────────────────────────────
    if ! command -v brew >/dev/null 2>&1; then
        echo "  Instalando Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    else
        ok "Homebrew ya instalado"
    fi

    # ── 2. Herramientas ───────────────────────────────────────────────────────
    for tool in k3d kubectl helm podman; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "  Instalando $tool..."
            brew install "$tool"
        else
            ok "$tool ya instalado"
        fi
    done

    # ── 3. Podman machine ─────────────────────────────────────────────────────
    if ! podman machine list 2>/dev/null | grep -q "podman-machine-default"; then
        echo "  Creando Podman machine (4 CPUs, 8GB RAM, 60GB disco)..."
        podman machine init --cpus 4 --memory 8192 --disk-size 60
    else
        ok "Podman machine ya existe"
    fi

    if ! podman machine list 2>/dev/null | grep -q "Running"; then
        echo "  Arrancando Podman machine..."
        podman machine start podman-machine-default
    else
        ok "Podman machine Running"
    fi

    # Esperar a que Docker socket esté listo
    for i in $(seq 1 20); do docker info >/dev/null 2>&1 && break; sleep 3; done
    docker info >/dev/null 2>&1 || fail "Docker/Podman socket no responde"
    ok "Docker socket OK"

    # ── 4. Instalar AMP ───────────────────────────────────────────────────────
    echo ""
    echo -e "${B}  Instalando AMP v0.16.0...${N}"
    bash "$0" init
    ;;

check)
    REPO_DIR="$(dirname "$SCRIPT_DIR")"
    echo -e "${B}Comprobando cambios en WSO2 upstream...${N}"
    git -C "$REPO_DIR" fetch origin -q
    NEW=$(git -C "$REPO_DIR" log main..origin/main --oneline)
    if [ -z "$NEW" ]; then
        ok "Sin cambios — estás al día con WSO2"
    else
        COUNT=$(echo "$NEW" | wc -l | tr -d ' ')
        warn "$COUNT commits nuevos en WSO2:"
        echo "$NEW" | sed 's/^/    /'
        echo ""
        echo "  Para actualizar: bash deployments/amp.sh update"
    fi
    ;;

update)
    REPO_DIR="$(dirname "$SCRIPT_DIR")"
    CURRENT=$(git -C "$REPO_DIR" branch --show-current)
    echo -e "${B}Actualizando desde WSO2 upstream...${N}"
    git -C "$REPO_DIR" fetch origin -q
    NEW=$(git -C "$REPO_DIR" log main..origin/main --oneline)
    if [ -z "$NEW" ]; then
        ok "Ya estás al día, nada que actualizar"
        exit 0
    fi
    COUNT=$(echo "$NEW" | wc -l | tr -d ' ')
    echo "  $COUNT commits nuevos:"
    echo "$NEW" | sed 's/^/    /'
    echo ""
    # Avanzar main hasta origin/main
    git -C "$REPO_DIR" branch -f main origin/main
    ok "main actualizado a origin/main"
    # Rerebasar la rama de trabajo encima del nuevo main
    git -C "$REPO_DIR" rebase main "$CURRENT" 2>&1 | sed 's/^/    /'
    ok "Rama $CURRENT rebasada encima del nuevo main"
    echo ""
    warn "Si cambia algo en install.sh, haz: bash deployments/amp.sh init"
    ;;

--help|-h|help|*)
    echo "Uso: bash deployments/amp.sh <comando>"
    echo ""
    echo "  Cluster:"
    echo "    start      Arranca el cluster pausado (auto-fix Podman si falla)"
    echo "    stop       Pausa el cluster (conserva todos los datos)"
    echo "    init       Borra y reinstala desde cero (VERSION=0.16.0)"
    echo "    status     Muestra estado de pods, gateway y agentes"
    echo "    bootstrap  Máquina limpia → instala todo y levanta AMP"
    echo ""
    echo "  WSO2 upstream:"
    echo "    check    Ve si WSO2 tiene cambios nuevos (sin tocar nada)"
    echo "    update   Descarga y aplica los cambios de WSO2"
    ;;
esac
