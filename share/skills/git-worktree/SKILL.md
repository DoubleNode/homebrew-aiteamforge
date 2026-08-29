---
name: git-worktree-manager
description: Manages Git worktrees for parallel development workflows. Use when creating, listing, switching between, or cleaning up worktrees for iOS/Android/Firebase projects. Automates worktree creation with context-aware naming (feature/hotfix/refactor/release/test), handles branch management, shows status across all worktrees, and safely removes stale worktrees with validation.
version: 1.0.0
author: Commander Jett Reno (Chief Technical Instructor)
company: Starfleet Academy - Engineering Lab
project: Dev Team LCARS Infrastructure
platforms:
  - iOS
  - Android
  - Firebase Backend
  - Any Git-based project
terminals:
  - All terminals (auto-detects project from context)
supported_os:
  - macOS
  - Linux
  - Windows (WSL2)
dependencies:
  - Git 2.5+
  - Claude Code
tags:
  - git
  - worktrees
  - parallel-development
  - multi-project
  - workflow-automation
last_updated: 2025-11-08
status: production-ready
model: haiku
---

# Git Worktree Manager

## Skill Metadata

**Name:** Git Worktree Manager  
**Version:** 1.0.0  
**Author:** Commander Jett Reno (Starfleet Academy)  
**Primary Terminals:** All project terminals (iOS, Android, Firebase, Academy, DNS, Freelance)  
**Platforms:** macOS, Linux, Windows (WSL2)  
**Last Updated:** November 2025

---

## Purpose

This skill manages Git worktrees for parallel development workflows across multiple terminal sessions. It automates worktree creation, cleanup, and status tracking to support the virtual dev team infrastructure where each terminal context works on its own branch in an isolated working directory.

Git worktrees allow checking out multiple branches simultaneously from the same repository into different directories. This eliminates branch switching overhead, prevents stash/unstash cycles, and enables true parallel development across feature work, bug fixes, refactoring, and releases.

---

## Core Capabilities

### 1. Worktree Creation
- **Context-aware creation:** Automatically names worktrees based on terminal context (feature, hotfix, refactor, release, test)
- **Branch management:** Creates new branches or checks out existing ones
- **Directory organization:** Follows consistent naming patterns
- **Validation:** Prevents duplicate worktrees and invalid configurations

### 2. Worktree Discovery
- **List all worktrees:** Shows all active worktrees with branch info
- **Find by context:** Locates worktrees by type (feature, hotfix, etc.)
- **Status checking:** Shows branch status, uncommitted changes, push/pull state
- **Path resolution:** Resolves absolute paths for easy terminal navigation

### 3. Worktree Cleanup
- **Safe removal:** Removes worktrees after validation
- **Batch cleanup:** Removes multiple stale worktrees
- **Pruning:** Cleans up administrative files for deleted worktrees
- **Backup prompts:** Warns about uncommitted changes before removal

### 4. Context Integration
- **Terminal mapping:** Associates worktrees with specific terminal contexts
- **Persona awareness:** Suggests appropriate worktree types per dev team member
- **Project detection:** Auto-detects iOS, Android, or Firebase project context

---

## Worktree Naming Conventions

### Base Directory Structure

Each project is a separate Git repository with its own worktrees organized in a `worktrees/` subdirectory:

```
<your-project-root>/
│
├── <ProjectName-iOS>/                   # iOS Git repository (develop branch)
│   ├── .git/                            # Git metadata
│   ├── <AppName>.xcodeproj              # Xcode project
│   ├── Sources/                         # Source code
│   ├── Tests/                           # Tests
│   ├── README_DEV.md                    # Release documentation
│   └── worktrees/                       # iOS worktrees subdirectory
│       ├── feature/                     # Feature worktree
│       ├── hotfix/                      # Hotfix worktree
│       ├── refactor/                    # Refactor worktree
│       ├── release/                     # Release worktree
│       └── test/                        # Test worktree
│
├── <ProjectName-Android>/               # Android Git repository (develop branch)
│   ├── .git/                            # Git metadata
│   ├── app/                             # Android app module
│   ├── build.gradle.kts                 # Gradle build files
│   ├── README_DEV.md                    # Release documentation
│   └── worktrees/                       # Android worktrees subdirectory
│       ├── feature/                     # Feature worktree
│       ├── hotfix/                      # Hotfix worktree
│       ├── refactor/                    # Refactor worktree
│       ├── release/                     # Release worktree
│       └── test/                        # Test worktree
│
└── <ProjectName-Functions>/             # Firebase Git repository (develop branch)
    ├── .git/                            # Git metadata
    ├── functions/                       # Cloud Functions source
    ├── firebase.json                    # Firebase config
    ├── README_DEV.md                    # Release documentation
    └── worktrees/                       # Firebase worktrees subdirectory
        ├── feature/                     # Feature worktree
        ├── hotfix/                      # Hotfix worktree
        ├── refactor/                    # Refactor worktree
        ├── release/                     # Release worktree
        └── test/                        # Test worktree
```

**Key Structure Notes:**
- Each project has its own independent Git repository
- Worktrees are stored in `[project-root]/worktrees/` subdirectory
- Worktree names are simple: `feature`, `hotfix`, `refactor`, `release`, `test`
- For multiple worktrees of same type, use descriptive names: `feature-my-thing`, `hotfix-crash-3455`

### Naming Pattern

**Format:** `[context]` or `[context]-[descriptor]`

Since worktrees are stored within each project's `worktrees/` subdirectory, the names are simpler and don't need project prefixes.

**Basic Context Names:**
- `feature` - General feature development
- `hotfix` - Critical bug fixes
- `bugfix` - Non-critical bug fixes
- `refactor` - Code refactoring
- `release` - Release preparation
- `test` - Experimental/testing
- `review` - Code review

**With Descriptors (for multiple worktrees of same type):**
- `feature-funcard-reload` - Specific feature
- `feature-MEM-445-widget` - Feature with Jira ID
- `hotfix-crash-3455` - Specific hotfix
- `refactor-force-unwraps` - Specific refactoring task

**Full Path Examples:**

**iOS Project (substitute your actual repo path):**
```
<ios-repo>/worktrees/feature/
<ios-repo>/worktrees/feature-my-feature/
<ios-repo>/worktrees/hotfix/
<ios-repo>/worktrees/hotfix-crash-3455/
<ios-repo>/worktrees/refactor-force-unwraps/
```

**Android Project:**
```
<android-repo>/worktrees/feature/
<android-repo>/worktrees/feature-rewards-compose/
<android-repo>/worktrees/hotfix/
<android-repo>/worktrees/hotfix-payment-crash/
```

**Firebase Project:**
```
<firebase-repo>/worktrees/feature/
<firebase-repo>/worktrees/feature-webhook-handler/
<firebase-repo>/worktrees/hotfix/
<firebase-repo>/worktrees/refactor-query-optimization/
```

### Branch Naming Patterns

**Feature branches:** `feature/[description]` or `feature/MEM-[ID]-[description]`
- `feature/funcard-reload`
- `feature/MEM-445-home-screen-widget`

**Hotfix branches:** `hotfix/[description]` or `hotfix/crash-[ID]`
- `hotfix/booking-crash`
- `hotfix/crash-3455`

**Bugfix branches:** `bugfix/[description]` or `bugfix/MEM-[ID]`
- `bugfix/leaderboard-sort`
- `bugfix/MEM-450-reward-display`

**Refactor branches:** `refactor/[description]`
- `refactor/force-unwraps`
- `refactor/mvvm-rewards`

**Release branches:** `release/[version]`
- `release/2.9.0`
- `release/1.6.0-rc1`

---

## Terminal Context Mappings

### iOS Team (Star Trek: TNG)

**Project Root:** `<ios-repo>/` (auto-detected from terminal name or cwd)
**Worktrees Root:** `<ios-repo>/worktrees/`

| Terminal | Location | Persona | Typical Worktree | Full Path | Branch Pattern |
|----------|----------|---------|------------------|-----------|----------------|
| **ios-bridge** | Main Bridge | Picard | `feature` | `.../worktrees/feature/` | `feature/*` |
| **ios-engineering** | Engineering | Geordi | `release` | `.../worktrees/release/` | `release/*` |
| **ios-sickbay** | Sickbay | Beverly | `hotfix` | `.../worktrees/hotfix/` | `hotfix/*` or `bugfix/*` |
| **ios-holodeck** | Holodeck | Worf/Wesley | `test` | `.../worktrees/test/` | `test/*` or `feature/*` |
| **ios-observation** | Observation Lounge | Deanna | `review` | `.../worktrees/review/` | Any (for reviewing) |
| **ios-stellar** | Stellar Cartography | Data | `refactor` | `.../worktrees/refactor/` | `refactor/*` |

### Android Team (Star Trek: TOS)

**Project Root:** `<android-repo>/` (auto-detected from terminal name or cwd)
**Worktrees Root:** `<android-repo>/worktrees/`

| Terminal | Location | Persona | Typical Worktree | Full Path | Branch Pattern |
|----------|----------|---------|------------------|-----------|----------------|
| **android-bridge** | Main Bridge | Kirk | `feature` | `.../worktrees/feature/` | `feature/*` |
| **android-engineering** | Engineering | Scotty | `release` | `.../worktrees/release/` | `release/*` |
| **android-sickbay** | Sickbay | Bones | `hotfix` | `.../worktrees/hotfix/` | `hotfix/*` or `bugfix/*` |
| **android-science-lab** | Science Lab | Spock | `refactor` | `.../worktrees/refactor/` | `refactor/*` |
| **android-communications** | Communications | Uhura | `review` | `.../worktrees/review/` | Any (for reviewing) |
| **android-briefing-room** | Briefing Room | Multiple | `test` | `.../worktrees/test/` | `test/*` |

### Firebase Team (Star Trek: DS9)

**Project Root:** `<firebase-repo>/` (auto-detected from terminal name or cwd)
**Worktrees Root:** `<firebase-repo>/worktrees/`

| Terminal | Location | Persona | Typical Worktree | Full Path | Branch Pattern |
|----------|----------|---------|------------------|-----------|----------------|
| **firebase-ops** | Operations | Sisko | `feature` | `.../worktrees/feature/` | `feature/*` |
| **firebase-engineering** | Engineering | O'Brien | `release` | `.../worktrees/release/` | `release/*` |
| **firebase-infirmary** | Infirmary | Bashir | `hotfix` | `.../worktrees/hotfix/` | `hotfix/*` or `bugfix/*` |
| **firebase-science-lab** | Science Lab | Dax | `refactor` | `.../worktrees/refactor/` | `refactor/*` |
| **firebase-security** | Security | Odo | `test` | `.../worktrees/test/` | `test/*` |
| **firebase-wardroom** | Wardroom | Kira | `review` | `.../worktrees/review/` | Any (for reviewing) |

---

## Project Detection

### Automatic Project Context Detection

The skill automatically detects which project you're working on using multiple methods:

**Detection Priority (in order):**

1. **Terminal Name Prefix**
   ```bash
   # Terminal name starts with project identifier
   ios-bridge       → iOS project
   android-sickbay  → Android project
   firebase-ops     → Firebase project
   academy-*        → Academy dev-team project
   dns-*            → DNS Framework project
   ```

2. **Current Working Directory**
   ```bash
   # If pwd contains a recognized project directory name
   git rev-parse --show-toplevel   # root of git repo
   # → Detected from terminal prefix or cwd heuristic
   ```

3. **Git Remote URL**
   ```bash
   # Check git remote origin
   git remote get-url origin
   # → Matches project by remote URL pattern
   ```

4. **Project Files**
   ```bash
   # Check for platform-specific files
   *.xcodeproj      → iOS project
   build.gradle.kts → Android project
   firebase.json    → Firebase project
   ```

5. **Explicit Override**
   ```bash
   # User can explicitly specify in command
   "Create iOS worktree for feature/my-feature"
   "Create Android worktree for hotfix"
   "Create Firebase worktree for refactor"
   ```

### Project Context Examples

**Scenario 1: In iOS terminal**
```
Terminal: ios-bridge
Location: <ios-repo>/
Command: "Create worktree for feature"

Skill detects:
✓ Terminal prefix: ios-*
✓ Working directory: <ios-repo>
✓ Project files: *.xcodeproj found
→ Project: iOS

Creates: <ios-repo>/worktrees/feature/
Branch: feature/[name]
```

**Scenario 2: In Android terminal**
```
Terminal: android-sickbay
Location: <android-repo>/
Command: "Create worktree for hotfix"

Skill detects:
✓ Terminal prefix: android-*
✓ Working directory: <android-repo>
✓ Project files: build.gradle.kts found
→ Project: Android

Creates: <android-repo>/worktrees/hotfix/
Branch: hotfix/[name]
```

**Scenario 3: In Firebase terminal**
```
Terminal: firebase-ops
Location: <firebase-repo>/
Command: "Create worktree for feature"

Skill detects:
✓ Terminal prefix: firebase-*
✓ Working directory: <firebase-repo>
✓ Project files: firebase.json found
→ Project: Firebase

Creates: <firebase-repo>/worktrees/feature/
Branch: feature/[name]
```

**Scenario 4: Ambiguous context (no terminal prefix)**
```
Terminal: my-custom-terminal
Location: /some/random/path/
Command: "Create worktree for feature"

Skill responds:
⚠️  Cannot auto-detect project. Please specify:
- "Create iOS worktree for feature"
- "Create Android worktree for feature"
- "Create Firebase worktree for feature"

Or navigate to a project directory first:
- cd <ios-repo>/
- cd <android-repo>/
- cd <firebase-repo>/
```

### Cross-Project Work

**Can you work on multiple projects simultaneously?**
Yes! Each project has its own independent worktree structure:

```
# iOS Feature Work (in ios-bridge)
cd <ios-repo>/worktrees/feature/
[Working on iOS feature]

# Android Feature Work (in android-bridge) 
cd <android-repo>/worktrees/feature/
[Working on Android feature]

# Firebase Backend Support (in firebase-ops)
cd <firebase-repo>/worktrees/feature/
[Working on Firebase backend]

All three can be in progress simultaneously!
```

### List Worktrees Across All Projects

**Command:** `"List all worktrees across all projects"`

**Output:**
```
📁 Git Worktrees - All Projects

═══════════════════════════════════════════════════
iOS Project
═══════════════════════════════════════════════════

Feature Development:
  🟢 feature
     Branch: feature/my-feature
     Status: Clean
     Path: .../worktrees/feature/
     Ahead of develop: 3 commits

Bug Fixes:
  🔴 hotfix
     Branch: hotfix/crash-3455
     Status: DIRTY (2 uncommitted files)
     Path: .../worktrees/hotfix/
     Ahead of develop: 1 commit

═══════════════════════════════════════════════════
Android Project
═══════════════════════════════════════════════════

Feature Development:
  🟢 feature
     Branch: feature/compose-refactor
     Status: Clean
     Path: .../worktrees/feature/
     Ahead of develop: 5 commits

═══════════════════════════════════════════════════
Firebase Project
═══════════════════════════════════════════════════

Feature Development:
  🟢 feature
     Branch: feature/sync-endpoint
     Status: Clean
     Path: .../worktrees/feature/
     Ahead of develop: 2 commits

Total worktrees: 4 across 3 projects
```

---

## Trigger Phrases & Commands

### Worktree Creation

**Pattern:** `"Create worktree for [context] [optional: with branch name]"`

**Examples:**

**Simple feature worktree:**
```
# In ios-bridge terminal
"Create worktree for feature"
→ Detects iOS project from terminal name
→ Creates <ios-repo>/worktrees/feature/
→ Checks out develop branch initially
→ Ready for new feature branch creation
```

**Project-specific worktree (explicit):**
```
"Create Android worktree for feature"
→ Creates <android-repo>/worktrees/feature/
→ Checks out develop branch
→ Ready for Android feature work
```

**Feature worktree with specific branch:**
```
# In ios-bridge terminal
"Create worktree for feature/my-feature"
→ Detects iOS project
→ Creates <ios-repo>/worktrees/feature-my-feature/
→ Creates new branch: feature/my-feature
→ Based on current develop branch
```

**Hotfix worktree:**
```
# In android-sickbay terminal
"Create worktree for hotfix"
→ Detects Android project
→ Creates <android-repo>/worktrees/hotfix/
→ Checks out develop branch
→ Ready for hotfix branch creation
```

**Hotfix with specific issue:**
```
# In ios-sickbay terminal
"Create worktree for hotfix/crash-3455"
→ Detects iOS project
→ Creates <ios-repo>/worktrees/hotfix-crash-3455/
→ Creates branch: hotfix/crash-3455
→ Based on develop branch
```

**Refactor worktree:**
```
# In firebase-science-lab terminal
"Create worktree for refactor/query-optimization"
→ Detects Firebase project
→ Creates <firebase-repo>/worktrees/refactor-query-optimization/
→ Creates branch: refactor/query-optimization
→ Based on develop branch
```

**Release worktree:**
```
# In android-engineering terminal
"Create worktree for release/1.6.0"
→ Detects Android project
→ Creates <android-repo>/worktrees/release/
→ Creates branch: release/1.6.0
→ Based on develop branch
```

**Context-aware creation (uses current terminal and detects project):**
```
# In ios-sickbay terminal
"Create worktree for current context"
→ Detects iOS project from terminal name
→ Detects sickbay context (bug fixes)
→ Suggests hotfix worktree
→ Creates <ios-repo>/worktrees/hotfix/
```

**Worktree from existing branch:**
```
# In android-bridge terminal
"Create worktree from existing branch feature/PROJ-445"
→ Detects Android project
→ Creates <android-repo>/worktrees/feature-PROJ-445/
→ Checks out existing feature/PROJ-445 branch
→ No new branch created
```

### Worktree Discovery

**Pattern:** `"List worktrees"` or `"Show worktrees"` or `"What worktrees exist?"`

**Examples:**

**List all worktrees:**
```
"List all worktrees"
→ Shows all worktrees with:
  - Directory path
  - Branch name
  - Status (clean/dirty)
  - Last commit
```

**Find specific context:**
```
"Show feature worktrees"
→ Lists only feature-related worktrees
```

**Status check:**
```
"Check worktree status"
→ Shows detailed status for all worktrees:
  - Uncommitted changes
  - Unpushed commits
  - Branch ahead/behind develop
```

**Find worktree by branch:**
```
"Which worktree has branch feature/funcard-reload?"
→ Returns path to worktree with that branch
```

### Worktree Cleanup

**Pattern:** `"Remove worktree [name or context]"`

**Examples:**

**Remove by directory name:**
```
"Remove worktree main-event-hotfix-crash-3455"
→ Checks for uncommitted changes
→ Prompts for confirmation
→ Removes worktree
→ Prunes Git administrative files
```

**Remove by context:**
```
"Remove hotfix worktree"
→ Identifies hotfix worktrees
→ Confirms which one to remove (if multiple)
→ Performs removal
```

**Safe removal (checks for uncommitted work):**
```
"Safely remove worktree main-event-feature"
→ Checks git status
→ If clean: removes immediately
→ If dirty: shows uncommitted changes and asks for confirmation
```

**Batch cleanup:**
```
"Clean up all test worktrees"
→ Finds all test-related worktrees
→ Shows list
→ Confirms bulk removal
→ Removes all confirmed worktrees
```

**Prune deleted worktrees:**
```
"Prune worktrees"
→ Runs git worktree prune
→ Cleans up administrative files for manually deleted worktrees
```

### Worktree Navigation

**Pattern:** `"Switch to worktree [name or context]"` or `"Go to worktree [name]"`

**Examples:**

**Switch by context:**
```
"Switch to feature worktree"
→ Provides cd command: cd ~/dev-team/main-event-feature
→ Or: directly changes directory if in tmux session
```

**Switch by branch:**
```
"Switch to worktree with branch release/2.9.0"
→ Finds worktree
→ Provides navigation command
```

### Context-Aware Suggestions

**Pattern:** `"Suggest worktree for current task"`

**Examples:**

**In ios-bridge terminal (Picard - Feature Development):**
```
"Suggest worktree setup"
→ "You're in ios-bridge (Picard - Strategic Feature Development)"
→ "Detected project: iOS"
→ "I recommend creating: <ios-repo>/worktrees/feature/"
→ "Branch pattern: feature/[ID]-[description]"
→ "Would you like me to create it?"
```

**In ios-sickbay terminal (Beverly - Bug Fixes):**
```
"Suggest worktree setup"
→ "You're in ios-sickbay (Beverly - Bug Diagnosis)"
→ "Detected project: iOS"
→ "I recommend creating: <ios-repo>/worktrees/hotfix/"
→ "Branch pattern: hotfix/crash-[ID] or bugfix/PROJ-[ID]"
→ "Would you like me to create it?"
```

### Cross-Project Coordination

**Pattern:** `"Create coordinated worktrees for [feature] across projects"`

**Examples:**

**Coordinated feature across iOS + Android + Firebase:**
```
"Create coordinated worktrees for cross-platform widget feature"

Skill responds:
→ "Creating coordinated worktrees for cross-platform feature..."

✅ iOS worktree created:
   Path: <ios-repo>/worktrees/feature-widget/
   Branch: feature/PROJ-445-widget

✅ Android worktree created:
   Path: <android-repo>/worktrees/feature-widget/
   Branch: feature/PROJ-445-widget

✅ Firebase worktree created:
   Path: <firebase-repo>/worktrees/feature-widget-sync/
   Branch: feature/PROJ-445-widget-sync-endpoint

All worktrees ready for coordinated development!

Terminal assignments:
- ios-bridge → iOS widget UI
- android-bridge → Android widget UI  
- firebase-ops → Backend sync endpoint
```

**Check status of coordinated feature:**
```
"Status of widget feature across all projects"

Skill responds:
📊 Cross-Project Feature Status: Widget

iOS:
  Branch: feature/PROJ-445-widget
  Status: Clean
  Commits ahead: 8
  Last commit: "Complete widget UI layouts"
  
Android:
  Branch: feature/PROJ-445-widget
  Status: DIRTY (1 uncommitted file)
  Commits ahead: 6
  Last commit: "Add Material You theming to widget"
  ⚠️  Uncommitted: WidgetProvider.kt
  
Firebase:
  Branch: feature/PROJ-445-widget-sync-endpoint
  Status: Clean
  Commits ahead: 4
  Last commit: "Implement real-time balance sync endpoint"

Overall: 🟡 iOS & Firebase ready, Android needs commit
```

**Cleanup coordinated worktrees:**
```
"Clean up Fun Card widget worktrees across all projects"

Skill checks each project:
✅ iOS feature merged and pushed
✅ Android feature merged and pushed
✅ Firebase feature merged and pushed

Proceed with cleanup? (yes/no)

[User confirms]

✅ Removed iOS worktree
✅ Removed Android worktree
✅ Removed Firebase worktree

All Fun Card widget worktrees cleaned up!
```

---

## Processing Rules

### Worktree Creation Rules

**Pre-Creation Validation:**

1. **Check if worktree already exists**
   - If exists: Warn and suggest alternative name
   - Offer to switch to existing instead of creating duplicate

2. **Verify base repository exists**
   - Confirm we're in a Git repository
   - Identify develop repository location
   - Check that develop repo is in good state

3. **Validate branch name**
   - Check branch naming convention matches context
   - Warn if branch name doesn't follow patterns
   - Suggest correction if needed

4. **Check available disk space**
   - Worktrees are lightweight (hard links) but still need space
   - Warn if disk space is low (<10GB available)

**Creation Process:**

1. **Determine worktree directory**
   ```bash
   # Pattern: ~/dev-team/[project]-[context]-[optional-descriptor]
   WORKTREE_DIR=~/dev-team/main-event-feature
   ```

2. **Create worktree with Git command**
   ```bash
   # For new branch:
   git worktree add -b [branch-name] [worktree-path] [base-branch]
   
   # For existing branch:
   git worktree add [worktree-path] [existing-branch]
   ```

3. **Verify creation**
   - Check worktree directory exists
   - Verify branch is checked out
   - Confirm Git status is clean

4. **Provide navigation**
   - Give user cd command
   - Suggest next steps (create feature branch, start work)

**Post-Creation Actions:**

1. **Deploy personas into the new worktree**

   Container-layout teams (iOS, Android, Firebase, DNS) gitignore `.claude/agents/`, which means a freshly created worktree has NO personas — Claude falls back to built-in agent types instead of loading `spock`, `geordi`, etc. (Originating incident: Android worktree where the `spock` refactoring persona failed to load.)

   Two paths depending on machine type — behavior is automatic on tap machines:

   **Dev machines (dev-team present):** Run immediately after `git worktree add` succeeds:

   ```bash
   kb-sync-personas sync-worktrees <team> 2>/dev/null || true
   ```

   Replace `<team>` with the team slug (`ios`, `android`, `firebase`, `dns`). The command auto-skips git-tracked-persona teams (Academy, Command, Finance, Legal) and repos with no personas, so it is always safe to run unconditionally.

   **Tap machines (`~/aiteamforge` present):** `wt-new` calls `deploy-worktree-personas.sh` automatically on every successful creation — no manual step required. The helper reads personas from `~/aiteamforge/<team>/personas/agents/` and copies them into the new worktree's `.claude/agents/`. A `.synced-from-tap` marker is written to record provenance (tap-machine equivalent of XACA-0584's `.synced-from-master`). On dev machines the helper is absent, so the guard (`-x "$_dwp"`) makes this a silent no-op.

   **Pre-existing worktrees on tap machines:** If worktrees were created before the tap was installed (or before XACA-0588), they have no personas. Backfill all of them with:

   ```bash
   deploy-worktree-personas.sh --all <team>
   ```

   This is the tap-machine equivalent of `kb-sync-personas sync-worktrees --all`. It enumerates every worktree under `<repo>/worktrees/`, skips any that already have `.synced-from-tap` (idempotent), and deploys personas into the rest. Use `--force` to refresh existing deployments. Pass the repo path explicitly if running from outside the repo.

   The deployed files are intentionally UNTRACKED — they vanish when the worktree is removed. Do NOT `git add` them; seeing them in `.claude/agents/` after creation is expected, not drift.

2. **Record worktree metadata** (optional)
   - Terminal that created it
   - Creation timestamp
   - Purpose/description
   - Associated Jira issue (if applicable)

3. **Update terminal session** (if in tmux)
   - Can automatically cd into new worktree
   - Update tmux window title with worktree name

### Worktree Discovery Rules

**Listing Algorithm:**

1. **Execute git worktree list**
   ```bash
   git worktree list --porcelain
   ```

2. **Parse output**
   - Extract worktree paths
   - Extract branch names
   - Extract HEAD commit info

3. **Enhance with status info**
   ```bash
   # For each worktree:
   cd [worktree-path]
   git status --porcelain  # Check for uncommitted changes
   git log -1 --oneline    # Get last commit
   git rev-list --left-right --count develop...HEAD  # Check ahead/behind
   ```

4. **Format output**
   - Group by context (feature, hotfix, refactor, etc.)
   - Highlight dirty worktrees (uncommitted changes)
   - Show branch relationship to develop

**Example Output Format:**

```
📁 Git Worktrees for iOS Project

Feature Development:
  🟢 feature
     Branch: feature/my-feature
     Status: Clean
     Path: <ios-repo>/worktrees/feature/
     Last commit: PROJ-445: Add widget foundation
     Ahead of develop: 3 commits

Bug Fixes:
  🔴 hotfix-crash-3455
     Branch: hotfix/crash-3455
     Status: DIRTY (2 uncommitted files)
     Path: <ios-repo>/worktrees/hotfix-crash-3455/
     Last commit: Fix force unwrap in booking flow
     Ahead of develop: 1 commit
     ⚠️  Uncommitted changes - commit before cleanup!

Refactoring:
  🟢 refactor-force-unwraps
     Branch: refactor/force-unwraps
     Status: Clean
     Path: <ios-repo>/worktrees/refactor-force-unwraps/
     Last commit: Refactor ViewController guard statements
     Ahead of develop: 8 commits

Main Repository:
  🟢 (main repo)
     Branch: develop
     Status: Clean
     Path: <ios-repo>/
```

### Worktree Cleanup Rules

**Pre-Removal Safety Checks:**

1. **Check for uncommitted changes**
   ```bash
   git -C [worktree-path] status --porcelain
   ```
   - If dirty: Warn user and show uncommitted files
   - Require explicit confirmation to proceed

2. **Check for unpushed commits**
   ```bash
   git -C [worktree-path] log origin/[branch]..HEAD
   ```
   - If unpushed commits exist: Warn user
   - Show commits that would be lost
   - Require explicit confirmation

3. **Check if branch is merged**
   ```bash
   git branch --merged develop [branch-name]
   ```
   - If not merged: Strong warning
   - Suggest merging or creating backup branch

**Removal Process:**

1. **Confirmation prompt**
   ```
   About to remove worktree: ~/dev-team/main-event-hotfix-crash-3455
   Branch: hotfix/crash-3455
   Status: Clean, 0 uncommitted changes
   
   ⚠️  WARNING: This worktree has 1 unpushed commit:
       abc1234 Fix force unwrap in booking flow
   
   Options:
   1. Cancel and push commits first (recommended)
   2. Remove anyway (commits will be lost)
   3. Create backup branch before removing
   
   Choice: _
   ```

2. **Execute removal**
   ```bash
   git worktree remove [worktree-path]
   ```
   - Or with force flag if user confirmed: `git worktree remove -f`

3. **Cleanup branch** (optional)
   ```bash
   git branch -d [branch-name]  # Safe delete (merged)
   git branch -D [branch-name]  # Force delete (unmerged)
   ```

4. **Prune administrative files**
   ```bash
   git worktree prune
   ```

**Post-Removal:**

1. **Verify removal**
   - Confirm directory no longer exists
   - Verify `git worktree list` no longer shows it

2. **Provide feedback**
   ```
   ✅ Successfully removed worktree: main-event-hotfix-crash-3455
   ✅ Deleted branch: hotfix/crash-3455
   ✅ Pruned administrative files
   
   Remaining worktrees: 3
   ```

---

## Context-Aware Behavior

### Terminal Detection

The skill detects the current terminal context to provide intelligent suggestions:

**Detection Method:**

1. **Check environment variable** (if set)
   ```bash
   echo $TERMINAL_CONTEXT
   # Returns: ios-bridge, ios-sickbay, ios-engineering, etc.
   ```

2. **Check tmux session name**
   ```bash
   tmux display-message -p '#S'
   # Returns session name like: ios-bridge
   ```

3. **Check working directory**
   ```bash
   pwd
   # If in ~/dev-team/main-event-feature → feature context
   ```

4. **Check current branch**
   ```bash
   git branch --show-current
   # feature/* → feature context
   # hotfix/* → hotfix context
   ```

### Persona-Specific Recommendations

**Bridge/Command Center (Picard, Kirk, Sisko):**
- Default: Feature development worktree
- Suggested branches: `feature/MEM-[ID]-[description]`
- Typical workflow: Strategic feature implementation

**Sickbay (Beverly, Bones, Bashir):**
- Default: Hotfix worktree
- Suggested branches: `hotfix/crash-[ID]` or `bugfix/PROJ-[ID]`
- Typical workflow: Rapid bug diagnosis and fixes

**Engineering (Geordi, Scotty, O'Brien):**
- Default: Release worktree
- Suggested branches: `release/[version]`
- Typical workflow: Release preparation and CI/CD

**Refactoring Space (Data, Spock, Dax):**
- Default: Refactor worktree
- Suggested branches: `refactor/[description]`
- Typical workflow: Systematic code improvements

**Testing/Holodeck (Worf):**
- Default: Test worktree
- Suggested branches: `test/[description]` or `feature/[description]`
- Typical workflow: Comprehensive testing and QA

**Documentation/Observation (Deanna, Uhura, Kira):**
- Default: Review worktree
- Suggested branches: Any (for reviewing others' work)
- Typical workflow: Documentation and code review

---

## Integration with Virtual Dev Team

### Automatic Worktree Suggestions

When you start a task in a specific terminal, the skill can suggest the appropriate worktree setup:

**Example in ios-bridge:**

```
You: "I need to start working on the new feature"

Skill: "You're in ios-bridge (Captain Picard - Strategic Feature Development).

I recommend setting up a feature worktree:

  Directory: <ios-repo>/worktrees/feature-my-feature/
  Branch: feature/PROJ-445-my-feature
  Based on: develop

Would you like me to create this worktree? (yes/no)"

You: "yes"

Skill: [Creates worktree]

"✅ Worktree created successfully!

To get started:
  cd <ios-repo>/worktrees/feature-my-feature/

Your feature branch 'feature/PROJ-445-my-feature' is ready.
You're now in a clean workspace isolated from other work.

Suggested next steps:
1. Create initial implementation structure
2. Commit regularly as you build the feature
3. Push to remote when ready for review

### Kanban Integration

The git-worktree skill integrates with the kanban board system to track which worktree is being used for each backlog item.

**Automatic Tracking:**
When you use `kb-pick <item-id>` or `kb-backlog sub start <subitem-id>`, the current worktree and branch are automatically captured on the item.

**Manual Linking:**
You can manually link a worktree to a backlog item without starting work:

```bash
# Link current worktree to item
kb-link-worktree XFRE-0001

# Remove the link
kb-unlink-worktree XFRE-0001
```

**Benefits:**
- See which worktree/branch each item is being worked on in the LCARS UI
- Get warnings if trying to start work in a worktree already assigned to another item
- Filter the mission queue by worktree or branch: `worktree:feature` or `branch:MEM-445`

**Example Workflow:**
```
1. Create worktree: "Create worktree for feature/MEM-445-funcard"
2. Link to backlog: kb-link-worktree XFRE-0001
3. Later, start work: kb-pick XFRE-0001
4. The item now shows the worktree badge in LCARS
5. When done: kb-done (clears the worktree link)
```

Happy coding, Captain! Make it so. 🖖"
```

### Worktree Status in Terminal Prompt

The skill can enhance bash prompts to show current worktree context:

```bash
# Example enhanced prompt
[ios-sickbay] <ios-repo>/worktrees/hotfix (hotfix/crash-3455) $

# Breakdown:
# [ios-sickbay] - Terminal context
# <ios-repo>/worktrees/hotfix - Worktree directory
# (hotfix/crash-3455) - Current branch
```

### Cross-Terminal Worktree Awareness

When switching between terminals, the skill can remind you which worktree to use:

```
You: [Switch from ios-bridge to ios-sickbay]

Skill: "Welcome to ios-sickbay, Dr. Crusher.

I notice you have a hotfix worktree available:
  <ios-repo>/worktrees/hotfix (hotfix/crash-3455)
  Last commit: 2 hours ago
  Status: Clean

Would you like to resume work there? (yes/no)

Or create a new hotfix worktree for a different issue?"
```

---

## Advanced Features

### 1. Worktree Templates

Pre-configured worktree setups for common scenarios:

**Quick Start Templates:**

```
"Create feature worktree from template"
→ Creates worktree with:
  - Standard feature branch naming
  - Initial directory structure
  - Pre-commit hooks configured
  - README.md with task checklist
```

**Emergency Hotfix Template:**

```
"Create emergency hotfix worktree for crash"
→ Creates worktree with:
  - Hotfix branch from develop
  - Links to crash logs location
  - Hotfix checklist
  - Faster review settings
```

### 2. Worktree Synchronization

Keep worktrees in sync with develop branch:

```
"Sync all worktrees with develop"
→ For each worktree:
  1. Fetch latest from origin
  2. Rebase onto develop (if safe)
  3. Report any conflicts
  4. Suggest resolution steps
```

### 3. Worktree Backups

Create safety backups before risky operations:

```
"Backup worktree main-event-feature before major refactor"
→ Creates:
  - Git branch backup: feature/funcard-reload-backup-[timestamp]
  - Stashes any uncommitted work
  - Tags current commit
  - Provides rollback instructions
```

### 4. Worktree Migration

Move worktrees to different locations:

```
"Move worktree main-event-feature to ~/dev-team/archives/"
→ Uses git worktree move command
→ Updates any configuration references
→ Verifies integrity after move
```

### 5. Worktree Health Check

Regular developtenance and diagnostics:

```
"Check worktree health"
→ For each worktree:
  ✓ Verify Git integrity
  ✓ Check for dangling references
  ✓ Identify stale worktrees (no commits in 30+ days)
  ✓ Find worktrees with merged branches
  ✓ Suggest cleanup actions
```

---

## Error Handling

### Common Errors and Solutions

**Error: Worktree already exists**
```
Error: Worktree 'main-event-feature' already exists at ~/dev-team/main-event-feature

Options:
1. Switch to existing worktree: cd ~/dev-team/main-event-feature
2. Create with different name: main-event-feature-funcard-reload
3. Remove existing and recreate (requires confirmation)

What would you like to do?
```

**Error: Branch already checked out**
```
Error: Branch 'feature/funcard-reload' is already checked out in another worktree

Currently checked out at: ~/dev-team/main-event-feature

Options:
1. Switch to that worktree instead
2. Create new branch with different name
3. Remove other worktree first (if safe)

What would you like to do?
```

**Error: Uncommitted changes prevent removal**
```
Error: Cannot remove worktree - uncommitted changes detected

Uncommitted files in ~/dev-team/main-event-hotfix:
  M  Sources/Booking/BookingViewController.swift
  A  Sources/Booking/BookingViewModelTests.swift
  ?? Sources/Booking/BookingError.swift

Options:
1. Commit changes first (recommended)
2. Stash changes: git stash
3. Force remove (WILL LOSE CHANGES)
4. Cancel removal

What would you like to do?
```

**Error: Unpushed commits**
```
Warning: Worktree has unpushed commits

Commits not pushed to origin:
  abc1234 - Fix force unwrap in booking flow
  def5678 - Add error handling to Fun Card reload

Options:
1. Push commits first: git push origin hotfix/crash-3455
2. Create backup branch before removing
3. Force remove anyway (commits will be lost on this machine)
4. Cancel removal

What would you like to do?
```

**Error: Not in a Git repository**
```
Error: Current directory is not a Git repository

To use worktrees, you must be in a Git repository.

Are you trying to:
1. Initialize a new repository here? (git init)
2. Clone an existing repository? (provide URL)
3. Navigate to an existing repository?

What would you like to do?
```

---

## Best Practices

### Worktree Lifecycle

**1. Creation:**
- Create worktrees as needed, not preemptively
- Use descriptive names that match the task
- Base on correct branch (usually develop)

**2. Active Use:**
- Keep worktrees focused on single tasks
- Commit regularly within worktree
- Push to remote to prevent data loss
- Don't accumulate too many worktrees (3-5 max recommended)

**3. Cleanup:**
- Remove worktrees when task is complete
- Merge branches before removing worktrees
- Clean up regularly (weekly review)
- Use `git worktree prune` to clean up stale references

### Recommended Workflow

**For Feature Development:**
```
1. Create worktree: "Create worktree for feature/PROJ-445-widget"
2. Work in worktree: cd <repo>/worktrees/feature-PROJ-445/
3. Commit regularly: git commit -m "Progress on widget"
4. Push to remote: git push origin feature/PROJ-445-widget
5. Create PR when ready
6. After merge: "Remove worktree feature-PROJ-445"
```

**For Hotfixes:**
```
1. Create worktree: "Create worktree for hotfix/crash-3455"
2. Fix issue quickly: cd <repo>/worktrees/hotfix-crash-3455/
3. Test fix thoroughly
4. Commit and push: git commit -m "Fix crash #3455" && git push
5. Create PR for fast-track review
6. After merge and deploy: "Remove worktree hotfix-crash-3455"
```

**For Refactoring:**
```
1. Create worktree: "Create worktree for refactor/force-unwraps"
2. Systematic refactoring: cd <repo>/worktrees/refactor-force-unwraps/
3. Commit frequently (one file or logical group at a time)
4. Push regularly to prevent data loss
5. Create PR when refactor is complete
6. After merge: "Remove worktree refactor-force-unwraps"
```

### Multi-Terminal Workflow

**Parallel Development Example:**

```
Terminal 1 (ios-bridge):
  Working directory: <ios-repo>/worktrees/feature-my-feature/
  Branch: feature/my-feature
  Task: Implementing new feature

Terminal 2 (ios-sickbay):
  Working directory: <ios-repo>/worktrees/hotfix-crash/
  Branch: hotfix/crash-3455
  Task: Fixing booking flow crash

Terminal 3 (ios-stellar):
  Working directory: <ios-repo>/worktrees/refactor-force-unwraps/
  Branch: refactor/force-unwraps
  Task: Systematic force unwrap elimination

All three can work simultaneously without interference!
No branch switching, no stashing, no conflicts.
```

---

## Platform-Specific Notes

### macOS
- Full support, native Git
- Works seamlessly with Xcode projects
- Terminal integration with tmux

### Linux
- Full support, native Git
- Excellent tmux integration
- Fast worktree operations

### Windows (WSL2)
- Full support via WSL2
- Git worktrees work in Linux subsystem
- Windows Terminal integration available
- Note: Keep worktrees within WSL2 filesystem for best performance

---

## Security Considerations

### Safe Practices

**1. Never commit sensitive data in worktrees:**
- Use .gitignore for secrets, API keys, certificates
- Each worktree respects the repository's .gitignore
- Double-check before committing credentials

**2. Protect production branches:**
- Don't create worktrees from production branches casually
- Create hotfix branches from develop, not production
- Use branch protection rules on remote

**3. Clean up thoroughly:**
- Remove worktrees when done to prevent stale data
- Don't leave uncommitted sensitive changes in worktrees
- Prune regularly to clean up references

**4. Backup important work:**
- Push work-in-progress to remote regularly
- Create backup branches before risky operations
- Use git stash or commits, not local files

---

## Skill Limitations

### What This Skill Does NOT Do

1. **Does not modify remote repositories**
   - Only creates/manages local worktrees
   - You must push/pull manually
   - Does not create branches on remote

2. **Does not resolve merge conflicts**
   - Will warn about conflicts
   - You must resolve manually
   - Can guide conflict resolution, but doesn't auto-resolve

3. **Does not backup your work automatically**
   - You must commit and push regularly
   - Skill can remind you, but doesn't force it
   - Local worktree data can be lost if not committed

4. **Does not integrate with Xcode/Android Studio directly**
   - Works at Git level only
   - You must open projects in IDE manually
   - IDE may need to re-index after worktree creation

5. **Does not manage Git configuration**
   - Assumes Git is already configured
   - Assumes remote repositories are set up
   - Assumes SSH keys or credentials are configured

### When to Use This Skill

✅ **Use when:**
- Starting work on a new feature
- Need to fix a critical bug while feature work is in progress
- Doing systematic refactoring that takes multiple days
- Preparing a release while development continues
- Want to review someone's branch without disrupting your work
- Testing experimental changes without risking develop work

❌ **Don't use for:**
- Quick one-line changes (just commit in develop repo)
- Temporary experiments (use git stash instead for <1 hour work)
- When you're new to Git (learn Git basics first)
- Very large repositories (worktrees still duplicate metadata)

---

## Example Workflows

### Example 1: Feature Development in Parallel with Bug Fixes

**Scenario:** You're building a new Fun Card feature when a critical crash is reported.

**Initial State:**
```
Terminal: ios-bridge
Location: <ios-repo>/ (develop branch)
Task: About to start new feature
```

**Step 1: Create feature worktree**
```
You: "Create worktree for feature/PROJ-445-my-feature"

Skill: 
→ Detected iOS project from terminal name (ios-bridge)
→ [Creates <ios-repo>/worktrees/feature-PROJ-445-my-feature/]

✅ Worktree created!
   Directory: <ios-repo>/worktrees/feature-PROJ-445-my-feature/
   Branch: feature/PROJ-445-my-feature (new, based on develop)
   
To start working:
   cd <ios-repo>/worktrees/feature-PROJ-445-my-feature/
```

**Step 2: Start feature work**
```
You: cd <ios-repo>/worktrees/feature-PROJ-445-my-feature/
You: [Start implementing feature, make 3 commits over 2 hours]
```

**Step 3: Critical crash reported!**
```
You: [Switch to ios-sickbay terminal]
You: "Create worktree for hotfix/crash-3455"

Skill: 
→ Detected iOS project from terminal name (ios-sickbay)
→ [Creates <ios-repo>/worktrees/hotfix-crash-3455/]

✅ Hotfix worktree ready!
   Directory: <ios-repo>/worktrees/hotfix-crash-3455/
   Branch: hotfix/crash-3455 (new, based on develop)
   
This is isolated from your feature work in worktrees/feature-PROJ-445-my-feature/.
Fix the crash here without disrupting your feature development.
```

**Step 4: Fix crash (30 minutes)**
```
You: cd <ios-repo>/worktrees/hotfix-crash-3455/
You: [Fix crash, commit, push]
You: [Create PR, get it merged]
```

**Step 5: Clean up hotfix worktree**
```
You: "Remove worktree hotfix-crash-3455"

Skill: 
⚠️  Checking safety before removal...
✅ Branch hotfix/crash-3455 is merged to develop
✅ No uncommitted changes
✅ All commits pushed to remote

Safe to remove. Proceed? (yes/no)

You: yes

Skill:
✅ Removed worktree: <ios-repo>/worktrees/hotfix-crash-3455/
✅ Deleted local branch: hotfix/crash-3455 (merged)
✅ Pruned administrative files

You can now return to your feature work!
```

**Step 6: Resume feature work**
```
You: [Switch back to ios-bridge terminal]
You: cd <ios-repo>/worktrees/feature-PROJ-445-my-feature/
You: [Continue exactly where you left off, no merge conflicts, no stashing]
```

**Result:** Fixed critical crash without disrupting feature development. No branch switching, no stashing, complete isolation.

---

### Example 2: Systematic Refactoring

**Scenario:** You need to eliminate force unwraps across the codebase while other work continues.

**Step 1: Create refactor worktree**
```
You: [In ios-stellar terminal - Data's refactoring space]
You: "Create worktree for refactor/force-unwraps"

Skill:
✅ Refactor worktree created!
   Directory: <ios-repo>/worktrees/refactor-force-unwraps/
   Branch: refactor/force-unwraps (new, based on develop)
   
Perfect for systematic refactoring, Lt. Cmdr. Data.
Fascinating how many force unwraps we can eliminate!
```

**Step 2: Systematic refactoring over several days**
```
Day 1: cd <ios-repo>/worktrees/refactor-force-unwraps/
       Refactor BookingViewController.swift
       Commit: "Refactor BookingViewController force unwraps"
       
Day 2: Refactor RewardsViewController.swift
       Commit: "Refactor RewardsViewController force unwraps"
       
Day 3: Refactor AccountManager.swift
       Commit: "Refactor AccountManager force unwraps"
       
[Continue daily, 1-2 files at a time]
```

**Step 3: Check status periodically**
```
You: "Check worktree status"

Skill:
📁 Git Worktrees for iOS Project

Refactoring:
  🟢 refactor-force-unwraps
     Branch: refactor/force-unwraps
     Status: Clean
     Path: <ios-repo>/worktrees/refactor-force-unwraps/
     Last commit: Refactor AccountManager force unwraps
     Ahead of develop: 12 commits
     📊 Force unwraps eliminated: ~85

Feature Development:
  🟢 feature-my-feature
     Branch: feature/PROJ-445-my-feature
     Status: Clean
     Path: <ios-repo>/worktrees/feature-my-feature/
     Last commit: Complete widget UI
     Ahead of develop: 8 commits

Main Repository:
  🟢 (main repo)
     Branch: develop
     Status: Clean
     Path: <ios-repo>/
```

**Step 4: Complete refactoring**
```
You: [After 2 weeks of systematic refactoring]
You: git push origin refactor/force-unwraps
You: [Create PR, get code review, merge]
```

**Step 5: Clean up**
```
You: "Remove worktree refactor-force-unwraps"

Skill:
✅ Branch refactor/force-unwraps is merged to develop
✅ Refactor complete! Excellent work, Lt. Cmdr. Data.
✅ Removed worktree
✅ Local branch deleted

📊 Final stats: 85 force unwraps eliminated across 24 files
```

---

### Example 3: Release Preparation

**Scenario:** Preparing v2.9.0 release while development continues on v2.10.0 features.

**Step 1: Create release worktree**
```
You: [In ios-engineering terminal - Geordi's release space]
You: "Create worktree for release/2.9.0"

Skill:
✅ Release worktree created!
   Directory: <ios-repo>/worktrees/release/
   Branch: release/2.9.0 (new, based on develop)
   
Release management ready, Commander La Forge.
All systems nominal!
```

**Step 2: Prepare release**
```
You: cd <ios-repo>/worktrees/release/
You: [Update version numbers, finalize release notes]
You: [Run final tests, verify build settings]
You: [Commit release preparation changes]
```

**Step 3: Feature work continues in parallel**
```
[Meanwhile, in ios-bridge terminal]
Other developer: cd <ios-repo>/worktrees/feature-v2.10/
Other developer: [Working on v2.10.0 features without affecting release]
```

**Step 4: Release to TestFlight**
```
You: [In release worktree]
You: fastlane beta
You: [Release goes to TestFlight]
You: git push origin release/2.9.0
```

**Step 5: After successful release**
```
You: "Merge release branch and clean up worktree"

Skill:
Let me help you finalize the release:

1. Merge release/2.9.0 to develop? (yes/no)
You: yes

Skill: [Executes git merge]
✅ Merged release/2.9.0 to develop

2. Tag release as v2.9.0? (yes/no)
You: yes

Skill: [Creates tag]
✅ Created tag v2.9.0

3. Push to remote? (yes/no)
You: yes

Skill: [Pushes]
✅ Pushed develop and tags to remote

4. Remove release worktree? (yes/no)
You: yes

Skill:
✅ Removed worktree: ~/dev-team/main-event-release
✅ Deleted local branch: release/2.9.0 (merged)

🎉 Release v2.9.0 complete!
   Tagged, merged, and pushed to remote.
   Release worktree cleaned up.
```

---

## Terminal Integration Examples

### Bash Prompt Integration

Add to `~/.bashrc` or terminal-specific config:

```bash
# Function to show current worktree context
git_worktree_info() {
    if git rev-parse --git-dir > /dev/null 2>&1; then
        local worktree_path=$(git rev-parse --show-toplevel)
        local worktree_name=$(basename "$worktree_path")
        local branch=$(git branch --show-current)
        
        # Color code by worktree type
        local color=""
        case "$worktree_name" in
            *feature*) color="\[\033[0;32m\]" ;;  # Green
            *hotfix*) color="\[\033[0;31m\]" ;;   # Red
            *refactor*) color="\[\033[0;33m\]" ;; # Yellow
            *release*) color="\[\033[0;34m\]" ;;  # Blue
            *) color="\[\033[0;37m\]" ;;          # White
        esac
        
        echo -e "${color}[${worktree_name}]($branch)\[\033[0m\]"
    fi
}

# Add to PS1
PS1='$(git_worktree_info) \w $ '
```

### Tmux Integration

Add to `~/.tmux.conf`:

```bash
# Show worktree info in tmux status bar
set -g status-right '#(cd #{pane_current_path}; git rev-parse --show-toplevel 2>/dev/null | xargs basename) | %H:%M'
```

---

## Troubleshooting Guide

### Issue: "fatal: 'path' is already registered"

**Cause:** Worktree administrative files exist but directory was manually deleted

**Solution:**
```
"Prune worktrees"
→ Runs: git worktree prune
→ Cleans up orphaned references
→ Retry worktree creation
```

### Issue: Worktree creation fails with permission error

**Cause:** Directory already exists or permission issue

**Solution:**
```bash
# Check if directory exists
ls -la ~/dev-team/main-event-feature

# If exists and empty, remove it
rm -rf ~/dev-team/main-event-feature

# If permission issue
sudo chown -R $USER ~/dev-team

# Retry creation
"Create worktree for feature"
```

### Issue: Can't remove worktree - locked

**Cause:** Worktree is being used by another process (IDE, build system)

**Solution:**
```
1. Close Xcode/Android Studio projects in that worktree
2. Stop any running build processes
3. Check tmux sessions: tmux list-sessions
4. Kill any processes using the directory
5. Retry removal: "Remove worktree [name]"
6. If still locked: "Force remove worktree [name]"
```

### Issue: Worktree shows dirty but no files changed

**Cause:** File system timestamp issues or .DS_Store files

**Solution:**
```bash
# Check actual status
cd ~/dev-team/main-event-feature
git status

# Often it's just .DS_Store on macOS
git status --ignored

# Add to .gitignore if needed
echo ".DS_Store" >> .gitignore

# Clean up
git clean -fd
```

---

## Version History

**v1.0.0** (November 2025)
- Initial skill release
- Worktree creation, discovery, cleanup
- Terminal context integration
- iOS, Android, Firebase support
- Cross-platform support (macOS, Linux, Windows WSL2)
- Virtual dev team persona integration

---

## Future Enhancements (Planned)

**v1.1.0** (Future)
- Automatic worktree creation on task assignment
- Integration with Jira for automatic branch naming
- Worktree templates with pre-configured structure
- Visual worktree map/diagram generator
- Worktree usage analytics (time spent, commits per worktree)

**v1.2.0** (Future)
- Worktree sharing between team members
- Remote worktree synchronization
- Worktree snapshots and restore
- Advanced conflict detection before creation
- IDE project files auto-generation per worktree

---

## Support & Feedback

**Skill Author:** Commander Jett Reno (Chief Technical Instructor)  
**Company:** Starfleet Academy - Engineering Lab  
**Team:** Academy Dev Team Infrastructure  
**Last Updated:** November 2025

**Feedback Welcome:**
- Feature requests
- Bug reports
- Workflow suggestions
- Integration ideas
- Documentation improvements

---

**End of Skill Definition**
