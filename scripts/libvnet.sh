#!/usr/bin/env bash

# Version (for copy/paste sync)
LIBVNET_SH_VERSION="1.0.4"

# Source shared logging utilities and config (guarded)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/env.sh"     ]] && source "${SCRIPT_DIR}/env.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/logging.sh" ]] && source "${SCRIPT_DIR}/logging.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/config.sh"  ]] && source "${SCRIPT_DIR}/config.sh"

# Default jailed UID/GID used for TAP ownership (must match kiln/jailer UID/GID)
: "${INFERNO_JAIL_UID:=${DEFAULT_JAIL_UID:-123}}"
: "${INFERNO_JAIL_GID:=${DEFAULT_JAIL_GID:-100}}"

# Enable strict error handling if available
if declare -F set_error_handlers >/dev/null 2>&1; then
  set_error_handlers
fi

# --- Outbound interface resolution -------------------------------------------
# Allow override via env: INFERNO_OUTBOUND_INTERFACE takes precedence.
# If OUTBOUND_INTERFACE is unset/invalid, auto-detect the default route dev.
detect_default_interface() {
  # Try modern "ip route get"
  local dev
  dev="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev"){print $(i+1); exit}}')"
  if [[ -z "$dev" ]]; then
    # Fallback: first default route
    dev="$(ip -o route show to default 2>/dev/null | awk '{print $5; exit}')"
  fi
  printf '%s' "$dev"
}

ensure_outbound_interface() {
  # env override
  if [[ -n "${INFERNO_OUTBOUND_INTERFACE:-}" ]]; then
    OUTBOUND_INTERFACE="$INFERNO_OUTBOUND_INTERFACE"
  fi

  # if unset or invalid, try to auto-detect
  if [[ -z "${OUTBOUND_INTERFACE:-}" ]] || ! ip link show "$OUTBOUND_INTERFACE" &>/dev/null; then
    local det
    det="$(detect_default_interface)"
    if [[ -n "$det" ]] && ip link show "$det" &>/dev/null; then
      OUTBOUND_INTERFACE="$det"
      debug "Auto-detected OUTBOUND_INTERFACE=$OUTBOUND_INTERFACE"
    else
      error "Outbound interface ${OUTBOUND_INTERFACE:-<unset>} not found and auto-detect failed."
      error "Set INFERNO_OUTBOUND_INTERFACE to your uplink (e.g. enp3s0, wlp2s0, tailscale0)."
      return 1
    fi
  fi
  return 0
}

# --- IP/subnet helpers --------------------------------------------------------
# Find next available subnet in 172.16.x.y/30 range
get_next_subnet() {
    local db_path="$DB_PATH"
    local subnet

    # Get the highest third octet used so far using string operations
    subnet=$(sqlite3 "$db_path" "
        SELECT COALESCE(
            MAX(CAST(
                substr(substr(gateway_ip, 8), 1, instr(substr(gateway_ip, 8), '.') - 1)
                AS INTEGER
            )),
            0
        )
        FROM vms;")

    # Increment for next subnet
    subnet=$((subnet + 1))

    # Ensure we don't exceed valid range
    if [ "$subnet" -gt 255 ]; then
        error "No more subnets available in 172.16.0.0/16"
        return 1
    fi

    echo "$subnet"
}

# Generate gateway and guest IPs for a /30 subnet
generate_network_pair() {
    local subnet="$1"
    # For a /30 network:
    # x.x.x.0/30 -> Network address
    # x.x.x.1/30 -> Gateway
    # x.x.x.2/30 -> Guest
    # x.x.x.3/30 -> Broadcast

    local prefix="172.16.$subnet"
    echo "${prefix}.1" "${prefix}.2"
}

# Generate a random tap device name
generate_tap_name() {
    local tap_name
    tap_name=$(nanoid --alphabet "1234567890abcdef" --size 8)
    echo "tap${tap_name}"
}

# Generate a MAC address
generate_mac() {
    printf 'AA:BB:%02x:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
}

# Root requirement for net ops
require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This operation requires root privileges"
        return 1
    fi
}

# IP forwarding helpers
is_ip_forwarding_enabled() {
    local forwarding
    forwarding=$(cat /proc/sys/net/ipv4/ip_forward) || {
        error "Failed to read IP forwarding state"
        return 1
    }
    [[ "$forwarding" == "1" ]]
}

enable_ip_forwarding() {
    require_root || return 1
    if ! is_ip_forwarding_enabled; then
        echo 1 > /proc/sys/net/ipv4/ip_forward || {
            error "Failed to enable IP forwarding"
            return 1
        }
    fi
}

# Tap device helpers
tap_device_exists() {
    local tap_name="$1"
    ip link show "$tap_name" &>/dev/null
}

create_tap_device() {
    require_root || return 1
    local tap_name="$1"
    local gateway_ip="$2"

    if tap_device_exists "$tap_name"; then
        warn "Tap device $tap_name already exists"
        return 0
    fi

    debug "Creating TAP $tap_name owned by ${INFERNO_JAIL_UID}:${INFERNO_JAIL_GID}"

    (
        ip tuntap add dev "$tap_name" mode tap user "$INFERNO_JAIL_UID" group "$INFERNO_JAIL_GID" && \
        ip addr add "$gateway_ip/30" dev "$tap_name" && \
        ip link set "$tap_name" up
    ) || {
        error "Failed to create and configure tap device $tap_name"
        delete_tap_device "$tap_name" 2>/dev/null || true
        return 1
    }
}

delete_tap_device() {
    require_root || return 1
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

# Interface check (simple)
verify_interface() {
    local interface="$1"
    ip link show "$interface" &>/dev/null || {
        error "Interface $interface does not exist"
        return 1
    }
}

# nft helpers
nft_rule_exists() {
    local table="$1"
    local chain="$2"
    local rule="$3"
    nft list chain ip "$table" "$chain" 2>/dev/null | grep -q "$rule"
}

# Delete the first nft rule in a chain that matches a pattern (by handle)
nft_delete_rule_by_match() {
    local table="$1"
    local chain="$2"
    local pattern="$3"
    local handle
    handle=$(nft -a list chain ip "$table" "$chain" 2>/dev/null | awk -v pat="$pattern" '$0 ~ pat {for(i=1;i<=NF;i++) if($i=="handle"){print $(i+1); exit}}')
    if [[ -n "$handle" ]]; then
        nft delete rule ip "$table" "$chain" handle "$handle"
        return $?
    fi
    return 2
}

# Core nftables setup (masquerade + forward rules)
configure_basic_nftables() {
    require_root || return 1
    local tap_name="$1"
    local gateway_ip="$2"
    local guest_ip="$3"

    # Resolve outbound first (env override or auto-detect)
    ensure_outbound_interface || return 1

    # Verify that the required interfaces exist
    verify_interface "$tap_name" || return 1
    verify_interface "$OUTBOUND_INTERFACE" || return 1

    (
        nft list table ip inferno &>/dev/null || {
            nft add table ip inferno
            log "Created nftables table 'inferno'"
        }

        nft list chain ip inferno forward &>/dev/null || {
            nft add chain ip inferno forward { type filter hook forward priority 0 \; }
            log "Created forward chain"
        }

        nft list chain ip inferno postrouting &>/dev/null || {
            nft add chain ip inferno postrouting { type nat hook postrouting priority 100 \; }
            log "Created postrouting chain"
        }

        if ! nft_rule_exists "inferno" "forward" "iifname \"$tap_name\""; then
            nft add rule ip inferno forward iifname "$tap_name" oif "$OUTBOUND_INTERFACE" accept
            debug "Added forward rule for $tap_name -> $OUTBOUND_INTERFACE"
        fi

        if ! nft_rule_exists "inferno" "forward" "ct state"; then
            nft add rule ip inferno forward iif "$OUTBOUND_INTERFACE" oifname "$tap_name" ct state established,related accept
            debug "Added established/related state rule"
        fi

        # Masquerade the /30
        if ! nft_rule_exists "inferno" "postrouting" "ip saddr ${guest_ip}/30"; then
            nft add rule ip inferno postrouting oif "$OUTBOUND_INTERFACE" ip saddr "${guest_ip}/30" masquerade
            debug "Added masquerade rule for ${guest_ip}/30 via $OUTBOUND_INTERFACE"
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

    # Resolve outbound first
    ensure_outbound_interface || return 1

    # Check if HAProxy is installed
    if ! command -v haproxy >/dev/null 2>&1; then
        error "HAProxy is required for L7 mode"
        return 1
    fi

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

    # Resolve outbound first
    ensure_outbound_interface || return 1

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
    local tap_name
    tap_name=$(generate_tap_name)
    local subnet gateway_ip generated_guest_ip

    if [ -z "$guest_ip" ]; then
        subnet=$(get_next_subnet) || return 1
        read -r gateway_ip generated_guest_ip < <(generate_network_pair "$subnet")
        guest_ip="$generated_guest_ip"
        debug "Generated network: subnet=$subnet, gateway=$gateway_ip, guest=$guest_ip"
    else
        if [[ ! "$guest_ip" =~ ^172\.16\.([0-9]+)\.2$ ]]; then
            error "Invalid guest IP format. Must be 172.16.x.2"
            return 1
        fi
        subnet="${BASH_REMATCH[1]}"
        gateway_ip="172.16.${subnet}.1"
        debug "Using provided guest IP: gateway=$gateway_ip, guest=$guest_ip"
    fi

    local mac_addr
    mac_addr=$(generate_mac)

    # Create network configuration
    log "Enabling IP forwarding..."
    enable_ip_forwarding || return 1

    log "Creating tap device..."
    create_tap_device "$tap_name" "$gateway_ip" || return 1

    log "Configuring basic nftables rules..."
    configure_basic_nftables "$tap_name" "$gateway_ip" "$guest_ip" || {
        delete_tap_device "$tap_name"
        return 1
    }

    # Calculate configuration hashes
    local nft_rules_hash
    nft_rules_hash=$(nft list ruleset | sha256sum | cut -d' ' -f1)

    # Store in database
    local vm_data
    log "Storing configuration in database..."
    vm_data=$(create_vm_with_state "$name" "$tap_name" "$gateway_ip" "$guest_ip" "$mac_addr" "$nft_rules_hash") || {
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
            --mode)        mode="$2";       shift 2;;
            --host-port)   host_port="$2";  shift 2;;
            --guest-port)  guest_port="$2"; shift 2;;
            --host)        hostname="$2";   shift 2;;
            --public-ip)   public_ip="$2";  shift 2;;
            *) error "Unknown option: $1";  return 1;;
        esac
    done

    # Validate parameters
    if [[ -z "$mode" ]]; then error "Mode (--mode) is required"; return 1; fi
    if [[ -z "$host_port" ]]; then error "Host port (--host-port) is required"; return 1; fi
    if [[ -z "$guest_port" ]]; then error "Guest port (--guest-port) is required"; return 1; fi
    if [[ "$mode" == "l7" && -z "$hostname" ]]; then error "L7 mode requires --host"; return 1; fi
    if [[ "$mode" == "l4" && -z "$public_ip" ]]; then error "L4 mode requires --public-ip"; return 1; fi

    log "Exposing service for VM '$name'"

    local vm_data
    vm_data=$(get_vm_by_name "$name") || { error "Failed to get VM data"; return 1; }
    if [[ -z "$vm_data" ]]; then error "VM '$name' not found"; return 1; fi

    local guest_ip
    guest_ip=$(echo "$vm_data" | jq -r '.guest_ip')

    # Configure networking based on mode
    log "Configuring $mode mode forwarding..."
    if [[ "$mode" == "l7" ]]; then
        configure_l7_forwarding "127.0.0.1" || return 1
    else
        configure_l4_forwarding "$public_ip" "$guest_ip" || return 1
    fi

    local nft_rules_hash
    nft_rules_hash=$(nft list ruleset | sha256sum | cut -d' ' -f1)

    log "Updating database with new route..."
    local routes_data
    routes_data=$(add_route_to_vm "$name" "$mode" "$host_port" "$guest_port" "$hostname" "$public_ip" "$nft_rules_hash") || {
        error "Failed to update database with new route"
        return 1
    }

    if [[ "$mode" == "l7" ]]; then
        haproxy_required_or_die || return 1
        haproxy_prepare_base_config || return 1
        haproxy_render_routes_from_db || return 1
        haproxy_reload || return 1
    fi

    log "Service exposure complete for VM '$name'"
    echo "$routes_data" | jq '.'
}

publish_vm_service() {
    expose_vm_service "$@"
}

teardown() {
    require_root || return 1
    local tap_name="$1"

    delete_tap_device "$tap_name" || {
        error "Failed to delete tap device $tap_name"
        return 1
    }

    if nft list table ip inferno &>/dev/null; then
        nft delete table ip inferno || {
            error "Failed to delete nftables rules"
            return 1
        }
    fi

    log "Successfully cleaned up all resources"
}

unpublish_vm_service() {
    local name="$1"
    shift

    local mode="" host_port="" guest_port="" hostname="" public_ip=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode) mode="$2"; shift 2;;
            --port) host_port="$2"; shift 2;;
            --target-port) guest_port="$2"; shift 2;;
            --hostname) hostname="$2"; shift 2;;
            --address) public_ip="$2"; shift 2;;
            --soft) shift ;; # accepted by CLI; no-op here yet
            *) warn "Unknown option: $1"; shift ;;
        esac
    done

    if [[ -z "$name" ]]; then error "VM name is required"; return 1; fi
    if [[ -z "$mode" ]]; then error "--mode is required (l4|l7)"; return 1; fi

    local rule_ip=""
    if [[ "$mode" == "l7" ]]; then
        rule_ip="127.0.0.1"
    else
        if [[ -z "$public_ip" ]]; then
            error "--address (public IP) is required for l4 mode"
            return 1
        fi
        rule_ip="$public_ip"
    fi

    if nft_rule_exists "inferno" "forward" "ip daddr $rule_ip"; then
        nft_delete_rule_by_match "inferno" "forward" "ip daddr $rule_ip" || warn "Failed to delete nft forward rule for $rule_ip"
        debug "Removed forward rule for $rule_ip"
    else
        debug "No forward rule found for $rule_ip; nothing to remove"
    fi

    log "Unpublished service for VM '$name' (mode=$mode, ip=$rule_ip)"
}
