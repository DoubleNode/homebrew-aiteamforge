#!/usr/bin/env python3
"""power-guard-runner: the ACTING half of the UPS power-guard (XACA-1394-004).

power-guard.py DECIDES (it never acts). This file is what the root
LaunchDaemon (EPIC-0067 D4, option (a); plist template is XACA-1394-005)
runs every StartInterval. One invocation == one evaluation; there is no loop.

    /usr/bin/python3 power-guard-runner.py \
        --state-file F --policy-file F --counter-file F \
        --log-file L --notify-user USERNAME \
        [--marker-file M] [--dry-run-force] [--kb-msg-to TEAM]

Root's $HOME is /var/root, so the plist passes the console user's paths and
name explicitly. Nothing here auto-detects the user, and NOTHING here reads an
environment variable: a stray env var inherited by the daemon must never be
able to redirect, suppress, or fake a shutdown.

WHAT EACH VERDICT DOES
  NO_ACTION       log one line. Nothing else.
  WOULD_SHUTDOWN  log one line; notify (macOS + kb-msg) only on the TRANSITION
                  into WOULD_SHUTDOWN, not every 30 s. Never shuts down.
  SHUTDOWN        acts only if ALL hold:
                    (a) verdict is exactly the str "SHUTDOWN", and the verdict
                        also reports enabled is True and dry_run is False;
                    (b) geteuid() == 0;
                    (c) the marker file can be CREATED (O_CREAT|O_EXCL), i.e.
                        no shutdown was initiated yet this boot (/var/run is
                        cleared at boot).
                  Non-root => loud error line, nothing else.
                  --dry-run-force => downgraded to WOULD_SHUTDOWN.

  Anything odd from power-guard (import failure, exception, non-dict, missing
  or unknown verdict) is NO_ACTION. A false shutdown is the harm D4 forbids.

SHUTDOWN ORDERING (and why)
  1. log the evaluation line      -- the record of WHY exists before any act.
                                     Logging is best-effort: a failure here is
                                     swallowed and does not stop steps 2-5.
  2. create the marker (O_EXCL)   -- the once-per-boot latch is taken BEFORE
                                     any side effect, so a crash, a kill, or
                                     an overlapping run mid-sequence can never
                                     repeat the notify/shutdown sequence. EEXIST
                                     => already initiated, stop. Any OTHER
                                     marker error is logged and we PROCEED:
                                     the verdict is valid, a failed latch is
                                     not evidence of bad data, and a missed
                                     shutdown is a hard power-off. Worst case
                                     without a latch is a repeated, harmless
                                     `shutdown -h now`.
  3. log "initiating"             -- best-effort.
  4. notify macOS, then kb-msg    -- each in its own process group with a hard
                                     NOTIFY_TIMEOUT_S, all output to /dev/null
                                     (no pipes a grandchild could hold open),
                                     every exception swallowed. Notifying
                                     BEFORE the shutdown is the point: after
                                     it nobody is left to send anything.
  5. /sbin/shutdown -h now        -- literal argv, no shell, minimal env.
     If it fails to launch or exits non-zero, the marker is REMOVED so the
     next StartInterval retries (a held latch would turn a transient failure
     into a missed shutdown for the rest of the boot).

kb-msg TARGET
  Team broadcast to `academy` (override with --kb-msg-to). Sent as the
  notify-user with KB_TEAM=power-guard, KB_TERMINAL=<short hostname>, so the
  sender differs from the target and kb-msg takes its cross-machine relay
  path when academy is not live on this machine. Best-effort: if
  kanban-helpers.sh cannot be found, or kb-msg fails, it is logged and skipped.

TEST SEAMS
  SHUTDOWN_ARGV, geteuid, execute_shutdown, _spawn, lookup_user,
  load_decide, NOTIFY_TIMEOUT_S are module globals that tests monkeypatch.
  They are deliberately NOT environment variables (see above).

Must run under /usr/bin/python3 (3.9): no match/case, no `X | Y` types.
"""
import argparse
import datetime
import errno
import importlib.util
import json
import os
import pwd
import signal
import socket
import subprocess
import sys
import tempfile

NO_ACTION = "NO_ACTION"
WOULD_SHUTDOWN = "WOULD_SHUTDOWN"
SHUTDOWN = "SHUTDOWN"
KNOWN_VERDICTS = (NO_ACTION, WOULD_SHUTDOWN, SHUTDOWN)

DEFAULT_LOG_FILE = "/Library/Logs/aiteamforge/power-guard.log"
DEFAULT_MARKER_FILE = "/var/run/aiteamforge-power-guard.shutdown-initiated"
LAST_VERDICT_BASENAME = "aiteamforge-power-guard.last-verdict"
DEFAULT_KB_MSG_TO = "academy"

LOG_MAX_BYTES = 1024 * 1024  # rotate to <log>.1 above this; one generation kept
NOTIFY_TIMEOUT_S = 10
SHUTDOWN_TIMEOUT_S = 30
REASON_MAX = 500

HERE = os.path.dirname(os.path.abspath(__file__))
POWER_GUARD_PATH = os.path.join(HERE, "power-guard.py")
INSTALL_ROOT = os.path.dirname(os.path.dirname(HERE))  # <root>/fleet-monitor/client

# Environment for every child. Fixed, never inherited.
CLEAN_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
KB_MSG_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ---------------------------------------------------------------------------
# TEST SEAMS (module globals; tests monkeypatch these, the daemon never can)
# ---------------------------------------------------------------------------
SHUTDOWN_ARGV = ("/sbin/shutdown", "-h", "now")
geteuid = os.geteuid
lookup_user = pwd.getpwnam


def _spawn(argv, timeout):
    """Run argv (no shell) with all stdio on /dev/null, in its own process
    group, with a hard timeout. Returns the exit code, or None on timeout.
    Raises only if the process cannot be started."""
    proc = subprocess.Popen(
        list(argv), shell=False, close_fds=True, start_new_session=True,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL, env={"PATH": CLEAN_PATH})
    try:
        return proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            proc.kill()
        except OSError:
            pass
        try:
            proc.wait(timeout=2)
        except Exception:
            pass
        return None


def _execute_shutdown(argv):
    """The ONLY place a shutdown is executed. Returns the exit code (None on
    timeout). Tests replace `execute_shutdown`, never call this directly
    except through the tripwire test."""
    return _spawn(argv, SHUTDOWN_TIMEOUT_S)


execute_shutdown = _execute_shutdown


def load_decide():
    """Import power-guard.py by path and return its decide(). Bytecode
    writing is disabled: as root it would leave root-owned __pycache__ in the
    install dir."""
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("power_guard", POWER_GUARD_PATH)
    if spec is None or spec.loader is None:
        raise ImportError("cannot load %s" % POWER_GUARD_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.decide


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def _now_str():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _host():
    try:
        return socket.gethostname() or "this machine"
    except Exception:
        return "this machine"


def _one_line(s, limit=REASON_MAX):
    s = str(s).replace("\r", " ").replace("\n", " ")
    return s if len(s) <= limit else s[:limit] + "..."


def log_line(log_file, msg):
    """Append one line. Never raises; returns True on success."""
    try:
        d = os.path.dirname(os.path.abspath(log_file))
        if not os.path.isdir(d):
            os.makedirs(d, 0o755, exist_ok=True)
        try:
            if os.path.getsize(log_file) > LOG_MAX_BYTES:
                os.replace(log_file, log_file + ".1")
        except OSError:
            pass
        fd = os.open(log_file, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o644)
        try:
            os.write(fd, ("%s %s\n" % (_now_str(), _one_line(msg, 2000))).encode("utf-8", "replace"))
        finally:
            os.close(fd)
        return True
    except Exception:
        return False


def evaluate(state_file, policy_file, counter_file):
    """Return (verdict, reason, accessory_id, raw). Fails closed to NO_ACTION."""
    try:
        decide = load_decide()
    except Exception as exc:
        return NO_ACTION, "power-guard import failed, failing closed: %s: %s" % (
            type(exc).__name__, exc), None, None
    try:
        raw = decide(policy_file, state_file, counter_file)
    except Exception as exc:
        return NO_ACTION, "power-guard raised, failing closed: %s: %s" % (
            type(exc).__name__, exc), None, None
    if not isinstance(raw, dict):
        return NO_ACTION, "power-guard returned %s, not an object; failing closed" % (
            type(raw).__name__,), None, raw
    verdict = raw.get("verdict")
    reason = raw.get("reason")
    acc = raw.get("accessory_id")
    if not isinstance(reason, str):
        reason = repr(reason)
    if not isinstance(acc, str):
        acc = None
    if type(verdict) is not str or verdict not in KNOWN_VERDICTS:
        return NO_ACTION, "power-guard verdict %r unrecognised; failing closed" % (verdict,), acc, raw
    if verdict == SHUTDOWN and not (raw.get("enabled") is True and raw.get("dry_run") is False):
        return NO_ACTION, ("power-guard said SHUTDOWN but enabled=%r dry_run=%r; "
                           "inconsistent, failing closed" % (raw.get("enabled"), raw.get("dry_run"))), acc, raw
    return verdict, reason, acc, raw


def _last_verdict_path(marker_file):
    return os.path.join(os.path.dirname(os.path.abspath(marker_file)), LAST_VERDICT_BASENAME)


def read_last_verdict(path):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def write_last_verdict(path, verdict):
    try:
        d = os.path.dirname(os.path.abspath(path))
        fd, tmp = tempfile.mkstemp(prefix=".pg-last-verdict.", dir=d)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write(verdict + "\n")
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return True
    except Exception:
        return False


def take_marker(marker_file):
    """Create the once-per-boot latch. Returns "taken", "exists", or an error
    string (latch could not be created for some other reason)."""
    try:
        fd = os.open(marker_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    except OSError as exc:
        if exc.errno == errno.EEXIST:
            return "exists"
        return "error: %s" % exc
    try:
        os.write(fd, ("%s pid=%d\n" % (_now_str(), os.getpid())).encode())
    except OSError:
        pass
    finally:
        os.close(fd)
    return "taken"


def _applescript_str(s):
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')


def build_notify_commands(user, title, message, kb_msg_to):
    """Return [(name, argv)] for the console notification and kb-msg. Never
    raises; an unresolvable user yields an empty list."""
    try:
        pw = lookup_user(user)
    except Exception:
        return []
    cmds = []
    script = "display notification %s with title %s sound name \"Sosumi\"" % (
        _applescript_str(_one_line(message, 240)), _applescript_str(title))
    cmds.append(("macos-notification", [
        "/bin/launchctl", "asuser", str(pw.pw_uid),
        "/usr/bin/sudo", "-n", "-u", user,
        "/usr/bin/osascript", "-e", script]))

    helpers = None
    for cand in (os.path.join(INSTALL_ROOT, "kanban-helpers.sh"),
                 os.path.join(pw.pw_dir, "aiteamforge", "kanban-helpers.sh"),
                 os.path.join(pw.pw_dir, "dev-team", "kanban-helpers.sh")):
        if os.path.isfile(cand):
            helpers = cand
            break
    if helpers:
        host = _host().split(".")[0] or "unknown"
        # The body and target are positional args ($2/$3), never interpolated
        # into the script text, so nothing in a reason can become shell code.
        cmds.append(("kb-msg", [
            "/usr/bin/sudo", "-n", "-u", user, "-H",
            "/usr/bin/env", "HOME=" + pw.pw_dir, "USER=" + user, "LOGNAME=" + user,
            "PATH=" + KB_MSG_PATH, "KB_TEAM=power-guard", "KB_TERMINAL=" + host,
            "/bin/zsh", "-f", "-c",
            'source "$1" >/dev/null 2>&1 || exit 3; kb-msg send "$2" "$3"',
            "power-guard", helpers, kb_msg_to, "%s: %s" % (title, _one_line(message, 400))]))
    return cmds


def notify(log_file, user, title, message, kb_msg_to):
    """Best-effort. Every failure is logged and swallowed. Never raises."""
    try:
        cmds = build_notify_commands(user, title, message, kb_msg_to)
    except Exception as exc:
        log_line(log_file, "notify: could not build commands: %s" % exc)
        return
    if not cmds:
        log_line(log_file, "notify: user %r not resolvable; no notifications sent" % user)
    if not any(n == "kb-msg" for n, _ in cmds) and cmds:
        log_line(log_file, "notify: kanban-helpers.sh not found; kb-msg skipped")
    for name, argv in cmds:
        try:
            rc = _spawn(argv, NOTIFY_TIMEOUT_S)
            if rc is None:
                log_line(log_file, "notify: %s timed out after %ss (killed)" % (name, NOTIFY_TIMEOUT_S))
            elif rc != 0:
                log_line(log_file, "notify: %s exited %s" % (name, rc))
        except Exception as exc:
            log_line(log_file, "notify: %s failed: %s: %s" % (name, type(exc).__name__, exc))


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def run(args):
    verdict, reason, acc, _raw = evaluate(args.state_file, args.policy_file, args.counter_file)

    if verdict == SHUTDOWN and args.dry_run_force:
        verdict = WOULD_SHUTDOWN
        reason = "dry-run-force: " + reason

    log_line(args.log_file, "verdict=%s accessory=%s reason=%s" % (verdict, acc or "-", _one_line(reason)))

    lv_path = _last_verdict_path(args.marker_file)
    previous = read_last_verdict(lv_path)
    if previous != verdict:
        write_last_verdict(lv_path, verdict)

    if verdict == WOULD_SHUTDOWN:
        if previous != WOULD_SHUTDOWN:
            notify(args.log_file, args.notify_user, "UPS power-guard (DRY RUN)",
                   "Would shut down %s now: %s" % (_host(), reason), args.kb_msg_to)
        return 0

    if verdict != SHUTDOWN:
        return 0

    # ---- verdict is exactly SHUTDOWN from here on ----
    try:
        euid = geteuid()
    except Exception as exc:
        euid = None
        log_line(args.log_file, "ERROR: geteuid failed: %s" % exc)
    # type() check: False == 0 and 0.0 == 0 in Python; only the int 0 is root.
    if type(euid) is not int or euid != 0:
        log_line(args.log_file, "ERROR: SHUTDOWN verdict but not running as root (euid=%r); "
                 "NOT shutting down. The power-guard LaunchDaemon must run as root." % (euid,))
        return 0

    latch = take_marker(args.marker_file)
    if latch == "exists":
        log_line(args.log_file, "shutdown already initiated this boot (marker %s present); no action"
                 % args.marker_file)
        return 0
    if latch != "taken":
        log_line(args.log_file, "WARNING: could not create marker %s (%s); proceeding with shutdown anyway"
                 % (args.marker_file, latch))

    log_line(args.log_file, "INITIATING SHUTDOWN: notifying %s, then %s" % (
        args.notify_user, " ".join(SHUTDOWN_ARGV)))
    notify(args.log_file, args.notify_user, "UPS power-guard: SHUTTING DOWN",
           "%s is shutting down now: %s" % (_host(), reason), args.kb_msg_to)

    try:
        rc = execute_shutdown(tuple(SHUTDOWN_ARGV))
    except Exception as exc:
        rc = "%s: %s" % (type(exc).__name__, exc)
    if rc == 0:
        log_line(args.log_file, "shutdown command accepted (rc=0)")
        return 0
    log_line(args.log_file, "ERROR: shutdown command failed (rc=%r); marker removed so the next run retries" % (rc,))
    if latch == "taken":
        try:
            os.unlink(args.marker_file)
        except OSError:
            pass
    return 0


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="power-guard runner: acts on power-guard.py's verdict "
                                            "(run by the root LaunchDaemon, once per invocation)")
    p.add_argument("--state-file", required=True)
    p.add_argument("--policy-file", required=True)
    p.add_argument("--counter-file", required=True)
    p.add_argument("--log-file", default=DEFAULT_LOG_FILE)
    p.add_argument("--notify-user", required=True,
                   help="console user to notify (also the kb-msg sender account)")
    p.add_argument("--marker-file", default=DEFAULT_MARKER_FILE,
                   help="once-per-boot shutdown latch (default under /var/run, cleared at boot)")
    p.add_argument("--dry-run-force", action="store_true",
                   help="downgrade SHUTDOWN to WOULD_SHUTDOWN (supervised drill)")
    p.add_argument("--kb-msg-to", default=DEFAULT_KB_MSG_TO,
                   help="kb-msg address for notifications (default: academy team broadcast)")
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        return run(args)
    except Exception as exc:  # anything unexpected before acting => no action
        log_line(args.log_file, "ERROR: runner failed, no action: %s: %s" % (type(exc).__name__, exc))
        return 0


if __name__ == "__main__":
    sys.exit(main())
