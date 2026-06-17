#!/bin/bash
# =============================================================================
# deploy_proxy.sh — Crea virtual host en el Proxy Inverso para un nuevo cliente
# SIS313 | USFX | Proyecto 13
#
# Uso: bash deploy_proxy.sh <cliente> <dominio>
# Ej:  bash deploy_proxy.sh innovatech innovatech.hosting.local
#
# Ejecutar en: VM Hosting (192.168.100.152)
# Opera en:    VM Proxy (192.168.100.151) vía SSH
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log_ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

PROXY_IP="192.168.100.151"
PROXY_USER="adming5"
SSH_KEY="/home/adming5/.ssh/id_hosting"
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
LOG_DIR="/var/log/nginx/clients"

SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10"

ssh_proxy() { ssh $SSH_OPTS "${PROXY_USER}@${PROXY_IP}" "$@"; }

# ── Validar argumentos ────────────────────────────────────────────────────────
CLIENT="${1:-}"
DOMAIN="${2:-}"

if [[ -z "$CLIENT" || -z "$DOMAIN" ]]; then
    echo "Uso: bash $0 <cliente> <dominio>"
    echo "Ej:  bash $0 innovatech innovatech.hosting.local"
    exit 1
fi

echo ""
echo -e "${BOLD}── deploy_proxy.sh: ${CYAN}${CLIENT}${RESET}${BOLD} → ${PROXY_IP} ──${RESET}"

# ── Verificar conectividad ────────────────────────────────────────────────────
log_info "Verificando conexión a VM Proxy (${PROXY_IP})..."
ssh_proxy "echo ok" &>/dev/null || {
    log_err "No se puede conectar a ${PROXY_USER}@${PROXY_IP}"
    exit 1
}
log_ok "Conexión SSH establecida."

# ── Verificar que el vhost no existe ya ───────────────────────────────────────
if ssh_proxy "test -f ${NGINX_AVAIL}/${DOMAIN}.conf" 2>/dev/null; then
    log_ok "Virtual host para '${DOMAIN}' ya existe. Se omite."
    exit 0
fi

# ── Crear directorio de logs en el proxy ──────────────────────────────────────
log_info "Preparando directorio de logs en Proxy..."
ssh_proxy "sudo mkdir -p ${LOG_DIR}"

# ── Crear virtual host vía heredoc remoto ─────────────────────────────────────
log_info "Creando virtual host: ${DOMAIN}.conf"

ssh_proxy "sudo tee ${NGINX_AVAIL}/${DOMAIN}.conf > /dev/null << 'VHOST'
# Virtual Host: ${DOMAIN}
# Cliente:      ${CLIENT}
# Creado:       $(date '+%Y-%m-%d %H:%M:%S')
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    access_log ${LOG_DIR}/${CLIENT}_proxy.log;
    error_log  ${LOG_DIR}/${CLIENT}_proxy_error.log warn;
    server_tokens off;
    location / {
        proxy_pass         http://hosting_backend;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 10s;
        proxy_read_timeout    30s;
    }
    location ~ /\. { deny all; }
}
VHOST"

# ── Habilitar el sitio ────────────────────────────────────────────────────────
log_info "Habilitando sitio en sites-enabled..."
ssh_proxy "sudo ln -sf ${NGINX_AVAIL}/${DOMAIN}.conf ${NGINX_ENABLED}/${DOMAIN}.conf"

# ── Verificar configuración y recargar ────────────────────────────────────────
log_info "Verificando configuración NGINX..."
CHECK=$(ssh_proxy "sudo nginx -t 2>&1")
if echo "$CHECK" | grep -q "successful"; then
    ssh_proxy "sudo systemctl reload nginx"
    log_ok "NGINX recargado correctamente."
else
    log_err "Error en la configuración de NGINX:"
    echo "$CHECK"
    # Revertir si hay error
    ssh_proxy "sudo rm -f ${NGINX_AVAIL}/${DOMAIN}.conf ${NGINX_ENABLED}/${DOMAIN}.conf" 2>/dev/null || true
    exit 1
fi

# ── Verificar que el sitio responde ──────────────────────────────────────────
log_info "Verificando respuesta del sitio..."
RESPONSE=$(ssh_proxy "curl -s http://localhost -H 'Host: ${DOMAIN}' | grep '<title>' 2>/dev/null")
if echo "$RESPONSE" | grep -q "${DOMAIN}"; then
    log_ok "Sitio responde: ${RESPONSE// /}"
else
    log_err "El sitio no responde como se esperaba. Verificar manualmente."
    exit 1
fi

echo ""
