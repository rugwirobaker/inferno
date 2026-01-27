#!/bin/bash

# bundle-libs.sh - Bundle dynamic library dependencies into initramfs
# Version: 1.0.0

# Source shared logging utilities
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/logging.sh" ]] && source "${SCRIPT_DIR}/logging.sh"

# Bundle libraries for a given binary into a target directory
# Args: $1 = binary_path, $2 = target_lib_dir
# Creates: lib/ structure with all dependencies and dynamic linker
bundle_binary_libs() {
  local binary="$1"
  local target_lib_dir="$2"

  [[ -f "$binary" ]] || { error "Binary not found: $binary"; return 1; }
  [[ -d "$target_lib_dir" ]] || mkdir -p "$target_lib_dir" || { error "Cannot create $target_lib_dir"; return 1; }

  local binary_name
  binary_name="$(basename "$binary")"

  debug "Bundling libraries for $binary_name..."

  # Get all library dependencies (resolved paths)
  local libs
  libs="$(ldd "$binary" 2>/dev/null | grep '=>' | awk '{print $3}' | grep -v '^$' || true)"

  if [[ -z "$libs" ]]; then
    debug "$binary_name is statically linked or has no dependencies"
    return 0
  fi

  # Also get the dynamic linker
  local ld_linux
  ld_linux="$(ldd "$binary" 2>/dev/null | grep 'ld-linux' | awk '{print $1}' || true)"

  # Count total libraries
  local lib_count=0
  local total_size=0

  # Copy each library, preserving symlink structure
  while IFS= read -r lib_path; do
    [[ -z "$lib_path" ]] && continue

    # Resolve to actual file
    local real_lib
    real_lib="$(readlink -f "$lib_path")"

    # Get library filename
    local lib_name
    lib_name="$(basename "$lib_path")"
    local real_name
    real_name="$(basename "$real_lib")"

    # Copy the actual library file if not already present
    if [[ ! -f "$target_lib_dir/$real_name" ]]; then
      cp -L "$real_lib" "$target_lib_dir/$real_name" || { warn "Failed to copy $real_name"; continue; }
      chmod 755 "$target_lib_dir/$real_name"

      local size
      size="$(stat -c%s "$real_lib" 2>/dev/null || echo 0)"
      total_size=$((total_size + size))
      ((lib_count++))

      debug "  Copied: $real_name ($(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size}B"))"
    fi

    # Create symlink if library was accessed via symlink
    if [[ "$lib_name" != "$real_name" ]] && [[ ! -e "$target_lib_dir/$lib_name" ]]; then
      ln -s "$real_name" "$target_lib_dir/$lib_name" 2>/dev/null || true
      debug "  Symlink: $lib_name -> $real_name"
    fi
  done <<< "$libs"

  # Copy dynamic linker if present
  if [[ -n "$ld_linux" ]] && [[ -f "$ld_linux" ]]; then
    local ld_real
    ld_real="$(readlink -f "$ld_linux")"
    local ld_name
    ld_name="$(basename "$ld_linux")"
    local ld_real_name
    ld_real_name="$(basename "$ld_real")"

    # Create lib64 directory for ld-linux (standard location)
    local lib64_dir="${target_lib_dir%/lib}/lib64"
    mkdir -p "$lib64_dir" || true

    if [[ ! -f "$lib64_dir/$ld_real_name" ]]; then
      cp -L "$ld_real" "$lib64_dir/$ld_real_name" || warn "Failed to copy dynamic linker"
      chmod 755 "$lib64_dir/$ld_real_name"

      local ld_size
      ld_size="$(stat -c%s "$ld_real" 2>/dev/null || echo 0)"
      total_size=$((total_size + ld_size))

      debug "  Copied: $ld_real_name ($(numfmt --to=iec-i --suffix=B "$ld_size" 2>/dev/null || echo "${ld_size}B"))"
    fi

    # Create symlink if accessed via different name
    if [[ "$ld_name" != "$ld_real_name" ]] && [[ ! -e "$lib64_dir/$ld_name" ]]; then
      ln -s "$ld_real_name" "$lib64_dir/$ld_name" 2>/dev/null || true
      debug "  Symlink: $ld_name -> $ld_real_name"
    fi
  fi

  if [[ $lib_count -gt 0 ]]; then
    info "Bundled $lib_count libraries for $binary_name ($(numfmt --to=iec-i --suffix=B "$total_size" 2>/dev/null || echo "${total_size}B"))"
  fi

  return 0
}

# Verify bundled libraries work with binary
# Args: $1 = binary_path, $2 = lib_dir
verify_bundled_libs() {
  local binary="$1"
  local lib_dir="$2"

  debug "Verifying bundled libraries for $(basename "$binary")..."

  # Test with LD_LIBRARY_PATH
  if LD_LIBRARY_PATH="$lib_dir" ldd "$binary" 2>&1 | grep -q "not found"; then
    error "Missing libraries detected:"
    LD_LIBRARY_PATH="$lib_dir" ldd "$binary" 2>&1 | grep "not found"
    return 1
  fi

  debug "Library verification passed"
  return 0
}

# Main entry point for standalone usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <binary_path> <target_lib_dir> [verify]"
    echo ""
    echo "Bundle dynamic library dependencies for a binary into target directory."
    echo ""
    echo "Options:"
    echo "  verify  - Run verification check after bundling"
    exit 1
  fi

  bundle_binary_libs "$1" "$2" || exit 1

  if [[ "${3:-}" == "verify" ]]; then
    verify_bundled_libs "$1" "$2" || exit 1
  fi
fi
