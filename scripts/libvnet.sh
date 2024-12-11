#!/bin/bash

# Source shared logging utilities and config
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/logging.sh"
source "${SCRIPT_DIR}/config.sh"

# Enable strict error handling
set_error_handlers

# Generate a gateway IP in the 172.16.0.0/16 subnet
generate_gateway_ip() {
    local subnet="172.16"
    local octet3=$((RANDOM % 256))
    echo "$subnet.$octet3.1"
}

# Generate a random guest IP in the 172.16.0.0/16 subnet
generate_guest_ip() {
    local subnet="172.16"
    local octet3=$((RANDOM % 256))
    echo "$subnet.$octet3.2"
}

# Generate a random tap device name
generate_tap_name() {
    local tap_name=$(nanoid --alphabet "1234567890abcdef" --size 8)
    echo "tap${tap_name}"
}

# Generate a MAC address
generate_mac() {
    printf 'AA:BB:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

# Check for root privileges for network operations
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This operation requires root privileges"
        return 1
    fi
}

# Check if IP forwarding is enabled
is_ip_forwarding_enabled() {
    local forwarding
    forwarding=$(cat /proc/sys/net/ipv4/ip_forward) || {
        error "Failed to read IP forwarding state"
        return 1
    }
    [[ "$forwarding" == "1" ]]
}

enable_ip_forwarding() {
    require_root
    if ! is_ip_forwarding_enabled; then
        echo 1 > /proc/sys/net/ipv4/ip_forward || {
            error "Failed to enable IP forwarding"
            return 1
        }
    fi
}

# Check if tap device exists
tap_device_exists() {
    local tap_name="$1"
    ip link show "$tap_name" &>/dev/null
}

create_tap_device() {
    require_root
    local tap_name="$1"
    local gateway_ip="$2"

    if tap_device_exists "$tap_name"; then
        warn "Tap device $tap_name already exists"
        return 0
    fi

    # Create operations in a subshell to ensure atomic execution
    (
        ip tuntap add dev "$tap_name" mode tap && \
        ip addr add "$gateway_ip/16" dev "$tap_name" && \
        ip link set "$tap_name" up
    ) || {
        error "Failed to create and configure tap device $tap_name"
        delete_tap_device "$tap_name" 2>/dev/null || true
        return 1
    }
}

delete_tap_device() {
    require_root
    local tap_name="$1"

    if ! tap_device_exists "$tap_name"; then
        warn "Tap device $tap_name does not exist"
        return 0
    fi

    ip link del "$tap_name" || {
        error "Failed to delete tap device $tap_name"
        return 1
    }
}

# Verify network interface exists
verify_interface() {
    local interface="$1"
    ip link show "$interface" &>/dev/null || {
        error "Interface $interface does not exist"
        return 1
    }
}

# Check if nftables rule exists
nft_rule_exists() {
    local table="$1"
    local chain="$2"
    local rule="$3"
    nft list chain ip "$table" "$chain" 2>/dev/null | grep -q "$rule"
}

configure_basic_nftables() {
    require_root || return 1
    local tap_name="$1"
    local gateway_ip="$2"
    local guest_ip="$3"

    # Verify that the required interfaces exist
    verify_interface "$tap_name" || return 1
    verify_interface "$OUTBOUND_INTERFACE" || {
        error "Outbound interface $OUTBOUND_INTERFACE not found. Please specify the correct interface using INFERNO_OUTBOUND_INTERFACE"
        return 1
    }

    # Create table and chains in a subshell to ensure atomic execution
    (
        # Create table if it doesn't exist
        nft list table ip inferno &>/dev/null || {
            nft add table ip inferno
            log "Created nftables table 'inferno'"
        }

        # Create chains if they don't exist
        nft list chain ip inferno forward &>/dev/null || {
            nft add chain ip inferno forward { type filter hook forward priority 0 \; }
            log "Created forward chain"
        }
        
        nft list chain ip inferno postrouting &>/dev/null || {
            nft add chain ip inferno postrouting { type nat hook postrouting priority 100 \; }
            log "Created postrouting chain"
        }

        # Add rules idempotently
        if ! nft_rule_exists "inferno" "forward" "iifname \"$tap_name\""; then
            nft add rule ip inferno forward iifname "$tap_name" oif "$OUTBOUND_INTERFACE" accept
            debug "Added forward rule for $tap_name"
        fi

        if ! nft_rule_exists "inferno" "forward" "ct state"; then
            nft add rule ip inferno forward iif "$OUTBOUND_INTERFACE" oifname "$tap_name" ct state established,related accept
            debug "Added established/related state rule"
        fi

        if ! nft_rule_exists "inferno" "postrouting" "ip saddr $guest_ip"; then
            nft add rule ip inferno postrouting oif "$OUTBOUND_INTERFACE" ip saddr "$guest_ip" masquerade
            debug "Added masquerade rule for $guest_ip"
        fi
        
        return 0
    ) || {
        error "Failed to configure nftables rules"
        return 1
    }
    
    log "Successfully configured basic nftables rules"
}

configure_l7_forwarding() {
    require_root || return 1
    local proxy_ip="$1"
    
    # Check if HAProxy is installed
    if ! command -v haproxy >/dev/null 2>&1; then
        error "HAProxy is required for L7 mode"
        return 1
    fi

    # Add L7 specific rules in a subshell
    (
        verify_interface "$OUTBOUND_INTERFACE" || return 1
        
        if ! nft_rule_exists "inferno" "forward" "ip daddr $proxy_ip"; then
            nft add rule ip inferno forward ip daddr "$proxy_ip" accept
            debug "Added L7 forward rule for $proxy_ip"
        fi
        
        return 0
    ) || {
        error "Failed to configure L7 forwarding rules"
        return 1
    }
    
    log "Successfully configured L7 forwarding"
}

configure_l4_forwarding() {
    require_root || return 1
    local public_ip="$1"
    local guest_ip="$2"
    
    # Add L4 specific rules in a subshell
    (
        verify_interface "$OUTBOUND_INTERFACE" || return 1
        
        if ! nft_rule_exists "inferno" "forward" "ip daddr $public_ip"; then
            nft add rule ip inferno forward ip daddr "$public_ip" accept
            debug "Added L4 forward rule for $public_ip"
        fi
        
        return 0
    ) || {
        error "Failed to configure L4 forwarding rules"
        return 1
    }
    
    log "Successfully configured L4 forwarding"
}

create_vm_network() {
    local name="$1"
    shift
    
    local guest_ip=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --guest-ip)
                guest_ip="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    # Check if VM already exists
    if vm_exists "$name"; then
        error "VM '$name' already exists"
        return 1
    fi

    log "Creating network for VM '$name'"

    # Generate network details
    local tap_name=$(generate_tap_name)
    local gateway_ip=$(generate_gateway_ip)
    local generated_guest_ip="${guest_ip:-$(generate_guest_ip)}"
    local mac_addr=$(generate_mac)

    # Create network configuration
    log "Enabling IP forwarding..."
    enable_ip_forwarding || return 1
    
    log "Creating tap device..."
    create_tap_device "$tap_name" "$gateway_ip" || return 1
    
    log "Configuring basic nftables rules..."
    configure_basic_nftables "$tap_name" "$gateway_ip" "$generated_guest_ip" || {
        delete_tap_device "$tap_name"
        return 1
    }
    
    # Calculate configuration hashes
    local nft_rules_hash
    nft_rules_hash=$(nft list ruleset | sha256sum | cut -d' ' -f1)
    
    # Store in database
    local vm_data
    log "Storing configuration in database..."
    vm_data=$(create_vm_with_state "$name" "$tap_name" "$gateway_ip" "$generated_guest_ip" "$mac_addr" "$nft_rules_hash") || {
        delete_tap_device "$tap_name"
        error "Failed to create VM in database"
        return 1
    }

    log "Basic network setup complete for VM '$name'"
    echo "$vm_data" | jq '.'
}

expose_vm_service() {
    local name="$1"
    shift
    
    local mode=""
    local host_port=""
    local guest_port=""
    local hostname=""
    local public_ip=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                mode="$2"
                shift 2
                ;;
            --host-port)
                host_port="$2"
                shift 2
                ;;
            --guest-port)
                guest_port="$2"
                shift 2
                ;;
            --host)
                hostname="$2"
                shift 2
                ;;
            --public-ip)
                public_ip="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                return 1
                ;;
        esac
    done

    # Validate parameters
    if [[ -z "$mode" ]]; then
        error "Mode (--mode) is required"
        return 1
    fi
    
    if [[ -z "$host_port" ]]; then
        error "Host port (--host-port) is required"
        return 1
    fi
    
    if [[ -z "$guest_port" ]]; then
        error "Guest port (--guest-port) is required"
        return 1
    fi
    
    if [[ "$mode" == "l7" && -z "$hostname" ]]; then
        error "L7 mode requires --host"
        return 1
    fi
    
    if [[ "$mode" == "l4" && -z "$public_ip" ]]; then
        error "L4 mode requires --public-ip"
        return 1
    fi
    
    log "Exposing service for VM '$name'"
    
    # Get VM details
    local vm_data
    vm_data=$(get_vm_by_name "$name") || {
        error "Failed to get VM data"
        return 1
    }
    
    if [[ -z "$vm_data" ]]; then
        error "VM '$name' not found"
        return 1
    fi
    
    local guest_ip
    guest_ip=$(echo "$vm_data" | jq -r '.guest_ip')
    
    # Configure networking based on mode
    log "Configuring $mode mode forwarding..."
    if [[ "$mode" == "l7" ]]; then
        configure_l7_forwarding "127.0.0.1" || return 1
    else
        configure_l4_forwarding "$public_ip" "$guest_ip" || return 1
    fi
    
    # Calculate new state hash
    local nft_rules_hash
    nft_rules_hash=$(nft list ruleset | sha256sum | cut -d' ' -f1)
    
    # Update database
    log "Updating database with new route..."
    local routes_data
    routes_data=$(add_route_to_vm "$name" "$mode" "$host_port" "$guest_port" "$hostname" "$public_ip" "$nft_rules_hash") || {
        error "Failed to update database with new route"
        return 1
    }
    
    log "Service exposure complete for VM '$name'"
    echo "$routes_data" | jq '.'
}

teardown() {
    require_root || return 1
    local tap_name="$1"
    
    # Delete tap device
    delete_tap_device "$tap_name" || {
        error "Failed to delete tap device $tap_name"
        return 1
    }
    
    # Clean up nftables rules
    if nft list table ip inferno &>/dev/null; then
        nft delete table ip inferno || {
            error "Failed to delete nftables rules"
            return 1
        }
    fi
    
    log "Successfully cleaned up all resources"
}