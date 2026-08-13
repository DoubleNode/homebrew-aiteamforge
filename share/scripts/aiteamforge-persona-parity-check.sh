#!/bin/bash
# aiteamforge-persona-parity-check.sh
#
# XACA-0925 durability guard: a read-only, content-based drift DETECTOR for
# working-dir persona installs, standing apart from update_team_personas()
# (aiteamforge-upgrade.sh), which is the FIXER.
#
# WHY THIS EXISTS: XACA-0925 found 9 of 11 teams on darren-m4-mini frozen at
# install-time persona content, invisible for ~2 months because
# kb-sync-personas re-stamps every deployed copy's mtime on each sync — the
# most obvious staleness signal was actively poisoned. update_team_personas()
# stops the drift going FORWARD once `aiteamforge upgrade` runs, but nothing
# previously DETECTED drift that had already happened, or would catch a
# future regression in update_team_personas() itself, or a machine that
# simply hasn't upgraded in a while. This script is that detector.
#
# DESIGN: standalone and read-only by construction (no write, no backup, no
# state) so it is safe to invoke from anywhere — a cron job, `aiteamforge
# doctor`, or by hand — without inheriting any of the mutation-path's
# concerns (DRY_RUN, backups, orphan handling). It intentionally duplicates
# NONE of update_team_personas()'s write logic; it only reads and compares.
#
# COMPARISON: byte-for-byte `cmp`, exactly like the fixer — NEVER mtime. A
# parity checker that trusted mtime would be worse than useless here: it is
# the exact signal kb-sync-personas poisons, so an mtime-based checker would
# report "clean" on the precise machines this ticket was filed about.
#
# TEAM ENUMERATION: `.teams[]` in ${WORKING_DIR}/.aiteamforge-config via
# get_configured_teams() (lib/config.sh) — the same source of truth
# update_team_personas() uses — never a glob of share/personas/*/. A team
# this machine never installed must never be flagged.
#
# SUGGESTED INTEGRATION (not wired by this ticket — XACA-0925-006 is
# test/durability scope; wiring a *doctor* check or a fleet cron job into the
# live command surface is feature work for a follow-up ticket):
#   - `aiteamforge doctor`, as a new check_persona_parity() alongside the
#     existing check_version_drift()/check_connect_scripts() checks
#     (aiteamforge-doctor.sh) — same shape, same audience.
#   - A periodic fleet job (mirrors the nightly auto-upgrade LaunchAgent)
#     that runs this after every `aiteamforge upgrade` and alerts on exit 1,
#     closing the loop the M4Mini incident exposed: the fix landing in a
#     release is not the same as a specific machine's drift being resolved.
#
# USAGE:
#   aiteamforge-persona-parity-check.sh [--working-dir DIR] [--framework-dir DIR] [--quiet]
#
# EXIT CODES:
#   0 = no drift found (or nothing configured to check).
#   1 = at least one configured team has content drift, or a configured team
#       has no working-dir persona directory at all.
#   2 = bad arguments.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Installed layout ships libexec/ as a sibling of share/ under the same
# Cellar version dir (share/scripts/<this file> -> ../../libexec/lib/config.sh).
# This also holds for a plain tap checkout (this repo), where the same
# relative relationship exists between share/scripts/ and libexec/lib/.
LIB_DIR="$(cd "$SCRIPT_DIR/../../libexec/lib" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/config.sh"

QUIET=false
_ARG_WORKING_DIR=""
_ARG_FRAMEWORK_DIR=""

usage() {
    cat <<'EOF'
Usage: aiteamforge-persona-parity-check.sh [--working-dir DIR] [--framework-dir DIR] [--quiet]

Read-only content-parity check: compares each configured team's working-dir
persona files (${WORKING_DIR}/<team>/personas/agents/*.md) against the
Cellar/framework's shipped source (${FRAMEWORK_DIR}/share/personas/<team>/agents/*.md)
using `cmp` (never mtime). Reports every team/file pair that differs.

Exit 0: no drift found.
Exit 1: drift found in at least one team, OR a configured team has no
        working-dir persona directory at all.
Exit 2: bad arguments.

Teams are enumerated from `.teams[]` in ${WORKING_DIR}/.aiteamforge-config —
never a glob of share/personas/*/ — so a team this machine never installed
is never flagged.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --working-dir) _ARG_WORKING_DIR="${2:-}"; shift 2 ;;
        --framework-dir) _ARG_FRAMEWORK_DIR="${2:-}"; shift 2 ;;
        --quiet) QUIET=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

WORKING_DIR="${_ARG_WORKING_DIR:-$(get_working_dir)}"
FRAMEWORK_DIR="${_ARG_FRAMEWORK_DIR:-$(get_framework_dir)}"
# get_configured_teams()/get_config_file() (lib/config.sh) key off
# $AITEAMFORGE_DIR, not whatever WORKING_DIR resolves to locally — keep them
# in lockstep so a caller who only overrides --working-dir still reads the
# matching .aiteamforge-config.
export AITEAMFORGE_DIR="$WORKING_DIR"

_log() { [ "$QUIET" = true ] || printf '%s\n' "$*"; }

TEAMS="$(get_configured_teams || true)"
if [ -z "${TEAMS// /}" ]; then
    _log "No configured teams found in ${WORKING_DIR}/.aiteamforge-config — nothing to check."
    exit 0
fi

DRIFT_FOUND=false

for team in $TEAMS; do
    src_dir="${FRAMEWORK_DIR}/share/personas/${team}/agents"
    dst_dir="${WORKING_DIR}/${team}/personas/agents"

    # Nothing shipped for this team in the Cellar — not this script's concern
    # (e.g. a team whose personas are entirely repo-tracked, XACA-0285 style).
    [ -d "$src_dir" ] || continue

    if [ ! -d "$dst_dir" ]; then
        _log "DRIFT [${team}]: no working-dir persona directory at ${dst_dir} (never refreshed since install, or upgrade hasn't run since XACA-0925 shipped)"
        DRIFT_FOUND=true
        continue
    fi

    for src_file in "$src_dir"/*.md; do
        [ -f "$src_file" ] || continue
        name="$(basename "$src_file")"
        dst_file="${dst_dir}/${name}"

        if [ ! -f "$dst_file" ]; then
            _log "DRIFT [${team}]: ${name} missing from working dir (present in Cellar)"
            DRIFT_FOUND=true
            continue
        fi

        # Content comparison ONLY — never mtime. This is the entire point of
        # the tool: mtime is the signal XACA-0925 proved unreliable.
        if ! cmp -s "$src_file" "$dst_file"; then
            _log "DRIFT [${team}]: ${name} differs from Cellar (content mismatch)"
            DRIFT_FOUND=true
        fi
    done
done

if [ "$DRIFT_FOUND" = true ]; then
    _log ""
    _log "Persona parity check FAILED — one or more teams have stale or missing working-dir persona content."
    _log "Run: aiteamforge upgrade   (refreshes via update_team_personas)."
    exit 1
fi

_log "Persona parity check passed — all configured teams' working-dir personas match the Cellar."
exit 0
