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

# setup_encrypted_volume - Format volume with LUKS2, create filesystem, store key
# Args:
#   $1 - volume_id (e.g., vol_01ARZ3NDEKTSV4RRFFQ69G5FAV)
#   $2 - device_path (e.g., /dev/inferno_vg/vol_xxx)
# Returns: 0 on success, 1 on failure
setup_encrypted_volume() {
    local volume_id="$1"
    local device_path="$2"

    if [[ -z "$volume_id" ]]; then
        error "setup_encrypted_volume: volume_id is required"
        return 1
    fi

    if [[ ! -b "$device_path" ]]; then
        error "Device $device_path does not exist"
        return 1
    fi

    # Check if cryptsetup is available
    if ! command -v cryptsetup >/dev/null 2>&1; then
        error "cryptsetup command not found. Install cryptsetup-bin package."
        return 1
    fi

    # Generate 32-byte encryption key (base64 encoded)
    log "Generating encryption key for volume $volume_id..."
    local encryption_key
    encryption_key=$(head -c 32 /dev/urandom | base64 -w0)
    if [[ -z "$encryption_key" ]]; then
        error "Failed to generate encryption key"
        return 1
    fi

    # Format device with LUKS2
    log "Formatting volume with LUKS2 encryption..."
    if ! echo -n "$encryption_key" | base64 -d | \
      cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --key-file=- \
        --batch-mode \
        "$device_path" 2>&1; then
        error "Failed to format volume with LUKS"
        unset encryption_key
        return 1
    fi

    # Temporarily unlock volume to create filesystem
    log "Unlocking volume temporarily to create filesystem..."
    local mapper_name="${volume_id}_tmp"
    if ! echo -n "$encryption_key" | base64 -d | \
      cryptsetup open --key-file=- "$device_path" "$mapper_name" 2>&1; then
        error "Failed to unlock LUKS volume"
        unset encryption_key
        return 1
    fi

    # Create ext4 filesystem on unlocked device
    log "Creating ext4 filesystem..."
    if ! mkfs.ext4 -F -q -L "inferno_volume" "/dev/mapper/$mapper_name" 2>&1; then
        error "Failed to create ext4 filesystem"
        cryptsetup close "$mapper_name" 2>/dev/null || true
        unset encryption_key
        return 1
    fi

    # Lock volume again
    log "Locking volume..."
    if ! cryptsetup close "$mapper_name" 2>&1; then
        warn "Failed to lock volume after filesystem creation"
        # Continue anyway - volume will be locked eventually
    fi

    # Store encryption key in KMS
    log "Storing encryption key in KMS..."
    if type -t kms_store_key >/dev/null 2>&1; then
        if ! kms_store_key "$volume_id" "$encryption_key"; then
            error "Failed to store encryption key in KMS"
            unset encryption_key
            return 1
        fi
    else
        error "KMS functions not available. Cannot store encryption key."
        unset encryption_key
        return 1
    fi

    # Clear key from memory
    unset encryption_key

    log "Volume $volume_id encrypted and key stored successfully"
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

# ============================================================================
# Checkpoint Operations
# ============================================================================

create_checkpoint() {
    local volume_id="$1"
    local comment="${2:-}"
    local checkpoint_type="${3:-user}"

    # Verify volume exists
    local vol_row
    vol_row=$(sqlite3 "$DB_PATH" "SELECT id, state, active_source_checkpoint_id FROM volumes WHERE volume_id = '$volume_id';")

    if [[ -z "$vol_row" ]]; then
        error "Volume $volume_id not found"
        return 1
    fi

    local vol_db_id state active_source
    IFS='|' read -r vol_db_id state active_source <<< "$vol_row"

    # Get next sequence number
    local seq_num
    seq_num=$(sqlite3 "$DB_PATH" "SELECT COALESCE(MAX(sequence_num), 0) + 1 FROM volume_checkpoints WHERE volume_id = $vol_db_id;")

    local lv_name="${volume_id}_cp_$(printf '%03d' "$seq_num")"

    info "Creating checkpoint $lv_name for volume $volume_id (seq: $seq_num)..."

    # Create LVM snapshot
    if ! lvcreate --snapshot --name "$lv_name" "$VG_NAME/${volume_id}" >/dev/null 2>&1; then
        error "Failed to create LVM snapshot"
        return 1
    fi

    # Insert checkpoint record
    local insert_sql
    insert_sql="INSERT INTO volume_checkpoints (volume_id, lv_name, sequence_num, source_checkpoint_id, type, comment)
                VALUES ($vol_db_id, '$lv_name', $seq_num, "

    if [[ -n "$active_source" ]]; then
        insert_sql+="$active_source, "
    else
        insert_sql+="NULL, "
    fi

    insert_sql+="'$checkpoint_type', "

    if [[ -n "$comment" ]]; then
        # Escape single quotes in comment
        local escaped_comment="${comment//\'/\'\'}"
        insert_sql+="'$escaped_comment');"
    else
        insert_sql+="NULL);"
    fi

    sqlite3 "$DB_PATH" "$insert_sql" || {
        error "Failed to insert checkpoint record"
        lvremove -f "$VG_NAME/$lv_name" 2>/dev/null
        return 1
    }

    # Update active_source_checkpoint_id to this new checkpoint
    local new_checkpoint_id
    new_checkpoint_id=$(sqlite3 "$DB_PATH" "SELECT id FROM volume_checkpoints WHERE lv_name = '$lv_name';")

    sqlite3 "$DB_PATH" "UPDATE volumes SET active_source_checkpoint_id = $new_checkpoint_id WHERE id = $vol_db_id;" || {
        warn "Failed to update active_source_checkpoint_id"
    }

    info "Checkpoint $lv_name created successfully (id: $new_checkpoint_id)"
    return 0
}

list_checkpoints() {
    local volume_id="$1"

    # Get volume database ID
    local vol_db_id
    vol_db_id=$(sqlite3 "$DB_PATH" "SELECT id FROM volumes WHERE volume_id = '$volume_id';")

    if [[ -z "$vol_db_id" ]]; then
        error "Volume $volume_id not found"
        return 1
    fi

    # Query checkpoints
    sqlite3 -header -column "$DB_PATH" "
        SELECT
            id,
            sequence_num as seq,
            lv_name,
            type,
            comment,
            datetime(created_at, 'localtime') as created
        FROM volume_checkpoints
        WHERE volume_id = $vol_db_id
        ORDER BY sequence_num DESC;
    "
}

restore_checkpoint() {
    local volume_id="$1"
    local checkpoint_id="$2"

    # Get volume info
    local vol_row
    vol_row=$(sqlite3 "$DB_PATH" "SELECT id, state FROM volumes WHERE volume_id = '$volume_id';")

    if [[ -z "$vol_row" ]]; then
        error "Volume $volume_id not found"
        return 1
    fi

    local vol_db_id state
    IFS='|' read -r vol_db_id state <<< "$vol_row"

    # Verify volume is not attached
    if [[ "$state" == "attached" ]]; then
        error "Cannot restore checkpoint while volume is attached"
        error "Detach volume first with: infernoctl volume detach $volume_id"
        return 1
    fi

    # Get checkpoint info
    local cp_row
    cp_row=$(sqlite3 "$DB_PATH" "SELECT lv_name FROM volume_checkpoints WHERE id = $checkpoint_id AND volume_id = $vol_db_id;")

    if [[ -z "$cp_row" ]]; then
        error "Checkpoint $checkpoint_id not found for volume $volume_id"
        return 1
    fi

    local checkpoint_lv_name="$cp_row"

    info "Restoring volume $volume_id to checkpoint $checkpoint_lv_name..."

    # Optional: Create pre_restore checkpoint
    info "Creating pre-restore checkpoint..."
    create_checkpoint "$volume_id" "Before restore to $checkpoint_lv_name" "pre_restore" || {
        warn "Failed to create pre-restore checkpoint, continuing anyway..."
    }

    # Remove current active LV
    info "Removing current active volume..."
    lvremove -f "$VG_NAME/${volume_id}" || {
        error "Failed to remove active volume"
        return 1
    }

    # Create new active LV as snapshot of checkpoint
    info "Creating new active volume from checkpoint..."
    lvcreate --snapshot --name "$volume_id" "$VG_NAME/$checkpoint_lv_name" || {
        error "Failed to create new active volume from checkpoint"
        return 1
    }

    # Update active_source_checkpoint_id
    sqlite3 "$DB_PATH" "UPDATE volumes SET active_source_checkpoint_id = $checkpoint_id WHERE id = $vol_db_id;" || {
        warn "Failed to update active_source_checkpoint_id"
    }

    info "Volume $volume_id restored to checkpoint $checkpoint_lv_name successfully"
    return 0
}

delete_checkpoint() {
    local checkpoint_id="$1"

    # Get checkpoint info
    local cp_row
    cp_row=$(sqlite3 "$DB_PATH" "SELECT lv_name, volume_id FROM volume_checkpoints WHERE id = $checkpoint_id;")

    if [[ -z "$cp_row" ]]; then
        error "Checkpoint $checkpoint_id not found"
        return 1
    fi

    local lv_name volume_db_id
    IFS='|' read -r lv_name volume_db_id <<< "$cp_row"

    # Check if this is the active source
    local is_active
    is_active=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM volumes WHERE active_source_checkpoint_id = $checkpoint_id;")

    if [[ "$is_active" -gt 0 ]]; then
        error "Cannot delete checkpoint that is the current active source"
        error "Restore to a different checkpoint first"
        return 1
    fi

    info "Deleting checkpoint $lv_name (id: $checkpoint_id)..."

    # Remove LVM snapshot
    lvremove -f "$VG_NAME/$lv_name" || {
        error "Failed to remove LVM snapshot"
        return 1
    }

    # Delete from database
    sqlite3 "$DB_PATH" "DELETE FROM volume_checkpoints WHERE id = $checkpoint_id;" || {
        error "Failed to delete checkpoint record"
        return 1
    }

    info "Checkpoint $lv_name deleted successfully"
    return 0
}

gc_checkpoints() {
    local volume_id="$1"
    local keep_count="${2:-5}"

    # Get volume database ID
    local vol_db_id
    vol_db_id=$(sqlite3 "$DB_PATH" "SELECT id FROM volumes WHERE volume_id = '$volume_id';")

    if [[ -z "$vol_db_id" ]]; then
        error "Volume $volume_id not found"
        return 1
    fi

    info "Running checkpoint GC for volume $volume_id (keeping $keep_count user checkpoints)..."

    # Get user checkpoints to delete (older than the keep_count newest)
    local checkpoints_to_delete
    checkpoints_to_delete=$(sqlite3 "$DB_PATH" "
        SELECT id
        FROM volume_checkpoints
        WHERE volume_id = $vol_db_id
          AND type = 'user'
          AND id NOT IN (
              SELECT id FROM volume_checkpoints
              WHERE volume_id = $vol_db_id AND type = 'user'
              ORDER BY created_at DESC
              LIMIT $keep_count
          )
          AND id NOT IN (
              SELECT active_source_checkpoint_id
              FROM volumes
              WHERE active_source_checkpoint_id IS NOT NULL
          );
    ")

    if [[ -z "$checkpoints_to_delete" ]]; then
        info "No checkpoints to delete"
        return 0
    fi

    local delete_count=0
    while IFS= read -r cp_id; do
        if delete_checkpoint "$cp_id"; then
            delete_count=$((delete_count + 1))
        fi
    done <<< "$checkpoints_to_delete"

    info "Deleted $delete_count old user checkpoints"
    return 0
}
