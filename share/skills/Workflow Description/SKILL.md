---
name: kb-desc
description: Update the description/task for the current active workflow item in the terminal. Sets what displays on the LCARS kanban card for this window.
version: 1.0.0
author: Commander Jett Reno (Chief Technical Instructor)
company: Starfleet Academy - Engineering Lab
project: Dev Team LCARS Infrastructure
terminals:
  - All terminals (auto-detects team)
supported_os:
  - macOS
  - Linux
dependencies:
  - Claude Code
  - Kanban board system
  - kanban-helpers.sh
tags:
  - kanban
  - workflow
  - description
  - task
  - active-window
command_shortcut: kb-desc
last_updated: 2026-01-07
status: production-ready
model: haiku
---

# Workflow Description

## Skill Metadata

**Name:** Workflow Description
**Version:** 1.0.0
**Author:** Commander Jett Reno (Starfleet Academy)
**Command Shortcut:** `kb-desc`
**Platforms:** All dev-team platforms
**Last Updated:** January 7, 2026

---

## Purpose

Quick way to update the description/task text for the currently active workflow item in this terminal window. The description appears on the LCARS kanban card in the workflow tab.

---

## Usage

When the user invokes this skill with `/kb-desc`, do the following:

### 1. Get the New Description

If the user provided a description in their message (e.g., `/kb-desc Fix authentication bug`), use that.

Otherwise, ask what description they want to set.

### 2. Execute the Update

Run the following bash command to update the workflow description:

```bash
source ~/dev-team/kanban-helpers.sh && kb-task "DESCRIPTION_HERE"
```

Replace `DESCRIPTION_HERE` with the actual description text.

### 3. Confirm the Update

After running the command, confirm to the user that the description has been updated. The change will appear immediately in the LCARS UI on the workflow tab.

---

## Examples

**User:** `/kb-desc`
**Response:** Ask what description they want to set, then run the command.

**User:** `/kb-desc Implementing user authentication flow`
**Action:** Run `source ~/dev-team/kanban-helpers.sh && kb-task "Implementing user authentication flow"`
**Response:** "Workflow description updated: Implementing user authentication flow"

**User:** `/kb-desc Fix crash in FunCard reload handler`
**Action:** Run `source ~/dev-team/kanban-helpers.sh && kb-task "Fix crash in FunCard reload handler"`
**Response:** "Workflow description updated: Fix crash in FunCard reload handler"

---

## Notes

- The description appears on the kanban card under the terminal/window name
- LCARS displays up to 2 lines of text
- Keep descriptions concise but descriptive
- The update is immediate - no refresh needed in LCARS

---

## Related Commands

| Command | Description |
|---------|-------------|
| `kb-plan "task"` | Start planning with a new task description |
| `kb-task "desc"` | Set task description (shell command) |
| `kb-my-status` | Show current window's status |
| `kb-show` | Display full kanban board |

---

*"I've fixed worse with less." - Commander Jett Reno*
