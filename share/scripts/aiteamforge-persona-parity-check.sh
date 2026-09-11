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
# live command surface is feature work for a follow-up ticket, tracked as
# XACA-0927):
#   - `aiteamforge doctor`, as a new check_persona_parity() alongside the
#     existing check_version_drift()/check_connect_scripts() checks
#     (aiteamforge-doctor.sh) — same shape, same audience.
#   - A periodic fleet job (mirrors the nightly auto-upgrade LaunchAgent)
#     that runs this after every `aiteamforge upgrade` and alerts on exit 1,
#     closing the loop the M4Mini incident exposed: the fix landing in a
#     release is not the same as a specific machine's drift being resolved.
#   NOTE for whoever wires the above (XACA-0931-001_decision §2.1 correction):
#   this script is NOT "tap-checkout only" — it already ships in every
#   consumer's Cellar at
#   <brew-prefix>/libexec/share/scripts/aiteamforge-persona-parity-check.sh.
#   What is true is that nothing lays it into the working dir
#   (~/aiteamforge/scripts/) and nothing in libexec/ or bin/ references it —
#   so a doctor arm can reach the Cellar copy directly, with no installer
#   change required, whenever XACA-0927 is picked up.
#
# THREE SURFACES (XACA-0931 added the third; S1<->S2 is the original
# XACA-0925 scope):
#   S1 Cellar/framework : ${FRAMEWORK_DIR}/share/personas/<team>/agents/*.md
#                          — shipped truth.
#   S2 working-dir source: ${WORKING_DIR}/<team>/personas/agents/*.md
#                          — what the deployer reads.
#   S3 deployed (NEW)    : <project_dir>/.claude/agents/*.md
#                          — what Claude Code actually LOADS. This is the
#                          only surface that affects a running session, and
#                          the one nothing checked before XACA-0931.
#
# S3 IS A TRANSFORMED DERIVATIVE OF S2 — NEVER RAW-COMPARE. `_deploy_core`
# (deploy-worktree-personas.sh) does not plain-copy: every file is piped
# through `_transform_persona`, which rewrites the frontmatter `name:` line
# to the character name derived from the filename. A raw `cmp` of S3 against
# S2 therefore reports drift on EVERY file, ALWAYS, on a perfectly clean box.
# This script never reimplements that rewrite — it shells out to
# `deploy-worktree-personas.sh emit-transformed <src_file>` (the single
# authority for "what should this file look like once deployed") and
# compares S3 against THAT output. See _check_s3_target() below and
# XACA-0931-001_decision.md §4.2 ("textbook k501 sibling-heuristic drift").
#
# S3 TARGET ENUMERATION IS SHARED, NOT REINVENTED — sourced from
# libexec/lib/persona-targets.sh, the SAME enumerator
# XACA-0931-002's upgrade-path fixer uses. Two independent enumerators for
# one concept is exactly the failure mode this ticket exists to prevent: a
# checker that looked at a smaller target set than the fixer wrote to would
# report false-clean forever. Target discovery there is git-root-based, NEVER
# a `~/<team>/*/` glob (impostor dirs exist: `~/medical/personas/` is a
# persona STORE, not a project) and NEVER keyed on the `.synced-from-tap`
# marker (a real, currently-drifted target can have no marker at all).
#
# USAGE:
#   aiteamforge-persona-parity-check.sh [--working-dir DIR] [--framework-dir DIR] [--quiet]
#
# EXIT CODES (unchanged by XACA-0931 — S3 folds into the existing
# DRIFT_FOUND flag; no new code, no new flag, no new entry point, so any
# future doctor-arm wiring (XACA-0927) needs zero additional work):
#   0 = no drift found (or nothing configured/deployed to check).
#   1 = at least one configured team has S1<->S2 content drift or is missing
#       its working-dir persona directory, OR at least one deployed target
#       has S2<->S3 content drift, OR any surface's inputs could not be
#       determined (fail CLOSED — never a silent skip, never a pass).
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
# shellcheck disable=SC1091
source "$LIB_DIR/persona-targets.sh"

# The single authority for "what should a deployed file look like" (see the
# S3 comment block above). Read-only; --nested-main-root/--all/plain deploy
# modes are never invoked from here.
DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy-worktree-personas.sh"

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
    # XACA-0931-005 (TE2): do NOT exit here. An empty `.teams[]` means there is
    # no Cellar-vs-source (S1<->S2) surface to check, but the deployed-vs-source
    # (S2<->S3) surface below is enumerated from ON-DISK deploy targets and is
    # deliberately INDEPENDENT of `.teams[]` (decision record §4.3). Exiting 0
    # here made S3 unreachable on exactly the boxes whose config is incomplete —
    # which is the population this ticket exists to serve (darren-m4-mini has
    # legal+medical deployed and absent from `.teams[]`). Fall through with an
    # empty TEAMS so the loop below runs zero iterations.
    _log "No configured teams found in ${CONFIG_FILE} — skipping the Cellar-vs-source surface; the deployed-vs-source surface still runs (it does not depend on .teams[])."
    TEAMS=""
fi

DRIFT_FOUND=false

for team in $TEAMS; do
    src_dir="${FRAMEWORK_DIR}/share/personas/${team}/agents"
    dst_dir="${WORKING_DIR}/${team}/personas/agents"

    # Nothing shipped for this team in the Cellar — not this script's concern
    # (e.g. a team whose personas are entirely repo-tracked, XACA-0285 style).
    [ -d "$src_dir" ] || continue

    # XACA-0925-023: existence is NOT enough. A shipped source dir that exists
    # but is unreadable (0300/0000) or non-searchable (0600) makes the glob
    # below yield zero iterations, so every team silently contributes no
    # comparisons and the script reports "parity check passed" — a POSITIVE
    # FALSE CLAIM of parity, with real drift sitting right there unexamined.
    # That is strictly worse than the 021 masquerade it mirrors: 021 said
    # "nothing to check", this says "everything matches". Same class as 014/019,
    # which were fixed in the FIXER (aiteamforge-upgrade.sh) but never mirrored
    # into the DETECTOR. A detector that cannot inspect its input must report a
    # check FAILURE, never a silent skip and never a pass.
    if [ ! -r "$src_dir" ] || [ ! -x "$src_dir" ]; then
        _err_always "ERROR [${team}]: shipped persona directory ${src_dir} exists but is not readable/searchable — cannot compare against the working dir. Treating as a check FAILURE, not \"nothing to check\"."
        DRIFT_FOUND=true
        continue
    fi

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

# ---------------------------------------------------------------------------
# S3 (XACA-0931): deployed vs working-dir source.
#
# Target enumeration is INDEPENDENT of `.teams[]` — it comes from
# persona-targets.sh's git-root sweep (shared with XACA-0931-002's upgrade
# fixer), because the two currently-drifted targets this surface exists to
# catch (legal/coparenting, medical/general on darren-m4-mini) are BOTH
# absent from `.teams[]` on that box. Gating S3 on `.teams[]` the way S1<->S2
# does above would reach only the one target already clean and miss both
# real cases — see XACA-0931-001_decision.md §2.4.
# ---------------------------------------------------------------------------

# Compares one deployed target's files against the EXPECTED TRANSFORM of its
# working-dir source (never raw source — see the S3 header comment block).
# Sets the shared DRIFT_FOUND flag; never exits directly, so one bad target
# never stops the remaining targets from being checked (mirrors the S1<->S2
# loop's own continue-on-drift behavior above).
_check_s3_target() {
    local team="$1"
    local project_dir="$2"
    local s2_dir="${WORKING_DIR}/${team}/personas/agents"
    local s3_dir="${project_dir}/.claude/agents"

    # Defensive re-check (belt-and-suspenders, not a reimplementation):
    # persona-targets.sh's enumerator already validated this dir before
    # emitting the target line; re-checking here only guards a TOCTOU race
    # (permissions changed between enumeration and this comparison) and
    # fails CLOSED on it exactly like the enumerator would have.
    if [ ! -d "$s3_dir" ] || [ ! -r "$s3_dir" ] || [ ! -x "$s3_dir" ]; then
        _err_always "ERROR [${team}]: ${s3_dir} is not a readable/searchable directory — cannot compare deployed personas. Treating as a check FAILURE, not \"nothing to check\"."
        DRIFT_FOUND=true
        return 0
    fi

    if [ ! -d "$s2_dir" ]; then
        _log "INFO [${team}]: no working-dir source at ${s2_dir} — every deployed file under ${s3_dir} is an orphan relative to source (not drift by itself)."
    fi

    local s2_file s3_file name expected_out expected_rc
    if [ -d "$s2_dir" ]; then
        for s2_file in "$s2_dir"/*.md; do
            [ -f "$s2_file" ] || continue
            name="$(basename "$s2_file")"
            s3_file="${s3_dir}/${name}"

            if [ ! -f "$s3_file" ]; then
                _log "DRIFT [${team}] ${name}: present in working-dir source (${s2_dir}) but missing from deployed (${s3_dir})"
                DRIFT_FOUND=true
                continue
            fi

            # Single authority for "expected deployed content": shell out to
            # the deployer's own transform, never reimplement the name:
            # rewrite here. Fail CLOSED (never a raw cmp fallback) on any
            # non-zero exit — the dominant cause is python3 being
            # unavailable, per XACA-0931-001_decision.md §4.2.
            expected_rc=0
            expected_out=$("$DEPLOY_SCRIPT" emit-transformed "$s2_file" 2>/dev/null) || expected_rc=$?

            if [ "$expected_rc" -ne 0 ]; then
                _err_always "ERROR [${team}] ${name}: could not compute the expected transform of ${s2_file} (emit-transformed rc=${expected_rc}, likely python3 unavailable) — cannot compare. Treating as a check FAILURE, never falling back to a raw comparison against untransformed source."
                DRIFT_FOUND=true
                continue
            fi

            # printf '%s\n' reconstructs the exact single-trailing-newline
            # form _deploy_core itself writes to disk (it captures
            # _transform_persona's stdout via command substitution — which
            # strips trailing newlines — then writes it back with exactly
            # one restored). emit-transformed's own stdout already went
            # through that same round trip once; capturing it here via
            # command substitution strips that one newline again, so this
            # printf restores it a second time — netting out identical to
            # what is actually sitting on disk in $s3_file. Comparing
            # without this reconstruction would report a trailing-newline
            # mismatch on every single file, clean or not.
            if ! printf '%s\n' "$expected_out" | cmp -s - "$s3_file"; then
                _log "DRIFT [${team}] ${name}: differs at ${s3_file} (deployed vs working-dir source)"
                DRIFT_FOUND=true
            fi
        done
    fi

    # Orphans: deployed files with no working-dir-source counterpart.
    # WARN only — mirrors update_team_personas()'s never-delete orphan
    # convention; does not set DRIFT_FOUND.
    for s3_file in "$s3_dir"/*.md; do
        [ -f "$s3_file" ] || continue
        name="$(basename "$s3_file")"
        if [ ! -f "${s2_dir}/${name}" ]; then
            _log "WARN [${team}] ${name}: deployed at ${s3_dir} with no working-dir source counterpart at ${s2_dir} (orphan — not drift)"
        fi
    done
}

# pt_enumerate_targets (libexec/lib/persona-targets.sh) streams zero or more
# "<team>\t<project_dir>" lines and ALWAYS ends with a "#UNINSPECTABLE\t<N>"
# trailer line — never a global variable — precisely because a global a
# streaming enumerator sets is invisible across a subshell boundary (its own
# header comment explains why: `<(...)`/pipe consumers run it in a subshell).
# Capturing the whole stream via command substitution first, THEN parsing the
# trailer out of the captured text in THIS shell, sidesteps that boundary
# entirely — nothing here relies on a variable persisting out of a subshell.
S3_RAW="$(pt_enumerate_targets "$FRAMEWORK_DIR")"
PERSONA_TARGETS_UNINSPECTABLE="$(printf '%s\n' "$S3_RAW" | tail -n 1 | awk -F'\t' '{print $2}')"
case "$PERSONA_TARGETS_UNINSPECTABLE" in
    ''|*[!0-9]*) PERSONA_TARGETS_UNINSPECTABLE=0 ;;  # malformed/missing trailer -- never trust a non-numeric count
esac
S3_TARGETS="$(printf '%s\n' "$S3_RAW" | sed '$d')"

# "Could not be determined" vs "zero targets" — the XACA-0925-021/-023
# distinction, applied to S3. A live near-miss during this ticket's own
# field probe (a non-login shell with an incomplete PATH reporting
# `teams: <empty>` and `brew: NONE`, both false) is why this is checked
# BEFORE looking at whether any targets were found, not folded into it.
if [ "$PERSONA_TARGETS_UNINSPECTABLE" -gt 0 ]; then
    _err_always "ERROR: could not determine ${PERSONA_TARGETS_UNINSPECTABLE} deploy target(s) (see persona-targets warnings above) — treating as a check FAILURE, never as \"no targets to check\"."
    DRIFT_FOUND=true
fi

if [ -z "$S3_TARGETS" ]; then
    _log "No deployed persona targets found on this box — S3 (deployed-vs-source) contributes nothing."
elif [ ! -f "$DEPLOY_SCRIPT" ] || [ ! -x "$DEPLOY_SCRIPT" ]; then
    _err_always "ERROR: ${DEPLOY_SCRIPT} not found or not executable — cannot compute expected transform output for any S3 target. Treating as a check FAILURE."
    DRIFT_FOUND=true
else
    while IFS=$'\t' read -r s3_team s3_project_dir; do
        [ -n "$s3_team" ] || continue
        _check_s3_target "$s3_team" "$s3_project_dir"
    done <<< "$S3_TARGETS"
fi

if [ "$DRIFT_FOUND" = true ]; then
    _log ""
    _log "Persona parity check FAILED — one or more teams have stale/missing working-dir persona content, or one or more deployed targets differ from working-dir source."
    _log "Run: aiteamforge upgrade   (refreshes source via update_team_personas, and deployed copies via deploy_team_personas_to_projects)."
    exit 1
fi

_log "Persona parity check passed — all configured teams' working-dir personas match the Cellar, and all deployed targets match their working-dir source."
exit 0
