#!/bin/bash
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log_ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

DNS_IP="192.168.100.154"
DNS_USER="adming5"
SSH_KEY="/home/adming5/.ssh/id_hosting"
ZONE_FILE="/etc/bind/zones/db.hosting.local"
PROXY_IP="192.168.100.151"
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10"
ssh_dns() { ssh $SSH_OPTS "${DNS_USER}@${DNS_IP}" "$@"; }

CLIENT="${1:-}"; DOMAIN="${2:-}"
[[ -z "$CLIENT" || -z "$DOMAIN" ]] && { echo "Uso: $0 <cliente> <dominio>"; exit 1; }

echo ""
echo -e "${BOLD}── deploy_dns.sh: ${CYAN}${CLIENT}${RESET}${BOLD} → ${DNS_IP} ──${RESET}"

log_info "Verificando conexión a VM DNS (${DNS_IP})..."
ssh_dns "echo ok" &>/dev/null || { log_err "No se puede conectar."; exit 1; }
log_ok "Conexión SSH establecida."

if ssh_dns "grep -q '^${CLIENT} \|^${CLIENT}\t' ${ZONE_FILE}" 2>/dev/null; then
    log_ok "Registro DNS para '${CLIENT}' ya existe. Se omite."
    exit 0
fi

log_info "Incrementando serial de zona..."
CURRENT_SERIAL=$(ssh_dns "grep -oP '\d{10}' ${ZONE_FILE} | head -1")
NEW_SERIAL=$(( CURRENT_SERIAL + 1 ))
log_info "  Serial: ${CURRENT_SERIAL} → ${NEW_SERIAL}"

log_info "Añadiendo registros A y CNAME para ${DOMAIN}..."

# Escribir fragmento en archivo temporal local
TMP_FRAGMENT=$(mktemp /tmp/dns_fragment_XXXXXX.txt)
cat > "$TMP_FRAGMENT" << FRAG

; Cliente: ${CLIENT}
${CLIENT}             IN  A       ${PROXY_IP}
www.${CLIENT}         IN  CNAME   ${DOMAIN}.
FRAG

# Actualizar serial en DNS
ssh_dns "sudo sed -i 's/${CURRENT_SERIAL}/${NEW_SERIAL}/' ${ZONE_FILE}"

# Transferir fragmento vía scp y concatenar
scp $SSH_OPTS "$TMP_FRAGMENT" "${DNS_USER}@${DNS_IP}:/tmp/dns_fragment.txt"
ssh_dns "sudo tee -a ${ZONE_FILE} < /tmp/dns_fragment.txt > /dev/null && rm /tmp/dns_fragment.txt"
rm -f "$TMP_FRAGMENT"

log_info "Verificando sintaxis de zona..."
CHECK=$(ssh_dns "sudo named-checkzone hosting.local ${ZONE_FILE} 2>&1")
if echo "$CHECK" | grep -q "OK"; then
    log_ok "Sintaxis de zona correcta."
else
    log_err "Error en la zona DNS:"; echo "$CHECK"; exit 1
fi

log_info "Recargando BIND9..."
ssh_dns "sudo rndc reload" &>/dev/null
log_ok "BIND9 recargado."

sleep 1
RESOLVED=$(ssh_dns "dig @192.168.100.154 ${DOMAIN} +short 2>/dev/null")
if [[ "$RESOLVED" == "${PROXY_IP}" ]]; then
    log_ok "DNS resuelve: ${DOMAIN} → ${RESOLVED}"
else
    log_err "Resolución fallida (obtuvo: '${RESOLVED}')"; exit 1
fi
echo ""
