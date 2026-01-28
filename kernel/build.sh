#!/usr/bin/env bash
# Inferno Kernel Build Script
# Builds a minimal, optimized kernel for Firecracker microVMs
# Requirements: build-essential, libncurses-dev, bison, flex, libssl-dev, libelf-dev, bc, wget

set -euo pipefail

# Configuration
KERNEL_VERSION="${KERNEL_VERSION:-5.10.245}"
KERNEL_MAJOR_VERSION="${KERNEL_VERSION%.*}"  # Extract 5.10 from 5.10.223
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-${KERNEL_VERSION}.tar.xz"
BUILD_DIR="$(pwd)"
KERNEL_DIR="${BUILD_DIR}/linux-${KERNEL_VERSION}"
CONFIG_FILE="${BUILD_DIR}/config-inferno-${KERNEL_MAJOR_VERSION}"
OUTPUT_KERNEL="${BUILD_DIR}/vmlinux"
INSTALL_DIR="/usr/share/inferno"
JOBS="${JOBS:-$(nproc)}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
die() { error "$*"; exit 1; }

# Usage
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Build a custom kernel for Inferno microVMs.

OPTIONS:
    --version VERSION    Kernel version to build (default: ${KERNEL_VERSION})
    --jobs N             Number of parallel jobs (default: $(nproc))
    --clean              Clean build (remove existing source)
    --no-install         Build only, don't install to ${INSTALL_DIR}
    --menuconfig         Run menuconfig before building
    --help               Show this help message

EXAMPLES:
    # Quick build with defaults
    $0

    # Build specific version
    $0 --version 5.10.230

    # Clean build with interactive config
    $0 --clean --menuconfig

    # Build without installing
    $0 --no-install

EOF
    exit 0
}

# Check dependencies
check_dependencies() {
    local missing=()
    local deps=(gcc make bison flex bc wget tar xz)

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
        echo ""
        echo "Install with:"
        echo "  Debian/Ubuntu: sudo apt-get install build-essential libncurses-dev bison flex libssl-dev libelf-dev bc wget"
        echo "  Arch: sudo pacman -S base-devel ncurses bison flex openssl elfutils bc wget"
        exit 1
    fi
}

# Download kernel source
download_kernel() {
    info "Checking for kernel source..."

    if [[ -d "$KERNEL_DIR" ]]; then
        warn "Kernel source already exists: $KERNEL_DIR"
        return 0
    fi

    info "Downloading Linux ${KERNEL_VERSION} from kernel.org..."
    wget -q --show-progress "$KERNEL_URL" -O "linux-${KERNEL_VERSION}.tar.xz" || die "Failed to download kernel"

    info "Extracting kernel source..."
    tar -xf "linux-${KERNEL_VERSION}.tar.xz" || die "Failed to extract kernel"

    success "Kernel source ready: $KERNEL_DIR"
}

# Apply Inferno config
apply_config() {
    info "Applying Inferno kernel configuration..."

    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "Config file not found: $CONFIG_FILE"
    fi

    cd "$KERNEL_DIR"

    # Copy config
    cp "$CONFIG_FILE" .config

    # Disable problematic options that might cause build failures
    scripts/config --disable MODULE_SIG
    scripts/config --disable SYSTEM_TRUSTED_KEYRING
    scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
    scripts/config --disable SYSTEM_REVOCATION_KEYS
    scripts/config --set-str SYSTEM_REVOCATION_KEYS ""

    # Update config for current kernel version (handle new options)
    make olddefconfig ARCH=x86_64 || die "Failed to update config"

    success "Configuration applied"
}

# Build kernel
build_kernel() {
    info "Building kernel with ${JOBS} parallel jobs..."
    info "This may take 5-15 minutes depending on your system..."

    cd "$KERNEL_DIR"

    # Build uncompressed kernel (Firecracker requirement)
    make vmlinux -j"${JOBS}" ARCH=x86_64 || die "Kernel build failed"

    # Copy to build directory
    cp vmlinux "$OUTPUT_KERNEL" || die "Failed to copy vmlinux"

    # Get kernel size
    local size
    size=$(du -h "$OUTPUT_KERNEL" | cut -f1)

    success "Kernel built successfully: $OUTPUT_KERNEL (${size})"
}

# Install kernel
install_kernel() {
    info "Installing kernel to ${INSTALL_DIR}..."

    if [[ ! -d "$INSTALL_DIR" ]]; then
        error "Inferno not installed: ${INSTALL_DIR} not found"
        echo "Run: sudo ./scripts/install.sh --mode dev"
        exit 1
    fi

    # Backup old kernel
    if [[ -f "${INSTALL_DIR}/vmlinux" ]]; then
        local backup="${INSTALL_DIR}/vmlinux.backup.$(date +%s)"
        info "Backing up old kernel to: ${backup}"
        sudo cp "${INSTALL_DIR}/vmlinux" "$backup"
    fi

    # Install new kernel
    sudo cp "$OUTPUT_KERNEL" "${INSTALL_DIR}/vmlinux" || die "Failed to install kernel"
    sudo chmod 644 "${INSTALL_DIR}/vmlinux"

    # Save config for reference
    sudo cp "${KERNEL_DIR}/.config" "${INSTALL_DIR}/.config" 2>/dev/null || true

    success "Kernel installed to ${INSTALL_DIR}/vmlinux"
    info "New VMs will use this kernel. Existing VMs use old kernel from their versioned chroot."
}

# Clean build artifacts
clean_build() {
    info "Cleaning build artifacts..."

    rm -rf "$KERNEL_DIR" "linux-${KERNEL_VERSION}.tar.xz" "$OUTPUT_KERNEL"

    success "Build directory cleaned"
}

# Run menuconfig
run_menuconfig() {
    info "Running menuconfig..."

    cd "$KERNEL_DIR"
    make menuconfig ARCH=x86_64 || die "menuconfig failed"

    # Save config back to build directory
    cp .config "$CONFIG_FILE"
    success "Configuration saved to: $CONFIG_FILE"
}

# Verify kernel
verify_kernel() {
    info "Verifying kernel configuration..."

    cd "$KERNEL_DIR"

    local required_configs=(
        "CONFIG_BLK_DEV_DM=y"
        "CONFIG_DM_CRYPT=y"
        "CONFIG_VIRTIO=y"
        "CONFIG_VIRTIO_BLK=y"
        "CONFIG_VIRTIO_NET=y"
        "CONFIG_EXT4_FS=y"
        "CONFIG_VSOCKETS=y"
    )

    local missing=()
    for cfg in "${required_configs[@]}"; do
        if ! grep -q "^${cfg}" .config; then
            missing+=("$cfg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing critical config options:"
        printf '  %s\n' "${missing[@]}"
        die "Kernel verification failed"
    fi

    success "Kernel configuration verified"
}

# Main
main() {
    local do_install=true
    local do_clean=false
    local do_menuconfig=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                KERNEL_VERSION="$2"
                shift 2
                ;;
            --jobs)
                JOBS="$2"
                shift 2
                ;;
            --clean)
                do_clean=true
                shift
                ;;
            --no-install)
                do_install=false
                shift
                ;;
            --menuconfig)
                do_menuconfig=true
                shift
                ;;
            --help)
                usage
                ;;
            *)
                error "Unknown option: $1"
                usage
                ;;
        esac
    done

    info "Inferno Kernel Build"
    info "===================="
    info "Kernel Version: ${KERNEL_VERSION}"
    info "Parallel Jobs: ${JOBS}"
    info "Config: ${CONFIG_FILE}"
    echo ""

    # Clean if requested
    if [[ "$do_clean" == true ]]; then
        clean_build
    fi

    # Check dependencies
    check_dependencies

    # Download kernel
    download_kernel

    # Apply config
    apply_config

    # Run menuconfig if requested
    if [[ "$do_menuconfig" == true ]]; then
        run_menuconfig
    fi

    # Verify config
    verify_kernel

    # Build
    build_kernel

    # Install if requested
    if [[ "$do_install" == true ]]; then
        install_kernel
    else
        warn "Skipping installation (--no-install specified)"
        info "Kernel available at: $OUTPUT_KERNEL"
    fi

    echo ""
    success "Build complete!"
    echo ""
    info "Next steps:"
    if [[ "$do_install" == false ]]; then
        echo "  1. Install kernel: sudo cp $OUTPUT_KERNEL /usr/share/inferno/vmlinux"
    fi
    echo "  2. Test with: sudo infernoctl create test1 --image alpine:latest"
    echo "  3. Check logs: infernoctl logs show"
    echo ""
    info "Kernel size: $(du -h "$OUTPUT_KERNEL" | cut -f1)"
}

main "$@"
