#!/usr/bin/env bash
set -euo pipefail

INSTALL_SH_VERSION="1.3.2"

# ===== Pretty logging =====
info()    { printf "\033[1;32m[INFO]\033[0m %s\n" "$*"; }
success() { printf "\033[1;32m[✓]\033[0m %s\n" "$*"; }
warn()    { printf "\033[1;33m[WARN]\033[0m %s\n" "$*" >&2; }
err()     { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; exit 1; }

# ===== Defaults (overridable by flags) =====
# Note: --mode dev|prod is the primary control now. We still accept legacy MODE env if --mode is omitted.
MODE=""                                     # dev | prod (set via --mode)
PREFIX="${PREFIX:-/usr/local}"              # install prefix for binaries
LIBDIR="${LIBDIR:-$PREFIX/lib/inferno}"     # /usr/local/lib/inferno
SCRIPTS_DIR_DEFAULT="$LIBDIR/scripts"       # bash scripts live here
SHAREDIR="${INFERNO_SHARE_DIR:-/usr/share/inferno}" # kernels, firecracker, kiln, init
ETCDIR="${ETCDIR:-/etc/inferno}"            # config dir
DATADIR_DEFAULT="/var/lib/inferno"          # prod default; dev overrides to ~/.local/share/inferno
RELEASE_TAG="${RELEASE_TAG:-latest}"        # gh tag or "latest"
REPO="${REPO:-yourusername/inferno}"        # change to real org/repo
USER_TO_ADD="${USER_TO_ADD:-${SUDO_USER:-$USER}}"
CREATE_GROUP="${CREATE_GROUP:-1}"

# Optional knobs
HAPROXY_MODE="${HAPROXY_MODE:-}"            # "worker" | "edge"
HAPROXY_BIND="${HAPROXY_BIND:-auto}"        # "auto" or IP
ROOTFS_DISK="${ROOTFS_DISK:-}"              # Disk device for LVM rootfs VG (e.g., /dev/sdb)
DATA_DISK="${DATA_DISK:-}"                  # Disk device for LVM data VG (e.g., /dev/sdc)

# Release asset names (if you use prod mode)
ASSET_INFERNO_AMD64="inferno_Linux_x86_64.tar.gz"
ASSET_KILN_AMD64="kiln_Linux_x86_64.tar.gz"
ASSET_INIT_AMD64="init_Linux_x86_64.tar.gz"
ASSET_INFERNO_ARM64="inferno_Linux_arm64.tar.gz"
ASSET_KILN_ARM64="kiln_Linux_arm64.tar.gz"
ASSET_INIT_ARM64="init_Linux_arm64.tar.gz"

# Firecracker + kernel sources (fallbacks)
FC_REPO="https://github.com/firecracker-microvm/firecracker"
KERNEL_LIST_URL="http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/v1.10/x86_64/vmlinux-5.10&list-type=2"

usage() {
  cat <<EOF
Usage: sudo ./scripts/install.sh --mode dev|prod [--rootfs-disk /dev/sdX] [--data-disk /dev/sdY]
       [--prefix PATH] [--libdir PATH] [--scripts-dir PATH]
       [--sharedir PATH] [--etcdir PATH] [--data-dir PATH]
       [--repo ORG/REPO] [--release TAG] [--user USER] [--no-group]
       [--haproxy worker|edge] [--haproxy-bind auto|IP]

Notes:
  - --mode controls defaults:
      dev  -> INFERNO_ROOT=\$HOME/.local/share/inferno (for USER)
      prod -> INFERNO_ROOT=/var/lib/inferno (unless --data-dir)

  - --rootfs-disk is OPTIONAL for VM rootfs LVM on dedicated disk:
      Example: --rootfs-disk /dev/sdb
      Without it, 'infernoctl init' will auto-create loopback devices

  - --data-disk is OPTIONAL for data volumes LVM on dedicated disk:
      Example: --data-disk /dev/sdc
      Can use same disk as rootfs or separate disk
      Without it, 'infernoctl init' will auto-create loopback devices

Compatibility:
  - Legacy env MODE=dev|prod is still honored if --mode is omitted.
  - --dev / --prod flags are still accepted shorthands.
EOF
  exit 1
}

need_root() { [[ $EUID -eq 0 ]] || err "Please run as root (sudo)."; }
need_cmd()  { command -v "$1" >/dev/null 2>&1 || err "$1 is required but not installed."; }

# ===== Parse flags =====
SCRIPTS_DIR=""  # allow override
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2;;
    --dev) MODE="dev"; shift;;
    --prod) MODE="prod"; shift;;
    --prefix) PREFIX="$2"; shift 2;;
    --libdir) LIBDIR="$2"; shift 2;;
    --scripts-dir) SCRIPTS_DIR="$2"; shift 2;;
    --sharedir|--share-dir) SHAREDIR="$2"; shift 2;;
    --etcdir|--etc-dir) ETCDIR="$2"; shift 2;;
    --data-dir) DATADIR_DEFAULT="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --release) RELEASE_TAG="$2"; shift 2;;
    --user) USER_TO_ADD="$2"; shift 2;;
    --no-group) CREATE_GROUP=0; shift;;
    --haproxy) HAPROXY_MODE="$2"; shift 2;;
    --haproxy-bind) HAPROXY_BIND="$2"; shift 2;;
    --rootfs-disk) ROOTFS_DISK="$2"; shift 2;;
    --data-disk) DATA_DISK="$2"; shift 2;;
    -h|--help) usage;;
    *) err "Unknown flag: $1";;
  esac
done

# Back-compat: allow MODE env if --mode not given
if [[ -z "${MODE}" ]]; then
  MODE="${MODE:-}"
fi
# Default to dev if still empty
if [[ -z "${MODE}" ]]; then
  MODE="dev"
fi
case "$MODE" in dev|prod) : ;; *) err "--mode must be 'dev' or 'prod' (got: $MODE)";; esac
[[ -z "$SCRIPTS_DIR" ]] && SCRIPTS_DIR="$SCRIPTS_DIR_DEFAULT"

need_root

# ===== Dependency checks =====
need_cmd install
need_cmd rsync
need_cmd sed
need_cmd awk
need_cmd jq
need_cmd curl
need_cmd tar
command -v ip >/dev/null 2>&1 || true
command -v nft >/dev/null 2>&1 || true

# ===== KVM availability check =====
check_kvm() {
  # Check if KVM is supported by CPU
  if ! grep -qE 'vmx|svm' /proc/cpuinfo; then
    warn "CPU does not support virtualization (no vmx/svm flags)"
    warn "Inferno requires KVM support to run Firecracker VMs"
    return 1
  fi

  # Check if KVM module is loaded
  if ! lsmod | grep -q '^kvm'; then
    info "KVM module not loaded, attempting to load..."
    if grep -q 'vmx' /proc/cpuinfo; then
      modprobe kvm_intel 2>/dev/null || warn "Failed to load kvm_intel module"
    elif grep -q 'svm' /proc/cpuinfo; then
      modprobe kvm_amd 2>/dev/null || warn "Failed to load kvm_amd module"
    fi
  fi

  # Check if /dev/kvm exists
  if [[ ! -e /dev/kvm ]]; then
    warn "/dev/kvm device not found"
    warn "KVM may not be properly configured. VMs will fail to start."
    return 1
  fi

  info "KVM support detected and available"
  return 0
}

check_kvm || warn "KVM checks failed - VMs may not start properly"

# ===== Arch mapping for release assets (prod) =====
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) GH_SUFFIX="_Linux_x86_64.tar.gz"; FC_ARCH="x86_64" ;;
  aarch64|arm64) GH_SUFFIX="_Linux_arm64.tar.gz"; FC_ARCH="aarch64" ;;
  *) err "Unsupported arch: $ARCH" ;;
esac

# ===== Create inferno group & user membership =====
if [[ "$CREATE_GROUP" -eq 1 ]]; then
  if ! getent group inferno >/dev/null; then
    info "Creating group 'inferno'"
    groupadd --system inferno
  else
    info "Group 'inferno' already exists"
  fi

  # Create inferno system user for running services (like Anubis)
  if ! id -u inferno >/dev/null 2>&1; then
    info "Creating system user 'inferno'"
    useradd --system --no-create-home --shell /usr/sbin/nologin --gid inferno inferno
  else
    info "User 'inferno' already exists"
  fi

  if id -u "$USER_TO_ADD" >/dev/null 2>&1; then
    info "Adding $USER_TO_ADD to group 'inferno'"
    usermod -aG inferno "$USER_TO_ADD"
  else
    warn "User $USER_TO_ADD not found; skipping group membership"
  fi
fi

# ===== Create base dirs =====
mkdir -p "$LIBDIR" "$SHAREDIR" "$ETCDIR"
chmod 755 "$LIBDIR" "$SHAREDIR"
chmod 755 "$ETCDIR"   # <-- make /etc/inferno world-readable so non-root can source env

# ===== Resolve data dir based on MODE =====
if [[ "$MODE" == "dev" ]]; then
  HOME_DIR="$(getent passwd "$USER_TO_ADD" | cut -d: -f6)"
  DATADIR="$DATADIR_DEFAULT"
  if [[ -z "${DATADIR_DEFAULT}" || "$DATADIR_DEFAULT" == "/var/lib/inferno" ]]; then
    DATADIR="$HOME_DIR/.local/share/inferno"
  fi
  [[ "$DATADIR" == "~"* ]] && DATADIR="${DATADIR/#\~/$HOME_DIR}"
else
  DATADIR="$DATADIR_DEFAULT"
fi

mkdir -p "$DATADIR" "$DATADIR"/{vms,images,logs,logs/vm,tmp,volumes}
chown -R "$USER_TO_ADD:inferno" "$DATADIR"
chmod 2775 "$DATADIR"
chmod 2750 "$DATADIR/vms" || true

# Create Anubis data directory (owned by inferno system user)
mkdir -p /var/lib/anubis
chown inferno:inferno /var/lib/anubis
chmod 0750 /var/lib/anubis

# ===== Helpers =====
install_bin() { local src="$1" name="$2"; install -m 0755 -D "$src" "$PREFIX/bin/$name"; info "Installed $name -> $PREFIX/bin/$name"; }
dl_release_asset() {
  local asset="$1" out="$2" tag="$RELEASE_TAG" api_url url
  if [[ "$tag" == "latest" ]]; then api_url="https://api.github.com/repos/$REPO/releases/latest";
  else api_url="https://api.github.com/repos/$REPO/releases/tags/$tag"; fi
  info "Fetching release metadata: $REPO @ $tag"
  url="$(curl -fsSL "$api_url" | jq -r --arg name "$asset" '.assets[] | select(.name==$name) | .browser_download_url')"
  [[ -n "$url" && "$url" != "null" ]] || err "Asset not found in release: $asset"
  info "Downloading $asset"
  curl -fL "$url" -o "$out"
}

normalize_scripts_dir() {
  shopt -s nullglob
  local any_warn=0
  for f in "$SCRIPTS_DIR"/*.sh; do
    chmod 0755 "$f" || true
    if ! bash -n "$f" 2>/dev/null; then
      warn "Syntax check failed for $f"
      any_warn=1
    fi
  done
  shopt -u nullglob
  if [[ "$any_warn" -eq 0 ]]; then
    info "Normalized scripts in $SCRIPTS_DIR/"
  else
    info "Normalized scripts in $SCRIPTS_DIR/ (some warnings above)"
  fi
}

# ===== Install scripts & binaries =====
if [[ "$MODE" == "dev" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
  mkdir -p "$SCRIPTS_DIR"
  rsync -a --delete "$REPO_ROOT/scripts/" "$SCRIPTS_DIR/"
  info "Installed scripts -> $SCRIPTS_DIR/"

  [[ -f "$REPO_ROOT/vmlinux"      ]] && install -m 0644 -D "$REPO_ROOT/vmlinux" "$SHAREDIR/vmlinux" || true
  [[ -x "$REPO_ROOT/firecracker"  ]] && install -m 0755 -D "$REPO_ROOT/firecracker" "$SHAREDIR/firecracker" || true
  [[ -x "$REPO_ROOT/bin/kiln"     ]] && install -m 0755 -D "$REPO_ROOT/bin/kiln" "$SHAREDIR/kiln" || true
  [[ -x "$REPO_ROOT/bin/init"     ]] && install -m 0755 -D "$REPO_ROOT/bin/init" "$SHAREDIR/init" || true
  [[ -x "$REPO_ROOT/bin/anubis"   ]] && install -m 0755 -D "$REPO_ROOT/bin/anubis" "$SHAREDIR/anubis" || true
  [[ -x "$REPO_ROOT/jailer"      ]] && install -m 0755 -D "$REPO_ROOT/jailer" "$SHAREDIR/jailer" || true
  info "Installed kiln, init, anubis -> $SHAREDIR/"

  if [[ -x "$REPO_ROOT/bin/inferno" ]]; then
    install_bin "$REPO_ROOT/bin/inferno" inferno
  fi
else
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  case "$ARCH" in
    x86_64|amd64)
      dl_release_asset "$ASSET_INFERNO_AMD64" "$TMP/inferno.tgz"
      dl_release_asset "$ASSET_KILN_AMD64" "$TMP/kiln.tgz"
      dl_release_asset "$ASSET_INIT_AMD64" "$TMP/init.tgz"
      ;;
    aarch64|arm64)
      dl_release_asset "$ASSET_INFERNO_ARM64" "$TMP/inferno.tgz"
      dl_release_asset "$ASSET_KILN_ARM64" "$TMP/kiln.tgz"
      dl_release_asset "$ASSET_INIT_ARM64" "$TMP/init.tgz"
      ;;
  esac
  mkdir -p "$TMP/extract"
  tar -xzf "$TMP/inferno.tgz" -C "$TMP/extract"
  tar -xzf "$TMP/kiln.tgz"    -C "$TMP/extract"
  tar -xzf "$TMP/init.tgz"    -C "$TMP/extract"

  install_bin "$(find "$TMP/extract" -type f -name inferno -perm -111 | head -n1)" inferno
  install -m 0755 -D "$(find "$TMP/extract" -type f -name kiln -perm -111 | head -n1)" "$SHAREDIR/kiln"
  install -m 0755 -D "$(find "$TMP/extract" -type f -name init -perm -111 | head -n1)" "$SHAREDIR/init"
  info "Installed kiln & init -> $SHAREDIR/"

  if [[ -d "$TMP/extract/scripts" ]]; then
    mkdir -p "$SCRIPTS_DIR"
    rsync -a --delete "$TMP/extract/scripts/" "$SCRIPTS_DIR/"
    info "Installed scripts -> $SCRIPTS_DIR/"
  else
    warn "No scripts/ dir found in release; skipping"
  fi
fi

# syntax check / perms on installed scripts
normalize_scripts_dir

# ===== Firecracker + Jailer (fallbacks) =====
if [[ ! -x "$SHAREDIR/firecracker" || ! -x "$SHAREDIR/jailer" ]]; then
  info "Installing Firecracker + Jailer"
  # --- Pin Firecracker/jailer version ---
  FC_VERSION="v1.14.1"
  case "$ARCH" in
    x86_64|amd64) FC_ARCH="x86_64" ;;
    aarch64|arm64) FC_ARCH="aarch64" ;;
    *) err "Unsupported arch: $ARCH" ;;
  esac
  TMPFC="$(mktemp -d)"; trap 'rm -rf "$TMPFC"' EXIT
  curl -fsSL "https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-${FC_ARCH}.tgz" -o "$TMPFC/fc.tgz"
  tar -xzf "$TMPFC/fc.tgz" -C "$TMPFC"
  FC_BIN="$(find "$TMPFC" -type f -name "firecracker*" -perm -111 | head -n1)"
  JAIL_BIN="$(find "$TMPFC" -type f -name "jailer*" -perm -111 | head -n1)"

  [[ -n "$FC_BIN" ]] || err "Firecracker binary not found in $TAR"
  install -m 0755 -D "$FC_BIN" "$SHAREDIR/firecracker"

  [[ -n "$JAIL_BIN" ]] || err "Jailer binary not found in download"
  install -m 0755 -D "$JAIL_BIN" /usr/local/bin/jailer

  # Verify installed versions
  FC_INSTALLED_VERSION="$("$SHAREDIR/firecracker" --version 2>&1 | head -n1 || echo 'unknown')"
  JAILER_INSTALLED_VERSION="$(jailer --version 2>&1 | head -n1 || echo 'unknown')"
  info "Firecracker installed: $FC_INSTALLED_VERSION"
  info "Jailer installed: $JAILER_INSTALLED_VERSION"

  rm -rf "$TMPFC"
fi

# ===== Kernel (fallback) =====
if [[ ! -f "$SHAREDIR/vmlinux" ]]; then
  info "Installing Firecracker-optimized kernel"
  # Allow override via KERNEL_LIST_URL; otherwise pick by arch
  if [[ -z "${KERNEL_LIST_URL:-}" ]]; then
    KERNEL_LIST_URL="http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/v1.10/${FC_ARCH}/vmlinux-5.10&list-type=2"
  fi
  # Grab the latest vmlinux-5.10.x object key for this arch
  latest_kernel_rel="$(curl -fsSL "$KERNEL_LIST_URL" \
    | grep -oE "firecracker-ci/v1\.10/${FC_ARCH}/vmlinux-5\.10\.[0-9]+" \
    | sort -Vr | head -n1)"
  [[ -n "$latest_kernel_rel" ]] || err "Could not resolve latest vmlinux for ${FC_ARCH}"
  curl -fL "https://s3.amazonaws.com/spec.ccfc.min/${latest_kernel_rel}" -o "$SHAREDIR/vmlinux"
  chmod 0644 "$SHAREDIR/vmlinux"
fi

# ===== cryptsetup for volume encryption =====
if [[ ! -x "$SHAREDIR/cryptsetup" ]]; then
  info "Installing cryptsetup binary for volume encryption"

  # Prefer system cryptsetup - we'll bundle libraries into initramfs
  if command -v cryptsetup >/dev/null 2>&1; then
    SYSTEM_CRYPT="$(command -v cryptsetup)"

    # Check if it's glibc-based (compatible with library bundling)
    if ldd "$SYSTEM_CRYPT" 2>&1 | grep -q "not a dynamic executable"; then
      info "Using static system cryptsetup"
      install -m 0755 -D "$SYSTEM_CRYPT" "$SHAREDIR/cryptsetup"
      CRYPT_VERSION="$("$SHAREDIR/cryptsetup" --version | head -n1 || echo 'unknown')"
      info "Cryptsetup installed: $CRYPT_VERSION (static)"
    elif ldd "$SYSTEM_CRYPT" 2>&1 | grep -q "libc.so.6"; then
      # glibc-based binary (compatible with our library bundling)
      info "Using system cryptsetup (glibc-based, libraries will be bundled)"
      install -m 0755 -D "$SYSTEM_CRYPT" "$SHAREDIR/cryptsetup"
      CRYPT_VERSION="$("$SYSTEM_CRYPT" --version | head -n1 || echo 'unknown')"
      info "Cryptsetup installed: $CRYPT_VERSION (dynamic, ~10MB with libraries)"
    else
      warn "System cryptsetup uses incompatible libc (musl?), attempting package install"
      # Try to install glibc-based package
      if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y cryptsetup-bin >/dev/null 2>&1 || true
        if command -v cryptsetup >/dev/null 2>&1; then
          SYSTEM_CRYPT="$(command -v cryptsetup)"
          install -m 0755 -D "$SYSTEM_CRYPT" "$SHAREDIR/cryptsetup"
          info "Cryptsetup installed via package manager"
        fi
      else
        warn "Could not find glibc-based cryptsetup"
      fi
    fi
  else
    # No system cryptsetup, try to install via package manager
    info "Attempting to install cryptsetup from system package manager"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get install -y cryptsetup-bin >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache cryptsetup >/dev/null 2>&1 || true
    fi

    if command -v cryptsetup >/dev/null 2>&1; then
      SYSTEM_CRYPT="$(command -v cryptsetup)"
      install -m 0755 -D "$SYSTEM_CRYPT" "$SHAREDIR/cryptsetup"
      CRYPT_VERSION="$("$SHAREDIR/cryptsetup" --version | head -n1 || echo 'unknown')"
      info "Cryptsetup installed: $CRYPT_VERSION"
    else
      warn "Could not install cryptsetup, volume encryption will not work"
      warn "To enable encryption: sudo apt-get install cryptsetup-bin (Debian/Ubuntu)"
    fi
  fi
fi

# ===== CLI wrapper in PATH (sources /etc/inferno/env) =====
WRAPPER="$PREFIX/bin/infernoctl"
cat > "$WRAPPER" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
: "${INFERNO_SHARE_DIR:=/usr/share/inferno}"
: "${INFERNO_ROOT:=/var/lib/inferno}"
SCRIPTDIR="/usr/local/lib/inferno/scripts"
if [[ -f /etc/inferno/env ]]; then
  # shellcheck disable=SC1091
  source /etc/inferno/env
fi
exec /usr/bin/env bash "$SCRIPTDIR/infernoctl.sh" "$@"
WRAP
chmod 0755 "$WRAPPER"
info "Installed CLI wrapper -> $WRAPPER"

# ===== Seed/update /etc/inferno/env from MODE decision =====
mkdir -p "$ETCDIR"
ENVFILE="$ETCDIR/env"
if [[ -f "$ENVFILE" ]]; then
  if grep -q '^INFERNO_ROOT=' "$ENVFILE"; then
    sed -i "s|^INFERNO_ROOT=.*|INFERNO_ROOT=\"$DATADIR\"|" "$ENVFILE"
  else
    printf 'INFERNO_ROOT="%s"\n' "$DATADIR" >> "$ENVFILE"
  fi
  if grep -q '^INFERNO_SHARE_DIR=' "$ENVFILE"; then
    sed -i "s|^INFERNO_SHARE_DIR=.*|INFERNO_SHARE_DIR=\"$SHAREDIR\"|" "$ENVFILE"
  else
    printf 'INFERNO_SHARE_DIR="%s"\n' "$SHAREDIR" >> "$ENVFILE"
  fi
  info "$ENVFILE exists; updated paths"
else
  cat > "$ENVFILE" <<EOF
# Inferno runtime config (edit as needed)
INFERNO_ROOT="$DATADIR"
INFERNO_SHARE_DIR="$SHAREDIR"
# Optional: VG_NAME="inferno_vg"
EOF
  chmod 0644 "$ENVFILE"
  info "Wrote $ENVFILE"
fi

# ===== Install Anubis config and systemd service =====
if [[ "$MODE" == "dev" ]]; then
  # Install Anubis config (independent service, not under ETCDIR)
  if [[ -f "$REPO_ROOT/etc/anubis/config.toml" ]]; then
    mkdir -p /etc/anubis
    install -m 0640 -D "$REPO_ROOT/etc/anubis/config.toml" /etc/anubis/config.toml
    chown root:inferno /etc/anubis/config.toml
    info "Installed Anubis config -> /etc/anubis/config.toml"
  else
    warn "Anubis config not found at $REPO_ROOT/etc/anubis/config.toml; skipping"
  fi

  # Install Anubis systemd service
  if [[ -f "$REPO_ROOT/etc/anubis/anubis.service" ]]; then
    install -m 0644 -D "$REPO_ROOT/etc/anubis/anubis.service" /etc/systemd/system/anubis.service
    systemctl daemon-reload || true
    info "Installed Anubis systemd service -> /etc/systemd/system/anubis.service"
    info "To start Anubis: sudo systemctl enable anubis && sudo systemctl start anubis"
  else
    warn "Anubis service file not found at $REPO_ROOT/etc/anubis/anubis.service; skipping"
  fi
fi

# ===== Save LVM disk configuration for infernoctl init =====
LVM_CONF="${ETCDIR}/lvm.conf"

# Validate disks if specified
if [[ -n "$ROOTFS_DISK" ]] && [[ ! -b "$ROOTFS_DISK" ]]; then
  err "Rootfs disk not found: $ROOTFS_DISK (must be a block device)"
fi

if [[ -n "$DATA_DISK" ]] && [[ ! -b "$DATA_DISK" ]]; then
  err "Data disk not found: $DATA_DISK (must be a block device)"
fi

# Save configuration
cat > "$LVM_CONF" <<EOF
# Inferno LVM Configuration
# This file is read by 'infernoctl init' to set up LVM storage
# Generated by install.sh on $(date)

# Rootfs VG configuration
ROOTFS_VG_NAME="${ROOTFS_VG_NAME:-inferno_rootfs_vg}"
ROOTFS_POOL_NAME="${ROOTFS_POOL_NAME:-rootfs_pool}"
ROOTFS_POOL_SIZE="${ROOTFS_POOL_SIZE:-20G}"
ROOTFS_DISK="${ROOTFS_DISK:-}"

# Data VG configuration
DATA_VG_NAME="${VG_NAME:-inferno_vg}"
DATA_POOL_NAME="${DATA_POOL_NAME:-vm_pool}"
DATA_POOL_SIZE="${DATA_POOL_SIZE:-40G}"
DATA_DISK="${DATA_DISK:-}"
EOF

chmod 0644 "$LVM_CONF"
info "Saved LVM configuration -> $LVM_CONF"

if [[ -n "$ROOTFS_DISK" ]] || [[ -n "$DATA_DISK" ]]; then
  info "  Dedicated disks will be used by 'infernoctl init':"
  [[ -n "$ROOTFS_DISK" ]] && info "    Rootfs: $ROOTFS_DISK"
  [[ -n "$DATA_DISK" ]] && info "    Data: $DATA_DISK"
else
  info "  No dedicated disks specified - loopback devices will be auto-created"
fi

# ===== Optional: seed HAProxy base (markers only) if requested =====
if [[ -n "${HAPROXY_MODE:-}" ]]; then
  cfg="/etc/haproxy/haproxy.cfg"
  if [[ -f "$cfg" ]]; then
    info "HAProxy config exists; leaving it unchanged (managed by inferno)."
  else
    mkdir -p /etc/haproxy
    cat > "$cfg" <<'HACFG'
global
    daemon
    maxconn 2048

defaults
    mode http
    timeout connect 5s
    timeout client  30s
    timeout server  30s

# BEGIN-INFERNO (autogenerated; do not edit between markers)
# (infernoctl haproxy render will write routes here)
# END-INFERNO
HACFG
    chmod 0644 "$cfg"
    info "Installed HAProxy base config -> $cfg"
  fi
fi

# ===== Verify installed versions =====
if [[ -x "$SHAREDIR/firecracker" ]]; then
  FC_VERSION_CHECK="$("$SHAREDIR/firecracker" --version 2>&1 | head -n1 || echo 'unknown')"
  info "Firecracker version: $FC_VERSION_CHECK"
else
  warn "Firecracker not found at $SHAREDIR/firecracker"
fi

if [[ -x /usr/local/bin/jailer ]]; then
  JAILER_VERSION_CHECK="$(jailer --version 2>&1 | head -n1 || echo 'unknown')"
  info "Jailer version: $JAILER_VERSION_CHECK"
else
  warn "Jailer not found at /usr/local/bin/jailer"
fi

# ===== Final permissions (group-based sharing) =====
chgrp -R inferno "$DATADIR" "$SHAREDIR" "$LIBDIR" || true
chmod -R g+rwX "$DATADIR" || true

# ===== Summary =====
cat <<EOM
✔ Install complete

Binaries placed for infernoctl to copy-per-VM:
  $SHAREDIR/kiln
  $SHAREDIR/init
  $SHAREDIR/firecracker
  $SHAREDIR/vmlinux

Driver scripts:
  $SCRIPTS_DIR/ (contains infernoctl.sh and helpers)

CLI entrypoint:
  $PREFIX/bin/infernoctl

Config:
  $ENVFILE

Data root:
  $DATADIR  (group=inferno, setgid)

HAProxy:
  If you installed with "--haproxy worker", HAProxy now listens on your Tailscale IP:80 and
  Inferno will append host-based routes under the "# BEGIN-INFERNO ... # END-INFERNO" markers.
  On an "edge" node, HAProxy will bind public :80 and forward to WORKER_TS_IP:80.

Usage:
  # Initialize data directory and LVM storage (requires root for LVM):
  sudo infernoctl init

  # Then create and manage VMs:
  sudo infernoctl create web1 --image nginx:latest
EOM

# group membership notice
if ! id -nG "$USER_TO_ADD" | grep -qw inferno; then
  warn "User $USER_TO_ADD may need to log out/in (or run 'newgrp inferno') for group changes to take effect."
fi
