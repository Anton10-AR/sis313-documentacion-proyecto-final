#!/bin/bash
# =============================================================================
# new_client.sh — Orquestador: crea y despliega un nuevo cliente completo
# SIS313 | USFX | Proyecto 13
#
# Uso: sudo bash new_client.sh <cliente> <dominio> [quota_mb]
# Ej:  sudo bash new_client.sh nexocorp nexocorp.hosting.local 400
#
# Ejecutar en: VM Hosting (192.168.100.152) como root
#
# Llama en orden:
#   1. create_client.sh  → crea usuario, dirs, vhost, logrotate, quota, firewall
#   2. deploy_dns.sh     → añade registro DNS en VM DNS vía SSH
#   3. deploy_proxy.sh   → crea virtual host en VM Proxy vía SSH
#   4. backup_client.sh  → realiza el primer backup del cliente
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
log_ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_IP="192.168.100.155"
BACKUP_USER="adming5"
BACKUP_SSH_KEY="/root/.ssh/id_backup_from_hosting"

# ── Verificar root ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { log_err "Ejecutar como root: sudo bash $0"; exit 1; }

# ── Argumentos ────────────────────────────────────────────────────────────────
CLIENT="${1:-}"
DOMAIN="${2:-}"
QUOTA_MB="${3:-500}"

if [[ -z "$CLIENT" || -z "$DOMAIN" ]]; then
    echo ""
    echo "Uso: sudo bash $0 <cliente> <dominio> [quota_mb]"
    echo "Ej:  sudo bash $0 nexocorp nexocorp.hosting.local 400"
    echo ""
    exit 1
fi

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${BLUE}║   Nuevo Cliente — SIS313 Hosting                     ║${RESET}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Cliente : ${CYAN}${CLIENT}${RESET}"
echo -e "  Dominio : ${CYAN}${DOMAIN}${RESET}"
echo -e "  Quota   : ${CYAN}${QUOTA_MB} MB${RESET}"
echo ""

START_TIME=$(date +%s)
FAILED_STEP=""

# ── Función para registrar resultado de cada paso ─────────────────────────────
step_result() {
    local step="$1"
    local status="$2"   # ok | fail
    local msg="$3"
    if [[ "$status" == "ok" ]]; then
        echo -e "  ${GREEN}✓${RESET} ${step}"
    else
        echo -e "  ${RED}✗${RESET} ${step} — ${msg}"
        FAILED_STEP="$step"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# PASO 1: Crear cliente en VM Hosting (local)
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}[1/4] Creando cliente en VM Hosting...${RESET}"
if bash "${SCRIPTS_DIR}/create_client.sh" "$CLIENT" "$DOMAIN" "$QUOTA_MB"; then
    step_result "create_client.sh" "ok" ""
else
    step_result "create_client.sh" "fail" "ver salida arriba"
    log_err "Fallo en el paso 1. Abortando."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# PASO 2: Propagar DNS en VM DNS
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}[2/4] Propagando DNS en VM DNS (192.168.100.154)...${RESET}"
if bash "${SCRIPTS_DIR}/deploy_dns.sh" "$CLIENT" "$DOMAIN"; then
    step_result "deploy_dns.sh" "ok" ""
else
    step_result "deploy_dns.sh" "fail" "cliente creado en Hosting pero sin DNS"
    log_warn "Puedes reintentar manualmente: bash ${SCRIPTS_DIR}/deploy_dns.sh ${CLIENT} ${DOMAIN}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PASO 3: Crear virtual host en VM Proxy
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}[3/4] Creando virtual host en VM Proxy (192.168.100.151)...${RESET}"
if bash "${SCRIPTS_DIR}/deploy_proxy.sh" "$CLIENT" "$DOMAIN"; then
    step_result "deploy_proxy.sh" "ok" ""
else
    step_result "deploy_proxy.sh" "fail" "cliente creado pero sin vhost en Proxy"
    log_warn "Puedes reintentar manualmente: bash ${SCRIPTS_DIR}/deploy_proxy.sh ${CLIENT} ${DOMAIN}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PASO 4: Primer backup desde VM Backup
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}[4/4] Realizando primer backup...${RESET}"

# El backup se ejecuta en la VM Backup (155) via SSH
# Requiere clave SSH desde Hosting hacia Backup (configurar si no existe)
if [[ -f "$BACKUP_SSH_KEY" ]]; then
    if ssh -i "$BACKUP_SSH_KEY" \
           -o StrictHostKeyChecking=no \
           -o ConnectTimeout=10 \
           "${BACKUP_USER}@${BACKUP_IP}" \
           "sudo bash /opt/backup/backup_client.sh backup ${CLIENT}"; then
        step_result "backup_client.sh (primer backup)" "ok" ""
    else
        step_result "backup_client.sh (primer backup)" "fail" "el backup nocturno lo hará automáticamente"
        log_warn "El backup automático (cron 02:00) incluirá a '${CLIENT}' esta noche."
    fi
else
    log_warn "Clave SSH hacia VM Backup no encontrada en ${BACKUP_SSH_KEY}."
    log_warn "El backup automático (cron 02:00) incluirá a '${CLIENT}' esta noche."
    step_result "backup_client.sh (primer backup)" "fail" "sin clave SSH hacia Backup — se hará automáticamente"
fi

# ── Resumen final ─────────────────────────────────────────────────────────────
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${BLUE}║   Resumen                                            ║${RESET}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Cliente  : ${CYAN}${CLIENT}${RESET}"
echo -e "  Dominio  : ${CYAN}${DOMAIN}${RESET}"
echo -e "  URL      : ${CYAN}http://${DOMAIN}${RESET}"
echo -e "  Tiempo   : ${ELAPSED} segundos"
echo ""

if [[ -z "$FAILED_STEP" ]]; then
    log_ok "Cliente '${CLIENT}' desplegado completamente."
else
    log_warn "Cliente '${CLIENT}' creado con advertencias. Revisar los pasos fallidos."
fi
echo ""
