#!/usr/bin/env bash
# ci-enable-guard.sh - refuse `aiteamforge ci enable` where it must never run (XACA-1443-005).
#
# SOURCEABLE LIBRARY. Sourcing defines one function and nothing else: no output, no
# `exit`, no change to the caller's `set` options. The CLI calls it FIRST, before any
# side effect, and aborts on a non-zero return.
#
#   ci_enable_guard            returns:
#       0   safe to proceed
#       10  REFUSED: this is the dev-team source machine (no override, ever)
#       11  REFUSED: the install dir is inside a git work-tree / has git-tracked files
#           (override: AITEAMFORGE_ALLOW_DEV_OVERWRITE=1, sandboxed tests only - same
#            switch and same rule as the XACA-0564 install_kanban_helpers guard)
#
# Env read: AITEAMFORGE_DIR (default $HOME/aiteamforge), HOME, AITEAMFORGE_ALLOW_DEV_OVERWRITE.
#
# (a) DEV-MACHINE SIGNAL. Reuses the XACA-0497 sentinel `.aiteamforge-source-tree`
#     (git-tracked at the root of dev-team, so it exists on every machine that carries the
#     source tree and on no machine that only has the shipped tap). Two probes, the same two
#     install-team.sh already uses: the sentinel at the root of the resolved install dir
#     (XACA-0497) and the sentinel at $HOME/dev-team (machine-level, its parity guard).
#     Deliberately NOT hostname inference: hostnames are renamed, duplicated and spoofable,
#     and a second signal that can disagree with the one every other guard trusts is how
#     guards drift. No override: the dev machine is where the shipped product must never
#     run (XACA-0212/0219/0497); an escape hatch here is the hole the incident came through.
#     Tests simulate "non-dev machine" by pointing HOME at a sandbox.
#
# (b) GIT WORK-TREE. The 0564 idiom (install dir IS a work-tree root, or kanban-helpers.sh
#     is tracked there) plus one extra probe: ANY tracked file at/below the install dir. A
#     gitignored install dir inside e.g. a dotfiles repo passes; a tracked one is refused.
#
# Portability: /bin/bash 3.2 and bash 5. Naming: public ci_enable_*, internals _cieg_*.

_cieg_err() { echo "ERROR: $*" >&2; }

ci_enable_guard() {
    local dir="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
    local real
    real="$(cd "$dir" 2>/dev/null && pwd -P)" || real=""

    # ---- (a) dev-team source machine: sentinel, no override ----
    if { [ -n "$real" ] && [ -f "$real/.aiteamforge-source-tree" ]; } \
        || [ -f "$HOME/dev-team/.aiteamforge-source-tree" ]; then
        _cieg_err "this is the AITeamForge dev-team source machine (.aiteamforge-source-tree sentinel found)."
        _cieg_err "The shipped product, including the CI runner capability, must never be enabled here (XACA-0497 / XACA-0212)."
        _cieg_err "Run 'aiteamforge ci enable' on a separate machine. There is no override."
        return 10
    fi

    # ---- (b) install dir inside a git work-tree / tracked ----
    if command -v git >/dev/null 2>&1 && [ -n "$real" ]; then
        local is_repo=0 top nd nt
        # GIT_DIR/GIT_WORK_TREE in the caller's env would redirect every probe below.
        top="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$real" rev-parse --show-toplevel 2>/dev/null)" || top=""
        if [ -n "$top" ]; then
            nd="$(cd "$real" && pwd -P)"
            nt="$(cd "$top" 2>/dev/null && pwd -P)" || nt="$top"
            [ "$nd" = "$nt" ] && is_repo=1
            if [ "$is_repo" = 0 ]; then
                env -u GIT_DIR -u GIT_WORK_TREE git -C "$real" ls-files --error-unmatch kanban-helpers.sh >/dev/null 2>&1 && is_repo=1
            fi
            if [ "$is_repo" = 0 ]; then
                [ -n "$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$real" ls-files 2>/dev/null | head -n 1)" ] && is_repo=1
            fi
        fi
        if [ "$is_repo" = 1 ]; then
            if [ "${AITEAMFORGE_ALLOW_DEV_OVERWRITE:-}" = "1" ]; then
                echo "WARNING: AITEAMFORGE_ALLOW_DEV_OVERWRITE=1 set - enabling CI inside a git work-tree ($real)." >&2
            else
                _cieg_err "$real is inside a git work-tree or has git-tracked files."
                _cieg_err "Refusing to enable the CI runner on top of a source checkout (XACA-0564 idiom)."
                _cieg_err "Set AITEAMFORGE_ALLOW_DEV_OVERWRITE=1 to override (sandboxed tests only)."
                return 11
            fi
        fi
    fi
    return 0
}
