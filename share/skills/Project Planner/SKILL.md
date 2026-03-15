---
name: project-planner
description: Strategic project planning skill that creates kanban items, subitems, and plan documents WITHOUT executing any implementation. Enforces plan-and-delegate workflow with explicit handoff checkpoint.
version: 1.5.0
author: Captain Nahla Ake (Chancellor, Starfleet Academy)
company: Starfleet Academy - Chancellor's Office
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
  - Kanban Manager skill
tags:
  - planning
  - project-management
  - kanban
  - delegation
  - handoff
  - architecture
  - no-execution
command_shortcut: /plan-project
last_updated: 2026-02-28
status: production-ready
---

# Project Planner

## Skill Metadata

**Name:** Project Planner
**Version:** 1.5.0
**Author:** Captain Nahla Ake (Starfleet Academy Chancellor)
**Command:** `/plan-project`
**Platforms:** All aiteamforge platforms
**Last Updated:** February 28, 2026

---

## Purpose

This skill provides **planning-only** project management. It creates all planning artifacts (kanban items, subitems, plan documents) but **NEVER executes implementation**.

The skill enforces a deliberate handoff checkpoint, allowing work to be delegated to other agents or deferred for later.

### What This Skill Does

1. **Analyzes** the project/feature requirements
2. **Researches** the codebase to understand scope and impact
3. **Creates** a kanban backlog item with proper metadata
4. **Creates** all subitems (phased implementation steps)
5. **Creates** a plan document in the team's `kanban/` directory
6. **STOPS** with explicit handoff options

### What This Skill NEVER Does

- Start implementation
- Create or modify code files
- Run tests, builds, or linters
- Make commits or PRs
- Assume approval means "start working"

---

## Critical Behavior Rules

### MANDATORY: Plan Document Creation

**Every kanban item MUST have a corresponding plan document.** This is NOT optional.

```
═══════════════════════════════════════════════════════════════════════════════
 ⛔ MANDATORY REQUIREMENT: NO KANBAN ITEM WITHOUT A PLAN DOCUMENT
═══════════════════════════════════════════════════════════════════════════════

 Before displaying the handoff checkpoint, you MUST:

   1. Create the kanban backlog item (get ITEM-ID)
   2. Create all subitems
   3. Create the plan document at: <team-kanban>/<ITEM-ID>_<description>.md
   4. VERIFY the plan document was written successfully

 The handoff checkpoint CANNOT be displayed until the plan document exists.
 If document creation fails, report the error and retry.

═══════════════════════════════════════════════════════════════════════════════
```

**Why This Is Mandatory:**
- Plan documents provide implementation context for any agent
- They preserve design decisions and rationale
- They enable delegation to other agents/terminals
- They serve as historical record of project scope
- Other agents check for plan docs when starting work

**Plan Document Location:** `<TEAM_KANBAN>/<ITEM-ID>_<10-30_char_description>.md`

⚠️ **CRITICAL: Team-Specific Paths** - Each team's plan documents MUST be stored in that team's `kanban/` directory. See [Plan Document Path Resolution](#plan-document-path-resolution) below.

**Examples (each in the team's own kanban directory):**
- `~/aiteamforge/kanban/XACA-0031_dark_mode_support.md` (Academy)
- `.../MainEventApp-iOS/kanban/XIOS-0042_payment_flow_refactor.md` (iOS)
- `.../MainEventApp-Functions/kanban/XFIR-0055_account_deletion_api.md` (Firebase)
- `.../Starwords/kanban/XFSW-0020_setup_wizard.md` (Starwords)

### STOP AFTER PLANNING

After creating all planning artifacts (including the plan document), the skill MUST:

1. **Verify plan document exists** (use Read tool to confirm)
2. Display the "PROJECT PLANNING COMPLETE" banner
3. List all created artifacts (including plan doc path)
4. Present handoff options
5. **WAIT for explicit user instruction**

### NEVER Auto-Execute

Even if the user approves the plan, DO NOT start implementation unless they explicitly choose option 2 ("Start working on subitem 1") or similar.

**Approval of a plan is NOT permission to execute.**

### Handoff Options Template

Always end with this exact format:

```
═══════════════════════════════════════════════════════════════════════════════
 PROJECT PLANNING COMPLETE - READY FOR HANDOFF
═══════════════════════════════════════════════════════════════════════════════

 Created Artifacts:
   Kanban Item:  <ITEM-ID> "<Title>"
   Subitems:     <count> implementation phases
   Plan Doc:     <team-kanban>/<ITEM-ID>_<description>.md
   Priority:     <priority>
   Tags:         <tags>

 How would you like to proceed?

   1. DELEGATE - Assign to another agent/terminal
      Specify which team or terminal should work on this

   2. START NOW - I'll begin working on the first subitem
      Only choose this if you want ME to implement

   3. TRACK ONLY - Add to backlog, work on it later
      Item is ready whenever you want to start

   4. MODIFY PLAN - Adjust subitems or scope before proceeding
      I can add, remove, or reorder implementation phases

═══════════════════════════════════════════════════════════════════════════════
```

---

## Usage

### Basic Usage

```
/plan-project Add a settings panel to Fleet Monitor that allows users to configure refresh rates and theme colors
```

### With Priority

```
/plan-project [high] Implement user authentication with OAuth2 support
```

### With Team Specification

```
/plan-project [ios] [critical] Fix the payment flow crash when card is declined
```

---

## Planning Process

### Phase 1: Requirements Analysis

1. Parse the user's project description
2. Identify key features and requirements
3. Determine scope (single feature vs. multi-phase project)
4. Identify the target team from context

### Phase 2: Codebase Research

1. Search for related existing code
2. Identify files that will need modification
3. Understand current architecture patterns
4. Note dependencies and integration points

**Tools to use:** Glob, Grep, Read, Task (with Explore agent)

**Tools NOT to use:** Edit, Write (for code), Bash (for builds/tests)

### Phase 3: Kanban Item Creation

Create the main backlog item using kanban-helpers:

```bash
source ~/aiteamforge/kanban-helpers.sh && kb-backlog add "<title>" <priority> "<description>" "<jira-id>" "<os>"
```

### Phase 4: Subitem Creation

Break down into implementation phases:

```bash
source ~/aiteamforge/kanban-helpers.sh && kb-backlog sub add <item-id> "<subitem-title>"
```

**Subitem Guidelines:**
- 3-12 subitems per project (ideal: 5-8)
- Each subitem should be 1-4 hours of work
- Order by implementation dependency
- Group related work into phases
- Include documentation as explicit subitem when appropriate

> All subitems created by this planner are subject to the **Subitem Completion Protocol** (see CLAUDE.md). Every subitem must be completed or cancelled before the parent item can be closed via `kb-done`.

**⚠️ MANDATORY: Testing/Debugging Subitem for Code Changes**

Any project that involves code changes MUST include a dedicated **"Testing & Debugging"** subitem. This is NOT optional.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  REQUIRED: Every code-related project MUST have a Testing/Debugging subitem │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Standard Testing/Debugging Subitem:                                        │
│  Title: "Testing & Debugging"                                               │
│                                                                             │
│  This subitem should include:                                               │
│  • Unit test creation/updates for new functionality                         │
│  • Integration testing across affected components                           │
│  • Manual testing of user-facing features                                   │
│  • Debugging and fixing issues found during testing                         │
│  • Lint validation (SwiftLint/ktlint/ESLint)                                │
│  • Performance verification if applicable                                   │
│                                                                             │
│  Position: Should be one of the LAST subitems (after implementation)        │
│                                                                             │
│  ⛔ DO NOT skip this subitem for "small" changes                            │
│  ⛔ DO NOT combine testing with implementation subitems                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**When Testing/Debugging subitem is required:**
- New feature implementation
- Bug fixes
- Refactoring existing code
- API changes
- UI/UX modifications
- Performance improvements
- Any change that modifies `.swift`, `.kt`, `.ts`, `.js`, `.py`, or other code files

**When Testing/Debugging subitem may be skipped:**
- See [Project-Level Exceptions](#project-level-exceptions) below

**⚠️ MANDATORY: PR Creation & Review Subitem for Code Changes**

Any project that involves code changes MUST also include a dedicated **"PR Creation & Review"** subitem. This is NOT optional.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  REQUIRED: Every code-related project MUST have a PR Creation & Review     │
│  subitem                                                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Standard PR Creation & Review Subitem:                                    │
│  Title: "PR Creation & Review"                                             │
│                                                                             │
│  This subitem should include:                                               │
│  • Create feature branch and push to remote                                │
│  • Create PR targeting develop (NEVER master) with full description        │
│  • Generate Review Handoff Prompt for reviewer agent                       │
│  • Monitor for bot review approval (polling loop)                          │
│  • Address any requested changes from reviewer                             │
│  • Merge PR after approval (squash merge, delete branch)                   │
│  • Update kanban status (kb-done)                                          │
│                                                                             │
│  Position: ALWAYS the LAST subitem (after Testing & Debugging)             │
│                                                                             │
│  ⛔ DO NOT skip this subitem — all code changes require PR review          │
│  ⛔ DO NOT combine PR creation with testing or implementation subitems     │
│  ⛔ DO NOT merge without reviewer approval (bot or human)                  │
│                                                                             │
│  Follows the PR Review Workflow defined in CLAUDE.md:                      │
│  • PR targets develop branch                                               │
│  • Review handoff prompt generated for cross-terminal review               │
│  • gh-bot-review used for formal approval (same-account restriction)       │
│  • Creating agent monitors and merges after bot approval                   │
│  • --admin flag required (GitHub Team plan limitation)                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**When PR Creation & Review subitem is required:**
- Same criteria as Testing/Debugging — any project with code changes
- New feature implementation
- Bug fixes
- Refactoring existing code
- API changes
- UI/UX modifications
- Performance improvements

**When PR Creation & Review subitem may be skipped:**
- See [Project-Level Exceptions](#project-level-exceptions) below

**Ordering of Mandatory Trailing Subitems:**
```
┌─────────────────────────────────────────────────────────────────────────────┐
│  For all code-related projects, the LAST TWO subitems must always be:      │
│                                                                             │
│  ... (implementation subitems) ...                                         │
│  N-1. Testing & Debugging          ← Second-to-last (MANDATORY)           │
│  N.   PR Creation & Review         ← Always LAST (MANDATORY)              │
│                                                                             │
│  This order ensures:                                                       │
│  • All code is tested BEFORE the PR is created                             │
│  • Lint validation passes BEFORE the PR is opened                          │
│  • The PR contains fully tested, lint-clean code                           │
│  • Reviewers receive quality code that's ready for review                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Subitem Completion Protocol

Before the parent kanban item can be marked COMPLETED, the implementing agent MUST follow this protocol:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     SUBITEM COMPLETION PROTOCOL                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. Run `kb-sweep` to verify all subitems are resolved                      │
│     kb-sweep will report any subitems still in todo or in-progress state    │
│                                                                             │
│  2. Complete or cancel every subitem:                                       │
│     • Completed: subitem work is done (kb-backlog sub done <ITEM-ID-NNN>)   │
│     • Cancelled: subitem is no longer needed — MUST include a reason        │
│       (kb-backlog sub cancel <ITEM-ID-NNN> "<reason>")                      │
│                                                                             │
│  3. Re-run `kb-sweep` to confirm zero unresolved subitems remain            │
│                                                                             │
│  4. Only then run `kb-done` to close the parent item                        │
│                                                                             │
│  ⛔ The `--force` flag is RESTRICTED TO USER-ONLY USAGE                     │
│     Agents MUST NOT bypass the subitem check with --force                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

This protocol applies to **all** subitems created by this planner — including the mandatory Testing & Debugging and PR Creation & Review subitems.

### Project-Level Exceptions

Not all teams and projects produce code. The mandatory trailing subitems (Testing & Debugging, PR Creation & Review) apply **only to projects that involve code changes in a git repository**.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   EXCEPTION RULES FOR MANDATORY SUBITEMS                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  EXCEPTION 1: Non-Code Teams                                               │
│  ─────────────────────────────────────────────────────────────────────────  │
│  Teams that do NOT maintain a code repository are EXEMPT from both          │
│  mandatory trailing subitems (Testing & PR).                               │
│                                                                             │
│  Exempt teams:                                                              │
│  • Command (XCMD-)  — Strategic/planning documents only, no code           │
│  • Legal (XLCP-)    — Case management, no code repository                  │
│                                                                             │
│  These teams have no codebase to test, no branches to PR, and no           │
│  CI/CD pipeline. Their deliverables are documents, plans, and strategy.    │
│                                                                             │
│  EXCEPTION 2: Non-Code Projects on Code Teams                              │
│  ─────────────────────────────────────────────────────────────────────────  │
│  Even on teams that normally produce code, some projects are non-code:     │
│                                                                             │
│  Both subitems may be skipped when the project involves ONLY:              │
│  • Documentation updates (README, guides, ADRs)                            │
│  • Asset updates (images, strings, localization files)                     │
│  • Planning/research tasks with no code output                             │
│  • Strategic initiatives or process changes                                │
│                                                                             │
│  EXCEPTION 3: Direct-to-Develop Changes                                    │
│  ─────────────────────────────────────────────────────────────────────────  │
│  The PR Creation & Review subitem (only) may be skipped when:              │
│  • Changes are minor and committed directly to develop                     │
│  • Agent is NOT in a worktree (main repo, on develop branch)              │
│  • Changes are config files, RELNOTES, or small fixes                      │
│  • Testing & Debugging subitem STILL APPLIES if code was changed          │
│                                                                             │
│  ⚠️ NOTE: This exception does NOT exempt Testing — tested code can be     │
│  committed directly, but untested code should not.                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Quick Reference — Which Subitems Does My Project Need?**

| Scenario | Testing & Debugging | PR Creation & Review |
|----------|:-------------------:|:--------------------:|
| Code project on code team (worktree) | **REQUIRED** | **REQUIRED** |
| Code project on code team (direct to develop) | **REQUIRED** | Skip |
| Non-code project on code team (docs, assets) | Skip | Skip |
| Command team (XCMD) — any project | Skip | Skip |
| Legal team (XLCP) — any project | Skip | Skip |
| Config-only changes (non-code) | Skip | Skip |
| Planning/research with no code output | Skip | Skip |

**Decision Flow:**

```
Is this a code-related project?
├── NO → Skip both mandatory subitems
│         (docs, assets, planning, strategy, Command/Legal teams)
│
└── YES → Does the team maintain a code repository?
    ├── NO → Skip both mandatory subitems
    │         (Command/XCMD, Legal/XLCP)
    │
    └── YES → Will changes go through a PR?
        ├── YES → BOTH subitems required (Testing + PR)
        │          (worktree work, feature branches)
        │
        └── NO → Testing subitem REQUIRED, PR subitem skipped
                   (minor fixes direct to develop, not in worktree)
```

### Phase 5: Plan Document Creation (MANDATORY)

**⚠️ This phase is REQUIRED. Do NOT skip to the handoff checkpoint without completing this phase.**

Create a comprehensive plan document following the template below.

**Location:** `<team-kanban>/<ITEM-ID>_<10-30_char_description>.md`

⚠️ **CRITICAL: Use the correct team kanban directory based on the item prefix!**
- See [Plan Document Path Resolution](#plan-document-path-resolution) for the full mapping
- NEVER put non-Academy (non-XACA) plan docs in `~/aiteamforge/kanban/`

**Naming Convention:**
- Use the ITEM-ID exactly as assigned (e.g., `XACA-0031`)
- Description should be 10-30 characters, lowercase, underscores for spaces
- Determine the correct team directory from the prefix

**Examples by Team (each in their OWN kanban directory):**
- Academy: `~/aiteamforge/kanban/XACA-0031_dark_mode_support.md`
- iOS: `.../MainEventApp-iOS/kanban/XIOS-0042_payment_refactor.md`
- Firebase: `.../MainEventApp-Functions/kanban/XFIR-0055_account_api.md`
- Freelance: `.../Starwords/kanban/XFSW-0020_setup_wizard.md`

**Minimum Content Requirements:**

Every plan document MUST include:
1. ✅ **Header metadata** (Status, Priority, Tags, Created date, Team)
2. ✅ **Summary** (2-4 sentences describing the project)
3. ✅ **Requirements** (numbered list of what must be accomplished)
4. ✅ **Design Decisions** (at least one architectural/implementation decision)
5. ✅ **Files to Modify** (specific file paths, not generic descriptions)
6. ✅ **Implementation Order** (phased steps matching subitems)
7. ✅ **Subitems Table** (all subitems with IDs and status)
8. ✅ **Verification Checklist** (testable acceptance criteria)

**Template:**

```markdown
# <ITEM-ID>: <Title>

**Status:** Planning Complete
**Priority:** <Critical | High | Medium | Low>
**Tags:** <comma-separated tags>
**Created:** <YYYY-MM-DD>
**Team:** <Team Name>

---

## Summary

<2-4 sentence description of the project/feature>

## Requirements

<Numbered list of requirements>

---

## Design Decisions

### <Decision Area 1>
<Explanation of architectural choice>

### <Decision Area 2>
<Explanation of implementation approach>

---

## Files to Modify

### New Files to Create

| File | Purpose |
|------|---------|
| `path/to/file.ext` | Description |

### Existing Files to Modify

| File | Changes |
|------|---------|
| `path/to/existing.ext` | Description of changes |

---

## Implementation Order

### Phase 1: <Phase Name>
1. <Step description>
2. <Step description>

### Phase 2: <Phase Name>
3. <Step description>
4. <Step description>

---

## Subitems

| ID | Title | Status |
|----|-------|--------|
| <ITEM-ID>-001 | <Subitem 1 title> | todo |
| <ITEM-ID>-002 | <Subitem 2 title> | todo |
| ... | ... | ... |
| <ITEM-ID>-00(N-1) | Testing & Debugging | todo |
| <ITEM-ID>-00N | PR Creation & Review | todo |

> ⚠️ **Note:** Testing & Debugging and PR Creation & Review subitems are MANDATORY for all code-related projects
> These two subitems must always be the last two, in this order.

---

## Verification Checklist

- [ ] <Test case 1>
- [ ] <Test case 2>
- [ ] <Test case 3>

---

## Notes

<Additional context, dependencies, risks, or considerations>

---

*Plan created by <Agent Name> - <Role>*
```

### Phase 5b: Plan Document Verification (MANDATORY)

After writing the plan document, you MUST verify it was created successfully:

```bash
# Get the correct team directory for this item
PLAN_DIR=$(get_plan_doc_dir "<ITEM-ID>")

# Verify the plan document exists in the CORRECT team directory
ls "$PLAN_DIR/<ITEM-ID>_"*.md
```

**Verification Checklist (internal - do not display to user):**
- [ ] File exists at the CORRECT team-specific kanban/ path
- [ ] File contains all 8 required sections
- [ ] Subitems table matches created subitems
- [ ] File paths are specific (not generic placeholders)
- [ ] Verification checklist has at least 3 testable items

**If verification fails:**
1. Report the specific failure to the user
2. Attempt to create/fix the plan document
3. Re-verify before proceeding

**DO NOT display the handoff checkpoint until verification passes.**

### Phase 6: Handoff Checkpoint

Display the completion banner and wait for user instruction.

**DO NOT proceed to implementation without explicit user choice.**

---

## Example Workflow

### User Request

```
/plan-project Add dark mode support to the LCARS Fleet Monitor
```

### Agent Response

```
I'll create a comprehensive plan for dark mode support.

**Researching codebase...**

Found relevant files:
- public/lcars/css/lcars-fleet-theme.css (main theme)
- public/lcars/js/lcars-fleet-core.js (theme switching logic)
- server/server.js (user preference storage)

**Creating kanban item...**

✓ Created XACA-0031 "LCARS Fleet Monitor Dark Mode"

**Creating subitems...**

✓ XACA-0031-001: Define dark mode color palette
✓ XACA-0031-002: Create CSS custom properties for theme switching
✓ XACA-0031-003: Add theme toggle UI component
✓ XACA-0031-004: Implement localStorage preference persistence
✓ XACA-0031-005: Update all component styles to use CSS variables
✓ XACA-0031-006: Add system preference detection (prefers-color-scheme)
✓ XACA-0031-007: Testing & Debugging (MANDATORY for code changes)
✓ XACA-0031-008: PR Creation & Review (MANDATORY for code changes)

**Creating plan document...**

Resolving plan doc path for XACA-0031 → ~/aiteamforge/kanban/ (Academy team)

Writing ~/aiteamforge/kanban/XACA-0031_dark_mode_support.md with:
- Summary and requirements
- Design decisions (CSS custom properties approach)
- Files to modify (3 files identified)
- Implementation order (8 phases)
- Subitems table (8 items, including mandatory Testing & PR subitems)
- Verification checklist (5 test cases)

✓ Created ~/aiteamforge/kanban/XACA-0031_dark_mode_support.md

**Verifying plan document...**

✓ Plan document exists and contains all required sections

═══════════════════════════════════════════════════════════════════════════════
 PROJECT PLANNING COMPLETE - READY FOR HANDOFF
═══════════════════════════════════════════════════════════════════════════════

 Created Artifacts:
   Kanban Item:  XACA-0031 "LCARS Fleet Monitor Dark Mode"
   Subitems:     8 implementation phases
   Plan Doc:     ~/aiteamforge/kanban/XACA-0031_dark_mode_support.md
   Priority:     Medium
   Tags:         feature, ui, accessibility

 How would you like to proceed?

   1. DELEGATE - Assign to another agent/terminal
      Specify which team or terminal should work on this

   2. START NOW - I'll begin working on the first subitem
      Only choose this if you want ME to implement

   3. TRACK ONLY - Add to backlog, work on it later
      Item is ready whenever you want to start

   4. MODIFY PLAN - Adjust subitems or scope before proceeding
      I can add, remove, or reorder implementation phases

═══════════════════════════════════════════════════════════════════════════════
```

---

## Integration with Kanban Manager

This skill uses the Kanban Manager skill commands:

| Action | Command |
|--------|---------|
| Create item | `kb-backlog add` |
| Add subitem | `kb-backlog sub add` |
| Set priority | `kb-backlog priority` |
| Add tags | `kb-backlog tag` |
| Set due date | `kb-backlog due` |
| Link JIRA | `kb-backlog jira` |

**Always source helpers first:**
```bash
source ~/aiteamforge/kanban-helpers.sh && <command>
```

---

## Team Detection

The skill auto-detects the target team from:

1. Explicit specification: `/plan-project [ios] ...`
2. Environment variable: `$LCARS_TEAM`
3. Terminal name mapping
4. Working directory context

**Valid teams:** `ios`, `android`, `firebase`, `academy`, `command`, `dns`, `freelance`, `mainevent`

---

## Plan Document Path Resolution

⚠️ **CRITICAL: Each team has its OWN kanban directory in their repository.**

Plan documents MUST be stored in the owning team's `kanban/` directory, NOT in a central location or subdirectory of another team's repo.

### Repository-Based Path Mapping

Each project has its own git repository. The item ID prefix determines which repo's kanban/ directory to use:

#### Main Event Teams

| Prefix | Team | Kanban Directory |
|--------|------|------------------|
| `XACA-` | Academy | `~/aiteamforge/kanban/` |
| `XIOS-` | iOS | `/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban/` |
| `XAND-` | Android | `/Users/Shared/Development/Main Event/MainEventApp-Android/kanban/` |
| `XFIR-` | Firebase | `/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban/` |
| `XCMD-` | Command | `/Users/Shared/Development/Main Event/aiteamforge/kanban/` |
| `XDNS-` | DNS | `/Users/Shared/Development/DNSFramework/kanban/` |

#### Freelance Projects (Each project has its own repo)

| Prefix | Project | Kanban Directory |
|--------|---------|------------------|
| `XFSW-` | Starwords | `/Users/Shared/Development/DoubleNode/Starwords/kanban/` |
| `XFAP-` | AppPlanning | `/Users/Shared/Development/DoubleNode/appPlanning/kanban/` |
| `XFWS-` | WorkStats | `/Users/Shared/Development/DoubleNode/WorkStats/kanban/` |

#### Legal Projects

| Prefix | Project | Kanban Directory |
|--------|---------|------------------|
| `XLCP-` | CoParenting | `~/legal/coparenting/kanban/` |

### Key Principle

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  EVERY team has its own kanban directory in their repository:              │
│                                                                             │
│  <repo-root>/                                                               │
│  └── kanban/               ← All kanban files go HERE                       │
│      ├── <team>-board.json                                                  │
│      ├── <ITEM-ID>_<description>.md  (plan docs)                            │
│      └── releases/<release-id>/manifest.json                                │
│                                                                             │
│  ⛔ NEVER put another team's files in YOUR repo's kanban/                   │
│  ⛔ NEVER create team subdirectories (ios/, firebase/, etc.) in kanban/     │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Path Resolution Logic

When creating a plan document:

1. **Extract the prefix** from the ITEM-ID (e.g., `XIOS-0042` → `XIOS`)
2. **Look up the team's kanban directory** using the mapping table above
3. **Construct the full path**: `<team-kanban>/<ITEM-ID>_<description>.md`
4. **Ensure directory exists** before writing (create if needed)

### Bash Helper for Path Resolution

```bash
# Function to get plan doc directory from item ID
get_plan_doc_dir() {
    local item_id="$1"
    local prefix="${item_id%%-*}"  # Extract prefix before first hyphen

    case "$prefix" in
        # Main Event Teams
        XACA) echo "$HOME/aiteamforge/kanban" ;;
        XIOS) echo "/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban" ;;
        XAND) echo "/Users/Shared/Development/Main Event/MainEventApp-Android/kanban" ;;
        XFIR) echo "/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban" ;;
        XCMD) echo "/Users/Shared/Development/Main Event/aiteamforge/kanban" ;;
        XDNS) echo "/Users/Shared/Development/DNSFramework/kanban" ;;

        # Freelance Projects (each project has its own repo)
        XFSW) echo "/Users/Shared/Development/DoubleNode/Starwords/kanban" ;;
        XFAP) echo "/Users/Shared/Development/DoubleNode/appPlanning/kanban" ;;
        XFWS) echo "/Users/Shared/Development/DoubleNode/WorkStats/kanban" ;;

        # Legal Projects
        XLCP) echo "$HOME/legal/coparenting/kanban" ;;

        *) echo "$HOME/aiteamforge/kanban" ;;  # Default fallback to Academy
    esac
}

# Usage example
ITEM_ID="XIOS-0042"
PLAN_DIR=$(get_plan_doc_dir "$ITEM_ID")
mkdir -p "$PLAN_DIR"
echo "Plan doc path: $PLAN_DIR/${ITEM_ID}_description.md"
```

### Why Separate Repositories?

1. **Team ownership** - Each team manages their own git history and planning documents
2. **Independent deployments** - Teams can release without affecting others
3. **Access control** - Repository permissions are per-team
4. **Code reviews** - PRs stay within team boundaries
5. **Scalability** - Each repo stays focused and manageable

### Directory Creation

If a team's `kanban/` directory doesn't exist, create it before writing:

```bash
PLAN_DIR=$(get_plan_doc_dir "$ITEM_ID")
mkdir -p "$PLAN_DIR"
```

---

## Error Handling

### No Clear Requirements

If the project description is too vague:

```
I need more information to create a comprehensive plan.

Please clarify:
- What specific functionality should this include?
- Are there any constraints or requirements?
- What's the expected scope (small fix vs. large feature)?
```

### Cross-Team Work

If the project spans multiple teams:

```
This project involves multiple teams:
- iOS: <component>
- Firebase: <component>

I'll create the plan for the [primary team] board.
Cross-team coordination items will be noted in the plan document.
```

---

## Retroactive Plan Document Creation

If a kanban item was created WITHOUT a plan document (e.g., via direct `kb-backlog add`), you should create the plan document retroactively.

**When to Create Retroactive Plan Docs:**
- Item exists in backlog but no plan doc exists in the team's `kanban/` directory
- Item has subitems but no plan document
- User asks to "document" or "plan" an existing item

**Process:**
1. Read the existing item details: `kb-backlog show <item-id>`
2. List existing subitems: `kb-backlog sub list <item-id>`
3. **Determine the correct team directory** using [Plan Document Path Resolution](#plan-document-path-resolution)
4. Research the codebase for context
5. Create the plan document in the **team-specific directory**
6. Verify document creation

**Command to check for missing plan docs (project-aware):**
```bash
# Function to get plan doc directory from item ID
get_plan_doc_dir() {
    local item_id="$1"
    local prefix="${item_id%%-*}"

    case "$prefix" in
        # Main Event Teams
        XACA) echo "$HOME/aiteamforge/kanban" ;;
        XIOS) echo "/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban" ;;
        XAND) echo "/Users/Shared/Development/Main Event/MainEventApp-Android/kanban" ;;
        XFIR) echo "/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban" ;;
        XCMD) echo "/Users/Shared/Development/Main Event/aiteamforge/kanban" ;;
        XDNS) echo "/Users/Shared/Development/DNSFramework/kanban" ;;

        # Freelance Projects
        XFSW) echo "/Users/Shared/Development/DoubleNode/Starwords/kanban" ;;
        XFAP) echo "/Users/Shared/Development/DoubleNode/appPlanning/kanban" ;;
        XFWS) echo "/Users/Shared/Development/DoubleNode/WorkStats/kanban" ;;

        # Legal Projects
        XLCP) echo "$HOME/legal/coparenting/kanban" ;;

        *) echo "$HOME/aiteamforge/kanban" ;;
    esac
}

# List all backlog items without plan documents (checks correct project repo)
for id in $(kb-backlog list --ids-only); do
  plan_dir=$(get_plan_doc_dir "$id")
  if ! ls "$plan_dir/${id}_"*.md 2>/dev/null; then
    echo "Missing plan doc: $id (should be in $plan_dir)"
  fi
done
```

---

## Best Practices

### Subitem Granularity

**Too coarse (bad):**
- "Implement the feature"
- "Write all the code"

**Too fine (bad):**
- "Create file header"
- "Add import statement"
- "Define first variable"

**Just right (good):**
- "Create data model and schema"
- "Implement API endpoints"
- "Build UI components"
- "Add error handling"
- "Write unit tests"

### Plan Document Quality

Include enough detail that:
- Another developer can implement without asking questions
- Design decisions are documented with rationale
- File paths are specific and accurate
- Verification checklist covers all requirements

---

## Quick Reference: Mandatory Requirements

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    PROJECT PLANNER - MANDATORY CHECKLIST                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Before showing handoff checkpoint, ALL of these MUST be complete:         │
│                                                                             │
│  □ Kanban item created with kb-backlog add                                 │
│  □ All subitems created with kb-backlog sub add                            │
│  □ Testing/Debugging subitem included (unless exempt — see Exceptions)     │
│  □ PR Creation & Review subitem included (unless exempt — see Exceptions)  │
│  □ Mandatory subitems are last two: Testing, then PR (in that order)       │
│  □ Exceptions verified (non-code teams, non-code projects, direct-develop) │
│  □ Plan document written to CORRECT TEAM KANBAN DIRECTORY:                 │
│      XACA-* → ~/aiteamforge/kanban/                                           │
│      XIOS-* → .../MainEventApp-iOS/kanban/                                 │
│      XAND-* → .../MainEventApp-Android/kanban/                             │
│      XFIR-* → .../MainEventApp-Functions/kanban/                           │
│      XCMD-* → .../Main Event/aiteamforge/kanban/                              │
│      XDNS-* → .../DNSFramework/kanban/                                     │
│      XFSW-* → .../Starwords/kanban/                                        │
│      XFAP-* → .../appPlanning/kanban/                                      │
│      XFWS-* → .../WorkStats/kanban/                                        │
│      XLCP-* → ~/legal/coparenting/kanban/                                  │
│  □ Plan document verified (exists + has all 8 required sections)           │
│                                                                             │
│  When closing the parent item (implementing agent checklist):               │
│  □ Run kb-sweep — verify all subitems are completed or cancelled            │
│  □ Cancel any unneeded subitems with a reason before running kb-done        │
│  □ Run kb-done only AFTER kb-sweep confirms zero unresolved subitems        │
│  ⛔ --force flag is RESTRICTED TO USER-ONLY USAGE — agents must not use it │
│                                                                             │
│  ⛔ NEVER put another project's plan docs in YOUR repo                     │
│  ⛔ Each Freelance project has its OWN repository                          │
│                                                                             │
│  Plan Document Required Sections:                                          │
│  1. Header metadata (Status, Priority, Tags, Created, Team)                │
│  2. Summary (2-4 sentences)                                                │
│  3. Requirements (numbered list)                                           │
│  4. Design Decisions (at least one)                                        │
│  5. Files to Modify (specific paths)                                       │
│  6. Implementation Order (phased steps)                                    │
│  7. Subitems Table (matching created subitems)                             │
│  8. Verification Checklist (3+ testable items)                             │
│                                                                             │
│  ⛔ DO NOT display handoff checkpoint if plan document is missing          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Version History

**v1.5.0** (February 28, 2026)
- **Subitem Completion Protocol** - Added full protocol section requiring `kb-sweep` before `kb-done`
- Agents must run `kb-sweep`, resolve all subitems (complete or cancel with reason), then run `kb-done`
- `--force` flag explicitly restricted to user-only usage — agents must not bypass subitem checks
- Added protocol note in Phase 4 Subitem Guidelines
- Added protocol box in Quick Reference checklist for implementing agents
- References the Subitem Completion Protocol defined in CLAUDE.md

**v1.4.0** (February 14, 2026)
- **MANDATORY PR Creation & Review subitem** - All code-related projects now require a dedicated PR Creation & Review subitem
- PR subitem covers: branch push, PR creation targeting develop, review handoff prompt generation, bot approval monitoring, merge after approval, kanban status update
- Follows the full PR Review Workflow defined in CLAUDE.md (gh-bot-review, --admin merge, cross-terminal review)
- **Mandatory trailing subitem ordering** - Testing & Debugging is second-to-last, PR Creation & Review is always last
- Ensures all code is tested and lint-clean before PR is opened
- **Project-Level Exceptions** - Clear exception rules for when mandatory subitems may be skipped:
  - Non-code teams (Command/XCMD, Legal/XLCP) exempt from both subitems
  - Non-code projects on code teams (docs, assets, planning) exempt from both subitems
  - Direct-to-develop changes exempt from PR subitem only (Testing still required for code)
- Added decision flow chart and quick-reference table for subitem requirements
- Updated plan document template to include both mandatory trailing subitems
- Updated example workflow to show 8 subitems (including both mandatory subitems)
- Updated quick reference checklist with PR subitem verification and exception check

**v1.3.0** (February 2, 2026)
- **MANDATORY Testing/Debugging subitem** - All code-related projects now require a dedicated Testing & Debugging subitem
- Added detailed guidance on what testing subitem should include (unit tests, integration, lint validation, etc.)
- Updated mandatory checklist to include testing subitem verification
- Updated example workflow to show testing subitem as standard practice
- Updated plan document template to include testing subitem note
- Clarified when testing subitem can be skipped (docs-only, config, assets)

**v1.2.0** (January 26, 2026)
- **Repository-based plan document storage** - Each project has its own kanban/ directory
- Added [Plan Document Path Resolution](#plan-document-path-resolution) section with project-to-repo mapping
- Added bash helper function `get_plan_doc_dir()` for repo path resolution
- Updated all examples to show correct repository paths
- Updated verification commands to check correct project repository
- Updated quick reference checklist with repository mapping
- ⚠️ **CRITICAL**: Plan docs go in the PROJECT'S REPOSITORY, not subdirectories of another repo
- **Main Event**: Academy, iOS, Android, Firebase (separate repos)
- **Freelance**: Each project (Starwords, AppPlanning, etc.) has its OWN repo
- **Legal**: CoParenting has its own repo with XLCP-* prefix

**v1.1.0** (January 26, 2026)
- **MANDATORY plan document enforcement** - Every kanban item must have a plan doc
- Added verification step (Phase 5b) before handoff checkpoint
- Added minimum content requirements (8 required sections)
- Added retroactive plan document creation guidance
- Added quick reference checklist
- Strengthened enforcement language throughout

**v1.0.0** (January 20, 2026)
- Initial release
- Planning-only workflow enforcement
- Handoff checkpoint with explicit options
- Integration with Kanban Manager skill
- Plan document template
- Team auto-detection

---

## Support

**Skill Author:** Captain Nahla Ake (Chancellor, Starfleet Academy)

**Related Skills:**
- Kanban Manager (`kb-backlog`)
- Team Mission Status (`/team-missions`)

---

*"Let's design this for the future, not just today." - Captain Nahla Ake*
