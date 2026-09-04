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
#   kb-host-ready.sh status                 Read-only report. No side effects.
#   kb-host-ready.sh check                  Validation only, zero side
#                                           effects. The gate a human runs.
#   kb-host-ready.sh suggest                Print a candidate config for THIS
#                                           host, derived from
#                                           team-machines.json. Writes nothing.
#   kb-host-ready.sh -h | --help | help     This text.
#
# EXIT CODES
#   login    : 0 = everything asked for was done or already true, INCLUDING
#              the absent-config no-op. 1 = something did not complete.
#   restore  : 0 = all desired teams up. 1 = one or more not.
#   lock     : 0 = login window reached or already there. 1 = refused,
#              unavailable, or failed.
#   status   : 0 always, unless it cannot read what it needs to report.
#   check    : 0 = everything valid. 1 = any problem (one line each).
#   suggest  : 0.
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
    sed -n '2,40p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
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
    with open(os.environ["STATEFILE"]) as fh:
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
# fragments. Only the double quote and the backslash need handling: the
# resolver's BAD_CHARS already rejects every control character. Escaping HERE
# is the actual fix, because a REJECTED entry's team is still summarised on the
# skip path -- which is how a quoted team name produced invalid JSON, made the
# state write fail, and thereby permanently disabled guard 1 (the login-session
# stamp) on every subsequent run. BAD_CHARS is the second layer, not the fix.
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
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '%s' "$v"
}

_hr_write_state() {
    # $1=login_stamp_epoch $2=restore_json_summary $3=lock_status $4=lock_reason $5=exit_code
    local stamp="$1" restore_summary="$2" lock_status="$3" lock_reason="$4" exit_code="$5"
    local dir tmp
    dir="$(_hr_state_dir)"
    mkdir -p "$dir" 2>/dev/null || { warn "could not create state dir $dir"; return 1; }
    tmp="$(mktemp "${dir}/.host-ready.state.XXXXXX" 2>/dev/null)" || { warn "mktemp failed for state file"; return 1; }
    STAMP="$stamp" RESTORE="$restore_summary" LOCKSTATUS="$lock_status" LOCKREASON="$lock_reason" \
        EXITCODE="$exit_code" NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')" python3 - > "$tmp" <<'PY'
import json, os

def _restore_or_raw():
    raw = os.getenv("RESTORE")
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError as e:
        return {"parse_error": str(e), "raw": raw[:2000]}

doc = {
    "login_session_stamp": os.environ.get("STAMP") or None,
    "last_run_at": os.environ["NOW"],
    # NEVER let a malformed restore summary cost us the stamp: guard 1 depends
    # on this file existing, and a persistent write failure would disable it on
    # every later run. Degrade the summary to a diagnostic, never abort the doc.
    "restore": _restore_or_raw(),
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
import json, os, sys

cfg_path = os.environ["CFG"]
team_paths_path = os.environ["TEAMPATHS"]
workdir = os.environ["WORKDIR"]
filter_team = os.environ.get("FILTERTEAM") or ""

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
    return v.replace("\n", "\\n").replace("\r", "\\r").replace("\x1f", "\\x1f")

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

# ── Load config ──────────────────────────────────────────────────────────
if not os.path.exists(cfg_path):
    emit("STATE", "absent", f"no config at {cfg_path}")
    _finish(0)

try:
    with open(cfg_path, "r") as fh:
        raw = fh.read()
except OSError as e:
    emit("STATE", "malformed_json", f"could not read {cfg_path}: {e}")
    _finish(0)

try:
    doc = json.loads(raw)
except Exception as e:
    emit("STATE", "malformed_json", f"{cfg_path}: {e}")
    _finish(0)

if not isinstance(doc, dict):
    emit("STATE", "malformed_root", f"{cfg_path}: root is {type(doc).__name__}, expected object")
    _finish(0)

emit("STATE", "ok", cfg_path)

schema_version = doc.get("schema_version", 1)
emit("SCHEMA", schema_version)

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
        with open(team_paths_path, "r") as fh:
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
    emit("WARN", f"team-paths.json ({team_paths_path}) is {registry_state} — gate 2 (runtime-id "
                 f"cross-check) skipped for all entries; gate 1 alone decides validity (§3 'Gate 2 "
                 f"failing OPEN')")

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

for idx, entry in enumerate(autostart_raw):
    if not isinstance(entry, dict):
        emit("ENTRY", idx, "SKIP", "", "", "", "FAIL", "SKIPPED", f"entry {idx} is not an object")
        continue

    team = entry.get("team")
    args = entry.get("args", [])

    if not isinstance(team, str) or not team or any(c in BAD_CHARS for c in team):
        emit("ENTRY", idx, "SKIP", str(team), "", "", "FAIL", "SKIPPED", f"entry {idx}: 'team' missing or not a clean string")
        continue

    if filter_team and team != filter_team:
        continue

    if not isinstance(args, list) or not all(isinstance(a, str) and a and not any(c in BAD_CHARS for c in a) for a in args):
        emit("ENTRY", idx, "SKIP", team, "", "", "FAIL", "SKIPPED", f"entry {idx} ({team}): 'args' must be an array of clean strings")
        continue

    args_packed = "\x1e".join(args)
    prefix = team + "".join("-" + a.lower() for a in args)

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
            reason_bits.append(f"gate1 FAIL: {script_path} not found/readable")
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
    tmp="$(mktemp -t kbhostready 2>/dev/null)" || { warn "mktemp failed for tmux probe"; return 0; }

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

# True (0) iff at least one live session on $socket equals $prefix or begins
# with "$prefix-". Prefix-matching (not socket-existence) is required because
# two projects of one team share a socket (§4.2).
_hr_team_already_up() {
    local tmux_bin="$1" socket="$2" prefix="$3" line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [ "$line" = "$prefix" ]; then
            return 0
        fi
        case "$line" in
            "${prefix}-"*) return 0 ;;
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

    _hr_write_state "${current_epoch:-}" "${_HR_LAST_RESTORE_SUMMARY:-}" "$lock_status" "$lock_reason" "$overall_rc"

    if [ "$overall_rc" -ne 0 ]; then
        notify "kb-host-ready login finished with problems (restore_rc=$restore_rc, lock=$lock_status). See the LaunchAgent's StandardOutPath log, or run: kb-host-ready.sh status"
    fi

    return $overall_rc
}

# ─────────────────────────────────────────────────────────────────────────────
# status — read-only.
# ─────────────────────────────────────────────────────────────────────────────
cmd_status() {
    log "kb-host-ready status"
    log "  config file:        $KB_HOST_READY_CONFIG"
    log "  team-paths.json:    $KB_HOST_READY_TEAM_PATHS"
    log "  state file:         $KB_HOST_READY_STATE_FILE"

    local resolved state="" lock_configured="false" registry_state=""
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
            WARN) warn "$f1" ;;
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
    log "  registry state:     ${registry_state:-n/a}"
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
    local resolved state="" lock_configured="false" registry_state=""

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
            ENTRY)
                local idx="$f1" st="$f2" team="$f3" reason="$f8"
                if [ "$st" = "SKIP" ]; then
                    err "check: FAIL — entry $idx ($team): $reason"
                    problems=$((problems + 1))
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

if not os.path.exists(path):
    print(json.dumps({"schema_version": 1, "autostart": [], "lock_after_login": False}, indent=2))
    sys.exit(0)

try:
    with open(path) as fh:
        doc = json.load(fh)
except Exception as e:
    sys.stderr.write(f"suggest: could not parse {path}: {e}\n")
    sys.exit(1)

if not isinstance(doc, dict):
    sys.stderr.write(f"suggest: {path} root is not an object\n")
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
# Dispatch
# ─────────────────────────────────────────────────────────────────────────────
main() {
    local cmd="${1:-}"
    if [ $# -gt 0 ]; then shift; fi

    case "$cmd" in
        login)              cmd_login "$@"; return $? ;;
        restore|reconcile)  cmd_restore "$@"; return $? ;;
        lock)                cmd_lock "$@"; return $? ;;
        status)              cmd_status "$@"; return $? ;;
        check)                cmd_check "$@"; return $? ;;
        suggest)            cmd_suggest "$@"; return $? ;;
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
