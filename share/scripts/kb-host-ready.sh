#!/usr/bin/env bash
# kb-host-ready.sh — per-host readiness agent: idempotent tmux team restore
# at login, plus an optional fast-user-switch to the login window for
# shared-machine hosts (XACA-1066).
#
# Authoritative design: kanban/plans/XACA-1066/XACA-1066-001-design.md
# (Nahla, 2026-09-02). This header restates the load-bearing decisions; the
# design doc is the source of truth if the two ever disagree.
#
# USAGE
#   kb-host-ready.sh login                 The LaunchAgent's entry point.
#                                           Guard -> restore -> lock -> state
#                                           -> best-effort notify.
#   kb-host-ready.sh restore [--dry-run] [--team <t>]
#                                           Restore half only. Idempotent,
#                                           level-triggered. Alias: reconcile.
#   kb-host-ready.sh reconcile [...]        Alias for restore.
#   kb-host-ready.sh lock [--force]         Lock half only. Refuses unless
#                                           lock_after_login is true, unless
#                                           --force (which also bypasses the
#                                           session-age guard).
#   kb-host-ready.sh resume [--dry-run]    Claude auto-resume half only (XACA-1380-005).
#                                           Needs auto_resume_claude: true. Scope =
#                                           configured teams that are up now.
#   kb-host-ready.sh status                 Read-only report. No side effects.
#   kb-host-ready.sh check                  Validation only, zero side
#                                           effects. The gate a human runs.
#   kb-host-ready.sh suggest                Print a candidate config for THIS
#                                           host, derived from
#                                           team-machines.json. Writes nothing.
#   kb-host-ready.sh init-config [--dry-run] [--quiet]
#                                           Seed ~/.aiteamforge/host-ready.json
#                                           write-if-absent (never overwrites)
#                                           with an inert placeholder (empty
#                                           autostart, lock_after_login=false,
#                                           self-marked _seeded_unconfigured).
#                                           Called by the installer and by
#                                           every upgrade (XACA-1162) — never
#                                           run this to "reset" a config; it
#                                           is a no-op once a file exists.
#   kb-host-ready.sh -h | --help | help     This text.
#
# EXIT CODES
#   login       : 0 = everything asked for was done or already true,
#                 INCLUDING the absent-config no-op. 1 = something did not
#                 complete.
#   restore     : 0 = all desired teams up. 1 = one or more not.
#   lock        : 0 = login window reached or already there. 1 = refused,
#                 unavailable, or failed.
#   status      : 0 always, unless it cannot read what it needs to report.
#   check       : 0 = everything valid. 1 = any problem (one line each).
#   suggest     : 0.
#   init-config : 0 always — never fails the install/upgrade that calls it.
#   usage error on any subcommand: 2.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS FILE IS BASH, NOT ZSH — READ BEFORE "MODERNIZING" THE SHEBANG
# ─────────────────────────────────────────────────────────────────────────────
# Every one of the 11 master `<team>-startup.sh` scripts opens with a
# `cleanup_orphans` sweep:
#
#   local orphans=$(ps -eo pid,ppid,tty,comm | grep zsh | grep "??" | awk '$2 == 1 {print $1}')
#   echo "$orphans" | xargs kill 2>/dev/null
#
# That kills every process named `zsh` whose parent pid is 1 and whose
# controlling tty is "??". A launchd-spawned process has EXACTLY that shape.
# If this script were zsh, the first `<team>-startup.sh` it invokes would
# kill ITS OWN PARENT mid-restore, and every later team in `autostart` would
# silently never start — with `lock_after_login` never reached either,
# because that failure is silent (the filter is `grep zsh`, so it never
# shows up as an error, just as teams that never came up).
#
# The repo's documented convention is that shell helpers here are zsh. THIS
# FILE IS A DELIBERATE, REASONED EXCEPTION TO THAT CONVENTION. Do not
# "fix" the shebang to match the rest of the repo.
#
# Corollary: this file is also verified to run under macOS's shipped
# `/bin/bash` (3.2), because the LaunchAgent invokes it as
# `/bin/bash .../kb-host-ready.sh login` explicitly (never trusting a shebang
# under launchd, and PATH there doesn't reliably contain a newer bash
# anyway). That means NO `declare -A`, NO `${var^^}`, NO `mapfile`, NO
# `[[ -v ]]` anywhere below — all bash-4+-only.
#
# ─────────────────────────────────────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────────────────────────────────────
#   ~/.aiteamforge/host-ready.json  (path overridable: KB_HOST_READY_CONFIG)
#
#   {
#     "schema_version": 1,
#     "autostart": [ { "team": "dns", "args": [] }, ... ],
#     "lock_after_login": false
#   }
#
# Absent file -> restore and lock both do nothing, no state file is written,
# exit 0. This is a tested property (see subitem 005), not an assurance —
# it is what licenses this agent joining the XACA-0734 mandatory set.
#
# XACA-1162: the installer and every upgrade now call `init-config` (below)
# to seed this file WRITE-IF-ABSENT with an inert placeholder — empty
# autostart, lock_after_login=false, self-marked with a top-level
# "_seeded_unconfigured": true key so `check`/`status` can tell "never
# customized" apart from "deliberately configured to do nothing". A seeded
# file is NOT absent (see "Absent file ->" above) — it takes the `ok` path
# below, which starts nothing and locks nothing but DOES write a state file
# on `login` and turns `check` into a real (still-green) assertion instead
# of a vacuous one. Deleting the file reverts to the absent no-op; deleting
# only the `_seeded_unconfigured` key marks a config as deliberately
# customized. See kanban/plans/XACA-1162/XACA-1162-004-*.md for the full
# rationale and docs/host-ready-runbook.md for the operator-facing version.
#
# XACA-1066

set -uo pipefail
# Deliberately NOT `set -e`: several loops below must continue past a
# per-entry failure and record it, rather than aborting the whole run — see
# feedback_set_e_last_line_short_circuit.md for why `set -e` plus a trailing
# `[[ cond ]] && cmd` is its own trap; this script avoids that shape entirely
# by using `if` rather than `&&`-as-a-statement.

# ─────────────────────────────────────────────────────────────────────────────
# Sandbox-overridable locations + constants. Every path this script reads or
# writes is overridable so the whole thing can be exercised against a
# TEST_TMP_DIR without touching a real host. (KB_TTYD_CONFIG pattern.)
# ─────────────────────────────────────────────────────────────────────────────
KB_HOST_READY_CONFIG="${KB_HOST_READY_CONFIG:-$HOME/.aiteamforge/host-ready.json}"
KB_HOST_READY_TEAM_PATHS="${KB_HOST_READY_TEAM_PATHS:-$HOME/.aiteamforge/team-paths.json}"
KB_HOST_READY_TEAM_MACHINES="${KB_HOST_READY_TEAM_MACHINES:-$HOME/.aiteamforge/team-machines.json}"
KB_HOST_READY_STATE_FILE="${KB_HOST_READY_STATE_FILE:-$HOME/.aiteamforge/run/host-ready.state}"
KB_HOST_READY_PLIST="${KB_HOST_READY_PLIST:-$HOME/Library/LaunchAgents/com.aiteamforge.host-ready.plist}"
KB_HOST_READY_LAUNCHCTL="${KB_HOST_READY_LAUNCHCTL:-launchctl}"

# Constants (§1.3) — env overrides exist for tests only, never for config.
KB_HOST_READY_MAX_SESSION_AGE="${KB_HOST_READY_MAX_SESSION_AGE:-300}"
KB_HOST_READY_RESTORE_BUDGET="${KB_HOST_READY_RESTORE_BUDGET:-600}"
KB_HOST_READY_PROBE_TIMEOUT="${KB_HOST_READY_PROBE_TIMEOUT:-3}"

# Lock mechanism env override — tests / manual override only, NOT a config
# field (§6.2 step 1).
KB_HOST_READY_LOCK_MECHANISM="${KB_HOST_READY_LOCK_MECHANISM:-}"

# Working dir: the directory that holds `<team>-startup.sh`. Reused verbatim
# from the convention every other script in this repo already uses
# (lcars-launch-helpers.sh, kb-ttyd-bridge.sh, ...): unset AITEAMFORGE_DIR on
# the dev source resolves to ~/dev-team; a tap-installed machine sets
# AITEAMFORGE_DIR itself.
KB_HOST_READY_WORKING_DIR="${AITEAMFORGE_DIR:-$HOME/dev-team}"

# XACA-1162 init-config gates. Honours AITF_LAUNCHAGENT_OPTOUT_FILE if the
# caller already set it (same var name the tap's launchagents.sh uses), so a
# test or an upgrade run that exports it for the tap's own gate keeps both
# gates pointed at the same sandboxed file.
KB_HOST_READY_OPTOUT_FILE="${KB_HOST_READY_OPTOUT_FILE:-${AITF_LAUNCHAGENT_OPTOUT_FILE:-$HOME/.aiteamforge/launchagents.optout}}"

# tmux resolution — PATH under launchd does NOT include /opt/homebrew/bin
# (XACA-0713). Probe known absolute locations before falling back to PATH.
_hr_resolve_tmux() {
    if [ -n "${KB_HOST_READY_TMUX:-}" ] && command -v "$KB_HOST_READY_TMUX" >/dev/null 2>&1; then
        printf '%s\n' "$KB_HOST_READY_TMUX"
        return 0
    fi
    local cand
    for cand in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
        if [ -x "$cand" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    if command -v tmux >/dev/null 2>&1; then
        command -v tmux
        return 0
    fi
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Output helpers. No internal log file: the plist's StandardOutPath /
# StandardErrorPath already fix the log location (§1.2 rejects a config
# `log_path` field for exactly this reason — one artifact, one place to look).
# ─────────────────────────────────────────────────────────────────────────────
log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
err()  { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

_escape_for_osascript() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Best-effort desktop notification. Never fatal — a no-op with no Aqua
# session, which is the common case for this script (§2.2 item 2).
notify() {
    local message="$1"
    if command -v osascript >/dev/null 2>&1; then
        local safe
        safe=$(_escape_for_osascript "$message")
        osascript -e "display notification \"$safe\" with title \"AITeamForge Host Ready\"" >/dev/null 2>&1 || true
    fi
}

usage() {
    sed -n '2,55p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
}

# ─────────────────────────────────────────────────────────────────────────────
# Login-session identity (§4.5) — used by BOTH guards.
# ─────────────────────────────────────────────────────────────────────────────

# Echoes the epoch start-time of the current `loginwindow` process, or
# nothing (+ non-zero) if it cannot be determined. Verified format on this
# machine: `ps -o lstart=` prints e.g. "Mon Aug 24  9:24:31 2026"; macOS
# `date -j -f` with "%a %b %e %T %Y" parses that (both single- and
# double-digit days, %e is space-padded).
_hr_loginwindow_start_epoch() {
    local pid epoch lstart
    pid=$(pgrep -x loginwindow 2>/dev/null | head -1)
    if [ -z "$pid" ]; then
        return 1
    fi
    # LC_ALL=C on the PROBE as well as on the date parse below: both guards read
    # this single value and BOTH fail open when it is empty, so one locale
    # difference in ps's output format removes the entire guard set at once. The
    # launchd path pins LANG via the plist; the CLI path inherits the user's.
    lstart=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null)
    if [ -z "$lstart" ]; then
        return 1
    fi
    epoch=$(LC_ALL=C date -j -f "%a %b %e %T %Y" "$lstart" "+%s" 2>/dev/null)
    if [ -z "$epoch" ]; then
        return 1
    fi
    printf '%s\n' "$epoch"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# State file (§4.5). Atomic write (mktemp in the same dir + mv). Overridable
# for sandboxed tests.
# ─────────────────────────────────────────────────────────────────────────────

_hr_state_dir() { dirname "$KB_HOST_READY_STATE_FILE"; }

_hr_read_state_field() {
    # $1 = field name. Tolerant of a missing/malformed state file (returns
    # empty). This is OUR OWN state file, not a third-party registry, so a
    # read failure here just means "no prior run recorded" — never an error.
    local field="$1"
    [ -f "$KB_HOST_READY_STATE_FILE" ] || return 1
    FIELD="$field" STATEFILE="$KB_HOST_READY_STATE_FILE" python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    with open(os.environ["STATEFILE"], encoding="utf-8") as fh:
        doc = json.load(fh)
    val = doc.get(os.environ["FIELD"])
    if val is None:
        sys.exit(1)
    print(val)
except Exception:
    sys.exit(1)
PY
}

# JSON-escape a bash string before splicing it into the hand-built summary
# fragments. Escaping HERE is the actual fix, because a REJECTED entry's team
# is still summarised on the skip path -- which is how a quoted team name
# produced invalid JSON, made the state write fail, and thereby permanently
# disabled guard 1 (the login-session stamp) on every subsequent run (that
# fallback -- _restore_or_raw() degrading to a parse_error/raw diagnostic
# instead of losing the stamp -- is what keeps a still-imperfect escape from
# being catastrophic; it is not a reason for the escape to stay imperfect).
#
# An earlier version of this comment claimed only `"` and `\` needed handling
# because "the resolver's BAD_CHARS already rejects every control character."
# THAT REASONING IS WRONG, and it is wrong for the exact same reason
# _sanitize()'s own comment block (in the python resolver below) documents at
# length: rejecting a character does not remove it from the output, because
# the reject path still emits the raw value forward. Concretely: BAD_CHARS
# rejects a tab in `team`, but the SKIP summary entry above still splices that
# same raw team string in here -- and _sanitize() deliberately does NOT escape
# a bare tab at the wire-protocol boundary (several free-text WARN/reason
# diagnostics rely on it surviving unescaped), so a literal tab byte reaches
# THIS function. JSON (RFC 8259) requires every control character
# (U+0000-U+001F) inside a string to be escaped, and a literal tab is not
# valid there -- demonstrated live (PR #821 review round 4) with a team named
# `tab<TAB>here`, which broke the restore summary's JSON.
#
# Fix: escape every C0 control character, not just the two structural ASCII
# characters. \b \f \n \r \t use JSON's short forms; anything else in
# U+0000-U+001F gets \u00XX.
#
# Getting the numeric value of `c` right is version-sensitive, and an
# earlier round of this fix got it right for only one interpreter. Bash's
# notion of "one character" in `${v:$i:1}` is locale-dependent: bash 3.2 has
# no multibyte awareness, so it is always exactly one BYTE; bash 4+ in a
# UTF-8 locale (this machine's default) treats it as one CODEPOINT, which
# can span several bytes. `printf '%d' "'$c"` follows the same split -- on
# 3.2 it returns the byte's value, sign-extended to negative for anything
# >=0x80 (e.g. -61 for a UTF-8 lead byte); on 4+ it returns the actual
# Unicode codepoint (e.g. 256 for U+0100, 1040 for Cyrillic U+0410, 128512
# for U+1F600 - measured live on this host's /opt/homebrew/bin/bash 5.3).
# `& 0xFF` is the right fix for the 3.2 case (it undoes sign extension on a
# byte) and the WRONG operation on a bash-4+ codepoint (it truncates the
# high bits instead): U+0100 and U+1F600 both mask to 0, and U+0410 masks
# to 16, so each misfires the control-character branch and gets mangled
# into a bogus \u00XX escape. A prior version of this comment claimed
# masking "changes no output ... ASCII or otherwise" -- that was only ever
# true under 3.2; it is false under bash 4+.
#
# Fix for the fix: force `LC_ALL=C` for the scope of this function. That
# collapses bash 4+'s codepoint-aware string handling back to the
# single-byte-per-"character" behavior 3.2 has unconditionally, so
# `${#v}`, `${v:$i:1}`, and `printf '%d' "'$c"` all walk `v` one byte at a
# time and agree with 3.2 byte-for-byte (verified live: both interpreters
# produce the identical sign-extended per-byte sequence for multi-byte
# UTF-8 input once LC_ALL=C is forced). With that in place, `& 0xFF` is
# undoing sign extension on a BYTE on both interpreters -- the job it was
# always meant to do -- rather than truncating a codepoint on one of them.
# This changes no output for ASCII 0x20-0x7E on either interpreter, and no
# output for non-ASCII on bash 3.2 (which was already byte-wise); the only
# behavior it changes is bash 4+'s non-ASCII handling, from wrong to
# matching 3.2.
# Was the resolver's record stream COMPLETE? (XACA-1066, fifth shape.)
# The resolver ends every normal path with a bare "END" record. Its ABSENCE means
# the resolver aborted mid-stream — an encoding error, an unhandled exception, a
# killed interpreter, or python3 missing entirely — and a truncated stream is
# otherwise indistinguishable from a finished one. Acting on a truncated stream is
# what silently dropped a VALID team while reporting skipped=0 and exit 0, which
# on a lock_after_login host would lock a machine whose teams never came up: this
# ticket's own root incident, reproduced from a config typo.
#
# Deliberately NOT another BAD_CHARS entry. Four earlier rounds each ended with
# "that was the last bad character" and each was wrong. A sentinel is
# cause-agnostic and covers causes nobody has enumerated.
#
# Fail CLOSED: refuse to act on a partial stream rather than acting on part of it.
_hr_stream_complete() {
    case $'\n'"$1" in
        *$'\n'"END") return 0 ;;
    esac
    return 1
}

_hr_json_str() {
    # LC_ALL=C forces byte semantics for the scope of this function on
    # BOTH bash 3.2 and bash 4+ -- see the comment block above this
    # function for the full explanation and live-verified numbers. Without
    # it, bash 4+ in a UTF-8 locale walks `v` one codepoint at a time
    # instead of one byte at a time, and the `& 0xFF` mask below stops
    # meaning what it's supposed to mean.
    local v="$1" out="" n i c ord LC_ALL=C
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    n=${#v}
    i=0
    while [ "$i" -lt "$n" ]; do
        c="${v:$i:1}"
        case "$c" in
            $'\t') out="${out}\\t" ;;
            $'\n') out="${out}\\n" ;;
            $'\r') out="${out}\\r" ;;
            $'\b') out="${out}\\b" ;;
            $'\f') out="${out}\\f" ;;
            *)
                # `'$c` is bash's numeric-value-of-first-byte trick; masking
                # with & 0xFF undoes sign extension for bytes >=0x80 (see
                # above) so this test only ever fires for the real C0
                # control range, on both bash 3.2 and bash 4+.
                ord=$(( $(printf '%d' "'$c") & 0xFF ))
                if [ "$ord" -lt 32 ]; then
                    out="${out}$(printf '\\u%04x' "$ord")"
                else
                    out="${out}${c}"
                fi
                ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "$out"
}

_hr_write_state() {
    # $1=login_stamp_epoch $2=restore_json_summary $3=lock_status $4=lock_reason $5=exit_code
    local stamp="$1" restore_summary="$2" lock_status="$3" lock_reason="$4" exit_code="$5" resume_summary="${6:-}"
    local dir tmp
    dir="$(_hr_state_dir)"
    mkdir -p "$dir" 2>/dev/null || { warn "could not create state dir $dir"; return 1; }
    tmp="$(mktemp "${dir}/.host-ready.state.XXXXXX" 2>/dev/null)" || { warn "mktemp failed for state file"; return 1; }
    STAMP="$stamp" RESTORE="$restore_summary" LOCKSTATUS="$lock_status" LOCKREASON="$lock_reason" \
        EXITCODE="$exit_code" RESUME="$resume_summary" RESTORESRC="${_HR_LAST_RESTORE_SOURCE:-}" NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')" python3 - > "$tmp" <<'PY'
import json, os

def _restore_or_raw():
    raw = os.getenv("RESTORE")
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError as e:
        return {"parse_error": str(e), "raw": raw[:2000]}

def _resume_or_none():
    raw = os.getenv("RESUME")
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError as e:
        return {"parse_error": str(e)}

doc = {
    "login_session_stamp": os.environ.get("STAMP") or None,
    "last_run_at": os.environ["NOW"],
    # NEVER let a malformed restore summary cost us the stamp: guard 1 depends
    # on this file existing, and a persistent write failure would disable it on
    # every later run. Degrade the summary to a diagnostic, never abort the doc.
    "restore": _restore_or_raw(),
    "restore_source": os.environ.get("RESTORESRC") or None,
    "resume": _resume_or_none(),
    "lock": os.environ.get("LOCKSTATUS") or "NOT_ATTEMPTED",
    "lock_reason": os.environ.get("LOCKREASON") or None,
    "exit_code": int(os.environ.get("EXITCODE", "0")),
}
print(json.dumps(doc, indent=2))
PY
    if [ -s "$tmp" ]; then
        mv "$tmp" "$KB_HOST_READY_STATE_FILE"
    else
        rm -f "$tmp"
        warn "state write produced no output; leaving prior state file (if any) untouched"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Config resolver (§1, §1.4, §2, §3). ONE python3 pass does all the JSON-level
# work (parsing, field validation, gate 1 + gate 2 per entry) and emits a
# simple \x1f-delimited line protocol bash can parse without a second parser.
#
# Deliberately reads team-paths.json with a PLAIN, READ-ONLY json.load —
# never via aiteamforge_paths.py::load_config(), whose three self-healing
# passes rewrite the file on disk and caused XACA-1029 (a transient read
# treated as permanent corruption, deleting every overlay-only team). A
# login-time job that runs before anyone could notice must not have that
# power. (§2.3, R6)
#
# Output lines (\x1f-separated, one record type per line):
#   STATE\t<absent|malformed_json|malformed_root|ok>\t<message>
#   WARN\t<free text>                          (zero or more)
#   LOCK\t<true|false>
#   SCHEMA\t<int>
#   REGISTRY\t<ok|missing|unparseable>
#   SOURCE\t<static|last-running|static-fallback>\t<detail>   (XACA-1380; once, before ENTRYs)
#   RESUME\t<true|false>\t<stagger_seconds>      (XACA-1380-005; auto_resume_claude + resume_stagger_seconds)
#   ENTRY\t<index>\t<OK|SKIP>\t<team>\t<args_packed>\t<prefix>\t<gate1>\t<gate2>\t<reason>
#     gate1 in {PASS,FAIL}; gate2 in {PASS,FAIL,SKIPPED}
# ─────────────────────────────────────────────────────────────────────────────
# Resolver indirection (XACA-1066-016).
#
# cmd_login used to resolve FOUR times — the STATE peek, cmd_restore, cmd_lock
# and the WARN count — costing four python3 starts per login and opening a
# TOCTOU window: the config could change between the peek that decides intent
# and the step that acts on it.
#
# A memo cache INSIDE this function cannot fix that: every caller invokes it as
# `resolved="$(_hr_resolve ...)"`, and command substitution runs in a SUBSHELL,
# so any cache variable assigned here is discarded when that subshell exits.
# (Measured: a memoised version still produced four resolver runs.) The handoff
# therefore has to come from the CALLER's scope — cmd_login invokes cmd_restore
# and cmd_lock directly, not in a subshell, so a variable it sets is visible to
# them. cmd_login snapshots once into _HR_PRERESOLVED and every callee reuses it.
#
# _HR_PRERESOLVED_KEY guards correctness: `restore --team X` resolves a narrowed
# view, so a snapshot taken with a different filter must never be substituted.
_HR_PRERESOLVED=""
_HR_PRERESOLVED_KEY="__unset__"
_HR_LAST_RESTORE_SOURCE=""   # XACA-1380: set by cmd_restore from the SOURCE record
_hr_resolve() {
    local _key="${1:-}"
    if [ -n "$_HR_PRERESOLVED" ] && [ "$_key" = "$_HR_PRERESOLVED_KEY" ]; then
        printf '%s\n' "$_HR_PRERESOLVED"
        return 0
    fi
    _hr_resolve_uncached "$_key"
}

_hr_resolve_uncached() {
    local filter_team="${1:-}"
    CFG="$KB_HOST_READY_CONFIG" TEAMPATHS="$KB_HOST_READY_TEAM_PATHS" \
        WORKDIR="$KB_HOST_READY_WORKING_DIR" FILTERTEAM="$filter_team" \
        python3 - <<'PY'
import json, os, re, sys

cfg_path = os.environ["CFG"]
team_paths_path = os.environ["TEAMPATHS"]
workdir = os.environ["WORKDIR"]
filter_team = os.environ.get("FILTERTEAM") or ""

# cfg_path, team_paths_path, and workdir all come from the process
# environment (CFG/TEAMPATHS/WORKDIR above), and CPython decodes environ
# values with PEP 383 "surrogateescape": any byte in there that isn't
# valid UTF-8 becomes a lone surrogate codepoint in the resulting str
# (e.g. a non-UTF-8 byte in $HOME on a misconfigured locale). That is the
# SAME unencodable-lone-surrogate shape the ALLOWLIST comment block below
# documents for JSON-sourced `team`/`args` values -- it just arrives via a
# different door (the environment, not the config file) and reaches these
# diagnostics BEFORE the config is even opened, so ALLOWED_CHARS/BAD_CHARS
# (which only ever see `team`/`args`) cannot intercept it. Every emit()
# call below that interpolates one of these three variables (or an
# exception whose message may embed one of them) routes it through
# _hr_safe_repr() first -- see each site (XACA-1096-014).
def _sanitize(v):
    # One record per LINE, fields separated by \x1f. Any character that can end a
    # line or a field must not survive INSIDE a field, or the record forks: bash's
    # `read` gets a truncated line and the remainder parses as a bogus record.
    # BAD_CHARS rejects these in a team value, but a REJECTED entry is still
    # reported and its raw value reaches this emit, so the escape has to live at
    # the protocol boundary rather than at each caller (XACA-1066-018).
    #
    # ESCAPE: \n, \r (end the record) and \x1f (ends the field). \x1f is safe to
    # escape because emit applies the separator AFTER this runs, so it has no
    # legitimate in-field meaning.
    #
    # DO NOT ESCAPE \x1e. It is the args sub-delimiter INSIDE args_packed, and
    # escaping it collapses a multi-argument team into one malformed argument
    # (measured: freelance's two args arrived as the single token `p1\x1ep2`).
    #
    # THIS TRANSFORM IS ONE-WAY AND LOSSY, AND THAT IS THE POINT. A literal
    # backslash-n in a value is indistinguishable in the output from an escaped
    # real newline (verified: team "a\\nb" and team "a<LF>b" both emit "a\\nb").
    # An earlier version of this comment claimed the escape was unambiguous
    # because BAD_CHARS rejects the raw characters -- that reasoning is WRONG for
    # exactly the reason BAD_CHARS alone did not fix the JSON break: rejecting a
    # character does not remove it from the output, because the reject path emits
    # the raw value. Backslashes also arrive here via cfg_path/script_path in
    # diagnostics, which never pass through BAD_CHARS at all.
    #
    # Lossiness is acceptable ONLY because nothing downstream un-escapes or
    # round-trips these fields -- they are split on \x1f and used for display and
    # for comparisons already constrained by BAD_CHARS. If you ever add a decode
    # step, make the escape reversible FIRST (escape the backslash too).
    v = str(v)
    v = v.replace("\n", "\\n").replace("\r", "\\r").replace("\x1f", "\\x1f")
    #
    # ENCODING DEFENSE, MOVED HERE (XACA-1096, round 3 fix). THIS CLASS HAS
    # RECURRED THREE TIMES ON THIS BRANCH, each time "closed" at a call site
    # and each time reopened one door over:
    #   1. The allowlist paths were made surrogate-safe (_hr_safe_repr) while
    #      the legacy BAD_CHARS branch running AHEAD of them stayed raw.
    #   2. Two unsafe env-derived emit() sites were reported fixed; auditing
    #      every call site found eight.
    #   3. _hr_safe_repr() itself encoded to utf-8 -- surrogate-safe, but not
    #      ENCODING-safe: utf-8 represents all valid non-ASCII, so a
    #      perfectly legitimate accented team name passed through untouched
    #      and only raised later, inside emit(), under a non-UTF-8 stdout
    #      locale -- moving the failure sideways rather than closing it.
    #
    # The fix each round applied more call-site discipline. That is exactly
    # the shape of a class that keeps recurring: call-site discipline is an
    # open set, and someone will eventually add a ninth emit() site (or a
    # tenth) without having read this file's history. So the encode step
    # that used to live only in _hr_safe_repr() -- ascii with
    # backslashreplace, the only codec that cannot be weaker than any
    # stdout encoding this process could have -- now ALSO runs here, at the
    # one place every emit() field passes through regardless of which
    # caller produced it. A future emit() call site needs no special
    # handling any more: safe-repr'd already, or not, ASCII, or not, it
    # leaves this function encoding-safe either way.
    #
    # This does not replace the per-site _hr_safe_repr() calls -- they stay,
    # deliberately, as belt-and-braces: they run BEFORE a value is spliced
    # into a hand-built diagnostic string, so a rejection message can still
    # name the specific offending character with useful '<char>' (U+XXXX)
    # detail instead of a flat backslash-escape. This function is the
    # backstop underneath that, not a replacement for it.
    #
    # Composition is idempotent -- verified for plain, accented, surrogate,
    # and tab inputs (safe(safe(x)) == safe(x)) -- so the two layers stack
    # harmlessly rather than double-escaping. ascii is the identity
    # transform for all 128 ASCII codepoints (verified exhaustively, not
    # sampled), so this changes no message any all-ASCII config can
    # produce, and does not touch \x1e (see above) or the tab character
    # (ASCII, encodable as-is, and several existing diagnostics rely on it
    # surviving here unescaped).
    return v.encode("ascii", "backslashreplace").decode("ascii", "replace")

def _finish(code=0):
    # COMPLETENESS SENTINEL (XACA-1066, fifth shape). The record stream had no
    # way to say "I finished", so a consumer could not tell "resolver finished"
    # from "resolver died mid-loop" — both look like the stream ending. An abort
    # therefore dropped every remaining entry silently while cmd_restore reported
    # skipped=0 and exit 0. Reproduced with an unpaired surrogate ("\ud800"):
    # valid JSON that json.loads accepts but UTF-8 cannot encode, so emit() raised
    # and a VALID later team never started. On a lock_after_login host that locks
    # a machine whose teams never came up — this ticket's own root incident.
    #
    # Deliberately NOT another BAD_CHARS entry: four earlier rounds each ended
    # with "that was the last bad character" and each was wrong. A sentinel is
    # cause-agnostic and also covers "python3 missing, so no output at all".
    sys.stdout.write("END\n")
    sys.stdout.flush()
    sys.exit(code)

def emit(*fields):
    sys.stdout.write("\x1f".join(_sanitize(f) for f in fields) + "\n")

# Defined here (ahead of ALLOWED_CHARS/_hr_describe_bad_chars further down,
# which need ALLOWED_CHARS to exist first) because the config-load emit()
# calls immediately below run BEFORE ALLOWED_CHARS is ever reached and
# already need it -- see the PEP-383 comment above cfg_path/team_paths_path/
# workdir for why those three variables specifically require this.
def _hr_safe_repr(v):
    # ASCII-safe stand-in for any string that might not survive encoding to
    # THIS PROCESS'S stdout, for splicing into an emit() diagnostic without
    # risking a UnicodeEncodeError. `str(v)` first, so this also safely
    # handles non-string values (ints, exceptions, ...).
    #
    # ENCODE TO ascii, NOT utf-8, AND THAT DISTINCTION IS THE WHOLE POINT.
    # An earlier version used utf-8, which made this function SURROGATE-safe
    # but not ENCODING-safe: `backslashreplace` only escapes what the target
    # codec cannot represent, and utf-8 represents all valid non-ASCII, so
    # "cafeteam" with an e-acute passed through UNTOUCHED. stdout's encoding
    # comes from the LOCALE, not from this function, so under a non-UTF-8
    # locale that value then raised inside emit() anyway -- truncating the
    # record stream and failing the WHOLE restore closed, siblings included.
    # Measured (PR #821 review round 3): LC_ALL=en_US.US-ASCII, a team value
    # with one accented character, resolver dead, valid sibling never started.
    # PEP 538/540 coerce C/POSIX/unset to UTF-8, so this needs an explicitly
    # non-UTF-8 locale -- low reachability, not zero, and the LaunchAgent
    # environment is not ours to assume.
    #
    # ascii is the only codec that cannot be weaker than stdout's. It is the
    # identity transform for all 128 ASCII codepoints (verified exhaustively,
    # not sampled), so no message any inventoried value can produce changes;
    # a legitimate non-ASCII path in a diagnostic now renders escaped rather
    # than killing the run, which is the correct trade.
    #
    # THIS IS THE THIRD RECURRENCE OF ONE CLASS ON THIS BRANCH: the allowlist
    # paths were made safe while the legacy branch ahead of them was not; then
    # 8 env-derived emit() sites were found where 2 were reported; then this.
    # If you are about to add a fourth exception, the fix is almost certainly
    # at the protocol boundary (_sanitize/emit), not another call site.
    return str(v).encode("ascii", "backslashreplace").decode("ascii", "replace")

# ── Load config ──────────────────────────────────────────────────────────
if not os.path.exists(cfg_path):
    emit("STATE", "absent", f"no config at {_hr_safe_repr(cfg_path)}")
    _finish(0)

try:
    # encoding="utf-8" is REQUIRED, not stylistic. open() otherwise decodes
    # using the LOCALE's encoding, so under a non-UTF-8 locale a perfectly
    # valid UTF-8 config raised UnicodeDecodeError HERE -- before validation
    # ever ran -- truncating the record stream and failing the whole restore
    # closed. JSON is defined as UTF-8 (RFC 8259), so the locale has no
    # business deciding how it is read. Every json read in this file is
    # pinned for the same reason; see _hr_safe_repr for the write half.
    with open(cfg_path, "r", encoding="utf-8") as fh:
        raw = fh.read()
except (OSError, UnicodeDecodeError) as e:
    # UnicodeDecodeError is NOT an OSError -- it subclasses ValueError -- so
    # a config file containing byte-invalid UTF-8 (independent of, and just
    # as reachable as, the locale mismatch the comment above already fixed)
    # used to fall straight through this handler as an unhandled exception:
    # raw traceback, no STATE record, no END sentinel, the whole restore
    # failing closed exactly like every other instance of this ticket's
    # class rather than landing on the clean "malformed_json" outcome this
    # code already intends for a syntactically-invalid config (PR #821
    # review round 4). str(e) on either exception type embeds the filename
    # (cfg_path) or the raw offending bytes, so the message still needs
    # _hr_safe_repr -- same as the OSError branch it replaces.
    emit("STATE", "malformed_json", f"could not read {_hr_safe_repr(cfg_path)}: {_hr_safe_repr(e)}")
    _finish(0)

try:
    doc = json.loads(raw)
except Exception as e:
    emit("STATE", "malformed_json", f"{_hr_safe_repr(cfg_path)}: {_hr_safe_repr(e)}")
    _finish(0)

if not isinstance(doc, dict):
    emit("STATE", "malformed_root", f"{_hr_safe_repr(cfg_path)}: root is {type(doc).__name__}, expected object")
    _finish(0)

emit("STATE", "ok", _hr_safe_repr(cfg_path))

schema_version = doc.get("schema_version", 1)
# schema_version is attacker/config-controlled JSON, not env-derived --
# but json.loads happily decodes a "\ud800"-style escape into the same
# kind of lone surrogate, so it needs the identical safe-repr treatment
# even though the PEP-383 comment above doesn't apply to it directly.
emit("SCHEMA", _hr_safe_repr(schema_version))

# lock_after_login — must be a real boolean, else treated as absent -> false.
lock_raw = doc.get("lock_after_login", False)
if isinstance(lock_raw, bool):
    lock_value = lock_raw
else:
    emit("WARN", f"'lock_after_login' is not a boolean (got {type(lock_raw).__name__}); treated as false")
    lock_value = False
emit("LOCK", "true" if lock_value else "false")

# autostart — must be an array, else treated as empty (restore does nothing,
# lock is UNAFFECTED — §1.4).
autostart_raw = doc.get("autostart", [])
if not isinstance(autostart_raw, list):
    emit("WARN", f"'autostart' is not an array (got {type(autostart_raw).__name__}); restore will do nothing")
    autostart_raw = []

# ── Registry (team-paths.json) for gate 2 — read-only, tolerant ───────────
registry_teams = None
registry_state = "missing"
if os.path.exists(team_paths_path):
    try:
        with open(team_paths_path, "r", encoding="utf-8") as fh:
            reg_doc = json.load(fh)
        teams = reg_doc.get("teams") if isinstance(reg_doc, dict) else None
        if isinstance(teams, dict):
            registry_teams = set(teams.keys())
            registry_state = "ok"
        else:
            registry_state = "unparseable"
    except Exception:
        registry_state = "unparseable"
emit("REGISTRY", registry_state)
if registry_state != "ok":
    # team_paths_path is env-derived (PEP-383 surrogateescape) -- see the
    # comment above cfg_path/team_paths_path/workdir.
    emit("WARN", f"team-paths.json ({_hr_safe_repr(team_paths_path)}) is {registry_state} — gate 2 (runtime-id "
                 f"cross-check) skipped for all entries; gate 1 alone decides validity (§3 'Gate 2 "
                 f"failing OPEN')")

# ─────────────────────────────────────────────────────────────────────────
# VALIDATION: TWO LAYERS, TWO CLOSED REMITS (XACA-1096-005 — owner ruling)
# ─────────────────────────────────────────────────────────────────────────
# Subitem -004 proved subsumption exhaustively: all 8 characters in
# BAD_CHARS (defined just below) are also rejected by ALLOWED_CHARS
# (defined further below) — checked 8/8. But the relation is STRICT
# CONTAINMENT, not equivalence: ALLOWED_CHARS additionally rejects 55 of
# the other 120 ASCII codepoints (comma, space, and '/' among them) plus
# effectively all non-ASCII. On that evidence alone, BAD_CHARS could be
# deleted with zero change in accept/reject behavior for every input this
# resolver has ever seen.
#
# The owner ruled to keep it anyway — and gave each layer its own closed
# remit instead of a shared, growing one:
#
#   ALLOWED_CHARS = [A-Za-z0-9._-]  ->  the IDENTIFIER POLICY.
#     Answers "what is a valid team id / arg?" It is legitimately open to
#     revision if the fleet's naming conventions ever change — see its own
#     comment block below for the inventory evidence that backs today's
#     set, and re-run that inventory before touching it.
#
#   BAD_CHARS (below)  ->  PROTOCOL INTEGRITY.
#     Answers "what breaks the \x1f/\x1e record protocol, or the
#     hand-built JSON in cmd_restore's summary?" It is CLOSED. It must
#     never grow a 9th character.
#
# THE GUARDRAIL THIS SUBITEM EXISTS TO INSTALL: if you are ever tempted to
# add a 9th character to BAD_CHARS, that impulse is by definition an
# ALLOWED_CHARS question, not a BAD_CHARS one. Doing an identifier
# policy's job with a protocol-integrity denylist is exactly how BAD_CHARS
# accreted one character per review round across five rounds — with four
# straight rounds each wrongly declaring "that was the last one" (full
# history in ALLOWED_CHARS's own comment block below). Take the new
# character to ALLOWED_CHARS instead, and re-run the inventory that backs
# it.
#
# Why not just delete BAD_CHARS, given the proven subsumption? Because
# ALLOWED_CHARS is deliberately left open to widen if naming conventions
# change, and BAD_CHARS is what still stands between the wire protocol and
# a bad day if someone widens it carelessly. A closed backstop that can
# never grow is cheap insurance against an open policy that is allowed to.
# ─────────────────────────────────────────────────────────────────────────
#
# Rejects the delimiter set AND the two characters that would break the
# hand-built JSON fragments in cmd_restore's summary ('"' and backslash).
# Without those two, a team name containing a double quote produced invalid
# JSON, _hr_write_state's json.loads threw, NO state file was written, and
# login_session_stamp was therefore never recorded — permanently disabling
# guard 1 on every later run, from one typo. `team` also composes a filesystem
# path and reaches an argv, so this is defense in depth, not cosmetics.
# \x00 is rejected for a different reason than the rest: it does not desync the
# protocol, it is silently DELETED by bash's command substitution around
# _hr_resolve, so `a<NUL>b` reaches the gates as `ab` — a corrupted identifier
# that could match a different team than the one configured. No legitimate team
# id or argument can contain it, and unlike the surrogate case there is nothing
# to preserve, so rejecting at validation is the right layer here.
BAD_CHARS = set("\t\n\r\x1e\x1f\x00" + chr(34) + chr(92))

# ─────────────────────────────────────────────────────────────────────────
# ALLOWLIST (XACA-1096-003) — a SECOND, INDEPENDENT layer alongside
# BAD_CHARS, not a replacement for it. BAD_CHARS is a DENYLIST, and this
# file's own history is the argument against a denylist as the ONLY
# defense: it has grown one character at a time across five review rounds
# (\t \n \r \x1e \x1f \x00 '"' '\\'), and FOUR separate rounds each closed
# with "that was the last bad character that can break this protocol" —
# and each was wrong; the fifth shape (the surrogate that still gets
# through today) is what opened this ticket. A denylist can only enumerate
# failures somebody has already imagined. An allowlist bounds the INPUT
# SPACE itself, so the next character nobody has thought of yet is
# rejected by construction, not by being remembered.
#
# XACA-1096-001's inventory measured every value that legitimately reaches
# `team`/`args` fleet-wide — 3 machines, ~46 files, 4+ months of backups:
# 30 distinct team ids, 22 decomposed args, 24 distinct characters, ZERO
# outside [A-Za-z0-9._-]. That set is also a superset of the stricter
# ^[a-z0-9_]+$ already enforced independently by freelance-connect.sh and
# install-team.sh, so it does not admit anything those scripts would
# reject. Do not widen or narrow ALLOWED_CHARS without re-running that
# inventory — it is the only evidence backing this pattern.
#
# PATH-COMPOSITION HARDENING: `team` composes `script_path` later in this
# same resolver pass, at gate 1 (`os.path.join(workdir,
# f"{team}-startup.sh")`) — and cmd_restore's bash counterpart composes
# that same `<workdir>/<team>-startup.sh` shape again independently (its
# own `script_path="${KB_HOST_READY_WORKING_DIR}/${team}-startup.sh"`) and
# actually EXECUTES it via `_hr_run_with_deadline`. No BAD_CHARS character
# was ever '/' — it was never in scope for the wire-protocol problem
# BAD_CHARS was built to solve — so a `team` value like "../../tmp/evil"
# passed BAD_CHARS clean and composed a script_path OUTSIDE this script's
# working directory. ALLOWED_CHARS rejects '/' and closes that shape.
# Scope this claim correctly: host-ready.json lives under the invoking
# user's own ~/.aiteamforge/, so anyone able to write it already runs as
# that user — this is defense in depth against a MISTAKEN or malformed
# config, NOT a privilege-escalation fix, and must never be described as
# one.
#
# RULING (XACA-1096-005): retirement of BAD_CHARS was fully evaluated, not
# skipped — -004 proved the exhaustive 8/8 subsumption cited at the top of
# this validation section — and the owner declined it anyway. Proven-
# safe-to-remove and worth-removing are different questions; see the
# "VALIDATION: TWO LAYERS, TWO CLOSED REMITS" block above this file's
# validation section for why both layers stay, each with its own
# closed/open remit. BAD_CHARS still owns the specific "does this byte
# desync the \x1f/\x1e wire protocol" reasoning documented at its own
# definition above (its \x00 case in particular — silently deleted by
# bash's command substitution rather than rejected by either layer's
# character test — is NOT something an allowlist alone would catch on its
# own terms, since \x00 fails membership in ALLOWED_CHARS the same as any
# other character, but the REASON it must be rejected is protocol-specific
# and belongs to BAD_CHARS, permanently). ALLOWED_CHARS is not "defense in
# depth on top of" BAD_CHARS the way an earlier draft of this comment
# described it — the relationship is the other way round: ALLOWED_CHARS is
# the primary, revisable identifier policy, and BAD_CHARS is the closed,
# never-widen protocol-integrity backstop underneath it.
#
# THE SURROGATE TRAP — why the diagnostic itself has to be encoded before
# it reaches emit(), not just the fact that it was rejected:
#
# An allowlist DETECTS an unpaired surrogate character-by-character (e.g.
# "\ud800bad" fails membership immediately on its first character) — but
# naively reporting *which* value or character failed by interpolating it
# VERBATIM into the rejection message reintroduces the exact fifth shape
# this ticket exists to close. Measured: emitting str(team) raw for a
# value containing "\ud800" raises UnicodeEncodeError ("surrogates not
# allowed") from INSIDE emit() itself, uncaught anywhere in this loop,
# which aborts the python3 process mid-stream. That is indistinguishable
# from the resolver dying for any other reason — _hr_stream_complete()
# correctly fails closed on it — but a loud, DIAGNOSABLE rejection was the
# entire point of adding this layer, and instead you get a truncated
# stream and the root incident again, just wearing an allowlist's clothes.
#
# So every rejection diagnostic below -- INCLUDING the legacy BAD_CHARS branch,
# which runs first and is therefore the one that actually had to be fixed --
# routes the offending value AND any
# per-character detail through _hr_safe_repr()/_hr_describe_bad_chars()
# before it is spliced into an emit() call. `.encode("utf-8",
# "backslashreplace").decode("utf-8", "replace")` round-trips every
# legitimate Unicode character back to itself (verified: 'é' -> 'é', an
# emoji -> itself) and turns ONLY an unencodable lone surrogate into a
# literal, ASCII-safe backslash-u escape (verified: '\ud800' -> '\\ud800')
# — so operator-facing diagnostics stay readable for real Unicode while
# still never being able to raise. This is load-bearing, not cosmetic: an
# allowlist whose own diagnostic can crash the resolver is not a fix, it's
# a second way to trigger the same bug.
ALLOWED_CHARS = set(
    "abcdefghijklmnopqrstuvwxyz"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "0123456789._-"
)

# _hr_safe_repr() is defined earlier in this script (right after emit()),
# because the config-load emit() calls above ALLOWED_CHARS also need it —
# see the comment there.

def _hr_is_allowed(c):
    # THE one definition of ALLOWED_CHARS membership (XACA-1096-013). Three
    # call sites each independently wrote `c not in ALLOWED_CHARS` — the
    # `team` check, the `args` bad-value search, and this file's own
    # _hr_describe_bad_chars scan below — so a future change to what
    # ALLOWED_CHARS means could be applied to only two of the three. Route
    # all three through this single predicate (directly, or via
    # _hr_first_bad below) instead.
    return c in ALLOWED_CHARS

def _hr_first_bad(s):
    # First character in s that fails _hr_is_allowed, or None if s is
    # entirely clean. Used by the `team` check and the `args` bad-value
    # search, which only need a yes/no answer — see _hr_is_allowed.
    for c in s:
        if not _hr_is_allowed(c):
            return c
    return None

def _hr_describe_bad_chars(s):
    # Distinct disallowed characters in s, in first-seen order, each as
    # 'char' (U+XXXX) with the character itself passed through
    # _hr_safe_repr() first. Used to make a rejection name the SPECIFIC
    # character(s) that failed, not just "rejected", per XACA-1096-003.
    #
    # `seen` stays a list because the ORDER is deliberate (diagnostics
    # report characters in the order first encountered); `seen_set` is a
    # parallel set used ONLY for the membership test, so a pathological
    # input with many distinct disallowed characters doesn't pay an O(n)
    # list scan per character (XACA-1096-012). Both are updated together.
    seen = []
    seen_set = set()
    for c in s:
        if not _hr_is_allowed(c) and c not in seen_set:
            seen.append(c)
            seen_set.add(c)
    return ", ".join(f"'{_hr_safe_repr(c)}' (U+{ord(c):04X})" for c in seen)

def _hr_describe_chars_in(s, badset):
    # Generalizes _hr_describe_bad_chars() above to an explicit character
    # set rather than ALLOWED_CHARS-non-membership, so the legacy BAD_CHARS
    # branch (XACA-1096-015) can report the SAME '<char>' (U+XXXX) style
    # detail the allowlist branches already give, without depending on
    # ALLOWED_CHARS at all. Same first-seen ordering / seen_set dedup
    # rationale as _hr_describe_bad_chars.
    seen = []
    seen_set = set()
    for c in s:
        if c in badset and c not in seen_set:
            seen.append(c)
            seen_set.add(c)
    return ", ".join(f"'{_hr_safe_repr(c)}' (U+{ord(c):04X})" for c in seen)

# ── XACA-1380-003: entry SOURCE selection (static list vs run-markers) ────
# restore_mode: "static" (default; autostart list, byte-for-byte the old
# behaviour) | "last-running" (restore what the per-team startup/shutdown
# scripts recorded as RUNNING in the marker dir). Absent -> static. Invalid
# -> WARN + static (the operator's previously working behaviour).
#
# last-running + .armed present: ONLY markers are restored; the static list
# is IGNORED and zero markers means restore NOTHING (user stopped everything).
# last-running + .armed absent: first boot after upgrade, no startup has run
# the marker code yet -> fall back to the static list ("static-fallback").
# Markers feed the SAME per-entry loop below (BAD_CHARS, allowlist, gate1,
# gate2, already-up, budgets) -- no second validator. Marker-only checks
# (malformed / schema / host / prefix mismatch) become pre-skipped rows.
# Login NEVER deletes or edits a marker: stale ones stay as evidence.
# Armed + unreadable marker dir fails CLOSED (nothing restored); it must
# never fall back to static, which would start teams the user stopped.
restore_mode_raw = doc.get("restore_mode", None)
if restore_mode_raw is None:
    restore_mode = "static"
    _mode_note = "restore_mode absent"
elif restore_mode_raw in ("static", "last-running"):
    restore_mode = restore_mode_raw
    _mode_note = "restore_mode " + restore_mode_raw
else:
    emit("WARN", f"'restore_mode' must be \"static\" or \"last-running\" (got {_hr_safe_repr(repr(restore_mode_raw))}); treated as static")
    restore_mode = "static"
    _mode_note = "restore_mode invalid"

# auto_resume_claude (XACA-1380-005, opt-in, default false) and
# resume_stagger_seconds (int 0..120, default 8). Invalid values WARN and fall
# back to the safe default (false / 8) -- same rule as lock_after_login.
_resume_raw = doc.get("auto_resume_claude", False)
resume_enabled = False
if not isinstance(_resume_raw, bool):
    emit("WARN", f"'auto_resume_claude' is not a boolean (got {type(_resume_raw).__name__}); treated as false")
else:
    resume_enabled = _resume_raw
_stag_raw = doc.get("resume_stagger_seconds", 8)
if isinstance(_stag_raw, bool) or not isinstance(_stag_raw, int) or _stag_raw < 0 or _stag_raw > 120:
    emit("WARN", f"'resume_stagger_seconds' must be an integer 0..120 (got {_hr_safe_repr(repr(_stag_raw))}); treated as 8")
    _stag_raw = 8
emit("RESUME", "true" if resume_enabled else "false", str(_stag_raw))

def _hr_this_host():
    ov = os.environ.get("KB_HOST_READY_HOSTNAME")
    if ov:
        return ov
    import subprocess
    for cmd in (["scutil", "--get", "LocalHostName"], ["hostname", "-s"]):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout.strip()
            if out:
                return out
        except Exception:
            continue
    return ""

work = []   # (idx, entry_dict_or_None, preskip_reason_or_None, display_team)
source_kind = "static"
source_detail = _mode_note
def _hr_static_entry(e):
    # XACA-1380-020: "match" is a marker-only key (the writer validates it before storing). A static
    # autostart entry is hand-edited and unvalidated, and nothing in the static list legitimately
    # needs it, so it is dropped here -- the key can never steer gate 2 / the already-up probe.
    if isinstance(e, dict) and "match" in e:
        return {k: v for k, v in e.items() if k != "match"}
    return e

if restore_mode == "static":
    work = [(i, _hr_static_entry(e), None, "") for i, e in enumerate(autostart_raw)]
else:
    marker_dir = os.environ.get("KB_RUN_MARKER_DIR") or os.path.join(
        os.path.expanduser("~"), ".aiteamforge", "run", "teams-running")
    # Only ENOENT/ENOTDIR mean "never armed". Any other stat failure (EACCES on an
    # unreadable marker dir) is "armed but unreadable" and must fail CLOSED below.
    _armed_err = None
    try:
        os.stat(os.path.join(marker_dir, ".armed"))
        _is_armed = True
    except (FileNotFoundError, NotADirectoryError):
        _is_armed = False
    except OSError as _e:
        _is_armed = True
        _armed_err = _e
    if not _is_armed:
        source_kind = "static-fallback"
        source_detail = "last-running but never armed (no .armed in marker dir); using static autostart list"
        work = [(i, _hr_static_entry(e), None, "") for i, e in enumerate(autostart_raw)]
    else:
        source_kind = "last-running"
        try:
            if _armed_err is not None:
                raise _armed_err
            names = sorted(n for n in os.listdir(marker_dir)
                           if n.endswith(".json") and not n.startswith(".") and ".tmp." not in n)
        except OSError as e:
            names = None
            source_detail = f"armed but marker dir unreadable: {_hr_safe_repr(e)}"
            work = [(0, None, f"armed but marker dir {_hr_safe_repr(marker_dir)} is unreadable ({_hr_safe_repr(e)}); restoring NOTHING (never falling back to static)", "marker-dir")]
        if names is not None:
            this_host = _hr_this_host()
            source_detail = f"{len(names)} marker(s)" if names else "armed, no teams were running"
            for i, fname in enumerate(names):
                stem = fname[:-5]
                fpath = os.path.join(marker_dir, fname)
                def _skip(reason, team_disp=stem, i=i, fname=fname):
                    return (i, None, f"marker {_hr_safe_repr(fname)}: {reason}", _hr_safe_repr(team_disp))
                try:
                    with open(fpath, "r", encoding="utf-8") as fh:
                        mdoc = json.load(fh)
                except Exception:
                    if not filter_team:
                        work.append(_skip("malformed marker (unreadable or not valid JSON)"))
                    continue
                if not isinstance(mdoc, dict) or mdoc.get("schema_version") != 1:
                    if not filter_team:
                        work.append(_skip("malformed marker (root not an object or schema_version != 1)"))
                    continue
                m_team = mdoc.get("team")
                m_args = mdoc.get("args", [])
                if filter_team and m_team != filter_team:
                    continue
                m_host = mdoc.get("host")
                # FAIL CLOSED (XACA-1380-018): an unknown local host rejects every marker, it never
                # accepts them all. Armed + unknown host restores NOTHING (no static fallback).
                if not this_host:
                    work.append(_skip("cannot determine this host (scutil and hostname -s both failed); refusing to trust any marker"))
                    continue
                if not isinstance(m_host, str) or not m_host or m_host != this_host:
                    work.append(_skip(f"marker from another host '{_hr_safe_repr(m_host)}' (this host '{_hr_safe_repr(this_host)}')"))
                    continue
                # Only derive a prefix when team/args are clean: dirty values
                # fall through to the existing BAD_CHARS/allowlist rejections.
                if (isinstance(m_team, str) and m_team and isinstance(m_args, list)
                        and all(isinstance(a, str) and a for a in m_args)
                        and _hr_first_bad(m_team) is None
                        and all(_hr_first_bad(a) is None for a in m_args)):
                    derived = m_team + "".join("-" + a.lower() for a in m_args)
                    stored = mdoc.get("prefix")
                    if stored != derived or stem != derived:
                        work.append(_skip(f"prefix mismatch (file={_hr_safe_repr(stem)}, stored={_hr_safe_repr(stored)}, derived={_hr_safe_repr(derived)})"))
                        continue
                _mk = mdoc.get("match")
                if _mk is not None and (not isinstance(_mk, str) or not _mk or _hr_first_bad(_mk) is not None
                                        or _mk.startswith(".")):
                    work.append(_skip(f"invalid 'match' key {_hr_safe_repr(_mk)}"))
                    continue
                work.append((i, {"team": m_team, "args": m_args, "match": _mk}, None, ""))
emit("SOURCE", source_kind, source_detail)

# XACA-1380-019: upgrade gap. Once the host is armed, last-running restores ONLY marked teams, so a
# configured team that was already running before the upgrade (no marker until its next start) is
# silently dropped after a power loss. Surface the candidates: autostart teams with no marker.
# check/status probe liveness and WARN (never fail) when one is actually up.
if source_kind == "last-running" and names is not None:
    _marked = set(n[:-5] for n in names)
    _seen_um = set()
    for _e in autostart_raw:
        if not isinstance(_e, dict):
            continue
        _t, _a = _e.get("team"), _e.get("args", [])
        if (isinstance(_t, str) and _t and isinstance(_a, list) and all(isinstance(x, str) and x for x in _a)
                and _hr_first_bad(_t) is None and all(_hr_first_bad(x) is None for x in _a)):
            _p = _t + "".join("-" + x.lower() for x in _a)
            if _p not in _marked and _p not in _seen_um:
                _seen_um.add(_p)
                # XACA-1380-024: probe by the SAME session-ownership key the marker reader uses. A
                # project-template team (its startup script calls kb_run_marker_write --match) names
                # sessions <team>-<agent>, so the key is the instance id (== team), not team+args.
                _probe = _p
                try:
                    with open(os.path.join(workdir, f"{_t}-startup.sh"), "r", encoding="utf-8", errors="replace") as _sf:
                        if re.search(r"^[ \t]*kb_run_marker_write[ \t]+--match[ \t]", _sf.read(), re.M):
                            _probe = _t.lower()
                except OSError:
                    pass
                emit("UNMARKED", _t, _p, _probe)

for idx, entry, _preskip, _disp in work:
    if _preskip is not None:
        emit("ENTRY", idx, "SKIP", _disp, "", "", "FAIL", "SKIPPED", _preskip)
        continue
    if not isinstance(entry, dict):
        emit("ENTRY", idx, "SKIP", "", "", "", "FAIL", "SKIPPED", f"entry {idx} is not an object")
        continue

    team = entry.get("team")
    args = entry.get("args", [])

    if not isinstance(team, str) or not team or any(c in BAD_CHARS for c in team):
        # XACA-1096 (PR #821, both gate bots, independently): this legacy branch
        # runs BEFORE the allowlist check below, so it -- not the allowlist -- is
        # the first emit any rejected `team` reaches. It emitted str(team) RAW,
        # so a value carrying BOTH an unpaired surrogate AND any BAD_CHARS
        # character (e.g. "a\ud800\tb") never reached the safe path: emit()
        # raised UnicodeEncodeError, the stream truncated, and the END sentinel
        # correctly failed the WHOLE restore closed -- taking unrelated sibling
        # teams down with it. That is the XACA-1066 root incident, reachable
        # through the one path the surrogate-safe work had not covered.
        # _hr_safe_repr() is the identity transform for every ASCII value, so
        # this changes no message any real config can produce.
        emit("ENTRY", idx, "SKIP", _hr_safe_repr(team), "", "", "FAIL", "SKIPPED", f"entry {idx}: 'team' missing or not a clean string")
        continue

    if _hr_first_bad(team) is not None:
        emit("ENTRY", idx, "SKIP", _hr_safe_repr(team), "", "", "FAIL", "SKIPPED",
             f"entry {idx}: 'team' value '{_hr_safe_repr(team)}' rejected by allowlist "
             f"[A-Za-z0-9._-]: disallowed character(s) {_hr_describe_bad_chars(team)}")
        continue

    if filter_team and team != filter_team:
        continue

    if not isinstance(args, list):
        emit("ENTRY", idx, "SKIP", team, "", "", "FAIL", "SKIPPED", f"entry {idx} ({team}): 'args' must be an array of clean strings")
        continue

    # XACA-1096-015: this legacy BAD_CHARS branch used to report only "'args'
    # must be an array of clean strings" -- naming neither the arg INDEX, nor
    # its VALUE, nor the offending CHARACTER, unlike the allowlist branch
    # further below (which names all three, and unlike the `team` BAD_CHARS
    # branch above, whose offending value is at least visible via the
    # `($team)` / ENTRY-row rendering downstream). Bring it to parity using
    # the same surrogate-safe helpers (_hr_safe_repr / _hr_describe_chars_in)
    # the allowlist branch already relies on. The ORIGINAL substring is kept
    # verbatim and first, so nothing downstream that pins it breaks; the
    # detail is appended after it.
    _bad_char_arg = next(
        (
            (a_idx, a)
            for a_idx, a in enumerate(args)
            if not isinstance(a, str) or not a or any(c in BAD_CHARS for c in a)
        ),
        None,
    )
    if _bad_char_arg is not None:
        a_idx, a_val = _bad_char_arg
        if isinstance(a_val, str) and a_val:
            emit("ENTRY", idx, "SKIP", team, "", "", "FAIL", "SKIPPED",
                 f"entry {idx} ({team}): 'args' must be an array of clean strings: "
                 f"args[{a_idx}] value '{_hr_safe_repr(a_val)}' contains disallowed "
                 f"character(s) {_hr_describe_chars_in(a_val, BAD_CHARS)}")
        else:
            emit("ENTRY", idx, "SKIP", team, "", "", "FAIL", "SKIPPED",
                 f"entry {idx} ({team}): 'args' must be an array of clean strings: "
                 f"args[{a_idx}] is missing or not a clean string")
        continue

    _bad_arg = next(
        ((a_idx, a) for a_idx, a in enumerate(args) if _hr_first_bad(a) is not None),
        None,
    )
    if _bad_arg is not None:
        a_idx, a_val = _bad_arg
        emit("ENTRY", idx, "SKIP", team, "", "", "FAIL", "SKIPPED",
             f"entry {idx} ({team}): 'args[{a_idx}]' value '{_hr_safe_repr(a_val)}' rejected by "
             f"allowlist [A-Za-z0-9._-]: disallowed character(s) {_hr_describe_bad_chars(a_val)}")
        continue

    args_packed = "\x1e".join(args)
    prefix = team + "".join("-" + a.lower() for a in args)
    # Marker with an explicit session-match key (XACA-1380-017): the runtime id (gate2) and the
    # already-up probe use it; args_packed still carries the real args for the relaunch.
    if isinstance(entry.get("match"), str) and entry.get("match"):
        prefix = entry["match"].lower()

    # Gate 1 — startability: <workdir>/<team>-startup.sh exists, is a
    # regular file, and is readable.
    script_path = os.path.join(workdir, f"{team}-startup.sh")
    gate1 = "PASS" if (os.path.isfile(script_path) and os.access(script_path, os.R_OK)) else "FAIL"

    # Gate 2 — runtime-id cross-check, only when the registry is readable.
    if registry_teams is None:
        gate2 = "SKIPPED"
    elif prefix in registry_teams:
        gate2 = "PASS"
    else:
        gate2 = "FAIL"

    if gate1 == "PASS" and gate2 in ("PASS", "SKIPPED"):
        emit("ENTRY", idx, "OK", team, args_packed, prefix, gate1, gate2, "")
    else:
        reason_bits = []
        if gate1 == "FAIL":
            # script_path embeds workdir, which is env-derived (PEP-383
            # surrogateescape) -- see the comment above cfg_path/
            # team_paths_path/workdir. `team` itself is already known safe
            # here (it passed ALLOWED_CHARS above), but workdir is not.
            reason_bits.append(f"gate1 FAIL: {_hr_safe_repr(script_path)} not found/readable")
        if gate2 == "FAIL":
            reason_bits.append(f"gate2 FAIL: derived prefix '{prefix}' not in team-paths.json .teams")
        emit("ENTRY", idx, "SKIP", team, args_packed, prefix, gate1, gate2, "; ".join(reason_bits))
_finish(0)
PY
}

# ─────────────────────────────────────────────────────────────────────────────
# tmux idempotency probe (§4.2, §4.3, R7). Bounded: tmux has NO connect
# timeout, so a stale/hostile socket can block `list-sessions` forever
# (measured, XACA-0830-002). SIGKILL watchdog, both sides reaped — the bash
# equivalent of that ticket's zsh/zselect approach (this script is bash,
# §0.3).
#
# Echoes each live session name on the given socket, one per line. Always
# returns 0 (a probe timeout / dead socket / missing socket dir are all
# treated as "no sessions", which is the correct disposition — see §4.2).
# ─────────────────────────────────────────────────────────────────────────────
_hr_tmux_sessions() {
    local tmux_bin="$1" socket="$2"
    local tmp
    # portable: GNU mktemp -t rejects an X-less template (BSD accepts it)
    tmp="$(mktemp "${TMPDIR:-/tmp}/kbhostready.XXXXXX" 2>/dev/null)" || { warn "mktemp failed for tmux probe"; return 0; }

    ( "$tmux_bin" -L "$socket" list-sessions -F '#{session_name}' >"$tmp" 2>/dev/null ) &
    local tpid=$!
    # >/dev/null 2>&1 on the WHOLE watchdog subshell, not just the `kill`
    # inside it, is load-bearing: this subshell runs two statements
    # (sleep; kill), so bash does NOT exec-optimize it into a single
    # process — `sleep` runs as a grandchild that inherits this shell's
    # own stdout/stderr fds. If a caller reads our output via `$(...)`
    # (as `_hr_team_already_up` does below), that command substitution
    # will not see EOF and return until EVERY process holding the pipe's
    # write end closes it — including this orphaned `sleep`, even after we
    # `kill -9` its immediate parent below. Without this redirect, every
    # probe pays the FULL timeout on every call, not just the pathological
    # one — silently defeating the entire point of §4.2/R7 (measured: 3s on
    # a socket that never existed, which resolves in <10ms on its own).
    ( sleep "$KB_HOST_READY_PROBE_TIMEOUT"; kill -9 "$tpid" 2>/dev/null ) >/dev/null 2>&1 &
    local wpid=$!
    wait "$tpid" 2>/dev/null
    kill -9 "$wpid" 2>/dev/null
    wait "$wpid" 2>/dev/null

    cat "$tmp" 2>/dev/null
    rm -f "$tmp"
    return 0
}

# True (0) iff at least one live session on $socket equals $prefix or is
# "$prefix-<base>" (single hyphen-free word). Prefix-matching (not socket-existence)
# is required because two projects of one team share a socket (§4.2); it must be
# EXCLUSIVE so "x" is not "up" just because "x-y" is (XACA-1380-013).
_hr_team_already_up() {
    local tmux_bin="$1" socket="$2" prefix="$3" line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ "$line" = "$prefix" ]; then
            return 0
        fi
        # EXCLUSIVE match (XACA-1380-013): "<prefix>-<base>" with a ONE-word, hyphen-free base.
        # A longer sibling ("x-y-command" for prefix "x") is another team/project's session.
        case "$line" in
            "${prefix}-"*)
                case "${line#"${prefix}"-}" in
                    *-*) ;;
                    *) return 0 ;;
                esac
                ;;
        esac
    done <<< "$(_hr_tmux_sessions "$tmux_bin" "$socket")"
    return 1
}

# Run "$@" but SIGKILL it if it has not returned by $deadline_epoch. Both
# sides reaped. Used to bound each `<team>-startup.sh` invocation so a
# single hung script cannot silently consume the whole restore budget and
# leave `lock_after_login: true` unreached (§1.3 / §4.4).
_hr_run_with_deadline() {
    local deadline_epoch="$1"; shift
    local now remaining
    now=$(date +%s)
    remaining=$(( deadline_epoch - now ))
    if [ "$remaining" -le 0 ]; then
        return 124
    fi
    ( "$@" ) &
    local cpid=$!
    # See the identical note in _hr_tmux_sessions above: this subshell is
    # two statements, so `sleep` runs as a grandchild holding our stdout/
    # stderr fds unless explicitly redirected here — without it, a caller
    # reading this function's output via `$(...)` would block for the full
    # remaining budget even when "$@" returns almost immediately.
    ( sleep "$remaining"; kill -9 "$cpid" 2>/dev/null ) >/dev/null 2>&1 &
    local wpid=$!
    wait "$cpid" 2>/dev/null
    local status=$?
    kill -9 "$wpid" 2>/dev/null
    wait "$wpid" 2>/dev/null
    return $status
}

# ─────────────────────────────────────────────────────────────────────────────
# restore — §4
# ─────────────────────────────────────────────────────────────────────────────
cmd_restore() {
    local dry_run=0 filter_team=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=1; shift ;;
            --team)
                # bash 3.2: `shift 2` with $#==1 FAILS and does not shift, so $1
                # stays "--team" and this loop never terminates (measured: still
                # running at 8s with zero output). Validate before shifting.
                if [ $# -lt 2 ]; then
                    err "restore: --team requires a value"
                    return 2
                fi
                filter_team="$2"; shift 2 ;;
            *) err "restore: unknown argument '$1'"; return 2 ;;
        esac
    done

    local tmux_bin
    tmux_bin="$(_hr_resolve_tmux)" || { err "restore: tmux not found on this host"; return 1; }

    local resolved
    resolved="$(_hr_resolve "$filter_team")"
    if ! _hr_stream_complete "$resolved"; then
        err "restore: the config resolver did not run to completion (no END sentinel) — refusing to act on a truncated entry list, because the missing entries would look like they were never configured. Run: kb-host-ready.sh check"
        return 1
    fi

    local state=""
    local overall_rc=0
    local processed=0 skipped=0 started=0 already_up=0
    local deadline_epoch=$(( $(date +%s) + KB_HOST_READY_RESTORE_BUDGET ))
    local budget_exceeded=0
    _HR_STARTED_PREFIXES=""   # XACA-1380-005: prefixes THIS run started (auto-resume scope)
    # Summary JSON built incrementally for the state file (login step only).
    local summary_entries=""

    while IFS=$'\x1f' read -r rectype f1 f2 f3 f4 f5 f6 f7 f8; do
        case "$rectype" in
            STATE)
                state="$f1"
                if [ "$state" = "absent" ]; then
                    log "restore: no config at ${KB_HOST_READY_CONFIG} — nothing to do"
                fi
                if [ "$state" = "malformed_json" ] || [ "$state" = "malformed_root" ]; then
                    err "restore: config is malformed (${state}): $f2"
                    overall_rc=1
                fi
                ;;
            WARN)
                warn "restore: $f1"
                ;;
            SOURCE)
                _HR_LAST_RESTORE_SOURCE="$f1"
                log "restore: entry source = $f1 ($f2)"
                ;;
            ENTRY)
                local idx="$f1" status="$f2" team="$f3" args_packed="$f4" prefix="$f5" gate1="$f6" gate2="$f7" reason="$f8"
                if [ "$status" = "SKIP" ]; then
                    err "restore: entry $idx ($team) SKIPPED — $reason"
                    overall_rc=1
                    skipped=$((skipped + 1))
                    summary_entries="${summary_entries}{\"team\":\"$(_hr_json_str "$team")\",\"index\":${idx},\"outcome\":\"skipped\",\"reason\":\"invalid entry\"},"
                    continue
                fi

                processed=$((processed + 1))
                local socket="$team"
                local args=()
                if [ -n "$args_packed" ]; then
                    # IFS=$'\x1e' scoped to this one command only (command-prefix
                    # assignment) — never touches the function's own IFS.
                    IFS=$'\x1e' read -ra args <<< "$args_packed"
                fi

                if [ "$budget_exceeded" -eq 1 ]; then
                    err "restore: skipping entry $idx ($team) — restore budget (${KB_HOST_READY_RESTORE_BUDGET}s) already exceeded"
                    overall_rc=1
                    summary_entries="${summary_entries}{\"team\":\"$(_hr_json_str "$team")\",\"index\":${idx},\"outcome\":\"skipped\",\"reason\":\"budget exceeded\"},"
                    continue
                fi

                if _hr_team_already_up "$tmux_bin" "$socket" "$prefix"; then
                    log "restore: $team (prefix=$prefix) already up — skipping"
                    already_up=$((already_up + 1))
                    summary_entries="${summary_entries}{\"team\":\"$(_hr_json_str "$team")\",\"index\":${idx},\"outcome\":\"already_up\"},"
                    continue
                fi

                if [ "$dry_run" -eq 1 ]; then
                    log "restore --dry-run: would start $team (args: ${args[*]:-<none>}, prefix=$prefix)"
                    continue
                fi

                local script_path="${KB_HOST_READY_WORKING_DIR}/${team}-startup.sh"
                if [ ! -x "$script_path" ]; then
                    err "restore: $script_path is not executable — cannot start $team"
                    overall_rc=1
                    summary_entries="${summary_entries}{\"team\":\"$(_hr_json_str "$team")\",\"index\":${idx},\"outcome\":\"failed\",\"reason\":\"not executable\"},"
                    continue
                fi

                log "restore: starting $team (args: ${args[*]:-<none>})"
                # AITF_NO_ITERM_GUI=1 — headless restore. A launchd-time run
                # has no automatable iTerm2 window; without this the master
                # script's has_iterm_gui() can flip true mid-run if iTerm2 is
                # ALSO a login item racing us, and drive AppleScript at a
                # window that isn't ready (R3). Headless (tmux sessions
                # created, no tabs opened) satisfies "restore team sessions".
                # NOTE: do NOT write "${args[@]:-}" here. For an ARRAY that does
                # NOT expand to zero words when empty — it substitutes the empty
                # default as ONE word, so an argless team ("args": [], the
                # documented default for all six of them) would invoke its startup
                # script with a single empty argument. Harmless for the six that
                # ignore argv, but finance/legal/medical/mainevent each guard with
                # `if [ $# -lt 1 ]`, and $#==1 slips past that guard leaving
                # PROJECTID="" — turning a self-diagnosing refusal into a silently
                # wrong session, unattended, at login. Reachable as configured
                # today: bare `mainevent` is a key in team-paths.json, so it passes
                # gate 1 AND gate 2 and `check` reports all-clear. Branch on count.
                local rc=0
                if [ ${#args[@]} -gt 0 ]; then
                    AITF_NO_ITERM_GUI=1 _hr_run_with_deadline "$deadline_epoch" "$script_path" "${args[@]}" || rc=$?
                else
                    AITF_NO_ITERM_GUI=1 _hr_run_with_deadline "$deadline_epoch" "$script_path" || rc=$?
                fi
                if [ "$rc" -eq 0 ]; then
                    log "restore: $team started"
                    started=$((started + 1))
                    _HR_STARTED_PREFIXES="${_HR_STARTED_PREFIXES}${socket}"$'\t'"${prefix}"$'\n'
                    summary_entries="${summary_entries}{\"team\":\"$(_hr_json_str "$team")\",\"index\":${idx},\"outcome\":\"started\"},"
                else
                    err "restore: $team FAILED to start (exit $rc)"
                    overall_rc=1
                    summary_entries="${summary_entries}{\"team\":\"$(_hr_json_str "$team")\",\"index\":${idx},\"outcome\":\"failed\",\"reason\":\"exit ${rc}\"},"
                fi

                if [ "$(date +%s)" -ge "$deadline_epoch" ]; then
                    budget_exceeded=1
                fi
                ;;
        esac
    done <<< "$resolved"

    if [ "$state" = "absent" ]; then
        return 0
    fi

    log "restore: summary — processed=$processed started=$started already_up=$already_up skipped=$skipped"
    _HR_LAST_RESTORE_SUMMARY="[${summary_entries%,}]"
    return $overall_rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Lock mechanism resolution (§6.2) — PROBE ONLY. Never invokes the resolved
# mechanism. Prints one line: "<name>\t<detail>" where name is one of
# cgsession | login_framework | unavailable.
# ─────────────────────────────────────────────────────────────────────────────
_hr_resolve_lock_mechanism() {
    if [ -n "$KB_HOST_READY_LOCK_MECHANISM" ]; then
        printf 'env_override\t%s\n' "$KB_HOST_READY_LOCK_MECHANISM"
        return 0
    fi

    local cgsession="/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
    if [ -f "$cgsession" ] && [ -x "$cgsession" ]; then
        printf 'cgsession\t%s\n' "$cgsession"
        return 0
    fi

    # login.framework's binary is NOT on disk (it lives in the dyld shared
    # cache — `ls` on it fails while dlopen succeeds, which is why a naive
    # path check would wrongly conclude this is absent). Probe via
    # ctypes.CDLL + getattr; this ONLY resolves the symbol, it is never
    # called here.
    local probe
    probe=$(python3 - <<'PY' 2>/dev/null
import ctypes
try:
    lib = ctypes.CDLL("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login")
    getattr(lib, "SACSwitchToLoginWindow")
    print("ok")
except Exception:
    print("fail")
PY
)
    if [ "$probe" = "ok" ]; then
        printf 'login_framework\tSACSwitchToLoginWindow\n'
        return 0
    fi

    printf 'unavailable\tcgsession absent, login.framework/SACSwitchToLoginWindow not resolvable\n'
    return 1
}

# Actually PERFORMS the switch-to-login-window call. Only reached from
# cmd_lock, and only after every guard has passed. NEVER call this function
# for manual testing on a machine you are not prepared to lose the session
# on (M3Pro dev source: NEVER. M1Pro/M4Mini, by the owner: subitem 007).
_hr_invoke_lock() {
    local mechanism="$1" detail="$2"
    case "$mechanism" in
        cgsession|env_override)
            if [ "$mechanism" = "env_override" ]; then
                # Test-only path: env override names the mechanism, not a
                # binary to exec. Treat as a successful simulated lock so
                # subitem 005's tests can exercise the guards without ever
                # touching a real session.
                log "lock: KB_HOST_READY_LOCK_MECHANISM override ('$detail') — simulated, no real call made"
                return 0
            fi
            "$detail" -suspend
            return $?
            ;;
        login_framework)
            python3 - <<'PY'
import ctypes, sys
try:
    lib = ctypes.CDLL("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login")
    func = lib.SACSwitchToLoginWindow
    func.restype = ctypes.c_int
    ret = func()
    sys.exit(0 if ret == 0 else 1)
except Exception:
    sys.exit(1)
PY
            return $?
            ;;
        *)
            return 1
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# lock — §6
# ─────────────────────────────────────────────────────────────────────────────
cmd_lock() {
    local force=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=1; shift ;;
            *) err "lock: unknown argument '$1'"; return 2 ;;
        esac
    done

    local resolved lock_configured="false" state=""
    resolved="$(_hr_resolve "")"
    if ! _hr_stream_complete "$resolved"; then
        err "lock: the config resolver did not run to completion (no END sentinel) — refusing, since intent to lock cannot be read from a truncated stream (§2.2)"
        _HR_LAST_LOCK_REASON="resolver stream incomplete"
        return 1
    fi
    while IFS=$'\x1f' read -r rectype f1 f2; do
        case "$rectype" in
            STATE) state="$f1" ;;
            LOCK) lock_configured="$f1" ;;
        esac
    done <<< "$resolved"

    if [ "$state" = "malformed_json" ] || [ "$state" = "malformed_root" ]; then
        err "lock: config is malformed — refusing (see §2.2: no recorded intent to lock)"
        _HR_LAST_LOCK_STATUS="NOT_ATTEMPTED"
        _HR_LAST_LOCK_REASON="config malformed"
        return 1
    fi

    if [ "$lock_configured" != "true" ] && [ "$force" -ne 1 ]; then
        log "lock: lock_after_login is not true — nothing to do"
        _HR_LAST_LOCK_STATUS="NOT_ATTEMPTED"
        _HR_LAST_LOCK_REASON="lock_after_login not set"
        return 0
    fi

    if [ "$force" -ne 1 ]; then
        local epoch now age
        epoch="$(_hr_loginwindow_start_epoch)" || epoch=""
        if [ -n "$epoch" ]; then
            now=$(date +%s)
            age=$(( now - epoch ))
            if [ "$age" -gt "$KB_HOST_READY_MAX_SESSION_AGE" ]; then
                err "lock: refusing — current login session is ${age}s old, over the ${KB_HOST_READY_MAX_SESSION_AGE}s guard (§4.5 guard 2). Use --force for a deliberate manual lock."
                _HR_LAST_LOCK_STATUS="REFUSED_AGE"
                _HR_LAST_LOCK_REASON="session age ${age}s > ${KB_HOST_READY_MAX_SESSION_AGE}s"
                return 1
            fi
        else
            warn "lock: could not determine login session age — proceeding, since a missing/failed probe is not itself evidence of a mid-day reload"
        fi
    fi

    local mech_line name detail
    mech_line="$(_hr_resolve_lock_mechanism)"
    name="${mech_line%%$'\t'*}"
    detail="${mech_line#*$'\t'}"

    if [ "$name" = "unavailable" ]; then
        err "lock: no working mechanism resolved — $detail"
        _HR_LAST_LOCK_STATUS="UNAVAILABLE"
        _HR_LAST_LOCK_REASON="$detail"
        return 1
    fi

    log "lock: invoking mechanism '$name' ($detail)"
    if _hr_invoke_lock "$name" "$detail"; then
        log "lock: mechanism returned success. NOTE (§6.2): this is NOT proof the login window was reached — a defaults-style read-back proves nothing here either. GUI verification on the actual host is the only proof."
        _HR_LAST_LOCK_STATUS="INVOKED"
        _HR_LAST_LOCK_REASON=""
        return 0
    else
        err "lock: mechanism '$name' returned failure"
        _HR_LAST_LOCK_STATUS="FAILED"
        _HR_LAST_LOCK_REASON="mechanism $name returned non-zero"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# auto-resume (XACA-1380-005) — opt-in, default OFF.
#
# After a restore, type `ccc` into each window whose Claude conversation was
# interrupted by the crash/power loss. A typed command is the one irreversible
# thing this script can do to a window, so the posture is "refuse unless EVERY
# check passes, and log a fixed reason" (design 5.2). Never guess.
#
# Inputs it trusts: the liveness markers written by claude_code_cc_aliases.sh
# (KB_CLAUDE_LIVE_DIR, default ~/.aiteamforge/run/claude-live/), one pipe line:
#   1|<uuid>|<pwd>|<socket>|<session_name>|<window_name>|<server_start>|<server_pid>|<set_epoch>
# and the XACA-1075 sidecars (~/.claude/terminal-sessions/<SESSION_CODE><sfx>),
# whose filename is the 1:1 join key with the marker's filename.
#
# The whole preflight + send loop is ONE python3 program (the same reason the
# resolver is: bash 3.2 has no assoc arrays, and a window/uuid join is exactly
# the place a quoting slip types into the wrong conversation).
#
# Examined markers are moved to claude-live/archive/<stamp>/ so a second reboot
# cannot resume them again. EXCEPTION: a marker whose recorded tmux server is
# still the LIVE server on that socket is left in place, untouched -- that
# window was never interrupted and its marker is the crash evidence for NEXT time.
# ─────────────────────────────────────────────────────────────────────────────
KB_CLAUDE_LIVE_DIR="${KB_CLAUDE_LIVE_DIR:-$HOME/.aiteamforge/run/claude-live}"
KB_HOST_READY_RESUME_BUDGET="${KB_HOST_READY_RESUME_BUDGET:-300}"
KB_HOST_READY_RESUME_SHELL_WAIT="${KB_HOST_READY_RESUME_SHELL_WAIT:-20}"
_HR_STARTED_PREFIXES=""      # "<socket>\t<prefix>\n" per team THIS run started
_HR_LAST_RESUME_SUMMARY=""   # JSON array for the state file

# $1 = dry-run (0|1), $2 = stagger seconds, $3 = login_session_stamp (archive dir name)
_hr_auto_resume() {
    local dry="${1:-0}" stagger="${2:-8}" stamp="${3:-}"
    local tmux_bin
    tmux_bin="$(_hr_resolve_tmux)" || { warn "resume: tmux not found on this host — nothing resumed"; return 0; }
    local out_json
    out_json="$(mktemp "${TMPDIR:-/tmp}/kbhostready-resume.XXXXXX" 2>/dev/null)" || { warn "resume: mktemp failed — nothing resumed"; return 0; }
    DRY="$dry" STAGGER="$stagger" STAMP="$stamp" TMUX_BIN="$tmux_bin" OUT_JSON="$out_json" \
        LIVE_DIR="$KB_CLAUDE_LIVE_DIR" CLAUDE_HOME="$HOME/.claude" \
        BUDGET="$KB_HOST_READY_RESUME_BUDGET" SHELL_WAIT="$KB_HOST_READY_RESUME_SHELL_WAIT" \
        PROBE_TIMEOUT="$KB_HOST_READY_PROBE_TIMEOUT" STARTED="$_HR_STARTED_PREFIXES" python3 - <<'PY'
import json, os, re, subprocess, sys, time

E = os.environ
DRY = E["DRY"] == "1"
TMUX = E["TMUX_BIN"]
LIVE = E["LIVE_DIR"]
CLAUDE = E["CLAUDE_HOME"]
TS_DIR = os.path.join(CLAUDE, "terminal-sessions")
PROJ = os.path.join(CLAUDE, "projects")

def _int(name, dflt):
    try:
        return max(0, int(E.get(name, dflt)))
    except ValueError:
        return dflt
STAGGER = _int("STAGGER", 8)
BUDGET = _int("BUDGET", 300)
SHELL_WAIT = _int("SHELL_WAIT", 20)
PROBE = _int("PROBE_TIMEOUT", 3) or 3

def now():
    return time.strftime("%Y-%m-%d %H:%M:%S")
def log(m):
    sys.stdout.write("[%s] %s\n" % (now(), m)); sys.stdout.flush()
def warn(m):
    sys.stderr.write("[%s] WARN: %s\n" % (now(), m)); sys.stderr.flush()

# Closed enum: one fixed reason per refusal.
TEXT = {
    "marker_malformed": "liveness marker is malformed or carries unsafe fields",
    "team_not_restored": "its team was not restored by this login",
    "no_pinned_uuid": "low-confidence session (no pinned uuid)",
    "window_id_key": "window-id key cannot be proven after a restart",
    "key_mismatch": "marker key does not match the window name",
    "sidecar_missing": "sidecar missing",
    "sidecar_uuid_mismatch": "sidecar uuid differs from the liveness marker",
    "transcript_missing": "sidecar transcript missing",
    "uuid_collision": "session uuid is held by more than one sidecar (collision)",
    "pwd_mismatch": "sidecar pwd differs from the launch-time pwd in the liveness marker",
    "pwd_missing": "launch-time directory no longer exists",
    "window_not_found": "window not found on the restored server",
    "window_not_unique": "window name is not unique on this server",
    "pane_not_at_shell": "pane not at a shell prompt",
    "budget_exceeded": "resume budget exceeded",
    "send_failed": "tmux send-keys failed",
}
TAIL = "Window restored without Claude; resume by hand with `ccc` after checking the sidecar."

SAFE = re.compile(r"^[A-Za-z0-9._-]+$")
UUID = re.compile(r"^[A-Za-z0-9_-]+$")
SHELLS = ("zsh", "bash", "-zsh", "-bash")

def tm(sock, *args):
    try:
        r = subprocess.run([TMUX, "-L", sock] + list(args), stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=PROBE)
        return r.returncode, r.stdout.decode("utf-8", "replace")
    except Exception:
        return 1, ""

def sanitize(s):
    # Mirror _cc_window_key: tr -c 'A-Za-z0-9._-' '_' (per BYTE).
    out = []
    for b in s.encode("utf-8"):
        c = chr(b)
        out.append(c if (b < 128 and (c.isalnum() or c in "._-")) else "_")
    return "".join(out)

def first_line(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.readline().rstrip("\n")
    except Exception:
        return None

started = []
for ln in E.get("STARTED", "").split("\n"):
    if "\t" in ln:
        a, b = ln.split("\t", 1)
        started.append((a, b))

def team_started(sock, session):
    for s, p in started:
        if s == sock and (session == p or session.startswith(p + "-")):
            return True
    return False

results = []
def finish():
    try:
        with open(E["OUT_JSON"], "w") as fh:
            json.dump(results, fh)
    except Exception as ex:
        warn("resume: could not write summary: %s" % ex)

try:
    names = sorted(n for n in os.listdir(LIVE)
                   if not n.startswith(".") and ".tmp" not in n and os.path.isfile(os.path.join(LIVE, n)))
except Exception:
    names = []
if not names:
    log("resume: no Claude liveness markers in %s — nothing to resume" % LIVE)
    finish(); sys.exit(0)

# uuid -> number of sidecars holding it (ALL sidecars, any suffix) — design 5.2 check 6.
uuid_count = {}
try:
    for n in os.listdir(TS_DIR):
        p = os.path.join(TS_DIR, n)
        if os.path.isfile(p):
            fl = first_line(p)
            if fl:
                u = fl.split("|", 1)[0]
                if u:
                    uuid_count[u] = uuid_count.get(u, 0) + 1
except Exception:
    pass

deadline = time.time() + BUDGET
last_send = None
archive = []
log("resume: examining %d Claude liveness marker(s)%s" % (len(names), " (dry-run: nothing will be sent)" if DRY else ""))

def preflight(name):
    """Return (None, ctx) when every check passes, else (reason, ctx)."""
    ctx = {"label": name}
    line = first_line(os.path.join(LIVE, name))
    f = line.split("|") if line else []
    if len(f) != 9 or f[0] != "1":
        return "marker_malformed", ctx
    uuid, pwd, sock, session, wname, sstart, spid = f[1], f[2], f[3], f[4], f[5], f[6], f[7]
    if not (SAFE.match(sock) and SAFE.match(session) and wname
            and (not uuid or UUID.match(uuid)) and pwd.startswith("/")):
        return "marker_malformed", ctx          # label stays the filename: never echo unsafe fields
    ctx["label"] = "%s:%s" % (session, wname)
    ctx.update(sock=sock, session=session)
    # (1) the marker must come from a DEAD server. Checked FIRST so a marker
    # belonging to a window that was never interrupted is never consumed,
    # whatever its team's restore outcome was.
    rc, out = tm(sock, "list-sessions", "-F", "#{start_time} #{pid}")
    if rc == 0 and out.strip():
        live = out.strip().splitlines()[0].split()
        if live == [sstart, spid]:
            return "LIVE", ctx
    if not team_started(sock, session):
        return "team_not_restored", ctx
    if not uuid:
        return "no_pinned_uuid", ctx
    if re.search(r"-w@[0-9]+$", name):
        return "window_id_key", ctx
    # XACA-1074-021: the -k<key> is session-qualified. Marker name = SESSION_CODE + "-k" + key,
    # key = <window> when the tmux session is named SESSION_CODE (canonical layout), else
    # <session>.<window>. Accept exactly those two shapes (mirrors _cc_qualify_key); a
    # qualified suffix under a name whose prefix equals the session is not a shape the
    # writer produces, so it is a mismatch.
    if name == session + "-k" + sanitize(wname):
        pass
    else:
        sfx = "-k" + sanitize(session + "." + wname)
        if not name.endswith(sfx) or len(name) == len(sfx) or name[:-len(sfx)] == session:
            return "key_mismatch", ctx
    sl = first_line(os.path.join(TS_DIR, name))
    if sl is None:
        return "sidecar_missing", ctx
    sf = sl.split("|")
    if sf[0] != uuid:
        return "sidecar_uuid_mismatch", ctx
    spwd = sf[2] if len(sf) > 2 else ""
    enc_a = re.sub(r"[/ ]", "-", spwd)            # claude's dir naming, leading dash kept
    enc_b = re.sub(r"[^A-Za-z0-9]", "-", spwd)    # defensive: any non-alnum
    if not spwd or not (os.path.isfile(os.path.join(PROJ, enc_a, uuid + ".jsonl"))
                        or os.path.isfile(os.path.join(PROJ, enc_b, uuid + ".jsonl"))):
        return "transcript_missing", ctx
    if uuid_count.get(uuid, 0) != 1:
        return "uuid_collision", ctx
    if spwd != pwd:
        return "pwd_mismatch", ctx
    if not os.path.isdir(pwd):
        return "pwd_missing", ctx
    rc, out = tm(sock, "list-windows", "-a", "-F",
                 "#{session_name}\t#{window_id}\t#{pane_id}\t#{@cc_window_key}\t#{window_name}")
    hits = []
    if rc == 0:
        for ln in out.splitlines():
            p = ln.split("\t", 4)
            if len(p) != 5:
                continue
            eff = p[3] if p[3] else p[4]
            # Same-named windows in OTHER sessions are legitimate since the key is
            # session-qualified (XACA-1074-021); only this marker's session competes.
            if p[0] == session and sanitize(eff) == sanitize(wname):
                hits.append(p)
    if len(hits) > 1:
        return "window_not_unique", ctx
    if len(hits) == 0 or hits[0][0] != session:
        return "window_not_found", ctx
    ctx["pane"] = hits[0][2]
    # (9) pane at a shell prompt, polled up to SHELL_WAIT (once in dry-run).
    end = time.time() + (0 if DRY else SHELL_WAIT)
    while True:
        rc, out = tm(sock, "display-message", "-p", "-t", ctx["pane"], "#{pane_current_command}")
        if rc == 0 and out.strip() in SHELLS:
            break
        if time.time() >= end:
            return "pane_not_at_shell", ctx
        time.sleep(1)
    return None, ctx

for name in names:
    if time.time() > deadline:
        reason, ctx = "budget_exceeded", {"label": name}
    else:
        reason, ctx = preflight(name)
    if reason == "LIVE":
        log("resume: %s — recorded tmux server is still live (window never interrupted); marker left untouched" % ctx["label"])
        results.append({"window": ctx["label"], "marker": name, "outcome": "skipped_live", "reason": "server_still_live"})
        continue
    if reason is not None:
        warn("resume: REFUSED %s (%s) — %s. %s" % (ctx["label"], name, TEXT[reason], TAIL))
        results.append({"window": ctx["label"], "marker": name, "outcome": "refused", "reason": reason})
        archive.append(name)
        continue
    if DRY:
        log("resume --dry-run: would send 'ccc' to %s (pane %s, marker %s)" % (ctx["label"], ctx["pane"], name))
        results.append({"window": ctx["label"], "marker": name, "outcome": "would_send"})
        continue
    if last_send is not None:
        wait = STAGGER - (time.time() - last_send)
        if wait > 0:
            time.sleep(wait)
    rc, _ = tm(ctx["sock"], "send-keys", "-t", ctx["pane"], "ccc", "Enter")
    last_send = time.time()
    if rc != 0:
        warn("resume: REFUSED %s (%s) — %s. %s" % (ctx["label"], name, TEXT["send_failed"], TAIL))
        results.append({"window": ctx["label"], "marker": name, "outcome": "refused", "reason": "send_failed"})
    else:
        log("resume: sent 'ccc' to %s (pane %s)" % (ctx["label"], ctx["pane"]))
        results.append({"window": ctx["label"], "marker": name, "outcome": "sent"})
    archive.append(name)

# Consume examined markers (never in dry-run, never a still-live one).
if archive and not DRY:
    stamp = re.sub(r"[^A-Za-z0-9._-]", "_", E.get("STAMP") or "") or time.strftime("%Y%m%d%H%M%S")
    adir = os.path.join(LIVE, "archive", stamp)
    try:
        os.makedirs(adir, exist_ok=True)
        for n in archive:
            os.replace(os.path.join(LIVE, n), os.path.join(adir, n))
        log("resume: archived %d examined marker(s) to %s" % (len(archive), adir))
    except Exception as ex:
        warn("resume: could not archive examined markers (%s) — a second reboot may resume them again" % ex)
sent = sum(1 for r in results if r["outcome"] == "sent")
ref = sum(1 for r in results if r["outcome"] == "refused")
log("resume: summary — sent=%d refused=%d" % (sent, ref))
finish()
PY
    local prc=$?
    if [ "$prc" -ne 0 ]; then
        warn "resume: the resume program exited $prc — some windows may not have been resumed (resume by hand with ccc)"
    fi
    _HR_LAST_RESUME_SUMMARY="$(cat "$out_json" 2>/dev/null)"
    rm -f "$out_json"
    return 0
}

# Read the RESUME record out of a resolved stream. Echoes "<true|false> <stagger>".
_hr_resume_cfg_from() {
    printf '%s\n' "$1" | awk -F$'\x1f' '$1=="RESUME"{print $2, $3; found=1; exit} END{if(!found) print "false 8"}'
}

# Standalone entry point: `kb-host-ready.sh resume [--dry-run]`. No restore ran in
# this process, so "started" is unknowable; scope is every resolved, gate-passing
# configured team that is CURRENTLY UP. Safety is unchanged (dead-server marker,
# shell-prompt pane, every other check); it is an explicit operator action.
cmd_resume() {
    local dry=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry=1; shift ;;
            *) err "resume: unknown argument '$1'"; return 2 ;;
        esac
    done
    local tmux_bin resolved cfg
    tmux_bin="$(_hr_resolve_tmux)" || { err "resume: tmux not found on this host"; return 1; }
    resolved="$(_hr_resolve "")"
    if ! _hr_stream_complete "$resolved"; then
        err "resume: the config resolver did not run to completion (no END sentinel) — refusing"
        return 1
    fi
    cfg="$(_hr_resume_cfg_from "$resolved")"
    if [ "${cfg%% *}" != "true" ]; then
        log "resume: auto_resume_claude is not true in ${KB_HOST_READY_CONFIG} — nothing to do"
        return 0
    fi
    _HR_STARTED_PREFIXES=""
    local rectype f1 f2 f3 f4 f5 f6 f7 f8
    while IFS=$'\x1f' read -r rectype f1 f2 f3 f4 f5 f6 f7 f8; do
        if [ "$rectype" = "ENTRY" ] && [ "$f2" = "OK" ]; then
            if _hr_team_already_up "$tmux_bin" "$f3" "$f5"; then
                _HR_STARTED_PREFIXES="${_HR_STARTED_PREFIXES}${f3}"$'\t'"${f5}"$'\n'
            fi
        fi
    done <<< "$resolved"
    _hr_auto_resume "$dry" "${cfg#* }" "manual-$(date +%Y%m%d%H%M%S)"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# login — the LaunchAgent's entry point. §4.4 sequence.
# ─────────────────────────────────────────────────────────────────────────────
cmd_login() {
    local force=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) force=1; shift ;;
            *) err "login: unknown argument '$1'"; return 2 ;;
        esac
    done

    # Guard 1 (§4.5): already ran for this login session? Bypassed by
    # --force. A missing/unreadable stamp never triggers this guard — only
    # an exact match does.
    local current_epoch prior_epoch
    current_epoch="$(_hr_loginwindow_start_epoch)" || current_epoch=""
    if [ "$force" -ne 1 ] && [ -n "$current_epoch" ]; then
        prior_epoch="$(_hr_read_state_field login_session_stamp)" || prior_epoch=""
        if [ -n "$prior_epoch" ] && [ "$prior_epoch" = "$current_epoch" ]; then
            log "login: already ran for this login session (stamp $current_epoch) — no-op. Use --force to re-run."
            return 0
        fi
    fi

    # Peek at config state before doing anything else, so the absent case
    # can be a true no-op — no state file, no directory, nothing (§1.4).
    local resolved_state
    # ONE resolver run for the whole login (XACA-1066-016). Set in cmd_login's
    # own scope so cmd_restore and cmd_lock — both called directly below, not in
    # a subshell — reuse this exact snapshot. Also removes the TOCTOU window
    # between deciding intent and acting on it.
    _HR_PRERESOLVED="$(_hr_resolve_uncached "")"
    _HR_PRERESOLVED_KEY=""
    if ! _hr_stream_complete "$_HR_PRERESOLVED"; then
        err "login: the config resolver did not run to completion (no END sentinel) — doing NOTHING this run. Neither restoring a partial team list nor locking on unreadable intent is safe, and both would be silent. Run: kb-host-ready.sh check"
        notify "kb-host-ready: config resolver failed to complete — no teams restored, no lock. Run: kb-host-ready.sh check"
        return 1
    fi
    resolved_state="$(printf '%s\n' "$_HR_PRERESOLVED" | awk -F$'\x1f' '$1=="STATE"{print $2; exit}')"
    if [ "$resolved_state" = "absent" ]; then
        log "login: no config at ${KB_HOST_READY_CONFIG} — nothing to do, touching nothing"
        return 0
    fi

    log "login: restoring configured teams (restore before lock — locking first would race the startup scripts, §4.4)"
    _HR_LAST_RESTORE_SUMMARY=""
    cmd_restore
    local restore_rc=$?

    local lock_status="NOT_ATTEMPTED" lock_reason=""
    _HR_LAST_LOCK_STATUS=""
    _HR_LAST_LOCK_REASON=""
    # Step 4 does not depend on step 3's outcome — a restore failure must
    # never suppress the lock attempt, or a restore bug becomes a privacy
    # hole on M1Pro (§4.4).
    log "login: restore step finished (rc=$restore_rc) — proceeding to lock step regardless"
    cmd_lock
    local lock_rc=$?
    lock_status="${_HR_LAST_LOCK_STATUS:-NOT_ATTEMPTED}"
    lock_reason="${_HR_LAST_LOCK_REASON:-}"

    # XACA-1380-005: login order is restore -> lock -> RESUME (design 3.6). The
    # lock above is the security property and never waits on a slow resume.
    # Opt-in (auto_resume_claude), only for teams this run STARTED, and a resume
    # problem never changes login's exit code (the team is up; only the
    # conversation is withheld).
    _HR_LAST_RESUME_SUMMARY=""
    local resume_cfg
    resume_cfg="$(_hr_resume_cfg_from "$_HR_PRERESOLVED")"
    if [ "${resume_cfg%% *}" = "true" ]; then
        log "login: lock step finished — proceeding to Claude auto-resume (opt-in)"
        _hr_auto_resume 0 "${resume_cfg#* }" "${current_epoch:-}"
    fi
    local overall_rc=0
    if [ "$restore_rc" -ne 0 ] || [ "$lock_rc" -ne 0 ]; then
        overall_rc=1
    fi
    # NOT_ATTEMPTED because lock_after_login was simply false is the normal,
    # healthy case (e.g. every M4Mini login) and must not flip the overall
    # exit code — cmd_lock already returns 0 for that case, so lock_rc is 0
    # there and this falls through correctly.

    # login's own exit contract explicitly lists "malformed config" as a
    # reason to exit 1 (§1.4's "autostart present but not an array" and
    # "lock_after_login present but not a boolean" rows both specify exit 1
    # even though the corresponding STEP behaves correctly — e.g. lock
    # legitimately does nothing because the field defaulted to false).
    # restore/lock's OWN narrower exit contracts (§5: "all desired teams
    # up" / "login window reached") don't need this — `check` is the
    # dedicated aggregate-everything gate — but login's contract does, so
    # check here explicitly rather than silently missing it.
    if [ "$overall_rc" -eq 0 ]; then
        local warn_count
        warn_count=$(printf '%s\n' "$_HR_PRERESOLVED" | awk -F$'\x1f' '$1=="WARN"' | wc -l | tr -d ' ')
        if [ "${warn_count:-0}" -gt 0 ]; then
            warn "login: config has ${warn_count} field-level warning(s) (see above) — flagging as incomplete per §1.4 even though the affected step correctly no-op'd"
            overall_rc=1
        fi
    fi

    _hr_write_state "${current_epoch:-}" "${_HR_LAST_RESTORE_SUMMARY:-}" "$lock_status" "$lock_reason" "$overall_rc" "${_HR_LAST_RESUME_SUMMARY:-}"

    if [ "$overall_rc" -ne 0 ]; then
        notify "kb-host-ready login finished with problems (restore_rc=$restore_rc, lock=$lock_status). See the LaunchAgent's StandardOutPath log, or run: kb-host-ready.sh status"
    fi

    return $overall_rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Seeded-but-never-customized NOTICE (XACA-1162, item 7 — severable, but
# included: without it a seeded config is only marginally more discoverable
# than the `suggest` hint the installer already prints at install time and
# already goes unread — see Point 5 of the decision doc). Best-effort only:
# never affects exit code either caller returns. A host that genuinely wants
# nothing IS healthy; this exists to make that state visible, not to fail it.
# ─────────────────────────────────────────────────────────────────────────────
_hr_seeded_unconfigured_notice() {
    [ -f "$KB_HOST_READY_CONFIG" ] || return 1
    CFG="$KB_HOST_READY_CONFIG" python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    with open(os.environ["CFG"], encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception:
    sys.exit(1)
if not isinstance(doc, dict):
    sys.exit(1)
sys.exit(0 if doc.get("_seeded_unconfigured") is True and doc.get("autostart") == [] else 1)
PY
}

# ─────────────────────────────────────────────────────────────────────────────
# status — read-only.
# ─────────────────────────────────────────────────────────────────────────────
cmd_status() {
    log "kb-host-ready status"
    log "  config file:        $KB_HOST_READY_CONFIG"
    log "  team-paths.json:    $KB_HOST_READY_TEAM_PATHS"
    log "  state file:         $KB_HOST_READY_STATE_FILE"

    local resolved state="" lock_configured="false" registry_state="" restore_source="" restore_source_detail=""
    local unmarked_live=""
    resolved="$(_hr_resolve "")"
    # A truncated stream must NOT be rendered as a complete picture (XACA-1066,
    # fifth shape). Without this, status printed a one-row table and
    # "config state: ok" at rc=0 for a config whose resolver had died — a
    # partial list shown as the whole truth, which is the quiet version of the
    # same defect that made restore drop a valid team.
    if ! _hr_stream_complete "$resolved"; then
        err "status: the config resolver did not run to completion (no END sentinel) — the entry list below is TRUNCATED and must not be read as complete. Run: kb-host-ready.sh check"
        return 1
    fi
    local tmux_bin
    tmux_bin="$(_hr_resolve_tmux 2>/dev/null)"

    printf '\n%-6s %-10s %-24s %-8s %-8s %-8s\n' "IDX" "STATUS" "TEAM(ARGS)" "GATE1" "GATE2" "LIVE?"
    while IFS=$'\x1f' read -r rectype f1 f2 f3 f4 f5 f6 f7 f8; do
        case "$rectype" in
            STATE) state="$f1" ;;
            LOCK) lock_configured="$f1" ;;
            REGISTRY) registry_state="$f1" ;;
            SOURCE) restore_source="$f1"; restore_source_detail="$f2" ;;
            WARN) warn "$f1" ;;
            UNMARKED)
                if [ -n "$tmux_bin" ] && _hr_team_already_up "$tmux_bin" "$f1" "${f3:-$f2}"; then
                    unmarked_live="${unmarked_live}${f2} "
                fi
                ;;
            ENTRY)
                local idx="$f1" st="$f2" team="$f3" args_packed="$f4" prefix="$f5" gate1="$f6" gate2="$f7"
                local live="n/a"
                if [ "$st" = "OK" ] && [ -n "$tmux_bin" ]; then
                    if _hr_team_already_up "$tmux_bin" "$team" "$prefix"; then
                        live="up"
                    else
                        live="down"
                    fi
                fi
                # args_packed is \x1e-delimited (unprintable); render it
                # comma-separated for humans. Display only — never re-parsed.
                local args_display="${args_packed//$'\x1e'/, }"
                printf '%-6s %-10s %-24s %-8s %-8s %-8s\n' "$idx" "$st" "${team}(${args_display})" "$gate1" "$gate2" "$live"
                ;;
        esac
    done <<< "$resolved"

    printf '\n'
    log "  config state:       ${state:-absent}"
    if [ "$state" = "ok" ] && _hr_seeded_unconfigured_notice; then
        log "  NOTICE:             seeded default, never customized; this host restores nothing and locks nothing. Run: kb-host-ready.sh suggest"
    fi
    log "  registry state:     ${registry_state:-n/a}"
    log "  restore source:     ${restore_source:-n/a} (${restore_source_detail:-})"
    if [ -n "$unmarked_live" ]; then
        warn "status: running with NO run-marker: ${unmarked_live% } — these will NOT be restored after a power loss until restarted once (XACA-1380-019)"
    fi
    log "  lock_after_login:   $lock_configured"

    local mech_line
    mech_line="$(_hr_resolve_lock_mechanism 2>/dev/null)"
    log "  lock mechanism:     ${mech_line/$'\t'/ -> }"

    if [ -f "$KB_HOST_READY_STATE_FILE" ]; then
        log "  last state file:"
        sed 's/^/    /' "$KB_HOST_READY_STATE_FILE"
    else
        log "  last state file:    none recorded yet"
    fi

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# check — validation only, zero side effects (§5, §2.2 "the gate a human runs")
# ─────────────────────────────────────────────────────────────────────────────
cmd_check() {
    local problems=0
    local resolved state="" lock_configured="false" registry_state="" restore_source=""
    local chk_tmux=""

    # A path that EXISTS but is not a regular file (classically a directory) is
    # NOT "absent": _hr_resolve reports malformed_json for it and cmd_lock then
    # refuses for want of recorded intent. `check` is the gate a human runs, so
    # it must not print all-clear on a state the login path rejects — that is
    # precisely the disagreement that makes a pre-flight check worthless.
    # A broken symlink stays in the "absent" bucket, which matches the login
    # path's own treatment of it.
    if [ -e "$KB_HOST_READY_CONFIG" ] && [ ! -f "$KB_HOST_READY_CONFIG" ]; then
        err "check: config path ${KB_HOST_READY_CONFIG} exists but is not a regular file — the login path treats this as malformed and will refuse to lock"
        return 1
    fi
    if [ ! -f "$KB_HOST_READY_CONFIG" ]; then
        log "check: no config at ${KB_HOST_READY_CONFIG} — nothing to validate (a host without this feature configured is healthy, not broken)"
        return 0
    fi

    resolved="$(_hr_resolve "")"
    # THE most important instance of this guard (XACA-1066, fifth shape).
    # restore/lock/login all tell the operator to "Run: kb-host-ready.sh check",
    # and the runbook calls check the reliable signal. Without this guard check
    # reported "all clear" at rc=0 on the very config that had just made login
    # refuse to do anything — the operator follows the instruction in the error
    # message and is told nothing is wrong. Note that check may exit non-zero
    # ANYWAY on such a config if a surviving entry happens to fail validation;
    # that is coincidence, not detection, and it disappears when the aborting
    # entry is last. This guard makes the detection explicit and unconditional.
    if ! _hr_stream_complete "$resolved"; then
        err "check: the config resolver did not run to completion (no END sentinel) — validation is INCOMPLETE and cannot be trusted. Some entries were never evaluated. Check ${KB_HOST_READY_CONFIG} for a value the resolver cannot encode (an unpaired surrogate such as \\ud800 is valid JSON but not valid UTF-8)."
        return 1
    fi
    while IFS=$'\x1f' read -r rectype f1 f2 f3 f4 f5 f6 f7 f8; do
        case "$rectype" in
            STATE)
                state="$f1"
                if [ "$state" = "malformed_json" ] || [ "$state" = "malformed_root" ]; then
                    err "check: FAIL — config is malformed ($state): $f2"
                    problems=$((problems + 1))
                fi
                ;;
            WARN)
                err "check: FAIL — $f1"
                problems=$((problems + 1))
                ;;
            LOCK) lock_configured="$f1" ;;
            REGISTRY) registry_state="$f1" ;;
            SOURCE) restore_source="$f1" ;;
            UNMARKED)
                [ -z "$chk_tmux" ] && chk_tmux="$(_hr_resolve_tmux 2>/dev/null)"
                if [ -n "$chk_tmux" ] && _hr_team_already_up "$chk_tmux" "$f1" "${f3:-$f2}"; then
                    warn "check: $f2 is running but has no run-marker — it will NOT be restored after a power loss until it is restarted once (XACA-1380-019)"
                fi
                ;;
            ENTRY)
                local idx="$f1" st="$f2" team="$f3" reason="$f8"
                if [ "$st" = "SKIP" ]; then
                    err "check: FAIL — entry $idx ($team): $reason"
                    problems=$((problems + 1))
                elif [ "$restore_source" != "static" ] && [ -n "$restore_source" ] \
                     && ! grep -qE '^[[:space:]]*kb_run_marker_write[[:space:]]+(--match[[:space:]]+[^[:space:]]+[[:space:]]+)?[A-Za-z"$]' "${KB_HOST_READY_WORKING_DIR}/${team}-startup.sh" 2>/dev/null; then
                    # Non-failing: an unwired/un-rendered startup script never
                    # writes a marker, so the team silently drops out of
                    # last-running restore after its next clean start.
                    warn "check: ${team}-startup.sh does not call kb_run_marker_write — $team will not be recorded as running in last-running mode"
                fi
                ;;
        esac
    done <<< "$resolved"

    if [ "$state" = "ok" ] && [ "$lock_configured" = "true" ]; then
        local mech_line name
        mech_line="$(_hr_resolve_lock_mechanism)"
        name="${mech_line%%$'\t'*}"
        if [ "$name" = "unavailable" ]; then
            err "check: FAIL — lock_after_login is true but no lock mechanism resolves on this host: ${mech_line#*$'\t'}"
            problems=$((problems + 1))
        else
            log "check: OK — lock mechanism resolves to '$name' (${mech_line#*$'\t'})"
        fi
    fi

    if [ "$state" = "ok" ]; then
        if [ -f "$KB_HOST_READY_PLIST" ]; then
            if "$KB_HOST_READY_LAUNCHCTL" list com.aiteamforge.host-ready >/dev/null 2>&1; then
                log "check: OK — LaunchAgent installed and registered with launchctl"
            else
                err "check: FAIL — plist exists at $KB_HOST_READY_PLIST but launchctl does not report it loaded; this config will never run automatically"
                problems=$((problems + 1))
            fi
        else
            err "check: FAIL — config exists but no LaunchAgent plist at $KB_HOST_READY_PLIST; this config will never run automatically (subitem 006/upgrade installs the mandatory-set plist)"
            problems=$((problems + 1))
        fi
    fi

    if [ "$state" = "ok" ] && _hr_seeded_unconfigured_notice; then
        log "check: NOTICE — seeded default, never customized; this host restores nothing and locks nothing. Run: kb-host-ready.sh suggest"
    fi

    if [ "$problems" -eq 0 ]; then
        log "check: all clear"
        return 0
    fi
    err "check: $problems problem(s) found"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# suggest — print a candidate config for THIS host, derived from
# team-machines.json. Writes nothing (§5.1).
# ─────────────────────────────────────────────────────────────────────────────
cmd_suggest() {
    local hostname
    hostname="$(scutil --get LocalHostName 2>/dev/null || hostname -s 2>/dev/null || echo "")"
    if [ -z "$hostname" ]; then
        err "suggest: could not determine local hostname"
        return 1
    fi

    log "suggest: candidates for host '$hostname' (case-insensitive match against ${KB_HOST_READY_TEAM_MACHINES})"
    log "suggest: NOTE — team-machines.json ids are already lowercased. Where a team takes a"
    log "suggest:        PROJECTID/GROUPID argument with meaningful case (e.g. mainevent), verify"
    log "suggest:        the real casing yourself before pasting this — this command cannot recover it."

    HOSTNAME_LOWER="$hostname" TEAMMACHINES="$KB_HOST_READY_TEAM_MACHINES" python3 - <<'PY'
import json, os, sys

path = os.environ["TEAMMACHINES"]
host = os.environ["HOSTNAME_LOWER"].lower()

# XACA-1096-017: `path` is env-derived (PEP-383 surrogateescape -- same door
# as cfg_path/team_paths_path/workdir in the resolver heredoc above, just a
# separate python3 process, so it needs its own copy of the same helper) and
# `e`'s message can embed it too. This heredoc is its OWN process, entirely
# independent of the resolver's `_hr_safe_repr()` -- defining a matching
# helper here is what closes this specific instance, since the resolver's
# fix cannot reach across a process boundary. Not currently reachable on
# APFS (os.path.exists() is always False for a surrogate-laden path, and
# open() raises OSError "Illegal byte sequence" before reaching here) --
# this is consistency work, not a live bug, but closing a known-open
# instance now is how a future refactor or a non-APFS mount does not become
# recurrence #4.
def _suggest_safe_repr(v):
    return str(v).encode("ascii", "backslashreplace").decode("ascii", "replace")

if not os.path.exists(path):
    print(json.dumps({"schema_version": 1, "autostart": [], "lock_after_login": False}, indent=2))
    sys.exit(0)

try:
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception as e:
    sys.stderr.write(f"suggest: could not parse {_suggest_safe_repr(path)}: {_suggest_safe_repr(e)}\n")
    sys.exit(1)

if not isinstance(doc, dict):
    sys.stderr.write(f"suggest: {_suggest_safe_repr(path)} root is not an object\n")
    sys.exit(1)

# §0.2 shapes, by known team id.
ARGLESS = {"academy", "android", "command", "dns", "firebase", "ios"}
ONE_ARG = {"finance", "legal", "mainevent", "medical"}
TWO_ARG = {"freelance"}
KNOWN = ARGLESS | ONE_ARG | TWO_ARG

ids_here = sorted(k for k, v in doc.items() if isinstance(v, str) and v.lower() == host)

def decompose(id_):
    for team in KNOWN:
        if id_ == team:
            return team, []
        if id_.startswith(team + "-"):
            rest = id_[len(team) + 1:]
            if team in ARGLESS:
                # Should not happen (argless teams have no suffix), but if
                # it does, treat the whole suffix as unexpected and skip.
                return None
            if team in ONE_ARG:
                return team, [rest]
            if team in TWO_ARG:
                if "-" not in rest:
                    return team, [rest]
                group, project = rest.split("-", 1)
                return team, [group, project]
    return None

decomposed = []
for id_ in ids_here:
    d = decompose(id_)
    if d is None:
        sys.stderr.write(f"suggest: WARN — '{id_}' does not match any known team-id shape; skipped (add it to KNOWN in kb-host-ready.sh if this is a new team)\n")
        continue
    decomposed.append((id_, d))

# Fold catalog aliases: an id that is a strict prefix (team name alone, with
# an underlying "-"-suffixed sibling also present) is the alias, not an
# instance — drop it (§5.1).
teams_with_instances = {team for _id, (team, args) in decomposed if args}
entries = []
seen = set()
for _id, (team, args) in decomposed:
    if not args and team in teams_with_instances:
        continue  # bare alias, e.g. "finance" when "finance-personal" is also present
    key = (team, tuple(a.lower() for a in args))
    if key in seen:
        continue
    seen.add(key)
    entries.append({"team": team, "args": args})

entries.sort(key=lambda e: (e["team"], e["args"]))
print(json.dumps({"schema_version": 1, "autostart": entries, "lock_after_login": False}, indent=2))
PY
}

# ─────────────────────────────────────────────────────────────────────────────
# init-config (XACA-1162) — seed ${KB_HOST_READY_CONFIG} WRITE-IF-ABSENT with
# an inert placeholder. This is what closes the gap this ticket exists to
# fix: XACA-1066 shipped the script and the plist through the tap's
# mandatory-materialize / mandatory-launchagent sets (both of which reach an
# already-installed box on `aiteamforge upgrade`), but nothing ever wrote
# ${KB_HOST_READY_CONFIG} itself — so the agent installed and loaded cleanly
# everywhere and did nothing everywhere, because "no config" and "no
# LaunchAgent" both look identical from inside a login-time no-op.
#
# Called from TWO sites, sharing this one implementation (no drift between
# fresh-install and upgrade, per feedback_install_time_provisioning_
# unreachable_from_upgrade.md):
#   - install-kanban.sh :: install_host_ready_launchagent()   (fresh install)
#   - aiteamforge-upgrade.sh :: provision_host_ready_config() (every upgrade,
#     unconditional, registered right after update_runtime_helpers)
#
# See the "CONFIG" section above the resolver for the exact seed shape and
# why `_seeded_unconfigured` MUST be present, and Point 4 of
# kanban/plans/XACA-1162/XACA-1162-004-*.md for why write-if-absent (never
# write-always, never merge) is the only safe contract for an unattended,
# nightly-run seeder touching a file the operator may have hand-tuned.
# ─────────────────────────────────────────────────────────────────────────────

# True (exit 0) when com.aiteamforge.host-ready.plist has a recorded
# opt-out. LIGHTWEIGHT MIRROR of _xaca0734_normalize_optout_line /
# _xaca0734_is_opted_out (homebrew-tap/libexec/lib/launchagents.sh) — not a
# source of that file, deliberately: this script ships standalone into
# ${AITEAMFORGE_DIR}/scripts on a consumer machine and also runs unmodified
# from the dev-team source tree with no tap checkout anywhere nearby, so it
# cannot assume FRAMEWORK_DIR/libexec/lib/launchagents.sh is reachable at
# runtime. Handles the same hand-edited-file realities the tap file does
# (CRLF, leading/trailing whitespace, blank lines, whole-line `#` comments)
# so a hand-edited opt-out sentinel is honoured the same way here as there.
_hr_init_config_opted_out() {
    local f="$KB_HOST_READY_OPTOUT_FILE"
    [ -f "$f" ] && [ -r "$f" ] || return 1
    local line norm
    while IFS= read -r line || [ -n "$line" ]; do
        norm="${line%$'\r'}"
        norm="${norm#"${norm%%[![:space:]]*}"}"
        norm="${norm%"${norm##*[![:space:]]}"}"
        [ -z "$norm" ] && continue
        case "$norm" in
            \#*) continue ;;
        esac
        if [ "$norm" = "com.aiteamforge.host-ready.plist" ]; then
            return 0
        fi
    done < "$f"
    return 1
}

# True (exit 0) when this install should have LaunchAgents at all — a
# DELIBERATELY PARTIAL mirror of _xaca0734_launchagents_applicable's marker 1
# (cockpit profile via WORKING_DIR/.install-profile). Marker 2 (the
# jq-dependent "LCARS Kanban declined" check reading .aiteamforge-config) is
# NOT mirrored: reproducing a fail-open, jq-gated JSON-key read a second time
# risks getting the fail-open direction subtly wrong in the copy, and the
# consequence of skipping it is low-severity either way — an unwanted seed is
# an inert file (empty autostart, lock_after_login=false) that nothing ever
# reads on a box with no LaunchAgents, not a functional defect. FAILS OPEN
# on a missing/unreadable marker, matching the tap gate's own direction: a
# false-close here would silently suppress seeding on a box that actually
# needs it, with no symptom to notice.
_hr_init_config_applicable() {
    local wd="$KB_HOST_READY_WORKING_DIR"
    local profile_file="${wd}/.install-profile"
    if [ -f "$profile_file" ] && [ -r "$profile_file" ]; then
        local profile
        profile="$(tr -d '[:space:]' < "$profile_file" 2>/dev/null || true)"
        if [ "$profile" = "cockpit" ]; then
            return 1
        fi
    fi
    return 0
}

cmd_init_config() {
    local dry_run=false quiet=false
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=true; shift ;;
            --quiet)   quiet=true; shift ;;
            *)
                err "init-config: unknown argument: $1"
                return 2
                ;;
        esac
    done

    # Write-if-absent (Point 4 of the decision doc): the ONLY write
    # condition. A file that already exists — seeded on a prior run, or
    # hand-authored — is never touched again, seeded or not.
    if [ -f "$KB_HOST_READY_CONFIG" ]; then
        [ "$quiet" = true ] || log "init-config: ${KB_HOST_READY_CONFIG} already exists — leaving it untouched"
        return 0
    fi

    # A path that EXISTS but is not a regular file (e.g. a directory) is
    # malformed, not absent — mirrors cmd_check's identical guard above.
    # Never "fix" it by clobbering; warn and move on.
    if [ -e "$KB_HOST_READY_CONFIG" ]; then
        warn "init-config: ${KB_HOST_READY_CONFIG} exists but is not a regular file — leaving it untouched"
        return 0
    fi

    if _hr_init_config_opted_out; then
        [ "$quiet" = true ] || log "init-config: com.aiteamforge.host-ready.plist is opted out (${KB_HOST_READY_OPTOUT_FILE}) — not seeding a config for a disabled agent (XACA-0734: intent is recorded, never inferred)"
        return 0
    fi

    if ! _hr_init_config_applicable; then
        [ "$quiet" = true ] || log "init-config: this install has no LaunchAgents (cockpit profile) — not seeding a config that could never run"
        return 0
    fi

    if [ "$dry_run" = true ]; then
        log "init-config: would seed ${KB_HOST_READY_CONFIG} (dry-run — writing nothing)"
        return 0
    fi

    local dir tmp
    dir="$(dirname "$KB_HOST_READY_CONFIG")"
    mkdir -p "$dir" 2>/dev/null || { warn "init-config: could not create ${dir} — not seeding"; return 0; }

    # Atomic write: mktemp in the SAME directory (so the final `mv` is a
    # same-filesystem rename, not a copy) + mv. Same idiom as
    # _hr_write_state above.
    tmp="$(mktemp "${dir}/.host-ready.json.XXXXXX" 2>/dev/null)" || { warn "init-config: mktemp failed in ${dir} — not seeding"; return 0; }

    cat > "$tmp" <<'SEED'
{
  "schema_version": 1,
  "_comment": "Seeded by aiteamforge with an EMPTY autostart: this machine restores nothing and locks nothing. This is a placeholder, not a configured host. Run 'kb-host-ready.sh suggest' for candidate entries, then edit this file and delete the _seeded_unconfigured key.",
  "_seeded_unconfigured": true,
  "autostart": [],
  "lock_after_login": false
}
SEED

    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        warn "init-config: seed write produced no output — not seeding"
        return 0
    fi

    if mv "$tmp" "$KB_HOST_READY_CONFIG"; then
        [ "$quiet" = true ] || log "init-config: seeded ${KB_HOST_READY_CONFIG} (empty autostart, lock_after_login=false — run 'kb-host-ready.sh suggest' to customize, then delete the _seeded_unconfigured key)"
    else
        rm -f "$tmp" 2>/dev/null
        warn "init-config: mv failed writing ${KB_HOST_READY_CONFIG} — not seeded"
    fi

    # Never fails the caller — install and upgrade must never abort over a
    # seeding hiccup (Point 4, guard 5).
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Dispatch
# ─────────────────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-}"
    if [ $# -gt 0 ]; then shift; fi

    case "$cmd" in
        login)              cmd_login "$@"; return $? ;;
        restore|reconcile)  cmd_restore "$@"; return $? ;;
        lock)                cmd_lock "$@"; return $? ;;
        resume)              cmd_resume "$@"; return $? ;;
        status)              cmd_status "$@"; return $? ;;
        check)                cmd_check "$@"; return $? ;;
        suggest)            cmd_suggest "$@"; return $? ;;
        init-config)  cmd_init_config "$@"; return $? ;;
        -h|--help|help|"")  usage; return 0 ;;
        *)
            err "unknown subcommand: $cmd"
            usage
            return 2
            ;;
    esac
}

main "$@"
exit $?
