# Git Worktree Manager - Quick Reference

**Version:** 1.0.0 | **Author:** Darren Ehlers | **Date:** November 2025

---

## 🚀 Quick Start

```bash
# 1. Navigate to project
cd /Users/Shared/development/Main\ Event/MainEventApp-iOS/

# 2. Create worktree (in Claude Code)
"Create worktree for feature"

# 3. Navigate and work
cd worktrees/feature/
git checkout -b feature/my-feature
# ... code ...

# 4. Clean up when done
"Remove worktree feature"
```

---

## 📁 Directory Structure

```
MainEventApp-iOS/
├── .git/                    # Shared Git metadata
├── [source files]           # Main branch
└── worktrees/               # Worktrees here
    ├── feature/
    ├── hotfix/
    ├── refactor/
    ├── release/
    └── test/
```

---

## 🎯 Common Commands

### Create Worktrees

| Command | Result |
|---------|--------|
| `"Create worktree for feature"` | Creates `worktrees/feature/` on `main` |
| `"Create worktree for hotfix"` | Creates `worktrees/hotfix/` on `main` |
| `"Create worktree for feature/funcard-reload"` | Creates `worktrees/feature-funcard-reload/` with new branch |
| `"Create worktree for hotfix/crash-3455"` | Creates `worktrees/hotfix-crash-3455/` with new branch |
| `"Create worktree from existing branch feature/MEM-445"` | Checks out existing branch |

### List & Status

| Command | Result |
|---------|--------|
| `"List worktrees"` | Shows all worktrees in current project |
| `"List all worktrees across all projects"` | Shows iOS + Android + Firebase |
| `"Check worktree status"` | Detailed status (commits, changes, etc.) |
| `"Which worktree has branch feature/X?"` | Finds worktree by branch name |

### Remove & Cleanup

| Command | Result |
|---------|--------|
| `"Remove worktree feature"` | Safely removes with checks |
| `"Remove worktree hotfix-crash-3455"` | Removes specific worktree |
| `"Clean up all test worktrees"` | Batch removal |
| `"Prune worktrees"` | Cleans up orphaned references |

### Cross-Project

| Command | Result |
|---------|--------|
| `"Create coordinated worktrees for Fun Card widget"` | Creates on iOS + Android + Firebase |
| `"Status of Fun Card widget across all projects"` | Cross-project status check |
| `"Clean up Fun Card widget worktrees across all projects"` | Cross-project cleanup |

### Navigation & Help

| Command | Result |
|---------|--------|
| `"Switch to feature worktree"` | Provides `cd` command |
| `"Suggest worktree for current task"` | Context-aware suggestion |
| `"Help with worktrees"` | Shows help |

---

## 🖥️ Terminal Context Awareness

| Terminal | Auto-Detects | Suggests |
|----------|-------------|----------|
| **ios-bridge** | iOS project | `feature` worktree |
| **ios-sickbay** | iOS project | `hotfix` worktree |
| **ios-stellar** | iOS project | `refactor` worktree |
| **ios-engineering** | iOS project | `release` worktree |
| **ios-holodeck** | iOS project | `test` worktree |
| **android-***  | Android project | Context-appropriate |
| **firebase-*** | Firebase project | Context-appropriate |

---

## ✅ Safety Features

### Pre-Removal Checks

Before removing a worktree, the skill checks:

- ✅ **Uncommitted changes** - Warns if files not committed
- ✅ **Unpushed commits** - Warns if commits not pushed
- ✅ **Branch merged** - Warns if branch not merged to main
- ✅ **Confirmation prompt** - Always asks before destructive actions

### Example Safety Prompt

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

---

## 🔧 Manual Git Commands

### List Worktrees
```bash
git worktree list
```

### Add Worktree Manually
```bash
# New branch
git worktree add -b feature/my-feature worktrees/feature main

# Existing branch
git worktree add worktrees/feature feature/existing-branch
```

### Remove Worktree Manually
```bash
git worktree remove worktrees/feature

# Force remove (dangerous)
git worktree remove -f worktrees/feature
```

### Prune Stale Worktrees
```bash
git worktree prune
```

---

## 🚨 Common Issues & Solutions

### Issue: "Worktree already exists"

**Solution:**
```
# Option 1: Use existing
cd worktrees/feature/

# Option 2: Create with different name
"Create worktree for feature/my-specific-feature"

# Option 3: Remove existing first
"Remove worktree feature"
```

---

### Issue: "Branch already checked out"

**Solution:**
```
# Find where it's checked out
"Which worktree has branch feature/X?"

# Switch to that worktree or create new branch name
```

---

### Issue: "Cannot remove - uncommitted changes"

**Solution:**
```bash
# Option 1: Commit first (recommended)
cd worktrees/hotfix/
git add .
git commit -m "Fix description"
git push

# Option 2: Stash
cd worktrees/hotfix/
git stash

# Option 3: Force remove (DANGER)
"Force remove worktree hotfix"
```

---

### Issue: "Worktree shows dirty but no changes"

**Solution:**
```bash
cd worktrees/feature/
echo ".DS_Store" >> .gitignore
git add .gitignore
git commit -m "Ignore .DS_Store"
```

---

### Issue: "'path' is already registered"

**Solution:**
```
"Prune worktrees"
```

---

## 💡 Best Practices

### Do's ✅

- ✅ Create worktrees as needed (not preemptively)
- ✅ Use descriptive names (`feature-funcard-reload`)
- ✅ Commit and push regularly
- ✅ Keep 3-5 worktrees max per project
- ✅ Clean up when task is complete
- ✅ Run weekly worktree review

### Don'ts ❌

- ❌ Don't accumulate too many worktrees
- ❌ Don't forget to push work (risk data loss)
- ❌ Don't manually delete worktree directories (use skill)
- ❌ Don't use worktrees for quick one-line changes
- ❌ Don't check out same branch in multiple worktrees

---

## 🔄 Typical Workflows

### Feature Development

```
1. "Create worktree for feature/MEM-445-widget"
2. cd worktrees/feature-MEM-445-widget/
3. [Code, commit regularly, push]
4. Create PR when ready
5. After merge: "Remove worktree feature-MEM-445-widget"
```

### Emergency Hotfix

```
1. "Create worktree for hotfix/crash-3455"
2. cd worktrees/hotfix-crash-3455/
3. [Fix, test, commit, push]
4. Create fast-track PR
5. After deploy: "Remove worktree hotfix-crash-3455"
```

### Systematic Refactoring

```
1. "Create worktree for refactor/force-unwraps"
2. cd worktrees/refactor-force-unwraps/
3. [Refactor daily, commit per file, push often]
4. Create PR when complete
5. After merge: "Remove worktree refactor-force-unwraps"
```

---

## 📊 Project Detection Methods

The skill auto-detects your project using (in order):

1. **Terminal name prefix** (`ios-*`, `android-*`, `firebase-*`)
2. **Working directory** (contains `MainEventApp-iOS`, etc.)
3. **Git remote URL** (checks origin for project name)
4. **Project files** (`.xcodeproj`, `build.gradle.kts`, `firebase.json`)
5. **Explicit override** (`"Create iOS worktree for feature"`)

---

## 🌍 Multi-Project Example

```
# iOS Feature (Terminal 1: ios-bridge)
cd MainEventApp-iOS/worktrees/feature/
# Working on iOS Fun Card widget

# Android Feature (Terminal 2: android-bridge)
cd MainEventApp-Android/worktrees/feature/
# Working on Android Fun Card widget

# Firebase Backend (Terminal 3: firebase-ops)
cd MainEventApp-Functions/worktrees/feature/
# Working on sync endpoint

All three work simultaneously without conflicts!
```

---

## 📝 Worktree Naming Patterns

| Pattern | Example | Use Case |
|---------|---------|----------|
| `feature` | `worktrees/feature/` | General feature work |
| `feature-[desc]` | `worktrees/feature-funcard-reload/` | Specific feature |
| `feature-MEM-[ID]` | `worktrees/feature-MEM-445/` | Jira-tracked feature |
| `hotfix` | `worktrees/hotfix/` | General hotfix work |
| `hotfix-crash-[ID]` | `worktrees/hotfix-crash-3455/` | Specific crash fix |
| `refactor` | `worktrees/refactor/` | General refactoring |
| `refactor-[desc]` | `worktrees/refactor-force-unwraps/` | Specific refactor |
| `release` | `worktrees/release/` | Release preparation |
| `test` | `worktrees/test/` | Experiments/QA |
| `review` | `worktrees/review/` | Code review |

---

## 🔗 Branch Naming Patterns

| Type | Pattern | Example |
|------|---------|---------|
| Feature | `feature/[description]` | `feature/funcard-reload` |
| Feature + Jira | `feature/MEM-[ID]-[description]` | `feature/MEM-445-widget` |
| Hotfix | `hotfix/[description]` | `hotfix/booking-crash` |
| Hotfix + ID | `hotfix/crash-[ID]` | `hotfix/crash-3455` |
| Bugfix | `bugfix/[description]` | `bugfix/leaderboard-sort` |
| Bugfix + Jira | `bugfix/MEM-[ID]` | `bugfix/MEM-450` |
| Refactor | `refactor/[description]` | `refactor/force-unwraps` |
| Release | `release/[version]` | `release/2.9.0` |

---

## 💾 Backup & Safety

### Worktrees ARE Branches

Worktrees are just working directories. Your data is safe as long as you:

1. **Commit your work:**
   ```bash
   git commit -m "Description"
   ```

2. **Push to remote:**
   ```bash
   git push origin feature/your-branch
   ```

The worktree directory itself is disposable - the commits are what matter!

---

## 📦 Disk Space

Each worktree uses:
- **Git metadata:** ~10-20MB (hard links, minimal)
- **Working files:** Size of your source code (~50-200MB typical)
- **Total per worktree:** ~60-220MB

**5 worktrees ≈ 300MB - 1GB** depending on project size

---

## 🎓 When to Use Worktrees

### ✅ Perfect For:

- Feature development while fixing critical bugs
- Systematic refactoring over multiple days
- Release preparation while dev continues
- Code review without disrupting current work
- Testing experimental changes safely

### ❌ Not Ideal For:

- Quick one-line changes (just commit in main repo)
- Temporary experiments <1 hour (use `git stash`)
- Learning Git (learn basics first)
- Absolute beginners to Git workflows

---

## 📞 Getting Help

### In Claude Code:
```
"Help with worktrees"
"Troubleshoot worktree issue"
"Show worktree examples"
```

### Git Documentation:
```bash
git worktree --help
man git-worktree
```

### Online Resources:
- **Git Docs:** https://git-scm.com/docs/git-worktree
- **Skill Location:** `~/dev-team/skills/Git_Worktree_Manager_SKILL.md`

---

## 📄 Related Documents

- **Full Skill Definition:** `Git_Worktree_Manager_SKILL.md` (53KB)
- **User Guide:** `Git_Worktree_Manager_USER_GUIDE.md` (Complete documentation)
- **This Quick Ref:** `Git_Worktree_Manager_QUICK_REFERENCE.md` (Print me!)

---

## ✨ Pro Tips

1. **Weekly cleanup:** Review and remove old worktrees every Friday
2. **Push often:** Protect your work by pushing to remote regularly
3. **Use tmux:** Each worktree in its own tmux window
4. **Name clearly:** Use descriptive names like `feature-funcard-reload`
5. **3-5 max:** Don't accumulate too many worktrees per project
6. **Check status:** Run `"List worktrees"` regularly to see what's active

---

**🖖 Live Long and Code**

**Skill Version:** 1.0.0  
**Last Updated:** November 2025  
**Author:** Darren Ehlers (Dave & Buster's Entertainment, Inc.)

---

**Print this page and keep it handy!**
