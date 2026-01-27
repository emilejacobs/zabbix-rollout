# Zabbix Rollout

Automated Zabbix agent deployment scripts and templates for monitoring distributed hardware devices over Tailscale VPN.

## Supported Platforms

- **Raspberry Pi** (Raspberry Pi OS Lite / Debian)
- **Radxa Rock** (Debian)
- **Mac Mini** (macOS, Apple Silicon)

## Quick Install

### Raspberry Pi
```bash
curl -fsSL https://raw.githubusercontent.com/emilejacobs/zabbix-rollout/main/scripts/install-zabbix-agent-raspberrypi.sh | sudo DEVICE_NAME=rpi-london-001 LOCATION=London CLIENT=Acme CHAIN=Acme ASSET_TAG=RPI-001 ZABBIX_API_TOKEN=your-token bash
```

### Radxa Rock
```bash
curl -fsSL https://raw.githubusercontent.com/emilejacobs/zabbix-rollout/main/scripts/install-zabbix-agent-radxa.sh | sudo DEVICE_NAME=radxa-london-001 LOCATION=London CLIENT=Acme CHAIN=Acme ASSET_TAG=RX-001 ZABBIX_API_TOKEN=your-token bash
```

### Mac Mini
```bash
curl -fsSL https://raw.githubusercontent.com/emilejacobs/zabbix-rollout/main/scripts/install-zabbix-agent-macos.sh | sudo DEVICE_NAME=macmini-london-001 LOCATION=London CLIENT=Acme CHAIN=Acme ASSET_TAG=MM-001 ZABBIX_API_TOKEN=your-token bash
```

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `LOCATION` | Yes | Location identifier (e.g., `London`, `"New York"`) |
| `DEVICE_NAME` | No | Custom hostname — if omitted, auto-generated from serial/MAC |
| `ZABBIX_API_TOKEN` | No | API token for setting tags and inventory (see [API setup](docs/zabbix-api-setup.md)) |
| `CLIENT` | No | Client name tag |
| `CHAIN` | No | Chain/group tag |
| `ASSET_TAG` | No | Physical asset tag identifier |
| `LATITUDE` | No | GPS latitude for Zabbix map |
| `LONGITUDE` | No | GPS longitude for Zabbix map |

Multi-word values should be quoted: `CLIENT="Burger King"`

If `ZABBIX_API_TOKEN` is not provided, the agent will still install and auto-register, but tags and inventory will not be populated.

## What the Scripts Do

1. Detect platform, OS version, and architecture
2. Verify Tailscale connectivity to Zabbix server
3. Install Zabbix Agent 2 (Homebrew on macOS, apt on Linux)
4. Configure agent for active checks via Tailscale
5. Set up platform-specific hardware monitoring (temperature, power, etc.)
6. Start the agent service
7. Wait for auto-registration with Zabbix server
8. Set host tags and populate inventory via Zabbix API

## Auto-Detected Inventory Fields

The scripts automatically detect and populate the following inventory fields via the Zabbix API:

| Field | macOS | Raspberry Pi | Radxa Rock |
|-------|-------|-------------|------------|
| OS | sw_vers | /etc/os-release | /etc/os-release |
| Model | system_profiler | /proc/device-tree/model | /proc/device-tree/model |
| Serial number | system_profiler | /proc/cpuinfo | /proc/device-tree/serial-number |
| MAC address | ifconfig en0 | /sys/class/net/eth0 | eth0/end0/enp1s0 |
| CPU/Chip | system_profiler | lscpu | lscpu + SoC type |
| Local IP | ipconfig | hostname -I | hostname -I |
| Gateway | netstat -rn | ip route | ip route |
| Subnet mask | ifconfig | ip addr | ip addr |

## Bulk Deployment

For deploying to multiple devices at once, use the orchestration script with a CSV inventory file.

### Prerequisites

```bash
brew install hudochenkov/sshpass/sshpass
```

### Inventory CSV

Export `docs/rollout-inventory.xlsx` to CSV. Required columns:

| Column | Required | Description |
|--------|----------|-------------|
| `device_name` | Yes | Hostname for the device |
| `platform` | Yes | `raspberrypi`, `radxa`, or `macos` |
| `tailscale_ip` | Yes | Tailscale VPN IP address |
| `location` | Yes | Location identifier |
| `client` | No | Client name |
| `chain` | No | Chain/group name |
| `asset_tag` | No | Physical asset tag |
| `latitude` | No | GPS latitude |
| `longitude` | No | GPS longitude |
| `ssh_user` | Yes | SSH username |
| `ssh_password` | Yes | SSH password |

### Usage

```bash
# Preview what will happen (no changes)
python3 scripts/deploy-agents.py --inventory inventory.csv --dry-run

# Test SSH connectivity to all devices
python3 scripts/deploy-agents.py --inventory inventory.csv --check

# Deploy to a single device (for testing)
ZABBIX_API_TOKEN=your-token python3 scripts/deploy-agents.py --inventory inventory.csv --device rpi-london-001

# Deploy to all devices
ZABBIX_API_TOKEN=your-token python3 scripts/deploy-agents.py --inventory inventory.csv

# Deploy only Raspberry Pi devices
ZABBIX_API_TOKEN=your-token python3 scripts/deploy-agents.py --inventory inventory.csv --platform raspberrypi

# Resume after a partial deployment (skips successful devices)
ZABBIX_API_TOKEN=your-token python3 scripts/deploy-agents.py --inventory inventory.csv --resume

# Retry only failed devices
ZABBIX_API_TOKEN=your-token python3 scripts/deploy-agents.py --inventory inventory.csv --retry-failed
```

The script uses SCP to copy install scripts to each device and execute them via SSH. Use `--github` to fetch scripts from GitHub instead. Deployment state is tracked in `rollout-state.json` for resume/retry support. Per-device logs are saved in the `logs/` directory.

## Application Service Monitoring

The install scripts automatically detect and configure monitoring for these application services:

| Service | Detection (Linux) | Detection (macOS) |
|---------|------------------|-------------------|
| Raven | `raven.service` or process | `/Applications/Raven/raven` |
| Raven Detection Server | `raven-detection-server.service` or process | `/Applications/RavenDetection/raven_detection_server.py` |
| Transcriber | `transcriber.service` or process | `/Applications/uknomi-transcriber/transcriber_cpp.py` |

For each detected service, the scripts configure:
- **Running status** — process count (alert if 0)
- **CPU usage** — percentage
- **Memory usage** — RSS in bytes
- **Uptime** — seconds since last start (detect restarts)

Hosts are tagged with `service:raven` and/or `service:transcriber` for filtering in Zabbix. Import `templates/template_app_services.yaml` and link it to hosts that run these services.

## Repository Structure

```
├── scripts/
│   ├── install-zabbix-agent-raspberrypi.sh
│   ├── install-zabbix-agent-radxa.sh
│   ├── install-zabbix-agent-macos.sh
│   └── deploy-agents.py
├── templates/
│   ├── template_process_monitoring.yaml
│   ├── template_app_services.yaml
│   ├── template_raspberry_pi.yaml
│   ├── template_radxa.yaml
│   └── template_macos.yaml
├── docs/
│   ├── rollout-inventory.xlsx
│   ├── zabbix-server-setup.md
│   ├── zabbix-api-setup.md
│   └── template-import-guide.md
└── device-inventory.csv
```

## Zabbix Server Configuration

1. Import all templates from `templates/` directory
2. Create host groups (`Hardware/RaspberryPi`, `Hardware/Radxa`, `Hardware/MacMini`, `Tailscale Devices`)
3. Configure per-device-type auto-registration actions
4. Link built-in OS templates (`Linux by Zabbix agent active`, `macOS by Zabbix agent`)
5. Create API user and token for script integration

See [docs/zabbix-server-setup.md](docs/zabbix-server-setup.md) for auto-registration setup and [docs/zabbix-api-setup.md](docs/zabbix-api-setup.md) for API token configuration.

## Templates

| Template | Platform | Description |
|----------|----------|-------------|
| Template Application Services | All | Raven, Raven Detection Server, Transcriber (CPU, memory, uptime, status) |
| Template Process Monitoring Active | All | Critical process monitoring (tailscaled, sshd, zabbix_agent2) |
| Template Hardware Raspberry Pi | Raspberry Pi | Temperature, voltage, throttling, firmware via vcgencmd |
| Template Hardware Radxa Rock | Radxa | Thermal zones, CPU/GPU frequency, SoC metrics |
| Template Hardware Mac Mini | macOS | Temperature, memory pressure, FileVault, SIP, firewall |
| Linux by Zabbix agent active | Pi / Radxa | Built-in: CPU, RAM, disk, network (linked via auto-registration) |
| macOS by Zabbix agent | Mac Mini | Built-in: CPU, RAM, disk, network (linked via auto-registration) |

## Uninstall

### Raspberry Pi / Radxa Rock
```bash
sudo systemctl stop zabbix-agent2; sudo dpkg --purge zabbix-agent2 zabbix-release; sudo rm -rf /etc/zabbix /etc/apt/sources.list.d/zabbix*.list /etc/apt/sources.list.d/zabbix*.sources; sudo apt-get autoremove -y
```

### Mac Mini
```bash
sudo pkill -9 zabbix_agentd; brew uninstall zabbix; sudo rm -rf /usr/local/etc/zabbix /opt/homebrew/etc/zabbix /Library/LaunchDaemons/com.zabbix.zabbix_agentd.plist
```

Then delete the host from Zabbix UI: Data collection → Hosts → select host → Delete.

## Requirements

- Zabbix Server 7.4+
- Tailscale VPN configured on all devices
- Devices must be able to reach Zabbix server on port 10051
- Python 3 on devices (for API integration, pre-installed on all supported platforms)
- Homebrew on macOS (for Zabbix agent installation)

## License

MIT
