#!/bin/bash

# Function to log messages
log() {
    echo -e "\033[1;32m[INFO]\033[0m $1"
}

# Function to handle errors
handle_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1"
    exit 1
}

# Ensure Docker is installed
command -v docker >/dev/null 2>&1 || handle_error "Docker is required but not installed."

# Check if rootfs image size was passed in
if [ -z "$1" ]; then
    handle_error "Usage: $0 <docker-image> [rootfs.img]"
fi

DOCKER_IMAGE=$1
ROOTFS_IMG=${2:-rootfs.img}  # Default to rootfs.img if not provided

# Temporary directory for extracting Docker image contents
TMP_DIR=$(mktemp -d)

log "Creating root filesystem from Docker image: $DOCKER_IMAGE..."

# Extract Docker image contents to the temporary directory
docker create --name rootfs-container $DOCKER_IMAGE || handle_error "Failed to create Docker container from image."
docker export rootfs-container | tar -C "$TMP_DIR" -xvf - || handle_error "Failed to export Docker container filesystem."
docker rm rootfs-container >/dev/null 2>&1 || log "Warning: Failed to remove Docker container."

log "Creating empty root filesystem image ($ROOTFS_IMG)..."

# Create an empty ext4 image
dd if=/dev/zero of=$ROOTFS_IMG bs=1M count=1024 || handle_error "Failed to create rootfs image file."
mkfs.ext4 $ROOTFS_IMG || handle_error "Failed to format rootfs image as ext4."

# Mount the image and copy files
MOUNT_DIR=$(mktemp -d)

log "Mounting root filesystem image..."
sudo mount -o loop $ROOTFS_IMG $MOUNT_DIR || handle_error "Failed to mount rootfs image."

log "Copying extracted files to root filesystem image..."
sudo cp -a $TMP_DIR/* $MOUNT_DIR || handle_error "Failed to copy files to rootfs image."

log "Unmounting root filesystem image..."
sudo umount $MOUNT_DIR || handle_error "Failed to unmount rootfs image."

# Clean up
log "Cleaning up..."
rm -rf $TMP_DIR
rmdir $MOUNT_DIR

log "Root filesystem image ($ROOTFS_IMG) created successfully."
