#!/usr/bin/env python3
"""
register-claude-hook.py — idempotent hook-event registration for ~/.claude/settings.json

XACA-0885. XACA-0777 shipped msg-inbox-check.sh and setup-hooks.sh symlinked it,
but nothing ever wrote it into settings.json, so no machine has ever surfaced
kb-msg mail automatically. This is the missing writer.

Registration is keyed on the EXACT command string. Re-running is a no-op, which is
what makes it safe to call unconditionally from setup-hooks.sh on every run.

XACA-0787-017: if --settings is omitted, the default (~/.claude/settings.json,
resolved against THIS process's own HOME) is refused whenever --command
references an absolute path outside that same HOME — pass --settings
explicitly for a command that legitimately lives elsewhere. This exists
because a caller can build --command against a different, faked HOME without
that HOME ever reaching this process; confirmed 2026-09-06, a sandboxed
caller's temp-dir command was written straight into the operator's real
settings.json this way.

Usage:
    register-claude-hook.py --event <Event> --command <cmd> [--event <Event> ...]
                            [--settings <path>] [--matcher <str>]
                            [--check] [--quiet]

Exit codes:
    0  registration present (already, or newly written) / --check found everything
    1  --check found a missing registration, or a write was required but failed
    2  usage error, unreadable-settings error, or --command points outside HOME
       with --settings omitted (XACA-0787-017)
"""

import argparse
import json
import os
import shlex
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
    """Every command string already registered under `event`.

    The type guards below are load-bearing and were added after review: the
    original read was `(data.get("hooks") or {}).get(event, []) or []`, and
    `X or {}` only rescues a FALSY wrong type. `{"hooks": []}` degraded into the
    correct exit-2 refusal by accident, while `{"hooks": ["x"]}` — the same wrong
    type, merely non-empty — reached `.get` on a list and died with a raw
    AttributeError traceback (exit 1) instead of the documented clean refusal.
    The test that was supposed to cover this asserted only the empty shape, so it
    passed for a narrower reason than its name claimed.

    No data was ever at risk (the crash precedes any write), but this runs on
    every session start, and an unhandled traceback there is indistinguishable
    from the tool being broken.
    """
    hooks = data.get("hooks")
    if hooks is None:
        return []
    if not isinstance(hooks, dict):
        _die_unreadable(
            "register-claude-hook: settings['hooks'] is not an object "
            "(found %s); refusing to rewrite." % type(hooks).__name__
        )
    entries = hooks.get(event)
    if entries is None:
        return []
    if not isinstance(entries, list):
        _die_unreadable(
            "register-claude-hook: settings['hooks']['%s'] is not a list "
            "(found %s); refusing to rewrite." % (event, type(entries).__name__)
        )
    out = []
    for block in entries:
        if not isinstance(block, dict):
            continue
        inner = block.get("hooks")
        if not isinstance(inner, list):
            continue
        for hook in inner:
            if isinstance(hook, dict) and "command" in hook:
                out.append(hook["command"])
    return out


def _register(data, event, command, matcher=None):
    """Append a matcher block for `command`. Returns True if data was modified.

    DEDUP IS BY EXACT COMMAND STRING ONLY — `matcher` is deliberately not part of
    the identity, and a caller re-registering the same command under a DIFFERENT
    matcher gets a no-op rather than an updated block (review finding, PR #758).

    That is correct for the only call site today: setup-hooks.sh registers one
    fixed inbox-hook command with no matcher, and command-only dedup is exactly
    what makes re-running it idempotent. It would be wrong for a future caller
    that varies the matcher, which would silently keep the first one.

    If you add such a caller, change the identity here — do not add a second
    registration path. Two writers against settings.json is how the original
    defect (a hook symlinked but never registered) became possible to miss.
    """
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


def _referenced_paths(command):
    """Absolute-looking path tokens found in a --command string.

    --command is an opaque shell command (e.g. "bash /home/x/.claude/hooks/y.sh")
    — there is no formal "path argument" to inspect, so this is a heuristic
    shell-tokenized scan for words that look like absolute paths (leading '/'
    or '~'). A command this fails to parse (unbalanced quotes) or that has no
    such token yields []: the guard below only ever REFUSES on a path it
    positively identified, so parser blind spots fail open here, not closed.
    """
    try:
        tokens = shlex.split(command)
    except ValueError:
        return []
    return [t for t in tokens if t.startswith("/") or t.startswith("~")]


def _outside_home(path, home_real):
    candidate = os.path.realpath(os.path.expanduser(path))
    return candidate != home_real and not candidate.startswith(home_real + os.sep)


def _refuse_unsafe_default_settings(command, settings_explicit):
    """XACA-0787-017 callee guard.

    Confirmed 2026-09-06: a caller built --command against a FAKE/sandboxed
    HOME (a TMPDIR / /var/folders path) and omitted --settings. Nothing binds
    --settings to the HOME the caller used to build --command — this process's
    own os.environ stayed the OPERATOR'S real HOME the whole time, so the
    default `os.path.expanduser("~/.claude/settings.json")` resolved to the
    real settings.json, and the sandbox path got written straight into it.
    Every SessionStart/Stop after that failed: the sandbox is ephemeral.

    Deliberately NOT the "path does not exist AND lies outside HOME" AND-guard
    floated when this ticket was filed: at the moment of the actual incident
    the sandboxed script EXISTED (the caller had just created it) — an
    existence check would have let it straight through, and would keep doing
    so for as long as the sandbox happens to survive. The one invariant that
    was actually violated is HOME, independent of whether the target exists
    yet, so that is what this checks.

    Why this lives at the callee: it is what protects against a caller that
    does not exist yet, matching this ticket's "call site AND callee" framing
    (787-003 is the call-site gate; this is the backstop for every OTHER
    caller, present or future).

    Deliberately scoped to settings_explicit == False. There is no reliable
    way to recover "the HOME the caller used to build --command" from an
    opaque string — command construction happens in the CALLER's shell, often
    before --settings is even chosen, so nothing here can verify the two were
    built from the same HOME. Requiring an explicit --settings whenever
    --command points outside the CALLEE's own HOME is the reliable substitute:
    it forces the caller to state, in the same invocation, which settings.json
    they mean, rather than letting a mismatch resolve itself silently via two
    independently-defaulted paths. A caller with a legitimate reason to
    register a command living outside HOME (e.g. provisioning a different
    machine's settings.json from a script that runs elsewhere) is NOT blocked
    — it only has to say so with --settings, which is a one-flag cost against
    a class of mistake that has already corrupted a real operator file once.

    No currently known caller is affected: setup-hooks.sh's own command is
    always "bash $HOME/.claude/hooks/msg-inbox-check.sh" (inside HOME) with no
    --settings override, and every test in register-claude-hook.bats already
    passes --settings explicitly.
    """
    if settings_explicit:
        return
    home_real = os.path.realpath(os.path.expanduser("~"))
    for token in _referenced_paths(command):
        if _outside_home(token, home_real):
            print(
                "register-claude-hook: --command references a path outside "
                "$HOME (%s) but --settings was not given. Refusing to guess "
                "which settings.json you mean — pass --settings explicitly."
                % token,
                file=sys.stderr,
            )
            raise SystemExit(2)


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--event", action="append", required=True,
                    help="Hook event (repeatable), e.g. SessionStart")
    ap.add_argument("--command", required=True, help="Exact command string to register")
    # Sentinel default (None), NOT a pre-expanded path: XACA-0787-017 needs to
    # tell "caller relied on the default" apart from "caller explicitly chose
    # the same path the default would have picked" — those are different
    # trust levels, and a pre-expanded default collapses that distinction.
    ap.add_argument("--settings", default=None,
                    help="Defaults to ~/.claude/settings.json (this process's own HOME).")
    ap.add_argument("--matcher", default=None, help="Optional matcher for the block")
    ap.add_argument("--check", action="store_true",
                    help="Report registration state; never write. Exit 1 if any event is missing.")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    settings_explicit = args.settings is not None
    settings_path = args.settings if settings_explicit else os.path.expanduser("~/.claude/settings.json")

    _refuse_unsafe_default_settings(args.command, settings_explicit)

    def say(msg):
        if not args.quiet:
            print(msg)

    data, existed = _load(settings_path)

    if args.check:
        missing = [ev for ev in args.event if args.command not in _commands_for_event(data, ev)]
        if not existed:
            say("  [MISSING] %s does not exist" % settings_path)
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
        _atomic_write(settings_path, data)
    except Exception as exc:
        print("register-claude-hook: write failed: %s" % exc, file=sys.stderr)
        return 1

    say("  Registered hook for %s in %s" % (", ".join(changed), settings_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
