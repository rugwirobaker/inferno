#!/bin/bash

# Source shared logging utilities
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_DIR}/logging.sh"

# Default values
DEFAULT_OUTBOUND_INTERFACE="eth0"

# Try to automatically detect the main outbound interface
detect_outbound_interface() {
    # Look for the interface with default route
    local interface
    interface=$(ip route show default | grep -Po '(?<=dev )[^ ]+' | head -1)

    if [[ -n "$interface" ]]; then
        echo "$interface"
    else
        echo "$DEFAULT_OUTBOUND_INTERFACE"
    fi
}

# Environment variable can override the detected interface
OUTBOUND_INTERFACE=${INFERNO_OUTBOUND_INTERFACE:-$(detect_outbound_interface)}

# Enable strict error handling
set_error_handlers

generate_firecracker_config() {
    local name="$1"
    local rootfs_path="$2"
    local tap_device="$3"
    local mac_address="$4"
    local volume_id="$5"
    local vcpus="$6"
    local memory="$7"

    # Base configuration
    local config=$(jq -n \
        --arg kernel "vmlinux" \
        --arg rootfs "$rootfs_path" \
        --arg tap "$tap_device" \
        --arg mac "$mac_address" \
        --arg vcpu "$vcpus" \
        --arg mem "$memory" \
        '{
            "boot-source": {
                "kernel_image_path": $kernel,
                "initrd_path": "initrd.cpio",
                "boot_args": "console=ttyS0 reboot=k panic=1 pci=off rdinit=/inferno/init"
            },
            "drives": [
                {
                    "drive_id": "rootfs",
                    "path_on_host": $rootfs,
                    "is_root_device": false,
                    "is_read_only": false
                }
            ],
            "machine-config": {
                "vcpu_count": ($vcpu|tonumber),
                "mem_size_mib": ($mem|tonumber)
            },
            "vsock": {
                "vsock_id": "control",
                "guest_cid": 3,
                "uds_path": "control.sock"
            },
            "network-interfaces": [
                {
                    "iface_id": "eth0",
                    "host_dev_name": $tap,
                    "guest_mac": $mac
                }
            ]
        }')

    # Add volume if specified
    if [[ -n "$volume_id" ]]; then
        config=$(echo "$config" | jq \
            --arg vol_id "$volume_id" \
            '.drives += [{
                "drive_id": $vol_id,
                "path_on_host": "/dev/inferno_vg/\($vol_id)",
                "is_root_device": false,
                "is_read_only": false
            }]')
    fi

    echo "$config"
}

generate_run_config() {
    local name="$1"
    local guest_ip="$2"
    local gateway_ip="$3"
    local volume_id="$4"
    local process_json="$5"
    local ssh_files="$6"

    # Validate JSON inputs first
    if ! echo "$process_json" | jq empty; then
        error "Invalid process JSON"
        return 1
    fi
    debug "Setting up process JSON: $process_json"

    if ! echo "$ssh_files" | jq empty; then
        error "Invalid SSH files JSON"
        return 1
    fi
    debug "Setting up SSH files JSON: $ssh_files"

    local mounts_json='{
        "root": {
            "device": "/dev/vda",
            "mount_point": "/",
            "fs_type": "ext4",
            "options": ["rw", "relatime"]
        },
        "volumes": []
    }'

    # Add volume mount if specified
    if [[ -n "$volume_id" ]]; then
        mounts_json=$(echo "$mounts_json" | jq \
            --arg vol_id "$volume_id" \
            '.volumes += [{
                "device": "/dev/vdb",
                "mount_point": "/data",
                "fs_type": "ext4",
                "options": ["rw"]
            }]')
    fi
    debug "Setting up mounts JSON: $mounts_json"

    # Create the final config
    jq -n \
        --arg name "$name" \
        --arg guest_ip "$guest_ip" \
        --arg gateway_ip "$gateway_ip" \
        --argjson process "$process_json" \
        --argjson files "$ssh_files" \
        --argjson mounts "$mounts_json" \
        '{
            id: $name,
            process: $process,
            files: $files,
            env: {
                "PATH": "/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin"
            },
            user: {
                name: "root",
                group: "root",
                create: true
            },
            log: {
                format: "text",
                timestamp: true,
                debug: true
            },
            etc_resolv: {
                nameservers: [
                    "8.8.8.8",
                    "1.1.1.1"
                ]
            },
            mounts: $mounts,
            vsock_stdout_port: 10000,
            vsock_exit_port: 10001,
            vsock_api_port: 10002,
            ips: [
                {
                    ip: $guest_ip,
                    gateway: $gateway_ip,
                    mask: 30
                }
            ]
        }'
}

generate_kiln_config() {
    local name="$1"
    local vcpus="$2"
    local memory="$3"

    jq -n \
        --arg name "$name" \
        --arg vcpus "$vcpus" \
        --arg mem "$memory" \
        '{
            jail_id: $name,
            uid: 100,
            gid: 100,
            log: {
                format: "text",
                timestamp: true,
                debug: true
            },
            firecracker_socket_path: "firecracker.sock",
            firecracker_config_path: "firecracker.json",
            firecracker_vsock_uds_path: "control.sock",
            vsock_stdout_port: 10000,
            vsock_exit_port: 10001,
            vm_logs_socket_path: "vm_logs.sock",
            exit_status_path: "exit_status.json",
            resources: {
                cpu_count: ($vcpus|tonumber),
                memory_mb: ($mem|tonumber),
                cpu_kind: "C3"
            }
        }'
}
