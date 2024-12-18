#!/bin/bash

# Source shared logging utilities and config
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/logging.sh"
source "${SCRIPT_DIR}/config.sh"

# Enable strict error handling
set_error_handlers

verify_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        error "Docker is required but not installed"
        return 1
    fi
}

extract_docker_image() {
    local docker_image="$1"
    local rootfs_path="$2"
    local container_id=""
    local tmp_dir=""
    local mount_dir=""

    if ! verify_docker; then
        return 1
    fi

    # Cleanup function that handles cleanup regardless of how we exit
    cleanup() {
        local exit_code=$?

        # Only try to cleanup if the directories were created
        if [[ -n "${tmp_dir:-}" ]]; then
            rm -rf "$tmp_dir"
        fi
        if [[ -n "${mount_dir:-}" ]]; then
            # Ensure mount is cleaned up
            if mountpoint -q "$mount_dir" 2>/dev/null; then
                umount "$mount_dir" 2>/dev/null
            fi
            rm -rf "$mount_dir"
        fi
        # Cleanup container if it exists
        if [[ -n "${container_id:-}" ]]; then
            docker rm "$container_id" 2>/dev/null || true
        fi
        # Remove rootfs on failure
        if [[ $exit_code -ne 0 && -n "${rootfs_path:-}" && -f "$rootfs_path" ]]; then
            rm -f "$rootfs_path"
        fi
        return $exit_code
    }

    # Set up cleanup trap
    trap cleanup EXIT

    # Create temporary directories
    tmp_dir=$(mktemp -d) || {
        error "Failed to create temp dir"
        return 1
    }

    mount_dir=$(mktemp -d) || {
        error "Failed to create mount dir"
        return 1
    }

    # Rest of the function remains the same...
}

verify_rootfs() {
    local rootfs_path="$1"

    # Check if file exists and is a regular file
    if ! [[ -f "$rootfs_path" ]]; then
        error "Rootfs image not found: $rootfs_path"
        return 1
    fi

    # Check if it's an ext4 filesystem
    local fs_type
    fs_type=$(blkid -o value -s TYPE "$rootfs_path")
    if [[ $? -ne 0 ]]; then
        error "Failed to determine filesystem type"
        return 1
    fi

    if [[ "$fs_type" != "ext4" ]]; then
        error "Invalid filesystem type: $fs_type (expected ext4)"
        return 1
    fi

    return 0
}

# Helper function to extract process configuration from Docker image
get_container_metadata() {
    local image="$1"

    # First check if Docker is available
    if ! command -v docker >/dev/null 2>&1; then
        error "Docker is not installed or not in PATH"
        return 1
    fi

    debug "Inspecting Docker image: $image"

    # Get container metadata with explicit format
    local manifest
    manifest=$(docker inspect --format '{{json .Config}}' "$image" 2>/dev/null) || {
        error "Failed to inspect Docker image: $image"
        return 1
    }

    debug "Got manifest: $manifest"

    # Parse Cmd and Entrypoint with explicit null handling
    local cmd_str entrypoint_str
    cmd_str=$(echo "$manifest" | jq -r '.Cmd | if type == "array" then map(.) else [] end | join("\n")')
    entrypoint_str=$(echo "$manifest" | jq -r '.Entrypoint | if type == "array" then map(.) else [] end | join("\n")')

    debug "Parsed Cmd: $cmd_str"
    debug "Parsed Entrypoint: $entrypoint_str"

    # Combine entrypoint and cmd properly
    local cmd_args
    if [[ -n "$entrypoint_str" ]]; then
        if [[ -n "$cmd_str" ]]; then
            cmd_args=$(printf '%s\n%s\n' "$entrypoint_str" "$cmd_str" | jq -R . | jq -s .)
        else
            cmd_args=$(printf '%s\n' "$entrypoint_str" | jq -R . | jq -s .)
        fi
    else
        if [[ -n "$cmd_str" ]]; then
            cmd_args=$(printf '%s\n' "$cmd_str" | jq -R . | jq -s .)
        else
            # Default to shell if no command specified
            cmd_args='["/bin/sh"]'
        fi
    fi

    debug "Combined command args: $cmd_args"

    # Get environment variables with fallback to empty array
    local env_vars
    env_vars=$(echo "$manifest" | jq '.Env // []')

    debug "Environment variables: $env_vars"

    # Construct final process JSON
    local process_json
    process_json=$(jq -n \
        --argjson cmd_args "$cmd_args" \
        --argjson env "$env_vars" \
        '{
            "cmd": ($cmd_args[0] // "/bin/sh"),
            "args": ($cmd_args[1:] // []),
            "env": $env
        }')

    debug "Generated process JSON: $process_json"
    echo "$process_json"
    return 0
}
