#!/bin/bash

# Function to exit on errors
set -e

# Function to log messages
log() {
    echo -e "\033[1;32m[INFO]\033[0m $1"
}

# Function to handle errors
handle_error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1"
    exit 1
}

# Ensure required commands are available
check_dependencies() {
    command -v ip >/dev/null 2>&1 || handle_error "ip is required but not installed."
    command -v nanoid >/dev/null 2>&1 || handle_error "nanoid is required but not installed."
    command -v jq >/dev/null 2>&1 || handle_error "jq is required but not installed."
}

# Generate a random IP in the 172.16.0.0/16 subnet
generate_ip() {
    local SUBNET="172.16"
    local OCTET3=$((RANDOM % 256))
    local OCTET4=$((RANDOM % 256))
    echo "$SUBNET.$OCTET3.$OCTET4"
}

# Generate a random tap device name
generate_tap_name() {
    local TAP_NAME=$(nanoid --alphabet "1234567890abcdef" --size 8)
    echo "tap${TAP_NAME}"
}

# Generate a MAC address
generate_mac() {
    printf 'AB:CD:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

# Create a tap device with a specified name and IP address
create_tap_device() {
    local TAP_NAME="$1"
    local IP="$2"
    log "Creating tap device $TAP_NAME with IP $IP"
    sudo ip tuntap add dev "$TAP_NAME" mode tap || handle_error "Failed to add tap device $TAP_NAME"
    sudo ip addr add "$IP/16" dev "$TAP_NAME" || handle_error "Failed to assign IP $IP to $TAP_NAME"
    sudo ip link set "$TAP_NAME" up || handle_error "Failed to bring up $TAP_NAME"
}

# Enable IP forwarding on the host
enable_ip_forwarding() {
    log "Enabling IP forwarding"
    sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
}

# Add a rule to accept packets from a specific tap device
accept_packets() {
    local TAP_NAME="$1"
    local HOST_INTERFACE="$2"
    log "Accepting packets from $TAP_NAME to $HOST_INTERFACE"
    sudo iptables -t filter -A FORWARD -i "$TAP_NAME" -j ACCEPT -o "$HOST_INTERFACE" -m comment --comment "inferno" || handle_error "Failed to accept packets"
}

# Accept packets on connection state established or related
accept_established_packets() {
    log "Accepting established and related packets"
    sudo iptables -t filter -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "inferno" || handle_error "Failed to accept established and related packets"
}

# Masquerade packets from a specific tap device
masquerade_packets() {
    local HOST_INTERFACE="$1"
    log "Masquerading packets to $HOST_INTERFACE"
    sudo iptables -t nat -A POSTROUTING -o "$HOST_INTERFACE" -j MASQUERADE -m comment --comment "inferno" || handle_error "Failed to masquerade packets"
}

# Remove rules tagged with "inferno"
remove_inferno_rules() {
    log "Removing inferno rules"

    # Remove NAT masquerade rules
    while sudo iptables -t nat -L POSTROUTING --line-numbers | grep -q "inferno"; do
        sudo iptables -t nat -D POSTROUTING $(sudo iptables -t nat -L POSTROUTING --line-numbers | grep "inferno" | head -n 1 | awk '{print $1}')
    done

    # Remove FORWARD chain rules
    while sudo iptables -t filter -L FORWARD --line-numbers | grep -q "inferno"; do
        sudo iptables -t filter -D FORWARD $(sudo iptables -t filter -L FORWARD --line-numbers | grep "inferno" | head -n 1 | awk '{print $1}')
    done
}

# Delete the specified tap device
delete_tap_device() {
    local TAP_NAME="$1"
    log "Deleting tap device $TAP_NAME"
    sudo ip link del "$TAP_NAME" || handle_error "Failed to delete tap device $TAP_NAME"
}

# Teardown function to remove rules and clean up
teardown() {
    local TAP_NAME="$1"
    log "Starting teardown"
    delete_tap_device "$TAP_NAME"
    remove_inferno_rules
    log "Teardown complete"
}

# Update JSON configuration files
update_config_files() {
    local TAP_NAME="$1"
    local IP="$2"
    local MAC_ADDR="$3"
    local FIRECRACKER_JSON="firecracker.json"
    local RUN_JSON="run.json"

    FILE_OWNER=$(stat -c '%U' firecracker.json)
    FILE_GROUP=$(stat -c '%G' firecracker.json) 

    log "Updating $FIRECRACKER_JSON with network interface details"
    jq --arg iface_id "eth0" \
       --arg host_dev_name "$TAP_NAME" \
       --arg guest_mac "$MAC_ADDR" \
       '.network_interfaces += [{"iface_id": $iface_id, "host_dev_name": $host_dev_name, "guest_mac": $guest_mac}]' \
       "$FIRECRACKER_JSON" > temp.json && mv temp.json "$FIRECRACKER_JSON"

    log "Updating $RUN_JSON with IP configuration details"
    jq --arg ip "$IP" \
       --arg gateway "172.16.0.1" \
       --argjson mask 16 \
       '.ips += [{"ip": $ip, "gateway": $gateway, "mask": $mask}]' \
       "$RUN_JSON" > temp.json && mv temp.json "$RUN_JSON"

    # Restore file owner and group
    chown $FILE_OWNER:$FILE_GROUP $FIRECRACKER_JSON $RUN_JSON
}

# Main function to create the tap device, generate config, and update files
setup() {
    if [ -z "$1" ]; then
        handle_error "Host network interface is required for setup."
    fi

    local HOST_INTERFACE="$1"
    local IP=$(generate_ip)
    local TAP_NAME=$(generate_tap_name)
    local MAC_ADDR=$(generate_mac)

    enable_ip_forwarding
    create_tap_device "$TAP_NAME" "$IP"
    accept_packets "$TAP_NAME" "$HOST_INTERFACE"
    accept_established_packets
    masquerade_packets "$HOST_INTERFACE"
    update_config_files "$TAP_NAME" "$IP" "$MAC_ADDR"

    # Output JSON configuration for verification
    log "Configuration generated successfully"
    echo "{ \"tap_name\": \"$TAP_NAME\", \"ip\": \"$IP/16\", \"mac\": \"$MAC_ADDR\" }"
}

# Switch between setup and teardown
main() {
    case "$1" in
        setup)
            setup "$2"
            ;;
        teardown)
            if [ -z "$2" ]; then
                handle_error "Tap device name is required for teardown."
            fi
            teardown "$2"
            ;;
        *)
            echo "Usage: $0 {setup <host_interface>|teardown <tap_name>}"
            exit 1
            ;;
    esac
}

# Run the main function and handle errors
trap 'handle_error "An unexpected error occurred."' ERR
main "$@"
