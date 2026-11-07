#!/usr/bin/env bash
# aitf-root.sh — shared root resolver for the Claude Code hooks (XACA-1753-001).
#
# SOURCED by each hook, never executed. ONE copy, so the lookup cannot drift
# between seven hooks (the sibling-heuristic drift this epic fights). bash 3.2
# and zsh compatible; touches no global shell options; defines only aitf_*
# names and AITF_* variables.
#
# WHY IT EXISTS: the hooks used to hardcode the legacy checkout path. That path is a
# real checkout only on M3Pro; on ai-sol it is an empty stub and on a tap
# consumer it does not exist, so C2-C6 exited 0 silently (a fail-open all-clear).
#
# THREE LAYOUTS (the hook, this file, and shipped checkers are SIBLINGS in the
# two shipped layouts; in the dev tree checkers live one level up in scripts/):
#   dev tree   <repo>/claude-hooks/<hook> + aitf-root.sh
#              <repo>/scripts/<checker>   <repo>/kanban-helpers.sh
#   tap        homebrew-tap/share/scripts/<hook> + aitf-root.sh + <checker>
#   installed  ~/aiteamforge/scripts/<hook> + aitf-root.sh + <checker>
#              ~/aiteamforge/kanban-helpers.sh
# The tap layout is a delivery staging area, not an execution root.
#
# API
#   aitf_init <path-to-hook>   once, right after sourcing. Sets AITF_HOOK_DIR
#                              (absolute, symlinks resolved).
#   aitf_locate <relpath>      relpath is relative to a root, e.g.
#                              "scripts/kb-gh-credential-check.sh" or
#                              "kanban-helpers.sh". Sets AITF_FOUND to the first
#                              existing regular file and returns 0, or sets it
#                              empty and returns 1. Either way AITF_LOOKED holds
#                              every candidate tried (", "-separated), for
#                              "could not check: ... (looked in ...)". Prints
#                              nothing: call it WITHOUT $(...), a subshell
#                              would discard the variables.
#   Candidate order: the hook's own location (siblings for "scripts/X", then
#   <hook dir>/../<relpath>), then $AITEAMFORGE_DIR, then the legacy checkout
#   fallback (the ONLY place a hardcoded dev-team path is allowed to live, kept
#   so M3Pro's real checkout keeps working), then the default installed home.

AITF_HOOK_DIR=""
AITF_LOOKED=""
AITF_FOUND=""

# Resolve symlinks portably (no readlink -f dependency).
_aitf_resolve_file() {
    local _f="$1" _l _d
    while [ -L "$_f" ]; do
        _l="$(readlink "$_f")"
        case "$_l" in
            /*) _f="$_l" ;;
            *) _d="$(dirname "$_f")"; _f="$_d/$_l" ;;
        esac
    done
    printf '%s' "$_f"
}

aitf_init() {
    local _self _d
    _self="$(_aitf_resolve_file "${1:-}")"
    _d="$(cd "$(dirname "$_self")" 2>/dev/null && pwd)" || _d=""
    AITF_HOOK_DIR="$_d"
    AITF_LOOKED=""
    return 0
}

aitf_locate() {
    local _rel="${1:-}" _c _root
    local _cands=()
    AITF_LOOKED=""
    AITF_FOUND=""
    [ -n "$_rel" ] || return 1
    if [ -n "${AITF_HOOK_DIR:-}" ]; then
        case "$_rel" in
            scripts/*) _cands+=("$AITF_HOOK_DIR/${_rel#scripts/}") ;;
        esac
        _cands+=("$AITF_HOOK_DIR/../$_rel")
    fi
    if [ -n "${AITEAMFORGE_DIR:-}" ]; then
        _cands+=("$AITEAMFORGE_DIR/$_rel")
    fi
    # Documented fallbacks: legacy checkout (M3Pro), then default installed home.
    _cands+=("$HOME/dev-team/$_rel" "$HOME/aiteamforge/$_rel")
    for _c in "${_cands[@]}"; do
        if [ -z "$AITF_LOOKED" ]; then AITF_LOOKED="$_c"; else AITF_LOOKED="$AITF_LOOKED, $_c"; fi
    done
    for _c in "${_cands[@]}"; do
        if [ -f "$_c" ]; then
            AITF_FOUND="$_c"
            return 0
        fi
    done
    return 1
}
