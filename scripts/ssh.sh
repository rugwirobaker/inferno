#!/bin/bash

# Source shared logging utilities
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/logging.sh"

# Enable strict error handling
set_error_handlers

# Get user's actual home directory even when running with sudo
get_user_home() {
    if [[ -n "$SUDO_USER" ]]; then
        getent passwd "$SUDO_USER" | cut -d: -f6
    else
        echo "$HOME"
    fi
}

# Generate base64 encoded content for authorized_keys
get_authorized_keys() {
    local user_home
    user_home=$(get_user_home)

    local pub_key_path="$user_home/.ssh/id_rsa.pub"
    local alt_key_paths=("$user_home/.ssh/id_ed25519.pub" "$user_home/.ssh/id_ecdsa.pub")

    debug "Looking for SSH keys in $user_home/.ssh/"

    # Try default RSA key first
    if [[ -f "$pub_key_path" ]]; then
        debug "Found RSA public key at $pub_key_path"
        base64 -w0 <"$pub_key_path"
        return 0
    fi

    # Try alternative key types
    for key_path in "${alt_key_paths[@]}"; do
        if [[ -f "$key_path" ]]; then
            debug "Found public key at $key_path"
            base64 -w0 <"$key_path"
            return 0
        fi
    done

    error "No SSH public key found in $user_home/.ssh/"
    return 1
}

# Generate host key file content
generate_host_key() {
    local vm_name="$1"
    if [[ -z "$vm_name" ]]; then
        error "VM name is required for host key generation"
        return 1
    fi

    # Check for ssh-keygen availability
    if ! command -v ssh-keygen >/dev/null 2>&1; then
        error "ssh-keygen not found. Please install openssh-client"
        return 1
    fi

    # Create temporary directory with proper permissions
    local temp_dir
    temp_dir=$(mktemp -d) || {
        error "Failed to create temporary directory"
        return 1
    }
    chmod 700 "$temp_dir"

    local temp_key="$temp_dir/host_key"
    debug "Creating temporary key at $temp_key"

    # Generate key with proper permissions from the start
    ssh-keygen -t ed25519 \
        -f "$temp_key" \
        -N "" \
        -C "vm-${vm_name}-host-key" \
        -E sha256 \
        -q || {
        rm -rf "$temp_dir"
        error "Failed to generate host key"
        return 1
    }

    debug "Key generated, encoding to base64"
    base64 -w0 <"$temp_key" || {
        rm -rf "$temp_dir"
        error "Failed to encode host key"
        return 1
    }

    local exit_code=$?
    rm -rf "$temp_dir"
    return $exit_code
}

# Generate VM SSH configuration files
generate_ssh_files() {
    local vm_name="$1"
    if [[ -z "$vm_name" ]]; then
        error "VM name is required"
        return 1
    fi

    local host_key_content
    local authorized_keys_content

    debug "Generating SSH host key for VM $vm_name..."
    host_key_content=$(generate_host_key "$vm_name") || return 1

    debug "Getting authorized keys..."
    authorized_keys_content=$(get_authorized_keys) || return 1

    if [[ -z "$host_key_content" ]]; then
        error "Generated host key content is empty"
        return 1
    fi

    if [[ -z "$authorized_keys_content" ]]; then
        error "Generated authorized keys content is empty"
        return 1
    fi

    debug "Generating SSH files configuration"
    # Use jq to properly escape JSON strings
    jq -n \
        --arg host_key "$host_key_content" \
        --arg auth_keys "$authorized_keys_content" \
        '[
            {
                "path": "/etc/inferno/ssh/host_key",
                "content": $host_key,
                "mode": 420
            },
            {
                "path": "/etc/inferno/ssh/authorized_keys",
                "content": $auth_keys,
                "mode": 420
            }
        ]'
}
