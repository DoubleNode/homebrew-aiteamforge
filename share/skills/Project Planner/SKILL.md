---
name: project-planner
description: Strategic project planning skill that creates kanban items, subitems, and plan documents WITHOUT executing any implementation. Enforces plan-and-delegate workflow with explicit handoff checkpoint.
version: 1.10.0
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
last_updated: 2026-03-18 (v1.10.0)
status: production-ready
---

# Project Planner

## Skill Metadata

**Name:** Project Planner
**Version:** 1.10.0
**Author:** Captain Nahla Ake (Starfleet Academy Chancellor)
**Command:** `/plan-project`
**Platforms:** All dev-team platforms
**Last Updated:** March 18, 2026

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
- `~/dev-team/kanban/XACA-0031_dark_mode_support.md` (Academy)
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

### Review & Test Subitem Governance

#### Protected Subitem Classification

Subitems tagged with `[Review]` or `[Test]` are **protected subitems** with special governance rules:

| Tier | Tags | Agent Can Cancel? | User Approval Required? |
|------|------|-------------------|------------------------|
| Standard | (none) | Yes, with reason | No |
| **Protected** | `[Review]`, `[Test]` | **No** | **Yes** |
| Mandatory | Core implementation | No | Yes |

#### Rules for Protected Subitems

1. **Review subitems are real work.** When a PR reviewer creates a `[Review]` subitem, they are creating a mandatory pre-merge work item — NOT an optional suggestion. All `[Review]` subitems MUST be resolved before the PR can be merged.

2. **Test subitems are real work.** When a QA tester creates a `[Test]` subitem, they are flagging quality issues that MUST be addressed.

3. **Agents CANNOT cancel protected subitems.** The only valid outcomes are:
   - **Completed** — the agent did the work
   - **Cancelled by user** — the user explicitly approved cancellation

4. **If cancellation seems warranted:** The agent must STOP, present the subitem and reasoning to the user, and WAIT for explicit approval before cancelling.

5. **"Cancelled with a reason" is NOT equivalent to "completed."** Agents must not use cancellation as a shortcut to avoid doing review/test work.

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
source ~/dev-team/kanban-helpers.sh && kb-backlog add "<title>" <priority> "<description>" "<jira-id>" "<os>"
```

### Phase 4: Subitem Creation

Break down into implementation phases:

```bash
source ~/dev-team/kanban-helpers.sh && kb-backlog sub add <item-id> "<subitem-title>"
```

**Subitem Guidelines:**
- 3-12 subitems per project (ideal: 5-8)
- Each subitem should be 1-4 hours of work
- Order by implementation dependency
- Group related work into phases
- Include documentation as explicit subitem when appropriate

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

**⚠️ MANDATORY: PR Creation & Test Handoff Subitem for Code Changes**

Any project that involves code changes MUST also include a dedicated **"PR Creation & Test Handoff"** subitem. This is NOT optional.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  REQUIRED: Every code-related project MUST have a PR Creation & Test       │
│  Handoff subitem                                                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Standard PR Creation & Test Handoff Subitem:                              │
│  Title: "PR Creation & Test Handoff"                                       │
│                                                                             │
│  This subitem should include:                                               │
│  • Create feature branch and push to remote                                │
│  • Create PR targeting develop (NEVER master) with full description        │
│  • Auto-spawn test agent (background Agent, subagent_type for QA)          │
│  • Auto-spawn review agent (background Agent, subagent_type for reviewer)  │
│  • Both agents fire in PARALLEL (not sequential)                           │
│  • Enter parallel monitoring loop (check both gates each cycle)            │
│  • Address any requested changes from QA tester or reviewer                │
│  • Merge PR after both approvals (squash merge, delete branch)             │
│  • Update kanban status (kb-done)                                          │
│                                                                             │
│  Position: Third-to-last (after Testing & Debugging, before QA Testing     │
│  & Code Review, before Retrospective)                                      │
│                                                                             │
│  ⛔ DO NOT skip this subitem — all code changes require PR + QA testing    │
│  ⛔ DO NOT combine PR creation with testing or implementation subitems     │
│  ⛔ DO NOT merge without both QA and reviewer approval                     │
│                                                                             │
│  Follows the Auto-Spawn PR Test & Review workflow in CLAUDE.md:            │
│  • PR targets develop branch                                               │
│  • Test + review agents auto-spawned via Agent tool (run_in_background)    │
│  • Both run in parallel — no sequential dependency                         │
│  • gh-bot-test/gh-bot-review used for formal approval (bot identity)       │
│  • Creating agent enters parallel monitoring loop                          │
│  • --admin flag required (GitHub Team plan limitation)                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**When PR Creation & Test Handoff subitem is required:**
- Same criteria as Testing/Debugging — any project with code changes
- New feature implementation
- Bug fixes
- Refactoring existing code
- API changes
- UI/UX modifications
- Performance improvements

**When PR Creation & Test Handoff subitem may be skipped:**
- See [Project-Level Exceptions](#project-level-exceptions) below

**⚠️ MANDATORY: QA Testing & Code Review Subitem for Code Changes**

Any project that involves code changes MUST also include a dedicated **"QA Testing & Code Review"** subitem. This is NOT optional.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  REQUIRED: Every code-related project MUST have a QA Testing & Code        │
│  Review subitem                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Standard QA Testing & Code Review Subitem:                                │
│  Title: "QA Testing & Code Review"                                         │
│                                                                             │
│  This subitem covers what happens AFTER the PR is created:                 │
│  • QA tester runs unit tests, lint validation, and integration tests       │
│  • QA tester validates edge cases and regression scenarios                 │
│  • QA tester submits test result via gh-bot-test (APPROVE or              │
│    REQUEST_CHANGES)                                                         │
│  • Code reviewer performs standard review checklist (Security,             │
│    Architecture, Code Quality, Performance, Testing)                       │
│  • Code reviewer submits review via gh-bot-review (APPROVE or             │
│    REQUEST_CHANGES)                                                         │
│  • On both approvals, creating agent merges PR                             │
│                                                                             │
│  Position: Second-to-last (after PR Creation & Test Handoff, before        │
│  Retrospective and Knowledge Capture)                                      │
│                                                                             │
│  ⛔ DO NOT skip this subitem — all code changes require QA + code review   │
│  ⛔ DO NOT combine QA testing with PR creation or implementation subitems  │
│  ⛔ DO NOT merge without both QA tester and reviewer approval              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**When QA Testing & Code Review subitem is required:**
- Same criteria as Testing/Debugging — any project with code changes
- New feature implementation
- Bug fixes
- Refactoring existing code
- API changes
- UI/UX modifications
- Performance improvements

**When QA Testing & Code Review subitem may be skipped:**
- See [Project-Level Exceptions](#project-level-exceptions) below

**⚠️ MANDATORY: Retrospective and Knowledge Capture Subitem for All Projects**

Every project MUST include a dedicated **"Retrospective and Knowledge Capture"** subitem as the second-to-last step. This is NOT optional for code projects. Non-code teams and non-code projects are technically exempt but strongly encouraged to include it.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  REQUIRED: Every code-related project MUST have a Retrospective and        │
│  Knowledge Capture subitem as the SECOND-TO-LAST step                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Standard Retrospective and Knowledge Capture Subitem:                     │
│  Title: "Retrospective and Knowledge Capture"                              │
│                                                                             │
│  This subitem should include:                                               │
│  • Review kanban item, git history, and PR comments                        │
│  • Review all subagent Task outputs — locate and extract "Lessons Learned" │
│    sections from each subagent's output                                    │
│  • Create the retrospective document using kb-retro-path:                  │
│    RETRO_PATH=$(kb-retro-path <ITEM-ID>)                                  │
│    cp ~/dev-team/kanban/knowledge/TEMPLATES/retrospective_template.md \    │
│       "$RETRO_PATH"                                                        │
│    ⛔ Do NOT manually construct the path — always use kb-retro-path       │
│  • Fill in the Delegation Map — EVERY Task tool invocation during the     │
│    project MUST be logged (subagent_type, subitem, what they did)          │
│  • Categorize each lesson: agent-specific vs. team domain knowledge        │
│    - Agent-specific → <repo-kanban>/knowledge/<codename>/                  │
│    - Team domain    → <repo-kanban>/knowledge/TEAM/                        │
│    - A lesson CAN go to both if it has personal AND team-wide value        │
│    - Subagent lessons: categorize per Section 12 of the design doc         │
│  • Write knowledge entry (or entries) to the appropriate directory/ies     │
│  • Update INDEX.md for each location written                               │
│  • Fill in the "Knowledge Entries Created" table in the retrospective doc  │
│  • Run cross-agent review: re-spawn each unique subagent type from the    │
│    Delegation Map to review the retrospective and extract knowledge to    │
│    their own directories (see Cross-Agent Review section below)           │
│  • Update the Cross-Agent Review table in the retrospective doc           │
│  • Mark this retrospective subitem done ONLY after all agents reviewed    │
│                                                                             │
│  See ~/dev-team/kanban/XACA-0084_knowledge_base_design.md for full        │
│  process details, file templates, agent-to-directory mapping,              │
│  guidance on agent-specific vs. team domain categorization, subagent       │
│  knowledge extraction (Section 12), and retrospective document spec        │
│  (Section 13).                                                             │
│                                                                             │
│  Position: SECOND-TO-LAST subitem (after QA Testing & Code Review,         │
│  before Sync Local Develop Branch)                                         │
│                                                                             │
│  ⛔ DO NOT skip this subitem for code-related projects                     │
│  ⛔ DO NOT combine retrospective with implementation or PR subitems        │
│  ⛔ DO NOT skip writing knowledge entries to ALL appropriate locations     │
│  ⛔ DO NOT skip creating the retrospective document                        │
│  ⛔ NEVER include secrets, credentials, or PII in knowledge entries or     │
│     retrospective documents                                                │
│  ⛔ NEVER claim "lessons captured inline in retrospective" as reason to    │
│     skip creating knowledge entries — inline lessons are effectively dead   │
│     because no agent reads retrospectives before starting work. Only       │
│     INDEX.md and knowledge entry files get consulted.                      │
│  ⛔ MINIMUM 1 knowledge entry per retrospective is REQUIRED. If a project │
│     truly taught nothing new, you MUST explicitly cite the existing         │
│     knowledge entries that already cover the lessons and verify they exist. │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**🚨🚨🚨 CRITICAL: Retrospective File Naming & Location Rules 🚨🚨🚨**

These rules are absolute. Violations cause broken cross-references, polluted knowledge bases, and wasted cleanup effort.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  RETROSPECTIVE FILE NAMING                                                  │
│                                                                             │
│  Pattern:  <ITEM-ID>_<desc>_RETROSPECTIVE.md                              │
│                                                                             │
│  The <desc> MUST match the plan document's description slug exactly.       │
│                                                                             │
│  Example — if the plan document is:                                        │
│    XACA-0083_division_analytics_dashboards.md                              │
│  Then the retrospective MUST be:                                           │
│    XACA-0083_division_analytics_dashboards_RETROSPECTIVE.md                │
│                                                                             │
│  ❌ WRONG:  XACA-0083_RETROSPECTIVE.md          (missing <desc>)          │
│  ❌ WRONG:  xaca-0083-retro.md                   (wrong format entirely)   │
│  ❌ WRONG:  XACA-0083-RETROSPECTIVE.md           (hyphen instead of _)    │
│  ✅ RIGHT:  XACA-0083_division_analytics_dashboards_RETROSPECTIVE.md       │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│  RETROSPECTIVE FILE LOCATION                                                │
│                                                                             │
│  Retrospective documents live in ONE place only:                           │
│                                                                             │
│    <kanban-dir>/<ITEM-ID>_<desc>_RETROSPECTIVE.md                         │
│                                                                             │
│  For Academy:  ~/dev-team/kanban/                                          │
│  For iOS:      <ios-repo>/kanban/                                          │
│  For Android:  <android-repo>/kanban/                                      │
│  For Firebase: <firebase-repo>/kanban/                                     │
│                                                                             │
│  ⛔ NEVER copy retrospective documents into knowledge directories          │
│  ⛔ NEVER place retros in ~/dev-team/docs/kanban/                          │
│  ⛔ NEVER place retros in <repo-kanban>/knowledge/<codename>/              │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│  RETROSPECTIVE vs. KNOWLEDGE ENTRIES — THEY ARE DIFFERENT THINGS           │
│                                                                             │
│  Retrospective documents:                                                  │
│    → Live in kanban/ only                                                  │
│    → Are NOT knowledge entries                                             │
│    → Must NOT appear in any INDEX.md                                       │
│    → Must NOT be copied to knowledge directories                           │
│                                                                             │
│  Knowledge entries (extracted FROM retrospectives):                         │
│    → Live in knowledge directories (primary + backup)                      │
│    → Named k###-<slug>.md (e.g., k001-chart-js-registration-scoping.md)   │
│    → ARE listed in INDEX.md                                                │
│    → Live in <repo-kanban>/knowledge/<codename>/                           │
│                                                                             │
│  The retrospective PROCESS creates knowledge entries.                      │
│  The retrospective DOCUMENT is not itself a knowledge entry.               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Subagent Prompt Requirements for Knowledge Capture:**

When any project subitem is delegated to a subagent via the Task tool, the subagent
prompt MUST include this instruction at the end (before the LCARS cleanup instruction):

```
Before returning your output, include a "Lessons Learned" section at the end with:
- Any technical lessons, gotchas, or surprising behaviors you encountered
- Mistakes you made or nearly made and how you caught them
- Patterns or approaches that worked particularly well
- Anything a future agent doing similar work should know
Keep it brief (3-7 bullet points). The implementing agent will extract these during
the retrospective step.
```

This is required so the implementing agent has source material for subagent lessons
when creating the retrospective document. Without it, subagent lessons are lost when
the Task completes.

**🚨 MANDATORY: Retrospective Subitem Delegation Prompt**

When delegating the "Retrospective and Knowledge Capture" subitem to a subagent via the Task tool, the delegation prompt MUST include these specific instructions (in addition to the standard "Lessons Learned" instruction above):

````
## CRITICAL: Retrospective File Creation (MANDATORY)

You MUST create a retrospective FILE. Knowledge entries alone are NOT sufficient.

Steps:
1. Get the retrospective file path:
   RETRO_PATH=$(source ~/dev-team/kanban-helpers.sh && kb-retro-path <ITEM-ID>)
2. Copy the template:
   cp ~/dev-team/kanban/knowledge/TEMPLATES/retrospective_template.md "$RETRO_PATH"
3. Fill in ALL sections of the retrospective document
4. Create knowledge entries (separate files in the knowledge directory)
5. The `kb-backlog sub done` command will BLOCK completion if the retro file is missing

⛔ DO NOT skip creating the retrospective file
⛔ DO NOT confuse knowledge entries with the retrospective document — they are DIFFERENT things
⛔ The retrospective file MUST exist at the path returned by kb-retro-path
````

**Why This Is Mandatory:**
Agents delegated the retrospective subitem have historically focused on knowledge entries (which they understand well) while skipping the retrospective file (which they don't realize is a separate, mandatory artifact). This explicit prompt template ensures the subagent knows both are required. The `kb-backlog sub done` command enforces this — it will refuse to mark the subitem complete if the retrospective file is missing.

**When Retrospective and Knowledge Capture subitem is required:**
- New feature implementation
- Bug fixes
- Refactoring existing code
- API changes
- UI/UX modifications
- Performance improvements
- Any project that involves code changes in a git repository

**When Retrospective and Knowledge Capture subitem may be skipped:**
- See [Project-Level Exceptions](#project-level-exceptions) below

**Note for non-code projects:** Even when technically exempt, non-code projects (planning, documentation, infrastructure design, strategy) are strongly encouraged to include the Retrospective subitem. Lessons about planning, communication, scope estimation, and coordination are just as valuable as technical lessons.

**🚨 MANDATORY: Cross-Agent Retrospective Review**

The retrospective is NOT a single-agent activity. Every agent who contributed to a project — planner, implementer, reviewer, subagent — should review the retrospective and extract knowledge relevant to their own domain.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  CROSS-AGENT RETROSPECTIVE REVIEW PROCESS                                  │
│                                                                             │
│  After the implementing agent creates the retrospective document:          │
│                                                                             │
│  1. IMPLEMENTING AGENT writes the retrospective document and extracts      │
│     their own knowledge entries (as already documented above)              │
│                                                                             │
│  2. ALL INVOLVED AGENTS must review the retrospective and extract          │
│     knowledge entries relevant to THEIR domain:                            │
│                                                                             │
│     • PLANNING AGENT (e.g., Nahla) — lessons about scope estimation,      │
│       phasing decisions, requirement gaps, plan-vs-reality divergence      │
│     • REVIEWING AGENT — lessons from PR feedback, review patterns          │
│     • TESTING AGENT (e.g., Thok) — lessons about test strategy, QA gaps   │
│     • SUBAGENTS (e.g., Reno) — lessons from implementation challenges     │
│       encountered during delegated subitems                                │
│                                                                             │
│  3. Each involved agent writes knowledge entries to THEIR OWN knowledge   │
│     directory (primary + backup) and updates THEIR OWN INDEX.md           │
│                                                                             │
│  WHO COUNTS AS "INVOLVED":                                                 │
│     ✅ Agent who planned the project (created the plan document)           │
│     ✅ Agent who implemented the project (wrote the code)                  │
│     ✅ Agent who reviewed the PR                                           │
│     ✅ Agents who were delegated subitems via the Task tool                │
│     ❌ Agents who were NOT part of the project in any capacity             │
│                                                                             │
│  IMPORTANT: Not every involved agent will have knowledge to extract.       │
│  If an agent reviews the retrospective and finds nothing relevant to      │
│  their domain, that is fine — do NOT create entries just to have entries.  │
│  Only create entries when there is a genuine lesson worth preserving.      │
│                                                                             │
│  The implementing agent's retrospective subitem is NOT complete until      │
│  all involved agents have had the opportunity to review.                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**How to Run Cross-Agent Review for Subagents:**

Subagents spawned via the Task tool are ephemeral — they don't persist after returning.
To give them the opportunity to review the retrospective, the **implementing agent**
re-spawns each unique subagent type after writing the retrospective document:

```
For each unique subagent_type in the Delegation Map:

1. Spawn a Task with that subagent_type
2. Provide the full retrospective document content in the prompt
3. Tell the subagent:
   - "Review this retrospective for lessons relevant to YOUR domain"
   - "If you find genuine lessons, write knowledge entries to YOUR
     knowledge directory (primary + backup) and update YOUR INDEX.md"
   - "If nothing is relevant to your domain, reply with 'No entries —
     reviewed, nothing applicable' so I can mark you as reviewed"
   - Provide the agent's knowledge directory paths
4. Record the result in the Cross-Agent Review table
```

For **non-subagent involved parties** (planning agent, reviewer) who run in separate
terminals, the implementing agent should note their names in the Cross-Agent Review
table as "Pending" — those agents review the retrospective in their own sessions.

**Pre-Project Knowledge Review (reinforcement):** Before beginning work on any new project, agents SHOULD read both their personal `INDEX.md` and their team's `TEAM/INDEX.md`. This is specified in each agent's persona under "Knowledge Base," and is reinforced here. Use the Tag Index in both files to surface entries relevant to the current work area. This review should happen before Phase 1 (Requirements Analysis) or at the very start of implementation — not after.

**⚠️ MANDATORY: Sync Local Develop Branch Subitem**

Every code-related project MUST include a dedicated **"Sync Local Develop Branch"** subitem as the very last step. This ensures the local develop branch is fully up-to-date after the PR merges, preventing stale branch issues for subsequent work.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  REQUIRED: Every code-related project MUST have a Sync Local Develop       │
│  Branch subitem as the FINAL step                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Standard Sync Local Develop Branch Subitem:                               │
│  Title: "Sync Local Develop Branch"                                        │
│                                                                             │
│  This subitem should include:                                               │
│  • Switch to the main repo (not a worktree):                               │
│    cd <main-repo-path>                                                     │
│  • Checkout develop and pull latest:                                        │
│    git checkout develop && git pull                                        │
│  • Verify the merged PR's changes are present locally                      │
│  • If in a worktree: clean up the worktree after confirming merge:         │
│    git worktree remove <worktree-path>  (if no longer needed)              │
│  • Mark the kanban item as done:                                            │
│    source ~/dev-team/kanban-helpers.sh && kb-done                          │
│                                                                             │
│  Position: ALWAYS the LAST subitem (after Retrospective)                   │
│                                                                             │
│  ⛔ DO NOT skip this subitem — stale local branches cause merge conflicts  │
│  ⛔ DO NOT mark the task complete without syncing develop                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Ordering of Mandatory Trailing Subitems:**
```
┌─────────────────────────────────────────────────────────────────────────────┐
│  For all code-related projects, the LAST FIVE subitems must always be:    │
│                                                                             │
│  ... (implementation subitems) ...                                         │
│  N-4. Testing & Debugging                    ← Fifth-to-last (MANDATORY)  │
│  N-3. PR Creation & Test Handoff             ← Fourth-to-last (MANDATORY) │
│  N-2. QA Testing & Code Review               ← Third-to-last (MANDATORY)  │
│  N-1. Retrospective and Knowledge Capture    ← Second-to-last (MANDATORY) │
│  N.   Sync Local Develop Branch              ← Always LAST (MANDATORY)    │
│                                                                             │
│  This order ensures:                                                       │
│  • All code is tested BEFORE the PR is created                             │
│  • Lint validation passes BEFORE the PR is opened                          │
│  • The PR contains fully tested, lint-clean code                           │
│  • A formal QA testing gate validates all tests pass after PR is open      │
│  • Code reviewers receive QA-validated code ready for review               │
│  • Knowledge is captured AFTER the PR is merged and project is complete    │
│  • PR review feedback is available when writing the retrospective          │
│  • Local develop branch is fully synced after merge completes              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Project-Level Exceptions

Not all teams and projects produce code. The mandatory trailing subitems (Testing & Debugging, PR Creation & Test Handoff, QA Testing & Code Review, Retrospective and Knowledge Capture, Sync Local Develop Branch) apply **only to projects that involve code changes in a git repository**. The Retrospective and Sync subitems follow the same exception rules as Testing & PR, but even exempt projects are encouraged to include them.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   EXCEPTION RULES FOR MANDATORY SUBITEMS                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  EXCEPTION 1: Non-Code Teams                                               │
│  ─────────────────────────────────────────────────────────────────────────  │
│  Teams that do NOT maintain a code repository are EXEMPT from all five     │
│  mandatory trailing subitems (Testing, PR, QA, Retrospective, and Sync).  │
│                                                                             │
│  Exempt teams:                                                              │
│  • Command (XCMD-)  — Strategic/planning documents only, no code           │
│  • Legal (XLCP-)    — Case management, no code repository                  │
│                                                                             │
│  These teams have no codebase to test, no branches to PR, and no           │
│  CI/CD pipeline. Their deliverables are documents, plans, and strategy.    │
│                                                                             │
│  ⚠️ ENCOURAGED: Even exempt teams benefit from retrospectives. Non-code   │
│  lessons about planning, communication, and coordination are valuable.     │
│                                                                             │
│  EXCEPTION 2: Non-Code Projects on Code Teams                              │
│  ─────────────────────────────────────────────────────────────────────────  │
│  Even on teams that normally produce code, some projects are non-code:     │
│                                                                             │
│  All five subitems may be skipped when the project involves ONLY:          │
│  • Documentation updates (README, guides, ADRs)                            │
│  • Asset updates (images, strings, localization files)                     │
│  • Planning/research tasks with no code output                             │
│  • Strategic initiatives or process changes                                │
│                                                                             │
│  ⚠️ ENCOURAGED: Even for non-code projects, a Retrospective subitem is    │
│  recommended. Lessons from planning and documentation work are valuable.   │
│                                                                             │
│  EXCEPTION 3: Direct-to-Develop Changes                                    │
│  ─────────────────────────────────────────────────────────────────────────  │
│  The PR Creation & Test Handoff and QA Testing & Code Review subitems      │
│  (only) may be skipped when:                                               │
│  • Changes are minor and committed directly to develop                     │
│  • Agent is NOT in a worktree (main repo, on develop branch)              │
│  • Changes are config files, RELNOTES, or small fixes                      │
│  • Testing & Debugging subitem STILL APPLIES if code was changed          │
│  • Retrospective subitem STILL APPLIES                                     │
│  • Sync Local Develop Branch subitem STILL APPLIES                        │
│                                                                             │
│  ⚠️ NOTE: This exception does NOT exempt Testing, Retrospective, or      │
│  Sync — tested code can be committed directly, but untested code should   │
│  not. Local develop must still be synced after direct commits.            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Quick Reference — Which Subitems Does My Project Need?**

| Scenario | Testing & Debugging | PR Creation & Test Handoff | QA Testing & Code Review | Retrospective | Sync Develop |
|----------|:-------------------:|:--------------------------:|:------------------------:|:-------------:|:------------:|
| Code project on code team (worktree) | **REQUIRED** | **REQUIRED** | **REQUIRED** | **REQUIRED** | **REQUIRED** |
| Code project on code team (direct to develop) | **REQUIRED** | Skip | Skip | **REQUIRED** | **REQUIRED** |
| Non-code project on code team (docs, assets) | Skip | Skip | Skip | Encouraged | Skip |
| Command team (XCMD) — any project | Skip | Skip | Skip | Encouraged | Skip |
| Legal team (XLCP) — any project | Skip | Skip | Skip | Encouraged | Skip |
| Config-only changes (non-code) | Skip | Skip | Skip | Encouraged | Skip |
| Planning/research with no code output | Skip | Skip | Skip | Encouraged | Skip |

**Decision Flow:**

```
Is this a code-related project?
├── NO → Skip Testing, PR, QA, and Sync mandatory subitems
│         (docs, assets, planning, strategy, Command/Legal teams)
│         → Retrospective is encouraged but not required
│
└── YES → Does the team maintain a code repository?
    ├── NO → Skip Testing, PR, QA, and Sync mandatory subitems
    │         (Command/XCMD, Legal/XLCP)
    │         → Retrospective is encouraged but not required
    │
    └── YES → Will changes go through a PR?
        ├── YES → ALL FIVE subitems required
        │          (Testing + PR Handoff + QA Review + Retrospective + Sync)
        │          (worktree work, feature branches)
        │
        └── NO → Testing subitem REQUIRED, PR Handoff and QA Review skipped
                   Retrospective subitem REQUIRED
                   Sync Local Develop Branch subitem REQUIRED
                   (minor fixes direct to develop, not in worktree)
```

### Phase 5: Plan Document Creation (MANDATORY)

**⚠️ This phase is REQUIRED. Do NOT skip to the handoff checkpoint without completing this phase.**

Create a comprehensive plan document following the template below.

**Location:** `<team-kanban>/<ITEM-ID>_<10-30_char_description>.md`

⚠️ **CRITICAL: Use the correct team kanban directory based on the item prefix!**
- See [Plan Document Path Resolution](#plan-document-path-resolution) for the full mapping
- NEVER put non-Academy (non-XACA) plan docs in `~/dev-team/kanban/`

**Naming Convention:**
- Use the ITEM-ID exactly as assigned (e.g., `XACA-0031`)
- Description should be 10-30 characters, lowercase, underscores for spaces
- Determine the correct team directory from the prefix

**Examples by Team (each in their OWN kanban directory):**
- Academy: `~/dev-team/kanban/XACA-0031_dark_mode_support.md`
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
| <ITEM-ID>-00(N-4) | Testing & Debugging | todo |
| <ITEM-ID>-00(N-3) | PR Creation & Test Handoff | todo |
| <ITEM-ID>-00(N-2) | QA Testing & Code Review | todo |
| <ITEM-ID>-00(N-1) | Retrospective and Knowledge Capture | todo |
| <ITEM-ID>-00N | Sync Local Develop Branch | todo |

> ⚠️ **Note:** Testing & Debugging, PR Creation & Test Handoff, QA Testing & Code Review, Retrospective and Knowledge Capture, and Sync Local Develop Branch subitems are MANDATORY for all code-related projects.
> These five subitems must always be the last five, in this order.

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
✓ XACA-0031-008: PR Creation & Test Handoff (MANDATORY for code changes)
✓ XACA-0031-009: QA Testing & Code Review (MANDATORY for code changes)
✓ XACA-0031-010: Retrospective and Knowledge Capture (MANDATORY for code changes)
✓ XACA-0031-011: Sync Local Develop Branch (MANDATORY for code changes)

**Creating plan document...**

Resolving plan doc path for XACA-0031 → ~/dev-team/kanban/ (Academy team)

Writing ~/dev-team/kanban/XACA-0031_dark_mode_support.md with:
- Summary and requirements
- Design decisions (CSS custom properties approach)
- Files to modify (3 files identified)
- Implementation order (11 phases)
- Subitems table (11 items, including mandatory Testing, PR Handoff, QA Review, Retrospective, and Sync subitems)
- Verification checklist (5 test cases)

✓ Created ~/dev-team/kanban/XACA-0031_dark_mode_support.md

**Verifying plan document...**

✓ Plan document exists and contains all required sections

═══════════════════════════════════════════════════════════════════════════════
 PROJECT PLANNING COMPLETE - READY FOR HANDOFF
═══════════════════════════════════════════════════════════════════════════════

 Created Artifacts:
   Kanban Item:  XACA-0031 "LCARS Fleet Monitor Dark Mode"
   Subitems:     11 implementation phases
   Plan Doc:     ~/dev-team/kanban/XACA-0031_dark_mode_support.md
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
source ~/dev-team/kanban-helpers.sh && <command>
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
| `XACA-` | Academy | `~/dev-team/kanban/` |
| `XIOS-` | iOS | `/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban/` |
| `XAND-` | Android | `/Users/Shared/Development/Main Event/MainEventApp-Android/kanban/` |
| `XFIR-` | Firebase | `/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban/` |
| `XCMD-` | Command | `/Users/Shared/Development/Main Event/dev-team/kanban/` |
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
        XACA) echo "$HOME/dev-team/kanban" ;;
        XIOS) echo "/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban" ;;
        XAND) echo "/Users/Shared/Development/Main Event/MainEventApp-Android/kanban" ;;
        XFIR) echo "/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban" ;;
        XCMD) echo "/Users/Shared/Development/Main Event/dev-team/kanban" ;;
        XDNS) echo "/Users/Shared/Development/DNSFramework/kanban" ;;

        # Freelance Projects (each project has its own repo)
        XFSW) echo "/Users/Shared/Development/DoubleNode/Starwords/kanban" ;;
        XFAP) echo "/Users/Shared/Development/DoubleNode/appPlanning/kanban" ;;
        XFWS) echo "/Users/Shared/Development/DoubleNode/WorkStats/kanban" ;;

        # Legal Projects
        XLCP) echo "$HOME/legal/coparenting/kanban" ;;

        *) echo "$HOME/dev-team/kanban" ;;  # Default fallback to Academy
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
        XACA) echo "$HOME/dev-team/kanban" ;;
        XIOS) echo "/Users/Shared/Development/Main Event/MainEventApp-iOS/kanban" ;;
        XAND) echo "/Users/Shared/Development/Main Event/MainEventApp-Android/kanban" ;;
        XFIR) echo "/Users/Shared/Development/Main Event/MainEventApp-Functions/kanban" ;;
        XCMD) echo "/Users/Shared/Development/Main Event/dev-team/kanban" ;;
        XDNS) echo "/Users/Shared/Development/DNSFramework/kanban" ;;

        # Freelance Projects
        XFSW) echo "/Users/Shared/Development/DoubleNode/Starwords/kanban" ;;
        XFAP) echo "/Users/Shared/Development/DoubleNode/appPlanning/kanban" ;;
        XFWS) echo "/Users/Shared/Development/DoubleNode/WorkStats/kanban" ;;

        # Legal Projects
        XLCP) echo "$HOME/legal/coparenting/kanban" ;;

        *) echo "$HOME/dev-team/kanban" ;;
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
│  □ PR Creation & Test Handoff subitem included (unless exempt)             │
│  □ QA Testing & Code Review subitem included (unless exempt)               │
│  □ Retrospective and Knowledge Capture subitem included (unless exempt)    │
│  □ Sync Local Develop Branch subitem included (unless exempt)             │
│  □ Mandatory subitems are last five: Testing, PR Handoff, QA Review,      │
│    Retrospective, Sync (in this order)                                     │
│  □ Exceptions verified (non-code teams, non-code projects, direct-develop) │
│  □ Plan document written to CORRECT TEAM KANBAN DIRECTORY:                 │
│      XACA-* → ~/dev-team/kanban/                                           │
│      XIOS-* → .../MainEventApp-iOS/kanban/                                 │
│      XAND-* → .../MainEventApp-Android/kanban/                             │
│      XFIR-* → .../MainEventApp-Functions/kanban/                           │
│      XCMD-* → .../Main Event/dev-team/kanban/                              │
│      XDNS-* → .../DNSFramework/kanban/                                     │
│      XFSW-* → .../Starwords/kanban/                                        │
│      XFAP-* → .../appPlanning/kanban/                                      │
│      XFWS-* → .../WorkStats/kanban/                                        │
│      XLCP-* → ~/legal/coparenting/kanban/                                  │
│  □ Plan document verified (exists + has all 8 required sections)           │
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

**v1.10.0** (March 18, 2026)
- **MANDATORY Retrospective delegation prompt template** - Added explicit delegation prompt template for the "Retrospective and Knowledge Capture" subitem that agents MUST include when delegating via the Task tool
- Ensures subagents create the retrospective FILE (not just knowledge entries)
- Addresses root cause: delegation prompts previously lacked explicit retrospective file creation requirements, causing subagents to skip the mandatory retrospective document
- `kb-backlog sub done` now blocks completion if retro file is missing (enforced in kanban-helpers.sh)

**v1.9.0** (March 2, 2026)
- **Review & Test Subitem Governance** - Added protected subitem classification rules for `[Review]` and `[Test]` tagged subitems
- Agents CANNOT cancel `[Review]` or `[Test]` subitems without explicit user approval — these represent real committed work items, not optional suggestions
- Three-tier classification table added: Standard (agent can cancel with reason), Protected (requires user approval), Mandatory (requires user approval)
- Clarifies that "cancelled with a reason" is NOT equivalent to "completed" — cancellation cannot be used as a shortcut to avoid review/test work
- Section added to Critical Behavior Rules to ensure agents encounter this governance early in the skill

**v1.8.0** (February 26, 2026)
- **MANDATORY Sync Local Develop Branch subitem** - All code-related projects now require a Sync Local Develop Branch subitem as the very last step, ensuring local develop is fully up-to-date after PR merge
- **Mandatory trailing subitem ordering updated** - Now FIVE trailing subitems: Testing & Debugging, PR Creation & Test Handoff, QA Testing & Code Review, Retrospective and Knowledge Capture, Sync Local Develop Branch
- Updated ordering box, quick reference table, decision flow, example workflow (11 subitems), plan document template, and mandatory checklist to reflect five trailing subitems
- Exception rules updated: direct-to-develop changes still require Sync subitem; non-code projects exempt from Sync

**v1.7.0** (February 26, 2026)
- **MANDATORY QA Testing & Code Review subitem** - All code-related projects now require a dedicated QA Testing & Code Review subitem as a formal testing gate between PR creation and retrospective
- **Renamed "PR Creation & Review" to "PR Creation & Test Handoff"** - The PR creation subitem now focuses on creating the PR, generating the test handoff prompt, and entering the test + review monitoring loops
- **QA Testing & Code Review subitem** covers: QA tester runs unit tests, lint validation, integration tests, and validates edge cases; QA tester submits via gh-bot-test; code reviewer performs standard checklist and submits via gh-bot-review; creating agent merges on both approvals
- **Mandatory trailing subitem ordering updated** - Now FOUR trailing subitems: Testing & Debugging (fourth-to-last), PR Creation & Test Handoff (third-to-last), QA Testing & Code Review (second-to-last), Retrospective and Knowledge Capture (always last)
- Updated ordering box from three to four mandatory trailing subitems
- **Exception rules updated** - Direct-to-develop exception now skips BOTH PR Handoff AND QA Review subitems (not just PR); non-code team/project exceptions updated to reference "four" subitems
- Updated plan document template subitems table to include all four mandatory trailing subitems
- Updated example workflow to show 10 subitems (including all four mandatory trailing subitems)
- Updated Quick Reference table to include QA Testing & Code Review column
- Updated decision flow to incorporate QA Testing & Code Review requirement
- Updated quick reference checklist to include QA Testing & Code Review subitem verification

**v1.6.0** (February 20, 2026)
- **Knowledge directory migration** - Updated all knowledge path references to reflect XACA-0089 migration: knowledge directories moved from `~/dev-team/<team>/knowledge/` to `<repo-kanban>/knowledge/`. `~/.claude/knowledge/<codename>/` entries are now symlinks to primary locations — no dual-write or backup mirroring required
- **Removed backup mirror instructions** - Retrospective subitem no longer instructs agents to mirror entries to `~/.claude/knowledge/`. The symlinks created by XACA-0089 handle this automatically
- **Updated TEMPLATES path** - Template reference updated from `~/dev-team/academy/knowledge/TEMPLATES/` to `~/dev-team/kanban/knowledge/TEMPLATES/`

**v1.5.3** (February 19, 2026)
- **Security: NO SECRETS in knowledge files** - Added explicit prohibition in Retrospective subitem box: never include secrets, credentials, or PII in knowledge entries or retrospective documents
- **Corrected claude backup paths** - Fixed backup location references from `~/dev-team/claude/knowledge/` to `~/.claude/knowledge/` throughout (including version history entries and subitem box)

**v1.5.2** (February 19, 2026)
- **Retrospective document creation** - The Retrospective subitem now requires creating a project retrospective document at `<kanban-dir>/<ITEM-ID>_<desc>_RETROSPECTIVE.md` using the template at `~/dev-team/kanban/knowledge/TEMPLATES/retrospective_template.md`
- **Subagent knowledge extraction** - Retrospective subitem now explicitly covers reviewing all subagent Task outputs for "Lessons Learned" sections and extracting lessons during the retrospective step
- **Subagent prompt requirements** - Added mandatory "Lessons Learned" instruction that must be included in every subagent prompt when delegating subitems via the Task tool
- **Multi-role categorization guidance** - Retrospective subitem references Section 12 of the design doc for how to categorize subagent-sourced lessons (agent vs. team knowledge)
- **Retrospective doc knowledge table** - Added step to fill in the "Knowledge Entries Created" table in the retrospective doc after writing all entries
- Updated retrospective subitem box with new steps and prohibition line for skipping the retro doc
- References updated design document Sections 12 (Subagent Knowledge) and 13 (Retrospective Document)

**v1.5.1** (February 19, 2026)
- **Team-level knowledge categorization in Retrospective subitem** - Agents now categorize each lesson as agent-specific or team domain during the retrospective process
- Agent-specific lessons go to `<repo-kanban>/knowledge/<codename>/`; team domain lessons go to `<repo-kanban>/knowledge/TEAM/`; a single lesson CAN be written to both if it has both personal and team-wide implications
- **Claude backup updated for team entries** - Team domain entries mirror to `~/.claude/knowledge/team-<teamname>/` (not just the agent backup) (Note: as of v1.6.0, these are symlinks — no dual-write required)
- **Pre-project knowledge review reinforced** - Added explicit note that agents SHOULD read both their personal INDEX.md and the team TEAM/INDEX.md before beginning any new project
- Updated Retrospective subitem box with categorization step and new backup paths
- Updated prohibition line to cover all appropriate locations (not just "BOTH")
- References updated design document sections (Sections 10 and 11) for team knowledge and curation guidance

**v1.5.0** (February 19, 2026)
- **MANDATORY Retrospective and Knowledge Capture subitem** - All code-related projects now require a dedicated Retrospective and Knowledge Capture subitem as the final step
- Retrospective subitem covers: reviewing kanban item and git history, reviewing PR comments, writing a knowledge entry to primary knowledge dir (`<repo-kanban>/knowledge/<codename>/`), updating INDEX.md, and marking the subitem done
- References `~/dev-team/kanban/XACA-0084_knowledge_base_design.md` for full process details, file templates, and agent-to-directory mapping
- **Mandatory trailing subitem ordering updated** - Now THREE trailing subitems: Testing & Debugging (third-to-last), PR Creation & Review (second-to-last), Retrospective and Knowledge Capture (always last)
- Updated ordering box from two to three mandatory trailing subitems
- **Exception rules updated** - Retrospective follows the same exception rules as Testing & PR. Non-code teams (Command/XCMD, Legal/XLCP) and non-code projects are technically exempt. However, even exempt projects are encouraged to include retrospectives since lessons about planning and coordination are valuable regardless of whether code was produced
- Updated plan document template subitems table to include Retrospective as mandatory last subitem
- Updated example workflow to show 9 subitems (including all three mandatory trailing subitems)
- Updated quick reference checklist to include Retrospective subitem verification
- Updated Quick Reference table to include Retrospective column
- Updated decision flow to incorporate Retrospective requirement

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
