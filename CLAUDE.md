# Inferno Development Guide for Claude Code

## About Inferno

Inferno is a lightweight container runtime that runs Docker/OCI images as Firecracker microVMs instead of traditional containers. Think "Docker but with VM-level isolation."

**Current Architecture:** Primarily bash-based CLI layer (`scripts/`) with critical binaries:
- **jailer** - Firecracker's security tool (Rust) - chroot, cgroups, privilege dropping, then exec() into kiln
- **kiln** - Firecracker supervisor (Go) - vsock communication, lifecycle management
- **init** - Guest-side init process (Go) - bootstraps VM and runs containerized process

**Not a daemon:** Unlike Docker, Inferno doesn't run a background daemon. Each VM is a standalone process supervised by `kiln`.

## Process Execution Architecture (CRITICAL)

**MUST READ FIRST:** Before working on any code, understand the jailer → kiln → firecracker execution flow.

See [README.md - Process Execution Flow](README.md#process-execution-flow-critical-for-understanding-inferno) for complete details including:
- The four binaries and their roles
- How `exec()` transforms jailer into kiln (same PID!)
- Complete execution flow with cgroup setup
- Process tree examples
- Cgroup hierarchy structure
- Resource limit conversion formulas (vcpus → cpu.max, memory → memory.max)

**Key takeaway:** The jailer creates cgroups and adds its PID, then `exec()`s into kiln **without changing PID**. This is why resource limits work - kiln and Firecracker inherit the cgroup membership.

## Project Structure

```
inferno/
├── scripts/              # PRIMARY INTERFACE - Bash CLI and library functions
│   ├── infernoctl.sh     # Main CLI wrapper (create, start, stop, destroy, logs)
│   ├── install.sh        # Installation script (dev/prod modes)
│   ├── env.sh            # Environment setup and path configuration
│   ├── config.sh         # JSON generators (firecracker.json, kiln.json, run.json)
│   ├── libvnet.sh        # Network setup (TAP, IP allocation, nftables)
│   ├── libvol.sh         # LVM volume management
│   ├── database.sh       # SQLite helpers for VM/network/volume state
│   ├── images.sh         # Docker/Podman integration (inspect, extract)
│   ├── haproxy.sh        # L7 load balancing configuration
│   ├── logging.sh        # Logging utilities with color/level support
│   ├── ssh.sh            # SSH key generation for VMs
│   └── schema.sql        # SQLite schema (vms, routes, volumes, versions)
├── cmd/
│   ├── kiln/             # Firecracker supervisor (Go)
│   └── init/             # Guest init process (Go)
├── internal/             # Go packages for kiln/init
│   ├── kiln/             # Kiln config, API, exit status
│   ├── image/            # run.json struct definitions
│   ├── vsock/            # Vsock port definitions
│   ├── process/          # Process execution, SSH handling
│   └── ...
├── bin/                  # Compiled binaries (after make build)
├── /usr/share/inferno/   # Installed binaries (kiln, init, firecracker, vmlinux)
├── /usr/local/lib/inferno/scripts/  # Installed scripts
└── ~/.local/share/inferno/  # Data directory (dev mode)
    ├── vms/kiln/<VERSION>/  # Versioned chroot per VM
    ├── images/           # Container rootfs images
    ├── volumes/          # LVM volumes (if configured)
    └── logs/             # VM logs and global socket
```

**Key Insight:** The project **looks** like a Go project but **runs** as bash scripts that shell out to Go binaries.

## Development Workflow

### Building from Source

```bash
# Build Go binaries (kiln + init)
make build

# Compile output: bin/kiln, bin/init

# Optional: Build with debug symbols
go build -gcflags="all=-N -l" -o bin/kiln ./cmd/kiln
go build -gcflags="all=-N -l" -o bin/init ./cmd/init
```

### Installation

**Dev Mode** (recommended for development):
```bash
# Install to /usr/local + ~/.local/share/inferno
sudo ./scripts/install.sh --mode dev --user $USER

# What this does:
# - Creates inferno group, adds your user
# - Installs scripts to /usr/local/lib/inferno/scripts/
# - Installs binaries to /usr/share/inferno/
# - Creates CLI wrapper: /usr/local/bin/infernoctl
# - Sets up ~/.local/share/inferno/ as INFERNO_ROOT
# - Auto-initializes database as your user
```

**Prod Mode** (system-wide installation):
```bash
sudo ./scripts/install.sh --mode prod

# Uses /var/lib/inferno instead of ~/.local/share/inferno
# Does NOT auto-initialize database (security)
```

**LVM Rootfs Setup** (recommended for efficiency):

Inferno uses **LVM thin snapshots** by default for rootfs deduplication and ephemeral behavior. This provides:
- **Deduplication**: 10 VMs from same image = ~1.5GB vs 10GB
- **Always ephemeral**: Snapshots deleted on stop, fresh state on start
- **Static 5GB** per base image (configurable via `ROOTFS_SIZE_MB`)

**Option 1: Loopback Device (Testing/Development)**
```bash
# Create a 30GB sparse file (uses minimal space initially)
sudo truncate -s 30G /var/lib/inferno_rootfs.img

# Set up as loopback device
sudo losetup -f /var/lib/inferno_rootfs.img

# Find the loopback device name
LOOP_DEV=$(sudo losetup -j /var/lib/inferno_rootfs.img | cut -d: -f1)
echo "Loop device: $LOOP_DEV"  # e.g., /dev/loop0

# Install with loopback device
sudo ./scripts/install.sh --mode dev --rootfs-disk $LOOP_DEV --user $USER

# What this does:
# - Creates physical volume on loop device
# - Creates volume group: inferno_rootfs_vg
# - Creates thin pool: rootfs_pool (20GB)
# - Enables LVM mode by default
```

**To make loopback persistent across reboots**, add to `/etc/rc.local` or systemd:
```bash
# /etc/systemd/system/inferno-loopback.service
[Unit]
Description=Setup Inferno rootfs loopback device
Before=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/losetup -f /var/lib/inferno_rootfs.img
RemainAfterExit=yes

[Install]
WantedBy=local-fs.target
```

**Option 2: Real Disk (Production)**
```bash
# Identify available disk
lsblk

# Install with dedicated disk (CAUTION: erases disk!)
sudo ./scripts/install.sh --mode prod --rootfs-disk /dev/sdb

# What this does:
# - Creates physical volume on /dev/sdb
# - Creates volume group: inferno_rootfs_vg
# - Creates thin pool: rootfs_pool (20GB, expandable)
```

**Option 3: File-based Fallback (No LVM)**
```bash
# Install without --rootfs-disk
sudo ./scripts/install.sh --mode dev --user $USER

# Behavior:
# - Falls back to 1GB file per VM (no deduplication)
# - Still works, just less efficient
# - Each VM creates ~/.local/share/inferno/vms/kiln/*/root/rootfs.img
```

**Verify LVM Setup:**
```bash
# Check volume group
sudo vgs inferno_rootfs_vg

# Check thin pool
sudo lvs inferno_rootfs_vg/rootfs_pool

# Monitor pool usage
sudo lvs --units g -o lv_name,data_percent inferno_rootfs_vg/rootfs_pool
```

### Running Inferno

**Initialize data directory** (first time only, or after changing INFERNO_ROOT):
```bash
infernoctl init
# Creates: images/, vms/, volumes/, logs/, inferno.db
# Starts global VM logs socket
```

**Create a VM from a Docker image:**
```bash
# Basic usage
sudo infernoctl create web1 --image nginx:latest

# With resource limits
sudo infernoctl create db1 --image postgres:16 --vcpus 2 --memory 512

# With attached volume
sudo infernoctl create app1 --image myapp:latest --volume vol_abc123
```

**Start a VM:**
```bash
# Foreground (see logs in terminal)
sudo infernoctl start web1

# Background (detached)
sudo infernoctl start web1 --detach
```

**View logs:**
```bash
# Tail combined logs from all VMs
infernoctl logs tail

# Manage global logs socket
infernoctl logs status
infernoctl logs restart
```

**Stop a VM:**
```bash
# Graceful shutdown (SIGTERM, 10s timeout)
sudo infernoctl stop web1

# Force kill if timeout exceeded
sudo infernoctl stop web1 --kill --timeout 5
```

**Destroy a VM:**
```bash
# Interactive confirmation
sudo infernoctl destroy web1

# Auto-confirm (dangerous!)
sudo infernoctl destroy web1 --yes

# Keep logs after destroy
sudo infernoctl destroy web1 --keep-logs
```

## Before Making Changes

### Understanding the Versioned Chroot System

**CRITICAL:** Inferno uses immutable versioned chroots. Each `create` generates a ULID version ID and builds an isolated tree:

```
~/.local/share/inferno/vms/kiln/01ARZ3NDEKTSV4RRFFQ69G5FAV/
├── root/                    # Jailer chroot
│   ├── firecracker          # VM binary
│   ├── vmlinux              # Kernel
│   ├── rootfs.img           # Container filesystem (ext4)
│   ├── initrd.cpio          # Init ramdisk
│   ├── kiln.json            # Supervisor config
│   ├── firecracker.json     # VM config
│   └── vm_logs.sock         # Link to global socket
├── initramfs/inferno/
│   ├── init                 # Init binary
│   └── run.json             # Guest config
└── kiln                     # Executable link
```

**Why versioned?**
- Enables VM recreation with exact same binaries
- Isolates versions; old VMs don't corrupt new ones
- Supports future multi-version kiln upgrades

**Implication:** Changing kiln/init code requires rebuilding AND creating new VMs. Existing VMs use old binaries.

### Configuration Hierarchy

**Precedence (highest to lowest):**
1. CLI flags (`--vcpus`, `--memory`, etc.)
2. Environment variables (`INFERNO_ROOT`, `INFERNO_SHARE_DIR`)
3. `/etc/inferno/env` (system config)
4. Defaults in `scripts/env.sh`

**Key configs:**
- **kiln.json** (inside chroot) - Supervisor config: UID/GID, resources, socket paths
- **firecracker.json** (inside chroot) - VM machine config: kernel, drives, vsock
- **run.json** (inside initramfs) - Guest init config: process, network, mounts, SSH

### Communication Architecture

**Host ↔ Guest via Firecracker vsock:**

```
infernoctl stop web1
    ↓
send_vm_signal() in infernoctl.sh
    ↓
POST /v1/signal {"signal": 15}
    ↓
socat → control.sock (Firecracker UDS)
    ↓
CONNECT 10002\n (Firecracker mux protocol)
    ↓
Guest vsock listener (init)
    ↓
Init receives signal, forwards to child process
```

**Port assignments:**
- **10000:** Stdout/stderr from init → kiln
- **10001:** Exit status from init → kiln
- **10002:** HTTP API (guest init) ← host

**Firecracker mux quirk:** Can't send raw HTTP. Must prepend `CONNECT <port>\n` before HTTP request.

### Network Isolation

Each VM gets:
- **TAP device** (tap_inferno_<name>) owned by UID 123:GID 100
- **Private /30 subnet** in 172.16.x.0/30 range
- **NAT masquerading** via nftables for outbound traffic
- **No direct guest-guest communication** (isolated by design)

Expose services via:
- **L7 routing** (HAProxy with host-based routing)
- **L4 forwarding** (nftables port forwarding)

### Testing Changes

**Bash script changes:**
```bash
# Syntax check all scripts
for f in scripts/*.sh; do bash -n "$f" || echo "Error in $f"; done

# Reinstall scripts only (fast)
sudo rsync -a scripts/ /usr/local/lib/inferno/scripts/

# Test create workflow
sudo infernoctl create test1 --image alpine:latest
sudo infernoctl start test1 --detach
sudo infernoctl stop test1
sudo infernoctl destroy test1 --yes
```

**Go code changes (kiln/init):**
```bash
# Rebuild binaries
make build

# Reinstall (copies to /usr/share/inferno/)
sudo ./scripts/install.sh --mode dev --user $USER

# Create NEW VM to use new binaries
sudo infernoctl create test2 --image nginx:latest
sudo infernoctl start test2

# IMPORTANT: Old VMs still use old kiln/init from their versioned chroot
```

**Database changes:**
```bash
# Edit scripts/schema.sql
# Drop and recreate DB
rm ~/.local/share/inferno/inferno.db
infernoctl init
```

## After Making Changes

### Code Quality Checks

**Bash:**
```bash
# Shellcheck (if installed)
shellcheck scripts/*.sh

# Basic syntax validation
bash -n scripts/infernoctl.sh
```

**Go:**
```bash
# Format code
go fmt ./...

# Vet for common mistakes
go vet ./...

# Optional: golangci-lint
golangci-lint run
```

### Cleanup Between Tests

```bash
# Nuclear option: wipe everything
sudo make clean
rm -rf ~/.local/share/inferno/

# Selective cleanup
sudo infernoctl destroy test1 --yes  # Per-VM cleanup
infernoctl logs clear                # Clear combined logs
```

### Common Issues After Changes

**Problem:** `control.sock not found` after kiln changes
- **Cause:** Kiln crashed during startup
- **Debug:** Check `~/.local/share/inferno/logs/<vmname>.log`
- **Fix:** Add debug logging to kiln, rebuild, test

**Problem:** Init doesn't apply new config changes
- **Cause:** Still reading old run.json from old initrd
- **Fix:** Destroy VM, create new one (versioned chroot issue)

**Problem:** Network not working after libvnet.sh changes
- **Cause:** nftables rules not applied, or TAP device permissions wrong
- **Debug:** `sudo nft list ruleset`, `ip link show`, check TAP ownership
- **Fix:** Verify UID 123:GID 100 owns TAP, check nft rules exist

## Code Changes Best Practices

### Bash Script Changes

**DO:**
- Use `local` for function variables to avoid global namespace pollution
- Quote all variable expansions: `"$var"` not `$var`
- Check exit codes: `|| { warn "failed"; return 1; }`
- Use `set -euo pipefail` for strict error handling (already in logging.sh)
- Use existing logging functions: `info`, `warn`, `error`, `debug`, `die`
- Use existing JSON helpers: `jq` for parsing, `jq -cn` for generation

**DON'T:**
- Hard-code paths; use `$INFERNO_ROOT`, `$INFERNO_SHARE_DIR` from env.sh
- Use `sudo` inside scripts; require root at entry point (`require_root()`)
- Parse JSON with sed/awk; use `jq`
- Create global state; prefer DB or config files

**Example: Adding a new infernoctl command**

```bash
# In infernoctl.sh

cmd_restart() {
  require_root
  local name="$1"
  [[ -n "$name" ]] || die 2 "Usage: infernoctl restart <name>"

  info "Restarting ${name}..."
  cmd_stop "$name" || warn "Stop failed, continuing"
  sleep 1
  cmd_start "$name" --detach
}

# Add to main() dispatch
main() {
  case "$sub" in
    restart) cmd_restart "$@";;
    # ... existing cases
  esac
}
```

### Go Code Changes

**kiln changes:**
- Config loading: See `internal/kiln/config.go`
- Firecracker interaction: `cmd/kiln/main.go` run() function
- Logging: Use `log.Info()`, `log.Debug()`, etc. from slog
- Vsock listeners: Existing ports defined in `internal/vsock/vsock.go`

**init changes:**
- Config loading: See `cmd/init/main.go` and `internal/image/config.go`
- Mounts: `cmd/init/mount.go`
- Network: `cmd/init/network.go`
- Process exec: `internal/process/primary.go`
- API server: `cmd/init/api.go`

**Example: Adding a new vsock port**

```go
// internal/vsock/vsock.go
const (
    StdoutPort     = 10000
    ExitPort       = 10001
    APIPort        = 10002
    MetricsPort    = 10003  // NEW
)

// Update kiln.json generation in scripts/config.sh
# "vsock_metrics_port": 10003

// Listen in kiln: cmd/kiln/main.go
go listenMetrics(ctx, cfg.VsockMetricsPort)
```

## Testing Strategy

### Unit Testing

**Bash functions:** Limited unit testing available. Prefer integration tests.

**Go code:**
```bash
# Run all tests
go test ./...

# Test specific package
go test ./internal/kiln

# With coverage
go test -cover ./...
```

### Integration Testing

**Create a test matrix:**
```bash
#!/bin/bash
# test-images.sh

images=(
  "alpine:latest"
  "nginx:latest"
  "postgres:16"
  "redis:7"
)

for img in "${images[@]}"; do
  name="test_$(echo "$img" | tr ':/' '_')"
  echo "Testing $img as $name"

  sudo infernoctl create "$name" --image "$img" || { echo "FAIL create $img"; continue; }
  sudo infernoctl start "$name" --detach || { echo "FAIL start $img"; continue; }
  sleep 2
  sudo infernoctl stop "$name" || echo "FAIL stop $img"
  sudo infernoctl destroy "$name" --yes || echo "FAIL destroy $img"
done
```

**Test network isolation:**
```bash
# Create two VMs
sudo infernoctl create vm1 --image alpine:latest
sudo infernoctl create vm2 --image alpine:latest

# Check IPs
sqlite3 ~/.local/share/inferno/inferno.db "SELECT name, guest_ip FROM vms;"

# Verify isolation: VMs should NOT be able to ping each other
```

### Debugging Techniques

**Kiln debugging:**
```bash
# Enable debug logging in kiln.json
jq '.log.debug = true' kiln.json > tmp.json && mv tmp.json kiln.json

# Attach to running kiln process
ps aux | grep kiln
sudo strace -p <kiln_pid>
```

**Init debugging:**
```bash
# Check init logs (sent via vsock to kiln)
infernoctl logs tail

# Enable debug in run.json
jq '.log.debug = true' run.json > tmp.json && mv tmp.json run.json
```

**Network debugging:**
```bash
# List nftables rules
sudo nft list ruleset | grep inferno

# Check TAP devices
ip link show | grep tap_inferno

# Test vsock connectivity
./scripts/ping_vsock.sh <vm_name>
```

**Database inspection:**
```bash
# SQLite console
sqlite3 ~/.local/share/inferno/inferno.db

# Useful queries
.schema
SELECT * FROM vms;
SELECT * FROM vms_versions;
SELECT * FROM network_state;
```

## Performance Considerations

### VM Startup Time

**Factors:**
- Image size (rootfs.img extraction)
- Initrd size (keep minimal)
- Kernel boot time (~100-200ms)
- Init mount/network setup (~50-100ms)

**Optimization tips:**
- Use smaller base images (alpine vs ubuntu)
- Pre-extract frequently used images
- Consider kernel boot args tuning

### Resource Limits

**Firecracker defaults:**
- 1 vCPU, 128MB RAM (set via --vcpus, --memory)
- Max ~4000 VMs per host (firecracker limit)

**Host requirements:**
- 1 TAP device per VM
- ~200MB RAM overhead per VM (firecracker + kiln + init)
- File descriptors: ~50 per VM

### Database Performance

**SQLite WAL mode:** Not currently enabled. Consider for high-concurrency workloads:
```sql
PRAGMA journal_mode=WAL;
```

**Indexing:** Current schema has indexes on foreign keys. Add as needed.

## Error Handling

### Bash Error Handling

**Enabled globally via logging.sh:**
```bash
set -euo pipefail  # Exit on error, undefined vars, pipe failures
```

**Function error handling:**
```bash
some_command || { warn "Command failed"; return 1; }
some_command || die 1 "Fatal error"  # Exit entire script
```

**Best practices:**
- Always check exit codes of critical operations
- Use `|| true` only when failure is genuinely optional
- Clean up resources on error (rm temp files, kill processes)

### Go Error Handling

**Standard pattern:**
```go
if err := someFunc(); err != nil {
    return fmt.Errorf("descriptive context: %w", err)
}
```

**Logging errors:**
```go
log.Error("operation failed", "error", err, "context", value)
```

## Common Pitfalls to Avoid

### 1. Forgetting VM Immutability

**WRONG:**
```bash
# Edit kiln.json in existing VM's chroot
vim ~/.local/share/inferno/vms/kiln/01ABC.../root/kiln.json
# Changes ignored; kiln already running with old config
```

**RIGHT:**
```bash
# Destroy and recreate with new version
sudo infernoctl destroy vm1 --yes
sudo infernoctl create vm1 --image nginx:latest
```

### 2. Hardcoding UID/GID

**WRONG:**
```bash
chown 100:100 "$file"  # Might not match INFERNO_JAIL_UID
```

**RIGHT:**
```bash
chown "${JAIL_UID}:${JAIL_GID}" "$file"
```

### 3. Not Checking for Running VMs

**WRONG:**
```bash
sudo infernoctl destroy vm1 --yes  # Fails if VM running
```

**RIGHT:**
```bash
sudo infernoctl stop vm1 || true
sudo infernoctl destroy vm1 --yes
```

### 4. Assuming Socket Permissions

**WRONG:**
```bash
echo "test" | socat - UNIX-CONNECT:/path/to/control.sock
# Fails if socket owned by jailed UID
```

**RIGHT:**
```bash
# Use sudo -u with correct user, or run as root
local user; user="$(getent passwd "$JAIL_UID" | cut -d: -f1)"
echo "test" | sudo -u "$user" socat - UNIX-CONNECT:/path/to/control.sock
```

### 5. Not Handling Firecracker Mux Protocol

**WRONG:**
```bash
printf "GET /v1/ping HTTP/1.1\r\n\r\n" | socat - UNIX-CONNECT:control.sock
# Firecracker expects CONNECT prelude
```

**RIGHT:**
```bash
_vsock_http_mux "$sock" "$port" "GET" "/v1/ping" ""
# Uses: printf "CONNECT %d\n%s" "$port" "$http_request"
```

## Configuration

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `INFERNO_ROOT` | ~/.local/share/inferno (dev)<br>/var/lib/inferno (prod) | Data directory |
| `INFERNO_SHARE_DIR` | /usr/share/inferno | Binaries location |
| `INFERNO_JAIL_UID` | 123 | Jailed UID |
| `INFERNO_JAIL_GID` | 100 | Jailed GID |
| `LOG_LEVEL` | INFO | Logging level |
| `DB_PATH` | $INFERNO_ROOT/inferno.db | SQLite database |
| `VG_NAME` | inferno_vg | LVM volume group |

### System Configuration Files

| File | Purpose |
|------|---------|
| `/etc/inferno/env` | System-wide config (sourced by infernoctl wrapper) |
| `/etc/haproxy/haproxy.cfg` | L7 routing config (managed by haproxy.sh) |
| `/usr/local/bin/infernoctl` | CLI wrapper (sources env, calls scripts) |

### Per-VM Configuration

Generated during `create`:
- **kiln.json** - Supervisor config
- **firecracker.json** - VM machine config
- **run.json** - Guest init config

## Shell Tools Usage

### File Operations

**Finding files:**
```bash
# Find all bash scripts
find scripts/ -name "*.sh"

# Find large rootfs images
find ~/.local/share/inferno/images/ -type f -size +500M
```

**Searching code:**
```bash
# Grep for function definitions
grep -r "^cmd_.*() {" scripts/

# Find all uses of INFERNO_ROOT
grep -r "INFERNO_ROOT" scripts/
```

### JSON Processing

**Querying VM state:**
```bash
# Get VM guest IP
jq -r '.network.guest_ip' <<< "$network_config"

# Parse firecracker config
jq -r '.["boot-source"].kernel_image_path' firecracker.json

# Update config value
jq '.resources.vcpu_count = 2' kiln.json > tmp.json && mv tmp.json kiln.json
```

### Database Queries

```bash
# List all VMs with network info
sqlite3 ~/.local/share/inferno/inferno.db <<SQL
SELECT v.name, v.guest_ip, n.state
FROM vms v
JOIN network_state n ON v.id = n.vm_id;
SQL

# Find VMs using specific version
sqlite3 ~/.local/share/inferno/inferno.db \
  "SELECT vm_id, version FROM vms_versions WHERE version = '01ABC...';"
```

### Network Inspection

```bash
# List nftables rules
sudo nft list ruleset | grep inferno

# Show TAP devices
ip link show | grep tap_inferno

# Route to specific guest
ip route get 172.16.1.2
```

## Key Components Deep Dive

### infernoctl.sh Architecture

**Loading sequence:**
1. Bootstrap (`scripts/env.sh`) - Sets paths, defaults
2. Logging (`scripts/logging.sh`) - Enables error handlers, log functions
3. Config (`scripts/config.sh`) - JSON generators
4. Optional libs (database, images, networking, volumes, HAProxy, SSH)

**Command dispatch:**
```bash
main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    create)  cmd_create "$@";;
    start)   cmd_start "$@";;
    stop)    cmd_stop "$@";;
    destroy) cmd_destroy "$@";;
    # ...
  esac
}
```

**Context resolution:**
- `_resolve_vm_ctx()` - Sets VM_ROOT, CHROOT_DIR, JAIL_ID, JAIL_UID/GID, KILN_EXEC
- Used by start/stop/destroy to locate VM resources

### Versioning System

**ULID generation:**
```bash
_ulid_new() {
  local ts; ts="$(date +%s%3N)"  # Milliseconds since epoch
  printf "%026s\n" "$(printf "%x" "$ts" | tr '[:lower:]' '[:upper:]')"
  # Simplified; real impl includes random component
}
```

**Version immutability:**
- Version recorded in `vms_versions` table
- Chroot path: `$INFERNO_ROOT/vms/kiln/<VERSION>/root/`
- Once created, never modified (except runtime files: PIDs, sockets)

### Global Logs Socket

**Creation:**
```bash
socat -u \
  "UNIX-LISTEN:${global_socket},fork,mode=666" \
  "SYSTEM:while IFS= read -r line; do \
    echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] \$line\" >> '$global_log_file'; \
  done" &
```

**Why global?**
- Centralized log aggregation
- Single output file for all VMs
- Simplifies log shipping (vector.dev, etc.)

**Per-VM linking:**
- Hard link or symlink global socket into each chroot
- Kiln writes to `./vm_logs.sock` (relative to chroot)
- All writes → same global listener

## Current Implementation Status

### Completed Features

- [x] VM creation from Docker/OCI images
- [x] VM start/stop with graceful shutdown
- [x] VM destroy with cleanup
- [x] Versioned chroot system
- [x] Network isolation (TAP + nftables)
- [x] Vsock communication (stdout, exit status, API)
- [x] Global logging socket
- [x] SQLite state management
- [x] HAProxy L7 routing (basic)
- [x] SSH key injection
- [x] LVM volume support (basic)
- [x] Dev/prod installation modes

### Planned/Incomplete Features

- [ ] VM snapshots
- [ ] Live migration
- [ ] Resource limits enforcement (cgroups)
- [ ] Multi-tenancy / namespaces
- [ ] Image caching (currently pulls every time)
- [ ] Log rotation
- [ ] Metrics collection
- [ ] Health checks
- [ ] Auto-restart on crash
- [ ] Container registries (private auth)

## Important Notes for Claude Code

### When Modifying Bash Scripts

- Always test with `bash -n <script>` before committing
- Respect existing function boundaries; don't create mega-functions
- Use existing helpers (`die`, `warn`, `info`, `jq`, etc.)
- Document complex logic with inline comments
- Update this CLAUDE.md if you add new commands or workflows

### When Modifying Go Code

- Run `go fmt ./...` before committing
- Update internal/*/README.md if you change package structure
- Rebuild (`make build`) AND reinstall (`install.sh`) to test
- Remember: Old VMs use old binaries from versioned chroots

### When Adding Dependencies

**Bash:**
- Add to `dependencies.sh` with version check if possible
- Update install.sh to install via package manager or download

**Go:**
- Run `go get <package>`
- Run `go mod tidy`
- Check vendor/ if vendoring (currently not vendored)

### When Changing Database Schema

1. Edit `scripts/schema.sql`
2. Add migration logic to `database.sh` (or document manual steps)
3. Test with fresh DB: `rm inferno.db && infernoctl init`
4. Document in this file under "Database Changes"

### When Updating README.md

Keep README focused on user-facing guide:
- Installation instructions
- Quick start examples
- Troubleshooting common issues

Keep CLAUDE.md (this file) focused on developer guide:
- Architecture details
- Development workflow
- Testing strategies
- Code patterns

## Getting Help

- Check `infernoctl --help` for command usage
- Read function comments in `scripts/*.sh`
- Inspect database schema: `sqlite3 inferno.db ".schema"`
- Review recent commits for examples of changes
- Test changes in isolated environment (VM or container)

## Common Development Workflows

### Adding a New VM Config Option

1. Add field to run.json generator in `scripts/config.sh`
2. Update `internal/image/config.go` struct if needed
3. Handle in `cmd/init/main.go` or appropriate handler
4. Rebuild init: `make build`
5. Reinstall: `sudo ./scripts/install.sh --mode dev`
6. Test with new VM: `sudo infernoctl create test --image alpine`

### Changing Network Configuration

1. Edit `scripts/libvnet.sh`
2. Test nftables rules: `sudo nft list ruleset`
3. Verify TAP creation: `ip link show`
4. Test with new VM (old VMs use old network state)
5. Update `scripts/schema.sql` if adding DB fields

### Debugging a Crash

1. Enable debug logging: `export LOG_LEVEL=DEBUG`
2. Check kiln logs: `~/.local/share/inferno/logs/<vmname>.log`
3. Check VM logs: `infernoctl logs tail`
4. Inspect database state: `sqlite3 inferno.db`
5. Check for stale PIDs: `ps aux | grep kiln`
6. Verify socket permissions: `ls -la ~/.local/share/inferno/vms/kiln/*/root/`

---

**Last Updated:** 2026-01-17 (version tracking started)
