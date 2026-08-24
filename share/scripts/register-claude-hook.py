#!/usr/bin/env python3
"""
register-claude-hook.py — idempotent hook-event registration for ~/.claude/settings.json

XACA-0885. XACA-0777 shipped msg-inbox-check.sh and setup-hooks.sh symlinked it,
but nothing ever wrote it into settings.json, so no machine has ever surfaced
kb-msg mail automatically. This is the missing writer.

Registration is keyed on the EXACT command string. Re-running is a no-op, which is
what makes it safe to call unconditionally from setup-hooks.sh on every run.

Usage:
    register-claude-hook.py --event <Event> --command <cmd> [--event <Event> ...]
                            [--settings <path>] [--matcher <str>]
                            [--check] [--quiet]

Exit codes:
    0  registration present (already, or newly written) / --check found everything
    1  --check found a missing registration, or a write was required but failed
    2  usage or unreadable-settings error
"""

import argparse
import json
import os
import shutil
import sys
import tempfile


def _die_unreadable(msg):
    """Exit 2 — 'I could not read your settings', distinct from exit 1's
    'registration is missing'. kb-msg doctor needs to tell those apart: one is a
    fixable gap, the other means every hook on the machine is at risk."""
    print(msg, file=sys.stderr)
    raise SystemExit(2)


def _load(path):
    """Return (data, existed). Refuses to guess on malformed JSON."""
    if not os.path.exists(path):
        return {}, False
    try:
        with open(path, "r") as fh:
            text = fh.read()
    except OSError as exc:
        _die_unreadable("register-claude-hook: cannot read %s: %s" % (path, exc))
    if not text.strip():
        return {}, True
    try:
        data = json.loads(text)
    except ValueError as exc:
        # Fail closed and LOUD. Silently rewriting a settings file we could not
        # parse would destroy every hook already registered on this machine.
        _die_unreadable(
            "register-claude-hook: %s is not valid JSON (%s).\n"
            "  Refusing to rewrite it — fix the file by hand, then re-run." % (path, exc)
        )
    if not isinstance(data, dict):
        _die_unreadable(
            "register-claude-hook: %s is not a JSON object; refusing to rewrite." % path
        )
    return data, True


def _commands_for_event(data, event):
    """Every command string already registered under `event`."""
    out = []
    for block in (data.get("hooks") or {}).get(event, []) or []:
        if not isinstance(block, dict):
            continue
        for hook in block.get("hooks", []) or []:
            if isinstance(hook, dict) and "command" in hook:
                out.append(hook["command"])
    return out


def _register(data, event, command, matcher=None):
    """Append a matcher block for `command`. Returns True if data was modified."""
    if command in _commands_for_event(data, event):
        return False
    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        _die_unreadable(
            "register-claude-hook: settings['hooks'] is not an object; refusing to rewrite."
        )
    block = {"hooks": [{"type": "command", "command": command}]}
    if matcher is not None:
        block["matcher"] = matcher
    hooks.setdefault(event, []).append(block)
    return True


# Deliberately NOT plain ".bak": ~/.claude/settings.json.bak is a pre-existing
# convention used by other tooling (a four-month-old one was found on M3Pro while
# building this). Reusing that name would silently destroy a backup we did not
# create and cannot regenerate.
BACKUP_SUFFIX = ".pre-register-claude-hook.bak"


def _atomic_write(path, data):
    """Write via temp+rename so an interrupted run cannot truncate settings.json."""
    parent = os.path.dirname(path) or "."
    os.makedirs(parent, exist_ok=True)
    if os.path.exists(path):
        shutil.copy2(path, path + BACKUP_SUFFIX)
    fd, tmp = tempfile.mkstemp(dir=parent, prefix=".settings-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(json.dumps(data, indent=2))
            fh.write("\n")
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--event", action="append", required=True,
                    help="Hook event (repeatable), e.g. SessionStart")
    ap.add_argument("--command", required=True, help="Exact command string to register")
    ap.add_argument("--settings", default=os.path.expanduser("~/.claude/settings.json"))
    ap.add_argument("--matcher", default=None, help="Optional matcher for the block")
    ap.add_argument("--check", action="store_true",
                    help="Report registration state; never write. Exit 1 if any event is missing.")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    def say(msg):
        if not args.quiet:
            print(msg)

    data, existed = _load(args.settings)

    if args.check:
        missing = [ev for ev in args.event if args.command not in _commands_for_event(data, ev)]
        if not existed:
            say("  [MISSING] %s does not exist" % args.settings)
            return 1
        for ev in args.event:
            state = "MISSING" if ev in missing else "ok"
            say("  [%s] %s: %s" % (state, ev, args.command))
        return 1 if missing else 0

    changed = [ev for ev in args.event if _register(data, ev, args.command, args.matcher)]

    if not changed:
        say("  Hook already registered for %s — no change" % ", ".join(args.event))
        return 0

    try:
        _atomic_write(args.settings, data)
    except Exception as exc:
        print("register-claude-hook: write failed: %s" % exc, file=sys.stderr)
        return 1

    say("  Registered hook for %s in %s" % (", ".join(changed), args.settings))
    return 0


if __name__ == "__main__":
    sys.exit(main())
