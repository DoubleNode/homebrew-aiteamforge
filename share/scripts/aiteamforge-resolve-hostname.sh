#!/bin/bash
# Resolve the display hostname for this Mac.
#
# Preference order:
#   1. Tailscale machine name (stable, user-controlled, matches team-connect
#      host arguments — "darren-m4-mini")
#   2. `hostname -s` with .local suffix stripped (fallback for machines
#      without Tailscale or with tailscaled stopped)
#
# Used by:
#   - LCARS server.py (subprocess from Python, at module load time)
#   - Per-agent tmux startup scripts (bash, at session-creation time, to
#     set tmux status-right to a string consistent with what appears in
#     the LCARS header on the same machine)
#
# Keep this script side-effect-free and fast. Timeouts are hard-capped at
# 3 seconds so a stuck tailscaled daemon cannot hang team startup or
# delay LCARS server launch.
#
# Writes exactly one line to stdout: the resolved hostname. Exit code is
# always 0 — failures fall through to hostname -s.

set -u

_tailscale_binary() {
    if command -v tailscale >/dev/null 2>&1; then
        command -v tailscale
        return
    fi
    local _app_path="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    if [ -x "$_app_path" ]; then
        printf '%s\n' "$_app_path"
    fi
}

_tailscale_hostname() {
    local _ts
    _ts=$(_tailscale_binary)
    [ -z "$_ts" ] && return 1

    local _json
    # 3s hard cap — tailscaled can stall on login/coordination issues
    _json=$( (
        "$_ts" status --json --self=true 2>/dev/null &
        local _pid=$!
        ( sleep 3 && kill -KILL "$_pid" 2>/dev/null ) &
        local _watchdog=$!
        wait "$_pid" 2>/dev/null
        kill "$_watchdog" 2>/dev/null
    ) )
    [ -z "$_json" ] && return 1

    # Extract .Self.HostName. Prefer python3 (reliable JSON); fall back to
    # a grep-based extractor for systems without python3 on PATH.
    local _name=""
    if command -v python3 >/dev/null 2>&1; then
        _name=$(printf '%s' "$_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    self_info = d.get("Self") or {}
    name = self_info.get("HostName") or ""
    print(name, end="")
except Exception:
    pass
' 2>/dev/null)
    else
        # Naive fallback: first HostName field in Self block
        _name=$(printf '%s' "$_json" | awk '
            /"Self"/ { in_self = 1 }
            in_self && /"HostName"/ {
                match($0, /"HostName"[[:space:]]*:[[:space:]]*"[^"]*"/)
                if (RSTART) {
                    s = substr($0, RSTART, RLENGTH)
                    sub(/.*"HostName"[[:space:]]*:[[:space:]]*"/, "", s)
                    sub(/".*/, "", s)
                    print s
                    exit
                }
            }
        ')
    fi

    if [ -n "$_name" ]; then
        printf '%s\n' "$_name"
        return 0
    fi
    return 1
}

_fallback_hostname() {
    local _h
    _h=$(hostname -s 2>/dev/null)
    [ -z "$_h" ] && _h=$(hostname 2>/dev/null)
    # Strip .local if present (some macOS configurations return FQDN)
    _h="${_h%.local}"
    printf '%s\n' "$_h"
}

_name=""
_name=$(_tailscale_hostname) || true
if [ -z "$_name" ]; then
    _name=$(_fallback_hostname)
fi
printf '%s\n' "$_name"
