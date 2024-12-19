#!/bin/bash

# Source shared logging utilities
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/logging.sh"
source "${SCRIPT_DIR}/init.sh"

# Enable strict error handling
set_error_handlers

SCHEMA_PATH="./scripts/schema.sql"

create_vm_with_state() {
    local name="$1"
    local tap_device="$2"
    local gateway_ip="$3"
    local guest_ip="$4"
    local mac_address="$5"
    local nft_rules_hash="$6"

    debug "Creating VM record for $name with tap device $tap_device"

    local result
    result=$(
        sqlite3 "$DB_PATH" <<EOF
BEGIN TRANSACTION;
INSERT INTO vms (name, tap_device, gateway_ip, guest_ip, mac_address)
VALUES ('$name', '$tap_device', '$gateway_ip', '$guest_ip', '$mac_address')
RETURNING json_object(
    'id', id,
    'name', name,
    'tap_device', tap_device,
    'guest_ip', guest_ip,
    'gateway_ip', gateway_ip,
    'mac_address', mac_address
);

INSERT INTO network_state (vm_id, nft_rules_hash, config_files_hash, state)
VALUES (last_insert_rowid(), '$nft_rules_hash', '', 'created');

COMMIT;
EOF
    )
    if [ $? -ne 0 ]; then
        error "Failed to create VM record in database"
        return 1
    fi

    echo "$result"
}

add_route_to_vm() {
    local vm_name="$1"
    local mode="$2"
    local host_port="$3"
    local guest_port="$4"
    local hostname="$5"
    local public_ip="$6"
    local nft_rules_hash="$7"

    debug "Adding route for VM $vm_name: $mode mode, host port $host_port -> guest port $guest_port"

    local result
    result=$(
        sqlite3 "$DB_PATH" <<EOF
BEGIN TRANSACTION;
INSERT INTO routes (vm_id, mode, host_port, guest_port, hostname, public_ip)
SELECT id, '$mode', $host_port, $guest_port, NULLIF('$hostname', ''), NULLIF('$public_ip', '')
FROM vms WHERE name = '$vm_name';

UPDATE network_state 
SET nft_rules_hash = '$nft_rules_hash',
    state = 'exposed',
    last_updated = CURRENT_TIMESTAMP
WHERE vm_id = (SELECT id FROM vms WHERE name = '$vm_name');

SELECT json_group_array(
    json_object(
        'mode', mode,
        'host_port', host_port,
        'guest_port', guest_port,
        'hostname', hostname,
        'public_ip', public_ip
    )
)
FROM routes
WHERE vm_id = (SELECT id FROM vms WHERE name = '$vm_name')
AND active = TRUE;

COMMIT;
EOF
    )
    if [ $? -ne 0 ]; then
        error "Failed to add route to VM in database"
        return 1
    fi

    echo "$result"
}

get_vm_by_name() {
    local name="$1"
    debug "Fetching VM details for $name"

    local result
    result=$(
        sqlite3 "$DB_PATH" <<EOF
SELECT json_object(
    'name', v.name,
    'tap_device', v.tap_device,
    'guest_ip', v.guest_ip,
    'gateway_ip', v.gateway_ip,
    'mac_address', v.mac_address,
    'state', ns.state,
    'last_updated', ns.last_updated
)
FROM vms v
LEFT JOIN network_state ns ON ns.vm_id = v.id
WHERE v.name = '$name';
EOF
    )
    if [ $? -ne 0 ]; then
        error "Failed to fetch VM details"
        return 1
    fi

    echo "$result"
}

get_vm_routes() {
    local name="$1"
    debug "Fetching routes for VM $name"

    local result
    result=$(
        sqlite3 "$DB_PATH" <<EOF
SELECT json_group_array(
    json_object(
        'mode', mode,
        'host_port', host_port,
        'guest_port', guest_port,
        'hostname', hostname,
        'public_ip', public_ip,
        'active', active
    )
)
FROM routes r
JOIN vms v ON v.id = r.vm_id
WHERE v.name = '$name'
AND r.active = TRUE;
EOF
    )
    if [ $? -ne 0 ]; then
        error "Failed to fetch VM routes"
        return 1
    fi

    echo "$result"
}

list_all_vms() {
    debug "Listing all VMs"
    local result
    result=$(
        sqlite3 -json "$DB_PATH" <<EOF
SELECT 
    v.name,
    v.tap_device,
    v.guest_ip,
    ns.state,
    COUNT(r.id) as active_routes
FROM vms v
LEFT JOIN network_state ns ON ns.vm_id = v.id
LEFT JOIN routes r ON r.vm_id = v.id AND r.active = TRUE
GROUP BY v.id;
EOF
    )
    if [ $? -ne 0 ]; then
        error "Failed to list VMs"
        return 1
    fi

    echo "$result"
}

delete_vm() {
    local name="$1"
    debug "Deleting VM $name"

    local result
    result=$(
        sqlite3 "$DB_PATH" <<EOF
BEGIN TRANSACTION;
UPDATE network_state
SET state = 'deleted',
    last_updated = CURRENT_TIMESTAMP
WHERE vm_id = (SELECT id FROM vms WHERE name = '$name');

UPDATE routes
SET active = FALSE
WHERE vm_id = (SELECT id FROM vms WHERE name = '$name');

COMMIT;
EOF
    )
    if [ $? -ne 0 ]; then
        error "Failed to delete VM from database"
        return 1
    fi

    log "Successfully deleted VM $name from database"
}

get_tap_by_name() {
    local name="$1"
    debug "Fetching tap device for VM $name"

    local result
    result=$(sqlite3 "$DB_PATH" "SELECT tap_device FROM vms WHERE name = '$name';")
    if [ $? -ne 0 ]; then
        error "Failed to fetch tap device"
        return 1
    fi

    echo "$result"
}

vm_exists() {
    local name="$1"
    debug "Checking if VM $name exists"

    local count
    count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM vms WHERE name = '$name';")
    if [ $? -ne 0 ]; then
        error "Failed to check VM existence"
        return 1
    fi
    [[ $count -gt 0 ]]
}

# Volume management functions

create_volume() {
    local name="$1"
    local size_gb="$2"

    local volume_id=$(generate_volume_id)
    local device_path="/dev/$VG_NAME/$volume_id"

    # Create the LVM volume first
    if ! create_lv "$volume_id" "$size_gb"; then
        return 1
    fi

    # Format the volume
    if ! format_volume "$device_path"; then
        return 1
    fi

    local result
    result=$(
        sqlite3 "$DB_PATH" <<EOF
INSERT INTO volumes (volume_id, name, size_gb, device_path)
VALUES ('$volume_id', '$name', $size_gb, '$device_path')
RETURNING json_object(
    'volume_id', volume_id,
    'name', name,
    'size_gb', size_gb,
    'device_path', device_path,
    'created_at', created_at
);
EOF
    )
    if [ $? -ne 0 ]; then
        error "Failed to create volume record in database"
        return 1
    fi

    echo "$result"
}

list_volumes() {
    local result
    result=$(
        sqlite3 -json "$DB_PATH" <<EOF
SELECT 
    v.volume_id,
    v.name,
    v.size_gb,
    v.device_path,
    v.created_at,
    vm.name as vm_name
FROM volumes v
LEFT JOIN vms vm ON v.vm_id = vm.id
ORDER BY v.created_at DESC;
EOF
    )
    if [ $? -ne 0 ]; then
        error "Failed to list volumes"
        return 1
    fi

    echo "$result"
}

get_volume() {
    local volume_id="$1"
    local result
    result=$(
        sqlite3 -json "$DB_PATH" <<EOF
SELECT 
    v.volume_id,
    v.name,
    v.size_gb,
    v.device_path,
    v.created_at,
    vm.name as vm_name
FROM volumes v
LEFT JOIN vms vm ON v.vm_id = vm.id
WHERE v.volume_id = '$volume_id'
LIMIT 1;
EOF
    )
    if [ $? -ne 0 ]; then
        error "Failed to get volume"
        return 1
    fi

    echo "$result"
}

update_volume_vm() {
    local volume_id="$1"
    local vm_name="$2"

    debug "Updating volume $volume_id attachment to VM $vm_name"

    sqlite3 "$DB_PATH" <<EOF
UPDATE volumes 
SET vm_id = (
    SELECT id FROM vms WHERE name = '$vm_name'
)
WHERE volume_id = '$volume_id';
EOF

    if [ $? -ne 0 ]; then
        error "Failed to update volume-VM association"
        return 1
    fi
}

delete_volume() {
    local volume_id="$1"

    debug "Deleting volume $volume_id"

    # Check if volume is attached to a VM
    local attached_vm
    attached_vm=$(sqlite3 "$DB_PATH" "
        SELECT vm.name 
        FROM volumes v 
        JOIN vms vm ON v.vm_id = vm.id 
        WHERE v.volume_id = '$volume_id';
    ")
    if [ $? -ne 0 ]; then
        error "Failed to check if volume is attached"
        return 1
    fi

    if [[ -n "$attached_vm" ]]; then
        error "Volume is still attached to VM: $attached_vm"
        return 1
    fi

    # Get device path before deletion
    local device_path
    device_path=$(sqlite3 "$DB_PATH" "
        SELECT device_path 
        FROM volumes 
        WHERE volume_id = '$volume_id';
    ")
    if [ $? -ne 0 ]; then
        error "Failed to fetch volume device path"
        return 1
    fi

    if [[ -z "$device_path" ]]; then
        error "Volume not found: $volume_id"
        return 1
    fi

    # Delete LVM volume
    if ! delete_lv "$volume_id"; then
        error "Failed to delete logical volume"
        return 1
    fi

    sqlite3 "$DB_PATH" "
        DELETE FROM volumes 
        WHERE volume_id = '$volume_id';
    "
    if [ $? -ne 0 ]; then
        error "Failed to remove volume from database"
        return 1
    fi

    log "Volume $volume_id deleted successfully"
}

verify_volume() {
    local volume_id="$1"
    local device_path

    debug "Verifying volume $volume_id"

    device_path=$(sqlite3 "$DB_PATH" "
        SELECT device_path 
        FROM volumes 
        WHERE volume_id = '$volume_id';
    ")
    if [ $? -ne 0 ]; then
        return 1
    fi

    if [[ -z "$device_path" ]]; then
        error "Volume not found: $volume_id"
        return 1
    fi

    if [[ ! -b "$device_path" ]]; then
        error "Volume device not found: $device_path"
        return 1
    fi

    if ! lvs "$VG_NAME/$volume_id" >/dev/null 2>&1; then
        error "Volume not found in LVM: $volume_id"
        return 1
    fi

    return 0
}

get_vm_volumes() {
    local vm_name="$1"

    debug "Fetching volumes for VM $vm_name"

    local result
    result=$(
        sqlite3 -json "$DB_PATH" <<EOF
SELECT 
    v.volume_id,
    v.name,
    v.size_gb,
    v.device_path,
    v.created_at
FROM volumes v
JOIN vms vm ON v.vm_id = vm.id
WHERE vm.name = '$vm_name'
ORDER BY v.created_at DESC;
EOF
    )
    if [ $? -ne 0 ]; then
        error "Failed to fetch VM volumes"
        return 1
    fi

    echo "$result"
}

get_volume_attachment() {
    local volume_id="$1"
    debug "Checking volume attachment status for $volume_id"

    local result
    result=$(sqlite3 "$DB_PATH" "
        SELECT vm.name 
        FROM volumes v 
        JOIN vms vm ON v.vm_id = vm.id 
        WHERE v.volume_id = '$volume_id';
    ")
    if [ $? -ne 0 ]; then
        error "Failed to check volume attachment status"
        return 1
    fi

    echo "$result"
}

detach_volume() {
    local volume_id="$1"

    debug "Detaching volume $volume_id"

    sqlite3 "$DB_PATH" "
        UPDATE volumes 
        SET vm_id = NULL 
        WHERE volume_id = '$volume_id';
    "
    if [ $? -ne 0 ]; then
        error "Failed to detach volume from VM"
        return 1
    fi

    log "Volume $volume_id detached successfully"
}

create_image() {
    local image_id="$1"
    local name="$2"
    local source_image="$3"
    local rootfs_path="$4"
    local manifest_path="$5"

    debug "Creating image record for $name from $source_image"

    local result
    result=$(
        sqlite3 "$DB_PATH" <<EOF
INSERT INTO images (
    image_id,
    name,
    source_image,
    rootfs_path,
    manifest_path
) VALUES (
    '$image_id',
    '$name',
    '$source_image',
    '$rootfs_path',
    '$manifest_path'
)
RETURNING json_object(
    'image_id', image_id,
    'name', name,
    'source_image', source_image,
    'rootfs_path', rootfs_path,
    'created_at', created_at
);
EOF
    )
    if [ $? -ne 0 ]; then
        error "Failed to create image record in database"
        return 1
    fi

    echo "$result"
}

list_images() {
    debug "Listing all images"

    local result
    result=$(
        sqlite3 -json "$DB_PATH" <<EOF
SELECT 
    i.image_id,
    i.name,
    i.source_image,
    i.created_at,
    COUNT(v.id) as vm_count
FROM images i
LEFT JOIN vms v ON v.image_id = i.id
GROUP BY i.id
ORDER BY i.created_at DESC;
EOF
    )
    if [ $? -ne 0 ]; then
        error "Failed to list images"
        return 1
    fi

    echo "$result"
}

get_image() {
    local image_id="$1"
    debug "Fetching image details for $image_id"

    local result
    result=$(
        sqlite3 -json "$DB_PATH" <<EOF
SELECT json_object(
    'image_id', i.image_id,
    'name', i.name,
    'source_image', i.source_image,
    'rootfs_path', i.rootfs_path,
    'manifest_path', i.manifest_path,
    'created_at', i.created_at,
    'vms', (
        SELECT json_group_array(name)
        FROM vms 
        WHERE image_id = i.id
    )
)
FROM images i
WHERE i.image_id = '$image_id';
EOF
    )
    if [ $? -ne 0 ]; then
        error "Failed to get image details"
        return 1
    fi

    echo "$result"
}

delete_image() {
    local image_id="$1"
    debug "Deleting image $image_id"

    # Check if image is in use
    local vm_count
    vm_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM vms WHERE image_id = (SELECT id FROM images WHERE image_id = '$image_id');")
    if [ $? -ne 0 ]; then
        error "Failed to check image usage"
        return 1
    fi

    if [ "$vm_count" -gt 0 ]; then
        error "Cannot delete image that is in use by VMs"
        return 1
    fi

    # Get paths before deletion
    local paths
    paths=$(sqlite3 "$DB_PATH" "SELECT rootfs_path, manifest_path FROM images WHERE image_id = '$image_id';")
    if [ $? -ne 0 ]; then
        error "Failed to get image paths"
        return 1
    fi
    read -r rootfs_path manifest_path <<<"$paths"

    # Delete from database
    sqlite3 "$DB_PATH" "DELETE FROM images WHERE image_id = '$image_id';"
    if [ $? -ne 0 ]; then
        error "Failed to delete image from database"
        return 1
    fi

    echo "$rootfs_path $manifest_path"
}

update_vm_image() {
    local vm_name="$1"
    local image_id="$2"

    debug "Updating VM $vm_name to use image $image_id"

    sqlite3 "$DB_PATH" <<EOF
UPDATE vms 
SET image_id = (SELECT id FROM images WHERE image_id = '$image_id')
WHERE name = '$vm_name';
EOF

    if [ $? -ne 0 ]; then
        error "Failed to update VM image"
        return 1
    fi
}

is_tap_registered() {
    local tap="$1"
    debug "Checking if tap device $tap is registered in database"

    # Check if database file exists
    if [[ ! -f "$DB_PATH" ]]; then
        debug "Database file does not exist"
        return 1
    fi

    local has_table
    has_table=$(
        sqlite3 "$DB_PATH" <<EOF
SELECT COUNT(*) 
FROM sqlite_master 
WHERE type='table' AND name='vms';
EOF
    )
    if [ $? -ne 0 ]; then
        error "Failed to check if vms table exists"
        return 1
    fi

    if [[ "$has_table" -eq 0 ]]; then
        debug "VMs table does not exist"
        return 1
    fi

    local count
    count=$(
        sqlite3 "$DB_PATH" <<EOF
SELECT COUNT(*) 
FROM vms v 
JOIN network_state ns ON ns.vm_id = v.id 
WHERE v.tap_device = '$tap' 
AND ns.state != 'deleted';
EOF
    )
    if [ $? -ne 0 ]; then
        error "Failed to check if tap device is registered"
        return 1
    fi

    # Return success if count > 0, failure otherwise
    [[ "$count" -gt 0 ]]
}
