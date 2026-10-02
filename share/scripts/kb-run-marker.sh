#!/bin/bash
# kb-run-marker.sh — "what was RUNNING" markers for last-running restore (XACA-1380-002)
#
# Each <team>-startup.sh records a marker when its tmux sessions are up; each
# <team>-shutdown.sh clears it once tmux confirms the sessions are gone. After a power
# loss the markers that remain are exactly the teams that were running, and
# kb-host-ready.sh (XACA-1380-003) restores them at login.
#
# Design: kanban/plans/XACA-1380/XACA-1380-001_design.md §1-§2.
#
# Sourced library (zsh, /bin/bash 3.2, bash 5) AND CLI:
#   kb_run_marker_write [--match <session-prefix>] <team> [args...]   live-session gate, atomic write, arms .armed. Always rc 0.
#   kb_run_marker_clear <team> [args...]   set-match delete, only when tmux shows no live match. Always rc 0.
#   kb_run_marker_dir                      echo the marker directory
#   kb_claude_live_clear_socket <socket>   sweep Claude liveness markers of that socket whose tmux
#                                          session is gone (XACA-1380-025). Always rc 0.
#   kb-run-marker.sh list | forget <prefix> | write ... | clear ... | live-clear-socket <socket>
#
# XACA-1380-025 (Claude liveness markers, KB_CLAUDE_LIVE_DIR, written by claude_code_cc_aliases.sh):
#   - clear ALSO sweeps the liveness markers of the sessions it just confirmed gone: a stopped team
#     was not running, so its windows' conversations must never be auto-resumed later.
#   - write ALSO installs a per-server tmux hook window-unlinked[1380] that drops the liveness marker
#     of a window killed (kill-window / kill-session / pane exit) while its server keeps running.
#     Measured (tmux 3.6a): the hook does NOT fire on kill-server or a SIGTERM'd server, and nothing
#     fires on a power loss -- exactly the case whose markers must survive.
#
# --match: for a team whose tmux sessions are NOT named after its args (<team>-<agent> only), the
# marker keeps args (to relaunch) but is judged live by this explicit session prefix instead.
# Stored as an optional "match" field; schema_version stays 1 (old markers read unchanged).
# Session ownership is EXCLUSIVE: <prefix> or <prefix>-<one hyphen-free word>; "x-y-command" is not x's.
#
# Marker dir: ${KB_RUN_MARKER_DIR:-$HOME/.aiteamforge/run/teams-running}  (tests MUST set it)
#
# GOTCHA: the shell layer is deliberately dumb (argument passing only). All JSON, lowercasing
# and tmux probing happen in python3 so the identical text behaves the same under every shell
# dialect. No arrays, no [[ =~ ]], no ${var,,}, no declare -A here. Keep it that way.
# A marker failure must NEVER fail a startup or shutdown: every entry point returns 0.

kb_run_marker_dir() {
    printf '%s\n' "${KB_RUN_MARKER_DIR:-$HOME/.aiteamforge/run/teams-running}"
}

_krm_py() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "warn: kb-run-marker: python3 not found — run marker not updated" >&2
        return 0
    fi
    KRM_MARKER_DIR="$(kb_run_marker_dir)" KRM_SELF="${_KRM_SELF:-}" \
        KRM_LIVE_DIR="${KB_CLAUDE_LIVE_DIR:-$HOME/.aiteamforge/run/claude-live}" python3 - "$@" <<'KRM_PY'
import json, os, re, signal, subprocess, sys, time

ALLOW = re.compile(r'^[A-Za-z0-9._-]+$')
MDIR = os.environ.get("KRM_MARKER_DIR", "")
LDIR = os.environ.get("KRM_LIVE_DIR", "")
# A path baked into a tmux hook body must survive tmux's own parser (single quotes) AND /bin/sh
# (double quotes) AND run-shell's format expansion (#): no quote, $, `, backslash, #, ; or ~ in it.
HOOKSAFE = re.compile(r'^/[A-Za-z0-9._/ @+,:=-]+$')
TMUX_PROBE = ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux")  # launchd PATH lacks brew (XACA-0713)


def warn(msg):
    sys.stderr.write("warn: kb-run-marker: %s\n" % msg)


def find_tmux():
    for p in TMUX_PROBE:
        if os.access(p, os.X_OK):
            return p
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, "tmux")
        if d and os.access(p, os.X_OK):
            return p
    return None


def run_tmux(sock, *args):
    """Return (rc, stdout, stderr) or None when tmux is unusable/hung (3s SIGKILL watchdog,
    a stale socket can hang list-sessions forever — XACA-0830-002)."""
    tmux = find_tmux()
    if not tmux:
        return None
    env = dict(os.environ)
    env.pop("TMUX", None)
    try:
        p = subprocess.Popen([tmux, "-L", sock] + list(args), stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                             universal_newlines=True)
    except Exception:
        return None
    try:
        out, err = p.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            p.send_signal(signal.SIGKILL)
        except Exception:
            pass
        try:
            p.communicate(timeout=2)
        except Exception:
            pass
        return None
    return (p.returncode, out, err)


NOSERVER = re.compile(r"no server running|error connecting|failed to connect|no sessions|"
                      r"no such file", re.I)


def live_sessions(sock):
    """List of session names; [] when no server; None when the answer is unknown."""
    r = run_tmux(sock, "list-sessions", "-F", "#{session_name}")
    if r is None:
        return None
    rc, out, err = r
    if rc == 0:
        return [l for l in out.splitlines() if l]
    if NOSERVER.search(err or ""):
        return []
    return None


def belongs(prefix, name):
    """EXCLUSIVE session match (XACA-1380-013/015). A team's sessions are exactly <prefix> or
    <prefix>-<base> where <base> is ONE hyphen-free station word (lcars, command, ...). A longer
    sibling prefix (x-y-command vs x) therefore does NOT belong to x. Keep byte-identical in
    spirit with _hr_team_already_up in kb-host-ready.sh."""
    if name == prefix:
        return True
    if not name.startswith(prefix + "-"):
        return False
    return "-" not in name[len(prefix) + 1:]


def matches(prefix, names):
    return any(belongs(prefix, n) for n in names)


def derive(team, args):
    return team.lower() + "".join("-" + a.lower() for a in args)


def validate(team, args):
    if not team or not ALLOW.match(team) or team.startswith("."):
        return "invalid team %r" % team
    for a in args:
        if not a or not ALLOW.match(a):
            return "invalid arg %r (allowed: A-Za-z0-9._-)" % a
    return None


def hostname():
    for cmd in (["scutil", "--get", "LocalHostName"], ["hostname", "-s"]):
        try:
            h = subprocess.check_output(cmd, stderr=subprocess.DEVNULL,
                                        universal_newlines=True, timeout=3).strip()
            if h:
                return h
        except Exception:
            pass
    # XACA-1380-021: NO socket.gethostname() fallback. The reader (_hr_this_host in kb-host-ready.sh)
    # uses exactly this chain and treats "empty" as "unknown host -> fail closed". A host the reader
    # would not derive must never be stored, so the caller skips the write on "".
    return ""


def list_markers():
    try:
        names = sorted(os.listdir(MDIR))
    except OSError:
        return []
    return [n for n in names if n.endswith(".json") and not n.startswith(".")
            and ".tmp." not in n]


def match_key(doc, stem):
    """The session-name prefix liveness is judged by. Normally the marker's own derived prefix
    (== stem); a marker written with --match carries an explicit key because its sessions are
    not named after its args (legacy team-project template: sessions <team>-<agent>, XACA-1380-017).
    Old markers have no "match" -> stem, unchanged behaviour."""
    m = doc.get("match") if isinstance(doc, dict) else None
    if isinstance(m, str) and m and ALLOW.match(m) and not m.startswith("."):
        return m
    return stem


def load_doc(stem):
    try:
        with open(os.path.join(MDIR, stem + ".json")) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def live_markers():
    """(name, fields) for every top-level Claude liveness marker (9-field v1 lines only;
    anything else is left alone -- kb-host-ready refuses it as malformed anyway)."""
    out = []
    try:
        names = sorted(os.listdir(LDIR)) if LDIR else []
    except OSError:
        return out
    for n in names:
        p = os.path.join(LDIR, n)
        if n.startswith(".") or ".tmp" in n or not os.path.isfile(p):
            continue
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as fh:
                f = fh.readline().rstrip("\n").split("|")
        except OSError:
            continue
        if len(f) == 9 and f[0] == "1":
            out.append((n, f))
    return out


def sweep_live(sock, names, keys):
    """XACA-1380-025(c): drop liveness markers on socket <sock> whose session is NOT live any more.
    keys=None -> every session of the socket; else only sessions owned (belongs) by one of keys,
    so stopping one prefix never touches a sibling prefix sharing the socket. A session that is
    still live keeps its marker (its window may still be running claude)."""
    for n, f in live_markers():
        if f[3] != sock or f[4] in names:
            continue
        if keys is not None and not any(belongs(k, f[4]) for k in keys):
            continue
        try:
            os.unlink(os.path.join(LDIR, n))
        except OSError:
            pass


def install_unlink_hook(team):
    """XACA-1380-025(e): per-server hook removing the liveness marker of a window that is
    unlinked while the server keeps running. Best effort; never fails the write. One hook per
    server is correct here (unlike a per-session LCARS tmp dir, XACA-1255): the only value baked
    in is this helper's path, which is the same for every session of the host; the marker dir is
    read from the server environment at fire time."""
    selfp = os.environ.get("KRM_SELF", "")
    if not selfp:
        return
    selfp = os.path.realpath(selfp)
    if not HOOKSAFE.match(selfp) or not os.path.isfile(selfp):
        warn("not installing the window-unlinked hook: unusable helper path %r" % selfp)
        return
    body = ("run-shell -b '/bin/bash \"%s\" live-unlinked #{q:socket_path} #{q:hook_session_name} "
            "#{q:hook_window_name} #{pid} #{start_time} >/dev/null 2>&1'" % selfp)
    r = run_tmux(team, "set-hook", "-g", "window-unlinked[1380]", body)
    if not r or r[0] != 0:
        warn("could not install the window-unlinked hook on socket '%s'" % team)


def cmd_live_unlinked(sockpath, session, window, pid, start):
    """Hook handler: window <window> of session <session> on the server (pid, start) at socket
    <sockpath> was unlinked while that server lived on -> its conversation is not live; drop the
    liveness marker. Matches the marker's server identity too, so a marker from any other server
    lifetime is never touched here."""
    sock = os.path.basename(sockpath)
    session = session.replace("|", " ")
    window = window.replace("|", " ")
    if not (sock and session and window and start.isdigit()):
        return
    for n, f in live_markers():
        if f[3] == sock and f[4] == session and f[5] == window and f[6] == start and f[7] == pid:
            try:
                os.unlink(os.path.join(LDIR, n))
            except OSError:
                pass


def cmd_live_clear_socket(sock):
    if not sock or not ALLOW.match(sock) or sock.startswith("."):
        warn("not sweeping liveness markers: invalid socket %r" % sock)
        return
    names = live_sessions(sock)
    if names is None:
        warn("tmux probe failed on socket '%s' -- liveness markers kept" % sock)
        return
    sweep_live(sock, names, None)


def cmd_write(team, args, match=None):
    bad = validate(team, args)
    if not bad and match is not None and (not ALLOW.match(match) or match.startswith(".")):
        bad = "invalid --match %r" % match
    if bad:
        warn("not writing marker: " + bad)
        return
    prefix = derive(team, args)
    live_key = match.lower() if match is not None else prefix
    names = live_sessions(team)
    if names is None:
        warn("tmux probe failed on socket '%s' — no marker written for %s" % (team, prefix))
        return
    if not matches(live_key, names):
        warn("no live session for '%s' on socket '%s' — no marker written" % (live_key, team))
        return
    host = hostname()
    if not host:
        warn("cannot determine this host (scutil and hostname -s both failed) — no marker written for %s" % prefix)
        return
    srv_pid = srv_start = None
    r = run_tmux(team, "display-message", "-p", "#{pid} #{start_time}")
    if r and r[0] == 0:
        parts = r[1].split()
        if len(parts) == 2 and all(x.isdigit() for x in parts):
            srv_pid, srv_start = int(parts[0]), int(parts[1])
    now = time.time()
    doc = {
        "schema_version": 1,
        "team": team,
        "args": list(args),          # verbatim argv, ORIGINAL casing (only place it survives)
        "prefix": prefix,
        "socket": team,
        "host": host,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)),
        "started_epoch": int(now),
        "startup_pid": os.getppid(),
        "tmux_server_pid": srv_pid,      # diagnostic only, never a restore gate
        "tmux_server_start": srv_start,  # diagnostic only
    }
    if match is not None:
        doc["match"] = live_key      # optional: session prefix to judge liveness by (XACA-1380-017)
    os.makedirs(MDIR, mode=0o700, exist_ok=True)
    final = os.path.join(MDIR, prefix + ".json")
    tmp = os.path.join(MDIR, ".%s.json.tmp.%d" % (prefix, os.getpid()))
    try:
        with open(tmp, "w") as f:
            json.dump(doc, f, indent=2, sort_keys=False)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, final)   # atomic within one dir on APFS
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    armed = os.path.join(MDIR, ".armed")
    if not os.path.exists(armed):
        atmp = os.path.join(MDIR, ".armed.tmp.%d" % os.getpid())
        with open(atmp, "w") as f:
            f.write(doc["started_at"] + "\n")
        os.replace(atmp, armed)
    install_unlink_hook(team)


def cmd_clear(team, args):
    bad = validate(team, args)
    if bad:
        warn("not clearing markers: " + bad)
        return
    flt = derive(team, args)
    # XACA-1380-023: with args, the candidate is EXACTLY that marker (stem == prefix). The old
    # prefix-family filter let "stop bw" delete a crashed sibling bw-dash's orphan marker. A no-arg
    # (whole team) clear keeps the set-match: every marker of the team, each kept while live.
    if args:
        cand = [n[:-5] for n in list_markers() if n[:-5] == flt]
    else:
        cand = [n[:-5] for n in list_markers() if n[:-5] == flt or n[:-5].startswith(flt + "-")]
    # XACA-1380-025(c): the liveness sweep runs even when there is no run-marker to clear. Its
    # session-ownership key is read BEFORE the run-marker is deleted (a --match team's sessions
    # are not named after its args).
    live_keys = [match_key(load_doc(flt), flt)] if args else None
    names = live_sessions(team)
    if names is None:
        warn("tmux probe failed on socket '%s' — markers kept (bias toward restore)" % team)
        return
    sweep_live(team, names, live_keys)
    for stem in cand:
        if matches(match_key(load_doc(stem), stem), names):
            warn("sessions for '%s' still alive — marker kept" % stem)
            continue
        try:
            os.unlink(os.path.join(MDIR, stem + ".json"))
        except OSError:
            pass


def cmd_list():
    stems = list_markers()
    if not stems:
        armed = os.path.exists(os.path.join(MDIR, ".armed"))
        print("no markers (%s)" % ("armed: nothing was running" if armed else "never armed"))
        return 0
    print("%-34s %-24s %-26s %-8s %s" % ("PREFIX", "ARGS", "STARTED", "SERVER", "TEAM"))
    for n in stems:
        stem = n[:-5]
        try:
            with open(os.path.join(MDIR, n)) as f:
                d = json.load(f)
            if not isinstance(d, dict):
                raise ValueError("root not an object")
        except Exception:
            print("%-34s malformed marker" % stem)
            continue
        team = d.get("team") or stem.split("-")[0]
        sock = d.get("socket") or team
        names = live_sessions(sock)
        up = "unknown" if names is None else ("up" if matches(match_key(d, stem), names) else "down")
        pid, st = d.get("tmux_server_pid"), d.get("tmux_server_start")
        srv = "n/a"
        if pid is not None and st is not None:
            r = run_tmux(sock, "display-message", "-p", "#{pid} #{start_time}")
            if r and r[0] == 0:
                srv = "alive" if r[1].split() == [str(pid), str(st)] else "gone"
            else:
                srv = "gone"
        note = "  orphaned: will restore at next login" if up == "down" else ""
        print("%-34s %-24s %-26s %-8s %s%s" % (stem, " ".join(d.get("args") or []) or "-",
                                               d.get("started_at", "?"), srv, up, note))
    return 0


def cmd_forget(prefix):
    if not prefix or not ALLOW.match(prefix) or prefix.startswith("."):
        sys.stderr.write("error: bad prefix %r\n" % prefix)
        return 2
    p = os.path.join(MDIR, prefix + ".json")
    if not os.path.exists(p):
        sys.stderr.write("error: no marker for '%s'\n" % prefix)
        return 1
    os.unlink(p)
    print("forgot %s" % prefix)
    return 0


def main(argv):
    if not MDIR:
        warn("no marker dir")
        return 0
    if not argv:
        sys.stderr.write("usage: kb-run-marker.sh write|clear <team> [args...] | list | forget <prefix>\n")
        return 2
    sub, rest = argv[0], argv[1:]
    try:
        if sub == "write" and rest:
            mk = None
            if rest[0] == "--match":
                if len(rest) < 3:
                    sys.stderr.write("usage: kb-run-marker.sh write [--match <session-prefix>] <team> [args...]\n")
                    return 2
                mk, rest = rest[1], rest[2:]
            cmd_write(rest[0], rest[1:], mk)
        elif sub == "clear" and rest:
            cmd_clear(rest[0], rest[1:])
        elif sub == "live-clear-socket" and len(rest) == 1:
            cmd_live_clear_socket(rest[0])
        elif sub == "live-unlinked" and len(rest) == 5:
            cmd_live_unlinked(*rest)
        elif sub == "list":
            return cmd_list()
        elif sub == "forget" and len(rest) == 1:
            return cmd_forget(rest[0])
        else:
            sys.stderr.write("usage: kb-run-marker.sh write|clear <team> [args...] | list | forget <prefix>\n")
            return 2
    except Exception as e:  # never fail a startup/shutdown over a marker
        warn("%s failed: %s" % (sub, e))
    return 0


sys.exit(main(sys.argv[1:]))
KRM_PY
}

kb_run_marker_write() { _krm_py write "$@" || true; return 0; }
kb_run_marker_clear() { _krm_py clear "$@" || true; return 0; }
kb_claude_live_clear_socket() { _krm_py live-clear-socket "$@" || true; return 0; }

# This file's own absolute path, baked into the window-unlinked hook (XACA-1380-025e). zsh: %x is
# the file being sourced/executed (eval'd so bash never parses the zsh-only expansion).
if [ -n "${ZSH_VERSION:-}" ]; then
    _KRM_SELF="$(eval 'printf "%s" "${(%):-%x}"' 2>/dev/null)"
else
    _KRM_SELF="${BASH_SOURCE:-$0}"
fi
case "$_KRM_SELF" in /*) ;; ?*) _KRM_SELF="$(pwd -P)/$_KRM_SELF" ;; esac

# CLI mode: only when EXECUTED. When sourced we must not touch the caller's "$@".
_krm_run=""
if [ -n "${ZSH_VERSION:-}" ]; then
    case "${ZSH_EVAL_CONTEXT:-}" in *:file*) ;; *) _krm_run=1 ;; esac
elif [ -n "${BASH_VERSION:-}" ]; then
    [ "${BASH_SOURCE:-}" = "$0" ] && _krm_run=1
fi
if [ -n "$_krm_run" ]; then
    unset _krm_run
    case "${1:-}" in
        # Explicit calls, NOT "kb_run_marker_$sub": a runtime-built helper name is invisible to the
        # XACA-1151 shipped-script helper scanner (check-dynamic-names fails the real tree on it).
        write) shift; kb_run_marker_write "$@"; exit 0 ;;
        clear) shift; kb_run_marker_clear "$@"; exit 0 ;;
        live-clear-socket) shift; kb_claude_live_clear_socket "$@"; exit 0 ;;
        live-unlinked) _krm_py "$@"; exit 0 ;;
        list|forget) _krm_py "$@"; exit $? ;;
        dir) kb_run_marker_dir; exit 0 ;;
        *) echo "usage: kb-run-marker.sh write|clear <team> [args...] | list | forget <prefix> | dir | live-clear-socket <socket>" >&2; exit 2 ;;
    esac
fi
unset _krm_run
