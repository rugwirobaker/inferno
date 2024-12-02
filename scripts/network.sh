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

# Generate a random gateway IP in the 172.16.0.0/16 subnet
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

# Create a tap device with a specified name and gateway IP address
create_tap_device() {
    local tap_name="$1"
    local gateway_ip="$2"

    log "Creating tap device $tap_name with gateway IP $gateway_ip"
    sudo ip tuntap add dev "$tap_name" mode tap || handle_error "Failed to add tap device $tap_name"
    sudo ip addr add "$gateway_ip/16" dev "$tap_name" || handle_error "Failed to assign IP $gateway_ip to $tap_name"
    sudo ip link set "$tap_name" up || handle_error "Failed to bring up $tap_name"
}

# Enable IP forwarding on the host
enable_ip_forwarding() {
    log "Enabling IP forwarding"
    sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"
}

# Add a rule to accept packets from a specific tap device
accept_packets() {
    local tap_name="$1"
    log "Accepting packets from $tap_name"
    sudo iptables -t filter -A FORWARD -i "$tap_name" -j ACCEPT -o eth0 -m comment --comment "inferno" || handle_error "Failed to accept packets"
}

# Accept packets on connection state established or related
accept_established_packets() {
    log "Accepting established and related packets"
    sudo iptables -t filter -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "inferno" || handle_error "Failed to accept established and related packets"
}

# Masquerade packets from a specific tap device
masquerade_packets() {
    local tap_name="$1"
    log "Masquerading packets from $tap_name"
    sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE -m comment --comment "inferno" || handle_error "Failed to masquerade packets"
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
    local tap_name="$1"
    log "Deleting tap device $tap_name"
    sudo ip link del "$tap_name" || handle_error "Failed to delete tap device $tap_name"
}

# Teardown function to remove rules and clean up
teardown() {
    local tap_name="$1"
    log "Starting teardown"
    delete_tap_device "$tap_name"
    remove_inferno_rules
    log "Teardown complete"
}

# Update JSON configuration files
update_config_files() {
    local tap_name="$1"
    local guest_ip="$2"
    local gateway_ip="$3"
    local mac_addr="$4"
    local firecracker_json="firecracker.json"
    local run_json="run.json"

    FILE_OWNER=$(stat -c '%U' "$firecracker_json")
    FILE_GROUP=$(stat -c '%G' "$firecracker_json")

    log "Overwriting $firecracker_json with new network interface details"
    jq --arg iface_id "eth0" \
       --arg host_dev_name "$tap_name" \
       --arg guest_mac "$mac_addr" \
       '.["network-interfaces"] = [{"iface_id": $iface_id, "host_dev_name": $host_dev_name, "guest_mac": $guest_mac}]' \
       "$firecracker_json" > temp.json && mv temp.json "$firecracker_json"

    log "Overwriting $run_json with new IP configuration details"
    jq --arg ip "$guest_ip" \
       --arg gateway "$gateway_ip" \
       --argjson mask 16 \
       '.ips = [{"ip": $ip, "gateway": $gateway, "mask": $mask}]' \
       "$run_json" > temp.json && mv temp.json "$run_json"

    # Restore file owner and group
    chown $FILE_OWNER:$FILE_GROUP "$firecracker_json" "$run_json"
}

# Main function to create the tap device, generate config, and update files
setup() {
    check_dependencies

    local gateway_ip=$(generate_gateway_ip)
    local guest_ip=$(generate_guest_ip)
    local tap_name=$(generate_tap_name)
    local mac_addr=$(generate_mac)

    enable_ip_forwarding
    create_tap_device "$tap_name" "$gateway_ip"
    accept_packets "$tap_name"
    accept_established_packets
    masquerade_packets "$tap_name"
    update_config_files "$tap_name" "$guest_ip" "$gateway_ip" "$mac_addr"

    # Output JSON configuration for verification
    log "Configuration generated successfully"
    echo "{ \"tap_name\": \"$tap_name\", \"gateway_ip\": \"$gateway_ip\", \"guest_ip\": \"$guest_ip\", \"mac\": \"$mac_addr\" }"
}

# Switch between setup and teardown
main() {
    case "$1" in
        setup)
            setup
            ;;
        teardown)
            if [ -z "$2" ]; then
                handle_error "Tap device name is required for teardown."
            fi
            teardown "$2"
            ;;
        *)
            echo "Usage: $0 {setup|teardown <tap_name>}"
            exit 1
            ;;
    esac
}

# Run the main function and handle errors
trap 'handle_error "An unexpected error occurred."' ERR
main "$@"
