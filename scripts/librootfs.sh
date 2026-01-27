#!/bin/bash

# librootfs.sh - LVM thin volume management for rootfs images
# Version: 1.0.0

# Source shared logging utilities and config
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/env.sh"     ]] && source "${SCRIPT_DIR}/env.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/logging.sh" ]] && source "${SCRIPT_DIR}/logging.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/database.sh" ]] && source "${SCRIPT_DIR}/database.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/images.sh"  ]] && source "${SCRIPT_DIR}/images.sh"

# Enable strict error handling if available
if declare -F set_error_handlers >/dev/null 2>&1; then
    set_error_handlers
fi

# Constants
ROOTFS_VG_NAME="${ROOTFS_VG_NAME:-inferno_rootfs_vg}"
ROOTFS_POOL_NAME="${ROOTFS_POOL_NAME:-rootfs_pool}"
ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-5120}"  # Default 5GB

# Check if LVM rootfs feature is enabled and configured
# Returns: 0 if enabled, 1 if disabled/unavailable
rootfs_lvm_available() {
    [[ "${INFERNO_ROOTFS_LVM_ENABLED:-0}" == "1" ]] || return 1
    vgs "$ROOTFS_VG_NAME" >/dev/null 2>&1 || return 1
    lvs "$ROOTFS_VG_NAME/$ROOTFS_POOL_NAME" >/dev/null 2>&1 || return 1
    return 0
}

# Get rootfs size (static for now, configurable via env)
# Output: Size in MB
rootfs_get_size() {
    echo "${ROOTFS_SIZE_MB}"
}

# Generate base image LV name from Docker digest
# Args: $1 = docker_digest (e.g., sha256:abc123...)
# Output: base_<short_hash>
rootfs_base_lv_name() {
    local digest="$1"
    local short_hash="${digest##*:}"  # Strip "sha256:" prefix
    short_hash="${short_hash:0:12}"   # First 12 chars
    echo "base_${short_hash}"
}

# Generate ephemeral snapshot LV name
# Args: $1 = vm_name, $2 = version (ULID)
# Output: snap_<vmname>_<version_short>
rootfs_snapshot_lv_name() {
    local vm_name="$1"
    local version="$2"
    local version_short="${version:0:12}"
    echo "snap_${vm_name}_${version_short}"
}

# Check if base image exists in database
# Args: $1 = docker_digest
# Returns: 0 if exists, 1 if not
rootfs_base_exists() {
    local digest="$1"
    local result
    result="$(sqlite3 "$DB_PATH" "SELECT 1 FROM base_images WHERE docker_digest = '$digest' LIMIT 1;" 2>/dev/null || true)"
    [[ "$result" == "1" ]]
}

# Get base image LV path from digest
# Args: $1 = docker_digest
# Output: /dev/mapper/inferno_rootfs_vg-base_...
rootfs_base_path() {
    local digest="$1"
    sqlite3 "$DB_PATH" "SELECT lv_path FROM base_images WHERE docker_digest = '$digest';" 2>/dev/null || true
}

# Get base image ID from digest
# Args: $1 = docker_digest
# Output: base image ID (integer)
rootfs_base_id() {
    local digest="$1"
    sqlite3 "$DB_PATH" "SELECT id FROM base_images WHERE docker_digest = '$digest';" 2>/dev/null || true
}

# Create base image from Docker image
# Args: $1 = image_ref, $2 = docker_digest
# Output: LV path
rootfs_create_base() {
    local image="$1"
    local digest="$2"
    local size_mb
    size_mb="$(rootfs_get_size)"

    # Check if already exists
    if rootfs_base_exists "$digest"; then
        debug "Base image $digest already exists"
        # Update last_used_at
        sqlite3 "$DB_PATH" "UPDATE base_images SET last_used_at = datetime('now') WHERE docker_digest = '$digest';" 2>/dev/null || true
        rootfs_base_path "$digest"
        return 0
    fi

    local lv_name
    lv_name="$(rootfs_base_lv_name "$digest")"
    local lv_path="/dev/${ROOTFS_VG_NAME}/${lv_name}"

    log "Creating base image LV: $lv_name (${size_mb}MB)"

    # Create thin volume
    if ! lvcreate -V "${size_mb}M" -T "$ROOTFS_VG_NAME/$ROOTFS_POOL_NAME" -n "$lv_name" >/dev/null 2>&1; then
        error "Failed to create base LV $lv_name"
        return 1
    fi

    # Format as ext4
    if ! mkfs.ext4 -F -q "$lv_path" 2>/dev/null; then
        error "Failed to format base LV $lv_name"
        lvremove -f "$ROOTFS_VG_NAME/$lv_name" >/dev/null 2>&1 || true
        return 1
    fi

    # Extract Docker image into LV
    local mnt
    mnt="$(mktemp -d)" || {
        error "Failed to create temp mount point"
        lvremove -f "$ROOTFS_VG_NAME/$lv_name" >/dev/null 2>&1 || true
        return 1
    }

    if ! mount "$lv_path" "$mnt" 2>/dev/null; then
        error "Failed to mount base LV $lv_name"
        rm -rf "$mnt"
        lvremove -f "$ROOTFS_VG_NAME/$lv_name" >/dev/null 2>&1 || true
        return 1
    fi

    # Extract using existing function
    local extract_success=0
    if type -t extract_docker_image >/dev/null 2>&1; then
        # extract_docker_image expects a file path, but we have a mounted device
        # We'll use the alternative method below
        extract_success=0
    fi

    if [[ $extract_success -eq 0 ]] && type -t _images_container_create >/dev/null 2>&1 && type -t _images_container_export >/dev/null 2>&1; then
        local cid
        cid="$(_images_container_create "$image" 2>/dev/null)" || cid=""
        if [[ -n "$cid" ]]; then
            if _images_container_export "$cid" 2>/dev/null | tar -C "$mnt" -xf - 2>/dev/null; then
                extract_success=1
            fi
            _images_container_rm "$cid" 2>/dev/null || true
        fi
    fi

    if [[ $extract_success -eq 0 ]]; then
        error "Failed to extract image $image to base LV"
        umount "$mnt" 2>/dev/null || true
        rm -rf "$mnt"
        lvremove -f "$ROOTFS_VG_NAME/$lv_name" >/dev/null 2>&1 || true
        return 1
    fi

    sync
    umount "$mnt" 2>/dev/null || true
    rm -rf "$mnt"

    # Get manifest JSON for storage
    local manifest_json="{}"
    if type -t images_inspect_json >/dev/null 2>&1; then
        manifest_json="$(images_inspect_json "$image" 2>/dev/null | jq -c . 2>/dev/null || echo '{}')"
    fi

    # Store in database
    local escaped_ref escaped_manifest
    escaped_ref="$(echo "$image" | sed "s/'/''/g")"
    escaped_manifest="$(echo "$manifest_json" | sed "s/'/''/g")"

    sqlite3 "$DB_PATH" <<EOF
INSERT INTO base_images (docker_ref, docker_digest, lv_name, lv_path, size_mb, manifest_json)
VALUES (
    '$escaped_ref',
    '$digest',
    '$lv_name',
    '$lv_path',
    $size_mb,
    '$escaped_manifest'
);
EOF

    if [ $? -ne 0 ]; then
        error "Failed to record base image in database"
        lvremove -f "$ROOTFS_VG_NAME/$lv_name" >/dev/null 2>&1 || true
        return 1
    fi

    success "Base image created: $lv_name"
    echo "$lv_path"
}

# Create ephemeral snapshot from base image
# Args: $1 = vm_name, $2 = vm_id, $3 = docker_digest, $4 = version
# Output: snapshot LV path
rootfs_create_snapshot() {
    local vm_name="$1"
    local vm_id="$2"
    local digest="$3"
    local version="$4"

    # Get base image ID and LV name
    local base_info
    base_info="$(sqlite3 "$DB_PATH" "SELECT id, lv_name FROM base_images WHERE docker_digest = '$digest';" 2>/dev/null || true)"

    if [[ -z "$base_info" ]]; then
        error "Base image not found for digest $digest"
        return 1
    fi

    local base_id="${base_info%%|*}"
    local base_lv="${base_info##*|}"

    # Generate snapshot name
    local snap_lv
    snap_lv="$(rootfs_snapshot_lv_name "$vm_name" "$version")"
    local snap_path="/dev/${ROOTFS_VG_NAME}/${snap_lv}"

    # Check for existing snapshot (cleanup from crash)
    if lvs "$ROOTFS_VG_NAME/$snap_lv" >/dev/null 2>&1; then
        warn "Orphaned snapshot exists: $snap_lv; removing"
        lvremove -f "$ROOTFS_VG_NAME/$snap_lv" >/dev/null 2>&1 || true
        sqlite3 "$DB_PATH" "DELETE FROM ephemeral_snapshots WHERE lv_name = '$snap_lv';" 2>/dev/null || true
    fi

    log "Creating ephemeral snapshot: $snap_lv"

    # Create thin snapshot
    if ! lvcreate -s "$ROOTFS_VG_NAME/$base_lv" -n "$snap_lv" >/dev/null 2>&1; then
        error "Failed to create snapshot $snap_lv"
        return 1
    fi

    # Clear skip-activation flag and activate (thin snapshots default to -k for crash consistency)
    if ! lvchange -kn "$ROOTFS_VG_NAME/$snap_lv" >/dev/null 2>&1; then
        error "Failed to clear skip-activation flag on $snap_lv"
        lvremove -f "$ROOTFS_VG_NAME/$snap_lv" >/dev/null 2>&1 || true
        return 1
    fi

    if ! lvchange -ay "$ROOTFS_VG_NAME/$snap_lv" >/dev/null 2>&1; then
        error "Failed to activate snapshot $snap_lv"
        lvremove -f "$ROOTFS_VG_NAME/$snap_lv" >/dev/null 2>&1 || true
        return 1
    fi

    # Set permissions for jailer UID (best effort)
    local jail_uid="${JAIL_UID:-${DEFAULT_JAIL_UID:-123}}"
    local jail_gid="${JAIL_GID:-${DEFAULT_JAIL_GID:-100}}"
    chown "${jail_uid}:${jail_gid}" "$snap_path" 2>/dev/null || true
    chmod 0660 "$snap_path" 2>/dev/null || true

    # Record in database
    sqlite3 "$DB_PATH" <<EOF
INSERT INTO ephemeral_snapshots (vm_id, base_image_id, lv_name, lv_path)
VALUES ($vm_id, $base_id, '$snap_lv', '$snap_path');
EOF

    if [ $? -ne 0 ]; then
        error "Failed to record snapshot in database"
        lvremove -f "$ROOTFS_VG_NAME/$snap_lv" >/dev/null 2>&1 || true
        return 1
    fi

    # Update base image last_used_at
    sqlite3 "$DB_PATH" "UPDATE base_images SET last_used_at = datetime('now') WHERE id = $base_id;" 2>/dev/null || true

    success "Snapshot created: $snap_lv"
    echo "$snap_path"
}

# Delete ephemeral snapshot
# Args: $1 = vm_name OR vm_id
rootfs_delete_snapshot() {
    local vm_identifier="$1"

    # Resolve to vm_id if name provided
    local vm_id="$vm_identifier"
    if ! [[ "$vm_id" =~ ^[0-9]+$ ]]; then
        vm_id="$(sqlite3 "$DB_PATH" "SELECT id FROM vms WHERE name = '$vm_identifier';" 2>/dev/null || true)"
    fi

    if [[ -z "$vm_id" ]]; then
        debug "VM not found: $vm_identifier"
        return 0
    fi

    # Get snapshot info
    local snap_info
    snap_info="$(sqlite3 "$DB_PATH" "SELECT lv_name FROM ephemeral_snapshots WHERE vm_id = $vm_id;" 2>/dev/null || true)"

    if [[ -z "$snap_info" ]]; then
        debug "No snapshot for VM $vm_identifier"
        return 0
    fi

    local snap_lv="$snap_info"

    log "Deleting ephemeral snapshot: $snap_lv"

    # Remove LV
    if ! lvremove -f "$ROOTFS_VG_NAME/$snap_lv" >/dev/null 2>&1; then
        warn "Failed to remove LV $snap_lv"
    fi

    # Remove from database
    sqlite3 "$DB_PATH" "DELETE FROM ephemeral_snapshots WHERE vm_id = $vm_id;" 2>/dev/null || true

    success "Snapshot deleted: $snap_lv"
}

# Cleanup orphaned snapshots (after crashes)
rootfs_cleanup_orphans() {
    log "Checking for orphaned snapshots..."

    # Get all snapshot LVs from LVM
    local lvm_snapshots
    lvm_snapshots="$(lvs --noheadings -o lv_name "$ROOTFS_VG_NAME" 2>/dev/null | grep '^[[:space:]]*snap_' | tr -d '[:space:]' || true)"

    if [[ -z "$lvm_snapshots" ]]; then
        info "No snapshots found in LVM"
        return 0
    fi

    local orphan_count=0
    while IFS= read -r lv_name; do
        [[ -z "$lv_name" ]] && continue

        # Check if snapshot exists in database
        local in_db
        in_db="$(sqlite3 "$DB_PATH" "SELECT 1 FROM ephemeral_snapshots WHERE lv_name = '$lv_name' LIMIT 1;" 2>/dev/null || true)"

        if [[ -z "$in_db" ]]; then
            warn "Orphaned snapshot: $lv_name; removing"
            lvremove -f "$ROOTFS_VG_NAME/$lv_name" >/dev/null 2>&1 || true
            ((orphan_count++))
        fi
    done <<<"$lvm_snapshots"

    if [[ $orphan_count -gt 0 ]]; then
        success "Cleaned up $orphan_count orphaned snapshot(s)"
    else
        info "No orphaned snapshots found"
    fi
}

# Check thin pool usage and warn if high
rootfs_check_pool_usage() {
    local pool_usage
    pool_usage="$(lvs --noheadings --units g --nosuffix -o data_percent "$ROOTFS_VG_NAME/$ROOTFS_POOL_NAME" 2>/dev/null | tr -d '[:space:]' || true)"

    if [[ -z "$pool_usage" ]]; then
        warn "Could not determine thin pool usage for $ROOTFS_VG_NAME/$ROOTFS_POOL_NAME"
        return 0
    fi

    # Remove any non-numeric characters (sometimes returns "N/A")
    if ! [[ "$pool_usage" =~ ^[0-9.]+$ ]]; then
        debug "Pool usage format unexpected: $pool_usage"
        return 0
    fi

    # Warn at 80%, error at 95%
    if (( $(echo "$pool_usage >= 95" | bc -l 2>/dev/null || echo 0) )); then
        error "Thin pool usage CRITICAL: ${pool_usage}% - Immediate action required!"
        error "  Volume group: $ROOTFS_VG_NAME"
        error "  Thin pool: $ROOTFS_POOL_NAME"
        return 1
    elif (( $(echo "$pool_usage >= 80" | bc -l 2>/dev/null || echo 0) )); then
        warn "Thin pool usage HIGH: ${pool_usage}% - Consider expanding pool"
        warn "  Volume group: $ROOTFS_VG_NAME"
        warn "  Thin pool: $ROOTFS_POOL_NAME"
    else
        debug "Thin pool usage: ${pool_usage}%"
    fi

    return 0
}

# List all base images
rootfs_list_bases() {
    sqlite3 -json "$DB_PATH" <<EOF
SELECT
    docker_ref,
    docker_digest,
    lv_name,
    size_mb,
    created_at,
    last_used_at
FROM base_images
ORDER BY last_used_at DESC;
EOF
}

# List all active snapshots
rootfs_list_snapshots() {
    sqlite3 -json "$DB_PATH" <<EOF
SELECT
    v.name AS vm_name,
    es.lv_name,
    es.lv_path,
    bi.docker_ref,
    es.created_at
FROM ephemeral_snapshots es
JOIN vms v ON es.vm_id = v.id
JOIN base_images bi ON es.base_image_id = bi.id
ORDER BY es.created_at DESC;
EOF
}
