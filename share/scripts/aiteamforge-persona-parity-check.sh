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
# Diagnostics that MUST surface even under --quiet — reserved for the
# "config is broken" error class (XACA-0925-021), never for routine findings.
# Routine findings (DRIFT lines, "nothing to check") stay on _log/stdout so
# --quiet keeps its existing, tested behavior (T7).
_err_always() { printf '%s\n' "$*" >&2; }

# XACA-0925-021: get_configured_teams() (lib/config.sh) reads
# .aiteamforge-config via `jq -r '.teams[]? // empty' "$config_file"
# 2>/dev/null | tr '\n' ' '` — jq's own exit status is discarded by
# `2>/dev/null`, and the pipeline's reported exit status is `tr`'s (always
# 0), never jq's. So an UNREADABLE or MALFORMED config comes back exactly
# the same as a genuinely empty one: an empty string. That collapse is the
# correct fail-soft contract for the FIXER (update_team_personas() in
# aiteamforge-upgrade.sh, which wraps every call `|| true` by deliberate
# design — see its own "Fail-soft" header) but it is precisely the fail-open
# masquerade THIS detector exists to catch: a machine whose config went
# unreadable would report "nothing to check" and exit 0 — silently, even
# under --quiet — which is permanently GREEN on exactly the machine that
# most needs to be flagged (per this file's own "SUGGESTED INTEGRATION"
# note above: a fleet cron alerting on exit 1 would never fire for it).
#
# Rather than change get_configured_teams()'s return-code contract (shared
# by aiteamforge-status.sh, aiteamforge-doctor.sh, aiteamforge-start.sh, and
# aiteamforge-upgrade.sh, all of which already treat any nonzero as
# fail-soft "nothing configured" — a contract this ticket has no reason to
# touch), this script validates the config file itself, explicitly, BEFORE
# calling get_configured_teams() for extraction. That keeps the
# unreadable/malformed-vs-legitimately-empty distinction intact for the
# DETECTOR without changing the FIXER's (or any other caller's) contract.
CONFIG_FILE="$(get_config_file)"

if [ ! -f "$CONFIG_FILE" ]; then
    _log "No .aiteamforge-config found at ${CONFIG_FILE} — nothing configured yet, nothing to check."
    exit 0
fi

if [ ! -r "$CONFIG_FILE" ]; then
    _err_always "ERROR: ${CONFIG_FILE} exists but is not readable (permission denied) — cannot determine configured teams. Treating as a check FAILURE, not \"nothing to check\"."
    exit 1
fi

if command -v jq &>/dev/null; then
    # Check jq's OWN exit status explicitly here — never rely on a
    # pipeline's last-command status the way get_configured_teams() does
    # internally (that is exactly the bug: `jq ... 2>/dev/null | tr '\n' ' '`
    # reports `tr`'s exit code, and `tr` always succeeds even when jq failed
    # to parse malformed JSON upstream). `jq -e` treats a `false`/`null`
    # result as failure too, so this also catches ".teams" existing but not
    # being an array (e.g. a hand-edited config with `"teams": "academy"`).
    if ! jq -e '(.teams? // []) | type == "array"' "$CONFIG_FILE" >/dev/null 2>&1; then
        _err_always "ERROR: ${CONFIG_FILE} exists but could not be parsed as valid JSON (or its \"teams\" key is not an array) — cannot determine configured teams. Treating as a check FAILURE, not \"nothing to check\"."
        exit 1
    fi
fi
# No-jq environments fall through to get_configured_teams()'s existing
# grep/sed fallback below, unchanged — that fallback's own malformed-input
# behavior is pre-existing and out of this ticket's scope.

TEAMS="$(get_configured_teams || true)"
if [ -z "${TEAMS// /}" ]; then
    _log "No configured teams found in ${CONFIG_FILE} — nothing to check."
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
