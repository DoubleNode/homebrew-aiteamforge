#!/usr/bin/env python3
"""PreToolUse guard: block native file-tool access under the iCloud File Provider mount.

Claude Code (Bun) opening a file under ~/Library/Mobile Documents/com~apple~CloudDocs/
wedges its event loop in an uninterruptible openat$NOCANCEL — on BOTH reads and writes.
This guard denies the fatal open BEFORE it happens and points the agent at the local
transfer dir. Bash is intentionally NOT guarded (subprocess opens don't hang — that is
how the stage-transfer / publish-transfer helpers move files across the iCloud boundary).

Fails OPEN (exit 0) on any error so it can never break normal tool use.
"""
import sys, os, json

def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0

    tool = data.get("tool_name", "")
    ti = data.get("tool_input", {}) or {}

    paths = []
    for key in ("file_path", "notebook_path", "path"):
        v = ti.get(key)
        if isinstance(v, str) and v:
            paths.append(v)
    if not paths:
        return 0

    home = os.path.expanduser("~")
    icloud = os.path.join(home, "Library", "Mobile Documents", "com~apple~CloudDocs") + os.sep

    def resolve(p):
        if p.startswith("~"):
            p = home + p[1:]
        return os.path.normpath(p) + (os.sep if p.endswith(os.sep) else "")

    hit = next((p for p in paths if resolve(p).startswith(os.path.normpath(icloud) + os.sep)
                or resolve(p) == os.path.normpath(icloud)), None)
    if hit:
        sys.stderr.write(
            "BLOCKED (iCloud hang guard): '%s' is on iCloud Drive. The %s tool hangs "
            "Claude uninterruptibly when opening files under the iCloud File Provider "
            "mount. Do NOT read or write iCloud paths directly.\n"
            "Use the LOCAL transfer dir instead: ~/aiteamforge-transfers/<team>/ .\n"
            "First load the helpers in your Bash command: `source ~/.aiteamforge/stage-transfer.sh && <cmd>`\n"
            "  - incoming file: `source ~/.aiteamforge/stage-transfer.sh && sync-transfers-in` (or `stage-transfer <name>`), then read the local copy\n"
            "  - outgoing file: write it into the dir from `source ~/.aiteamforge/stage-transfer.sh && transfers-dir`, then `... && publish-transfer <file>`\n"
            % (hit, tool)
        )
        return 2
    return 0

sys.exit(main())
