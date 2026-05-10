# Edit-Shared Workflow

**Safe editing of canonical files with automatic tap synchronization**

---

## The Problem

When editing files in `~/dev-team/` that have mirror copies in the `homebrew-tap/` submodule, it's easy to forget to run `./sync-tap.sh` afterward. This causes drift — your edits appear in dev-team but not in the tap. The pre-push hook will block you with a drift error, and you'll have to re-run sync-tap and restage files.

The `kb-edit-shared` helper automates this workflow: open a file in your `$EDITOR`, run sync-tap automatically, and stage both the canonical and tap copies in one command.

---

## The Mirror Surface

Files synced from dev-team → tap (`homebrew-tap/`):

| Canonical (dev-team) | Tap mirror |
| --- | --- |
| `lcars-ui/` | `homebrew-tap/share/lcars-ui/` |
| `kanban-hooks/` | `homebrew-tap/share/kanban-hooks/` |
| `scripts/<mapped files>` | `homebrew-tap/share/scripts/` |
| `iterm2_window_manager.py`, `kanban-backup.py` | `homebrew-tap/share/scripts/` |
| `fleet-monitor/server/` | `homebrew-tap/fleet-monitor/server/` |
| `docs/homebrew-tap/` | `homebrew-tap/docs/` |

`kb-edit-shared` accepts either side of the mapping — pass a tap-mirror path and it reverse-maps to the canonical source. Files outside the mirror surface (e.g. `CHANGELOG.md`, `kanban-helpers.sh`) are rejected with a clear error.

For the authoritative mapping, see `sync-tap.sh` and the function's `case` statement in `kanban-helpers.sh`.

---

## Usage

### Shell: kb-edit-shared

```bash
# Edit a canonical file (path relative to ~/dev-team/)
kb-edit-shared scripts/agent-panel-display.sh

# Or with absolute path
kb-edit-shared ~/dev-team/kanban-helpers.sh
```

The helper:
1. Opens the file in your `$EDITOR`
2. After you save and close the editor, runs `./sync-tap.sh`
3. Stages both the canonical copy and the tap mirror (via `git add`)
4. Displays the changes made

If sync-tap reports **no changes**, the file either has no mirror or matches the tap copy already.

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
Error: path is not in the mirrored surface: …/CHANGELOG.md
  Only files synced by sync-tap.sh can be edited with kb-edit-shared.
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

`kb-edit-shared` runs `./sync-tap.sh` in-place, which requires the `homebrew-tap/` submodule to be initialized. In feature worktrees the submodule is intentionally uninitialized (XACA-0455) — `kb-edit-shared` will abort with a clear error from sync-tap. Run the helper from the **main repo** (`~/dev-team`) on a feature branch instead, or use the worktree-aware sync flags directly: `./sync-tap.sh --source-dir <worktree> --reference-dir ~/dev-team --check`.

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
