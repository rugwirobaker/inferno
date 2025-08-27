#!/bin/bash

# Version (for copy/paste sync)
LIBVOL_SH_VERSION="1.0.1"

# Source shared logging utilities and config (guarded; works when sourced OR executed)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/env.sh"     ]] && source "${SCRIPT_DIR}/env.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/logging.sh" ]] && source "${SCRIPT_DIR}/logging.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/config.sh"  ]] && source "${SCRIPT_DIR}/config.sh"

# Enable strict error handling if available (don’t assume logging.sh is present)
if declare -F set_error_handlers >/dev/null 2>&1; then
    set_error_handlers
fi

VG_NAME="inferno_vg"

generate_volume_id() {
    echo "vol_$(nanoid --alphabet "0123456789abcdefghijklmnopqrstuvwxyz" --size 16)"
}

verify_volume_group() {
    if ! vgs "$VG_NAME" >/dev/null 2>&1; then
        error "Volume group '$VG_NAME' not found"
        return 1
    fi
}

verify_thin_pool() {
    if ! lvs "$VG_NAME/vm_pool" >/dev/null 2>&1; then
        error "Thin pool '$VG_NAME/vm_pool' not found"
        return 1
    fi
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

    # Check available space in volume group
    local vg_free
    vg_free=$(vgs --noheadings --units g --nosuffix "$VG_NAME" -o vg_free | tr -d '[:space:]')

    # Warn about overprovisioning but allow it
    if (($(echo "$vg_free < $size_gb" | bc -l))); then
        warn "Overprovisioning: Requested ${size_gb}GB with only ${vg_free}GB free in volume group"
        warn "This is OK with thin provisioning but ensure you monitor space usage"
    fi

    # Check thin pool usage
    local pool_usage
    pool_usage=$(lvs --noheadings --units g --nosuffix "$VG_NAME/vm_pool" -o data_percent | tr -d '[:space:]')

    if (($(echo "$pool_usage >= 80" | bc -l))); then
        warn "Thin pool usage is at ${pool_usage}%. Monitor space carefully."
    fi

    # Create thin volume
    log "Creating thin volume '${volume_id}' of size ${size_gb}GB..."
    if ! lvcreate -V "${size_gb}G" -T "$VG_NAME/vm_pool" -n "$volume_id" >/dev/null 2>&1; then
        error "Failed to create thin volume"
        return 1
    fi

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
