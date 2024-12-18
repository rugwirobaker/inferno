#!/bin/bash

# Source shared logging utilities and config
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/logging.sh"
source "${SCRIPT_DIR}/config.sh"

# Enable strict error handling
set_error_handlers

VG_NAME="inferno_vg"

generate_volume_id() {
    echo "vol_$(nanoid --alphabet "0123456789abcdefghijklmnopqrstuvwxyz" --size 16)"
}

format_volume() {
    local device_path="$1"
    
    if [[ ! -b "$device_path" ]]; then
        error "Device $device_path does not exist"
        return 1
    fi
    
    log "Formatting volume with ext4..."
    mkfs.ext4 -F -q "$device_path" || {
        error "Failed to create ext4 filesystem"
        return 1
    }
    
    return 0
}

create_lv() {
    local volume_id="$1"
    local size_gb="$2"
    
    # Validate VG and pool existence
    verify_volume_group || return 1
    verify_thin_pool || return 1
    
    # Create thin volume
    log "Creating thin volume '${volume_id}' of size ${size_gb}GB..."
    lvcreate -V "${size_gb}G" -T "$VG_NAME/vm_pool" -n "$volume_id" || {
        error "Failed to create thin volume"
        return 1
    }
    
    # Format the new volume
    format_volume "/dev/$VG_NAME/$volume_id" || {
        error "Failed to format volume"
        lvremove -f "$VG_NAME/$volume_id"
        return 1
    }
    
    return 0
}

delete_lv() {
    local volume_id="$1"
    
    if ! lvs "$VG_NAME/$volume_id" >/dev/null 2>&1; then
        warn "Volume $volume_id does not exist"
        return 0
    fi
    
    log "Removing volume $volume_id..."
    lvremove -f "$VG_NAME/$volume_id" || {
        error "Failed to remove volume $volume_id"
        return 1
    }
    
    return 0
}