# Zabbix Monitoring Deployment Plan

## Executive Summary

This document outlines the comprehensive plan for deploying Zabbix monitoring across distributed hardware infrastructure connected via Tailscale VPN. The deployment will enable centralized monitoring, auto-registration of new devices, comprehensive service monitoring, and Microsoft Teams integration for alerting.

---

## 0. Gathered Requirements

### Infrastructure Details
| Item | Value |
|------|-------|
| **Zabbix Server Tailscale IP** | 100.122.201.5 |
| **Zabbix Version** | 7.4.0 |
| **Total Devices** | 36 |

### Hardware Inventory
| Device Type | Count | OS | Architecture |
|-------------|-------|-----|--------------|
| Raspberry Pi | 31 | Raspberry Pi OS Lite (versions vary) | ARM64/ARMhf |
| Radxa Rock | 2 | Debian | ARM64 |
| Mac Mini | 3 | macOS | Apple Silicon (ARM64) |

### Monitoring Configuration
- **Service Monitoring:** ALL processes automatically (using Low-Level Discovery)
- **SSH Access:** Mostly same credentials across devices (inventory list to be provided)

### Teams Integration Status
- **Webhook:** Configured in Zabbix but notifications not working
- **Troubleshooting Required:** Need to verify:
  - [ ] Trigger Action exists and is enabled
  - [ ] User media type is assigned
  - [ ] Message template format is correct for Teams
  - [ ] Webhook URL format is valid

---

## 1. Architecture Overview

### 1.1 Network Topology

```
┌─────────────────────────────────────────────────────────────┐
│                     Tailscale VPN Network                    │
│                                                               │
│  ┌──────────────────┐                                        │
│  │  Zabbix Server   │                                        │
│  │    (AWS)         │                                        │
│  │  Tailscale IP:   │                                        │
│  │  100.122.201.5   │                                        │
│  └────────┬─────────┘                                        │
│           │                                                   │
│           │ Port 10051 (Zabbix Trapper - Auto-registration)  │
│           │ Port 10050 (Zabbix Agent - Passive checks)       │
│           │                                                   │
│  ─────────┼──────────────────────────────────────────────   │
│           │                                                   │
│  ┌────────▼─────────┐  ┌─────────────┐  ┌─────────────┐    │
│  │  Client Network  │  │   Client    │  │   Client    │    │
│  │   Location 1     │  │  Network 2  │  │  Network 3  │    │
│  │                  │  │             │  │             │    │
│  │ ┌──────────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐ │    │
│  │ │ Raspberry Pi │ │  │ │ Radxa   │ │  │ │Mac Mini │ │    │
│  │ │  + Agent     │ │  │ │+ Agent  │ │  │ │+ Agent  │ │    │
│  │ └──────────────┘ │  │ └─────────┘ │  │ └─────────┘ │    │
│  │                  │  │             │  │             │    │
│  │ ┌──────────────┐ │  │ ┌─────────┐ │  │             │    │
│  │ │   [More      │ │  │ │ [More   │ │  │             │    │
│  │ │   Devices]   │ │  │ │Devices] │ │  │             │    │
│  │ └──────────────┘ │  │ └─────────┘ │  │             │    │
│  └──────────────────┘  └─────────────┘  └─────────────┘    │
│                                                               │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ HTTPS Webhook
                              ▼
                   ┌──────────────────────┐
                   │  Microsoft Teams     │
                   │  Notification Channel│
                   └──────────────────────┘
```

### 1.2 Component Responsibilities

**Zabbix Server (AWS)**
- Central monitoring and data collection
- Auto-registration handling
- Alert processing and notification routing
- Data storage and visualization
- Teams webhook integration

**Zabbix Agents (Remote Hardware)**
- System metrics collection
- Service/process discovery
- Active check execution
- Auto-registration with metadata
- Communication via Tailscale IPs

**Tailscale VPN**
- Secure communication channel
- Stable IP addressing across networks
- NAT traversal for remote sites
- Encrypted transport layer

---

## 2. Zabbix Server Configuration

### 2.1 Prerequisites

- [X] Zabbix Server version: **7.4.0**
- [ ] Admin access to Zabbix web interface
- [ ] API access credentials
- [X] Zabbix server Tailscale IP address: **100.122.201.5**
- [ ] Firewall rules: Allow inbound on ports 10050, 10051 from Tailscale network

### 2.2 Auto-Registration Configuration

**Action Configuration:**

1. Navigate to: Configuration → Actions → Autoregistration actions
2. Create new action: "Auto-register hardware devices"

**Conditions:**
- Host metadata contains: `tailscale-device`
- Optional: Additional conditions based on device type metadata

**Operations:**
- Add host
- Add to host groups (based on metadata):
  - `Hardware/RaspberryPi` (if metadata contains "rpi")
  - `Hardware/Radxa` (if metadata contains "radxa")
  - `Hardware/MacMini` (if metadata contains "mac")
- Link templates (conditional based on OS):
  - Linux devices: "Linux by Zabbix agent active", "Template Process Monitoring"
  - macOS devices: "macOS by Zabbix agent active", "Template Process Monitoring"
- Set host inventory mode to automatic

**Host Naming Convention:**
- Format: `{devicetype}-{location}-{identifier}`
- Example: `rpi-london-001`, `radxa-newyork-api-01`, `macmini-paris-render-02`
- Hostname sent by agent during auto-registration

### 2.3 Host Groups Structure

Create the following host groups:

```
Hardware/
├── RaspberryPi
├── Radxa
└── MacMini

Locations/
├── [Location1]
├── [Location2]
└── [Location3]

Services/
├── Critical
└── Standard
```

### 2.4 Required Templates

**Standard Zabbix Templates:**
- Linux by Zabbix agent active
- macOS by Zabbix agent active

**Custom Templates (to be created):**
- Template Process Monitoring (all devices)
- Template Hardware - Raspberry Pi (platform-specific)
- Template Hardware - Radxa Rock (platform-specific)
- Template Hardware - Mac Mini (platform-specific)

---

## 3. Service Monitoring Strategy

### 3.1 Process Discovery Mechanism

**Approach:** Low-Level Discovery (LLD) for automatic process detection

**Discovery Rules:**
- Discovery interval: 1 hour
- Item key: `proc.get[]` (Zabbix Agent 2)
- Filter: Exclude kernel threads and system processes

**Item Prototypes (per discovered process):**
1. Process count: `proc.num[{#PROCESS.NAME}]`
2. Memory usage: `proc.mem[{#PROCESS.NAME},,,,rss]`
3. CPU utilization: `proc.cpu.util[{#PROCESS.NAME}]`

**Update intervals:**
- Process count: 1 minute
- Memory: 2 minutes
- CPU: 1 minute

### 3.2 Critical Service Monitoring

For specific critical services, create dedicated items (not just discovery):

**Common Services to Monitor:**
- SSH daemon (sshd)
- Tailscale daemon (tailscaled)
- Docker daemon (dockerd) - if applicable
- Custom application processes

**Item Configuration:**
- Type: Zabbix agent (active)
- Check interval: 30 seconds for critical services
- History retention: 90 days
- Trend retention: 365 days

### 3.3 Trigger Configuration

**Service Availability Triggers:**
- Severity: High
- Expression: `last(/hostname/proc.num[sshd])=0`
- Description: "Critical service {ITEM.KEY1} is not running"
- Recovery: `last(/hostname/proc.num[sshd])>0`

**Host Availability Triggers:**
- Severity: Disaster
- Expression: `nodata(/hostname/agent.ping,3m)=1`
- Description: "Host {HOST.NAME} is offline"
- Dependencies: None (this is the root trigger)

**Resource Abuse Triggers:**
- Severity: Warning
- Expression: `avg(/hostname/proc.mem[{#PROCESS.NAME}],5m)>1G`
- Description: "Process {#PROCESS.NAME} using excessive memory"

---

## 4. Agent Deployment Strategy

### 4.1 Deployment Phases

**Phase 1: Preparation**
- Create inventory of all devices
- Document Tailscale IPs for each device
- Verify SSH access to all devices
- Prepare deployment scripts

**Phase 2: Pilot Deployment**
- Deploy to 1 device of each type (3 devices total)
- Verify auto-registration
- Test monitoring data collection
- Test Teams notifications
- Refine scripts based on findings

**Phase 3: Staged Rollout**
- Deploy by location or device type
- Monitor for issues
- Maximum 10 devices per batch
- Wait 24 hours between batches

**Phase 4: Full Production**
- Complete deployment to all devices
- Final verification
- Documentation of actual configuration

### 4.2 Installation Script Requirements

**Common Requirements (All OS Types):**

1. **Prerequisites Check**
   - Root/sudo privileges
   - Network connectivity to Zabbix server
   - Tailscale connectivity (ping Zabbix server Tailscale IP)
   - Sufficient disk space (100MB minimum)

2. **OS and Architecture Detection**
   - Automatic detection of OS type
   - Architecture detection (ARM64, ARMhf, x86_64, arm64)
   - Version detection for repository selection

3. **Tailscale IP Detection**
   - Extract device's Tailscale IP address
   - Validate IP format
   - Test connectivity to Zabbix server

4. **Hostname Generation**
   - Detect device type (Raspberry Pi, Radxa, Mac)
   - Prompt for location identifier
   - Generate hostname: `{type}-{location}-{serial/mac}`
   - Validate uniqueness (optional API check)

5. **Agent Installation**
   - Add Zabbix repository (Linux) or use Homebrew (macOS)
   - Install zabbix-agent2 package
   - Verify installation

6. **Configuration**
   - Server: Zabbix server Tailscale IP (passive checks)
   - ServerActive: Zabbix server Tailscale IP:10051 (active checks)
   - Hostname: Generated hostname
   - HostMetadata: `tailscale-device,{devicetype},{location}`
   - ListenIP: 0.0.0.0 (listen on all interfaces)
   - Timeout: 30 (for process enumeration)
   - RefreshActiveChecks: 120
   - BufferSize: 100
   - EnableRemoteCommands: 0 (security)
   - LogRemoteCommands: 0

7. **Platform-Specific Configuration**
   - UserParameters for hardware monitoring
   - Include directories for modular configuration
   - Platform-specific plugins

8. **Service Management**
   - Enable agent service on boot
   - Start agent service
   - Verify service status

9. **Connectivity Verification**
   - Test agent connectivity to server
   - Check agent log for errors
   - Verify auto-registration in server logs (optional)

10. **Output and Logging**
    - Clear success/failure messages
    - Log file for troubleshooting
    - Summary of configuration

### 4.3 OS-Specific Scripts

**Script Files to Create:**

1. `install-zabbix-agent-raspberrypi.sh`
   - Target: Raspberry Pi OS (Debian-based)
   - Architecture: ARM64 or ARMhf
   - Additional monitoring: vcgencmd for temperature, GPU memory

2. `install-zabbix-agent-radxa.sh`
   - Target: Ubuntu/Debian on Radxa Rock
   - Architecture: ARM64
   - Additional monitoring: RK3588/RK3399 thermal zones

3. `install-zabbix-agent-macos.sh`
   - Target: macOS (Apple Silicon and Intel)
   - Installation method: Homebrew
   - Additional monitoring: powermetrics, system_profiler

4. `install-zabbix-agent-generic-linux.sh`
   - Fallback for other Linux distributions
   - Auto-detect distribution and version

---

## 5. Microsoft Teams Integration

### 5.1 Teams Webhook Setup

**Steps to Create Webhook:**

1. Open Microsoft Teams
2. Navigate to target channel
3. Click channel menu → Connectors → Incoming Webhook
4. Configure webhook:
   - Name: "Zabbix Monitoring Alerts"
   - Upload icon (optional)
   - Create
5. Copy webhook URL: `https://outlook.office.com/webhook/...`

**Security Considerations:**
- Webhook URL is sensitive (treat as credential)
- Store in Zabbix as macro: `{$TEAMS_WEBHOOK_URL}`
- Restrict access to webhook configuration

### 5.2 Zabbix Media Type Configuration

**Create Custom Media Type:**

1. Navigate to: Administration → Media types → Create media type
2. Configuration:
   - Name: "Microsoft Teams"
   - Type: Webhook
   - Script: [JavaScript webhook script - TO BE PROVIDED]
   - Parameters:
     - `webhook_url`: `{ALERT.SENDTO}`
     - `event_source`: `{EVENT.SOURCE}`
     - `event_value`: `{EVENT.VALUE}`
     - `event_severity`: `{EVENT.SEVERITY}`
     - `event_name`: `{EVENT.NAME}`
     - `event_opdata`: `{EVENT.OPDATA}`
     - `event_date`: `{EVENT.DATE}`
     - `event_time`: `{EVENT.TIME}`
     - `event_tags`: `{EVENT.TAGS}`
     - `host_name`: `{HOST.NAME}`
     - `host_ip`: `{HOST.IP}`
     - `trigger_description`: `{TRIGGER.DESCRIPTION}`
     - `trigger_severity`: `{TRIGGER.SEVERITY}`
     - `trigger_status`: `{TRIGGER.STATUS}`
     - `event_update_status`: `{EVENT.UPDATE.STATUS}`
     - `event_recovery_value`: `{EVENT.RECOVERY.VALUE}`

3. Message templates:
   - Problem: Formatted card with problem details
   - Problem recovery: Formatted card with recovery notification
   - Problem update: Formatted card with update information

### 5.3 User Configuration

**Setup Notification User:**

1. Administration → Users → Create user
2. User details:
   - Alias: `teams-notifications`
   - Name: Teams Notification Bot
   - Groups: Add to group with read access to all hosts
   - Password: Generate strong password

3. Media configuration:
   - Type: Microsoft Teams
   - Send to: `{$TEAMS_WEBHOOK_URL}` or direct webhook URL
   - When active: 1-7, 00:00-24:00
   - Severity: All levels
   - Status: Enabled

### 5.4 Action Configuration

**Create Alert Actions:**

1. **Host Offline Alert**
   - Navigate to: Configuration → Actions → Trigger actions
   - Create action: "Notify Teams - Host Offline"
   - Conditions:
     - Trigger severity >= High
     - Trigger name contains "offline" OR "unreachable"
   - Operations:
     - Send message to user: teams-notifications via Microsoft Teams
     - Custom message template with host details

2. **Service Failure Alert**
   - Action: "Notify Teams - Service Failure"
   - Conditions:
     - Trigger severity >= Warning
     - Trigger name contains "not running" OR "stopped"
   - Operations:
     - Send message to user: teams-notifications

3. **Recovery Notifications**
   - Enabled in recovery operations
   - Send recovery message when trigger returns to OK

### 5.5 Message Format Examples

**Problem Message:**
```
🔴 PROBLEM: Host {HOST.NAME} is offline
Severity: Disaster
Time: {EVENT.TIME} {EVENT.DATE}
Host IP: {HOST.IP}
Duration: {EVENT.AGE}
Problem: {TRIGGER.DESCRIPTION}
```

**Recovery Message:**
```
✅ RESOLVED: Host {HOST.NAME} is online
Severity: Disaster → OK
Time: {EVENT.RECOVERY.TIME} {EVENT.RECOVERY.DATE}
Host IP: {HOST.IP}
Problem duration: {EVENT.DURATION}
```

---

## 6. Deployment Orchestration

### 6.1 Inventory Management

**Create Device Inventory File:** `device-inventory.csv`

```csv
hostname,device_type,os_type,tailscale_ip,location,ssh_user,ssh_key,status
rpi-london-001,raspberrypi,raspbian,100.64.0.10,london,pi,~/.ssh/id_rsa,pending
radxa-newyork-001,radxa,ubuntu,100.64.0.20,newyork,rock,~/.ssh/id_rsa,pending
macmini-paris-001,macmini,macos,100.64.0.30,paris,admin,~/.ssh/id_rsa,pending
```

### 6.2 Batch Deployment Script

**Create:** `deploy-batch.sh`

**Features:**
- Read inventory file
- Filter devices by status, type, or location
- SSH to each device and execute appropriate installation script
- Update inventory with deployment status
- Generate deployment report
- Handle errors gracefully
- Parallel deployment option (with concurrency limit)

**Usage:**
```bash
./deploy-batch.sh --inventory device-inventory.csv --filter "status=pending" --max-concurrent 5
```

### 6.3 Verification Script

**Create:** `verify-deployment.sh`

**Features:**
- Check agent connectivity for all devices
- Query Zabbix API for host status
- Verify data collection (check latest data timestamp)
- Test trigger functionality
- Generate health report
- Identify failed deployments

**Usage:**
```bash
./verify-deployment.sh --inventory device-inventory.csv --zabbix-url https://zabbix.example.com
```

### 6.4 Rollback Procedures

**Manual Rollback:**
```bash
# On agent device
sudo systemctl stop zabbix-agent2
sudo systemctl disable zabbix-agent2
sudo apt-get remove zabbix-agent2  # Linux
# OR
brew services stop zabbix          # macOS
brew uninstall zabbix
```

**Automated Rollback Script:** `rollback-agent.sh`
- Uninstall agent package
- Remove configuration files
- Remove from Zabbix server (API)
- Update inventory status

---

## 7. Testing and Validation

### 7.1 Pilot Testing Checklist

**Per Device Type:**

- [ ] Agent installation successful
- [ ] Service starts and runs continuously
- [ ] Auto-registration occurs within 2 minutes
- [ ] Host appears in correct host groups
- [ ] Correct templates linked automatically
- [ ] Process discovery finds all running processes
- [ ] Data collection verified in Latest Data
- [ ] Host offline trigger works (stop agent, verify alert)
- [ ] Teams notification received for offline event
- [ ] Host online recovery notification received
- [ ] Service failure trigger works (stop critical service)
- [ ] Teams notification for service failure
- [ ] Platform-specific metrics collected correctly
- [ ] No errors in agent logs
- [ ] No errors in server logs

### 7.2 Performance Testing

- Monitor Zabbix server load during mass deployment
- Verify database performance with increased load
- Check network bandwidth usage over Tailscale
- Measure agent CPU and memory overhead on devices

### 7.3 Failure Scenarios

**Test these scenarios:**

1. Agent can't reach server (Tailscale down)
2. Agent configuration error
3. Duplicate hostname
4. Incorrect server IP
5. Network timeout during deployment
6. Insufficient permissions during installation
7. Missing dependencies

---

## 8. Troubleshooting Guide

### 8.1 Agent Installation Issues

**Problem:** Repository not found (Linux)
**Solution:**
- Verify Zabbix repository URL is correct for OS version
- Check internet connectivity
- Try manual repository addition

**Problem:** Homebrew installation fails (macOS)
**Solution:**
- Update Homebrew: `brew update`
- Check Homebrew permissions
- Install from official pkg if Homebrew fails

### 8.2 Auto-Registration Issues

**Problem:** Host doesn't appear in Zabbix
**Solution:**
1. Check agent logs: `/var/log/zabbix/zabbix_agent2.log`
2. Verify ServerActive is set correctly
3. Check HostMetadata is configured
4. Verify auto-registration action is enabled
5. Check Zabbix server logs for connection attempts
6. Test network connectivity: `telnet {zabbix-server-ip} 10051`

**Problem:** Host registered but wrong templates
**Solution:**
- Review auto-registration action conditions
- Check HostMetadata format
- Manually unlink incorrect templates and link correct ones

### 8.3 Monitoring Data Issues

**Problem:** No data collected
**Solution:**
1. Check item status (grey = not supported)
2. Review agent configuration for ListenIP
3. Verify item keys are correct for agent version
4. Check agent logs for errors
5. Test item manually: `zabbix_agent2 -t <item_key>`

**Problem:** Process discovery not working
**Solution:**
- Verify proc.get is supported (Agent 2 only)
- Check discovery rule filters
- Increase Timeout in agent configuration
- Review agent logs during discovery execution

### 8.4 Teams Notification Issues

**Problem:** No Teams messages received
**Solution:**
1. Verify webhook URL is correct
2. Check media type configuration
3. Verify user media is enabled
4. Check action conditions match trigger
5. Review Zabbix alert log (Reports → Action log)
6. Test webhook manually with curl
7. Check Teams channel webhook status

---

## 9. Maintenance Procedures

### 9.1 Adding New Devices

1. Ensure device has Tailscale installed and connected
2. Run appropriate installation script
3. Verify auto-registration
4. Add device to inventory file
5. Update documentation

### 9.2 Decommissioning Devices

1. Disable host in Zabbix (don't delete immediately)
2. Monitor for 7 days to ensure no impact
3. Delete host from Zabbix
4. Uninstall agent from device
5. Update inventory file
6. Archive historical data if needed

### 9.3 Updating Agents

**Strategy:** Rolling updates

1. Update pilot devices first
2. Monitor for issues for 48 hours
3. Update remaining devices in batches
4. Keep agent versions consistent across environment

**Update Script:** `update-agent.sh`
- Backup current configuration
- Update package
- Verify configuration compatibility
- Restart service
- Verify connectivity

### 9.4 Template Updates

1. Export current template (backup)
2. Make changes in test environment
3. Test with pilot devices
4. Import to production
5. Document changes

---

## 10. Security Considerations

### 10.1 Network Security

- Tailscale provides encrypted transport (WireGuard)
- No public internet exposure required
- Firewall rules on Zabbix server restrict to Tailscale network
- Agent listens only on Tailscale interface (if configured)

### 10.2 Authentication

**Option 1: No PSK (Rely on Tailscale encryption)**
- Simplest configuration
- Tailscale already provides encryption
- Suitable for most environments

**Option 2: PSK Encryption (Defense in depth)**
- Add pre-shared key encryption
- Configure on server and agents
- Different PSK per device type or location
- More complex to manage

**Recommendation:** Start with Option 1, implement Option 2 if compliance requires

### 10.3 Access Control

- Limit Zabbix web interface access (VPN or IP whitelist)
- Use strong passwords for Zabbix users
- Implement RBAC for different user roles
- Disable remote commands on agents (EnableRemoteCommands=0)
- Regular audit of user permissions

### 10.4 Credential Management

- Teams webhook URL stored as encrypted macro
- API credentials stored securely
- SSH keys for deployment protected with passphrase
- Regular rotation of credentials

---

## 11. Deliverables Checklist

### 11.1 Documentation

- [X] This deployment plan document
- [X] Zabbix server setup guide (docs/zabbix-server-setup.md)
- [ ] Installation script documentation (per OS)
- [ ] Troubleshooting runbook
- [X] Inventory template (device-inventory.csv)
- [ ] Architecture diagrams

### 11.2 Scripts

- [X] `install-zabbix-agent-raspberrypi.sh` (Created: scripts/install-zabbix-agent-raspberrypi.sh)
- [X] `install-zabbix-agent-radxa.sh` (Created: scripts/install-zabbix-agent-radxa.sh)
- [X] `install-zabbix-agent-macos.sh` (Created: scripts/install-zabbix-agent-macos.sh)
- [ ] `install-zabbix-agent-generic-linux.sh`
- [ ] `deploy-batch.sh`
- [ ] `verify-deployment.sh`
- [ ] `rollback-agent.sh`
- [ ] `update-agent.sh`

### 11.3 Zabbix Configuration

- [ ] Auto-registration action
- [ ] Host groups structure
- [ ] Custom templates (Process Monitoring, Platform-specific)
- [ ] Teams media type with webhook script
- [ ] Notification actions (offline, service failure, recovery)
- [ ] User for Teams notifications

### 11.4 Tools and Templates

- [X] Device inventory CSV template (device-inventory.csv)
- [ ] Deployment report template
- [ ] Teams message format templates
- [X] Zabbix template export files (YAML):
  - templates/template_process_monitoring.yaml
  - templates/template_raspberry_pi.yaml
  - templates/template_radxa.yaml
  - templates/template_macos.yaml
- [X] Template import guide (docs/template-import-guide.md)

---

## 12. Timeline and Milestones

**Estimated Timeline:** 2-3 weeks

### Week 1: Preparation and Development
- Days 1-2: Requirements gathering and server configuration
- Days 3-5: Script development and template creation
- Days 6-7: Teams integration setup and testing

### Week 2: Testing and Refinement
- Days 1-2: Pilot deployment (3 devices)
- Days 3-5: Issue resolution and script refinement
- Days 6-7: Documentation completion

### Week 3: Production Rollout
- Days 1-5: Staged deployment to all devices
- Days 6-7: Validation and final documentation

---

## 13. Success Criteria

- [ ] All devices successfully registered in Zabbix
- [ ] All devices reporting metrics continuously
- [ ] Process discovery working on all devices
- [ ] Host offline/online detection working (< 3 minute detection time)
- [ ] Service monitoring detecting critical service failures
- [ ] Teams notifications received for all alert types
- [ ] No false positive alerts (> 95% accuracy)
- [ ] Agent overhead < 2% CPU, < 100MB RAM on smallest devices
- [ ] Zero manual host configuration (100% auto-registration)
- [ ] Deployment scripts work without manual intervention
- [ ] Complete documentation delivered

---

## 14. Next Steps

### Immediate Actions Required

1. **Answer Infrastructure Questions:**
   - Provide hardware inventory details
   - Confirm Zabbix server version and Tailscale IP
   - Define service monitoring requirements
   - Specify Teams webhook URL or channel
   - Confirm deployment method preferences

2. **Server Preparation:**
   - Verify Zabbix server access
   - Create host groups
   - Configure auto-registration action
   - Set up Teams webhook

3. **Script Development:**
   - Create OS-specific installation scripts
   - Develop deployment orchestration tools
   - Build verification scripts

4. **Pilot Testing:**
   - Select pilot devices (1 of each type)
   - Execute test deployment
   - Validate all functionality
   - Refine based on results

5. **Production Rollout:**
   - Deploy in stages
   - Monitor and validate
   - Complete documentation

---

## Appendix A: Reference Information

### Zabbix Documentation Links
- Auto-registration: https://www.zabbix.com/documentation/current/manual/discovery/auto_registration
- Zabbix Agent 2: https://www.zabbix.com/documentation/current/manual/appendix/agent2
- Process monitoring: https://www.zabbix.com/documentation/current/manual/config/items/itemtypes/zabbix_agent
- Webhooks: https://www.zabbix.com/documentation/current/manual/config/notifications/media/webhook

### Tailscale Documentation
- Tailscale basics: https://tailscale.com/kb/1151/what-is-tailscale/
- Subnet routers: https://tailscale.com/kb/1019/subnets/

### Platform-Specific Resources
- Raspberry Pi monitoring: vcgencmd documentation
- Radxa Rock: RK3588 thermal management
- macOS monitoring: powermetrics man page

---

## Appendix B: Configuration Templates

### Agent Configuration Template

```ini
# Zabbix Agent 2 Configuration Template
# Generated by installation script

# Server connection
Server={ZABBIX_SERVER_IP}
ServerActive={ZABBIX_SERVER_IP}:10051

# Host identification
Hostname={GENERATED_HOSTNAME}
HostMetadata=tailscale-device,{DEVICE_TYPE},{LOCATION}

# Network settings
ListenPort=10050
ListenIP=0.0.0.0

# Performance tuning
RefreshActiveChecks=120
BufferSize=100
Timeout=30

# Security
EnableRemoteCommands=0
LogRemoteCommands=0

# Logging
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=10
DebugLevel=3

# Plugin configuration
Plugins.SystemRun.LogRemoteCommands=0

# Include platform-specific configuration
Include=/etc/zabbix/zabbix_agent2.d/*.conf
```

---

**Document Version:** 1.1
**Last Updated:** 2026-01-26
**Status:** Requirements gathered - Implementation in progress
