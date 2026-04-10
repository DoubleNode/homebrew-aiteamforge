---
name: kanban-manager
description: Comprehensive kanban board management skill with full subitem support. Manages backlog items, workflow states, priorities, JIRA/GitHub linking, tags, worktree tracking, and hierarchical subitems. Works with all teams.
version: 1.8.2
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
  - backlog
  - workflow
  - subitems
  - jira
  - github
  - tags
  - worktree
  - task-management
  - priority
  - due-date
  - os-platform
command_shortcut: kb-backlog
last_updated: 2026-02-17
status: production-ready
---

# Kanban Manager

## Skill Metadata

**Name:** Kanban Manager
**Version:** 1.8.2
**Author:** Commander Jett Reno (Starfleet Academy)
**Command Shortcut:** `kb-backlog`
**Platforms:** All dev-team platforms
**Last Updated:** February 17, 2026
**New in 1.8.2:** `kb-release create` command - create releases from CLI via LCARS server API

---

## Purpose

This skill provides comprehensive kanban board management for all dev-team projects. It handles:

- **Backlog Management:** Add, modify, remove, and prioritize backlog items
- **Subitem Hierarchies:** Break down tasks into trackable subitems
- **Workflow Tracking:** Manage task progression through workflow states
- **External Linking:** Connect items to JIRA tickets and GitHub issues
- **Worktree Tracking:** Track which git worktree is being used for each item
- **LCARS Integration:** All changes reflect in the LCARS Mission Queue UI

---

## ⚠️ CRITICAL: How to Execute Commands

The `kb*` commands are shell functions from `kanban-helpers.sh`. To run them from Claude Code, you **MUST source the file first**:

```bash
source ~/dev-team/kanban-helpers.sh && kb-backlog sub start XACA-0013-001
```

**Always use this pattern:**
```bash
source ~/dev-team/kanban-helpers.sh && <kb-command>
```

**Examples:**
```bash
# Start a subitem
source ~/dev-team/kanban-helpers.sh && kb-backlog sub start XFIR-0001-001

# Mark subitem done
source ~/dev-team/kanban-helpers.sh && kb-backlog sub done XFIR-0001-001

# List backlog
source ~/dev-team/kanban-helpers.sh && kb-backlog list
```

**DO NOT** directly edit the board JSON files. Always use the commands.

---

## Quick Reference

### Backlog Commands

| Command | Description |
|---------|-------------|
| `kb-backlog add "title" [priority] [description] [jira-id] [os]` | Add new backlog item |
| `kb-backlog list` | List all backlog items with indices |
| `kb-backlog change <idx> ["title"] [priority]` | Modify existing item |
| `kb-backlog remove <idx>` | Remove item (use sparingly - prefer completing) |
| `kb-backlog priority <idx> [priority]` | View/set priority (critical/high/medium/low/blocked) |
| `kb-backlog jira <idx> [jira-id]` | View/set/clear JIRA ID |
| `kb-backlog github <idx> [issue-ref]` | View/set/clear GitHub issue |
| `kb-backlog desc <idx> [description]` | View/set/clear description |
| `kb-backlog tag <idx> [add\|rm\|clear] [tags...]` | Manage tags (clickable in LCARS) |
| `kb-backlog due <idx> [YYYY-MM-DD]` | View/set/clear due date |
| `kb-backlog toggle <idx>` | Toggle collapsed/expanded state |

> **⚠️ IMPORTANT:** When work is finished, use `kb-done` to mark items as **COMPLETED** rather than removing them. Completed items remain visible in the LCARS UI with a checkmark, providing work history. Only use `remove` for items added by mistake.

### Subitem Commands

| Command | Description |
|---------|-------------|
| `kb-backlog sub add <parent-id> "title" [jira-id] [os]` | Add subitem |
| `kb-backlog sub list <parent-id>` | List subitems |
| `kb-backlog sub remove <parent-id> <sub-idx>` | Remove subitem (use sparingly) |
| `kb-backlog sub start <subitem-id>` | Start working on subitem (tracks worktree) |
| `kb-backlog sub done <subitem-id>` | Mark subitem **COMPLETED** (clears worktree) |
| `kb-backlog sub stop <parent-id> <sub-idx>` | Stop working without completing |
| `kb-backlog sub todo <parent-id> <sub-idx>` | Mark subitem as todo |
| `kb-backlog sub priority <parent-id> <sub-idx> [priority]` | View/set subitem priority |
| `kb-backlog sub jira <parent-id> <sub-idx> <jira-id>` | Set subitem JIRA |
| `kb-backlog sub github <parent-id> <sub-idx> <issue-ref>` | Set subitem GitHub |
| `kb-backlog sub tag <parent-id> <sub-idx> [add\|rm\|clear] [tags...]` | Manage subitem tags |
| `kb-backlog sub due <parent-id> <sub-idx> [YYYY-MM-DD]` | Set subitem due date |

**Note:** Subitem IDs use format `XTEAM-0001-001` (parent ID + 3-digit suffix)

> **⚠️ IMPORTANT: Complete, Don't Delete**
> When finishing work on items/subitems, **always mark them as COMPLETED** using `sub done` or `kb-done`. Do NOT remove/delete completed items. Completed items provide valuable history and are displayed with a checkmark (✓) in the LCARS UI. Only use `remove` for items added by mistake.

### Workflow Commands

| Command | Description |
|---------|-------------|
| `kb-plan "task"` | Start planning phase |
| `kb-code` | Move to coding phase |
| `kb-test` | Move to testing phase |
| `kb-commit` | Move to commit phase |
| `kb-pause "reason"` | Pause task with reason (stores previous status) |
| `kb-resume` | Resume paused task and return to previous status |
| `kb-done [--force]` | Complete current task (requires all subitems completed) |
| `kb-pick <id>` | Mark item as active (simple assignment, no Claude launch) |
| `kb-run <id>` | Launch Claude Code with task (auto-creates worktree if in main repo) |
| `kb-stop-working` | Stop working on current item without completing |

### Worktree Commands

| Command | Description |
|---------|-------------|
| `kb-link-worktree <id>` | Link current worktree to a backlog item |
| `kb-unlink-worktree <id>` | Remove worktree link from item |

**Note:** When you run `kb-run` from the main repository, it automatically creates a worktree at `worktrees/<item-id>/` and a branch `feature/<item-id>`. Use `kb-pick` for simple assignment without worktree creation or Claude launch.

---

## Detailed Usage

### Adding Backlog Items

**Basic add (low priority default):**
```bash
kb-backlog add "Implement dark mode"
```

**With priority:**
```bash
kb-backlog add "Fix login crash" high
kb-backlog add "Production hotfix" critical
kb-backlog add "Waiting on design" blocked
```

**With description:**
```bash
kb-backlog add "Refactor auth module" high "Need to extract token validation and add refresh support"
```

**With JIRA ID:**
```bash
kb-backlog add "API integration" medium "" ME-123
```

**Full specification:**
```bash
kb-backlog add "Complete feature implementation" high "Detailed description here" ME-456
```

**With OS platform (for platform-specific items):**
```bash
kb-backlog add "Fix iOS payment crash" high "" ME-789 iOS
kb-backlog add "Android notification bug" medium "" "" Android
kb-backlog add "Firebase auth update" high "" FIR-456 Firebase
```

**Valid OS values:** `iOS`, `Android`, `Firebase` (case-insensitive)

> **Note:** OS is stored as the first element in the tags array. In the LCARS UI, OS displays as a logo below the priority pill. Click the logo to change the OS selection.

### Priority Levels

| Priority | Display | Sort Order | Use Case |
|----------|---------|------------|----------|
| `critical` / `crit` | RED (pulsing) | 1st | Production emergencies |
| `high` | ORANGE | 2nd | Urgent work, in-progress |
| `medium` / `med` | YELLOW | 3rd | Planned features |
| `low` | TAN | 4th | Nice-to-have, tech debt |
| `blocked` / `block` | GRAY (paused) | 5th | Waiting on external |

### Managing Subitems

Break down complex tasks into trackable subitems:

**Add subitems:**
```bash
kb-backlog sub add 0 "Design API schema"
kb-backlog sub add 0 "Implement endpoints" ME-124
kb-backlog sub add 0 "Write tests"
kb-backlog sub add 0 "Update documentation"
```

**Add subitems with OS:**
```bash
kb-backlog sub add XIOS-0001 "Fix UI crash" ME-789 iOS
kb-backlog sub add XAND-0002 "Update notifications" "" Android
```

**View subitems:**
```bash
kb-backlog sub list 0
```
Output:
```
Subitems for [0] "API Integration":
  [0.0] ○ Design API schema
  [0.1] ○ Implement endpoints (ME-124)
  [0.2] ○ Write tests
  [0.3] ○ Update documentation
```

**Track progress:**
```bash
kb-backlog sub done 0 0    # Mark "Design API schema" complete
kb-backlog sub done 0 1    # Mark "Implement endpoints" complete
```

**Start a subitem (promotes to active work):**
```bash
kb-backlog sub start 0 2   # Start "Write tests"
```
This:
1. Marks the subitem as `in_progress`
2. Creates an activeWindow entry with the subitem task
3. Subitem appears in LCARS workflow view

### LCARS UI Behavior

**Collapsed state (default):**
- Parent shows ▶ indicator
- Badge shows completion ratio: `2/4`
- Click/tap expands to show subitems

**Expanded state:**
- Parent shows ▼ indicator
- Subitems render indented below parent
- Each subitem shows status: ○ (todo), ● (in progress), ✓ (completed)

**Toggle expansion:**
```bash
kb-backlog toggle 0
```
State persists in JSON across refreshes.

### LCARS Inline Editing

The LCARS Mission Queue supports inline editing of priority and due dates directly in the UI:

**Priority Editing:**
- Click any priority pill (CRITICAL, HIGH, MEDIUM, LOW, BLOCKED) to open dropdown
- Select new priority level - changes save immediately to board JSON
- Priority colors update instantly in the UI

**Due Date Editing:**
- Click any due date pill to open date editor
- Use preset buttons (TODAY, TOMORROW, +1 WEEK, CLEAR) for quick selection
- Or enter custom date in YYYY-MM-DD format
- Due dates show urgency colors: red (past due), orange (today), yellow (this week)

**Subitem Editing:**
- Click subitem priority pill (shows as compact version)
- Click subitem due date to edit
- Same dropdown/editor UI as parent items

**Sort Toggle:**
- Click SORT button in filter bar to toggle between PRIORITY and DUE DATE sorting
- Priority sort: groups by priority level, uses due date as secondary sort
- Due date sort: items with due dates first (by urgency), priority as secondary
- Sort preference persists in browser localStorage

### External Issue Linking

**JIRA (Main Event teams):**
```bash
kb-backlog jira 0 ME-123              # Parent item
kb-backlog sub jira 0 1 ME-124        # Subitem
```

**GitHub (Academy, DNS, Freelance):**
```bash
kb-backlog github 0 #42               # Shorthand (uses team default repo)
kb-backlog github 0 owner/repo#123    # Full format
kb-backlog sub github 0 1 #43         # Subitem GitHub link
```

**Clear link:**
```bash
kb-backlog jira 0 -                   # Clear JIRA
kb-backlog github 0 -                 # Clear GitHub
```

### Managing Tags

Tags are displayed as clickable pill buttons in the LCARS UI. When clicked, they automatically filter the mission queue to show items with that tag.

**View current tags:**
```bash
kb-backlog tag 0                      # Show tags for item 0
```

**Set tags (replaces existing):**
```bash
kb-backlog tag 0 iOS feature urgent   # Set multiple tags
kb-backlog tag 0 refactor             # Set single tag
```

**Add tags (preserves existing):**
```bash
kb-backlog tag 0 add testing          # Add one tag
kb-backlog tag 0 add iOS Android      # Add multiple tags
```

**Remove specific tags:**
```bash
kb-backlog tag 0 rm testing           # Remove one tag
kb-backlog tag 0 rm iOS Android       # Remove multiple tags
```

**Clear all tags:**
```bash
kb-backlog tag 0 clear                # Remove all tags
```

**Subitem tags:**
```bash
kb-backlog sub tag 0 1 iOS testing    # Set tags on subitem [0.1]
kb-backlog sub tag 0 1 add feature    # Add tag to subitem
kb-backlog sub tag 0 1 rm testing     # Remove tag from subitem
kb-backlog sub tag 0 1 clear          # Clear all subitem tags
```

**LCARS UI Display:**
- Tags appear as a single purple pill below the timestamp
- Individual tags separated by black vertical bars
- Click any tag to filter the mission queue
- Tags are uppercase in display

---

## Data Structure

### Kanban Board File

Location: Each team's board is in their own repository under `kanban/`:

| Team | Board Location |
|------|----------------|
| Academy | `~/dev-team/kanban/academy-board.json` |
| iOS | `/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban/ios-board.json` |
| Android | `/Users/Shared/Development/Main Event/MainEventApp-Android/kanban/android-board.json` |
| Firebase | `/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban/firebase-board.json` |
| Command | `/Users/Shared/Development/Main Event/dev-team/kanban/command-board.json` |
| DNS | `/Users/Shared/Development/DNSFramework/kanban/dns-board.json` |
| Starwords | `/Users/Shared/Development/DoubleNode/Starwords/kanban/freelance-doublenode-starwords-board.json` |
| appPlanning | `/Users/Shared/Development/DoubleNode/appPlanning/kanban/freelance-doublenode-appplanning-board.json` |
| WorkStats | `/Users/Shared/Development/DoubleNode/WorkStats/kanban/freelance-doublenode-workstats-board.json` |
| Legal | `~/legal/coparenting/kanban/legal-coparenting-board.json` |

```json
{
  "team": "ios",
  "ship": "U.S.S. Enterprise NCC-1701-D",
  "series": "TNG",
  "teamName": "iOS",
  "lastUpdated": "2026-01-06T10:30:00Z",
  "terminals": { ... },
  "activeWindows": [ ... ],
  "backlog": [
    {
      "id": "IOS-001",
      "title": "Fun Card Packages",
      "priority": "high",
      "status": "in_progress",
      "description": "Enable fun card purchases",
      "jiraId": "ME-123",
      "addedAt": "2026-01-02T14:30:00Z",
      "collapsed": true,
      "tags": ["iOS", "feature", "payment"],
      "subitems": [
        {
          "id": "IOS-001-0",
          "title": "API Integration",
          "status": "completed",
          "jiraKey": "ME-124",
          "tags": ["API", "backend"]
        },
        {
          "id": "IOS-001-1",
          "title": "UI Implementation",
          "status": "in_progress",
          "jiraKey": "ME-125",
          "tags": ["UI", "SwiftUI"]
        }
      ]
    }
  ]
}
```

### Backlog Item Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique ID (team prefix + number) |
| `title` | string | Yes | Short task title |
| `priority` | string | Yes | critical, high, medium, low, blocked |
| `status` | string | Yes | todo, in_progress, completed, blocked, cancelled |
| `addedAt` | string | Yes | ISO 8601 timestamp - when created |
| `updatedAt` | string | Auto | ISO 8601 timestamp - when last modified |
| `completedAt` | string | Auto | ISO 8601 timestamp - when marked completed |
| `startedAt` | string | Auto | ISO 8601 timestamp - when work FIRST started (persists forever) |
| `dueDate` | string | No | ISO 8601 date (YYYY-MM-DD) - deadline |
| `description` | string | No | Longer description |
| `jiraId` | string | No | JIRA ticket ID |
| `githubIssue` | string | No | GitHub issue reference |
| `tags` | array | No | Array of tag strings (clickable in LCARS) |
| `collapsed` | boolean | No | UI expansion state (default: true) |
| `subitems` | array | No | Array of subitem objects |
| `activelyWorking` | boolean | No | True when item is being actively worked on |
| `worktree` | string | No | Full path to git worktree |
| `worktreeBranch` | string | No | Git branch name |
| `worktreeWindowId` | string | No | Terminal window ID working on this item |
| `workStartedAt` | string | Auto | ISO 8601 timestamp - when current work session started (cleared on completion) |
| `timeWorkedMs` | number | Auto | Accumulated work time in milliseconds (persists across sessions) |

### Subitem Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Auto | Auto-generated: `{parent-id}-{index}` |
| `title` | string | Yes | Short subitem title |
| `status` | string | Yes | todo, in_progress, completed, cancelled |
| `priority` | string | No | critical, high, medium, low, blocked (inherits from parent if not set) |
| `addedAt` | string | Yes | ISO 8601 timestamp - when created |
| `updatedAt` | string | Auto | ISO 8601 timestamp - when last modified |
| `completedAt` | string | Auto | ISO 8601 timestamp - when marked completed |
| `startedAt` | string | Auto | ISO 8601 timestamp - when work FIRST started (persists forever) |
| `dueDate` | string | No | ISO 8601 date (YYYY-MM-DD) - deadline |
| `jiraKey` | string | No | Subitem's JIRA ticket |
| `githubIssue` | string | No | Subitem's GitHub issue |
| `tags` | array | No | Array of tag strings (clickable in LCARS) |
| `description` | string | No | Optional description |
| `workStartedAt` | string | Auto | ISO 8601 timestamp - when current work session started (cleared on completion) |
| `timeWorkedMs` | number | Auto | Accumulated work time in milliseconds (persists across sessions) |

---

## Workflow Integration

### Starting Work from Backlog

**Before starting work on any item/subitem:**
1. Check if a plan document exists in the team's `kanban/` directory: `<team-kanban>/<ITEM-ID>_*.md`
2. If found, read the plan document for implementation context
3. Reference the plan throughout development for design decisions and verification checklist

**Simple assignment (mark as active):**
```bash
kb-backlog list                    # View available items
# Check for plan doc in team kanban/: ls <team-kanban>/XIOS-0001_*.md
kb-pick XIOS-0001                  # Mark item as active (no Claude, no worktree)
```

**Full launch with Claude Code:**
```bash
kb-backlog list                    # View available items
# Check for plan doc in team kanban/: ls <team-kanban>/XIOS-0001_*.md
kb-run XIOS-0001                   # Launch Claude + auto-create worktree
```

**Pick subitem:**
```bash
kb-backlog sub list 0              # View subitems
# Reference parent's plan doc for subitem context
kb-backlog sub start 0 1           # Start subitem [0.1]
```

> **TIP:** Plan documents contain implementation order, design decisions, and verification checklists. Always reference them to ensure consistent implementation.

### Workflow Progression

```
kb-plan "task"  ->  kb-code  ->  kb-test  ->  kb-commit  ->  kb-done
    |                  |            |             |             |
 PLANNING          CODING       TESTING        COMMIT      COMPLETED
                       \            |            /
                        \           |           /
                         \          v          /
                          `---> kb-pause "reason" <---`
                                    |
                                  PAUSED (pulsing red)
                                    |
                                kb-resume
                                    |
                             (returns to previous status)
```

Each state is visible in the LCARS kanban swimlanes. Paused cards appear in the PAUSED column with a pulsing red animation and display the pause reason prominently.

**Note:** `kb-done` marks the item/subitem as **COMPLETED** with status `completed`. The item remains in the backlog with a checkmark (✓) for historical tracking. It is NOT deleted.

### Subitem Completion Requirement

When completing a **main item** (not a subitem), `kb-done` will check that all subitems are completed first:

```bash
# If item XIOS-0001 has incomplete subitems:
kb-done XIOS-0001
# ═══════════════════════════════════════════════════════
# ❌ Cannot complete item: Incomplete subitems found
# ═══════════════════════════════════════════════════════
#
# The following subitems must be completed first:
#   • XIOS-0001-001 - API Integration
#   • XIOS-0001-003 - Write tests
#
# Options:
#   1. Complete the subitems first: kb-done <subitem-id>
#   2. Force complete anyway:       kb-done XIOS-0001 --force
# ═══════════════════════════════════════════════════════
```

**To bypass this check** (use with caution):
```bash
kb-done XIOS-0001 --force
```

This ensures all planned work is accounted for before marking a parent item complete.

---

## Work Time Tracking

The kanban system automatically tracks time spent working on items and subitems.

### How Time Tracking Works

**Automatic capture:**
1. When you run `sub start` or `kb-run`, a `workStartedAt` timestamp is recorded
2. When you run `sub done`, `sub stop`, or `kb-done`, elapsed time is calculated and added to `timeWorkedMs`
3. Time accumulates across multiple work sessions

**Time is captured when:**
- `sub start <id>` → Sets `workStartedAt` timestamp
- `sub done <id>` → Calculates elapsed time, adds to `timeWorkedMs`, clears `workStartedAt`
- `sub stop <id>` → Calculates elapsed time, adds to `timeWorkedMs`, clears `workStartedAt` (without completing)
- `kb-done` → Same behavior for parent items

**Example workflow:**
```bash
# Start work - begins time tracking
kb-backlog sub start XACA-0001-001

# ... work for 2 hours ...

# Complete - captures 2 hours
kb-backlog sub done XACA-0001-001

# Later, reopen and work more
kb-backlog sub start XACA-0001-001

# ... work for 1 more hour ...

# Stop without completing - captures additional hour
kb-backlog sub stop XACA-0001-001

# Total timeWorkedMs now reflects 3 hours
```

### LCARS Time Display

**Completed items/subitems:** Display total time worked in the UI
- Format: `< 1m`, `25m`, `2h 15m`, `1d 3h`

**Parent items with subitems:** Show aggregated time from all completed subitems

**In-progress items:** Show partial time (current session not yet captured)

### Important Notes

- Time is only captured when using `done` or `stop` commands
- If you mark items complete by directly editing JSON, no time is captured
- `workStartedAt` is cleared when work stops; `timeWorkedMs` persists forever
- Parent item time = sum of all completed subitem times

---

## Team Configurations

Each team has their own kanban directory in their repository:

| Team | Kanban Directory | Focus |
|------|------------------|-------|
| Academy | `~/dev-team/kanban/` | Dev Team Infrastructure |
| iOS | `.../MainEventApp-iOS/kanban/` | Main Event iOS App |
| Android | `.../MainEventApp-Android/kanban/` | Main Event Android App |
| Firebase | `.../MainEventApp-Functions/kanban/` | Firebase Functions/Rules |
| Command | `.../Main Event/dev-team/kanban/` | Strategic Operations |
| DNS | `.../DNSFramework/kanban/` | DNS Framework Packages |
| Starwords | `.../DoubleNode/Starwords/kanban/` | Starwords Freelance Project |
| appPlanning | `.../DoubleNode/appPlanning/kanban/` | AppPlanning Freelance Project |
| WorkStats | `.../DoubleNode/WorkStats/kanban/` | WorkStats Freelance Project |
| Legal | `~/legal/coparenting/kanban/` | Legal CoParenting Project |

Team is auto-detected from terminal name, `$LCARS_TEAM` env var, or working directory.

---

## Error Handling

**Item not found:**
```
Error: Index 5 out of range (0-3 available)
```

**Subitem not found:**
```
Error: Subitem index 2 out of range for parent 0 (0-1 available)
```

**No subitems:**
```
Error: Item at index 0 has no subitems
```

**File lock contention:**
```
Warning: Board file locked, retrying...
```
(Automatic retry with file locking prevents data corruption)

---

## Examples

### Complex Task Breakdown

```bash
# Add parent task
kb-backlog add "User Authentication Refactor" high "Complete auth system overhaul" ME-200

# Add subitems
kb-backlog sub add 0 "Extract token validation" ME-201
kb-backlog sub add 0 "Add refresh token support" ME-202
kb-backlog sub add 0 "Update error handling" ME-203
kb-backlog sub add 0 "Write integration tests" ME-204
kb-backlog sub add 0 "Update documentation"

# Start first subitem
kb-backlog sub start 0 0

# Mark complete, start next
kb-backlog sub done 0 0
kb-backlog sub start 0 1
```

### Daily Workflow

```bash
# Morning: Check backlog
kb-backlog list

# Quick assignment (just mark as active)
kb-pick XIOS-0001

# OR full Claude launch with worktree
kb-run XIOS-0001

# Work through phases
kb-code
kb-test
kb-commit
kb-done

# Or work on specific subitem
kb-backlog sub start XIOS-0001-001
```

### Reopening Completed Items

When a completed item needs additional work (bug fixes, enhancements, debugging), follow this process to maintain proper tracking history:

**⚠️ CRITICAL: Always create a new subitem when reopening**

When reopening a completed item where all subitems are also completed, Claude MUST automatically create a new subitem describing the new work. This:
- Preserves the historical record of completed work
- Documents why the item was reopened
- Tracks the new work separately from original implementation

**Reopening Process:**

1. **Change item status** from `completed` to `in_progress`
2. **Remove `completedAt`** field from the item
3. **Add active working fields:**
   - `activelyWorking: true`
   - `workStartedAt: <current timestamp>`
   - `worktree`, `worktreeBranch`, `worktreeWindowId`
4. **Create a new subitem** with:
   - Title prefixed with `REOPENED:` to indicate this is follow-up work
   - Description explaining why the item was reopened
   - Tags like `debug`, `post-merge`, `bugfix`, or `enhancement`
   - Status set to `in_progress`
   - Active working fields linking to the current window

**Example - Reopening for bug fix:**
```bash
# The board JSON should be updated to:
# 1. Parent item: status = "in_progress", remove completedAt, add activelyWorking fields
# 2. New subitem added:
{
  "id": "XACA-0015-013",
  "title": "REOPENED: Debug and fix OS tag display issues post-merge",
  "status": "in_progress",
  "description": "Item reopened to investigate and resolve issues after feature merge",
  "tags": ["debug", "post-merge"],
  "activelyWorking": true,
  "worktree": "/path/to/worktree",
  "worktreeBranch": "feature/xaca-0015",
  "worktreeWindowId": "engineering:engineering-cmd"
}
```

**Title Prefixes for Reopened Items:**
| Prefix | Use Case |
|--------|----------|
| `REOPENED: Debug...` | Investigating issues with completed feature |
| `REOPENED: Fix...` | Bug fix for completed feature |
| `REOPENED: Enhance...` | Adding to completed feature |
| `REOPENED: Refactor...` | Code improvements to completed feature |

**Why This Matters:**
- **Audit Trail:** Shows full history including post-completion work
- **Metrics:** Accurately tracks original vs. follow-up effort
- **Context:** Future developers understand the item's full lifecycle
- **Visibility:** LCARS UI shows the reopened subitem as active work

---

## Plan Documents

Plan documents capture detailed implementation context for complex work items. The kanban system supports three types of plan documents, each following a consistent naming convention.

### Document Location

Plan documents are stored in each team's `kanban/` directory (same as board files):

| Team | Plan Doc Directory |
|------|-------------------|
| Academy | `~/dev-team/kanban/` |
| iOS | `.../MainEventApp-iOS/kanban/` |
| Android | `.../MainEventApp-Android/kanban/` |
| Firebase | `.../MainEventApp-Functions/kanban/` |
| Command | `.../Main Event/dev-team/kanban/` |
| DNS | `.../DNSFramework/kanban/` |
| Starwords | `.../DoubleNode/Starwords/kanban/` |
| appPlanning | `.../DoubleNode/appPlanning/kanban/` |
| WorkStats | `.../DoubleNode/WorkStats/kanban/` |
| Legal | `~/legal/coparenting/kanban/` |

### Document Types & Naming Conventions

| Type | ID Pattern | Naming Convention | Example |
|------|------------|-------------------|---------|
| **Item** | `X{TEAM}-xxxx` | `<ITEM-ID>_<description>.md` | `XACA-0015_os_tag_display_feature.md` |
| **Epic** | `EPIC-xxxx` | `EPIC-xxxx_<description>.md` | `EPIC-0001_leaderboards.md` |
| **Release** | `REL-xxxx` | `REL-xxxx_<description>.md` | `REL-2026-Q1-001_feature_release.md` |

**Description guidelines:**
- 10-30 characters, lowercase with underscores
- Descriptive but concise
- No special characters

---

### Item Plan Documents

For complex backlog items with multiple subitems.

**Examples:**
- `XACA-0015_os_tag_display_feature.md`
- `XIOS-0023_funcard_reload_flow.md`
- `XFIR-0008_auth_token_refresh.md`

**Template:**
```markdown
# <ITEM-ID>: <Title>

**Status:** Planning Complete | In Progress | Completed
**Priority:** Critical | High | Medium | Low
**Tags:** <comma-separated tags>
**Created:** YYYY-MM-DD
**Team:** <Team Name>

---

## Summary
Brief description of the feature/task.

## Design Decisions
Key architectural and implementation choices.

## Files to Modify
List of files with specific changes needed.

## Implementation Order
Numbered steps/phases for implementation.

## Subitems
| ID | Title | Status |
|----|-------|--------|
| ... | ... | ... |

## Verification Checklist
- [ ] Test case 1
- [ ] Test case 2

## Notes
Additional context, dependencies, or considerations.
```

---

### Epic Plan Documents

For epics that group multiple related items across a larger initiative.

**Examples:**
- `EPIC-0001_leaderboards.md`
- `EPIC-0005_force_unwrap_remediation.md`
- `EPIC-0007_ios26_design_system.md`

**Template:**
```markdown
# EPIC: <Title>

**Epic ID:** EPIC-xxxx
**JIRA:** [KEY-xxx](https://jira.example.com/browse/KEY-xxx)
**Status:** Planning | Active | Completed | On Hold
**Priority:** Critical | High | Medium | Low
**Category:** Epic / Feature | Epic / Bugfix | Epic / Refactor

---

## Overview
High-level description of the epic's goals and scope.

## Business Value
- **Value 1:** Description
- **Value 2:** Description

## Child Stories
| ID | Title | JIRA | Status | Due Date |
|----|-------|------|--------|----------|
| XIOS-0001 | Story title | KEY-001 | todo | YYYY-MM-DD |

## Technical Approach
Implementation strategy, patterns, and key decisions.

## Dependencies
- External dependencies
- Cross-team coordination needs

## Risks
| Risk | Impact | Mitigation |
|------|--------|------------|
| Risk description | High/Medium/Low | Mitigation strategy |

## Success Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## Timeline
| Milestone | Target | Status |
|-----------|--------|--------|
| Phase 1 | YYYY-MM-DD | Status |

---

*Created: YYYY-MM-DD*
*Last Updated: YYYY-MM-DD*
*Owner: <Team Name>*
```

---

### Release Plan Documents

For release planning with multi-platform coordination and environment promotion.

**Examples:**
- `REL-2026-Q1-001_feature_release.md`
- `REL-STAR-120_starwords_update.md`
- `REL-2026-HOTFIX-001_crash_fixes.md`

**Template:**
```markdown
# Release: <Release Name>

**Release ID:** REL-xxxx
**Type:** Feature | Bugfix | Hotfix | Maintenance
**Status:** Planning | In Progress | QA | Staged | Released
**Target Date:** YYYY-MM-DD
**Created:** YYYY-MM-DD

---

## Overview
Brief description of the release goals and scope.

## Platforms & Environments

| Platform | Current Env | Target Env | Status |
|----------|-------------|------------|--------|
| iOS | DEV | PROD | In Progress |
| Android | DEV | PROD | Planning |
| Firebase | DEV | PROD | Planning |

## Included Items

### iOS
| ID | Title | Status | Priority |
|----|-------|--------|----------|
| XIOS-0001 | Item title | in_progress | high |

### Android
| ID | Title | Status | Priority |
|----|-------|--------|----------|
| XAND-0001 | Item title | todo | high |

### Firebase
| ID | Title | Status | Priority |
|----|-------|--------|----------|
| XFIR-0001 | Item title | todo | medium |

## Release Checklist

### Pre-Release
- [ ] All items completed
- [ ] Code review approved
- [ ] Unit tests passing
- [ ] QA sign-off

### Release Day
- [ ] Build created
- [ ] Environment promoted
- [ ] Smoke tests passed
- [ ] Stakeholders notified

### Post-Release
- [ ] Monitoring verified
- [ ] Rollback plan tested
- [ ] Documentation updated

## Rollback Plan
Steps to rollback if issues are discovered.

## Notes
Additional context, dependencies, or coordination needs.

---

*Release Manager: <Name>*
*Last Updated: YYYY-MM-DD*
```

---

### When to Create Plan Documents

| Document Type | Always Create For | Optional For |
|---------------|-------------------|--------------|
| **Item** | 3+ subitems, complex refactoring, cross-team work | Simple bug fixes, single-file changes |
| **Epic** | Multi-item initiatives, cross-team coordination | Single-item groupings |
| **Release** | Multi-platform releases, coordinated deployments | Single-platform hotfixes |

---

### Workflow Integration

**For Items:**
```bash
# 1. Create the item
kb-backlog add "Feature Name" high "Description"

# 2. Add subitems
kb-backlog sub add <id> "Subitem 1"
kb-backlog sub add <id> "Subitem 2"

# 3. Create plan document (Claude Code will do this)
# Location: <team-kanban>/<ITEM-ID>_<description>.md

# 4. Add tags
kb-backlog tag <id> add feature planning
```

**For Epics:**
```bash
# 1. Create the epic using kb-epic command
source ~/dev-team/kanban-helpers.sh && kb-epic create "Epic Title" "Description" high feature

# 2. Add items to epic
source ~/dev-team/kanban-helpers.sh && kb-epic add-item EPIC-0001 XIOS-0001

# 3. Create plan document
# Location: <team-kanban>/EPIC-xxxx_<description>.md
```

**For Releases:**
```bash
# 1. Create the release
/release create "Q1 2026 Feature Release" --platforms ios,android,firebase

# 2. Assign items to release
/release assign XIOS-0001 REL-2026-Q1-001 --platform ios

# 3. Create plan document
# Location: <team-kanban>/REL-xxxx_<description>.md
```

---

## Epic Management

Epics group multiple kanban items into high-level objectives. Each team has their own epics stored in their board JSON file.

### Epic Commands

> **⚠️ Remember:** Always source kanban-helpers.sh first:
> ```bash
> source ~/dev-team/kanban-helpers.sh && kb-epic <command>
> ```

| Command | Description |
|---------|-------------|
| `kb-epic create "title" [desc] [pri] [cat]` | Create new epic |
| `kb-epic list` | List all epics for current team |
| `kb-epic show <epic-id>` | Show epic details with items and progress |
| `kb-epic add-item <epic-id> <item-id>` | Add backlog item to epic |
| `kb-epic remove-item <epic-id> <item-id>` | Remove item from epic |
| `kb-epic update <epic-id> <field> <value>` | Update epic field |
| `kb-epic delete <epic-id>` | Delete/archive epic |

**Priority values:** `low`, `medium` (or `med`), `high`, `critical` (or `crit`)

**Category values:** `project`, `release`, `legal`, `milestone`, or any custom value

**Status values:** `planning`, `active`, `completed`, `on_hold`, `cancelled`

**Update fields:** `title`, `description`, `priority`, `status`, `category`, `dueDate`, `owner`

### Epic Examples

```bash
# Create an epic
source ~/dev-team/kanban-helpers.sh && kb-epic create "Q1 Infrastructure" "Infrastructure improvements" high project

# List all epics
source ~/dev-team/kanban-helpers.sh && kb-epic list

# Add items to epic
source ~/dev-team/kanban-helpers.sh && kb-epic add-item EPIC-0001 XACA-0015
source ~/dev-team/kanban-helpers.sh && kb-epic add-item EPIC-0001 XACA-0016

# View epic details and progress
source ~/dev-team/kanban-helpers.sh && kb-epic show EPIC-0001

# Update epic status
source ~/dev-team/kanban-helpers.sh && kb-epic update EPIC-0001 status active

# Set due date
source ~/dev-team/kanban-helpers.sh && kb-epic update EPIC-0001 dueDate 2026-03-31
```

### Epic Data Structure

Epics are stored in the team's board JSON under the `epics` array:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Epic ID (EPIC-xxxx format) |
| `title` | string | Yes | Epic title |
| `status` | string | Yes | planning, active, completed, on_hold, cancelled |
| `priority` | string | Yes | low, medium, high, critical |
| `description` | string | No | Detailed description |
| `category` | string | No | project, release, legal, milestone, or custom |
| `itemIds` | array | Yes | Array of backlog item IDs in this epic |
| `addedAt` | string | Yes | ISO 8601 timestamp - when created |
| `updatedAt` | string | Auto | ISO 8601 timestamp - when last modified |
| `dueDate` | string | No | ISO 8601 date (YYYY-MM-DD) |
| `owner` | string | No | Team or person responsible |
| `tags` | array | No | Array of tag strings |
| `collapsed` | boolean | No | UI expansion state |

### LCARS Epics Tab

The LCARS UI Epics tab provides:

- **Epic cards** showing title, status, priority, and item count
- **Progress bars** showing completion percentage
- **Expandable item lists** showing all items in each epic
- **Inline editing** for priority, status, and other fields
- **Filter by status** (All, Active, Planning, Completed)
- **Click-to-assign** items to epics from the modal

---

## Release Management

Releases coordinate deployments across platforms with environment promotion tracking. The release system uses dual storage:

1. **Board JSON** (`releases` array) - Release metadata and configuration
2. **Manifest files** (team-specific paths) - Items assigned to each release

### Manifest File Locations

Manifest files are stored in each team's `kanban/releases/` directory:

| Team | Manifest Path |
|------|---------------|
| **Academy** | `~/dev-team/kanban/releases/<release-id>/manifest.json` |
| **iOS** | `.../MainEventApp-iOS/kanban/releases/<release-id>/manifest.json` |
| **Android** | `.../MainEventApp-Android/kanban/releases/<release-id>/manifest.json` |
| **Firebase** | `.../MainEventApp-Functions/kanban/releases/<release-id>/manifest.json` |
| **Command** | `.../Main Event/dev-team/kanban/releases/<release-id>/manifest.json` |
| **DNS** | `.../DNSFramework/kanban/releases/<release-id>/manifest.json` |
| **Starwords** | `.../DoubleNode/Starwords/kanban/releases/<release-id>/manifest.json` |
| **appPlanning** | `.../DoubleNode/appPlanning/kanban/releases/<release-id>/manifest.json` |
| **WorkStats** | `.../DoubleNode/WorkStats/kanban/releases/<release-id>/manifest.json` |
| **Legal** | `~/legal/coparenting/kanban/releases/<release-id>/manifest.json` |

**Pattern:** `<team-repo>/kanban/releases/<release-id>/manifest.json`

> **Note:** During migration, the server can still read from the legacy central path (`~/dev-team/releases/`) for backward compatibility

### Release Commands

> **⚠️ Remember:** Always source kanban-helpers.sh first:
> ```bash
> source ~/dev-team/kanban-helpers.sh && kb-release <command>
> ```

> **⚠️ TEAM BOUNDARY ENFORCEMENT:** All `kb-release` commands operate **only on the current team's kanban**. Items must exist in your team's backlog to be assigned to releases. You cannot manage releases for items belonging to other teams.

| Command | Description |
|---------|-------------|
| `kb-release create <name> [options]` | Create a new release (calls LCARS server API) |
| `kb-release list` | List all releases for current team |
| `kb-release assign <item-id> <release-id> [platform]` | Assign item to release (item must be in current team's backlog) |
| `kb-release unassign <item-id>` | Remove release assignment from item (item must be in current team's backlog) |
| `kb-release show <item-id>` | Show item's release assignment (item must be in current team's backlog) |

**Platform values:** `ios`, `android`, `firebase` (default: `ios`)

**Create options:**

| Option | Description | Default |
|--------|-------------|---------|
| `--type <type>` | Release type: `feature`, `bugfix`, `hotfix`, `maintenance` | `feature` |
| `--platforms <list>` | Comma-separated platforms: `ios,android,firebase` | `ios,android` |
| `--project <name>` | Project name (e.g., `Starwords`, `MainEvent`) | none |
| `--target-date <date>` | Target release date (`YYYY-MM-DD`) | none |
| `--short-title <title>` | Short display name for LCARS UI | none |

> **Note:** Release deletion and environment promotion are done via the LCARS UI or `/release` skill. Release creation is available from both CLI (`kb-release create`) and the LCARS UI.

### Release Examples

```bash
# Create a basic release (defaults to feature type, ios+android platforms)
source ~/dev-team/kanban-helpers.sh && kb-release create "Q1 2026 Feature Release"

# Create a hotfix release for iOS only
source ~/dev-team/kanban-helpers.sh && kb-release create "iOS Hotfix 2.8.1" --type hotfix --platforms ios

# Create a multi-platform release with target date
source ~/dev-team/kanban-helpers.sh && kb-release create "March Update" --platforms ios,android,firebase --target-date 2026-03-15

# Create a project-specific release with short title
source ~/dev-team/kanban-helpers.sh && kb-release create "Starwords 1.2.0" --project Starwords --short-title "SW 1.2"

# List all releases
source ~/dev-team/kanban-helpers.sh && kb-release list

# Assign item to a release
source ~/dev-team/kanban-helpers.sh && kb-release assign XFIR-0001 REL-2026-Q1-001 firebase

# Check item's release assignment
source ~/dev-team/kanban-helpers.sh && kb-release show XFIR-0001

# Remove release assignment
source ~/dev-team/kanban-helpers.sh && kb-release unassign XFIR-0001
```

### Release Data Structure

#### Board Release Fields

Releases are stored in the team's board JSON under the `releases` array:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Release ID (REL-xxxx format) |
| `name` | string | Yes | Release name (e.g., "v3.0.0 - Feature Name") |
| `type` | string | Yes | feature, bugfix, hotfix, maintenance |
| `status` | string | Yes | planning, in_progress, completed, archived |
| `targetDate` | string | No | Target release date (YYYY-MM-DD) |
| `createdAt` | string | Yes | ISO 8601 timestamp |
| `environments` | array | Yes | Environment progression (DEV, QA, ALPHA, BETA, GAMMA, PROD) |
| `platforms` | object | Yes | Platform-specific version/environment tracking |
| `tags` | array | No | Array of tag strings |
| `team` | string | Yes | Owning team |

**Platform object structure:**
```json
{
  "ios": {
    "version": "3.0.0",
    "buildNumber": 1,
    "environment": "DEV",
    "environmentHistory": []
  }
}
```

#### Manifest Fields

Each release has a manifest file in the team's repository at `<team-repo>/dev-team/kanban/releases/<release-id>/manifest.json`:

| Field | Type | Description |
|-------|------|-------------|
| `releaseId` | string | Release ID |
| `name` | string | Release name |
| `version` | string | Version number |
| `type` | string | Release type |
| `team` | string | Owning team |
| `targetDate` | string | Target date |
| `description` | string | Release description |
| `items` | array | Array of assigned items |
| `createdAt` | string | Creation timestamp |
| `updatedAt` | string | Last update timestamp |

**Item object in manifest:**
```json
{
  "itemId": "XFIR-0001",
  "title": "Item Title",
  "status": "todo",
  "platform": "firebase",
  "team": "firebase",
  "assignedAt": "2026-01-27T03:49:20Z"
}
```

### Manifest System

The release system maintains item assignments in two places:

1. **Board item's `releaseAssignment` field** - Quick lookup from item perspective
2. **Manifest `items` array** - Authoritative list for release perspective

When items are assigned via `kb-release assign` or the LCARS UI, both are updated. The LCARS Releases tab reads from manifests.

**Manifest sync utility:**

If manifests get out of sync (e.g., items show `releaseAssignment` but manifest is empty):

```bash
# Sync all teams
python3 ~/dev-team/scripts/sync-release-manifests.py

# Sync specific team
python3 ~/dev-team/scripts/sync-release-manifests.py --team firebase

# Dry run (show what would change)
python3 ~/dev-team/scripts/sync-release-manifests.py --dry-run
```

### Environment Promotion

Releases progress through environments: `DEV → QA → ALPHA → BETA → GAMMA → PROD`

Promotion is done via the LCARS Releases tab:
1. Click on a release card to expand
2. View current environment per platform
3. Click "Promote" to advance to next environment
4. Environment history is tracked for audit

### LCARS Releases Tab

The LCARS UI Releases tab provides:

- **Release cards** showing name, type, status, and target date
- **Platform badges** showing current environment per platform
- **Item lists** (expandable) showing all assigned items
- **Progress indicators** showing completion percentage
- **Promote buttons** to advance environments
- **Inline editing** for release metadata
- **Filter by status** (All, In Progress, Completed, Archived)

---

## Troubleshooting

### Manifest Sync Issues

**Symptom:** Releases tab shows "0 items" but items have `+REL` badges or release assignments visible in Queue.

**Cause:** Items were assigned via a mechanism that updated the board's `releaseAssignment` field but not the manifest files.

**Solution:**
```bash
# Sync manifests from board data
python3 ~/dev-team/scripts/sync-release-manifests.py --team <team>

# Example for Firebase
python3 ~/dev-team/scripts/sync-release-manifests.py --team firebase
```

### Cross-Team Assignment Errors

**Symptom:** Error "Cross-team assignment rejected" when assigning item to release.

**Cause:** The item belongs to a different team than the release.

**Solution:** Items can only be assigned to releases owned by the same team. Create a release for the correct team or move the item.

### Epic Item Not Found

**Symptom:** Error "Item not found" when running `kb-epic add-item`.

**Cause:** The item ID doesn't exist in the current team's backlog.

**Solution:** Verify the item exists with `kb-backlog list` and check you're in the correct team terminal.

### Item Already in Epic

**Symptom:** Error "Item is already in Epic EPIC-xxxx".

**Cause:** An item can only belong to one epic at a time.

**Solution:** Remove from current epic first:
```bash
source ~/dev-team/kanban-helpers.sh && kb-epic remove-item EPIC-0001 XACA-0015
source ~/dev-team/kanban-helpers.sh && kb-epic add-item EPIC-0002 XACA-0015
```

### Release Not Showing in List

**Symptom:** `kb-release list` doesn't show expected releases.

**Cause:** Releases are team-specific. You may be in a different team's terminal.

**Solution:** Check your team with terminal name or `$LCARS_TEAM` environment variable. Releases only appear for their owning team.

### Item Not Found in Team Board

**Symptom:** Error "Item 'XAND-0001' not found in academy board" when running `kb-release assign`.

**Cause:** `kb-release` commands enforce team boundaries. The item must exist in the **current team's backlog**, not just any team's backlog.

**Solution:**
1. Verify you're in the correct team's terminal (item prefix should match your team)
2. Check current team context: `echo $LCARS_TEAM` or check terminal name
3. Switch to the correct team's terminal before running release commands
4. Example: To assign `XAND-0001` to a release, you must run the command from an Android team terminal

---

## Version History

**v1.8.2** (February 17, 2026)
- **`kb-release create` command** - Create releases from CLI without LCARS UI
  - Calls `POST /api/releases` on the LCARS server (consistent with existing `_kb_release_sync` pattern)
  - Supports `--type` (feature/bugfix/hotfix/maintenance), `--platforms`, `--project`, `--target-date`, `--short-title`
  - Input validation for release type, clear error messages for missing name or server-down
  - Wired into `kb-release` dispatcher as `create|new` subcommand
  - Updated `kb-help` and `kb-release help` with create documentation
  - All teams can now create releases through the official API without modifying kanban data directly

**v1.8.1** (January 27, 2026)
- **Team boundary enforcement for kb-release commands** (XACA-0049)
  - `kb-release assign`, `unassign`, and `show` now only work with items in current team's backlog
  - Commands use terminal context to determine team, not item ID prefix
  - Clear error messages when attempting to manage items from other teams
  - Prevents cross-team release management accidents
  - Updated documentation with team boundary notes and troubleshooting

**v1.8.0** (January 26, 2026)
- **Full Epic and Release management documentation** (XACA-0047)
  - Epic Commands section with full reference table (`kb-epic create`, `list`, `show`, `add-item`, `remove-item`, `update`, `delete`)
  - Release Commands section with full reference table (`kb-release list`, `assign`, `unassign`, `show`)
  - Epic Data Structure fields documentation
  - Release Data Structure fields documentation (board JSON and manifest files)
  - Manifest System explanation with sync utility documentation
  - Environment Promotion workflow documentation
  - LCARS UI integration documentation for Epics and Releases tabs
  - Troubleshooting section for common issues (manifest sync, cross-team errors, etc.)

**v1.7.0** (January 26, 2026)
- **Epic and Release plan document templates** - Comprehensive planning documentation for all kanban entity types
  - Item plan docs: `<ITEM-ID>_<description>.md` (existing)
  - Epic plan docs: `EPIC-xxxx_<description>.md` (new)
  - Release plan docs: `REL-xxxx_<description>.md` (new)
  - Full templates with sections for overview, business value, child stories, risks, success criteria
  - Workflow integration examples for creating plan docs alongside kanban entities
  - "When to Create" guidance table for all document types

**v1.6.0** (January 19, 2026)
- **Work time tracking** (XACA-0029) - Automatic tracking of time spent on items/subitems
  - `workStartedAt` timestamp set when starting work (`sub start`, `kb-run`)
  - `timeWorkedMs` accumulates elapsed time when completing or stopping work
  - Time persists across multiple work sessions
  - LCARS UI displays formatted time on completed items (e.g., "2h 15m")
  - Parent items show aggregated time from completed subitems
  - New "Work Time Tracking" documentation section

**v1.5.1** (January 19, 2026)
- **Subitem completion validation** - `kb-done` now verifies all subitems are completed before allowing parent item completion
  - Prevents accidentally completing items with unfinished subitems
  - Lists all incomplete subitems with IDs and titles
  - Provides `--force` flag to bypass check when intentional
  - Subitems can still be completed individually without restriction

**v1.4.1** (January 14, 2026)
- **Reopening completed items process** - Documented workflow for reopening completed items
  - When reopening, MUST create a new subitem describing the new work
  - Title prefix convention: `REOPENED: Debug/Fix/Enhance/Refactor...`
  - Preserves audit trail and metrics accuracy
  - New subitem gets active working fields linking to current window
  - Added to "Reopening Completed Items" section in Examples

**v1.5.0** (January 16, 2026)
- **Renamed blocked → paused** (XACA-0019) - Semantic clarification for workflow states
  - `kb-pause "reason"` - New command (replaces kb-block)
  - `kb-resume` - New command (replaces kb-unblock)
  - `kb-block`/`kb-unblock` still work as deprecated aliases with warnings
  - PAUSED column in LCARS kanban board (was BLOCKED)
  - Field names: `pausedReason`, `pausedAt`, `pausedPreviousStatus`
  - Reserves 'blocked' for future dependency-based blocking (XACA-0020)

**v1.4.0** (January 14, 2026)
- **OS platform tagging** - Add iOS/Android/Firebase platform tags to items/subitems
  - Visual OS logo display below priority pill in LCARS UI
  - Clickable to change OS selection
  - OS tags filtered from regular tag display
  - `kb-backlog add` and `kb-backlog sub add` support optional OS parameter

**v1.3.0** (January 14, 2026)
- **Blocking workflow support** - New commands and LCARS UI for blocked status
  - `kb-block "reason"` - Block current task with explanation, stores previous status
  - `kb-unblock` - Unblock task and automatically return to previous status
  - BLOCKED column in LCARS kanban board (first column for visibility)
  - Blocked cards display with pulsing red animation
  - Block reason displayed prominently on cards and detail view
  - `blocked` added to valid workflow statuses
  - Stores `blockedReason` and `previousStatus` in window data

**v1.2.6** (January 13, 2026)
- **Plan Documents** - New documentation standard for complex backlog items
  - Location: `<team-kanban>/<ITEM-ID>_<description>.md`
  - Template with Summary, Design Decisions, Files, Subitems, Verification
  - Required for features with 3+ subitems
  - Captures full implementation context for institutional knowledge

**v1.2.5** (January 13, 2026)
- **Command split** - Split `kb-pick` into two commands:
  - `kb-pick <id>` - Simple assignment, marks item as active (no Claude, no worktree)
  - `kb-run <id>` - Full launch with Claude Code and auto-worktree creation
- **LCARS ACTIVE filter** - New filter button to show only in-progress items

**v1.2.4** (January 12, 2026)
- **Priority command** - New `kb-backlog priority <idx> [priority]` to directly set item priority
- **Subitem priority command** - New `kb-backlog sub priority <parent-idx> <sub-idx> [priority]` for subitem priority
- **Priority aliases** - Supports `pri`, `med`, `crit`, `block` shortcuts
- **LCARS inline priority editing** - Click priority pills to change priority directly in UI
- **LCARS inline due date editing** - Click due date pills to set/clear dates with presets
- **Subitem inline editing** - Priority and due date editing for subitems in LCARS
- **Sort toggle** - Toggle between priority and due date sorting in Mission Queue
- **Secondary sorting** - Priority sort uses due date as tiebreaker, and vice versa

**v1.2.3** (January 12, 2026)
- **Started timestamp** - Added `startedAt` field to track when work FIRST started on an item/subitem
- **Persistent history** - `startedAt` persists forever (unlike `workStartedAt` which clears on completion)
- **Board timestamp fixes** - All boards updated with proper timestamps for historical items

**v1.2.2** (January 12, 2026)
- **Timestamp tracking** - Added `addedAt`, `updatedAt`, `completedAt` timestamps to items and subitems
- **Due dates support** - Items and subitems can have `dueDate` field for deadlines
- **Automatic timestamps** - `updatedAt` auto-updates on any modification; `completedAt` set when marked done

**v1.2.1** (January 12, 2026)
- **Clarified completion behavior** - Emphasized that items/subitems should be marked COMPLETED, not removed/deleted
- **Documentation updates** - Added important notes about using `done` vs `remove` commands
- **LCARS UI integration** - Completed items display with checkmark (✓) in Mission Queue

**v1.2.0** (January 12, 2026)
- **Worktree tracking** - Items/subitems track which worktree they're being worked on
- **Auto-worktree creation** - `kb-run` creates worktree automatically from main repo
- **Worktree conflict warnings** - Warns when starting work in worktree already assigned
- **New commands** - `kb-link-worktree`, `kb-unlink-worktree`, `kb-stop-working`
- **Subitem ID syntax** - `sub start` and `sub done` now accept subitem IDs directly
- **LCARS worktree badges** - Shows worktree/branch on actively worked items
- **Worktree filters** - Filter by `worktree:` or `branch:` in LCARS UI
- **Shell sourcing docs** - Clear instructions on how Claude should invoke commands

**v1.1.0** (January 7, 2026)
- **Tags support** - Clickable tag pills in LCARS UI
- New `tags` field on backlog items and subitems
- New `kb-backlog tag` command (add, rm, clear, set)
- New `kb-backlog sub tag` command for subitem tags
- Tags display as purple pills with black separators
- Click any tag to filter mission queue by that tag
- Search includes tag text matching

**v1.0.0** (January 6, 2026)
- Initial release of comprehensive Kanban Manager skill
- Full backlog item management (add, list, change, remove)
- Complete subitem support (add, list, remove, done, todo, jira, github, start)
- Toggle collapsed/expanded state
- JIRA and GitHub issue linking for both items and subitems
- File locking for thread safety
- Auto-generated subitem IDs
- LCARS UI integration with collapsible display

---

## Support

**Skill Author:** Commander Jett Reno (Chief Technical Instructor)

**Quick Help:**
```bash
kb-help              # Show all commands
kb-help sub          # Subitem command help
kb-backlog list      # View current backlog
```

---

*"I can fix it. I just need time, and some respect for my genius." - Commander Jett Reno*
