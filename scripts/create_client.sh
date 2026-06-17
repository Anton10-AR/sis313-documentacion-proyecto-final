#!/bin/bash
# =============================================================================
# create_client.sh — Proyecto 13: Proveedor de Hosting Web Compartido
# SIS313 | USFX | Semestre 1/2026
#
# Uso: sudo bash create_client.sh <nombre_cliente> <dominio> [quota_mb]
# Ej:  sudo bash create_client.sh acmecorp acmecorp.hosting.local 500
#
# Ejecutar en: VM Hosting (192.168.100.152)
# Requisitos:  nginx, quota, logrotate instalados; grupo www-hosting existente
# =============================================================================

set -euo pipefail

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log_ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── Rutas fijas ───────────────────────────────────────────────────────────────
WEB_BASE="/var/www/hosting"
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
LOG_BASE="/var/log/nginx/clients"
BACKUP_BASE="/var/backups/hosting"
LOGROTATE_DIR="/etc/logrotate.d"
REGISTRY="/var/lib/hosting/clients.tsv"
NGINX_GROUP="www-hosting"

# ── Verificaciones previas ────────────────────────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] || { log_err "Ejecutar como root: sudo bash $0"; exit 1; }
}

check_deps() {
    local missing=()
    for cmd in nginx logrotate; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || {
        log_err "Faltan dependencias: ${missing[*]}"
        log_err "Instalar con: sudo apt install ${missing[*]}"
        exit 1
    }
}

validate_client() {
    local name="$1"
    [[ "$name" =~ ^[a-z][a-z0-9-]{2,29}$ ]] || {
        log_err "Nombre inválido: '$name'. Solo minúsculas, números y guion. 3-30 chars."
        exit 1
    }
}

# ── 1. Grupo compartido ───────────────────────────────────────────────────────
ensure_group() {
    if ! getent group "$NGINX_GROUP" &>/dev/null; then
        groupadd --system "$NGINX_GROUP"
        log_ok "Grupo '$NGINX_GROUP' creado."
    fi
    # NGINX necesita estar en el grupo para leer los public_html
    usermod -aG "$NGINX_GROUP" www-data 2>/dev/null || true
}

# ── 2. Usuario del sistema ────────────────────────────────────────────────────
create_user() {
    local client="$1"
    local username="web_${client}"

    if id "$username" &>/dev/null; then
        log_warn "Usuario '$username' ya existe. Se omite."
        return 0
    fi

    useradd \
        --system \
        --no-create-home \
        --shell /usr/sbin/nologin \
        --comment "Hosting-$client" \
        --gid "$NGINX_GROUP" \
        "$username"
    log_ok "Usuario del sistema '$username' creado (sin shell, sin home)."
}

# ── 3. Directorios con permisos estrictos ─────────────────────────────────────
create_directories() {
    local client="$1"
    local username="web_${client}"
    local client_dir="${WEB_BASE}/${client}"

    mkdir -p \
        "${client_dir}/public_html" \
        "${client_dir}/logs" \
        "${client_dir}/tmp" \
        "${LOG_BASE}/${client}/archive" \
        "${BACKUP_BASE}/${client}"

    # Propietario del árbol: usuario del cliente
    chown -R "${username}:${NGINX_GROUP}" "${client_dir}"

    # Permisos:
    #   client_dir/       750 → solo propietario y grupo (nginx) entran
    #   public_html/      755 → nginx puede leer, el cliente puede escribir
    #   logs/             750 → solo propietario y grupo
    #   tmp/              700 → solo el propietario
    chmod 750 "${client_dir}"
    chmod 755 "${client_dir}/public_html"
    chmod 750 "${client_dir}/logs"
    chmod 700 "${client_dir}/tmp"

    # Logs de nginx: root los escribe, el grupo puede leerlos
    chown -R root:"${NGINX_GROUP}" "${LOG_BASE}/${client}"
    chmod -R 750 "${LOG_BASE}/${client}"

    # Backups: solo root
    chmod 700 "${BACKUP_BASE}/${client}"

    log_ok "Directorios creados con permisos estrictos."
    log_info "  ${client_dir}/public_html  → 755 (${username}:${NGINX_GROUP})"
    log_info "  ${client_dir}/tmp          → 700 (${username}:${NGINX_GROUP})"
    log_info "  ${LOG_BASE}/${client}      → 750 (root:${NGINX_GROUP})"
}

# ── 4. Página de bienvenida HTML ──────────────────────────────────────────────
create_welcome_page() {
    local client="$1"
    local domain="$2"
    local username="web_${client}"
    local index="${WEB_BASE}/${client}/public_html/index.html"

    cat > "$index" <<HTML
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${domain} — SIS313 Hosting</title>
  <style>
    *{box-sizing:border-box;margin:0;padding:0}
    body{font-family:'Segoe UI',sans-serif;background:#0f172a;color:#e2e8f0;
         display:flex;justify-content:center;align-items:center;min-height:100vh}
    .card{background:#1e293b;border:1px solid #334155;border-radius:14px;
          padding:2.5rem 3rem;max-width:540px;width:90%;text-align:center;
          box-shadow:0 20px 60px rgba(0,0,0,.5)}
    .badge{background:#22c55e;color:#052e16;font-size:.75rem;font-weight:700;
           padding:4px 14px;border-radius:20px;letter-spacing:1px;
           display:inline-block;margin-bottom:1.2rem}
    h1{font-size:1.9rem;color:#f1f5f9;margin-bottom:.4rem}
    .domain{color:#94a3b8;font-size:.95rem;margin-bottom:1.8rem}
    .grid{display:grid;grid-template-columns:1fr 1fr;gap:.6rem;text-align:left}
    .item{background:#0f172a;border-radius:8px;padding:.75rem 1rem}
    .label{color:#475569;font-size:.72rem;text-transform:uppercase;letter-spacing:.5px}
    .value{color:#38bdf8;font-size:.9rem;margin-top:.2rem;font-weight:600}
    .footer{margin-top:1.5rem;color:#334155;font-size:.78rem}
  </style>
</head>
<body>
  <div class="card">
    <div class="badge">✓ ACTIVO</div>
    <h1>${domain}</h1>
    <p class="domain">Alojado en SIS313 Hosting · USFX</p>
    <div class="grid">
      <div class="item">
        <div class="label">Cliente</div>
        <div class="value">${client}</div>
      </div>
      <div class="item">
        <div class="label">Servidor</div>
        <div class="value">hosting (192.168.100.152)</div>
      </div>
      <div class="item">
        <div class="label">Proxy</div>
        <div class="value">192.168.100.151</div>
      </div>
      <div class="item">
        <div class="label">Activado</div>
        <div class="value">$(date '+%Y-%m-%d')</div>
      </div>
    </div>
    <div class="footer">Proyecto 13 · Infraestructura, Plataformas y Redes · 1/2026</div>
  </div>
</body>
</html>
HTML

    chown "${username}:${NGINX_GROUP}" "$index"
    chmod 644 "$index"
    log_ok "Página de bienvenida creada."
}

# ── 5. Virtual host NGINX (en el servidor Hosting) ───────────────────────────
create_nginx_vhost() {
    local client="$1"
    local domain="$2"
    local vhost="${NGINX_AVAIL}/${domain}.conf"

    cat > "$vhost" <<NGINX
# ─────────────────────────────────────────────────────────────────────────────
# Virtual Host: ${domain}
# Cliente:      ${client}
# Servidor:     VM Hosting (192.168.100.152)
# Creado:       $(date '+%Y-%m-%d %H:%M:%S')
# ─────────────────────────────────────────────────────────────────────────────

server {
    listen 80;
    server_name ${domain} www.${domain};

    root ${WEB_BASE}/${client}/public_html;
    index index.html index.htm;

    # Logs individuales por cliente
    access_log  ${LOG_BASE}/${client}/access.log combined;
    error_log   ${LOG_BASE}/${client}/error.log warn;

    # Ocultar versión de nginx
    server_tokens off;

    # Cabeceras de seguridad HTTP
    add_header X-Frame-Options        "SAMEORIGIN"   always;
    add_header X-Content-Type-Options "nosniff"      always;
    add_header X-XSS-Protection       "1; mode=block" always;

    location / {
        try_files \$uri \$uri/ =404;
        # Solo métodos seguros
        limit_except GET HEAD { deny all; }
    }

    # Denegar acceso a archivos ocultos (.htaccess, .git, etc.)
    location ~ /\. {
        deny all;
        access_log off;
        log_not_found off;
    }

    # Denegar acceso directo al directorio tmp
    location ^~ /tmp/ {
        deny all;
    }
}
NGINX

    # Activar el sitio
    ln -sf "${vhost}" "${NGINX_ENABLED}/${domain}.conf"
    log_ok "Virtual host NGINX creado y activado: ${domain}"
}

# ── 6. Logrotate por cliente ──────────────────────────────────────────────────
setup_logrotate() {
    local client="$1"

    cat > "${LOGROTATE_DIR}/hosting-${client}" <<LOGROTATE
# Logrotate para cliente: ${client}
# Rotación diaria, 30 días de retención, comprimido
${LOG_BASE}/${client}/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    sharedscripts
    dateext
    dateformat -%Y%m%d
    olddir ${LOG_BASE}/${client}/archive
    createolddir 750 root ${NGINX_GROUP}
    postrotate
        nginx -s reload > /dev/null 2>&1 || true
    endscript
}
LOGROTATE

    log_ok "Logrotate configurado: retención 30 días, comprimido, archivado."
}

# ── 7. Quota de disco ─────────────────────────────────────────────────────────
setup_quota() {
    local client="$1"
    local quota_mb="${2:-500}"
    local username="web_${client}"

    # Verificar que quota esté instalado
    if ! command -v setquota &>/dev/null; then
        log_warn "Quota no instalado. Instalar: sudo apt install quota"
        log_warn "Se omite configuración de quota para '$client'."
        return 0
    fi

    # Verificar que el filesystem tenga usrquota montado
    local mount_point
    mount_point=$(df --output=target "${WEB_BASE}" | tail -1)
    if ! grep -qE "usrquota|uquota" /proc/mounts 2>/dev/null; then
        log_warn "El filesystem en '${mount_point}' no tiene 'usrquota' habilitado."
        log_warn "Para habilitar quotas, añadir 'usrquota' a la entrada de ${mount_point} en /etc/fstab:"
        log_warn "  Ejemplo: UUID=xxxx  ${mount_point}  ext4  defaults,usrquota  0 1"
        log_warn "  Luego: sudo mount -o remount ${mount_point} && sudo quotacheck -cum ${mount_point} && sudo quotaon ${mount_point}"
        log_warn "Se omite quota para '$client' hasta que el filesystem esté habilitado."
        return 0
    fi

    # soft = quota_mb, hard = quota_mb + 20% (margen de gracia)
    local soft_kb=$(( quota_mb * 1024 ))
    local hard_kb=$(( quota_mb * 1024 * 12 / 10 ))   # +20%

    setquota -u "$username" "$soft_kb" "$hard_kb" 0 0 "$mount_point"
    log_ok "Quota: ${quota_mb} MB soft / $(( quota_mb * 12 / 10 )) MB hard para $username en ${mount_point}."
}

# ── 8. Reglas UFW: aislamiento entre clientes ─────────────────────────────────
setup_firewall() {
    local client="$1"
    local username="web_${client}"

    # El aislamiento principal se logra con permisos de filesystem (ya aplicados).
    # Adicionalmente, bloqueamos conexiones de red salientes de procesos del cliente
    # usando iptables xt_owner (requiere módulo xt_owner en el kernel).
    local uid
    uid=$(id -u "$username" 2>/dev/null) || return 0

    if modinfo xt_owner &>/dev/null 2>&1; then
        # Evitar regla duplicada
        if ! iptables -C OUTPUT -m owner --uid-owner "$uid" ! -d 127.0.0.1 -j DROP 2>/dev/null; then
            iptables -A OUTPUT -m owner --uid-owner "$uid" ! -d 127.0.0.1 -j DROP
            log_ok "Regla iptables xt_owner: procesos de UID $uid ($username) no pueden conectar a la red."
        else
            log_warn "Regla iptables para $username ya existe. Se omite."
        fi
    else
        log_warn "Módulo xt_owner no disponible. Aislamiento de red por UID omitido."
        log_warn "El aislamiento se aplica solo a nivel de permisos del filesystem."
    fi
}

# ── 9. Recargar NGINX ─────────────────────────────────────────────────────────
reload_nginx() {
    if nginx -t 2>/dev/null; then
        systemctl reload nginx
        log_ok "NGINX recargado correctamente."
    else
        log_err "Error en la configuración de NGINX:"
        nginx -t
        exit 1
    fi
}

# ── 10. Registrar cliente ─────────────────────────────────────────────────────
register_client() {
    local client="$1"
    local domain="$2"
    local quota_mb="$3"
    mkdir -p "$(dirname "$REGISTRY")"
    # Evitar duplicados
    if ! grep -q "^${client}	" "$REGISTRY" 2>/dev/null; then
        printf "%s\t%s\t%s\t%s\t%s\n" \
            "$client" "$domain" "${quota_mb}MB" \
            "$(date '+%Y-%m-%d %H:%M:%S')" "ACTIVO" \
            >> "$REGISTRY"
        log_ok "Cliente registrado en $REGISTRY"
    fi
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
    check_root
    check_deps

    local CLIENT="${1:-}"
    local DOMAIN="${2:-}"
    local QUOTA_MB="${3:-500}"

    if [[ -z "$CLIENT" || -z "$DOMAIN" ]]; then
        echo -e "\nUso: sudo bash $0 <cliente> <dominio> [quota_mb]"
        echo -e "Ej:  sudo bash $0 acmecorp acmecorp.hosting.local 500\n"
        exit 1
    fi

    validate_client "$CLIENT"

    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}   Creando cliente de hosting: ${CYAN}${CLIENT}${RESET}"
    echo -e "${BOLD}══════════════════════════════════════════════════════${RESET}"
    echo -e "  Dominio  : ${CYAN}${DOMAIN}${RESET}"
    echo -e "  Quota    : ${CYAN}${QUOTA_MB} MB${RESET}"
    echo -e "  Hosting  : 192.168.100.152"
    echo -e "  Proxy    : 192.168.100.151"
    echo ""

    ensure_group
    create_user          "$CLIENT"
    create_directories   "$CLIENT"
    create_welcome_page  "$CLIENT" "$DOMAIN"
    create_nginx_vhost   "$CLIENT" "$DOMAIN"
    setup_logrotate      "$CLIENT"
    setup_quota          "$CLIENT" "$QUOTA_MB"
    setup_firewall       "$CLIENT"
    reload_nginx
    register_client      "$CLIENT" "$DOMAIN" "$QUOTA_MB"

    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════${RESET}"
    log_ok "Cliente '${CLIENT}' creado exitosamente."
    echo ""
    echo -e "  Web dir  : ${WEB_BASE}/${CLIENT}/public_html"
    echo -e "  Logs     : ${LOG_BASE}/${CLIENT}/"
    echo -e "  Backup   : ${BACKUP_BASE}/${CLIENT}/"
    echo -e "  URL      : http://${DOMAIN}"
    echo ""
    echo -e "  ${YELLOW}SIGUIENTE PASO:${RESET} Añadir registro DNS en VM DNS (192.168.100.154):"
    echo -e "  ${CYAN}${CLIENT%.hosting.local}   IN  A  192.168.100.151${RESET}  (apunta al Proxy)"
    echo -e "${BOLD}══════════════════════════════════════════════════════${RESET}"
    echo ""
}

main "$@"
