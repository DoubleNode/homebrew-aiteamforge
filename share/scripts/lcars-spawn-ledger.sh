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
# _lcars_json_escape <string>
#
# Minimal JSON string-body escaper for the small, shell-controlled field set
# this ledger writes (no untrusted external input reaches it). Escapes
# backslash and double-quote, and flattens embedded newlines/tabs to spaces
# so one ledger row always occupies exactly one line (a reader can safely
# process this file with `wc -l` / `tail -1` / `jq -c`).
# ---------------------------------------------------------------------------
_lcars_json_escape() {
    local _s="${1:-}"
    _s="${_s//\\/\\\\}"
    _s="${_s//\"/\\\"}"
    _s="${_s//$'\n'/ }"
    _s="${_s//$'\t'/ }"
    printf '%s' "${_s}"
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
        _ppid="$(printf '%s\n' "${_ps_out}" | awk '{print $1}')"
        _comm="$(printf '%s\n' "${_ps_out}" | awk '{$1=""; sub(/^ /,""); print}')"
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

    printf '{"ts":"%s","site":"%s","event":"%s","launch_id":"%s","team":"%s","port":"%s","session":"%s","pid":"%s","ppid":"%s","argv":"%s","skip_server_start":"%s","skip_attach":"%s","ancestors":"%s"}\n' \
        "$(_lcars_json_escape "${_ts}")" \
        "$(_lcars_json_escape "${_site}")" \
        "$(_lcars_json_escape "${_event}")" \
        "$(_lcars_json_escape "${_launch_id}")" \
        "$(_lcars_json_escape "${_team}")" \
        "$(_lcars_json_escape "${_port}")" \
        "$(_lcars_json_escape "${_session}")" \
        "$(_lcars_json_escape "${_pid}")" \
        "$(_lcars_json_escape "${_ppid}")" \
        "$(_lcars_json_escape "${_argv}")" \
        "$(_lcars_json_escape "${_skip_server_start}")" \
        "$(_lcars_json_escape "${_skip_attach}")" \
        "$(_lcars_json_escape "${_ancestors}")" \
        >> "${_path}" 2>/dev/null || true
}
