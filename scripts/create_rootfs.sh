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
check_dependencies() {
    command -v docker >/dev/null 2>&1 || handle_error "Docker is required but not installed."
}

# Extract Docker image contents to a temporary directory
extract_docker_image() {
    local image="$1"
    local tmp_dir="$2"

    log "Creating temporary directory for extraction..."
    mkdir -p "$tmp_dir"

    log "Creating container from Docker image: $image..."
    docker create --name rootfs-container "$image" || handle_error "Failed to create Docker container from image."

    log "Exporting container filesystem..."
    docker export rootfs-container | tar -C "$tmp_dir" -xvf - || handle_error "Failed to export Docker container filesystem."

    log "Removing temporary Docker container..."
    docker rm rootfs-container >/dev/null 2>&1 || log "Warning: Failed to remove Docker container."
}

# Extract Docker image manifest to a JSON file
extract_image_manifest() {
    local image="$1"
    local manifest_file="$2"

    log "Extracting image manifest for $image..."
    docker inspect "$image" >"$manifest_file" || handle_error "Failed to extract image manifest."
    log "Image manifest saved to $manifest_file"
}

# Create and format an empty root filesystem image
create_rootfs_image() {
    local rootfs_img="$1"

    log "Creating empty root filesystem image ($rootfs_img)..."
    dd if=/dev/zero of="$rootfs_img" bs=1M count=1024 || handle_error "Failed to create rootfs image file."
    mkfs.ext4 "$rootfs_img" || handle_error "Failed to format rootfs image as ext4."
}

# Copy extracted files into the root filesystem image
populate_rootfs_image() {
    local tmp_dir="$1"
    local rootfs_img="$2"
    local mount_dir="$3"

    log "Mounting root filesystem image..."
    sudo mount -o loop "$rootfs_img" "$mount_dir" || handle_error "Failed to mount rootfs image."

    log "Copying extracted files to root filesystem image..."
    sudo cp -a "$tmp_dir"/* "$mount_dir" || handle_error "Failed to copy files to rootfs image."

    log "Unmounting root filesystem image..."
    sudo umount "$mount_dir" || handle_error "Failed to unmount rootfs image."
}

# Main script logic
main() {
    if [ -z "$1" ]; then
        handle_error "Usage: $0 <docker-image> [rootfs.img] [manifest.json]"
    fi

    local docker_image="$1"
    local rootfs_img="${2:-rootfs.img}"  # Default to rootfs.img if not provided
    local manifest_file="${3:-manifest.json}"  # Default to manifest.json if not provided
    local tmp_dir
    local mount_dir

    tmp_dir=$(mktemp -d)
    mount_dir=$(mktemp -d)

    check_dependencies

    extract_image_manifest "$docker_image" "$manifest_file"
    extract_docker_image "$docker_image" "$tmp_dir"
    create_rootfs_image "$rootfs_img"
    populate_rootfs_image "$tmp_dir" "$rootfs_img" "$mount_dir"

    log "Cleaning up..."
    rm -rf "$tmp_dir"
    rmdir "$mount_dir"

    log "Root filesystem image ($rootfs_img) created successfully."
    log "Image manifest saved to $manifest_file."
}

# Run the script
main "$@"
