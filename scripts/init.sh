#!/bin/bash

# Source shared logging utilities
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/logging.sh"

# Enable strict error handling
set_error_handlers

# Base directory structure
INFERNO_ROOT=${INFERNO_ROOT:-"/var/lib/inferno"}
export INFERNO_ROOT
VM_DIR="${INFERNO_ROOT}/vms"

# Database path (directly under root)
DB_PATH="${INFERNO_ROOT}/inferno.db"
SCHEMA_PATH="${SCRIPT_DIR}/schema.sql"

# Function to create and set permissions on a directory
create_secure_directory() {
    local dir="$1"
    local perms="${2:-700}"  # Default to 700 if not specified
    
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || {
            error "Failed to create directory: $dir"
            return 1
        }
        chmod "$perms" "$dir" || {
            error "Failed to set permissions on directory: $dir"
            return 1
        }
        debug "Created directory with secure permissions: $dir"
    fi
    return 0
}

# Create initial directory structure
create_directory_structure() {
    # Create base directory
    create_secure_directory "$INFERNO_ROOT" "750" || return 1
    
    # Create VMs directory
    create_secure_directory "$VM_DIR" "750" || return 1
    
    return 0
}

# Initialize the database
init_db() {
    if [[ ! -f "$SCHEMA_PATH" ]]; then
        error "Schema file not found at $SCHEMA_PATH"
        return 1
    fi

    if [[ -f "$DB_PATH" ]]; then
        warn "Database already exists at $DB_PATH"
        return 0
    fi

    if [[ $EUID -eq 0 ]]; then
        error "Database should not be initialized as root"
        return 1
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

# Get VM directory path
get_vm_dir() {
    local name="$1"
    if [[ -z "$name" ]]; then
        error "VM name is required"
        return 1
    fi
    echo "${VM_DIR}/${name}"
}

# Initialize the entire system
init_system() {
    create_directory_structure || return 1
    init_db || return 1
    return 0
}

# Export variables and functions for use in other scripts
export INFERNO_ROOT VM_DIR DB_PATH
export -f create_secure_directory create_directory_structure get_vm_dir