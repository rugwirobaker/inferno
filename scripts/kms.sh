#!/usr/bin/env bash
# KMS (Anubis) service management helpers for Inferno
# Provides functions to interact with the Anubis Key Management Service

KMS_SH_VERSION="1.0.0"

# Source logging functions if not already loaded
if [[ -z "${LOGGING_SH_VERSION:-}" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/logging.sh" || {
    echo >&2 "ERROR: Failed to source logging.sh"
    exit 1
  }
fi

# Default KMS socket path
: "${KMS_SOCKET_PATH:=/var/lib/anubis/anubis.sock}"

# ---- KMS Service Status ------------------------------------------------

# kms_is_running - Check if Anubis service is active
# Returns: 0 if running, 1 if not
kms_is_running() {
  if systemctl is-active --quiet anubis; then
    return 0
  else
    return 1
  fi
}

# kms_start - Start Anubis service
# Returns: 0 on success, 1 on failure
kms_start() {
  if kms_is_running; then
    debug "Anubis service already running"
    return 0
  fi

  info "Starting Anubis service..."
  if sudo systemctl start anubis; then
    sleep 1  # Give service time to create socket
    if kms_is_running; then
      info "Anubis service started successfully"
      return 0
    else
      error "Anubis service failed to start"
      return 1
    fi
  else
    error "Failed to start Anubis service"
    return 1
  fi
}

# kms_health_check - Test KMS HTTP API health endpoint
# Returns: 0 if healthy, 1 if not
kms_health_check() {
  local socket_path="${1:-$KMS_SOCKET_PATH}"

  if [[ ! -S "$socket_path" ]]; then
    error "KMS socket not found at $socket_path"
    return 1
  fi

  debug "Checking KMS health at $socket_path"

  local response
  response=$(curl --silent --unix-socket "$socket_path" \
    "http://unix/v1/sys/health" 2>&1)

  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    error "KMS health check failed: curl error $exit_code"
    return 1
  fi

  # Check if response contains "initialized":true
  if echo "$response" | grep -q '"initialized":true'; then
    debug "KMS health check passed"
    return 0
  else
    error "KMS health check failed: unexpected response"
    debug "Response: $response"
    return 1
  fi
}

# ---- KMS Key Operations ------------------------------------------------

# kms_store_key - Store encryption key in KMS
# Args:
#   $1 - volume_id (e.g., vol_01ARZ3NDEKTSV4RRFFQ69G5FAV)
#   $2 - base64-encoded encryption key
# Returns: 0 on success, 1 on failure
kms_store_key() {
  local volume_id="$1"
  local key="$2"
  local socket_path="${3:-$KMS_SOCKET_PATH}"

  if [[ -z "$volume_id" ]]; then
    error "kms_store_key: volume_id is required"
    return 1
  fi

  if [[ -z "$key" ]]; then
    error "kms_store_key: key is required"
    return 1
  fi

  debug "Storing encryption key for volume $volume_id"

  local kms_path="inferno/volumes/$volume_id/encryption-key"
  local response

  response=$(curl --silent --show-error --unix-socket "$socket_path" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "{\"data\": {\"key\": \"$key\", \"algorithm\": \"aes-xts-plain64\", \"key_size\": 512}}" \
    "http://unix/v1/secret/data/$kms_path" 2>&1)

  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    error "Failed to store key in KMS: curl error $exit_code"
    debug "Response: $response"
    return 1
  fi

  # Check if response contains success indicators
  if echo "$response" | grep -q '"version"'; then
    debug "Key stored successfully for $volume_id"
    return 0
  else
    error "Failed to store key in KMS: unexpected response"
    debug "Response: $response"
    return 1
  fi
}

# kms_get_key - Retrieve encryption key from KMS (for testing/debugging)
# Args:
#   $1 - volume_id (e.g., vol_01ARZ3NDEKTSV4RRFFQ69G5FAV)
# Returns: 0 and prints key on success, 1 on failure
kms_get_key() {
  local volume_id="$1"
  local socket_path="${2:-$KMS_SOCKET_PATH}"

  if [[ -z "$volume_id" ]]; then
    error "kms_get_key: volume_id is required"
    return 1
  fi

  debug "Retrieving encryption key for volume $volume_id"

  local kms_path="inferno/volumes/$volume_id/encryption-key"
  local response

  response=$(curl --silent --unix-socket "$socket_path" \
    "http://unix/v1/secret/data/$kms_path" 2>&1)

  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    error "Failed to retrieve key from KMS: curl error $exit_code"
    return 1
  fi

  # Extract key from JSON response
  local key
  key=$(echo "$response" | jq -r '.data.data.key // empty' 2>/dev/null)

  if [[ -z "$key" ]]; then
    error "Failed to extract key from KMS response"
    debug "Response: $response"
    return 1
  fi

  echo "$key"
  return 0
}

# kms_delete_key - Delete encryption key from KMS
# Args:
#   $1 - volume_id (e.g., vol_01ARZ3NDEKTSV4RRFFQ69G5FAV)
# Returns: 0 on success, 1 on failure
kms_delete_key() {
  local volume_id="$1"
  local socket_path="${2:-$KMS_SOCKET_PATH}"

  if [[ -z "$volume_id" ]]; then
    error "kms_delete_key: volume_id is required"
    return 1
  fi

  debug "Deleting encryption key for volume $volume_id"

  local kms_path="inferno/volumes/$volume_id/encryption-key"

  curl --silent --unix-socket "$socket_path" \
    -X DELETE \
    "http://unix/v1/secret/data/$kms_path" >/dev/null 2>&1

  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    debug "Key deleted successfully for $volume_id"
    return 0
  else
    error "Failed to delete key from KMS"
    return 1
  fi
}

# ---- KMS Socket Management ---------------------------------------------

# kms_link_socket - Bind mount KMS socket into chroot
# Args:
#   $1 - chroot directory path
# Returns: 0 on success, 1 on failure
#
# Note: We use bind mount instead of symlink because kiln runs in a chroot jail
# and cannot access paths outside the jail through symlinks.
kms_link_socket() {
  local chroot_dir="$1"
  local socket_path="${2:-$KMS_SOCKET_PATH}"

  if [[ -z "$chroot_dir" ]]; then
    error "kms_link_socket: chroot_dir is required"
    return 1
  fi

  if [[ ! -d "$chroot_dir" ]]; then
    error "Chroot directory does not exist: $chroot_dir"
    return 1
  fi

  if [[ ! -S "$socket_path" ]]; then
    error "KMS socket not found at $socket_path"
    return 1
  fi

  local target_path="$chroot_dir/kms.sock"

  # Create empty file as mount target if it doesn't exist
  if [[ ! -e "$target_path" ]]; then
    touch "$target_path" || {
      error "Failed to create mount target: $target_path"
      return 1
    }
  fi

  # Unmount if already mounted (cleanup from previous run)
  if mountpoint -q "$target_path" 2>/dev/null; then
    debug "Unmounting existing KMS socket bind mount"
    umount "$target_path" 2>/dev/null || true
  fi

  debug "Bind mounting KMS socket into chroot: $target_path <- $socket_path"

  # Bind mount the socket into the chroot
  if mount --bind "$socket_path" "$target_path"; then
    debug "KMS socket bind mounted successfully"
    return 0
  else
    error "Failed to bind mount KMS socket"
    return 1
  fi
}

# kms_unlink_socket - Unmount KMS socket from chroot
# Args:
#   $1 - chroot directory path
# Returns: 0 on success, 1 on failure
kms_unlink_socket() {
  local chroot_dir="$1"
  local target_path="$chroot_dir/kms.sock"

  if [[ ! -e "$target_path" ]]; then
    debug "KMS socket mount target does not exist: $target_path"
    return 0
  fi

  if mountpoint -q "$target_path" 2>/dev/null; then
    debug "Unmounting KMS socket from chroot: $target_path"
    if umount "$target_path" 2>/dev/null; then
      debug "KMS socket unmounted successfully"
    else
      warn "Failed to unmount KMS socket: $target_path"
      return 1
    fi
  else
    debug "KMS socket not mounted: $target_path"
  fi

  # Remove the empty file
  rm -f "$target_path" 2>/dev/null || true
  return 0
}

# ---- Verification Functions --------------------------------------------

# kms_verify_setup - Verify KMS service is properly configured
# Returns: 0 if setup is valid, 1 if not
kms_verify_setup() {
  local errors=0

  info "Verifying Anubis KMS setup..."

  # Check if service exists
  if ! systemctl list-unit-files | grep -q "anubis.service"; then
    error "Anubis service not installed"
    ((errors++))
  fi

  # Check if service is running
  if ! kms_is_running; then
    warn "Anubis service is not running"
    info "Start service with: sudo systemctl start anubis"
    ((errors++))
  fi

  # Check socket exists
  if [[ ! -S "$KMS_SOCKET_PATH" ]]; then
    error "KMS socket not found at $KMS_SOCKET_PATH"
    ((errors++))
  else
    # Check socket permissions
    local socket_perms
    socket_perms=$(stat -c "%a" "$KMS_SOCKET_PATH" 2>/dev/null)
    debug "KMS socket permissions: $socket_perms"
  fi

  # Test health endpoint
  if ! kms_health_check; then
    error "KMS health check failed"
    ((errors++))
  fi

  if [[ $errors -eq 0 ]]; then
    info "KMS setup verification passed"
    return 0
  else
    error "KMS setup verification failed with $errors error(s)"
    return 1
  fi
}
