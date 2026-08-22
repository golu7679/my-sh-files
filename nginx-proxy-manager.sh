#!/bin/bash

# Ensure the script is run with bash
if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

########################################################
# Proxy Manager V2
# Author: Golu Rajak
# Version: 1.0
########################################################

set -e

NGINX_AVAILABLE="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"

BASE_DIR="/opt/proxy-manager"
BACKUP_DIR="$BASE_DIR/backups"


GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

###########################################
# UI
###########################################

success() {
    printf "${GREEN}%s${NC}\n" "$1"
}

error() {
    printf "${RED}%s${NC}\n" "$1"
}

warning() {
    printf "${YELLOW}%s${NC}\n" "$1"
}

info() {
    printf "${BLUE}%s${NC}\n" "$1"
}

pause() {
    read -p "Press Enter to continue..."
}

###########################################
# REQUIREMENTS
###########################################

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Please run with sudo."
        exit 1
    fi
}

install_dependencies() {

    if ! command -v nginx >/dev/null; then
        info "Installing nginx..."
        apt update
        apt install -y nginx
    fi

    if ! command -v curl >/dev/null; then
        apt install -y curl
    fi

    if ! command -v dig >/dev/null; then
        apt install -y dnsutils
    fi

    if ! command -v openssl >/dev/null; then
        apt install -y openssl
    fi
}

###########################################
# NGINX
###########################################

reload_nginx() {

    if nginx -t; then
        systemctl reload nginx
        success "Nginx reloaded."
    else
        error "Nginx config validation failed."
    fi
}

nginx_status() {
    systemctl status nginx --no-pager
}

###########################################
# HELPERS
###########################################

proxy_exists() {

    local DOMAIN="$1"

    [[ -f "$NGINX_AVAILABLE/$DOMAIN" ]]
}

get_proxy_port() {

    local DOMAIN="$1"

    grep proxy_pass "$NGINX_AVAILABLE/$DOMAIN" \
        | grep -oE '[0-9]+' \
        | tail -1
}

get_ssl_expiry() {

    local DOMAIN="$1"
    local CERT_FILE="/etc/letsencrypt/live/$DOMAIN/cert.pem"

    if [[ -f "$CERT_FILE" ]] && command -v openssl >/dev/null; then
        local END_DATE
        END_DATE=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
        if [[ -n "$END_DATE" ]]; then
            date -d "$END_DATE" "+%Y-%m-%d" 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$END_DATE" "+%Y-%m-%d" 2>/dev/null || echo "$END_DATE"
        else
            echo "N/A"
        fi
    else
        echo "N/A"
    fi
}

clean_domain() {

    local INPUT="$1"

    echo "$INPUT" | sed -e 's|^https*://||' -e 's|/.*||' -e 's|::.*||' | tr '[:upper:]' '[:lower:]'
}

validate_port() {

    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

###########################################
# ADD PROXY
###########################################

add_proxy() {

    clear

    echo "Create Reverse Proxy"
    echo

    read -p "Domain: " DOMAIN
    DOMAIN=$(clean_domain "$DOMAIN")
    read -p "Application Port: " PORT

    if [[ -z "$DOMAIN" || -z "$PORT" ]]; then
        error "Domain and port required."
        return
    fi

    if ! validate_port "$PORT"; then
        error "Invalid port number (must be between 1 and 65535)."
        return
    fi

    if proxy_exists "$DOMAIN"; then
        error "Domain already exists."
        return
    fi

    cat > "$NGINX_AVAILABLE/$DOMAIN" <<EOF
server {

    listen 80;
    server_name $DOMAIN;

    location / {

        proxy_pass http://127.0.0.1:$PORT;

        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

    ln -sf \
        "$NGINX_AVAILABLE/$DOMAIN" \
        "$NGINX_ENABLED/$DOMAIN"

    reload_nginx

    success "Proxy created."
    success "$DOMAIN -> localhost:$PORT"
}


###########################################
# ADD STATIC WEBSITE
###########################################

add_static_website() {

    clear

    echo "Deploy Static Website"
    echo

    read -p "Domain: " DOMAIN
    DOMAIN=$(clean_domain "$DOMAIN")
    read -p "Website Path: " WEBSITE_PATH

    if [[ -z "$DOMAIN" || -z "$WEBSITE_PATH" ]]; then
        error "Domain and website path are required."
        return
    fi

    if [[ ! -d "$WEBSITE_PATH" ]]; then
        error "Directory does not exist."
        return
    fi

    if [[ ! -f "$WEBSITE_PATH/index.html" ]]; then
        warning "index.html not found."
        read -p "Continue anyway? (y/n): " CONFIRM

        [[ "$CONFIRM" != "y" ]] && return
    fi

    cat > "$NGINX_AVAILABLE/$DOMAIN" <<EOF
server {

    listen 80;
    server_name $DOMAIN;

    root $WEBSITE_PATH;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log /var/log/nginx/${DOMAIN}.error.log;
}
EOF

    ln -sf \
        "$NGINX_AVAILABLE/$DOMAIN" \
        "$NGINX_ENABLED/$DOMAIN"

    reload_nginx

    success "Static website deployed."
    success "$DOMAIN -> $WEBSITE_PATH"

    echo

    read -p "Enable SSL now? (y/n): " SSL

    if [[ "$SSL" == "y" ]]; then

        if ! command -v certbot >/dev/null; then

            apt update

            apt install -y \
                certbot \
                python3-certbot-nginx
        fi

        certbot \
            --nginx \
            -d "$DOMAIN"
    fi
}

###########################################
# DELETE PROXY
###########################################

delete_proxy() {

    clear

    list_proxies

    echo

    read -p "Domain to delete: " DOMAIN
    DOMAIN=$(clean_domain "$DOMAIN")

    if ! proxy_exists "$DOMAIN"; then
        error "Proxy not found."
        return
    fi

    echo
    warning "This will remove proxy:"
    echo "$DOMAIN"
    echo

    read -p "Continue? (y/n): " CONFIRM

    [[ "$CONFIRM" != "y" ]] && return

    rm -f "$NGINX_ENABLED/$DOMAIN"
    rm -f "$NGINX_AVAILABLE/$DOMAIN"

    reload_nginx

    success "Proxy deleted."
}

###########################################
# LIST PROXIES
###########################################

list_proxies() {

    clear

    printf "\n"

    printf "%-35s %-10s %-10s %-15s\n" \
        "DOMAIN" \
        "STATUS" \
        "PORT" \
        "SSL EXPIRY"

    printf "%-35s %-10s %-10s %-15s\n" \
        "------" \
        "------" \
        "----" \
        "----------"

    for file in "$NGINX_AVAILABLE"/*; do

        [[ -f "$file" ]] || continue

        DOMAIN=$(basename "$file")

        PORT=$(get_proxy_port "$DOMAIN")

        if [[ -L "$NGINX_ENABLED/$DOMAIN" ]]; then
            STATUS="ACTIVE"
        else
            STATUS="DISABLED"
        fi

        SSL_EXPIRY=$(get_ssl_expiry "$DOMAIN")

        printf "%-35s %-10s %-10s %-15s\n" \
            "$DOMAIN" \
            "$STATUS" \
            "${PORT:-N/A}" \
            "$SSL_EXPIRY"
    done

    echo
}

###########################################
# SEARCH PROXY
###########################################

search_proxy() {

    clear

    read -p "Search Domain: " SEARCH
    SEARCH=$(clean_domain "$SEARCH")

    echo

    printf "%-35s %-10s %-10s %-15s\n" \
        "DOMAIN" \
        "STATUS" \
        "PORT" \
        "SSL EXPIRY"

    printf "%-35s %-10s %-10s %-15s\n" \
        "------" \
        "------" \
        "----" \
        "----------"

    for file in "$NGINX_AVAILABLE"/*; do

        [[ -f "$file" ]] || continue

        DOMAIN=$(basename "$file")

        if [[ "$DOMAIN" == *"$SEARCH"* ]]; then

            PORT=$(get_proxy_port "$DOMAIN")

            if [[ -L "$NGINX_ENABLED/$DOMAIN" ]]; then
                STATUS="ACTIVE"
            else
                STATUS="DISABLED"
            fi

            SSL_EXPIRY=$(get_ssl_expiry "$DOMAIN")

            printf "%-35s %-10s %-10s %-15s\n" \
                "$DOMAIN" \
                "$STATUS" \
                "${PORT:-N/A}" \
                "$SSL_EXPIRY"
        fi
    done

    echo
}

###########################################
# SHOW DETAILS
###########################################

show_details() {

    clear

    list_proxies

    read -p "Domain: " DOMAIN
    DOMAIN=$(clean_domain "$DOMAIN")

    if ! proxy_exists "$DOMAIN"; then
        error "Proxy not found."
        return
    fi

    PORT=$(get_proxy_port "$DOMAIN")

    echo
    echo "Domain : $DOMAIN"
    echo "Port   : $PORT"

    if [[ -L "$NGINX_ENABLED/$DOMAIN" ]]; then
        echo "Status : ACTIVE"
    else
        echo "Status : DISABLED"
    fi

    if certbot certificates 2>/dev/null \
        | grep -q "$DOMAIN"; then
        SSL_EXP=$(get_ssl_expiry "$DOMAIN")
        echo "SSL    : ENABLED (Expires: $SSL_EXP)"
    else
        echo "SSL    : DISABLED"
    fi

    echo
}

###########################################
# ENABLE PROXY
###########################################

enable_proxy() {

    clear

    list_proxies

    read -p "Domain: " DOMAIN
    DOMAIN=$(clean_domain "$DOMAIN")

    if ! proxy_exists "$DOMAIN"; then
        error "Proxy not found."
        return
    fi

    ln -sf \
        "$NGINX_AVAILABLE/$DOMAIN" \
        "$NGINX_ENABLED/$DOMAIN"

    reload_nginx

    success "Proxy enabled."
}

###########################################
# DISABLE PROXY
###########################################

disable_proxy() {

    clear

    list_proxies

    read -p "Domain: " DOMAIN
    DOMAIN=$(clean_domain "$DOMAIN")

    if ! proxy_exists "$DOMAIN"; then
        error "Proxy not found."
        return
    fi

    rm -f "$NGINX_ENABLED/$DOMAIN"

    reload_nginx

    success "Proxy disabled."
}

###########################################
# CHANGE PORT
###########################################

change_port() {

    clear

    list_proxies

    read -p "Domain: " DOMAIN
    DOMAIN=$(clean_domain "$DOMAIN")

    if ! proxy_exists "$DOMAIN"; then
        error "Proxy not found."
        return
    fi

    CURRENT_PORT=$(get_proxy_port "$DOMAIN")

    echo
    echo "Current Port : $CURRENT_PORT"
    echo

    read -p "New Port: " NEW_PORT

    if [[ -z "$NEW_PORT" ]]; then
        error "Port required."
        return
    fi

    if ! validate_port "$NEW_PORT"; then
        error "Invalid port number (must be between 1 and 65535)."
        return
    fi

    cp \
        "$NGINX_AVAILABLE/$DOMAIN" \
        "$NGINX_AVAILABLE/$DOMAIN.bak"

    sed -i \
        "s/:$CURRENT_PORT/:$NEW_PORT/g" \
        "$NGINX_AVAILABLE/$DOMAIN"

    if nginx -t; then

        systemctl reload nginx

        success "Port updated."
        success "$DOMAIN -> localhost:$NEW_PORT"

    else

        mv \
            "$NGINX_AVAILABLE/$DOMAIN.bak" \
            "$NGINX_AVAILABLE/$DOMAIN"

        error "Validation failed. Rollback applied."
    fi
}

###########################################
# SSL INSTALL
###########################################

enable_ssl() {

    clear

    list_proxies

    read -p "Domain: " DOMAIN
    DOMAIN=$(clean_domain "$DOMAIN")

    if [[ -z "$DOMAIN" ]]; then
        return
    fi

    if ! proxy_exists "$DOMAIN"; then
        error "Proxy not found."
        return
    fi

    if ! command -v certbot >/dev/null; then

        info "Installing certbot..."

        apt update

        apt install -y \
            certbot \
            python3-certbot-nginx
    fi

    echo
    info "Issuing SSL certificate..."
    echo

    certbot \
        --nginx \
        -d "$DOMAIN"

    success "SSL configured."
}

###########################################
# REMOVE SSL
###########################################

remove_ssl() {

    clear

    list_proxies

    read -p "Domain: " DOMAIN
    DOMAIN=$(clean_domain "$DOMAIN")

    if [[ -z "$DOMAIN" ]]; then
        return
    fi

    echo
    warning "Delete certificate for:"
    echo "$DOMAIN"
    echo

    read -p "Continue? (y/n): " CONFIRM

    [[ "$CONFIRM" != "y" ]] && return

    certbot delete \
        --cert-name "$DOMAIN"

    success "Certificate removed."
}

###########################################
# SSL STATUS
###########################################

ssl_status() {

    clear

    list_proxies

    read -p "Domain: " DOMAIN

    echo

    if certbot certificates 2>/dev/null \
        | grep -q "$DOMAIN"; then

        success "SSL Enabled"

    else

        error "SSL Not Found"
    fi

    echo
}

###########################################
# RENEW SSL
###########################################

renew_ssl() {

    clear

    if ! command -v certbot >/dev/null; then
        error "Certbot is not installed."
        return
    fi

    info "Renewing certificates..."

    certbot renew

    success "Renew completed."
}

###########################################
# HEALTH CHECK
###########################################

health_check() {

    clear

    list_proxies

    read -p "Domain: " DOMAIN
    DOMAIN=$(clean_domain "$DOMAIN")

    if [[ -z "$DOMAIN" ]]; then
        return
    fi

    if ! proxy_exists "$DOMAIN"; then
        error "Proxy not found."
        return
    fi

    PORT=$(get_proxy_port "$DOMAIN")

    echo

    if [[ -n "$PORT" ]]; then
        info "Checking reverse proxy backend localhost:$PORT"
        echo

        if curl \
            --connect-timeout 3 \
            -s \
            "http://127.0.0.1:$PORT" \
            >/dev/null
        then
            success "Application is responding."
        else
            error "Application is not responding on port $PORT."
        fi
    else
        info "Checking static website configuration..."
        ROOT_PATH=$(grep -E '^\s*root\s+' "$NGINX_AVAILABLE/$DOMAIN" 2>/dev/null | awk '{print $2}' | tr -d ';')
        echo
        if [[ -n "$ROOT_PATH" && -d "$ROOT_PATH" ]]; then
            success "Static root directory exists ($ROOT_PATH)."
        else
            error "Static root directory missing or invalid ($ROOT_PATH)."
        fi

        if curl --connect-timeout 3 -s -H "Host: $DOMAIN" "http://127.0.0.1" >/dev/null; then
            success "Local Nginx response OK."
        else
            warning "Local Nginx did not return success response."
        fi
    fi

    echo
}

###########################################
# DNS CHECK
###########################################

dns_check() {

    clear

    list_proxies

    read -p "Domain: " DOMAIN
    DOMAIN=$(clean_domain "$DOMAIN")

    if [[ -z "$DOMAIN" ]]; then
        return
    fi

    echo

    DOMAIN_IP=$(dig +short "$DOMAIN" A 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | tail -1)

    SERVER_IP=$(curl -s --connect-timeout 5 https://api.ipify.org)

    echo "Domain IP : ${DOMAIN_IP:-Not resolved}"
    echo "Server IP : ${SERVER_IP:-Unable to get public IP}"
    echo

    if [[ -n "$DOMAIN_IP" && "$DOMAIN_IP" == "$SERVER_IP" ]]; then
        success "DNS is pointing correctly to this server."
    else
        error "DNS does not point to this server."
    fi

    echo
}

###########################################
# DETECT SERVICES
###########################################

detect_services() {

    clear

    echo
    info "Listening Ports"
    echo

    ss -tulpn

    echo
}

###########################################
# VIEW ACCESS LOG
###########################################

view_access_log() {

    clear

    info "Press CTRL+C to stop viewing"
    echo

    tail -f /var/log/nginx/access.log
}

###########################################
# VIEW ERROR LOG
###########################################

view_error_log() {

    clear

    info "Press CTRL+C to stop viewing"
    echo

    tail -f /var/log/nginx/error.log
}

###########################################
# DOMAIN LOGS
###########################################

domain_logs() {

    clear

    list_proxies

    read -p "Domain: " DOMAIN
    DOMAIN=$(clean_domain "$DOMAIN")

    if [[ -z "$DOMAIN" ]]; then
        return
    fi

    if ! proxy_exists "$DOMAIN"; then
        error "Proxy not found."
        return
    fi

    ACCESS="/var/log/nginx/${DOMAIN}.access.log"
    ERROR_LOG="/var/log/nginx/${DOMAIN}.error.log"

    echo
    echo "1. Access Log"
    echo "2. Error Log"
    echo

    read -p "Choice: " CHOICE

    case $CHOICE in

        1)

            if [[ -f "$ACCESS" ]]; then
                tail -f "$ACCESS"
            else
                error "Log file not found."
            fi

        ;;

        2)

            if [[ -f "$ERROR_LOG" ]]; then
                tail -f "$ERROR_LOG"
            else
                error "Log file not found."
            fi

        ;;

    esac
}

###########################################
# BACKUP CONFIGS
###########################################

backup_configs() {

    clear

    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

    FILE="$BACKUP_DIR/nginx_backup_$TIMESTAMP.tar.gz"

    tar \
        -czf "$FILE" \
        /etc/nginx/sites-available \
        /etc/nginx/sites-enabled \
        /etc/letsencrypt \
        >/dev/null 2>&1

    success "Backup created:"
    echo "$FILE"

    echo
}

###########################################
# RESTORE BACKUP
###########################################

restore_backup() {

    clear

    echo
    info "Available Backups"
    echo

    ls -lh "$BACKUP_DIR"

    echo

    read -p "Backup filename: " FILE

    if [[ ! -f "$BACKUP_DIR/$FILE" ]]; then
        error "Backup not found."
        return
    fi

    echo
    warning "This will overwrite current configs."
    echo

    read -p "Continue? (y/n): " CONFIRM

    [[ "$CONFIRM" != "y" ]] && return

    tar \
        -xzf "$BACKUP_DIR/$FILE" \
        -C /

    reload_nginx

    success "Restore completed."
}

###########################################
# LIST BACKUPS
###########################################

list_backups() {

    clear

    echo
    info "Available Backups"
    echo

    ls -lh "$BACKUP_DIR"

    echo
}

###########################################
# ORACLE CLOUD FIREWALL FIX
###########################################

fix_oracle_firewall() {

    clear

    echo "Fix Oracle Cloud / OS Firewall (Open Ports 80 & 443)"
    echo

    info "Applying iptables rules to open HTTP (80) & HTTPS (443)..."

    if command -v iptables >/dev/null; then
        iptables -I INPUT 6 -m state --state NEW -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 80 -j ACCEPT
        iptables -I INPUT 6 -m state --state NEW -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 443 -j ACCEPT

        if command -v apt >/dev/null; then
            info "Ensuring netfilter-persistent is installed to keep rules after reboot..."
            DEBIAN_FRONTEND=noninteractive apt update -qq 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
        fi

        if command -v netfilter-persistent >/dev/null; then
            netfilter-persistent save >/dev/null 2>&1 || true
        fi

        success "iptables rules applied and saved."
    fi

    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        info "Configuring UFW firewall..."
        ufw allow 80/tcp >/dev/null 2>&1
        ufw allow 443/tcp >/dev/null 2>&1
        success "UFW rules added for ports 80 & 443."
    fi

    echo
    warning "Note: Make sure to also allow ports 80 & 443 in your Oracle Cloud Console Ingress Security Rules!"
    echo
}


###########################################
# DASHBOARD
###########################################

dashboard() {

    TOTAL=$(find "$NGINX_AVAILABLE" \
        -maxdepth 1 \
        -type f \
        | wc -l)

    ACTIVE=$(find "$NGINX_ENABLED" \
        -maxdepth 1 \
        -type l \
        | wc -l)

    DISABLED=$((TOTAL - ACTIVE))

    clear

    echo
    echo "=================================================="
    echo "               Proxy Manager V2"
    echo "=================================================="
    echo

    echo "Total Proxies : $TOTAL"
    echo "Active        : $ACTIVE"
    echo "Disabled      : $DISABLED"

    if systemctl is-active --quiet nginx; then
        echo "Nginx Status  : RUNNING"
    else
        echo "Nginx Status  : STOPPED"
    fi

    echo
}

###########################################
# MAIN MENU
###########################################

main_menu() {

    echo "1.  Add Proxy"
    echo "2.  Add Static Website"
    echo "3.  Delete Proxy"
    echo "4.  List Proxies"
    echo "5.  Search Proxy"
    echo "6.  Show Proxy Details"
    echo
    echo "7.  Enable Proxy"
    echo "8.  Disable Proxy"
    echo "9.  Change Port"
    echo
    echo "10. Enable SSL"
    echo "11. Remove SSL"
    echo "12. SSL Status"
    echo "13. Renew SSL"
    echo
    echo "14. Health Check"
    echo "15. DNS Check"
    echo "16. Detect Running Services"
    echo
    echo "17. View Access Log"
    echo "18. View Error Log"
    echo "19. Domain Logs"
    echo
    echo "20. Backup Configs"
    echo "21. Restore Backup"
    echo "22. List Backups"
    echo
    echo "23. Nginx Status"
    echo "24. Reload Nginx"
    echo "25. Fix Oracle Cloud Firewall (Open Ports 80/443)"
    echo
    echo "26. Exit"
    echo

    read -p "Select option: " OPTION
}

###########################################
# APPLICATION LOOP
###########################################

run_application() {

    while true
    do

        dashboard

        main_menu

        case $OPTION in

            1)
                add_proxy
                pause
            ;;

            2)
                add_static_website
                pause
            ;;

            3)
                delete_proxy
                pause
            ;;

            4)
                list_proxies
                pause
            ;;

            5)
                search_proxy
                pause
            ;;

            6)
                show_details
                pause
            ;;

            7)
                enable_proxy
                pause
            ;;

            8)
                disable_proxy
                pause
            ;;

            9)
                change_port
                pause
            ;;

            10)
                enable_ssl
                pause
            ;;

            11)
                remove_ssl
                pause
            ;;

            12)
                ssl_status
                pause
            ;;

            13)
                renew_ssl
                pause
            ;;

            14)
                health_check
                pause
            ;;

            15)
                dns_check
                pause
            ;;

            16)
                detect_services
                pause
            ;;

            17)
                view_access_log
            ;;

            18)
                view_error_log
            ;;

            19)
                domain_logs
            ;;

            20)
                backup_configs
                pause
            ;;

            21)
                restore_backup
                pause
            ;;

            22)
                list_backups
                pause
            ;;

            23)
                nginx_status
                pause
            ;;

            24)
                reload_nginx
                pause
            ;;

            25)
                fix_oracle_firewall
                pause
            ;;

            26)

                clear

                success "Goodbye."

                exit 0

            ;;

            *)

                error "Invalid option."
                pause

            ;;

        esac

    done
}

###########################################
# ENTRY POINT
###########################################

require_root

# Create base and backup directories
mkdir -p "$BASE_DIR"
mkdir -p "$BACKUP_DIR"

install_dependencies
run_application
