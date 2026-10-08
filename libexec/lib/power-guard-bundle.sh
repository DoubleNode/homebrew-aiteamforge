#!/bin/bash
# power-guard-bundle.sh
# DoubleNode Dev-Team Infrastructure (AITeamForge)
#
# XACA-1394-005 (EPIC-0067 UPS power-guard): places the power-guard root
# LaunchDaemon bundle under $AITEAMFORGE_DIR/scripts/power-guard/ and tells the
# operator how to activate it. Shared VERBATIM between install-shell.sh (fresh
# installs) and aiteamforge-upgrade.sh (already-installed machines) so the two
# paths cannot drift -- the same shape as lib/ci-runner-bundle.sh (XACA-1443).
#
# NEVER ACTIVATES ANYTHING. The daemon runs as ROOT, so installing it needs a
# one-time password the installer must not ask for. This file only COPIES FILES
# and PRINTS a command. It must never:
#   * run sudo, launchctl, or install-power-guard.sh itself,
#   * prompt for a password,
#   * write under /Library or /usr/local.
# tests/test-xaca-1394-005-power-guard-wiring.sh enforces this with PATH shims
# and mutation controls; keep it passing when editing.
#
# Layout (the subdirectory is why neither setup's flat `find -maxdepth 1` copy
# nor update_runtime_helpers' flat *.sh sweep reaches these files):
#   scripts/power-guard/install-power-guard.sh
#   scripts/power-guard/power-guard-daemon.template.plist
#   scripts/power-guard/power-guard-policy.example.json   (DISARMED: enabled=false, dry_run=true)
#   scripts/power-guard/client/{power-guard-runner.py,power-guard.py}
# install-power-guard.sh copies client/* into a ROOT-OWNED dir
# (/usr/local/libexec/aiteamforge/power-guard) that root executes. A non-root
# upgrade therefore cannot refresh that copy: when the daemon is installed and
# the root copy differs from the freshly placed client/, the upgrade prints the
# exact re-run command instead. List must match sync-tap.sh's XACA-1394-005 block.
#
# TEST SEAMS: PG_LAUNCHD_DIR and PG_LIBEXEC_DIR are honoured ONLY when
# PG_TESTING=1 (the same seams install-power-guard.sh honours).
#
# Bash 3.2 compatible.

# Relative path (under power-guard/) and mode, one per line: "<mode> <relpath>".
_aitf_power_guard_bundle_files() {
    cat <<'LIST'
755 install-power-guard.sh
644 power-guard-daemon.template.plist
644 power-guard-policy.example.json
755 client/power-guard-runner.py
755 client/power-guard.py
LIST
}

# Where the installed daemon's plist and root-owned payload live.
_aitf_power_guard_launchd_dir() {
    if [ "${PG_TESTING:-}" = "1" ] && [ -n "${PG_LAUNCHD_DIR:-}" ]; then
        printf '%s\n' "$PG_LAUNCHD_DIR"
    else
        printf '%s\n' "/Library/LaunchDaemons"
    fi
}
_aitf_power_guard_libexec_dir() {
    if [ "${PG_TESTING:-}" = "1" ] && [ -n "${PG_LIBEXEC_DIR:-}" ]; then
        printf '%s\n' "$PG_LIBEXEC_DIR"
    else
        printf '%s\n' "/usr/local/libexec/aiteamforge/power-guard"
    fi
}
_aitf_power_guard_plist() {
    printf '%s/com.aiteamforge.power-guard.plist\n' "$(_aitf_power_guard_launchd_dir)"
}

# _aitf_install_power_guard_bundle <scripts_src> <scripts_dest> [dry_run]
#   scripts_src  = <share>/scripts   scripts_dest = $AITEAMFORGE_DIR/scripts
# Always (re)writes present files (a stale sibling is the same bug as a missing
# one, XACA-1322). Fail-soft: a missing source is skipped, never aborts the
# install/upgrade. Sets AITF_PG_BUNDLE_COUNT to the number of files placed.
_aitf_install_power_guard_bundle() {
    local src_root="${1:-}/power-guard" dest_root="${2:-}/power-guard" dry="${3:-}"
    local mode rel dest
    AITF_PG_BUNDLE_COUNT=0
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
    [ -d "$src_root" ] || return 0
    while read -r mode rel; do
        [ -n "$rel" ] || continue
        [ -f "$src_root/$rel" ] || continue
        dest="$dest_root/$rel"
        if [ -n "$dry" ]; then
            echo "Would update: scripts/power-guard/${rel}"
        else
            mkdir -p "$(dirname "$dest")" || continue
            cp "$src_root/$rel" "$dest" || continue
            chmod "$mode" "$dest"
        fi
        AITF_PG_BUNDLE_COUNT=$((AITF_PG_BUNDLE_COUNT + 1))
    done <<EOF_BUNDLE
$(_aitf_power_guard_bundle_files)
EOF_BUNDLE
    return 0
}

# _aitf_power_guard_payload_stale <scripts_dest>
#   rc 0 = the root-owned payload is missing or differs from scripts/power-guard/client
#   rc 1 = every payload file is byte-identical (nothing to refresh)
_aitf_power_guard_payload_stale() {
    local client="${1:-}/power-guard/client" root f
    root="$(_aitf_power_guard_libexec_dir)"
    for f in power-guard-runner.py power-guard.py; do
        [ -f "$client/$f" ] || continue
        cmp -s "$client/$f" "$root/$f" || return 0
    done
    return 1
}

# _aitf_power_guard_offer <scripts_dest>
# FRESH INSTALL. Prints, never executes. Daemon absent -> the one-time offer;
# daemon already present (a re-run of setup) -> the same refresh notice the
# upgrade prints. Silent when the bundle was not placed.
_aitf_power_guard_offer() {
    local installer="${1:-}/power-guard/install-power-guard.sh"
    [ -f "$installer" ] || return 0
    if [ -f "$(_aitf_power_guard_plist)" ]; then
        _aitf_power_guard_upgrade_notice "${1:-}"
        return 0
    fi
    echo ""
    echo "Optional: UPS power-guard (graceful shutdown on UPS battery) is staged but NOT installed."
    echo "  It runs as a root LaunchDaemon, so it needs your password once. To install it:"
    echo "    sudo bash \"${installer}\" install"
    echo "  It installs DISARMED (enabled=false, dry_run=true); it only acts after a drill arms it."
    return 0
}

# _aitf_power_guard_upgrade_notice <scripts_dest>
# UPGRADE. Silent unless the daemon is installed AND its root-owned payload is
# stale. Prints the exact re-run; never runs it (needs root, upgrades do not).
_aitf_power_guard_upgrade_notice() {
    local installer="${1:-}/power-guard/install-power-guard.sh"
    [ -f "$installer" ] || return 0
    [ -f "$(_aitf_power_guard_plist)" ] || return 0
    _aitf_power_guard_payload_stale "${1:-}" || return 0
    echo ""
    echo "UPS power-guard: the installed root daemon is running an OLDER payload than this release."
    echo "  An upgrade cannot refresh root-owned files. Re-run the installer once (password required):"
    echo "    sudo bash \"${installer}\" install"
    echo "  Your policy file is never touched by a re-run; an armed guard stays armed."
    return 0
}
