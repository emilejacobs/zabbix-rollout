# Zabbix API Setup for Automated Deployment

This guide covers setting up the Zabbix API and creating an API token for use with the automated installation scripts. The scripts use the API to set host tags and populate inventory fields after agent registration.

**Zabbix Version:** 7.4.0
**Server Tailscale IP:** 100.122.201.5

---

## Table of Contents

1. [Overview](#1-overview)
2. [Verify API Access](#2-verify-api-access)
3. [Create a Dedicated API User](#3-create-a-dedicated-api-user)
4. [Create an API Token](#4-create-an-api-token)
5. [Test the API Token](#5-test-the-api-token)
6. [Update Auto-Registration Actions](#6-update-auto-registration-actions)
7. [API Reference for Install Scripts](#7-api-reference-for-install-scripts)
8. [Troubleshooting](#8-troubleshooting)

---

## 1. Overview

The Zabbix API is **enabled by default** — it is built into the Zabbix web frontend and requires no additional installation. The API endpoint is:

```
https://100.122.201.5/api_jsonrpc.php
```

The install scripts will use the API to:
- Look up the newly registered host by hostname
- Add tags to the host (client, chain, location, device-type)
- Set inventory mode to manual
- Populate inventory fields (OS, MAC address, serial number, location, asset tag, coordinates, network info)

### Authentication Methods

Zabbix 7.4 supports two API authentication methods:

| Method | Description | Best For |
|--------|-------------|----------|
| **API Token** | Long-lived token tied to a user | Automation scripts (recommended) |
| **Session Login** | Username/password, returns session ID | Interactive/ad-hoc use |

We will use an **API token** since it avoids exposing credentials in scripts and can be revoked independently.

---

## 2. Verify API Access

Before creating tokens, verify the API is reachable.

### From your local machine (or any Tailscale device):

```bash
curl -s -X POST -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "apiinfo.version",
    "params": [],
    "id": 1
  }' "https://100.122.201.5/api_jsonrpc.php" | python3 -m json.tool
```

**Expected response:**
```json
{
    "jsonrpc": "2.0",
    "result": "7.4.0",
    "id": 1
}
```

If you get a connection error, check:
- Zabbix web frontend is running (`systemctl status apache2` or `systemctl status nginx`)
- Port 80/443 is open on the AWS security group for Tailscale IPs (100.64.0.0/10)
- Tailscale is connected (`tailscale status`)

---

## 3. Create a Dedicated API User

It is best practice to create a dedicated user for API automation rather than using the Admin account. This limits permissions and makes it easy to revoke access.

### 3.1 Create a User Role (optional but recommended)

1. Navigate to: **Users → User roles**
2. Click: **Create user role**
3. Configure:

| Field | Value |
|-------|-------|
| **Name** | `API Deployment Role` |
| **User type** | Admin |

4. Under **API access**, ensure the following API methods are allowed:
   - `host.get`
   - `host.update`
   - `hostgroup.get`
   - `template.get`

   Alternatively, leave API access as **All** if you prefer simplicity.

5. Click **Add** to save.

### 3.2 Create a User Group

1. Navigate to: **Users → User groups**
2. Click: **Create user group**
3. Configure:

| Field | Value |
|-------|-------|
| **Group name** | `API Automation` |
| **Frontend access** | Disabled |

4. Go to the **Host permissions** tab:
   - Click **Select** next to host groups
   - Add **all host groups** that your devices belong to:
     - `Hardware/RaspberryPi`
     - `Hardware/Radxa`
     - `Hardware/MacMini`
     - `Tailscale Devices`
     - `Auto-Registered`
   - Set permission level: **Read-write**

5. Click **Add** to save.

### 3.3 Create the API User

1. Navigate to: **Users → Users**
2. Click: **Create user**
3. Configure the **User** tab:

| Field | Value |
|-------|-------|
| **Username** | `api-deploy` |
| **Groups** | `API Automation` |
| **Role** | `API Deployment Role` (or `Admin role` if you skipped 3.1) |
| **Password** | Set a strong password (it won't be used directly, but is required) |

4. No media configuration is needed for this user.
5. Click **Add** to save.

---

## 4. Create an API Token

### 4.1 Create the Token in Zabbix UI

1. Navigate to: **Users → API tokens**
2. Click: **Create API token**
3. Configure:

| Field | Value |
|-------|-------|
| **Name** | `deployment-scripts` |
| **User** | `api-deploy` |
| **Set expiration date and time** | Optional — uncheck for no expiry, or set to a future date |
| **Enabled** | Checked |

4. Click **Add**
5. **IMPORTANT:** The token is displayed **only once** after creation. Copy it immediately and store it securely.

The token will look something like:
```
b0a37c3f8e7d4a5c9f1234567890abcdef1234567890abcdef1234567890abcd
```

### 4.2 Store the Token Securely

Store the token somewhere secure. Options:
- Password manager (recommended)
- Environment variable on your deployment machine
- Encrypted secrets file

**Do NOT:**
- Commit the token to the git repository
- Store it in plaintext on shared systems
- Include it in documentation

---

## 5. Test the API Token

### 5.1 Basic connectivity test

```bash
export ZABBIX_API_TOKEN="your-token-here"

curl -s -X POST -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ZABBIX_API_TOKEN}" \
  -d '{
    "jsonrpc": "2.0",
    "method": "host.get",
    "params": {
      "output": ["hostid", "host", "name"],
      "limit": 5
    },
    "id": 1
  }' "https://100.122.201.5/api_jsonrpc.php" | python3 -m json.tool
```

**Expected response:** A list of hosts (or empty array if none exist yet).

### 5.2 Test tag assignment (on an existing host)

If you already have a registered host, test adding tags:

```bash
# First, get the host ID
HOST_ID=$(curl -s -X POST -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ZABBIX_API_TOKEN}" \
  -d '{
    "jsonrpc": "2.0",
    "method": "host.get",
    "params": {
      "output": ["hostid"],
      "filter": {"host": ["your-hostname-here"]}
    },
    "id": 1
  }' "https://100.122.201.5/api_jsonrpc.php" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['hostid'])")

echo "Host ID: $HOST_ID"

# Add tags to the host
curl -s -X POST -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ZABBIX_API_TOKEN}" \
  -d '{
    "jsonrpc": "2.0",
    "method": "host.update",
    "params": {
      "hostid": "'$HOST_ID'",
      "tags": [
        {"tag": "client", "value": "test-client"},
        {"tag": "chain", "value": "test-chain"},
        {"tag": "device-type", "value": "mac-mini"},
        {"tag": "location", "value": "london"}
      ]
    },
    "id": 1
  }' "https://100.122.201.5/api_jsonrpc.php" | python3 -m json.tool
```

**Expected response:**
```json
{
    "jsonrpc": "2.0",
    "result": {
        "hostids": ["10001"]
    },
    "id": 1
}
```

### 5.3 Test inventory population

```bash
curl -s -X POST -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ZABBIX_API_TOKEN}" \
  -d '{
    "jsonrpc": "2.0",
    "method": "host.update",
    "params": {
      "hostid": "'$HOST_ID'",
      "inventory_mode": 1,
      "inventory": {
        "os": "macOS 15.2",
        "location": "London Office",
        "macaddress_a": "aa:bb:cc:dd:ee:ff",
        "asset_tag": "MM-001",
        "location_lat": "51.5074",
        "location_lon": "-0.1278",
        "type": "Mac Mini",
        "model": "Apple Mac Mini M2",
        "serialno_a": "C02ABC123DEF",
        "host_networks": "192.168.1.0/24",
        "host_router": "192.168.1.1",
        "host_subnet": "255.255.255.0"
      }
    },
    "id": 1
  }' "https://100.122.201.5/api_jsonrpc.php" | python3 -m json.tool
```

**Expected response:**
```json
{
    "jsonrpc": "2.0",
    "result": {
        "hostids": ["10001"]
    },
    "id": 1
}
```

Verify in Zabbix UI: Go to **Data collection → Hosts → (host) → Inventory** to confirm fields are populated.

---

## 6. Update Auto-Registration Actions

The auto-registration actions need to assign the correct host groups per device type. Use separate actions for each device type (Section 3B in the server setup guide).

### 6.1 Delete or Disable the Existing Generic Action

If you created the single generic action from the server setup guide, disable it in favour of per-device-type actions.

### 6.2 Create Per-Device-Type Actions

Go to: **Alerts → Actions → Autoregistration actions**

#### Action 1: Auto-register Raspberry Pi

**Action tab:**
| Field | Value |
|-------|-------|
| Name | `Auto-register Raspberry Pi` |
| Conditions | Host metadata contains `rpi` |

**Operations tab — add all of the following:**

| # | Operation | Target |
|---|-----------|--------|
| 1 | Add to host group | `Hardware/RaspberryPi` |
| 2 | Add to host group | `Tailscale Devices` |
| 3 | Link to template | `Template Hardware Raspberry Pi` |
| 4 | Link to template | `Template Process Monitoring Active` |
| 5 | Link to template | `Linux by Zabbix agent active` |
| 6 | Set host inventory mode | Automatic |

#### Action 2: Auto-register Radxa Rock

**Action tab:**
| Field | Value |
|-------|-------|
| Name | `Auto-register Radxa Rock` |
| Conditions | Host metadata contains `radxa` |

**Operations tab:**

| # | Operation | Target |
|---|-----------|--------|
| 1 | Add to host group | `Hardware/Radxa` |
| 2 | Add to host group | `Tailscale Devices` |
| 3 | Link to template | `Template Hardware Radxa Rock` |
| 4 | Link to template | `Template Process Monitoring Active` |
| 5 | Link to template | `Linux by Zabbix agent active` |
| 6 | Set host inventory mode | Automatic |

#### Action 3: Auto-register Mac Mini

**Action tab:**
| Field | Value |
|-------|-------|
| Name | `Auto-register Mac Mini` |
| Conditions | Host metadata contains `macos` |

**Operations tab:**

| # | Operation | Target |
|---|-----------|--------|
| 1 | Add to host group | `Hardware/MacMini` |
| 2 | Add to host group | `Tailscale Devices` |
| 3 | Link to template | `Template Hardware Mac Mini` |
| 4 | Link to template | `Template Process Monitoring Active` |
| 5 | Link to template | `macOS by Zabbix agent active` |
| 6 | Set host inventory mode | Automatic |

---

## 7. API Reference for Install Scripts

### How the Scripts Will Use the API

After installing and starting the Zabbix agent, each script will:

```
1. Wait for auto-registration (retry loop checking if host exists via API)
2. Get the host ID by hostname
3. Update host tags (client, chain, location, device-type)
4. Update host inventory with auto-detected + provided values
```

### Inventory Fields Used

| Zabbix Field | API Key | Source |
|-------------|---------|--------|
| Type | `type` | Script (device type: Raspberry Pi / Radxa / Mac Mini) |
| OS | `os` | Auto-detected |
| Model | `model` | Auto-detected |
| Serial number A | `serialno_a` | Auto-detected |
| MAC address A | `macaddress_a` | Auto-detected (primary interface) |
| Asset tag | `asset_tag` | `ASSET_TAG` env variable |
| Location | `location` | `LOCATION` env variable |
| Location latitude | `location_lat` | `LATITUDE` env variable |
| Location longitude | `location_lon` | `LONGITUDE` env variable |
| Host networks | `host_networks` | Auto-detected (local network CIDR) |
| Host router | `host_router` | Auto-detected (default gateway) |
| Host subnet mask | `host_subnet` | Auto-detected |
| Notes | `notes` | Tailscale IP + hostname |

### Tags Set by Scripts

| Tag | Source |
|-----|--------|
| `client` | `CLIENT` env variable |
| `chain` | `CHAIN` env variable |
| `location` | `LOCATION` env variable |
| `device-type` | Auto-detected (raspberry-pi / radxa / mac-mini) |
| `os` | Auto-detected (e.g., raspbian / debian / macos) |

### Script Invocation

```bash
# Example: Mac Mini
curl -fsSL https://raw.githubusercontent.com/.../install-zabbix-agent-macos.sh | sudo \
  LOCATION=london \
  CLIENT=acme-corp \
  CHAIN=uk-south \
  ASSET_TAG=MM-001 \
  LATITUDE=51.5074 \
  LONGITUDE=-0.1278 \
  ZABBIX_API_TOKEN=your-token-here \
  bash
```

### Required vs Optional Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `LOCATION` | Yes | Location identifier for hostname |
| `ZABBIX_API_TOKEN` | No* | API token for tags/inventory |
| `CLIENT` | No | Client name tag |
| `CHAIN` | No | Chain/group tag |
| `ASSET_TAG` | No | Physical asset tag identifier |
| `LATITUDE` | No | GPS latitude for map |
| `LONGITUDE` | No | GPS longitude for map |

*If `ZABBIX_API_TOKEN` is not provided, the script will skip API calls. The agent will still install and auto-register, but tags and inventory will not be populated.

---

## 8. Troubleshooting

### "No permissions" error

The API user does not have read-write access to the required host groups.

**Fix:** Go to Users → User groups → API Automation → Host permissions, and ensure all relevant host groups have Read-write permission.

### "No API access" error

The user role does not allow API access.

**Fix:** Go to Users → User roles → (role) → API access, and ensure it is not restricted.

### "Invalid parameter" on inventory update

Not all inventory field names are obvious. Common field names:

| UI Label | API Parameter |
|----------|--------------|
| Type | `type` |
| Name | `name` |
| OS | `os` |
| Serial number A | `serialno_a` |
| Serial number B | `serialno_b` |
| Tag | `tag` |
| Asset tag | `asset_tag` |
| MAC address A | `macaddress_a` |
| MAC address B | `macaddress_b` |
| Hardware | `hardware` |
| Software | `software` |
| Model | `model` |
| Location | `location` |
| Location latitude | `location_lat` |
| Location longitude | `location_lon` |
| Host networks | `host_networks` |
| Host subnet mask | `host_subnet` |
| Host router | `host_router` |
| OOB IP address | `oob_ip` |
| Notes | `notes` |
| Alias | `alias` |

### Host not found after registration

The script may query the API before auto-registration completes. The scripts include a retry loop (up to 60 seconds) to handle this timing issue.

### Token expired

If you set an expiry date on the token, create a new one:
1. Go to Users → API tokens
2. Create a new token
3. Update the token in your deployment process

---

## Checklist

Complete these steps before running the updated install scripts:

- [ ] Verify API is accessible (Section 2)
- [ ] Create API user role (Section 3.1)
- [ ] Create API user group with host permissions (Section 3.2)
- [ ] Create API user (Section 3.3)
- [ ] Generate API token and store securely (Section 4)
- [ ] Test API token (Section 5)
- [ ] Update auto-registration actions to per-device-type (Section 6)
- [ ] Disable old generic auto-registration action if it exists (Section 6.1)
