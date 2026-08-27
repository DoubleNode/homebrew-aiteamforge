#!/usr/bin/env zsh
# shellcheck shell=bash
# lcars-spawn-ledger.sh — XACA-0988-001 append-only server.py spawn ledger.
#
# WHY THIS FILE EXISTS
# XACA-0988 is "LCARS duplicate server spawns on stray ports." Before this
# could be fixed, someone had to be able to answer "who spawned that?" — and
# nothing in the repo recorded parent PID, argv, env, or ancestry for a
# server.py launch. This file is the instrumentation substrate for that: it
# is sourced from every known server.py spawn site and appends one
# structured JSON-Lines record per spawn-relevant event.
#
# WHY A SEPARATE FILE FROM THE PER-TEAM SERVER LOG (XACA-0988-006)
# start_lcars_server() (scripts/lcars-launch-helpers.sh) unconditionally
# rotates ${team}'s server log at the top of every invocation (`mv -f … .old`,
# XACA-0661) — by design, so a fresh log only ever shows the CURRENT launch's
# server.py stderr. That rotation is exactly the hazard this ledger must not
# inherit: if spawn evidence lived in the same file, the very event an
# investigator is trying to diagnose (another launch happening) would destroy
# the evidence. This ledger is APPEND-ONLY. No code in this repository may
# truncate, rotate, or size-cap it. See XACA-0988-006's banner mechanism
# (_lcars_stamp_launch_banner in lcars-launch-helpers.sh) for the sibling fix
# that makes the ROTATED per-team log itself attribution-safe — this file and
# that mechanism share the SAME launch_id (_lcars_new_launch_id, below), so a
# single id ties a per-team-log launch banner to its ledger row.
#
# DUAL-SHELL PORTABILITY — MANDATORY
# This file is `source`d from BOTH zsh contexts (scripts/lcars-launch-helpers.sh,
# itself sourced by lcars-health-check.sh under zsh) and bash contexts (every
# `*/scripts/*-lcars-startup.sh` per-terminal script, `#!/usr/bin/env bash`).
# A sourced file's shebang is ignored — it always runs under the CALLER's
# shell (feedback: sourced shell helpers run under the caller shell, not
# their shebang). Every construct below must therefore work under BOTH bash
# 3.2 (macOS's shipped bash, which the startup scripts must support —
# feedback_verify_under_bin_bash_not_path_bash) and zsh:
#   - no arrays, no bash-4-only builtins (`${var,,}`, associative arrays, …)
#   - `local NAME=value` is NEVER used as the first statement of a loop body
#     (zsh echoes "NAME=value" to stdout on the 2nd+ iteration —
#     feedback_zsh_bare_local_in_loop); every `local` here is either outside
#     a loop or declared (no assignment) before the loop, assigned inside it.
#   - `${10}`-style braced two-digit positional parameters (both shells
#     require the braces; `$10` parses as `${1}0`).
#
# WHAT GETS RECORDED
# One JSON object per line (see _lcars_ledger_write) with: wall-clock
# timestamp, spawn SITE (which of the 3 known call paths), EVENT (what
# happened — attempt vs. result vs. skipped), the shared launch_id, resolved
# team/port/session, the spawned server's PID + PPID (once known), a
# human-readable argv reconstruction, the ambient SKIP_SERVER_START /
# SKIP_ATTACH values as seen at that call site, and an ancestor process
# chain walked from the invoking shell so "who ultimately triggered this" is
# answerable without guessing.
#
# TEST ISOLATION: LCARS_SPAWN_LEDGER_PATH overrides the resolved path — used
# by tests/test-xaca-0988-001-spawn-ledger.sh so test runs never touch the
# real fleet's ledger file.
#
# RETENTION / SIZE POLICY (XACA-0988-016)
# This file's own APPEND-ONLY invariant above is deliberate and this script
# must NEVER rotate, truncate, or size-cap the ledger itself — see "WHY A
# SEPARATE FILE" above for why: XACA-0661's per-launch rotation destroying
# the very evidence a spawn investigation needs is the defect this ticket
# exists to fix, and a ledger that quietly rotated itself out from under a
# runaway-spawn-loop investigation — the ONE scenario this ledger exists to
# diagnose, and the ONE scenario that grows it fastest and least boundedly —
# would recreate that exact defect at one remove, in the one file that is
# supposed to be immune to it.
#
# That does not mean unbounded growth is fine to ignore. The answer is
# observability, not automatic destruction, split two ways:
#   1. _lcars_ledger_write emits a LOUD, repeated warning to stderr (see
#      _lcars_ledger_maybe_warn_size, below) once the ledger crosses
#      LCARS_SPAWN_LEDGER_SIZE_WARN_BYTES (default 50 MiB). It keeps
#      appending regardless — a diagnostic write must never fail because of
#      its own size, per _lcars_ledger_write's existing `|| true` contract —
#      but the warning repeats on every subsequent write past the threshold
#      so it cannot be missed by anyone tailing server stderr or grepping
#      "[LCARS][ledger]" in a health-check sweep.
#   2. Retention, when it is ever actually needed, is an OPERATOR-RUN,
#      OUT-OF-BAND action this script never decides on its own — no cron, no
#      startup-time check, no code path here that fires it automatically.
#      An operator who has confirmed no active incident investigation still
#      needs the older rows can prune manually, e.g.:
#        tail -n 200000 "$LEDGER" > "${LEDGER}.pruned" && mv "${LEDGER}.pruned" "$LEDGER"
#      That boundary (a human types this, with eyes on the situation,
#      instead of the script running it unattended) is load-bearing, not
#      incidental — see the file header's WHY above.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _lcars_new_launch_id
#
# Emits a fresh, practically-unique id on stdout: second-resolution UTC time,
# the invoking shell's PID, and 4 bytes of real entropy from /dev/urandom.
#
# WHY NOT $RANDOM ALONE (the first version of this function used exactly
# that, and it collided in this ticket's own test suite): `$$` inside a
# `$(...)` command substitution is the PARENT shell's PID in BOTH bash and
# zsh — it does NOT vary between two nearby calls from the same long-lived
# parent shell (verified empirically). Worse, `$RANDOM`'s very FIRST read
# inside a forked command-substitution subshell reproduces the SAME value
# across two separate `$(...)` calls from that same parent, because the
# PRNG's internal state is cloned at fork time and the PARENT's own copy of
# that state never advances unless the parent itself reads $RANDOM directly.
# Two `_lcars_new_launch_id` calls of the OLD form back-to-back from one
# parent shell (e.g. lcars-health-check.sh's run_health_check restarting
# several unhealthy teams in one sweep — precisely the multi-spawn scenario
# XACA-0988 exists to diagnose) therefore risked emitting IDENTICAL launch
# ids. /dev/urandom is a real kernel entropy source, immune to shell-PRNG
# fork-state cloning, and is present on both macOS and Linux. Falls back to
# two concatenated $RANDOM reads (still forced to advance twice within the
# SAME subshell, unlike the collision case above, which read it only once)
# if /dev/urandom is ever unavailable — soft-degrading, never erroring.
# Not a cryptographic guarantee — none is needed; this id's only job is to
# let a human or a grep tie together the handful of log/ledger lines one
# launch produced.
# ---------------------------------------------------------------------------
_lcars_new_launch_id() {
    local _entropy
    _entropy="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    if [[ -z "${_entropy}" ]]; then
        _entropy="${RANDOM:-0}${RANDOM:-0}"
    fi
    printf 'lid-%s-%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$$" "${_entropy}"
}

# ---------------------------------------------------------------------------
# _lcars_ledger_path
#
# Resolves the ledger's on-disk path and prints it on stdout. Honors
# LCARS_SPAWN_LEDGER_PATH for test isolation; otherwise mirrors the portable
# base every other LCARS helper uses (AITEAMFORGE_DIR, default $HOME/dev-team)
# so dev machine and tap-installed consumer machines both resolve correctly.
# ---------------------------------------------------------------------------
_lcars_ledger_path() {
    if [[ -n "${LCARS_SPAWN_LEDGER_PATH:-}" ]]; then
        printf '%s' "${LCARS_SPAWN_LEDGER_PATH}"
        return 0
    fi
    local _base="${AITEAMFORGE_DIR:-$HOME/dev-team}"
    printf '%s' "${_base}/logs/lcars-spawn-ledger.jsonl"
}

# ---------------------------------------------------------------------------
# _lcars_json_escape_var <string> <out_var_name>
#
# Minimal JSON string-body escaper for the small, shell-controlled field set
# this ledger writes (no untrusted external input reaches it). Escapes
# backslash and double-quote, and flattens EVERY C0 control byte (0x00-0x1F)
# to a single space each — not just newline/tab — so one ledger row always
# occupies exactly one line and a strict JSON parser (python's json.loads,
# jq) never sees a raw control byte in a string body.
#
# XACA-0988-017: the original version flattened only \n and \t. Any OTHER
# C0 byte reaching a field — e.g. a `comm` value pulled from `ps` while
# walking the ancestor chain below, which can legitimately contain odd bytes
# for some processes — reached the ledger raw and produced a line strict
# JSON parsers reject outright, defeating the ledger's entire purpose
# ("tooling must parse this"). Every byte in 0x01-0x1F is now flattened.
# 0x00 (NUL) is deliberately EXCLUDED: it cannot occur in a value sourced
# from `ps`/`awk`/shell argv (all NUL-terminated C strings, incapable of
# embedding one), and `${_s//$'\x00'/ }` is a hard parse error under macOS's
# shipped bash 3.2 ("bad substitution: no closing `}`" — confirmed
# empirically, feedback_verify_under_bin_bash_not_path_bash) — so including
# it would trade a hypothetical hole for a guaranteed crash on every call.
#
# XACA-0988-018: writes the result into the CALLER-NAMED variable ($2) via
# `printf -v`, instead of the caller capturing this function's stdout
# through `$(...)`. Every command substitution forks a subshell in both
# bash and zsh, even when the command inside is a builtin/function with no
# external calls of its own — _lcars_ledger_write previously paid that fork
# 13 times per write (once per field) on top of the ancestor-chain cost
# below. `printf -v "$name"` with a DYNAMIC variable name is honored by both
# bash 3.2 and zsh 5.9 (verified) and does the same job with zero forks.
# ---------------------------------------------------------------------------
_lcars_json_escape_var() {
    local _s="${1:-}"
    _s="${_s//\\/\\\\}"
    _s="${_s//\"/\\\"}"
    _s="${_s//$'\x01'/ }"
    _s="${_s//$'\x02'/ }"
    _s="${_s//$'\x03'/ }"
    _s="${_s//$'\x04'/ }"
    _s="${_s//$'\x05'/ }"
    _s="${_s//$'\x06'/ }"
    _s="${_s//$'\x07'/ }"
    _s="${_s//$'\x08'/ }"
    _s="${_s//$'\t'/ }"
    _s="${_s//$'\n'/ }"
    _s="${_s//$'\x0b'/ }"
    _s="${_s//$'\x0c'/ }"
    _s="${_s//$'\x0d'/ }"
    _s="${_s//$'\x0e'/ }"
    _s="${_s//$'\x0f'/ }"
    _s="${_s//$'\x10'/ }"
    _s="${_s//$'\x11'/ }"
    _s="${_s//$'\x12'/ }"
    _s="${_s//$'\x13'/ }"
    _s="${_s//$'\x14'/ }"
    _s="${_s//$'\x15'/ }"
    _s="${_s//$'\x16'/ }"
    _s="${_s//$'\x17'/ }"
    _s="${_s//$'\x18'/ }"
    _s="${_s//$'\x19'/ }"
    _s="${_s//$'\x1a'/ }"
    _s="${_s//$'\x1b'/ }"
    _s="${_s//$'\x1c'/ }"
    _s="${_s//$'\x1d'/ }"
    _s="${_s//$'\x1e'/ }"
    _s="${_s//$'\x1f'/ }"
    printf -v "${2}" '%s' "${_s}"
}

# ---------------------------------------------------------------------------
# _lcars_json_escape <string>
#
# Back-compat wrapper around _lcars_json_escape_var with the ORIGINAL
# print-to-stdout interface, for any caller (tests, a future call site) that
# wants a plain `$(...)`-captured result and doesn't need the zero-fork
# path. _lcars_ledger_write itself calls _lcars_json_escape_var directly and
# never goes through this wrapper.
# ---------------------------------------------------------------------------
_lcars_json_escape() {
    local _out
    _lcars_json_escape_var "${1:-}" _out
    printf '%s' "${_out}"
}

# ---------------------------------------------------------------------------
# _lcars_ancestor_chain [pid] [max_hops]
#
# Walks the process ancestry of [pid] (default: the calling shell, $$) up to
# [max_hops] (default 15) generations, emitting "pid:comm <- pid:comm <- …"
# on stdout. Stops early at pid 1 (launchd/init) or when `ps` can no longer
# resolve the current pid (already reaped). This answers "who ultimately
# triggered this spawn" without asserting a specific ancestor is *the*
# trigger — the raw chain is the evidence; interpretation is left to whoever
# reads the ledger during an incident review.
#
# Portable `ps -o ppid=,comm= -p <pid>` invocation — works under both macOS
# BSD ps and Linux procps without GNU-only flags.
#
# XACA-0988-018: each hop previously forked 3 processes — the unavoidable
# `ps` call, PLUS two separate `awk` calls (one to pull ppid, one to pull
# comm) — so a full 15-hop chain could cost ~45 forks on the server spawn
# path. The two `awk` calls are replaced below with a single `read -r _ppid
# _comm <<< "${_ps_out}"`: a shell BUILTIN, not a fork. `read` with two
# target variables gives the first var the first whitespace-delimited field
# (ppid) and gives the LAST var the entire REMAINDER of the line verbatim —
# same behavior as the old `awk '{$1=""; sub(/^ /,"")}'` for a multi-word
# comm (e.g. "Google Chrome Helper"), including the empty-`_ps_out` early-
# exit case. Verified identical under both bash 3.2 and zsh 5.9. This drops
# per-hop cost from 3 forks to 1 (the `ps` call itself — irreducible, since
# there is no builtin that reads another process's ancestry).
# ---------------------------------------------------------------------------
_lcars_ancestor_chain() {
    local _pid="${1:-$$}"
    local _max_hops="${2:-15}"
    local _chain=""
    local _cur="${_pid}"
    local _hop=0
    local _ps_out _ppid _comm
    while [[ -n "${_cur}" ]] && [[ "${_cur}" != "0" ]] && [[ "${_hop}" -lt "${_max_hops}" ]]; do
        _ps_out="$(ps -o ppid=,comm= -p "${_cur}" 2>/dev/null)"
        if [[ -z "${_ps_out}" ]]; then
            _chain="${_chain}${_chain:+ <- }${_cur}:?"
            break
        fi
        _ppid=""
        _comm=""
        read -r _ppid _comm <<< "${_ps_out}"
        _chain="${_chain}${_chain:+ <- }${_cur}:${_comm:-?}"
        if [[ -z "${_ppid}" ]] || [[ "${_ppid}" == "${_cur}" ]]; then
            break
        fi
        if [[ "${_ppid}" == "1" ]]; then
            _chain="${_chain} <- 1:launchd-or-init"
            break
        fi
        _cur="${_ppid}"
        _hop=$((_hop + 1))
    done
    printf '%s' "${_chain}"
}

# ---------------------------------------------------------------------------
# _lcars_ledger_maybe_warn_size <path>
#
# XACA-0988-016: this ledger is intentionally APPEND-ONLY and unbounded (see
# the RETENTION / SIZE POLICY section of the file header for why no code
# here may rotate/truncate/cap it). Unbounded is not the same as unwatched:
# emit a LOUD, un-throttled warning to stderr once the ledger crosses
# LCARS_SPAWN_LEDGER_SIZE_WARN_BYTES (default 50 MiB, overridable for tests)
# so a genuine runaway-spawn-loop — the ONE scenario this ledger exists to
# diagnose, and the one that grows it fastest — cannot go unnoticed. Fires
# on EVERY write past the threshold, deliberately: a one-shot warning is
# exactly the kind of thing that scrolls off a log and gets missed mid-
# incident, and this path is already best-effort/non-blocking (matches
# _lcars_ledger_write's own `|| true` contract — sizing must never fail a
# spawn). A malformed/non-numeric override is treated as "no check" rather
# than a fatal error, for the same reason.
# ---------------------------------------------------------------------------
_lcars_ledger_maybe_warn_size() {
    local _path="${1:-}"
    if [[ -z "${_path}" ]] || [[ ! -f "${_path}" ]]; then
        return 0
    fi
    local _limit="${LCARS_SPAWN_LEDGER_SIZE_WARN_BYTES:-52428800}"
    case "${_limit}" in
        ''|*[!0-9]*)
            return 0
            ;;
    esac
    local _size
    _size="$(wc -c < "${_path}" 2>/dev/null | tr -d '[:space:]')"
    case "${_size}" in
        ''|*[!0-9]*)
            return 0
            ;;
    esac
    if [[ "${_size}" -gt "${_limit}" ]]; then
        printf '[LCARS][ledger] WARNING: %s is %s bytes, over the %s-byte size-warning threshold.\n[LCARS][ledger] This ledger is APPEND-ONLY BY DESIGN (XACA-0988) — nothing here will rotate or truncate it automatically.\n[LCARS][ledger] If retention is genuinely needed, prune it manually and out-of-band; see the RETENTION / SIZE POLICY comment atop scripts/lcars-spawn-ledger.sh.\n' \
            "${_path}" "${_size}" "${_limit}" >&2 2>/dev/null || true
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _lcars_ledger_write <site> <event> <launch_id> <team> <port> <session> \
#                      <pid> <ppid> <argv> <skip_server_start> <skip_attach>
#
# Appends exactly one JSON object (one line) to the ledger. Never aborts the
# caller: mkdir/printf failures are swallowed (`|| true`) because this is
# diagnostic instrumentation, not a load-bearing part of the startup path —
# a startup must never fail because the ledger directory is unwritable.
#
# <site>   one of: start_lcars_server | health_check_delegate |
#          team_startup_sendkeys
# <event>  spawn_attempt | spawn_result | spawn_skipped
# Any field the caller doesn't have yet (e.g. <pid> before the process is
# known) should be passed as an empty string, not omitted — positional
# arity here is fixed at 11 to keep the JSON shape stable across all sites.
# ---------------------------------------------------------------------------
_lcars_ledger_write() {
    local _site="${1:-unknown}"
    local _event="${2:-unknown}"
    local _launch_id="${3:-}"
    local _team="${4:-}"
    local _port="${5:-}"
    local _session="${6:-}"
    local _pid="${7:-}"
    local _ppid="${8:-}"
    local _argv="${9:-}"
    local _skip_server_start="${10:-}"
    local _skip_attach="${11:-}"

    local _path
    _path="$(_lcars_ledger_path)"
    local _dir
    _dir="$(dirname "${_path}")"
    mkdir -p "${_dir}" 2>/dev/null || true

    local _ts
    _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local _ancestors
    _ancestors="$(_lcars_ancestor_chain "$$" 15)"

    # XACA-0988-018: escape every field via _lcars_json_escape_var (writes
    # into the named local below) instead of `"$(_lcars_json_escape ...)"` —
    # the latter forked a subshell PER FIELD (13 forks per write) purely to
    # capture a value this process could just as well receive directly.
    local _e_ts _e_site _e_event _e_launch_id _e_team _e_port _e_session
    local _e_pid _e_ppid _e_argv _e_skip_server_start _e_skip_attach
    local _e_ancestors
    _lcars_json_escape_var "${_ts}" _e_ts
    _lcars_json_escape_var "${_site}" _e_site
    _lcars_json_escape_var "${_event}" _e_event
    _lcars_json_escape_var "${_launch_id}" _e_launch_id
    _lcars_json_escape_var "${_team}" _e_team
    _lcars_json_escape_var "${_port}" _e_port
    _lcars_json_escape_var "${_session}" _e_session
    _lcars_json_escape_var "${_pid}" _e_pid
    _lcars_json_escape_var "${_ppid}" _e_ppid
    _lcars_json_escape_var "${_argv}" _e_argv
    _lcars_json_escape_var "${_skip_server_start}" _e_skip_server_start
    _lcars_json_escape_var "${_skip_attach}" _e_skip_attach
    _lcars_json_escape_var "${_ancestors}" _e_ancestors

    printf '{"ts":"%s","site":"%s","event":"%s","launch_id":"%s","team":"%s","port":"%s","session":"%s","pid":"%s","ppid":"%s","argv":"%s","skip_server_start":"%s","skip_attach":"%s","ancestors":"%s"}\n' \
        "${_e_ts}" \
        "${_e_site}" \
        "${_e_event}" \
        "${_e_launch_id}" \
        "${_e_team}" \
        "${_e_port}" \
        "${_e_session}" \
        "${_e_pid}" \
        "${_e_ppid}" \
        "${_e_argv}" \
        "${_e_skip_server_start}" \
        "${_e_skip_attach}" \
        "${_e_ancestors}" \
        >> "${_path}" 2>/dev/null || true

    _lcars_ledger_maybe_warn_size "${_path}"
}
