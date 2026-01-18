# Inferno

**Docker-like interface for Firecracker microVMs**

Inferno runs Docker/OCI container images as lightweight Firecracker microVMs instead of traditional containers, providing VM-level isolation with near-container startup times.

## Features

- **VM-based isolation** - Each container runs in its own Firecracker microVM
- **Docker image compatibility** - Use existing Docker/OCI images without modification
- **Fast startup** - Boot times under 500ms for small images
- **Network isolation** - Each VM gets its own TAP device and private subnet
- **Resource limits** - Configure CPU and memory per VM
- **VM inspection** - List VMs and view detailed status with runtime verification
- **Centralized logging** - All VM logs stream to a single aggregation point
- **No daemon required** - Unlike Docker, no background service needed

## Quick Start

### Prerequisites

- Linux with KVM support enabled
- Docker or Podman (for image extraction)
- Root access (for network/VM management)

### Installation

**Development mode** (installs to your home directory):
```bash
sudo ./scripts/install.sh --mode dev --user $USER
```

**Production mode** (system-wide installation):
```bash
sudo ./scripts/install.sh --mode prod
```

This installs:
- `infernoctl` command-line tool
- Firecracker hypervisor and kernel
- Network and database management utilities

### Initialize Inferno

First-time setup (creates data directory and database):
```bash
infernoctl init
```

### Create and Run a VM

```bash
# Create a VM from nginx image
sudo infernoctl create web1 --image nginx:latest

# List all VMs
sudo infernoctl list

# Start the VM
sudo infernoctl start web1 --detach

# Check VM status
sudo infernoctl status web1

# View logs from all VMs
infernoctl logs tail

# Stop the VM
sudo infernoctl stop web1

# Clean up
sudo infernoctl destroy web1
```

## Architecture

Inferno consists of three main components:

1. **infernoctl** (Bash) - CLI that manages VM lifecycle, networking, and state
2. **kiln** (Go) - Firecracker supervisor that handles VM execution and vsock communication
3. **init** (Go) - Guest-side init process that bootstraps the environment and runs your application

```
┌─────────────────────────────────────────────┐
│  infernoctl (Bash CLI)                      │
│  ├─ VM creation & configuration             │
│  ├─ Network setup (TAP, nftables)           │
│  └─ State management (SQLite)               │
└────────────────┬────────────────────────────┘
                 │ spawns
┌────────────────▼────────────────────────────┐
│  kiln (Go supervisor)                       │
│  ├─ Firecracker lifecycle management        │
│  ├─ Vsock communication                     │
│  └─ Log aggregation                         │
└────────────────┬────────────────────────────┘
                 │ launches
┌────────────────▼────────────────────────────┐
│  Firecracker microVM                        │
│  └─ init (Go process)                       │
│     ├─ Mount filesystems                    │
│     ├─ Configure network                    │
│     ├─ Run container process                │
│     └─ Handle signals                       │
└─────────────────────────────────────────────┘
```

## Commands

### VM Management

```bash
# Create VM
infernoctl create <name> --image <image> [--vcpus N] [--memory MB]

# Start VM
infernoctl start <name> [--detach]

# Stop VM
infernoctl stop <name> [--signal SIGTERM] [--timeout SECONDS]

# Destroy VM
infernoctl destroy <name> [--yes] [--keep-logs]
```

### VM Inspection

```bash
# List all VMs
infernoctl list [--format table|json] [--state created|running|stopped]
infernoctl ls   [--format table|json] [--state created|running|stopped]

# Get detailed VM status
infernoctl status <name> [--format human|json]
```

### Logging

```bash
# Tail combined logs
infernoctl logs tail

# Manage global log socket
infernoctl logs {start|stop|restart|status|clear}
```

### Image Inspection

```bash
# Get container metadata
infernoctl images process <image>

# List exposed ports
infernoctl images exposed <image>
```

### System

```bash
# Show version
infernoctl version

# Show environment
infernoctl env print

# Initialize data directory
infernoctl init
```

## Configuration

Inferno reads configuration from:
1. Environment variables (`INFERNO_ROOT`, `INFERNO_SHARE_DIR`)
2. `/etc/inferno/env` (system-wide settings)
3. Built-in defaults

**Key directories:**
- Data: `~/.local/share/inferno/` (dev) or `/var/lib/inferno/` (prod)
- Binaries: `/usr/share/inferno/`
- Scripts: `/usr/local/lib/inferno/scripts/`

**Environment variables:**
```bash
export INFERNO_ROOT=~/.local/share/inferno  # Data directory
export INFERNO_SHARE_DIR=/usr/share/inferno # Binaries location
export LOG_LEVEL=DEBUG                       # Logging verbosity
```

## Examples

### Running Multiple VMs

```bash
# Create and start multiple VMs
for i in {1..3}; do
  sudo infernoctl create "web$i" --image nginx:latest
  sudo infernoctl start "web$i" --detach
done

# View all VMs
sudo infernoctl list

# View running VMs only
sudo infernoctl list --state running

# Get detailed status of a specific VM
sudo infernoctl status web1

# Stop all VMs
for i in {1..3}; do
  sudo infernoctl stop "web$i"
done
```

### Custom Resource Limits

```bash
# Create VM with 4 vCPUs and 2GB RAM
sudo infernoctl create db1 --image postgres:16 --vcpus 4 --memory 2048

# Start and check
sudo infernoctl start db1 --detach
```

### With Persistent Volumes

```bash
# Create volume (requires LVM setup)
infernoctl volume create data1 --size 10

# Attach to VM
sudo infernoctl create app1 --image myapp:latest --volume data1
```

## Troubleshooting

### VM Won't Start

**Symptom:** `infernoctl start` fails immediately

**Solutions:**
1. Check KVM is enabled: `lsmod | grep kvm`
2. Verify permissions: `ls -la ~/.local/share/inferno/vms/kiln/*/root/`
3. Check logs: `infernoctl logs tail`
4. Verify resources: `free -h` (enough RAM?), `df -h` (enough disk?)

### Network Connectivity Issues

**Symptom:** VM has no internet access

**Solutions:**
1. Verify TAP device exists: `ip link show | grep tap_inferno`
2. Check nftables rules: `sudo nft list ruleset | grep inferno`
3. Enable IP forwarding: `sysctl net.ipv4.ip_forward` (should be 1)
4. Check routing: `ip route get <guest_ip>`

### Control Socket Not Found

**Symptom:** `control.sock not found` when stopping VM

**Solutions:**
1. Check VM status: `sudo infernoctl status vm1` or `sudo infernoctl list`
2. Check VM is actually running: `ps aux | grep kiln`
3. Verify socket exists: `find ~/.local/share/inferno -name control.sock`
4. Check permissions: `stat <socket_path>`
5. Try hard kill: `sudo infernoctl stop vm1 --kill`

### Logs Not Appearing

**Symptom:** `infernoctl logs tail` shows nothing

**Solutions:**
1. Check global socket: `infernoctl logs status`
2. Restart logging: `infernoctl logs restart`
3. Verify socket permissions: `ls -la ~/.local/share/inferno/logs/vm_logs.sock`

## Building from Source

If you want to modify Inferno or contribute to development:

```bash
# Clone repository
git clone https://github.com/yourusername/inferno.git
cd inferno

# Build Go binaries
make build

# Install in dev mode
sudo ./scripts/install.sh --mode dev --user $USER

# Initialize
infernoctl init

# Test changes
sudo infernoctl create test1 --image alpine:latest
sudo infernoctl start test1
```

For detailed development documentation, see [CLAUDE.md](CLAUDE.md).

## How It Works

### VM Creation Flow

1. **Network Setup** - Allocate /30 subnet, create TAP device, configure nftables
2. **Image Processing** - Pull Docker image, extract to ext4 filesystem
3. **Version Generation** - Create unique ULID version for immutable artifact tree
4. **Configuration** - Generate firecracker.json, kiln.json, run.json
5. **Initramfs Packing** - Bundle init binary + run.json into cpio archive
6. **Asset Installation** - Place kernel, firecracker, kiln in versioned chroot

### VM Startup Flow

1. **Context Resolution** - Load VM metadata from database, locate versioned chroot
2. **Jailer Invocation** - Launch jailer with chroot, UID/GID, exec-file
3. **Kiln Execution** - Jailer drops privileges, executes kiln inside jail
4. **Firecracker Launch** - Kiln starts Firecracker with config
5. **VM Boot** - Kernel boots, init process mounts filesystems and configures network
6. **Process Start** - Init executes container entrypoint/cmd

### Communication Architecture

```
Host (infernoctl)
    ↓ HTTP over Unix socket
control.sock (Firecracker vsock mux)
    ↓ CONNECT <port>\n
Guest (init listening on vsock:10002)
    ↓ HTTP API
/v1/signal - Receive signals
/v1/status - Health check
/v1/ping   - Connectivity test
```

## Dependencies

**Required:**
- Linux kernel 4.14+ with KVM
- iproute2, nftables, sqlite3, jq, socat
- Docker or Podman

**Optional:**
- LVM2 (for volumes)
- HAProxy (for L7 routing)
- Vector.dev (for log aggregation)

## Project Status

Inferno is **experimental** software. It's functional for basic use cases but not production-ready.

**Current focus:**
- Stability and bug fixes
- Documentation improvements
- Performance optimization

**Known limitations:**
- No live migration
- No snapshots
- Limited resource enforcement
- Basic logging (no rotation)
