#!/bin/bash
#
# Zabbix Agent 2 Installation Script for macOS
# Supports: macOS on Apple Silicon (M1/M2/M3) and Intel
#
# This script:
# - Detects macOS version and architecture
# - Gets the device's Tailscale IP
# - Installs Zabbix Agent 2 via Homebrew
# - Configures auto-registration with Zabbix server
# - Sets up hardware-specific monitoring (temperature, power, etc.)
#
# Usage: sudo ./install-zabbix-agent-macos.sh [location]
#        sudo LOCATION=xxx bash -c "$(curl -fsSL ...)"
#
# Examples:
#   sudo ./install-zabbix-agent-macos.sh london
#   sudo LOCATION=london bash -c "$(curl -fsSL https://...)"
#   curl -fsSL https://... | sudo LOCATION=london bash
#
# Note: This script requires Homebrew to be installed.
#       If running as root, Homebrew commands will be run as the original user.
#

set -e

# =============================================================================
# CONFIGURATION - Modify these values for your environment
# =============================================================================

ZABBIX_SERVER_IP="100.122.201.5"
ZABBIX_SERVER_PORT="10051"
ZABBIX_AGENT_PORT="10050"

# Log file location
LOG_FILE="/var/log/zabbix-agent-install.log"

# Zabbix configuration directory
ZABBIX_CONF_DIR="/usr/local/etc/zabbix"
ZABBIX_CONF_FILE="${ZABBIX_CONF_DIR}/zabbix_agent2.conf"
ZABBIX_CONF_D="${ZABBIX_CONF_DIR}/zabbix_agent2.d"

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
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${timestamp} [${level}] ${message}"
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
# HOMEBREW HELPER
# =============================================================================

# Get the original user if running with sudo
get_brew_user() {
    if [[ -n "$SUDO_USER" ]]; then
        echo "$SUDO_USER"
    else
        echo "$USER"
    fi
}

# Run brew command as the appropriate user
run_brew() {
    local brew_user=$(get_brew_user)
    local brew_path=""

    # Find Homebrew path
    if [[ -f "/opt/homebrew/bin/brew" ]]; then
        brew_path="/opt/homebrew/bin/brew"
    elif [[ -f "/usr/local/bin/brew" ]]; then
        brew_path="/usr/local/bin/brew"
    else
        fatal "Homebrew not found. Please install Homebrew first: https://brew.sh"
    fi

    if [[ $EUID -eq 0 && -n "$SUDO_USER" ]]; then
        sudo -u "$brew_user" "$brew_path" "$@"
    else
        "$brew_path" "$@"
    fi
}

# Get Homebrew prefix
get_brew_prefix() {
    local brew_user=$(get_brew_user)

    if [[ -f "/opt/homebrew/bin/brew" ]]; then
        echo "/opt/homebrew"
    elif [[ -f "/usr/local/bin/brew" ]]; then
        echo "/usr/local"
    else
        echo "/usr/local"
    fi
}

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        fatal "This script must be run as root (use sudo)"
    fi
    success "Running as root"

    # Check if we have the original user
    if [[ -z "$SUDO_USER" ]]; then
        warn "SUDO_USER not set - Homebrew commands may fail"
    else
        info "Original user: $SUDO_USER"
    fi
}

check_macos() {
    if [[ "$(uname)" != "Darwin" ]]; then
        fatal "This script is for macOS only"
    fi

    # Get macOS version
    MACOS_VERSION=$(sw_vers -productVersion)
    MACOS_BUILD=$(sw_vers -buildVersion)
    MACOS_NAME=$(sw_vers -productName)

    success "Detected: $MACOS_NAME $MACOS_VERSION ($MACOS_BUILD)"

    # Check minimum version (10.15 Catalina or later recommended)
    local major_version=$(echo "$MACOS_VERSION" | cut -d. -f1)
    if [[ $major_version -lt 11 ]]; then
        local minor_version=$(echo "$MACOS_VERSION" | cut -d. -f2)
        if [[ $major_version -lt 10 ]] || [[ $major_version -eq 10 && $minor_version -lt 15 ]]; then
            warn "macOS version $MACOS_VERSION may not be fully supported"
        fi
    fi
}

check_architecture() {
    ARCH=$(uname -m)

    case "$ARCH" in
        arm64)
            ARCH_NAME="Apple Silicon"
            BREW_PREFIX="/opt/homebrew"
            ;;
        x86_64)
            ARCH_NAME="Intel"
            BREW_PREFIX="/usr/local"
            ;;
        *)
            fatal "Unsupported architecture: $ARCH"
            ;;
    esac

    success "Architecture: $ARCH ($ARCH_NAME)"
}

check_mac_model() {
    # Get Mac model information
    MAC_MODEL=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Model Name" | cut -d: -f2 | xargs)
    MAC_IDENTIFIER=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Model Identifier" | cut -d: -f2 | xargs)
    MAC_CHIP=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Chip" | cut -d: -f2 | xargs)
    MAC_SERIAL=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Serial Number" | cut -d: -f2 | xargs)

    if [[ -z "$MAC_MODEL" ]]; then
        MAC_MODEL="Unknown Mac"
    fi

    info "Model: $MAC_MODEL"
    if [[ -n "$MAC_CHIP" ]]; then
        info "Chip: $MAC_CHIP"
    fi
}

check_homebrew() {
    info "Checking for Homebrew..."

    BREW_PREFIX=$(get_brew_prefix)

    if ! run_brew --version &>/dev/null; then
        echo ""
        echo -e "${YELLOW}Homebrew is not installed.${NC}"
        echo "Homebrew is required to install Zabbix Agent 2 on macOS."
        echo ""
        echo "To install Homebrew, run:"
        echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        echo ""
        fatal "Please install Homebrew and run this script again"
    fi

    local brew_version=$(run_brew --version | head -1)
    success "Homebrew found: $brew_version"

    # Update Homebrew
    info "Updating Homebrew..."
    run_brew update --quiet || warn "Failed to update Homebrew"
}

check_disk_space() {
    local required_mb=200
    local available_mb=$(df -m / | awk 'NR==2 {print $4}')

    if [[ $available_mb -lt $required_mb ]]; then
        fatal "Insufficient disk space. Required: ${required_mb}MB, Available: ${available_mb}MB"
    fi

    success "Disk space: ${available_mb}MB available"
}

check_network() {
    info "Checking network connectivity..."

    # Check internet connectivity
    if ! ping -c 1 -W 5 github.com &>/dev/null; then
        warn "Cannot reach github.com - checking alternative..."
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

    # Check common Tailscale locations
    local tailscale_cmd=""

    if [[ -f "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]]; then
        tailscale_cmd="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    elif command -v tailscale &>/dev/null; then
        tailscale_cmd="tailscale"
    elif [[ -f "/usr/local/bin/tailscale" ]]; then
        tailscale_cmd="/usr/local/bin/tailscale"
    fi

    if [[ -z "$tailscale_cmd" ]]; then
        fatal "Tailscale is not installed. Please install Tailscale first."
    fi

    # Check if Tailscale is running
    if ! "$tailscale_cmd" status &>/dev/null; then
        fatal "Tailscale is not running or not connected. Please connect to Tailscale first."
    fi

    # Get Tailscale IP
    TAILSCALE_IP=$("$tailscale_cmd" ip -4 2>/dev/null | head -n1)

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

        # Get last 8 characters of serial number
        if [[ -n "$MAC_SERIAL" ]]; then
            serial=$(echo "$MAC_SERIAL" | tail -c 9 | tr '[:upper:]' '[:lower:]')
        fi

        # Fallback to MAC address
        if [[ -z "$serial" ]]; then
            serial=$(ifconfig en0 2>/dev/null | grep ether | awk '{print $2}' | tr -d ':' | tail -c 7)
        fi

        if [[ -z "$serial" ]]; then
            serial="unknown"
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

        ZABBIX_HOSTNAME="macmini-${LOCATION}-${serial}"
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

install_zabbix_agent() {
    info "Installing Zabbix Agent 2 via Homebrew..."

    # Check if already installed
    if run_brew list zabbix &>/dev/null; then
        warn "Zabbix is already installed via Homebrew"

        if [[ -t 0 ]]; then
            echo -e "${YELLOW}Do you want to reinstall/upgrade? (y/N):${NC}"
            read -r reinstall
            if [[ "$reinstall" == "y" || "$reinstall" == "Y" ]]; then
                info "Upgrading Zabbix..."
                run_brew upgrade zabbix || run_brew reinstall zabbix
            else
                info "Skipping installation, will reconfigure existing agent"
                return 0
            fi
        else
            info "Non-interactive mode: reconfiguring existing agent"
            return 0
        fi
    else
        # Install Zabbix
        run_brew install zabbix || fatal "Failed to install Zabbix via Homebrew"
    fi

    success "Zabbix Agent installed"

    # Get installed version
    local zabbix_version=$(run_brew info zabbix --json | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)
    info "Installed version: $zabbix_version"
}

# =============================================================================
# CONFIGURATION
# =============================================================================

configure_agent() {
    info "Configuring Zabbix Agent..."

    # Determine config paths based on Homebrew prefix
    BREW_PREFIX=$(get_brew_prefix)
    ZABBIX_CONF_DIR="${BREW_PREFIX}/etc/zabbix"
    ZABBIX_CONF_FILE="${ZABBIX_CONF_DIR}/zabbix_agentd.conf"
    ZABBIX_CONF_D="${ZABBIX_CONF_DIR}/zabbix_agentd.d"
    ZABBIX_LOG_DIR="${BREW_PREFIX}/var/log/zabbix"

    # Create directories
    mkdir -p "$ZABBIX_CONF_DIR"
    mkdir -p "$ZABBIX_CONF_D"
    mkdir -p "$ZABBIX_LOG_DIR"

    # Backup existing configuration
    if [[ -f "$ZABBIX_CONF_FILE" ]]; then
        local config_backup="${ZABBIX_CONF_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        cp "$ZABBIX_CONF_FILE" "$config_backup"
        info "Backed up existing config to: $config_backup"
    fi

    # Get location from hostname if not set
    if [[ -z "$LOCATION" ]]; then
        LOCATION=$(echo "$ZABBIX_HOSTNAME" | cut -d'-' -f2)
    fi

    # Create host metadata for auto-registration
    HOST_METADATA="tailscale-device,macmini,macos,${LOCATION},${ARCH}"

    # Write configuration
    cat > "$ZABBIX_CONF_FILE" << EOF
# Zabbix Agent 2 Configuration
# Generated by install-zabbix-agent-macos.sh
# Date: $(date '+%Y-%m-%d %H:%M:%S')
# Device: ${MAC_MODEL}
# Chip: ${MAC_CHIP:-Intel}

# =============================================================================
# GENERAL SETTINGS
# =============================================================================

# Unique hostname for this host (used in auto-registration)
Hostname=${ZABBIX_HOSTNAME}

# Host metadata for auto-registration (comma-separated tags)
# Format: tailscale-device,device-type,os-type,location,architecture
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
DenyKey=system.run[*]

# =============================================================================
# LOGGING
# =============================================================================

# Log file location
LogFile=${ZABBIX_LOG_DIR}/zabbix_agentd.log

# Log file size in MB (0 = no rotation)
LogFileSize=10

# Debug level (0-5, 3 = warnings)
DebugLevel=3

# =============================================================================
# INCLUDE ADDITIONAL CONFIGURATION
# =============================================================================

# Include platform-specific configuration
Include=${ZABBIX_CONF_D}/*.conf
EOF

    # Set proper permissions
    chmod 644 "$ZABBIX_CONF_FILE"

    success "Agent configuration written to $ZABBIX_CONF_FILE"
}

configure_macos_monitoring() {
    info "Configuring macOS specific monitoring..."

    local macos_config="${ZABBIX_CONF_D}/macos-hardware.conf"

    # Create macOS specific monitoring configuration
    cat > "$macos_config" << 'EOF'
# macOS Hardware Monitoring
# Custom UserParameters for Mac-specific metrics

# =============================================================================
# SYSTEM INFORMATION
# =============================================================================

# Mac model name
UserParameter=macos.model,system_profiler SPHardwareDataType 2>/dev/null | grep "Model Name" | cut -d: -f2 | xargs || echo "Unknown"

# Mac model identifier
UserParameter=macos.model.identifier,system_profiler SPHardwareDataType 2>/dev/null | grep "Model Identifier" | cut -d: -f2 | xargs || echo "Unknown"

# Chip/Processor
UserParameter=macos.chip,system_profiler SPHardwareDataType 2>/dev/null | grep -E "Chip|Processor Name" | head -1 | cut -d: -f2 | xargs || echo "Unknown"

# Number of CPU cores
UserParameter=macos.cpu.cores,sysctl -n hw.ncpu 2>/dev/null || echo "0"

# Total physical memory in bytes
UserParameter=macos.memory.total,sysctl -n hw.memsize 2>/dev/null || echo "0"

# macOS version
UserParameter=macos.version,sw_vers -productVersion 2>/dev/null || echo "Unknown"

# macOS build
UserParameter=macos.build,sw_vers -buildVersion 2>/dev/null || echo "Unknown"

# Serial number (may require permissions)
UserParameter=macos.serial,system_profiler SPHardwareDataType 2>/dev/null | grep "Serial Number" | cut -d: -f2 | xargs || echo "Unknown"

# =============================================================================
# CPU MONITORING
# =============================================================================

# CPU usage percentage (user + system)
UserParameter=macos.cpu.usage,top -l 1 -n 0 2>/dev/null | grep "CPU usage" | awk '{print $3+$5}' | tr -d '%' || echo "0"

# Load averages (1, 5, 15 minutes)
UserParameter=macos.load.1min,sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' || echo "0"
UserParameter=macos.load.5min,sysctl -n vm.loadavg 2>/dev/null | awk '{print $3}' || echo "0"
UserParameter=macos.load.15min,sysctl -n vm.loadavg 2>/dev/null | awk '{print $4}' || echo "0"

# =============================================================================
# MEMORY MONITORING
# =============================================================================

# Memory pressure percentage (macOS specific)
UserParameter=macos.memory.pressure,memory_pressure 2>/dev/null | grep "System-wide memory free percentage" | awk '{print 100-$5}' | tr -d '%' || echo "0"

# Page ins (memory read from disk)
UserParameter=macos.memory.pageins,vm_stat 2>/dev/null | grep "Pageins" | awk '{print $2}' | tr -d '.' || echo "0"

# Page outs (memory written to disk - indicates swapping)
UserParameter=macos.memory.pageouts,vm_stat 2>/dev/null | grep "Pageouts" | awk '{print $2}' | tr -d '.' || echo "0"

# Swap used in bytes
UserParameter=macos.swap.used,sysctl -n vm.swapusage 2>/dev/null | awk '{print $6}' | tr -d 'M' | awk '{print $1*1024*1024}' || echo "0"

# =============================================================================
# DISK MONITORING
# =============================================================================

# Root disk usage percentage
UserParameter=macos.disk.root.pused,df -h / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%' || echo "0"

# Root disk free space in bytes
UserParameter=macos.disk.root.free,df -k / 2>/dev/null | awk 'NR==2 {print $4*1024}' || echo "0"

# =============================================================================
# THERMAL MONITORING (Apple Silicon)
# =============================================================================

# CPU temperature (requires powermetrics, may need root)
# Note: This returns 0 if powermetrics is not available or no permission
UserParameter=macos.temperature.cpu,sudo powermetrics -n 1 -i 1 --samplers smc 2>/dev/null | grep "CPU die temperature" | awk '{print $4}' || echo "0"

# GPU temperature (Apple Silicon)
UserParameter=macos.temperature.gpu,sudo powermetrics -n 1 -i 1 --samplers smc 2>/dev/null | grep "GPU die temperature" | awk '{print $4}' || echo "0"

# Fan speed (if available)
UserParameter=macos.fan.speed,sudo powermetrics -n 1 -i 1 --samplers smc 2>/dev/null | grep -i "fan" | head -1 | grep -oE '[0-9]+' | head -1 || echo "0"

# =============================================================================
# POWER MONITORING
# =============================================================================

# Check if on battery or AC (1 = AC, 0 = Battery, -1 = Unknown/Desktop)
UserParameter=macos.power.source,pmset -g batt 2>/dev/null | grep -q "AC Power" && echo "1" || (pmset -g batt 2>/dev/null | grep -q "Battery" && echo "0" || echo "-1")

# Battery percentage (if applicable)
UserParameter=macos.battery.percent,pmset -g batt 2>/dev/null | grep -oE '[0-9]+%' | tr -d '%' || echo "-1"

# =============================================================================
# NETWORK MONITORING
# =============================================================================

# Primary network interface
UserParameter=macos.network.primary,route -n get default 2>/dev/null | grep interface | awk '{print $2}' || echo "unknown"

# Wi-Fi signal strength (RSSI)
UserParameter=macos.wifi.rssi,/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I 2>/dev/null | grep agrCtlRSSI | awk '{print $2}' || echo "0"

# =============================================================================
# PROCESS MONITORING
# =============================================================================

# Number of running processes
UserParameter=macos.processes.total,ps aux 2>/dev/null | wc -l | xargs || echo "0"

# Number of zombie processes
UserParameter=macos.processes.zombie,ps aux 2>/dev/null | grep -c ' Z ' || echo "0"

# Process count by name (compatible with proc.num key used by templates)
# Uses case statement to translate Linux process names to macOS equivalents:
#   - zabbix_agent2 -> zabbix_agentd (macOS uses agentd, not agent2)
#   - sshd -> sshd-session (macOS SSH process name)
#   - empty -> total process count
UserParameter=proc.num[*],case "\$1" in zabbix_agent2) pgrep -x zabbix_agentd ;; sshd) pgrep -f sshd-session ;; "") ps aux | wc -l ;; *) pgrep -x "\$1" ;; esac 2>/dev/null | wc -l | tr -d " "

# Specific critical process checks (macOS native names)
UserParameter=macos.proc.tailscaled,pgrep -x tailscaled 2>/dev/null | wc -l | xargs || echo "0"
UserParameter=macos.proc.sshd,pgrep -f sshd-session 2>/dev/null | wc -l | xargs || echo "0"
UserParameter=macos.proc.zabbix_agentd,pgrep -x zabbix_agentd 2>/dev/null | wc -l | xargs || echo "0"

# =============================================================================
# SECURITY MONITORING
# =============================================================================

# FileVault status (1 = enabled, 0 = disabled)
UserParameter=macos.filevault.status,fdesetup status 2>/dev/null | grep -q "FileVault is On" && echo "1" || echo "0"

# SIP status (1 = enabled, 0 = disabled)
UserParameter=macos.sip.status,csrutil status 2>/dev/null | grep -q "enabled" && echo "1" || echo "0"

# Firewall status (1 = enabled, 0 = disabled)
UserParameter=macos.firewall.status,/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | grep -q "enabled" && echo "1" || echo "0"

# =============================================================================
# UPTIME
# =============================================================================

# System uptime in seconds
UserParameter=macos.uptime.seconds,sysctl -n kern.boottime 2>/dev/null | awk '{print $4}' | tr -d ',' | xargs -I {} expr $(date +%s) - {} || echo "0"
EOF

    chmod 644 "$macos_config"
    success "macOS monitoring configuration created"

    # Check if powermetrics requires setup
    info "Note: Some thermal metrics require 'sudo powermetrics' which may need configuration"
}

# =============================================================================
# SERVICE MANAGEMENT
# =============================================================================

setup_log_directory() {
    info "Setting up log directory with correct permissions..."

    # Create log directory
    mkdir -p "$ZABBIX_LOG_DIR"

    # Set permissions - directory and files need to be writable by zabbix user
    chown root:wheel "$ZABBIX_LOG_DIR"
    chmod 777 "$ZABBIX_LOG_DIR"

    # Create log files with world-writable permissions (agent runs as zabbix user)
    touch "$ZABBIX_LOG_DIR/zabbix_agentd.log"
    touch "$ZABBIX_LOG_DIR/zabbix_agentd.stdout.log"
    touch "$ZABBIX_LOG_DIR/zabbix_agentd.stderr.log"
    chmod 666 "$ZABBIX_LOG_DIR/zabbix_agentd.log"
    chmod 666 "$ZABBIX_LOG_DIR/zabbix_agentd.stdout.log"
    chmod 666 "$ZABBIX_LOG_DIR/zabbix_agentd.stderr.log"

    success "Log directory configured"
}

create_launchd_plist() {
    info "Creating launchd service configuration..."

    BREW_PREFIX=$(get_brew_prefix)
    local plist_file="/Library/LaunchDaemons/com.zabbix.zabbix_agentd.plist"
    local zabbix_agent_path=""

    # Find the zabbix_agentd binary - try Cellar path first (most reliable)
    zabbix_agent_path=$(ls /opt/homebrew/Cellar/zabbix/*/sbin/zabbix_agentd 2>/dev/null | head -1)

    # Fallback to other locations
    if [[ -z "$zabbix_agent_path" ]] || [[ ! -f "$zabbix_agent_path" ]]; then
        for path in \
            "${BREW_PREFIX}/opt/zabbix/sbin/zabbix_agentd" \
            "${BREW_PREFIX}/sbin/zabbix_agentd" \
            "${BREW_PREFIX}/bin/zabbix_agentd" \
            "/usr/local/Cellar/zabbix/*/sbin/zabbix_agentd"
        do
            # Handle glob patterns
            local expanded_path=$(ls $path 2>/dev/null | head -1)
            if [[ -n "$expanded_path" ]] && [[ -f "$expanded_path" ]]; then
                zabbix_agent_path="$expanded_path"
                break
            fi
        done
    fi

    if [[ -z "$zabbix_agent_path" ]] || [[ ! -f "$zabbix_agent_path" ]]; then
        fatal "Could not find zabbix_agentd binary"
    fi

    info "Using binary: $zabbix_agent_path"

    # Remove any existing plist and unload service
    launchctl bootout system/com.zabbix.zabbix_agentd 2>/dev/null || true
    rm -f "$plist_file" 2>/dev/null

    # Create the plist file
    cat > "$plist_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.zabbix.zabbix_agentd</string>
    <key>ProgramArguments</key>
    <array>
        <string>${zabbix_agent_path}</string>
        <string>-c</string>
        <string>${ZABBIX_CONF_FILE}</string>
        <string>-f</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${ZABBIX_LOG_DIR}/zabbix_agentd.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${ZABBIX_LOG_DIR}/zabbix_agentd.stderr.log</string>
    <key>WorkingDirectory</key>
    <string>${BREW_PREFIX}/var</string>
</dict>
</plist>
EOF

    chmod 644 "$plist_file"
    chown root:wheel "$plist_file"

    success "Launchd plist created at $plist_file"
}

start_agent_service() {
    info "Starting Zabbix Agent service..."

    # Kill any existing zabbix processes
    pkill -9 zabbix_agentd 2>/dev/null || true
    sleep 1

    # Find the binary path
    local zabbix_binary=$(ls /opt/homebrew/Cellar/zabbix/*/sbin/zabbix_agentd 2>/dev/null | head -1)
    if [[ -z "$zabbix_binary" ]]; then
        zabbix_binary=$(ls /usr/local/Cellar/zabbix/*/sbin/zabbix_agentd 2>/dev/null | head -1)
    fi

    if [[ -z "$zabbix_binary" ]] || [[ ! -f "$zabbix_binary" ]]; then
        fatal "Could not find zabbix_agentd binary"
    fi

    # Start the agent directly (more reliable than launchd)
    "$zabbix_binary" -c "$ZABBIX_CONF_FILE"

    # Wait for service to start
    sleep 2

    # Check if running
    if pgrep -x zabbix_agentd > /dev/null; then
        success "Zabbix Agent service is running"
    else
        error "Zabbix Agent service failed to start"
        echo ""
        echo "Check logs at: ${ZABBIX_LOG_DIR}/zabbix_agentd.log"
        tail -10 "${ZABBIX_LOG_DIR}/zabbix_agentd.log" 2>/dev/null || true
    fi
}

# =============================================================================
# VERIFICATION
# =============================================================================

verify_installation() {
    info "Verifying installation..."

    BREW_PREFIX=$(get_brew_prefix)
    local zabbix_agent_path=""

    # Find the zabbix_agentd binary
    zabbix_agent_path=$(ls /opt/homebrew/Cellar/zabbix/*/sbin/zabbix_agentd 2>/dev/null | head -1)
    if [[ -z "$zabbix_agent_path" ]]; then
        zabbix_agent_path="${BREW_PREFIX}/sbin/zabbix_agentd"
    fi

    echo ""
    echo "============================================="
    echo "       INSTALLATION VERIFICATION"
    echo "============================================="
    echo ""

    # Check service status
    echo -n "Service Status: "
    if launchctl list | grep -q "com.zabbix.zabbix_agentd"; then
        echo -e "${GREEN}RUNNING${NC}"
    else
        echo -e "${RED}NOT RUNNING${NC}"
    fi

    # Check agent version
    echo -n "Agent Version:  "
    "$zabbix_agent_path" -V 2>/dev/null | head -1 || echo "Unable to determine"

    # Check configuration
    echo -n "Config Test:    "
    if "$zabbix_agent_path" -c "$ZABBIX_CONF_FILE" -t agent.ping &>/dev/null; then
        echo -e "${GREEN}PASSED${NC}"
    else
        echo -e "${RED}FAILED${NC}"
    fi

    # Check connectivity to server
    echo -n "Server Ping:    "
    if nc -z -w 5 "$ZABBIX_SERVER_IP" "$ZABBIX_SERVER_PORT" 2>/dev/null; then
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
    echo "Mac Model:        ${MAC_MODEL}"
    echo "Chip:             ${MAC_CHIP:-Intel}"
    echo "macOS Version:    ${MACOS_VERSION}"
    echo "Zabbix Server:    ${ZABBIX_SERVER_IP}:${ZABBIX_SERVER_PORT}"
    echo "Agent Hostname:   ${ZABBIX_HOSTNAME}"
    echo "Host Metadata:    ${HOST_METADATA}"
    echo "Tailscale IP:     ${TAILSCALE_IP}"
    echo "Listen Port:      ${ZABBIX_AGENT_PORT}"
    echo ""
    echo "Config File:      ${ZABBIX_CONF_FILE}"
    echo "Log File:         ${ZABBIX_LOG_DIR}/zabbix_agentd.log"
    echo "Install Log:      ${LOG_FILE}"
    echo ""

    # Test some items
    echo "============================================="
    echo "       ITEM TESTS"
    echo "============================================="
    echo ""
    echo -n "agent.ping:             "
    "$zabbix_agent_path" -c "$ZABBIX_CONF_FILE" -t agent.ping 2>/dev/null | tail -1 || echo "FAILED"

    echo -n "system.hostname:        "
    "$zabbix_agent_path" -c "$ZABBIX_CONF_FILE" -t system.hostname 2>/dev/null | tail -1 || echo "FAILED"

    echo -n "system.uptime:          "
    "$zabbix_agent_path" -c "$ZABBIX_CONF_FILE" -t system.uptime 2>/dev/null | tail -1 || echo "FAILED"

    echo -n "macos.model:            "
    "$zabbix_agent_path" -c "$ZABBIX_CONF_FILE" -t macos.model 2>/dev/null | tail -1 || echo "FAILED"

    echo -n "macos.cpu.cores:        "
    "$zabbix_agent_path" -c "$ZABBIX_CONF_FILE" -t macos.cpu.cores 2>/dev/null | tail -1 || echo "FAILED"

    echo -n "macos.memory.pressure:  "
    "$zabbix_agent_path" -c "$ZABBIX_CONF_FILE" -t macos.memory.pressure 2>/dev/null | tail -1 || echo "FAILED"

    echo ""
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    echo ""
    echo "============================================="
    echo "  Zabbix Agent Installer for macOS"
    echo "============================================="
    echo ""
    echo "Zabbix Server: ${ZABBIX_SERVER_IP}"
    echo ""

    # Initialize log
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "=== Installation started at $(date) ===" >> "$LOG_FILE" 2>/dev/null || true

    # Get command line arguments
    local arg_hostname="${1:-}"
    local arg_location="${2:-}"

    # Run checks
    info "Running prerequisite checks..."
    check_root
    check_macos
    check_architecture
    check_mac_model
    check_homebrew
    check_disk_space
    check_network

    # Get Tailscale IP
    get_tailscale_ip

    # Generate hostname
    generate_hostname "$arg_hostname" "$arg_location"

    # Confirm before proceeding
    echo ""
    echo -e "${YELLOW}Ready to install Zabbix Agent 2 with the following settings:${NC}"
    echo "  Model:        ${MAC_MODEL}"
    echo "  Chip:         ${MAC_CHIP:-Intel}"
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
    install_zabbix_agent

    # Configure
    configure_agent
    configure_macos_monitoring

    # Setup log directory with correct permissions
    setup_log_directory

    # Create and start service
    create_launchd_plist
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
    echo "To check agent status:  launchctl list | grep zabbix"
    echo "To view agent logs:     tail -f ${ZABBIX_LOG_DIR}/zabbix_agentd.log"
    echo "To restart agent:       sudo launchctl unload /Library/LaunchDaemons/com.zabbix.zabbix_agentd.plist && sudo launchctl load /Library/LaunchDaemons/com.zabbix.zabbix_agentd.plist"
    echo ""

    log "INFO" "Installation completed successfully"
}

# Run main function
main "$@"
