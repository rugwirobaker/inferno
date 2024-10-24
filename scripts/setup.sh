#!/bin/bash

# Function to exit on errors
set -e

# Function to log messages
log() {
    echo -e "\033[1;32m[INFO]\033[0m $1"
}

# Function to handle errors
handle_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1"
    exit 1
}

# Check for necessary commands
command -v curl >/dev/null 2>&1 || handle_error "curl is required but not installed."
command -v wget >/dev/null 2>&1 || handle_error "wget is required but not installed."
command -v tar >/dev/null 2>&1 || handle_error "tar is required but not installed."
command -v docker >/dev/null 2>&1 || handle_error "docker is required but not installed."
command -v kvm-ok >/dev/null 2>&1 || handle_error "kvm-ok is required but not installed."

# Variables
ARCH="$(uname -m)"
FIRECRACKER_RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases"
FIRECRACKER_BINARY="firecracker"
KERNEL_URL="http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/v1.10/x86_64/vmlinux-5.10&list-type=2"

# Download Firecracker
log "Downloading the latest version of Firecracker..."
latest_firecracker=$(basename $(curl -fsSLI -o /dev/null -w  %{url_effective} ${FIRECRACKER_RELEASE_URL}/latest))
curl -L ${FIRECRACKER_RELEASE_URL}/download/${latest_firecracker}/firecracker-${latest_firecracker}-${ARCH}.tgz | tar -xz
mv release-${latest_firecracker}-${ARCH}/firecracker-${latest_firecracker}-${ARCH} ${FIRECRACKER_BINARY} || handle_error "Failed to rename Firecracker binary."

# Download Firecracker Optimized Kernel
log "Downloading Firecracker-optimized Linux kernel..."
latest_kernel=$(wget -qO- ${KERNEL_URL} | grep -oP 'firecracker-ci/v1.10/x86_64/vmlinux-5\.10\.[0-9]{3}')
if [ -z "$latest_kernel" ]; then
    handle_error "Failed to find the latest kernel version."
fi
wget "https://s3.amazonaws.com/spec.ccfc.min/${latest_kernel}" -O vmlinux || handle_error "Failed to download the Linux kernel."

# Check for KVM support
if kvm-ok; then
    log "KVM is already correctly set up. Skipping KVM setup."
else
    log "Setting up KVM..."
    sudo modprobe kvm
    sudo modprobe kvm_intel || sudo modprobe kvm_amd
    sudo chown root:kvm /dev/kvm
    sudo chmod 660 /dev/kvm
    sudo usermod -aG kvm $USER
    log "KVM setup complete. You may need to log out and back in to apply group changes."
fi

log "Setup complete. You can now proceed with running Kiln + Init."
 