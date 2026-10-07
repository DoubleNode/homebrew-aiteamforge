#!/bin/bash
# ci-runner-bundle.sh
# DoubleNode Dev-Team Infrastructure (AITeamForge)
#
# XACA-1443-001: places the DORMANT Fleet CI Pool provisioning bundle under
# $AITEAMFORGE_DIR/scripts/ci-runner/ so `aiteamforge ci enable` (XACA-1443-002)
# can provision a customer host later. Shared VERBATIM between install-shell.sh
# (fresh installs) and aiteamforge-upgrade.sh (already-installed machines) so
# the two paths cannot drift -- the install-only-reaches-fresh-installs class
# (XACA-0747/0751/0814/1078-004/1449; same shape as msg-client-deps.sh).
#
# DORMANT BY CONTRACT. This file only COPIES FILES. It must never:
#   * execute provision-host.sh / create-ci-runner-user.sh / ci-host.sh,
#   * call sudo, dscl, sysadminctl, launchctl, limactl, tart, curl or gh,
#   * write a plist, create a user, start a VM, or register a GitHub runner.
# Activation is an explicit, operator-driven `aiteamforge ci enable`.
# tests/test-xaca-1443-dormant-ship.sh enforces this with PATH shims and a
# mutation control; keep it passing when editing.
#
# Layout (the subdirectory is why neither setup's flat `find -maxdepth 1` copy
# nor update_runtime_helpers' flat *.sh sweep reaches these files):
#   scripts/ci-runner/{provision-host.sh,ci-host.sh,create-ci-runner-user.sh,teardown-host.sh}
#   scripts/ci-runner/lib/{ci-host-lib.sh,ci-enable-guard.sh,ci-headroom.sh,ci-provision-version.sh,ci-runner-version.sh,ci-status.sh}
#   scripts/ci-runner/runner-pin.conf   (data: pinned fallback actions/runner + registration floor, XACA-1443-014)
#   scripts/ci-runner/client/{ci-pool-agent.py,ci-runner-*.sh}
# provision-host.sh resolves its client payload by provenance (XACA-1443-016):
# the sibling ${its dir}/client wins whenever it exists (only this shipped
# bundle has one); the dev tree's ../../fleet-monitor/client is used only when
# the checkout carries the .aiteamforge-source-tree sentinel. A customer's
# $AITEAMFORGE_DIR/fleet-monitor/client (fleet reporter) is never used.
# NOT shipped: provision-m1mini.sh
# (M1Mini-specific), spike*.sh (research). List must match sync-tap.sh's
# XACA-1443-001 block.

# Relative path (under ci-runner/) and mode, one per line: "<mode> <relpath>".
_aitf_ci_runner_bundle_files() {
    cat <<'LIST'
755 provision-host.sh
755 ci-host.sh
755 create-ci-runner-user.sh
755 teardown-host.sh
644 runner-pin.conf
755 lib/ci-host-lib.sh
644 lib/ci-enable-guard.sh
644 lib/ci-headroom.sh
644 lib/ci-provision-version.sh
644 lib/ci-runner-version.sh
644 lib/ci-status.sh
644 client/ci-pool-agent.py
755 client/ci-runner-jit-guest.sh
755 client/ci-runner-jit-macos.sh
755 client/ci-runner-job-started.sh
755 client/ci-runner-reporter.sh
LIST
}

# _aitf_install_ci_runner_bundle <scripts_src> <scripts_dest> [dry_run]
#   scripts_src  = <share>/scripts   scripts_dest = $AITEAMFORGE_DIR/scripts
# Always (re)writes present files (a stale sibling is the same bug as a missing
# one, XACA-1322). Fail-soft: a missing source is skipped, never aborts the
# install/upgrade. Sets AITF_CI_BUNDLE_COUNT to the number of files placed.
_aitf_install_ci_runner_bundle() {
    local src_root="${1:-}/ci-runner" dest_root="${2:-}/ci-runner" dry="${3:-}"
    local mode rel dest
    AITF_CI_BUNDLE_COUNT=0
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
    [ -d "$src_root" ] || return 0
    while read -r mode rel; do
        [ -n "$rel" ] || continue
        [ -f "$src_root/$rel" ] || continue
        dest="$dest_root/$rel"
        if [ -n "$dry" ]; then
            echo "Would update: scripts/ci-runner/${rel}"
        else
            mkdir -p "$(dirname "$dest")" || continue
            cp "$src_root/$rel" "$dest" || continue
            chmod "$mode" "$dest"
        fi
        AITF_CI_BUNDLE_COUNT=$((AITF_CI_BUNDLE_COUNT + 1))
    done <<EOF_BUNDLE
$(_aitf_ci_runner_bundle_files)
EOF_BUNDLE
    return 0
}
