#!/usr/bin/env bash
# Inferno CLI wrapper
# Provides user-facing commands and delegates to the library scripts.
# Keep this file thin; most logic should live in libs (images, haproxy, db, â€¦).
INFERNOCTL_SH_VERSION="1.2.2"

# --- Bootstrap ---------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/env.sh"        ]] && source "${SCRIPT_DIR}/env.sh"

DEFAULT_JAIL_UID="${INFERNO_JAIL_UID:-123}"
DEFAULT_JAIL_GID="${INFERNO_JAIL_GID:-100}"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/logging.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config.sh"

# Optional libs
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/database.sh"     ]] && source "${SCRIPT_DIR}/database.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/dependencies.sh" ]] && source "${SCRIPT_DIR}/dependencies.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/images.sh"       ]] && source "${SCRIPT_DIR}/images.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/haproxy.sh"      ]] && source "${SCRIPT_DIR}/haproxy.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/libvol.sh"       ]] && source "${SCRIPT_DIR}/libvol.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/librootfs.sh"    ]] && source "${SCRIPT_DIR}/librootfs.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/libvnet.sh"      ]] && source "${SCRIPT_DIR}/libvnet.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/init.sh"         ]] && source "${SCRIPT_DIR}/init.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/ssh.sh"          ]] && source "${SCRIPT_DIR}/ssh.sh"

if declare -F set_error_handlers >/dev/null 2>&1; then
  set_error_handlers
fi

# --- Helpers -----------------------------------------------------------------
require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die 127 "missing required command: $c"
  done
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    die 1 "This action requires root. Re-run with sudo."
  fi
}

# Derived paths
get_vm_dir() {
  local name="$1"
  echo "${INFERNO_ROOT}/vms/${name}"
}

# Versioned chroot base: ~/.local/share/inferno/vms/kiln/<VERSION>/root
_chroot_base_dir() { echo "${INFERNO_ROOT}/vms"; }
_kiln_versions_dir() { echo "$(_chroot_base_dir)/kiln"; }

# --- Small utilities needed by create/start/stop -----------------------------
link_or_copy() {
  local src="$1" dst="$2"
  ln -f "$src" "$dst" 2>/dev/null || cp -f "$src" "$dst"
}

_ensure_dev_nodes() {
  local chroot_dir="$1" uid="$2" gid="$3"
  local dev="$chroot_dir/dev"
  mkdir -p "$dev"

  _mk() {
    local path="$1" type="$2" major="$3" minor="$4" mode="$5"
    [[ -e "$path" ]] || { mknod "$path" "$type" "$major" "$minor" || return 1; }
    chown "$uid:$gid" "$path" || true
    chmod "$mode" "$path" || true
  }

  _mk "$dev/null" c 1 3 0666
  _mk "$dev/zero" c 1 5 0666
  _mk "$dev/tty"  c 5 0 0666
  # NOTE: /dev/kvm is created by the jailer, not here
  # _mk "$dev/net/tun"   c 10 200 0666
}

_read_pid() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  local p; p="$(tr -d ' \t\r\n' <"$f" 2>/dev/null)"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  echo "$p"
}

_wait_pid_dead() {
  local pid="$1" timeout="${2:-10}"
  local end=$(( $(date +%s) + timeout ))
  while kill -0 "$pid" 2>/dev/null; do
    if (( $(date +%s) >= end )); then
      return 1
    fi
    sleep 0.2
  done
  return 0
}


# Resolve the "current" version for a VM (latest recorded)
_resolve_vm_version() {
  local name="$1" v=""
  if type -t get_latest_vm_version >/dev/null 2>&1; then
    v="$(get_latest_vm_version "$name" | tr -d '[:space:]')" || true
  fi
  echo "$v"
}

_version_for_vm() {
  local name="$1" v=""
  if type -t get_latest_vm_version >/dev/null 2>&1; then
    v="$(get_latest_vm_version "$name" 2>/dev/null || true)"
    v="${v//$'\r'/}"; v="${v//$'\n'/}"   # trim newlines
  fi
  if [[ -z "$v" && -f "$(get_vm_dir "$name")/kiln.json" ]]; then
    v="$(jq -r '.jail_id // empty' "$(get_vm_dir "$name")/kiln.json" 2>/dev/null || true)"
  fi
  [[ -n "$v" ]] || return 1
  echo "$v"
}

# --- Jailer helpers -----------------------------------------------------------
_jailer_bin() {
  if [[ -n "${INFERNO_JAILER_BIN:-}" && -x "$INFERNO_JAILER_BIN" ]]; then
    echo "$INFERNO_JAILER_BIN"; return
  fi
  if [[ -x "/usr/share/inferno/jailer" ]]; then
    echo "/usr/share/inferno/jailer"; return
  fi
  command -v jailer 2>/dev/null || true
}

# Sets: VM_ROOT, KILN_CFG, JAIL_ID, JAIL_UID, JAIL_GID, EXEC_BASE, KILN_SRC, KILN_EXEC, CHROOT_DIR, LOGF
_resolve_vm_ctx() {
  local name="$1"
  [[ -n "$name" ]] || die 2 "_resolve_vm_ctx: missing VM name"

  VM_ROOT="$(get_vm_dir "$name")"
  [[ -d "$VM_ROOT" ]] || die 1 "VM directory not found: $VM_ROOT"

  # Version (immutable): from DB; no kiln.json inside VM root anymore
  JAIL_ID="$(_version_for_vm "$name")" \
    || die 1 "No version recorded for '$name' (did you run 'infernoctl create $name ...'?)"

  EXEC_BASE="kiln"
  CHROOT_DIR="$(_kiln_versions_dir)/${JAIL_ID}/root"
  [[ -d "$CHROOT_DIR" ]] || die 1 "Chroot not found for version ${JAIL_ID}: $CHROOT_DIR"

  # Host kiln binary; jailer will hard-link this into the jail
  KILN_SRC="/usr/share/inferno/kiln"
  if [[ ! -x "$KILN_SRC" ]]; then
    KILN_SRC="$(command -v kiln || true)"
  fi
  [[ -n "$KILN_SRC" && -x "$KILN_SRC" ]] || die 1 "kiln binary not found in /usr/share/inferno or PATH"
  KILN_EXEC="$KILN_SRC"   # pass host path to jailer

  JAIL_UID="$DEFAULT_JAIL_UID"
  JAIL_GID="$DEFAULT_JAIL_GID"

  LOGF="${INFERNO_ROOT}/logs/${name}.log"
}

# --- Guest API transport helpers ---------------------------------------------
_sig_num() {
  case "$1" in
    SIGTERM|TERM|15) echo 15;;
    SIGINT|INT|2)    echo 2;;
    SIGKILL|KILL|9)  echo 9;;
    SIGQUIT|QUIT|3)  echo 3;;
    *) kill -l "$1" 2>/dev/null || echo 15;;
  esac
}

_find_kiln_pid_file() {
  local vm_root="$1" name; name="$(basename "$vm_root")"
  local ver; ver="$(_version_for_vm "$name" 2>/dev/null || true)"
  if [[ -n "$ver" && -f "$(_kiln_versions_dir)/$ver/root/kiln.pid" ]]; then
    echo "$(_kiln_versions_dir)/$ver/root/kiln.pid"; return 0
  fi
  find "$vm_root" -maxdepth 5 -type f -name 'kiln.pid' 2>/dev/null | head -n1
}

_find_firecracker_pid_file() {
  local vm_root="$1" name; name="$(basename "$vm_root")"
  local ver; ver="$(_version_for_vm "$name" 2>/dev/null || true)"
  if [[ -n "$ver" && -f "$(_kiln_versions_dir)/$ver/root/firecracker.pid" ]]; then
    echo "$(_kiln_versions_dir)/$ver/root/firecracker.pid"; return 0
  fi
  find "$vm_root" -maxdepth 5 -type f -name 'firecracker.pid' 2>/dev/null | head -n1
}

# Replace your _find_control_sock with this
_find_control_sock() {
  # _find_control_sock <vm_root> [api_port]
  local vm_root="$1" port="${2:-}"

  # 0) If stop/start already resolved CHROOT_DIR, prefer it.
  if [[ -n "${CHROOT_DIR:-}" && -d "$CHROOT_DIR" ]]; then
    if [[ -S "$CHROOT_DIR/control.sock" ]]; then
      debug "control.sock found at $CHROOT_DIR/control.sock (via CHROOT_DIR)"
      echo "$CHROOT_DIR/control.sock|mux"; return 0
    fi
    if [[ -n "$port" && -S "$CHROOT_DIR/control.sock_${port}" ]]; then
      debug "control.sock_${port} found at $CHROOT_DIR (via CHROOT_DIR)"
      echo "$CHROOT_DIR/control.sock_${port}|direct"; return 0
    fi
  fi

  # 1) Try deterministic versioned path
  local name; name="$(basename "$vm_root")"
  local ver;  ver="$(_version_for_vm "$name" 2>/dev/null || true)"
  if [[ -n "$ver" ]]; then
    local root
    root="$(_kiln_versions_dir)/$ver/root"
    if [[ -S "$root/control.sock" ]]; then
      debug "control.sock found at $root/control.sock (via versioned path)"
      echo "$root/control.sock|mux"; return 0
    fi
    if [[ -n "$port" && -S "$root/control.sock_${port}" ]]; then
      debug "control.sock_${port} found at $root (via versioned path)"
      echo "$root/control.sock_${port}|direct"; return 0
    fi
  fi

  # 2) Legacy fallback (pre-versioned tree under VM dir)
  local legacy_root; legacy_root="$(find "$vm_root" -maxdepth 5 -type d -name root 2>/dev/null | head -n1)" || true
  if [[ -n "$legacy_root" && -d "$legacy_root" ]]; then
    if [[ -S "$legacy_root/control.sock" ]]; then
      debug "control.sock found at $legacy_root/control.sock (legacy)"
      echo "$legacy_root/control.sock|mux"; return 0
    fi
    if [[ -n "$port" && -S "$legacy_root/control.sock_${port}" ]]; then
      debug "control.sock_${port} found at $legacy_root (legacy)"
      echo "$legacy_root/control.sock_${port}|direct"; return 0
    fi
  fi

  debug "control.sock not found (vm_root=$vm_root, port=${port:-<none>})"
  return 1
}

# Return "<path>|mux" or nothing (non-zero exit).
_control_sock_path() {
  # Usage: _control_sock_path <api_port> <vm_root>
  local vm_root="$2"

  # Prefer the resolved chroot
  if [[ -n "${CHROOT_DIR:-}" && -S "$CHROOT_DIR/control.sock" ]]; then
    echo "$CHROOT_DIR/control.sock|mux"; return 0
  fi

  # Deterministic versioned path
  local name ver root
  name="$(basename "$vm_root")"
  ver="$(_version_for_vm "$name" 2>/dev/null || true)"
  if [[ -n "$ver" ]]; then
    root="$(_kiln_versions_dir)/$ver/root"
    if [[ -S "$root/control.sock" ]]; then
      echo "$root/control.sock|mux"; return 0
    fi
  fi

  # Legacy fallback (pre-versioned tree)
  local legacy_root
  legacy_root="$(find "$vm_root" -maxdepth 5 -type d -name root 2>/dev/null | head -n1)" || true
  if [[ -n "$legacy_root" && -S "$legacy_root/control.sock" ]]; then
    echo "$legacy_root/control.sock|mux"; return 0
  fi

  return 1
}

# HTTP over UNIX domain socket (no CONNECT prelude)
_unix_http() {
  local sock="$1" method="$2" path="$3" body="${4:-}" req
  if [[ -n "$body" ]]; then
    local len; len=$(printf %s "$body" | wc -c)
    req="${method} ${path} HTTP/1.1\r\nHost: vsock\r\nContent-Type: application/json\r\nContent-Length: ${len}\r\nConnection: close\r\n\r\n${body}"
  else
    req="${method} ${path} HTTP/1.1\r\nHost: vsock\r\nConnection: close\r\n\r\n"
  fi

  if [[ "$EUID" -ne 0 && -n "${JAIL_UID:-}" ]] && getent passwd "$JAIL_UID" >/dev/null; then
    local user; user="$(getent passwd "$JAIL_UID" | cut -d: -f1)"
    printf "%b" "$req" | sudo -n -u "$user" socat - "UNIX-CONNECT:${sock}"
  else
    printf "%b" "$req" | socat - "UNIX-CONNECT:${sock}"
  fi
}

# Firecracker muxed vsock: "CONNECT <port>\n" then wait for OK, then HTTP over same stream
_vsock_http_mux() {
  local sock="$1" port="$2" method="$3" path="$4" body="${5:-}"

  # Build HTTP request (without CONNECT line)
  local http_req
  if [[ -n "$body" ]]; then
    local len; len=$(printf %s "$body" | wc -c)
    http_req="$(printf "%s %s HTTP/1.1\r\nHost: vsock\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
      "$method" "$path" "$len" "$body")"
  else
    http_req="$(printf "%s %s HTTP/1.1\r\nHost: vsock\r\nConnection: close\r\n\r\n" \
      "$method" "$path")"
  fi

  # Use a bi-directional communication with socat
  # Protocol: Send "CONNECT port\n", read "OK ...", then send HTTP request, read HTTP response
  local result; local exit_code
  result=$(
    {
      # Send CONNECT line
      printf "CONNECT %d\n" "$port"
      # Wait a moment for the OK response (firecracker should respond immediately)
      sleep 0.1
      # Send HTTP request
      printf "%s" "$http_req"
      # Wait for the guest to process and respond (critical!)
      sleep 0.5
    } | timeout 5 socat - "UNIX-CONNECT:${sock}" 2>&1
  )
  exit_code=$?

  # If we got a connection error, log it at debug level
  if [[ $exit_code -ne 0 ]]; then
    debug "socat connection failed: exit_code=$exit_code, output=${result}"
    return $exit_code
  fi

  # The result should start with "OK ..." line, then HTTP response
  # Strip the OK line and return only the HTTP response
  local http_response
  http_response=$(printf "%s" "$result" | tail -n +2)

  printf "%s" "$http_response"
}

_http_status() {
  awk 'tolower($1) ~ /^http\/1\.[01]/ { print $2; exit }' <<<"$1"
}

# Parse guest CID from firecracker.json if available; default 3
_guest_cid() {
  # _guest_cid <vm_root>
  local vm_root="$1"
  local fc=""

  # Prefer resolved CHROOT_DIR
  if [[ -n "${CHROOT_DIR:-}" && -f "$CHROOT_DIR/firecracker.json" ]]; then
    fc="$CHROOT_DIR/firecracker.json"
  else
    # Try deterministic versioned path
    local name; name="$(basename "$vm_root")"
    local ver;  ver="$(_version_for_vm "$name" 2>/dev/null || true)"
    if [[ -n "$ver" && -f "$(_kiln_versions_dir)/$ver/root/firecracker.json" ]]; then
      fc="$(_kiln_versions_dir)/$ver/root/firecracker.json"
    fi
  fi

  local cid=""
  if [[ -n "$fc" && -f "$fc" ]]; then
    cid="$(jq -r '.vsock.guest_cid // .guest_cid // .net.vsock.guest_cid // empty' "$fc" 2>/dev/null || true)"
  fi
  [[ -n "$cid" && "$cid" =~ ^[0-9]+$ ]] || cid="3"
  echo "$cid"
}

send_vm_signal() {
    local name="$1" sig="${2:-TERM}" api_port="${3:-10002}"
    local vm_root; vm_root="$(get_vm_dir "$name")"

    local sig_num; sig_num="$(_sig_num "$sig")"
    local body; body=$(jq -cn --argjson n "$sig_num" '{signal:$n}')

    local sock_line; sock_line="$(_control_sock_path "$api_port" "$vm_root")" || {
        warn "control.sock not found for ${name}."
        return 1
    }
    local sock="${sock_line%%|*}"

    # Ensure socket exists and is accessible
    if [[ ! -S "$sock" ]]; then
        warn "Control socket does not exist: $sock"
        return 1
    fi

    # Wait a moment for the socket to be ready
    local attempts=0
    while (( attempts < 5 )); do
        if timeout 1 bash -c "true < '$sock'" 2>/dev/null; then
            break
        fi
        sleep 0.2
        attempts=$((attempts + 1))
    done

    debug "Attempting to send signal $sig (num=$sig_num) to $name via $sock (port=$api_port)"
    debug "Request body: $body"

    # Try the vsock mux connection
    local resp exit_code
    resp="$(_vsock_http_mux "$sock" "$api_port" "POST" "/v1/signal" "$body")"
    exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        debug "Failed to connect to guest API socket: $sock (exit_code=$exit_code)"
        return 1
    fi

    debug "Raw response: ${resp:0:200}"  # Show first 200 chars of response

    local status; status="$(_http_status "$resp")"
    if [[ "$status" =~ ^(200|204)$ ]]; then
        info "Guest API signal delivered (HTTP $status)"
        return 0
    elif [[ -z "$status" ]]; then
        debug "No HTTP status line found in response"
        warn "Guest API returned empty or malformed response"
    else
        debug "Guest API response: ${resp:0:200}"
        warn "Guest API returned HTTP $status"
    fi

    return 1
}


_detect_tap_for_guest() {
  local ip="$1"
  ip route get "$ip" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

_list_vm_resources() {
  local name="$1"
  local vm_root; vm_root="$(get_vm_dir "$name")"
  local ver; ver="$(_resolve_vm_version "$name")"
  local base; base="$(_kiln_versions_dir)/${ver}"
  local run_json="${base}/initramfs/inferno/run.json"

  local guest_ip; guest_ip="$(jq -r '.ips[0].ip // empty' "$run_json" 2>/dev/null)"
  local tap=""; [[ -n "$guest_ip" ]] && tap="$(_detect_tap_for_guest "$guest_ip")"

  local sock_line; sock_line="$(_control_sock_path 10002 "$vm_root" 2>/dev/null)" || true
  local sock=""; [[ -n "$sock_line" ]] && sock="${sock_line%%|*}"
  local chroot_dir="${base}/root"

  local jailer_pid_file="${vm_root}/jailer.pid"
  local kiln_pid_file; kiln_pid_file="$(_find_kiln_pid_file "$vm_root")"

  echo "VM name:          $name"
  echo "VM directory:     $vm_root"
  echo "Version:          ${ver:-<unknown>}"
  echo "Chroot (root):    ${chroot_dir:-<unknown>}"
  echo "Guest IP:         ${guest_ip:-<unknown>}"
  echo "TAP device:       ${tap:-<unknown>}"
  if [[ -n "$guest_ip" ]]; then
    echo -n "Route probe:      "
    ip route get "$guest_ip" 2>/dev/null | tr -s ' ' || echo "<none>"
  else
    echo "Route probe:      <unknown>"
  fi
  echo "PIDs (best-effort):"
  [[ -f "$jailer_pid_file" ]] && echo "  jailer:          $(cat "$jailer_pid_file")" || echo "  jailer:          <none>"
  [[ -n "$kiln_pid_file" && -f "$kiln_pid_file" ]] && echo "  kiln:            $(cat "$kiln_pid_file")" || echo "  kiln:            <none>"
}

# Ensure kiln.json has the exact UID/GID we expect; fix it if not.
_verify_kiln_ids() {
  local chroot_dir="$1" expect_uid="$2" expect_gid="$3"
  local got_uid got_gid
  got_uid="$(jq -r '.uid // empty' "$chroot_dir/kiln.json" 2>/dev/null || true)"
  got_gid="$(jq -r '.gid // empty' "$chroot_dir/kiln.json" 2>/dev/null || true)"

  if [[ "$got_uid" != "$expect_uid" || "$got_gid" != "$expect_gid" ]]; then
    warn "kiln.json uid/gid mismatch (got ${got_uid:-<unset>}:${got_gid:-<unset>} expected ${expect_uid}:${expect_gid}); fixing."
    jq --argjson uid "$expect_uid" --argjson gid "$expect_gid" \
       '.uid=$uid | .gid=$gid' \
       "$chroot_dir/kiln.json" >"$chroot_dir/.kiln.json.tmp" \
      && mv -f "$chroot_dir/.kiln.json.tmp" "$chroot_dir/kiln.json"
  fi
}

_prepare_firecracker_caps() {
  local fc="$CHROOT_DIR/firecracker"
  if [[ -x "$fc" ]]; then
    if command -v setcap >/dev/null 2>&1; then
      # idempotent; re-run is fine
      setcap cap_net_admin+ep "$fc" 2>/dev/null || warn "setcap failed on $fc"
    else
      warn "setcap not found; install libcap tools or create TAP with user ${JAIL_UID} group ${JAIL_GID}."
    fi
  fi
}

ensure_global_vm_logs_socket() {
    local global_socket="${INFERNO_ROOT}/logs/vm_logs.sock"
    local global_log_file="${INFERNO_ROOT}/logs/vm_combined.log"
    local pid_file="${INFERNO_ROOT}/logs/vm_logs.pid"
    
    # Check if already running
    if [[ -S "$global_socket" ]] && echo "test" | timeout 1 socat - "UNIX-CONNECT:${global_socket}" &>/dev/null 2>&1; then
        debug "Global VM logs socket already running"
        return 0
    fi
    
    # Clean up stale files
    rm -f "$global_socket" "$pid_file" 2>/dev/null || true
    
    # Ensure logs directory exists
    mkdir -p "${INFERNO_ROOT}/logs"
    
    # Start global listener (one for all VMs)
    (
        exec socat -u \
            "UNIX-LISTEN:${global_socket},fork,mode=666" \
            "SYSTEM:while IFS= read -r line; do echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] \$line\" >> '$global_log_file'; done" \
            &
        echo $! > "$pid_file"
        wait
    ) &
    
    # Wait for socket creation - FIXED the (( attempts++ )) issue
    local attempts=0
    while [[ ! -S "$global_socket" ]] && (( attempts < 20 )); do
        sleep 0.1
        attempts=$((attempts + 1))  # Use explicit assignment instead of post-increment
    done
    
    if [[ -S "$global_socket" ]]; then
        chmod 666 "$global_socket" 2>/dev/null || true
        info "Global VM logs socket started at $global_socket"
        return 0
    else
        error "Failed to start global VM logs socket"
        return 1
    fi
}

# Link the global socket into a jail
link_vm_logs_socket() {
    local jail_root="$1"
    local vm_name="$2"
    
    local global_socket="${INFERNO_ROOT}/logs/vm_logs.sock"
    local jail_socket="${jail_root}/vm_logs.sock"
    
    # Ensure global socket exists
    ensure_global_vm_logs_socket || return 1
    
    # Remove any existing jail socket
    rm -f "$jail_socket" 2>/dev/null || true
    
    # Create symlink (since you can't hard link sockets)
    if ln -sf "$global_socket" "$jail_socket"; then
        # Make sure jail can access it
        chown -h "${INFERNO_JAIL_UID:-123}:${INFERNO_JAIL_GID:-100}" "$jail_socket" 2>/dev/null || true
        debug "Linked global socket to jail: $jail_socket -> $global_socket"
        return 0
    else
        error "Failed to link VM logs socket for $vm_name"
        return 1
    fi
}

# Clean up jail socket link
unlink_vm_logs_socket() {
    local jail_root="$1"
    rm -f "${jail_root}/vm_logs.sock" 2>/dev/null || true
}

# Stop global socket (only when shutting down everything)
stop_global_vm_logs_socket() {
    local global_socket="${INFERNO_ROOT}/logs/vm_logs.sock"
    local pid_file="${INFERNO_ROOT}/logs/vm_logs.pid"
    
    if [[ -f "$pid_file" ]]; then
        local pid; pid="$(cat "$pid_file" 2>/dev/null)" || true
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 0.5
            kill -KILL "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi
    rm -f "$global_socket" 2>/dev/null || true
}

debug_control_socket() {
    local name="$1"
    local vm_root; vm_root="$(get_vm_dir "$name")"
    
    _resolve_vm_ctx "$name" || return 1
    
    local sock_line; sock_line="$(_control_sock_path 10002 "$vm_root")" || {
        echo "[ERROR] control.sock not found"
        return 1
    }
    local sock="${sock_line%%|*}"
    
    echo "Control Socket Debug for VM: $name"
    echo "VM Root: $vm_root"
    echo "Chroot: $CHROOT_DIR"
    echo "Socket: $sock"
    
    if [[ -S "$sock" ]]; then
        echo "Socket exists: YES"
        echo "Permissions: $(stat -c '%A %a %U:%G' "$sock" 2>/dev/null)"
        echo "Current user: $(id)"
        
        # Test socket connection
        echo "Testing socket connection..."
        if echo "test" | timeout 2 socat - "UNIX-CONNECT:${sock}" 2>/dev/null; then
            echo "Basic socket connection: SUCCESS"
        else
            echo "Basic socket connection: FAILED"
            echo "Socket details:"
            ls -la "$sock"
            echo "Parent directory:"
            ls -la "$(dirname "$sock")"
        fi
        
        # Test vsock mux connection
        echo "Testing vsock mux connection..."
        if timeout 2 bash -c "printf 'CONNECT 10002\nGET /v1/ping HTTP/1.1\nHost: vsock\n\n' | socat - 'UNIX-CONNECT:${sock}'" 2>/dev/null | grep -q "HTTP"; then
            echo "Vsock mux connection: SUCCESS"
        else
            echo "Vsock mux connection: FAILED"
        fi
        
        # Check if processes are running
        echo "Related processes:"
        local kiln_pid_file; kiln_pid_file="$(_find_kiln_pid_file "$vm_root")"
        if [[ -f "$kiln_pid_file" ]]; then
            local pid; pid="$(cat "$kiln_pid_file")"
            if kill -0 "$pid" 2>/dev/null; then
                echo "kiln process: RUNNING (PID: $pid)"
                echo "Command: $(ps -p "$pid" -o cmd= 2>/dev/null || echo 'unknown')"
            else
                echo "kiln process: NOT RUNNING (stale PID: $pid)"
            fi
        else
            echo "kiln PID file: NOT FOUND"
        fi
        
    else
        echo "Socket exists: NO"
        echo "Expected location: $sock"
        echo "Directory contents:"
        ls -la "$(dirname "$sock")" 2>/dev/null || echo "Directory doesn't exist"
    fi
}

_purge_version_runtime() {
  local root="$1"
  # remove sockets/pids the guest creates (but NOT the shared vm_logs.sock mount)
  rm -f "$root"/{kiln.pid,firecracker.pid,firecracker.sock,control.sock} 2>/dev/null || true
  rm -f "$root"/control.sock_* 2>/dev/null || true
  rm -f "$root"/exit_status.json 2>/dev/null || true
  rm -rf "${root:?}/dev" "${root:?}/run" 2>/dev/null || true
}

# Verify if VM is actually running by checking PID
# Returns 0 if running, 1 if not
_verify_vm_running() {
  local vm_name="$1"
  local vm_root; vm_root="$(get_vm_dir "$vm_name" 2>/dev/null)" || return 1

  local kiln_pid_file; kiln_pid_file="$(_find_kiln_pid_file "$vm_root" 2>/dev/null)" || return 1
  [[ -n "$kiln_pid_file" && -f "$kiln_pid_file" ]] || return 1

  local pid; pid="$(_read_pid "$kiln_pid_file" 2>/dev/null)" || return 1
  [[ -n "$pid" ]] || return 1

  kill -0 "$pid" 2>/dev/null
}

usage() {
  cat <<'USAGE'
infernoctl â€" manage Inferno VMs

Usage:
  infernoctl version
  infernoctl env print
  infernoctl init [--owner <user>]

  infernoctl list [--format table|json] [--state created|running|stopped]
  infernoctl ls   [--format table|json] [--state created|running|stopped]
  infernoctl status <name> [--format human|json]
  infernoctl reconcile

  infernoctl create  <name> --image <ref> [--vcpus N] [--memory MB] [--volume VOL_ID]
  infernoctl start   <name> [--detach]
  infernoctl stop    <name> [--signal SIGTERM] [--timeout SECONDS] [--kill]
  infernoctl destroy <name> [--yes] [--keep-logs]

  infernoctl logs {start|stop|restart|status|tail|clear}

  infernoctl haproxy render
  infernoctl haproxy reload
  infernoctl images process <image> [entrypoint_json|string] [cmd_json|string]
  infernoctl images exposed <image>

Examples:
  # List all VMs
  infernoctl list
  infernoctl ls --state running

  # Fix state mismatches (e.g., after Ctrl+C on foreground VM)
  infernoctl reconcile

  # Get detailed status
  infernoctl status web1
  infernoctl status web1 --format json

  # Create and manage VMs
  infernoctl create web1 --image nginx:latest
  infernoctl start web1 --detach
  infernoctl stop web1

Env:
  LOG_LEVEL              DEBUG/INFO/WARN/ERROR (default: INFO)
  INFERNO_ROOT           Inferno data root (from env.sh / /etc/inferno/env)
USAGE
}

# --- Commands ----------------------------------------------------------------
cmd_version() {
  echo "INFERNOCTL_SH_VERSION=${INFERNOCTL_SH_VERSION}"
  inferno_versions 2>/dev/null || true
}

cmd_env_print() {
  echo "INFERNO_ROOT=${INFERNO_ROOT}"
  echo "DB_PATH=${DB_PATH}"
  echo "HAPROXY_CFG=${HAPROXY_CFG}"
  echo "LOG_LEVEL=${LOG_LEVEL:-INFO}"
}

cmd_init() {
  local owner="${1:-${SUDO_USER:-$USER}}"
  info "Initializing Inferno data dir at ${INFERNO_ROOT} (owner=${owner})"
  mkdir -p "${INFERNO_ROOT}"/{images,vms,volumes,logs,tmp}
  chgrp -R inferno "${INFERNO_ROOT}" 2>/dev/null || true
  chmod -R g+rwXs "${INFERNO_ROOT}" 2>/dev/null || true

  if type -t db_init >/dev/null 2>&1; then
    db_init "$owner"
  else
    warn "database.sh not loaded; skipping DB schema init."
  fi
    
  # Start the global VM logs socket
  ensure_global_vm_logs_socket

  success "Init complete."
}

cmd_logs() {
  local action="${1:-tail}"
  local global_log_file="${INFERNO_ROOT}/logs/vm_combined.log"
    
  case "$action" in
    start)
      ensure_global_vm_logs_socket
      ;;
    stop)
      stop_global_vm_logs_socket
      info "Global VM logs socket stopped"
      ;;
    restart)
      stop_global_vm_logs_socket
      sleep 1
      ensure_global_vm_logs_socket
      ;;
    tail)
      if [[ -f "$global_log_file" ]]; then
        tail -f "$global_log_file"
      else
        warn "No VM logs found at $global_log_file"
        return 1
      fi
      ;;
    clear)
      true > "$global_log_file"
      info "Cleared VM logs"
      ;;
    status)
      local global_socket="${INFERNO_ROOT}/logs/vm_logs.sock"
      if [[ -S "$global_socket" ]] && echo "test" | timeout 1 socat - "UNIX-CONNECT:${global_socket}" &>/dev/null; then
        info "Global VM logs socket is running"
        local pid_file="${INFERNO_ROOT}/logs/vm_logs.pid"
        if [[ -f "$pid_file" ]]; then
          info "PID: $(cat "$pid_file")"
        fi
      else
        warn "Global VM logs socket is not running"
        return 1
      fi
      ;;
    *)
      echo "Usage: infernoctl logs {start|stop|restart|status|tail|clear}"
      return 1
      ;;
  esac
}

cmd_reconcile() {
  require_root
  require_cmd sqlite3

  info "Checking VM states for mismatches..."

  local fixed=0
  local checked=0

  # Get all VMs marked as running
  local vms_data
  vms_data="$(sqlite3 "$DB_PATH" "SELECT name FROM vms WHERE state = 'running';" 2>/dev/null)" || {
    warn "Failed to query database"
    return 1
  }

  while IFS= read -r vm_name; do
    [[ -z "$vm_name" ]] && continue
    ((checked++))

    # Check if VM is actually running
    if ! _verify_vm_running "$vm_name"; then
      warn "VM '$vm_name' marked as running but process not found - fixing"

      # Update state to stopped
      if type -t set_vm_state >/dev/null 2>&1; then
        set_vm_state "$vm_name" "stopped" || warn "Failed to update state for $vm_name"
      fi

      ((fixed++))
    fi
  done <<< "$vms_data"

  if [[ $fixed -gt 0 ]]; then
    success "Fixed $fixed state mismatch(es) out of $checked VMs checked"
  elif [[ $checked -gt 0 ]]; then
    info "All $checked running VMs are in sync"
  else
    info "No running VMs found"
  fi
}

cmd_list() {
  require_root
  require_cmd jq sqlite3

  local format="table"
  local state_filter=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format)  format="$2"; shift 2;;
      --state)   state_filter="$2"; shift 2;;
      -*)        die 2 "Unknown option: $1";;
      *)         die 2 "Unexpected argument: $1";;
    esac
  done

  # Validate format
  case "$format" in
    table|json) ;;
    *) die 2 "Invalid format: $format. Use 'table' or 'json'";;
  esac

  # Validate state filter
  if [[ -n "$state_filter" ]]; then
    case "$state_filter" in
      created|running|stopped) ;;
      *) die 2 "Invalid state: $state_filter. Use 'created', 'running', or 'stopped'";;
    esac
  fi

  # Get VM list from database
  local vms_json
  vms_json="$(list_vms_detailed "$state_filter")" || die 1 "Failed to list VMs"

  # Check if empty
  local count; count="$(echo "$vms_json" | jq -r 'length')"
  if [[ "$count" -eq 0 ]]; then
    if [[ "$format" == "json" ]]; then
      echo "[]"
    else
      info "No VMs found"
    fi
    return 0
  fi

  # Verify state for running VMs
  local verified_json="[]"
  while read -r vm; do
    local name; name="$(echo "$vm" | jq -r '.name')"
    local state; state="$(echo "$vm" | jq -r '.state')"
    local state_verified="true"

    # Verify if VM is actually running
    if [[ "$state" == "running" ]]; then
      if ! _verify_vm_running "$name"; then
        state_verified="false"
      fi
    fi

    # Add state_verified field
    local updated_vm; updated_vm="$(echo "$vm" | jq --arg verified "$state_verified" '. + {state_verified: ($verified == "true")}')"
    verified_json="$(echo "$verified_json" | jq --argjson vm "$updated_vm" '. += [$vm]')"
  done < <(echo "$vms_json" | jq -c '.[]')

  # Output based on format
  if [[ "$format" == "json" ]]; then
    echo "$verified_json" | jq .
  else
    # Table format
    printf "%-20s %-10s %-16s %-30s %-7s %s\n" "NAME" "STATE" "GUEST IP" "IMAGE" "ROUTES" "CREATED"
    printf "%s\n" "$(printf '─%.0s' {1..100})"

    while read -r vm; do
      local name; name="$(echo "$vm" | jq -r '.name')"
      local state; state="$(echo "$vm" | jq -r '.state')"
      local verified; verified="$(echo "$vm" | jq -r '.state_verified')"
      local guest_ip; guest_ip="$(echo "$vm" | jq -r '.guest_ip')"
      local image; image="$(echo "$vm" | jq -r '.image')"
      local routes; routes="$(echo "$vm" | jq -r '.active_routes')"
      local created; created="$(echo "$vm" | jq -r '.created_at')"

      # Truncate long image names
      if [[ ${#image} -gt 28 ]]; then
        image="${image:0:25}..."
      fi

      # Add asterisk for state mismatch
      if [[ "$state" == "running" && "$verified" == "false" ]]; then
        state="${state}*"
      fi

      printf "%-20s %-10s %-16s %-30s %-7s %s\n" \
        "$name" "$state" "$guest_ip" "$image" "$routes" "$created"
    done < <(echo "$verified_json" | jq -c '.[]')

    # Show legend if there are state mismatches
    if echo "$verified_json" | jq -e '.[] | select(.state == "running" and .state_verified == false)' >/dev/null 2>&1; then
      printf "\n"
      warn "* State mismatch: Database shows 'running' but process not found"
      info "  Run 'infernoctl reconcile' to fix state mismatches"
    fi
  fi
}

cmd_status() {
  require_root
  require_cmd jq sqlite3

  local name=""
  local format="human"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format)  format="$2"; shift 2;;
      -*)        die 2 "Unknown option: $1";;
      *)         name="$1"; shift;;
    esac
  done

  [[ -n "$name" ]] || die 2 "Usage: infernoctl status <name> [--format human|json]"

  # Validate format
  case "$format" in
    human|json) ;;
    *) die 2 "Invalid format: $format. Use 'human' or 'json'";;
  esac

  # Check if VM exists
  vm_exists "$name" || die 1 "VM not found: $name"

  # Get VM details from database
  local vm_json
  vm_json="$(get_vm_detailed "$name")" || die 1 "Failed to get VM details"

  # Extract basic info
  local state; state="$(echo "$vm_json" | jq -r '.state')"
  local version; version="$(echo "$vm_json" | jq -r '.version')"
  local guest_ip; guest_ip="$(echo "$vm_json" | jq -r '.guest_ip')"

  # Resolve VM context
  _resolve_vm_ctx "$name"

  # Get resource information from kiln.json
  local kiln_json="${VM_ROOT}/kiln/${version}/root/kiln.json"
  local vcpus="<unknown>"
  local memory="<unknown>"
  if [[ -f "$kiln_json" ]]; then
    vcpus="$(jq -r '.resources.cpu_count // "<unknown>"' "$kiln_json" 2>/dev/null)" || vcpus="<unknown>"
    memory="$(jq -r '.resources.memory_mb // "<unknown>"' "$kiln_json" 2>/dev/null)" || memory="<unknown>"
  fi

  # Get cgroup information if VM is running
  local cgroup_cpu_limit="<not available>"
  local cgroup_memory_limit="<not available>"
  local cgroup_memory_usage="<not available>"

  if [[ "$state" == "running" && -n "$version" ]]; then
    local cgroup_path="/sys/fs/cgroup/firecracker/${version}"

    if [[ -d "$cgroup_path" ]]; then
      # Read CPU limit (format: "quota period")
      if [[ -f "${cgroup_path}/cpu.max" ]]; then
        local cpu_max; cpu_max="$(cat "${cgroup_path}/cpu.max" 2>/dev/null)" || cpu_max=""
        if [[ -n "$cpu_max" && "$cpu_max" != "max 100000" ]]; then
          local quota; quota="$(echo "$cpu_max" | awk '{print $1}')"
          local period; period="$(echo "$cpu_max" | awk '{print $2}')"
          if [[ -n "$quota" && -n "$period" && "$quota" != "max" ]]; then
            # Convert to vCPUs (quota / period)
            local vcpu_float; vcpu_float="$(awk "BEGIN {printf \"%.2f\", $quota / $period}")"
            cgroup_cpu_limit="${vcpu_float} vCPU"
          fi
        fi
      fi

      # Read memory limit (bytes)
      if [[ -f "${cgroup_path}/memory.max" ]]; then
        local mem_max; mem_max="$(cat "${cgroup_path}/memory.max" 2>/dev/null)" || mem_max=""
        if [[ -n "$mem_max" && "$mem_max" != "max" ]]; then
          # Convert bytes to MB
          local mem_mb; mem_mb="$((mem_max / 1024 / 1024))"
          cgroup_memory_limit="${mem_mb} MB"
        fi
      fi

      # Read current memory usage (bytes)
      if [[ -f "${cgroup_path}/memory.current" ]]; then
        local mem_current; mem_current="$(cat "${cgroup_path}/memory.current" 2>/dev/null)" || mem_current=""
        if [[ -n "$mem_current" ]]; then
          # Convert bytes to MB
          local mem_usage_mb; mem_usage_mb="$((mem_current / 1024 / 1024))"
          cgroup_memory_usage="${mem_usage_mb} MB"
        fi
      fi
    fi
  fi

  # Get runtime information
  local kiln_pid=""
  local kiln_running="false"
  local fc_pid=""
  local fc_running="false"
  local state_verified="true"

  if [[ "$state" == "running" ]]; then
    # Check kiln PID
    local kiln_pid_file; kiln_pid_file="$(_find_kiln_pid_file "$VM_ROOT" 2>/dev/null)"
    if [[ -n "$kiln_pid_file" && -f "$kiln_pid_file" ]]; then
      kiln_pid="$(_read_pid "$kiln_pid_file" 2>/dev/null)" || kiln_pid=""
      if [[ -n "$kiln_pid" ]] && kill -0 "$kiln_pid" 2>/dev/null; then
        kiln_running="true"
      else
        state_verified="false"
      fi
    else
      state_verified="false"
    fi

    # Check firecracker PID
    local fc_pid_file; fc_pid_file="$(_find_firecracker_pid_file "$VM_ROOT" 2>/dev/null)"
    if [[ -n "$fc_pid_file" && -f "$fc_pid_file" ]]; then
      fc_pid="$(_read_pid "$fc_pid_file" 2>/dev/null)" || fc_pid=""
      if [[ -n "$fc_pid" ]] && kill -0 "$fc_pid" 2>/dev/null; then
        fc_running="true"
      fi
    fi

    # Fallback: Find firecracker as child of kiln
    if [[ -z "$fc_pid" && -n "$kiln_pid" && "$kiln_running" == "true" ]]; then
      # Try pgrep first (finds children of kiln)
      if command -v pgrep >/dev/null 2>&1; then
        fc_pid="$(pgrep -P "$kiln_pid" 2>/dev/null | head -n1)" || fc_pid=""
      fi

      # Fallback to ps if pgrep not available
      if [[ -z "$fc_pid" ]] && command -v ps >/dev/null 2>&1; then
        fc_pid="$(ps --ppid "$kiln_pid" -o pid= 2>/dev/null | tr -d ' ' | head -n1)" || fc_pid=""
      fi

      # Verify it's actually firecracker
      if [[ -n "$fc_pid" ]]; then
        local proc_name; proc_name="$(ps -p "$fc_pid" -o comm= 2>/dev/null || true)"
        if [[ "$proc_name" == "firecracker" ]]; then
          fc_running="true"
        else
          # Not firecracker, clear it
          fc_pid=""
        fi
      fi
    fi
  fi

  # Check control socket
  local sock_status="not found"
  local sock_line; sock_line="$(_control_sock_path 10002 "$VM_ROOT" 2>/dev/null)" || true
  if [[ -n "$sock_line" ]]; then
    local sock="${sock_line%%|*}"
    if [[ -S "$sock" ]]; then
      sock_status="exists"
      # Try to test if accessible (non-blocking)
      if timeout 0.1 bash -c "true 2>/dev/null <> '$sock'" 2>/dev/null; then
        sock_status="accessible"
      fi
    fi
  fi

  # Get routes
  local routes_json
  routes_json="$(sqlite3 -json "$DB_PATH" "SELECT mode, host_port, guest_port, hostname FROM routes WHERE vm_id = (SELECT id FROM vms WHERE name = '$name') AND active = TRUE;" 2>/dev/null)" || routes_json="[]"
  [[ -z "$routes_json" ]] && routes_json="[]"

  # Get volumes
  local volumes_json
  volumes_json="$(sqlite3 -json "$DB_PATH" "SELECT volume_id, name, size_gb FROM volumes WHERE vm_id = (SELECT id FROM vms WHERE name = '$name');" 2>/dev/null)" || volumes_json="[]"
  [[ -z "$volumes_json" ]] && volumes_json="[]"

  # Output based on format
  if [[ "$format" == "json" ]]; then
    # Build complete JSON output
    jq -n \
      --argjson vm "$vm_json" \
      --arg vcpus "$vcpus" \
      --arg memory "$memory" \
      --arg cgroup_cpu_limit "$cgroup_cpu_limit" \
      --arg cgroup_memory_limit "$cgroup_memory_limit" \
      --arg cgroup_memory_usage "$cgroup_memory_usage" \
      --arg kiln_pid "$kiln_pid" \
      --argjson kiln_running "$kiln_running" \
      --arg fc_pid "$fc_pid" \
      --argjson fc_running "$fc_running" \
      --arg sock_status "$sock_status" \
      --argjson state_verified "$state_verified" \
      --argjson routes "$routes_json" \
      --argjson volumes "$volumes_json" \
      '{
        name: $vm.name,
        state: $vm.state,
        state_verified: $state_verified,
        version: $vm.version,
        image: $vm.image,
        image_id: $vm.image_id,
        created_at: $vm.created_at,
        network: {
          guest_ip: $vm.guest_ip,
          gateway_ip: $vm.gateway_ip,
          tap_device: $vm.tap_device,
          mac_address: $vm.mac_address
        },
        resources: {
          vcpus: $vcpus,
          memory_mb: $memory,
          cgroup_cpu_limit: $cgroup_cpu_limit,
          cgroup_memory_limit: $cgroup_memory_limit,
          cgroup_memory_usage: $cgroup_memory_usage
        },
        runtime: {
          kiln_pid: $kiln_pid,
          kiln_running: $kiln_running,
          firecracker_pid: $fc_pid,
          firecracker_running: $fc_running,
          control_socket: $sock_status
        },
        routes: $routes,
        volumes: $volumes
      }'
  else
    # Human-readable format
    local state_display="$state"
    if [[ "$state" == "running" && "$state_verified" == "false" ]]; then
      state_display="$state (WARNING: Process not found)"
    elif [[ "$state" == "running" && "$state_verified" == "true" ]]; then
      state_display="$state (verified)"
    fi

    cat <<EOF

VM Status: $name
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Basic Information:
  Name:          $name
  State:         $state_display
  Version:       $version
  Image:         $(echo "$vm_json" | jq -r '.image')
  Created:       $(echo "$vm_json" | jq -r '.created_at')

Network:
  Guest IP:      $(echo "$vm_json" | jq -r '.guest_ip')
  Gateway IP:    $(echo "$vm_json" | jq -r '.gateway_ip')
  TAP Device:    $(echo "$vm_json" | jq -r '.tap_device')
  MAC Address:   $(echo "$vm_json" | jq -r '.mac_address')

Resources:
  vCPUs:         $vcpus
  Memory:        $memory MB
  CPU Limit:     $cgroup_cpu_limit
  Memory Limit:  $cgroup_memory_limit
  Memory Usage:  $cgroup_memory_usage

Runtime:
  kiln PID:      ${kiln_pid:-<not running>} $([ "$kiln_running" == "true" ] && echo "(running)" || echo "")
  Firecracker:   ${fc_pid:-<not running>} $([ "$fc_running" == "true" ] && echo "(running)" || echo "")
  Control Socket: $sock_status

EOF

    # Show routes
    local route_count; route_count="$(echo "$routes_json" | jq 'length')"
    if [[ "$route_count" -gt 0 ]]; then
      echo "Routes ($route_count active):"
      while read -r route; do
        local mode; mode="$(echo "$route" | jq -r '.mode')"
        local host_port; host_port="$(echo "$route" | jq -r '.host_port')"
        local guest_port; guest_port="$(echo "$route" | jq -r '.guest_port')"
        local hostname; hostname="$(echo "$route" | jq -r '.hostname // empty')"

        if [[ "$mode" == "l7" ]]; then
          echo "  • L7: ${hostname}:${host_port} → ${guest_ip}:${guest_port}"
        else
          echo "  • L4: 0.0.0.0:${host_port} → ${guest_ip}:${guest_port}"
        fi
      done < <(echo "$routes_json" | jq -c '.[]')
      echo
    fi

    # Show volumes
    local vol_count; vol_count="$(echo "$volumes_json" | jq 'length')"
    if [[ "$vol_count" -gt 0 ]]; then
      echo "Volumes ($vol_count attached):"
      while read -r volume; do
        local vol_id; vol_id="$(echo "$volume" | jq -r '.volume_id')"
        local vol_name; vol_name="$(echo "$volume" | jq -r '.name')"
        local vol_size; vol_size="$(echo "$volume" | jq -r '.size_gb')"
        echo "  • $vol_id ($vol_name) - ${vol_size} GB"
      done < <(echo "$volumes_json" | jq -c '.[]')
      echo
    fi
  fi
}

cmd_haproxy_render() {
  haproxy_required_or_die || return 1
  if ! type -t haproxy_render_routes_from_db >/dev/null 2>&1; then
    die 1 "haproxy.sh not available; cannot render routes."
  fi
  haproxy_render_routes_from_db
  success "HAProxy routes rendered."
}

cmd_haproxy_reload() {
  haproxy_required_or_die || return 1
  if ! type -t haproxy_reload >/dev/null 2>&1; then
    die 1 "haproxy.sh not available; cannot reload."
  fi
  haproxy_reload
  success "HAProxy reloaded."
}

cmd_create() {
  require_root
  require_cmd jq sqlite3 dd mkfs.ext4 cpio

  local name="" image="" volume_id=""
  local vcpus="${DEFAULT_VCPUS:-1}"
  local memory="${DEFAULT_MEMORY:-128}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)  image="$2"; shift 2;;
      --volume) volume_id="$2"; shift 2;;
      --vcpus)  vcpus="$2"; shift 2;;
      --memory) memory="$2"; shift 2;;
      --)       shift; break;;
      -*)       die 2 "Unknown option: $1";;
      *)        name="$1"; shift;;
    esac
  done

  [[ -n "$name"  ]] || die 2 "Usage: infernoctl create <name> --image <ref>"
  [[ -n "$image" ]] || die 2 "Image (--image) is required; usage: infernoctl create <name> --image <ref>"

  # ensure VM root exists (metadata/logs live here), but we won't duplicate artifacts inside it
  local vm_root; vm_root="$(get_vm_dir "$name")"
  if [[ -e "$vm_root" ]]; then
    die 1 "VM directory already exists: $vm_root"
  fi
  mkdir -p "$vm_root" || die 1 "Failed to create $vm_root"
  chmod 750 "$vm_root" || { rm -rf "$vm_root"; die 1 "Failed to chmod $vm_root"; }

  log "Setting up network..."
  type -t create_vm_network >/dev/null 2>&1 \
    || { rm -rf "$vm_root"; die 1 "libvnet.sh not available; cannot allocate network"; }
  local network_config
  if ! network_config="$(create_vm_network "$name")"; then
    rm -rf "$vm_root"; die 1 "Network setup failed"
  fi

  # Persist base VM record (no version yet)
  if type -t vm_exists >/dev/null 2>&1 && ! vm_exists "$name"; then
    if type -t create_vm_with_state >/dev/null 2>&1; then
      create_vm_with_state \
        "$name" \
        "$(echo "$network_config" | jq -r '.tap_device')" \
        "$(echo "$network_config" | jq -r '.gateway_ip')" \
        "$(echo "$network_config" | jq -r '.guest_ip')" \
        "$(echo "$network_config" | jq -r '.mac_address')" \
        "$(echo "$network_config" | jq -r '.nft_rules_hash // ""')" >/dev/null \
        || { rm -rf "$vm_root"; die 1 "Failed to persist VM in DB"; }
    fi
  fi

  if [[ -n "$volume_id" ]] && type -t update_volume_vm >/dev/null 2>&1; then
    log "Attaching volume..."
    update_volume_vm "$volume_id" "$name" \
      || { rm -rf "$vm_root"; die 1 "Failed to attach volume to VM"; }
  fi

  log "Getting container metadata..."
  local process_json
  if type -t get_container_metadata >/dev/null 2>&1; then
    process_json="$(get_container_metadata "$image")" \
      || { rm -rf "$vm_root"; die 1 "Failed to get container metadata"; }
  elif type -t images_process_json >/dev/null 2>&1; then
    process_json="$(images_process_json "$image")" \
      || { rm -rf "$vm_root"; die 1 "Failed to derive process spec"; }
  else
    rm -rf "$vm_root"; die 1 "No images metadata helper (get_container_metadata or images_process_json)."
  fi

  # === IMAGE METADATA PERSISTENCE ==============================================
  log "Storing image metadata..."

  local image_manifest image_manifest_raw
  if type -t images_inspect_json >/dev/null 2>&1; then
    image_manifest_raw="$(images_inspect_json "$image" 2>/dev/null)" || { warn "Failed to inspect image $image"; image_manifest_raw="{}"; }
    image_manifest="$image_manifest_raw"
  else
    warn "images_inspect_json not available; skipping image metadata storage"
    image_manifest="{}"
  fi

  local docker_digest
  docker_digest="$(jq -r '.Id // empty' <<<"$image_manifest" 2>/dev/null || true)"

  # Fallback: Generate synthetic ID if no digest available
  if [[ -z "$docker_digest" ]]; then
    warn "No Docker digest found for $image; generating synthetic image_id"
    docker_digest="synthetic_$(echo -n "$image" | sha256sum | awk '{print $1}')"
  fi

  # Normalize image name (remove registry prefix, library/ prefix)
  local image_name
  image_name="$(echo "$image" | sed -E 's|^[^/]+/||;s|^library/||')"

  # Create manifests directory
  local manifest_dir="${IMAGES_DIR}/manifests"
  mkdir -p "$manifest_dir" 2>/dev/null || warn "Failed to create manifests directory"

  # Store manifest JSON to disk (sanitize digest for filename)
  local manifest_path="${manifest_dir}/${docker_digest//:/_}.json"
  echo "$image_manifest" > "$manifest_path" 2>/dev/null || warn "Failed to write manifest to $manifest_path"

  # Create or update image record in database
  if type -t create_image >/dev/null 2>&1 && type -t update_vm_image >/dev/null 2>&1; then
    local existing_image
    existing_image="$(sqlite3 "$DB_PATH" "SELECT image_id FROM images WHERE image_id = '$docker_digest';" 2>/dev/null || true)"

    if [[ -z "$existing_image" ]]; then
      debug "Creating new image record: $docker_digest"
      create_image "$docker_digest" "$image_name" "$image" "pending" "$manifest_path" >/dev/null 2>&1 \
        || warn "Failed to create image record (non-fatal)"
    else
      debug "Image $docker_digest already exists in database"
    fi

    # Link VM to image
    update_vm_image "$name" "$docker_digest" 2>/dev/null \
      || warn "Failed to link VM to image (non-fatal)"
  else
    warn "Database image functions not available; skipping image persistence"
  fi
  # === END IMAGE METADATA PERSISTENCE ==========================================

  local ssh_config="{}"
  if type -t generate_ssh_files >/dev/null 2>&1; then
    log "Generating SSH configuration..."
    if ! ssh_config="$(generate_ssh_files "$name")"; then
      warn "Failed to generate SSH config; continuing without SSH access"
      ssh_config="{}"
    fi
  fi

  # === VERSIONED CHROOT LAYOUT ================================================
  local version; version="$(_ulid_new)"
  local base
  base="$(_kiln_versions_dir)/${version}"
  local chroot_dir="${base}/root"
  local initramfs_dir="${base}/initramfs"
  local inferno_dir="${initramfs_dir}/inferno"

  mkdir -p "$chroot_dir" "$inferno_dir" || { rm -rf "$vm_root"; die 1 "Failed to create chroot/initramfs structure"; }

  # Stage init payloads (run.json), then pack into initrd in-place
  log "Generating init configuration..."
  if type -t generate_run_config >/dev/null 2>&1; then
    generate_run_config \
      "$name" \
      "$(echo "$network_config" | jq -r '.guest_ip')" \
      "$(echo "$network_config" | jq -r '.gateway_ip')" \
      "$volume_id" \
      "$process_json" \
      "$ssh_config" >"$inferno_dir/run.json" \
      || { rm -rf "$base"; die 1 "Failed to write run.json"; }
  else
    printf '%s\n' "$process_json" >"$inferno_dir/run.json" \
      || { rm -rf "$base"; die 1 "Failed to write minimal run.json"; }
  fi

  # init binary (shared system binary) -> into initrd contents (not duplicated in vm root)
  cp "/usr/share/inferno/init" "$inferno_dir/init" || { rm -rf "$base"; die 1 "Failed to copy init binary"; }
  chmod 755 "$inferno_dir/init"

  log "Creating initrd.cpio..."
  (cd "$initramfs_dir" && find . | cpio -H newc -o >"$chroot_dir/initrd.cpio") \
    || { rm -rf "$base"; die 1 "Failed to create initrd.cpio"; }

  # === ROOT FILESYSTEM (FILE-BASED OR LVM) =====================================
  local rootfs_mode="file"

  # Check if LVM rootfs is available
  if type -t rootfs_lvm_available >/dev/null 2>&1 && rootfs_lvm_available; then
    rootfs_mode="lvm"
    log "Using LVM thin snapshots for rootfs"

    # Create or reuse base image (snapshot created on start)
    local base_lv_path
    if type -t rootfs_create_base >/dev/null 2>&1; then
      base_lv_path="$(rootfs_create_base "$image" "$docker_digest")" \
        || { rm -rf "$base"; die 1 "Failed to create base image LV"; }
      log "Base image ready: $base_lv_path"
    else
      rm -rf "$base"; die 1 "librootfs.sh not loaded; cannot use LVM mode"
    fi

  else
    # Traditional file-based rootfs
    rootfs_mode="file"
    log "Using file-based rootfs"

    local rootfs_path="$chroot_dir/rootfs.img"
    log "Creating root filesystem image..."
    dd if=/dev/zero of="$rootfs_path" bs=1M count=1024 status=none \
      || { rm -rf "$base"; die 1 "Failed to create rootfs image"; }
    mkfs.ext4 -F -q "$rootfs_path" \
      || { rm -rf "$base"; die 1 "Failed to format rootfs image"; }

    if type -t extract_docker_image >/dev/null 2>&1; then
      extract_docker_image "$image" "$rootfs_path" \
        || { rm -rf "$base"; die 1 "Failed to extract image $image to rootfs"; }
    elif type -t images_extract_rootfs >/dev/null 2>&1; then
      images_extract_rootfs "$image" "$rootfs_path" \
        || { rm -rf "$base"; die 1 "Failed to extract image $image to rootfs"; }
    else
      rm -rf "$base"; die 1 "No image extraction helper found."
    fi
  fi

  # Store rootfs mode for start/stop logic
  echo "$rootfs_mode" > "$chroot_dir/rootfs.mode" || true
  # === END ROOT FILESYSTEM ======================================================

  # Static assets into the chroot + host exec under the version dir
  log "Placing firecracker/vmlinux/kiln once into versioned chroot..."
  link_or_copy "/usr/share/inferno/firecracker"  "$chroot_dir/firecracker"
  link_or_copy "/usr/share/inferno/vmlinux"      "$chroot_dir/vmlinux"
  local exec_base="kiln"
  link_or_copy "/usr/share/inferno/kiln"         "$base/${exec_base}"
  chmod 0755 "$base/${exec_base}"

  log "Generating firecracker configuration..."
  if type -t generate_firecracker_config >/dev/null 2>&1; then
    generate_firecracker_config \
      "$name" \
      "rootfs.img" \
      "$(echo "$network_config" | jq -r '.tap_device')" \
      "$(echo "$network_config" | jq -r '.mac_address')" \
      "$volume_id" \
      "$vcpus" \
      "$memory" >"$chroot_dir/firecracker.json" \
      || { rm -rf "$base"; die 1 "Failed to generate firecracker.json"; }
  else
    cat >"$chroot_dir/firecracker.json" <<EOF
{"vcpus": ${vcpus}, "memory_mb": ${memory}}
EOF
  fi

  log "Generating kiln configuration (uid=${DEFAULT_JAIL_UID:-123} gid=${DEFAULT_JAIL_GID:-100})..."
  export INFERNO_JAILER_ID="$version"
  if type -t generate_kiln_config >/dev/null 2>&1; then
    generate_kiln_config \
    "$name" \
    "$vcpus" \
    "$memory" \
    "${DEFAULT_JAIL_UID:-123}" \
    "${DEFAULT_JAIL_GID:-100}" >"$chroot_dir/kiln.json" \
    || { rm -rf "$base"; die 1 "Failed to generate kiln.json"; }
  else
    cat >"$chroot_dir/kiln.json" <<EOF
{"jail_id":"${version}","machine_id":"${name}","uid":${DEFAULT_JAIL_UID:-123},"gid":${DEFAULT_JAIL_GID:-100},"resources":{"cpu_count":${vcpus},"memory_mb":${memory},"cpu_kind":"C3"},"log":{"format":"text","timestamp":true,"debug":true},"firecracker_socket_path":"firecracker.sock","firecracker_config_path":"firecracker.json","firecracker_vsock_uds_path":"control.sock","vsock_stdout_port":10000,"vsock_exit_port":10001,"vm_logs_socket_path":"vm_logs.sock","exit_status_path":"exit_status.json"}
EOF
  fi
  unset INFERNO_JAILER_ID

  # Sanity: enforce UID/GID in kiln.json to match 123/100 (or your env-provided overrides).
  _verify_kiln_ids "$chroot_dir" "${DEFAULT_JAIL_UID:-123}" "${DEFAULT_JAIL_GID:-100}"

  # permissions (best-effort â€" kiln.json carries uid/gid expectations)
  local uid gid
  # NOTE: correct fallbacks are 123/100, not 100/100.
  uid="$(jq -r '.uid // empty' "$chroot_dir/kiln.json" 2>/dev/null || true)"
  gid="$(jq -r '.gid // empty' "$chroot_dir/kiln.json" 2>/dev/null || true)"
  [[ "$uid" =~ ^[0-9]+$ ]] || uid="${DEFAULT_JAIL_UID:-123}"
  [[ "$gid" =~ ^[0-9]+$ ]] || gid="${DEFAULT_JAIL_GID:-100}"

  chown "$uid:$gid" "$chroot_dir/rootfs.img" "$chroot_dir/kiln.json" "$chroot_dir/firecracker.json" 2>/dev/null || true
  chown -R "$uid:$gid" "$chroot_dir" 2>/dev/null || true
  chmod u+rwx,go+rx "$chroot_dir" 2>/dev/null || true
  chmod 0644 "$chroot_dir/vmlinux" "$chroot_dir/initrd.cpio" "$chroot_dir/firecracker.json" "$chroot_dir/kiln.json" || true

  # Record immutable version
  if type -t add_vm_version >/dev/null 2>&1; then
    add_vm_version "$name" "$version" >/dev/null || warn "Failed to record version for $name"
  fi

  # Friendly ownership of the metadata dir
  if [[ -n "$SUDO_USER" ]]; then
    chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$vm_root" || warn "chown failed (vm_root)"
  else
    chown -R "$(id -un):$(id -gn)" "$vm_root" || warn "chown failed (vm_root)"
  fi

  log "VM created successfully (version=${version})"

  jq -cn \
    --arg name "$name" \
    --arg version "$version" \
    --arg root "$chroot_dir" \
    --argjson net "$network_config" \
    --arg volume "${volume_id:-}" '
  {
    name: $name,
    version: $version,
    chroot_dir: $root,
    network: $net,
    volume: (if $volume == "" then null else $volume end)
  }'
}

cmd_start() {
  require_root
  require_cmd jq mount mountpoint

  local name="" detach="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --detach) detach="1"; shift;;
      -*) die 2 "Unknown option: $1";;
      *)  name="$1"; shift;;
    esac
  done
  [[ -n "$name" ]] || die 2 "Usage: infernoctl start <name> [--detach]"

  # Check VM state before attempting to start
  if type -t get_vm_state >/dev/null 2>&1; then
    local current_state; current_state="$(get_vm_state "$name" 2>/dev/null || true)"
    if [[ "$current_state" == "running" ]]; then
      warn "VM ${name} is already running."
      return 0
    fi
  fi

  _resolve_vm_ctx "$name"

  local jailer_bin; jailer_bin="$(_jailer_bin)"
  [[ -n "$jailer_bin" ]] || die 1 "jailer binary not found (set INFERNO_JAILER_BIN or install to /usr/share/inferno or PATH)"

  local version="$JAIL_ID"

  # Ensure kiln.json has the correct jail_id and is writable by the jailed UID/GID
  local tmp="$CHROOT_DIR/.kiln.json.tmp"
  jq --arg v "$version" '.jail_id = $v' "$CHROOT_DIR/kiln.json" >"$tmp" \
    || die 1 "Failed to render kiln.json with jail_id=$version"
  chown "$JAIL_UID:$JAIL_GID" "$tmp" 2>/dev/null || true
  chmod 0664 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$CHROOT_DIR/kiln.json" \
    || die 1 "Failed to update kiln.json"
  chown "$JAIL_UID:$JAIL_GID" "$CHROOT_DIR" 2>/dev/null || true

  _purge_version_runtime "$CHROOT_DIR"
  _ensure_dev_nodes "$CHROOT_DIR" "$JAIL_UID" "$JAIL_GID"

  # === EPHEMERAL SNAPSHOT CREATION (LVM MODE) ==================================
  local rootfs_mode="file"
  [[ -f "$CHROOT_DIR/rootfs.mode" ]] && rootfs_mode="$(cat "$CHROOT_DIR/rootfs.mode" 2>/dev/null || echo file)"

  if [[ "$rootfs_mode" == "lvm" ]]; then
    log "Creating ephemeral rootfs snapshot..."

    # Get VM ID from database
    local vm_id
    vm_id="$(sqlite3 "$DB_PATH" "SELECT id FROM vms WHERE name = '$name';" 2>/dev/null || true)"
    if [[ -z "$vm_id" ]]; then
      die 1 "VM not found in database: $name"
    fi

    # Get Docker digest from database
    local docker_digest
    docker_digest="$(sqlite3 "$DB_PATH" "SELECT i.image_id FROM images i JOIN vms v ON v.image_id = i.id WHERE v.name = '$name';" 2>/dev/null || true)"
    if [[ -z "$docker_digest" ]]; then
      die 1 "Image digest not found for VM $name"
    fi

    # Create ephemeral snapshot
    local snap_path
    if type -t rootfs_create_snapshot >/dev/null 2>&1; then
      snap_path="$(rootfs_create_snapshot "$name" "$vm_id" "$docker_digest" "$version")" \
        || die 1 "Failed to create ephemeral snapshot"
    else
      die 1 "librootfs.sh not loaded; cannot create snapshot"
    fi

    log "Ephemeral snapshot created: $snap_path"

    # Create device node inside chroot for snapshot
    log "Creating device node in chroot..."
    local snap_dev_major snap_dev_minor
    snap_dev_major="$(stat -L -c '%t' "$snap_path" 2>/dev/null)"
    snap_dev_minor="$(stat -L -c '%T' "$snap_path" 2>/dev/null)"
    snap_dev_major=$((16#$snap_dev_major))
    snap_dev_minor=$((16#$snap_dev_minor))

    local chroot_dev_path="$CHROOT_DIR/dev/rootfs"
    rm -f "$chroot_dev_path" 2>/dev/null || true
    mknod "$chroot_dev_path" b "$snap_dev_major" "$snap_dev_minor" || die 1 "Failed to create device node in chroot"
    chown "$JAIL_UID:$JAIL_GID" "$chroot_dev_path" 2>/dev/null || true
    chmod 0660 "$chroot_dev_path" 2>/dev/null || true

    # Update firecracker.json with relative device path
    log "Updating firecracker config with snapshot path..."
    if jq '.drives[0].path_on_host = "dev/rootfs"' "$CHROOT_DIR/firecracker.json" > "$CHROOT_DIR/firecracker.json.tmp" 2>/dev/null; then
      mv "$CHROOT_DIR/firecracker.json.tmp" "$CHROOT_DIR/firecracker.json"
      chown "$JAIL_UID:$JAIL_GID" "$CHROOT_DIR/firecracker.json" 2>/dev/null || true
    else
      warn "Failed to update firecracker.json with snapshot path"
    fi

    # Check thin pool usage
    if type -t rootfs_check_pool_usage >/dev/null 2>&1; then
      rootfs_check_pool_usage || warn "Thin pool usage check failed"
    fi
  fi
  # === END EPHEMERAL SNAPSHOT CREATION =========================================

  # Start global VM logs socket if not running
  ensure_global_vm_logs_socket || warn "Global VM logs socket not available"

  # Hard link the global VM logs socket into the chroot
  log "Linking VM logs socket into jail..."
  
  local global_socket="${INFERNO_ROOT}/logs/vm_logs.sock"
  local jail_socket="$CHROOT_DIR/vm_logs.sock"
  
  if [[ -S "$global_socket" ]]; then
      rm -f "$jail_socket" 2>/dev/null || true
      if ln "$global_socket" "$jail_socket"; then
          chown "${JAIL_UID}:${JAIL_GID}" "$jail_socket" 2>/dev/null || true
          debug "Hard linked VM logs socket to jail"
      else
          warn "Failed to hard link VM logs socket - VM logs may not work"
      fi
  else
      warn "Global VM logs socket not found at $global_socket"
  fi

  # Verify kiln.json has correct UID/GID expectations
  _verify_kiln_ids "$CHROOT_DIR" "${JAIL_UID}" "${JAIL_GID}"

  # Prepare firecracker capabilities if needed
  _prepare_firecracker_caps

  # Read resource limits from kiln.json for cgroup configuration
  local vcpus memory_mb
  vcpus="$(jq -r '.resources.cpu_count // 1' "$CHROOT_DIR/kiln.json" 2>/dev/null)" || vcpus=1
  memory_mb="$(jq -r '.resources.memory_mb // 128' "$CHROOT_DIR/kiln.json" 2>/dev/null)" || memory_mb=128

  # Convert to cgroup v2 format
  # CPU: vcpus * 100000 microseconds per 100000 microsecond period
  # Memory: memory_mb * 1024 * 1024 bytes
  local cpu_quota memory_bytes
  cpu_quota=$((vcpus * 100000))
  memory_bytes=$((memory_mb * 1024 * 1024))

  debug "Resource limits: vcpus=${vcpus}, memory=${memory_mb}MB"
  debug "Cgroup values: cpu.max=${cpu_quota} 100000, memory.max=${memory_bytes}"

  # Jailer args: kiln takes NO args; it finds ./kiln.json in CWD
  # Using cgroups v2 with proper format for cpu.max and memory.max
  # NOTE: The space in "cpu.max=X Y" must be quoted as a single argument
  local -a JARGS=(
    --id "$version"
    --uid "$JAIL_UID" --gid "$JAIL_GID"
    --exec-file "$KILN_EXEC"
    --chroot-base-dir "$(_chroot_base_dir)"
    --cgroup-version "2"
    --parent-cgroup "firecracker"
    --cgroup "cpu.max=${cpu_quota} 100000"
    --cgroup "memory.max=${memory_bytes}"
  )

  mkdir -p "${INFERNO_ROOT}/logs"
  info "Starting ${name} with jailer (jail_id=${version}, uid=${JAIL_UID}, gid=${JAIL_GID})"
  info "Exec file (host): $KILN_EXEC"
  info "Jail root:        ${CHROOT_DIR}"

  if [[ "$detach" == "1" ]]; then
    info "Starting in background..."
    (
      nohup env RUST_BACKTRACE=full "$jailer_bin" "${JARGS[@]}" -- &>/dev/null &
      echo $! > "$VM_ROOT/jailer.pid"
    ) </dev/null

    # Wait for kiln to write its PID file (up to 2 seconds)
    local pid_file="${CHROOT_DIR}/kiln.pid"
    local retries=20
    while [[ $retries -gt 0 ]] && [[ ! -f "$pid_file" ]]; do
      sleep 0.1
      ((retries--))
    done

    if [[ -f "$pid_file" ]]; then
      # Update VM state to running
      if type -t set_vm_state >/dev/null 2>&1; then
        set_vm_state "$name" "running" || warn "Failed to update VM state to running"
      fi
      success "VM ${name} started (PID $(cat "$pid_file"))."
    else
      warn "VM ${name} started but PID file not yet present."
    fi
  else
    info "Foreground mode (Ctrl-C to stop)â€¦"
    # Update VM state to running (for foreground mode)
    if type -t set_vm_state >/dev/null 2>&1; then
      set_vm_state "$name" "running" || warn "Failed to update VM state to running"
    fi

    # Setup cleanup trap for foreground mode
    _cleanup_foreground() {
      local exit_code=$?
      warn "Caught signal, cleaning up..."

      # Update database state
      if type -t set_vm_state >/dev/null 2>&1; then
        set_vm_state "$name" "stopped" 2>/dev/null || true
      fi

      # Kill jailer process if it's still running
      if [[ -f "$VM_ROOT/jailer.pid" ]]; then
        local jpid; jpid="$(_read_pid "$VM_ROOT/jailer.pid" 2>/dev/null)" || jpid=""
        if [[ -n "$jpid" ]] && kill -0 "$jpid" 2>/dev/null; then
          kill -TERM "$jpid" 2>/dev/null || true
          sleep 1
          kill -KILL "$jpid" 2>/dev/null || true
        fi
      fi

      exit $exit_code
    }
    trap '_cleanup_foreground' SIGINT SIGTERM

    # Start jailer in foreground (not using exec so trap works)
    env RUST_BACKTRACE=full "$jailer_bin" "${JARGS[@]}" --
    local jailer_exit=$?

    # Normal exit cleanup
    trap - SIGINT SIGTERM
    if type -t set_vm_state >/dev/null 2>&1; then
      set_vm_state "$name" "stopped" || warn "Failed to update VM state to stopped"
    fi

    return $jailer_exit
  fi
}

cmd_stop() {
  require_root
  require_cmd jq socat umount

  local name="" sig="SIGTERM" timeout="10" do_kill="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --signal)  sig="$2"; shift 2;;
      --timeout) timeout="$2"; shift 2;;
      --kill)    do_kill="1"; shift;;
      -*)        die 2 "Unknown option: $1";;
      *)         name="$1"; shift;;
    esac
  done
  [[ -n "$name" ]] || die 2 "Usage: infernoctl stop <name> [--signal SIGTERM] [--timeout SECONDS] [--kill]"

  # Check VM state before attempting to stop
  if type -t get_vm_state >/dev/null 2>&1; then
    local current_state; current_state="$(get_vm_state "$name" 2>/dev/null || true)"
    if [[ "$current_state" == "stopped" ]]; then
      info "VM ${name} is already stopped."
      return 0
    elif [[ "$current_state" == "created" ]]; then
      info "VM ${name} has not been started yet."
      return 0
    fi
  fi

  _resolve_vm_ctx "$name"  # sets: VM_ROOT, JAIL_ID, JAIL_UID/GID, EXEC_BASE=kiln, CHROOT_DIR, LOGF

  # Locate PIDs (best-effort)
  local kiln_pid_file; kiln_pid_file="$(_find_kiln_pid_file "$VM_ROOT")"
  local fc_pid_file;   fc_pid_file="$(_find_firecracker_pid_file "$VM_ROOT")"
  local jailer_pid_file="${VM_ROOT}/jailer.pid"

  local kiln_pid="";   [[ -n "$kiln_pid_file"   ]] && kiln_pid="$(_read_pid "$kiln_pid_file")"
  local fc_pid="";     [[ -n "$fc_pid_file"     ]] && fc_pid="$(_read_pid "$fc_pid_file")"
  local jailer_pid=""; [[ -f "$jailer_pid_file" ]] && jailer_pid="$(_read_pid "$jailer_pid_file")"

  info "Requesting graceful shutdown of ${name} (version=${JAIL_ID}, signal=${sig}, timeout=${timeout}s)â€¦"

  # Resolve API port from the versioned run.json (fallback 10002)
  local api_port
  local run_json_base="$(_kiln_versions_dir)/${JAIL_ID}/initramfs/inferno/run.json"
  api_port="$(jq -r '.vsock_api_port // 10002' "$run_json_base" 2>/dev/null || echo 10002)"

  if send_vm_signal "$name" "$sig" "$api_port"; then
    info "Guest API signal delivered."
  else
    local sock_line; sock_line="$(_control_sock_path "$api_port" "$VM_ROOT" 2>/dev/null)" || true
    if [[ -n "$sock_line" ]]; then
      local sock="${sock_line%%|*}"
      warn "Guest API not reachable via $sock; perms: $(stat -c '%A %a %U:%G' "$sock" 2>/dev/null || echo 'n/a')"
    fi
    warn "Guest vsock API not reachable; falling back to host-side signaling."
    [[ -n "$kiln_pid"   ]] && kill -"${sig}" "$kiln_pid"   2>/dev/null || true
    [[ -n "$fc_pid"     ]] && kill -"${sig}" "$fc_pid"     2>/dev/null || true
    [[ -n "$jailer_pid" ]] && kill -"${sig}" "$jailer_pid" 2>/dev/null || true
  fi

  local ok="0"
  [[ -n "$kiln_pid"   ]] && _wait_pid_dead "$kiln_pid"   "$timeout" && ok="1"
  [[ -n "$fc_pid"     ]] && _wait_pid_dead "$fc_pid"     "$timeout" && ok="1"
  [[ -n "$jailer_pid" ]] && _wait_pid_dead "$jailer_pid" "$timeout" && ok="1"

  if [[ "$do_kill" == "1" ]]; then
    for p in "$kiln_pid" "$fc_pid" "$jailer_pid"; do
      if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
        warn "Escalating: SIGKILL PID ${p}â€¦"
        kill -KILL "$p" 2>/dev/null || true
        _wait_pid_dead "$p" 2 >/dev/null || true
        ok="1"
      fi
    done
  fi

  # === EPHEMERAL SNAPSHOT DELETION (LVM MODE) ==================================
  local rootfs_mode="file"
  [[ -f "$CHROOT_DIR/rootfs.mode" ]] && rootfs_mode="$(cat "$CHROOT_DIR/rootfs.mode" 2>/dev/null || echo file)"

  if [[ "$rootfs_mode" == "lvm" ]]; then
    log "Deleting ephemeral rootfs snapshot..."

    if type -t rootfs_delete_snapshot >/dev/null 2>&1; then
      rootfs_delete_snapshot "$name" || warn "Failed to delete snapshot (non-fatal)"
    else
      warn "librootfs.sh not loaded; snapshot not deleted"
    fi
  fi
  # === END EPHEMERAL SNAPSHOT DELETION =========================================

  # Clean transient artifacts in the versioned chroot
  rm -f "${CHROOT_DIR}/${EXEC_BASE}.pid" \
        "${CHROOT_DIR}/kiln.pid" \
        "${CHROOT_DIR}/firecracker.pid" \
        "${CHROOT_DIR}/firecracker.sock" \
        "${CHROOT_DIR}/vm_logs.sock" \
        "${CHROOT_DIR}/control.sock" 2>/dev/null || true
  rm -f "${CHROOT_DIR}"/control.sock_* 2>/dev/null || true

  # unmount the logs bind (best-effort)
  umount -l "${CHROOT_DIR}/run/inferno" 2>/dev/null || true

  local still=""
  for p in "$kiln_pid" "$fc_pid" "$jailer_pid"; do
    if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
      still+=" ${p}"
    fi
  done

  if [[ -z "$still" ]]; then
    # Update VM state to stopped
    if type -t set_vm_state >/dev/null 2>&1; then
      set_vm_state "$name" "stopped" || warn "Failed to update VM state to stopped"
    fi

    if [[ "$ok" == "1" ]]; then
      success "Stopped ${name} (version ${JAIL_ID})."
    else
      warn "No running processes found for ${name}."
    fi
  else
    warn "Partial stop; still running PIDs:${still}"
    return 1
  fi
}

cmd_destroy() {
  require_root
  require_cmd jq ip socat umount

  local name="" yes="0" keep_logs="0"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes)       yes="1"; shift;;
      --keep-logs) keep_logs="1"; shift;;
      -*)          die 2 "Unknown option: $1";;
      *)           name="$1"; shift;;
    esac
  done
  [[ -n "$name" ]] || die 2 "Usage: infernoctl destroy <name> [--yes] [--keep-logs]"

  _resolve_vm_ctx "$name"  # sets VM_ROOT, JAIL_ID, CHROOT_DIR, EXEC_BASE, LOGF

  echo "About to destroy VM '${name}'. Planned actions:"
  _list_vm_resources "$name"
  echo "Filesystem:"
  echo "  â€¢ Remove jailer chroot: $(_kiln_versions_dir)/${JAIL_ID}"
  echo "  â€¢ Remove PID file: ${VM_ROOT}/jailer.pid (if present)"
  if [[ "$keep_logs" == "1" ]]; then
    echo "  â€¢ Keep log file: ${LOGF}"
  else
    echo "  â€¢ Remove log file: ${LOGF} (if present)"
  fi
  echo "  â€¢ Remove metadata dir: ${VM_ROOT}"
  if type -t delete_vm >/dev/null 2>&1; then
    echo "Database:"
    echo "  â€¢ Delete VM record via database.sh: delete_vm \"$name\""
  fi

  if [[ "$yes" != "1" ]]; then
    echo
    read -r -p "Proceed with destroy? [y/N] " ans
    case "$ans" in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; return 1;;
    esac
  fi

  # Best-effort graceful stop
  local api_port
  local run_json_base
  run_json_base="$(_kiln_versions_dir)/${JAIL_ID}/initramfs/inferno/run.json"
  api_port="$(jq -r '.vsock_api_port // 10002' "$run_json_base" 2>/dev/null || echo 10002)"
  send_vm_signal "$name" "TERM" "$api_port" >/dev/null 2>&1 || true
  sleep 0.5

  # Kill remaining processes if any
  local kiln_pid_file; kiln_pid_file="$(_find_kiln_pid_file "$VM_ROOT")"
  local fc_pid_file;   fc_pid_file="$(_find_firecracker_pid_file "$VM_ROOT")"
  local jailer_pid_file="${VM_ROOT}/jailer.pid"

  local kiln_pid="";   [[ -n "$kiln_pid_file"   ]] && kiln_pid="$(_read_pid "$kiln_pid_file")"
  local fc_pid="";     [[ -n "$fc_pid_file"     ]] && fc_pid="$(_read_pid "$fc_pid_file")"
  local jailer_pid=""; [[ -f "$jailer_pid_file" ]] && jailer_pid="$(_read_pid "$jailer_pid_file")"

  for p in "$kiln_pid" "$fc_pid" "$jailer_pid"; do
    if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
      kill -TERM "$p" 2>/dev/null || true
      sleep 0.3
      kill -KILL "$p" 2>/dev/null || true
    fi
  done

  # Network teardown
  if type -t delete_vm_network >/dev/null 2>&1; then
    delete_vm_network "$name" || warn "delete_vm_network failed"
  else
    local guest_ip tap
    guest_ip="$(jq -r '.ips[0].ip // empty' "$run_json_base" 2>/dev/null)"
    if [[ -z "$guest_ip" && -f "$VM_ROOT/initramfs/inferno/run.json" ]]; then
      guest_ip="$(jq -r '.ips[0].ip // empty' "$VM_ROOT/initramfs/inferno/run.json" 2>/dev/null)"
    fi
    if [[ -n "$guest_ip" ]]; then
      tap="$(_detect_tap_for_guest "$guest_ip")"
      ip route del "$guest_ip" dev "$tap" 2>/dev/null || true
      ip addr del 172.16.1.1/30 dev "$tap" 2>/dev/null || true
      ip link del "$tap" 2>/dev/null || true
    fi
  fi

  # unmount logs bind before deleting chroot
  umount -l "${CHROOT_DIR}/run/inferno" 2>/dev/null || true

  # Chroot cleanup
  rm -f "${VM_ROOT}/jailer.pid" 2>/dev/null || true
  rm -rf "$(_kiln_versions_dir)/${JAIL_ID}" 2>/dev/null || true

  # DB cleanup (if available)
  if type -t delete_vm >/dev/null 2>&1; then
    delete_vm "$name" || warn "delete_vm failed"
  fi

  # === BASE IMAGE CLEANUP (LVM MODE) ===========================================
  # Ensure snapshot is deleted (defensive cleanup)
  if type -t rootfs_delete_snapshot >/dev/null 2>&1; then
    rootfs_delete_snapshot "$name" 2>/dev/null || true
  fi

  # Note: Base images are NOT deleted here (kept cached for reuse)
  # Use 'infernoctl gc' (future feature) to prune unused base images
  # === END BASE IMAGE CLEANUP ==================================================

  # Logs and metadata dir
  if [[ "$keep_logs" != "1" ]]; then
    rm -f "$LOGF" 2>/dev/null || true
  fi
  rm -rf "$VM_ROOT"

  success "Destroyed '${name}'."
}

cmd_images_process() {
  local img="${1:-}"; shift || true
  local ep="${1:-}";  shift || true
  local cmd="${1:-}"; shift || true
  [[ -n "$img" ]] || die 2 "Usage: infernoctl images process <image> [entrypoint] [cmd]"
  images_process_json "$img" "$ep" "$cmd" | jq .
}

cmd_images_exposed() {
  local img="${1:-}"; shift || true
  [[ -n "$img" ]] || die 2 "Usage: infernoctl images exposed <image>"
  images_exposed_ports "$img" | jq .
}

# --- Dispatch ----------------------------------------------------------------
main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    version)              cmd_version;;
    env) case "${1:-}" in
            print) shift; cmd_env_print;;
            *) usage; exit 2;;
         esac ;;

    init)                 cmd_init "$@";;

    list|ls)              cmd_list "$@";;
    status)               cmd_status "$@";;
    reconcile)            cmd_reconcile "$@";;

    create)               cmd_create "$@";;
    start)                cmd_start "$@";;
    stop)                 cmd_stop "$@";;
    destroy)              cmd_destroy "$@";;

    logs)                 cmd_logs "$@";;

    haproxy) case "${1:-}" in
               render) shift; cmd_haproxy_render;;
               reload) shift; cmd_haproxy_reload;;
               *) usage; exit 2;;
             esac ;;

    images) case "${1:-}" in
              process) shift; cmd_images_process "$@";;
              exposed) shift; cmd_images_exposed "$@";;
              *) usage; exit 2;;
            esac ;;

    -h|--help|help|"")    usage;;
    *)                    usage; exit 2;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi