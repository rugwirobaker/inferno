#!/usr/bin/env bash
# env.sh — global environment for Inferno scripts
# VERSION
ENV_SH_VERSION="1.1.0"

# NOTE: This file is meant to be *sourced*. Do not enable -e/-u/-o pipefail here.

# -------------------------------------------------------------------
# Resolve this script's directory even when the file is *sourced*
# -------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"

# -------------------------------------------------------------------
# Load system overrides from /etc/inferno/env (if present)
# This file is also sourced by the wrapper; doing it here keeps behavior
# consistent when scripts are sourced directly (e.g. during debugging).
# -------------------------------------------------------------------
if [[ -f /etc/inferno/env ]]; then
  # shellcheck disable=SC1091
  source /etc/inferno/env
fi

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
_expand_tilde() {
  # Expand ~ only if it appears at the beginning
  case "$1" in
    "~" | "~/"* )
      # shellcheck disable=SC2086
      eval echo $1
      ;;
    * ) echo "$1" ;;
  esac
}

# -------------------------------------------------------------------
# Core directories (with sane defaults)
# These can be overridden in /etc/inferno/env before we get here.
# -------------------------------------------------------------------
: "${INFERNO_ROOT:=/var/lib/inferno}"          # data root (VMs, DB, images, etc.)
: "${INFERNO_SHARE_DIR:=/usr/share/inferno}"   # shipped artifacts (kiln, init, firecracker, vmlinux)

# SCRIPTS_DIR defaults to the directory *this* file lives in (installed path)
: "${SCRIPTS_DIR:=$SCRIPT_DIR}"

# Expand possible tildes
INFERNO_ROOT="$(_expand_tilde "$INFERNO_ROOT")"
INFERNO_SHARE_DIR="$(_expand_tilde "$INFERNO_SHARE_DIR")"
SCRIPTS_DIR="$(_expand_tilde "$SCRIPTS_DIR")"

# -------------------------------------------------------------------
# Subpaths and files
# -------------------------------------------------------------------
: "${DB_PATH:=$INFERNO_ROOT/inferno.db}"
: "${VM_DIR:=$INFERNO_ROOT/vms}"
: "${IMAGES_DIR:=$INFERNO_ROOT/images}"

# LVM volume group used by libvol/database
: "${VG_NAME:=inferno_vg}"

# HAProxy defaults (used by haproxy.sh unless overridden)
: "${HAPROXY_CFG:=/etc/haproxy/haproxy.cfg}"
: "${HAPROXY_ENABLE:=1}"          # 1=managed by systemd reload/restart
: "${HAPROXY_MODE:=worker}"       # typical single-node dev; can be "none","worker","edge"
: "${HAPROXY_BIND:=auto}"         # auto|IP|0.0.0.0 (interpreted elsewhere)
: "${TS_DEV:=tailscale0}"         # for auto-binding on worker

# -------------------------------------------------------------------
# Export for downstream scripts
# -------------------------------------------------------------------
export SCRIPT_DIR
export SCRIPTS_DIR
export INFERNO_ROOT
export INFERNO_SHARE_DIR
export DB_PATH
export VM_DIR
export IMAGES_DIR
export VG_NAME
export HAPROXY_CFG
export HAPROXY_ENABLE
export HAPROXY_MODE
export HAPROXY_BIND
export TS_DEV

# Optional debug breadcrumb (prints only if a debug() logger exists)
type debug >/dev/null 2>&1 && debug "Loaded env.sh v${ENV_SH_VERSION} (SCRIPTS_DIR=${SCRIPTS_DIR}, INFERNO_ROOT=${INFERNO_ROOT})"
