# Zabbix Template Import Guide

This guide explains how to import and configure the custom monitoring templates.

---

## Templates Overview

| Template | Purpose | Target Devices |
|----------|---------|----------------|
| `Template Process Monitoring Active` | Auto-discover and monitor all processes | All devices |
| `Template Hardware Raspberry Pi` | Pi-specific metrics (temp, voltage, throttling) | 31 Raspberry Pis |
| `Template Hardware Radxa Rock` | Radxa-specific metrics (thermal, freq, NPU) | 2 Radxa devices |
| `Template Hardware Mac Mini` | macOS-specific metrics (memory pressure, security) | 3 Mac Minis |

---

## Step 1: Create Template Group

Before importing, create the template group:

1. Go to: **Data collection → Template groups**
2. Click: **Create template group**
3. Name: `Templates/Custom`
4. Click: **Add**

---

## Step 2: Import Templates

### Import via Web Interface

1. Go to: **Data collection → Templates**
2. Click: **Import** (top right)
3. Click: **Choose file** and select the template YAML file
4. Configure import options:

   | Option | Setting |
   |--------|---------|
   | Template groups | ✓ Create new |
   | Templates | ✓ Create new, ✓ Update existing |
   | Items | ✓ Create new, ✓ Update existing |
   | Triggers | ✓ Create new, ✓ Update existing |
   | Discovery rules | ✓ Create new, ✓ Update existing |
   | Value maps | ✓ Create new, ✓ Update existing |

5. Click: **Import**

### Import Order

Import in this order to ensure dependencies are met:

1. `template_process_monitoring.yaml` (base template for all devices)
2. `template_raspberry_pi.yaml`
3. `template_radxa.yaml`
4. `template_macos.yaml`

### Import via API (Alternative)

```bash
# Set credentials
ZABBIX_URL="http://100.122.201.5/api_jsonrpc.php"
ZABBIX_USER="Admin"
ZABBIX_PASS="your-password"

# Get auth token
AUTH_TOKEN=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "user.login",
    "params": {"username": "'$ZABBIX_USER'", "password": "'$ZABBIX_PASS'"},
    "id": 1
  }' "$ZABBIX_URL" | jq -r '.result')

# Import template
TEMPLATE_FILE="template_process_monitoring.yaml"
TEMPLATE_CONTENT=$(cat "$TEMPLATE_FILE" | jq -Rs .)

curl -s -X POST -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "configuration.import",
    "params": {
      "format": "yaml",
      "source": '"$TEMPLATE_CONTENT"',
      "rules": {
        "template_groups": {"createMissing": true},
        "templates": {"createMissing": true, "updateExisting": true},
        "items": {"createMissing": true, "updateExisting": true},
        "triggers": {"createMissing": true, "updateExisting": true},
        "discoveryRules": {"createMissing": true, "updateExisting": true},
        "valueMaps": {"createMissing": true, "updateExisting": true}
      }
    },
    "auth": "'$AUTH_TOKEN'",
    "id": 1
  }' "$ZABBIX_URL"
```

---

## Step 3: Link Templates to Auto-Registration

Update your auto-registration action to link the appropriate templates.

### Option A: Update Existing Action

1. Go to: **Alerts → Actions → Autoregistration actions**
2. Edit: `Auto-register Tailscale devices`
3. Add new operations:

**For Raspberry Pi devices:**
| Field | Value |
|-------|-------|
| Operation type | Link to template |
| Templates | `Template Process Monitoring Active`, `Template Hardware Raspberry Pi` |
| Conditions | Host metadata contains `rpi` |

**For Radxa devices:**
| Field | Value |
|-------|-------|
| Operation type | Link to template |
| Templates | `Template Process Monitoring Active`, `Template Hardware Radxa Rock` |
| Conditions | Host metadata contains `radxa` |

**For Mac Mini devices:**
| Field | Value |
|-------|-------|
| Operation type | Link to template |
| Templates | `Template Process Monitoring Active`, `Template Hardware Mac Mini` |
| Conditions | Host metadata contains `macos` |

### Option B: Separate Actions Per Device Type

Create three separate auto-registration actions with specific template links.

---

## Step 4: Verify Template Import

After importing, verify the templates:

1. Go to: **Data collection → Templates**
2. Search for: `Template Process Monitoring`
3. Click on the template name
4. Verify:
   - Items are listed (Static items + Discovery rule)
   - Triggers are listed
   - Discovery rules are listed

---

## Template Details

### Template Process Monitoring Active

**Discovery Rule: Process Discovery**
- Key: `proc.get[,,,process]`
- Interval: 1 hour
- Filters out kernel threads and system processes
- Creates items for each discovered process:
  - Process count (`proc.num[{#PROC.NAME}]`)
  - Memory usage RSS (`proc.mem[{#PROC.NAME},,,,rss]`)
  - CPU utilization (`proc.cpu.util[{#PROC.NAME}]`)

**Static Items (Critical Services):**
| Item | Key | Interval |
|------|-----|----------|
| Tailscale daemon | `proc.num[tailscaled]` | 30s |
| SSH daemon | `proc.num[sshd]` | 30s |
| Zabbix agent | `proc.num[zabbix_agent2]` | 30s |
| Total processes | `proc.num[]` | 1m |

**Triggers:**
| Name | Severity | Condition |
|------|----------|-----------|
| Tailscale daemon not running | DISASTER | `proc.num[tailscaled]=0` |
| SSH daemon not running | HIGH | `proc.num[sshd]=0` |
| Zabbix agent not running | HIGH | `proc.num[zabbix_agent2]=0` |
| High process count | WARNING | `proc.num[]>500` |

### Template Hardware Raspberry Pi

**Items:**
| Item | Key | Description |
|------|-----|-------------|
| CPU temperature | `rpi.cpu.temperature` | From vcgencmd |
| GPU temperature | `rpi.gpu.temperature` | From vcgencmd |
| Core voltage | `rpi.voltage.core` | CPU core voltage |
| Throttling status | `rpi.throttled` | Throttling flags |
| ARM clock | `rpi.clock.arm` | CPU frequency |
| Model | `rpi.model` | Device model |

**Triggers:**
| Name | Severity | Condition |
|------|----------|-----------|
| High CPU temperature | HIGH | >80°C |
| Critical CPU temperature | DISASTER | >85°C |
| Throttling detected | WARNING | Not 0x0 |
| Low core voltage | WARNING | <1.15V |

### Template Hardware Radxa Rock

**Items:**
| Item | Key | Description |
|------|-----|-------------|
| CPU temperature | `radxa.cpu.temperature` | From thermal zone |
| GPU temperature | `radxa.gpu.temperature` | From thermal zone |
| CPU frequency | `radxa.cpu.freq.current` | Current frequency |
| GPU frequency | `radxa.gpu.freq.current` | Mali GPU frequency |
| NPU frequency | `radxa.npu.freq` | RK3588 only |
| CPU governor | `radxa.cpu.governor` | Scaling governor |
| Device model | `radxa.model` | From device tree |

**Triggers:**
| Name | Severity | Condition |
|------|----------|-----------|
| High CPU temperature | HIGH | >80°C |
| Critical CPU temperature | DISASTER | >90°C |
| High GPU temperature | HIGH | >85°C |

### Template Hardware Mac Mini

**Items:**
| Item | Key | Description |
|------|-----|-------------|
| Model name | `macos.model` | Mac model |
| Chip | `macos.chip` | Apple Silicon/Intel |
| CPU usage | `macos.cpu.usage` | CPU percentage |
| Memory pressure | `macos.memory.pressure` | macOS specific |
| Disk usage | `macos.disk.root.pused` | Root filesystem |
| FileVault status | `macos.filevault.status` | Encryption status |
| SIP status | `macos.sip.status` | Security status |

**Triggers:**
| Name | Severity | Condition |
|------|----------|-----------|
| High CPU usage | WARNING | >90% for 5m |
| High memory pressure | WARNING | >80% |
| Critical memory pressure | HIGH | >95% |
| Low disk space | WARNING | >90% used |
| FileVault disabled | WARNING | Status = 0 |
| SIP disabled | HIGH | Status = 0 |

---

## Step 5: Link Templates to Existing Hosts

For hosts that already exist (not auto-registered), manually link templates:

1. Go to: **Data collection → Hosts**
2. Click on a host
3. Go to: **Templates** tab
4. Click: **Link new templates**
5. Select: Appropriate templates
6. Click: **Update**

---

## Troubleshooting

### Items Show "Not Supported"

1. Check the UserParameter is defined in the agent config
2. Test manually on the device:
   ```bash
   zabbix_agent2 -t rpi.cpu.temperature
   ```
3. Check agent logs for errors

### Discovery Not Finding Processes

1. Verify `proc.get` item is working:
   ```bash
   zabbix_agent2 -t 'proc.get[,,,process]'
   ```
2. Check the Timeout setting (should be 30 or higher)
3. Review preprocessing JavaScript filter

### Template Import Fails

1. Ensure template group exists
2. Check YAML syntax is valid
3. Verify Zabbix version compatibility (7.0+)
4. Check for duplicate UUIDs if re-importing

---

## Next Steps

After importing templates:

1. [ ] Verify templates appear in Data collection → Templates
2. [ ] Update auto-registration action to link templates
3. [ ] Test on pilot devices
4. [ ] Verify data collection in Latest Data
5. [ ] Check triggers are working correctly
