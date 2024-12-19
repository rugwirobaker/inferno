#!/bin/bash

# Script version
VERSION="1.0.0"

# Get absolute path to script directory
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

# Source all dependencies
declare -a DEPENDENCIES=(
    "logging.sh"
    "config.sh"
    "init.sh"
    "database.sh"
    "dependencies.sh"
    "libvnet.sh"
    "libvol.sh"
    "images.sh"
    "ssh.sh"
)

for dep in "${DEPENDENCIES[@]}"; do
    source "${SCRIPT_DIR}/${dep}" || {
        echo "Error: Failed to source ${dep}"
        exit 1
    }
done

# Enable strict error handling
set_error_handlers

# Default values for VM creation
readonly DEFAULT_VCPUS=1
readonly DEFAULT_MEMORY=128

usage() {
    echo -e "$(
        cat <<EOF
${GREEN}infernoctl${NC} - Inferno VM Network Management Tool v${VERSION}

${YELLOW}USAGE${NC}
    $(basename $0) <command> [options]

${YELLOW}COMMANDS${NC}
    ${GREEN}Setup:${NC}
    init                Initialize the database and directory structure
    check               Check all dependencies and their versions
    install-info        Show installation information for missing dependencies
    generate-install    Generate an installation script for missing dependencies

    ${GREEN}VM Management:${NC}
    create <name>                        Create a new VM
      Options:
        --image <image>                  Docker image to use (required)
        --volume <volume-id>             Volume ID to attach (optional)
        --vcpus <count>                  Number of vCPUs (default: 1)
        --memory <mb>                    Memory in MB (default: 128)

    expose <name>                        Expose VM services
      Options:
        --mode <l4|l7>                   Exposure mode
        --port <port>                    Port to expose
        --target-port <port>             Target port in VM
        --hostname <host>                Hostname (required for L7)
        --address <ip>                   Public IP (required for L4)

    list                                List all VMs
    show <name>                         Show VM details
    delete <name>                       Delete a VM

    ${GREEN}Volume Management:${NC}
    volume create <name>                 Create a new volume
      Options:
        --size                          Size in GB (default: 10)
    volume list                         List all volumes
    volume show <volume-id>             Show volume details
    volume delete <volume-id>           Delete a volume

    ${GREEN}Cleanup:${NC}
    cleanup                             Clean up Inferno state
      Options:
        -f, --force                     Force cleanup

${YELLOW}EXAMPLES${NC}
    # Create a VM from Docker image
    $(basename $0) create web1 --image nginx:latest

    # Create a volume of 5GB
    $(basename $0) volume create data --size 5

    # Create a VM with volume
    $(basename $0) create web2 --image nginx:latest --volume vol_xyz789

    # Expose HTTP service
    $(basename $0) expose web1 --mode l7 --port 80 --target-port 80 --hostname web1.local

For more information, visit: https://github.com/yourusername/inferno
EOF
    )"
}

# Check if command needs root privileges
check_privileges() {
    local cmd="$1"
    case "$cmd" in
    create | expose | delete | volume | cleanup)
        if [[ $EUID -ne 0 ]]; then
            error "The '$cmd' command requires root privileges"
            exit 1
        fi
        ;;
    esac
}

create_vm() {
    local name="$1"
    shift

    # Parse arguments
    local image="" volume_id=""
    local vcpus="$DEFAULT_VCPUS" memory="$DEFAULT_MEMORY"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --image)
            image="$2"
            shift 2
            ;;
        --volume)
            volume_id="$2"
            shift 2
            ;;
        --vcpus)
            vcpus="$2"
            shift 2
            ;;
        --memory)
            memory="$2"
            shift 2
            ;;
        *)
            error "Unknown option: $1"
            return 1
            ;;
        esac
    done

    debug "Parsed arguments: image=$image, volume=$volume_id, vcpus=$vcpus, memory=$memory"

    # Validate required arguments
    if [[ -z "$image" ]]; then
        error "Image (--image) is required"
        return 1
    fi

    # Handle volume verification early if specified
    local volume_info
    if [[ -n "$volume_id" ]]; then
        log "Verifying volume..."
        if ! verify_volume "$volume_id"; then
            error "Invalid or inaccessible volume: $volume_id"
            return 1
        fi

        # Check if volume is already attached
        local attached_vm
        attached_vm=$(get_volume_attachment "$volume_id") || return 1

        if [[ -n "$attached_vm" ]]; then
            error "Volume $volume_id is already attached to VM: $attached_vm"
            return 1
        fi

        # Get volume information for later use
        volume_info=$(get_volume "$volume_id") || {
            error "Failed to get volume information"
            return 1
        }
    fi

    # Setup VM root directory
    local vm_root rootfs_path
    vm_root=$(get_vm_dir "$name") || return 1
    rootfs_path="$vm_root/rootfs.img"

    debug "Using VM directory: $vm_root"
    if [[ -d "$vm_root" ]]; then
        error "VM directory already exists: $vm_root"
        return 1
    fi

    # Create VM directory with proper permissions
    mkdir -p "$vm_root" || {
        error "Failed to create directory: $vm_root"
        return 1
    }
    chmod 750 "$vm_root" || {
        error "Failed to set permissions on directory: $vm_root"
        return 1
    }

    # Define system file mappings (source -> destination)
    declare -A system_files=(
        ["/usr/share/inferno/firecracker"]="$vm_root/firecracker"
        ["/usr/share/inferno/vmlinux"]="$vm_root/vmlinux"
        ["/usr/share/inferno/kiln"]="$vm_root/kiln"
    )

    # Copy system files
    log "Copying system files..."
    for src in "${!system_files[@]}"; do
        local dst="${system_files[$src]}"
        if [[ ! -f "$src" ]]; then
            error "Required system file not found: $src"
            rm -rf "$vm_root"
            return 1
        fi

        cp "$src" "$dst" || {
            error "Failed to copy system file: $src -> $dst"
            rm -rf "$vm_root"
            return 1
        }

        chmod 755 "$dst" || {
            error "Failed to set permissions on: $dst"
            rm -rf "$vm_root"
            return 1
        }
    done

    # Create initramfs structure
    local initramfs_dir="$vm_root/initramfs"
    local inferno_dir="$initramfs_dir/inferno"
    mkdir -p "$inferno_dir" || {
        error "Failed to create initramfs directory structure"
        rm -rf "$vm_root"
        return 1
    }

    # Copy init binary and run.json to initramfs
    cp "/usr/share/inferno/init" "$inferno_dir/init" || {
        error "Failed to copy init binary"
        rm -rf "$vm_root"
        return 1
    }
    chmod 755 "$inferno_dir/init"

    # Create and format rootfs image
    log "Creating root filesystem image..."
    if ! dd if=/dev/zero of="$rootfs_path" bs=1M count=1024 status=none; then
        error "Failed to create rootfs image"
        rm -rf "$vm_root"
        return 1
    fi

    if ! mkfs.ext4 -F -q "$rootfs_path"; then
        error "Failed to format rootfs image"
        rm -rf "$vm_root"
        return 1
    fi

    # Extract container image to rootfs
    if ! extract_docker_image "$image" "$rootfs_path"; then
        rm -rf "$vm_root"
        return 1
    fi

    # Setup network
    log "Setting up network..."
    local network_config
    network_config=$(create_vm_network "$name")
    if [[ $? -ne 0 ]]; then
        rm -rf "$vm_root"
        return 1
    fi
    debug "Network configuration complete: $network_config"

    # Attach volume if specified
    if [[ -n "$volume_id" ]]; then
        log "Attaching volume..."
        if ! update_volume_vm "$volume_id" "$name"; then
            error "Failed to attach volume to VM"
            rm -rf "$vm_root"
            return 1
        fi
        debug "Volume attached: $volume_id"
    fi

    # Get container metadata
    log "Getting container metadata..."
    local process_json
    process_json=$(get_container_metadata "$image")
    if [[ $? -ne 0 ]]; then
        error "Failed to get container metadata"
        rm -rf "$vm_root"
        return 1
    fi
    debug "Got process JSON: $process_json"

    # Generate SSH configuration
    local ssh_config="{}"
    if type generate_ssh_files &>/dev/null; then
        log "Generating SSH configuration..."
        if ! ssh_config=$(generate_ssh_files "$name"); then
            warn "Failed to generate SSH configuration, continuing without SSH access"
            ssh_config="{}"
        fi
    fi

    # Generate run.json for the init process
    log "Generating init configuration..."
    generate_run_config \
        "$name" \
        "$(echo "$network_config" | jq -r '.guest_ip')" \
        "$(echo "$network_config" | jq -r '.gateway_ip')" \
        "$volume_id" \
        "$process_json" \
        "$ssh_config" >"$inferno_dir/run.json"

    # Create initrd.cpio
    log "Creating initrd.cpio..."
    (cd "$initramfs_dir" && find . | cpio -H newc -o >"$vm_root/initrd.cpio") || {
        error "Failed to create initrd.cpio"
        rm -rf "$vm_root"
        return 1
    }

    # Generate firecracker config
    log "Generating firecracker configuration..."
    generate_firecracker_config \
        "$name" \
        "rootfs.img" \
        "$(echo "$network_config" | jq -r '.tap_device')" \
        "$(echo "$network_config" | jq -r '.mac_address')" \
        "$volume_id" \
        "$vcpus" \
        "$memory" >"$vm_root/firecracker.json"

    # Generate kiln config
    log "Generating kiln configuration..."
    generate_kiln_config "$name" "$vcpus" "$memory" >"$vm_root/kiln.json" || {
        error "Failed to generate kiln configuration"
        rm -rf "$vm_root"
        return 1
    }

    # Fix file ownership
    log "Setting file ownership..."
    if [[ -n "$SUDO_USER" ]]; then
        chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$vm_root"
    else
        chown -R "$(id -un):$(id -gn)" "$vm_root"
    fi

    log "VM created successfully in $vm_root"

    # Return VM details
    cat <<EOF | jq '.'
{
    "name": "$name",
    "root_dir": "$vm_root",
    "network": $(echo "$network_config"),
    "volume": $(if [[ -n "$volume_id" ]]; then echo "\"$volume_id\""; else echo "null"; fi)
}
EOF
}

cleanup() {
    require_root || return 1
    local force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
        -f | --force)
            force=1
            shift
            ;;
        *)
            error "Unknown option: $1"
            return 1
            ;;
        esac
    done

    # Clean up networking components
    log "Cleaning up routes..."
    while read -r route; do
        if [[ -n "$route" ]]; then
            local network=$(echo "$route" | awk '{print $1}')
            local dev=$(echo "$route" | awk '{print $3}')
            log "Removing route: $route"
            ip route del "$network" dev "$dev" || warn "Failed to remove route: $network via $dev"
        fi
    done < <(ip route show | grep '172.16')

    log "Cleaning up tap devices..."
    while read -r tap; do
        if [[ -n "$tap" ]]; then
            local tap_name=$(echo "$tap" | awk '{print $2}' | sed 's/:$//')
            if [[ $force -eq 1 ]] || ! is_tap_registered "$tap_name"; then
                log "Removing tap device: $tap_name"
                ip link set "$tap_name" down 2>/dev/null || true
                ip link delete "$tap_name" 2>/dev/null || warn "Failed to remove tap device: $tap_name"
            else
                warn "Skipping tap device in use: $tap_name"
            fi
        fi
    done < <(ip link show | grep ': tap')

    # Clean up nftables
    log "Cleaning up nftables rules..."
    if nft list tables | grep -q 'table ip inferno'; then
        nft flush table ip inferno
        nft delete table ip inferno || warn "Failed to delete nftables table"
    fi

    # Clean up volumes
    log "Checking volumes..."
    if lvs "$VG_NAME" >/dev/null 2>&1; then
        while read -r volume_id; do
            if [[ -n "$volume_id" ]]; then
                if [[ $force -eq 1 ]] || ! is_volume_in_use "$volume_id"; then
                    log "Removing volume: $volume_id"
                    lvremove -f "$VG_NAME/$volume_id" >/dev/null 2>&1 ||
                        warn "Failed to remove volume: $volume_id"
                else
                    warn "Skipping volume in use: $volume_id"
                fi
            fi
        done < <(lvs --noheadings -o lv_name "$VG_NAME" 2>/dev/null | grep '^vol_')
    fi

    # Clean up database state if forced
    if [[ $force -eq 1 ]]; then
        log "Cleaning up database state..."
        sqlite3 "$DB_PATH" <<EOF || warn "Failed to clean up database state"
        BEGIN TRANSACTION;
        -- Clean network state
        UPDATE network_state 
        SET state = 'deleted', 
            last_updated = CURRENT_TIMESTAMP 
        WHERE state != 'deleted';
        
        -- Clean up routes
        UPDATE routes 
        SET active = FALSE 
        WHERE active = TRUE;

        -- Clean up volume attachments
        UPDATE volumes
        SET vm_id = NULL;
        
        COMMIT;
EOF
    fi

    log "Cleanup complete"
}
# Add this helper function to check if a volume is in use
is_volume_in_use() {
    local volume_id="$1"
    local mounted

    # Check if volume is mounted
    mounted=$(lsblk -n -o MOUNTPOINT "/dev/$VG_NAME/$volume_id" 2>/dev/null)
    if [[ -n "$mounted" ]]; then
        return 0 # Volume is mounted
    fi

    # Check database for VM associations if not mounted
    local attached
    attached=$(get_volume_attachment "$volume_id")
    [[ -n "$attached" ]]
}

# # Helper function to check if nftables has any inferno rules
# has_inferno_rules() {
#     nft list ruleset | grep -q 'table ip inferno'
# }

main() {
    check_privileges "$1"

    case "$1" in
    init)
        if [[ $EUID -eq 0 ]]; then
            error "Database should not be initialized as root"
            exit 1
        fi
        init_system || exit 1
        ;;

    check)
        verify_dependencies "check"
        ;;

    install-info)
        verify_dependencies "install-info"
        ;;

    generate-install)
        generate_install_script
        ;;

    cleanup)
        shift
        cleanup "$@"
        ;;

    volume)
        shift
        case "$1" in
        create)
            shift
            if [[ -z "$1" ]]; then
                error "Volume name required"
                exit 1
            fi
            local name="$1"
            shift

            local size_gb=10
            while [[ $# -gt 0 ]]; do
                case "$1" in
                --size)
                    size_gb="$2"
                    shift 2
                    ;;
                *)
                    error "Unknown option: $1"
                    exit 1
                    ;;
                esac
            done

            create_volume "$name" "$size_gb" | jq '.' || exit 1
            ;;
        list)
            list_volumes | jq '.' || exit 1
            ;;
        show)
            shift
            if [[ -z "$1" ]]; then
                error "Volume ID required"
                exit 1
            fi
            get_volume "$1" | jq '.' || exit 1
            ;;
        delete)
            shift
            if [[ -z "$1" ]]; then
                error "Volume ID required"
                exit 1
            fi
            delete_volume "$1" || exit 1
            ;;
        *)
            error "Unknown volume command: $1"
            exit 1
            ;;
        esac
        ;;

    create)
        shift
        if [[ -z "$1" ]]; then
            error "VM name required"
            exit 1
        fi
        create_vm "$@" || exit 1
        ;;

    expose)
        shift
        if [[ -z "$1" ]]; then
            error "VM name required"
            exit 1
        fi
        expose_vm_service "$@" || exit 1
        ;;

    list)
        list_all_vms | jq '.' || exit 1
        ;;

    show)
        shift
        if [[ -z "$1" ]]; then
            error "VM name required"
            exit 1
        fi
        get_vm_by_name "$1" | jq '.' || exit 1
        ;;

    delete)
        shift
        if [[ -z "$1" ]]; then
            error "VM name required"
            exit 1
        fi
        local name="$1"
        local tap_device

        tap_device=$(get_tap_by_name "$name") || exit 1

        log "Deleting VM '$name'..."
        teardown "$tap_device" || exit 1

        # Remove VM directory and database entry
        rm -rf "$(get_vm_dir "$name")" || warn "Failed to remove VM directory"
        delete_vm "$name" || exit 1

        log "VM '$name' deleted successfully"
        ;;

    --help | -h)
        usage
        exit 0
        ;;

    *)
        usage
        exit 1
        ;;
    esac
}

main "$@"
