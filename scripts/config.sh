#!/usr/bin/env bash
# config.sh — shared config & JSON generators for Inferno
# VERSION
CONFIG_SH_VERSION="1.2.0"

# This file is intended to be *sourced* by other scripts.

# -------------------------------------------------------------------
# Resolve this script's directory robustly
# -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"

# -------------------------------------------------------------------
# Bring in environment & logging (installed paths, not repo-relative)
# -------------------------------------------------------------------
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/env.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/logging.sh"

# Enable strict traps/handlers from logging.sh
set_error_handlers

# -------------------------------------------------------------------
# Outbound interface detection (used by nftables / NAT rules)
# -------------------------------------------------------------------
DEFAULT_OUTBOUND_INTERFACE="eth0"

detect_outbound_interface() {
  # Prefer default route device; fall back to DEFAULT_OUTBOUND_INTERFACE
  local iface
  iface="$(ip route show default 2>/dev/null | awk '/ default / {for (i=1;i<=NF;i++) if ($i=="dev"){print $(i+1); exit}}')"
  if [[ -n "$iface" ]]; then
    echo "$iface"
  else
    echo "$DEFAULT_OUTBOUND_INTERFACE"
  fi
}

# Allow override via INFERNO_OUTBOUND_INTERFACE; export for downstream users
OUTBOUND_INTERFACE="${INFERNO_OUTBOUND_INTERFACE:-$(detect_outbound_interface)}"
export OUTBOUND_INTERFACE

# --- ULID generator (26 chars, crockford base32) -----------------------------
_ulid_new() {
  # quick ULID-ish (monotonic time + random); good enough for jail IDs
  date +%s%3N | awk '{printf "%026s\n", toupper(sprintf("%x", $1) substr(sprintf("%016x", rand()*2^64),1,16))}' | tr ' ' '0'
}


# -------------------------------------------------------------------
# JSON generators
# -------------------------------------------------------------------

# Build Firecracker machine config JSON
# Args: name rootfs_path tap_device mac_address volume_id vcpus memory
generate_firecracker_config() {
  local name="$1"
  local rootfs_path="$2"
  local tap_device="$3"
  local mac_address="$4"
  local volume_id="$5"
  local vcpus="$6"
  local memory="$7"

  # Base configuration
  local config
  config="$(jq -n \
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
    }')"

  # Optional data volume as /dev/vdb (init will mount it via run.json)
  if [[ -n "$volume_id" ]]; then
    config="$(jq --arg vol_id "$volume_id" \
      '.drives += [{
         "drive_id": $vol_id,
         "path_on_host": ("/dev/inferno_vg/" + $vol_id),
         "is_root_device": false,
         "is_read_only": false
       }]' <<<"$config")"
  fi

  echo "$config"
}

# Build run.json consumed by init (net, mounts, proc, ssh files)
# Args: name guest_ip gateway_ip volume_id process_json ssh_files_json
generate_run_config() {
  local name="$1"
  local guest_ip="$2"
  local gateway_ip="$3"
  local volume_id="$4"
  local process_json="$5"
  local ssh_files="$6"

  # Validate JSON inputs
  if ! jq empty <<<"$process_json" >/dev/null 2>&1; then
    error "Invalid process JSON"
    return 1
  fi
  if ! jq empty <<<"$ssh_files" >/dev/null 2>&1; then
    error "Invalid SSH files JSON"
    return 1
  fi

  local mounts_json
  mounts_json='{
    "root": {
      "device": "/dev/vda",
      "mount_point": "/",
      "fs_type": "ext4",
      "options": ["rw","relatime"]
    },
    "volumes": []
  }'

  # Optional /data volume
  if [[ -n "$volume_id" ]]; then
    mounts_json="$(jq \
      '.volumes += [{
        "device": "/dev/vdb",
        "mount_point": "/data",
        "fs_type": "ext4",
        "options": ["rw"]
      }]' <<<"$mounts_json")"
  fi

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
      user: { name: "root", group: "root", create: true },
      log:  { format: "json", timestamp: true, debug: true },
      etc_resolv: { nameservers: ["8.8.8.8","1.1.1.1"] },
      mounts: $mounts,
      vsock_stdout_port: 10000,
      vsock_exit_port: 10001,
      vsock_api_port: 10002,
      ips: [
        { ip: $guest_ip, gateway: $gateway_ip, mask: 30 }
      ]
    }'
}

# Build kiln.json (driver launcher config)
# Args: name vcpus memory [uid] [gid]
# Defaults harden to 123/100 if not provided or non-numeric.
generate_kiln_config() {
  local name="$1"
  local vcpus="$2"
  local memory="$3"
  local uid_arg="${4:-}"
  local gid_arg="${5:-}"

  # Resolve UID/GID with hard defaults that match the Go constants.
  local uid="${uid_arg:-${INFERNO_JAIL_UID:-123}}"
  local gid="${gid_arg:-${INFERNO_JAIL_GID:-100}}"

  # Enforce numeric values; fall back to 123/100 if not.
  [[ "$uid" =~ ^[0-9]+$ ]] || uid=123
  [[ "$gid" =~ ^[0-9]+$ ]] || gid=100

  # Allow override via env (useful for tests), else generate a fresh ULID
  local jail_id="${INFERNO_JAILER_ID:-$(_ulid_new)}"

  jq -n \
    --arg jail_id "$jail_id" \
    --arg machine_id "$name" \
    --arg vcpus "$vcpus" \
    --arg mem "$memory" \
    --argjson uid "$uid" \
    --argjson gid "$gid" \
    --arg log_dir "./logs" \
    --argjson max_size_mb "${INFERNO_LOG_MAX_SIZE_MB:-100}" \
    --argjson max_files "${INFERNO_LOG_MAX_FILES:-5}" \
    --argjson max_age_days "${INFERNO_LOG_MAX_AGE_DAYS:-30}" \
    --argjson compress "${INFERNO_LOG_COMPRESS:-true}" \
    '{
      jail_id: $jail_id,
      machine_id: $machine_id,
      uid: $uid,
      gid: $gid,
      log: { format: "text", timestamp: true, debug: true },
      firecracker_socket_path: "firecracker.sock",
      firecracker_config_path: "firecracker.json",
      firecracker_vsock_uds_path: "control.sock",
      vsock_stdout_port: 10000,
      vsock_exit_port: 10001,
      log_dir: $log_dir,
      log_rotation: {
        max_size_mb: $max_size_mb,
        max_files: $max_files,
        max_age_days: $max_age_days,
        compress: $compress
      },
      exit_status_path: "exit_status.json",
      resources: {
        cpu_count: ($vcpus|tonumber),
        memory_mb: ($mem|tonumber),
        cpu_kind: "C3"
      }
    }'
}


# Breadcrumb for debugging
type debug >/dev/null 2>&1 && debug "Loaded config.sh v${CONFIG_SH_VERSION} (OUTBOUND_INTERFACE=${OUTBOUND_INTERFACE})"
