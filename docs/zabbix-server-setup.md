# Zabbix Server Configuration for Auto-Registration

This guide covers the Zabbix server-side configuration required for automatic host registration when agents connect.

**Zabbix Version:** 7.4.0
**Server Tailscale IP:** 100.122.201.5

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Create Host Groups](#2-create-host-groups)
3. [Configure Auto-Registration Action](#3-configure-auto-registration-action)
4. [Verify Firewall Settings](#4-verify-firewall-settings)
5. [Testing Auto-Registration](#5-testing-auto-registration)
6. [Troubleshooting](#6-troubleshooting)

---

## 1. Prerequisites

Before configuring auto-registration, ensure:

- [ ] You have admin access to the Zabbix web interface
- [ ] The Zabbix server is accessible via Tailscale IP (100.122.201.5)
- [ ] Ports 10050 and 10051 are open on the Zabbix server

### Verify Server Configuration

SSH into your Zabbix server and check `/etc/zabbix/zabbix_server.conf`:

```bash
# These settings should be present:
grep -E "^(StartAutoRegistration|ListenIP)" /etc/zabbix/zabbix_server.conf
```

If `StartAutoRegistration` is set to 0, change it to at least 1:

```ini
# Number of pre-forked instances of auto-registration processes
StartAutoRegistration=3
```

Restart Zabbix server after changes:
```bash
sudo systemctl restart zabbix-server
```

---

## 2. Create Host Groups

Create host groups to organize devices by type and location.

### Step-by-Step Instructions

1. **Navigate to:** Data collection → Host groups
2. **Click:** "Create host group" (top right)
3. **Create the following groups:**

| Group Name | Description |
|------------|-------------|
| `Hardware/RaspberryPi` | All Raspberry Pi devices |
| `Hardware/Radxa` | All Radxa Rock devices |
| `Hardware/MacMini` | All Mac Mini devices |
| `Tailscale Devices` | All devices on Tailscale network |
| `Auto-Registered` | Temporary group for newly registered hosts |

### Create Groups via API (Alternative)

If you prefer using the API, here's a script you can run:

```bash
# Set your Zabbix API credentials
ZABBIX_URL="http://100.122.201.5/api_jsonrpc.php"
ZABBIX_USER="Admin"
ZABBIX_PASS="your-password"

# Get auth token
AUTH_TOKEN=$(curl -s -X POST -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "user.login",
    "params": {
      "username": "'$ZABBIX_USER'",
      "password": "'$ZABBIX_PASS'"
    },
    "id": 1
  }' "$ZABBIX_URL" | jq -r '.result')

# Create host groups
for GROUP in "Hardware/RaspberryPi" "Hardware/Radxa" "Hardware/MacMini" "Tailscale Devices" "Auto-Registered"; do
  curl -s -X POST -H "Content-Type: application/json" \
    -d '{
      "jsonrpc": "2.0",
      "method": "hostgroup.create",
      "params": {
        "name": "'$GROUP'"
      },
      "auth": "'$AUTH_TOKEN'",
      "id": 1
    }' "$ZABBIX_URL"
  echo "Created group: $GROUP"
done
```

---

## 3. Configure Auto-Registration Action

This is the main configuration that tells Zabbix what to do when a new agent connects.

### Step-by-Step Instructions

#### 3.1 Navigate to Auto-Registration Actions

1. Go to: **Alerts → Actions → Autoregistration actions**
2. Click: **"Create action"** (top right)

#### 3.2 Configure the Action (Tab 1: Action)

| Field | Value |
|-------|-------|
| **Name** | `Auto-register Tailscale devices` |
| **Enabled** | ✓ (checked) |

#### 3.3 Configure Conditions (Tab 1: Conditions)

Click "Add" to add conditions. We'll use host metadata to identify our devices:

**Condition 1 - Identify Tailscale Devices:**
| Field | Value |
|-------|-------|
| Type | Host metadata |
| Operator | contains |
| Value | `tailscale-device` |

This ensures only devices with our specific metadata are auto-registered.

#### 3.4 Configure Operations (Tab 2: Operations)

Click "Add" to add operations. Add the following operations:

**Operation 1 - Add to Tailscale Devices group:**
| Field | Value |
|-------|-------|
| Operation type | Add to host group |
| Host groups | `Tailscale Devices` |

**Operation 2 - Add to Auto-Registered group:**
| Field | Value |
|-------|-------|
| Operation type | Add to host group |
| Host groups | `Auto-Registered` |

**Operation 3 - Link Linux template (for Pi and Radxa):**
| Field | Value |
|-------|-------|
| Operation type | Link to template |
| Templates | `Linux by Zabbix agent active` |
| Conditions | Host metadata contains `rpi` OR Host metadata contains `radxa` |

**Operation 4 - Link macOS template:**
| Field | Value |
|-------|-------|
| Operation type | Link to template |
| Templates | `macOS by Zabbix agent active` |
| Conditions | Host metadata contains `macos` |

**Operation 5 - Set host inventory mode:**
| Field | Value |
|-------|-------|
| Operation type | Set host inventory mode |
| Inventory mode | Automatic |

#### 3.5 Complete Configuration Screenshot Reference

Your configuration should look similar to this:

```
┌─────────────────────────────────────────────────────────────────┐
│ Action: Auto-register Tailscale devices                         │
├─────────────────────────────────────────────────────────────────┤
│ Conditions:                                                      │
│   AND                                                            │
│   ├─ Host metadata contains "tailscale-device"                  │
│                                                                  │
│ Operations:                                                      │
│   1. Add to host groups: Tailscale Devices, Auto-Registered     │
│   2. Link to templates: Linux by Zabbix agent active            │
│      (if Host metadata contains "rpi" or "radxa")               │
│   3. Link to templates: macOS by Zabbix agent active            │
│      (if Host metadata contains "macos")                        │
│   4. Set host inventory mode: Automatic                         │
└─────────────────────────────────────────────────────────────────┘
```

#### 3.6 Click "Add" to Save

---

## 3B. Alternative: Create Separate Actions per Device Type

If you want more granular control, create separate actions for each device type:

### Action 1: Auto-register Raspberry Pi

**Conditions:**
- Host metadata contains `tailscale-device`
- AND Host metadata contains `rpi`

**Operations:**
- Add to host groups: `Hardware/RaspberryPi`, `Tailscale Devices`
- Link to templates: `Linux by Zabbix agent active`
- Set host inventory mode: Automatic

### Action 2: Auto-register Radxa

**Conditions:**
- Host metadata contains `tailscale-device`
- AND Host metadata contains `radxa`

**Operations:**
- Add to host groups: `Hardware/Radxa`, `Tailscale Devices`
- Link to templates: `Linux by Zabbix agent active`
- Set host inventory mode: Automatic

### Action 3: Auto-register Mac Mini

**Conditions:**
- Host metadata contains `tailscale-device`
- AND Host metadata contains `macos`

**Operations:**
- Add to host groups: `Hardware/MacMini`, `Tailscale Devices`
- Link to templates: `macOS by Zabbix agent active`
- Set host inventory mode: Automatic

---

## 4. Verify Firewall Settings

On your Zabbix server (AWS), ensure the following ports are accessible from the Tailscale network:

### Check Current Firewall Rules

```bash
# For iptables
sudo iptables -L -n | grep -E "10050|10051"

# For firewalld
sudo firewall-cmd --list-ports

# For ufw
sudo ufw status
```

### Allow Zabbix Ports from Tailscale Network

```bash
# Using iptables
sudo iptables -A INPUT -s 100.64.0.0/10 -p tcp --dport 10050 -j ACCEPT
sudo iptables -A INPUT -s 100.64.0.0/10 -p tcp --dport 10051 -j ACCEPT

# Using firewalld
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="100.64.0.0/10" port protocol="tcp" port="10050" accept'
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="100.64.0.0/10" port protocol="tcp" port="10051" accept'
sudo firewall-cmd --reload

# Using ufw
sudo ufw allow from 100.64.0.0/10 to any port 10050
sudo ufw allow from 100.64.0.0/10 to any port 10051
```

### AWS Security Group

If your Zabbix server is on AWS, also check the EC2 Security Group:

1. Go to EC2 → Security Groups
2. Find the security group attached to your Zabbix server
3. Add inbound rules:

| Type | Protocol | Port Range | Source | Description |
|------|----------|------------|--------|-------------|
| Custom TCP | TCP | 10050 | 100.64.0.0/10 | Zabbix Agent (passive) |
| Custom TCP | TCP | 10051 | 100.64.0.0/10 | Zabbix Agent (active/trapper) |

**Note:** Tailscale IPs are in the 100.64.0.0/10 CGNAT range, but your specific Tailnet may use a subset like 100.122.x.x.

---

## 5. Testing Auto-Registration

### 5.1 Test from a Device

After installing the Zabbix agent on a device, check if it registers:

1. **On the device**, check agent logs:
   ```bash
   # Linux
   tail -f /var/log/zabbix/zabbix_agent2.log

   # macOS
   tail -f /usr/local/var/log/zabbix/zabbix_agent2.log
   ```

   Look for messages like:
   ```
   auto-registration: successfully sent host auto-registration request to server
   ```

2. **On the Zabbix server**, check the hosts:
   - Go to: **Data collection → Hosts**
   - The new host should appear within 2 minutes
   - Check that it's in the correct host groups
   - Check that templates are linked

### 5.2 Check Zabbix Server Logs

```bash
tail -f /var/log/zabbix/zabbix_server.log | grep -i autoregist
```

You should see:
```
auto-registration: host 'rpi-london-abc123' registered successfully
```

### 5.3 Verify Host Configuration

After a host registers, verify:

1. **Host groups** are assigned correctly
2. **Templates** are linked
3. **Interface** shows Tailscale IP
4. **Items** are being collected (check Latest Data)

---

## 6. Troubleshooting

### Host Not Appearing

**Check agent connectivity:**
```bash
# From the agent device, test connection to server
nc -zv 100.122.201.5 10051
# or
telnet 100.122.201.5 10051
```

**Check agent configuration:**
```bash
# Verify ServerActive is correct
grep ServerActive /etc/zabbix/zabbix_agent2.conf
# Should show: ServerActive=100.122.201.5:10051

# Verify HostMetadata is set
grep HostMetadata /etc/zabbix/zabbix_agent2.conf
# Should include: tailscale-device
```

**Check agent logs for errors:**
```bash
tail -50 /var/log/zabbix/zabbix_agent2.log
```

### Host Appears but No Templates Linked

**Check auto-registration action conditions:**
- Verify the host metadata matches the conditions
- Check if the action is enabled
- Review the action log: Alerts → Actions → Action log

**Manually verify host metadata:**
- Go to the host in Zabbix
- Check Configuration → Host inventory
- The metadata should match what's in the agent config

### Host Appears in Wrong Groups

**Check operation conditions:**
- The operation conditions might be too broad or too narrow
- Verify the host metadata contains the expected values

### Connection Refused

**Check Tailscale status:**
```bash
tailscale status
tailscale ping 100.122.201.5
```

**Check Zabbix server is listening:**
```bash
# On Zabbix server
ss -tlnp | grep -E "10050|10051"
```

### Auto-Registration Action Not Triggered

1. Check action is enabled
2. Check conditions match the host metadata exactly
3. Look at server logs for autoregistration messages
4. Verify the host doesn't already exist (auto-registration only works for new hosts)

---

## Quick Reference

### Host Metadata Format

Our installation scripts set the following metadata format:

| Device | Metadata |
|--------|----------|
| Raspberry Pi | `tailscale-device,rpi,raspberrypi,{location},arm` |
| Radxa | `tailscale-device,radxa,debian,{location},arm,{soc}` |
| Mac Mini | `tailscale-device,macmini,macos,{location},{arch}` |

### Key Configuration Files

| Component | File |
|-----------|------|
| Zabbix Server | `/etc/zabbix/zabbix_server.conf` |
| Zabbix Agent (Linux) | `/etc/zabbix/zabbix_agent2.conf` |
| Zabbix Agent (macOS) | `/usr/local/etc/zabbix/zabbix_agent2.conf` or `/opt/homebrew/etc/zabbix/zabbix_agent2.conf` |

### Important Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 10050 | TCP | Zabbix agent (passive checks) |
| 10051 | TCP | Zabbix trapper (active checks, auto-registration) |

---

## Next Steps

After completing auto-registration setup:

1. [ ] Test with one device of each type (pilot deployment)
2. [ ] Verify hosts appear in correct groups
3. [ ] Check that templates are linked
4. [ ] Verify data collection is working
5. [ ] Proceed with production rollout
