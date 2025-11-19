#!/bin/bash

###############################################################################
# IONOS DynDNS Updater Script
# 
# This script automatically updates DNS A records for all zones and subdomains
# in your IONOS account with your current public IP address.
###############################################################################

set -euo pipefail

# Configuration
readonly API_KEY_FILE="${HOME}/.config/ionos-dyndns/api_key"
readonly LOG_FILE="${HOME}/.config/ionos-dyndns/dyndns.log"
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
    
    # Log to stderr with colors (to avoid capture in command substitution)
    case "${level}" in
        INFO)
            echo -e "${BLUE}[INFO]${NC} ${message}" >&2
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS]${NC} ${message}" >&2
            ;;
        WARN)
            echo -e "${YELLOW}[WARN]${NC} ${message}" >&2
            ;;
        ERROR)
            echo -e "${RED}[ERROR]${NC} ${message}" >&2
            ;;
        *)
            echo "[${level}] ${message}" >&2
            ;;
    esac
}

###############################################################################
# Error Handling
###############################################################################

error_exit() {
    log ERROR "$1"
    exit 1
}

###############################################################################
# Confirmation Function
###############################################################################

confirm_step() {
    if [[ "${CONFIRM_MODE}" == true ]]; then
        echo -e "${YELLOW}[CONFIRM]${NC} $1" >&2
        # Read from /dev/tty to avoid stdin conflicts with while loops
        read -p "Continue? [y/N] " -n 1 -r </dev/tty
        echo >&2
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log WARN "Step cancelled by user"
            exit 0
        fi
    fi
}

###############################################################################
# API Key Management
###############################################################################

setup_api_key() {
    local force_update="${1:-false}"
    local config_dir=$(dirname "${API_KEY_FILE}")
    
    # Create config directory if it doesn't exist
    if [[ ! -d "${config_dir}" ]]; then
        mkdir -p "${config_dir}"
        chmod 700 "${config_dir}"
        log INFO "Created config directory: ${config_dir}"
    fi
    
    # Check if API key file exists
    if [[ ! -f "${API_KEY_FILE}" ]]; then
        echo -e "${YELLOW}API key not found.${NC}" >&2
        read -p "Please enter your IONOS API key: " -r api_key </dev/tty
        echo "${api_key}" > "${API_KEY_FILE}"
        chmod 600 "${API_KEY_FILE}"
        log SUCCESS "API key saved securely to ${API_KEY_FILE}"
    elif [[ "${force_update}" == "true" ]]; then
        echo -e "${YELLOW}Updating API key...${NC}" >&2
        echo -e "Current key file: ${API_KEY_FILE}" >&2
        read -p "Please enter your new IONOS API key: " -r api_key </dev/tty
        echo "${api_key}" > "${API_KEY_FILE}"
        chmod 600 "${API_KEY_FILE}"
        log SUCCESS "API key updated successfully"
    else
        # Verify permissions
        local perms=$(stat -c %a "${API_KEY_FILE}" 2>/dev/null || stat -f %A "${API_KEY_FILE}" 2>/dev/null)
        if [[ "${perms}" != "600" ]]; then
            log WARN "API key file has insecure permissions. Fixing..."
            chmod 600 "${API_KEY_FILE}"
        fi
    fi
}

load_api_key() {
    if [[ ! -f "${API_KEY_FILE}" ]]; then
        error_exit "API key file not found. Please run setup first."
    fi
    
    API_KEY=$(cat "${API_KEY_FILE}")
    if [[ -z "${API_KEY}" ]]; then
        error_exit "API key is empty"
    fi
}

###############################################################################
# API Functions
###############################################################################

api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    
    local url="${BASE_URL}${endpoint}"
    local response_file=$(mktemp)
    local http_code
    
    log INFO "API Call: ${method} ${endpoint}"
    
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
# Main Functions
###############################################################################

get_public_ip() {
    log INFO "================================================"
    log INFO "FETCHING PUBLIC IP ADDRESS"
    log INFO "================================================"
    log INFO "Querying: ${IP_CHECK_URL}"
    
    confirm_step "Fetch public IP from ${IP_CHECK_URL}?"
    
    local ip=$(curl -s --connect-timeout "${CONNECT_TIMEOUT}" --max-time "${API_TIMEOUT}" "${IP_CHECK_URL}")
    
    if [[ -z "${ip}" ]]; then
        error_exit "Failed to fetch public IP address from ${IP_CHECK_URL}"
    fi
    
    # Validate IP format (basic IPv4 check)
    if [[ ! "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        error_exit "Invalid IP address format received: ${ip}"
    fi
    
    log SUCCESS "Current Public IP: ${ip}"
    log INFO "================================================"
    echo "" >&2
    echo "${ip}"
}

fetch_zones() {
    log INFO "================================================"
    log INFO "FETCHING DNS ZONES"
    log INFO "================================================"
    
    confirm_step "Fetch zones from IONOS API?"
    
    local response=$(api_call "GET" "/zones")
    
    if [[ -z "${response}" ]]; then
        error_exit "Failed to fetch zones - empty response"
    fi
    
    # Extract zone IDs and names
    local zones=$(echo "${response}" | jq -r '.[] | "\(.id):\(.name)"' 2>/dev/null)
    
    if [[ -z "${zones}" ]]; then
        error_exit "No zones found or failed to parse response"
    fi
    
    local zone_count=$(echo "${zones}" | wc -l)
    log SUCCESS "Found ${zone_count} zone(s):"
    
    local counter=1
    while IFS=: read -r zone_id zone_name; do
        echo -e "  ${BLUE}${counter}.${NC} ${zone_name} ${YELLOW}(${zone_id})${NC}" >&2
        ((counter++))
    done <<< "${zones}"
    
    log INFO "================================================"
    echo "" >&2
    echo "${zones}"
}

fetch_zone_records() {
    local zone_id="$1"
    local zone_name="$2"
    local current_ip="$3"
    
    log INFO "Fetching records for zone: ${zone_name} (${zone_id})"
    confirm_step "Fetch records for zone ${zone_name}?"
    
    local response=$(api_call "GET" "/zones/${zone_id}?recordType=A,AAAA")
    
    if [[ -z "${response}" ]]; then
        log ERROR "Failed to fetch records for zone ${zone_name}"
        return 1
    fi
    
    # Extract all A records with their current IPs
    local records=$(echo "${response}" | jq -r '.records[] | select(.type == "A") | "\(.name):\(.content)"' 2>/dev/null)
    
    if [[ -z "${records}" ]]; then
        log WARN "No A records found for zone ${zone_name}"
        return 0
    fi
    
    local record_count=$(echo "${records}" | wc -l)
    log SUCCESS "Found ${record_count} A record(s) in ${zone_name}"
    
    # Display each record with status
    # Return format: name:ip:status (where status is "current" or "outdated")
    while IFS=: read -r record_name record_ip; do
        local fqdn="${record_name}"
        
        # Check if IP needs updating
        if [[ "${record_ip}" == "${current_ip}" ]]; then
            echo -e "  ${GREEN}✓${NC} ${fqdn} → ${record_ip} ${GREEN}(current)${NC}" >&2
            echo "${fqdn}:${record_ip}:current"
        else
            echo -e "  ${YELLOW}⚠${NC} ${fqdn} → ${record_ip} ${YELLOW}(needs update to ${current_ip})${NC}" >&2
            echo "${fqdn}:${record_ip}:outdated"
        fi
    done <<< "${records}"
}

build_domain_list() {
    local zones="$1"
    local current_ip="$2"
    local all_domains=()
    local outdated_count=0
    local current_count=0
    
    echo "" >&2
    log INFO "================================================"
    log INFO "DISCOVERED DOMAINS AND UPDATE STATUS"
    log INFO "================================================"
    
    while IFS=: read -r zone_id zone_name; do
        local records=$(fetch_zone_records "${zone_id}" "${zone_name}" "${current_ip}")
        
        if [[ -n "${records}" ]]; then
            while IFS=: read -r record_name record_ip status; do
                all_domains+=("${record_name}")
                
                if [[ "${status}" == "outdated" ]]; then
                    ((outdated_count++))
                elif [[ "${status}" == "current" ]]; then
                    ((current_count++))
                fi
            done <<< "${records}"
        fi
        echo "" >&2
    done <<< "${zones}"
    
    log INFO "================================================"
    log INFO "Domain Status Summary:"
    log INFO "  Current:  ${current_count}"
    log INFO "  Outdated: ${outdated_count}"
    log INFO "  Total:    $((current_count + outdated_count))"
    log INFO "================================================"
    
    # Return domains and outdated count (separated by a marker)
    printf '%s\n' "${all_domains[@]}" | sort -u
    echo "OUTDATED_COUNT:${outdated_count}"
}

create_dyndns_bulk() {
    local domains="$1"
    local description="IONOS DynDNS Update $(date '+%Y%m%d-%H%M%S')"
    
    log INFO "================================================"
    log INFO "CREATING DYNDNS BULK UPDATE"
    log INFO "================================================"
    
    local domain_count=$(echo "${domains}" | wc -l)
    log INFO "Preparing bulk update for ${domain_count} domain(s)"
    log INFO "Description: ${description}"
    
    confirm_step "Create DynDNS bulk update for ${domain_count} domain(s)?"
    
    # Build JSON array
    local domains_json=$(echo "${domains}" | jq -R . | jq -s -c .)
    local request_body=$(jq -n \
        --argjson domains "${domains_json}" \
        --arg description "${description}" \
        '{domains: $domains, description: $description}')
    
    log INFO "Sending request to IONOS API..."
    
    local response=$(api_call "POST" "/dyndns" "${request_body}")
    
    if [[ -z "${response}" ]]; then
        error_exit "Failed to create DynDNS bulk update"
    fi
    
    local bulk_id=$(echo "${response}" | jq -r '.bulkId' 2>/dev/null)
    local update_url=$(echo "${response}" | jq -r '.updateUrl' 2>/dev/null)
    
    if [[ -z "${bulk_id}" || -z "${update_url}" ]]; then
        error_exit "Failed to parse DynDNS response: ${response}"
    fi
    
    log SUCCESS "DynDNS bulk created successfully!"
    log INFO "Bulk ID: ${bulk_id}"
    log INFO "Update URL: ${update_url}"
    log INFO "================================================"
    echo "" >&2
    
    echo "${update_url}"
}

trigger_update() {
    local update_url="$1"
    
    log INFO "================================================"
    log INFO "TRIGGERING DNS UPDATE"
    log INFO "================================================"
    log INFO "Update URL: ${update_url}"
    
    confirm_step "Execute DNS update via the generated URL?"
    
    log INFO "Sending GET request to update URL..."
    
    local response_file=$(mktemp)
    local http_code=$(curl -s -w "%{http_code}" -o "${response_file}" \
        --connect-timeout "${CONNECT_TIMEOUT}" \
        --max-time "${API_TIMEOUT}" \
        -X GET "${update_url}")
    local response=$(cat "${response_file}")
    rm -f "${response_file}"
    
    if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
        log SUCCESS "DNS update triggered successfully! (HTTP ${http_code})"
        if [[ -n "${response}" ]]; then
            log INFO "API Response: ${response}"
        fi
        log INFO "================================================"
        echo "" >&2
        return 0
    else
        log ERROR "DNS update failed with HTTP ${http_code}"
        log ERROR "Response: ${response}"
        return 1
    fi
}

verify_updates() {
    local zones="$1"
    local expected_ip="$2"
    
    log INFO "================================================"
    log INFO "VERIFYING DNS UPDATES"
    log INFO "================================================"
    log INFO "Expected IP: ${expected_ip}"
    
    confirm_step "Verify that all records were updated with IP ${expected_ip}?"
    
    local total_checked=0
    local total_matched=0
    local total_mismatched=0
    
    echo "" >&2
    while IFS=: read -r zone_id zone_name; do
        log INFO "Checking zone: ${zone_name}"
        
        local response=$(api_call "GET" "/zones/${zone_id}?recordType=A,AAAA")
        
        if [[ -z "${response}" ]]; then
            log WARN "Could not fetch records for verification: ${zone_name}"
            continue
        fi
        
        # Check each A record
        local records=$(echo "${response}" | jq -r '.records[] | select(.type == "A") | "\(.name):\(.content)"' 2>/dev/null)
        
        while IFS=: read -r record_name record_ip; do
            ((total_checked++))
            
            # The name field from IONOS API is already a FQDN
            local fqdn="${record_name}"
            
            if [[ "${record_ip}" == "${expected_ip}" ]]; then
                echo -e "  ${GREEN}✓${NC} ${fqdn} → ${record_ip}" >&2
                ((total_matched++))
            else
                echo -e "  ${RED}✗${NC} ${fqdn} → ${record_ip} ${YELLOW}(expected: ${expected_ip})${NC}" >&2
                ((total_mismatched++))
            fi
        done <<< "${records}"
        
    done <<< "${zones}"
    
    echo "" >&2
    log INFO "================================================"
    log INFO "VERIFICATION SUMMARY"
    log INFO "================================================"
    log INFO "Total records checked: ${total_checked}"
    if [[ ${total_matched} -gt 0 ]]; then
        echo -e "${GREEN}[SUCCESS]${NC} Matched expected IP: ${total_matched}" >&2
    fi
    if [[ ${total_mismatched} -gt 0 ]]; then
        echo -e "${RED}[WARN]${NC} Mismatched: ${total_mismatched}" >&2
        log WARN "Some records do not match the expected IP."
        log WARN "This may be due to DNS propagation delay or partial update."
    fi
    log INFO "================================================"
    echo "" >&2
}

###############################################################################
# Main Execution
###############################################################################

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    -c, --confirm       Run with confirmation prompts for each step
    -f, --force         Force update even if all records are current
    -h, --help          Show this help message
    -s, --setup         Setup or update API key
    
Examples:
    $0                  Run full update automatically (only if needed)
    $0 --confirm        Run with confirmation for each step
    $0 --force          Force update regardless of current state
    $0 --setup          Setup/update API key

Description:
    This script checks your current public IP against all DNS A records
    in your IONOS zones. It only triggers an update if at least one record
    is outdated, unless --force is specified.
    
    Ideal for cron jobs: */2 * * * * /path/to/ionos.sh

EOF
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--confirm)
                CONFIRM_MODE=true
                shift
                ;;
            -f|--force)
                FORCE_MODE=true
                shift
                ;;
            -s|--setup)
                setup_api_key "true"
                exit 0
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Initialize
    echo "" >&2
    echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${GREEN}║     IONOS DynDNS Updater Script Started        ║${NC}" >&2
    echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}" >&2
    echo "" >&2
    log INFO "Mode: $([ "${CONFIRM_MODE}" = true ] && echo "Confirmation (Testing)" || echo "Automatic")"
    log INFO "Force: $([ "${FORCE_MODE}" = true ] && echo "Yes" || echo "No")"
    log INFO "Date: $(date '+%Y-%m-%d %H:%M:%S')"
    log INFO "Log file: ${LOG_FILE}"
    echo "" >&2
    
    # Setup API key if needed
    setup_api_key
    load_api_key
    
    # Step 1: Get public IP
    public_ip=$(get_public_ip)
    
    # Step 2: Fetch all zones
    zones=$(fetch_zones)
    
    # Step 3: Build complete domain list from all zones
    result=$(build_domain_list "${zones}" "${public_ip}")
    
    # Extract domains and outdated count
    domains=$(echo "${result}" | grep -v "^OUTDATED_COUNT:")
    outdated_count=$(echo "${result}" | grep "^OUTDATED_COUNT:" | cut -d: -f2)
    
    if [[ -z "${domains}" ]]; then
        error_exit "No domains found to update"
    fi
    
    local domain_count=$(echo "${domains}" | wc -l)
    log SUCCESS "Total domains found: ${domain_count}"
    
    echo "" >&2
    
    # Decision logic: Should we proceed with the update?
    if [[ "${outdated_count}" -eq 0 && "${FORCE_MODE}" != true ]]; then
        log SUCCESS "================================================"
        log SUCCESS "✓ ALL RECORDS ARE CURRENT!"
        log SUCCESS "================================================"
        log INFO "All ${domain_count} domain(s) already point to IP: ${public_ip}"
        log INFO "No update necessary. Use --force to update anyway."
        log SUCCESS "================================================"
        exit 0
    fi
    
    if [[ "${outdated_count}" -eq 0 && "${FORCE_MODE}" == true ]]; then
        log WARN "All records are current, but --force flag is set"
        log INFO "Proceeding with update anyway..."
        echo "" >&2
    elif [[ "${outdated_count}" -gt 0 ]]; then
        log WARN "Found ${outdated_count} outdated record(s)"
        log INFO "Proceeding with update..."
        echo "" >&2
    fi
    
    log INFO "================================================"
    log INFO "DOMAINS TO BE UPDATED"
    log INFO "================================================"
    local counter=1
    while IFS= read -r domain; do
        echo -e "  ${BLUE}${counter}.${NC} ${domain}" >&2
        ((counter++))
    done <<< "${domains}"
    log INFO "================================================"
    echo "" >&2
    
    # Summary before action
    local zone_count=$(echo "${zones}" | wc -l)
    echo -e "${YELLOW}┌────────────────────────────────────────────────┐${NC}" >&2
    echo -e "${YELLOW}│              UPDATE SUMMARY                    │${NC}" >&2
    echo -e "${YELLOW}├────────────────────────────────────────────────┤${NC}" >&2
    echo -e "${YELLOW}│${NC} Current IP:      ${GREEN}${public_ip}${NC}$(printf '%*s' $((30 - ${#public_ip})) '')${YELLOW}│${NC}" >&2
    echo -e "${YELLOW}│${NC} Zones:           ${zone_count}$(printf '%*s' $((31 - ${#zone_count})) '')${YELLOW}│${NC}" >&2
    echo -e "${YELLOW}│${NC} Domains:         ${domain_count}$(printf '%*s' $((31 - ${#domain_count})) '')${YELLOW}│${NC}" >&2
    echo -e "${YELLOW}│${NC} Outdated:        ${outdated_count}$(printf '%*s' $((31 - ${#outdated_count})) '')${YELLOW}│${NC}" >&2
    echo -e "${YELLOW}└────────────────────────────────────────────────┘${NC}" >&2
    echo "" >&2
    
    # Step 4: Create DynDNS bulk update
    update_url=$(create_dyndns_bulk "${domains}")
    
    # Step 5: Trigger the update
    if ! trigger_update "${update_url}"; then
        error_exit "Failed to trigger DynDNS update"
    fi
    
    # Wait a moment for the update to process
    log INFO "Waiting 5 seconds for DNS update to propagate..."
    sleep 5
    
    # Step 6: Verify updates
    verify_updates "${zones}" "${public_ip}"
    
    log SUCCESS "================================================"
    log SUCCESS "✓ DYNDNS UPDATE COMPLETED SUCCESSFULLY!"
    log SUCCESS "================================================"
    log INFO "All ${domain_count} domain(s) have been updated to IP: ${public_ip}"
    log INFO "Script execution time: $SECONDS seconds"
    log SUCCESS "================================================"
}

# Ensure log directory exists
mkdir -p "$(dirname "${LOG_FILE}")"

# Run main function
main "$@"