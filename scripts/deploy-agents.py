#!/usr/bin/env python3
"""
Zabbix Agent Deployment Orchestrator

Deploys Zabbix agents to remote devices via SSH using inventory from CSV.
Supports Raspberry Pi, Radxa Rock, and Mac Mini platforms.

Usage:
    python3 scripts/deploy-agents.py --inventory inventory.csv
    python3 scripts/deploy-agents.py --inventory inventory.csv --dry-run
    python3 scripts/deploy-agents.py --inventory inventory.csv --device rpi-london-001
    python3 scripts/deploy-agents.py --inventory inventory.csv --resume
    python3 scripts/deploy-agents.py --inventory inventory.csv --retry-failed
    python3 scripts/deploy-agents.py --inventory inventory.csv --check

Prerequisites:
    brew install hudochenkov/sshpass/sshpass
"""

import argparse
import csv
import dataclasses
import datetime
import getpass
import json
import os
import shlex
import shutil
import subprocess
import sys
import threading
import time
import concurrent.futures

# =============================================================================
# Constants
# =============================================================================

GITHUB_RAW_BASE = (
    "https://raw.githubusercontent.com/emilejacobs/zabbix-rollout/main/scripts"
)

INSTALL_SCRIPTS = {
    "raspberrypi": "install-zabbix-agent-raspberrypi.sh",
    "radxa": "install-zabbix-agent-radxa.sh",
    "macos": "install-zabbix-agent-macos.sh",
}

VALID_PLATFORMS = set(INSTALL_SCRIPTS.keys())

SSH_OPTIONS = [
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=/dev/null",
    "-o", "ConnectTimeout=10",
    "-o", "ServerAliveInterval=30",
    "-o", "ServerAliveCountMax=3",
    "-o", "LogLevel=ERROR",
]

# =============================================================================
# Data Classes
# =============================================================================


@dataclasses.dataclass
class Device:
    device_name: str
    platform: str
    tailscale_ip: str
    location: str
    client: str
    chain: str
    asset_tag: str
    latitude: str
    longitude: str
    ssh_user: str
    ssh_password: str

    @property
    def install_script(self) -> str:
        return INSTALL_SCRIPTS[self.platform]

    def validate(self) -> list:
        errors = []
        if not self.device_name:
            errors.append("device_name is empty")
        if self.platform not in VALID_PLATFORMS:
            errors.append(
                f"platform '{self.platform}' is invalid "
                f"(must be one of: {', '.join(sorted(VALID_PLATFORMS))})"
            )
        if not self.tailscale_ip:
            errors.append("tailscale_ip is empty")
        if not self.location:
            errors.append("location is empty")
        if not self.ssh_user:
            errors.append("ssh_user is empty")
        if not self.ssh_password:
            errors.append("ssh_password is empty")
        return errors


@dataclasses.dataclass
class DeploymentResult:
    device_name: str
    success: bool
    duration_seconds: float
    error_message: str = ""
    log_file: str = ""


# =============================================================================
# CSV Parser
# =============================================================================


def parse_inventory(csv_path: str) -> list:
    """Parse inventory CSV file into a list of Device objects."""
    devices = []
    with open(csv_path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)

        # Validate header
        required_columns = {
            "device_name", "platform", "tailscale_ip", "location",
            "ssh_user", "ssh_password",
        }
        if reader.fieldnames is None:
            print("ERROR: CSV file is empty or has no header row")
            sys.exit(1)

        actual_columns = {c.strip().lower() for c in reader.fieldnames}
        missing = required_columns - actual_columns
        if missing:
            print(f"ERROR: CSV is missing required columns: {', '.join(sorted(missing))}")
            print(f"  Found columns: {', '.join(reader.fieldnames)}")
            sys.exit(1)

        for row_num, row in enumerate(reader, start=2):
            # Normalize keys to lowercase/stripped
            row = {k.strip().lower(): (v.strip() if v else "") for k, v in row.items()}

            # Skip empty rows
            if not row.get("device_name"):
                continue

            device = Device(
                device_name=row.get("device_name", ""),
                platform=row.get("platform", "").lower(),
                tailscale_ip=row.get("tailscale_ip", ""),
                location=row.get("location", ""),
                client=row.get("client", ""),
                chain=row.get("chain", ""),
                asset_tag=row.get("asset_tag", ""),
                latitude=row.get("latitude", ""),
                longitude=row.get("longitude", ""),
                ssh_user=row.get("ssh_user", ""),
                ssh_password=row.get("ssh_password", ""),
            )

            errors = device.validate()
            if errors:
                print(f"WARNING: Row {row_num} ({device.device_name or 'unnamed'}): "
                      f"{'; '.join(errors)} — skipping")
                continue

            devices.append(device)

    return devices


# =============================================================================
# State Manager
# =============================================================================


class StateManager:
    """Tracks deployment state per device in a JSON file."""

    def __init__(self, state_file: str):
        self.state_file = state_file
        self._lock = threading.Lock()
        self.state = self._load()

    def _load(self) -> dict:
        if os.path.exists(self.state_file):
            try:
                with open(self.state_file) as f:
                    return json.load(f)
            except (json.JSONDecodeError, IOError):
                return {}
        return {}

    def _save(self):
        with self._lock:
            with open(self.state_file, "w") as f:
                json.dump(self.state, f, indent=2)

    def get_status(self, device_name: str):
        entry = self.state.get(device_name)
        return entry.get("status") if entry else None

    def mark_success(self, device_name: str):
        self.state[device_name] = {
            "status": "success",
            "timestamp": datetime.datetime.now().isoformat(),
            "error": None,
        }
        self._save()

    def mark_failed(self, device_name: str, error: str):
        self.state[device_name] = {
            "status": "failed",
            "timestamp": datetime.datetime.now().isoformat(),
            "error": error,
        }
        self._save()


# =============================================================================
# SSH Executor
# =============================================================================


class SSHExecutor:
    """Wraps sshpass + ssh/scp for password-based SSH operations."""

    def __init__(self, sshpass_path: str):
        self.sshpass_path = sshpass_path

    def _build_env(self, password: str) -> dict:
        """Build environment with SSHPASS set for sshpass -e mode."""
        env = os.environ.copy()
        env["SSHPASS"] = password
        return env

    def test_connectivity(self, device: Device) -> tuple:
        """Test SSH connectivity. Returns (success, message)."""
        try:
            result = subprocess.run(
                [self.sshpass_path, "-e", "ssh"] + SSH_OPTIONS +
                [f"{device.ssh_user}@{device.tailscale_ip}", "echo ok"],
                env=self._build_env(device.ssh_password),
                capture_output=True, text=True, timeout=15,
            )
            if result.returncode == 0 and "ok" in result.stdout:
                return True, "OK"
            else:
                stderr = result.stderr.strip()
                return False, f"SSH failed: {stderr or 'unknown error'}"
        except subprocess.TimeoutExpired:
            return False, "SSH connection timed out"
        except Exception as e:
            return False, f"SSH error: {e}"

    def scp_file(self, device: Device, local_path: str, remote_path: str):
        """Copy a file to the remote device."""
        return subprocess.run(
            [self.sshpass_path, "-e", "scp"] + SSH_OPTIONS +
            [local_path, f"{device.ssh_user}@{device.tailscale_ip}:{remote_path}"],
            env=self._build_env(device.ssh_password),
            capture_output=True, text=True, timeout=60,
        )

    def ssh_run(self, device: Device, command: str, timeout: int = 600):
        """Execute a command on the remote device."""
        return subprocess.run(
            [self.sshpass_path, "-e", "ssh"] + SSH_OPTIONS +
            [f"{device.ssh_user}@{device.tailscale_ip}", command],
            env=self._build_env(device.ssh_password),
            capture_output=True, text=True, timeout=timeout,
        )


# =============================================================================
# Deployment Logic
# =============================================================================


def build_env_string(device: Device, zabbix_token: str) -> str:
    """Build environment variable string for the install script."""
    parts = [f"DEVICE_NAME={shlex.quote(device.device_name)}"]

    if device.location:
        parts.append(f"LOCATION={shlex.quote(device.location)}")
    if device.client:
        parts.append(f"CLIENT={shlex.quote(device.client)}")
    if device.chain:
        parts.append(f"CHAIN={shlex.quote(device.chain)}")
    if device.asset_tag:
        parts.append(f"ASSET_TAG={shlex.quote(device.asset_tag)}")
    if device.latitude:
        parts.append(f"LATITUDE={shlex.quote(device.latitude)}")
    if device.longitude:
        parts.append(f"LONGITUDE={shlex.quote(device.longitude)}")
    if zabbix_token:
        parts.append(f"ZABBIX_API_TOKEN={shlex.quote(zabbix_token)}")

    return " ".join(parts)


def deploy_device(device: Device, ssh: SSHExecutor, zabbix_token: str,
                  scripts_dir: str, log_dir: str, use_github: bool) -> DeploymentResult:
    """Deploy Zabbix agent to a single device."""
    start_time = time.time()
    log_file = os.path.join(log_dir, f"{device.device_name}.log")

    # Step 1: Test connectivity
    reachable, msg = ssh.test_connectivity(device)
    if not reachable:
        duration = time.time() - start_time
        write_log(log_file, device, 1, "", msg)
        return DeploymentResult(device.device_name, False, duration, msg, log_file)

    env_vars = build_env_string(device, zabbix_token)

    # macOS needs sudo -E to preserve env for Homebrew's SUDO_USER
    sudo_prefix = "sudo -E" if device.platform == "macos" else "sudo"

    if use_github:
        # GitHub mode: curl | sudo bash
        github_url = f"{GITHUB_RAW_BASE}/{device.install_script}"
        command = (
            f"curl -fsSL {shlex.quote(github_url)} "
            f"| {sudo_prefix} {env_vars} bash"
        )
        result = ssh.ssh_run(device, command)
    else:
        # Local mode: SCP + SSH execute
        local_script = os.path.join(scripts_dir, device.install_script)
        if not os.path.exists(local_script):
            duration = time.time() - start_time
            err = f"Local script not found: {local_script}"
            write_log(log_file, device, 1, "", err)
            return DeploymentResult(device.device_name, False, duration, err, log_file)

        remote_script = "/tmp/install-zabbix-agent.sh"

        # SCP script to device
        scp_result = ssh.scp_file(device, local_script, remote_script)
        if scp_result.returncode != 0:
            duration = time.time() - start_time
            err = f"SCP failed: {scp_result.stderr.strip()}"
            write_log(log_file, device, scp_result.returncode, scp_result.stdout, err)
            return DeploymentResult(device.device_name, False, duration, err, log_file)

        # Execute script
        command = f"{sudo_prefix} {env_vars} bash {remote_script}"
        result = ssh.ssh_run(device, command)

        # Clean up remote script (best effort)
        try:
            ssh.ssh_run(device, f"rm -f {remote_script}", timeout=10)
        except Exception:
            pass

    duration = time.time() - start_time
    write_log(log_file, device, result.returncode, result.stdout, result.stderr)

    if result.returncode == 0:
        return DeploymentResult(device.device_name, True, duration, log_file=log_file)
    else:
        error = result.stderr.strip()
        if len(error) > 200:
            error = "..." + error[-200:]
        if not error:
            # Check stdout for error clues
            error = "Script exited with non-zero status"
        return DeploymentResult(device.device_name, False, duration, error, log_file)


def write_log(log_file: str, device: Device, exit_code: int,
              stdout: str, stderr: str):
    """Write deployment log for a device."""
    with open(log_file, "w") as f:
        f.write(f"{'=' * 60}\n")
        f.write(f"Deployment Log: {device.device_name}\n")
        f.write(f"{'=' * 60}\n")
        f.write(f"Platform:    {device.platform}\n")
        f.write(f"IP:          {device.tailscale_ip}\n")
        f.write(f"Location:    {device.location}\n")
        f.write(f"Timestamp:   {datetime.datetime.now().isoformat()}\n")
        f.write(f"Exit code:   {exit_code}\n")
        f.write(f"\n{'=' * 60}\n")
        f.write("STDOUT\n")
        f.write(f"{'=' * 60}\n")
        f.write(stdout or "(empty)\n")
        f.write(f"\n{'=' * 60}\n")
        f.write("STDERR\n")
        f.write(f"{'=' * 60}\n")
        f.write(stderr or "(empty)\n")


def deploy_and_record(device: Device, ssh: SSHExecutor, zabbix_token: str,
                      scripts_dir: str, log_dir: str, use_github: bool,
                      state: StateManager) -> DeploymentResult:
    """Deploy to a device and update state file."""
    result = deploy_device(device, ssh, zabbix_token, scripts_dir, log_dir, use_github)
    if result.success:
        state.mark_success(device.device_name)
    else:
        state.mark_failed(device.device_name, result.error_message)
    return result


# =============================================================================
# Prerequisite Checks
# =============================================================================


def check_prerequisites(dry_run: bool = False) -> str:
    """Check prerequisites. Returns sshpass path or exits with error."""
    sshpass_path = shutil.which("sshpass")

    if not sshpass_path and not dry_run:
        print("ERROR: sshpass is not installed.")
        print()
        print("Install it with:")
        print("  brew install hudochenkov/sshpass/sshpass")
        print()
        print("Or use --dry-run to preview without SSH.")
        sys.exit(1)

    if not dry_run:
        if not shutil.which("ssh"):
            print("ERROR: ssh is not installed")
            sys.exit(1)
        if not shutil.which("scp"):
            print("ERROR: scp is not installed")
            sys.exit(1)

    return sshpass_path or "sshpass"


# =============================================================================
# Connectivity Check
# =============================================================================


def run_connectivity_checks(devices: list, ssh: SSHExecutor):
    """Test SSH connectivity to all devices and print results."""
    print(f"\nTesting connectivity to {len(devices)} devices...\n")

    name_width = max(len(d.device_name) for d in devices)
    ip_width = max(len(d.tailscale_ip) for d in devices)

    ok_count = 0
    fail_count = 0

    for device in devices:
        reachable, msg = ssh.test_connectivity(device)
        status = "OK" if reachable else f"FAIL: {msg}"
        symbol = "+" if reachable else "x"

        print(f"  [{symbol}] {device.device_name:<{name_width}}  "
              f"{device.tailscale_ip:<{ip_width}}  {status}")

        if reachable:
            ok_count += 1
        else:
            fail_count += 1

    print(f"\nReachable: {ok_count}/{len(devices)}", end="")
    if fail_count:
        print(f"  |  Unreachable: {fail_count}")
    else:
        print()


# =============================================================================
# Display Functions
# =============================================================================


def print_deployment_plan(devices: list, args):
    """Print summary of what will be deployed."""
    platform_counts = {}
    for d in devices:
        platform_counts[d.platform] = platform_counts.get(d.platform, 0) + 1

    print(f"\n{'=' * 60}")
    print("  DEPLOYMENT PLAN")
    print(f"{'=' * 60}")
    print(f"  Devices:    {len(devices)}")
    for platform in sorted(platform_counts):
        print(f"    {platform}: {platform_counts[platform]}")
    print(f"  Method:     {'GitHub (curl)' if args.github else 'Local (SCP)'}")
    print(f"  API token:  {'provided' if args.token or os.environ.get('ZABBIX_API_TOKEN') else 'not set (tags/inventory will be skipped)'}")
    if args.parallel and args.parallel > 1:
        print(f"  Parallel:   {args.parallel} concurrent")
    else:
        print(f"  Parallel:   sequential")
    print(f"{'=' * 60}")

    print(f"\n  {'Device':<35} {'Platform':<15} {'IP':<18} {'Location'}")
    print(f"  {'-' * 35} {'-' * 15} {'-' * 18} {'-' * 20}")
    for d in devices:
        print(f"  {d.device_name:<35} {d.platform:<15} {d.tailscale_ip:<18} {d.location}")
    print()


def print_device_result(result: DeploymentResult, index: int = 0, total: int = 0):
    """Print the result of a single device deployment."""
    prefix = f"[{index}/{total}] " if index else ""
    duration = format_duration(result.duration_seconds)

    if result.success:
        print(f"  {prefix}[+] {result.device_name} — SUCCESS ({duration})")
    else:
        print(f"  {prefix}[x] {result.device_name} — FAILED ({duration})")
        print(f"       Error: {result.error_message}")
        if result.log_file:
            print(f"       Log:   {result.log_file}")


def print_dry_run_device(device: Device, zabbix_token: str,
                         scripts_dir: str, use_github: bool):
    """Print what would happen for a device in dry-run mode."""
    env_vars = build_env_string(device, zabbix_token)
    # Redact token in display
    display_vars = env_vars
    if zabbix_token:
        display_vars = env_vars.replace(zabbix_token, "***REDACTED***")

    sudo_prefix = "sudo -E" if device.platform == "macos" else "sudo"

    print(f"\n  Device:    {device.device_name}")
    print(f"  Platform:  {device.platform}")
    print(f"  IP:        {device.tailscale_ip}")
    print(f"  SSH User:  {device.ssh_user}")
    print(f"  Script:    {device.install_script}")

    if use_github:
        print(f"  Method:    curl from GitHub")
        print(f"  Command:   curl -fsSL {GITHUB_RAW_BASE}/{device.install_script} "
              f"| {sudo_prefix} {display_vars} bash")
    else:
        local_script = os.path.join(scripts_dir, device.install_script)
        exists = "exists" if os.path.exists(local_script) else "NOT FOUND"
        print(f"  Method:    SCP + SSH ({exists})")
        print(f"  SCP:       {local_script} -> /tmp/install-zabbix-agent.sh")
        print(f"  Command:   {sudo_prefix} {display_vars} bash /tmp/install-zabbix-agent.sh")


def print_summary_report(results: list):
    """Print final deployment summary."""
    total = len(results)
    success = sum(1 for r in results if r.success)
    failed = total - success
    total_duration = sum(r.duration_seconds for r in results)

    print(f"\n{'=' * 60}")
    print("  DEPLOYMENT SUMMARY")
    print(f"{'=' * 60}")
    print(f"  Total devices:    {total}")
    print(f"  Successful:       {success}")
    print(f"  Failed:           {failed}")
    print(f"  Total duration:   {format_duration(total_duration)}")
    print(f"{'=' * 60}\n")

    if results:
        name_width = max(len(r.device_name) for r in results)
        print(f"  {'Device':<{name_width}}  {'Status':<10}  Duration")
        print(f"  {'-' * name_width}  {'-' * 10}  {'-' * 10}")
        for r in results:
            status = "OK" if r.success else "FAILED"
            print(f"  {r.device_name:<{name_width}}  {status:<10}  "
                  f"{format_duration(r.duration_seconds)}")
            if not r.success:
                print(f"  {'':>{name_width}}  Error: {r.error_message}")
                if r.log_file:
                    print(f"  {'':>{name_width}}  Log:   {r.log_file}")

    if failed > 0:
        print(f"\nFailed devices can be retried with:")
        print(f"  python3 scripts/deploy-agents.py --inventory <csv> --retry-failed")


def format_duration(seconds: float) -> str:
    """Format seconds into human-readable duration."""
    if seconds < 1:
        return "<1s"
    minutes = int(seconds) // 60
    secs = int(seconds) % 60
    if minutes > 0:
        return f"{minutes}m {secs:02d}s"
    return f"{secs}s"


# =============================================================================
# CLI Interface
# =============================================================================


def parse_args():
    parser = argparse.ArgumentParser(
        description="Zabbix Agent Deployment Orchestrator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Preview deployment (no changes made)
  python3 scripts/deploy-agents.py --inventory inventory.csv --dry-run

  # Test SSH connectivity to all devices
  python3 scripts/deploy-agents.py --inventory inventory.csv --check

  # Deploy to a single device (for testing)
  python3 scripts/deploy-agents.py --inventory inventory.csv --device rpi-london-001

  # Deploy to all Raspberry Pi devices
  python3 scripts/deploy-agents.py --inventory inventory.csv --platform raspberrypi

  # Full deployment with API token
  ZABBIX_API_TOKEN=your-token python3 scripts/deploy-agents.py --inventory inventory.csv

  # Resume after a partial deployment
  python3 scripts/deploy-agents.py --inventory inventory.csv --resume

  # Retry only failed devices
  python3 scripts/deploy-agents.py --inventory inventory.csv --retry-failed

  # Deploy using GitHub URLs (instead of local SCP)
  python3 scripts/deploy-agents.py --inventory inventory.csv --github

Prerequisites:
  brew install hudochenkov/sshpass/sshpass
        """,
    )

    parser.add_argument(
        "--inventory", required=True, metavar="CSV",
        help="Path to CSV inventory file (exported from Excel)",
    )
    parser.add_argument(
        "--token", metavar="TOKEN",
        help="Zabbix API token (or set ZABBIX_API_TOKEN env var)",
    )
    parser.add_argument(
        "--scripts-dir", metavar="DIR",
        help="Path to install scripts directory (default: ./scripts)",
    )
    parser.add_argument(
        "--log-dir", metavar="DIR",
        help="Path for log files (default: ./logs)",
    )
    parser.add_argument(
        "--state-file", metavar="FILE",
        help="Path for state file (default: ./rollout-state.json)",
    )

    # Filtering
    filter_group = parser.add_argument_group("filtering")
    filter_group.add_argument(
        "--device", metavar="NAME",
        help="Deploy to a single device only",
    )
    filter_group.add_argument(
        "--platform", choices=sorted(VALID_PLATFORMS), metavar="TYPE",
        help="Deploy only to devices of this platform (raspberrypi, radxa, macos)",
    )

    # Modes
    mode_group = parser.add_argument_group("modes")
    mode_group.add_argument(
        "--github", action="store_true",
        help="Use GitHub raw URLs instead of SCP (requires internet on devices)",
    )
    mode_group.add_argument(
        "--dry-run", action="store_true",
        help="Preview what would happen without executing",
    )
    mode_group.add_argument(
        "--check", action="store_true",
        help="Only test SSH connectivity, do not deploy",
    )
    mode_group.add_argument(
        "--resume", action="store_true",
        help="Skip devices already successfully deployed",
    )
    mode_group.add_argument(
        "--retry-failed", action="store_true",
        help="Only retry devices that previously failed",
    )
    mode_group.add_argument(
        "--force", action="store_true",
        help="Ignore state file, deploy to all devices",
    )

    # Performance
    parser.add_argument(
        "--parallel", type=int, default=1, metavar="N",
        help="Max concurrent deployments (default: 1, max: 5)",
    )

    args = parser.parse_args()

    # Resolve defaults relative to script location
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)

    if not args.scripts_dir:
        args.scripts_dir = os.path.join(repo_root, "scripts")
    if not args.log_dir:
        args.log_dir = os.path.join(repo_root, "logs")
    if not args.state_file:
        args.state_file = os.path.join(repo_root, "rollout-state.json")

    # Validate parallel range
    if args.parallel < 1:
        args.parallel = 1
    elif args.parallel > 5:
        print("WARNING: Limiting parallel deployments to 5")
        args.parallel = 5

    return args


# =============================================================================
# Main
# =============================================================================


def main():
    args = parse_args()

    # 1. Get Zabbix API token
    zabbix_token = args.token or os.environ.get("ZABBIX_API_TOKEN", "")
    if not zabbix_token and not args.dry_run and not args.check:
        print("No ZABBIX_API_TOKEN provided.")
        print("The agent will install but tags/inventory will not be populated.")
        response = input("Continue without API token? [y/N]: ").strip().lower()
        if response != "y":
            try:
                zabbix_token = getpass.getpass("Enter ZABBIX_API_TOKEN: ")
            except (EOFError, KeyboardInterrupt):
                print("\nAborted.")
                sys.exit(1)

    # 2. Check prerequisites
    sshpass_path = check_prerequisites(dry_run=args.dry_run)

    # 3. Parse inventory
    if not os.path.exists(args.inventory):
        print(f"ERROR: Inventory file not found: {args.inventory}")
        sys.exit(1)

    devices = parse_inventory(args.inventory)
    if not devices:
        print("ERROR: No valid devices found in inventory")
        sys.exit(1)

    print(f"Loaded {len(devices)} devices from {args.inventory}")

    # 4. Apply filters
    if args.device:
        devices = [d for d in devices if d.device_name == args.device]
        if not devices:
            print(f"ERROR: Device '{args.device}' not found in inventory")
            sys.exit(1)

    if args.platform:
        devices = [d for d in devices if d.platform == args.platform]
        if not devices:
            print(f"ERROR: No devices found for platform '{args.platform}'")
            sys.exit(1)

    # 5. Apply resume/retry logic
    state = StateManager(args.state_file)

    if args.resume:
        before = len(devices)
        devices = [d for d in devices if state.get_status(d.device_name) != "success"]
        skipped = before - len(devices)
        if skipped:
            print(f"Resuming: skipping {skipped} already successful devices")

    elif args.retry_failed:
        devices = [d for d in devices if state.get_status(d.device_name) == "failed"]
        if not devices:
            print("No failed devices to retry.")
            sys.exit(0)
        print(f"Retrying {len(devices)} failed devices")

    if not devices:
        print("No devices to deploy after applying filters.")
        sys.exit(0)

    # 6. Initialize SSH executor
    ssh = SSHExecutor(sshpass_path) if not args.dry_run else None

    # 7. Check-only mode
    if args.check:
        run_connectivity_checks(devices, ssh)
        sys.exit(0)

    # 8. Print plan
    print_deployment_plan(devices, args)

    # 9. Dry-run mode
    if args.dry_run:
        print("DRY RUN — no changes will be made\n")
        for device in devices:
            print_dry_run_device(device, zabbix_token, args.scripts_dir, args.github)
        print(f"\n{len(devices)} devices would be deployed.")
        sys.exit(0)

    # 10. Confirm before multi-device deployment
    if len(devices) > 1:
        response = input(f"Deploy to {len(devices)} devices? [y/N]: ").strip().lower()
        if response != "y":
            print("Aborted.")
            sys.exit(0)

    # 11. Create log directory
    os.makedirs(args.log_dir, exist_ok=True)

    # 12. Deploy
    results = []

    if args.parallel > 1:
        # Parallel deployment
        print(f"\nDeploying to {len(devices)} devices ({args.parallel} concurrent)...\n")
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.parallel) as pool:
            future_to_device = {
                pool.submit(
                    deploy_and_record, device, ssh, zabbix_token,
                    args.scripts_dir, args.log_dir, args.github, state
                ): device
                for device in devices
            }
            for future in concurrent.futures.as_completed(future_to_device):
                device = future_to_device[future]
                try:
                    result = future.result()
                except Exception as e:
                    result = DeploymentResult(
                        device.device_name, False, 0, f"Unexpected error: {e}"
                    )
                results.append(result)
                print_device_result(result)
    else:
        # Sequential deployment
        print(f"\nDeploying to {len(devices)} devices (sequential)...\n")
        for i, device in enumerate(devices, 1):
            print(f"[{i}/{len(devices)}] {device.device_name} "
                  f"({device.platform} @ {device.tailscale_ip})...")
            try:
                result = deploy_and_record(
                    device, ssh, zabbix_token,
                    args.scripts_dir, args.log_dir, args.github, state
                )
            except Exception as e:
                result = DeploymentResult(
                    device.device_name, False, 0, f"Unexpected error: {e}"
                )
            results.append(result)
            print_device_result(result, i, len(devices))

    # 13. Print summary
    print_summary_report(results)

    # Exit with non-zero if any failures
    if any(not r.success for r in results):
        sys.exit(1)


if __name__ == "__main__":
    main()
