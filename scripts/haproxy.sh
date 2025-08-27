#!/usr/bin/env bash
# HAProxy helpers for L7 publish/unpublish
# Requires: haproxy, sqlite3, jq
HAPROXY_SH_VERSION="0.2.2"
# Changes:
# - Switch to per-file version var: HAPROXY_SH_VERSION (to match ENV_SH_VERSION/CONFIG_SH_VERSION scheme).
# - Keeps v0.2.x fixes: relative sourcing, no database.sh dependency, safe base config, default backend.

# Resolve this file's directory correctly even when *sourced*
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# Load shared libs (env first so DB_PATH etc. exist)
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/env.sh" ]] && source "${SCRIPT_DIR}/env.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/env.sh"     ]] && source "${SCRIPT_DIR}/env.sh"
# shellcheck disable=SC1091
[[ -f "${SCRIPT_DIR}/logging.sh" ]] && source "${SCRIPT_DIR}/logging.sh"
# NOTE: database.sh is intentionally NOT sourced here.

HAPROXY_CFG="${HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"

# Marker blocks
HAPROXY_FE_START="# BEGIN-INFERNO"
HAPROXY_FE_END="# END-INFERNO"
HAPROXY_BE_START="# BEGIN-INFERNO-BE"
HAPROXY_BE_END="# END-INFERNO-BE"

haproxy_required_or_die() {
    if ! command -v haproxy >/dev/null 2>&1; then
        error "HAProxy is required for L7 mode"
        return 1
    fi
    return 0
}

# Create a sane base config (or minimally repair) with FE/BE markers
haproxy_prepare_base_config() {
    local dir; dir="$(dirname "$HAPROXY_CFG")"
    mkdir -p "$dir"

    if [[ ! -f "$HAPROXY_CFG" ]]; then
        log "Creating base HAProxy config at $HAPROXY_CFG"
        cat >"$HAPROXY_CFG" <<'CFG'
global
    daemon
    user haproxy
    group haproxy
    maxconn 4096
    stats socket /run/haproxy/admin.sock mode 660 level admin

defaults
    mode http
    timeout connect 5s
    timeout client  30s
    timeout server  30s

# L7 entrypoint managed by Inferno:
frontend inferno_http
    bind *:80
    # Set headers first
    http-request set-header X-Forwarded-Proto https if { ssl_fc }
    http-request set-header X-Forwarded-Proto http  if !{ ssl_fc }
    default_backend _default_404
    # BEGIN-INFERNO
    # END-INFERNO

# Inferno-managed backends:
# BEGIN-INFERNO-BE
# END-INFERNO-BE

backend _default_404
    http-request deny deny_status 404
CFG
        return 0
    fi

    # If file exists, ensure the two marker regions are present in correct places.
    cp -a "$HAPROXY_CFG" "$HAPROXY_CFG.bak.$(date +%s)"

    # Ensure a frontend exists; if none, append a minimal one
    if ! grep -qE '^[[:space:]]*frontend[[:space:]]+inferno_http(\s|$)' "$HAPROXY_CFG"; then
        cat >>"$HAPROXY_CFG" <<'CFG'

# L7 entrypoint managed by Inferno:
frontend inferno_http
    bind *:80
    http-request set-header X-Forwarded-Proto https if { ssl_fc }
    http-request set-header X-Forwarded-Proto http  if !{ ssl_fc }
    default_backend _default_404
    # BEGIN-INFERNO
    # END-INFERNO
CFG
    fi

    # Make sure FE markers exist *inside* the inferno_http frontend (after first bind)
    if ! grep -q "$HAPROXY_FE_START" "$HAPROXY_CFG"; then
        awk -v fe_start="$HAPROXY_FE_START" -v fe_end="$HAPROXY_FE_END" '
          BEGIN{infe=0; inserted=0}
          /^[ \t]*frontend[ \t]+inferno_http(\s|$)/ {infe=1}
          infe && /^[ \t]*bind[ \t]/ {
              print
              if(!inserted){
                  print "    " fe_start
                  print "    " fe_end
                  inserted=1
              }
              next
          }
          infe && /^[ \t]*backend[ \t]/ {infe=0}
          {print}
        ' "$HAPROXY_CFG" > "${HAPROXY_CFG}.tmp" && mv "${HAPROXY_CFG}.tmp" "$HAPROXY_CFG"
    fi

    # Ensure FE has a default backend (avoid 503 if nothing matches)
    if grep -qE '^[ \t]*frontend[ \t]+inferno_http' "$HAPROXY_CFG" && \
       ! awk '/^[ \t]*frontend[ \t]+inferno_http/{f=1} f && /^[ \t]*default_backend[ \t]+/{print; exit}' "$HAPROXY_CFG" >/dev/null; then
        awk '
          BEGIN{infe=0}
          /^[ \t]*frontend[ \t]+inferno_http(\s|$)/ {infe=1}
          infe && /^[ \t]*http-request[ \t]+set-header[ \t]+X-Forwarded-Proto/ && !added {
              print
              print "    default_backend _default_404"
              added=1; next
          }
          infe && /^[ \t]*backend[ \t]/ {infe=0}
          {print}
        ' "$HAPROXY_CFG" > "${HAPROXY_CFG}.tmp" && mv "${HAPROXY_CFG}.tmp" "$HAPROXY_CFG"
    fi

    # Ensure BE marker block exists (append once at EOF)
    if ! grep -q "$HAPROXY_BE_START" "$HAPROXY_CFG"; then
        printf '\n# Inferno-managed backends:\n%s\n%s\n' "$HAPROXY_BE_START" "$HAPROXY_BE_END" >> "$HAPROXY_CFG"
    fi

    # Ensure fallback backend exists
    if ! grep -qE '^[ \t]*backend[ \t]+_default_404(\s|$)' "$HAPROXY_CFG"; then
        cat >>"$HAPROXY_CFG" <<'CFG'

backend _default_404
    http-request deny deny_status 404
CFG
    fi
}

# Escape dots etc. for regex matching host header with optional :port
_haproxy_escape_re() { printf '%s' "$1" | sed -e 's/[.[*^$()+?{}|\\]/\\&/g'; }

haproxy_render_routes_from_db() {
    # Build FE and BE snippets from active L7 routes
    local json tmp
    tmp="$(mktemp)"; trap 'rm -f "$tmp"' RETURN

    sqlite3 "$DB_PATH" -json "
      SELECT
        r.hostname,
        r.guest_port,
        v.name      AS vm_name,
        v.guest_ip  AS guest_ip
      FROM routes r
      JOIN vms v ON v.id = r.vm_id
      WHERE r.active = 1 AND r.mode = 'l7' AND r.hostname IS NOT NULL;
    " >"$tmp" || { error "Failed to read routes from DB"; return 1; }
    json="$(cat "$tmp")"

    local fe_snip="" be_snip=""
    if jq -e 'length>0' >/dev/null 2>&1 <<<"$json"; then
        while IFS= read -r row; do
            local host gport vip vname esc name
            host="$(jq -r '.hostname'   <<<"$row")"
            gport="$(jq -r '.guest_port'<<<"$row")"
            vip="$(jq -r   '.guest_ip'  <<<"$row")"
            vname="$(jq -r '.vm_name'   <<<"$row")"
            name="$(printf '%s' "$host" | tr -c 'A-Za-z0-9' '_')"
            esc="$(_haproxy_escape_re "$host")"

            fe_snip+="    acl host_${name} hdr(host) -m reg -i ^${esc}(:[0-9]+)?$\n"
            fe_snip+="    use_backend be_${name} if host_${name}\n"

            be_snip+=$'\n'"backend be_${name}"$'\n'
            be_snip+="    server ${vname} ${vip}:${gport} check"$'\n'
        done < <(jq -c '.[]' <<<"$json")
    fi

    # Replace FE and BE blocks in one awk pass
    awk -v fe_start="$HAPROXY_FE_START" -v fe_end="$HAPROXY_FE_END" \
        -v be_start="$HAPROXY_BE_START" -v be_end="$HAPROXY_BE_END" \
        -v fe_snip="$fe_snip" -v be_snip="$be_snip" '
        BEGIN{infe=0; inbe=0}
        $0 ~ fe_start { print; printf "%s", fe_snip; infe=1; next }
        $0 ~ fe_end   { print; infe=0; next }
        $0 ~ be_start { print; printf "%s", be_snip; inbe=1; next }
        $0 ~ be_end   { print; inbe=0; next }
        { if(!infe && !inbe) print }
    ' "$HAPROXY_CFG" > "${HAPROXY_CFG}.new" || return 1

    haproxy -c -f "${HAPROXY_CFG}.new" || {
        rm -f "${HAPROXY_CFG}.new"
        error "HAProxy config validation failed"
        return 1
    }

    install -m 0644 "${HAPROXY_CFG}.new" "$HAPROXY_CFG"
    rm -f "${HAPROXY_CFG}.new"
}

haproxy_reload() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reload haproxy || systemctl restart haproxy
    else
        local pidfile=/run/haproxy.pid
        if [[ -f $pidfile ]]; then
            haproxy -f "$HAPROXY_CFG" -sf "$(cat "$pidfile")"
        else
            haproxy -D -f "$HAPROXY_CFG" -p "$pidfile"
        fi
    fi
}
