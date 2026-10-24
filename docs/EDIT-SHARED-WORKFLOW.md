# Edit-Shared Workflow

**Safe editing of canonical files with automatic tap synchronization**

---

## The Problem

When editing files in `~/dev-team/` that have mirror copies in the `homebrew-tap/` submodule, it's easy to forget to run `./sync-tap.sh` afterward. This causes drift — your edits appear in dev-team but not in the tap. The pre-push hook will block you with a drift error, and you'll have to re-run sync-tap and restage files.

The `kb-edit-shared` helper automates this workflow: open a file in your `$EDITOR` and stage the canonical file in one command. When the tap publisher is not armed it also runs sync-tap and stages the tap copy.

---

## The Mirror Surface

The mirror surface is **whatever `./sync-tap.sh --manifest` reports**. `kb-edit-shared` runs that command (6-19 seconds) on every invocation and resolves your path against it, so there is no second list to drift. The manifest currently covers, among others:

| Canonical (dev-team) | Tap mirror |
| --- | --- |
| `lcars-ui/` | `homebrew-tap/share/lcars-ui/` |
| `kanban-hooks/` | `homebrew-tap/share/kanban-hooks/` |
| `scripts/<mapped files>`, `lcars-health-check.sh`, `fleet-monitor/client/<files>` | `homebrew-tap/share/scripts/...` |
| `iterm2_window_manager.py`, `kanban-backup.py` | `homebrew-tap/share/scripts/` |
| `fleet-monitor/server/` | `homebrew-tap/fleet-monitor/server/` |
| `docs/homebrew-tap/` | `homebrew-tap/docs/` |
| `skills/<allowlisted>/` | `homebrew-tap/share/skills/` |
| `.claude/agents-master/<team>/` | `homebrew-tap/share/personas/<team>/agents/` |

`kb-edit-shared` accepts either side of the mapping: pass a tap-mirror path and it reverse-maps to the canonical source. Files outside the mirror surface (e.g. `CHANGELOG.md`, `kanban-helpers.sh`) are rejected with a clear error.

It fails closed (exit 2, editor never opened, nothing staged) if the `homebrew-tap/share` checkout is missing or the manifest cannot be read, because it then cannot tell which files are mirrored.

Documented refusals: a gitignored canonical path (`lcars-ui/lcars-target.js`, runtime data), a symlink (the target is named), a tap-only file with no canonical source (use `kb-tap-release --push-tap-edit`), a `<team>/scripts/<file>` the tap does not already ship, and a skill or team that is not yet in `sync-tap.sh`'s allowlist (add it there first). A tracked file under a mirrored directory that `sync-tap.sh`'s file filters drop (for example a `Dockerfile`) is accepted: you are editing the right canonical file, but it will not ship.

Provenance flags (unarmed publisher only): `--skip-unsafe-provenance` and `--allow-provenance-revert "<reason>"` are forwarded to `sync-tap.sh`. When the publisher is armed `sync-tap.sh` is never run, so the flags are refused with exit 2. If `--skip-unsafe-provenance` leaves your file untouched, `kb-edit-shared` reports that and stages nothing.

For the authoritative mapping, run `./sync-tap.sh --manifest` or read `sync-tap.sh`.

---

## Usage

### Shell: kb-edit-shared

```bash
# Edit a canonical file (path relative to ~/dev-team/)
kb-edit-shared scripts/agent-panel-display.sh

# Or with absolute path
kb-edit-shared ~/dev-team/lcars-ui/server.py

# Or with the tap-mirror path (resolved back to the canonical source)
kb-edit-shared homebrew-tap/share/lcars-ui/server.py
```

The helper:
1. Checks whether the tap publisher is armed (`TAP_PUBLISHER_ENABLED` is `true`; an unreadable state counts as armed)
2. Reads `./sync-tap.sh --manifest` and resolves your path to its canonical source, refusing (before any edit) if the path is not mirrored or the manifest cannot be read
3. Opens the canonical file in your `$EDITOR`
4. **Armed (normal):** stages only the canonical file. It does not run `./sync-tap.sh` and does not stage `homebrew-tap`; the publisher mirrors the file after merge
5. **Unarmed:** runs `./sync-tap.sh --allow-local-write` and stages the canonical copy and the tap mirror
6. Displays the changes made

Unarmed only: if sync-tap reports **no changes**, the file already matches the tap copy.

### Makefile: make edit-shared

For teams preferring make targets over shell functions:

```bash
# Edit a file using make
make edit-shared FILE=scripts/agent-panel-display.sh

# Equivalent to:
kb-edit-shared scripts/agent-panel-display.sh
```

---

## Examples

### Example 1: Edit a script, save, auto-sync

```bash
$ kb-edit-shared scripts/agent-panel-display.sh
# Opens scripts/agent-panel-display.sh in $EDITOR
# You make changes, save, and exit
# sync-tap runs and reports:
#   → scripts/agent-panel-display.sh: 245 bytes copied to homebrew-tap/

$ git status
# Shows both files staged:
#   modified:   scripts/agent-panel-display.sh
#   modified:   homebrew-tap/share/scripts/agent-panel-display.sh
```

### Example 2: Edit a tap-mirror path (reverse-mapped to canonical)

```bash
# Same-name reverse-map (canonical and mirror share the filename):
$ kb-edit-shared homebrew-tap/share/scripts/agent-panel-display.sh
# Reverse-maps to ~/dev-team/scripts/agent-panel-display.sh and opens THAT file.

# Different-name reverse-map (two dev-team root scripts mirror into share/scripts/):
$ kb-edit-shared homebrew-tap/share/scripts/iterm2_window_manager.py
# Reverse-maps to ~/dev-team/iterm2_window_manager.py (root, not scripts/).

# The canonical dev-team source is always what you edit, not the mirror copy.
# sync-tap then propagates back to the tap.
```

### Example 3: Reject an unmirrored path

```bash
$ kb-edit-shared CHANGELOG.md
Error: path is not in the mirrored surface per sync-tap.sh --manifest (250 records): …/CHANGELOG.md
  Only files that sync-tap.sh mirrors can be edited with kb-edit-shared.
```

Unmirrored files (CHANGELOG.md, kanban-helpers.sh, etc.) must be edited the normal way — `kb-edit-shared` is only for files where forgetting sync-tap would cause drift.

### Example 4: Forgetting kb-edit-shared

If you edit a mirrored file directly without the helper:

```bash
$ vi scripts/agent-panel-display.sh
$ git add scripts/agent-panel-display.sh
$ git commit -m "Fix hook logic"
$ git push origin feature/fix-hook

# Pre-push hook detects drift:
#   ERROR: homebrew-tap out of sync (drift detected)
#   Run ./sync-tap.sh --check to verify
```

Now you must:
```bash
./sync-tap.sh
git add homebrew-tap/
git commit --amend -m "Fix hook logic"
git push --force-with-lease origin feature/fix-hook
```

Using `kb-edit-shared` avoids this friction.

---

## Worktree note

`kb-edit-shared` operates on the main checkout (`$DEV_TEAM`, default `~/dev-team`), even when invoked from a worktree. Both paths need `homebrew-tap/share` to exist in that checkout, because the mirrored surface is read from `./sync-tap.sh --manifest`; without it `kb-edit-shared` exits 2. When the publisher is armed it never runs `./sync-tap.sh` write mode. When it is unarmed it runs `./sync-tap.sh --allow-local-write`. For a read-only comparison, run `./sync-tap.sh --check` from the worktree (XACA-1374: it defaults to the invoking checkout when that worktree's tap is initialized, and refuses otherwise; `--source-dir <worktree> --reference-dir ~/dev-team` still overrides). The armed publisher is the routine writer.

---

## Related Resources

- **sync-tap.sh** — Full documentation and flags (run `./sync-tap.sh --help`)
- **ARCHITECTURE.md** — Detailed mirror mapping and design
- **LOCKSTEP-CHECK.md** (XACA-0344) — CI guard that catches tap-only edits without a canonical source; complementary to this workflow doc
- **CONTRIBUTING.md** (XACA-0346) — Will include a link to this workflow when published

---

## See Also

- For non-interactive sync, use `./sync-tap.sh` directly
- For repository structure, see `docs/homebrew-tap/ARCHITECTURE.md`
- For Makefile targets, see the project `Makefile` (XACA-0347 Subitem 003)
