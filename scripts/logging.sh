#!/usr/bin/env bash
# Common logging & error-handling helpers for Inferno scripts
# Keep this file minimal; do not alter shell options upon source.
# Consumers should opt-in to strict mode via set_error_handlers.
#
# VERSIONING
# ----------
# Per-file versioning helps us sync by copy/paste without ambiguity.
LOGGING_SH_VERSION="1.0.0"

# ---- Color/output config ----------------------------------------------------
# Respect NO_COLOR (https://no-color.org)
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  _CLR_GREEN=$'\033[0;32m'
  _CLR_RED=$'\033[0;31m'
  _CLR_YELLOW=$'\033[1;33m'
  _CLR_BLUE=$'\033[0;34m'
  _CLR_BOLD=$'\033[1m'
  _CLR_RESET=$'\033[0m'
else
  _CLR_GREEN='' ; _CLR_RED='' ; _CLR_YELLOW='' ; _CLR_BLUE='' ; _CLR_BOLD='' ; _CLR_RESET=''
fi

# LOG_LEVEL can be: DEBUG, INFO, WARN, ERROR (default INFO)
: "${LOG_LEVEL:=INFO}"
__log_level_to_num() {
  case "${1^^}" in
    DEBUG) printf '10';;
    INFO)  printf '20';;
    WARN)  printf '30';;
    ERROR) printf '40';;
    *)     printf '20';;
  esac
}
__LOG_THRESHOLD="$(__log_level_to_num "$LOG_LEVEL")"

__log_ts() {
  # ISO-8601 timestamp; prefer UTC when non-tty for easy grepping
  if [[ -t 2 ]]; then
    date '+%Y-%m-%d %H:%M:%S'
  else
    date -u '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

__should_log() {
  local lvl_num="$(__log_level_to_num "$1")"
  [[ "$lvl_num" -ge "$__LOG_THRESHOLD" ]]
}

# ---- Public logging functions -----------------------------------------------
log() {  # INFO
  __should_log INFO || return 0
  printf '%s%s[INFO]%s %s\n' "$_CLR_GREEN" "$_CLR_BOLD" "$_CLR_RESET" "$*" >&2
}
info() { log "$@"; }

warn() {
  __should_log WARN || return 0
  printf '%s[WARN]%s %s\n' "$_CLR_YELLOW" "$_CLR_RESET" "$*" >&2
}

error() {
  __should_log ERROR || true
  printf '%s[ERROR]%s %s\n' "$_CLR_RED" "$_CLR_RESET" "$*" >&2
}

debug() {
  __should_log DEBUG || return 0
  printf '%s[DEBUG]%s %s\n' "$_CLR_BLUE" "$_CLR_RESET" "$*" >&2
}

success() {
  __should_log INFO || return 0
  printf '%s[SUCCESS]%s %s\n' "$_CLR_GREEN" "$_CLR_RESET" "$*" >&2
}

die() {
  local code="${1:-1}"; shift || true
  error "$@"
  exit "$code"
}

# ---- Error handling helpers --------------------------------------------------
# Use set_error_handlers to enable strict mode and traps in the caller.
inferno_handle_err() {
  # args: code line cmd
  local code="${1:-1}" line="${2:-0}" cmd="${3:-?}"
  error "line ${line}: command failed with exit ${code}: ${cmd}"
}

# Backwards-compatible name used by older scripts:
handle_error() {
  # args: line code
  local line="${1:-0}" code="${2:-1}"
  error "Error on line ${line}: Command exited with status ${code}"
}

set_error_handlers() {
  # Enable: -e (fail fast), -E (ERR trap inheritance), pipefail.
  # Nounset (-u) is optional to avoid breaking scripts that read unset vars.
  # Set STRICT_NOUNSET=1 before calling to turn it on.
  set -Ee -o pipefail
  if [[ "${STRICT_NOUNSET:-0}" == "1" ]]; then
    set -u
  fi
  # ERR trap with more context (exit code, line, command)
  trap 'inferno_handle_err "$?" "${BASH_LINENO[0]:-0}" "${BASH_COMMAND:-?}"' ERR
  trap 'warn "Interrupted (SIGINT)"; exit 130' INT
  trap 'warn "Terminated (SIGTERM)"; exit 143' TERM
}

# ---- Version summary (optional) ---------------------------------------------
inferno_versions() {
  printf 'ENV_SH_VERSION=%s\n'    "${ENV_SH_VERSION:-unset}"
  printf 'CONFIG_SH_VERSION=%s\n' "${CONFIG_SH_VERSION:-unset}"
  printf 'HAPROXY_SH_VERSION=%s\n' "${HAPROXY_SH_VERSION:-unset}"
  printf 'LOGGING_SH_VERSION=%s\n' "${LOGGING_SH_VERSION:-unset}"
  # Add more as needed…
}

_inferno_socket="${INFERNO_ROOT}/logs/vm_logs.sock"

_log_to_vm_socket() {
  local line="$1"
  # best-effort; avoid blocking on errors
  if [[ -S "$_inferno_socket" ]]; then
    printf '%s\n' "$line" | socat - "UNIX-CONNECT:${_inferno_socket}" 2>/dev/null || true
  fi
}
