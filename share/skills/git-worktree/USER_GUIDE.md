# Git Worktree Manager - User Guide

## Table of Contents

1. [Introduction](#introduction)
2. [Quick Start](#quick-start)
3. [How It Works](#how-it-works)
4. [Installation & Setup](#installation--setup)
5. [Basic Usage](#basic-usage)
6. [Advanced Features](#advanced-features)
7. [Terminal Integration](#terminal-integration)
8. [Troubleshooting](#troubleshooting)
9. [Best Practices](#best-practices)
10. [FAQ](#faq)

---

## Introduction

### What is Git Worktree Manager?

Git Worktree Manager is a Claude Code skill that automates the creation, management, and cleanup of Git worktrees across your Main Event mobile development projects (iOS, Android, and Firebase). It enables true parallel development by letting you work on features, hotfixes, refactoring, and releases simultaneously without branch switching or stashing.

### Why Use This Skill?

**Without Worktrees:**
```bash
# Working on feature
git add .
git commit -m "WIP feature"

# Critical bug reported!
git stash
git checkout main
git checkout -b hotfix/crash-3455
# Fix bug...
git checkout feature-branch
git stash pop
# Resume feature work
```

**With Worktrees (via this skill):**
```bash
# Working on feature in ios-bridge terminal
cd MainEventApp-iOS/worktrees/feature/

# Critical bug reported! Switch to ios-sickbay terminal
"Create worktree for hotfix/crash-3455"
cd MainEventApp-iOS/worktrees/hotfix-crash-3455/
# Fix bug (feature work untouched)

# Done! Switch back to ios-bridge
cd MainEventApp-iOS/worktrees/feature/
# Continue exactly where you left off
```

### Key Benefits

✅ **Zero Branch Switching** - Each worktree is a separate working directory  
✅ **No Stashing** - Work in progress stays in place  
✅ **Parallel Development** - Work on feature + hotfix + refactor simultaneously  
✅ **Context Isolation** - Bug fixes don't pollute feature branches  
✅ **Multi-Project Support** - Manages iOS, Android, Firebase independently  
✅ **Terminal-Aware** - Auto-detects project from terminal name  
✅ **Safety First** - Prevents accidental data loss with pre-cleanup checks  

---

## Quick Start

### Prerequisites

- Git 2.5+ installed
- Claude Code configured
- One or more Main Event projects:
  - `/Users/Shared/development/Main Event/MainEventApp-iOS/`
  - `/Users/Shared/development/Main Event/MainEventApp-Android/`
  - `/Users/Shared/development/Main Event/MainEventApp-Functions/`

### 5-Minute Quickstart

**1. Create your first worktree:**
```
# In ios-bridge terminal (or any iOS terminal)
cd /Users/Shared/development/Main Event/MainEventApp-iOS/

"Create worktree for feature"
```

**2. Navigate to the worktree:**
```bash
cd worktrees/feature/
```

**3. Create a feature branch and start working:**
```bash
git checkout -b feature/my-awesome-feature
# Start coding!
```

**4. When done, clean up:**
```
"Remove worktree feature"
```

That's it! You've just created and cleaned up your first worktree.

---

## How It Works

### Automatic Project Detection

The skill automatically detects which project you're working on using these methods (in order):

1. **Terminal Name Prefix**
   - `ios-*` terminals → iOS project
   - `android-*` terminals → Android project
   - `firebase-*` terminals → Firebase project

2. **Working Directory**
   - If `pwd` contains `MainEventApp-iOS` → iOS project
   - If `pwd` contains `MainEventApp-Android` → Android project
   - If `pwd` contains `MainEventApp-Functions` → Firebase project

3. **Git Remote URL**
   - Checks `git remote get-url origin` for project identifier

4. **Project Files**
   - Finds `MainEventApp.xcodeproj` → iOS project
   - Finds `build.gradle.kts` → Android project
   - Finds `firebase.json` → Firebase project

5. **Explicit Override**
   - You can specify: `"Create iOS worktree for feature"`

### Worktree Storage Structure

Each project stores its worktrees in a `worktrees/` subdirectory:

```
MainEventApp-iOS/
├── .git/                    # Git repository
├── Sources/                 # Source code (main branch)
├── MainEventApp.xcodeproj   # Xcode project
└── worktrees/               # Worktrees directory
    ├── feature/             # Feature development
    ├── hotfix/              # Bug fixes
    ├── refactor/            # Code refactoring
    ├── release/             # Release preparation
    └── test/                # Testing/experiments
```

### Context-Aware Suggestions

The skill knows which terminal you're in and suggests appropriate worktree types:

| Terminal | Context | Suggested Worktree | Typical Use |
|----------|---------|-------------------|-------------|
| **ios-bridge** | Strategic Planning | `feature` | New feature development |
| **ios-sickbay** | Bug Fixes | `hotfix` | Critical bug fixes |
| **ios-stellar** | Refactoring | `refactor` | Code cleanup |
| **ios-engineering** | Release | `release` | Release preparation |
| **ios-holodeck** | Testing | `test` | Experiments, QA |

---

## Installation & Setup

### Step 1: Verify Git Version

```bash
git --version
# Should be 2.5.0 or higher
```

### Step 2: Install the Skill

1. Download `Git_Worktree_Manager_SKILL.md`
2. Save to your skills directory:
   ```bash
   mkdir -p ~/dev-team/skills/
   cp Git_Worktree_Manager_SKILL.md ~/dev-team/skills/
   ```

3. Reference it in Claude Code:
   ```bash
   # In any terminal with Claude Code
   "Read the Git Worktree Manager skill from ~/dev-team/skills/"
   ```

### Step 3: Create Worktrees Directory (Optional)

The skill will create the `worktrees/` directory automatically, but you can pre-create it:

```bash
# For each project
mkdir -p /Users/Shared/development/Main\ Event/MainEventApp-iOS/worktrees
mkdir -p /Users/Shared/development/Main\ Event/MainEventApp-Android/worktrees
mkdir -p /Users/Shared/development/Main\ Event/MainEventApp-Functions/worktrees
```

### Step 4: Test Installation

```bash
# Navigate to a project
cd /Users/Shared/development/Main\ Event/MainEventApp-iOS/

# In Claude Code, test the skill
"List all worktrees"

# Should see: "No worktrees found" (or list existing ones)
```

---

## Basic Usage

### Creating Worktrees

#### Simple Context Worktree

**Command:** `"Create worktree for [context]"`

**Examples:**
```
"Create worktree for feature"
"Create worktree for hotfix"
"Create worktree for refactor"
"Create worktree for release"
"Create worktree for test"
```

**Result:**
- Creates `worktrees/feature/` (or hotfix, refactor, etc.)
- Checks out `main` branch
- Ready for you to create a feature branch

#### Worktree with Specific Branch

**Command:** `"Create worktree for [branch-name]"`

**Examples:**
```
"Create worktree for feature/funcard-reload"
"Create worktree for hotfix/crash-3455"
"Create worktree for refactor/force-unwraps"
"Create worktree for release/2.9.0"
```

**Result:**
- Creates `worktrees/feature-funcard-reload/` (descriptive name)
- Creates new branch `feature/funcard-reload`
- Based on `main` branch
- Ready to start work immediately

#### Worktree from Existing Branch

**Command:** `"Create worktree from existing branch [branch-name]"`

**Example:**
```
"Create worktree from existing branch feature/MEM-445"
```

**Result:**
- Creates `worktrees/feature-MEM-445/`
- Checks out existing `feature/MEM-445` branch (doesn't create new branch)
- Useful for reviewing someone else's work or resuming old work

### Listing Worktrees

#### List Current Project's Worktrees

**Command:** `"List worktrees"` or `"Show worktrees"`

**Output:**
```
📁 Git Worktrees for MainEventApp-iOS

Feature Development:
  🟢 feature
     Branch: feature/funcard-reload
     Status: Clean
     Path: .../MainEventApp-iOS/worktrees/feature/
     Ahead of main: 3 commits

Bug Fixes:
  🔴 hotfix-crash-3455
     Branch: hotfix/crash-3455
     Status: DIRTY (2 uncommitted files)
     Path: .../MainEventApp-iOS/worktrees/hotfix-crash-3455/
     Ahead of main: 1 commit
     ⚠️  Uncommitted changes - commit before cleanup!
```

#### List All Projects' Worktrees

**Command:** `"List all worktrees across all projects"`

**Output:**
Shows worktrees for iOS, Android, and Firebase projects in one view.

#### Check Worktree Status

**Command:** `"Check worktree status"`

**Output:**
Detailed status including:
- Uncommitted changes
- Unpushed commits
- Branch ahead/behind main
- Last commit message

### Removing Worktrees

#### Safe Removal (Recommended)

**Command:** `"Remove worktree [name]"`

**Examples:**
```
"Remove worktree feature"
"Remove worktree hotfix-crash-3455"
"Remove worktree refactor-force-unwraps"
```

**Safety Checks:**
1. ✅ Checks for uncommitted changes
2. ✅ Checks for unpushed commits
3. ✅ Checks if branch is merged to main
4. ✅ Prompts for confirmation if issues found
5. ✅ Offers to create backup branch if needed

**Example Safety Prompt:**
```
⚠️  Checking safety before removal...

Found issues:
- 2 uncommitted files
- 1 unpushed commit

Options:
1. Cancel and commit/push first (recommended)
2. Create backup branch before removing
3. Force remove (WILL LOSE CHANGES)

What would you like to do?
```

#### Batch Cleanup

**Command:** `"Clean up all [context] worktrees"`

**Example:**
```
"Clean up all test worktrees"
```

**Result:**
- Finds all test-related worktrees
- Shows list for confirmation
- Removes all confirmed worktrees

#### Prune Deleted Worktrees

**Command:** `"Prune worktrees"`

**Use Case:** Cleans up Git administrative files for worktrees that were manually deleted (outside of the skill).

```
git worktree prune
```

---

## Advanced Features

### Cross-Project Coordination

#### Create Coordinated Worktrees

**Command:** `"Create coordinated worktrees for [feature-name]"`

**Example:**
```
"Create coordinated worktrees for Fun Card widget feature"
```

**Result:**
Creates matching worktrees across all three projects:
- `MainEventApp-iOS/worktrees/feature-funcard-widget/`
- `MainEventApp-Android/worktrees/feature-funcard-widget/`
- `MainEventApp-Functions/worktrees/feature-funcard-sync/`

All with appropriate branch names (same feature ID).

#### Check Cross-Project Status

**Command:** `"Status of [feature-name] across all projects"`

**Example:**
```
"Status of Fun Card widget feature across all projects"
```

**Output:**
```
📊 Cross-Project Feature Status: Fun Card Widget

iOS: Clean, 8 commits ahead
Android: DIRTY (1 uncommitted file), 6 commits ahead
Firebase: Clean, 4 commits ahead

Overall: 🟡 iOS & Firebase ready, Android needs commit
```

#### Cleanup Coordinated Worktrees

**Command:** `"Clean up [feature-name] worktrees across all projects"`

**Example:**
```
"Clean up Fun Card widget worktrees across all projects"
```

**Result:**
Safely removes worktrees from all three projects after checking each one.

### Context-Aware Suggestions

**Command:** `"Suggest worktree for current task"`

**Example in ios-sickbay:**
```
You: "Suggest worktree setup"

Skill: "You're in ios-sickbay (Beverly - Bug Diagnosis)"
       "Detected project: iOS (MainEventApp-iOS)"
       "I recommend creating: .../MainEventApp-iOS/worktrees/hotfix"
       "Branch pattern: hotfix/crash-[ID] or bugfix/MEM-[ID]"
       "Would you like me to create it?"
```

### Worktree Navigation

**Command:** `"Switch to worktree [name]"` or `"Go to worktree [name]"`

**Example:**
```
"Switch to feature worktree"
```

**Result:**
Provides the `cd` command to navigate there:
```
To switch to feature worktree:
  cd /Users/Shared/development/Main Event/MainEventApp-iOS/worktrees/feature/
```

---

## Terminal Integration

### Terminal-Specific Defaults

The skill knows which terminal you're in and suggests appropriate worktree types:

**iOS Terminals:**
- `ios-bridge` (Picard) → `feature` worktrees
- `ios-sickbay` (Beverly) → `hotfix` worktrees
- `ios-stellar` (Data) → `refactor` worktrees
- `ios-engineering` (Geordi) → `release` worktrees
- `ios-holodeck` (Worf/Wesley) → `test` worktrees
- `ios-observation` (Deanna) → `review` worktrees

**Android Terminals:**
- `android-bridge` (Kirk) → `feature` worktrees
- `android-sickbay` (Bones) → `hotfix` worktrees
- `android-science-lab` (Spock) → `refactor` worktrees
- `android-engineering` (Scotty) → `release` worktrees
- `android-briefing-room` → `test` worktrees
- `android-communications` (Uhura) → `review` worktrees

**Firebase Terminals:**
- `firebase-ops` (Sisko) → `feature` worktrees
- `firebase-infirmary` (Bashir) → `hotfix` worktrees
- `firebase-science-lab` (Dax) → `refactor` worktrees
- `firebase-engineering` (O'Brien) → `release` worktrees
- `firebase-security` (Odo) → `test` worktrees
- `firebase-wardroom` (Kira) → `review` worktrees

### Enhanced Bash Prompt (Optional)

Add worktree info to your bash prompt:

```bash
# Add to ~/.bashrc or terminal-specific config
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

**Result:**
```
[feature](feature/funcard-reload) ~/MainEventApp-iOS/worktrees/feature $
```

---

## Troubleshooting

### Common Issues

#### Issue: "Worktree already exists"

**Error:**
```
Error: Worktree 'feature' already exists at .../worktrees/feature/
```

**Solutions:**
1. **Switch to existing worktree:**
   ```
   cd worktrees/feature/
   ```

2. **Create with different name:**
   ```
   "Create worktree for feature/my-specific-feature"
   ```

3. **Remove existing first (if safe):**
   ```
   "Remove worktree feature"
   ```

#### Issue: "Branch already checked out"

**Error:**
```
Error: Branch 'feature/funcard-reload' is already checked out in another worktree
```

**Cause:** Git doesn't allow the same branch in multiple worktrees (safety feature).

**Solutions:**
1. **Switch to that worktree:**
   ```
   "Which worktree has branch feature/funcard-reload?"
   cd [shown path]
   ```

2. **Create new branch with different name:**
   ```
   "Create worktree for feature/funcard-reload-v2"
   ```

#### Issue: "Cannot remove worktree - uncommitted changes"

**Error:**
```
Error: Cannot remove worktree - uncommitted changes detected

Uncommitted files:
  M  Sources/Booking/BookingViewController.swift
  A  Sources/Booking/BookingViewModelTests.swift
```

**Solutions:**
1. **Commit changes first (recommended):**
   ```bash
   cd worktrees/hotfix/
   git add .
   git commit -m "Fix booking crash"
   git push
   # Then remove worktree
   ```

2. **Stash changes:**
   ```bash
   cd worktrees/hotfix/
   git stash
   # Then remove worktree
   # Later: git stash pop in main repo
   ```

3. **Force remove (DANGER - WILL LOSE CHANGES):**
   ```
   "Force remove worktree hotfix"
   ```

#### Issue: "Worktree shows dirty but no files changed"

**Cause:** Usually `.DS_Store` files on macOS.

**Solution:**
```bash
cd worktrees/feature/
git status --ignored

# Add .DS_Store to .gitignore
echo ".DS_Store" >> .gitignore
git add .gitignore
git commit -m "Ignore .DS_Store files"
```

#### Issue: "fatal: 'path' is already registered"

**Cause:** Worktree administrative files exist but directory was manually deleted.

**Solution:**
```
"Prune worktrees"
```

This runs `git worktree prune` to clean up orphaned references.

#### Issue: "Cannot detect project"

**Error:**
```
⚠️  Cannot auto-detect project. Please specify:
- "Create iOS worktree for feature"
- "Create Android worktree for feature"
- "Create Firebase worktree for feature"
```

**Cause:** You're not in a project directory and terminal name doesn't indicate project.

**Solution:**
1. **Navigate to project first:**
   ```bash
   cd /Users/Shared/development/Main\ Event/MainEventApp-iOS/
   "Create worktree for feature"
   ```

2. **Or specify explicitly:**
   ```
   "Create iOS worktree for feature"
   ```

---

## Best Practices

### Worktree Lifecycle

**1. Creation:**
- Create worktrees as needed, not preemptively
- Use descriptive names for multiple worktrees of same type
- Base on correct branch (usually `main`)

**2. Active Use:**
- Keep worktrees focused on single tasks
- Commit regularly within worktree
- Push to remote to prevent data loss
- Don't accumulate too many worktrees (3-5 max recommended per project)

**3. Cleanup:**
- Remove worktrees when task is complete
- Merge branches before removing worktrees
- Clean up regularly (weekly review)
- Use `git worktree prune` to clean up stale references

### Recommended Workflows

#### For Feature Development
```
1. Create worktree: "Create worktree for feature/MEM-445-widget"
2. Work in worktree: cd worktrees/feature-MEM-445-widget/
3. Commit regularly: git commit -m "Progress on widget"
4. Push to remote: git push origin feature/MEM-445-widget
5. Create PR when ready
6. After merge: "Remove worktree feature-MEM-445-widget"
```

#### For Hotfixes
```
1. Create worktree: "Create worktree for hotfix/crash-3455"
2. Fix issue quickly: cd worktrees/hotfix-crash-3455/
3. Test fix thoroughly
4. Commit and push: git commit -m "Fix crash #3455" && git push
5. Create PR for fast-track review
6. After merge and deploy: "Remove worktree hotfix-crash-3455"
```

#### For Refactoring
```
1. Create worktree: "Create worktree for refactor/force-unwraps"
2. Systematic refactoring: cd worktrees/refactor-force-unwraps/
3. Commit frequently (one file or logical group at a time)
4. Push regularly to prevent data loss
5. Create PR when refactor is complete
6. After merge: "Remove worktree refactor-force-unwraps"
```

### Multi-Terminal Workflow

**Parallel Development Example:**

```
Terminal 1 (ios-bridge):
  Working directory: ~/MainEventApp-iOS/worktrees/feature/
  Branch: feature/funcard-reload
  Task: Implementing Fun Card reload feature

Terminal 2 (ios-sickbay):
  Working directory: ~/MainEventApp-iOS/worktrees/hotfix/
  Branch: hotfix/crash-3455
  Task: Fixing booking flow crash

Terminal 3 (ios-stellar):
  Working directory: ~/MainEventApp-iOS/worktrees/refactor/
  Branch: refactor/force-unwraps
  Task: Systematic force unwrap elimination

All three can work simultaneously without interference!
No branch switching, no stashing, no conflicts.
```

### When to Use Worktrees

✅ **Use worktrees when:**
- Starting work on a new feature
- Need to fix a critical bug while feature work is in progress
- Doing systematic refactoring that takes multiple days
- Preparing a release while development continues
- Want to review someone's branch without disrupting your work
- Testing experimental changes without risking main work

❌ **Don't use worktrees for:**
- Quick one-line changes (just commit in main repo)
- Temporary experiments (use `git stash` instead for <1 hour work)
- When you're new to Git (learn Git basics first)
- Very large repositories (worktrees still duplicate metadata)

### Worktree Limits

**Recommended maximum per project:**
- **3-5 worktrees** per project is optimal
- More than 5 becomes hard to track
- Each worktree uses ~50-100MB of disk space (Git metadata + working files)

**If you have too many:**
```
"List worktrees"
# Review the list
"Remove worktree [old-one]"
"Remove worktree [another-old-one]"
```

---

## FAQ

### Q: Do worktrees share Git history?

**A:** Yes! All worktrees share the same `.git` directory. Commits, tags, branches, and remotes are synchronized across all worktrees. This means:
- Commits in one worktree are immediately visible in others
- Pushing from any worktree updates the remote for all
- Minimal extra disk space (uses hard links)

### Q: Can I have the same branch in multiple worktrees?

**A:** No, Git prevents this for safety. Each branch can only be checked out in one worktree at a time. This prevents conflicting changes.

### Q: What happens if I manually delete a worktree directory?

**A:** Git will still think the worktree exists. Run `"Prune worktrees"` to clean up the orphaned references.

### Q: Can I use worktrees with Xcode/Android Studio?

**A:** Yes! Each worktree is a complete working directory. Just open the project from the worktree directory:
- **Xcode:** Open `worktrees/feature/MainEventApp.xcodeproj`
- **Android Studio:** Open `worktrees/feature/` directory

The IDE will index the worktree separately.

### Q: Do worktrees work with Git submodules?

**A:** Yes, but submodules are shared across all worktrees. Changes to submodules affect all worktrees.

### Q: Can I use worktrees on Windows?

**A:** Yes! Via WSL2. Install Git in WSL2, and keep worktrees within the WSL2 filesystem for best performance.

### Q: How do I back up my worktrees?

**A:** Worktrees are just branches. As long as you:
1. Commit your work: `git commit`
2. Push to remote: `git push`

Your work is backed up. The worktree directory itself is just a working copy.

### Q: Can multiple developers share worktrees?

**A:** No, worktrees are local to your machine. But multiple developers can:
- Share branches (push/pull)
- Use the same worktree organization strategy
- Coordinate on feature names

### Q: Does this work with Git LFS?

**A:** Yes, Git LFS works normally with worktrees.

### Q: Can I move a worktree to a different location?

**A:** Yes! Use `git worktree move`:
```bash
git worktree move worktrees/feature worktrees/feature-backup
```

Or let the skill do it:
```
"Move worktree feature to feature-backup"
```

### Q: What if I lose track of which worktree has which branch?

**A:** Run:
```
"List all worktrees"
```

This shows all worktrees with their current branches.

### Q: Can I use worktrees for code review?

**A:** Absolutely! Create a `review` worktree:
```
"Create worktree from existing branch feature/teammates-pr"
cd worktrees/review/
# Review code, test, provide feedback
# When done:
"Remove worktree review"
```

### Q: Do worktrees slow down Git operations?

**A:** No. Git operations (commit, push, pull) perform the same regardless of how many worktrees you have. Each worktree is independent.

### Q: Can I use this with Git hooks?

**A:** Yes! Git hooks are shared across all worktrees (they live in `.git/hooks/`). Pre-commit hooks will run in every worktree.

---

## Getting Help

### Skill Commands for Help

```
"Help with worktrees"
"Show worktree examples"
"Troubleshoot worktree issue"
```

### Manual Git Worktree Commands

If you need to use Git directly:

```bash
# List worktrees
git worktree list

# Add worktree manually
git worktree add -b branch-name path/to/worktree base-branch

# Remove worktree manually
git worktree remove path/to/worktree

# Prune stale worktrees
git worktree prune
```

### Additional Resources

- **Git Worktree Docs:** https://git-scm.com/docs/git-worktree
- **Skill Author:** Darren Ehlers (Dave & Buster's Entertainment)
- **Last Updated:** November 2025

---

## Appendix: Directory Structure Reference

### Complete Example Structure

```
/Users/Shared/development/Main Event/
│
├── MainEventApp-iOS/                    # iOS Git repository
│   ├── .git/                            # Shared Git metadata
│   ├── MainEventApp.xcodeproj
│   ├── Sources/                         # Main branch source
│   ├── Tests/
│   ├── README_DEV.md
│   └── worktrees/                       # iOS worktrees
│       ├── feature/
│       │   ├── Sources/                 # Separate working copy
│       │   ├── Tests/
│       │   └── [... full project ...]
│       ├── feature-funcard-reload/
│       ├── hotfix/
│       ├── hotfix-crash-3455/
│       ├── refactor/
│       ├── release/
│       └── test/
│
├── MainEventApp-Android/                # Android Git repository
│   ├── .git/
│   ├── app/
│   ├── build.gradle.kts
│   └── worktrees/                       # Android worktrees
│       ├── feature/
│       ├── hotfix/
│       └── refactor/
│
└── MainEventApp-Functions/              # Firebase Git repository
    ├── .git/
    ├── functions/
    ├── firebase.json
    └── worktrees/                       # Firebase worktrees
        ├── feature/
        └── hotfix/
```

---

**End of User Guide**

For quick reference, see: `Git_Worktree_Manager_QUICK_REFERENCE.md`
