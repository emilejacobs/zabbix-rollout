# Zabbix Rollout

Automated Zabbix agent deployment scripts and templates for monitoring distributed hardware devices over Tailscale VPN.

## Supported Platforms

- **Raspberry Pi** (Raspberry Pi OS Lite)
- **Radxa Rock** (Debian)
- **Mac Mini** (macOS, Apple Silicon)

## Quick Install

### Raspberry Pi
```bash
curl -fsSL https://raw.githubusercontent.com/emilejacobs/zabbix-rollout/main/scripts/install-zabbix-agent-raspberrypi.sh | sudo bash
```

### Radxa Rock
```bash
curl -fsSL https://raw.githubusercontent.com/emilejacobs/zabbix-rollout/main/scripts/install-zabbix-agent-radxa.sh | sudo bash
```

### Mac Mini
```bash
curl -fsSL https://raw.githubusercontent.com/emilejacobs/zabbix-rollout/main/scripts/install-zabbix-agent-macos.sh | bash
```

## Repository Structure

```
├── scripts/
│   ├── install-zabbix-agent-raspberrypi.sh
│   ├── install-zabbix-agent-radxa.sh
│   └── install-zabbix-agent-macos.sh
├── templates/
│   ├── template_process_monitoring.yaml
│   ├── template_raspberry_pi.yaml
│   ├── template_radxa.yaml
│   └── template_macos.yaml
├── docs/
│   ├── zabbix-server-setup.md
│   └── template-import-guide.md
└── device-inventory.csv
```

## Zabbix Server Configuration

1. Import all templates from `templates/` directory
2. Create host groups for auto-registration
3. Configure auto-registration action

See [docs/zabbix-server-setup.md](docs/zabbix-server-setup.md) for detailed instructions.

## Templates

| Template | Platform | Items | Triggers |
|----------|----------|-------|----------|
| Template Process Monitoring Active | All | 4 | 4 |
| Template Hardware Raspberry Pi | Raspberry Pi | 11 | 4 |
| Template Hardware Radxa Rock | Radxa | 12 | 3 |
| Template Hardware Mac Mini | macOS | 17 | 9 |

## Requirements

- Zabbix Server 7.4+
- Tailscale VPN configured on all devices
- Devices must be able to reach Zabbix server on port 10051

## License

MIT
