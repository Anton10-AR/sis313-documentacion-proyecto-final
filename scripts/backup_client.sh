#!/bin/bash
# =============================================================================
# backup_client.sh — Backup y restauración por cliente
# SIS313 | USFX | Proyecto 13
#
# Ejecutar en: VM Backup (192.168.100.155)
# Origen:      VM Hosting (192.168.100.152) vía SSH sin contraseña
#
# Uso:
#   bash backup_client.sh menu               → menú interactivo
#   bash backup_client.sh all                → backup de todos los clientes
#   bash backup_client.sh backup <cliente>   → backup de un cliente
#   bash backup_client.sh restore <cliente>  → restaurar un cliente
#   bash backup_client.sh list <cliente>     → listar backups disponibles
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log_ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_err()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── Infraestructura ───────────────────────────────────────────────────────────
HOSTING_IP="192.168.100.152"
HOSTING_USER="backupagent"                # usuario dedicado en la VM Hosting
SSH_KEY="/root/.ssh/id_backup"            # clave ed25519 sin contraseña
SSH_OPTS="-i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10"

REMOTE_WEB_BASE="/var/www/hosting"
LOCAL_BACKUP_BASE="/var/backups/hosting"
BACKUP_LOG="/var/log/hosting-backup.log"

# Política de retención
RETAIN_DAILY=7
RETAIN_WEEKLY=4
RETAIN_MONTHLY=3

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
WEEK_NUM=$(date '+%Y_W%V')
MONTH=$(date '+%Y%m')
DOW=$(date '+%u')    # 1=lunes … 7=domingo
DOM=$(date '+%d')    # día del mes

# ── Helpers ───────────────────────────────────────────────────────────────────
tlog() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$BACKUP_LOG"; }

ssh_run() { ssh $SSH_OPTS "${HOSTING_USER}@${HOSTING_IP}" "$@"; }

list_remote_clients() {
    ssh_run "ls -1 ${REMOTE_WEB_BASE}/" 2>/dev/null
}

check_ssh() {
    if ! ssh_run "echo ok" &>/dev/null; then
        log_err "No se puede conectar a ${HOSTING_USER}@${HOSTING_IP}"
        log_err "Verificar: clave SSH en ${SSH_KEY}, usuario backupagent en Hosting."
        exit 1
    fi
}

# ── Backup de un cliente ──────────────────────────────────────────────────────
backup_client() {
    local client="$1"
    local daily_dir="${LOCAL_BACKUP_BASE}/${client}/daily"
    local weekly_dir="${LOCAL_BACKUP_BASE}/${client}/weekly"
    local monthly_dir="${LOCAL_BACKUP_BASE}/${client}/monthly"
    mkdir -p "$daily_dir" "$weekly_dir" "$monthly_dir"

    local archive="${client}_${TIMESTAMP}.tar.gz"
    tlog "Iniciando backup: $client"

    # Crear tar.gz en el servidor Hosting y transferirlo
    log_info "Empaquetando ${client} en ${HOSTING_IP}..."
    ssh_run "tar czf /tmp/${archive} -C ${REMOTE_WEB_BASE} ${client}/public_html 2>/dev/null"

    log_info "Transfiriendo ${archive}..."
    scp $SSH_OPTS "${HOSTING_USER}@${HOSTING_IP}:/tmp/${archive}" "${daily_dir}/${archive}"

    # Limpiar temporal en remoto
    ssh_run "rm -f /tmp/${archive}" 2>/dev/null || true

    # Verificar integridad
    if ! tar tzf "${daily_dir}/${archive}" &>/dev/null; then
        log_err "Backup corrupto: ${archive}. Eliminando."
        rm -f "${daily_dir}/${archive}"
        tlog "ERROR: backup corrupto para $client"
        return 1
    fi

    # Checksum
    md5sum "${daily_dir}/${archive}" > "${daily_dir}/${archive}.md5"

    local size
    size=$(du -sh "${daily_dir}/${archive}" | cut -f1)
    log_ok "Backup diario OK: ${archive} (${size})"
    tlog "  Diario: ${daily_dir}/${archive} (${size})"

    # Copia semanal (lunes)
    if [[ "$DOW" == "1" ]]; then
        cp "${daily_dir}/${archive}" "${weekly_dir}/${client}_${WEEK_NUM}.tar.gz"
        log_ok "Copia semanal: ${client}_${WEEK_NUM}.tar.gz"
        tlog "  Semanal: ${weekly_dir}/${client}_${WEEK_NUM}.tar.gz"
    fi

    # Copia mensual (día 1)
    if [[ "$DOM" == "01" ]]; then
        cp "${daily_dir}/${archive}" "${monthly_dir}/${client}_${MONTH}.tar.gz"
        log_ok "Copia mensual: ${client}_${MONTH}.tar.gz"
        tlog "  Mensual: ${monthly_dir}/${client}_${MONTH}.tar.gz"
    fi

    # Retención
    purge_old "$daily_dir"   "$RETAIN_DAILY"
    purge_old "$weekly_dir"  "$RETAIN_WEEKLY"
    purge_old "$monthly_dir" "$RETAIN_MONTHLY"
}

# ── Purgar backups antiguos ───────────────────────────────────────────────────
purge_old() {
    local dir="$1"
    local keep="$2"
    local archives
    mapfile -t archives < <(ls -1t "${dir}"/*.tar.gz 2>/dev/null)
    local count=${#archives[@]}

    if (( count > keep )); then
        local to_delete=$(( count - keep ))
        for f in "${archives[@]: -$to_delete}"; do
            rm -f "$f" "${f}.md5"
            log_info "Eliminado por retención: $(basename "$f")"
            tlog "  Purgado: $f"
        done
    fi
}

# ── Restaurar un cliente ──────────────────────────────────────────────────────
restore_client() {
    local client="$1"
    local backup_file="${2:-}"
    local daily_dir="${LOCAL_BACKUP_BASE}/${client}/daily"

    echo ""
    echo -e "${BOLD}══ RESTAURACIÓN: ${CYAN}${client}${RESET}${BOLD} ══${RESET}"

    # Elegir el más reciente si no se especifica
    if [[ -z "$backup_file" ]]; then
        backup_file=$(ls -1t "${daily_dir}"/*.tar.gz 2>/dev/null | head -1)
        [[ -n "$backup_file" ]] || {
            log_err "No hay backups disponibles para '$client'."
            return 1
        }
        log_info "Backup más reciente: $(basename "$backup_file")"
    fi

    [[ -f "$backup_file" ]] || { log_err "Archivo no encontrado: $backup_file"; return 1; }

    # Verificar integridad
    log_info "Verificando integridad..."
    tar tzf "$backup_file" &>/dev/null || { log_err "Archivo corrupto: $backup_file"; return 1; }
    log_ok "Integridad OK."

    # Verificar checksum si existe
    if [[ -f "${backup_file}.md5" ]]; then
        if md5sum -c "${backup_file}.md5" &>/dev/null; then
            log_ok "Checksum MD5 verificado."
        else
            log_warn "Checksum MD5 no coincide. Continúa bajo tu responsabilidad."
        fi
    fi

    # Confirmación
    echo -e "\n  ${YELLOW}¿Restaurar '${client}' desde $(basename "$backup_file")?${RESET}"
    echo -e "  ${RED}Esto sobreescribirá el public_html actual del cliente.${RESET}"
    read -r -p "  Escribe 'CONFIRMAR' para continuar: " confirm
    [[ "$confirm" == "CONFIRMAR" ]] || { log_warn "Restauración cancelada."; return 0; }

    # Snapshot de seguridad antes de restaurar
    local snap_dir="${LOCAL_BACKUP_BASE}/${client}/pre-restore"
    mkdir -p "$snap_dir"
    log_info "Creando snapshot de seguridad pre-restauración..."
    ssh_run "tar czf /tmp/prerestore_${client}_${TIMESTAMP}.tar.gz \
        -C ${REMOTE_WEB_BASE} ${client}/public_html 2>/dev/null || true"
    scp $SSH_OPTS \
        "${HOSTING_USER}@${HOSTING_IP}:/tmp/prerestore_${client}_${TIMESTAMP}.tar.gz" \
        "${snap_dir}/" 2>/dev/null && log_ok "Snapshot guardado en ${snap_dir}/" || true
    ssh_run "rm -f /tmp/prerestore_${client}_${TIMESTAMP}.tar.gz" 2>/dev/null || true

    # Transferir backup al Hosting y extraer
    log_info "Transfiriendo backup al servidor Hosting..."
    scp $SSH_OPTS "$backup_file" \
        "${HOSTING_USER}@${HOSTING_IP}:/tmp/restore_${client}.tar.gz"

    log_info "Extrayendo en ${HOSTING_IP}:${REMOTE_WEB_BASE}/${client}/public_html ..."
    ssh_run "
        set -e
        DEST='${REMOTE_WEB_BASE}/${client}/public_html'
	sudo -n find \"\$DEST\" -mindepth 1 -delete 2>/dev/null || true
        sudo -n tar xzf /tmp/restore_${client}.tar.gz \
            -C '${REMOTE_WEB_BASE}/${client}' \
            --strip-components=1 \
            2>/dev/null
        sudo -n chown -R web_${client}:www-hosting \"\$DEST\"
        sudo -n chmod 755 \"\$DEST\"
        rm -f /tmp/restore_${client}.tar.gz
    "

    tlog "Restauración completada: $client ← $(basename "$backup_file")"
    echo ""
    log_ok "Restauración de '${client}' completada."
    echo -e "  Origen  : $(basename "$backup_file")"
    echo -e "  Destino : ${HOSTING_IP}:${REMOTE_WEB_BASE}/${client}/public_html"
}

# ── Listar backups de un cliente ──────────────────────────────────────────────
list_backups() {
    local client="$1"
    local base="${LOCAL_BACKUP_BASE}/${client}"

    echo ""
    echo -e "${BOLD}Backups disponibles — ${CYAN}${client}${RESET}"
    echo "──────────────────────────────────────────────────"

    for tipo in daily weekly monthly; do
        echo -e "\n  ${YELLOW}[ ${tipo} ]${RESET}"
        local dir="${base}/${tipo}"
        if ls "${dir}"/*.tar.gz &>/dev/null 2>&1; then
            ls -lht "${dir}"/*.tar.gz | awk '{printf "    %-45s %s\n", $9, $5}'
        else
            echo "    (sin backups)"
        fi
    done

    local pre="${base}/pre-restore"
    if ls "${pre}"/*.tar.gz &>/dev/null 2>&1; then
        echo -e "\n  ${YELLOW}[ pre-restore (snapshots) ]${RESET}"
        ls -lht "${pre}"/*.tar.gz | awk '{printf "    %-45s %s\n", $9, $5}'
    fi
    echo ""
}

# ── Menú interactivo ──────────────────────────────────────────────────────────
menu() {
    while true; do
        clear
        echo -e "${BOLD}${CYAN}"
        echo "  ╔══════════════════════════════════════════╗"
        echo "  ║  Sistema de Backup — SIS313 Hosting      ║"
        echo "  ║  VM Backup (192.168.100.155)              ║"
        echo "  ╚══════════════════════════════════════════╝"
        echo -e "${RESET}"
        echo "  1) Backup de TODOS los clientes"
        echo "  2) Backup de un cliente específico"
        echo "  3) Restaurar un cliente"
        echo "  4) Listar backups de un cliente"
        echo "  5) Ver log de operaciones"
        echo "  6) Salir"
        echo ""
        read -r -p "  Opción: " op

        case "$op" in
        1)
            check_ssh
            tlog "=== Backup completo iniciado ==="
            for c in $(list_remote_clients); do
                backup_client "$c" || log_err "Fallo en backup de $c"
            done
            tlog "=== Backup completo finalizado ==="
            read -r -p "  Presiona Enter para continuar..."
            ;;
        2)
            read -r -p "  Nombre del cliente: " c
            check_ssh
            backup_client "$c"
            read -r -p "  Presiona Enter para continuar..."
            ;;
        3)
            read -r -p "  Nombre del cliente: " c
            list_backups "$c"
            read -r -p "  Ruta del archivo (Enter = más reciente): " bf
            check_ssh
            restore_client "$c" "$bf"
            read -r -p "  Presiona Enter para continuar..."
            ;;
        4)
            read -r -p "  Nombre del cliente: " c
            list_backups "$c"
            read -r -p "  Presiona Enter para continuar..."
            ;;
        5)
            tail -50 "$BACKUP_LOG" 2>/dev/null || echo "  (log vacío)"
            read -r -p "  Presiona Enter para continuar..."
            ;;
        6) echo "Saliendo."; exit 0 ;;
        *) log_warn "Opción no válida."; sleep 1 ;;
        esac
    done
}

# ── Punto de entrada ──────────────────────────────────────────────────────────
case "${1:-menu}" in
    all)
        check_ssh
        tlog "=== Backup automático (cron) ==="
        for c in $(list_remote_clients); do
            backup_client "$c" || tlog "ERROR en backup de $c"
        done
        tlog "=== Fin backup automático ==="
        ;;
    backup)
        check_ssh
        backup_client "${2:?Falta nombre de cliente}"
        ;;
    restore)
        check_ssh
        restore_client "${2:?Falta nombre de cliente}" "${3:-}"
        ;;
    list)
        list_backups "${2:?Falta nombre de cliente}"
        ;;
    menu)
        menu
        ;;
    *)
        echo "Uso: $0 {menu|all|backup <cliente>|restore <cliente> [archivo]|list <cliente>}"
        exit 1
        ;;
esac
