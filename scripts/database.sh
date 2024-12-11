#!/bin/bash

# Source shared logging utilities
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/logging.sh"

# Enable strict error handling
set_error_handlers

DB_DIR="./data"
DB_PATH="$DB_DIR/inferno.db"
SCHEMA_PATH="./scripts/schema.sql"

init_db() {
    if [[ ! -d "$DB_DIR" ]]; then
        mkdir -p "$DB_DIR" || {
            error "Failed to create database directory at $DB_DIR"
            return 1
        }
        # Set restrictive permissions
        chmod 700 "$DB_DIR" || {
            error "Failed to set permissions on $DB_DIR"
            return 1
        }
        log "Created database directory with secure permissions"
    fi

    if [[ ! -f "$SCHEMA_PATH" ]]; then
        error "Schema file not found at $SCHEMA_PATH"
        return 1
    fi

    if [[ -f "$DB_PATH" ]]; then
        warn "Database already exists at $DB_PATH"
        return 0
    fi

    # Create the database with proper permissions
    touch "$DB_PATH" || {
        error "Failed to create database file at $DB_PATH"
        return 1
    }
    
    chmod 600 "$DB_PATH" || {
        error "Failed to set permissions on $DB_PATH"
        return 1
    }

    log "Initializing database with schema..."
    if sqlite3 "$DB_PATH" < "$SCHEMA_PATH"; then
        log "Database initialized successfully at $DB_PATH"
        return 0
    else
        error "Failed to initialize database"
        return 1
    fi
}

create_vm_with_state() {
    local name="$1"
    local tap_device="$2"
    local gateway_ip="$3"
    local guest_ip="$4"
    local mac_address="$5"
    local nft_rules_hash="$6"
    
    debug "Creating VM record for $name with tap device $tap_device"
    
    local result
    result=$(sqlite3 "$DB_PATH" <<EOF
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
    ) || {
        error "Failed to create VM record in database"
        return 1
    }
    
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
    result=$(sqlite3 "$DB_PATH" <<EOF
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
    ) || {
        error "Failed to add route to VM in database"
        return 1
    }
    
    echo "$result"
}

get_vm_by_name() {
    local name="$1"
    debug "Fetching VM details for $name"
    
    sqlite3 "$DB_PATH" <<EOF || { error "Failed to fetch VM details"; return 1; }
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
}

get_vm_routes() {
    local name="$1"
    debug "Fetching routes for VM $name"
    
    sqlite3 "$DB_PATH" <<EOF || { error "Failed to fetch VM routes"; return 1; }
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
}

list_all_vms() {
    debug "Listing all VMs"
    sqlite3 -json "$DB_PATH" <<EOF || { error "Failed to list VMs"; return 1; }
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
}

delete_vm() {
    local name="$1"
    debug "Deleting VM $name"
    
    sqlite3 "$DB_PATH" <<EOF || { error "Failed to delete VM from database"; return 1; }
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
    
    log "Successfully deleted VM $name from database"
}

get_tap_by_name() {
    local name="$1"
    debug "Fetching tap device for VM $name"
    
    sqlite3 "$DB_PATH" "SELECT tap_device FROM vms WHERE name = '$name';" || {
        error "Failed to fetch tap device"
        return 1
    }
}

vm_exists() {
    local name="$1"
    debug "Checking if VM $name exists"
    
    local count
    count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM vms WHERE name = '$name';") || {
        error "Failed to check VM existence"
        return 1
    }
    [[ $count -gt 0 ]]
}