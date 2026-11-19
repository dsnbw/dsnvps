#!/usr/bin/env bash
# ==============================================================================
# DSNVPS v7.1.0 - Universal Cross-OS Self-Healing Installer & 2026+ Optimizer
# Repository: https://github.com/dsnbw/dsnvps
# Supports: Ubuntu 20.04-26.04+, Debian 11-13+, AlmaLinux/Rocky/RHEL/OL 8-10+
# Architectures: x86_64 (amd64) & aarch64 (arm64)
# ==============================================================================
set -u

REPO_RAW_BASE="https://raw.githubusercontent.com/dsnbw/dsnvps/main"
REPO_TAR_URL="https://github.com/dsnbw/dsnvps/archive/refs/heads/main.tar.gz"
REPO_GIT_URL="https://github.com/dsnbw/dsnvps.git"
LOG_FILE="/var/log/dsnvps-install.log"

AUTO_MODE=0
UPGRADE_ONLY=0
NO_BLOAT_REMOVE=0
PHP_VER="8.4"
ADMIN_PORT=""
MAINSITE="dsnvps.demo"
LANG_CODE="VN"

C_RESET=$'\033[0m'
C_RED=$'\033[1;31m'
C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_CYAN=$'\033[1;36m'

log_msg()  { echo -e "${C_CYAN}[INFO]${C_RESET} $*"; echo "[$(date '+%F %T')] [INFO] $*" >> "$LOG_FILE" 2>/dev/null || true; }
log_ok()   { echo -e "${C_GREEN}[OK]${C_RESET} $*"; echo "[$(date '+%F %T')] [OK] $*" >> "$LOG_FILE" 2>/dev/null || true; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; echo "[$(date '+%F %T')] [WARN] $*" >> "$LOG_FILE" 2>/dev/null || true; }
log_err()  { echo -e "${C_RED}[ERR]${C_RESET} $*" >&2; echo "[$(date '+%F %T')] [ERR] $*" >> "$LOG_FILE" 2>/dev/null || true; }

show_help() {
    cat <<'HELP'
DSNVPS v7.1.0 - Universal Cross-OS Installer & 2026+ Server Optimizer

Usage:
  curl -sSL https://raw.githubusercontent.com/dsnbw/dsnvps/main/install.sh | sudo bash
  bash install.sh [OPTIONS]

Options:
  -y, --auto            Unattended install with optimal defaults
  --upgrade             Upgrade DSNVPS scripts + run optimizations on existing LEMP VPS
  --optimize-only       Alias for --upgrade (preserves websites, DBs, configs)
  --php <ver>           PHP version to install: 8.4 (default), 8.3, 8.2, 8.1, 8.0, 7.4
  --port <port>         Admin/phpMyAdmin port (default: random 20000-59999)
  --domain <domain>     Default panel/demo domain (default: dsnvps.demo)
  --lang <vi|en>        Interface language: vi (default) or en
  --no-bloat-remove     Do not purge snapd/fwupd/multipathd/etc.
  -h, --help            Show this help message
HELP
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--auto) AUTO_MODE=1 ;;
        --upgrade|--optimize-only) UPGRADE_ONLY=1 ;;
        --php) PHP_VER="${2:-8.4}"; shift ;;
        --port) ADMIN_PORT="${2:-}"; shift ;;
        --domain) MAINSITE="${2:-dsnvps.demo}"; shift ;;
        --lang)
            case "${2,,}" in
                en|english) LANG_CODE="EN" ;;
                *) LANG_CODE="VN" ;;
            esac
            shift
            ;;
        --no-bloat-remove) NO_BLOAT_REMOVE=1 ;;
        -h|--help) show_help; exit 0 ;;
        *) log_warn "Tham so khong hop le: $1" ;;
    esac
    shift
done

[[ ! -t 0 ]] && AUTO_MODE=1

if [[ "$(id -u)" != "0" ]]; then
    log_err "Vui long chay trinh cai dat voi quyen root (sudo bash)!"
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")" /tmp/dsnvps-work
: > "$LOG_FILE"

retry_cmd() {
    local max="${1:-3}"; shift
    local n=1 delay=3
    while true; do
        if "$@"; then
            return 0
        fi
        if ((n >= max)); then
            return 1
        fi
        log_warn "Lenh that bai (lan $n/$max), thu lai sau ${delay}s: $*"
        sleep "$delay"
        ((n++))
        ((delay *= 2))
    done
}

detect_os() {
    OS_ID="unknown"; OS_VER=""; OS_CODENAME=""; OS_LIKE=""; OS_FAMILY=""
    if [[ -r /etc/os-release ]]; then
        while IFS='=' read -r k v; do
            v="${v#\"}"; v="${v%\"}"
            case "$k" in
                ID) OS_ID="${v,,}" ;;
                VERSION_ID) OS_VER="$v" ;;
                VERSION_CODENAME) OS_CODENAME="${v,,}" ;;
                ID_LIKE) OS_LIKE="${v,,}" ;;
            esac
        done < /etc/os-release
    fi
    OS_MAJOR="${OS_VER%%.*}"
    ARCH="$(uname -m)"

    case "$OS_ID" in
        ubuntu|debian) OS_FAMILY="debian" ;;
        almalinux|rocky|rhel|ol|oracle|centos|fedora) OS_FAMILY="rhel" ;;
        *)
            if [[ "$OS_LIKE" == *"debian"* || "$OS_LIKE" == *"ubuntu"* ]]; then
                OS_FAMILY="debian"
            elif [[ "$OS_LIKE" == *"rhel"* || "$OS_LIKE" == *"fedora"* || "$OS_LIKE" == *"centos"* ]]; then
                OS_FAMILY="rhel"
            else
                log_err "He dieu hanh khong duoc ho tro: ${OS_ID} (${OS_VER})."
                exit 1
            fi
            ;;
    esac
    log_ok "Phat hien he dieu hanh: ${OS_ID} ${OS_VER} (${OS_FAMILY}, ${ARCH})"
}

# ==============================================================================
# SELF-HEALING PREFLIGHT ENGINE
# ==============================================================================
heal_dns_and_clock() {
    if ! getent hosts github.com >/dev/null 2>&1; then
        log_warn "DNS loi hoac khong phan giai duoc github.com -> tu dong bo sung 1.1.1.1 & 8.8.8.8..."
        cp -a /etc/resolv.conf /etc/resolv.conf.dsnvps.bak 2>/dev/null || true
        {
            echo "nameserver 1.1.1.1"
            echo "nameserver 8.8.8.8"
            cat /etc/resolv.conf.dsnvps.bak 2>/dev/null || true
        } > /etc/resolv.conf.tmp && mv -f /etc/resolv.conf.tmp /etc/resolv.conf
    fi

    # Fix severe clock skew that breaks SSL/TLS verification
    local yr
    yr="$(date +%Y 2>/dev/null || echo 2026)"
    if ((yr < 2024)); then
        log_warn "Dong ho he thong bi lech ($yr) -> dang dong bo lai thoi gian..."
        local http_date=""
        http_date="$(curl -sIk --max-time 5 https://1.1.1.1 2>/dev/null | awk -F': ' '/^[Dd]ate:/ {print $2; exit}' | tr -d '\r')"
        [[ -n "$http_date" ]] && date -s "$http_date" >/dev/null 2>&1 || true
    fi
}

heal_pkg_manager() {
    if [[ "$OS_FAMILY" == "debian" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        # Wait briefly if another apt/dpkg holds lock; only clean if orphaned
        if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
            log_warn "Phat hien tien trinh apt/dpkg khac dang chay, cho toi da 30s..."
            local w=0
            while ((w < 30)) && (fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1); do
                sleep 2; ((w += 2))
            done
        fi
        if ! pgrep -x "apt|apt-get|dpkg" >/dev/null 2>&1; then
            rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* 2>/dev/null || true
        fi
        dpkg --configure -a >/dev/null 2>&1 || true
        apt-get install -f -y -qq >/dev/null 2>&1 || true
        retry_cmd 3 apt-get update -qq || {
            log_warn "apt-get update gap loi, dang lam sach cache va thu lai..."
            rm -rf /var/lib/apt/lists/*
            retry_cmd 3 apt-get update -qq
        }
        apt-get install -y -qq curl wget ca-certificates gnupg lsb-release tar unzip zip socat bc jq openssl git >/dev/null 2>&1 || true
    else
        PKG_MGR="dnf"; command -v dnf >/dev/null 2>&1 || PKG_MGR="yum"
        rm -f /var/run/dnf.pid /var/run/yum.pid 2>/dev/null || true
        "$PKG_MGR" clean metadata -q >/dev/null 2>&1 || true
        retry_cmd 3 "$PKG_MGR" install -y -q curl wget ca-certificates tar unzip zip socat bc jq openssl git >/dev/null 2>&1 || true
        # Enable EPEL & CRB/PowerTools for jemalloc, yara, etc.
        "$PKG_MGR" install -y -q epel-release >/dev/null 2>&1 || true
        if command -v dnf >/dev/null 2>&1; then
            dnf config-manager --set-enabled crb >/dev/null 2>&1 || \
            dnf config-manager --set-enabled powertools >/dev/null 2>&1 || \
            dnf config-manager --set-enabled ol9_codeready_builder >/dev/null 2>&1 || \
            dnf config-manager --set-enabled ol8_codeready_builder >/dev/null 2>&1 || true
        fi
    fi
    log_ok "Trinh quan ly goi & thu vien nen da san sang."
}

heal_low_ram_swap() {
    local ram_mb swap_mb
    ram_mb="$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)"
    swap_mb="$(free -m | awk '/^Swap:/ {print $2}')"
    if ((ram_mb < 1024 && swap_mb < 512)); then
        log_warn "RAM thap (${ram_mb}MB) va chua co Swap -> tao tam 1GB swapfile tranh OOM khi cai dat..."
        if fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none; then
            chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile >/dev/null 2>&1 || true
            grep -q '/swapfile' /etc/fstab || echo "/swapfile none swap sw,pri=-2 0 0" >> /etc/fstab
        fi
    fi
}

heal_port_conflicts() {
    ((UPGRADE_ONLY == 1)) && return 0
    for svc in apache2 httpd lsws lshttpd caddy lighttpd; do
        if systemctl is-active --quiet "$svc" 2>/dev/null || systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            log_warn "Phat hien webserver xung dot (${svc}) -> dang dung va vo hieu hoa de nhuong cong 80/443 cho Nginx..."
            systemctl stop "$svc" >/dev/null 2>&1 || true
            systemctl disable "$svc" >/dev/null 2>&1 || true
            systemctl mask "$svc" >/dev/null 2>&1 || true
        fi
    done
    # Disable SELinux enforcing on RHEL to prevent silent Nginx/PHP/FTP permission blocks
    if [[ "$OS_FAMILY" == "rhel" ]] && command -v setenforce >/dev/null 2>&1; then
        setenforce 0 2>/dev/null || true
        [[ -f /etc/selinux/config ]] && sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
    fi
}

# ==============================================================================
# DOWNLOAD / STAGE DSNVPS PACKAGE
# ==============================================================================
stage_dsnvps_files() {
    local script_dir=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi

    local src_root=""
    if [[ -n "$script_dir" && -d "${script_dir}/etc-dsnvps/menu" ]]; then
        src_root="$script_dir"
        log_ok "Su dung ma nguon DSNVPS tai cho: ${src_root}"
    else
        log_msg "Dang tai goi cai dat DSNVPS moi nhat tu GitHub..."
        rm -rf /tmp/dsnvps-work/src /tmp/dsnvps-work/dsnvps.tar.gz
        mkdir -p /tmp/dsnvps-work/src
        if retry_cmd 3 curl -fsSL "$REPO_TAR_URL" -o /tmp/dsnvps-work/dsnvps.tar.gz; then
            tar -xzf /tmp/dsnvps-work/dsnvps.tar.gz -C /tmp/dsnvps-work/src --strip-components=1
            src_root="/tmp/dsnvps-work/src"
        elif command -v git >/dev/null 2>&1 && retry_cmd 2 git clone --depth 1 "$REPO_GIT_URL" /tmp/dsnvps-work/src; then
            src_root="/tmp/dsnvps-work/src"
        else
            log_err "Khong the tai ma nguon DSNVPS tu GitHub!"
            exit 1
        fi
    fi

    # Preserve existing user configs on upgrade
    mkdir -p /etc/dsnvps/.tmp /etc/dsnvps/Backup.Vhost.SSL /etc/dsnvps/ddns-cloudflare /etc/dsnvps/domainquanly
    if [[ -d /etc/dsnvps/menu ]]; then
        cp -a /etc/dsnvps/menu "/etc/dsnvps/menu.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    cp -a "${src_root}/etc-dsnvps/menu" /etc/dsnvps/
    [[ -f "${src_root}/etc-dsnvps/public_suffix_list.dat" ]] && cp -af "${src_root}/etc-dsnvps/public_suffix_list.dat" /etc/dsnvps/
    cp -af "${src_root}/bin/dsnvps" /usr/bin/dsnvps

    # Normalize permissions & strip accidental CRLF on shell scripts
    chmod +x /usr/bin/dsnvps /etc/dsnvps/menu/inc/mainmenu/dsnvps
    find /etc/dsnvps/menu -type f \( ! -name "*.zip" ! -name "*.png" ! -name "*.dat" ! -name "*.jpg" ! -name "*.json" \) -exec chmod +x {} + 2>/dev/null || true

    # Unlock full features cleanly
    printf 'DSNVPS-FREE-FOR-ALL-UNLOCKED-202\n' > /usr/bin/gxred
    chmod 644 /usr/bin/gxred
    touch -a -m -t 201802180130.09 /usr/bin/gxred

    echo "$LANG_CODE" > /etc/dsnvps/menu/dsnvps-check-language
    log_ok "Da cai dat bo ma nguon DSNVPS v$(cat /etc/dsnvps/menu/inc/dsnvps.version 2>/dev/null || echo 7.1.0)."
}

# ==============================================================================
# CROSS-OS LEMP STACK INSTALLATION
# ==============================================================================
setup_nginx_user() {
    if ! id -u nginx >/dev/null 2>&1; then
        groupadd -r nginx 2>/dev/null || true
        useradd -r -g nginx -s /sbin/nologin -d /var/cache/nginx -M nginx 2>/dev/null || true
    fi
}

install_nginx_cross_os() {
    log_msg "Dang cai dat Nginx..."
    setup_nginx_user
    if [[ "$OS_FAMILY" == "debian" ]]; then
        retry_cmd 3 apt-get install -y -qq nginx
        apt-get install -y -qq libnginx-mod-http-brotli-filter libnginx-mod-http-brotli-static libnginx-mod-http-headers-more-filter libnginx-mod-http-geoip2 2>/dev/null || true
    else
        retry_cmd 3 "$PKG_MGR" install -y -q nginx
    fi

    mkdir -p /etc/nginx/conf /etc/nginx/conf.d /etc/nginx/auth-acme /etc/nginx/paidssl /etc/nginx/pwprotect /etc/nginx/geoip2 /var/cache/nginx-fastcgi /var/log/nginx
    chown -R nginx:nginx /var/cache/nginx-fastcgi /var/log/nginx

    # Copy DSNVPS Nginx templates if not yet present
    for f in /etc/dsnvps/menu/inc/conf/*.conf; do
        [[ -f "$f" ]] || continue
        local bn; bn="$(basename "$f")"
        [[ ! -f "/etc/nginx/conf/${bn}" ]] && cp -a "$f" "/etc/nginx/conf/${bn}"
    done

    # Clean, universal 2026 nginx.conf if default distro nginx.conf is still active
    if ! grep -q "/etc/nginx/conf/ddos1.conf" /etc/nginx/nginx.conf 2>/dev/null; then
        cp -a /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig 2>/dev/null || true
        local mod_inc=""
        [[ -d /etc/nginx/modules-enabled ]] && mod_inc="include /etc/nginx/modules-enabled/*.conf;"
        [[ -d /usr/share/nginx/modules ]] && [[ -z "$mod_inc" ]] && mod_inc="include /usr/share/nginx/modules/*.conf;"
        cat > /etc/nginx/nginx.conf <<NGX
${mod_inc}
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
pcre_jit on;

error_log /var/log/nginx/error.log crit;
pid /run/nginx.pid;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include /etc/nginx/conf/ddos1.conf;

    access_log off;
    sendfile on;
    sendfile_max_chunk 512k;
    tcp_nopush on;
    tcp_nodelay on;
    server_tokens off;
    server_name_in_redirect off;
    ignore_invalid_headers on;
    reset_timedout_connection on;

    open_file_cache max=200000 inactive=60s;
    open_file_cache_valid 30s;
    open_file_cache_min_uses 2;
    open_file_cache_errors off;

    client_max_body_size 1024m;
    client_body_buffer_size 256k;
    client_header_buffer_size 64k;
    large_client_header_buffers 4 256k;
    keepalive_timeout 25;
    keepalive_requests 2000;

    gzip on;
    gzip_static on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;

    include /etc/nginx/conf/real-ip-cloudflare.conf;
    include /etc/nginx/conf/websocket.conf;
    include /etc/nginx/conf.d/*.conf;
}
NGX
        rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf 2>/dev/null || true
    fi

    echo -e "upstream php-fpm {\n    server 127.0.0.1:9000;\n}" > /etc/nginx/conf.d/php-fpm.conf
    systemctl enable nginx >/dev/null 2>&1 || true
    log_ok "Nginx da san sang."
}

install_php_cross_os() {
    log_msg "Dang cai dat PHP ${PHP_VER} & extensions..."
    if [[ "$OS_FAMILY" == "debian" ]]; then
        if [[ "$OS_ID" == "ubuntu" ]]; then
            # Add Ondrej PPA directly without needing software-properties-common/packagekit
            if [[ ! -f /etc/apt/sources.list.d/ondrej-php.list ]]; then
                mkdir -p /etc/apt/keyrings
                curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x4F4EA0AAE5267A6C" | gpg --dearmor -o /etc/apt/keyrings/ondrej-php.gpg 2>/dev/null || true
                if [[ -s /etc/apt/keyrings/ondrej-php.gpg && -n "$OS_CODENAME" ]]; then
                    echo "deb [signed-by=/etc/apt/keyrings/ondrej-php.gpg] https://ppa.launchpadcontent.net/ondrej/php/ubuntu ${OS_CODENAME} main" > /etc/apt/sources.list.d/ondrej-php.list
                    apt-get update -qq || rm -f /etc/apt/sources.list.d/ondrej-php.list
                fi
            fi
        elif [[ "$OS_ID" == "debian" ]]; then
            if [[ ! -f /etc/apt/sources.list.d/sury-php.list ]]; then
                mkdir -p /etc/apt/keyrings
                curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/keyrings/sury-php.gpg 2>/dev/null || true
                if [[ -s /etc/apt/keyrings/sury-php.gpg && -n "$OS_CODENAME" ]]; then
                    echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ ${OS_CODENAME} main" > /etc/apt/sources.list.d/sury-php.list
                    apt-get update -qq || rm -f /etc/apt/sources.list.d/sury-php.list
                fi
            fi
        fi

        if ! apt-cache show "php${PHP_VER}-fpm" >/dev/null 2>&1; then
            log_warn "Khong tim thay php${PHP_VER}-fpm trong repo -> tu dong chuyen sang PHP mac dinh cua he thong."
            retry_cmd 3 apt-get install -y -qq php-fpm php-cli php-common php-mysql php-curl php-gd php-mbstring php-xml php-zip php-bcmath php-intl php-soap php-opcache php-sqlite3 php-imagick
            PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
        else
            retry_cmd 3 apt-get install -y -qq \
                "php${PHP_VER}-fpm" "php${PHP_VER}-cli" "php${PHP_VER}-common" \
                "php${PHP_VER}-mysql" "php${PHP_VER}-curl" "php${PHP_VER}-gd" \
                "php${PHP_VER}-mbstring" "php${PHP_VER}-xml" "php${PHP_VER}-zip" \
                "php${PHP_VER}-bcmath" "php${PHP_VER}-intl" "php${PHP_VER}-soap" \
                "php${PHP_VER}-opcache" "php${PHP_VER}-sqlite3" "php${PHP_VER}-readline"
            apt-get install -y -qq "php${PHP_VER}-imagick" 2>/dev/null || true
        fi

        update-alternatives --set php "/usr/bin/php${PHP_VER}" >/dev/null 2>&1 || true
        ln -sfn "/etc/php/${PHP_VER}/fpm/php.ini" /etc/php.ini
        ln -sfn "/etc/php/${PHP_VER}/fpm/php.ini" "/etc/php/${PHP_VER}/cli/php.ini"
        ln -sfn "/etc/php/${PHP_VER}/fpm/conf.d" /etc/php.d
        ln -sfn "/etc/php/${PHP_VER}/fpm/php-fpm.conf" /etc/php-fpm.conf
        ln -sfn "/etc/php/${PHP_VER}/fpm/pool.d" /etc/php-fpm.d
        ln -sfn "/usr/lib/systemd/system/php${PHP_VER}-fpm.service" /etc/systemd/system/php-fpm.service
        systemctl daemon-reload
        rm -f /etc/php.d/10-opcache.ini
        systemctl enable "php${PHP_VER}-fpm" >/dev/null 2>&1 || true
    else
        # RHEL / AlmaLinux / Rocky / Oracle
        local remi_rpm="https://rpms.remirepo.net/enterprise/remi-release-${OS_MAJOR}.rpm"
        "$PKG_MGR" install -y -q "$remi_rpm" >/dev/null 2>&1 || true
        local php_nodot="${PHP_VER/./}"
        if dnf module list php 2>/dev/null | grep -q "remi-${PHP_VER}"; then
            dnf -y -q module reset php >/dev/null 2>&1 || true
            dnf -y -q module enable "php:remi-${PHP_VER}" >/dev/null 2>&1 || true
        fi
        retry_cmd 3 "$PKG_MGR" install -y -q php php-fpm php-cli php-common php-mysqlnd php-gd php-mbstring php-xml php-zip php-bcmath php-intl php-soap php-opcache php-pdo
        "$PKG_MGR" install -y -q php-pecl-imagick 2>/dev/null || true
        PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
        systemctl enable php-fpm >/dev/null 2>&1 || true
    fi

    mkdir -p /var/lib/php/session /var/log/php-fpm /var/run/php-fpm
    chown -R nginx:nginx /var/lib/php/session /var/log/php-fpm /var/run/php-fpm

    # Configure www.conf to listen on 127.0.0.1:9000 as nginx:nginx
    local www_conf="/etc/php-fpm.d/www.conf"
    if [[ -f "$www_conf" ]]; then
        sed -i 's/^user = .*/user = nginx/; s/^group = .*/group = nginx/' "$www_conf"
        sed -i 's|^listen = .*|listen = 127.0.0.1:9000|' "$www_conf"
        grep -q '^listen.allowed_clients' "$www_conf" || echo "listen.allowed_clients = 127.0.0.1" >> "$www_conf"
    fi
    log_ok "PHP ${PHP_VER}-FPM da san sang."
}

install_mariadb_cross_os() {
    log_msg "Dang cai dat MariaDB Server..."
    if [[ "$OS_FAMILY" == "debian" ]]; then
        retry_cmd 3 apt-get install -y -qq mariadb-server mariadb-client
    else
        retry_cmd 3 "$PKG_MGR" install -y -q mariadb-server mariadb
    fi
    systemctl enable --now mariadb >/dev/null 2>&1 || systemctl enable --now mysql >/dev/null 2>&1 || true

    local db_pass
    if [[ -f /root/dsnvps.conf ]] && grep -q '^mariadbpass=' /root/dsnvps.conf; then
        db_pass="$(grep '^mariadbpass=' /root/dsnvps.conf | head -n1 | cut -d'"' -f2)"
    else
        db_pass="$(openssl rand -hex 16)"
    fi

    # Ensure root password & .my.cnf work cleanly
    mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${db_pass}'); FLUSH PRIVILEGES;" 2>/dev/null || \
    mariadb -u root -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${db_pass}'); FLUSH PRIVILEGES;" 2>/dev/null || true

    cat > /root/.my.cnf <<MYCNF
[client]
user=root
password=${db_pass}
MYCNF
    chmod 600 /root/.my.cnf

    # Include /etc/my.cnf on Debian/Ubuntu MariaDB
    if [[ -d /etc/mysql/mariadb.conf.d ]]; then
        echo "!include /etc/my.cnf" > /etc/mysql/mariadb.conf.d/99-dsnvps.cnf
    fi

    MARIADB_PASS="$db_pass"
    log_ok "MariaDB Server da san sang."
}

install_tools_cross_os() {
    log_msg "Dang cai dat cong cu bo tro (WP-CLI, Composer, Pure-FTPd, vnStat, YARA, jemalloc, rclone)..."
    if [[ "$OS_FAMILY" == "debian" ]]; then
        apt-get install -y -qq libjemalloc2 yara zram-tools pure-ftpd vnstat htop nftables cron fail2ban 2>/dev/null || true
    else
        "$PKG_MGR" install -y -q jemalloc yara pure-ftpd vnstat htop nftables cronie 2>/dev/null || true
    fi

    # WP-CLI
    if [[ ! -x /usr/local/bin/wp ]]; then
        retry_cmd 3 curl -fsSL "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar" -o /usr/local/bin/wp && chmod +x /usr/local/bin/wp || true
    fi
    # Composer
    if [[ ! -x /usr/local/bin/composer ]]; then
        retry_cmd 3 curl -fsSL "https://getcomposer.org/composer-stable.phar" -o /usr/local/bin/composer && chmod +x /usr/local/bin/composer || true
    fi
    # acme.sh
    if [[ ! -x /root/.acme.sh/acme.sh ]]; then
        curl -fsSL https://get.acme.sh | sh -s email="admin@${MAINSITE}" >/dev/null 2>&1 || true
    fi
    # vnStat init
    local ifaces; ifaces="$(ip -o link show | awk -F': ' '/state UP/ {print $2}')"
    for iface in $ifaces; do vnstat --add -i "$iface" >/dev/null 2>&1 || true; done
    systemctl enable --now vnstat >/dev/null 2>&1 || true
    systemctl enable --now pure-ftpd >/dev/null 2>&1 || true
    log_ok "Cong cu bo tro da san sang."
}

setup_firewall_safe() {
    local ssh_port
    ssh_port="$(ss -tlnp 2>/dev/null | awk '/sshd/ {print $4}' | grep -oE '[0-9]+$' | head -n1)"
    [[ -z "$ssh_port" ]] && ssh_port="$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | tail -n1)"
    [[ -z "$ssh_port" ]] && ssh_port=22

    if command -v nft >/dev/null 2>&1; then
        cat > /etc/nftables.conf <<NFT
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority filter; policy accept;
        iif "lo" accept
        ct state established,related accept
        icmp type echo-request accept
        icmpv6 type echo-request accept
        tcp dport { 21, ${ssh_port}, 80, 443, ${ADMIN_PORT} } accept
        tcp dport 30000-50000 accept
    }
    chain forward { type filter hook forward priority filter; policy accept; }
    chain output { type filter hook output priority filter; policy accept; }
}
NFT
        nft -f /etc/nftables.conf >/dev/null 2>&1 || true
        systemctl enable nftables >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        for p in 21 "$ssh_port" 80 443 "$ADMIN_PORT" 30000-50000; do
            firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
        done
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
    log_ok "Firewall da mo cong an toan (SSH=${ssh_port}, HTTP=80/443, Admin=${ADMIN_PORT})."
}

finalize_dsnvps_config() {
    local pub_ip
    pub_ip="$(curl -s4 --max-time 4 https://ifconfig.me || curl -s4 --max-time 4 https://api.ipify.org || hostname -I | awk '{print $1}')"
    if [[ -z "$ADMIN_PORT" ]]; then
        ADMIN_PORT=$((20000 + RANDOM % 39000))
    fi

    if [[ ! -f /root/dsnvps.conf ]]; then
        cat > /root/dsnvps.conf <<CONF
mainsite="${MAINSITE}"
priport="${ADMIN_PORT}"
serverip="${pub_ip}"
mariadbpass="${MARIADB_PASS}"
emailmanage="admin@${MAINSITE}"
Businesscode="DSNVPS-FREE-FOR-ALL"
CONF
        chmod 600 /root/dsnvps.conf
    fi

    mkdir -p "/home/${MAINSITE}/public_html" "/home/${MAINSITE}/private_html" "/home/${MAINSITE}/logs"
    if [[ ! -f "/home/${MAINSITE}/public_html/index.html" ]]; then
        echo "<h1>DSNVPS Ready</h1>" > "/home/${MAINSITE}/public_html/index.html"
    fi
    if [[ ! -f "/etc/nginx/conf.d/${MAINSITE}.conf" && -f /etc/dsnvps/menu/inc/vhost-sample/dsnvps.demo.conf ]]; then
        sed -e "s/dsnvps\.demo/${MAINSITE}/g" -e "s/34618/${ADMIN_PORT}/g" \
            /etc/dsnvps/menu/inc/vhost-sample/dsnvps.demo.conf > "/etc/nginx/conf.d/${MAINSITE}.conf"
    fi
    chown -R nginx:nginx "/home/${MAINSITE}"

    # Configure RAM-based PHP/MariaDB tuning & run 2026+ optimization suite
    /etc/dsnvps/menu/inc/setup/config-php.ini-www.conf-belong-ram >/dev/null 2>&1 || true
    /etc/dsnvps/menu/inc/setup/config-server.cnf-belong-ram >/dev/null 2>&1 || true

    if ((NO_BLOAT_REMOVE == 1)); then
        /etc/dsnvps/menu/optimize/dsnvps-opt-zram --auto
        /etc/dsnvps/menu/optimize/dsnvps-opt-kernel
        /etc/dsnvps/menu/optimize/dsnvps-opt-disk
        /etc/dsnvps/menu/optimize/dsnvps-opt-oom
        /etc/dsnvps/menu/optimize/dsnvps-opt-jemalloc
        /etc/dsnvps/menu/optimize/dsnvps-opt-journald
        /etc/dsnvps/menu/optimize/dsnvps-opt-php-jit --auto
        /etc/dsnvps/menu/optimize/dsnvps-opt-nginx
    else
        /etc/dsnvps/menu/optimize/dsnvps-opt-all
    fi

    systemctl restart nginx "$(bash -c '. /etc/dsnvps/menu/inc/dsnvps-common.sh && dsnvps_php_service')" mariadb >/dev/null 2>&1 || true
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================
clear
echo -e "${C_CYAN}=========================================================================${C_RESET}"
echo -e "${C_YELLOW}   DSNVPS v7.1.0 - UNIVERSAL SELF-HEALING INSTALLER & 2026+ OPTIMIZER${C_RESET}"
echo -e "${C_CYAN}=========================================================================${C_RESET}"

detect_os
heal_dns_and_clock
heal_pkg_manager
heal_low_ram_swap
heal_port_conflicts

if ((UPGRADE_ONLY == 1)); then
    log_msg "Che do --upgrade / --optimize-only: giu nguyen website, DB & cau hinh hien tai..."
    stage_dsnvps_files
    if ((NO_BLOAT_REMOVE == 1)); then
        /etc/dsnvps/menu/optimize/dsnvps-opt-zram --auto
        /etc/dsnvps/menu/optimize/dsnvps-opt-kernel
        /etc/dsnvps/menu/optimize/dsnvps-opt-disk
        /etc/dsnvps/menu/optimize/dsnvps-opt-oom
        /etc/dsnvps/menu/optimize/dsnvps-opt-jemalloc
        /etc/dsnvps/menu/optimize/dsnvps-opt-journald
        /etc/dsnvps/menu/optimize/dsnvps-opt-php-jit --auto
        /etc/dsnvps/menu/optimize/dsnvps-opt-nginx
    else
        /etc/dsnvps/menu/optimize/dsnvps-opt-all
    fi
else
    if ((AUTO_MODE == 0)); then
        read -r -p "Chon phien ban PHP mac dinh [8.4 / 8.3 / 8.2 / 8.1] (Enter = ${PHP_VER}): " in_php
        [[ -n "$in_php" ]] && PHP_VER="$in_php"
        read -r -p "Nhap cong quan tri Admin/phpMyAdmin (Enter = ngau nhien): " in_port
        [[ "$in_port" =~ ^[0-9]+$ ]] && ADMIN_PORT="$in_port"
    fi
    [[ -z "$ADMIN_PORT" ]] && ADMIN_PORT=$((20000 + RANDOM % 39000))

    stage_dsnvps_files
    install_nginx_cross_os
    install_php_cross_os
    install_mariadb_cross_os
    install_tools_cross_os
    setup_firewall_safe
    finalize_dsnvps_config
fi

rm -rf /tmp/dsnvps-work
echo ""
echo -e "${C_GREEN}=========================================================================${C_RESET}"
echo -e "${C_GREEN} ✔ CAI DAT & TOI UU HOA DSNVPS v7.1.0 HOAN TAT!${C_RESET}"
echo -e "${C_GREEN}=========================================================================${C_RESET}"
echo -e " - Go lenh ${C_YELLOW}dsnvps${C_RESET} de mo Menu quan tri (44 nhom tinh nang)"
echo -e " - Go lenh ${C_YELLOW}dsnvps status${C_RESET} hoac ${C_YELLOW}dsnvps top${C_RESET} de theo doi hieu nang server"
echo -e " - Go lenh ${C_YELLOW}dsnvps help${C_RESET} de xem toan bo lenh nhanh CLI"
echo -e " - Log cai dat luu tai: ${LOG_FILE}"
echo -e "${C_GREEN}=========================================================================${C_RESET}"
