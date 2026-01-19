#!/usr/bin/env bash
# Image helpers: pull/inspect container images, derive process, and extract rootfs
# Requires: jq, and either docker or podman (for extraction/inspect)
IMAGES_SH_VERSION="1.3.0"

# --- Bootstrap & deps ---------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Load env first so shared paths/DB_PATH exist; then logging & config
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/env.sh" ]] && source "${SCRIPT_DIR}/env.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/logging.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config.sh"

# Opt-in strict mode with nice ERR traps from logging.sh (no-op if absent)
declare -F set_error_handlers >/dev/null 2>&1 && set_error_handlers

# --- Tool selection (docker or podman) ----------------------------------------
_images_tool=""
_images_detect_tool() {
  if [[ -n "${DOCKER_BIN:-}" ]]; then
    _images_tool="$DOCKER_BIN"
  elif command -v docker >/dev/null 2>&1; then
    _images_tool="docker"
  elif command -v podman >/dev/null 2>&1; then
    _images_tool="podman"
  else
    die 1 "Neither docker nor podman found; please install one."
  fi
}
_images_detect_tool

# Small wrappers to tolerate docker/podman differences
_images_exists_locally() {
  local img="$1"
  if [[ "$_images_tool" == docker* ]]; then
    "$_images_tool" image inspect "$img" >/dev/null 2>&1
  else
    "$_images_tool" image exists "$img"
  fi
}

_images_pull() {
  local img="$1"
  log "Pulling image: $img"
  "$_images_tool" pull "$img"
}

_images_inspect() {
  local img="$1"
  if [[ "$_images_tool" == docker* ]]; then
    "$_images_tool" image inspect "$img"
  else
    "$_images_tool" image inspect "$img"
  fi
}

_images_container_create() {
  local img="$1"
  "$_images_tool" create "$img"
}

_images_container_rm() {
  local cid="$1"
  "$_images_tool" rm -f "$cid" >/dev/null 2>&1 || true
}

_images_container_export() {
  local cid="$1"
  "$_images_tool" export "$cid"
}

# --- Helpers ------------------------------------------------------------------
images_norm_ref() { printf '%s' "$1"; }

# Convert override string or JSON to a JSON array
# - If empty -> []
# - If valid JSON -> compact it (caller may pass array or string)
# - Else -> wrap as single-element array
__to_json_argv() {
  local s="$1"
  if [[ -z "$s" ]]; then
    jq -cn '[]'
  elif jq -e . >/dev/null 2>&1 <<<"$s"; then
    jq -c . <<<"$s"
  else
    jq -cn --arg v "$s" '[$v]'
  fi
}

# --- Process/metadata ---------------------------------------------------------
# Ensure image local, inspect JSON (single object)
images_inspect_json() {
  local img; img="$(images_norm_ref "$1")"
  if ! _images_exists_locally "$img"; then
    _images_pull "$img" || { error "Failed to pull image $img"; return 1; }
  fi
  # Some tools yield an array; normalize to first element
  local result
  result="$(_images_inspect "$img" 2>&1)" || { error "Failed to inspect image $img"; return 1; }

  # Validate the raw output is valid JSON before processing
  if ! jq -e . >/dev/null 2>&1 <<<"$result"; then
    error "Invalid JSON returned from docker/podman inspect for $img"
    return 1
  fi

  # Normalize array to single object
  jq 'if type=="array" then .[0] else . end' <<<"$result"
}

# Compose argv from (override_entrypoint + override_cmd) or image (Entrypoint+Cmd).
# Fallback if nothing set: ["/bin/sh"]
# Inputs:
#   $1 image
#   $2 entrypoint override (JSON array or plain string) (optional)
#   $3 cmd override        (JSON array or plain string) (optional)
images_process_json() {
  local img="$1" ep_override="${2:-}" cmd_override="${3:-}"
  [[ -n "$img" ]] || die 2 "image ref required"

  local meta; meta="$(images_inspect_json "$img")" || return 1

  # Validate that meta is actually valid JSON
  if ! jq -e . >/dev/null 2>&1 <<<"$meta"; then
    error "Invalid JSON returned from image inspect"
    return 1
  fi

  # Extract config pieces
  local img_ep img_cmd img_env img_workdir
  img_ep="$(jq -c '.Config.Entrypoint // []' <<<"$meta")" || { error "Failed to extract Entrypoint"; return 1; }
  img_cmd="$(jq -c '.Config.Cmd        // []' <<<"$meta")" || { error "Failed to extract Cmd"; return 1; }
  img_env="$(jq -c '.Config.Env        // []' <<<"$meta")" || { error "Failed to extract Env"; return 1; }
  img_workdir="$(jq -r '.Config.WorkingDir // "/"' <<<"$meta")" || { error "Failed to extract WorkingDir"; return 1; }
  debug "image Entrypoint: $img_ep"
  debug "image Cmd:        $img_cmd"
  debug "image Env:        $img_env"
  debug "image WorkDir:    $img_workdir"

  # Normalize overrides
  local ep_over cmd_over
  ep_over="$(__to_json_argv "$ep_override")"
  cmd_over="$(__to_json_argv "$cmd_override")"

  # Build argv (prefer overrides if non-empty)
  local argv
  argv="$(
    jq -cn \
      --argjson ep      "$ep_over" \
      --argjson cmd     "$cmd_over" \
      --argjson img_ep  "$img_ep" \
      --argjson img_cmd "$img_cmd" '
        def nz(a): if (a|type)=="array" and (a|length)>0 then a else null end;
        (nz($ep)   // $img_ep)  as $use_ep |
        (nz($cmd)  // $img_cmd) as $use_cmd |
        ($use_ep + $use_cmd)    as $argv   |
        if ($argv|length) == 0 then ["/bin/sh"] else $argv end
      '
  )"

  # Convert Env list ["A=B","C=D"] to {A:"B",C:"D"}
  local env_obj
  env_obj="$(
    jq -cn --argjson pairs "$img_env" '
      reduce $pairs[]? as $e ({};
        ($e | capture("^(?<k>[^=]+)=(?<v>.*)$")) as $kv
        | . + { ($kv.k): $kv.v })
    '
  )"

  # Build process JSON
  jq -cn \
    --argjson argv "$argv" \
    --arg workdir "$img_workdir" \
    --argjson env "$env_obj" \
    '
      {
        command: $argv,
        working_dir: (if $workdir == "" then "/" else $workdir end),
        env: $env
      }
    '
}

# Compatibility wrapper that matches your earlier "cmd/args/env[]" shape.
# Returns:
#   { "cmd": "/path", "args": ["..."], "env": ["K=V", ...] }
get_container_metadata() {
  local img="$1"
  [[ -n "$img" ]] || die 2 "image ref required"

  local meta; meta="$(images_inspect_json "$img")" || return 1

  # Validate that meta is actually valid JSON
  if ! jq -e . >/dev/null 2>&1 <<<"$meta"; then
    error "Invalid JSON returned from image inspect"
    return 1
  fi

  # Entrypoint+Cmd combine
  local ep cmd
  ep="$(jq -c '.Config.Entrypoint // []' <<<"$meta")" || { error "Failed to extract Entrypoint from image metadata"; return 1; }
  cmd="$(jq -c '.Config.Cmd        // []' <<<"$meta")" || { error "Failed to extract Cmd from image metadata"; return 1; }
  local argv; argv="$(jq -cn --argjson ep "$ep" --argjson cmd "$cmd" '$ep+$cmd | if length==0 then ["/bin/sh"] else . end')" || { error "Failed to build argv from Entrypoint and Cmd"; return 1; }

  # Split into cmd + args
  local first; first="$(jq -r '.[0]' <<<"$argv")"
  local rest;  rest="$(jq -c '.[1:]' <<<"$argv")"
  # Keep Env as array-of-strings for compatibility
  local env_arr; env_arr="$(jq -c '.Config.Env // []' <<<"$meta")"

  jq -cn --arg cmd "$first" --argjson args "$rest" --argjson env "$env_arr" \
    '{cmd:$cmd, args:$args, env:$env}'
}

# --- EXPOSEd ports ------------------------------------------------------------
# Return EXPOSEd ports from image (as JSON array of ints)
images_exposed_ports() {
  local img="$1"
  [[ -n "$img" ]] || die 2 "image ref required"
  local meta; meta="$(images_inspect_json "$img")"
  jq -c '
    (.Config.ExposedPorts // {} ) as $m |
    [ $m
      | keys[]
      | capture("^(?<p>[0-9]+)")
      | .p
      | tonumber
    ] | unique | sort
  ' <<<"$meta"
}

# --- Rootfs extraction --------------------------------------------------------
# Verify an ext4 filesystem image (best-effort)
verify_rootfs() {
  local rootfs_path="$1"
  [[ -f "$rootfs_path" ]] || { error "Rootfs image not found: $rootfs_path"; return 1; }
  local fs_type
  fs_type="$(blkid -o value -s TYPE "$rootfs_path" 2>/dev/null || true)"
  if [[ -z "$fs_type" ]]; then
    warn "Could not determine filesystem type for $rootfs_path (blkid missing or image fresh) — continuing."
    return 0
  fi
  if [[ "$fs_type" != "ext4" ]]; then
    error "Invalid filesystem type: $fs_type (expected ext4)"
    return 1
  fi
  return 0
}

# Extract a Docker/Podman image rootfs into an ext4 image file.
# Usage: extract_docker_image <image_ref> <rootfs.img>
extract_docker_image() {
  local image="$1"
  local rootfs_path="$2"
  local cid="" mnt=""

  [[ -n "$image" && -n "$rootfs_path" ]] || { error "extract_docker_image requires <image> <rootfs.img>"; return 2; }

  # Ensure tools and image present
  _images_detect_tool
  if ! _images_exists_locally "$image"; then
    _images_pull "$image" || { error "Failed to pull $image"; return 1; }
  fi

  verify_rootfs "$rootfs_path" || return 1

  # Create temp mountpoint
  mnt="$(mktemp -d)" || { error "Failed to create mount dir"; return 1; }

  # Cleanup trap (runs on any exit path of this function scope)
  _extract_cleanup() {
    local ec=$?
    if mountpoint -q "$mnt" 2>/dev/null; then umount "$mnt" 2>/dev/null || true; fi
    [[ -n "$cid" ]] && _images_container_rm "$cid"
    [[ -n "$mnt" ]] && rm -rf "$mnt"
    return $ec
  }
  trap _extract_cleanup RETURN

  # Mount the ext4 image
  mount -o loop "$rootfs_path" "$mnt" || { error "Failed to mount $rootfs_path"; return 1; }

  # Create a stopped container and export its fs into the mount
  cid="$(_images_container_create "$image")" || { error "Failed to create container from $image"; return 1; }

  # Stream-export → untar into mountpoint
  if ! _images_container_export "$cid" | tar -C "$mnt" -xf - ; then
    error "Failed to export container filesystem into $mnt"
    return 1
  fi

  sync || true
  success "Extracted $image into $rootfs_path"
  return 0
}

# Alias to match the name infernoctl looks for as a fallback
images_extract_rootfs() {
  extract_docker_image "$@"
}

# --- Tiny CLI for manual testing ---------------------------------------------
# Usage examples:
#   ./images.sh process nginx:latest
#   ./images.sh exposed nginx:latest
#   ./images.sh extract nginx:latest /path/to/rootfs.img
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  sub="${1:-}"; shift || true
  case "$sub" in
    process)
      img="${1:-}"; shift || true
      ep="${1:-}";  shift || true
      cmd="${1:-}"; shift || true
      [[ -n "$img" ]] || die 2 "Usage: $0 process <image> [entrypoint_json|string] [cmd_json|string]"
      images_process_json "$img" "$ep" "$cmd" | jq .
      ;;
    exposed)
      img="${1:-}"; shift || true
      [[ -n "$img" ]] || die 2 "Usage: $0 exposed <image>"
      images_exposed_ports "$img" | jq .
      ;;
    extract)
      img="${1:-}"; shift || true
      imgfile="${1:-}"; shift || true
      [[ -n "$img" && -n "$imgfile" ]] || die 2 "Usage: $0 extract <image> <rootfs.img>"
      extract_docker_image "$img" "$imgfile"
      ;;
    version|-v|--version)
      echo "IMAGES_SH_VERSION=$IMAGES_SH_VERSION"
      ;;
    *)
      cat >&2 <<'EOF'
Usage:
  $0 process <image> [entrypoint_json_or_string] [cmd_json_or_string]
  $0 exposed <image>
  $0 extract <image> <rootfs.img>
  $0 --version
EOF
      exit 2
      ;;
  esac
fi
