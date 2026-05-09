# Homebrew Tap Lockstep Check

**Preventing mirror/canonical source divergence in the tap repository**

---

## Table of Contents

- [Overview](#overview)
- [The Problem: Lockstep Drift](#the-problem-lockstep-drift)
- [How the Check Works](#how-the-check-works)
- [Escape Hatches](#escape-hatches)
  - [Commit Trailer (Preferred)](#commit-trailer-preferred)
  - [PR Label (Fallback)](#pr-label-fallback)
  - [When to Use Each](#when-to-use-each)
- [What Has a Canonical Source](#what-has-a-canonical-source)
- [Examples](#examples)

---

## Overview

The `scripts/check-tap-only-edits.sh` script runs automatically on pull requests to prevent a common source-of-truth problem in the AITeamForge Homebrew tap. It detects when a file in `homebrew-tap/` is edited without also editing its canonical source, and blocks the PR unless you explicitly acknowledge the exception.

This document explains:
1. Why the check exists (the XACA-0340 regression class)
2. When and how to use the escape hatches
3. Which files are mirrored (and thus require canonical edits)

---

## The Problem: Lockstep Drift

### Background

The `homebrew-tap/` directory contains **mirror copies** of files whose authoritative source lives elsewhere in this repository:

```
Canonical Source              →  Mirror Copy (homebrew-tap/)
─────────────────────────────    ─────────────────────────────
scripts/agent-panel-display.sh   homebrew-tap/share/scripts/agent-panel-display.sh
lcars-ui/lcars.html              homebrew-tap/share/lcars-ui/lcars.html
kanban-hooks/                     homebrew-tap/share/kanban-hooks/
```

The mirror copies are created and updated by the `sync-tap.sh` script, which synchronizes changes from canonical sources into the tap directory for distribution via Homebrew.

### The Regression

If you edit **only** the tap copy without editing the canonical source (XACA-0340 scenario):

1. Your PR edits `homebrew-tap/share/scripts/agent-panel-display.sh`
2. The PR merges to `develop`
3. Next time `sync-tap.sh` runs (before the next release), it **overwrites your tap edit** with the unchanged canonical source
4. Your fix disappears silently
5. Users receive the old, broken version

This creates a regression that is difficult to detect and trace.

---

## How the Check Works

When you push a PR, GitHub Actions automatically runs `scripts/check-tap-only-edits.sh`. The script:

1. Identifies all files you've added or modified in the PR
2. For each `homebrew-tap/` file, looks up its canonical counterpart
3. Verifies that the canonical source was **also** edited in the same PR
4. Blocks the PR if a tap file was edited without its canonical source
5. Allows bypass if you've provided an escape hatch (see below)

The check is **lockstep enforcement**: tap edits and canonical-source edits must move together.

---

## Escape Hatches

The check provides two ways to acknowledge and bypass the restriction when **legitimate** cases arise (e.g., a file with no canonical source, or an intentional tap-only fix).

### Commit Trailer (Preferred)

Add the trailer `Tap-Only-Edit: intentional` to any commit message in your PR.

**Example:**

```
feat: Update LCARS stylesheet for better dark-mode contrast

- Improved readability in low-light environments
- Adjusted color values for accessibility standards

Tap-Only-Edit: intentional

Co-Authored-By: Claude <noreply@anthropic.com>
```

**Why this is preferred:**
- The intent travels with git history
- Future developers can see why the tap-only edit was justified
- Works regardless of PR lifecycle (already pushed, in review, etc.)
- Self-documents the decision

**When it's valid:**
- File genuinely has no canonical source (e.g., tap-specific build script)
- Tap-side fix for an issue that doesn't require canonical-source changes
- Documented in PR description explaining the exception

### PR Label (Fallback)

Apply the GitHub label `tap-only-intentional` to the PR. The check will detect it and bypass.

**Steps:**
1. Go to your PR on GitHub
2. On the right sidebar, click **Labels**
3. Select or search for `tap-only-intentional`
4. The check will re-run and pass

**Why this is fallback:**
- Better for already-pushed PRs where adding a commit trailer requires `git commit --amend`
- Useful for hotfixes where the branching/commit strategy is already fixed
- Does not appear in git history (purely GitHub-scoped)

**When to use:**
- You've already pushed the PR and don't want to amend
- Emergency/hotfix situations where the canonical source genuinely cannot be changed in the same PR
- Documented in the PR description

### When to Use Each

| Scenario | Use Trailer | Use Label | Notes |
|----------|-------------|-----------|-------|
| Normal feature with canonical edits | N/A | N/A | Check passes automatically; no escape hatch needed |
| Tap-only file with no canonical source | ✓ | Only if already pushed | Trailer is preferred; label is acceptable if already in review |
| Hotfix to tap-specific code | ✓ (if re-pushing is cheap) | ✓ (if avoiding amend) | Either works; trailer is better for history |
| Intentional divergence (documented exception) | ✓ | Only if already pushed | Trailer + clear PR description required |

**General rule:** Use the **commit trailer** if you haven't pushed yet or are comfortable amending. Use the **PR label** if the PR is already in review and you want to avoid churn.

---

## What Has a Canonical Source

The check knows about the following mirror/canonical pairs. If your edited file is **not** in this list, the check will not apply to it.

### Individual Files

| Mirror Path | Canonical Source |
|-------------|------------------|
| `homebrew-tap/share/scripts/iterm2_window_manager.py` | `iterm2_window_manager.py` |
| `homebrew-tap/share/scripts/kanban-backup.py` | `kanban-backup.py` |
| `homebrew-tap/share/scripts/agent-panel-display.sh` | `scripts/agent-panel-display.sh` |
| `homebrew-tap/share/scripts/display-agent-avatar.sh` | `scripts/display-agent-avatar.sh` |
| `homebrew-tap/share/scripts/set-lcars-profile-browser.py` | `scripts/set-lcars-profile-browser.py` |
| `homebrew-tap/share/scripts/lcars-tmp-dir.sh` | `scripts/lcars-tmp-dir.sh` |
| `homebrew-tap/share/scripts/aiteamforge-paths-init.sh` | `scripts/aiteamforge-paths-init.sh` |
| `homebrew-tap/share/scripts/aiteamforge-team-paths-wizard.py` | `scripts/aiteamforge-team-paths-wizard.py` |
| `homebrew-tap/share/scripts/aiteamforge-paths` | `scripts/aiteamforge-paths` |
| `homebrew-tap/share/templates/claude/tmux.conf` | `claude/tmux.conf` |

### Directory Mirrors

Entire directories mirrored from canonical sources. All files under these paths require canonical edits:

| Mirror Prefix | Canonical Prefix | Notes |
|---------------|------------------|-------|
| `homebrew-tap/share/lcars-ui/` | `lcars-ui/` | All `.py`, `.html`, `.js`, `.css` files |
| `homebrew-tap/share/kanban-hooks/integrations/` | `kanban-hooks/integrations/` | Integration adapters |
| `homebrew-tap/docs/` | `docs/homebrew-tap/` | Tap documentation |
| `homebrew-tap/fleet-monitor/server/` | `fleet-monitor/server/` | Fleet monitoring server code |
| `homebrew-tap/share/kanban-hooks/` | `kanban-hooks/` | Kanban hook system (note: `fleet-monitor/server/` has some tap-only files; see below) |

### Tap-Only Files (No Canonical Source)

These files under `homebrew-tap/fleet-monitor/server/` have **no** canonical counterpart and are tap-only. Edits to these do not require escape hatches:

- `homebrew-tap/fleet-monitor/server/config.yaml` (tap-only configuration)
- `homebrew-tap/fleet-monitor/server/README.md` (tap-specific docs)
- Fleet-monitor deployment-specific files (installer configs, systemd units)

All other files under `homebrew-tap/fleet-monitor/server/` still require canonical edits.

---

## Examples

### Example 1: Fixing a bug in `agent-panel-display.sh` (Normal Case)

You discover a bug in the agent panel display script. The canonical source is `scripts/agent-panel-display.sh`; the tap copy is `homebrew-tap/share/scripts/agent-panel-display.sh`.

**Correct workflow:**
1. Edit `scripts/agent-panel-display.sh` (canonical source)
2. Commit it
3. Push the PR
4. The `sync-tap.sh` script (during release) will automatically propagate your fix to the tap copy
5. Check passes automatically — no escape hatch needed

**What NOT to do:**
- Do not edit only `homebrew-tap/share/scripts/agent-panel-display.sh`
- The check will block your PR
- You must either add the escape hatch OR edit the canonical source too

### Example 2: LCARS UI Fix with Escape Hatch

You discover that the LCARS UI dark mode looks broken in the distributed version. You want to push a quick fix to the tap copy without waiting for the next canonical release.

**Workflow:**
1. Edit `homebrew-tap/share/lcars-ui/lcars.css` (tap copy)
2. In your commit message, add the trailer:
   ```
   Tap-Only-Edit: intentional
   ```
3. In the PR description, explain why this is tap-only:
   ```
   ## Changes
   - Fixed dark-mode color contrast in LCARS UI

   ## Why Tap-Only
   This is a critical visual fix for the distributed version. The canonical
   source (lcars-ui/) will be updated in the next development cycle, but
   users need this fix immediately via Homebrew.
   ```
4. Push the PR
5. Check sees the trailer and passes

**Note:** This is an exceptional case. Normally, both canonical and tap copies should be edited together.

### Example 3: Fleet Monitor Tap-Specific Config (No Canonical)

The fleet monitoring server has deployment-specific configuration in `homebrew-tap/fleet-monitor/server/config.yaml`. This file has no canonical source (it's tap-only).

**Workflow:**
1. Edit `homebrew-tap/fleet-monitor/server/config.yaml`
2. Push the PR
3. Check sees that this is in the tap-only exemption list and passes automatically
4. No escape hatch needed — the check knows this file has no canonical counterpart

---

## Troubleshooting

### Q: The check is blocking my PR. What do I do?

**A:** The check detected an edit to a mirrored tap file without a corresponding canonical-source edit.

1. **First choice:** Edit the canonical source too. This is the correct solution for most cases.
   - Find the canonical path in the [What Has a Canonical Source](#what-has-a-canonical-source) section
   - Edit that file in the same commit
   - Push the update — check will pass

2. **Second choice:** If this is a legitimate tap-only edit, add an escape hatch.
   - **Trailer approach** (preferred): Add `Tap-Only-Edit: intentional` to the commit message and force-push
   - **Label approach** (if already in review): Add the `tap-only-intentional` label on GitHub
   - Document your justification in the PR description

### Q: I added the trailer but the check still blocks the PR. Why?

**A:** The check looks for the exact trailer text `Tap-Only-Edit: intentional` (case-insensitive, flexible spacing).

- Verify the trailer is on its own line in the commit message (after the body)
- The trailer must be in one of the commits in the PR (if you have multiple commits, any one is sufficient)
- Re-push if you're unsure

Example of correct trailer placement:

```
Subject line

Body paragraph with details.

Tap-Only-Edit: intentional

Co-Authored-By: ...
```

### Q: I applied the `tap-only-intentional` label but the check still blocks the PR. Why?

**A:** The label-based check only works in GitHub Actions (during the automated check run). It does not work for local `scripts/check-tap-only-edits.sh` runs.

If you're running the script locally to test, use the **commit trailer** approach instead. The trailer works everywhere (local, CI, review).

### Q: How do I know if a file has a canonical source?

**A:** Check the [What Has a Canonical Source](#what-has-a-canonical-source) section above. If your file is listed there, it has a canonical counterpart. If not, it's tap-only and doesn't need an escape hatch.

You can also inspect the file-map in `scripts/check-tap-only-edits.sh` directly (lines 51–95).

---

## Related Documentation

- **[sync-tap.sh]** — The script that propagates canonical changes to tap mirrors (run during release)
- **[XACA-0340]** — Original issue describing the lockstep-drift regression class
- **[Homebrew Tap Guide](USER_GUIDE.md)** — General tap installation and usage

---

**Last Updated:** 2026-05-09
