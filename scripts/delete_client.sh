#!/bin/bash
# =============================================================================
# delete_client.sh — Elimina un cliente completo de todas las VMs
# SIS313 | USFX | Proyecto 13
#
# Uso: sudo bash delete_client.sh <cliente>
# Ej:  sudo bash delete_client.sh acmecorp
#
# Ejecutar en: VM Hosting (192.168.100.152)
# Opera en:    VM Proxy (151) y VM DNS (154) vía SSH
#
# Elimina:
#   - Usuario del sistema web_<cliente>
#   - Directorio /var/www/hosting/<cliente>
#   - Logs /var/log/nginx/clients/<cliente>
#   - Virtual host NGINX en Hosting y Proxy
#   - Logrotate /etc/logrotate.d/hosting-<cliente>
#   - Registro DNS en BIND9
#   - Entrada en /var/lib/hosting/clients.tsv
#
# Los backups en VM Backup NO se eliminan por seguridad.
# Eliminarlos manualmente si se desea:
#   ssh backup
#   sudo rm -rf /var/backups/hosting/<cliente>
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
log_ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── Configuración ─────────────────────────────────────────────────────────────
WEB_BASE="/var/www/hosting"
LOG_BASE="/var/log/nginx/clients"
REGISTRY="/var/lib/hosting/clients.tsv"
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"

PROXY_IP="192.168.100.151"
PROXY_USER="adming5"
DNS_IP="192.168.100.154"
DNS_USER="adming5"
SSH_KEY="/home/adming5/.ssh/id_hosting"
ZONE_FILE="/etc/bind/zones/db.hosting.local"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10"

ssh_proxy() { ssh $SSH_OPTS "${PROXY_USER}@${PROXY_IP}" "$@"; }
ssh_dns()   { ssh $SSH_OPTS "${DNS_USER}@${DNS_IP}" "$@"; }

# ── Validaciones ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || { log_err "Ejecutar como root: sudo bash $0"; exit 1; }

CLIENT="${1:-}"
[[ -z "$CLIENT" ]] && { echo "Uso: sudo bash $0 <cliente>"; exit 1; }

# Verificar que el cliente existe
if ! grep -q "^${CLIENT}	" "$REGISTRY" 2>/dev/null; then
    log_err "Cliente '$CLIENT' no encontrado en el registro."
    exit 1
fi

DOMAIN=$(grep "^${CLIENT}	" "$REGISTRY" | cut -f2)

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${RED}║   Eliminar Cliente — SIS313 Hosting                  ║${RESET}"
echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Cliente : ${CYAN}${CLIENT}${RESET}"
echo -e "  Dominio : ${CYAN}${DOMAIN}${RESET}"
echo ""
echo -e "  ${RED}ADVERTENCIA: Esta acción es irreversible.${RESET}"
echo -e "  ${YELLOW}Los backups en VM Backup se conservan por seguridad.${RESET}"
echo ""
CONFIRM="${2:-}"
if [[ -z "$CONFIRM" || "$CONFIRM" != "$CLIENT" ]]; then
    log_warn "Eliminación cancelada."
    exit 0
fi

echo ""
START_TIME=$(date +%s)

# ──────────────────────────────────────────────────────────────────────────────
# PASO 1: Eliminar en VM Hosting (local)
# ──────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}[1/4] Eliminando en VM Hosting...${RESET}"

# Virtual host NGINX
rm -f "${NGINX_ENABLED}/${DOMAIN}.conf" "${NGINX_AVAIL}/${DOMAIN}.conf"
log_ok "Virtual host NGINX eliminado."

# Recargar NGINX
if nginx -t 2>/dev/null; then
    systemctl reload nginx
    log_ok "NGINX recargado."
fi

# Directorios web y logs
rm -rf "${WEB_BASE}/${CLIENT}"
log_ok "Directorio web eliminado: ${WEB_BASE}/${CLIENT}"

rm -rf "${LOG_BASE}/${CLIENT}"
log_ok "Logs eliminados: ${LOG_BASE}/${CLIENT}"

# Logrotate
rm -f "/etc/logrotate.d/hosting-${CLIENT}"
log_ok "Logrotate eliminado."

# Usuario del sistema
if id "web_${CLIENT}" &>/dev/null; then
    userdel "web_${CLIENT}" 2>/dev/null || true
    log_ok "Usuario web_${CLIENT} eliminado."
fi

# Regla iptables (si existe)
UID_CLIENT=$(id -u "web_${CLIENT}" 2>/dev/null) || true
if [[ -n "$UID_CLIENT" ]]; then
    iptables -D OUTPUT -m owner --uid-owner "$UID_CLIENT" ! -d 127.0.0.1 -j DROP 2>/dev/null || true
    log_ok "Regla iptables eliminada."
fi

# Registro en TSV
sed -i "/^${CLIENT}	/d" "$REGISTRY"
log_ok "Entrada eliminada del registro."

echo -e "  ${GREEN}✓${RESET} Hosting limpio."

# ──────────────────────────────────────────────────────────────────────────────
# PASO 2: Eliminar virtual host en VM Proxy
# ──────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}[2/4] Eliminando virtual host en VM Proxy (${PROXY_IP})...${RESET}"

if ssh_proxy "test -f ${NGINX_AVAIL}/${DOMAIN}.conf" 2>/dev/null; then
    ssh_proxy "sudo rm -f ${NGINX_ENABLED}/${DOMAIN}.conf ${NGINX_AVAIL}/${DOMAIN}.conf"
    if ssh_proxy "sudo nginx -t 2>/dev/null"; then
        ssh_proxy "sudo systemctl reload nginx"
        log_ok "Virtual host y NGINX recargado en Proxy."
    fi
    echo -e "  ${GREEN}✓${RESET} Proxy limpio."
else
    log_warn "Virtual host no encontrado en Proxy. Se omite."
    echo -e "  ${YELLOW}~${RESET} Proxy (ya estaba limpio)"
fi

# ──────────────────────────────────────────────────────────────────────────────
# PASO 3: Eliminar registro DNS en VM DNS
# ──────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}[3/4] Eliminando registro DNS en VM DNS (${DNS_IP})...${RESET}"

# Obtener serial actual e incrementarlo
CURRENT_SERIAL=$(ssh_dns "grep -oP '\d{10}' ${ZONE_FILE} | head -1")
NEW_SERIAL=$(( CURRENT_SERIAL + 1 ))

ssh_dns "
    sudo sed -i 's/${CURRENT_SERIAL}/${NEW_SERIAL}/' ${ZONE_FILE}
    sudo sed -i '/^${CLIENT}[[:space:]]/d' ${ZONE_FILE}
    sudo sed -i '/^www\.${CLIENT}[[:space:]]/d' ${ZONE_FILE}
    sudo sed -i '/; Cliente: ${CLIENT}/d' ${ZONE_FILE}
"

CHECK=$(ssh_dns "sudo named-checkzone hosting.local ${ZONE_FILE} 2>&1")
if echo "$CHECK" | grep -q "OK"; then
    ssh_dns "sudo rndc reload" &>/dev/null
    log_ok "Registro DNS eliminado. Serial: ${CURRENT_SERIAL} → ${NEW_SERIAL}"
    echo -e "  ${GREEN}✓${RESET} DNS limpio."
else
    log_err "Error en zona DNS tras eliminar registro:"
    echo "$CHECK"
    echo -e "  ${RED}✗${RESET} DNS — verificar manualmente"
fi

# ──────────────────────────────────────────────────────────────────────────────
# PASO 4: Nota sobre backups
# ──────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}[4/4] Backups...${RESET}"
log_warn "Los backups en VM Backup (192.168.100.155) se conservan por seguridad."
log_warn "Para eliminarlos manualmente:"
log_warn "  ssh backup"
log_warn "  sudo rm -rf /var/backups/hosting/${CLIENT}"
echo -e "  ${YELLOW}~${RESET} Backups conservados"

# ── Resumen ───────────────────────────────────────────────────────────────────
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

echo ""
echo -e "${BOLD}${RED}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${RED}║   Resumen                                            ║${RESET}"
echo -e "${BOLD}${RED}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Cliente eliminado : ${CYAN}${CLIENT}${RESET}"
echo -e "  Dominio           : ${CYAN}${DOMAIN}${RESET}"
echo -e "  Tiempo            : ${ELAPSED} segundos"
echo ""
log_ok "Cliente '${CLIENT}' eliminado del sistema."
echo ""
