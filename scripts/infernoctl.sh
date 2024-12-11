#!/bin/bash

VERSION="1.0.0"

# Source dependencies
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/logging.sh"
source "${SCRIPT_DIR}/libvnet.sh"
source "${SCRIPT_DIR}/database.sh"
source "${SCRIPT_DIR}/dependencies.sh"
source "${SCRIPT_DIR}/config.sh"

# Enable strict error handling
set_error_handlers

usage() {
    echo -e "$(cat << EOF
${GREEN}infernoctl${NC} - Inferno VM Network Management Tool v${VERSION}

${YELLOW}USAGE${NC}
    $(basename $0) <command> [options]

${YELLOW}COMMANDS${NC}
    ${GREEN}Dependency Management:${NC}
    check               Check all dependencies and their versions
    install-info        Show installation information for missing dependencies
    generate-install    Generate an installation script for missing dependencies

    ${GREEN}VM Management:${NC}
    create <vm-name>    Create basic network setup for a VM
      Options:
        --guest-ip      Specify the guest IP address (optional)
                       Format: IPv4 address (e.g., 172.16.1.2)

    expose <vm-name>    Expose VM services
      Options:
        --mode          Exposure mode (l4|l7)
        --host-port     Port on the host system
        --guest-port    Port on the guest VM
        --host          Hostname for L7 mode
        --public-ip     Public IP for L4 mode

    list                List all VMs and their configurations
    
    show <vm-name>      Show detailed configuration for a VM
    
    delete <vm-name>    Remove VM and all its configurations

    ${GREEN}Database Management:${NC}
    init                Initialize the database
    reset               Reset the database (warning: destroys all data)

${YELLOW}EXAMPLES${NC}
    # Check system dependencies
    $(basename $0) check

    # Create a new VM with default networking
    $(basename $0) create webapp1

    # Create a VM with specific IP
    $(basename $0) create webapp1 --guest-ip 172.16.1.2

    # Expose a service using L7 (HTTP) mode
    $(basename $0) expose webapp1 --mode l7 --host-port 80 --guest-port 8080 --host webapp1.example.com

    # Expose a service using L4 (TCP) mode
    $(basename $0) expose webapp1 --mode l4 --host-port 5432 --guest-port 5432 --public-ip 203.0.113.1

    # List all VMs
    $(basename $0) list

    # Show specific VM details
    $(basename $0) show webapp1

    # Delete a VM
    $(basename $0) delete webapp1

${YELLOW}NOTES${NC}
    - L7 mode is used for HTTP/HTTPS traffic and requires a hostname
    - L4 mode is used for TCP traffic and requires a public IP
    - All commands requiring elevated privileges will prompt for sudo
    - Database is stored in /etc/vm-network/network.db

For more information, visit: https://github.com/yourusername/inferno
EOF
)"
}

check_privileges() {
    local cmd="$1"
    case "$cmd" in
        create|expose|delete)
            if [[ $EUID -ne 0 ]]; then
                error "The '$cmd' command requires root privileges"
                exit 1
            fi
            ;;
    esac
}

main() {
    check_privileges "$1"

    case "$1" in
        init)
            if [[ $EUID -eq 0 ]]; then
                error "Database should not be initialized as root"
                exit 1
            fi
            init_db
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
        create)
            verify_dependencies "check" >/dev/null || {
                error "Missing required dependencies"
                warn "Run '$(basename $0) install-info' for more information"
                exit 1
            }
            shift
            [[ -z "$1" ]] && { error "VM name required"; exit 1; }
            local name="$1"
            shift
            create_vm_network "$name" "$@" || exit 1
            ;;
        expose)
            shift
            [[ -z "$1" ]] && { error "VM name required"; exit 1; }
            local name="$1"
            shift
            expose_vm_service "$name" "$@" || exit 1
            ;;
        list)
            list_all_vms | jq '.' || exit 1
            ;;
        show)
            shift
            [[ -z "$1" ]] && { error "VM name required"; exit 1; }
            show_vm "$1" || exit 1
            ;;
        delete)
            shift
            [[ -z "$1" ]] && { error "VM name required"; exit 1; }
            local name="$1"
            local tap_device
            
            tap_device=$(get_tap_by_name "$name") || {
                error "Failed to get tap device for VM $name"
                exit 1
            }
            
            log "Deleting VM '$name'..."
            teardown "$tap_device" || {
                error "Failed to teardown VM resources"
                exit 1
            }
            delete_vm "$name" || {
                error "Failed to delete VM from database"
                exit 1
            }
            log "VM '$name' deleted successfully"
            ;;
        --help|-h)
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