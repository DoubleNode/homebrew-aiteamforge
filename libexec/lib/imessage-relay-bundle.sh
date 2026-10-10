#!/bin/bash
# imessage-relay-bundle.sh
# DoubleNode Dev-Team Infrastructure (AITeamForge)
#
# XACA-1402-011 (EPIC-0068 iMessage notify provider): places the opt-in iMessage
# relay bundle under $AITEAMFORGE_DIR/scripts/imessage-relay/ and tells the
# operator how to activate it. Shared VERBATIM between install-shell.sh (fresh
# installs) and aiteamforge-upgrade.sh (already-installed machines) so the two
# paths cannot drift -- the same shape as lib/power-guard-bundle.sh (XACA-1394-005).
# The bundle is a SUBDIRECTORY of share/scripts/, which is why neither setup's flat
# `find -maxdepth 1` copy nor update_runtime_helpers' flat sweep reaches it.
#
# NEVER ACTIVATES ANYTHING. The relay is an opt-in LaunchAgent that needs a Mac with
# Messages signed in. This file only COPIES FILES and PRINTS a command. It must
# never run launchctl, install-imessage-relay.sh, osascript, node or sudo.
# tests/test-xaca-1402-011-imessage-relay-wiring.sh enforces this with PATH shims,
# a static audit and a mutation control; keep it passing when editing.
#
# Layout:
#   scripts/imessage-relay/install-imessage-relay.sh
#   scripts/imessage-relay/imessage-relay.template.plist
#   scripts/imessage-relay/client/imessage-relay.js
# install-imessage-relay.sh copies client/imessage-relay.js to
# $AITEAMFORGE_DIR/scripts/imessage-relay.js (the RUNNING copy) and renders the plist
# into ~/Library/LaunchAgents. An upgrade refreshes only the staged client/; when the
# agent is installed and the running copy differs, the upgrade prints the re-run
# command (a re-run IS the upgrade). List must match sync-tap.sh's XACA-1402-011 block
# one-for-one.
#
# TEST SEAM: IR_LAUNCHD_DIR (the name install-imessage-relay.sh honours; IR_LAUNCHAGENTS_DIR
# is accepted as an alias) is honoured ONLY when IR_TESTING=1.
#
# Bash 3.2 compatible.

# "<mode> <relpath>" one per line, relative to imessage-relay/.
_aitf_imessage_relay_bundle_files() {
    cat <<'LIST'
755 install-imessage-relay.sh
644 imessage-relay.template.plist
644 client/imessage-relay.js
LIST
}

_aitf_imessage_relay_launchagents_dir() {
    if [ "${IR_TESTING:-}" = "1" ] && [ -n "${IR_LAUNCHD_DIR:-}" ]; then
        printf '%s\n' "$IR_LAUNCHD_DIR"
    elif [ "${IR_TESTING:-}" = "1" ] && [ -n "${IR_LAUNCHAGENTS_DIR:-}" ]; then
        printf '%s\n' "$IR_LAUNCHAGENTS_DIR"
    else
        printf '%s\n' "$HOME/Library/LaunchAgents"
    fi
}
_aitf_imessage_relay_plist() {
    printf '%s/com.aiteamforge.imessage-relay.plist\n' "$(_aitf_imessage_relay_launchagents_dir)"
}

# _aitf_install_imessage_relay_bundle <scripts_src> <scripts_dest> [dry_run]
#   scripts_src = <share>/scripts   scripts_dest = $AITEAMFORGE_DIR/scripts
# Always (re)writes present files (XACA-1322). Fail-soft: a missing source is
# skipped, never aborts. Sets AITF_IR_BUNDLE_COUNT to the number of files placed.
_aitf_install_imessage_relay_bundle() {
    local src_root="${1:-}/imessage-relay" dest_root="${2:-}/imessage-relay" dry="${3:-}"
    local mode rel dest
    AITF_IR_BUNDLE_COUNT=0
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
    [ -d "$src_root" ] || return 0
    while read -r mode rel; do
        [ -n "$rel" ] || continue
        [ -f "$src_root/$rel" ] || continue
        dest="$dest_root/$rel"
        if [ -n "$dry" ]; then
            echo "Would update: scripts/imessage-relay/${rel}"
        else
            mkdir -p "$(dirname "$dest")" || continue
            cp "$src_root/$rel" "$dest" || continue
            chmod "$mode" "$dest"
        fi
        AITF_IR_BUNDLE_COUNT=$((AITF_IR_BUNDLE_COUNT + 1))
    done <<EOF_BUNDLE
$(_aitf_imessage_relay_bundle_files)
EOF_BUNDLE
    return 0
}

# _aitf_imessage_relay_offer <scripts_dest>
# FRESH INSTALL. Prints, never executes. Agent absent -> the one-time offer;
# agent already present (a re-run of setup) -> the upgrade notice. Silent when
# the bundle was not placed.
_aitf_imessage_relay_offer() {
    local installer="${1:-}/imessage-relay/install-imessage-relay.sh"
    [ -f "$installer" ] || return 0
    if [ -f "$(_aitf_imessage_relay_plist)" ]; then
        _aitf_imessage_relay_upgrade_notice "${1:-}"
        return 0
    fi
    echo ""
    echo "Optional: the iMessage relay is staged but NOT installed. To opt in, run:"
    echo "    bash \"${installer}\" install --opt-in"
    echo "  It is opt-in and needs the Messages app signed in to iMessage on this Mac."
    return 0
}

# _aitf_imessage_relay_upgrade_notice <scripts_dest>
# UPGRADE. Silent unless the LaunchAgent is installed AND the running relay
# (<scripts_dest>/imessage-relay.js) differs from the freshly placed client/ copy.
_aitf_imessage_relay_upgrade_notice() {
    local installer="${1:-}/imessage-relay/install-imessage-relay.sh"
    local staged="${1:-}/imessage-relay/client/imessage-relay.js"
    local running="${1:-}/imessage-relay.js"
    [ -f "$installer" ] || return 0
    [ -f "$staged" ] || return 0
    [ -f "$(_aitf_imessage_relay_plist)" ] || return 0
    cmp -s "$staged" "$running" && return 0
    echo ""
    echo "iMessage relay: the installed relay is running an OLDER copy than this release."
    echo "  Re-run the installer once to refresh it (a re-run is the upgrade):"
    echo "    bash \"${installer}\" install --opt-in"
    return 0
}
