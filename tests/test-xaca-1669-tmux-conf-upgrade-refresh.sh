#!/bin/bash
# test-xaca-1669-tmux-conf-upgrade-refresh.sh
#
# XACA-1669-006: FUNCTIONAL regression suite for the receipt-guarded
# ~/.tmux.conf refresh on the UPGRADE path plus the running-tmux-server reload.
#
# Code under test:
#   libexec/installers/install-claude-config.sh
#     install_tmux_conf()                  writes ${AITEAMFORGE_DIR}/.tmux-conf.receipt
#     _xaca1669_refresh_tmux_conf()        rc 0 current | 1 soft-fail | 2 refreshed
#                                          | 3 left untouched (+ ~/.tmux.conf.new sidecar)
#                                          | 4 no live file
#     _xaca1669_reload_tmux_servers()      source-file + refresh-client -S on every
#                                          live socket under ${TMUX_TMPDIR:-/tmp}/tmux-<uid>/
#   libexec/commands/aiteamforge-upgrade.sh
#     update_tmux_conf()                   fail-soft wrapper; reload ONLY on rc 2
#
# Unlike test-xaca-1159-global-claude-md-upgrade-registration.sh (structural
# only), this suite EXECUTES the real installer functions, sourcing the real
# installer file exactly as the upgrade does. Cases:
#   C1  fresh install writes receipt == live file
#   C2  pristine (receipt match) + changed template -> rc 2, refreshed, backup
#   C3  pristine + unchanged template -> rc 0, no write (inode + mtime)
#   C4  customized (receipt mismatch) -> rc 3, untouched, sidecar == template
#   C4b stale receipt but live == CURRENT render -> rc 0, receipt re-synced, no
#       sidecar (adoption; never strand the user on "customized")
#   C5  pre-receipt box on the historical shipped blob -> rc 2, receipt written
#       (historical bytes are the committed fixture tests/fixtures/xaca-1669/
#       tmux.conf.2fec0ca5, sha256-pinned to the installer's constant; NO git
#       history dependency -- CI checkouts are shallow, and the publisher will
#       later replace the template this blob came from)
#   C6  pre-receipt box, foreign content -> rc 3, untouched, sidecar
#   C7  symlink (incl. target bytes == receipt) and dangling symlink -> rc 3
#   C8  no ~/.tmux.conf -> rc 4, nothing created
#   C9  idempotence: second run after a refresh -> rc 0
#   C10 reload against throwaway tmux servers (-L, isolated TMUX_TMPDIR)
#   C10b reload must stay bounded when a server is SIGSTOPped (wedged): that
#       socket is skipped + reported, live servers still reload
#   C10c XACA-1669-024: servers on -f <other conf> / -f /dev/null are NOT reloaded,
#        servers on ~/.tmux.conf (default search or -f) are; #{config_files}
#        unavailable -> skipped (fail safe)
#   C10d symlinked ~/.tmux.conf (relative link) matches by link and by target
#   C10g XACA-1669-029: a server started with a RELATIVE -f is never reloaded,
#        even when the upgrade runs from the directory that relative name hits
#   C10e XACA-1669-025: a server of ours that rejects the file is counted as
#        failed to source (rc 3), reported next to the other buckets
#   C11 upgrade wiring: static order checks + the REAL update_tmux_conf body
#       (C11f: warns when a server failed to source, still returns 0)
#   C12 soft-fail paths (missing template, unwritable backup dir) -> rc 1
#
# ISOLATION (non-negotiable): every case builds its own mktemp HOME and
# AITEAMFORGE_DIR and its own TMUX_TMPDIR (short path under /tmp: unix socket
# paths cap at 104 bytes on macOS); TMUX, GIT_DIR, GIT_WORK_TREE are unset; tmux
# is only ever driven through tm(), which refuses to run without an isolated
# TMUX_TMPDIR and always passes -L, so the default socket and real team servers
# are unreachable. Only servers this suite started are killed.
#
# Mutation seam: XACA1669_INSTALLER / XACA1669_UPGRADE_SH override the files
# under test so the mutation sentinels can aim the suite at a mutated scratch
# copy. Unset in normal runs.
#
# Runs standalone (bash tests/test-xaca-1669-tmux-conf-upgrade-refresh.sh) OR
# via test-runner.sh. Exit 0 = all pass (and >=1 assertion ran), exit 1 = any
# fail OR zero assertions executed (vacuous-green guard).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="${XACA1669_INSTALLER:-$TAP_ROOT/libexec/installers/install-claude-config.sh}"
UPGRADE_SH="${XACA1669_UPGRADE_SH:-$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh}"

# The historically shipped render: tap blob 2fec0ca5 (the single-line tab bar),
# committed byte-exact as a fixture (produced by `git show 2fec0ca5 >`). The
# installer embeds its sha256. Do NOT regenerate this from git history or from
# share/: the point is that the suite needs neither.
HIST_SHA256="f83149da485c2edf2aeefbd261e7d6d5378edb5b399df27d0b2266b42b92d924"
HIST_FIXTURE="$SCRIPT_DIR/fixtures/xaca-1669/tmux.conf.2fec0ca5"

for _need in "$INSTALLER" "$UPGRADE_SH"; do
    if [ ! -f "$_need" ]; then
        echo "FATAL: required file not found: $_need" >&2
        exit 1
    fi
done

if [ ! -f "$HIST_FIXTURE" ]; then
    echo "FATAL: historical tmux.conf fixture missing: $HIST_FIXTURE" >&2
    exit 1
fi
_fx_sha="$(shasum -a 256 "$HIST_FIXTURE" | awk '{print $1}')"
if [ "$_fx_sha" != "$HIST_SHA256" ]; then
    echo "FATAL: fixture sha256 ($_fx_sha) != expected historical sha256 ($HIST_SHA256) -- fixture corrupted or edited; refusing to fall back" >&2
    exit 1
fi
if ! grep -q "^${HIST_SHA256}\$" "$INSTALLER"; then
    echo "FATAL: installer does not embed the historical sha256 ${HIST_SHA256} (constant drifted from the fixture)" >&2
    exit 1
fi

# The interpreter running this suite is the interpreter that runs the installer
# (so /bin/bash 3.2 runs exercise the installer under 3.2 too).
TEST_BASH="${BASH:-bash}"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework stubs (mirrors test-xaca-1159 / test-xaca-0761).
# ─────────────────────────────────────────────────────────────────────────────
if ! type -t test_start >/dev/null 2>&1; then
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# Scratch roots. TEST_TMP_DIR: runner-supplied or our own. TMUX_BASE is always
# our own SHORT dir (socket path limit), never shared with the runner.
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1669.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TMUX_BASE="$(mktemp -d /tmp/xt1669.XXXXXX)"

# Servers/clients this suite started: "<TMUX_TMPDIR>|<-L name>" lines.
STARTED_SERVERS=""
FIFO_FDS=""
# PIDs of throwaway servers THIS suite SIGSTOPped (recorded before the STOP so
# cleanup can never miss one). Only ever pids we started ourselves.
STOPPED_PIDS=""

tm() {
    # Only ever talk to a server under an isolated, suite-owned TMUX_TMPDIR.
    case "${TMUXB:-}" in
        "$TMUX_BASE"/?*) ;;
        *) echo "tm: refusing to run tmux without an isolated TMUX_TMPDIR (TMUXB='${TMUXB:-}')" >&2; return 99 ;;
    esac
    case "${HOME_T:-}" in
        "$TEST_TMP_DIR"/?*) ;;
        *) echo "tm: refusing to run tmux without a sandbox HOME (HOME_T='${HOME_T:-}')" >&2; return 99 ;;
    esac
    env -u TMUX HOME="$HOME_T" TMUX_TMPDIR="$TMUXB" tmux "$@"
}

# start_srv <name> [tmux flags e.g. -f FILE]: start a throwaway detached server.
# With no -f it searches the sandbox HOME's ~/.tmux.conf, like a team server.
start_srv() {
    local n="$1"; shift
    STARTED_SERVERS="$STARTED_SERVERS $TMUXB|$n"
    tm -L "$n" "$@" new-session -d -s sess >/dev/null 2>&1 || fail_note "could not start throwaway server $n"
}

cleanup() {
    local entry d n fd p
    for p in $STOPPED_PIDS; do
        kill -CONT "$p" >/dev/null 2>&1 || true
        kill -KILL "$p" >/dev/null 2>&1 || true
    done
    for entry in $STARTED_SERVERS; do
        d="${entry%%|*}"; n="${entry#*|}"
        case "$d" in "$TMUX_BASE"/?*) env -u TMUX TMUX_TMPDIR="$d" tmux -L "$n" kill-server >/dev/null 2>&1 || true ;; esac
    done
    for fd in $FIFO_FDS; do eval "exec ${fd}>&-" 2>/dev/null || true; done
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ] && [ -d "$TEST_TMP_DIR" ]; then
        find "$TEST_TMP_DIR" -depth -delete 2>/dev/null || true
    fi
    if [ -n "${TMUX_BASE:-}" ] && [ -d "$TMUX_BASE" ]; then
        find "$TMUX_BASE" -depth -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ─────────────────────────────────────────────────────────────────────────────
# Case plumbing
# ─────────────────────────────────────────────────────────────────────────────
CASE_ERRS=""
begin_case() { CASE_ERRS=""; test_start "$1"; }
fail_note()  { CASE_ERRS="${CASE_ERRS}${CASE_ERRS:+; }$1"; }
end_case() {
    if [ -z "$CASE_ERRS" ]; then test_pass; else test_fail "$CASE_ERRS"; fi
}
# check "<description>" <command...>  -> records a failure note if command fails
check() {
    local desc="$1"; shift
    "$@" >/dev/null 2>&1 || fail_note "$desc"
}
# check_rc "<description>" <expected> <actual>
check_rc() {
    [ "$2" = "$3" ] || fail_note "$1: expected rc $2, got rc $3 (output: ${OUT:-})"
}

same_bytes()  { cmp -s "$1" "$2"; }
fstat() {
    # inode:mtime of a file (follows nothing; plain files only here)
    if [ "$(uname)" = Darwin ]; then stat -f '%i:%m' "$1"; else stat -c '%i:%Y' "$1"; fi
}
sha256_of()   { shasum -a 256 "$1" | awk '{print $1}'; }
home_strays() {
    # anything in HOME other than the live file and its sidecar = leaked temp
    local f
    for f in "$HOME_T"/.tmux.conf.*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        [ "$f" = "$HOME_T/.tmux.conf.new" ] && continue
        echo "$f"
    done
}
backup_files() { find "$AITEAMFORGE_DIR_T/.backups" -name tmux.conf -type f 2>/dev/null; }

# New sandbox: sets S HOME_T AITF TMPL_ROOT TMPL TMUXB. Synthetic "current"
# template (v2). The tap's own template is the OLD single-line render.
new_sandbox() {
    S="$(mktemp -d "$TEST_TMP_DIR/case.XXXXXX")"
    HOME_T="$S/home"
    AITF="$S/aiteamforge"
    AITEAMFORGE_DIR_T="$AITF"
    TMPL_ROOT="$S/templates"
    TMPL="$TMPL_ROOT/claude/tmux.conf"
    mkdir -p "$HOME_T" "$AITF" "$TMPL_ROOT/claude"
    TMUXB="$TMUX_BASE/$(basename "$S")"
    mkdir -p "$TMUXB"
    printf '# tmux.conf v2 (two-line tab bar)\nset -g status 2\nset -g @xaca1669-marker "v2"\n' > "$TMPL"
    OLD_BYTES="$S/old-shipped.conf"
    cp "$HIST_FIXTURE" "$OLD_BYTES"
    RECEIPT="$AITF/.tmux-conf.receipt"
    LIVE="$HOME_T/.tmux.conf"
    RUN_PATH="$PATH"
}

# kill_tree <pid>: SIGKILL a process and all its descendants (children first).
kill_tree() {
    local c
    for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done
    kill -KILL "$1" >/dev/null 2>&1 || true
}

# run_fn <function> [args]: sources the REAL installer in a child bash (same
# interpreter as this suite) exactly the way update_tmux_conf does, then calls
# the function. Sets OUT (stdout+stderr), RC, ELAPSED (whole seconds); a hang is recorded
# as a case failure (RC=137).
# The child runs under an OUTER watchdog (RUN_LIMIT seconds, default 60) so a
# hang in the code under test FAILS the case instead of hanging the suite.
run_fn() {
    local limit="${RUN_LIMIT:-60}" outf="$S/.run.out" rcf="$S/.run.rc" hungf="$S/.run.hung"
    local pid t0
    command rm -f "$outf" "$rcf" "$hungf"
    t0="$(date +%s)"
    ( env -u TMUX -u GIT_DIR -u GIT_WORK_TREE \
        PATH="$RUN_PATH" HOME="$HOME_T" USER=xaca1669 \
        AITEAMFORGE_DIR="$AITF" TEMPLATE_DIR="$TMPL_ROOT" TMUX_TMPDIR="$TMUXB" \
        XACA1669_TMUX_TIMEOUT="${XACA1669_TMUX_TIMEOUT:-}" \
        PRELUDE="${PRELUDE:-}" \
        "$TEST_BASH" -c 'source "$1" >/dev/null 2>&1; shift; if [ -n "$PRELUDE" ]; then source "$PRELUDE"; fi; "$@"' _ "$INSTALLER" "$@" >"$outf" 2>&1 </dev/null
      echo $? >"$rcf" ) &
    pid=$!
    (
        while kill -0 "$pid" 2>/dev/null; do
            sleep 0.2
            if [ $(( $(date +%s) - t0 )) -ge "$limit" ] && kill -0 "$pid" 2>/dev/null; then
                : >"$hungf"
                kill_tree "$pid"
                exit 0
            fi
        done
    ) >/dev/null 2>&1 &
    wait "$pid" 2>/dev/null
    ELAPSED=$(( $(date +%s) - t0 ))
    OUT="$(cat "$outf" 2>/dev/null)"
    if [ -e "$hungf" ]; then
        RC=137
        fail_note "HUNG: run_fn $1 exceeded ${limit}s and was killed by the outer watchdog"
    else
        RC="$(cat "$rcf" 2>/dev/null)"; RC="${RC:-255}"
    fi
}

refresh() { run_fn _xaca1669_refresh_tmux_conf; }

# The upgrade script defines _aitf_file_mode; update_tmux_conf's subshell
# inherits it, so the installer's mode-preservation only engages under upgrade.
# Extract the REAL definition so we can reproduce that environment.
MODE_HELPER="$TEST_TMP_DIR/aitf_file_mode.sh"
awk '/^_aitf_file_mode\(\) \{/{c=1} c{print} c&&/^}$/{exit}' "$UPGRADE_SH" > "$MODE_HELPER"
[ -s "$MODE_HELPER" ] || echo "FATAL: could not extract _aitf_file_mode from $UPGRADE_SH" >&2
. "$MODE_HELPER"

# ═══════════════════════════════════════════════════════════════════════════
# C1 — fresh install writes receipt == live file
# ═══════════════════════════════════════════════════════════════════════════
begin_case "C1: install_tmux_conf writes a receipt byte-identical to the live file"
new_sandbox
run_fn install_tmux_conf
check_rc "install_tmux_conf" 0 "$RC"
check "live file == template" same_bytes "$LIVE" "$TMPL"
check "receipt exists at \$AITEAMFORGE_DIR/.tmux-conf.receipt" test -f "$RECEIPT"
check "receipt == live file" same_bytes "$RECEIPT" "$LIVE"
# A symlinked ~/.tmux.conf is replaced by install (setup contract), receipt follows.
new_sandbox
printf 'user dotfile\n' > "$S/dotfile"; ln -s "$S/dotfile" "$LIVE"
run_fn install_tmux_conf
check_rc "install over symlink" 0 "$RC"
check "install replaced the symlink with a plain file" test ! -L "$LIVE"
check "replaced file == template" same_bytes "$LIVE" "$TMPL"
check "receipt == live after symlink replace" same_bytes "$RECEIPT" "$LIVE"
check "symlink destination untouched" test "$(cat "$S/dotfile")" = "user dotfile"
end_case

# ═══════════════════════════════════════════════════════════════════════════
# C2 — pristine (receipt match) + changed template -> rc 2
# ═══════════════════════════════════════════════════════════════════════════
begin_case "C2: pristine file + changed template -> rc 2, refreshed, receipt updated, backup holds old bytes"
new_sandbox
printf '# tmux.conf v1\nset -g status on\n' > "$LIVE"
cp "$LIVE" "$RECEIPT"
cp "$LIVE" "$S/v1.bytes"
chmod 600 "$LIVE"
PRELUDE="$MODE_HELPER" refresh
check_rc "refresh" 2 "$RC"
check "live == new template" same_bytes "$LIVE" "$TMPL"
check "receipt == new live bytes" same_bytes "$RECEIPT" "$LIVE"
check "exactly one backup" test "$(backup_files | wc -l | tr -d ' ')" = 1
check "backup holds the OLD bytes" same_bytes "$(backup_files | head -1)" "$S/v1.bytes"
check "no sidecar on a refresh" test ! -e "$LIVE.new"
check "no stray temp files in HOME" test -z "$(home_strays)"
check "file mode preserved (600) when the upgrade's _aitf_file_mode is present" test "$(_aitf_file_mode "$LIVE")" = 600
case "$OUT" in *"refreshed from shipped template"*) ;; *) fail_note "summary line missing: $OUT" ;; esac
# Standalone (no _aitf_file_mode): documented default 644.
new_sandbox
cp "$OLD_BYTES" "$LIVE"; chmod 600 "$LIVE"
refresh
check_rc "refresh (no mode helper)" 2 "$RC"
check "default mode 644 without the upgrade's mode helper" test "$(_aitf_file_mode "$LIVE")" = 644
end_case

# ═══════════════════════════════════════════════════════════════════════════
# C3 — pristine + unchanged template -> rc 0, no write
# ═══════════════════════════════════════════════════════════════════════════
begin_case "C3: pristine file + unchanged template -> rc 0, no write (inode+mtime), no backup"
new_sandbox
cp "$TMPL" "$LIVE"; cp "$TMPL" "$RECEIPT"
touch -t 200001010000 "$LIVE"
before="$(fstat "$LIVE")"
refresh
check_rc "refresh" 0 "$RC"
check "inode+mtime unchanged" test "$(fstat "$LIVE")" = "$before"
check "live still == template" same_bytes "$LIVE" "$TMPL"
check "receipt still == live" same_bytes "$RECEIPT" "$LIVE"
check "no backup created" test -z "$(backup_files)"
check "no sidecar" test ! -e "$LIVE.new"
check "no stray temp files" test -z "$(home_strays)"
end_case

# ═══════════════════════════════════════════════════════════════════════════
# C4 — customized (receipt mismatch) -> rc 3, untouched, sidecar
# ═══════════════════════════════════════════════════════════════════════════
begin_case "C4: customized file (receipt mismatch) -> rc 3, untouched byte-for-byte, sidecar == template"
new_sandbox
printf '# tmux.conf v1\nset -g status on\n' > "$RECEIPT"
printf '# tmux.conf v1\nset -g status on\n# my personal tweak\nset -g mouse on\n' > "$LIVE"
cp "$LIVE" "$S/mine.bytes"
cp "$RECEIPT" "$S/receipt.bytes"
refresh
check_rc "refresh" 3 "$RC"
check "live untouched byte-for-byte" same_bytes "$LIVE" "$S/mine.bytes"
check "receipt untouched" same_bytes "$RECEIPT" "$S/receipt.bytes"
check "sidecar exists" test -f "$LIVE.new"
check "sidecar == current template" same_bytes "$LIVE.new" "$TMPL"
check "no backup (nothing overwritten)" test -z "$(backup_files)"
check "no stray temp files" test -z "$(home_strays)"
case "$OUT" in *"Left untouched"*"user-customized"*) ;; *) fail_note "summary line missing: $OUT" ;; esac
# Re-run is stable (sidecar rewritten identically, live still untouched).
refresh
check_rc "second refresh" 3 "$RC"
check "live still untouched after re-run" same_bytes "$LIVE" "$S/mine.bytes"
check "sidecar still == template after re-run" same_bytes "$LIVE.new" "$TMPL"
end_case

# ═══════════════════════════════════════════════════════════════════════════
# C4b — stale receipt, live == CURRENT render -> adopt (rc 0)
# ═══════════════════════════════════════════════════════════════════════════
# This REPLACES C4's old third sub-case, which asserted rc 3 / no sidecar for
# "receipt != live but live == current template". That pinned a bug: nothing is
# customized there, yet the user was reported as "left untouched" on EVERY
# upgrade, forever (no write ever re-synced the receipt). The live file is
# provably the current render, so the correct outcome is "already current" and
# a re-synced receipt.
begin_case "C4b: stale receipt but live == current render -> rc 0, receipt re-synced, no sidecar, no write"
new_sandbox
printf '# older\n' > "$RECEIPT"; cp "$TMPL" "$LIVE"
touch -t 200001010000 "$LIVE"
before="$(fstat "$LIVE")"
refresh
check_rc "adopt stale-receipt/current-live" 0 "$RC"
check "receipt re-synced to live" same_bytes "$RECEIPT" "$LIVE"
check "live == template and not rewritten (inode+mtime)" test "$(fstat "$LIVE")" = "$before"
check "no sidecar" test ! -e "$LIVE.new"
check "no backup" test -z "$(backup_files)"
check "no stray temp files" test -z "$(home_strays)"
case "$OUT" in *"already current"*) ;; *) fail_note "summary line missing: $OUT" ;; esac
# Second run is the plain pristine+current path.
refresh
check_rc "second run" 0 "$RC"
# Guard against over-adoption: stale receipt + live differs from BOTH -> still rc 3.
new_sandbox
printf '# older\n' > "$RECEIPT"; printf '# something else entirely\n' > "$LIVE"
cp "$LIVE" "$S/mine.bytes"; cp "$RECEIPT" "$S/receipt.bytes"
refresh
check_rc "live differs from receipt and template" 3 "$RC"
check "live untouched" same_bytes "$LIVE" "$S/mine.bytes"
check "receipt untouched (not adopted)" same_bytes "$RECEIPT" "$S/receipt.bytes"
end_case

# ═══════════════════════════════════════════════════════════════════════════
# C5 — pre-receipt box on the historical shipped blob -> rc 2
# ═══════════════════════════════════════════════════════════════════════════
begin_case "C5: pre-receipt box on the historical shipped blob (2fec0ca5) -> rc 2, receipt written"
new_sandbox
check "historical fixture bytes sha256 == installer constant" test "$(sha256_of "$OLD_BYTES")" = "$HIST_SHA256"
check "installer embeds the SAME sha256 constant (no silent drift)" grep -q "^${HIST_SHA256}\$" "$INSTALLER"
cp "$OLD_BYTES" "$LIVE"
cp "$OLD_BYTES" "$S/pre.bytes"
check "precondition: no receipt" test ! -e "$RECEIPT"
refresh
check_rc "refresh" 2 "$RC"
check "live == new template" same_bytes "$LIVE" "$TMPL"
check "receipt written == new live" same_bytes "$RECEIPT" "$LIVE"
check "backup holds the historical bytes" same_bytes "$(backup_files | head -1)" "$S/pre.bytes"
check "no sidecar" test ! -e "$LIVE.new"
# Pre-receipt box already equal to the CURRENT template: pristine, rc 0, receipt written.
new_sandbox
cp "$TMPL" "$LIVE"
refresh
check_rc "pre-receipt == current template" 0 "$RC"
check "receipt bootstrapped from current-template match" same_bytes "$RECEIPT" "$LIVE"
check "no backup, no sidecar" test -z "$(backup_files)$( [ -e "$LIVE.new" ] && echo x)"
end_case

# ═══════════════════════════════════════════════════════════════════════════
# C6 — pre-receipt box, foreign content -> rc 3
# ═══════════════════════════════════════════════════════════════════════════
begin_case "C6: pre-receipt box, foreign content -> rc 3, untouched, sidecar, no receipt invented"
new_sandbox
printf '# hand-authored by the user\nset -g prefix C-a\n' > "$LIVE"
cp "$LIVE" "$S/foreign.bytes"
refresh
check_rc "refresh" 3 "$RC"
check "live untouched" same_bytes "$LIVE" "$S/foreign.bytes"
check "sidecar == template" same_bytes "$LIVE.new" "$TMPL"
check "no receipt fabricated for a foreign file" test ! -e "$RECEIPT"
check "no backup" test -z "$(backup_files)"
case "$OUT" in *"no render receipt on file"*) ;; *) fail_note "summary line missing: $OUT" ;; esac
# Near-miss: the historical blob plus ONE extra byte must NOT pass provenance.
new_sandbox
{ cat "$OLD_BYTES"; printf '#'; } > "$LIVE"
cp "$LIVE" "$S/near.bytes"
refresh
check_rc "near-miss refresh" 3 "$RC"
check "near-miss untouched" same_bytes "$LIVE" "$S/near.bytes"
end_case

# ═══════════════════════════════════════════════════════════════════════════
# C7 — symlinks -> rc 3, link preserved, target untouched
# ═══════════════════════════════════════════════════════════════════════════
begin_case "C7: symlink (target bytes == receipt) and dangling symlink -> rc 3, link + target untouched"
new_sandbox
printf '# tmux.conf v1\nset -g status on\n' > "$RECEIPT"
mkdir -p "$S/dotfiles"
cp "$RECEIPT" "$S/dotfiles/tmux.conf"
cp "$RECEIPT" "$S/target.bytes"
ln -s "$S/dotfiles/tmux.conf" "$LIVE"
refresh
check_rc "symlink to receipt-identical target" 3 "$RC"
check "~/.tmux.conf is still a symlink" test -L "$LIVE"
check "link still points at the same target" test "$(readlink "$LIVE")" = "$S/dotfiles/tmux.conf"
check "link target bytes untouched" same_bytes "$S/dotfiles/tmux.conf" "$S/target.bytes"
check "sidecar written beside the link, == template" same_bytes "$LIVE.new" "$TMPL"
check "sidecar is a plain file, not written through the link" test ! -L "$LIVE.new"
check "no backup" test -z "$(backup_files)"
check "no stray temp files" test -z "$(home_strays)"
case "$OUT" in *"is a symlink"*) ;; *) fail_note "summary line missing: $OUT" ;; esac
# Symlink to a target equal to the current template: no sidecar needed.
new_sandbox
mkdir -p "$S/dotfiles"; cp "$TMPL" "$S/dotfiles/tmux.conf"
ln -s "$S/dotfiles/tmux.conf" "$LIVE"
refresh
check_rc "symlink to template-identical target" 3 "$RC"
check "link preserved" test "$(readlink "$LIVE")" = "$S/dotfiles/tmux.conf"
check "no sidecar when link target already equals template" test ! -e "$LIVE.new"
# Dangling symlink.
new_sandbox
ln -s "$S/nowhere/tmux.conf" "$LIVE"
refresh
check_rc "dangling symlink" 3 "$RC"
check "dangling link preserved" test "$(readlink "$LIVE")" = "$S/nowhere/tmux.conf"
check "dangling target NOT created" test ! -e "$S/nowhere"
check "sidecar == template" same_bytes "$LIVE.new" "$TMPL"
check "no stray temp files" test -z "$(home_strays)"
end_case

# ═══════════════════════════════════════════════════════════════════════════
# C8 — no ~/.tmux.conf -> rc 4
# ═══════════════════════════════════════════════════════════════════════════
begin_case "C8: no ~/.tmux.conf -> rc 4, nothing created (upgrade is not install)"
new_sandbox
refresh
check_rc "refresh (no receipt)" 4 "$RC"
check "HOME still empty" test -z "$(ls -A "$HOME_T")"
check "no receipt created" test ! -e "$RECEIPT"
check "no backup" test -z "$(backup_files)"
# Even with a stale receipt on disk it must not conjure a live file.
cp "$TMPL" "$RECEIPT"
refresh
check_rc "refresh (receipt present, live absent)" 4 "$RC"
check "HOME still empty (receipt present)" test -z "$(ls -A "$HOME_T")"
end_case

# ═══════════════════════════════════════════════════════════════════════════
# C9 — idempotence
# ═══════════════════════════════════════════════════════════════════════════
begin_case "C9: second run after a refresh -> rc 0, no further backup, bytes stable"
new_sandbox
cp "$OLD_BYTES" "$LIVE"
refresh
check_rc "first refresh" 2 "$RC"
touch -t 200001010000 "$LIVE"
before="$(fstat "$LIVE")"
refresh
check_rc "second refresh" 0 "$RC"
check "live unchanged (inode+mtime)" test "$(fstat "$LIVE")" = "$before"
check "live == template" same_bytes "$LIVE" "$TMPL"
check "still exactly one backup" test "$(backup_files | wc -l | tr -d ' ')" = 1
refresh
check_rc "third refresh" 0 "$RC"
end_case

# ═══════════════════════════════════════════════════════════════════════════
# C12 — soft-fail paths (rc 1)
# ═══════════════════════════════════════════════════════════════════════════
begin_case "C12: missing template and unwritable backup location -> rc 1, live file untouched"
new_sandbox
cp "$OLD_BYTES" "$LIVE"; cp "$OLD_BYTES" "$S/pre.bytes"
command rm "$TMPL"
refresh
check_rc "missing template" 1 "$RC"
check "live untouched (missing template)" same_bytes "$LIVE" "$S/pre.bytes"
check "no sidecar/receipt (missing template)" test ! -e "$LIVE.new" -a ! -e "$RECEIPT"
new_sandbox
cp "$OLD_BYTES" "$LIVE"; cp "$OLD_BYTES" "$S/pre.bytes"
cp "$OLD_BYTES" "$RECEIPT"
: > "$AITF/.backups"   # a FILE where the backup dir must go: mkdir -p fails
refresh
check_rc "backup cannot be created" 1 "$RC"
check "live untouched when backup fails (no overwrite without backup)" same_bytes "$LIVE" "$S/pre.bytes"
check "receipt untouched when backup fails" same_bytes "$RECEIPT" "$S/pre.bytes"
check "no stray temp files" test -z "$(home_strays)"
end_case

# ═══════════════════════════════════════════════════════════════════════════
# C10 — reload against throwaway tmux servers
# ═══════════════════════════════════════════════════════════════════════════
begin_case "C10: reload reaches every live server (with and without a client), skips stale/non-socket entries"
if ! command -v tmux >/dev/null 2>&1; then
    fail_note "tmux is not installed; this suite needs it (CI installs it, XACA-0862) — refusing to skip into a vacuous pass"
else
    new_sandbox
    sdir="$TMUXB/tmux-$(id -u)"
    nA="xaca1669a-$$"; nB="xaca1669b-$$"; nS="xaca1669s-$$"
    for n in "$nA" "$nB" "$nS"; do
        start_srv "$n"
    done
    # Attached client on server A (control mode fed by a fifo we hold open).
    fifo="$S/ctl.fifo"; mkfifo "$fifo"
    exec 7<>"$fifo"; FIFO_FDS="$FIFO_FDS 7"
    tm -L "$nA" -C attach <"$fifo" >/dev/null 2>&1 &
    CLIENT_PID=$!
    # Wait (bounded) for the client to register.
    i=0; while [ "$i" -lt 50 ] && [ -z "$(tm -L "$nA" list-clients -F '#{client_name}' 2>/dev/null)" ]; do sleep 0.1; i=$((i+1)); done
    check "precondition: server A has an attached client" test -n "$(tm -L "$nA" list-clients -F '#{client_name}' 2>/dev/null)"
    # Stale socket: kill -9 the server, leave its socket file in place.
    pidS="$(tm -L "$nS" display-message -p '#{pid}' 2>/dev/null)"
    [ -n "$pidS" ] && kill -9 "$pidS" 2>/dev/null
    sleep 0.3
    check "precondition: stale socket file remains and is dead" test -S "$sdir/$nS" -a -z "$(tm -L "$nS" list-sessions 2>/dev/null)"
    # Non-socket file in the socket dir.
    : > "$sdir/not-a-socket"
    # The new config: marker option that none of the servers have yet.
    printf 'set -g @xaca1669-marker "reloaded"\n' > "$LIVE"
    check "precondition: server A lacks the marker" test -z "$(tm -L "$nA" show -gqv @xaca1669-marker)"
    check "precondition: server B lacks the marker" test -z "$(tm -L "$nB" show -gqv @xaca1669-marker)"
    run_fn _xaca1669_reload_tmux_servers
    check_rc "reload" 0 "$RC"
    check "server A (with client) sees the new option" test "$(tm -L "$nA" show -gqv @xaca1669-marker)" = reloaded
    check "server B (no client) sees the new option" test "$(tm -L "$nB" show -gqv @xaca1669-marker)" = reloaded
    check "summary says 2 servers, 1 client" test "$OUT" = "reloaded 2 server(s), 1 client(s)"
    check "stale socket file left in place (not our business)" test -S "$sdir/$nS"
    check "non-socket file left in place" test -f "$sdir/not-a-socket"
    check "live servers survived the reload" test -n "$(tm -L "$nA" list-sessions 2>/dev/null)" -a -n "$(tm -L "$nB" list-sessions 2>/dev/null)"

    # Config that fails to parse: rc 0, nothing counted, no error leaks.
    printf 'this-is-not-a-tmux-command\n' > "$LIVE"
    run_fn _xaca1669_reload_tmux_servers
    check_rc "reload with a broken config (rc 3 = servers failed to source)" 3 "$RC"
    check "broken config reloads 0 servers, reported as failed to source" test "$OUT" = "reloaded 0 server(s), 0 client(s); skipped: 2 failed to source"

    # tmux not on PATH: fail-soft, servers untouched.
    printf 'set -g @xaca1669-marker "second"\n' > "$LIVE"
    mkdir -p "$S/bin"
    for tool in id env date sed cat uname mkdir dirname basename mktemp cp mv cmp shasum awk chmod rm tr; do
        t="$(command -v "$tool" 2>/dev/null)"; [ -n "$t" ] && ln -s "$t" "$S/bin/$tool"
    done
    RUN_PATH="$S/bin"
    run_fn _xaca1669_reload_tmux_servers
    RUN_PATH="$PATH"
    check_rc "reload without tmux on PATH" 0 "$RC"
    check "no-tmux summary" test "$OUT" = "reloaded 0 server(s), 0 client(s)"
    check "server A untouched without tmux on PATH" test "$(tm -L "$nA" show -gqv @xaca1669-marker)" = reloaded

    for n in "$nA" "$nB"; do tm -L "$n" kill-server >/dev/null 2>&1; done
    exec 7>&-
    FIFO_FDS=""
    wait "$CLIENT_PID" 2>/dev/null
fi
# No sockets dir at all / empty sockets dir.
new_sandbox
check "precondition: no tmux-<uid> dir" test ! -e "$TMUXB/tmux-$(id -u)"
run_fn _xaca1669_reload_tmux_servers
check_rc "reload, no sockets dir" 0 "$RC"
check "no-sockets-dir summary" test "$OUT" = "reloaded 0 server(s), 0 client(s)"
mkdir -p "$TMUXB/tmux-$(id -u)"
run_fn _xaca1669_reload_tmux_servers
check_rc "reload, empty sockets dir" 0 "$RC"
check "empty-sockets-dir summary" test "$OUT" = "reloaded 0 server(s), 0 client(s)"
end_case

# ═══════════════════════════════════════════════════════════════════════════
# C10b — a wedged (SIGSTOPped) server must not hang the reload
# ═══════════════════════════════════════════════════════════════════════════
# A stopped server still owns its socket, so connect() succeeds and every tmux
# client call then blocks forever. Unattended upgrades must survive that. The
# wedged server sorts FIRST in the socket dir so the live one after it proves
# the loop kept going. run_fn's outer watchdog (RUN_LIMIT) turns a regression
# into a bounded FAIL rather than a hung suite.
begin_case "C10b: SIGSTOPped server -> reload returns in bounded time, skips it (reported), live servers still reload"
if ! command -v tmux >/dev/null 2>&1; then
    fail_note "tmux is not installed; refusing to skip into a vacuous pass"
else
    new_sandbox
    nW="xaca1669a-wedged-$$"; nL="xaca1669b-live-$$"
    for n in "$nW" "$nL"; do
        start_srv "$n"
    done
    pidW="$(tm -L "$nW" display-message -p '#{pid}' 2>/dev/null)"
    case "$pidW" in ''|*[!0-9]*) fail_note "could not read the wedged server pid ('$pidW')"; pidW="" ;; esac
    if [ -n "$pidW" ]; then
        # Record BEFORE stopping so cleanup (incl. the EXIT/INT/TERM trap) always CONT+KILLs it.
        STOPPED_PIDS="$STOPPED_PIDS $pidW"
        kill -STOP "$pidW"
        i=0; while [ "$i" -lt 30 ]; do
            case "$(ps -o state= -p "$pidW" 2>/dev/null | tr -d ' ')" in T*) break ;; esac
            sleep 0.1; i=$((i+1))
        done
        case "$(ps -o state= -p "$pidW" 2>/dev/null | tr -d ' ')" in
            T*) ;; *) fail_note "precondition: wedged server is not in stopped state" ;;
        esac
        printf 'set -g @xaca1669-marker "reloaded"\n' > "$LIVE"
        check "precondition: live server lacks the marker" test -z "$(tm -L "$nL" show -gqv @xaca1669-marker)"
        RUN_LIMIT=40 XACA1669_TMUX_TIMEOUT=1 run_fn _xaca1669_reload_tmux_servers
        check_rc "reload with a stopped server" 0 "$RC"
        check "returned within a bounded time (<=20 s, took ${ELAPSED}s)" test "$ELAPSED" -le 20
        check "stopped server reported as skipped, live server counted" test "$OUT" = "reloaded 1 server(s), 0 client(s); skipped: 1 unresponsive"
        check "live server (sorted AFTER the wedged one) still reloaded" test "$(tm -L "$nL" show -gqv @xaca1669-marker)" = reloaded
        check "no tmux client processes left behind by the reload" test -z "$(pgrep -f "tmux -S $TMUXB/tmux-$(id -u)/$nW" 2>/dev/null)"
        # Unwedge + stop it now (the trap is the backstop).
        kill -CONT "$pidW" 2>/dev/null
        tm -L "$nW" kill-server >/dev/null 2>&1
        i=0; while [ "$i" -lt 30 ] && kill -0 "$pidW" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
        kill -0 "$pidW" 2>/dev/null && { kill -KILL "$pidW" 2>/dev/null; fail_note "wedged server needed SIGKILL"; }
        STOPPED_PIDS=""
    fi
    tm -L "$nL" kill-server >/dev/null 2>&1
fi
end_case

# ═══════════════════════════════════════════════════════════════════════════
# C10c — XACA-1669-024: only servers that loaded ~/.tmux.conf are reloaded
# ═══════════════════════════════════════════════════════════════════════════
begin_case "C10c: server started on -f <other conf> / -f /dev/null is NOT reloaded; servers on ~/.tmux.conf (default search or -f) ARE"
if ! command -v tmux >/dev/null 2>&1; then
    fail_note "tmux is not installed; refusing to skip into a vacuous pass"
else
    new_sandbox
    printf 'set -g @xaca1669-marker "initial"\n' > "$LIVE"
    printf 'set -g @xaca1669-other "mine"\n' > "$S/other.conf"
    nO="xaca1669o-own-$$"; nF="xaca1669f-flag-$$"; nX="xaca1669x-other-$$"; nZ="xaca1669z-null-$$"
    start_srv "$nO"                       # default search -> ~/.tmux.conf
    start_srv "$nF" -f "$LIVE"            # explicit -f on our file
    start_srv "$nX" -f "$S/other.conf"    # someone else's config
    start_srv "$nZ" -f /dev/null          # deliberately config-less
    check "precondition: own server loaded the initial marker" test "$(tm -L "$nO" show -gqv @xaca1669-marker)" = initial
    check "precondition: -f /dev/null server has no marker" test -z "$(tm -L "$nZ" show -gqv @xaca1669-marker)"
    printf 'set -g @xaca1669-marker "reloaded"\n' > "$LIVE"
    run_fn _xaca1669_reload_tmux_servers
    check_rc "reload" 0 "$RC"
    check "default-search server reloaded" test "$(tm -L "$nO" show -gqv @xaca1669-marker)" = reloaded
    check "server started with -f ~/.tmux.conf reloaded" test "$(tm -L "$nF" show -gqv @xaca1669-marker)" = reloaded
    check "server on -f <other conf> NOT reloaded (marker absent)" test -z "$(tm -L "$nX" show -gqv @xaca1669-marker)"
    check "other-conf server kept its own option" test "$(tm -L "$nX" show -gqv @xaca1669-other)" = mine
    check "-f /dev/null server NOT reloaded (marker absent)" test -z "$(tm -L "$nZ" show -gqv @xaca1669-marker)"
    check "summary counts 2 reloaded, 2 not using ~/.tmux.conf" test "$OUT" = "reloaded 2 server(s), 0 client(s); skipped: 2 not using ~/.tmux.conf"
    check "skipped servers still alive" test -n "$(tm -L "$nX" list-sessions 2>/dev/null)" -a -n "$(tm -L "$nZ" list-sessions 2>/dev/null)"

    # Fail safe: when #{config_files} is unavailable (pre-3.2 tmux expands an
    # unknown format to ""), a server we cannot PROVE is ours is skipped, even
    # though it really is on ~/.tmux.conf. Shim tmux to blank only that query.
    real_tmux="$(command -v tmux)"
    mkdir -p "$S/shim"
    {
        printf '%s\n' '#!/bin/sh' 'for a in "$@"; do case "$a" in *config_files*) exit 0 ;; esac; done'
        printf 'exec "%s" "$@"\n' "$real_tmux"
    } > "$S/shim/tmux"
    chmod +x "$S/shim/tmux"
    printf 'set -g @xaca1669-marker "third"\n' > "$LIVE"
    RUN_PATH="$S/shim:$PATH"
    run_fn _xaca1669_reload_tmux_servers
    RUN_PATH="$PATH"
    check_rc "reload with #{config_files} unavailable" 0 "$RC"
    check "unprovable servers skipped, none reloaded" test "$OUT" = "reloaded 0 server(s), 0 client(s); skipped: 4 not using ~/.tmux.conf"
    check "unprovable own server keeps its old config" test "$(tm -L "$nO" show -gqv @xaca1669-marker)" = reloaded
    for n in "$nO" "$nF" "$nX" "$nZ"; do tm -L "$n" kill-server >/dev/null 2>&1; done
fi
end_case

# ═══════════════════════════════════════════════════════════════════════════
# C10g — XACA-1669-029: a RELATIVE -f entry is never ours. tmux reports it as
# typed (relative to that server's start dir, which we cannot know); resolving
# it against the upgrade's cwd matched a personal project config whenever the
# upgrade ran from a directory where that relative name hit ~/.tmux.conf.
# ═══════════════════════════════════════════════════════════════════════════
begin_case "C10g: server started with a RELATIVE -f is NOT reloaded even when the upgrade runs from \$HOME"
if ! command -v tmux >/dev/null 2>&1; then
    fail_note "tmux is not installed; refusing to skip into a vacuous pass"
else
    new_sandbox
    printf 'set -g @xaca1669-marker "initial"\n' > "$LIVE"
    mkdir -p "$HOME_T/proj"
    printf 'set -g @xaca1669-who "project"\n' > "$HOME_T/proj/.tmux.conf"
    nO="xaca1669o-own-$$"; nR="xaca1669r-relative-$$"
    start_srv "$nO"                                   # default search -> ~/.tmux.conf
    _c10g_back="$PWD"
    cd "$HOME_T/proj" && start_srv "$nR" -f .tmux.conf   # personal project config, relative -f
    cd "$_c10g_back" || fail_note "could not return to $_c10g_back"
    check "precondition: relative-f server reports its config as typed (relative)" \
        test "$(tm -L "$nR" display -p '#{config_files}' 2>/dev/null)" = ".tmux.conf"
    check "precondition: project server loaded its own config" test "$(tm -L "$nR" show -gqv @xaca1669-who)" = project
    printf 'set -g @xaca1669-marker "reloaded"\n' > "$LIVE"
    # Run the reload FROM the sandbox HOME, where ".tmux.conf" resolves to ~/.tmux.conf.
    cd "$HOME_T" || fail_note "could not cd to sandbox HOME"
    run_fn _xaca1669_reload_tmux_servers
    cd "$_c10g_back" || fail_note "could not return to $_c10g_back"
    check_rc "reload" 0 "$RC"
    check "own server reloaded" test "$(tm -L "$nO" show -gqv @xaca1669-marker)" = reloaded
    check "relative-f project server NOT reloaded (marker absent)" test -z "$(tm -L "$nR" show -gqv @xaca1669-marker)"
    check "summary: 1 reloaded, 1 not using ~/.tmux.conf" test "$OUT" = "reloaded 1 server(s), 0 client(s); skipped: 1 not using ~/.tmux.conf"
    for n in "$nO" "$nR"; do tm -L "$n" kill-server >/dev/null 2>&1; done
fi
end_case

begin_case "C10d: symlinked ~/.tmux.conf (relative link, dotfiles repo) still matches, by default search and by -f on the target"
if ! command -v tmux >/dev/null 2>&1; then
    fail_note "tmux is not installed; refusing to skip into a vacuous pass"
else
    new_sandbox
    mkdir -p "$HOME_T/dotfiles"
    printf 'set -g @xaca1669-marker "initial"\n' > "$HOME_T/dotfiles/tmux.conf"
    ln -s dotfiles/tmux.conf "$LIVE"      # relative link, like a stow/dotfiles setup
    nL="xaca1669l-link-$$"; nT="xaca1669t-target-$$"; nX="xaca1669x-other-$$"
    start_srv "$nL"                                    # lists the literal ~/.tmux.conf link
    start_srv "$nT" -f "$HOME_T/dotfiles/tmux.conf"    # lists the link TARGET
    printf 'set -g @xaca1669-other "mine"\n' > "$S/other.conf"
    start_srv "$nX" -f "$S/other.conf"
    printf 'set -g @xaca1669-marker "reloaded"\n' > "$HOME_T/dotfiles/tmux.conf"
    run_fn _xaca1669_reload_tmux_servers
    check_rc "reload through a symlinked conf" 0 "$RC"
    check "server listing the link path reloaded" test "$(tm -L "$nL" show -gqv @xaca1669-marker)" = reloaded
    check "server listing the link TARGET reloaded" test "$(tm -L "$nT" show -gqv @xaca1669-marker)" = reloaded
    check "unrelated server still skipped" test -z "$(tm -L "$nX" show -gqv @xaca1669-marker)"
    check "summary" test "$OUT" = "reloaded 2 server(s), 0 client(s); skipped: 1 not using ~/.tmux.conf"
    for n in "$nL" "$nT" "$nX"; do tm -L "$n" kill-server >/dev/null 2>&1; done
fi
end_case

begin_case "C10e: a server that IS ours but rejects the file is counted as failed to source (rc 3), reported alongside the other buckets"
if ! command -v tmux >/dev/null 2>&1; then
    fail_note "tmux is not installed; refusing to skip into a vacuous pass"
else
    new_sandbox
    printf 'set -g @xaca1669-marker "initial"\n' > "$LIVE"
    printf 'set -g @xaca1669-other "mine"\n' > "$S/other.conf"
    nO="xaca1669o-own-$$"; nF="xaca1669f-flag-$$"; nX="xaca1669x-other-$$"
    start_srv "$nO"; start_srv "$nF" -f "$LIVE"; start_srv "$nX" -f "$S/other.conf"
    printf 'set -g @xaca1669-marker "partial"\nthis-is-not-a-tmux-command\n' > "$LIVE"
    run_fn _xaca1669_reload_tmux_servers
    check_rc "reload where our servers reject the file" 3 "$RC"
    check "failed servers counted, foreign one counted separately" test "$OUT" = "reloaded 0 server(s), 0 client(s); skipped: 2 failed to source, 1 not using ~/.tmux.conf"
    check "foreign server untouched" test -z "$(tm -L "$nX" show -gqv @xaca1669-marker)"
    for n in "$nO" "$nF" "$nX"; do tm -L "$n" kill-server >/dev/null 2>&1; done
fi
end_case

# ═══════════════════════════════════════════════════════════════════════════
# C11 — upgrade wiring
# ═══════════════════════════════════════════════════════════════════════════
begin_case "C11a: static wiring — update_tmux_conf defined and called immediately after update_global_claude_md"
check "update_tmux_conf() is defined" grep -qE '^update_tmux_conf\(\) \{' "$UPGRADE_SH"
check "exactly one bare call line" test "$(grep -cE '^update_tmux_conf$' "$UPGRADE_SH")" = 1
md_line="$(grep -nE '^update_global_claude_md$' "$UPGRADE_SH" | head -1 | cut -d: -f1)"
tc_line="$(grep -nE '^update_tmux_conf$' "$UPGRADE_SH" | head -1 | cut -d: -f1)"
nxt="$(awk -v n="${md_line:-0}" 'NR>n && $0!~/^[[:space:]]*$/ && $0!~/^[[:space:]]*#/ {print; exit}' "$UPGRADE_SH")"
check "update_tmux_conf is the very next run-sequence line after update_global_claude_md" test "$nxt" = "update_tmux_conf"
check "call line ordered after update_global_claude_md" test -n "$md_line" -a -n "$tc_line" -a "${tc_line:-0}" -gt "${md_line:-0}"
check "does not call raw install_tmux_conf (unguarded overwrite)" sh -c "! awk '/^update_tmux_conf\\(\\) \\{/{c=1} c{print} c&&/^}\$/{exit}' '$UPGRADE_SH' | grep -qE '(^|[^_])install_tmux_conf\\b'"
check "reuses the guarded refresh + reload helpers" sh -c "awk '/^update_tmux_conf\\(\\) \\{/{c=1} c{print} c&&/^}\$/{exit}' '$UPGRADE_SH' | grep -q _xaca1669_refresh_tmux_conf && awk '/^update_tmux_conf\\(\\) \\{/{c=1} c{print} c&&/^}\$/{exit}' '$UPGRADE_SH' | grep -q _xaca1669_reload_tmux_servers"
end_case

# Extract the real function body once; run it with the upgrade's environment.
UPD_BODY="$TEST_TMP_DIR/update_tmux_conf.body.sh"
awk '/^update_tmux_conf\(\) \{/{c=1} c{print} c&&/^}$/{exit}' "$UPGRADE_SH" > "$UPD_BODY"

# run_upd <installer-libexec-root> <dry_run>: builds the upgrade env around the
# extracted real function. Output lines are print_* calls; sets OUT and RC.
run_upd() {
    local libexec="$1" dry="$2"
    OUT="$(env -u TMUX -u GIT_DIR -u GIT_WORK_TREE \
        PATH="$RUN_PATH" HOME="$HOME_T" USER=xaca1669 TMUX_TMPDIR="$TMUXB" \
        WORKING_DIR="$AITF" FRAMEWORK_DIR="$S/framework" LIBEXEC_DIR="$libexec" DRY_RUN="$dry" \
        "$TEST_BASH" -c '
            print_section() { echo "SECTION: $*"; }
            print_info()    { echo "INFO: $*"; }
            print_success() { echo "SUCCESS: $*"; }
            print_warning() { echo "WARNING: $*"; }
            source "$1"
            update_tmux_conf
            echo "FUNC_RC=$?"' _ "$UPD_BODY" 2>&1)" && RC=0 || RC=$?
}

# upgrade_sandbox: framework share/templates -> synthetic template; real
# installer copied under a libexec root (so the function genuinely sources it).
upgrade_sandbox() {
    new_sandbox
    mkdir -p "$S/framework/share" "$S/libexec/installers"
    ln -s "$TMPL_ROOT" "$S/framework/share/templates"
    cp "$INSTALLER" "$S/libexec/installers/install-claude-config.sh"
}

# Fake installer: refresh returns $FAKE_RC; reload drops a marker file. Proves
# the reload gate independent of tmux itself.
make_fake_installer() {  # <libexec-root> <refresh-rc> <marker-file> <mode: normal|exit>
    mkdir -p "$1/installers"
    if [ "$4" = srcexit ]; then
        # The installer dies while being SOURCED.
        printf '%s\n' 'echo "installer exploded" >&2' 'exit 7' > "$1/installers/install-claude-config.sh"
    elif [ "$4" = exit ]; then
        # The installer sources fine and DEFINES a reload that leaves a
        # detectable marker, but the refresh dies (exit 7). A wrapper that
        # reloaded on any failure would call the reload and drop the marker,
        # so "no marker" is a falsifiable claim.
        {
            printf '%s\n' '_xaca1669_refresh_tmux_conf() { echo "installer exploded" >&2; exit 7; }'
            printf '%s\n' '_xaca1669_reload_tmux_servers() { echo called > "'"$3"'"; echo "reloaded 9 server(s), 9 client(s)"; return 0; }'
        } > "$1/installers/install-claude-config.sh"
    else
        {
            printf '%s\n' '_xaca1669_refresh_tmux_conf() { echo "fake refresh"; return '"$2"'; }'
            printf '%s\n' '_xaca1669_reload_tmux_servers() { echo called > "'"$3"'"; echo "reloaded 9 server(s), 9 client(s)"; return 0; }'
        } > "$1/installers/install-claude-config.sh"
    fi
}

begin_case "C11b: update_tmux_conf (real body, real installer) refreshes a stale pristine file and reloads a live server"
if ! command -v tmux >/dev/null 2>&1; then
    fail_note "tmux is not installed; refusing to skip into a vacuous pass"
else
    upgrade_sandbox
    cp "$OLD_BYTES" "$LIVE"
    nU="xaca1669u-$$"
    start_srv "$nU"
    run_upd "$S/libexec" false
    check_rc "update_tmux_conf process" 0 "$RC"
    case "$OUT" in *"FUNC_RC=0"*) ;; *) fail_note "function did not return 0: $OUT" ;; esac
    check "live refreshed to template" same_bytes "$LIVE" "$TMPL"
    check "receipt written" same_bytes "$RECEIPT" "$LIVE"
    check "running server picked up the new config" test "$(tm -L "$nU" show -gqv @xaca1669-marker)" = v2
    case "$OUT" in *"SUCCESS: "*refreshed*) ;; *) fail_note "no success line: $OUT" ;; esac
    case "$OUT" in *"INFO: tmux: reloaded 1 server(s), 0 client(s)"*) ;; *) fail_note "no reload summary: $OUT" ;; esac
    case "$OUT" in *"WARNING: "*) fail_note "healthy reload must not warn: $OUT" ;; esac
    # Second upgrade run: already current, NO reload (a manually-set option on
    # the server must survive, proving source-file was not re-run).
    tm -L "$nU" set -g @xaca1669-marker "manual" >/dev/null 2>&1
    run_upd "$S/libexec" false
    case "$OUT" in *"FUNC_RC=0"*) ;; *) fail_note "second run rc: $OUT" ;; esac
    # The 'manual' marker surviving is only meaningful if the second run really
    # took the already-current path -- assert that from its OWN output, and that
    # it printed no reload line.
    case "$OUT" in *"SUCCESS: tmux.conf already current"*) ;; *) fail_note "second run did not report already-current: $OUT" ;; esac
    case "$OUT" in *"refreshed"*|*"tmux: reloaded"*) fail_note "second run refreshed/reloaded: $OUT" ;; esac
    check "second upgrade run does NOT reload (rc 0 path)" test "$(tm -L "$nU" show -gqv @xaca1669-marker)" = manual
    tm -L "$nU" kill-server >/dev/null 2>&1
fi
end_case

begin_case "C11f: update_tmux_conf (real body, real installer) WARNS when a server of ours fails to source the refreshed file, and still returns 0"
if ! command -v tmux >/dev/null 2>&1; then
    fail_note "tmux is not installed; refusing to skip into a vacuous pass"
else
    upgrade_sandbox
    cp "$OLD_BYTES" "$LIVE"
    nU="xaca1669u-$$"; nX="xaca1669x-other-$$"
    printf 'set -g @xaca1669-other "mine"\n' > "$S/other.conf"
    start_srv "$nU"
    start_srv "$nX" -f "$S/other.conf"
    # The shipped template renders fine (refresh succeeds, rc 2) but tmux
    # rejects it at source time.
    printf '# tmux.conf v3\nset -g @xaca1669-marker "v3"\nthis-is-not-a-tmux-command\n' > "$TMPL"
    run_upd "$S/libexec" false
    check_rc "update_tmux_conf process" 0 "$RC"
    case "$OUT" in *"FUNC_RC=0"*) ;; *) fail_note "function did not return 0: $OUT" ;; esac
    check "live refreshed to the (bad) template" same_bytes "$LIVE" "$TMPL"
    case "$OUT" in *"INFO: tmux: reloaded 0 server(s), 0 client(s); skipped: 1 failed to source, 1 not using ~/.tmux.conf"*) ;; *) fail_note "summary line missing/wrong: $OUT" ;; esac
    case "$OUT" in *"WARNING: tmux: 1 running server(s) failed to source"*"kept their OLD config"*) ;; *) fail_note "failed-to-source warning missing: $OUT" ;; esac
    case "$OUT" in *"reload skipped"*) fail_note "must not take the generic reload-skipped path: $OUT" ;; esac
    check "foreign server untouched" test -z "$(tm -L "$nX" show -gqv @xaca1669-marker)"
    tm -L "$nU" kill-server >/dev/null 2>&1; tm -L "$nX" kill-server >/dev/null 2>&1
fi
end_case

begin_case "C11c: update_tmux_conf always returns 0 — installer that exits non-zero, rc 1/3/4, missing installer"
for mode in exit srcexit; do
    upgrade_sandbox
    make_fake_installer "$S/libexec" 0 "$S/marker" "$mode"
    run_upd "$S/libexec" false
    case "$OUT" in *"FUNC_RC=0"*) ;; *) fail_note "[$mode] installer exit 7 leaked through (no FUNC_RC=0): $OUT" ;; esac
    case "$OUT" in *"WARNING: "*) ;; *) fail_note "[$mode] installer failure not surfaced as a warning: $OUT" ;; esac
    check "[$mode] installer failure -> no reload (fake reload would drop a marker)" test ! -e "$S/marker"
done
# Self-check: the same fake DOES drop the marker when its refresh reports rc 2,
# so the absence above is falsifiable (a vacuous harness would fail here).
upgrade_sandbox
make_fake_installer "$S/libexec" 2 "$S/marker" normal
run_upd "$S/libexec" false
check "sanity: the fake reload marker is detectable when a reload happens" test -f "$S/marker"
for rcv in 1 3 4 9; do
    upgrade_sandbox
    command rm -f "$S/marker"
    make_fake_installer "$S/libexec" "$rcv" "$S/marker" normal
    run_upd "$S/libexec" false
    case "$OUT" in *"FUNC_RC=0"*) ;; *) fail_note "refresh rc $rcv: function did not return 0: $OUT" ;; esac
    check "refresh rc $rcv -> NO reload" test ! -e "$S/marker"
done
upgrade_sandbox
run_upd "$S/does-not-exist" false
case "$OUT" in *"FUNC_RC=0"*"") ;; *) fail_note "missing installer: $OUT" ;; esac
case "$OUT" in *"WARNING: install-claude-config.sh not found"*) ;; *) fail_note "missing-installer warning absent: $OUT" ;; esac
end_case

begin_case "C11d: reload happens only on refresh rc 2 (fake installer)"
upgrade_sandbox
command rm -f "$S/marker"
make_fake_installer "$S/libexec" 2 "$S/marker" normal
run_upd "$S/libexec" false
case "$OUT" in *"FUNC_RC=0"*) ;; *) fail_note "rc 2: function did not return 0: $OUT" ;; esac
check "refresh rc 2 -> reload called" test -f "$S/marker"
case "$OUT" in *"INFO: tmux: reloaded 9 server(s), 9 client(s)"*) ;; *) fail_note "reload summary not relayed: $OUT" ;; esac
end_case

begin_case "C11e: DRY_RUN writes nothing and reloads nothing"
upgrade_sandbox
cp "$OLD_BYTES" "$LIVE"; cp "$OLD_BYTES" "$S/pre.bytes"
before_home="$(find "$HOME_T" "$AITF" | sort | tr '\n' ' ')"
run_upd "$S/libexec" true
case "$OUT" in *"FUNC_RC=0"*) ;; *) fail_note "dry-run rc: $OUT" ;; esac
case "$OUT" in *"Would check ~/.tmux.conf"*) ;; *) fail_note "dry-run preview line missing: $OUT" ;; esac
check "live untouched under DRY_RUN" same_bytes "$LIVE" "$S/pre.bytes"
check "no receipt under DRY_RUN" test ! -e "$RECEIPT"
check "no sidecar under DRY_RUN" test ! -e "$LIVE.new"
check "no file created/removed under HOME or AITEAMFORGE_DIR" test "$(find "$HOME_T" "$AITF" | sort | tr '\n' ' ')" = "$before_home"
# And with the fake installer: DRY_RUN must not even call refresh/reload.
upgrade_sandbox
command rm -f "$S/marker"
make_fake_installer "$S/libexec" 2 "$S/marker" normal
run_upd "$S/libexec" true
check "DRY_RUN never reaches the reload" test ! -e "$S/marker"
end_case

# ═══════════════════════════════════════════════════════════════════════════
# Summary + vacuous-green guard
# ═══════════════════════════════════════════════════════════════════════════
if [ -n "${_PASS_COUNT+x}" ]; then
    _TOTAL=$((_PASS_COUNT + _FAIL_COUNT))
    echo ""
    echo "XACA-1669 tmux-conf-upgrade-refresh tests: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed (${_TOTAL} assertions executed)"
    if [ "$_TOTAL" -eq 0 ]; then
        echo "FATAL: zero assertions executed — this is a vacuous pass, not a real result" >&2
        exit 1
    fi
    [ "${_FAIL_COUNT:-0}" -eq 0 ] || exit 1
fi
exit 0
