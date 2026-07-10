#!/usr/bin/env bash
# remote-tmux-attach.sh — Local-side reconnecting wrapper for a remote tmux attach.
#
# XACA-0774: replaces the one-shot
#     ssh -t ${HOST} "/bin/zsh -lc 'tmux -L ${SOCKET} attach -t ${SESSION}'"
# used by the *-connect.sh templates' iTerm2 tab `--command` strings. A
# dropped/reconnected SSH link with the one-shot form left the tab holding
# tmux alt-screen + iTerm2 imgcat passthrough residue and a dead attach,
# forcing a full re-run of the connect script. This wrapper fixes that with
# two layers:
#
#   Layer 1 (keepalives) — SSH ServerAlive* options so brief network blips
#     (a few missed pings) don't tear down the underlying TCP session in the
#     first place.
#   Layer 2 (reconnect + reset) — on an *unexpected* drop, reset the local
#     terminal (RIS, `printf '\033c'`) to wipe alt-screen/imgcat residue, then
#     re-run the ssh attach against the SAME tmux session so it silently
#     redraws in place.
#
# ── IMPORTANT: this script runs LOCALLY on the client machine (the box the
# iTerm2 connect-script tab lives on) — it WRAPS the ssh invocation, it does
# not run ON the remote host. This is the opposite of agent-panel-display.sh,
# which the connect templates ship to the REMOTE side via `ssh -t`. Do not
# confuse the two: this file never gets copied to a remote host, and it never
# reads remote-local state — it only shells out to ssh.
#
# Pure SSH. No mosh, no persistent-connection tooling — reconnection is just
# re-running `ssh -t` in a loop against the same tmux session.
#
# ============================================================================
# Usage
# ============================================================================
#   remote-tmux-attach.sh <HOST> <TMUX_SOCKET> <SESSION> [--no-reconnect]
#
#   <HOST>          SSH-reachable hostname (Tailscale MagicDNS name, etc.)
#   <TMUX_SOCKET>   tmux -L socket name on the remote host (e.g. "academy")
#   <SESSION>       tmux session name to attach to (e.g. "academy-lcars")
#   --no-reconnect  Attach once; on any drop, exit instead of looping. Useful
#                   for callers that want the OLD one-shot behavior (or for
#                   manual debugging) without a separate code path.
#
# Env var overrides (kept out of the CLI so callers embedding this inside an
# already-quoted iTerm2 `--command` / ssh string don't need extra args):
#   REMOTE_TMUX_ATTACH_KEEPALIVE_INTERVAL   ServerAliveInterval  (default 15)
#   REMOTE_TMUX_ATTACH_KEEPALIVE_COUNT_MAX  ServerAliveCountMax  (default 3)
#   REMOTE_TMUX_ATTACH_CONNECT_TIMEOUT      ConnectTimeout       (default 10)
#   REMOTE_TMUX_ATTACH_MAX_RETRIES          0 = unlimited        (default 0)
#   REMOTE_TMUX_ATTACH_BACKOFF_BASE         backoff base (secs)  (default 2)
#   REMOTE_TMUX_ATTACH_BACKOFF_MAX          backoff cap  (secs)  (default 30)
#   REMOTE_TMUX_ATTACH_NO_RECONNECT=1       same as --no-reconnect
#
# ============================================================================
# Exit-code / reconnect policy (the important design decision — read before
# changing this file)
# ============================================================================
# `ssh -t HOST 'tmux attach -t SESSION'` exit codes fall into three buckets:
#   0    — the remote command (tmux attach) exited cleanly. This covers BOTH
#          an intentional user detach (tmux prefix-d — the tmux client
#          process exits 0) AND the remote session simply ending. Either way
#          the user (or the session) is done — we MUST NOT reconnect here,
#          or a clean prefix-d would yank the tab straight back into a dead
#          or unrelated session.
#   255  — SSH transport-level failure (by long-standing OpenSSH convention:
#          connection refused/reset, DNS failure, auth failure, "Connection
#          closed by remote host", timeouts). This is the network-blip case
#          Layer 2 exists for — eligible for reconnect.
#   other (1-254) — the remote command itself failed (e.g. tmux exits 1 when
#          the named session doesn't exist). Treated as "unexpected" and also
#          eligible for reconnect, but ALWAYS gated by the session-gone
#          bail-out below, so a truly-dead session doesn't spin forever.
#
# Before reconnecting on 255/other, we independently probe
# `tmux -L <socket> has-session -t <session>` on the remote host. If that
# probe REACHES the host and tmux confirms the session is gone, we stop
# looping immediately and exit non-zero — there is nothing to reconnect to.
# If the probe itself can't reach the host (still offline), that is NOT
# treated as "session gone" — we keep retrying, since a genuine network
# outage is exactly the case Layer 2 exists for. This is deliberately
# checked AFTER every failed attach (not just once at startup), since the
# session can disappear at any point while we're offline/retrying.
#
# Reconnects use exponential backoff (capped) with a max-retry option and
# "reconnecting... (attempt N)" messaging so a permanently-down host doesn't
# silently hammer the network. Ctrl-C during the backoff wait aborts cleanly
# (`sleep` is interrupted, and the top-level INT trap catches it) instead of
# looping forever.
# ============================================================================

set -u

SCRIPT_NAME="$(basename "$0")"

usage() {
    cat >&2 <<EOF

  Usage: ${SCRIPT_NAME} <HOST> <TMUX_SOCKET> <SESSION> [--no-reconnect]

  <HOST>          SSH-reachable hostname
  <TMUX_SOCKET>   tmux -L socket name on the remote host
  <SESSION>       tmux session name to attach to
  --no-reconnect  Attach once; exit on any drop instead of reconnecting.

  Example: ${SCRIPT_NAME} darren-m1pro academy academy-lcars

  Runs LOCALLY — wraps 'ssh -t <HOST> tmux -L <SOCKET> attach -t <SESSION>'
  with keepalives + an unexpected-drop reconnect loop. See header comments
  in this file for the full exit-code / reconnect policy.

EOF
    exit 2
}

# ── Abort cleanly on Ctrl-C (mainly hits us during the backoff `sleep`) ─────
trap 'echo "" >&2; echo "${SCRIPT_NAME}: interrupted." >&2; exit 130' INT

# ============================================================================
# Argument parsing
# ============================================================================
NO_RECONNECT=false
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --no-reconnect) NO_RECONNECT=true ;;
        -h|--help) usage ;;
        -*)
            echo "${SCRIPT_NAME}: unknown flag '${arg}'" >&2
            usage
            ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

[[ ${#POSITIONAL[@]} -lt 3 ]] && usage

HOST="${POSITIONAL[0]}"
TMUX_SOCKET="${POSITIONAL[1]}"
SESSION="${POSITIONAL[2]}"

# Reject characters that would break out of the single-quoted remote command
# string we build below (mirrors the connect templates' _validate_ident,
# XACA-0614-013). Sockets/sessions are always simple identifiers in practice.
_validate_ident() {  # $1=value  $2=label
    if [[ ! "$1" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "${SCRIPT_NAME}: invalid ${2} '${1}' — only letters, digits, '.', '-', '_' are allowed." >&2
        exit 2
    fi
}
_validate_ident "$TMUX_SOCKET" "TMUX_SOCKET"
_validate_ident "$SESSION" "SESSION"

# HOST is passed to ssh as its own argv element (not string-interpolated into
# a shell command), so injection risk is lower — but still reject shell
# metacharacters as defense-in-depth. A leading '-' (the classic
# argv-injection-as-ssh-flag trick) is already rejected upstream: the arg
# parser above routes any leading-dash token into its '-*) unknown flag'
# branch before positionals are assigned, so HOST can never begin with '-'
# here (XACA-0774-014 removed a now-unreachable dedicated check for it).
case "$HOST" in
    *\'*|*\`*|*';'*|*'&'*|*'|'*|*$'\n'*)
        echo "${SCRIPT_NAME}: HOST contains unsafe characters." >&2
        exit 2
        ;;
esac

# ============================================================================
# Tunables (env-overridable — see header)
# ============================================================================
KEEPALIVE_INTERVAL="${REMOTE_TMUX_ATTACH_KEEPALIVE_INTERVAL:-15}"
KEEPALIVE_COUNT_MAX="${REMOTE_TMUX_ATTACH_KEEPALIVE_COUNT_MAX:-3}"
CONNECT_TIMEOUT="${REMOTE_TMUX_ATTACH_CONNECT_TIMEOUT:-10}"
MAX_RETRIES="${REMOTE_TMUX_ATTACH_MAX_RETRIES:-0}"      # 0 = unlimited
BACKOFF_BASE="${REMOTE_TMUX_ATTACH_BACKOFF_BASE:-2}"
BACKOFF_MAX="${REMOTE_TMUX_ATTACH_BACKOFF_MAX:-30}"
[[ "${REMOTE_TMUX_ATTACH_NO_RECONNECT:-0}" == "1" ]] && NO_RECONNECT=true

# Layer 1: keepalives live INSIDE this helper's ssh invocation so callers
# (the connect templates) never have to pass them.
SSH_ATTACH_OPTS=(
    -t
    -o "ServerAliveInterval=${KEEPALIVE_INTERVAL}"
    -o "ServerAliveCountMax=${KEEPALIVE_COUNT_MAX}"
    -o "ConnectTimeout=${CONNECT_TIMEOUT}"
)

REMOTE_CMD="/bin/zsh -lc 'tmux -L ${TMUX_SOCKET} attach -t ${SESSION}'"

# ============================================================================
# Helpers
# ============================================================================

# Session-gone bail-out probe (used both pre- and post-attempt). Uses a
# short, separate (non -t) SSH call so it doesn't allocate a pty or fight
# with the attach itself.
#
# Returns (via $?):
#   0 — session confirmed present
#   1 — reached the host fine; tmux confirmed no such session (real bail-out)
#   2 — could NOT reach the host to check (ssh itself failed, exit 255) —
#       this is the network-still-down case and must NOT be treated as
#       "session gone", or a genuine outage would wrongly cut the loop short
#       right when Layer 2 is supposed to keep retrying.
check_session_status() {
    ssh -o ConnectTimeout=5 -o BatchMode=yes "$HOST" \
        "/bin/zsh -lc 'tmux -L ${TMUX_SOCKET} has-session -t ${SESSION}'" 2>/dev/null
    local rc=$?
    if [[ $rc -eq 0 ]]; then
        return 0
    elif [[ $rc -eq 255 ]]; then
        return 2
    else
        return 1
    fi
}

# RIS (Reset to Initial State). Clears tmux alt-screen residue and any
# stuck iTerm2 imgcat inline-image passthrough sequences left behind by a
# torn-down connection, so the re-attach redraws onto a clean pane.
reset_terminal() {
    printf '\033c'
}

# ============================================================================
# Attach / reconnect loop
# ============================================================================
attempt=0
while true; do
    # shellcheck disable=SC2029
    ssh "${SSH_ATTACH_OPTS[@]}" "$HOST" "$REMOTE_CMD"
    exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        # Clean tmux client exit — either an intentional user detach
        # (prefix-d) or the remote session ending on its own. Respect it:
        # do NOT reconnect (see policy comment at top of file).
        exit 0
    fi

    if [[ "$NO_RECONNECT" == "true" ]]; then
        echo "${SCRIPT_NAME}: ssh exited ${exit_code}, reconnect disabled (--no-reconnect). Exiting." >&2
        exit "$exit_code"
    fi

    # Bail out only if the session is CONFIRMED gone remotely (status 1) —
    # nothing to reconnect to. Status 2 (host unreachable) is the ongoing-
    # outage case and must keep retrying, not bail out.
    check_session_status
    _session_status=$?
    if [[ $_session_status -eq 1 ]]; then
        echo "" >&2
        echo "${SCRIPT_NAME}: tmux session '${SESSION}' no longer exists on ${HOST} (socket ${TMUX_SOCKET}). Not reconnecting." >&2
        exit 1
    fi

    attempt=$((attempt + 1))
    if [[ "$MAX_RETRIES" -gt 0 && "$attempt" -gt "$MAX_RETRIES" ]]; then
        echo "${SCRIPT_NAME}: giving up after ${MAX_RETRIES} reconnect attempt(s)." >&2
        exit "$exit_code"
    fi

    # Exponential backoff, capped at BACKOFF_MAX. Clamp the exponent before
    # computing BACKOFF_BASE ** attempt: in unlimited-retry mode (MAX_RETRIES=0)
    # `attempt` grows without bound, and a large exponent overflows bash's
    # 64-bit signed integer arithmetic to a negative value — which would slip
    # past the `> BACKOFF_MAX` cap and feed `sleep` a negative arg, spuriously
    # aborting the loop during exactly the long outage Layer 2 must survive.
    # Any exponent past the cap-crossing point yields the same capped wait, so
    # clamping the exponent is behaviourally identical and overflow-proof.
    backoff_exp=$attempt
    (( backoff_exp > 30 )) && backoff_exp=30
    wait_s=$(( BACKOFF_BASE ** backoff_exp ))
    (( wait_s <= 0 || wait_s > BACKOFF_MAX )) && wait_s=$BACKOFF_MAX

    # Reconnect/backoff progress is diagnostic status, not program output —
    # send it to stderr (XACA-0774-013) so it never mixes with anything a
    # caller might capture on stdout. In the normal interactive-tab case both
    # streams land on the same terminal, so this is behaviour-neutral there.
    reset_terminal
    echo "" >&2
    if [[ $_session_status -eq 2 ]]; then
        echo "  (${HOST} unreachable — cannot verify session yet; will keep retrying)" >&2
    fi
    if [[ "$MAX_RETRIES" -gt 0 ]]; then
        echo "  ⚠ connection to ${HOST} dropped (ssh exit ${exit_code}) — reconnecting… (attempt ${attempt}/${MAX_RETRIES})" >&2
    else
        echo "  ⚠ connection to ${HOST} dropped (ssh exit ${exit_code}) — reconnecting… (attempt ${attempt})" >&2
    fi
    echo "  Retrying in ${wait_s}s (Ctrl-C to abort)..." >&2

    if ! sleep "$wait_s"; then
        # Ctrl-C (or another signal) during the wait — abort instead of
        # looping forever. The INT trap above also covers this, but this
        # catches sleep's own non-zero exit in case the trap doesn't fire
        # before sleep returns.
        echo "" >&2
        echo "${SCRIPT_NAME}: aborted during reconnect wait." >&2
        exit 130
    fi
done
