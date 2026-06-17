#!/bin/bash
# =============================================================================
# hosting_menu.sh — Menú de administración del Hosting
# SIS313 | USFX | Proyecto 13
# Ejecutar en: VM Hosting (192.168.100.152) como root o con sudo
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_BASE="/var/www/hosting"
LOG_BASE="/var/log/nginx/clients"
BACKUP_BASE="/var/backups/hosting"
REGISTRY="/var/lib/hosting/clients.tsv"
NGINX_GROUP="www-hosting"

check_root() {
    [[ $EUID -eq 0 ]] || { echo -e "${RED}Ejecutar como root: sudo bash $0${RESET}"; exit 1; }
}

banner() {
    clear
    echo -e "${BOLD}${BLUE}"
    echo "  ╔════════════════════════════════════════════════════╗"
    echo "  ║        HOSTING WEB COMPARTIDO — SIS313             ║"
    echo "  ║        VM Hosting · 192.168.100.152                ║"
    echo "  ╚════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    printf "  Host: ${CYAN}%s${RESET}  |  %s  |  %s\n" \
        "$(hostname)" "$(date '+%Y-%m-%d %H:%M')" "$(uptime -p)"
    echo ""
}

# ── Submenú: Clientes ─────────────────────────────────────────────────────────
menu_clientes() {
    while true; do
        banner
        echo -e "  ${BOLD}[ GESTIÓN DE CLIENTES ]${RESET}"
        echo "  ────────────────────────────────────────────"
        echo "  1) Crear nuevo cliente"
        echo "  2) Listar clientes registrados"
        echo "  3) Ver uso de disco y logs de un cliente"
        echo "  4) Suspender sitio (desactivar vhost)"
        echo "  5) Reactivar sitio"
        echo "  6) Eliminar cliente completamente"
        echo "  7) ← Volver"
        echo ""
        read -r -p "  Opción: " op

        case "$op" in
        1)
            echo ""
            read -r -p "  Nombre del cliente (ej: acmecorp): " client
            read -r -p "  Dominio completo (ej: acmecorp.hosting.local): " domain
            read -r -p "  Quota en MB [500]: " quota
            quota="${quota:-500}"
            bash "${SCRIPTS_DIR}/create_client.sh" "$client" "$domain" "$quota"
            read -r -p "  Enter para continuar..."
            ;;
        2)
            echo ""
            echo -e "  ${BOLD}Clientes registrados:${RESET}"
            echo "  ────────────────────────────────────────────────────────────────────────"
            printf "  %-18s %-35s %-8s %-20s %s\n" "CLIENTE" "DOMINIO" "QUOTA" "CREADO" "ESTADO"
            echo "  ────────────────────────────────────────────────────────────────────────"
            if [[ -f "$REGISTRY" ]]; then
                while IFS=$'\t' read -r c d q t s; do
                    printf "  %-18s %-35s %-8s %-20s %s\n" "$c" "$d" "$q" "$t" "$s"
                done < "$REGISTRY"
            else
                echo "  (sin clientes registrados aún)"
            fi
            echo ""
            read -r -p "  Enter para continuar..."
            ;;
        3)
            read -r -p "  Nombre del cliente: " client
            echo ""
            echo -e "  ${BOLD}── Estadísticas: ${CYAN}${client}${RESET}"
            echo -n "  public_html : "; du -sh "${WEB_BASE}/${client}/public_html" 2>/dev/null || echo "no existe"
            echo -n "  logs        : "; du -sh "${LOG_BASE}/${client}" 2>/dev/null || echo "no existe"
            echo -n "  tmp         : "; du -sh "${WEB_BASE}/${client}/tmp" 2>/dev/null || echo "no existe"
            echo ""
            echo -e "  ${BOLD}Últimas 10 visitas (access.log):${RESET}"
            tail -10 "${LOG_BASE}/${client}/access.log" 2>/dev/null || echo "  (sin registros)"
            echo ""
            echo -e "  ${BOLD}Últimos errores (error.log):${RESET}"
            tail -5 "${LOG_BASE}/${client}/error.log" 2>/dev/null || echo "  (sin errores)"
            echo ""
            if command -v quota &>/dev/null; then
                echo -e "  ${BOLD}Quota de disco:${RESET}"
                quota -u "web_${client}" 2>/dev/null || echo "  (quota no configurada)"
            fi
            echo ""
            read -r -p "  Enter para continuar..."
            ;;
        4)
            read -r -p "  Nombre del cliente a suspender: " client
            local domain
            domain=$(grep "^${client}	" "$REGISTRY" 2>/dev/null | cut -f2) || domain=""
            if [[ -n "$domain" ]] && [[ -L "/etc/nginx/sites-enabled/${domain}.conf" ]]; then
                rm "/etc/nginx/sites-enabled/${domain}.conf"
                nginx -s reload
                sed -i "s/^\(${client}	.*\)ACTIVO$/\1SUSPENDIDO/" "$REGISTRY" 2>/dev/null || true
                log_ok "Sitio de '$client' suspendido."
            else
                echo -e "  ${RED}No se encontró el vhost activo para '$client'.${RESET}"
            fi
            read -r -p "  Enter para continuar..."
            ;;
        5)
            read -r -p "  Nombre del cliente a reactivar: " client
            local domain
            domain=$(grep "^${client}	" "$REGISTRY" 2>/dev/null | cut -f2) || domain=""
            if [[ -n "$domain" ]] && [[ -f "/etc/nginx/sites-available/${domain}.conf" ]]; then
                ln -sf "/etc/nginx/sites-available/${domain}.conf" \
                       "/etc/nginx/sites-enabled/${domain}.conf"
                nginx -t && nginx -s reload
                sed -i "s/^\(${client}	.*\)SUSPENDIDO$/\1ACTIVO/" "$REGISTRY" 2>/dev/null || true
                echo -e "  ${GREEN}Sitio de '$client' reactivado.${RESET}"
            else
                echo -e "  ${RED}No se encontró la configuración de '$client'.${RESET}"
            fi
            read -r -p "  Enter para continuar..."
            ;;
        6)
            read -r -p "  Nombre del cliente a ELIMINAR: " client
            echo -e "  ${RED}ADVERTENCIA: esto elimina TODOS los datos de '$client'.${RESET}"
            read -r -p "  Escribe el nombre del cliente para confirmar: " confirm
            if [[ "$confirm" == "$client" ]]; then
                local domain
                domain=$(grep "^${client}	" "$REGISTRY" 2>/dev/null | cut -f2) || domain=""
                [[ -n "$domain" ]] && rm -f \
                    "/etc/nginx/sites-enabled/${domain}.conf" \
                    "/etc/nginx/sites-available/${domain}.conf"
                rm -rf "${WEB_BASE}/${client}" "${LOG_BASE}/${client}"
                rm -f "${LOGROTATE_DIR}/hosting-${client}" 2>/dev/null || true
                userdel "web_${client}" 2>/dev/null || true
                [[ -n "$domain" ]] && nginx -t && nginx -s reload || true
                sed -i "/^${client}	/d" "$REGISTRY" 2>/dev/null || true
                echo -e "  ${GREEN}Cliente '$client' eliminado.${RESET}"
            else
                echo -e "  ${YELLOW}Eliminación cancelada.${RESET}"
            fi
            read -r -p "  Enter para continuar..."
            ;;
        7) return ;;
        *) echo -e "  ${RED}Opción no válida.${RESET}"; sleep 1 ;;
        esac
    done
}

# ── Submenú: Servicios ────────────────────────────────────────────────────────
menu_servicios() {
    while true; do
        banner
        echo -e "  ${BOLD}[ SERVICIOS ]${RESET}"
        echo "  ─────────────────────────────────"
        echo "  1) Estado de NGINX"
        echo "  2) Verificar configuración NGINX"
        echo "  3) Recargar NGINX"
        echo "  4) Reiniciar NGINX"
        echo "  5) Sitios habilitados"
        echo "  6) ← Volver"
        echo ""
        read -r -p "  Opción: " op
        case "$op" in
        1) systemctl status nginx --no-pager | head -25; read -r -p "  Enter..." ;;
        2) nginx -t; read -r -p "  Enter..." ;;
        3) nginx -t && systemctl reload nginx && echo "NGINX recargado."; read -r -p "  Enter..." ;;
        4) systemctl restart nginx && echo "NGINX reiniciado."; read -r -p "  Enter..." ;;
        5) echo ""; ls -1 /etc/nginx/sites-enabled/ | sed 's/^/  /'; echo ""; read -r -p "  Enter..." ;;
        6) return ;;
        *) echo "Inválido."; sleep 1 ;;
        esac
    done
}

# ── Submenú: Logs ─────────────────────────────────────────────────────────────
menu_logs() {
    while true; do
        banner
        echo -e "  ${BOLD}[ LOGS ]${RESET}"
        echo "  ─────────────────────────────────"
        echo "  1) Ver accesos recientes de un cliente"
        echo "  2) Ver errores recientes de un cliente"
        echo "  3) Forzar rotación de un cliente"
        echo "  4) Forzar rotación de todos"
        echo "  5) Listar logs archivados de un cliente"
        echo "  6) ← Volver"
        echo ""
        read -r -p "  Opción: " op
        case "$op" in
        1) read -r -p "  Cliente: " c; echo ""; tail -30 "${LOG_BASE}/${c}/access.log" 2>/dev/null || echo "Sin logs."; read -r -p "  Enter..." ;;
        2) read -r -p "  Cliente: " c; echo ""; tail -30 "${LOG_BASE}/${c}/error.log" 2>/dev/null || echo "Sin errores."; read -r -p "  Enter..." ;;
        3) read -r -p "  Cliente: " c; logrotate -f "/etc/logrotate.d/hosting-${c}" && echo "Rotación forzada."; read -r -p "  Enter..." ;;
        4) logrotate -f /etc/logrotate.d/hosting-* 2>/dev/null && echo "Rotación forzada para todos."; read -r -p "  Enter..." ;;
        5) read -r -p "  Cliente: " c; echo ""; ls -lh "${LOG_BASE}/${c}/archive/" 2>/dev/null || echo "Sin archivos."; read -r -p "  Enter..." ;;
        6) return ;;
        *) echo "Inválido."; sleep 1 ;;
        esac
    done
}

# ── Submenú: Seguridad ────────────────────────────────────────────────────────
menu_seguridad() {
    while true; do
        banner
        echo -e "  ${BOLD}[ SEGURIDAD ]${RESET}"
        echo "  ─────────────────────────────────"
        echo "  1) Estado UFW"
        echo "  2) Reglas iptables OUTPUT (aislamiento)"
        echo "  3) Verificar permisos de directorios"
        echo "  4) Top IPs con más requests (últimos logs)"
        echo "  5) ← Volver"
        echo ""
        read -r -p "  Opción: " op
        case "$op" in
        1) ufw status verbose; read -r -p "  Enter..." ;;
        2) echo ""; iptables -L OUTPUT -n --line-numbers | head -30; read -r -p "  Enter..." ;;
        3)
            echo ""
            echo -e "  ${BOLD}Permisos en ${WEB_BASE}:${RESET}"
            find "$WEB_BASE" -maxdepth 3 -printf "  %M  %-15u %-15g  %p\n" 2>/dev/null
            echo ""
            read -r -p "  Enter..."
            ;;
        4)
            echo ""
            echo -e "  ${BOLD}Top 15 IPs (todos los clientes):${RESET}"
            find "${LOG_BASE}" -name "access.log" -exec cat {} + 2>/dev/null | \
                awk '{print $1}' | sort | uniq -c | sort -nr | head -15 | \
                awk '{printf "    %6s requests  %s\n", $1, $2}'
            echo ""
            read -r -p "  Enter..."
            ;;
        5) return ;;
        *) echo "Inválido."; sleep 1 ;;
        esac
    done
}

# ── Menú principal ────────────────────────────────────────────────────────────
main() {
    check_root
    while true; do
        banner
        echo -e "  ${BOLD}MENÚ PRINCIPAL${RESET}"
        echo "  ────────────────────────────────────────────"
        echo "  1) 👤  Gestión de Clientes"
        echo "  2) ⚙️   Servicios NGINX"
        echo "  3) 📋  Logs"
        echo "  4) 🔒  Seguridad"
        echo "  5) 📊  Resumen del sistema"
        echo "  6) 🚪  Salir"
        echo ""
        read -r -p "  Opción: " op
        case "$op" in
        1) menu_clientes ;;
        2) menu_servicios ;;
        3) menu_logs ;;
        4) menu_seguridad ;;
        5)
            banner
            echo -e "  ${BOLD}RESUMEN${RESET}"
            echo "  ────────────────────────────────────────────"
            echo -n "  Clientes activos  : "
            grep -c "ACTIVO" "$REGISTRY" 2>/dev/null || echo "0"
            echo -n "  Sitios en nginx   : "
            ls /etc/nginx/sites-enabled/ | grep -vc "^default" 2>/dev/null || echo "0"
            echo -n "  Uso /var/www      : "
            du -sh "$WEB_BASE" 2>/dev/null | cut -f1
            echo -n "  Uso /              : "
            df -h / | awk 'NR==2{print $5 " de " $2}'
            echo -n "  Memoria libre     : "
            free -h | awk '/^Mem/{print $7}'
            echo -n "  NGINX estado      : "
            systemctl is-active nginx
            echo ""
            echo -e "  ${BOLD}Clientes:${RESET}"
            [[ -f "$REGISTRY" ]] && column -t -s $'\t' "$REGISTRY" | sed 's/^/  /' || echo "  (ninguno)"
            echo ""
            read -r -p "  Enter para continuar..."
            ;;
        6) echo "Saliendo."; exit 0 ;;
        *) echo -e "  ${RED}Opción no válida.${RESET}"; sleep 1 ;;
        esac
    done
}

main
