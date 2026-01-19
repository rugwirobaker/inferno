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

### LVM Rootfs Setup (Recommended)

For efficient storage with deduplication and ephemeral rootfs, set up LVM thin provisioning:

**Testing/Development with loopback device:**
```bash
# Create a 30GB sparse file
sudo truncate -s 30G /var/lib/inferno_rootfs.img
sudo losetup -f /var/lib/inferno_rootfs.img

# Install with loopback device
LOOP_DEV=$(sudo losetup -j /var/lib/inferno_rootfs.img | cut -d: -f1)
sudo ./scripts/install.sh --mode dev --rootfs-disk $LOOP_DEV --user $USER
```

**Production with dedicated disk:**
```bash
# Use a dedicated disk (CAUTION: erases disk!)
sudo ./scripts/install.sh --mode prod --rootfs-disk /dev/sdb
```

Without `--rootfs-disk`, Inferno falls back to file-based rootfs (1GB per VM, no deduplication).

See [CLAUDE.md](CLAUDE.md#lvm-rootfs-setup-recommended-for-efficiency) for detailed setup instructions including persistent loopback configuration.

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

### High-Level Components

Inferno consists of four main components:

1. **infernoctl** (Bash) - CLI that manages VM lifecycle, networking, and state
2. **jailer** (Rust) - Firecracker's security isolation tool (chroot, cgroups, privilege dropping)
3. **kiln** (Go) - Firecracker supervisor that handles VM execution and vsock communication
4. **init** (Go) - Guest-side init process that bootstraps the environment and runs your application

```
┌─────────────────────────────────────────────┐
│  infernoctl (Bash CLI)                      │
│  ├─ VM creation & configuration             │
│  ├─ Network setup (TAP, nftables)           │
│  └─ State management (SQLite)               │
└────────────────┬────────────────────────────┘
                 │ spawns
┌────────────────▼────────────────────────────┐
│  jailer (Rust security layer)               │
│  ├─ Create chroot jail                      │
│  ├─ Set up cgroups (cpu, memory)            │
│  ├─ Drop privileges (setuid/setgid)         │
│  └─ exec() into kiln (same PID!)            │
└────────────────┬────────────────────────────┘
                 │ exec() transformation
┌────────────────▼────────────────────────────┐
│  kiln (Go supervisor)                       │
│  ├─ Firecracker lifecycle management        │
│  ├─ Vsock communication                     │
│  └─ Log aggregation                         │
└────────────────┬────────────────────────────┘
                 │ spawns child
┌────────────────▼────────────────────────────┐
│  Firecracker microVM                        │
│  └─ init (Go process)                       │
│     ├─ Mount filesystems                    │
│     ├─ Configure network                    │
│     ├─ Run container process                │
│     └─ Handle signals                       │
└─────────────────────────────────────────────┘
```

### Process Execution Flow (Critical for Understanding Inferno)

Understanding how processes are launched is essential for debugging and development. Inferno uses a specific execution pattern involving **process transformation** via the UNIX `exec()` system call.

#### The Four Binaries

1. **jailer** (`/usr/share/inferno/jailer`) - Rust binary from Firecracker project
   - Creates chroot jail in versioned directory
   - Sets up cgroups v2 for resource limits (cpu.max, memory.max)
   - Drops root privileges via setuid(123)/setgid(100)
   - Uses `exec()` to **transform into kiln** (same PID!)

2. **kiln** (`/usr/share/inferno/kiln`) - Go binary, Inferno's supervisor
   - Runs inside the chroot jail as non-root user (uid 123)
   - Sets up vsock Unix sockets for guest communication
   - Spawns Firecracker as a child process
   - Monitors VM lifecycle and collects exit status

3. **firecracker** (`/usr/share/inferno/firecracker`) - Rust binary, VMM
   - Child process of kiln
   - Boots Linux kernel with initramfs
   - Provides device emulation (virtio, vsock)
   - Runs guest workload

4. **init** (`/initramfs/inferno/init`) - Go binary, runs inside the guest
   - First process in the VM (PID 1)
   - Mounts filesystems (rootfs, proc, sys, dev)
   - Configures network (assigns IP, sets routes)
   - Executes container entrypoint/cmd

#### Understanding exec() - The Key Transformation

The jailer uses the UNIX `exec()` system call to **replace itself** with kiln. This is **NOT** spawning a child process:

```
Before exec():                After exec():
PID 12345: /jailer     →      PID 12345: /kiln
(jailer code in memory)       (kiln code in memory)
```

**Why this matters:**
- Jailer and kiln are **the same process** (same PID)
- Cgroup membership is **preserved** across exec()
- File descriptors, working directory, and environment carry over
- The `jailer.pid` file contains what is now kiln's PID
- In `ps` output, you see `/kiln`, not `/jailer` (jailer code is gone)

This is why resource limits work: the jailer creates cgroups and adds its PID to them, then exec's into kiln **without changing PID**, so kiln (and its child Firecracker) inherit the cgroup limits.

#### Complete Execution Flow with All Details

```
┌─────────────────────────────────────────────────────────────────────┐
│ Step 1: infernoctl.sh (bash script, running as root)               │
│                                                                     │
│  • Builds jail directory: ~/.local/share/inferno/vms/kiln/<ULID>/  │
│  • Reads resource limits from database                              │
│  • Converts limits to cgroup format:                                │
│    - vcpus=1  → cpu.max="100000 100000"  (1 core)                  │
│    - memory=128 → memory.max="134217728"  (128MB in bytes)         │
│  • Executes jailer with full flags:                                 │
│                                                                     │
│    /usr/share/inferno/jailer \                                      │
│      --id <version-ulid> \                                          │
│      --exec-file /usr/share/inferno/kiln \                          │
│      --uid 123 --gid 100 \                                          │
│      --cgroup-version 2 \                                           │
│      --parent-cgroup firecracker \                                  │
│      --cgroup "cpu.max=100000 100000" \                             │
│      --cgroup "memory.max=134217728" \                              │
│      --chroot-base-dir ~/.local/share/inferno/vms/kiln \            │
│      --                                                             │
│                                                                     │
│  • Saves jailer's PID to <vm-root>/jailer.pid                       │
└─────────────────────────────────────────────────────────────────────┘
                              ↓ fork() + exec()
┌─────────────────────────────────────────────────────────────────────┐
│ Step 2: jailer (PID 65393, running as root temporarily)            │
│                                                                     │
│  • Creates chroot at: ~/.local/share/inferno/vms/kiln/<ULID>/root/ │
│  • Creates cgroup hierarchy:                                        │
│    /sys/fs/cgroup/firecracker/<ULID>/                              │
│  • Writes cgroup files:                                             │
│    - cpu.max ← "100000 100000"                                      │
│    - memory.max ← "134217728"                                       │
│  • Adds own PID (65393) to cgroup.procs                             │
│  • chroot() into jail directory                                     │
│  • setuid(123), setgid(100) - drops root privileges                │
│  • exec("/kiln") - REPLACES JAILER CODE WITH KILN                   │
│    (same PID 65393, still in cgroup!)                               │
└─────────────────────────────────────────────────────────────────────┘
                              ↓ exec() - SAME PID!
┌─────────────────────────────────────────────────────────────────────┐
│ Step 3: kiln (PID 65393, uid 123, inside chroot jail)              │
│                                                                     │
│  • Working directory: / (inside chroot)                             │
│  • Reads ./kiln.json from current directory                         │
│  • Sets up vsock Unix socket listeners:                             │
│    - control.sock_10000 (stdout from guest)                         │
│    - control.sock_10001 (exit status from guest)                    │
│  • Writes kiln.pid file (contains 65393)                            │
│  • Executes Firecracker:                                            │
│                                                                     │
│    /firecracker \                                                   │
│      --id <version-ulid> \                                          │
│      --api-sock firecracker.sock \                                  │
│      --config-file firecracker.json                                 │
│                                                                     │
│  • Waits for Firecracker process, collects exit status             │
└─────────────────────────────────────────────────────────────────────┘
                              ↓ fork() + exec()
┌─────────────────────────────────────────────────────────────────────┐
│ Step 4: firecracker (PID 65403, child of kiln, uid 123)           │
│                                                                     │
│  • Inherits cgroup limits from parent (kiln/jailer)                 │
│  • Reads ./firecracker.json                                         │
│  • Opens /dev/kvm for virtualization                                │
│  • Boots Linux kernel (vmlinux) with initramfs                      │
│  • Guest init process starts inside VM                              │
│  • Guest connects back via vsock for logs/status                    │
└─────────────────────────────────────────────────────────────────────┘
```

#### Process Tree Example

When you inspect a running VM, here's what you see:

```bash
$ cat ~/.local/share/inferno/vms/web1/jailer.pid
65393

$ ps -p 65393 -o pid,ppid,cmd,user
    PID    PPID CMD                              USER
  65393       1 /kiln --id 19BD59DBC0DEC8E...   123

$ pstree -p 65393
kiln(65393)───firecracker(65403)─┬─{firecracker}(65406)
                                  └─{firecracker}(65411)
```

**Key observations:**
- The jailer is **not visible** in the process tree (it exec'd into kiln)
- `jailer.pid` contains **65393**, which is now running `/kiln`
- Firecracker (PID 65403) is a **child** of kiln (normal parent-child)
- Both processes run as uid **123** (non-root)

#### Cgroup Hierarchy on Disk

```bash
$ cat /sys/fs/cgroup/firecracker/19BD59DBC0DEC8E443D2517C000/cgroup.procs
65393   # kiln
65403   # firecracker (inherited from parent)

$ cat /sys/fs/cgroup/firecracker/19BD59DBC0DEC8E443D2517C000/cpu.max
100000 100000   # 1 full CPU core

$ cat /sys/fs/cgroup/firecracker/19BD59DBC0DEC8E443D2517C000/memory.max
134217728   # 128 MiB

$ cat /sys/fs/cgroup/firecracker/19BD59DBC0DEC8E443D2517C000/memory.current
67108864    # Currently using ~64 MiB
```

#### Resource Limit Conversion Reference

When configuring VMs, resources are specified in friendly units and converted to cgroup format:

**CPU Limits (cpu.max):**
- Format: `<quota> <period>` (both in microseconds)
- 1 vCPU = `100000 100000` (100ms quota / 100ms period = 100%)
- 2 vCPUs = `200000 100000` (200ms quota / 100ms period = 200%)
- 0.5 vCPU = `50000 100000` (50ms quota / 100ms period = 50%)
- 4 vCPUs = `400000 100000` (400ms quota / 100ms period = 400%)

**Memory Limits (memory.max):**
- Format: `<bytes>` (decimal, no suffixes in cgroup file)
- 128 MB = 128 × 1024 × 1024 = `134217728`
- 256 MB = 256 × 1024 × 1024 = `268435456`
- 512 MB = 512 × 1024 × 1024 = `536870912`
- 1 GB = 1024 × 1024 × 1024 = `1073741824`
- 2 GB = 2 × 1024 × 1024 × 1024 = `2147483648`

**Formula:**
```bash
cpu_quota=$((vcpus * 100000))
memory_bytes=$((memory_mb * 1024 * 1024))

--cgroup "cpu.max=${cpu_quota} 100000"
--cgroup "memory.max=${memory_bytes}"
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
