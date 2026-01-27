#!/bin/bash
#
# Zabbix Agent 2 Installation Script for Radxa Rock
# Supports: Debian on Radxa Rock devices (Rock 5B, Rock 4, etc.)
# Architecture: ARM64 (aarch64)
#
# This script:
# - Detects OS version and architecture
# - Gets the device's Tailscale IP
# - Installs Zabbix Agent 2
# - Configures auto-registration with Zabbix server
# - Sets up hardware-specific monitoring (thermal zones, SoC info)
#
# Usage: sudo ./install-zabbix-agent-radxa.sh [hostname] [location]
#
# Examples:
#   sudo ./install-zabbix-agent-radxa.sh
#   sudo ./install-zabbix-agent-radxa.sh radxa-office-001 london
#

set -e

# =============================================================================
# CONFIGURATION - Modify these values for your environment
# =============================================================================

ZABBIX_SERVER_IP="100.122.201.5"
ZABBIX_SERVER_PORT="10051"
ZABBIX_AGENT_PORT="10050"
ZABBIX_VERSION="7.4"

# Log file location
LOG_FILE="/var/log/zabbix-agent-install.log"

# =============================================================================
# COLORS AND FORMATTING
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log "INFO" "$1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
    log "OK" "$1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    log "WARN" "$1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log "ERROR" "$1"
}

fatal() {
    echo -e "${RED}[FATAL]${NC} $1"
    log "FATAL" "$1"
    exit 1
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        fatal "This script must be run as root (use sudo)"
    fi
    success "Running as root"
}

check_radxa() {
    RADXA_MODEL="Unknown Radxa"

    # Check device tree model
    if [[ -f /proc/device-tree/model ]]; then
        MODEL=$(cat /proc/device-tree/model | tr -d '\0')
        if [[ "$MODEL" == *"Radxa"* ]] || [[ "$MODEL" == *"ROCK"* ]] || [[ "$MODEL" == *"Rock"* ]]; then
            RADXA_MODEL="$MODEL"
            success "Detected: $RADXA_MODEL"
            return 0
        fi
    fi

    # Check for Rockchip SoC (common in Radxa devices)
    if [[ -d /sys/class/devfreq ]] && ls /sys/class/devfreq/ 2>/dev/null | grep -q "ff9"; then
        success "Detected: Rockchip-based device (likely Radxa)"
        return 0
    fi

    # Check for common Radxa identifiers
    if grep -q -i "rockchip\|rk3" /proc/cpuinfo 2>/dev/null; then
        success "Detected: Rockchip SoC device"
        return 0
    fi

    warn "Could not confirm this is a Radxa device, continuing anyway..."
}

detect_soc() {
    # Try to detect specific Rockchip SoC
    SOC_TYPE="unknown"

    if [[ -f /proc/device-tree/compatible ]]; then
        local compatible=$(cat /proc/device-tree/compatible | tr '\0' '\n')

        if echo "$compatible" | grep -q "rk3588"; then
            SOC_TYPE="rk3588"
        elif echo "$compatible" | grep -q "rk3399"; then
            SOC_TYPE="rk3399"
        elif echo "$compatible" | grep -q "rk3568"; then
            SOC_TYPE="rk3568"
        elif echo "$compatible" | grep -q "rk3566"; then
            SOC_TYPE="rk3566"
        elif echo "$compatible" | grep -q "rk3328"; then
            SOC_TYPE="rk3328"
        fi
    fi

    info "SoC Type: $SOC_TYPE"
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        fatal "Cannot determine OS - /etc/os-release not found"
    fi

    source /etc/os-release

    OS_NAME="$NAME"
    OS_VERSION="$VERSION_ID"
    OS_CODENAME="$VERSION_CODENAME"

    info "OS: $OS_NAME $OS_VERSION ($OS_CODENAME)"

    # Validate it's Debian-based
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" && "$ID_LIKE" != *"debian"* ]]; then
        fatal "This script is for Debian-based systems. Detected: $ID"
    fi

    # Map version to Zabbix repository codename
    case "$OS_CODENAME" in
        bookworm|trixie)
            REPO_CODENAME="bookworm"
            ;;
        bullseye)
            REPO_CODENAME="bullseye"
            ;;
        buster)
            REPO_CODENAME="buster"
            ;;
        jammy)
            REPO_CODENAME="jammy"
            REPO_TYPE="ubuntu"
            ;;
        focal)
            REPO_CODENAME="focal"
            REPO_TYPE="ubuntu"
            ;;
        noble)
            REPO_CODENAME="noble"
            REPO_TYPE="ubuntu"
            ;;
        *)
            warn "Unknown OS codename: $OS_CODENAME, trying bookworm repository"
            REPO_CODENAME="bookworm"
            ;;
    esac

    # Default to Debian if not Ubuntu
    REPO_TYPE="${REPO_TYPE:-debian}"

    success "Using Zabbix repository: $REPO_TYPE/$REPO_CODENAME"
}

check_architecture() {
    ARCH=$(uname -m)

    case "$ARCH" in
        aarch64|arm64)
            ARCH_NAME="arm64"
            ;;
        armv7l|armhf)
            ARCH_NAME="armhf"
            ;;
        x86_64)
            ARCH_NAME="amd64"
            ;;
        *)
            fatal "Unsupported architecture: $ARCH"
            ;;
    esac

    success "Architecture: $ARCH ($ARCH_NAME)"
}

check_disk_space() {
    local required_mb=100
    local available_mb=$(df -m / | awk 'NR==2 {print $4}')

    if [[ $available_mb -lt $required_mb ]]; then
        fatal "Insufficient disk space. Required: ${required_mb}MB, Available: ${available_mb}MB"
    fi

    success "Disk space: ${available_mb}MB available"
}

check_network() {
    info "Checking network connectivity..."

    # Check internet connectivity
    if ! ping -c 1 -W 5 repo.zabbix.com &>/dev/null; then
        warn "Cannot reach repo.zabbix.com - checking alternative..."
        if ! ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
            fatal "No network connectivity"
        fi
    fi
    success "Internet connectivity: OK"

    # Check Tailscale connectivity to Zabbix server
    if ! ping -c 1 -W 5 "$ZABBIX_SERVER_IP" &>/dev/null; then
        warn "Cannot ping Zabbix server at $ZABBIX_SERVER_IP"
        warn "Make sure Tailscale is connected and the server is reachable"
    else
        success "Zabbix server connectivity: OK"
    fi
}

# =============================================================================
# TAILSCALE IP DETECTION
# =============================================================================

get_tailscale_ip() {
    info "Detecting Tailscale IP address..."

    # Check if Tailscale is installed
    if ! command -v tailscale &>/dev/null; then
        fatal "Tailscale is not installed. Please install Tailscale first."
    fi

    # Check if Tailscale is running
    if ! tailscale status &>/dev/null; then
        fatal "Tailscale is not running or not connected. Please connect to Tailscale first."
    fi

    # Get Tailscale IP
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null | head -n1)

    if [[ -z "$TAILSCALE_IP" ]]; then
        fatal "Could not determine Tailscale IP address"
    fi

    # Validate IP format
    if [[ ! "$TAILSCALE_IP" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "Tailscale IP doesn't match expected format (100.x.x.x): $TAILSCALE_IP"
    fi

    success "Tailscale IP: $TAILSCALE_IP"
}

# =============================================================================
# HOSTNAME GENERATION
# =============================================================================

generate_hostname() {
    local provided_hostname="$1"
    local provided_location="$2"

    if [[ -n "$provided_hostname" ]]; then
        ZABBIX_HOSTNAME="$provided_hostname"
        info "Using provided hostname: $ZABBIX_HOSTNAME"
    else
        # Generate hostname from device info
        local serial=""

        # Try to get serial from device tree
        if [[ -f /proc/device-tree/serial-number ]]; then
            serial=$(cat /proc/device-tree/serial-number | tr -d '\0' | tail -c 9)
        fi

        # Fallback to MAC address last 6 chars
        if [[ -z "$serial" || "$serial" == "0000000000000000" ]]; then
            # Try eth0, then end0, then any available interface
            for iface in eth0 end0 enp1s0; do
                if [[ -f "/sys/class/net/${iface}/address" ]]; then
                    serial=$(cat "/sys/class/net/${iface}/address" | tr -d ':' | tail -c 7)
                    break
                fi
            done
        fi

        # Final fallback
        if [[ -z "$serial" ]]; then
            serial=$(cat /sys/class/net/$(ip route show default | awk '/default/ {print $5}' | head -1)/address 2>/dev/null | tr -d ':' | tail -c 7 || echo "unknown")
        fi

        # Get location
        if [[ -n "$provided_location" ]]; then
            LOCATION="$provided_location"
        elif [[ -n "${LOCATION:-}" ]]; then
            # Use environment variable if set
            info "Using location from environment: $LOCATION"
        elif [[ -t 0 ]]; then
            # Interactive mode - prompt user
            echo ""
            echo -e "${YELLOW}Enter a location identifier for this device (e.g., london, office-1, client-abc):${NC}"
            read -r LOCATION
            if [[ -z "$LOCATION" ]]; then
                LOCATION="default"
            fi
        else
            # Non-interactive mode - use default
            LOCATION="default"
            warn "Non-interactive mode: using default location. Set LOCATION env var for custom location."
        fi

        # Sanitize location (lowercase, replace spaces with dashes)
        LOCATION=$(echo "$LOCATION" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')

        ZABBIX_HOSTNAME="radxa-${LOCATION}-${serial}"
        info "Generated hostname: $ZABBIX_HOSTNAME"
    fi

    # Validate hostname length (max 128 chars for Zabbix)
    if [[ ${#ZABBIX_HOSTNAME} -gt 128 ]]; then
        ZABBIX_HOSTNAME="${ZABBIX_HOSTNAME:0:128}"
        warn "Hostname truncated to 128 characters"
    fi

    success "Zabbix hostname: $ZABBIX_HOSTNAME"
}

# =============================================================================
# ZABBIX AGENT INSTALLATION
# =============================================================================

install_zabbix_repository() {
    info "Adding Zabbix repository..."

    # Determine repository URL based on OS type
    local repo_url="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/${REPO_TYPE}/${REPO_CODENAME}/pool/main/z/zabbix-release/zabbix-release_latest_all.deb"
    local repo_deb="/tmp/zabbix-release.deb"

    info "Downloading from: $repo_url"

    if ! wget -q "$repo_url" -O "$repo_deb" 2>/dev/null; then
        # Try alternative URL structure
        repo_url="https://repo.zabbix.com/zabbix/${ZABBIX_VERSION}/${REPO_TYPE}/pool/main/z/zabbix-release/zabbix-release_latest+${REPO_TYPE}${OS_VERSION}_all.deb"
        info "Trying alternative URL: $repo_url"

        if ! wget -q "$repo_url" -O "$repo_deb"; then
            fatal "Failed to download Zabbix repository package"
        fi
    fi

    # Install repository package
    dpkg -i "$repo_deb" || fatal "Failed to install Zabbix repository package"
    rm -f "$repo_deb"

    # Update package lists
    info "Updating package lists..."
    apt-get update -qq || fatal "Failed to update package lists"

    success "Zabbix repository added"
}

install_zabbix_agent() {
    info "Installing Zabbix Agent 2..."

    # Check if already installed
    if dpkg -l | grep -q "zabbix-agent2"; then
        warn "Zabbix Agent 2 is already installed"

        if [[ -t 0 ]]; then
            echo -e "${YELLOW}Do you want to reinstall/upgrade? (y/N):${NC}"
            read -r reinstall
            if [[ "$reinstall" != "y" && "$reinstall" != "Y" ]]; then
                info "Skipping installation, will reconfigure existing agent"
                return 0
            fi
        else
            info "Non-interactive mode: reconfiguring existing agent"
            return 0
        fi
    fi

    # Install agent
    apt-get install -y zabbix-agent2 zabbix-agent2-plugin-* || {
        warn "Failed to install plugins, trying agent only..."
        apt-get install -y zabbix-agent2 || fatal "Failed to install Zabbix Agent 2"
    }

    success "Zabbix Agent 2 installed"
}

# =============================================================================
# CONFIGURATION
# =============================================================================

configure_agent() {
    info "Configuring Zabbix Agent 2..."

    local config_file="/etc/zabbix/zabbix_agent2.conf"
    local config_backup="/etc/zabbix/zabbix_agent2.conf.backup.$(date +%Y%m%d%H%M%S)"

    # Backup existing configuration
    if [[ -f "$config_file" ]]; then
        cp "$config_file" "$config_backup"
        info "Backed up existing config to: $config_backup"
    fi

    # Get location from hostname if not set
    if [[ -z "$LOCATION" ]]; then
        LOCATION=$(echo "$ZABBIX_HOSTNAME" | cut -d'-' -f2)
    fi

    # Create host metadata for auto-registration
    HOST_METADATA="tailscale-device,radxa,debian,${LOCATION},arm,${SOC_TYPE}"

    # Write configuration
    cat > "$config_file" << EOF
# Zabbix Agent 2 Configuration
# Generated by install-zabbix-agent-radxa.sh
# Date: $(date '+%Y-%m-%d %H:%M:%S')
# Device: ${RADXA_MODEL}
# SoC: ${SOC_TYPE}

# =============================================================================
# GENERAL SETTINGS
# =============================================================================

# Unique hostname for this host (used in auto-registration)
Hostname=${ZABBIX_HOSTNAME}

# Host metadata for auto-registration (comma-separated tags)
# Format: tailscale-device,device-type,os-type,location,architecture,soc
HostMetadata=${HOST_METADATA}

# =============================================================================
# SERVER CONNECTION
# =============================================================================

# Zabbix server IP (for passive checks)
Server=${ZABBIX_SERVER_IP}

# Zabbix server IP:port for active checks and auto-registration
ServerActive=${ZABBIX_SERVER_IP}:${ZABBIX_SERVER_PORT}

# =============================================================================
# NETWORK SETTINGS
# =============================================================================

# Listen on all interfaces (required for Tailscale)
ListenIP=0.0.0.0

# Agent listen port
ListenPort=${ZABBIX_AGENT_PORT}

# Source IP for outgoing connections (use Tailscale IP)
SourceIP=${TAILSCALE_IP}

# =============================================================================
# PERFORMANCE TUNING
# =============================================================================

# How often to refresh list of active checks (seconds)
RefreshActiveChecks=120

# Buffer size for collected values
BufferSize=100

# Timeout for processing requests (seconds)
# Higher value needed for process enumeration
Timeout=30

# =============================================================================
# SECURITY
# =============================================================================

# Disable remote commands (security best practice)
EnableRemoteCommands=0
LogRemoteCommands=0

# =============================================================================
# LOGGING
# =============================================================================

# Log file location
LogFile=/var/log/zabbix/zabbix_agent2.log

# Log file size in MB (0 = no rotation)
LogFileSize=10

# Debug level (0-5, 3 = warnings)
DebugLevel=3

# =============================================================================
# PLUGINS
# =============================================================================

# Disable remote commands in SystemRun plugin
Plugins.SystemRun.LogRemoteCommands=0

# =============================================================================
# INCLUDE ADDITIONAL CONFIGURATION
# =============================================================================

# Include platform-specific configuration
Include=/etc/zabbix/zabbix_agent2.d/*.conf
EOF

    success "Agent configuration written to $config_file"
}

configure_radxa_monitoring() {
    info "Configuring Radxa/Rockchip specific monitoring..."

    local radxa_config="/etc/zabbix/zabbix_agent2.d/radxa-hardware.conf"

    # Create config directory if needed
    mkdir -p /etc/zabbix/zabbix_agent2.d

    # Detect thermal zones
    local thermal_zones=()
    for zone in /sys/class/thermal/thermal_zone*/type; do
        if [[ -f "$zone" ]]; then
            local zone_dir=$(dirname "$zone")
            local zone_name=$(cat "$zone")
            local zone_num=$(basename "$zone_dir" | grep -oP '\d+')
            thermal_zones+=("$zone_num:$zone_name")
        fi
    done

    info "Found ${#thermal_zones[@]} thermal zones"

    # Create Radxa/Rockchip specific monitoring configuration
    cat > "$radxa_config" << 'EOF'
# Radxa/Rockchip Hardware Monitoring
# Custom UserParameters for SoC metrics

# =============================================================================
# THERMAL MONITORING
# =============================================================================

# Generic thermal zone temperature reader (in millidegrees, divide by 1000 for Celsius)
# Usage: radxa.thermal[zone_number]
UserParameter=radxa.thermal[*],cat /sys/class/thermal/thermal_zone$1/temp 2>/dev/null || echo "0"

# CPU thermal zone (usually zone 0 or soc-thermal)
UserParameter=radxa.cpu.temperature,cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f", $1/1000}' || echo "0"

# GPU thermal zone (if available)
UserParameter=radxa.gpu.temperature,for z in /sys/class/thermal/thermal_zone*/type; do if grep -q gpu "$z" 2>/dev/null; then cat "$(dirname $z)/temp" 2>/dev/null | awk '{printf "%.1f", $1/1000}'; exit; fi; done; echo "0"

# List all thermal zones with their types
UserParameter=radxa.thermal.zones,for z in /sys/class/thermal/thermal_zone*/type; do echo "$(basename $(dirname $z)):$(cat $z 2>/dev/null)"; done | tr '\n' ',' | sed 's/,$//'

# =============================================================================
# CPU FREQUENCY MONITORING
# =============================================================================

# Current CPU frequency (in kHz)
UserParameter=radxa.cpu.freq.current,cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo "0"

# Maximum CPU frequency (in kHz)
UserParameter=radxa.cpu.freq.max,cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null || echo "0"

# Minimum CPU frequency (in kHz)
UserParameter=radxa.cpu.freq.min,cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq 2>/dev/null || echo "0"

# CPU governor
UserParameter=radxa.cpu.governor,cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown"

# =============================================================================
# GPU FREQUENCY MONITORING (if available)
# =============================================================================

# GPU frequency (Rockchip Mali)
UserParameter=radxa.gpu.freq.current,cat /sys/class/devfreq/fb000000.gpu/cur_freq 2>/dev/null || cat /sys/class/devfreq/*.gpu/cur_freq 2>/dev/null | head -1 || echo "0"

# GPU load (if available)
UserParameter=radxa.gpu.load,cat /sys/class/devfreq/fb000000.gpu/load 2>/dev/null || cat /sys/class/devfreq/*.gpu/load 2>/dev/null | head -1 || echo "0"

# =============================================================================
# MEMORY MONITORING
# =============================================================================

# NPU frequency (RK3588 specific)
UserParameter=radxa.npu.freq,cat /sys/class/devfreq/fdab0000.npu/cur_freq 2>/dev/null || echo "0"

# DDR frequency
UserParameter=radxa.ddr.freq,cat /sys/class/devfreq/dmc/cur_freq 2>/dev/null || cat /sys/class/devfreq/*.dmc/cur_freq 2>/dev/null | head -1 || echo "0"

# =============================================================================
# SYSTEM INFORMATION
# =============================================================================

# Device model
UserParameter=radxa.model,cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || echo "Unknown"

# SoC compatible string
UserParameter=radxa.soc,cat /proc/device-tree/compatible 2>/dev/null | tr '\0' ',' | sed 's/,$//' || echo "Unknown"

# Kernel version
UserParameter=radxa.kernel,uname -r

# =============================================================================
# POWER MONITORING (if available)
# =============================================================================

# VDD CPU voltage (if available via IIO)
UserParameter=radxa.voltage.cpu,cat /sys/bus/iio/devices/iio:device0/in_voltage0_raw 2>/dev/null || echo "0"
EOF

    success "Radxa monitoring configuration created"

    # Display detected thermal zones
    if [[ ${#thermal_zones[@]} -gt 0 ]]; then
        info "Detected thermal zones:"
        for tz in "${thermal_zones[@]}"; do
            echo "  - $tz"
        done
    fi
}

# =============================================================================
# SERVICE MANAGEMENT
# =============================================================================

start_agent_service() {
    info "Starting Zabbix Agent 2 service..."

    # Reload systemd
    systemctl daemon-reload

    # Enable service to start on boot
    systemctl enable zabbix-agent2 || warn "Failed to enable service"

    # Stop service if running
    systemctl stop zabbix-agent2 2>/dev/null || true

    # Start service
    systemctl start zabbix-agent2 || fatal "Failed to start Zabbix Agent 2 service"

    # Wait for service to start
    sleep 2

    # Check service status
    if systemctl is-active --quiet zabbix-agent2; then
        success "Zabbix Agent 2 service is running"
    else
        error "Zabbix Agent 2 service failed to start"
        echo ""
        echo "Service status:"
        systemctl status zabbix-agent2 --no-pager
        echo ""
        echo "Recent logs:"
        journalctl -u zabbix-agent2 -n 20 --no-pager
        fatal "Service startup failed"
    fi
}

# =============================================================================
# VERIFICATION
# =============================================================================

verify_installation() {
    info "Verifying installation..."

    echo ""
    echo "============================================="
    echo "       INSTALLATION VERIFICATION"
    echo "============================================="
    echo ""

    # Check service status
    echo -n "Service Status: "
    if systemctl is-active --quiet zabbix-agent2; then
        echo -e "${GREEN}RUNNING${NC}"
    else
        echo -e "${RED}NOT RUNNING${NC}"
    fi

    # Check agent version
    echo -n "Agent Version:  "
    zabbix_agent2 -V 2>/dev/null | head -1 || echo "Unable to determine"

    # Check configuration
    echo -n "Config Test:    "
    if zabbix_agent2 -t agent.ping &>/dev/null; then
        echo -e "${GREEN}PASSED${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi

    # Check connectivity to server
    echo -n "Server Ping:    "
    if timeout 5 bash -c "echo > /dev/tcp/${ZABBIX_SERVER_IP}/${ZABBIX_SERVER_PORT}" 2>/dev/null; then
        echo -e "${GREEN}OK (port ${ZABBIX_SERVER_PORT} reachable)${NC}"
    else
        echo -e "${YELLOW}CANNOT CONNECT (port ${ZABBIX_SERVER_PORT})${NC}"
    fi

    # Display configuration summary
    echo ""
    echo "============================================="
    echo "       CONFIGURATION SUMMARY"
    echo "============================================="
    echo ""
    echo "Device Model:     ${RADXA_MODEL}"
    echo "SoC Type:         ${SOC_TYPE}"
    echo "Zabbix Server:    ${ZABBIX_SERVER_IP}:${ZABBIX_SERVER_PORT}"
    echo "Agent Hostname:   ${ZABBIX_HOSTNAME}"
    echo "Host Metadata:    ${HOST_METADATA}"
    echo "Tailscale IP:     ${TAILSCALE_IP}"
    echo "Listen Port:      ${ZABBIX_AGENT_PORT}"
    echo ""
    echo "Config File:      /etc/zabbix/zabbix_agent2.conf"
    echo "Log File:         /var/log/zabbix/zabbix_agent2.log"
    echo "Install Log:      ${LOG_FILE}"
    echo ""

    # Test some items
    echo "============================================="
    echo "       ITEM TESTS"
    echo "============================================="
    echo ""
    echo -n "agent.ping:              "
    zabbix_agent2 -t agent.ping 2>/dev/null | tail -1 || echo "FAILED"

    echo -n "system.hostname:         "
    zabbix_agent2 -t system.hostname 2>/dev/null | tail -1 || echo "FAILED"

    echo -n "system.uptime:           "
    zabbix_agent2 -t system.uptime 2>/dev/null | tail -1 || echo "FAILED"

    echo -n "radxa.cpu.temperature:   "
    zabbix_agent2 -t radxa.cpu.temperature 2>/dev/null | tail -1 || echo "FAILED"

    echo -n "radxa.cpu.freq.current:  "
    zabbix_agent2 -t radxa.cpu.freq.current 2>/dev/null | tail -1 || echo "FAILED"

    echo -n "radxa.model:             "
    zabbix_agent2 -t radxa.model 2>/dev/null | tail -1 || echo "FAILED"

    echo ""
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    echo ""
    echo "============================================="
    echo "  Zabbix Agent 2 Installer for Radxa Rock"
    echo "============================================="
    echo ""
    echo "Zabbix Server: ${ZABBIX_SERVER_IP}"
    echo "Zabbix Version: ${ZABBIX_VERSION}"
    echo ""

    # Initialize log
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== Installation started at $(date) ===" >> "$LOG_FILE"

    # Get command line arguments
    local arg_hostname="${1:-}"
    local arg_location="${2:-}"

    # Run checks
    info "Running prerequisite checks..."
    check_root
    check_radxa
    detect_soc
    check_os
    check_architecture
    check_disk_space
    check_network

    # Get Tailscale IP
    get_tailscale_ip

    # Generate hostname
    generate_hostname "$arg_hostname" "$arg_location"

    # Confirm before proceeding
    echo ""
    echo -e "${YELLOW}Ready to install Zabbix Agent 2 with the following settings:${NC}"
    echo "  Device:       ${RADXA_MODEL}"
    echo "  SoC:          ${SOC_TYPE}"
    echo "  Hostname:     ${ZABBIX_HOSTNAME}"
    echo "  Tailscale IP: ${TAILSCALE_IP}"
    echo "  Server:       ${ZABBIX_SERVER_IP}"
    echo ""
    if [[ -t 0 ]]; then
        echo -e "${YELLOW}Continue with installation? (Y/n):${NC}"
        read -r confirm
        if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
            info "Installation cancelled by user"
            exit 0
        fi
    else
        info "Non-interactive mode: proceeding with installation"
    fi


    # Install Zabbix
    install_zabbix_repository
    install_zabbix_agent

    # Configure
    configure_agent
    configure_radxa_monitoring

    # Start service
    start_agent_service

    # Verify
    verify_installation

    echo ""
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}  INSTALLATION COMPLETE${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo ""
    echo "The agent should auto-register with the Zabbix server within 2 minutes."
    echo "Check your Zabbix server's Configuration → Hosts to verify registration."
    echo ""
    echo "To check agent status:  systemctl status zabbix-agent2"
    echo "To view agent logs:     tail -f /var/log/zabbix/zabbix_agent2.log"
    echo ""

    log "INFO" "Installation completed successfully"
}

# Run main function
main "$@"
