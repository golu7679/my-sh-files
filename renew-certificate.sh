#!/usr/bin/env bash
# ==============================================================================
# Script Name : renew-certificate.sh
# Description : Automated installer, configurator, and manager for Let's Encrypt
#               SSL certificate expiry checking and auto-renewal with Nginx.
# Author      : Golu Rajak
# ==============================================================================
#
# This script automates the complete 4-step workflow:
#   1. Creates the certificate expiry checker script with customizable threshold.
#   2. Makes the checker script executable with proper PATH for cron.
#   3. Tests the renewal checker manually and monitors logs.
#   4. Schedules the checker script via root cron (e.g., every 6 hours).
#
# It includes an interactive wizard asking all necessary questions with smart
# defaults, a management menu, and safe crontab manipulation.
# ==============================================================================

# Ensure the script is run using Bash
if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

# Exit immediately if an unexpected error occurs during setup
set -Eeo pipefail

# ==============================================================================
# Default Configuration Constants
# ==============================================================================
DEFAULT_SCRIPT_PATH="/usr/local/bin/check-cert-expiry.sh"
DEFAULT_LOG_PATH="/var/log/cert-expiry-check.log"
DEFAULT_THRESHOLD_HOURS=48              # 48 hours (172,800 seconds)
DEFAULT_CRON_SCHEDULE="0 */6 * * *"     # Every 6 hours
DEFAULT_RELOAD_CMD="systemctl reload nginx"
CRON_TAG="# [cert-expiry-auto-renewal]"

# ==============================================================================
# Terminal Color Palette & Formatting
# ==============================================================================
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ==============================================================================
# UI & Output Helper Functions
# ==============================================================================

# Print informational message in blue
info() {
    printf "${BLUE}ℹ️  %s${NC}\n" "$1"
}

# Print success message in green
success() {
    printf "${GREEN}✅ %s${NC}\n" "$1"
}

# Print warning message in yellow
warning() {
    printf "${YELLOW}⚠️  %s${NC}\n" "$1"
}

# Print error message in red
error() {
    printf "${RED}❌ %s${NC}\n" "$1"
}

# Print section headers with separator
section_header() {
    echo ""
    printf "${CYAN}${BOLD}=== %s ===${NC}\n" "$1"
    echo ""
}

# Prompt user to press enter before continuing
pause() {
    echo ""
    read -rp "Press [Enter] to continue..."
}

# ==============================================================================
# Privilege & Dependency Checks
# ==============================================================================

# Ensure script is run with root/sudo privileges (required for /etc/letsencrypt,
# /usr/local/bin, crontab, and systemctl)
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script requires root privileges to manage /usr/local/bin, crontab, and SSL certificates."
        echo "Please re-run this script with sudo: sudo $0"
        exit 1
    fi
}

# Verify required system dependencies are installed
check_dependencies() {
    info "Verifying required system tools..."
    local missing_tools=()

    # Check for OpenSSL (needed to inspect certificate end dates)
    if ! command -v openssl >/dev/null 2>&1; then
        missing_tools+=("openssl")
    fi

    # Check for AWK (needed to parse certbot output)
    if ! command -v awk >/dev/null 2>&1; then
        missing_tools+=("awk")
    fi

    # Check for crontab (needed to schedule periodic execution)
    if ! command -v crontab >/dev/null 2>&1; then
        missing_tools+=("cron/crontab")
    fi

    # Check for certbot (warn if missing, as it handles certificate renewal)
    if ! command -v certbot >/dev/null 2>&1; then
        warning "Certbot was not detected in PATH. Ensure Certbot is installed (via apt or snap) before running renewals."
    fi

    if [ ${#missing_tools[@]} -gt 0 ]; then
        error "Missing required dependencies: ${missing_tools[*]}"
        echo "Please install them using your package manager (e.g., sudo apt update && sudo apt install -y ${missing_tools[*]})"
        exit 1
    fi

    success "All critical dependencies are present."
}

# ==============================================================================
# Step 1 & 2: Generate and Install Certificate Expiry Checker Script
# ==============================================================================

# Generates the target standalone renewal script and sets executable permissions
create_checker_script() {
    local target_script="$1"
    local log_file="$2"
    local threshold_seconds="$3"
    local reload_cmd="$4"

    info "Creating target script directory if needed..."
    mkdir -p "$(dirname "$target_script")"

    info "Writing renewal script to: $target_script"

    # Write the self-contained checker script
    cat <<'EOF' > "$target_script"
#!/usr/bin/env bash
# ==============================================================================
# Script Name : check-cert-expiry.sh
# Description : Checks Let's Encrypt certificate expiration dates and triggers
#               Certbot renewal when certificates fall within the threshold.
# Generated By: renew-certificate.sh
# ==============================================================================

# Ensure strict bash execution
set -Eeuo pipefail

# Ensure standard binaries and snap paths are accessible under cron environment
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin:$PATH"

# Configuration variables injected during setup
THRESHOLD=__THRESHOLD_PLACEHOLDER__
LOG_FILE="__LOG_FILE_PLACEHOLDER__"
RELOAD_CMD="__RELOAD_CMD_PLACEHOLDER__"

# Ensure target log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Helper for logging messages to file and optionally to stdout when run in a terminal
log_msg() {
    local timestamp
    timestamp=$(date '+%F %T')
    echo "[$timestamp] $1" >> "$LOG_FILE"
    if [ -t 1 ]; then
        echo "[$timestamp] $1"
    fi
}

log_msg "Starting certificate expiry check."

# Verify certbot is available
if ! command -v certbot >/dev/null 2>&1; then
    log_msg "ERROR: Certbot command not found in PATH ($PATH)."
    exit 1
fi

# Retrieve all certificate names managed by Certbot
CERT_NAMES=()
while IFS= read -r line; do
    if [[ -n "$line" ]]; then
        # Trim leading and trailing whitespace
        trimmed_name="$(echo "$line" | xargs)"
        CERT_NAMES+=("$trimmed_name")
    fi
done < <(certbot certificates 2>/dev/null | awk -F ': ' '/Certificate Name:/ {print $2}')

# Check if any certificates were found
if [ "${#CERT_NAMES[@]}" -eq 0 ]; then
    log_msg "No Certbot-managed certificates found on this system."
    exit 0
fi

log_msg "Found ${#CERT_NAMES[@]} certificate(s) to verify."

RENEW_NEEDED=0

# Helper function to convert human-readable date string into epoch seconds
# Supports both GNU date (Linux) and BSD date (macOS)
parse_date_to_epoch() {
    local raw_date="$1"
    local epoch=0

    # Try GNU date (-d)
    epoch=$(date -d "$raw_date" +%s 2>/dev/null || true)
    if [[ -n "$epoch" && "$epoch" =~ ^[0-9]+$ ]]; then
        echo "$epoch"
        return
    fi

    # Try BSD date format 1
    epoch=$(date -j -f "%b %d %T %Y %Z" "$raw_date" +%s 2>/dev/null || true)
    if [[ -n "$epoch" && "$epoch" =~ ^[0-9]+$ ]]; then
        echo "$epoch"
        return
    fi

    # Try BSD date format 2 (space padded day)
    epoch=$(date -j -f "%b %e %T %Y %Z" "$raw_date" +%s 2>/dev/null || true)
    if [[ -n "$epoch" && "$epoch" =~ ^[0-9]+$ ]]; then
        echo "$epoch"
        return
    fi

    # Fallback to python3 if available
    if command -v python3 >/dev/null 2>&1; then
        epoch=$(python3 -c "import datetime, sys; print(int(datetime.datetime.strptime(sys.argv[1].strip(), '%b %d %H:%M:%S %Y %Z').timestamp()))" "$raw_date" 2>/dev/null || true)
        if [[ -n "$epoch" && "$epoch" =~ ^[0-9]+$ ]]; then
            echo "$epoch"
            return
        fi
    fi

    echo 0
}

# Inspect each certificate's validity
for CERT_NAME in "${CERT_NAMES[@]}"; do
    CERT_PATH="/etc/letsencrypt/live/$CERT_NAME/fullchain.pem"

    if [ ! -f "$CERT_PATH" ]; then
        log_msg "Certificate fullchain file missing: $CERT_PATH (skipping)"
        continue
    fi

    # Extract expiry date using OpenSSL
    EXPIRY_DATE=$(openssl x509 -in "$CERT_PATH" -noout -enddate 2>/dev/null | cut -d= -f2)

    if [ -z "$EXPIRY_DATE" ]; then
        log_msg "Could not extract expiry date for: $CERT_NAME"
        continue
    fi

    EXPIRY_EPOCH=$(parse_date_to_epoch "$EXPIRY_DATE")
    NOW_EPOCH=$(date +%s)

    if [ "$EXPIRY_EPOCH" -le 0 ]; then
        log_msg "Failed to parse expiry date '$EXPIRY_DATE' for certificate: $CERT_NAME"
        continue
    fi

    REMAINING=$((EXPIRY_EPOCH - NOW_EPOCH))
    REMAINING_HOURS=$((REMAINING / 3600))
    REMAINING_DAYS=$((REMAINING_HOURS / 24))

    log_msg "Certificate '$CERT_NAME' expires on: $EXPIRY_DATE ($REMAINING_DAYS days / $REMAINING_HOURS hours remaining)"

    # Check if certificate expiry is within the threshold window
    if [ "$REMAINING" -lt "$THRESHOLD" ]; then
        log_msg "Renewal required for '$CERT_NAME' (remaining: $REMAINING_HOURS hours < threshold: $((THRESHOLD / 3600)) hours)"
        RENEW_NEEDED=1
    fi
done

# If at least one certificate is within the renewal threshold, invoke Certbot
if [ "$RENEW_NEEDED" -eq 1 ]; then
    log_msg "Running Certbot renewal process..."

    # certbot renew checks and renews expiring certificates
    if certbot renew --quiet; then
        log_msg "Certbot renewal command completed successfully."

        # Validate Nginx configuration syntax before reloading
        if command -v nginx >/dev/null 2>&1; then
            if nginx -t >/dev/null 2>&1; then
                log_msg "Nginx configuration syntax test passed."
                if $RELOAD_CMD; then
                    log_msg "Web server reloaded successfully ($RELOAD_CMD)."
                else
                    log_msg "ERROR: Failed to reload web server ($RELOAD_CMD)."
                    exit 1
                fi
            else
                log_msg "ERROR: Nginx configuration test failed (nginx -t). Web server was not reloaded."
                exit 1
            fi
        else
            # Execute reload command directly if nginx binary is not directly in PATH
            if $RELOAD_CMD; then
                log_msg "Web server reloaded successfully ($RELOAD_CMD)."
            else
                log_msg "ERROR: Failed to reload web server ($RELOAD_CMD)."
                exit 1
            fi
        fi
    else
        log_msg "ERROR: Certbot renewal command failed."
        exit 1
    fi
else
    log_msg "All certificates are healthy. No renewal needed at this time."
fi

log_msg "Certificate expiry check completed."
EOF

    # Replace configuration placeholders with user-chosen values
    sed -i.bak "s|__THRESHOLD_PLACEHOLDER__|$threshold_seconds|g" "$target_script"
    sed -i.bak "s|__LOG_FILE_PLACEHOLDER__|$log_file|g" "$target_script"
    sed -i.bak "s|__RELOAD_CMD_PLACEHOLDER__|$reload_cmd|g" "$target_script"
    rm -f "${target_script}.bak"

    # Step 2: Make the script executable
    chmod +x "$target_script"
    success "Generated executable script at: $target_script"
}

# ==============================================================================
# Step 4: Crontab Scheduling & Management
# ==============================================================================

# Safely installs or updates the cron job for root
install_cron_job() {
    local target_script="$1"
    local cron_schedule="$2"

    info "Configuring root crontab schedule..."

    # Read existing crontab (returns empty string if user has no crontab)
    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null || true)

    # Filter out previous instances of this script or tag to prevent duplicates
    local cleaned_crontab
    cleaned_crontab=$(echo "$current_crontab" | grep -v "$target_script" | grep -v "$CRON_TAG" || true)

    # Build new crontab entry
    local new_entry
    new_entry="$cron_schedule $target_script $CRON_TAG"

    local updated_crontab
    if [[ -z "$cleaned_crontab" ]]; then
        updated_crontab="$new_entry"
    else
        updated_crontab="${cleaned_crontab}"$'\n'"${new_entry}"
    fi

    # Install updated crontab
    echo "$updated_crontab" | crontab -

    success "Crontab updated successfully with schedule: $cron_schedule"
    echo ""
    info "Current root crontab entries:"
    crontab -l | grep --color=never "$target_script" || crontab -l
}

# View current cron jobs related to this script
view_cron_status() {
    section_header "Current Cron Job Status"
    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null || true)

    if echo "$current_crontab" | grep -q "$CRON_TAG"; then
        success "Active certificate renewal cron job found:"
        echo "$current_crontab" | grep "$CRON_TAG"
    else
        warning "No active certificate renewal cron job found in root's crontab."
    fi
}

# Remove certificate renewal cron job from root crontab
remove_cron_job() {
    local target_script="$1"
    info "Removing certificate renewal cron job..."

    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null || true)

    if echo "$current_crontab" | grep -q "$target_script"; then
        local cleaned_crontab
        cleaned_crontab=$(echo "$current_crontab" | grep -v "$target_script" | grep -v "$CRON_TAG" || true)
        
        if [[ -z "$cleaned_crontab" ]]; then
            crontab -r 2>/dev/null || true
        else
            echo "$cleaned_crontab" | crontab -
        fi
        success "Cron job removed."
    else
        info "No matching cron job found to remove."
    fi
}

# ==============================================================================
# Step 3: Testing & Log Viewer
# ==============================================================================

# Manually execute the certificate checker script
run_manual_check() {
    local target_script="$1"
    section_header "Testing Certificate Expiry Check Script"

    if [ ! -f "$target_script" ]; then
        error "Checker script not found at '$target_script'."
        echo "Please run the setup wizard first to generate the script."
        return 1
    fi

    info "Executing: $target_script"
    echo "------------------------------------------------------------"
    if bash "$target_script"; then
        echo "------------------------------------------------------------"
        success "Manual check execution finished successfully."
    else
        echo "------------------------------------------------------------"
        error "Manual check execution encountered an error (exit code: $?)."
    fi
}

# View recent log entries from the renewal check log file
view_logs() {
    local log_file="$1"
    section_header "Certificate Expiry Check Logs"

    if [ ! -f "$log_file" ]; then
        warning "Log file not found at '$log_file'."
        info "The log file will be automatically generated on the first script execution."
        return
    fi

    echo "Showing the last 50 lines from: $log_file"
    echo "------------------------------------------------------------"
    tail -n 50 "$log_file"
    echo "------------------------------------------------------------"
}

# ==============================================================================
# Helper: List Managed Certificates & Current Expirations
# ==============================================================================
list_certificates() {
    section_header "Certbot Certificates & Expirations"

    if ! command -v certbot >/dev/null 2>&1; then
        error "Certbot is not installed or not in PATH."
        return 1
    fi

    info "Querying Certbot for managed certificates..."
    echo ""
    certbot certificates 2>/dev/null || warning "Unable to query certbot certificates."
}

# ==============================================================================
# Interactive Full Setup Wizard (Steps 1, 2, 3, 4)
# ==============================================================================
interactive_setup() {
    section_header "Certificate Auto-Renewal Setup Wizard"
    echo "This wizard will configure the automated expiry checker and root cron schedule."
    echo ""

    # Question 1: Script Installation Location
    read -rp "1. Installation path for the renewal script [$DEFAULT_SCRIPT_PATH]: " user_script_path
    local script_path="${user_script_path:-$DEFAULT_SCRIPT_PATH}"

    # Question 2: Expiry Threshold (Hours)
    echo ""
    echo "Common threshold options:"
    echo "  - 48 hours  (2 days)  [Default]"
    echo "  - 168 hours (7 days)"
    echo "  - 720 hours (30 days)"
    read -rp "2. Renew certificates if expiring within how many hours? [$DEFAULT_THRESHOLD_HOURS]: " user_threshold_hours
    local threshold_hours="${user_threshold_hours:-$DEFAULT_THRESHOLD_HOURS}"

    # Validate that threshold is a positive integer
    if ! [[ "$threshold_hours" =~ ^[0-9]+$ ]] || [ "$threshold_hours" -le 0 ]; then
        warning "Invalid number entered. Falling back to default: $DEFAULT_THRESHOLD_HOURS hours."
        threshold_hours="$DEFAULT_THRESHOLD_HOURS"
    fi
    local threshold_seconds=$((threshold_hours * 3600))

    # Question 3: Log File Destination
    echo ""
    read -rp "3. Path to log file [$DEFAULT_LOG_PATH]: " user_log_path
    local log_file="${user_log_path:-$DEFAULT_LOG_PATH}"

    # Question 4: Cron Schedule Frequency
    echo ""
    echo "4. Choose how frequently cron should check for certificate expiry:"
    echo "   1) Every 6 hours  (0 */6 * * *) [Recommended / Default]"
    echo "   2) Every 12 hours (0 */12 * * *)"
    echo "   3) Daily at midnight (0 0 * * *)"
    echo "   4) Twice daily at 00:00 and 12:00 (0 0,12 * * *)"
    echo "   5) Custom cron expression"
    read -rp "Select schedule [1-5, default 1]: " schedule_choice

    local cron_schedule="$DEFAULT_CRON_SCHEDULE"
    case "$schedule_choice" in
        2) cron_schedule="0 */12 * * *" ;;
        3) cron_schedule="0 0 * * *" ;;
        4) cron_schedule="0 0,12 * * *" ;;
        5)
            read -rp "Enter your custom cron expression (e.g., '0 */4 * * *'): " custom_cron
            cron_schedule="${custom_cron:-$DEFAULT_CRON_SCHEDULE}"
            ;;
        *) cron_schedule="$DEFAULT_CRON_SCHEDULE" ;;
    esac

    # Question 5: Web Server Reload Command
    echo ""
    read -rp "5. Web server reload command [$DEFAULT_RELOAD_CMD]: " user_reload_cmd
    local reload_cmd="${user_reload_cmd:-$DEFAULT_RELOAD_CMD}"

    # Configuration Summary & Confirmation
    section_header "Configuration Summary"
    printf "${BOLD}Checker Script Path:${NC} %s\n" "$script_path"
    printf "${BOLD}Expiry Threshold   :${NC} %s hours (%s seconds)\n" "$threshold_hours" "$threshold_seconds"
    printf "${BOLD}Log File Path      :${NC} %s\n" "$log_file"
    printf "${BOLD}Cron Schedule      :${NC} %s\n" "$cron_schedule"
    printf "${BOLD}Web Server Reload  :${NC} %s\n" "$reload_cmd"
    echo ""

    read -rp "Proceed with setup using these settings? (y/n) [y]: " confirm_proceed
    confirm_proceed="${confirm_proceed:-y}"
    if [[ ! "$confirm_proceed" =~ ^[yY]$ ]]; then
        info "Setup cancelled by user."
        return
    fi

    # Step 1 & 2: Generate script & make executable
    create_checker_script "$script_path" "$log_file" "$threshold_seconds" "$reload_cmd"

    # Step 4: Schedule via Crontab
    install_cron_job "$script_path" "$cron_schedule"

    # Step 3: Offer to test script immediately
    echo ""
    read -rp "Would you like to test the certificate check script now? (y/n) [y]: " test_now
    test_now="${test_now:-y}"
    if [[ "$test_now" =~ ^[yY]$ ]]; then
        run_manual_check "$script_path"

        # Offer to view log output
        echo ""
        read -rp "Would you like to view the recent log entries? (y/n) [y]: " view_logs_now
        view_logs_now="${view_logs_now:-y}"
        if [[ "$view_logs_now" =~ ^[yY]$ ]]; then
            view_logs "$log_file"
        fi
    fi

    section_header "Setup Complete"
    success "Certificate auto-renewal is fully installed and scheduled!"
    echo "  - Script Location : $script_path"
    echo "  - Cron Schedule   : $cron_schedule"
    echo "  - Log File        : $log_file"
    echo "  - View Logs       : sudo tail -f $log_file"
}

# ==============================================================================
# Uninstall / Cleanup Function
# ==============================================================================
uninstall_all() {
    section_header "Uninstall Auto-Renewal Setup"
    warning "This will remove the scheduled cron job and optionally delete the checker script."
    echo ""

    read -rp "Target script path to remove [$DEFAULT_SCRIPT_PATH]: " user_script_path
    local script_path="${user_script_path:-$DEFAULT_SCRIPT_PATH}"

    read -rp "Are you sure you want to uninstall? (y/n) [n]: " confirm_uninstall
    if [[ ! "$confirm_uninstall" =~ ^[yY]$ ]]; then
        info "Uninstall cancelled."
        return
    fi

    # Remove cron job
    remove_cron_job "$script_path"

    # Remove script file if desired
    if [ -f "$script_path" ]; then
        read -rp "Do you also want to delete the script file ($script_path)? (y/n) [y]: " remove_file
        remove_file="${remove_file:-y}"
        if [[ "$remove_file" =~ ^[yY]$ ]]; then
            rm -f "$script_path"
            success "Deleted script: $script_path"
        fi
    fi

    # Remove log file if desired
    if [ -f "$DEFAULT_LOG_PATH" ]; then
        read -rp "Do you also want to delete the log file ($DEFAULT_LOG_PATH)? (y/n) [n]: " remove_log
        if [[ "$remove_log" =~ ^[yY]$ ]]; then
            rm -f "$DEFAULT_LOG_PATH"
            success "Deleted log file: $DEFAULT_LOG_PATH"
        fi
    fi

    success "Uninstallation completed."
}

# ==============================================================================
# Interactive Main Menu
# ==============================================================================
main_menu() {
    while true; do
        clear
        printf "${CYAN}${BOLD}"
        echo "============================================================"
        echo "   Let's Encrypt SSL Auto-Renewal Manager"
        echo "   Author: Golu Rajak"
        echo "============================================================"
        printf "${NC}\n"
        echo "1) Full Setup / Configure Auto-Renewal (Steps 1-4)"
        echo "2) Run Expiry Check Manually Now       (Step 3)"
        echo "3) View Expiry Check Logs              (Step 3)"
        echo "4) View / Verify Cron Schedule         (Step 4)"
        echo "5) List Active SSL Certificates"
        echo "6) Uninstall Auto-Renewal Setup"
        echo "0) Exit"
        echo ""
        read -rp "Choose an option [0-6]: " choice

        case "$choice" in
            1)
                interactive_setup
                pause
                ;;
            2)
                read -rp "Script path to execute [$DEFAULT_SCRIPT_PATH]: " custom_run_path
                run_manual_check "${custom_run_path:-$DEFAULT_SCRIPT_PATH}"
                pause
                ;;
            3)
                read -rp "Log file to view [$DEFAULT_LOG_PATH]: " custom_log_path
                view_logs "${custom_log_path:-$DEFAULT_LOG_PATH}"
                pause
                ;;
            4)
                view_cron_status
                pause
                ;;
            5)
                list_certificates
                pause
                ;;
            6)
                uninstall_all
                pause
                ;;
            0|q|Q)
                echo ""
                success "Goodbye!"
                exit 0
                ;;
            *)
                error "Invalid selection. Please choose an option from 0 to 6."
                pause
                ;;
        esac
    done
}

# ==============================================================================
# Command Line Argument Dispatcher
# ==============================================================================
show_help() {
    echo "Usage: sudo $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --setup, -s       Run interactive setup wizard directly"
    echo "  --check, -c       Execute the renewal check script manually"
    echo "  --logs, -l        View the last 50 lines of the renewal log"
    echo "  --cron            View the current cron status"
    echo "  --list            List active Certbot certificates"
    echo "  --uninstall, -u   Uninstall auto-renewal script and cron job"
    echo "  --help, -h        Display this help message"
    echo ""
    echo "When run without options, an interactive menu is displayed."
}

# ==============================================================================
# Script Entry Point
# ==============================================================================
# Handle help option before requiring root privileges
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    show_help
    exit 0
fi

require_root
check_dependencies

if [ $# -gt 0 ]; then
    case "$1" in
        --setup|-s)
            interactive_setup
            ;;
        --check|-c)
            run_manual_check "$DEFAULT_SCRIPT_PATH"
            ;;
        --logs|-l)
            view_logs "$DEFAULT_LOG_PATH"
            ;;
        --cron)
            view_cron_status
            ;;
        --list)
            list_certificates
            ;;
        --uninstall|-u)
            uninstall_all
            ;;
        *)
            error "Unknown parameter: $1"
            show_help
            exit 1
            ;;
    esac
else
    # Default behavior: Launch interactive menu
    main_menu
fi