#!/bin/bash
# DSNVPS Common Helper Library (Ubuntu/Debian & RHEL compatible)

[[ -f /root/dsnvps.conf ]] && . /root/dsnvps.conf 2>/dev/null || true

C_RESET=$'\033[0m'
C_RED=$'\033[1;31m'
C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_CYAN=$'\033[1;36m'
C_WHITE=$'\033[1;37m'
C_DIM=$'\033[2m'

dsnvps_os_family() {
    if grep -qiE "ubuntu|debian" /etc/os-release 2>/dev/null; then
        echo "debian"
    else
        echo "rhel"
    fi
}

dsnvps_ram_mb() {
    awk '/MemTotal/ {printf "%.0f", $2 / 1024}' /proc/meminfo
}

dsnvps_cpu_cores() {
    nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1
}

dsnvps_php_ver() {
    php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.4"
}

dsnvps_php_ini() {
    local ver
    ver="$(dsnvps_php_ver)"
    if [[ -f "/etc/php/${ver}/fpm/php.ini" ]]; then
        echo "/etc/php/${ver}/fpm/php.ini"
    elif [[ -f /etc/php.ini ]]; then
        readlink -f /etc/php.ini 2>/dev/null || echo "/etc/php.ini"
    else
        echo "/etc/php.ini"
    fi
}

dsnvps_php_confd() {
    local ver
    ver="$(dsnvps_php_ver)"
    if [[ -d "/etc/php/${ver}/fpm/conf.d" ]]; then
        echo "/etc/php/${ver}/fpm/conf.d"
    elif [[ -d /etc/php.d ]]; then
        readlink -f /etc/php.d 2>/dev/null || echo "/etc/php.d"
    else
        echo "/etc/php.d"
    fi
}

dsnvps_php_service() {
    local ver
    ver="$(dsnvps_php_ver)"
    if systemctl list-unit-files "php${ver}-fpm.service" >/dev/null 2>&1 && systemctl status "php${ver}-fpm.service" >/dev/null 2>&1; then
        echo "php${ver}-fpm"
    elif systemctl list-unit-files php-fpm.service >/dev/null 2>&1; then
        echo "php-fpm"
    else
        echo "php${ver}-fpm"
    fi
}

dsnvps_redis_service() {
    if systemctl list-unit-files valkey-server.service 2>/dev/null | grep -q valkey; then
        echo "valkey-server"
    elif systemctl list-unit-files redis-server.service 2>/dev/null | grep -q redis-server; then
        echo "redis-server"
    else
        echo "redis"
    fi
}

dsnvps_cron_service() {
    if systemctl list-unit-files cron.service 2>/dev/null | grep -q '^cron\.service'; then
        echo "cron"
    else
        echo "crond"
    fi
}

dsnvps_list_domains() {
    local f d
    for f in /etc/nginx/conf.d/*.conf; do
        [[ -f "$f" ]] || continue
        d="${f##*/}"
        d="${d%.conf}"
        [[ "$d" == "php-fpm" || "$d" == "dsnvps.demo" || "$d" == "${mainsite:-dsnvps.demo}" ]] && continue
        [[ -d "/home/$d/public_html" ]] && echo "$d"
    done | sort -u
}

dsnvps_list_wp_domains() {
    local d
    for d in $(dsnvps_list_domains); do
        [[ -f "/home/$d/public_html/wp-config.php" ]] && echo "$d"
    done
}

dsnvps_pick_domain() {
    local mode="${1:-all}" # all | wp
    local domains=()
    local d
    if [[ "$mode" == "wp" ]]; then
        while IFS= read -r d; do [[ -n "$d" ]] && domains+=("$d"); done < <(dsnvps_list_wp_domains)
    else
        while IFS= read -r d; do [[ -n "$d" ]] && domains+=("$d"); done < <(dsnvps_list_domains)
    fi
    if [[ ${#domains[@]} -eq 0 ]]; then
        echo -e "${C_RED}[!] Không tìm thấy website nào phù hợp trong /home/ (ngoài ${mainsite:-dsnvps.demo}).${C_RESET}" >&2
        return 1
    fi
    echo -e "${C_CYAN}Danh sách website hiện có:${C_RESET}" >&2
    local i=1
    for d in "${domains[@]}"; do
        printf "  %2d) %s\n" "$i" "$d" >&2
        ((i++))
    done
    echo "   0) Quay lại" >&2
    local pick
    read -r -p "Chọn số website [0-${#domains[@]}]: " pick
    [[ "$pick" == "0" || -z "$pick" ]] && return 1
    if [[ "$pick" =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#domains[@]})); then
        echo "${domains[$((pick-1))]}"
        return 0
    fi
    echo -e "${C_RED}Lựa chọn không hợp lệ!${C_RESET}" >&2
    return 1
}

dsnvps_wp() {
    local domain="$1"
    shift
    local wp_path="/home/${domain}/public_html"
    if [[ ! -f "${wp_path}/wp-config.php" ]]; then
        echo -e "${C_RED}[!] Không tìm thấy wp-config.php tại ${wp_path}${C_RESET}" >&2
        return 1
    fi
    sudo -u nginx -- /usr/local/bin/wp --path="$wp_path" "$@" 2>/dev/null || /usr/local/bin/wp --allow-root --path="$wp_path" "$@"
}

dsnvps_pkg_install() {
    if [[ "$(dsnvps_os_family)" == "debian" ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
    else
        dnf install -y -q "$@" 2>/dev/null || yum install -y -q "$@"
    fi
}

dsnvps_pad_col() {
    local text="$1"
    local width="${2:-35}"
    local plain disp_len pad
    plain="$(printf '%b' "$text" | sed -r 's/\x1B\[[0-9;]*[mK]//g')"
    disp_len="$(printf '%s' "$plain" | wc -L)"
    pad=$(( width - disp_len ))
    ((pad < 0)) && pad=0
    printf '%b%*s' "$text" "$pad" ""
}

dsnvps_menu_top() {
    echo -e " ${C_CYAN}╭───────────────────────────────────────────────────────────────────────────╮${C_RESET}"
}

dsnvps_menu_sep() {
    echo -e " ${C_CYAN}├─────────────────────────────────────┬─────────────────────────────────────┤${C_RESET}"
}

dsnvps_menu_full_sep() {
    echo -e " ${C_CYAN}├─────────────────────────────────────┴─────────────────────────────────────┤${C_RESET}"
}

dsnvps_menu_bot() {
    echo -e " ${C_CYAN}╰─────────────────────────────────────┴─────────────────────────────────────╯${C_RESET}"
}

dsnvps_menu_section() {
    local title="$1"
    printf " ${C_CYAN}│${C_RESET} %s ${C_CYAN}│${C_RESET}\n" "$(dsnvps_pad_col "${C_YELLOW}▸ ${title}${C_RESET}" 73)"
}

dsnvps_menu_row() {
    local left="$1"
    local right="$2"
    printf " ${C_CYAN}│${C_RESET} %s ${C_CYAN}│${C_RESET} %s ${C_CYAN}│${C_RESET}\n" \
        "$(dsnvps_pad_col "$left" 35)" \
        "$(dsnvps_pad_col "$right" 35)"
}
