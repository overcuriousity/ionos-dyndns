#!/bin/bash

###############################################################################
# IONOS DynDNS Updater Script
#
# Features:
# - Automatic Zone Discovery
# - Detailed Verbose Output
# - Intelligent IP change detection
# - Bulk Updates
# - Post-Update Verification
# - Gotify Notifications (supports self-signed certs)
# - Error Trapping
###############################################################################

set -euo pipefail

# --- TRAP FOR DEBUGGING SILENT FAILURES ---
trap 'err_line=$LINENO; log ERROR "Script crashed unexpectedly on line ${err_line}"' ERR

# Configuration Paths
readonly CONFIG_DIR="${HOME}/.config/ionos-dyndns"
readonly API_KEY_FILE="${CONFIG_DIR}/api_key"
readonly GOTIFY_CONFIG_FILE="${CONFIG_DIR}/gotify.conf"
readonly LOG_FILE="${CONFIG_DIR}/dyndns.log"

# Constants
readonly BASE_URL="https://api.hosting.ionos.com/dns/v1"
readonly IP_CHECK_URL="https://ipinfo.io/ip"
readonly API_TIMEOUT=30
readonly CONNECT_TIMEOUT=10

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Mode flags
CONFIRM_MODE=false
FORCE_MODE=false

# Global variables
GOTIFY_URL=""
GOTIFY_TOKEN=""
PUBLIC_IP=""

###############################################################################
# Logging Functions
###############################################################################

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Log to file
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}"
    
    # Log to stderr with colors
    case "${level}" in
        INFO)    echo -e "${BLUE}[INFO]${NC} ${message}" >&2 ;;
        SUCCESS) echo -e "${GREEN}[SUCCESS]${NC} ${message}" >&2 ;;
        WARN)    echo -e "${YELLOW}[WARN]${NC} ${message}" >&2 ;;
        ERROR)   echo -e "${RED}[ERROR]${NC} ${message}" >&2 ;;
        *)       echo "[${level}] ${message}" >&2 ;;
    esac
}

###############################################################################
# Gotify Functions
###############################################################################

load_gotify_config() {
    if [[ -f "${GOTIFY_CONFIG_FILE}" ]]; then
        source "${GOTIFY_CONFIG_FILE}"
        # Trim potential trailing slash
        GOTIFY_URL=${GOTIFY_URL%/}
    fi
}

send_gotify_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-5}"

    if [[ -z "${GOTIFY_URL}" || -z "${GOTIFY_TOKEN}" ]]; then
        log WARN "Gotify credentials missing. Skipping notification."
        return 0
    fi

    log INFO "Sending Gotify notification..."

    # Note: -k flag added to allow self-signed certificates
    # We capture both stdout and stderr to debug if it fails
    local response
    local http_code
    
    # Capture http code at the end of the output
    response=$(curl -k -s -w "\n%{http_code}" \
        --connect-timeout "${CONNECT_TIMEOUT}" \
        -X POST "${GOTIFY_URL}/message?token=${GOTIFY_TOKEN}" \
        -F "title=${title}" \
        -F "message=${message}" \
        -F "priority=${priority}" \
        -F "extras[client::display][contentType]=text/markdown")
    
    http_code=$(echo "${response}" | tail -n1)
    
    if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
        log SUCCESS "Gotify notification sent."
    else
        log WARN "Failed to send Gotify notification. HTTP Code: ${http_code}"
        log WARN "Response: ${response}"
    fi
}

###############################################################################
# Error Handling
###############################################################################

error_exit() {
    log ERROR "$1"
    # Attempt to notify on fatal error
    if [[ -n "${GOTIFY_URL}" && -n "${GOTIFY_TOKEN}" ]]; then
        send_gotify_notification "IONOS DNS Error" "Script failed: $1" 8
    fi
    exit 1
}

###############################################################################
# Configuration Setup
###############################################################################

setup_config() {
    local force_update="${1:-false}"
    
    if [[ ! -d "${CONFIG_DIR}" ]]; then
        mkdir -p "${CONFIG_DIR}"
        chmod 700 "${CONFIG_DIR}"
        log INFO "Created config directory: ${CONFIG_DIR}"
    fi
    
    # 1. API Key Setup
    if [[ ! -f "${API_KEY_FILE}" || "${force_update}" == "true" ]]; then
        echo -e "${YELLOW}--- IONOS API Setup ---${NC}" >&2
        read -p "Enter your IONOS API key: " -r api_key </dev/tty
        if [[ -n "${api_key}" ]]; then
            echo "${api_key}" > "${API_KEY_FILE}"
            chmod 600 "${API_KEY_FILE}"
            log SUCCESS "API key saved."
        fi
    fi

    # 2. Gotify Setup
    local configure_gotify=false
    
    if [[ "${force_update}" == "true" ]]; then
        echo -e "\n${YELLOW}--- Gotify Setup (Optional) ---${NC}" >&2
        read -p "Configure/Update Gotify? [y/N] " -n 1 -r </dev/tty
        echo >&2
        if [[ $REPLY =~ ^[Yy]$ ]]; then configure_gotify=true; fi
    elif [[ ! -f "${GOTIFY_CONFIG_FILE}" ]]; then
         true
    fi

    if [[ "$configure_gotify" == true ]]; then
        read -p "Gotify URL (e.g. https://push.example.com): " -r g_url </dev/tty
        read -p "Gotify App Token: " -r g_token </dev/tty
        
        g_url=${g_url%/}

        cat << EOF > "${GOTIFY_CONFIG_FILE}"
GOTIFY_URL="${g_url}"
GOTIFY_TOKEN="${g_token}"
EOF
        chmod 600 "${GOTIFY_CONFIG_FILE}"
        log SUCCESS "Gotify configuration saved."
    fi
}

load_api_key() {
    if [[ ! -f "${API_KEY_FILE}" ]]; then
        error_exit "API key file not found. Please run --setup first."
    fi
    API_KEY=$(cat "${API_KEY_FILE}")
    if [[ -z "${API_KEY}" ]]; then error_exit "API key is empty"; fi
}

###############################################################################
# Helper Functions
###############################################################################

confirm_step() {
    if [[ "${CONFIRM_MODE}" == true ]]; then
        echo -e "${YELLOW}[CONFIRM]${NC} $1" >&2
        read -p "Continue? [y/N] " -n 1 -r </dev/tty
        echo >&2
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log WARN "Step cancelled by user"
            exit 0
        fi
    fi
}

api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    local url="${BASE_URL}${endpoint}"
    local response_file=$(mktemp)
    local http_code
    
    echo "[$(date '+%H:%M:%S')] [INFO] API Call: ${method} ${endpoint}" >> "${LOG_FILE}"
    
    if [[ -n "${data}" ]]; then
        http_code=$(curl -s -w "%{http_code}" -o "${response_file}" \
            --connect-timeout "${CONNECT_TIMEOUT}" \
            --max-time "${API_TIMEOUT}" \
            -X "${method}" \
            "${url}" \
            -H "accept: application/json" \
            -H "X-API-Key: ${API_KEY}" \
            -H "Content-Type: application/json" \
            -d "${data}")
    else
        http_code=$(curl -s -w "%{http_code}" -o "${response_file}" \
            --connect-timeout "${CONNECT_TIMEOUT}" \
            --max-time "${API_TIMEOUT}" \
            -X "${method}" \
            "${url}" \
            -H "accept: application/json" \
            -H "X-API-Key: ${API_KEY}")
    fi
    
    local response=$(cat "${response_file}")
    rm -f "${response_file}"
    
    if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
        echo "${response}"
        return 0
    else
        log ERROR "API call failed with HTTP ${http_code}"
        log ERROR "Response: ${response}"
        return 1
    fi
}

###############################################################################
# Core Logic
###############################################################################

get_public_ip() {
    log INFO "Fetching Public IP..."
    local ip=$(curl -s --connect-timeout "${CONNECT_TIMEOUT}" --max-time "${API_TIMEOUT}" "${IP_CHECK_URL}")
    
    if [[ -z "${ip}" ]]; then error_exit "Failed to fetch public IP"; fi
    if [[ ! "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        error_exit "Invalid IP format: ${ip}"
    fi
    
    log SUCCESS "Current IP: ${ip}"
    PUBLIC_IP="${ip}"
}

fetch_zones() {
    log INFO "Fetching DNS Zones..."
    local response=$(api_call "GET" "/zones")
    if [[ -z "${response}" ]]; then error_exit "Empty response from zones API"; fi
    
    local zones=$(echo "${response}" | jq -r '.[] | "\(.id):\(.name)"' 2>/dev/null)
    if [[ -z "${zones}" ]]; then error_exit "No zones found"; fi
    echo "${zones}"
}

process_zone_records() {
    local zones="$1"
    local current_ip="$2"
    local all_domains=()
    local outdated_count=0
    
    echo "" >&2
    log INFO "--- Checking Domains ---"
    
    while IFS=: read -r zone_id zone_name; do
        local response=$(api_call "GET" "/zones/${zone_id}?recordType=A,AAAA")
        
        if [[ -n "${response}" ]]; then
            local records=$(echo "${response}" | jq -r '.records[] | select(.type == "A") | "\(.name):\(.content)"' 2>/dev/null)
            
            if [[ -z "${records}" ]]; then continue; fi

            while IFS=: read -r record_name record_ip; do
                if [[ "${record_ip}" != "${current_ip}" ]]; then
                    ((outdated_count+=1))
                    echo -e "  ${YELLOW}[UPDATE NEEDED]${NC} ${record_name} (${record_ip} -> ${current_ip})" >&2
                else
                    echo -e "  ${GREEN}[OK]${NC} ${record_name} (${record_ip})" >&2
                fi
                
                all_domains+=("${record_name}")
            done <<< "${records}"
        fi
    done <<< "${zones}"
    
    echo "" >&2
    
    printf '%s\n' "${all_domains[@]}" | sort -u
    echo "OUTDATED_COUNT:${outdated_count}"
}

create_dyndns_bulk() {
    local domains="$1"
    local description="IONOS DynDNS Update $(date '+%Y%m%d-%H%M%S')"
    
    log INFO "Creating DynDNS bulk update..."
    confirm_step "Create bulk update?"
    
    local domains_json=$(echo "${domains}" | jq -R . | jq -s -c .)
    local request_body=$(jq -n \
        --argjson domains "${domains_json}" \
        --arg description "${description}" \
        '{domains: $domains, description: $description}')
    
    local response=$(api_call "POST" "/dyndns" "${request_body}")
    if [[ -z "${response}" ]]; then error_exit "Failed to create bulk update"; fi
    
    echo "$(echo "${response}" | jq -r '.updateUrl' 2>/dev/null)"
}

trigger_update() {
    local update_url="$1"
    log INFO "Triggering Update URL..."
    confirm_step "Execute update?"
    
    local response_file=$(mktemp)
    local http_code=$(curl -s -w "%{http_code}" -o "${response_file}" \
        --connect-timeout "${CONNECT_TIMEOUT}" \
        --max-time "${API_TIMEOUT}" \
        -X GET "${update_url}")
    
    rm -f "${response_file}"
    
    if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
        log SUCCESS "Update triggered (HTTP ${http_code})"
        return 0
    else
        log ERROR "Update failed (HTTP ${http_code})"
        return 1
    fi
}

verify_updates() {
    local zones="$1"
    local expected_ip="$2"
    
    log INFO "--- Verifying Updates ---"
    
    local total_matched=0
    local total_mismatched=0
    
    while IFS=: read -r zone_id zone_name; do
        local response=$(api_call "GET" "/zones/${zone_id}?recordType=A,AAAA")
        
        if [[ -n "${response}" ]]; then
            local records=$(echo "${response}" | jq -r '.records[] | select(.type == "A") | "\(.name):\(.content)"' 2>/dev/null)
            
            if [[ -z "${records}" ]]; then continue; fi

            while IFS=: read -r record_name record_ip; do
                if [[ "${record_ip}" == "${expected_ip}" ]]; then
                    echo -e "  ${GREEN}✓${NC} ${record_name} → ${record_ip}" >&2
                    # FIX: Use +=1 instead of ++ to avoid exit on 0 with set -e
                    ((total_matched+=1))
                else
                    echo -e "  ${RED}✗${NC} ${record_name} → ${record_ip} ${YELLOW}(Expected: ${expected_ip})${NC}" >&2
                    ((total_mismatched+=1))
                fi
            done <<< "${records}"
        fi
    done <<< "${zones}"
    
    echo "" >&2
    if [[ ${total_mismatched} -gt 0 ]]; then
        log WARN "Verification: ${total_mismatched} records NOT updated yet."
        return 1
    else
        log SUCCESS "Verification: All ${total_matched} records match current IP."
        return 0
    fi
}

###############################################################################
# Main Execution
###############################################################################

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]
Options:
    -c, --confirm    Confirm steps
    -f, --force      Force update and notification
    -s, --setup      Configure API and Gotify
    -h, --help       Show help
EOF
}

main() {
    # Parse Args
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--confirm) CONFIRM_MODE=true; shift ;;
            -f|--force)   FORCE_MODE=true; shift ;;
            -s|--setup)   setup_config "true"; exit 0 ;;
            -h|--help)    show_usage; exit 0 ;;
            *) echo "Unknown: $1"; exit 1 ;;
        esac
    done
    
    # Init
    mkdir -p "$(dirname "${LOG_FILE}")"
    echo -e "${GREEN}--- IONOS DynDNS Updater ---${NC}" >&2
    
    setup_config
    load_api_key
    load_gotify_config
    
    # 1. Get IP
    get_public_ip
    
    # 2. Get Zones
    zones=$(fetch_zones)
    
    # 3. Check Status (And Print Verbose Output)
    result=$(process_zone_records "${zones}" "${PUBLIC_IP}")
    
    domains_list=$(echo "${result}" | grep -v "^OUTDATED_COUNT:")
    outdated_count=$(echo "${result}" | grep "^OUTDATED_COUNT:" | cut -d: -f2)
    
    if [[ -z "${domains_list}" ]]; then log INFO "No domains found."; exit 0; fi
    
    # 4. Decision
    if [[ "${outdated_count}" -eq 0 && "${FORCE_MODE}" != true ]]; then
        log SUCCESS "All records current. No update needed."
        exit 0
    fi
    
    if [[ "${FORCE_MODE}" == true ]]; then
        log WARN "Force mode active. Updating all records."
    else
        log WARN "Found ${outdated_count} outdated records. Updating..."
    fi
    
    # 5. Update
    update_url=$(create_dyndns_bulk "${domains_list}")
    
    if trigger_update "${update_url}"; then
        log INFO "Waiting 5s for propagation..."
        sleep 5
        
        # 6. Verify
        verify_updates "${zones}" "${PUBLIC_IP}"
        
        # 7. Notify
        if [[ -n "${GOTIFY_URL}" && -n "${GOTIFY_TOKEN}" ]]; then
            # Format domain list for markdown (bullet points)
            formatted_domains=$(echo "${domains_list}" | sed 's/^/* /')
            domain_count=$(echo "${domains_list}" | wc -l)
            
            msg_body="**New IP:** \`${PUBLIC_IP}\`  "
            msg_body+=$'\n'"**Mode:** $([[ "${FORCE_MODE}" == true ]] && echo "Forced" || echo "Automatic")"
            msg_body+=$'\n'"**Updated Domains:** ${domain_count}"
            msg_body+=$'\n'"${formatted_domains}"
            
            send_gotify_notification "IONOS DNS Update Success" "${msg_body}" 5
        else
            log WARN "Gotify not configured (URL or Token missing). Notification skipped."
        fi
    else
        error_exit "Update trigger failed."
    fi
}

main "$@"
