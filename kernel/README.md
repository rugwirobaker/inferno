# Inferno Custom Kernel

This directory contains the toolchain for building a minimal, optimized Linux kernel for Inferno microVMs.

## Why a Custom Kernel?

The Firecracker project provides generic kernels, but Inferno has specific requirements:

1. **RFC-005 (Guest-Side Encryption):** Requires device-mapper and dm-crypt built-in for LUKS volume unlocking
2. **Size Optimization:** Remove unnecessary drivers (USB, GPU, sound, wireless)
3. **Boot Speed:** No module loading infrastructure
4. **Future Features:** Container isolation, eBPF observability
5. **Traceability:** Document every config option and why it's needed

## Kernel Version

**Current Target:** Linux 5.10.245 (LTS until Dec 2026)

**Why 5.10.245?**
- Matches Firecracker v1.14.x official kernel version
- Contains critical vsock and virtio-mmio fixes
- Long-term support (security updates)
- Stable eBPF/BPF features
- Good virtio driver support

**Important:** Firecracker v1.14 requires Linux 5.10.245 specifically. Earlier versions (like 5.10.223) have vsock device probe failures that cause VMs to crash.

**Upgrade Path:** Can move to 6.1 LTS (Dec 2026 → Dec 2033) or 6.6 LTS (Dec 2029) when needed

## Requirements Traceability

### 1. Device Mapper & Encryption (RFC-005)

**Requirement:** Guest-side LUKS volume encryption

**Config Options:**
```
CONFIG_BLK_DEV_DM=y              # Device mapper core
CONFIG_DM_CRYPT=y                # dm-crypt target
CONFIG_MD=y                      # Multiple device support (dependency)
CONFIG_CRYPTO_AES=y              # AES cipher
CONFIG_CRYPTO_XTS=y              # XTS mode
CONFIG_CRYPTO_SHA256=y           # LUKS header validation
CONFIG_CRYPTO_USER_API_HASH=y    # Userspace crypto API
CONFIG_CRYPTO_USER_API_SKCIPHER=y # Symmetric key cipher API
```

**Why built-in (=y)?**
- No module infrastructure in initramfs
- Init needs dm-crypt immediately during boot
- Smaller attack surface

**Validation:**
```bash
# After kernel build
grep -E "CONFIG_BLK_DEV_DM|CONFIG_DM_CRYPT" .config
```

### 2. Virtio Drivers (Firecracker)

**Requirement:** Firecracker uses virtio for all I/O

**Config Options:**
```
CONFIG_VIRTIO=y                  # Virtio core
CONFIG_VIRTIO_PCI=y              # PCI transport
CONFIG_VIRTIO_MMIO=y             # MMIO transport (Firecracker primary)
CONFIG_VIRTIO_BLK=y              # Block devices (/dev/vda, /dev/vdb)
CONFIG_VIRTIO_NET=y              # Network device
CONFIG_VIRTIO_CONSOLE=y          # Serial console
CONFIG_VSOCKETS=y                # AF_VSOCK support
CONFIG_VIRTIO_VSOCKETS=y         # Virtio vsock transport (RFC-005 key delivery)
```

**Critical:** Without these, VM won't boot

### 3. Container Isolation (Future)

**Requirement:** Multi-container support per VM

**Namespaces:**
```
CONFIG_NAMESPACES=y              # Namespace support
CONFIG_UTS_NAMESPACE=y           # Hostname isolation
CONFIG_IPC_NAMESPACE=y           # IPC isolation
CONFIG_USER_NAMESPACE=y          # User namespace
CONFIG_PID_NAMESPACE=y           # PID namespace
CONFIG_NET_NAMESPACE=y           # Network namespace
CONFIG_CGROUP_NAMESPACES=y       # Cgroup namespace
```

**Cgroups (v2):**
```
CONFIG_CGROUPS=y                 # Cgroup support
CONFIG_CGROUP_CPUACCT=y          # CPU accounting
CONFIG_MEMCG=y                   # Memory cgroup
CONFIG_CGROUP_SCHED=y            # CPU scheduling
CONFIG_BLK_CGROUP=y              # Block I/O cgroup
CONFIG_CGROUP_FREEZER=y          # Freezer cgroup
CONFIG_CPUSETS=y                 # CPU sets
```

**Note:** Jailer handles cgroups on host; guest cgroups for in-VM isolation

### 4. eBPF Support (Future: Observability)

**Requirement:** Application metrics, tracing, security policies

**Core eBPF:**
```
CONFIG_BPF=y                     # Core BPF
CONFIG_BPF_SYSCALL=y             # BPF syscall interface
CONFIG_BPF_JIT=y                 # JIT compiler (10-100x faster)
CONFIG_HAVE_EBPF_JIT=y           # Architecture JIT support
```

**Tracing:**
```
CONFIG_KPROBES=y                 # Kernel probes
CONFIG_KPROBE_EVENTS=y           # Kprobe event tracing
CONFIG_UPROBE_EVENTS=y           # Userspace probes
CONFIG_TRACEPOINTS=y             # Static tracepoints
CONFIG_FTRACE=y                  # Function tracer
CONFIG_FUNCTION_TRACER=y         # Function tracing
```

**BPF Type Format (BTF):**
```
CONFIG_DEBUG_INFO_BTF=y          # BTF debug info (CO-RE)
```

**Performance Events:**
```
CONFIG_PERF_EVENTS=y             # Performance monitoring
CONFIG_BPF_EVENTS=y              # BPF events integration
```

**Security:**
```
CONFIG_BPF_LSM=y                 # BPF as LSM
```

**Use Cases:**
- Application latency tracing
- Custom metrics without code changes
- Security policies (syscall filtering)
- Network traffic analysis

**Size Impact:** ~500KB-1MB (worth it)

### 5. Filesystem Support

**Requirement:** Mount rootfs, volumes, tmpfs

**Config Options:**
```
CONFIG_EXT4_FS=y                 # ext4 (rootfs and volumes)
CONFIG_TMPFS=y                   # tmpfs for /tmp, /dev/shm
CONFIG_DEVTMPFS=y                # Automatic /dev population
CONFIG_DEVTMPFS_MOUNT=y          # Auto-mount devtmpfs
CONFIG_OVERLAY_FS=y              # OverlayFS (future optimization)
```

**Optional:**
```
CONFIG_SQUASHFS=y                # Compressed rootfs alternative
CONFIG_SQUASHFS_XZ=y             # XZ compression
```

### 6. Network Stack

**Requirement:** TCP/IP, vsock

**Config Options:**
```
CONFIG_NET=y                     # Networking support
CONFIG_INET=y                    # TCP/IP
CONFIG_PACKET=y                  # Packet socket
CONFIG_UNIX=y                    # Unix domain sockets
CONFIG_TUN=y                     # TAP/TUN devices (Firecracker)
```

**Netfilter (minimal):**
- Disabled in guest (host handles nftables)
- Can enable if needed: ~200KB

### 7. Security Features

**Requirement:** Defense in depth

**Config Options:**
```
CONFIG_SECURITY=y                # Security framework
CONFIG_SECCOMP=y                 # Seccomp syscall filtering
CONFIG_AUDIT=y                   # Audit subsystem
CONFIG_STRICT_KERNEL_RWX=y       # W^X enforcement
```

### 8. Boot & Console

**Requirement:** Fast boot, serial output

**Config Options:**
```
CONFIG_SERIAL_8250=y             # Serial port
CONFIG_SERIAL_8250_CONSOLE=y     # Serial console
CONFIG_PRINTK=y                  # Kernel messages
CONFIG_EARLY_PRINTK=y            # Early boot messages
```

### 9. Disabled for Optimization

**Removed:**
- USB drivers (no USB in Firecracker)
- GPU/DRM (no graphics)
- Sound (ALSA/OSS)
- Wireless (only virtio_net)
- Bluetooth
- Most physical device drivers
- Legacy hardware support
- Power management (minimal ACPI)
- Module loading infrastructure

**Expected Savings:** 38MB → 8-12MB

## Disk Space Requirements

- **Kernel source:** ~1.4GB (linux-5.10.245/)
- **Built kernel:** ~38MB (vmlinux)
- **Total during build:** ~1.5GB

To save space after building, you can remove the source directory:
```bash
cd kernel
rm -rf linux-5.10.245
```

The `build.sh` script will re-download and extract the source if needed for future builds.

## Quick Start (5 Minutes)

### Install Build Dependencies

```bash
# Debian/Ubuntu
sudo apt-get install -y build-essential libncurses-dev bison flex libssl-dev libelf-dev bc wget

# Arch Linux
sudo pacman -S base-devel ncurses bison flex openssl elfutils bc wget
```

### Build and Install Kernel

```bash
# From inferno root
make build-kernel install-kernel

# Or from kernel directory
cd kernel
./build.sh
```

**What happens:**
- Downloads Linux 5.10.245 source (~120MB, once)
- Applies Firecracker's config + Inferno dm-crypt additions
- Builds kernel (5-15 minutes depending on CPU)
- Installs to `/usr/share/inferno/vmlinux` (~38MB)

**Result:** New VMs will use custom kernel with dm-crypt built-in. Existing VMs continue using old kernel from their versioned chroot.

### Verify the Fix

```bash
# Check kernel size (should be 8-12MB, was 38MB)
ls -lh /usr/share/inferno/vmlinux

# Test with encrypted volume (see main README.md for volume creation)
sudo infernoctl create test_enc --image nginx:latest --volume <vol_id>
sudo infernoctl start test_enc

# Check logs - should NOT see "Is dm_mod kernel module loaded?"
infernoctl logs show | grep -i "device-mapper\|dm_mod\|luks"
```

### Build Options

```bash
./build.sh --clean              # Clean rebuild
./build.sh --version 5.10.230   # Specific version
./build.sh --menuconfig         # Interactive config
./build.sh --no-install         # Build only, no install
JOBS=8 ./build.sh               # Parallel jobs
```

For more options: `./build.sh --help` or `cd kernel && make help`

## Configuration Details

See `config-inferno-5.10` for the complete kernel configuration with inline comments explaining each option.

### Key Differences from Firecracker Default

**Critical Changes (RFC-005):**
```diff
- CONFIG_BLK_DEV_DM=m          # Module
+ CONFIG_BLK_DEV_DM=y          # Built-in

- CONFIG_DM_CRYPT=m
+ CONFIG_DM_CRYPT=y

- CONFIG_CRYPTO_AES=m
+ CONFIG_CRYPTO_AES=y
```

**Size Optimization:**
```diff
- CONFIG_MODULES=y
+ CONFIG_MODULES=n             # No module infrastructure

- CONFIG_DEBUG_INFO=y
+ CONFIG_DEBUG_INFO=n          # No debug symbols

- CONFIG_USB_SUPPORT=y
+ CONFIG_USB_SUPPORT=n         # Remove USB stack
```

**Future Features:**
```diff
+ CONFIG_BPF=y                 # eBPF support
+ CONFIG_BPF_JIT=y
+ CONFIG_DEBUG_INFO_BTF=y      # BTF for CO-RE
```

## Kernel Command Line

Current boot args (in `scripts/config.sh`):
```
console=ttyS0 reboot=k panic=1 pci=off nomodules
```

**Explanation:**
- `console=ttyS0` - Serial console output
- `reboot=k` - Use keyboard controller for reboot
- `panic=1` - Reboot after 1 second on panic
- `pci=off` - No PCI enumeration (virtio uses MMIO)
- `nomodules` - Explicitly disable module loading

## Testing

### 1. Boot Test

```bash
sudo infernoctl create test1 --image alpine:latest
sudo infernoctl start test1
# Should boot successfully
sudo infernoctl stop test1
sudo infernoctl destroy test1 --yes
```

### 2. Device Mapper Test (RFC-005)

```bash
# Create encrypted volume
vol_id=$(sudo infernoctl volume create 1)
sudo infernoctl create test2 --image nginx:latest --volume "$vol_id"
sudo infernoctl start test2

# Check logs for dm-crypt success
infernoctl logs show | grep -i "luks\|mapper\|device-mapper"
# Should NOT see: "Is dm_mod kernel module loaded?"

sudo infernoctl stop test2
sudo infernoctl destroy test2 --yes
```

### 3. Size Verification

```bash
ls -lh /usr/share/inferno/vmlinux
# Expected: 8-12 MB (was 38 MB)
```

### 4. Boot Time Test

```bash
time sudo infernoctl start test1
# Should be <2 seconds for alpine
```

## Troubleshooting

### Build Fails

**Problem:** `*** No rule to make target 'debian/canonical-certs.pem'`

**Solution:**
```bash
# Disable module signing
scripts/config --disable MODULE_SIG
scripts/config --disable SYSTEM_TRUSTED_KEYS
```

### Kernel Panics at Boot

**Problem:** `Kernel panic - not syncing: VFS: Unable to mount root fs`

**Possible Causes:**
- Missing `CONFIG_EXT4_FS=y`
- Missing `CONFIG_VIRTIO_BLK=y`
- Wrong kernel command line

**Debug:**
```bash
# Check dmesg in logs
infernoctl logs show | grep -i "kernel panic\|unable to mount"
```

### dm-crypt Still Fails

**Problem:** `Cannot initialize device-mapper`

**Verify:**
```bash
# Check kernel config
grep CONFIG_BLK_DEV_DM /usr/share/inferno/.config
# Should show: CONFIG_BLK_DEV_DM=y (not =m, not commented)

# Check if dm-crypt is available
strings /usr/share/inferno/vmlinux | grep dm-crypt
```

## Maintenance

### Updating to New Kernel Version

```bash
# Edit build.sh KERNEL_VERSION variable
vim build.sh

# Rebuild
./build.sh --clean

# Test thoroughly before deploying
```

### Adding New Features

1. Edit `config-inferno-5.10`
2. Add comment explaining why it's needed
3. Document in this README under "Requirements Traceability"
4. Rebuild and test
5. Measure size impact

### Security Updates

Monitor:
- https://www.kernel.org/ - Official releases
- https://cve.mitre.org/ - CVE database
- Firecracker releases (they track kernel security)

Update process:
```bash
# Update to latest 5.10.x
./build.sh --version 5.10.X
sudo ./install.sh  # Reinstall Inferno
# Test all VMs
```

## Integration with Inferno

The build script automatically installs the kernel to `/usr/share/inferno/vmlinux`, which is used by:

1. `scripts/config.sh` - Generates firecracker.json with `kernel_image_path`
2. `scripts/install.sh` - Copies kernel to shared directory during install

To use a custom kernel:
```bash
# Build custom kernel
cd kernel && ./build.sh

# Reinstall Inferno (copies new kernel)
sudo ./scripts/install.sh --mode dev --user $USER

# All new VMs will use new kernel
```

**Note:** Existing VMs use old kernel from their versioned chroot. Destroy and recreate to test new kernel.

## References

- [Firecracker Kernel Config](https://github.com/firecracker-microvm/firecracker/blob/main/resources/guest_configs/microvm-kernel-x86_64-5.10.config)
- [Linux Kernel Documentation](https://www.kernel.org/doc/html/latest/)
- [Device Mapper Documentation](https://www.kernel.org/doc/Documentation/device-mapper/)
- [eBPF Documentation](https://ebpf.io/what-is-ebpf/)
- RFC-005: Guest-Side Volume Encryption with Vsock Key Delivery
- RFC-006: Key Management Service Design & Implementation

## License

The Linux kernel is licensed under GPLv2. Inferno's kernel configuration and build scripts are part of the Inferno project.
