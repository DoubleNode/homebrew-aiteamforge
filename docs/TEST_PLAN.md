# AITeamForge Comprehensive Test Plan

**Version:** 1.0.0
**Target:** AITeamForge v1.4.2 (Homebrew distribution)
**Platform:** macOS Big Sur (11.0) or later
**Last Updated:** 2026-03-31

---

## Purpose

This test plan provides a systematic, human-executable validation of AITeamForge — an AI-powered
multi-team development infrastructure installed via Homebrew. It covers the full lifecycle from
clean environment prerequisites through installation, setup wizard, feature configuration, and
teardown/recovery scenarios.

Each test step specifies the exact command to run, the expected result, and a pass/fail checkbox.
Execute the phases in order; later phases depend on successful completion of earlier ones.

---

## Test Plan Structure

| Phase | Scope |
|-------|-------|
| Phase 1 | Prerequisites and clean environment verification |
| Phase 2 | Homebrew tap add and formula installation |
| Phase 3 | Setup wizard — dependencies check and machine identity |
| Phase 4 | Setup wizard — team selection and feature configuration |
| Phase 5 | Setup wizard — installation orchestration and completion |
| Phase 6 | Post-install verification (`aiteamforge doctor`) |
| Phase 7 | Shell environment and alias functionality |
| Phase 8 | LCARS Kanban service |
| Phase 9 | Claude Code integration |
| Phase 10 | Teardown and uninstall |

---

## Phase 1: Prerequisites and Clean Environment Verification

**Purpose:** Confirm the test machine meets all system requirements, that all required software
is present at acceptable versions, and that no prior AITeamForge installation exists that could
interfere with results.

**When to run Phase 1:**
- Before the very first test session on a machine
- After uninstalling AITeamForge to confirm clean state (Phase 10 verification)
- Any time test results are unexpectedly inconsistent

---

### 1.0 Pre-Test Checklist

Complete this checklist before running any test steps. Items here do not have pass/fail
checkboxes — they are go/no-go gates. Do not proceed if any item cannot be confirmed.

**Hardware**
- [ ] Machine is Apple Silicon (ARM64) or Intel (x86_64) Mac
- [ ] At least 8 GB RAM available (16 GB recommended for multi-team testing)
- [ ] At least 5 GB free disk space (10 GB recommended)
- [ ] Machine is connected to the internet

**Operating System**
- [ ] macOS Big Sur (11.0) or later is installed
- [ ] User account has administrator privileges (required for Homebrew)
- [ ] System Integrity Protection (SIP) is in its default state (not disabled)

**Network and Accounts**
- [ ] Internet connectivity confirmed (can open a browser and reach https://github.com)
- [ ] GitHub account available (required for `gh auth login` in Phase 3)
- [ ] Anthropic account available (required for Claude Code auth testing in Phase 9)

**Test Session Hygiene**
- [ ] No other installation or upgrade is running in background terminals
- [ ] The test terminal is a fresh session (not carrying prior environment variables)
- [ ] No VPN or proxy is intercepting Homebrew downloads (or tester knows to account for it)

---

### 1.1 Required Software — Homebrew

Homebrew is the only prerequisite that must be manually installed. All other dependencies can
be installed by the AITeamForge setup wizard, but Homebrew itself cannot.

#### Test 1.1.1: Homebrew Is Installed
**Action:** Run the following command in a new terminal window:
```
brew --version
```
**Expected Result:** Output begins with `Homebrew` followed by a version number (e.g., `Homebrew 4.2.0`). No error message.
**Pass/Fail:** [ ]

#### Test 1.1.2: Homebrew Is In PATH
**Action:** Run:
```
which brew
```
**Expected Result:** Returns a path such as `/opt/homebrew/bin/brew` (Apple Silicon) or `/usr/local/bin/brew` (Intel). No "not found" error.
**Pass/Fail:** [ ]

#### Test 1.1.3: Homebrew Update Succeeds
**Action:** Run:
```
brew update
```
**Expected Result:** Command completes without errors. Output shows "Already up-to-date" or lists updated formulae. No permission errors.
**Pass/Fail:** [ ]

---

### 1.2 Required Software — Git

#### Test 1.2.1: Git Is Installed
**Action:** Run:
```
git --version
```
**Expected Result:** Output is `git version X.Y.Z` where X.Y is 2.0 or higher (e.g., `git version 2.43.0`).
**Pass/Fail:** [ ]

#### Test 1.2.2: Git Is In PATH
**Action:** Run:
```
which git
```
**Expected Result:** Returns a path (e.g., `/usr/bin/git` or `/opt/homebrew/bin/git`). Not empty, no "not found" error.
**Pass/Fail:** [ ]

---

### 1.3 Required Software — jq

jq may or may not be pre-installed. The AITeamForge setup wizard can install it via Homebrew.
This test confirms whether it is already present so the tester knows what to expect during setup.

#### Test 1.3.1: jq Install Status (Informational)
**Action:** Run:
```
jq --version
```
**Expected Result (if installed):** Output is `jq-1.X` (e.g., `jq-1.7.1`). Record this version for Phase 3 test comparisons.
**Expected Result (if not installed):** `command not found: jq` — this is acceptable; the setup wizard will install it.
**Pass/Fail:** [ ] (pass if either outcome is clear and unambiguous)

---

### 1.4 Required Software — tmux

tmux may or may not be pre-installed. The AITeamForge setup wizard can install it via Homebrew.

#### Test 1.4.1: tmux Install Status (Informational)
**Action:** Run:
```
tmux -V
```
**Expected Result (if installed):** Output is `tmux X.Y` (e.g., `tmux 3.4`). Record this version.
**Expected Result (if not installed):** `command not found: tmux` — acceptable; the setup wizard will install it.
**Pass/Fail:** [ ] (pass if either outcome is clear and unambiguous)

---

### 1.5 Required Software — Node.js

#### Test 1.5.1: Node.js Install Status (Informational)
**Action:** Run:
```
node --version
```
**Expected Result (if installed):** Output is `vX.Y.Z` where major version is 18 or higher (e.g., `v20.10.0`). Record this version.
**Expected Result (if not installed):** `command not found: node` — acceptable; the setup wizard will install it.
**Pass/Fail:** [ ] (pass if either outcome is clear and unambiguous)

---

### 1.6 Required Software — Python 3

#### Test 1.6.1: Python 3 Install Status (Informational)
**Action:** Run:
```
python3 --version
```
**Expected Result (if installed):** Output is `Python 3.X.Y` where 3.X is 3.8 or higher (e.g., `Python 3.11.6`). Record this version.
**Expected Result (if not installed):** `command not found: python3` — acceptable; the setup wizard will install it.
**Pass/Fail:** [ ] (pass if either outcome is clear and unambiguous)

---

### 1.7 Required Software — GitHub CLI (gh)

#### Test 1.7.1: GitHub CLI Install Status (Informational)
**Action:** Run:
```
gh --version
```
**Expected Result (if installed):** Output begins with `gh version X.Y.Z` (e.g., `gh version 2.40.1`). Record this version.
**Expected Result (if not installed):** `command not found: gh` — acceptable; the setup wizard will install it.
**Pass/Fail:** [ ] (pass if either outcome is clear and unambiguous)

---

### 1.8 Clean Environment Verification — No Prior AITeamForge Installation

These tests confirm that no previous AITeamForge installation exists on the machine. If any of
these tests reveal a prior installation, the tester must perform cleanup (see 1.8.7) before
proceeding to Phase 2.

#### Test 1.8.1: No aiteamforge Homebrew Formula Installed
**Action:** Run:
```
brew list | grep aiteamforge
```
**Expected Result:** No output (empty). If `aiteamforge` appears in the output, a prior installation exists.
**Pass/Fail:** [ ]

#### Test 1.8.2: No DoubleNode Homebrew Tap Active
**Action:** Run:
```
brew tap | grep doublenode
```
**Expected Result:** No output (empty). If `doublenode/aiteamforge` appears, the tap was previously added.
**Pass/Fail:** [ ]

#### Test 1.8.3: No aiteamforge Working Directory
**Action:** Run:
```
ls ~/aiteamforge 2>&1
```
**Expected Result:** Output is `ls: /Users/<username>/aiteamforge: No such file or directory`. The directory must not exist.
**Pass/Fail:** [ ]

#### Test 1.8.4: No aiteamforge Configuration Directory
**Action:** Run:
```
ls ~/.aiteamforge 2>&1
```
**Expected Result:** Output is `ls: /Users/<username>/.aiteamforge: No such file or directory`. The directory must not exist.
**Pass/Fail:** [ ]

#### Test 1.8.5: No aiteamforge Shell Integration in .zshrc
**Action:** Run:
```
grep -c "aiteamforge" ~/.zshrc 2>/dev/null || echo "0"
```
**Expected Result:** Output is `0`. If a number greater than 0 is returned, leftover shell integration exists.
**Pass/Fail:** [ ]

#### Test 1.8.6: No aiteamforge LaunchAgents Loaded
**Action:** Run:
```
launchctl list 2>/dev/null | grep aiteamforge || echo "none"
```
**Expected Result:** Output is `none`. If any `com.aiteamforge.*` labels appear, prior LaunchAgents are still registered.
**Pass/Fail:** [ ]

#### Test 1.8.7: No aiteamforge Homebrew Installation Marker
**Action:** Run:
```
ls "$(brew --prefix)/var/aiteamforge/" 2>&1
```
**Expected Result:** Output is `ls: .../var/aiteamforge/: No such file or directory`. The marker directory must not exist.
**Pass/Fail:** [ ]

---

### 1.8.8 Cleanup Procedure (If Prior Installation Found)

If any of tests 1.8.1 through 1.8.7 failed, perform the following cleanup steps in order before
continuing. After completing cleanup, rerun the failing tests to confirm clean state.

**If Homebrew formula installed (1.8.1 failed):**
```
brew uninstall aiteamforge
```

**If tap still active (1.8.2 failed):**
```
brew untap DoubleNode/aiteamforge
```

**If working directory exists (1.8.3 failed):**
```
mv ~/aiteamforge ~/aiteamforge-old-$(date +%Y%m%d%H%M%S)
```
Note: Rename rather than delete so kanban data is preserved.

**If config directory exists (1.8.4 failed):**
```
mv ~/.aiteamforge ~/.aiteamforge-old-$(date +%Y%m%d%H%M%S)
```

**If shell integration exists (1.8.5 failed):**
Edit `~/.zshrc` manually and remove the `# AITeamForge Environment` block and the `source` line
that follows it.

**If LaunchAgents are loaded (1.8.6 failed):**
```
launchctl unload ~/Library/LaunchAgents/com.aiteamforge.*.plist 2>/dev/null
rm -f ~/Library/LaunchAgents/com.aiteamforge.*.plist
```

**If installation marker exists (1.8.7 failed):**
```
rm -rf "$(brew --prefix)/var/aiteamforge/"
```

After all cleanup steps, reload the shell environment:
```
source ~/.zshrc
```

Then rerun tests 1.8.1 through 1.8.7 to confirm all return the expected "clean" results.

---

### Phase 1 Summary

Record the results for this phase before proceeding to Phase 2.

| Section | Tests | Passed | Failed |
|---------|-------|--------|--------|
| 1.1 Homebrew | 3 | | |
| 1.2 Git | 2 | | |
| 1.3 jq (informational) | 1 | | |
| 1.4 tmux (informational) | 1 | | |
| 1.5 Node.js (informational) | 1 | | |
| 1.6 Python 3 (informational) | 1 | | |
| 1.7 GitHub CLI (informational) | 1 | | |
| 1.8 Clean environment | 7 | | |
| **Total** | **17** | | |

**Phase 1 Pass/Fail Criteria:**
- All tests in sections 1.1, 1.2, and 1.8 must pass (PASS verdict required)
- Sections 1.3 through 1.7 are informational — any clear, unambiguous result is acceptable
- Phase 1 is PASS when all required tests pass and the environment is confirmed clean
- Phase 1 is FAIL if any required test fails — do not proceed to Phase 2 until resolved

**Phase 1 Result:** [ ] PASS   [ ] FAIL

**Notes (record any observations, version numbers found, cleanup steps taken):**

```
Homebrew version:
Git version:
jq pre-installed: [ ] Yes (version: ____) [ ] No
tmux pre-installed: [ ] Yes (version: ____) [ ] No
Node.js pre-installed: [ ] Yes (version: ____) [ ] No
Python 3 pre-installed: [ ] Yes (version: ____) [ ] No
gh pre-installed: [ ] Yes (version: ____) [ ] No
Cleanup required: [ ] Yes [ ] No
Cleanup steps taken:
```

---

*Proceed to Phase 2: Homebrew Tap Add and Formula Installation*

---

## Phase 2: Fresh Install on Clean MacBook Pro

**Purpose:** Verify the complete end-to-end installation path — from registering the Homebrew tap through a fully operational AITeamForge environment. This phase exercises every installer module invoked by the setup wizard, validates the configuration generated, confirms shell integration, verifies Claude Code configuration, confirms the LCARS kanban service starts, and validates that the read-only framework layer and user-managed working layer are correctly separated.

**Preconditions:**
- Phase 1 completed with PASS result
- Machine confirmed clean per section 1.8 (no prior AITeamForge installation)
- Homebrew installed and on PATH
- Internet connection active
- Directories `~/aiteamforge/` and `~/.aiteamforge/` do not exist

---

### Section 2.1 — Homebrew Tap Registration

### Test 2.1: Add the AITeamForge Homebrew tap
**Action:** `brew tap DoubleNode/aiteamforge`
**Expected Result:** Homebrew clones the tap repository without error. Output confirms the tap was added (e.g., `Tapped N formulae (N files, N.NMB).`). Exit code is 0. No "Repository not found" or authentication failure appears.
**Pass/Fail:** [ ]

### Test 2.2: Verify tap appears in brew tap list
**Action:** `brew tap | grep -i doublenode`
**Expected Result:** Output contains `doublenode/aiteamforge`. Exit code is 0.
**Pass/Fail:** [ ]

### Test 2.3: Verify formula metadata is visible after tap
**Action:** `brew info aiteamforge`
**Expected Result:** Output displays: name (`aiteamforge`), version (`1.4.2`), description ("AITeamForge - AI-powered multi-team development infrastructure"), and homepage URL. No "No available formula or cask" error.
**Pass/Fail:** [ ]

---

### Section 2.2 — Homebrew Formula Installation

### Test 2.4: Install AITeamForge via brew install
**Action:** `brew install aiteamforge`
**Expected Result:** Homebrew resolves and installs all declared dependencies: python@3, node, jq, gh, git, tmux. Final output shows `aiteamforge 1.4.2` installed. Exit code is 0. No error lines in output.
**Pass/Fail:** [ ]

### Test 2.5: Verify post-install caveats block is displayed
**Action:** Review output from Test 2.4.
**Expected Result:** Caveats block contains all five commands: `aiteamforge setup`, `aiteamforge doctor`, `aiteamforge status`, `aiteamforge upgrade`, `aiteamforge help`. The message "Run 'aiteamforge setup' to configure your environment" is present.
**Pass/Fail:** [ ]

### Test 2.6: Verify installation marker file written by post_install hook
**Action:** `cat "$(brew --prefix)/var/aiteamforge/.installed"`
**Expected Result:** File exists. First line contains version string (e.g., `1.4.2`). Second line contains a timestamp. Exit code is 0.
**Pass/Fail:** [ ]

### Test 2.7: Verify all three CLI binaries are on PATH
**Action:** `which aiteamforge && which aiteamforge-setup && which aiteamforge-doctor`
**Expected Result:** All three resolve to paths under `$(brew --prefix)/bin/`. Each prints a path with exit code 0. No "command not found" for any of the three.
**Pass/Fail:** [ ]

### Test 2.8: Verify framework directory structure in libexec
**Action:** `ls "$(brew --prefix)/opt/aiteamforge/libexec/"`
**Expected Result:** Directory exists and contains: `libexec/commands/`, `libexec/installers/`, `libexec/lib/`, `share/templates/`, `share/teams/`. Exit code is 0.
**Pass/Fail:** [ ]

### Test 2.9: Verify core library files exist in framework
**Action:** `ls "$(brew --prefix)/opt/aiteamforge/libexec/libexec/lib/"`
**Expected Result:** Directory contains at minimum: `common.sh`, `config.sh`, `wizard-ui.sh`. All three present. Exit code is 0.
**Pass/Fail:** [ ]

### Test 2.10: Verify alias template files exist in framework
**Action:** `ls "$(brew --prefix)/opt/aiteamforge/libexec/share/templates/aliases/"`
**Expected Result:** Directory contains: `agent-aliases.sh`, `cc-aliases.sh`, `worktree-aliases.sh`. All three present. Exit code is 0.
**Pass/Fail:** [ ]

### Test 2.11: Verify framework layer is not writable by regular user
**Action:** `touch "$(brew --prefix)/opt/aiteamforge/libexec/write-probe-test" 2>&1; echo "exit:$?"`
**Expected Result:** Command fails with "Permission denied" or "Read-only file system". Exit code is non-zero. Probe file is not created.
**Pass/Fail:** [ ]

### Test 2.12: Verify setup wizard help flag works before running setup
**Action:** `aiteamforge-setup --help`
**Expected Result:** Help text printed showing usage, all flags (`--dry-run`, `--non-interactive`, `--verbose`, `--help`), and examples. Exit code is 0. No crash.
**Pass/Fail:** [ ]

---

### Section 2.3 — Setup Wizard: Dry-Run Mode

### Test 2.13: Dry-run mode completes without creating any files or directories
**Action:** `aiteamforge setup --dry-run` (accept all defaults). After exit: `ls ~/.aiteamforge/ 2>&1; echo "exit:$?"` and `ls ~/aiteamforge/ 2>&1; echo "exit:$?"`
**Expected Result:** Dry-run exits with code 0. Neither directory is created. `.zshrc` is unchanged. All output lines referencing writes are prefixed with `[DRY RUN]`.
**Pass/Fail:** [ ]

### Test 2.14: Dry-run mode prints configuration preview
**Action:** Review dry-run output from Test 2.13.
**Expected Result:** Wizard prints the JSON config that would have been saved, including `machine`, `teams`, `features`, and `paths` keys. Preview is clearly labeled (e.g., "Configuration preview:").
**Pass/Fail:** [ ]

---

### Section 2.4 — Setup Wizard: Prerequisites Check Stage

### Test 2.15: Wizard displays LCARS-styled welcome banner
**Action:** Begin interactive `aiteamforge setup`. Observe initial screen.
**Expected Result:** Styled LCARS-themed banner displayed using amber/blue/lilac palette. No raw escape sequences appear as literal characters.
**Pass/Fail:** [ ]

### Test 2.16: Prerequisites stage checks all five required dependencies
**Action:** Observe the "Checking Prerequisites" stage output.
**Expected Result:** All five required dependencies checked: git, python3, node, jq, gh. Each shows `ok` and version number. Section header "Checking required dependencies..." appears before the list.
**Pass/Fail:** [ ]

### Test 2.17: Prerequisites stage checks optional dependencies in a separate labeled group
**Action:** Observe optional dependencies section in same stage.
**Expected Result:** Optional dependencies (claude, brew) checked under "Checking optional dependencies...". Each shows `ok (version)` or `missing`. Two groups are visually distinct.
**Pass/Fail:** [ ]

### Test 2.18: Wizard aborts when a required dependency is absent
**Action:** In a controlled environment with `jq` temporarily removed from PATH, run `aiteamforge setup`.
**Expected Result:** Wizard prints error identifying `jq` as missing, prints install instruction `brew install jq`, exits with non-zero exit code. Does not proceed to machine identity stage.
**Pass/Fail:** [ ]

### Test 2.19: Wizard continues when user confirms missing optional dependency
**Action:** With `claude` not installed, run `aiteamforge setup` and answer `y` to "Continue without optional dependencies?"
**Expected Result:** Warning lists `claude` as missing with install instruction. After `y`, wizard proceeds to machine identity stage without exiting.
**Pass/Fail:** [ ]

---

### Section 2.5 — Setup Wizard: Machine Identity Stage

### Test 2.20: Machine name prompt defaults to system hostname
**Action:** Reach machine identity stage. Observe default in the machine name prompt.
**Expected Result:** Default matches output of `hostname -s`. User can accept by pressing Enter.
**Pass/Fail:** [ ]

### Test 2.21: Custom machine name with hyphen is accepted
**Action:** Clear default and type `test-clean-macbook`. Press Enter.
**Expected Result:** Wizard accepts input. Confirmation reads: `Machine: test-clean-macbook`.
**Pass/Fail:** [ ]

### Test 2.22: User display name defaults to system identity
**Action:** Observe default in user display name prompt.
**Expected Result:** Default is output of `id -F` or `$USER` if unavailable. Value is non-empty.
**Pass/Fail:** [ ]

### Test 2.23: User display name with spaces is accepted
**Action:** Enter `Test Tester` at user name prompt.
**Expected Result:** Wizard accepts multi-word name. Confirmation reads: `User: Test Tester`. No truncation at the space.
**Pass/Fail:** [ ]

---

### Section 2.6 — Setup Wizard: Team Selection Stage

### Test 2.24: All ten available teams appear in the selection list
**Action:** Reach team selection stage and observe the full list.
**Expected Result:** Exactly ten teams listed: iOS, Android, Firebase, Academy, DNS, Freelance, Command, Legal, Medical, MainEvent. Each shows its description.
**Pass/Fail:** [ ]

### Test 2.25: Single team selection is accepted
**Action:** Select only `Academy` and confirm.
**Expected Result:** Wizard confirms: `Selected teams: Academy`. Only one team name appears.
**Pass/Fail:** [ ]

### Test 2.26: Multiple team selection is accepted
**Action:** Select `iOS`, `Firebase`, and `Academy`.
**Expected Result:** All three appear in the confirmation. No team duplicated or missing.
**Pass/Fail:** [ ]

---

### Section 2.7 — Setup Wizard: Feature Selection Stage

### Test 2.27: LCARS Kanban defaults to yes
**Action:** Observe prompt "Install LCARS Kanban system?"
**Expected Result:** Default shown is `y`. Pressing Enter selects yes.
**Pass/Fail:** [ ]

### Test 2.28: Fleet Monitor defaults to no
**Action:** Observe prompt "Install Fleet Monitor (for multi-machine setups)?"
**Expected Result:** Default shown is `n`. Pressing Enter skips Fleet Monitor.
**Pass/Fail:** [ ]

### Test 2.29: Shell environment defaults to yes
**Action:** Observe prompt "Install shell environment (prompts, aliases)?"
**Expected Result:** Default shown is `y`.
**Pass/Fail:** [ ]

### Test 2.30: Claude Code configuration defaults to yes
**Action:** Observe prompt "Install Claude Code configuration?"
**Expected Result:** Default shown is `y`.
**Pass/Fail:** [ ]

### Test 2.31: iTerm2 integration defaults to no
**Action:** Observe prompt "Install iTerm2 integration (requires iTerm2)?"
**Expected Result:** Default shown is `n`.
**Pass/Fail:** [ ]

---

### Section 2.8 — Configuration Generation

### Test 2.32: Config directory ~/.aiteamforge/ is created
**Action:** After wizard completes all prompt stages: `ls -la ~/.aiteamforge/`
**Expected Result:** Directory exists and is owned by current user. Exit code is 0.
**Pass/Fail:** [ ]

### Test 2.33: config.json is valid JSON with all required top-level keys
**Action:** `cat ~/.aiteamforge/config.json | jq .`
**Expected Result:** Valid JSON output. Contains all six keys: `version`, `machine`, `teams`, `features`, `paths`, `installed_at`. Exit code from `jq` is 0.
**Pass/Fail:** [ ]

### Test 2.34: config.json machine section reflects wizard input
**Action:** `jq '.machine' ~/.aiteamforge/config.json`
**Expected Result:** `name` matches machine name entered in Stage 2.5. `user` matches display name entered. `hostname` is non-empty.
**Pass/Fail:** [ ]

### Test 2.35: config.json teams array matches wizard selection exactly
**Action:** `jq '.teams' ~/.aiteamforge/config.json`
**Expected Result:** JSON array contains exactly the teams selected during Stage 2.6 — no extras, no omissions.
**Pass/Fail:** [ ]

### Test 2.36: config.json features section matches wizard selection
**Action:** `jq '.features' ~/.aiteamforge/config.json`
**Expected Result:** All five boolean fields (`kanban`, `fleet_monitor`, `shell_env`, `claude_config`, `iterm_integration`) present and matching Stage 2.7 selections.
**Pass/Fail:** [ ]

### Test 2.37: config.json paths section uses correct absolute paths
**Action:** `jq '.paths' ~/.aiteamforge/config.json`
**Expected Result:** `install_dir` is absolute path to `~/aiteamforge` (expanded, not literal `~`). `config_dir` is absolute path to `~/.aiteamforge`.
**Pass/Fail:** [ ]

### Test 2.38: config.json installed_at is a valid recent UTC timestamp
**Action:** `jq -r '.installed_at' ~/.aiteamforge/config.json`
**Expected Result:** Value is ISO 8601 format with `Z` suffix (e.g., `2026-03-31T14:22:05Z`). Timestamp is within 10 minutes of actual UTC time.
**Pass/Fail:** [ ]

---

### Section 2.9 — Directory Structure Verification

### Test 2.39: Working directory ~/aiteamforge/ is created
**Action:** `ls -la ~/aiteamforge/`
**Expected Result:** Directory exists and is owned by current user. This is the user-managed working layer, separate from the read-only Homebrew framework.
**Pass/Fail:** [ ]

### Test 2.40: share/ subdirectory contains the environment loader
**Action:** `ls ~/aiteamforge/share/`
**Expected Result:** `share/` exists and contains `aiteamforge-env.sh` — the environment loader `.zshrc` sources.
**Pass/Fail:** [ ]

### Test 2.41: aliases/ subdirectory contains all three alias files
**Action:** `ls ~/aiteamforge/share/aliases/`
**Expected Result:** Directory contains: `agent-aliases.sh`, `cc-aliases.sh`, `worktree-aliases.sh`. All three present and non-empty.
**Pass/Fail:** [ ]

### Test 2.42: Template placeholder is substituted in installed alias files
**Action:** `grep "{{AITEAMFORGE_DIR}}" ~/aiteamforge/share/aliases/agent-aliases.sh 2>&1; echo "exit:$?"`
**Expected Result:** No `{{AITEAMFORGE_DIR}}` placeholder remains. Replaced with actual path. Exit code from grep is non-zero (no match).
**Pass/Fail:** [ ]

### Test 2.43: secrets.env.template is present in working directory
**Action:** `ls ~/aiteamforge/secrets.env.template`
**Expected Result:** File exists and is non-empty. Contains placeholder variable names. Exit code is 0.
**Pass/Fail:** [ ]

### Test 2.44: secrets.env file is NOT automatically created
**Action:** `ls ~/aiteamforge/secrets.env 2>&1; echo "exit:$?"`
**Expected Result:** File does not exist. Exit code is non-zero. Installer must not auto-create a secrets file.
**Pass/Fail:** [ ]

### Test 2.45: Framework layer and working layer are distinct paths
**Action:** `[[ "$(brew --prefix)/opt/aiteamforge/libexec" != "$HOME/aiteamforge" ]] && echo "DISTINCT" || echo "SAME"`
**Expected Result:** Output is `DISTINCT`. The two directories serve different roles and occupy different filesystem locations.
**Pass/Fail:** [ ]

---

### Section 2.10 — Shell Integration Verification

### Test 2.46: .zshrc backup is created before modification
**Action:** `ls -la ~/.zshrc.aiteamforge-backup`
**Expected Result:** Backup file exists if `.zshrc` existed before setup. Modification time predates setup run. If `.zshrc` did not exist before setup, mark `[S]`.
**Pass/Fail:** [ ]

### Test 2.47: .zshrc contains both AITeamForge integration markers
**Action:** `grep -n "aiteamforge initialize" ~/.zshrc`
**Expected Result:** Exactly two lines found: `# >>> aiteamforge initialize >>>` and `# <<< aiteamforge initialize <<<`. Both present. Exit code is 0.
**Pass/Fail:** [ ]

### Test 2.48: Integration block sources the environment loader
**Action:** `grep "aiteamforge-env.sh" ~/.zshrc`
**Expected Result:** A `source` statement referencing `~/aiteamforge/share/aiteamforge-env.sh` exists inside the integration block. Exit code is 0.
**Pass/Fail:** [ ]

### Test 2.49: Shell loads cleanly after sourcing .zshrc
**Action:** `zsh --login -c "source ~/.zshrc; echo SHELL_OK"`
**Expected Result:** Output contains `SHELL_OK`. No errors printed during sourcing.
**Pass/Fail:** [ ]

### Test 2.50: kb-* kanban helper functions available in new shell session
**Action:** In a new shell session: `type kb-list`
**Expected Result:** Output confirms `kb-list` is a shell function. Exit code is 0.
**Pass/Fail:** [ ]

### Test 2.51: Idempotency — second setup run does not duplicate .zshrc block
**Action:** Run `aiteamforge setup` a second time with same options. After: `grep -c "aiteamforge initialize >>>" ~/.zshrc`
**Expected Result:** Output is exactly `1`. Block is not duplicated.
**Pass/Fail:** [ ]

---

### Section 2.11 — Claude Code Configuration Verification

### Test 2.52: ~/.claude/ directory exists after setup
**Action:** `ls -la ~/.claude/`
**Expected Result:** Directory exists and is owned by current user. Exit code is 0.
**Pass/Fail:** [ ]

### Test 2.53: settings.json is installed and is valid JSON
**Action:** `cat ~/.claude/settings.json | jq .`
**Expected Result:** Valid JSON output. Non-empty. Exit code from `jq` is 0.
**Pass/Fail:** [ ]

### Test 2.54: Global CLAUDE.md is installed to ~/.claude/
**Action:** `wc -c ~/.claude/CLAUDE.md`
**Expected Result:** File exists. Byte count is greater than 0.
**Pass/Fail:** [ ]

### Test 2.55: Team agent directory exists for each selected team
**Action:** For each team selected during setup: `ls ~/.claude/agents/<TeamName>/`
**Expected Result:** Subdirectory exists for each selected team, containing at minimum a `CLAUDE.md` file.
**Pass/Fail:** [ ]

### Test 2.56: Hooks directory exists with damage-control subdirectory
**Action:** `ls ~/.claude/hooks/`
**Expected Result:** Directory exists. `damage-control/` subdirectory contains executable `.sh` files. If no hook templates found during install, mark `[W]`.
**Pass/Fail:** [ ]

### Test 2.57: Skills are symlinked (not copied) from working directory
**Action:** `ls -la ~/.claude/skills/ 2>/dev/null`
**Expected Result:** Entries under `~/.claude/skills/` are symbolic links pointing into `~/aiteamforge/skills/`. If no skills directory in working layer, mark `[S]`.
**Pass/Fail:** [ ]

### Test 2.58: Timestamped backup of prior Claude config was created
**Action:** `ls ~/aiteamforge/.backups/`
**Expected Result:** A timestamped directory exists (e.g., `claude-config-YYYYMMDD-HHMMSS/`). If no prior `~/.claude/` existed, mark `[S]`.
**Pass/Fail:** [ ]

---

### Section 2.12 — LCARS Kanban Service Verification

### Test 2.59: LCARS server health endpoint responds after setup
**Action:** `curl -s http://localhost:8082/health`
**Expected Result:** Server responds with JSON containing `"status":"ok"`. No "Connection refused" error.
**Pass/Fail:** [ ]

### Test 2.60: LCARS web UI returns HTTP 200
**Action:** `curl -s -o /dev/null -w "%{http_code}" http://localhost:8082/`
**Expected Result:** HTTP status code is `200`. LCARS UI HTML served at root path.
**Pass/Fail:** [ ]

### Test 2.61: Kanban backup LaunchAgent is registered
**Action:** `launchctl list | grep com.aiteamforge.kanban-backup`
**Expected Result:** Label `com.aiteamforge.kanban-backup` appears, confirming LaunchAgent is loaded. If kanban backup not selected, mark `[S]`.
**Pass/Fail:** [ ]

---

### Section 2.13 — Health Check: aiteamforge doctor

### Test 2.62: aiteamforge doctor exits 0 with all critical checks passing
**Action:** `aiteamforge doctor`
**Expected Result:** All dependency checks show passing status. Final summary reads "All critical checks passed". Exit code is 0. No "CRITICAL FAIL" or "FATAL" lines.
**Pass/Fail:** [ ]

### Test 2.63: aiteamforge doctor --verbose shows version detail for each dependency
**Action:** `aiteamforge doctor --verbose`
**Expected Result:** More detailed than standard run. Each dependency shows detected version number. Key directory paths confirmed present. Exit code is 0.
**Pass/Fail:** [ ]

### Test 2.64: aiteamforge doctor --check dependencies targets only that section
**Action:** `aiteamforge doctor --check dependencies`
**Expected Result:** Only DEPENDENCIES section printed. All five required tools (python3, node, jq, gh, git) listed with passing status and versions. Exit code is 0.
**Pass/Fail:** [ ]

### Test 2.65: aiteamforge doctor --check services reports LCARS status
**Action:** `aiteamforge doctor --check services`
**Expected Result:** SERVICES section printed. LCARS server shown as running with its port. Fleet Monitor shows "not configured" if not installed. Exit code reflects actual service health.
**Pass/Fail:** [ ]

### Test 2.66: aiteamforge doctor --check config validates configuration
**Action:** `aiteamforge doctor --check config`
**Expected Result:** CONFIGURATION section confirms: working directory exists, `~/.aiteamforge/config.json` exists and is valid JSON, templates copied. Exit code is 0 if healthy.
**Pass/Fail:** [ ]

### Test 2.67: aiteamforge status shows correct post-install state
**Action:** `aiteamforge status`
**Expected Result:** Output shows installed version, machine name, configured teams, enabled features, LCARS server port/status. No "not configured" or "uninstalled" state appears.
**Pass/Fail:** [ ]

---

### Section 2.14 — Framework vs. Working Layer Boundary

### Test 2.68: Framework installer scripts are not writable by regular user
**Action:** `ls -la "$(brew --prefix)/opt/aiteamforge/libexec/libexec/installers/install-shell.sh"`
**Expected Result:** File exists. Permission bits do not grant write access to current user — owner is root or Homebrew system account.
**Pass/Fail:** [ ]

### Test 2.69: Working layer files are writable by the user
**Action:** `ls -la ~/aiteamforge/share/aiteamforge-env.sh`
**Expected Result:** File is owned by current user. User has read and write permissions.
**Pass/Fail:** [ ]

### Test 2.70: Modifying working layer does not affect framework template
**Action:** Append a comment to `~/aiteamforge/share/aiteamforge-env.sh`. Then grep the framework template for the same comment. Clean up afterward.
**Expected Result:** Grep finds no match in framework template. Framework completely unaffected by working layer changes.
**Pass/Fail:** [ ]

### Test 2.71: brew reinstall does not overwrite the working layer
**Action:** Add a recognizable comment to `~/aiteamforge/share/aiteamforge-env.sh`. Run `brew reinstall aiteamforge`. Verify comment still present afterward. Clean up.
**Expected Result:** Customization survives the reinstall. Only framework files under libexec are updated by Homebrew. Working directory untouched.
**Pass/Fail:** [ ]

---

### Section 2.15 — Non-Interactive Installation Mode

### Test 2.72: Non-interactive mode reads from pre-written config and completes without prompts
**Action:** Create a minimal config file at `~/.aiteamforge/config.json` with machine, teams, features, and paths fields filled in. Then run: `aiteamforge setup --non-interactive`
**Expected Result:** Wizard completes without prompting for input. Reads selections from pre-written config. Exit code is 0.
**Pass/Fail:** [ ]

### Test 2.73: Non-interactive mode defaults machine name to hostname when omitted from config
**Action:** Write a config file omitting `machine.name`. Run `aiteamforge setup --non-interactive`. After: `jq -r '.machine.name' ~/.aiteamforge/config.json`
**Expected Result:** Resulting config uses `hostname -s` as machine name. No interactive prompt occurs. Exit code is 0.
**Pass/Fail:** [ ]

---

### Phase 2 Summary

| Section | Test Count | Pass | Fail | Skip | Warn |
|---------|-----------|------|------|------|------|
| 2.1 Homebrew Tap Registration | 3 | | | | |
| 2.2 Homebrew Formula Installation | 9 | | | | |
| 2.3 Dry-Run Mode | 2 | | | | |
| 2.4 Wizard: Prerequisites Check | 5 | | | | |
| 2.5 Wizard: Machine Identity | 4 | | | | |
| 2.6 Wizard: Team Selection | 3 | | | | |
| 2.7 Wizard: Feature Selection | 5 | | | | |
| 2.8 Configuration Generation | 7 | | | | |
| 2.9 Directory Structure | 7 | | | | |
| 2.10 Shell Integration | 6 | | | | |
| 2.11 Claude Code Configuration | 7 | | | | |
| 2.12 LCARS Kanban Service | 3 | | | | |
| 2.13 Health Check and Status | 6 | | | | |
| 2.14 Framework vs. Working Layer | 4 | | | | |
| 2.15 Non-Interactive Mode | 2 | | | | |
| **Phase 2 Total** | **73** | | | | |

**Phase 2 Pass Threshold:** All tests in sections 2.1, 2.2, 2.8, 2.10, and 2.13 must pass with zero failures. Sections 2.3, 2.14, and 2.15 failures are blocking. Sections 2.11 and 2.12 may have `[S]` results for optional features not selected during the test run.

**Phase 2 Result:** [ ] PASS   [ ] FAIL

**Phase 2 Tester:** ____________________
**Date Tested:** ____________________
**AITeamForge Version Installed:** ____________________
**macOS Version:** ____________________
**Architecture:** [ ] Apple Silicon (ARM64)   [ ] Intel (x86_64)

**Notes:**
```
brew --prefix:
Framework libexec path:
Working directory path:
Config directory path:
LCARS server port:
Teams selected during test:
Features enabled during test:
Issues found:
```

---

*Proceed to Phase 3: Setup Wizard — Initial Team Setup*

---

## Phase 3: Initial Team Setup — Academy (Foundation) + 2 Platform Teams

**Purpose:** Validate the team installation workflow end-to-end by installing the Academy
infrastructure team first (which is the recommended starting point), then two platform teams
(iOS and Firebase). Verify that each installation produces the correct directory structure,
persona files, kanban board, shell aliases, and LCARS port assignments. Confirm that teams
remain isolated from one another at the data and shell-alias level.

**Prerequisites:** Phase 2 complete. AITeamForge formula installed. `aiteamforge` command is
available in PATH. Working directory `~/aiteamforge` exists.

**Teams under test in this phase:**

| Order | Team ID | Name | Category | LCARS Port |
|-------|---------|------|----------|------------|
| 1st | `academy` | Starfleet Academy | Infrastructure | 8200 |
| 2nd | `ios` | Star Trek: TNG — iOS | Platform | 8260 |
| 3rd | `firebase` | Star Trek: DS9 — Firebase | Platform | 8240 |

---

### 3.0 Phase 3 Preconditions

Before running any test in this phase, confirm the following:

- [ ] `~/aiteamforge` directory exists (created during Phase 2 / formula install)
- [ ] No team subdirectories exist yet (`ls ~/aiteamforge/` shows no `academy/`, `ios/`, or `firebase/` directories)
- [ ] Shell session is fresh (run `exec zsh` to reload if in doubt)

---

## Section 3.1 — Academy Team Installation

### Test 3.1.1: Academy Team Install Command Succeeds
**Action:**
```
aiteamforge install-team academy
```
**Expected Result:** Command completes without error. Output includes the banner lines:
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Installing Team: academy
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```
Output includes at minimum:
- `Team Name: Starfleet Academy`
- `Category: infrastructure`
- Lines confirming directory creation, persona installation, kanban board creation, and LCARS port assignments
- Final banner: `✅ Team Installation Complete: Starfleet Academy`

Exit code is 0.
**Pass/Fail:** [ ]

---

### Test 3.1.2: Academy Base Directory Structure Created
**Action:**
```
ls ~/aiteamforge/academy/
```
**Expected Result:** Output lists all of the following subdirectories (order may vary):
```
personas/
scripts/
terminals/
```
No error. No missing directories.
**Pass/Fail:** [ ]

---

### Test 3.1.3: Academy Persona Subdirectories Created
**Action:**
```
ls ~/aiteamforge/academy/personas/
```
**Expected Result:** Output lists all of the following subdirectories:
```
agents/
avatars/
docs/
```
**Pass/Fail:** [ ]

---

### Test 3.1.4: Academy Agent Persona Files Installed
**Action:**
```
ls ~/aiteamforge/academy/personas/agents/
```
**Expected Result:** Output includes persona definition files for all four Academy agents:
```
academy_emh_documentation_persona.md
academy_nahla_chancellor_persona.md
academy_reno_engineer_persona.md
academy_thok_testing_persona.md
```
All four files must be present. File sizes must be greater than 0 bytes.
**Pass/Fail:** [ ]

---

### Test 3.1.5: Academy Prompt Files Installed in scripts/prompts/
**Action:**
```
ls ~/aiteamforge/academy/scripts/prompts/
```
**Expected Result:** Output lists `.txt` system prompt files for the Academy agents. At minimum:
```
academy-chancellor-prompt.txt
academy-engineering-prompt.txt
academy-medical-prompt.txt
academy-training-prompt.txt
```
All files must be present and non-empty.
**Pass/Fail:** [ ]

---

### Test 3.1.6: Academy Kanban Board Created
**Action:**
```
cat ~/aiteamforge/kanban/academy-board.json
```
**Expected Result:** Output is valid JSON containing the following fields with these exact values:
- `"team": "academy"`
- `"teamName": "Starfleet Academy"`
- `"version": "1.3.0"`
- `"items": {}` (empty object — no items yet)
- `"metadata"` object with `"created"` and `"lastModified"` timestamps in ISO 8601 format

No JSON parse errors. File is not empty.
**Pass/Fail:** [ ]

---

### Test 3.1.7: Academy Kanban Board Is Valid JSON
**Action:**
```
jq empty ~/aiteamforge/kanban/academy-board.json && echo "valid"
```
**Expected Result:** Output is `valid`. Exit code is 0. No parse errors printed to stderr.
**Pass/Fail:** [ ]

---

### Test 3.1.8: Academy LCARS Port Assignment Files Created
**Action:**
```
ls ~/aiteamforge/lcars-ports/ | grep "^academy-"
```
**Expected Result:** Output lists one `.port`, `.theme`, and `.order` file for each Academy agent
(chancellor, reno, emh, thok). Minimum expected files:
```
academy-chancellor.port
academy-chancellor.theme
academy-chancellor.order
academy-emh.port
academy-emh.theme
academy-emh.order
academy-reno.port
academy-reno.theme
academy-reno.order
academy-thok.port
academy-thok.theme
academy-thok.order
```
**Pass/Fail:** [ ]

---

### Test 3.1.9: Academy Chancellor Port Assignment Is Correct
**Action:**
```
cat ~/aiteamforge/lcars-ports/academy-chancellor.port
```
**Expected Result:** Output is `8200` (base LCARS port for the Academy team, agent index 0).
**Pass/Fail:** [ ]

---

### Test 3.1.10: Academy Theme Color File Written
**Action:**
```
cat ~/aiteamforge/lcars-ports/academy-chancellor.theme
```
**Expected Result:** Output is `#0099CC` (Academy team color as defined in `academy.conf`).
**Pass/Fail:** [ ]

---

### Test 3.1.11: Academy Banner Script Generated
**Action:**
```
ls ~/aiteamforge/academy/scripts/academy-banner.sh && head -3 ~/aiteamforge/academy/scripts/academy-banner.sh
```
**Expected Result:** File exists. First three lines include a shebang (`#!/`) and a comment
referencing the Academy team. File is executable (`-rwxr-xr-x` permissions or similar).
**Pass/Fail:** [ ]

---

### Test 3.1.12: Academy Startup Script Generated
**Action:**
```
ls -l ~/aiteamforge/academy-startup.sh
```
**Expected Result:** File exists in `~/aiteamforge/`. File permissions show it is executable
(`-rwx------` or similar). File size is greater than 0.
**Pass/Fail:** [ ]

---

### Test 3.1.13: Academy Shutdown Script Generated
**Action:**
```
ls -l ~/aiteamforge/academy-shutdown.sh
```
**Expected Result:** File exists in `~/aiteamforge/`. File is executable. File size is greater
than 0.
**Pass/Fail:** [ ]

---

### Test 3.1.14: Academy Agent Aliases Added to Aliases File
**Action:**
```
grep "^alias academy-" ~/aiteamforge/claude_agent_aliases.sh
```
**Expected Result:** Output contains one alias line for each Academy agent. The four expected
aliases are:
```
alias academy-chancellor=...
alias academy-reno=...
alias academy-emh=...
alias academy-thok=...
```
All four must be present. No duplicate entries.
**Pass/Fail:** [ ]

---

### Test 3.1.15: Academy Avatar Images Added to Shared Pool
**Action:**
```
ls ~/aiteamforge/avatars/ | grep -i "academy\|chancellor\|reno\|emh\|thok" | wc -l
```
**Expected Result:** Output is a number greater than 0 (at least one Academy-related avatar PNG
copied into the shared avatars pool). If the Academy persona set includes avatar images, all
expected images are present.
**Pass/Fail:** [ ]

---

## Section 3.2 — iOS Team Installation

### Test 3.2.1: iOS Team Install Command Succeeds
**Action:**
```
aiteamforge install-team ios
```
**Expected Result:** Command completes without error. Output includes:
- `Installing Team: ios`
- `Team Name: Star Trek: TNG - iOS`
- `Category: platform`
- Confirmation of directory creation, persona installation, kanban board creation, and port assignments
- Final line: `✅ Team Installation Complete: Star Trek: TNG - iOS`

Exit code is 0.
**Pass/Fail:** [ ]

---

### Test 3.2.2: iOS Base Directory Structure Created
**Action:**
```
ls ~/aiteamforge/ios/
```
**Expected Result:** Output lists `personas/`, `scripts/`, and `terminals/` subdirectories.
No error. The iOS directory is completely independent of the Academy directory.
**Pass/Fail:** [ ]

---

### Test 3.2.3: iOS Agent Persona Files Installed
**Action:**
```
ls ~/aiteamforge/ios/personas/agents/
```
**Expected Result:** Persona definition files exist for the iOS team agents (captain, doctor,
seven, kim, torres, wesley, tuvok). All seven agents must have corresponding persona files.
File sizes must be greater than 0 bytes.
**Pass/Fail:** [ ]

---

### Test 3.2.4: iOS Prompt Files Installed in scripts/prompts/
**Action:**
```
ls ~/aiteamforge/ios/scripts/prompts/*.txt 2>/dev/null | wc -l
```
**Expected Result:** Output is a number greater than 0 (at least one `.txt` prompt file installed
for the iOS team). Each file must be non-empty.
**Pass/Fail:** [ ]

---

### Test 3.2.5: iOS Kanban Board Created with Correct Metadata
**Action:**
```
jq '{team, teamName, version, items}' ~/aiteamforge/kanban/ios-board.json
```
**Expected Result:** Output is:
```json
{
  "team": "ios",
  "teamName": "Star Trek: TNG - iOS",
  "version": "1.3.0",
  "items": {}
}
```
Exit code is 0. No parse errors.
**Pass/Fail:** [ ]

---

### Test 3.2.6: iOS LCARS Port Assignment Uses Correct Base Port
**Action:**
```
cat ~/aiteamforge/lcars-ports/ios-captain.port
```
**Expected Result:** Output is `8260` (iOS team base port, agent index 0 = captain).
**Pass/Fail:** [ ]

---

### Test 3.2.7: iOS Team Color Written to Theme Files
**Action:**
```
cat ~/aiteamforge/lcars-ports/ios-captain.theme
```
**Expected Result:** Output is `#FF9500` (iOS team orange color as defined in `ios.conf`).
**Pass/Fail:** [ ]

---

### Test 3.2.8: iOS Agent Aliases Added Without Overwriting Academy Aliases
**Action:**
```
grep "^alias ios-" ~/aiteamforge/claude_agent_aliases.sh | wc -l
```
**Expected Result:** Output is `7` (one alias per iOS agent: captain, doctor, seven, kim,
torres, wesley, tuvok).
**Pass/Fail:** [ ]

---

### Test 3.2.9: Academy Aliases Still Present After iOS Install
**Action:**
```
grep "^alias academy-" ~/aiteamforge/claude_agent_aliases.sh | wc -l
```
**Expected Result:** Output is `4` (same four Academy aliases from section 3.1). iOS installation
must not have removed or duplicated the Academy alias block.
**Pass/Fail:** [ ]

---

## Section 3.3 — Firebase Team Installation

### Test 3.3.1: Firebase Team Install Command Succeeds
**Action:**
```
aiteamforge install-team firebase
```
**Expected Result:** Command completes without error. Output includes:
- `Installing Team: firebase`
- `Team Name: Star Trek: DS9 - Firebase`
- `Category: platform`
- Confirmation of directory creation, persona installation, kanban board creation, and port assignments
- Final line: `✅ Team Installation Complete: Star Trek: DS9 - Firebase`

Exit code is 0.
**Pass/Fail:** [ ]

---

### Test 3.3.2: Firebase Base Directory Structure Created
**Action:**
```
ls ~/aiteamforge/firebase/
```
**Expected Result:** Output lists `personas/`, `scripts/`, and `terminals/` subdirectories.
The Firebase directory is independent of the Academy and iOS directories.
**Pass/Fail:** [ ]

---

### Test 3.3.3: Firebase Agent Persona Files Installed
**Action:**
```
ls ~/aiteamforge/firebase/personas/agents/
```
**Expected Result:** Persona definition files exist for the Firebase team agents (sisko, kira,
odo, dax, bashir, obrien, quark). All seven agents must have corresponding persona files.
**Pass/Fail:** [ ]

---

### Test 3.3.4: Firebase Kanban Board Created with Correct Metadata
**Action:**
```
jq '{team, teamName, version, items}' ~/aiteamforge/kanban/firebase-board.json
```
**Expected Result:** Output is:
```json
{
  "team": "firebase",
  "teamName": "Star Trek: DS9 - Firebase",
  "version": "1.3.0",
  "items": {}
}
```
Exit code is 0. No parse errors.
**Pass/Fail:** [ ]

---

### Test 3.3.5: Firebase LCARS Port Assignment Uses Correct Base Port
**Action:**
```
cat ~/aiteamforge/lcars-ports/firebase-sisko.port
```
**Expected Result:** Output is `8240` (Firebase team base port, agent index 0 = sisko).
**Pass/Fail:** [ ]

---

### Test 3.3.6: Firebase Team Color Written to Theme Files
**Action:**
```
cat ~/aiteamforge/lcars-ports/firebase-sisko.theme
```
**Expected Result:** Output is `#FFCA28` (Firebase team yellow/amber color as defined in
`firebase.conf`).
**Pass/Fail:** [ ]

---

### Test 3.3.7: Firebase Agent Aliases Added Without Overwriting Prior Teams
**Action:**
```
grep "^alias firebase-" ~/aiteamforge/claude_agent_aliases.sh | wc -l
```
**Expected Result:** Output is `7` (one alias per Firebase agent: sisko, kira, odo, dax,
bashir, obrien, quark).
**Pass/Fail:** [ ]

---

## Section 3.4 — Three-Team Kanban Isolation

### Test 3.4.1: Three Separate Kanban Board Files Exist
**Action:**
```
ls ~/aiteamforge/kanban/ | grep "\-board\.json"
```
**Expected Result:** Output lists exactly (at minimum) these three files:
```
academy-board.json
firebase-board.json
ios-board.json
```
Each team has its own isolated board file. No single shared board file.
**Pass/Fail:** [ ]

---

### Test 3.4.2: Academy Board Team Field Is Correct
**Action:**
```
jq '.team' ~/aiteamforge/kanban/academy-board.json
```
**Expected Result:** Output is `"academy"`. The board's `team` field reflects only the Academy
team. No iOS or Firebase references appear in the top-level metadata.
**Pass/Fail:** [ ]

---

### Test 3.4.3: iOS Board Team Field Is Correct
**Action:**
```
jq '.team' ~/aiteamforge/kanban/ios-board.json
```
**Expected Result:** Output is `"ios"`.
**Pass/Fail:** [ ]

---

### Test 3.4.4: Firebase Board Team Field Is Correct
**Action:**
```
jq '.team' ~/aiteamforge/kanban/firebase-board.json
```
**Expected Result:** Output is `"firebase"`.
**Pass/Fail:** [ ]

---

### Test 3.4.5: Adding an Item to Academy Board Does Not Affect iOS Board
**Action:** Add a test item to the Academy board (using the kanban CLI installed by aiteamforge),
then inspect the iOS board:
```
aiteamforge kanban add academy "Test isolation item"
jq '.items | length' ~/aiteamforge/kanban/ios-board.json
```
**Expected Result:** The iOS board item count remains `0`. The Academy board item count is `1`.
No cross-contamination between board files.
**Pass/Fail:** [ ]

---

## Section 3.5 — Shell Alias and Agent Persona Loading

### Test 3.5.1: Academy Alias Resolves in Fresh Shell
**Action:** Open a new terminal window (or run `exec zsh`), then:
```
type academy-chancellor
```
**Expected Result:** Output shows the alias definition — something like:
```
academy-chancellor is an alias for claude --agent-path ...
```
The alias is available without manually sourcing any file (loaded by `.zshrc` integration
installed in Phase 2).
**Pass/Fail:** [ ]

---

### Test 3.5.2: iOS Agent Alias Resolves in Fresh Shell
**Action:** In the same new shell session:
```
type ios-captain
```
**Expected Result:** Output shows the iOS captain alias definition. No "not found" error.
**Pass/Fail:** [ ]

---

### Test 3.5.3: Firebase Agent Alias Resolves in Fresh Shell
**Action:**
```
type firebase-sisko
```
**Expected Result:** Output shows the Firebase sisko alias definition. No "not found" error.
**Pass/Fail:** [ ]

---

### Test 3.5.4: Academy Agent Persona File Is Valid Markdown
**Action:**
```
wc -l ~/aiteamforge/academy/personas/agents/academy_thok_testing_persona.md
```
**Expected Result:** Output shows a line count greater than 10 (the persona file is substantive,
not empty or a stub). File is readable text with no binary content.
**Pass/Fail:** [ ]

---

### Test 3.5.5: iOS Agent Prompt Files Are Non-Empty
**Action:**
```
wc -c ~/aiteamforge/ios/scripts/prompts/*.txt | tail -1
```
**Expected Result:** The total byte count shown on the `total` line is greater than 100. No
individual file is zero bytes.
**Pass/Fail:** [ ]

---

### Test 3.5.6: No Alias Collisions Across Three Teams
**Action:**
```
grep "^alias academy-\|^alias ios-\|^alias firebase-" ~/aiteamforge/claude_agent_aliases.sh | sort | uniq -d
```
**Expected Result:** No output (empty). `uniq -d` prints only duplicate lines; an empty result
confirms there are no duplicate alias definitions across the three teams.
**Pass/Fail:** [ ]

---

## Section 3.6 — LCARS Port Isolation Between Teams

### Test 3.6.1: No Two Teams Share the Same Base Port
**Action:**
```
cat ~/aiteamforge/lcars-ports/academy-chancellor.port \
    ~/aiteamforge/lcars-ports/ios-captain.port \
    ~/aiteamforge/lcars-ports/firebase-sisko.port
```
**Expected Result:** Three distinct values on separate lines:
```
8200
8260
8240
```
All three port numbers are different. No two teams share the same base port.
**Pass/Fail:** [ ]

---

### Test 3.6.2: Agent Ports Within a Team Are Sequential
**Action:**
```
cat ~/aiteamforge/lcars-ports/academy-chancellor.port \
    ~/aiteamforge/lcars-ports/academy-reno.port \
    ~/aiteamforge/lcars-ports/academy-emh.port \
    ~/aiteamforge/lcars-ports/academy-thok.port
```
**Expected Result:** Four sequential port numbers starting from the team base port (8200):
```
8200
8201
8202
8203
```
Exact order depends on agent array order in `academy.conf`; all four values must be distinct
and within the range 8200-8203.
**Pass/Fail:** [ ]

---

### Test 3.6.3: Order Files Reflect Agent Index
**Action:**
```
cat ~/aiteamforge/lcars-ports/academy-chancellor.order
cat ~/aiteamforge/lcars-ports/academy-reno.order
```
**Expected Result:** First command outputs `0` (chancellor is agent index 0). Second command
outputs `1` (reno is agent index 1).
**Pass/Fail:** [ ]

---

## Section 3.7 — Team Directory Isolation

### Test 3.7.1: Academy Directory Contains No iOS Agent Files
**Action:**
```
ls ~/aiteamforge/academy/personas/agents/ | grep -i "captain\|doctor\|seven\|kim\|torres\|wesley\|tuvok"
```
**Expected Result:** No output (empty). iOS agent personas must not appear in the Academy
personas directory.
**Pass/Fail:** [ ]

---

### Test 3.7.2: iOS Directory Contains No Firebase Agent Files
**Action:**
```
ls ~/aiteamforge/ios/personas/agents/ | grep -i "sisko\|kira\|odo\|dax\|bashir\|obrien\|quark"
```
**Expected Result:** No output (empty). Firebase agent personas must not appear in the iOS
personas directory.
**Pass/Fail:** [ ]

---

### Test 3.7.3: Firebase Directory Contains No Academy Agent Files
**Action:**
```
ls ~/aiteamforge/firebase/personas/agents/ | grep -i "chancellor\|reno\|emh\|thok"
```
**Expected Result:** No output (empty). Academy agent personas must not appear in the Firebase
personas directory.
**Pass/Fail:** [ ]

---

### Test 3.7.4: Startup Scripts Are Team-Specific
**Action:**
```
ls ~/aiteamforge/ | grep "\-startup\.sh"
```
**Expected Result:** Output lists one startup script per installed team:
```
academy-startup.sh
firebase-startup.sh
ios-startup.sh
```
(Order may vary.) No shared or generic startup script is used by multiple teams.
**Pass/Fail:** [ ]

---

### Test 3.7.5: Academy Banner Script Is Not Present in iOS Scripts Directory
**Action:**
```
ls ~/aiteamforge/ios/scripts/ | grep "academy"
```
**Expected Result:** No output (empty). Academy-specific scripts (e.g., `academy-banner.sh`)
must not appear in the iOS scripts directory.
**Pass/Fail:** [ ]

---

## Section 3.8 — Idempotency (Re-running install-team)

### Test 3.8.1: Re-running Academy Install Does Not Duplicate Aliases
**Action:**
```
aiteamforge install-team academy
grep "^alias academy-chancellor=" ~/aiteamforge/claude_agent_aliases.sh | wc -l
```
**Expected Result:** The install command completes without error. The alias count for
`academy-chancellor` in the aliases file is exactly `1`. Re-running install does not add a
second copy of the alias block.
**Pass/Fail:** [ ]

---

### Test 3.8.2: Re-running Academy Install Does Not Reset Kanban Board
**Action:** First confirm an item exists on the Academy board (from test 3.4.5 or add one now).
Record the item count, then re-run install and check again:
```
BEFORE=$(jq '.items | length' ~/aiteamforge/kanban/academy-board.json)
aiteamforge install-team academy
AFTER=$(jq '.items | length' ~/aiteamforge/kanban/academy-board.json)
echo "Before: $BEFORE  After: $AFTER"
```
**Expected Result:** Both values are identical. The installer outputs `✓ Kanban board already
exists` and does not overwrite the board with an empty items object.
**Pass/Fail:** [ ]

---

### Test 3.8.3: Re-running Academy Install Does Not Overwrite Port Files
**Action:**
```
BEFORE=$(cat ~/aiteamforge/lcars-ports/academy-chancellor.port)
aiteamforge install-team academy
AFTER=$(cat ~/aiteamforge/lcars-ports/academy-chancellor.port)
echo "Before: $BEFORE  After: $AFTER"
```
**Expected Result:** Both values are identical (e.g., `Before: 8200  After: 8200`). The
installer skips creating port files that already exist.
**Pass/Fail:** [ ]

---

## Section 3.9 — Invalid Team ID Handling

### Test 3.9.1: Unknown Team ID Returns Error
**Action:**
```
aiteamforge install-team nonexistent-team-xyz 2>&1; echo "Exit: $?"
```
**Expected Result:** Output includes an error message such as:
```
Error: Team configuration not found: .../teams/nonexistent-team-xyz.conf
```
Exit code is non-zero (typically 1). No team directory is created. No kanban board is created.
**Pass/Fail:** [ ]

---

### Test 3.9.2: Team ID With Invalid Characters Returns Error
**Action:**
```
aiteamforge install-team "bad team name!" 2>&1; echo "Exit: $?"
```
**Expected Result:** Output includes an error message about the invalid team ID format:
```
Error: Invalid team ID: bad team name! (alphanumeric, hyphens, and underscores only)
```
Exit code is non-zero. Input validation fires before any file system operations occur.
**Pass/Fail:** [ ]

---

### Test 3.9.3: No Team ID Argument Shows Usage and Available Teams
**Action:**
```
aiteamforge install-team 2>&1; echo "Exit: $?"
```
**Expected Result:** Output includes usage instructions and a list of available team IDs, similar to:
```
Usage: install-team.sh <team-id> [--install-dir <path>]

Available teams:
academy
android
...
```
Exit code is non-zero (1). No partial installation occurs.
**Pass/Fail:** [ ]

---

## Section 3.10 — Post-Install State Summary

After completing all tests in sections 3.1 through 3.9, verify the overall installed state.

### Test 3.10.1: Three Team Directories Present
**Action:**
```
ls ~/aiteamforge/ | grep -E "^(academy|ios|firebase)$" | sort
```
**Expected Result:** Exactly three lines:
```
academy
firebase
ios
```
**Pass/Fail:** [ ]

---

### Test 3.10.2: Three Kanban Board Files Present
**Action:**
```
ls ~/aiteamforge/kanban/ | grep "\-board\.json" | sort
```
**Expected Result:** At minimum three board files listed:
```
academy-board.json
firebase-board.json
ios-board.json
```
**Pass/Fail:** [ ]

---

### Test 3.10.3: Shared Avatars Pool Populated
**Action:**
```
ls ~/aiteamforge/avatars/ | wc -l
```
**Expected Result:** Output is a number greater than 0. Avatar images from at least one
installed team have been copied into the shared pool. A count of 0 is acceptable only if all
three teams define no avatar images in their persona sets.
**Pass/Fail:** [ ]

---

### Test 3.10.4: Aliases File Contains All Three Team Sections
**Action:**
```
grep "^# .*aliases$" ~/aiteamforge/claude_agent_aliases.sh
```
**Expected Result:** Output includes comment headers for all three teams (exact wording matches
each team's name from their `.conf` file):
```
# Starfleet Academy aliases
# Star Trek: TNG - iOS aliases
# Star Trek: DS9 - Firebase aliases
```
(Order may vary based on installation sequence.)
**Pass/Fail:** [ ]

---

### Phase 3 Summary

Record the results for this phase before proceeding to Phase 4.

| Section | Description | Tests | Passed | Failed |
|---------|-------------|-------|--------|--------|
| 3.1 | Academy team installation | 15 | | |
| 3.2 | iOS team installation | 9 | | |
| 3.3 | Firebase team installation | 7 | | |
| 3.4 | Three-team kanban isolation | 5 | | |
| 3.5 | Shell alias and persona loading | 6 | | |
| 3.6 | LCARS port isolation | 3 | | |
| 3.7 | Team directory isolation | 5 | | |
| 3.8 | Idempotency (re-run install) | 3 | | |
| 3.9 | Invalid team ID handling | 3 | | |
| 3.10 | Post-install state summary | 4 | | |
| **Total** | | **60** | | |

**Phase 3 Pass/Fail Criteria:**
- All tests in sections 3.1, 3.2, and 3.3 must pass (installation succeeds for all three teams)
- All tests in sections 3.4, 3.7, and 3.8 must pass (isolation and idempotency guaranteed)
- All tests in section 3.9 must pass (invalid inputs rejected gracefully)
- Sections 3.5, 3.6, and 3.10 must pass for full verification
- Phase 3 is PASS when all 60 tests pass
- Phase 3 is FAIL if any test in sections 3.1-3.9 fails — do not proceed to Phase 4 until resolved

**Phase 3 Result:** [ ] PASS   [ ] FAIL

**Notes (record any observations, unexpected output, or deviations from expected results):**

```
Academy install duration (seconds):
iOS install duration (seconds):
Firebase install duration (seconds):
Academy kanban board path:
iOS kanban board path:
Firebase kanban board path:
Avatar images found in shared pool: ____
Total alias count in aliases file: ____
Idempotency re-run — any issues observed: [ ] Yes [ ] No
Details:
```

---

*Proceed to Phase 4: Additional Team Setup*

---

## Phase 4: Additional Team Setup (Add More Teams Later)

**Purpose:** Validate that new teams can be added incrementally to an existing AITeamForge
installation without disrupting previously configured teams. This phase exercises the incremental
team addition workflow, verifies complete isolation between teams, and confirms that both
platform-separated (standard) and project-based (full-stack) team types install correctly.

**Prerequisites:** Phase 3 must be complete. At least one team (Academy) must be installed and
running. The initial team installation from Phase 3 provides the baseline state this phase
validates against.

**Baseline state before starting Phase 4:**
- Academy team installed and LCARS server responding on its configured port
- At least one platform team (e.g., iOS, Firebase) installed from Phase 3
- `aiteamforge doctor` passing all checks
- Shell aliases sourced and functional

---

### 4.1 Baseline Verification Before Adding Teams

Confirm existing teams are healthy before any incremental additions. A failure here indicates
a Phase 3 issue that must be resolved before proceeding.

### Test 4.1.1: Existing Teams Directory Structure Intact
**Action:** Run the following, substituting the actual teams installed in Phase 3:
```
ls ~/aiteamforge/academy/
ls ~/aiteamforge/ios/
```
**Expected Result:** Both directories exist and contain subdirectories including `personas/`,
`scripts/`, and `terminals/`. No "No such file or directory" errors.
**Pass/Fail:** [ ]

### Test 4.1.2: Existing LCARS Servers Responding
**Action:** Run health checks for all teams installed in Phase 3. Adjust ports to match your
Phase 3 configuration (Academy default is 8200, iOS default is 8260):
```
curl -s -o /dev/null -w "%{http_code}" http://localhost:8200/api/health
curl -s -o /dev/null -w "%{http_code}" http://localhost:8260/api/health
```
**Expected Result:** Each command returns `200`. If any team was not started after Phase 3,
start it first with `aiteamforge start` before running this test.
**Pass/Fail:** [ ]

### Test 4.1.3: Existing Kanban Boards Present
**Action:** Run:
```
ls ~/aiteamforge/kanban/
```
**Expected Result:** At minimum, `academy-board.json` and `ios-board.json` (or equivalent Phase 3
teams) are listed. All boards are non-empty files.
**Pass/Fail:** [ ]

### Test 4.1.4: Existing Aliases Functional
**Action:** Run:
```
grep -c "academy" ~/aiteamforge/claude_agent_aliases.sh
grep -c "ios" ~/aiteamforge/claude_agent_aliases.sh
```
**Expected Result:** Each command returns a number greater than 0, confirming the alias sections
for the Phase 3 teams exist in the aliases file.
**Pass/Fail:** [ ]

### Test 4.1.5: Registry Lists Available Teams
**Action:** Run:
```
aiteamforge list
```
**Expected Result:** Command outputs a list of available teams from the registry. The list
includes teams not yet installed (android, firebase, freelance, command, etc.) and marks already-
installed teams as installed. No error output.
**Pass/Fail:** [ ]

---

### 4.2 Adding a Platform-Separated Team (Android)

Android is a standard platform-separated team: it has its own LCARS port, its own kanban board,
and its own agent aliases. It does not share a working directory with other teams.

### Test 4.2.1: Install Android Team
**Action:** Run:
```
aiteamforge setup --add-team android
```
**Expected Result:** The installer runs without errors. Output confirms each installation step:
Homebrew dependencies checked (gradle, kotlin), team directory created at
`~/aiteamforge/android/`, startup and shutdown scripts generated, kanban board created, LCARS
port files created (port 8280), agent aliases appended to
`~/aiteamforge/claude_agent_aliases.sh`. Final summary shows
"Team Installation Complete: Star Trek: TOS - Android".
**Pass/Fail:** [ ]

### Test 4.2.2: Android Team Directory Structure Created
**Action:** Run:
```
ls ~/aiteamforge/android/
ls ~/aiteamforge/android/personas/
ls ~/aiteamforge/android/scripts/
```
**Expected Result:** `~/aiteamforge/android/` exists and contains `personas/`, `scripts/`, and
`terminals/` subdirectories. No errors.
**Pass/Fail:** [ ]

### Test 4.2.3: Android Startup Script Generated and Executable
**Action:** Run:
```
ls -la ~/aiteamforge/android-startup.sh
```
**Expected Result:** File exists and is executable (permissions include `x`). Size is non-zero.
**Pass/Fail:** [ ]

### Test 4.2.4: Android Kanban Board Created
**Action:** Run:
```
ls ~/aiteamforge/kanban/android-board.json
```
**Expected Result:** File exists.
**Pass/Fail:** [ ]

### Test 4.2.5: Android Kanban Board Is Valid JSON With Correct Team ID
**Action:** Run:
```
jq '.team' ~/aiteamforge/kanban/android-board.json
```
**Expected Result:** Output is `"android"` (with quotes). No parse errors.
**Pass/Fail:** [ ]

### Test 4.2.6: Android LCARS Base Port File Created
**Action:** Run:
```
cat ~/aiteamforge/lcars-ports/android-kirk.port
```
**Expected Result:** Output is `8280` (the base Android LCARS port, agent index 0). Port file
exists.
**Pass/Fail:** [ ]

### Test 4.2.7: Android Agent Port Files Sequential From Base Port
**Action:** Run:
```
cat ~/aiteamforge/lcars-ports/android-mccoy.port
```
**Expected Result:** Output is `8281` (base port 8280 + agent index 1).
**Pass/Fail:** [ ]

### Test 4.2.8: Android Aliases Added for All Seven Agents
**Action:** Run:
```
grep "android-" ~/aiteamforge/claude_agent_aliases.sh | wc -l
```
**Expected Result:** Returns `7` (one alias for each Android agent: kirk, mccoy, scotty, uhura,
sulu, chekov, spock).
**Pass/Fail:** [ ]

### Test 4.2.9: Previously Installed Teams Unaffected After Android Addition
**Action:** Run:
```
ls ~/aiteamforge/academy/
ls ~/aiteamforge/ios/
curl -s -o /dev/null -w "%{http_code}" http://localhost:8200/api/health
curl -s -o /dev/null -w "%{http_code}" http://localhost:8260/api/health
```
**Expected Result:** Both team directories exist intact. Both LCARS health checks return `200`.
The Android installation did not touch or modify any previously installed team's files or ports.
**Pass/Fail:** [ ]

---

### 4.3 Adding a Second Additional Platform Team (Firebase)

Firebase is another platform-separated team with a different LCARS port range. This test confirms
that multiple sequential incremental additions work correctly and that port assignments do not
conflict with previously installed teams.

### Test 4.3.1: Install Firebase Team
**Action:** Run:
```
aiteamforge setup --add-team firebase
```
**Expected Result:** Installer completes without errors. Output includes team name
"Star Trek: DS9 - Firebase", LCARS port 8240, and confirmation of all installation steps.
**Pass/Fail:** [ ]

### Test 4.3.2: Firebase Team Directory Created With Correct Structure
**Action:** Run:
```
ls ~/aiteamforge/firebase/
```
**Expected Result:** Directory exists with `personas/`, `scripts/`, and `terminals/`
subdirectories.
**Pass/Fail:** [ ]

### Test 4.3.3: Firebase Port Range Does Not Conflict With Android Port Range
**Action:** Run:
```
cat ~/aiteamforge/lcars-ports/firebase-*.port | sort -n | head -1
cat ~/aiteamforge/lcars-ports/android-*.port | sort -n | head -1
```
**Expected Result:** The lowest Firebase port value is 8240. The lowest Android port value is
8280. The two ranges do not overlap. No port number appears in both teams' port files.
**Pass/Fail:** [ ]

### Test 4.3.4: All Previously Installed Teams Unaffected After Firebase Addition
**Action:** Run:
```
curl -s -o /dev/null -w "%{http_code}" http://localhost:8200/api/health
curl -s -o /dev/null -w "%{http_code}" http://localhost:8260/api/health
jq '.team' ~/aiteamforge/kanban/academy-board.json
jq '.team' ~/aiteamforge/kanban/ios-board.json
jq '.team' ~/aiteamforge/kanban/android-board.json
```
**Expected Result:** Both LCARS servers return `200`. All three kanban board `team` fields return
their expected team IDs (`"academy"`, `"ios"`, `"android"`). No file corruption.
**Pass/Fail:** [ ]

---

### 4.4 Adding a Project-Based Team (Freelance)

The Freelance team uses `TEAM_HAS_PROJECTS="true"` and `TEAM_REQUIRES_CLIENT_ID="true"`. This
team type uses a different startup script template and handles working directories differently
from platform-separated teams. This test confirms that both organizational models coexist
correctly after installation.

### Test 4.4.1: Install Freelance Team
**Action:** Run:
```
aiteamforge setup --add-team freelance
```
**Expected Result:** Installer completes without errors. Output shows team name "Star Trek:
Enterprise - Full Stack Team" and port 8300. Installation steps complete: directory structure,
startup/shutdown scripts (using project template), kanban board, LCARS ports, agent aliases.
**Pass/Fail:** [ ]

### Test 4.4.2: Freelance Startup Script Contains Project-Specific Logic
**Action:** Run:
```
grep -c "CLIENT_ID\|client_id\|project" ~/aiteamforge/freelance-startup.sh
```
**Expected Result:** Returns a number greater than 0, confirming the generated startup script
contains project-specific handling (client ID or project directory references).
**Pass/Fail:** [ ]

### Test 4.4.3: Freelance Kanban Board Created in Correct Location With Correct Team ID
**Action:** Run:
```
jq '.team' ~/aiteamforge/kanban/freelance-board.json
```
**Expected Result:** Output is `"freelance"` (with quotes). No parse errors.
**Pass/Fail:** [ ]

### Test 4.4.4: Freelance Team Has All Seven Agent Aliases
**Action:** Run:
```
grep "freelance-" ~/aiteamforge/claude_agent_aliases.sh | wc -l
```
**Expected Result:** Returns `7` (archer, tucker, tpol, phlox, reed, sato, mayweather).
**Pass/Fail:** [ ]

### Test 4.4.5: Platform-Separated Teams Unaffected by Project-Based Team Addition
**Action:** Run:
```
ls ~/aiteamforge/academy/personas/
ls ~/aiteamforge/android/scripts/
ls ~/aiteamforge/firebase/
```
**Expected Result:** All three previously installed platform-separated team directories exist and
are intact. The project-based Freelance installation did not modify or delete any files from
other teams.
**Pass/Fail:** [ ]

---

### 4.5 Adding a Custom Team (User-Defined Configuration)

This test validates the workflow for adding a team not included in the default registry —
the scenario described in `ADDING_A_TEAM.md`. A minimal custom configuration is created and
installed, confirming that user-defined teams work without modifying AITeamForge internals.

### Test 4.5.1: Create Custom Team Configuration File
**Action:** Determine the share/teams directory for the installed AITeamForge formula:
```
TEAMS_DIR="$(brew --prefix)/opt/aiteamforge/libexec/share/teams"
```
Create `$TEAMS_DIR/testqa.conf` with the following content:
```
TEAM_ID="testqa"
TEAM_NAME="QA Test Team"
TEAM_DESCRIPTION="Temporary team for installation testing"
TEAM_CATEGORY="platform"
TEAM_COLOR="#FF00FF"
TEAM_LCARS_PORT="8490"
TEAM_TMUX_SOCKET="testqa"
TEAM_WORKING_DIR="$HOME/testqa"
TEAM_HAS_PROJECTS="false"
TEAM_REQUIRES_CLIENT_ID="false"
TEAM_AGENTS=(
    "inspector"
    "validator"
)
TEAM_BREW_DEPS=()
TEAM_BREW_CASK_DEPS=()
TEAM_STARTUP_SCRIPT="testqa-startup.sh"
TEAM_SHUTDOWN_SCRIPT="testqa-shutdown.sh"
TEAM_THEME="Test Theme"
TEAM_SHIP="USS Test Vessel"
```
**Expected Result:** File is created without write errors. Confirm: `ls $TEAMS_DIR/testqa.conf`
**Pass/Fail:** [ ]

### Test 4.5.2: Custom Team Installs Successfully
**Action:** Run:
```
INSTALLER="$(brew --prefix)/opt/aiteamforge/libexec/libexec/installers/install-team.sh"
"$INSTALLER" testqa
```
**Expected Result:** Installer loads the configuration, validates the team ID, and proceeds to
completion without errors. All installation steps (directory structure, scripts, kanban board,
port files, aliases) complete successfully.
**Pass/Fail:** [ ]

### Test 4.5.3: Custom Team Directory Structure Created
**Action:** Run:
```
ls ~/aiteamforge/testqa/
```
**Expected Result:** Directory exists with `personas/`, `scripts/`, and `terminals/`
subdirectories.
**Pass/Fail:** [ ]

### Test 4.5.4: Custom Team Kanban Board Is Valid JSON
**Action:** Run:
```
jq '{team: .team, version: .version}' ~/aiteamforge/kanban/testqa-board.json
```
**Expected Result:** Output shows `"team": "testqa"` and `"version": "1.3.0"`.
**Pass/Fail:** [ ]

### Test 4.5.5: Custom Team Port Files Created With Sequential Port Assignment
**Action:** Run:
```
cat ~/aiteamforge/lcars-ports/testqa-inspector.port
cat ~/aiteamforge/lcars-ports/testqa-validator.port
```
**Expected Result:** First file contains `8490` (base port + agent index 0). Second file contains
`8491` (base port + agent index 1).
**Pass/Fail:** [ ]

### Test 4.5.6: Custom Team Aliases Added for All Agents
**Action:** Run:
```
grep "testqa-" ~/aiteamforge/claude_agent_aliases.sh
```
**Expected Result:** Two alias lines appear: one for `testqa-inspector` and one for
`testqa-validator`.
**Pass/Fail:** [ ]

### Test 4.5.7: Invalid Team ID Is Rejected Before Any Installation Occurs
**Action:** Run:
```
INSTALLER="$(brew --prefix)/opt/aiteamforge/libexec/libexec/installers/install-team.sh"
"$INSTALLER" "bad team name!"
echo "Exit code: $?"
```
**Expected Result:** Output contains "Invalid team ID" and lists the disallowed characters.
Exit code is non-zero (printed by the `echo` line above). No installation steps execute and no
directories or files are created.
**Pass/Fail:** [ ]

### Test 4.5.8: Missing Team Configuration Is Rejected Gracefully
**Action:** Run:
```
INSTALLER="$(brew --prefix)/opt/aiteamforge/libexec/libexec/installers/install-team.sh"
"$INSTALLER" nonexistentteam
echo "Exit code: $?"
```
**Expected Result:** Output contains "Error: Team configuration not found" and shows the expected
path to the missing `.conf` file. Exit code is non-zero. No partial installation occurs.
**Pass/Fail:** [ ]

---

### 4.6 Re-Installing an Existing Team (Idempotency)

Running the installer on an already-installed team must not destroy existing data, overwrite
custom configurations, or produce errors. This validates idempotent installer behavior.

### Test 4.6.1: Re-Install Academy Team Without Data Loss
**Action:** Before re-installing, record the current Academy kanban board item count:
```
jq '.items | length' ~/aiteamforge/kanban/academy-board.json
```
Then run the installer again:
```
aiteamforge setup --add-team academy
```
**Expected Result:** Installer runs without errors. Output indicates existing files are preserved
(e.g., "Kanban board already exists", "Alias section already present"). Exit code is zero.
**Pass/Fail:** [ ]

### Test 4.6.2: Existing Kanban Data Preserved After Re-Install
**Action:** After the re-install from Test 4.6.1, run:
```
jq '.items | length' ~/aiteamforge/kanban/academy-board.json
```
**Expected Result:** Item count is identical to the count recorded before re-install. No kanban
items are lost or reset to empty.
**Pass/Fail:** [ ]

### Test 4.6.3: Existing Port Assignments Unchanged After Re-Install
**Action:** Before re-install, record an Academy agent's port value. After re-install, read the
same file:
```
cat ~/aiteamforge/lcars-ports/academy-<agentname>.port
```
(Substitute an Academy agent name from the academy.conf TEAM_AGENTS list.)
**Expected Result:** Port value is identical before and after re-install. Port files are not
recreated or changed to new values.
**Pass/Fail:** [ ]

---

### 4.7 Verify LCARS UI Updates to Show New Teams

With multiple teams installed, confirm that LCARS server instances for each team correctly
reflect the team identity and that the UI panels show the expected team data.

### Test 4.7.1: Start All Teams
**Action:** Run:
```
aiteamforge start
```
**Expected Result:** Command starts all installed teams without errors. No "address already in
use" or port conflict errors appear. Output shows each team's services starting.
**Pass/Fail:** [ ]

### Test 4.7.2: Each Team's LCARS Server Responds on Its Configured Port
**Action:** Run health checks for all installed teams. Adjust the port list to match your actual
configuration:
```
curl -s -o /dev/null -w "academy (8200): %{http_code}\n" http://localhost:8200/api/health
curl -s -o /dev/null -w "ios (8260): %{http_code}\n" http://localhost:8260/api/health
curl -s -o /dev/null -w "android (8280): %{http_code}\n" http://localhost:8280/api/health
curl -s -o /dev/null -w "firebase (8240): %{http_code}\n" http://localhost:8240/api/health
curl -s -o /dev/null -w "freelance (8300): %{http_code}\n" http://localhost:8300/api/health
```
**Expected Result:** Every command returns `200`. All LCARS servers are running simultaneously
with no port conflicts.
**Pass/Fail:** [ ]

### Test 4.7.3: LCARS UI Loads for Each Team in Browser
**Action:** Open each team's LCARS UI in a browser and confirm it loads without errors:
- `http://localhost:8200/lcars` (Academy)
- `http://localhost:8260/lcars` (iOS)
- `http://localhost:8280/lcars` (Android)
- `http://localhost:8240/lcars` (Firebase)
- `http://localhost:8300/lcars` (Freelance)

**Expected Result:** Each URL loads a LCARS dashboard. The page title or header identifies the
correct team name. No 404 errors, blank pages, or JavaScript console errors for any team.
**Pass/Fail:** [ ]

### Test 4.7.4: LCARS Kanban Endpoint Returns Team-Specific Data
**Action:** For at least two teams, query the kanban API endpoint:
```
curl -s http://localhost:8200/api/board | jq '.team'
curl -s http://localhost:8280/api/board | jq '.team'
```
**Expected Result:** First command returns `"academy"`. Second command returns `"android"`. Each
LCARS server serves its own team's kanban data, not another team's.
**Pass/Fail:** [ ]

### Test 4.7.5: All Port Assignments Are Unique (No Conflicts)
**Action:** Run:
```
sort -un ~/aiteamforge/lcars-ports/*.port | uniq -d
```
**Expected Result:** No output (empty). If any port number appears in both a `.port` file and
another `.port` file, it is listed here — the expected result is that no duplicates exist.
**Pass/Fail:** [ ]

---

### 4.8 Kanban Board Creation for New Teams

Verify that each newly installed team has a properly initialized kanban board with the correct
structure for immediate use.

### Test 4.8.1: All Installed Teams Have Kanban Boards
**Action:** Run:
```
ls ~/aiteamforge/kanban/*-board.json
```
**Expected Result:** One board file exists for each installed team. File names match the pattern
`<team-id>-board.json`. No team installed in this phase is missing its board.
**Pass/Fail:** [ ]

### Test 4.8.2: New Team Kanban Boards Contain Required Top-Level Fields
**Action:** For each new team installed in this phase, verify the board structure:
```
jq 'keys' ~/aiteamforge/kanban/android-board.json
jq 'keys' ~/aiteamforge/kanban/firebase-board.json
jq 'keys' ~/aiteamforge/kanban/freelance-board.json
```
**Expected Result:** Each board contains at minimum the keys: `team`, `teamName`, `version`,
`items`, and `metadata`.
**Pass/Fail:** [ ]

### Test 4.8.3: New Team Kanban Boards Start Empty (No Pre-Existing Items)
**Action:** Run:
```
jq '.items | length' ~/aiteamforge/kanban/android-board.json
jq '.items | length' ~/aiteamforge/kanban/firebase-board.json
```
**Expected Result:** Both commands return `0`. Newly created boards have no pre-existing items.
**Pass/Fail:** [ ]

### Test 4.8.4: Kanban Board Version Is Correct
**Action:** Run:
```
jq '.version' ~/aiteamforge/kanban/android-board.json
```
**Expected Result:** Output is `"1.3.0"` (or the current expected version for this release of
AITeamForge). All team boards use the same schema version.
**Pass/Fail:** [ ]

---

### 4.9 Shell Alias Updates for New Teams

Confirm that new team aliases are appended correctly to the shared aliases file and do not
conflict with or overwrite existing team aliases.

### Test 4.9.1: Aliases File Contains One Section Per Installed Team
**Action:** Run:
```
grep "^# " ~/aiteamforge/claude_agent_aliases.sh | grep "aliases"
```
**Expected Result:** Output includes one comment header line per installed team. The count of
header lines equals the number of teams installed.
**Pass/Fail:** [ ]

### Test 4.9.2: No Duplicate Alias Names Across Teams
**Action:** Run:
```
grep "^alias " ~/aiteamforge/claude_agent_aliases.sh | awk -F'=' '{print $1}' | sort | uniq -d
```
**Expected Result:** No output (empty). If any alias name appears twice, a collision exists
between two teams' configurations.
**Pass/Fail:** [ ]

### Test 4.9.3: Aliases File Is Valid Shell Syntax
**Action:** Run:
```
bash -n ~/aiteamforge/claude_agent_aliases.sh
echo "Syntax check exit code: $?"
```
**Expected Result:** No errors reported. Exit code is `0`. The file is syntactically valid shell
regardless of how many teams have been appended.
**Pass/Fail:** [ ]

### Test 4.9.4: Sourcing Aliases File Does Not Produce Errors
**Action:** Open a new terminal window and run:
```
source ~/aiteamforge/claude_agent_aliases.sh
echo "Source exit code: $?"
```
**Expected Result:** No error messages. Exit code is `0`. All aliases load silently.
**Pass/Fail:** [ ]

### Test 4.9.5: Team-Specific Alias Invokes Correct Agent Path
**Action:** After sourcing the aliases file, run:
```
alias android-kirk
```
**Expected Result:** Output shows the full alias definition for `android-kirk`. The alias
references the Android team's agent configuration, not another team's configuration.
**Pass/Fail:** [ ]

---

### 4.10 Stop and Restart All Teams

Verify the system starts and stops cleanly with multiple teams installed.

### Test 4.10.1: Stop All Teams
**Action:** Run:
```
aiteamforge stop
```
**Expected Result:** All LCARS servers stop. All per-team tmux sessions terminate. No error
messages. Exit code is zero. After stopping, health check endpoints should no longer respond:
```
curl -s -o /dev/null -w "%{http_code}" http://localhost:8200/api/health
```
Should return a connection refused error (not `200`).
**Pass/Fail:** [ ]

### Test 4.10.2: Restart All Teams After Stop
**Action:** Run:
```
aiteamforge start
```
Then re-run the health checks from Test 4.7.2.
**Expected Result:** All teams restart cleanly. All LCARS health checks return `200`. No team
fails to restart due to leftover state from the previous run.
**Pass/Fail:** [ ]

### Test 4.10.3: Doctor Passes With All Teams Installed and Running
**Action:** Run:
```
aiteamforge doctor
```
**Expected Result:** Doctor runs to completion. Output covers all installed teams. All checks
pass with no failures or warnings. Exit code is zero.
**Pass/Fail:** [ ]

---

### 4.11 Custom Team Cleanup

Remove the temporary `testqa` team created in section 4.5 to leave the environment in a known
state for subsequent phases.

### Test 4.11.1: Remove Custom Team Configuration File
**Action:** Run:
```
TEAMS_DIR="$(brew --prefix)/opt/aiteamforge/libexec/share/teams"
rm "$TEAMS_DIR/testqa.conf"
ls "$TEAMS_DIR/testqa.conf" 2>&1
```
**Expected Result:** File removed without errors. The `ls` confirms "No such file or directory".
**Pass/Fail:** [ ]

### Test 4.11.2: Remove Custom Team Working Directory
**Action:** Run:
```
rm -rf ~/aiteamforge/testqa/
ls ~/aiteamforge/testqa/ 2>&1
```
**Expected Result:** Directory removed. The `ls` confirms "No such file or directory".
**Pass/Fail:** [ ]

### Test 4.11.3: Remove Custom Team Kanban Board
**Action:** Run:
```
rm ~/aiteamforge/kanban/testqa-board.json
ls ~/aiteamforge/kanban/testqa-board.json 2>&1
```
**Expected Result:** File removed. The `ls` confirms "No such file or directory".
**Pass/Fail:** [ ]

### Test 4.11.4: Remove Custom Team Port, Theme, and Order Files
**Action:** Run:
```
rm -f ~/aiteamforge/lcars-ports/testqa-*
ls ~/aiteamforge/lcars-ports/testqa-* 2>&1
```
**Expected Result:** All testqa port, theme, and order files removed. The `ls` confirms
"No such file or directory".
**Pass/Fail:** [ ]

### Test 4.11.5: Remove Custom Team Aliases From Aliases File
**Action:** Edit `~/aiteamforge/claude_agent_aliases.sh` to remove the `# QA Test Team aliases`
section header and its alias lines. Then verify:
```
grep "testqa" ~/aiteamforge/claude_agent_aliases.sh
```
**Expected Result:** No output (empty). All testqa references removed from the aliases file.
**Pass/Fail:** [ ]

### Test 4.11.6: Remaining Teams Unaffected After Custom Team Cleanup
**Action:** Run:
```
aiteamforge doctor
```
**Expected Result:** Doctor passes for all remaining teams (academy, ios, android, firebase,
freelance). The testqa removal does not cause errors for any other team. Exit code is zero.
**Pass/Fail:** [ ]

---

### Phase 4 Summary

Record results for this phase before proceeding to Phase 5.

| Section | Tests | Passed | Failed |
|---------|-------|--------|--------|
| 4.1 Baseline verification | 5 | | |
| 4.2 Android team (platform-separated) | 9 | | |
| 4.3 Firebase team (second addition) | 4 | | |
| 4.4 Freelance team (project-based) | 5 | | |
| 4.5 Custom team creation | 8 | | |
| 4.6 Re-install idempotency | 3 | | |
| 4.7 LCARS UI verification | 5 | | |
| 4.8 Kanban board creation | 4 | | |
| 4.9 Shell alias updates | 5 | | |
| 4.10 Stop and restart all teams | 3 | | |
| 4.11 Custom team cleanup | 6 | | |
| **Total** | **57** | | |

**Phase 4 Pass/Fail Criteria:**
- All tests in sections 4.1 through 4.10 must pass (PASS verdict required)
- Section 4.11 cleanup tests are required for environment hygiene before Phase 5
- Phase 4 is PASS when all required tests pass, all LCARS servers respond simultaneously on
  their unique ports, and `aiteamforge doctor` reports no failures after all installations
- Phase 4 is FAIL if any team installation corrupts an existing team's data or configuration,
  if port conflicts occur, if any LCARS server fails to start after `aiteamforge start`, or if
  the aliases file becomes syntactically invalid

**Phase 4 Result:** [ ] PASS   [ ] FAIL

**Notes (record team install order, ports confirmed, any warnings, cleanup steps taken):**

```
Teams installed in this phase:
  android:   port range 8280+ [ ] installed [ ] verified
  firebase:  port range 8240+ [ ] installed [ ] verified
  freelance: port range 8300+ [ ] installed [ ] verified
  testqa:    port range 8490+ [ ] installed [ ] cleaned up
Port conflicts found: [ ] Yes (document below) [ ] No
Re-install idempotency confirmed: [ ] Yes [ ] No
All teams started simultaneously without conflicts: [ ] Yes [ ] No
Custom team cleanup completed: [ ] Yes [ ] No
Observations:
```

---

*Proceed to Phase 5: Archive Existing dev-team from Primary Machine*

---

## Phase 5: Archive Existing dev-team from Primary Machine

**Objective:** Verify that the primary machine's existing dev-team installation can be completely and safely archived/backed up in preparation for migration to a secondary machine. This phase validates the pre-migration check, backup creation, archive integrity, and dry-run capabilities.

**Prerequisites:**
- Phases 1-4 complete on the secondary (clean) machine
- AITeamForge installed and working on the primary (current) machine
- Primary machine has a running dev-team installation at `~/dev-team/` or `~/aiteamforge/`
- Sufficient disk space (at least 3x the current installation size)

---

### Test 5.1: Document Current Installation State
**Action:** On the PRIMARY machine, record the baseline state of the installation before any migration activity.
```bash
echo "=== Kanban boards ==="
ls -la ~/dev-team/kanban/*-board.json 2>/dev/null || ls -la ~/aiteamforge/kanban/*-board.json 2>/dev/null

echo "=== Plan documents ==="
ls ~/dev-team/kanban/*.md 2>/dev/null | wc -l || ls ~/aiteamforge/kanban/*.md 2>/dev/null | wc -l

echo "=== Installation size ==="
du -sh ~/dev-team/ 2>/dev/null || du -sh ~/aiteamforge/ 2>/dev/null

echo "=== Config files ==="
ls ~/dev-team/config/ 2>/dev/null || ls ~/aiteamforge/config/ 2>/dev/null

echo "=== Claude agent configs ==="
ls ~/dev-team/claude/agents/ 2>/dev/null | wc -l || ls ~/aiteamforge/claude/agents/ 2>/dev/null | wc -l

echo "=== Team directories ==="
for team in academy android command dns-framework firebase freelance ios legal mainevent medical; do
  dir="${HOME}/dev-team/${team}"
  [ -d "$dir" ] || dir="${HOME}/aiteamforge/${team}"
  [ -d "$dir" ] && echo "  $team: present"
done

echo "=== Kanban board item counts ==="
for board in ~/dev-team/kanban/*-board.json ~/aiteamforge/kanban/*-board.json 2>/dev/null; do
  [ -f "$board" ] && echo "  $(basename $board): $(jq '.backlog | length // 0' "$board" 2>/dev/null) items"
done
```
**Expected Result:** All counts and paths are printed without errors. Record these numbers — they are the baseline for post-migration comparison in Phase 6.
**Pass/Fail:** [ ]

---

### Test 5.2: Run Pre-Migration Check (Basic)
**Action:** Execute the pre-migration check script against the existing installation.
```bash
aiteamforge migrate --check
```
**Expected Result:**
- Script runs without crashing
- Output includes all analysis sections: Git Repository Analysis, Kanban Data Analysis, Configuration Analysis, Claude Code Agent Analysis, Team Directories Analysis, Service Analysis, LaunchAgent Analysis, Shell Integration Analysis, Disk Space Analysis, Migration Risk Assessment, Migration Time Estimate, Migration Recommendation
- Summary prints a count of critical items to preserve, warnings, and informational items
- Exits with code 0 (SAFE TO MIGRATE) or code 1 (REVIEW RECOMMENDED)
- Does NOT exit with code 2 (NOT RECOMMENDED) without a documented reason
**Pass/Fail:** [ ]

---

### Test 5.3: Review Risk Assessment Output
**Action:** Examine the risk score and individual risk factors from the migrate-check output.
```bash
aiteamforge migrate --check 2>&1 | grep -A 20 "Migration Risk Assessment"
```
**Expected Result:**
- Risk factors list is present (lines starting with `✓` or `⚠`)
- Git repository detected as present (reduces risk score)
- No uncommitted changes warning (if changes exist, commit them and re-run the check)
- Risk level reported as LOW (score <= 10) or MEDIUM (score <= 25)
- Recommendation is SAFE or REVIEW (not FIX_ISSUES)
- If uncommitted changes are present: run `cd ~/dev-team && git add -A && git commit -m "chore: Pre-migration commit"` then re-run Test 5.2
**Pass/Fail:** [ ]

---

### Test 5.4: Run Pre-Migration Check with Verbose Flag
**Action:** Re-run the check with verbose output to see full detail of all detected components.
```bash
aiteamforge migrate --check --verbose
```
**Expected Result:**
- All kanban board filenames listed under the "Boards:" section
- Agent directories listed under the "Agents:" section (if `claude/agents/` exists)
- Git worktrees listed if any exist in the installation
- Shell integration lines from `~/.zshrc` that reference aiteamforge are shown
- No new critical issues appear that were not visible in basic (non-verbose) mode
**Pass/Fail:** [ ]

---

### Test 5.5: Verify Disk Space Adequacy
**Action:** Confirm the migration disk space check passes and available space is sufficient.
```bash
# Review disk space section from migrate-check
aiteamforge migrate --check 2>&1 | grep -A 8 "Disk Space Analysis"

# Verify independently
INSTALL_SIZE=$(du -sk ~/dev-team 2>/dev/null | cut -f1 || du -sk ~/aiteamforge 2>/dev/null | cut -f1)
AVAILABLE=$(df -k ~ | tail -1 | awk '{print $4}')
REQUIRED=$((INSTALL_SIZE * 3))
echo "Required: $((REQUIRED / 1024)) MB"
echo "Available: $((AVAILABLE / 1024)) MB"
echo "Sufficient: $([ $AVAILABLE -gt $REQUIRED ] && echo YES || echo NO)"
```
**Expected Result:**
- The migrate-check "Disk Space Analysis" section reports current installation size and available disk space
- Independent calculation confirms available space is greater than or equal to 3x the installation size
- If insufficient space is found, resolve (free disk space or document rationale for `--skip-backup`) before proceeding
**Pass/Fail:** [ ]

---

### Test 5.6: Run Dry-Run Migration
**Action:** Execute migration in dry-run mode to preview all actions without making any changes.
```bash
aiteamforge migrate --dry-run
```
**Expected Result:**
- Banner displays "DRY RUN MODE - No changes will be made"
- Pre-migration checks run and pass
- Migration Plan section prints with source and destination paths
- Each migration component shows a `[DRY RUN] Would migrate:` line:
  - `kanban/ -> ~/.aiteamforge/kanban/`
  - `kanban-backups/ -> ~/.aiteamforge/kanban-backups/`
  - `config/ -> ~/.aiteamforge/config/` (specific files listed)
  - `claude/ -> ~/.aiteamforge/claude/`
  - Each team directory: `{team}/ -> ~/.aiteamforge/teams/{team}/`
  - `fleet-monitor/data/ -> ~/.aiteamforge/fleet-monitor/`
- LaunchAgents section shows `[DRY RUN] Would update paths in:` for each installed agent
- Shell integration section shows `[DRY RUN] Would update sourcing pattern in ~/.zshrc`
- Migration marker section shows `[DRY RUN] Would create migration marker`
- Validation section shows `[DRY RUN] Would run aiteamforge doctor for validation`
- Exits cleanly with "Dry run completed. No changes were made."
- No files created or modified (verify: `ls ~/.aiteamforge/migration-backups/` should not exist or be empty)
**Pass/Fail:** [ ]

---

### Test 5.7: Dry-Run with Custom Source Path
**Action:** Test dry-run with an explicitly specified source directory to confirm the `--old-dir` flag works correctly.
```bash
ACTUAL_PATH="${HOME}/dev-team"
[ -d "${HOME}/aiteamforge" ] && ACTUAL_PATH="${HOME}/aiteamforge"

aiteamforge migrate --dry-run --old-dir "${ACTUAL_PATH}"
```
**Expected Result:**
- Same dry-run output as Test 5.6
- Source path in the "Migration Plan" section matches the `--old-dir` argument
- No errors about the installation not being found
**Pass/Fail:** [ ]

---

### Test 5.8: Create Full Migration Backup
**Action:** Execute the actual migration. The backup is created at `~/.aiteamforge/migration-backups/<timestamp>/`.

This command will prompt for confirmation. Answer `y` to proceed.
```bash
aiteamforge migrate
```
**Expected Result:**
- Pre-migration checks pass
- Migration Plan section displays correct source, destination, and backup paths
- Confirmation prompt appears: answer `y`
- "Backup Phase" section runs and completes:
  - "Creating backup at: ~/.aiteamforge/migration-backups/YYYY-MM-DD_HHMMSS"
  - "Backing up aiteamforge directory..." completes
  - "Backing up LaunchAgents..." completes
  - "Backing up shell configs..." completes
  - "Verifying backup..." — original file count matches backup file count
  - "Backup created successfully (XMB)" with backup location printed
- Migration phases complete: kanban, config, claude, teams, fleet-monitor
- LaunchAgents updated (or "No LaunchAgents to update" if none are installed)
- Shell integration updated
- Migration marker created at `~/.aiteamforge/MIGRATED`
- Validation runs via `aiteamforge doctor`
- Final success summary prints all migrated component names
- Exit code 0
**Pass/Fail:** [ ]

---

### Test 5.9: Verify Backup Directory Exists and Has Correct Structure
**Action:** Inspect the backup directory that was created during Test 5.8.
```bash
BACKUP=$(ls -td ~/.aiteamforge/migration-backups/20* 2>/dev/null | head -1)
echo "Backup location: ${BACKUP}"

echo "=== Top-level backup contents ==="
ls -la "${BACKUP}/"

echo "=== aiteamforge subdirectory (first 20 entries) ==="
ls "${BACKUP}/aiteamforge/" | head -20

echo "=== LaunchAgents backup ==="
ls "${BACKUP}/LaunchAgents/" 2>/dev/null || echo "(No LaunchAgents backed up)"

echo "=== Shell config backup ==="
ls "${BACKUP}/.zshrc" 2>/dev/null && echo ".zshrc backed up" || echo "(No .zshrc backed up)"
```
**Expected Result:**
- Backup directory exists with a timestamp name in `YYYY-MM-DD_HHMMSS` format
- `aiteamforge/` subdirectory is present inside the backup
- `aiteamforge/` contains key directories: `kanban/`, `config/`, `claude/` (or equivalents from source)
- `LaunchAgents/` present if LaunchAgents were installed
- Backup directory is non-empty and non-trivially small
**Pass/Fail:** [ ]

---

### Test 5.10: Verify Backup File Count Integrity
**Action:** Confirm the backup contains the same number of files as the original installation.
```bash
INSTALL_DIR="${HOME}/dev-team"
[ -d "${HOME}/aiteamforge" ] && INSTALL_DIR="${HOME}/aiteamforge"

BACKUP=$(ls -td ~/.aiteamforge/migration-backups/20* 2>/dev/null | head -1)

ORIGINAL_COUNT=$(find "${INSTALL_DIR}" -type f | wc -l | tr -d ' ')
BACKUP_COUNT=$(find "${BACKUP}/aiteamforge" -type f | wc -l | tr -d ' ')

echo "Original files: ${ORIGINAL_COUNT}"
echo "Backup files: ${BACKUP_COUNT}"
echo "Match: $([ "${ORIGINAL_COUNT}" = "${BACKUP_COUNT}" ] && echo YES || echo NO -- INVESTIGATE)"
```
**Expected Result:**
- Original count and backup count are equal
- If counts differ, investigate: the migration script's own verification would have aborted on mismatch, so a discrepancy here indicates files changed during migration or a counting methodology difference (symlinks, hidden files)
**Pass/Fail:** [ ]

---

### Test 5.11: Verify Backup Contains All Critical Data
**Action:** Confirm each category of critical data is present in the backup.
```bash
BACKUP=$(ls -td ~/.aiteamforge/migration-backups/20* 2>/dev/null | head -1)
BACKUP_INSTALL="${BACKUP}/aiteamforge"

echo "=== Kanban boards ==="
ls "${BACKUP_INSTALL}/kanban/"*-board.json 2>/dev/null || echo "MISSING: No kanban boards in backup"

echo ""
echo "=== Plan documents ==="
COUNT=$(ls "${BACKUP_INSTALL}/kanban/"*.md 2>/dev/null | wc -l | tr -d ' ')
echo "${COUNT} plan documents backed up"

echo ""
echo "=== Configuration files ==="
for f in config/secrets.env config/machine.json config/teams.json config/remote-hosts.json config/fleet-config.json; do
  [ -f "${BACKUP_INSTALL}/${f}" ] && echo "  PRESENT: ${f}" || echo "  ABSENT: ${f} (may not have existed)"
done

echo ""
echo "=== Claude settings ==="
[ -f "${BACKUP_INSTALL}/claude/settings.json" ] && echo "  PRESENT: claude/settings.json" || echo "  ABSENT: claude/settings.json"

echo ""
echo "=== Claude agent configs ==="
AGENT_COUNT=$(find "${BACKUP_INSTALL}/claude/agents" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
echo "  ${AGENT_COUNT} agent directories backed up"

echo ""
echo "=== Team directories ==="
for team in academy android command dns-framework firebase freelance ios legal mainevent medical; do
  [ -d "${BACKUP_INSTALL}/${team}" ] && echo "  PRESENT: ${team}/" || true
done

echo ""
echo "=== Kanban backups ==="
[ -d "${BACKUP_INSTALL}/kanban-backups" ] && echo "  PRESENT: kanban-backups/" || echo "  ABSENT: kanban-backups/ (may not have existed)"
```
**Expected Result:**
- All kanban board JSON files present (count matches Test 5.1 baseline)
- Plan document count matches Test 5.1 baseline
- `config/machine.json` and `config/teams.json` are present (critical)
- `claude/settings.json` present if it existed in source
- Agent directory count matches Test 5.1 baseline
- All team directories that existed in source are present in the backup
**Pass/Fail:** [ ]

---

### Test 5.12: Verify Backup Size Is Reasonable
**Action:** Check that the backup size is reasonable relative to the original installation.
```bash
INSTALL_DIR="${HOME}/dev-team"
[ -d "${HOME}/aiteamforge" ] && INSTALL_DIR="${HOME}/aiteamforge"

BACKUP=$(ls -td ~/.aiteamforge/migration-backups/20* 2>/dev/null | head -1)

ORIGINAL_SIZE=$(du -sh "${INSTALL_DIR}" | cut -f1)
BACKUP_SIZE=$(du -sh "${BACKUP}" | cut -f1)

echo "Original installation: ${ORIGINAL_SIZE}"
echo "Backup size: ${BACKUP_SIZE}"
```
**Expected Result:**
- Backup size is within the same order of magnitude as the original (typically 80-100% of original size)
- Backup is NOT zero bytes or suspiciously tiny (would indicate a failed copy)
- Backup is NOT dramatically larger than original (would indicate duplication errors)
**Pass/Fail:** [ ]

---

### Test 5.13: Verify Migration Log Was Created
**Action:** Check that the migration log file captured all activity.
```bash
ls -la ~/.aiteamforge/migration.log
echo ""
echo "=== Last 30 lines of migration log ==="
tail -30 ~/.aiteamforge/migration.log
```
**Expected Result:**
- `~/.aiteamforge/migration.log` exists and is non-empty
- Log contains timestamped entries in `[YYYY-MM-DD HH:MM:SS]` format
- Log shows entries for each phase: Backup Phase, Migrating User Data, Updating LaunchAgents, Updating Shell Integration, Finalizing Migration, Validation Phase
- No ERROR entries in the log (warnings are acceptable)
**Pass/Fail:** [ ]

---

### Test 5.14: Verify Migration State File and Marker
**Action:** Confirm the migration state JSON and MIGRATED marker file were created correctly.
```bash
echo "=== MIGRATED marker ==="
cat ~/.aiteamforge/MIGRATED

echo ""
echo "=== Migration state JSON ==="
cat ~/.aiteamforge/migration-state.json | jq .
```
**Expected Result:**
- `~/.aiteamforge/MIGRATED` exists with content showing: Migration Date, Source, Destination, Backup path, and Migration Version
- `~/.aiteamforge/migration-state.json` is valid JSON containing:
  - `"migrated": true`
  - `"migration_date"` in ISO 8601 format
  - `"source"` matching the original install directory
  - `"destination"` matching `~/.aiteamforge`
  - `"backup"` matching the backup directory path from Test 5.9
  - `"version"` matching the installed AITeamForge version
**Pass/Fail:** [ ]

---

### Test 5.15: Verify Migrated Data in New Location
**Action:** Confirm user data was correctly copied to the new `~/.aiteamforge/` structure.
```bash
echo "=== Kanban data in new location ==="
ls ~/.aiteamforge/kanban/*-board.json 2>/dev/null || echo "MISSING: No boards at ~/.aiteamforge/kanban/"

echo ""
echo "=== Plan docs in new location ==="
ls ~/.aiteamforge/kanban/*.md 2>/dev/null | wc -l

echo ""
echo "=== Config files in new location ==="
ls ~/.aiteamforge/config/ 2>/dev/null

echo ""
echo "=== Claude configs in new location ==="
ls ~/.aiteamforge/claude/ 2>/dev/null

echo ""
echo "=== Team data in new location ==="
ls ~/.aiteamforge/teams/ 2>/dev/null

echo ""
echo "=== Board item count comparison ==="
for board in ~/.aiteamforge/kanban/*-board.json; do
  [ -f "$board" ] && echo "  $(basename $board): $(jq '.backlog | length // 0' "$board" 2>/dev/null) items"
done
```
**Expected Result:**
- Kanban board JSON files present at `~/.aiteamforge/kanban/`
- Plan document count matches baseline from Test 5.1
- Config files present: `machine.json`, `teams.json` (and others if they existed in source)
- Claude directory has `settings.json` and `agents/` subdirectory
- Team directories present under `~/.aiteamforge/teams/`
- Board item counts match the baseline from Test 5.1 (no data loss)
**Pass/Fail:** [ ]

---

### Test 5.16: Verify Automated Backup System Is Current
**Action:** Confirm the kanban-backup.py automated backup system has current backup data.
```bash
echo "=== Backup system status ==="
python3 ~/dev-team/kanban-backup.py --status 2>/dev/null || \
  python3 ~/aiteamforge/kanban-backup.py --status 2>/dev/null || \
  python3 "$(brew --prefix)/opt/aiteamforge/libexec/share/scripts/kanban-backup.py" --status 2>/dev/null

echo ""
echo "=== Backup files at centralized location ==="
ls -la ~/aiteamforge-backups/kanban/ 2>/dev/null | head -20
```
**Expected Result:**
- Backup system status command runs without error
- Status shows `lastRun` within the past 24 hours (or since last LaunchAgent invocation)
- Status shows `lastRunStatus: "success"`
- At least one backup exists per active team board
- Storage used is non-zero
- If backup is stale (>24 hours old): run `python3 ~/dev-team/kanban-backup.py --backup` manually and verify it completes without errors
**Pass/Fail:** [ ]

---

### Test 5.17: Force-Run Backup System Before Archive Transfer
**Action:** Force a fresh backup of all kanban boards immediately before creating the transfer archive, ensuring the most current data is captured.
```bash
python3 ~/dev-team/kanban-backup.py --backup --force 2>/dev/null || \
  python3 ~/aiteamforge/kanban-backup.py --backup --force 2>/dev/null || \
  python3 "$(brew --prefix)/opt/aiteamforge/libexec/share/scripts/kanban-backup.py" --backup --force

# Verify backup ran
python3 ~/dev-team/kanban-backup.py --status 2>/dev/null | grep -E "lastRun|lastRunStatus|backedUp"
```
**Expected Result:**
- Force backup completes without errors
- Summary output shows `Backed up: N` where N matches the number of active team boards
- `Errors: 0`
- `lastRun` timestamp in status is current (within the last minute)
- Each team directory under `~/aiteamforge-backups/kanban/` has a new backup zip file with today's timestamp
- Backup filenames follow the format `backup_YYYYMMDD_HHMMSS.zip`
**Pass/Fail:** [ ]

---

### Test 5.18: Create Manual Transfer Archive (tar)
**Action:** Create a complete tar archive of the installation for transfer to the secondary machine.
```bash
ARCHIVE_NAME="dev-team-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
ARCHIVE_PATH="${HOME}/Desktop/${ARCHIVE_NAME}"

INSTALL_DIR="${HOME}/dev-team"
[ -d "${HOME}/aiteamforge" ] && INSTALL_DIR="${HOME}/aiteamforge"

echo "Creating archive: ${ARCHIVE_PATH}"
echo "Source: ${INSTALL_DIR}"
echo ""

tar -czf "${ARCHIVE_PATH}" \
  --exclude='node_modules' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude='.DS_Store' \
  --exclude='*.log' \
  --exclude='worktrees' \
  "${INSTALL_DIR}" \
  ~/.aiteamforge/

echo ""
echo "Archive created:"
ls -lh "${ARCHIVE_PATH}"
```
**Expected Result:**
- `tar` command completes without error
- Archive file exists on Desktop with a name matching `dev-team-backup-YYYYMMDD-HHMMSS.tar.gz`
- Archive size is non-trivially large (greater than 1 MB for any real installation)
- Archive is NOT 0 bytes
**Pass/Fail:** [ ]

---

### Test 5.19: Verify Archive Integrity
**Action:** Test the tar archive for integrity and list its contents to confirm completeness.
```bash
ARCHIVE=$(ls -t ~/Desktop/dev-team-backup-*.tar.gz 2>/dev/null | head -1)
echo "Verifying: ${ARCHIVE}"
echo ""

echo "=== Integrity test ==="
tar -tzf "${ARCHIVE}" > /dev/null && echo "PASS: Archive is valid" || echo "FAIL: Archive is corrupt"

echo ""
echo "=== File count ==="
tar -tzf "${ARCHIVE}" | wc -l

echo ""
echo "=== Key paths present ==="
tar -tzf "${ARCHIVE}" | grep -E "kanban.*-board\.json" | head -10
tar -tzf "${ARCHIVE}" | grep "config/machine.json" || echo "(machine.json not in archive -- check if it existed)"
tar -tzf "${ARCHIVE}" | grep "claude/settings.json" || echo "(claude/settings.json not in archive)"
tar -tzf "${ARCHIVE}" | grep -c "\.md$" | xargs echo "Plan documents:"
```
**Expected Result:**
- Integrity test passes with no corrupt archive message
- File count is non-trivially large (hundreds or thousands for a real installation)
- At least one `*-board.json` path found in the archive listing
- `config/machine.json` is found (or noted as absent because it did not exist in source)
- `claude/settings.json` is found (or noted as absent)
- Plan document count is reasonable (>= count from Test 5.1)
**Pass/Fail:** [ ]

---

### Test 5.20: Test Migration WITHOUT Backup (--skip-backup Flag)
**Action:** Verify the `--skip-backup` flag suppresses the backup phase and shows an appropriate warning. Use dry-run to avoid making real changes.
```bash
aiteamforge migrate --dry-run --skip-backup
```
**Expected Result:**
- "DRY RUN MODE - No changes will be made" banner appears
- "Backup Phase" section appears with the message "Skipping backup (--skip-backup)"
- A WARNING is displayed to indicate the backup is being skipped
- Migration continues through subsequent phases (migration plan, user data previews) showing dry-run output
- No backup directory is created
- Pre-migration checks still run normally
**Pass/Fail:** [ ]

---

### Test 5.21: Test Migration with --force Flag (Dry-Run)
**Action:** Verify the `--force` flag bypasses interactive confirmation prompts. Use dry-run to confirm behavior without making changes.
```bash
aiteamforge migrate --dry-run --force
```
**Expected Result:**
- No confirmation prompts appear (the "Continue with migration? [y/N]" prompt is skipped)
- Migration proceeds through all phases automatically
- Dry-run output shows all expected "[DRY RUN] Would..." lines
- If the installation was already marked as migrated (MIGRATED file exists), `--force` allows re-running without the "already migrated" abort
**Pass/Fail:** [ ]

---

### Test 5.22: Test Pre-Migration Check with Non-Existent Path
**Action:** Verify that the migrate-check gracefully handles an invalid source directory path.
```bash
aiteamforge migrate --check --dir /tmp/nonexistent-installation-path
echo "Exit code: $?"
```
**Expected Result:**
- Error message: "No aiteamforge installation found at: /tmp/nonexistent-installation-path"
- Suggestion displayed to use `--dir <path>` if the installation is elsewhere
- Exits with code 3 (Invalid installation or not found)
- No crash, no unhandled exception, no stack trace
**Pass/Fail:** [ ]

---

### Test 5.23: Verify Migration Log Timestamps and Completeness
**Action:** Inspect the migration log for correct timestamp format and phase coverage.
```bash
echo "=== Migration log timestamps ==="
grep "^\[20" ~/.aiteamforge/migration.log | head -20

echo ""
echo "=== Log contains all expected phases ==="
for phase in "Backup Phase" "Migrating User Data" "Updating LaunchAgents" "Updating Shell Integration" "Finalizing Migration" "Validation Phase"; do
  grep -q "${phase}" ~/.aiteamforge/migration.log && echo "  FOUND: ${phase}" || echo "  MISSING: ${phase}"
done

echo ""
echo "=== Log error check ==="
grep -i "error\|fail\|critical" ~/.aiteamforge/migration.log | grep -v "# " || echo "No errors found in log"
```
**Expected Result:**
- All timestamps are in `[YYYY-MM-DD HH:MM:SS]` format
- All 6 phase names are found in the log
- No ERROR, FAIL, or CRITICAL entries appear (warnings are acceptable)
- Log file is complete and not truncated mid-migration
**Pass/Fail:** [ ]

---

### Test 5.24: Verify Shell Integration Was Updated
**Action:** Confirm that `~/.zshrc` was updated to use the new Homebrew-managed sourcing pattern.
```bash
echo "=== New sourcing pattern ==="
grep -n "aiteamforge\|shell-init" ~/.zshrc | tail -20

echo ""
echo "=== Old pattern commented out ==="
grep -n "MIGRATED" ~/.zshrc | head -10

echo ""
echo "=== Backup of .zshrc ==="
ls -la ~/.zshrc.pre-migration 2>/dev/null || echo "(No .zshrc backup -- may mean no aiteamforge references existed)"
```
**Expected Result:**
- New sourcing block present in `~/.zshrc`:
  ```
  # AITeamForge Shell Integration (Homebrew)
  if [[ -f ~/.aiteamforge/shell-init.sh ]]; then
    source ~/.aiteamforge/shell-init.sh
  fi
  ```
- Old `source ~/dev-team/...` or `source ~/aiteamforge/...` lines are commented out with `# [MIGRATED]` prefix
- `~/.zshrc.pre-migration` backup file exists from before the edit
- If no aiteamforge references were in `~/.zshrc` originally, "No aiteamforge references in ~/.zshrc" was logged and no changes were made
**Pass/Fail:** [ ]

---

### Test 5.25: Rollback Migration (Verify Rollback Works)
**Action:** Test the rollback capability to confirm the migration can be undone and the system returns to pre-migration state.

**Note:** After this test, re-run `aiteamforge migrate --force` (Test 5.26) to restore migrated state before Phase 6.
```bash
echo "=== State before rollback ==="
ls ~/.aiteamforge/MIGRATED 2>/dev/null && echo "MIGRATED marker exists"
ls ~/.aiteamforge/migration-backups/ 2>/dev/null

echo ""
echo "=== Running rollback ==="
aiteamforge migrate --rollback --force

echo "Exit code: $?"
```
**Expected Result:**
- Rollback locates the most recent backup automatically
- Backup information displayed: Location, Size, Created timestamp
- With `--force`, the "Continue with rollback? [y/N]" prompt is skipped
- Services stop before restoration begins
- Backup is restored to the original location (`~/dev-team` or `~/aiteamforge`)
- LaunchAgents restored if they were backed up
- `~/.zshrc` restored if it was backed up
- Exits with code 3 (Rollback successful)
- After rollback: `~/.aiteamforge/MIGRATED` no longer exists (or reflects backup state)
- Original installation directory is intact and accessible
**Pass/Fail:** [ ]

---

### Test 5.26: Re-Run Migration After Rollback
**Action:** Re-apply migration with `--force` to restore migrated state before proceeding to Phase 6.
```bash
aiteamforge migrate --force
```
**Expected Result:**
- Migration runs non-interactively (`--force` skips all prompts)
- Succeeds even if `~/.aiteamforge/MIGRATED` exists from the backup (`--force` overrides the "already migrated" check)
- A new backup is created with an updated timestamp
- All data re-migrated to `~/.aiteamforge/`
- Migration marker recreated with the current timestamp
- Exit code 0
**Pass/Fail:** [ ]

---

### Phase 5 Summary

Record the results for this phase before proceeding to Phase 6.

| Section | Tests | Passed | Failed |
|---------|-------|--------|--------|
| 5.1 Baseline documentation | 1 | | |
| 5.2-5.5 Pre-migration check | 4 | | |
| 5.6-5.7 Dry-run migration | 2 | | |
| 5.8-5.15 Backup creation and verification | 8 | | |
| 5.16-5.17 Automated backup system | 2 | | |
| 5.18-5.19 Transfer archive | 2 | | |
| 5.20-5.22 Flag behavior edge cases | 3 | | |
| 5.23-5.24 Log and shell integration | 2 | | |
| 5.25-5.26 Rollback and re-migration | 2 | | |
| **Total** | **26** | | |

**Phase 5 Pass/Fail Criteria:**
- All tests must pass before proceeding to Phase 6
- Any failure in Tests 5.8-5.15 (backup creation and verification) is a BLOCKING failure
- Any failure in Tests 5.1-5.7 should be resolved before running Test 5.8
- Tests 5.20-5.22 are edge case validations — failures should be filed as bugs but do not block Phase 6 if the core backup (5.8-5.15) passed

**Phase 5 Result:** [ ] PASS   [ ] FAIL

**Archive ready for transfer to secondary machine:** `~/Desktop/dev-team-backup-YYYYMMDD-HHMMSS.tar.gz`

**Notes (record any observations, issues encountered, baseline numbers):**

```
Installation directory used: ~/dev-team  OR  ~/aiteamforge
Kanban board count (Test 5.1):
Plan document count (Test 5.1):
Claude agent count (Test 5.1):
Team directories found (Test 5.1):
Risk level from migrate-check (Test 5.2):
Backup directory path (Test 5.8):
Backup file count original / backup (Test 5.10):
Archive file name and size (Test 5.18):
Rollback tested successfully: [ ] Yes [ ] No
Re-migration after rollback: [ ] Yes [ ] No
```

---

*Proceed to Phase 6: Restore/Migrate dev-team to Secondary Machine*

---


## Phase 6: Restore/Migrate dev-team to Secondary Machine

**Objective:** Validate the complete workflow for transferring an AITeamForge installation to a
secondary machine, including archive transfer, migration execution, path adaptation, data integrity
verification, service restoration, and rollback capability.

**Prerequisites:**
- Phase 5 complete: archive of primary machine's user data is available
- Secondary machine is a clean macOS system (or has no existing AITeamForge installation)
- AITeamForge is installed on the secondary machine via Homebrew before migration begins
- Network connectivity between machines (for SCP) or physical media (for USB/AirDrop)

**Risk Level:** HIGH. Data transfer and path remapping across machines; kanban board integrity
is critical.

---

### Test 6.1: Archive Transfer via SCP
**Action:** On the primary machine, transfer the archive created in Phase 5 to the secondary
machine via SCP:
```bash
scp ~/aiteamforge-transfer.tar.gz user@secondary-machine:~/
```
**Expected Result:** Transfer completes without error. Archive size on the secondary machine
matches the source. Verify with `ls -lh ~/aiteamforge-transfer.tar.gz` on both machines.
**Pass/Fail:** [ ]

---

### Test 6.2: Archive Transfer via USB Drive
**Action:** Copy the Phase 5 archive to a USB drive on the primary machine, eject, insert into
secondary machine, and copy to the secondary machine's home directory:
```bash
cp /Volumes/<USB_NAME>/aiteamforge-transfer.tar.gz ~/
```
**Expected Result:** File copies successfully. SHA-256 checksums match between primary and
secondary (`shasum -a 256 ~/aiteamforge-transfer.tar.gz` — both values must be identical).
**Pass/Fail:** [ ]

---

### Test 6.3: Archive Transfer via AirDrop
**Action:** On the primary machine, AirDrop `~/aiteamforge-transfer.tar.gz` to the secondary
machine. Accept the transfer on the secondary machine.
**Expected Result:** AirDrop completes. File appears in `~/Downloads/` on the secondary. File
size matches the source. No corruption warnings appear.
**Pass/Fail:** [ ]

---

### Test 6.4: AITeamForge Pre-Installed on Secondary Machine
**Action:** On the secondary machine, verify AITeamForge is installed via Homebrew:
```bash
brew list aiteamforge
aiteamforge --version
which aiteamforge
```
**Expected Result:** `brew list aiteamforge` shows the package. `aiteamforge --version` prints
a version string (e.g., `v1.3.0`). `which aiteamforge` returns the Homebrew binary path (e.g.,
`/opt/homebrew/bin/aiteamforge`). If not installed, run `brew install aiteamforge` first.
**Pass/Fail:** [ ]

---

### Test 6.5: Extract Archive on Secondary Machine
**Action:** On the secondary machine, extract the transferred archive to a staging directory:
```bash
mkdir -p ~/aiteamforge-restore-staging
tar -xzf ~/aiteamforge-transfer.tar.gz -C ~/aiteamforge-restore-staging/
ls -la ~/aiteamforge-restore-staging/
```
**Expected Result:** Extraction completes without errors. The staging directory contains expected
subdirectories: `kanban/`, `config/`, `claude/`, `teams/`, `kanban-backups/`, and
`fleet-monitor/` (if applicable). File count matches the Phase 5 archive.
**Pass/Fail:** [ ]

---

### Test 6.6: Run Migration Dry-Run on Secondary Machine
**Action:** Preview the migration without making changes:
```bash
aiteamforge migrate \
  --old-dir ~/aiteamforge-restore-staging \
  --dry-run
```
**Expected Result:** Exits with code `0`. No files modified. All planned operations listed with
`[DRY RUN]` prefix: kanban data migration, config migration, Claude agent config migration,
team data migration, LaunchAgent path updates, shell integration update. No confirmation prompt
shown in dry-run mode.
**Pass/Fail:** [ ]

---

### Test 6.7: Run Migration (Live) on Secondary Machine
**Action:** Execute the actual migration after reviewing the dry-run output:
```bash
aiteamforge migrate \
  --old-dir ~/aiteamforge-restore-staging
```
Respond `y` to the confirmation prompt.
**Expected Result:** All phases execute in order with success indicators: Pre-Migration Checks,
Backup Phase, Migrating User Data, Updating LaunchAgents, Updating Shell Integration,
Finalizing Migration, Validation Phase. Final output confirms success with backup location and
rollback instructions. Created files: `~/.aiteamforge/MIGRATED`,
`~/.aiteamforge/migration-state.json`, `~/.aiteamforge/migration.log`. Exit code is `0`.
**Pass/Fail:** [ ]

---

### Test 6.8: Migration Log Integrity Check
**Action:** Review the migration log for errors or warnings:
```bash
grep -i "error\|warn\|fail" ~/.aiteamforge/migration.log
echo "grep exit code: $?"
```
**Expected Result:** `grep` returns no matches (exit code `1` means no errors found). The full
log contains timestamped entries for all migration phases ending with success markers. Warnings
about optional components absent on the primary are informational only.
**Pass/Fail:** [ ]

---

### Test 6.9: Path Mapping Verification — Framework Paths
**Action:** Verify framework paths remapped from old manual install to Homebrew per the
`framework` mapping in `path-mappings.json`:
```bash
ls /opt/homebrew/opt/aiteamforge/libexec/

grep -r "aiteamforge-restore-staging" \
  ~/Library/LaunchAgents/com.aiteamforge.*.plist 2>/dev/null \
  && echo "PROBLEM: staging path found" || echo "OK: no staging path"
```
**Expected Result:** Framework exists at `/opt/homebrew/opt/aiteamforge/libexec/`. No LaunchAgent
contains a reference to the staging directory or the old `~/aiteamforge/` manual path (the
`sed` substitutions in `aiteamforge-migrate.sh` handle this). LaunchAgents reference
`~/.aiteamforge/` for user data and the Homebrew path for framework scripts.
**Pass/Fail:** [ ]

---

### Test 6.10: Path Mapping Verification — User Data Paths
**Action:** Verify user data directories are at correct new paths per `path-mappings.json`:
```bash
for dir in \
  ~/.aiteamforge/kanban \
  ~/.aiteamforge/config \
  ~/.aiteamforge/claude \
  ~/.aiteamforge/teams; do
  ls "$dir" > /dev/null 2>&1 \
    && echo "PRESENT: $dir" || echo "MISSING: $dir"
done
```
**Expected Result:** All four directories print `PRESENT`. Kanban board JSON files exist in
`~/.aiteamforge/kanban/`. Config files in `~/.aiteamforge/config/`. Claude agent configs in
`~/.aiteamforge/claude/`. Team data in `~/.aiteamforge/teams/`.
**Pass/Fail:** [ ]

---

### Test 6.11: Path Mapping Verification — Shell Integration Updated
**Action:** Verify shell integration updated from old sourcing pattern to Homebrew-managed
pattern per the `shell_integration` entry in `path-mappings.json`:
```bash
grep "aiteamforge" ~/.zshrc
ls ~/.zshrc.pre-migration 2>/dev/null && echo "Backup present" || echo "No backup"
```
**Expected Result:** Old `source ~/aiteamforge/` lines commented with `# [MIGRATED]` prefix.
New block present in `~/.zshrc`:
```
# AITeamForge Shell Integration (Homebrew)
if [[ -f ~/.aiteamforge/shell-init.sh ]]; then
  source ~/.aiteamforge/shell-init.sh
fi
```
Backup file `~/.zshrc.pre-migration` exists with original content.
**Pass/Fail:** [ ]

---

### Test 6.12: Kanban Data Integrity — Board JSON Validity
**Action:** Validate JSON structure of all kanban board files (mirrors `_krh_is_valid_json`
logic in `kanban-restore-helper.sh`):
```bash
for f in ~/.aiteamforge/kanban/*-board.json; do
  python3 -c "import json; json.load(open('$f'))" \
    && echo "VALID: $(basename $f)" || echo "INVALID: $(basename $f)"
done
```
**Expected Result:** Every board file prints `VALID`. Zero files print `INVALID`. Board file
count matches the primary machine. No board file is empty (zero bytes).
**Pass/Fail:** [ ]

---

### Test 6.13: Kanban Data Integrity — Item Count Verification
**Action:** Compare kanban item counts between primary and secondary machines:
```bash
source ~/.aiteamforge/shell-init.sh
kb-list 2>/dev/null | wc -l
```
Run on both machines and compare output.
**Expected Result:** Item counts are equal. `kb-list` runs without errors on the secondary. All
team boards accessible on the primary are accessible on the secondary.
**Pass/Fail:** [ ]

---

### Test 6.14: Kanban Data Integrity — Backup Files Accessible via Restore Helper
**Action:** Verify kanban backup files are readable using the `kanban-restore-helper.sh` public
API:
```bash
source /opt/homebrew/opt/aiteamforge/share/scripts/kanban-restore-helper.sh
find_board_backups "academy"
echo "Exit code: $?"
```
**Expected Result:** `find_board_backups` outputs at least one backup entry in the format
`YYYY-MM-DD HH:MM:SS  <size>  <filename>`, sorted newest-first. Return code is `0`. Corrupted
or empty files are silently skipped per the `_krh_is_valid_zip` validation logic.
**Pass/Fail:** [ ]

---

### Test 6.15: Kanban Data Integrity — Interactive Backup Menu
**Action:** Test the `show_backup_menu` cancellation path:
```bash
source /opt/homebrew/opt/aiteamforge/share/scripts/kanban-restore-helper.sh
selected=$(echo "q" | show_backup_menu "academy" 2>/tmp/backup_menu_stderr)
echo "Exit code: $?"
echo "Selected: '${selected}'"
cat /tmp/backup_menu_stderr
```
**Expected Result:** Function exits with code `1` on cancellation. `selected` is empty (nothing
printed to stdout on cancel). All menu output goes to stderr. Up to `KANBAN_RESTORE_MENU_LIMIT`
(10) backups displayed sorted newest-first, with dates, sizes, and filenames.
**Pass/Fail:** [ ]

---

### Test 6.16: Team Configurations Restored — Config Files
**Action:** Verify migrated configuration files are present and structurally valid:
```bash
ls -la ~/.aiteamforge/config/
python3 -c "
import json
d = json.load(open('$HOME/.aiteamforge/config/teams.json'))
print('teams.json keys:', list(d.keys()))
"
# Verify presence only -- do not print contents to terminal:
ls ~/.aiteamforge/config/machine.json && echo "machine.json: present"
```
**Expected Result:** `teams.json` loads as valid JSON with all team keys from the primary.
`machine.json` is present (hostname values expected to differ from primary; update for
secondary). Config files from `path-mappings.json` `preserve.critical_data` that existed on
the primary are present on the secondary.
**Pass/Fail:** [ ]

---

### Test 6.17: Team Configurations Restored — Team Data Directories
**Action:** Verify team-specific data directories are present per the `team_data` path mapping:
```bash
ls ~/.aiteamforge/teams/
for team in academy android command dns-framework firebase freelance ios legal mainevent medical; do
  ls ~/.aiteamforge/teams/$team/ > /dev/null 2>&1 \
    && echo "PRESENT: $team" \
    || echo "ABSENT: $team (expected if not on primary)"
done
```
**Expected Result:** `teams/` directory exists. Teams present on the primary show `PRESENT`.
Teams absent from primary show `ABSENT` (acceptable). Structure matches `path-mappings.json`
`team_data` mapping: `~/.aiteamforge/teams/{team}/`.
**Pass/Fail:** [ ]

---

### Test 6.18: Services Start on Secondary Machine — LCARS
**Action:** Start LCARS and verify it responds on the secondary machine:
```bash
aiteamforge start lcars
sleep 3
curl -s http://localhost:8082/api/health 2>/dev/null \
  || curl -s http://localhost:8203/api/health 2>/dev/null \
  || echo "No response -- verify LCARS port configuration"
```
**Expected Result:** LCARS starts without errors referencing the staging directory or incorrect
paths. Health endpoint returns JSON with a status field. LCARS UI accessible in a browser.
**Pass/Fail:** [ ]

---

### Test 6.19: Services Start on Secondary Machine — Kanban Backup LaunchAgent
**Action:** Verify the kanban backup LaunchAgent is loaded with correct updated paths:
```bash
launchctl list | grep aiteamforge
grep -i "staging\|aiteamforge-restore" \
  ~/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist 2>/dev/null \
  && echo "PROBLEM: staging path in plist" || echo "OK: no staging path"
```
**Expected Result:** `com.aiteamforge.kanban-backup` shows in `launchctl list` with status `0`
or a positive PID. Plist contains zero references to the staging directory or old
`~/aiteamforge/` path. Program arguments reference the Homebrew framework path or
`~/.aiteamforge/` user data path.
**Pass/Fail:** [ ]

---

### Test 6.20: Services Start on Secondary Machine — Fleet Monitor (if applicable)
**Action:** If Fleet Monitor data was migrated from the primary machine, verify it starts:
```bash
ls ~/.aiteamforge/fleet-monitor/ 2>/dev/null \
  && echo "Fleet Monitor data present" \
  || { echo "N/A: Fleet Monitor not configured on primary"; exit 0; }

aiteamforge start fleet-monitor
sleep 3
curl -s http://localhost:3000/api/health 2>/dev/null \
  || echo "Not responding -- update config.json if client mode needs new server address"
```
**Expected Result:** If migrated: health endpoint responds. If not configured on primary: N/A.
If client mode: connection error to remote server is expected until
`~/.aiteamforge/fleet-monitor/config.json` is updated with the secondary machine's server address.
**Pass/Fail:** [ ]

---

### Test 6.21: aiteamforge doctor Passes on Secondary Machine
**Action:** On the secondary machine, open a new terminal session and run the full doctor check:
```bash
aiteamforge doctor
echo "Exit code: $?"
```
**Expected Result:** All checks pass with success indicators. Exit code is `0`. Doctor confirms:
installation valid, `~/.aiteamforge/` readable, kanban boards accessible, shell integration
active, LaunchAgents loaded. Informational warnings about optional unconfigured services are
acceptable; zero critical errors.
**Pass/Fail:** [ ]

---

### Test 6.22: aiteamforge doctor — Network Check on Secondary Machine
**Action:** Run the network-specific doctor check:
```bash
aiteamforge doctor --check network
echo "Exit code: $?"
```
**Expected Result:** Network diagnostics complete. If Tailscale configured on secondary: machine
shows active in Tailnet. Fleet Monitor connectivity reported as configured or N/A. No critical
network errors block local operation. Exit code `0` for fully configured machine, or `1` with
informational warnings only.
**Pass/Fail:** [ ]

---

### Test 6.23: Rollback Testing — aiteamforge migrate --rollback (Default)
**Action:** After the successful migration in Test 6.7, test rollback to the most recent backup:
```bash
ls ~/.aiteamforge/migration-backups/
aiteamforge migrate --rollback
echo "Exit code: $?"
```
Respond `y` to the confirmation prompt.
**Expected Result:** Rollback finds the most recent backup under `~/.aiteamforge/migration-backups/`
(the backup created during Test 6.7). Displays backup location, size, and timestamp before
prompting. After `y`:
- Services stopped via `pkill -f "lcars-ui/server.py"` and `pkill -f "fleet-monitor/server"`
- Current state saved as `<old-dir>.before-rollback-<epoch>` (no permanent data loss)
- Backup content restored to original source directory via `cp -R`
- LaunchAgents and `~/.zshrc` restored if captured in backup
- Output: "Rollback completed successfully"
- Exit code: `3`
**Pass/Fail:** [ ]

---

### Test 6.24: Rollback Testing — aiteamforge migrate --rollback-from (Specific Backup)
**Action:** Perform a targeted rollback using an explicit backup directory path:
```bash
ls ~/.aiteamforge/migration-backups/
SPECIFIC_BACKUP=$(ls ~/.aiteamforge/migration-backups/ | sort -r | head -1)
echo "Using: $SPECIFIC_BACKUP"

aiteamforge migrate \
  --rollback-from ~/.aiteamforge/migration-backups/${SPECIFIC_BACKUP} \
  --force
echo "Exit code: $?"
```
**Expected Result:** Uses the explicitly specified backup directory rather than auto-selection.
With `--force`, no confirmation prompt. Log line "Restoring from backup" references the exact
specified path. Restoration completes successfully. Exit code is `3`.
**Pass/Fail:** [ ]

---

### Test 6.25: Rollback Testing — --rollback with No Available Backup
**Action:** Test error handling when no migration backup directory exists:
```bash
mv ~/.aiteamforge/migration-backups \
   ~/.aiteamforge/migration-backups.hidden 2>/dev/null || true
aiteamforge migrate --rollback
echo "Exit code: $?"
mv ~/.aiteamforge/migration-backups.hidden \
   ~/.aiteamforge/migration-backups 2>/dev/null || true
```
**Expected Result:** Command prints "No migration backup found to restore" and the expected
backup directory path. Exit code is non-zero and not `3`. No destructive action taken. No
unhandled error or stack trace.
**Pass/Fail:** [ ]

---

### Test 6.26: Rollback Testing — --rollback-from with Invalid Path
**Action:** Test error handling when `--rollback-from` receives a non-existent path:
```bash
aiteamforge migrate --rollback-from /nonexistent/backup/path --force
echo "Exit code: $?"
```
**Expected Result:** Prints "Backup directory not found: /nonexistent/backup/path". Exit code
is non-zero and not `3`. No files modified. No destructive action taken.
**Pass/Fail:** [ ]

---

### Test 6.27: Post-Rollback State Verification
**Action:** After rollback in Test 6.23, verify system state consistency and no data loss:
```bash
ls ~/*.before-rollback-* 2>/dev/null \
  || echo "Check for before-rollback directory near the source location used"

ls ~/.aiteamforge/MIGRATED 2>/dev/null \
  && echo "MIGRATED marker: present (correct)" \
  || echo "MIGRATED marker: absent (investigate)"

ls ~/.aiteamforge/migration-backups/ | head -5
```
**Expected Result:** A `.before-rollback-<epoch>` directory exists (rollback is reversible).
The `~/.aiteamforge/MIGRATED` marker still exists (rollback does not remove migration metadata).
Backup used for rollback remains available at `~/.aiteamforge/migration-backups/`. Original
source directory has been restored from backup content.
**Pass/Fail:** [ ]

---

### Test 6.28: Compare States — File Counts Primary vs Secondary
**Action:** Count total files in `~/.aiteamforge/` on both machines:
```bash
find ~/.aiteamforge/ -type f | wc -l
```
Run on primary, record result. Run on secondary, compare.
**Expected Result:** Counts equal or within a documented delta. Acceptable additional files on
secondary only: `MIGRATED`, `migration-state.json`, `migration.log`, `~/.zshrc.pre-migration`,
and migration backup directory contents. Core data files must have identical counts on both.
**Pass/Fail:** [ ]

---

### Test 6.29: Compare States — Critical Data Files Present on Both Machines
**Action:** On both machines, verify critical files from `path-mappings.json`
`preserve.critical_data` are present:
```bash
for path in \
  "kanban" \
  "config/machine.json" \
  "config/teams.json" \
  "claude"; do
  ls ~/.aiteamforge/$path > /dev/null 2>&1 \
    && echo "PRESENT: $path" || echo "MISSING: $path"
done
```
**Expected Result:** All paths print `PRESENT` on both machines. Zero critical paths print
`MISSING`. Optional paths never created on the primary may be absent on both (acceptable). Every
path present on the primary must be present on the secondary.
**Pass/Fail:** [ ]

---

### Test 6.30: Compare States — Kanban Board Checksums Match
**Action:** On both machines, generate SHA-256 checksums for all kanban board JSON files:
```bash
for f in ~/.aiteamforge/kanban/*-board.json; do
  echo "$(shasum -a 256 "$f" | awk '{print $1}')  $(basename $f)"
done | sort
```
Run on primary, record. Run on secondary, compare.
**Expected Result:** Every checksum-filename pair is identical between primary and secondary.
Any mismatch indicates data corruption and must be resolved before declaring the secondary
machine ready for production use.
**Pass/Fail:** [ ]

---

### Test 6.31: Compare States — Shell Integration Functional in New Session
**Action:** On the secondary machine, open a new terminal session and verify shell integration:
```bash
type kb-list
kb-list 2>/dev/null | head -5
```
**Expected Result:** `type kb-list` confirms the function is defined (sourced via
`~/.aiteamforge/shell-init.sh` loaded from `~/.zshrc`). `kb-list` returns kanban items without
errors. No "file not found" or "source failed" messages appear when the terminal opens.
**Pass/Fail:** [ ]

---

### Test 6.32: End-to-End Restore Validation — Secondary Machine Fully Operational
**Action:** Perform a complete operational smoke test on the secondary machine:
```bash
aiteamforge status
source ~/.aiteamforge/shell-init.sh
kb-list 2>/dev/null | head -10
aiteamforge doctor
curl -s http://localhost:8082/api/health \
  || curl -s http://localhost:8203/api/health \
  || echo "LCARS not running -- start with: aiteamforge start lcars"
```
**Expected Result:** `aiteamforge status` reports all configured services running or correctly
stopped. `kb-list` returns kanban data without errors. `aiteamforge doctor` exits with code `0`
with all checks passing. LCARS health endpoint responds with valid JSON. The secondary machine
is fully operational as an independent AITeamForge installation with the complete data set from
the primary machine. Zero critical errors in any component.
**Pass/Fail:** [ ]

---

### Phase 6 Summary

| Test | Description | Result |
|------|-------------|--------|
| 6.1 | Archive transfer via SCP | [ ] |
| 6.2 | Archive transfer via USB drive | [ ] |
| 6.3 | Archive transfer via AirDrop | [ ] |
| 6.4 | AITeamForge pre-installed on secondary | [ ] |
| 6.5 | Extract archive on secondary machine | [ ] |
| 6.6 | Run migration dry-run on secondary | [ ] |
| 6.7 | Run migration (live) on secondary | [ ] |
| 6.8 | Migration log integrity | [ ] |
| 6.9 | Path mapping -- framework paths | [ ] |
| 6.10 | Path mapping -- user data paths | [ ] |
| 6.11 | Path mapping -- shell integration updated | [ ] |
| 6.12 | Kanban data -- board JSON validity | [ ] |
| 6.13 | Kanban data -- item count verification | [ ] |
| 6.14 | Kanban data -- backup files accessible | [ ] |
| 6.15 | Kanban data -- interactive backup menu | [ ] |
| 6.16 | Team configs -- config files restored | [ ] |
| 6.17 | Team configs -- team data directories | [ ] |
| 6.18 | Services -- LCARS starts on secondary | [ ] |
| 6.19 | Services -- kanban backup LaunchAgent | [ ] |
| 6.20 | Services -- Fleet Monitor (if applicable) | [ ] |
| 6.21 | aiteamforge doctor passes | [ ] |
| 6.22 | aiteamforge doctor -- network check | [ ] |
| 6.23 | Rollback -- default (most recent backup) | [ ] |
| 6.24 | Rollback -- --rollback-from specific backup | [ ] |
| 6.25 | Rollback -- missing backup error handling | [ ] |
| 6.26 | Rollback -- invalid path error handling | [ ] |
| 6.27 | Post-rollback state verification | [ ] |
| 6.28 | Compare states -- file counts | [ ] |
| 6.29 | Compare states -- critical data files | [ ] |
| 6.30 | Compare states -- kanban board checksums | [ ] |
| 6.31 | Compare states -- shell integration in new session | [ ] |
| 6.32 | End-to-end restore -- secondary fully operational | [ ] |

**Total Tests:** 32
**Passed:** ___ / 32
**Failed:** ___ / 32
**Not Applicable:** ___ / 32

**Phase 6 Pass/Fail Criteria:**
- Tests 6.4, 6.5, 6.7, 6.8, 6.12, 6.13, 6.16, 6.17, 6.21, 6.23, 6.24, 6.25, 6.26,
  6.27, 6.28, 6.29, 6.30, 6.31, and 6.32 are REQUIRED to pass.
- Tests 6.1, 6.2, 6.3 -- only ONE transfer method needs to pass; mark the others N/A.
- Test 6.20 is N/A if Fleet Monitor was not configured on the primary machine.
- Phase 6 is PASS when all required tests pass and secondary machine is confirmed operational.
- Phase 6 is FAIL if any required test fails -- do not declare the secondary machine ready
  for production use until all failures are resolved.

**Phase 6 Result:** [ ] PASS   [ ] FAIL

**Notes:**

```
Transfer method used (SCP / USB / AirDrop):
Archive size transferred:
Secondary machine macOS version:
Migration completed without errors: [ ] Yes [ ] No
Doctor passed on secondary: [ ] Yes [ ] No
Rollback tested and exit code 3 confirmed: [ ] Yes [ ] No
Fleet Monitor applicable: [ ] Yes [ ] No (N/A)
Any unexpected behaviors or deviations:
```

---

*Proceed to Phase 7: Shell Environment and Alias Functionality*

---

## Phase 10: Edge Cases, Failure Modes, and Recovery Testing

**Purpose:** Validate that AITeamForge handles adversarial and degraded conditions
gracefully — interrupted operations, corrupted state, missing dependencies, resource
exhaustion, and concurrent access. A system that fails cleanly and recovers reliably
is as important as one that succeeds on the happy path.

**Prerequisites:** A fully configured AITeamForge installation (Phases 1–9 completed
successfully). Some tests deliberately break system state — restore from a known-good
snapshot or Time Machine backup before running subsequent phases if a test leaves the
system in an unrecoverable state.

**Tester note:** Record exact error messages in the Notes section at the end of the
phase. "Error message matches expected pattern" is a pass; a crash with no output or
a silent hang is always a fail.

---

### Test 10.1: Interrupted Installation Recovery — Kill Setup During Dependency Install

**Action:**
1. Begin a fresh setup: `aiteamforge setup`
2. Proceed through the wizard until the dependency-installation step begins (after
   team selection, while brew packages are being installed).
3. Press `Ctrl+C` to kill the wizard process mid-installation.
4. Wait 5 seconds, then run: `aiteamforge doctor`

**Expected Result:** The `doctor` command runs without crashing. It reports which
components are missing or incomplete rather than producing an unhandled error. The
partially installed state is clearly described. Running `aiteamforge setup` again
is able to resume or restart cleanly without manual cleanup steps.

**Pass/Fail:** [ ]

---

### Test 10.2: Interrupted Installation Recovery — Kill During File Copy

**Action:**
1. Begin a fresh setup: `aiteamforge setup`
2. Proceed until the wizard begins copying files into the working directory (the
   "Installing..." or "Deploying..." phase visible in the progress output).
3. Press `Ctrl+C` to kill the process.
4. Inspect the working directory: `ls -la ~/dev-team/` (or configured working
   directory).
5. Run `aiteamforge setup` again and complete the wizard normally.

**Expected Result:** The second `aiteamforge setup` run detects the partial
installation (via the presence or absence of `.aiteamforge-config`), offers to
continue or reinstall, and completes successfully. No orphaned files remain after
the second setup that would cause `aiteamforge doctor` to report failures.

**Pass/Fail:** [ ]

---

### Test 10.3: Corrupted Config File Handling

**Action:**
1. Confirm the system is working: `aiteamforge doctor` reports all-pass.
2. Corrupt the config file:
   ```bash
   echo "{ INVALID JSON !!!" > ~/dev-team/.aiteamforge-config
   ```
3. Run: `aiteamforge doctor`
4. Run: `aiteamforge doctor --check config`

**Expected Result:** Both `doctor` invocations exit with a non-zero exit code (2
for failures). The output reports "Config file is malformed JSON" as a FAIL item
(`✗`) and suggests `aiteamforge setup --upgrade` as the remediation. The process
does not crash with an unhandled bash error or a raw `jq` parse dump to stderr.
Exit code is 2.

**Pass/Fail:** [ ]

---

### Test 10.4: Corrupted Config File — Recovery via Upgrade

**Action:** (Continues from Test 10.3)
1. Run: `aiteamforge setup --upgrade`
2. Follow any prompts to regenerate the config, accepting defaults.
3. Run: `aiteamforge doctor`

**Expected Result:** The setup regenerates a valid `.aiteamforge-config` file.
`aiteamforge doctor --check config` reports "Config file is valid JSON" as PASS.
The full doctor run returns exit code 0 or 1 (warnings acceptable; failures not
acceptable).

**Pass/Fail:** [ ]

---

### Test 10.5: Missing Dependency — jq Removed, Doctor Reports Failure

**Action:**
1. Temporarily unlink jq from Homebrew:
   ```bash
   brew unlink jq
   ```
2. Verify jq is absent: `which jq` should return empty or "not found".
3. Run: `aiteamforge doctor`
4. Run: `aiteamforge doctor --check dependencies`
5. Restore: `brew link jq`

**Expected Result:** Steps 3 and 4 both report "jq not found" as a FAIL item with
the remediation hint "Install: brew install jq". The process does not crash or
produce a bash `command not found` trace — the `command -v jq` guard in
`check_dependencies()` handles the absent binary gracefully. The remaining
dependency checks still execute — one check's failure does not abort the suite.
Exit code is 2. After restoring jq (step 5), re-running `doctor` returns PASS for
the jq check.

**Pass/Fail:** [ ]

---

### Test 10.6: Missing Dependency — Node.js Removed, Doctor Reports Failure

**Action:**
1. Temporarily unlink Node.js: `brew unlink node`
2. Verify node is absent: `which node` should return empty or "not found".
3. Run: `aiteamforge doctor --check dependencies`
4. Restore: `brew link node`

**Expected Result:** Doctor reports "Node.js not found" as a FAIL with the hint
"Install: brew install node". The remaining dependency checks still run — the
failure of one check does not abort the entire check suite. Exit code is 2.
After restoring (step 4) the Node.js check passes cleanly.

**Pass/Fail:** [ ]

---

### Test 10.7: Disk Full Scenario — Pre-migration Disk Check

**Action:**
1. Run the migration dry-run to exercise the disk-space pre-check:
   ```bash
   aiteamforge migrate --old-dir ~/dev-team --dry-run 2>&1 \
     | grep -i "disk\|space\|available\|required"
   ```
2. Observe whether the migration pre-check reports disk space requirements.
3. To verify the check logic, inspect `aiteamforge-migrate.sh` and confirm it
   calculates `REQUIRED_SPACE=$((OLD_SIZE * 3))` (original + backup + new location)
   and exits with code 2 when `AVAILABLE_SPACE < REQUIRED_SPACE`.

**Expected Result:** The dry-run output includes disk space information. When
available space is less than three times the installation size, the migration exits
with: message "Insufficient disk space", required figure (MB), available figure
(MB), suggestion to use `--skip-backup` (marked "not recommended"), and exit code
2 (not a crash).

**Pass/Fail:** [ ]

---

### Test 10.8: Network Interruption During Fleet Monitor Sync

**Action:**
1. Ensure Fleet Monitor is running: `aiteamforge doctor --check services` shows
   "Fleet Monitor server" passing.
2. Disable the network interface:
   ```bash
   networksetup -setnetworkserviceenabled "Wi-Fi" off
   ```
3. Wait 60 seconds (one full Fleet Monitor heartbeat interval).
4. Re-enable the network:
   ```bash
   networksetup -setnetworkserviceenabled "Wi-Fi" on
   ```
5. Wait 60 seconds, then run: `aiteamforge doctor --check services`

**Expected Result:** During the outage, the Fleet Monitor client queues or silently
drops heartbeats rather than crashing the LaunchAgent or producing error dialogs.
After restoration, heartbeats resume automatically within two intervals (120 seconds).
`doctor --check services` returns to its pre-outage state without requiring a manual
restart.

**Pass/Fail:** [ ]

---

### Test 10.9: Service Crash Recovery — Kill LCARS Server, Verify Auto-Restart

**Action:**
1. Confirm LCARS is running: `aiteamforge doctor --check services` shows LCARS
   passing.
2. Record the LCARS process PID:
   ```bash
   pgrep -f "lcars-ui/server.py"
   ```
3. Hard-kill the LCARS server:
   ```bash
   kill -9 $(pgrep -f "lcars-ui/server.py")
   ```
4. Immediately run: `aiteamforge doctor --check services`
5. Wait 60 seconds (one `com.aiteamforge.lcars-health` LaunchAgent interval), then
   run: `aiteamforge doctor --check services` again.

**Expected Result:** Step 4 shows "LCARS Kanban server not running" as a WARNING
(exit code 1). Step 5 shows the LCARS server running again — the
`com.aiteamforge.lcars-health` LaunchAgent detected the process absence and
restarted it automatically. `doctor --check launchagents` confirms the health
LaunchAgent remained loaded throughout.

**Pass/Fail:** [ ]

---

### Test 10.10: Service Crash Recovery — Kill Fleet Monitor, Observe Behavior

**Action:**
1. Confirm Fleet Monitor is running (if configured).
2. Hard-kill the Fleet Monitor server:
   ```bash
   kill -9 $(pgrep -f "fleet-monitor/server")
   ```
3. Run `aiteamforge doctor --check services` immediately.
4. Wait 90 seconds, then run `aiteamforge doctor --check services` again.

**Expected Result:** Step 3 reports "Fleet Monitor server not running" as a WARNING
with the hint "Start: aiteamforge start fleet". Step 4 either shows the Fleet
Monitor running again (if a LaunchAgent manages it) or repeats the WARNING — but in
neither case does the system crash or produce an error cascade. LCARS and all other
services remain unaffected.

**Pass/Fail:** [ ]

---

### Test 10.11: Upgrade With Breaking Changes — Dry Run Preview

**Action:**
1. Run the upgrade in dry-run mode:
   ```bash
   aiteamforge upgrade --dry-run
   ```
2. Review output for all component sections: Homebrew formula, templates, LCARS UI,
   shell helpers, skills, LaunchAgents.

**Expected Result:** Each section reports either "up to date" or
"Would update: <filename>" — never a crash or unhandled error. The dry-run output
clearly distinguishes between framework files (updated) and user data (preserved).
The words "kanban" and "kanban-backups" do not appear in the "Would update" list —
user board data is never touched by upgrade. Exit code is 0.

**Pass/Fail:** [ ]

---

### Test 10.12: Upgrade With Breaking Changes — Template Backup Files Created

**Action:**
1. Run a forced upgrade to trigger template re-processing:
   ```bash
   aiteamforge upgrade --force
   ```
2. After completion, inspect for backup files:
   ```bash
   ls ~/dev-team/config/*.backup-* 2>/dev/null || echo "No config backups"
   ls ~/dev-team/share/aliases/*.backup-* 2>/dev/null || echo "No alias backups"
   ```

**Expected Result:** Any template file updated by the force-upgrade has a
corresponding `.backup-<timestamp>` file in the same directory. The upgrade output
listed each updated file before overwriting it. Kanban board JSON files are absent
from the backup list.

**Pass/Fail:** [ ]

---

### Test 10.13: Downgrade and Rollback After Failed Migration

**Action:**
1. Run the migration (or verify a migration backup exists):
   ```bash
   aiteamforge migrate --dry-run   # Verify plan first
   aiteamforge migrate             # Run actual migration; confirm when prompted
   ```
2. After migration, simulate a failure by corrupting the migrated config:
   ```bash
   echo "{BAD}" > ~/.aiteamforge/.aiteamforge-config
   ```
3. Initiate rollback:
   ```bash
   aiteamforge migrate --rollback
   ```
4. When prompted "Continue with rollback? [y/N]", enter `y`.
5. After rollback, run: `aiteamforge doctor`

**Expected Result:** The rollback:
- Finds the most recent backup under `~/.aiteamforge/migration-backups/`.
- Displays backup location, size, and creation timestamp before prompting.
- Restores the original installation to `~/aiteamforge/` (or configured `--old-dir`).
- Exits with code 3 (rollback-success code, distinct from failure code 1).
After rollback, `aiteamforge doctor` passes the config check.

**Pass/Fail:** [ ]

---

### Test 10.14: Downgrade — Rollback from a Specific Backup Path

**Action:**
1. List available migration backups:
   ```bash
   ls ~/.aiteamforge/migration-backups/
   ```
2. If multiple backups exist, pick any non-latest backup directory.
3. Run rollback targeting that specific backup:
   ```bash
   aiteamforge migrate --rollback-from \
     ~/.aiteamforge/migration-backups/<chosen-dir>
   ```
4. Confirm with `y` when prompted.

**Expected Result:** The rollback uses the specified backup directory. The output
confirms "Restoring from backup: <chosen-dir>". If the specified directory does not
exist, the process exits with code 1 and the message "Backup directory not found:
<path>" rather than silently falling back to the latest backup.

**Pass/Fail:** [ ]

---

### Test 10.15: Uninstall and Clean Reinstall Cycle

**Action:**
1. Run a standard uninstall (keeping data):
   ```bash
   aiteamforge uninstall --keep-data
   ```
2. When prompted "Continue with uninstall?", enter `y`.
3. When prompted "Preserve kanban board data?", enter `y`.
4. When prompted "Preserve secrets.env?", enter `y`.
5. After uninstall, verify shell integration is removed:
   ```bash
   grep "aiteamforge" ~/.zshrc | grep -v "^#" | grep -v "^$"
   ```
6. Run a clean reinstall: `aiteamforge setup`
7. Complete the wizard using the same team configuration as before.
8. Run: `aiteamforge doctor`

**Expected Result:**
- Step 5 returns no active (uncommented) aiteamforge lines in `.zshrc` — the
  `# >>> aiteamforge initialize >>>` block was removed. A `.zshrc.backup-<timestamp>`
  file exists as evidence.
- LaunchAgent plist files are removed from `~/Library/LaunchAgents/`.
- Kanban board data files are still present in their preserved location.
- After reinstall, `aiteamforge doctor` reports all-pass or warnings-only (no
  failures). Kanban boards are accessible and intact.

**Pass/Fail:** [ ]

---

### Test 10.16: Uninstall Purge — Complete Removal Verified

**Action:**
1. Back up kanban boards first:
   ```bash
   cp -R ~/dev-team/kanban/ /tmp/kanban-backup-purge-test/
   ```
2. Run a full purge uninstall:
   ```bash
   aiteamforge uninstall --purge --yes
   ```
3. After completion, verify removal:
   ```bash
   ls ~/dev-team/ 2>/dev/null || echo "Working directory removed"
   launchctl list | grep aiteamforge || echo "No LaunchAgents remain"
   grep "aiteamforge" ~/.zshrc | grep -v "^#" || echo "No active zshrc entries"
   ```
4. Restore kanban boards:
   ```bash
   mkdir -p ~/dev-team/kanban
   cp -R /tmp/kanban-backup-purge-test/ ~/dev-team/kanban/
   ```

**Expected Result:** Step 3 confirms: working directory is empty or removed;
no `com.aiteamforge.*` entries in `launchctl list`; no uncommented aiteamforge
entries in `.zshrc`. The purge does not prompt for confirmation when `--yes` is
supplied. Exit code is 0. The instruction to run `brew uninstall aiteamforge` is
shown at the end.

**Pass/Fail:** [ ]

---

### Test 10.17: Permission Issues — Read-Only Working Directory

**Action:**
1. Make the working directory read-only:
   ```bash
   chmod -R a-w ~/dev-team/
   ```
2. Attempt a forced upgrade:
   ```bash
   aiteamforge upgrade --force 2>&1; echo "Exit: $?"
   ```
3. Restore permissions:
   ```bash
   chmod -R u+w ~/dev-team/
   ```

**Expected Result:** The `upgrade` command detects the write failure and exits with
code 1. The error output identifies which file or directory could not be written.
The process does not silently succeed while leaving files in an inconsistent state.
The working directory structure is unchanged after the failed upgrade — no partial
writes.

**Pass/Fail:** [ ]

---

### Test 10.18: Permission Issues — Read-Only LaunchAgents Directory

**Action:**
1. Make the LaunchAgents directory read-only:
   ```bash
   chmod a-w ~/Library/LaunchAgents/
   ```
2. Run a forced upgrade:
   ```bash
   aiteamforge upgrade --force 2>&1; echo "Exit: $?"
   ```
3. Restore:
   ```bash
   chmod u+w ~/Library/LaunchAgents/
   ```

**Expected Result:** The upgrade continues updating other components (templates,
LCARS UI, shell helpers) even when the LaunchAgents directory is not writable. The
LaunchAgent update step prints a clear permission-denied error and skips that
component rather than aborting the entire upgrade. LaunchAgents already loaded
remain loaded and functional. Exit code is 1, not a crash.

**Pass/Fail:** [ ]

---

### Test 10.19: Concurrent Setup Wizard Runs

**Action:**
1. Open two terminal windows.
2. In terminal 1, start the setup wizard and leave it at a prompt (do not submit
   any input): `aiteamforge setup`
3. Immediately in terminal 2, start a second wizard: `aiteamforge setup`
4. Observe what terminal 2 outputs.
5. Complete the wizard in terminal 1 normally, then run: `aiteamforge doctor`

**Expected Result:** Terminal 2 either:
   a) Detects the concurrent run (via a lockfile or process check) and exits with
      "Another aiteamforge setup is already running" and code 1, OR
   b) Completes independently without corrupting the installation terminal 1 is
      building — both runs produce a valid, consistent `.aiteamforge-config`.
A corrupt or partially-written config file after either run is a FAIL. Silent data
corruption (config truncated, JSON invalid) is always a FAIL.

**Pass/Fail:** [ ]

---

### Test 10.20: Large Kanban Board Performance

**Action:**
1. Generate a synthetic board with 500 items:
   ```bash
   python3 - <<'EOF'
   import json, random, time, os
   items = []
   for i in range(500):
       items.append({
           "id": f"PERF-{i:04d}",
           "title": f"Performance test item {i}",
           "status": random.choice(["backlog","in_progress","in_review","done"]),
           "priority": random.choice(["high", "medium", "low"]),
           "created": time.strftime("%Y-%m-%dT%H:%M:%SZ")
       })
   board = {"version": "1.0.0", "team": "perf-test", "items": items}
   path = os.path.expanduser("~/dev-team/kanban/perf-test-board.json")
   with open(path, "w") as f:
       json.dump(board, f, indent=2)
   print(f"Created {len(items)} items at {path}")
   EOF
   ```
2. Run and time: `time aiteamforge doctor --check config`
3. If LCARS is running, open `http://localhost:<port>/` in a browser and measure
   time to first render.
4. Remove the test board: `rm ~/dev-team/kanban/perf-test-board.json`

**Expected Result:** `aiteamforge doctor --check config` completes in under 10
seconds with 500-item boards present. With `--verbose`, the board count is reported
as a single integer. The LCARS UI loads the board list within 5 seconds. No timeout,
out-of-memory error, or jq parse failure is produced. The test board is cleanly
removable without affecting other boards.

**Pass/Fail:** [ ]

---

### Test 10.21: LaunchAgent Failure — Plist Deleted Without Unloading

**Action:**
1. Confirm LaunchAgents are loaded: `aiteamforge doctor --check launchagents`
2. Delete the kanban-backup plist without unloading first:
   ```bash
   rm ~/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist
   ```
3. Run: `aiteamforge doctor --check launchagents`
4. Restore via: `aiteamforge setup --upgrade`
5. Run: `aiteamforge doctor --check launchagents`

**Expected Result:** Step 3 reports "com.aiteamforge.kanban-backup plist missing"
as a WARNING with the remediation hint "Run: aiteamforge setup --upgrade". The
process handles the discrepancy between launchctl's in-memory state and the missing
plist file without crashing. After step 4, the plist is restored. Step 5 confirms
"com.aiteamforge.kanban-backup loaded" as PASS.

**Pass/Fail:** [ ]

---

### Test 10.22: LaunchAgent Failure — Both Agents Manually Unloaded

**Action:**
1. Unload both LaunchAgents:
   ```bash
   launchctl unload ~/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist
   launchctl unload ~/Library/LaunchAgents/com.aiteamforge.lcars-health.plist
   ```
2. Run: `aiteamforge doctor --check launchagents`
3. Reload using the exact commands shown in the doctor output.
4. Run: `aiteamforge doctor --check launchagents` again.

**Expected Result:** Step 2 reports both agents as WARNING with status "plist exists
but not loaded" and the exact `launchctl load <path>` command as the remediation
hint. Exit code is 1 (warnings only — a not-loaded agent is non-fatal since the
plist file still exists). Step 4 reports both agents as PASS with exit code 0.

**Pass/Fail:** [ ]

---

### Test 10.23: Invalid Team Configuration — Path Traversal Attempt

**Action:**
1. Inject a path-traversal team ID into the config:
   ```bash
   python3 - <<'EOF'
   import json, os
   cfg_path = os.path.expanduser("~/dev-team/.aiteamforge-config")
   with open(cfg_path) as f:
       cfg = json.load(f)
   cfg.setdefault("teams", []).append("../../etc/passwd")
   with open(cfg_path, "w") as f:
       json.dump(cfg, f, indent=2)
   print("Injected path traversal team entry")
   EOF
   ```
2. Run: `aiteamforge doctor`
3. Confirm that `/etc/passwd` contents are not printed to the terminal.
4. Restore the config: `aiteamforge setup --upgrade`

**Expected Result:** The doctor reports the invalid team entry as either a WARNING
or FAIL. The path resolves outside the install directory — the team-directory check
reports "Team directory missing: <resolved-path>" without reading or printing the
contents of `/etc/passwd`. No system file contents appear in the output. The process
exits cleanly. Silent exposure of `/etc/passwd` contents is always a FAIL.

**Pass/Fail:** [ ]

---

### Test 10.24: Invalid Team Configuration — Unknown Team ID

**Action:**
1. Add a nonexistent team ID to the config:
   ```bash
   python3 - <<'EOF'
   import json, os
   cfg_path = os.path.expanduser("~/dev-team/.aiteamforge-config")
   with open(cfg_path) as f:
       cfg = json.load(f)
   cfg.setdefault("teams", []).append("nonexistent-team-xyz")
   with open(cfg_path, "w") as f:
       json.dump(cfg, f, indent=2)
   print("Added nonexistent team")
   EOF
   ```
2. Run: `aiteamforge doctor`
3. Restore: `aiteamforge setup --upgrade`

**Expected Result:** The doctor reports "Team directory missing:
~/dev-team/nonexistent-team-xyz" (or the equivalent resolved path) as a FAIL or
WARNING. The remaining configured teams are still checked — the invalid team does
not abort the team-checking loop. Exit code is 2 if FAIL, 1 if WARNING. The
remediation hint "Run: aiteamforge setup --upgrade" is shown.

**Pass/Fail:** [ ]

---

### Test 10.25: Doctor Exit Code Contract Verification

**Action:**
1. Ensure the system is healthy and note the exit code:
   ```bash
   aiteamforge doctor; echo "Exit: $?"
   ```
2. Remove jq to introduce a failure: `brew unlink jq`
3. Run doctor and note the exit code:
   ```bash
   aiteamforge doctor; echo "Exit: $?"
   ```
4. Restore jq: `brew link jq`
5. Introduce only a warning (unload one LaunchAgent):
   ```bash
   launchctl unload ~/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist
   aiteamforge doctor; echo "Exit: $?"
   launchctl load ~/Library/LaunchAgents/com.aiteamforge.kanban-backup.plist
   ```

**Expected Result:**
- Step 1: exit code 0 (all checks pass, no warnings) OR exit code 1 (warnings only).
  Document which is observed.
- Step 3: exit code 2 (failures detected — jq missing is FAIL per doctor source).
- Step 5: exit code 1 (warnings only — LaunchAgent not loaded is WARNING per
  `check_launchagents()`).
The exit code contract (0=clean, 1=warnings-only, 2=failures) must be consistent
and machine-parseable for CI/CD integration. Any deviation is a FAIL.

**Pass/Fail:** [ ]

---

## Phase 10 Test Summary

| Test | Description | Steps | Pass/Fail |
|------|-------------|-------|-----------|
| 10.1 | Kill setup during dependency install | 4 | |
| 10.2 | Kill setup during file copy, resume | 5 | |
| 10.3 | Corrupted config — doctor detects and reports | 4 | |
| 10.4 | Corrupted config — recovery via setup --upgrade | 3 | |
| 10.5 | jq removed — doctor reports without crash | 5 | |
| 10.6 | Node.js removed — doctor reports without crash | 4 | |
| 10.7 | Disk full — migration pre-check exits code 2 | 3 | |
| 10.8 | Network interruption — Fleet Monitor reconnects | 5 | |
| 10.9 | LCARS killed — lcars-health LaunchAgent restarts it | 5 | |
| 10.10 | Fleet Monitor killed — behavior stable | 4 | |
| 10.11 | Upgrade dry-run — user data never in update list | 2 | |
| 10.12 | Upgrade --force — template backup files created | 2 | |
| 10.13 | Migration rollback — most recent backup used | 5 | |
| 10.14 | Migration rollback — specific backup path honored | 4 | |
| 10.15 | Uninstall keep-data, clean reinstall cycle | 8 | |
| 10.16 | Uninstall --purge --yes — complete removal verified | 4 | |
| 10.17 | Read-only working directory — upgrade exits code 1 | 3 | |
| 10.18 | Read-only LaunchAgents — upgrade degrades gracefully | 3 | |
| 10.19 | Concurrent setup wizard runs — no corruption | 5 | |
| 10.20 | 500-item kanban board — doctor under 10 seconds | 4 | |
| 10.21 | LaunchAgent plist deleted — doctor warns, upgrade restores | 5 | |
| 10.22 | LaunchAgents unloaded — doctor warns with exact fix | 4 | |
| 10.23 | Invalid team config — path traversal contained | 4 | |
| 10.24 | Invalid team config — unknown team ID reported | 3 | |
| 10.25 | Doctor exit code contract 0/1/2 verified | 5 | |
| **Total** | | **101** | |

**Phase 10 Pass/Fail Criteria:**

Required tests (PASS verdict mandatory):
- **10.3** — Corrupted config must be detected and reported, not cause a crash
- **10.5** — Missing jq must be caught gracefully, not produce a bash error trace
- **10.9** — LCARS crash recovery via LaunchAgent auto-restart must function
- **10.13** — Migration rollback must restore state and exit with code 3
- **10.15** — Uninstall keep-data then clean reinstall must succeed end-to-end
- **10.16** — Purge uninstall must remove all components completely
- **10.25** — Doctor exit code contract (0/1/2) must be consistent

Important tests (WARN-level outcomes acceptable with written justification):
- 10.1, 10.2, 10.4, 10.6, 10.7, 10.8, 10.10, 10.11, 10.12, 10.14, 10.17, 10.18,
  10.19, 10.20, 10.21, 10.22, 10.23, 10.24

Phase 10 is **PASS** when all required tests pass and no test produces silent data
corruption, a crash with no output, or an unhandled bash error trace.
Phase 10 is **FAIL** if any required test fails or if any test leaves the system
in an unrecoverable state without recovery instructions in the output.

**Phase 10 Result:** [ ] PASS   [ ] FAIL

**Notes (record exact error messages, timing observations, and unexpected behavior):**

```
Test 10.1 — interruption point reached:
Test 10.2 — interruption point reached:
Test 10.3 — exact doctor output for corrupt config:
Test 10.5 — exact doctor output for missing jq:
Test 10.7 — disk space figures reported (required / available):
Test 10.8 — reconnection observed after (seconds):
Test 10.9 — LCARS auto-restart observed after (seconds):
Test 10.13 — rollback exit code observed:
Test 10.19 — concurrent wizard behavior observed:
Test 10.20 — doctor timing (seconds):
Test 10.20 — LCARS UI load time (seconds):
Test 10.25 — exit codes: healthy=___ jq-missing=___ launchagent-warning=___
Any crashes or unhandled errors encountered:
```

---

*Proceed to Phase 11: Post-Testing Retrospective*

---

---

## Phase 8: Remote Access from Primary Dev Machine

**Purpose:** Validate that the primary development machine can securely access the Fleet Monitor
dashboard, kanban boards, and agent status on the secondary machine over Tailscale. Verify
Tailscale Funnel delivers HTTPS access with valid certificates, confirm API endpoints are
reachable cross-machine, and confirm the system degrades gracefully when Tailscale is unavailable.

**Prerequisites:**
- Phase 7 (Fleet Monitor) complete and verified on the secondary machine
- AITeamForge installed and running on BOTH machines
- Both machines enrolled in the same Tailscale tailnet
- Tailscale Funnel enabled on the secondary machine (server role)
- Primary machine has Tailscale installed (client role)

**Machines:**
- **Secondary machine** — AITeamForge server running Fleet Monitor on port 3000
- **Primary machine** — Test client (this machine, where all curl/browser tests are run)

---

### Section 8.1: Tailscale Installation and Authentication

### Test 8.1.1: Tailscale Installed on Secondary Machine
**Action:** On the secondary machine, run:
```
tailscale version
```
**Expected Result:** Version string is printed (e.g., `1.60.x`). Exit code is 0.
**Pass/Fail:** [ ]

### Test 8.1.2: Tailscale Installed on Primary Machine
**Action:** On the primary machine, run:
```
tailscale version
```
**Expected Result:** Version string is printed. Exit code is 0.
**Pass/Fail:** [ ]

### Test 8.1.3: Secondary Machine is Authenticated and Connected
**Action:** On the secondary machine, run:
```
tailscale status
```
**Expected Result:** Output lists the secondary machine with status `active` or `online`. The
primary machine is also visible in the peer list if both are online.
**Pass/Fail:** [ ]

### Test 8.1.4: Primary Machine is Authenticated and Connected
**Action:** On the primary machine, run:
```
tailscale status
```
**Expected Result:** Output lists the primary machine as connected. The secondary machine appears
as a peer with an assigned Tailscale IP in the `100.x.x.x` range.
**Pass/Fail:** [ ]

### Test 8.1.5: MagicDNS Resolves Secondary Machine Hostname
**Action:** On the primary machine, run:
```
ping -c 3 <secondary-machine-tailscale-hostname>
```
Where `<secondary-machine-tailscale-hostname>` is the Tailscale MagicDNS name shown in
`tailscale status` (e.g., `macbook-pro-secondary`).
**Expected Result:** Ping succeeds with 3 replies. Round-trip time is under 200 ms for
same-network machines; any response is acceptable for cross-network machines.
**Pass/Fail:** [ ]

### Test 8.1.6: Tailscale IP is Consistent Across Sessions
**Action:** On the secondary machine, run `tailscale ip` and record the IP. Disconnect and
reconnect Tailscale (`sudo tailscale down && sudo tailscale up`), then run `tailscale ip` again.
**Expected Result:** The Tailscale IP is the same before and after reconnect. (IPs are stable
within a tailnet unless explicitly changed.)
**Pass/Fail:** [ ]

---

### Section 8.2: Tailscale Funnel Setup for Fleet Monitor

### Test 8.2.1: Funnel Script Syntax Is Valid
**Action:** On the secondary machine, run:
```
bash -n ~/aiteamforge/scripts/tailscale-funnel-restore.sh
```
**Expected Result:** No output and exit code 0, indicating the funnel restore script has valid
bash syntax.
**Pass/Fail:** [ ]

### Test 8.2.2: Funnel is Enabled on Secondary Machine
**Action:** On the secondary machine, run:
```
tailscale funnel status
```
**Expected Result:** Output shows Funnel is active for port 3000 (Fleet Monitor). A public HTTPS
URL in the format `https://<hostname>.<tailnet>.ts.net` is listed for the Fleet Monitor service.
**Pass/Fail:** [ ]

### Test 8.2.3: Funnel Port Matches Fleet Monitor Configuration
**Action:** On the secondary machine, run:
```
cat ~/aiteamforge/fleet-monitor/config.json | jq .port
tailscale funnel status
```
**Expected Result:** The port number in `config.json` (default: 3000) matches the port exposed
via Funnel in `tailscale funnel status`.
**Pass/Fail:** [ ]

### Test 8.2.4: Funnel Restore Script Runs Without Error
**Action:** On the secondary machine (with Tailscale connected), run:
```
bash ~/aiteamforge/scripts/tailscale-funnel-restore.sh
```
**Expected Result:** Script prints "Tailscale is connected", configures Funnel routes without
errors, prints "Funnel restoration complete!", and exits with code 0. The final
`tailscale funnel status` output shows the configured routes.
**Pass/Fail:** [ ]

### Test 8.2.5: Funnel Restore Script Fails Gracefully When Tailscale is Offline
**Action:** On the secondary machine, stop Tailscale (`sudo tailscale down`), then run:
```
bash ~/aiteamforge/scripts/tailscale-funnel-restore.sh
```
**Expected Result:** Script prints "ERROR: Tailscale is not running or not connected" and exits
with a non-zero exit code. No partial configuration is applied. Reconnect afterward:
`sudo tailscale up`.
**Pass/Fail:** [ ]

---

### Section 8.3: HTTPS Certificate Verification

### Test 8.3.1: Funnel URL Has Valid HTTPS Certificate
**Action:** From the primary machine, run:
```
curl -v https://<secondary-funnel-hostname>/api/health 2>&1 | grep -E "SSL|TLS|certificate|subject|issuer|expire"
```
Where `<secondary-funnel-hostname>` is the full `https://hostname.tailnet.ts.net` URL shown by
`tailscale funnel status` on the secondary machine.
**Expected Result:** Output shows a valid TLS certificate. No SSL errors. Certificate subject
matches the Funnel hostname. Certificate issuer is Let's Encrypt or Tailscale's CA.
**Pass/Fail:** [ ]

### Test 8.3.2: HTTP Does Not Expose Fleet Monitor to the Internet
**Action:** From the primary machine, attempt a plain-HTTP connection to the Tailscale IP:
```
curl -v --max-time 5 http://<secondary-tailscale-ip>:3000/api/health 2>&1 | head -20
```
**Expected Result:** Connection succeeds on the tailnet (accessible only to authenticated
Tailscale peers) OR is refused. The Funnel HTTPS URL is the only internet-accessible endpoint.
Plain HTTP on port 3000 must never be reachable from the public internet.
**Pass/Fail:** [ ]

### Test 8.3.3: Certificate Expiry is Not Imminent
**Action:** From the primary machine, run:
```
echo | openssl s_client -connect <secondary-funnel-hostname>:443 2>/dev/null | openssl x509 -noout -dates
```
**Expected Result:** `notAfter` date is at least 30 days in the future. (Tailscale auto-renews
certificates; an imminent expiry indicates a renewal failure.)
**Pass/Fail:** [ ]

---

### Section 8.4: Remote Fleet Monitor Dashboard Access

### Test 8.4.1: Health Endpoint Responds from Primary Machine
**Action:** From the primary machine, run:
```
curl -s https://<secondary-funnel-hostname>/api/health | jq .
```
**Expected Result:** JSON response with `"status": "operational"`, a valid `uptime` value,
`"timestamp"` in ISO 8601 format, and non-negative `machines_tracked` and `registered_teams`
counts. HTTP response code is 200.
**Pass/Fail:** [ ]

### Test 8.4.2: Fleet Endpoint Returns Secondary Machine in Listing
**Action:** From the primary machine, run:
```
curl -s https://<secondary-funnel-hostname>/api/fleet | jq '{online: .fleet.online_machines, machines: [.fleet.machines[].hostname]}'
```
**Expected Result:** The secondary machine's hostname appears in the machines list.
`online_machines` is at least 1. No 404 or 500 error.
**Pass/Fail:** [ ]

### Test 8.4.3: Registered Teams Endpoint Returns Data
**Action:** From the primary machine, run:
```
curl -s https://<secondary-funnel-hostname>/api/registered-teams | jq '{total: .total, teams: [.teams[].team]}'
```
**Expected Result:** Response includes `total` greater than 0 and a list of team names matching
the teams configured during setup on the secondary machine. HTTP response code is 200.
**Pass/Fail:** [ ]

### Test 8.4.4: Dashboard UI Loads in Browser from Primary Machine
**Action:** On the primary machine, open a browser and navigate to:
```
https://<secondary-funnel-hostname>
```
**Expected Result:** Fleet Monitor dashboard loads with no browser security warnings. The
secondary machine is visible in the machines list. Active sessions from the secondary machine
are displayed.
**Pass/Fail:** [ ]

### Test 8.4.5: Machine History Endpoint Accessible Remotely
**Action:** From the primary machine, retrieve the secondary machine's machine_id then query its
history:
```
MACHINE_ID=$(curl -s https://<secondary-funnel-hostname>/api/fleet | jq -r '.fleet.machines[0].machine_id')
curl -s "https://<secondary-funnel-hostname>/api/machine/${MACHINE_ID}/history?limit=10" \
  | jq '{total: .total, entries_returned: (.entries | length)}'
```
**Expected Result:** Response includes `total` (number of history entries) and `entries_returned`
of up to 10. HTTP response code is 200.
**Pass/Fail:** [ ]

---

### Section 8.5: API Access from Primary Machine

### Test 8.5.1: POST /api/status Accepted from Primary Machine
**Action:** From the primary machine, simulate a status heartbeat:
```
curl -s -X POST https://<secondary-funnel-hostname>/api/status \
  -H "Content-Type: application/json" \
  -d '{
    "machine": {
      "hostname": "primary-test-probe",
      "machine_id": "00000000-0000-0000-0000-000000000001",
      "ip": "100.0.0.1",
      "os": "macOS"
    },
    "sessions": []
  }' | jq .
```
**Expected Result:** Response is `{"success": true, "message": "Status received", "sessions_count": 0}`.
HTTP response code is 200.
**Pass/Fail:** [ ]

### Test 8.5.2: Invalid Status Payload Rejected with 400
**Action:** From the primary machine, send a malformed status request (missing hostname):
```
curl -s -o /dev/null -w "%{http_code}" -X POST https://<secondary-funnel-hostname>/api/status \
  -H "Content-Type: application/json" \
  -d '{"machine": {}}'
```
**Expected Result:** HTTP response code is 400. The server does not crash. Subsequent valid
requests to `/api/health` still return 200.
**Pass/Fail:** [ ]

### Test 8.5.3: Nickname Update Endpoint Works Remotely
**Action:** From the primary machine, set a nickname on the secondary machine's first machine
entry, then verify it persists:
```
MACHINE_ID=$(curl -s https://<secondary-funnel-hostname>/api/fleet | jq -r '.fleet.machines[0].machine_id')
curl -s -X PUT "https://<secondary-funnel-hostname>/api/machine/${MACHINE_ID}/nickname" \
  -H "Content-Type: application/json" \
  -d '{"nickname": "remote-test-nick"}' | jq .
curl -s https://<secondary-funnel-hostname>/api/fleet | jq '.fleet.machines[0].nickname'
```
**Expected Result:** PUT returns `{"success": true}` with HTTP 200. The fleet query confirms
`"remote-test-nick"` is the nickname. Clean up by clearing it:
```
curl -s -X PUT "https://<secondary-funnel-hostname>/api/machine/${MACHINE_ID}/nickname" \
  -H "Content-Type: application/json" \
  -d '{"nickname": ""}' | jq .
```
**Pass/Fail:** [ ]

### Test 8.5.4: Backup Status Endpoint Returns Valid Structure
**Action:** From the primary machine, run:
```
curl -s https://<secondary-funnel-hostname>/api/backup-status | jq '{status: .status, lastRun: .lastRun}'
```
**Expected Result:** Response includes a `status` field (one of: `"configured"`, `"not_configured"`,
`"stale"`, `"error"`). HTTP response code is 200 in all cases. Server does not return 500.
**Pass/Fail:** [ ]

---

### Section 8.6: Remote Kanban Board Viewing

### Test 8.6.1: Kanban Boards Visible via Fleet Monitor Dashboard
**Action:** On the primary machine, open the Fleet Monitor dashboard:
```
https://<secondary-funnel-hostname>
```
Navigate to the Kanban or Teams section of the UI.
**Expected Result:** Kanban boards from the secondary machine's configured teams are visible.
Board data reflects the actual state of kanban items on the secondary machine (not stale/empty).
**Pass/Fail:** [ ]

### Test 8.6.2: Team Registration Data Accessible Remotely
**Action:** From the primary machine, run:
```
curl -s https://<secondary-funnel-hostname>/api/registered-teams \
  | jq '.teams[] | {team: .team, org: .organization, terminals: .terminalCount}'
```
**Expected Result:** Each registered team from the secondary machine is listed with its
organization name and terminal count. Data matches what was configured during team setup in
earlier phases.
**Pass/Fail:** [ ]

### Test 8.6.3: LCARS Port Data Included in Team Registration
**Action:** From the primary machine, run:
```
curl -s https://<secondary-funnel-hostname>/api/registered-teams | jq '.teams[0].terminals | keys'
```
**Expected Result:** Terminal names (e.g., `"picard"`, `"riker"`, `"data"`) are listed as keys.
Each terminal entry contains metadata such as `lcars_port` or `theme_color` if populated.
**Pass/Fail:** [ ]

---

### Section 8.7: Remote Team Status Monitoring

### Test 8.7.1: Online/Offline Status Reflects Secondary Machine State
**Action:** From the primary machine, record the current counts:
```
curl -s https://<secondary-funnel-hostname>/api/fleet | jq '{online: .fleet.online_machines, offline: .fleet.offline_machines}'
```
Then stop Fleet Monitor on the secondary machine and wait 3 minutes (OFFLINE_THRESHOLD_MS = 180s):
```
# On secondary machine:
aiteamforge stop fleet-monitor
```
Re-query from the primary machine after the wait.
**Expected Result:** After the threshold elapses, `online_machines` decreases by 1 and
`offline_machines` increases by 1. Restart Fleet Monitor to restore:
`aiteamforge start fleet-monitor`.
**Pass/Fail:** [ ]

### Test 8.7.2: Warning Status Appears Before Offline Transition
**Action:** On the secondary machine, stop Fleet Monitor. Wait 2 minutes (WARNING_THRESHOLD_MS = 120s)
but less than 3 minutes. From the primary machine, query:
```
curl -s https://<secondary-funnel-hostname>/api/fleet | jq '.fleet.machines[] | {hostname: .hostname, status: .status}'
```
**Expected Result:** The secondary machine's status shows `"warning"` (not yet `"offline"`).
After the full 3-minute threshold, status transitions to `"offline"`. Restart Fleet Monitor to
restore.
**Pass/Fail:** [ ]

### Test 8.7.3: Session Count Reflects Active Claude Sessions
**Action:** On the secondary machine, launch a new Claude Code session in a new tmux window.
Wait for the next status heartbeat (default: 60 seconds), then from the primary machine, query:
```
curl -s https://<secondary-funnel-hostname>/api/fleet \
  | jq '.fleet.machines[] | {hostname: .hostname, session_count: .session_count}'
```
**Expected Result:** The session count for the secondary machine increases by 1 compared to
the baseline recorded before launching the new session.
**Pass/Fail:** [ ]

---

### Section 8.8: Latency and Responsiveness

### Test 8.8.1: Health Endpoint Responds Within Acceptable Latency
**Action:** From the primary machine, measure response time 5 times:
```
for i in 1 2 3 4 5; do time curl -s https://<secondary-funnel-hostname>/api/health > /dev/null; done
```
**Expected Result:** All 5 requests complete within 3 seconds. At least 4 of 5 complete within
1 second for same-network machines. Latency above 3 seconds on any request is a failure.
Record all 5 measurements in the Phase 8 Notes block.
**Pass/Fail:** [ ]

### Test 8.8.2: Fleet Endpoint Responds Within Acceptable Latency
**Action:** From the primary machine, run 3 times:
```
for i in 1 2 3; do time curl -s https://<secondary-funnel-hostname>/api/fleet > /dev/null; done
```
**Expected Result:** All 3 requests complete within 5 seconds. The fleet endpoint aggregates
machine data and is expected to be slower than the health endpoint; up to 5 seconds is
acceptable.
**Pass/Fail:** [ ]

### Test 8.8.3: Dashboard UI Loads Within Acceptable Time
**Action:** On the primary machine, open the browser developer tools (Network tab), clear the
cache, and load the Fleet Monitor dashboard URL. Record the total page load time displayed in
the Network tab.
**Expected Result:** Initial page load completes within 10 seconds including all assets. The
dashboard is interactive (not just a loading spinner) within 5 seconds.
**Pass/Fail:** [ ]

### Test 8.8.4: Tailscale Direct Connection Preferred Over DERP Relay
**Action:** On the primary machine, run:
```
tailscale ping <secondary-tailscale-hostname>
```
**Expected Result:** Output indicates "direct connection" rather than routing through a DERP relay.
(DERP relay is acceptable for cross-network setups where direct P2P is not possible, but direct
connection is expected for same-network machines.)
**Pass/Fail:** [ ]

---

### Section 8.9: Fallback When Tailscale is Unavailable

### Test 8.9.1: Fleet Monitor Continues Operating Locally Without Tailscale
**Action:** On the secondary machine, disconnect Tailscale:
```
sudo tailscale down
```
Verify Fleet Monitor still responds on localhost:
```
curl -s http://localhost:3000/api/health | jq .status
```
**Expected Result:** Fleet Monitor responds with `"operational"` on localhost. The service does
not crash or enter an error state when Tailscale is disconnected. Reconnect afterward:
`sudo tailscale up`.
**Pass/Fail:** [ ]

### Test 8.9.2: Local Dashboard Access Works Without Tailscale
**Action:** On the secondary machine (with Tailscale disconnected), open:
```
http://localhost:3000
```
**Expected Result:** Fleet Monitor dashboard loads normally via the local HTTP URL. All local
machines and sessions are displayed. The UI shows no errors related to Tailscale connectivity.
**Pass/Fail:** [ ]

### Test 8.9.3: Funnel Restore Script Reports Error When Tailscale is Down
**Action:** On the secondary machine (with Tailscale disconnected), run:
```
bash ~/aiteamforge/scripts/tailscale-funnel-restore.sh; echo "Exit code: $?"
```
**Expected Result:** Script prints "ERROR: Tailscale is not running or not connected" and exits
with non-zero code (e.g., `Exit code: 1`). The script does not hang. Reconnect:
`sudo tailscale up`.
**Pass/Fail:** [ ]

### Test 8.9.4: Primary Machine Receives Clear Error When Funnel is Down
**Action:** On the secondary machine, with Tailscale disconnected, attempt access from the
primary machine with a timeout:
```
curl -v --max-time 10 https://<secondary-funnel-hostname>/api/health 2>&1 | tail -5
```
**Expected Result:** curl returns a connection error (e.g., `Could not resolve host` or
`Connection refused`) within the 10-second timeout. The error is a network-level failure, not
an HTTP 5xx from the server. The primary machine does not hang indefinitely.
**Pass/Fail:** [ ]

### Test 8.9.5: aiteamforge doctor Reports Tailscale Status Accurately
**Action:** On the secondary machine, with Tailscale disconnected, run:
```
aiteamforge doctor 2>&1 | grep -i tailscale
```
**Expected Result:** The doctor output includes a Tailscale health check entry that reports
Tailscale as disconnected or unavailable (a warning or failure verdict, not a false "OK").
Reconnect: `sudo tailscale up`.
**Pass/Fail:** [ ]

---

### Section 8.10: Security — Unauthorized Access Prevention

### Test 8.10.1: Tailscale Funnel Enforces HTTPS
**Action:** From outside the tailnet (or simulate by using curl against the public hostname with
`http://` instead of `https://`), run:
```
curl -v --max-time 10 http://<secondary-funnel-public-hostname>/ 2>&1 | head -20
```
**Expected Result:** The connection is either refused or redirected to HTTPS. A plain-HTTP 200
response is a failure — Tailscale Funnel must enforce HTTPS for internet-accessible endpoints.
**Pass/Fail:** [ ]

### Test 8.10.2: Fleet Monitor API Does Not Expose Credentials or Secrets
**Action:** From the primary machine, retrieve the full fleet and teams responses and review all
field names:
```
curl -s https://<secondary-funnel-hostname>/api/fleet | jq 'keys'
curl -s https://<secondary-funnel-hostname>/api/registered-teams | jq '.teams[0] | keys'
```
**Expected Result:** API responses contain only operational metadata (hostnames, session counts,
team names, statuses, timestamps, port numbers). No API keys, tokens, passwords, private keys,
or file system paths outside of `~/aiteamforge/` appear in any response field.
**Pass/Fail:** [ ]

### Test 8.10.3: Machines Outside the Tailnet Cannot Access Fleet Monitor Directly
**Action:** From a machine NOT enrolled in the tailnet (or from a mobile device on a separate
network with no Tailscale), attempt a direct connection to the Tailscale IP:
```
curl --max-time 10 http://<secondary-tailscale-ip>:3000/api/health
```
**Expected Result:** Connection times out or is refused. The Fleet Monitor port is accessible
only to Tailscale-authenticated peers or via the HTTPS Funnel URL. Non-tailnet machines cannot
reach port 3000 directly.
**Pass/Fail:** [ ]

### Test 8.10.4: Invalid Machine ID Returns 404 Not Found
**Action:** From the primary machine, request history for a fabricated machine ID:
```
curl -s -o /dev/null -w "%{http_code}" \
  "https://<secondary-funnel-hostname>/api/machine/00000000-0000-0000-0000-000000000000/history"
```
**Expected Result:** HTTP response code is 404. The server returns a JSON error body. The server
does not crash or return 500. Subsequent health checks return 200.
**Pass/Fail:** [ ]

### Test 8.10.5: Oversized Status Payload Does Not Crash the Server
**Action:** From the primary machine, POST a status update with an excessively long hostname:
```
curl -s -X POST https://<secondary-funnel-hostname>/api/status \
  -H "Content-Type: application/json" \
  -d '{
    "machine": {
      "hostname": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
      "machine_id": "00000000-0000-0000-0000-000000000002",
      "ip": "100.0.0.2",
      "os": "macOS"
    },
    "sessions": []
  }' | jq '{success: .success}'
```
Then confirm the server is still healthy:
```
curl -s https://<secondary-funnel-hostname>/api/health | jq .status
```
**Expected Result:** Server accepts the request (200) or rejects it (400). In either case the
server does not return 500, does not crash, and the health endpoint continues returning
`"operational"` after the oversized request.
**Pass/Fail:** [ ]

---

### Phase 8 Summary

Record the results for this phase before proceeding to Phase 9.

| Section | Tests | Passed | Failed |
|---------|-------|--------|--------|
| 8.1 Tailscale Installation and Authentication | 6 | | |
| 8.2 Tailscale Funnel Setup | 5 | | |
| 8.3 HTTPS Certificate Verification | 3 | | |
| 8.4 Remote Fleet Monitor Dashboard Access | 5 | | |
| 8.5 API Access from Primary Machine | 4 | | |
| 8.6 Remote Kanban Board Viewing | 3 | | |
| 8.7 Remote Team Status Monitoring | 3 | | |
| 8.8 Latency and Responsiveness | 4 | | |
| 8.9 Fallback When Tailscale Unavailable | 5 | | |
| 8.10 Security — Unauthorized Access Prevention | 5 | | |
| **Total** | **43** | | |

**Phase 8 Pass/Fail Criteria:**
- Sections 8.1, 8.2, 8.3, 8.4, and 8.10 are required — all must pass for remote access to be
  considered functional and secure
- Sections 8.5, 8.6, and 8.7 must pass to confirm full API and kanban visibility
- Section 8.8 (latency) is informational; results above thresholds on cross-network setups
  should be documented but do not block phase completion
- Section 8.9 failures are blocking — local-only fallback must work correctly
- Phase 8 is PASS when all required sections pass
- Phase 8 is FAIL if any security test (8.10.x) or connectivity test (8.1.x through 8.4.x) fails

**Phase 8 Result:** [ ] PASS   [ ] FAIL

**Notes (record Tailscale hostnames, Funnel URL, latency measurements, any connectivity issues):**

```
Secondary machine Tailscale hostname:
Secondary machine Tailscale IP:
Funnel public URL:
Tailscale connection type (direct/DERP):
Health endpoint latency (5 runs):  1.___s  2.___s  3.___s  4.___s  5.___s
Fleet endpoint latency (3 runs):   1.___s  2.___s  3.___s
Dashboard load time:
Certificate issuer:
Certificate expiry (notAfter):
Issues encountered:
```

---

*Proceed to Phase 9: Claude Code Integration*

---

---

## Phase 9: Multi-Machine Coordination Validation

**Prerequisites:**
- Phase 1 through Phase 8 completed successfully on the primary machine (Machine A)
- A second machine (Machine B) with AITeamForge installed and configured
- Both machines connected via Tailscale (or same local network)
- Fleet Monitor running on Machine A in server mode
- Machine B configured as a client pointing to Machine A's Fleet Monitor
- Both machines registered as the same team (e.g., `academy`) or different teams
- At least one kanban board with items present on Machine A

**Setup verification before starting Phase 9:**
```bash
# On Machine A — confirm Fleet Monitor is running and healthy
curl -s http://localhost:3000/api/health | jq .

# On Machine B — confirm connectivity to Machine A Fleet Monitor
# Replace MACHINE_A_IP with Machine A's Tailscale IP or hostname
curl -s http://MACHINE_A_IP:3000/api/health | jq .
```

Both commands must return `{"status":"operational",...}` before proceeding.

---

### 9.1 Simultaneous Active Work Across Machines

### Test 9.1.1: Verify Both Machines Appear in Fleet Dashboard
**Action:** On Machine A, open the Fleet Monitor dashboard in a browser (`http://localhost:3000`). Examine the Machines section. Also query the API directly:
```bash
curl -s http://localhost:3000/api/fleet | jq '.fleet.machines[] | {hostname, status, session_count}'
```
**Expected Result:** Both Machine A and Machine B appear in the machines list with `status: "online"`. Each machine shows its correct hostname, IP address, and session count. The `total_machines` count reflects 2.
**Pass/Fail:** [ ]

### Test 9.1.2: Start Concurrent Agent Sessions on Both Machines
**Action:** On Machine A, open a Claude Code session in an existing tmux session for a team (e.g., `academy`). On Machine B, simultaneously open a Claude Code session for a different team or another terminal of the same team. Wait 90 seconds for the next heartbeat cycle to complete, then query:
```bash
curl -s http://localhost:3000/api/fleet | jq '.fleet.divisions'
```
**Expected Result:** The fleet API response shows sessions from both machines under their respective divisions/teams. Sessions from Machine A and Machine B appear separately under the same or different team entries. `total_sessions` reflects the combined count.
**Pass/Fail:** [ ]

### Test 9.1.3: Verify Working Items Aggregation Across Machines
**Action:** On Machine A, set a kanban item to `actively-working` status using `kb-update`. On Machine B, set a different kanban item to `actively-working` on its board. Then query from Machine A:
```bash
curl -s http://localhost:3000/api/working-items | jq .
```
**Expected Result:** The response includes working items from both boards. If both machines push their board data (via `kanban-push`), both working items appear in the aggregated `working-items` response. Each entry includes the item `id`, `title`, `status`, and any active `subitem`.
**Pass/Fail:** [ ]

---

### 9.2 Kanban State Synchronization Between Machines

### Test 9.2.1: Push Board from Machine A — Verify Visible from Machine A API
**Action:** On Machine A, push the local kanban board to Fleet Monitor:
```bash
curl -s -X POST http://localhost:3000/api/kanban-push \
  -H "Content-Type: application/json" \
  -d "$(jq '. + {team:"academy"}' ~/dev-team/kanban/academy-board.json)" \
  | jq .
```
**Expected Result:** Response shows `{"success": true, "team": "academy", "pushedAt": "<timestamp>"}`. The board data is stored in `pushedBoards` in memory.
**Pass/Fail:** [ ]

### Test 9.2.2: Read Pushed Board State from Machine B
**Action:** From Machine B, query Machine A's Fleet Monitor for kanban stats for the `academy` team:
```bash
# Replace MACHINE_A_IP with actual IP or Tailscale hostname
curl -s "http://MACHINE_A_IP:3000/api/kanban-stats?team=academy" | jq '{teamId, totalItems, completionRate}'
```
**Expected Result:** Returns kanban statistics matching the board that Machine A pushed. `totalItems` reflects the actual item count on Machine A's board. The response does not return raw board data — only computed statistics.
**Pass/Fail:** [ ]

### Test 9.2.3: Push Board from Machine B — Verify Both Boards Tracked
**Action:** On Machine B, push its local kanban board (for a different team, e.g., `ios` or `firebase`) to Machine A's Fleet Monitor server:
```bash
curl -s -X POST http://MACHINE_A_IP:3000/api/kanban-push \
  -H "Content-Type: application/json" \
  -d "$(jq '. + {team:"ios"}' /path/to/ios-board.json)" \
  | jq .
```
Then on Machine A query:
```bash
curl -s http://localhost:3000/api/kanban-stats | jq '.teams | keys'
```
**Expected Result:** Both `academy` and `ios` (or whichever teams pushed) appear in the `teams` object of the kanban-stats response. Each team has independently computed statistics. The `overall` section aggregates both boards correctly.
**Pass/Fail:** [ ]

### Test 9.2.4: Verify Board Data Staleness Tracking
**Action:** On Machine A, push the academy board. Note the `pushedAt` timestamp. Wait 5 minutes without pushing again. Query kanban-stats and check the timestamp:
```bash
curl -s "http://localhost:3000/api/kanban-stats?team=academy" | jq .timestamp
```
**Expected Result:** The `timestamp` field reflects the current query time (when stats were computed), not the board push time. There is no automatic expiry of pushed board data during the test window.
**Pass/Fail:** [ ]

---

### 9.3 Conflict Resolution When Both Machines Modify the Same Board

### Test 9.3.1: Sequential Push Overwrites — Last Push Wins
**Action:** Push version 1 of a board, then version 2 of the same team board. Query kanban-stats after both pushes:
```bash
# Version 1 push — status: todo
curl -s -X POST http://localhost:3000/api/kanban-push \
  -H "Content-Type: application/json" \
  -d '{"team":"test-team","backlog":[{"id":"T-0001","title":"Original Title","status":"todo"}]}' \
  | jq .pushedAt

# Version 2 push — status: in_progress
curl -s -X POST http://MACHINE_A_IP:3000/api/kanban-push \
  -H "Content-Type: application/json" \
  -d '{"team":"test-team","backlog":[{"id":"T-0001","title":"Modified Title","status":"in_progress"}]}' \
  | jq .pushedAt

curl -s "http://localhost:3000/api/kanban-stats?team=test-team" | jq '.teams["test-team"].statusCounts'
```
**Expected Result:** The second push wins because `pushedBoards.set(teamId, ...)` in `kanban.js` unconditionally replaces the previous entry. The kanban-stats response reflects the second version: `in_progress` appears in statusCounts, not `todo`. There is no merge or conflict detection — last write wins.
**Pass/Fail:** [ ]

### Test 9.3.2: Concurrent Push Isolation Per Team ID
**Action:** Push boards for two different team IDs simultaneously. Verify neither board is corrupted:
```bash
curl -s -X POST http://localhost:3000/api/kanban-push \
  -H "Content-Type: application/json" \
  -d '{"team":"academy","backlog":[{"id":"XACA-0001","title":"Academy Item","status":"todo"}]}' &

curl -s -X POST http://localhost:3000/api/kanban-push \
  -H "Content-Type: application/json" \
  -d '{"team":"ios","backlog":[{"id":"XIOS-0001","title":"iOS Item","status":"completed"}]}' &

wait

curl -s http://localhost:3000/api/kanban-stats | jq '.teams | to_entries[] | {team: .key, total: .value.totalItems}'
```
**Expected Result:** Both `academy` and `ios` boards are stored independently. Each team's statistics reflect only their own board data. The `Map` structure in `store.js` provides isolation by key.
**Pass/Fail:** [ ]

### Test 9.3.3: Confirm No Server-Side Merge Logic
**Action:** Push a board with 3 items, then push again with only 2 items (one item deleted on one machine):
```bash
# Push board with 3 items
curl -s -X POST http://localhost:3000/api/kanban-push \
  -H "Content-Type: application/json" \
  -d '{"team":"sync-test","backlog":[{"id":"ST-001","title":"Item 1","status":"todo"},{"id":"ST-002","title":"Item 2","status":"todo"},{"id":"ST-003","title":"Item 3","status":"todo"}]}' \
  | jq .

# Push board with 2 items (ST-003 deleted)
curl -s -X POST http://localhost:3000/api/kanban-push \
  -H "Content-Type: application/json" \
  -d '{"team":"sync-test","backlog":[{"id":"ST-001","title":"Item 1","status":"todo"},{"id":"ST-002","title":"Item 2","status":"completed"}]}' \
  | jq .

curl -s "http://localhost:3000/api/kanban-stats?team=sync-test" | jq '.teams["sync-test"].totalItems'
```
**Expected Result:** After the second push, `totalItems` is 2 (not 3). The server performs no merge — it replaces the entire board snapshot. Teams must coordinate their own conflict resolution outside of Fleet Monitor.
**Pass/Fail:** [ ]

---

### 9.4 Credential Sharing Across Machines

### Test 9.4.1: Verify Credentials Are Machine-Local
**Action:** On Machine A, list credentials stored in the local keychain via Fleet Monitor:
```bash
curl -s http://localhost:3000/api/credentials | jq .
```
On Machine B, if Fleet Monitor runs locally, list its own credentials and compare results.
**Expected Result:** Machine A's credential list reflects only credentials in Machine A's macOS Keychain (via `credential_cli.py`). Machine B returns only its own local credentials. There is no credential replication or sharing built into Fleet Monitor — credentials are strictly machine-local for security.
**Pass/Fail:** [ ]

### Test 9.4.2: Store Credential on Machine A — Accessible Through Machine A's Server
**Action:** On Machine A, store a test credential, then verify it exists:
```bash
curl -s -X POST http://localhost:3000/api/credentials/test-integration \
  -H "Content-Type: application/json" \
  -d '{"type": "test", "endpoint": "https://example.com", "token": "test-token-abc123"}' \
  | jq .

curl -s "http://localhost:3000/api/credentials/test-integration/verify" | jq .
```
**Expected Result:** The store operation returns `{"success": true}`. The verify request returns `{"integration_id": "test-integration", "exists": true}`. The credential CLI runs on Machine A's OS and accesses Machine A's local keychain only. Machine B's own local Fleet Monitor would NOT have this credential.
**Pass/Fail:** [ ]

### Test 9.4.3: Verify Credential Values Are Never Exposed Over Network
**Action:** After storing the credential in Test 9.4.2, call the info endpoint:
```bash
curl -s "http://localhost:3000/api/credentials/test-integration/info" | jq .
```
**Expected Result:** The response contains metadata only: `integration_id`, `type`, field presence flags, and timestamps. No actual token values, passwords, or secrets appear in the response. The literal string `test-token-abc123` from the store request does not appear anywhere in the response body.
**Pass/Fail:** [ ]

### Test 9.4.4: Invalid Integration ID Rejected by Credential API
**Action:** Attempt to store a credential with an integration ID that exceeds the 20-character maximum:
```bash
curl -s -X POST "http://localhost:3000/api/credentials/too-long-integration-id-exceeding-twenty" \
  -H "Content-Type: application/json" \
  -d '{"type": "test", "token": "value"}' \
  | jq .
```
**Expected Result:** Returns HTTP 400 with `{"error": "Invalid integration ID format"}`. The `validateIntegrationId()` function enforces the pattern `^[A-Za-z0-9_-]{2,20}$` — 2 to 20 alphanumeric characters (plus underscore and hyphen). This validation applies uniformly regardless of which machine calls the endpoint.
**Pass/Fail:** [ ]

---

### 9.5 Real-Time Fleet Monitor Status Updates

### Test 9.5.1: Machine B Status Update Appears Immediately After Heartbeat
**Action:** From Machine B (or simulated), send a manual status heartbeat to Machine A's Fleet Monitor:
```bash
MACHINE_B_ID=$(uuidgen)
curl -s -X POST http://MACHINE_A_IP:3000/api/status \
  -H "Content-Type: application/json" \
  -d "{\"machine\":{\"machine_id\":\"$MACHINE_B_ID\",\"hostname\":\"machine-b-test\",\"ip\":\"100.64.0.99\",\"os\":\"darwin\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"},\"sessions\":[{\"session_name\":\"academy\",\"division\":\"academy\",\"team\":\"academy\",\"name\":\"academy\",\"windows\":2,\"attached\":true,\"created\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"uptime_seconds\":120,\"tab_order\":1}]}" \
  | jq .
```
**Expected Result:** Response is `{"success": true, "sessions_count": 1}`. The status is processed with activity type `CONNECT` for first contact or `STATUS` for repeat. Machine B's hostname appears in the activity log.
**Pass/Fail:** [ ]

### Test 9.5.2: Fleet API Immediately Reflects New Heartbeat
**Action:** Immediately after sending the heartbeat in Test 9.5.1, query the fleet API:
```bash
curl -s http://localhost:3000/api/fleet | jq '.fleet.machines[] | select(.hostname == "machine-b-test") | {hostname, status, session_count, last_seen}'
```
**Expected Result:** Machine B's entry appears with `status: "online"`, `session_count: 1`, and a `last_seen` timestamp matching the heartbeat just sent. `GET /api/fleet` calls `parseFleetData()` which recalculates status from current in-memory data on every request — no cache delay.
**Pass/Fail:** [ ]

### Test 9.5.3: Activity Log Reflects Multi-Machine Events
**Action:** Send heartbeats from two different machine IDs in quick succession. Then query the activity log:
```bash
MACHINE_C_ID=$(uuidgen)
curl -s -X POST http://localhost:3000/api/status \
  -H "Content-Type: application/json" \
  -d "{\"machine\":{\"machine_id\":\"$MACHINE_C_ID\",\"hostname\":\"machine-c-test\",\"ip\":\"100.64.0.98\",\"os\":\"darwin\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"},\"sessions\":[]}" \
  | jq .

curl -s http://localhost:3000/api/fleet | jq '.activityLog | .[0:5] | .[] | {type, hostname, message}'
```
**Expected Result:** The `activityLog` array (capped at 20 entries) shows recent `CONNECT` events for both `machine-b-test` and `machine-c-test`. Entries appear in reverse chronological order (newest first). Each entry contains `type`, `hostname`, `ip`, `session_count`, and `message`.
**Pass/Fail:** [ ]

---

### 9.6 Machine Health Monitoring — Offline and Online Transitions

### Test 9.6.1: Machine Transitions to Warning After 2 Minutes Without Heartbeat
**Action:** Send one heartbeat from a test machine, then stop. Wait 130 seconds (just past WARNING_THRESHOLD_MS of 120 seconds). Query the fleet:
```bash
TEST_MACHINE_ID=$(uuidgen)
curl -s -X POST http://localhost:3000/api/status \
  -H "Content-Type: application/json" \
  -d "{\"machine\":{\"machine_id\":\"$TEST_MACHINE_ID\",\"hostname\":\"health-test-machine\",\"ip\":\"10.0.0.1\",\"os\":\"darwin\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"},\"sessions\":[]}" \
  | jq .success

echo "Waiting 130 seconds for warning threshold..."
sleep 130

curl -s http://localhost:3000/api/fleet | jq '.fleet.machines[] | select(.hostname == "health-test-machine") | {hostname, status, last_seen}'
```
**Expected Result:** After 130 seconds without a heartbeat, the machine's `status` field shows `"warning"`. The `updateMachineStatuses()` function in `fleet.js` checks `timeSinceLastSeen > WARNING_THRESHOLD_MS (120000ms)`. A history entry is logged for the status transition.
**Pass/Fail:** [ ]

### Test 9.6.2: Machine Transitions to Offline After 3 Minutes Without Heartbeat
**Action:** Continuing from Test 9.6.1, wait an additional 60 seconds (total approximately 190 seconds, past OFFLINE_THRESHOLD_MS of 180 seconds):
```bash
sleep 60

curl -s http://localhost:3000/api/fleet | jq '.fleet.machines[] | select(.hostname == "health-test-machine") | {hostname, status}'
```
**Expected Result:** The machine's status shows `"offline"`. `updateMachineStatuses()` detects `timeSinceLastSeen > OFFLINE_THRESHOLD_MS (180000ms)`. The machine no longer contributes to `fleet.online_machines` and is counted in `fleet.offline_machines`. A history entry is logged for the transition.
**Pass/Fail:** [ ]

### Test 9.6.3: Machine Transitions Back to Online After Reconnecting
**Action:** After the machine in Tests 9.6.1 and 9.6.2 is offline, send a new heartbeat:
```bash
curl -s -X POST http://localhost:3000/api/status \
  -H "Content-Type: application/json" \
  -d "{\"machine\":{\"machine_id\":\"$TEST_MACHINE_ID\",\"hostname\":\"health-test-machine\",\"ip\":\"10.0.0.1\",\"os\":\"darwin\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"},\"sessions\":[]}" \
  | jq .

curl -s http://localhost:3000/api/fleet | jq '.fleet.machines[] | select(.hostname == "health-test-machine") | {hostname, status}'
```
**Expected Result:** The fleet query shows `status: "online"`. The `detectChanges()` function in `history.js` detects the previous `offline` status and logs a `status_change` history entry. The activity type is `RECONNECT`. The `details` field includes downtime duration (e.g., "Status changed from offline to online (back after 3m)").
**Pass/Fail:** [ ]

### Test 9.6.4: Machine History Records All Status Transitions
**Action:** Retrieve the state change history for the test machine used in Tests 9.6.1 through 9.6.3:
```bash
curl -s "http://localhost:3000/api/machine/$TEST_MACHINE_ID/history" | jq '.entries[] | {event_type, previous_value, new_value, details}'
```
**Expected Result:** The history includes entries for: `first_seen` (initial connection), `status_change` (online to warning), `status_change` (warning to offline), and `status_change` (offline back to online). Each entry has a `timestamp`, `id` (UUID), `event_type`, `previous_value`, `new_value`, and `details` string with downtime duration. History is newest-first.
**Pass/Fail:** [ ]

### Test 9.6.5: Uptime History Sparkline Data Maintained
**Action:** Send 5 heartbeats to Fleet Monitor with short gaps, then check uptime_history length:
```bash
for i in 1 2 3 4 5; do
  curl -s -X POST http://localhost:3000/api/status \
    -H "Content-Type: application/json" \
    -d "{\"machine\":{\"machine_id\":\"$TEST_MACHINE_ID\",\"hostname\":\"health-test-machine\",\"ip\":\"10.0.0.1\",\"os\":\"darwin\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"},\"sessions\":[]}" \
    > /dev/null
  echo "Heartbeat $i sent"
  [ $i -lt 5 ] && sleep 5
done

curl -s http://localhost:3000/api/fleet | jq '.fleet.machines[] | select(.hostname == "health-test-machine") | .uptime_history | length'
```
**Expected Result:** The `uptime_history` array contains entries from all heartbeats sent including prior tests. Each entry has `timestamp`, `status`, and `session_count`. The array is capped at 48 entries (older entries shift out). This data powers the sparkline visualization in the Fleet Monitor dashboard.
**Pass/Fail:** [ ]

---

### 9.7 Dashboard Aggregation Across Multiple Machines

### Test 9.7.1: Overall Fleet Summary Aggregates All Machines
**Action:** With at least Machine A and Machine B (plus simulated test machines from prior tests) reporting to Fleet Monitor, query the fleet summary:
```bash
curl -s http://localhost:3000/api/fleet | jq '{
  total_machines: .fleet.total_machines,
  online_machines: .fleet.online_machines,
  offline_machines: .fleet.offline_machines,
  total_sessions: .fleet.total_sessions,
  division_count: (.fleet.divisions | length)
}'
```
**Expected Result:** `total_machines` equals the sum of `online_machines` and `offline_machines`. `total_sessions` counts only sessions from online machines — offline machine sessions are excluded from the divisions/sessions aggregation per `parseFleetData()` logic. `division_count` reflects the number of distinct divisions across all reporting machines.
**Pass/Fail:** [ ]

### Test 9.7.2: Machine Nicknames Display Correctly in Dashboard
**Action:** Set a nickname for a test machine and verify it appears in fleet data:
```bash
MACHINE_B_ID_FROM_FLEET=$(curl -s http://localhost:3000/api/fleet | jq -r '.fleet.machines[] | select(.hostname == "machine-b-test") | .machine_id')

curl -s -X PUT "http://localhost:3000/api/machine/$MACHINE_B_ID_FROM_FLEET/nickname" \
  -H "Content-Type: application/json" \
  -d '{"nickname": "Home Lab MacBook"}' \
  | jq .

curl -s http://localhost:3000/api/fleet | jq ".fleet.machines[] | select(.machine_id == \"$MACHINE_B_ID_FROM_FLEET\") | {hostname, nickname}"
```
**Expected Result:** The PUT response shows `{"success": true, "machine_id": "...", "nickname": "Home Lab MacBook"}`. The fleet query returns `nickname: "Home Lab MacBook"` for the machine. Setting nickname to an empty string clears it to `null`.
**Pass/Fail:** [ ]

### Test 9.7.3: Kanban Stats Aggregate All Pushed Boards
**Action:** With boards pushed from both Machine A (academy) and Machine B (ios or another team), query the overall kanban statistics:
```bash
curl -s http://localhost:3000/api/kanban-stats | jq '{
  total_teams: .overall.totalTeams,
  valid_teams: .overall.validTeams,
  total_items: .overall.totalItems,
  overall_completion_rate: .overall.overallCompletionRate,
  status_counts: .overall.statusCounts
}'
```
**Expected Result:** `total_teams` reflects all teams tracked. `total_items` is the sum of all items across all valid boards. `overall_completion_rate` is the weighted average. `status_counts` sums counts across all boards. The `timestamp` reflects when the query was computed, not when boards were pushed.
**Pass/Fail:** [ ]

### Test 9.7.4: Epics Aggregated Across All Team Boards
**Action:** Push a board with at least one epic defined for team `academy`. Then query all epics:
```bash
curl -s http://localhost:3000/api/epics | jq 'keys'
curl -s http://localhost:3000/api/epics/academy | jq '.epics[] | {id, progress: .progress.percentComplete}'
```
**Expected Result:** The `GET /api/epics` response returns a map of team IDs to epic arrays. Teams with no epics are omitted. The `GET /api/epics/academy` response shows epics with computed progress including `totalItems`, `completedItems`, `cancelledItems`, `resolvedItems`, and `percentComplete` calculated from backlog items assigned via `itemIds`.
**Pass/Fail:** [ ]

### Test 9.7.5: Knowledge Stats Aggregate Across Both Machines' Pushed Data
**Action:** Push knowledge stats from Machine A and Machine B to Fleet Monitor, then query the aggregated result:
```bash
# Machine A pushes academy knowledge stats
curl -s -X POST http://localhost:3000/api/knowledge-push \
  -H "Content-Type: application/json" \
  -d '{"team":"academy","knowledge":{"totalEntries":42,"contributingAgents":5,"categories":{"testing":12,"architecture":8,"bugs":7,"patterns":15},"tags":{"swift":10,"firebase":8,"kanban":12},"recentEntries":[{"title":"Test Pattern A","date":"2026-03-30","agent":"thok"}]}}' \
  | jq .

# Machine B pushes ios knowledge stats
curl -s -X POST http://MACHINE_A_IP:3000/api/knowledge-push \
  -H "Content-Type: application/json" \
  -d '{"team":"ios","knowledge":{"totalEntries":18,"contributingAgents":3,"categories":{"testing":5,"architecture":7,"bugs":6},"tags":{"swift":15,"xctest":8},"recentEntries":[{"title":"iOS Pattern B","date":"2026-03-29","agent":"picard"}]}}' \
  | jq .

# Query aggregated stats
curl -s http://localhost:3000/api/knowledge-stats | jq '{
  total_entries: .overall.totalEntries,
  teams_with_entries: .overall.teamsWithEntries,
  total_contributing_agents: .overall.totalContributingAgents,
  unique_categories: .overall.uniqueCategories,
  top_tag: .overall.topTags[0]
}'
```
**Expected Result:** `total_entries` is 60 (42 + 18). `teams_with_entries` is 2. `total_contributing_agents` is 8 (5 + 3). The `categories` object sums: `testing: 17`, `architecture: 15`, `bugs: 13`, `patterns: 15`. `top_tag` is swift with count 25. `recentEntries` shows entries from both teams sorted by date, capped at 10.
**Pass/Fail:** [ ]

---

### 9.8 Knowledge Base Sync Across Machines

### Test 9.8.1: Knowledge Push Timestamp Tracking Per Team
**Action:** Push knowledge stats for the same team twice (simulating competing pushes). Verify only the most recent push is stored:
```bash
# First push (10 entries)
curl -s -X POST http://localhost:3000/api/knowledge-push \
  -H "Content-Type: application/json" \
  -d '{"team":"kb-test","knowledge":{"totalEntries":10,"contributingAgents":1}}' \
  | jq .pushedAt

# Second push (25 entries)
curl -s -X POST http://localhost:3000/api/knowledge-push \
  -H "Content-Type: application/json" \
  -d '{"team":"kb-test","knowledge":{"totalEntries":25,"contributingAgents":3}}' \
  | jq .pushedAt

# Confirm latest data is used
curl -s http://localhost:3000/api/knowledge-stats | jq '.teams["kb-test"] | {totalEntries, contributingAgents, pushedAt}'
```
**Expected Result:** The `pushedKnowledge` map uses team ID as key, so the second push overwrites the first. The response shows `totalEntries: 25` and `contributingAgents: 3`. The `pushedAt` timestamp matches the second push time. Knowledge sync is last-write-wins at the team level.
**Pass/Fail:** [ ]

### Test 9.8.2: Knowledge Persistence After Server Restart
**Action:** Push knowledge stats to Fleet Monitor, then stop and restart the Fleet Monitor server. Query knowledge stats again after restart:
```bash
# Push knowledge stats
curl -s -X POST http://localhost:3000/api/knowledge-push \
  -H "Content-Type: application/json" \
  -d '{"team":"persist-test","knowledge":{"totalEntries":7,"contributingAgents":2}}' \
  | jq .

# Restart Fleet Monitor
aiteamforge restart fleet-monitor
sleep 5

# Verify data persists
curl -s http://localhost:3000/api/knowledge-stats | jq '.teams["persist-test"] | {totalEntries, pushedAt}'
```
**Expected Result:** After restart, knowledge stats for `persist-test` are still available with `totalEntries: 7` if the server called `savePushedKnowledge()` before stopping. The server loads from `pushed-knowledge.json` on startup via `loadPushedKnowledge()`. If the server does NOT auto-save pushed knowledge before restart, the data will be absent — record the actual behavior observed.
**Pass/Fail:** [ ]

---

### 9.9 Team Assignment Across Machines

### Test 9.9.1: Same Team Registered from Multiple Machines
**Action:** Register the `academy` team from Machine A with 2 terminals, then re-register the same team from Machine B with 3 terminals and a different `kanbanDir`. Query team config after both registrations:
```bash
# Machine A registers academy team
curl -s -X POST http://localhost:3000/api/team-register \
  -H "Content-Type: application/json" \
  -d '{"team":"academy","teamName":"Academy Team","organization":"MainEvent","orgColor":"blue","kanbanDir":"/Users/darrenehlers/dev-team/kanban","fleetMonitorUrl":"http://localhost:3000","terminals":{"thok":{"persona":"Lura Thok","role":"Testing","color":"cyan"},"emh":{"persona":"The Doctor","role":"Documentation","color":"green"}}}' \
  | jq .

# Machine B re-registers same team with additional terminal
curl -s -X POST http://MACHINE_A_IP:3000/api/team-register \
  -H "Content-Type: application/json" \
  -d '{"team":"academy","teamName":"Academy Team","organization":"MainEvent","orgColor":"blue","kanbanDir":"/Users/seconduser/dev-team/kanban","fleetMonitorUrl":"http://MACHINE_B_IP:3000","terminals":{"thok":{"persona":"Lura Thok","role":"Testing","color":"cyan"},"emh":{"persona":"The Doctor","role":"Documentation","color":"green"},"nahla":{"persona":"Nahla","role":"Leadership","color":"gold"}}}' \
  | jq .

# Query team config
curl -s "http://localhost:3000/api/team-config?team=academy" | jq '{team, kanbanDir, fleetMonitorUrl, terminal_count: (.terminals | length)}'
```
**Expected Result:** Machine A's registration returns HTTP 201 ("registered"). Machine B's returns HTTP 200 ("updated"). The final team config reflects Machine B's registration: `kanbanDir` from Machine B, 3 terminals including `nahla`. The `registeredAt` timestamp is preserved from Machine A's initial registration; `lastSeen` is updated to Machine B's timestamp.
**Pass/Fail:** [ ]

### Test 9.9.2: Terminal-to-Persona Mapping Accessible After Cross-Machine Registration
**Action:** Query the terminal configuration for the academy team after Test 9.9.1:
```bash
curl -s http://localhost:3000/api/team-config/academy/terminals | jq .
```
**Expected Result:** Response includes `team: "academy"` and `terminals` object with all 3 terminals: `thok`, `emh`, and `nahla`. Each terminal entry includes `persona`, `role`, and `color`. The configuration reflects the most recently registered version (Machine B's 3-terminal config).
**Pass/Fail:** [ ]

### Test 9.9.3: Registered Teams List Groups by Organization
**Action:** With multiple teams registered, query the full team registry and organization grouping:
```bash
curl -s http://localhost:3000/api/registered-teams | jq '{
  total: .total,
  teams: [.teams[] | {team, organization, terminal_count: (.terminals | length)}]
}'

curl -s http://localhost:3000/api/team-config | jq '.organizations'
```
**Expected Result:** The registered-teams response shows all registered teams sorted alphabetically with their organization and terminal count. The team-config `organizations` map groups teams by organization key. All MainEvent teams appear under the `MainEvent` organization. `orgColor` values are correctly associated per team.
**Pass/Fail:** [ ]

---

### 9.10 Concurrent Agent Operations Across Machines

### Test 9.10.1: Both Machines Send Simultaneous Status Heartbeats
**Action:** Send heartbeats from two different machine IDs simultaneously using background processes:
```bash
MACHINE_A_SIM=$(uuidgen)
MACHINE_B_SIM=$(uuidgen)

curl -s -X POST http://localhost:3000/api/status \
  -H "Content-Type: application/json" \
  -d "{\"machine\":{\"machine_id\":\"$MACHINE_A_SIM\",\"hostname\":\"concurrent-machine-a\",\"ip\":\"100.64.0.1\",\"os\":\"darwin\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"},\"sessions\":[{\"session_name\":\"academy\",\"division\":\"academy\",\"team\":\"academy\",\"name\":\"academy\",\"windows\":3,\"attached\":true,\"created\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"uptime_seconds\":600,\"tab_order\":1}]}" &

curl -s -X POST http://localhost:3000/api/status \
  -H "Content-Type: application/json" \
  -d "{\"machine\":{\"machine_id\":\"$MACHINE_B_SIM\",\"hostname\":\"concurrent-machine-b\",\"ip\":\"100.64.0.2\",\"os\":\"darwin\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"},\"sessions\":[{\"session_name\":\"ios\",\"division\":\"mainevent\",\"team\":\"ios\",\"name\":\"ios-picard\",\"windows\":2,\"attached\":true,\"created\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"uptime_seconds\":300,\"tab_order\":1}]}" &

wait

curl -s http://localhost:3000/api/fleet | jq '{online: .fleet.online_machines, sessions: .fleet.total_sessions}'
```
**Expected Result:** Both heartbeats are processed without error. The Fleet Monitor Node.js server handles concurrent Express requests correctly via the single-threaded event loop (no data races on the shared `machines` Map). The fleet response shows both machines online with their sessions contributing to `total_sessions`.
**Pass/Fail:** [ ]

### Test 9.10.2: Concurrent Kanban Pushes for Different Teams — No Data Corruption
**Action:** Simultaneously push board data for two different team IDs, then verify both boards are intact:
```bash
curl -s -X POST http://localhost:3000/api/kanban-push \
  -H "Content-Type: application/json" \
  -d '{"team":"concurrent-a","backlog":[{"id":"CA-001","title":"Machine A Item","status":"todo"}]}' &

curl -s -X POST http://localhost:3000/api/kanban-push \
  -H "Content-Type: application/json" \
  -d '{"team":"concurrent-b","backlog":[{"id":"CB-001","title":"Machine B Item","status":"completed"}]}' &

wait

curl -s http://localhost:3000/api/kanban-stats | jq '.teams | {
  concurrent_a_total: .["concurrent-a"].totalItems,
  concurrent_b_total: .["concurrent-b"].totalItems,
  concurrent_b_completion: .["concurrent-b"].completionRate
}'
```
**Expected Result:** `concurrent_a_total` is 1, `concurrent_b_total` is 1, `concurrent_b_completion` is 100.0 (one completed item). Neither board's data is corrupted by the concurrent push. The Node.js single-threaded event loop prevents data races on the shared `pushedBoards` Map.
**Pass/Fail:** [ ]

### Test 9.10.3: History Log Correctly Segregated by Machine
**Action:** Retrieve history for both simulated machines and verify they have separate, non-overlapping logs:
```bash
curl -s "http://localhost:3000/api/machine/$MACHINE_A_SIM/history" | jq '{machine: .machine_id, total_entries: .total, first_event: (.entries | last | .event_type)}'

curl -s "http://localhost:3000/api/machine/$MACHINE_B_SIM/history" | jq '{machine: .machine_id, total_entries: .total, first_event: (.entries | last | .event_type)}'
```
**Expected Result:** Each machine has its own history file at `data/history/<machine_id>.json`. Machine A's history contains only events for Machine A's ID. Machine B's history contains only Machine B's events. The `first_event` for each machine is `first_seen`. Entries are correctly segregated by machine ID with no cross-contamination.
**Pass/Fail:** [ ]

### Test 9.10.4: Backup Status Aggregated from Multiple Reporting Machines
**Action:** Send heartbeats from two machine IDs including `backup_status` data. Then query the aggregated backup status:
```bash
# Machine A heartbeat with backup data
curl -s -X POST http://localhost:3000/api/status \
  -H "Content-Type: application/json" \
  -d "{\"machine\":{\"machine_id\":\"$MACHINE_A_SIM\",\"hostname\":\"concurrent-machine-a\",\"ip\":\"100.64.0.1\",\"os\":\"darwin\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"},\"sessions\":[],\"backup_status\":{\"lastRun\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"lastRunStatus\":\"success\",\"totalBackups\":45,\"boards\":{\"academy\":{\"lastCheck\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"ok\"},\"ios\":{\"lastCheck\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"ok\"}}}}" \
  | jq .success

# Machine B heartbeat with its own backup data
curl -s -X POST http://localhost:3000/api/status \
  -H "Content-Type: application/json" \
  -d "{\"machine\":{\"machine_id\":\"$MACHINE_B_SIM\",\"hostname\":\"concurrent-machine-b\",\"ip\":\"100.64.0.2\",\"os\":\"darwin\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"},\"sessions\":[],\"backup_status\":{\"lastRun\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"lastRunStatus\":\"success\",\"totalBackups\":23,\"boards\":{\"firebase\":{\"lastCheck\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"ok\"}}}}" \
  | jq .success

# Query aggregated backup status
curl -s http://localhost:3000/api/backup-status | jq '{
  status,
  lastRunAgo,
  totalBackups,
  board_count: (.boards | length),
  sources: [.sources[] | .hostname]
}'
```
**Expected Result:** `status` is `"configured"`. `totalBackups` is 68 (45 + 23). `board_count` is 3 (academy, ios, firebase — merged with most-recent-check wins for duplicates). `sources` lists both `concurrent-machine-a` and `concurrent-machine-b`. `lastRun` reflects the most recent backup run across both machines. `lastRunAgo` shows elapsed time since that run.
**Pass/Fail:** [ ]

---

### Phase 9 Summary

Record the results for this phase before proceeding.

| Section | Tests | Passed | Failed |
|---------|-------|--------|--------|
| 9.1 Simultaneous Work | 3 | | |
| 9.2 Kanban State Sync | 4 | | |
| 9.3 Conflict Resolution | 3 | | |
| 9.4 Credential Sharing | 4 | | |
| 9.5 Real-Time Status Updates | 3 | | |
| 9.6 Machine Health Monitoring | 5 | | |
| 9.7 Dashboard Aggregation | 5 | | |
| 9.8 Knowledge Base Sync | 2 | | |
| 9.9 Team Assignment | 3 | | |
| 9.10 Concurrent Operations | 4 | | |
| **Total** | **36** | | |

**Phase 9 Pass/Fail Criteria:**
- All tests in sections 9.1, 9.2, 9.4, 9.5, 9.6, 9.7, 9.9, and 9.10 must pass
- Section 9.3 documents expected server behavior (last-write-wins) — results should match the described behavior
- Section 9.8.2 may reveal a known limitation (pushed data not persisted if auto-save is absent) — record actual behavior observed
- Phase 9 is PASS when all required tests pass and multi-machine coordination behaves as documented
- Phase 9 is FAIL if fleet aggregation, status transitions, history segregation, or concurrent operations produce incorrect results

**Phase 9 Result:** [ ] PASS   [ ] FAIL

**Notes (record machine IDs, Tailscale IPs, any unexpected behaviors observed):**

```
Machine A hostname:
Machine A Tailscale IP:
Machine A machine_id (first 8 chars):
Machine B hostname:
Machine B Tailscale IP:
Machine B machine_id (first 8 chars):
Warning threshold confirmed at (seconds):
Offline threshold confirmed at (seconds):
Knowledge persistence after restart: [ ] Persisted [ ] Lost (no auto-save)
Concurrent push conflicts observed: [ ] Yes (describe) [ ] No
```

---

*Proceed to Phase 10 (if applicable) or Phase 11: Post-Testing Retrospective*

---

## Phase 7: Fleet Monitor Setup and Integration Testing

**Purpose:** Validate that the Fleet Monitor server installs correctly, starts and serves its
dashboard, accepts machine heartbeats, handles kanban board sync, and provides accurate data
through all API endpoints and LCARS dashboard views.

**Dependencies:** Phase 5 (installation orchestration) must have completed successfully before
running Phase 7. Node.js must be installed and the Fleet Monitor source files must be present
at `~/aiteamforge/fleet-monitor/`.

**When to run Phase 7:**
- After a fresh AITeamForge installation to confirm Fleet Monitor is operational
- After updating AITeamForge to validate Fleet Monitor changes have not regressed
- When troubleshooting cross-machine visibility or kanban sync issues

---

### 7.1 Fleet Monitor Installation Verification

These tests confirm that the installer placed the correct files and that all Node.js
dependencies are present before attempting to start the server.

---

### Test 7.1: Fleet Monitor Directory and Entry Point Exist
**Action:** Run:
```
ls ~/aiteamforge/fleet-monitor/server/server.js
```
**Expected Result:** The file path is printed without error. The server entry point exists at the expected location.
**Pass/Fail:** [ ]

---

### Test 7.2: Node Dependencies Installed
**Action:** Run:
```
ls ~/aiteamforge/fleet-monitor/server/node_modules | head -5
```
**Expected Result:** At least five directory names are printed (e.g., `express`, `cors`, etc.). The `node_modules` directory is populated, confirming `npm install --production` ran during setup.
**Pass/Fail:** [ ]

---

### Test 7.3: Fleet Config File Created
**Action:** Run:
```
cat ~/aiteamforge/config/fleet-config.json
```
**Expected Result:** Valid JSON is printed. The object contains at minimum the fields `mode`, `serverUrl`, `machineId`, and `hostname`. The `mode` field is one of `standalone`, `server`, or `client`.
**Pass/Fail:** [ ]

---

### Test 7.4: Machine Identity File Created
**Action:** Run:
```
cat ~/aiteamforge/config/machine-identity.json
```
**Expected Result:** Valid JSON is printed. The object contains `machineId` (a UUID-format string, 36 characters with hyphens), `hostname`, `role`, and `capabilities`. The `machineId` value is 36 characters in length.
**Pass/Fail:** [ ]

---

### Test 7.5: Machine ID Is a Valid UUID
**Action:** Run:
```
cat ~/aiteamforge/config/machine-identity.json | python3 -c "import json,sys; d=json.load(sys.stdin); mid=d['machineId']; print('VALID' if len(mid)==36 and mid.count('-')==4 else 'INVALID'); print(mid)"
```
**Expected Result:** First line of output is `VALID`. Second line shows the UUID value (e.g., `3f2a1b4c-...`). The Fleet Monitor server rejects machines with IDs shorter than 36 characters as legacy entries and removes them at startup.
**Pass/Fail:** [ ]

---

### 7.2 Server Mode Configuration

These tests verify that the mode field in the configuration matches the installation choice and
that the server URL points to the correct host.

---

### Test 7.6: Mode and Server URL Are Consistent
**Action:** Run:
```
python3 -c "
import json, os
c = json.load(open(os.path.expanduser('~/aiteamforge/config/fleet-config.json')))
print('mode:', c.get('mode'))
print('serverUrl:', c.get('serverUrl'))
"
```
**Expected Result:** `mode` is `standalone`, `server`, or `client`. For `standalone` or `server` mode, `serverUrl` is `http://localhost:3000` (or the configured port). For `client` mode, `serverUrl` points to the remote server host rather than localhost.
**Pass/Fail:** [ ]

---

### Test 7.7: Data Directory Exists and Is Writable
**Action:** Run:
```
ls ~/aiteamforge/fleet-monitor/server/data/ 2>/dev/null && echo "EXISTS" || echo "MISSING"
touch ~/aiteamforge/fleet-monitor/server/data/.write-test 2>/dev/null && echo "WRITABLE" && rm ~/aiteamforge/fleet-monitor/server/data/.write-test || echo "NOT WRITABLE"
```
**Expected Result:** First line is `EXISTS`. Second line is `WRITABLE`. The `data/` directory must exist and be writable; the server writes `machines.json`, `registered-teams.json`, `pushed-boards.json`, and `pushed-knowledge.json` to this directory.
**Pass/Fail:** [ ]

---

### 7.3 Server Startup

---

### Test 7.8: Fleet Monitor Server Starts Successfully
**Action:** In a dedicated terminal, start the server:
```
cd ~/aiteamforge/fleet-monitor/server && node server.js
```
**Expected Result:** The terminal prints the startup banner including the text `STARFLEET OPERATIONS MONITOR - ONLINE`. The server outputs the port number (e.g., `Server running on port 3000`) and lists dashboard URLs for both classic and LCARS views. No unhandled error or crash occurs within 5 seconds of startup.
**Pass/Fail:** [ ]

---

### Test 7.9: Server Responds to Health Check
**Action:** In a separate terminal (leave the server running from Test 7.8):
```
curl -s http://localhost:3000/api/health | python3 -m json.tool
```
**Expected Result:** A JSON object is printed containing `"status": "operational"`, an `uptime` value greater than 0, a `timestamp` in ISO 8601 format, `machines_tracked` (an integer), and `registered_teams` (an integer). HTTP status 200.
**Pass/Fail:** [ ]

---

### Test 7.10: Server Console Logs Startup Data Load
**Action:** Review the server terminal output from Test 7.8.
**Expected Result:** The console shows lines for each data file loaded. Examples include "Loaded N machines from persistent storage" or "No persistent data file found, starting fresh" for each of the four data files (machines, registered-teams, pushed-boards, pushed-knowledge). No error lines appear during startup.
**Pass/Fail:** [ ]

---

### 7.4 Machine Registration and Heartbeat

---

### Test 7.11: POST /api/status Registers New Machine
**Action:** Send a simulated heartbeat (a new UUID is generated each test run):
```
TEST_UUID=$(uuidgen | tr '[:upper:]' '[:lower:]')
curl -s -X POST http://localhost:3000/api/status \
  -H "Content-Type: application/json" \
  -d "{\"machine\":{\"machine_id\":\"$TEST_UUID\",\"hostname\":\"test-machine-7a\",\"ip\":\"192.168.1.99\",\"os\":\"macOS 14.0\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"},\"sessions\":[{\"name\":\"academy-main\",\"division\":\"academy\",\"project\":null,\"team\":\"academy\",\"windows\":3,\"attached\":true,\"uptime_seconds\":120,\"lcars_port\":8203,\"theme_color\":\"blue\"}]}" | python3 -m json.tool
```
**Expected Result:** Response JSON contains `"success": true`, `"message": "Status received"`, and `"sessions_count": 1`. The server console prints a line with hostname `test-machine-7a` and the UUID prefix (first 8 characters followed by `...`).
**Pass/Fail:** [ ]

---

### Test 7.12: Registered Machine Appears in Fleet Status
**Action:** Immediately after Test 7.11 (`$TEST_UUID` must still be set):
```
curl -s http://localhost:3000/api/fleet | python3 -c "
import json, sys
data = json.load(sys.stdin)
match = [m for m in data['fleet']['machines'] if m['hostname'] == 'test-machine-7a']
if match:
    m = match[0]
    print('FOUND:', m['hostname'])
    print('status:', m['status'])
    print('sessions:', m['session_count'])
    print('machine_id length:', len(m['machine_id']))
else:
    print('NOT FOUND')
"
```
**Expected Result:** Output shows `FOUND: test-machine-7a`, `status: online`, `sessions: 1`, and `machine_id length: 36`. The machine is visible in the fleet immediately after its first heartbeat.
**Pass/Fail:** [ ]

---

### Test 7.13: POST /api/status Rejects Missing Hostname
**Action:** Run:
```
curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:3000/api/status \
  -H "Content-Type: application/json" \
  -d '{"machine": {}, "sessions": []}'
```
**Expected Result:** HTTP status code `400` is printed. The server correctly rejects the malformed request without crashing.
**Pass/Fail:** [ ]

---

### Test 7.14: Heartbeat Updates last_seen Timestamp
**Action:** Send a second heartbeat for the same machine UUID from Test 7.11, then query the fleet:
```
curl -s -X POST http://localhost:3000/api/status \
  -H "Content-Type: application/json" \
  -d "{\"machine\":{\"machine_id\":\"$TEST_UUID\",\"hostname\":\"test-machine-7a\",\"ip\":\"192.168.1.99\",\"os\":\"macOS 14.0\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"},\"sessions\":[]}" > /dev/null

curl -s http://localhost:3000/api/fleet | python3 -c "
import json, sys
data = json.load(sys.stdin)
match = [m for m in data['fleet']['machines'] if m['hostname'] == 'test-machine-7a']
if match:
    print('last_seen:', match[0]['last_seen'])
    print('status:', match[0]['status'])
"
```
**Expected Result:** The `last_seen` timestamp is recent (within the last 10 seconds). `status` is `online`. There is still only one entry for `test-machine-7a`.
**Pass/Fail:** [ ]

---

### Test 7.15: Machine Nickname Can Be Set
**Action:** Retrieve the machine ID of `test-machine-7a` and set a nickname:
```
MACHINE_ID=$(curl -s http://localhost:3000/api/fleet | python3 -c "
import json, sys
data = json.load(sys.stdin)
match = [m for m in data['fleet']['machines'] if m['hostname'] == 'test-machine-7a']
print(match[0]['machine_id'] if match else '')
")
curl -s -X PUT "http://localhost:3000/api/machine/$MACHINE_ID/nickname" \
  -H "Content-Type: application/json" \
  -d '{"nickname": "Bridge Station Alpha"}' | python3 -m json.tool
```
**Expected Result:** Response JSON contains `"success": true`, `"machine_id"` matching the UUID, and `"nickname": "Bridge Station Alpha"`. The server console logs a confirmation line.
**Pass/Fail:** [ ]

---

### 7.5 API Endpoint Testing

---

### Test 7.16: GET /api/fleet Returns Correct Structure
**Action:** Run:
```
curl -s http://localhost:3000/api/fleet | python3 -c "
import json, sys
data = json.load(sys.stdin)
f = data['fleet']
print('online_machines:', f['online_machines'])
print('offline_machines:', f['offline_machines'])
print('total_machines:', f['total_machines'])
print('total_sessions:', f['total_sessions'])
print('has divisions:', isinstance(f.get('divisions'), dict))
print('has machines list:', isinstance(f.get('machines'), list))
print('has activityLog:', isinstance(data.get('activityLog'), list))
print('has last_update:', bool(data.get('last_update')))
print('counts consistent:', f['total_machines'] == f['online_machines'] + f['offline_machines'])
"
```
**Expected Result:** All nine lines print expected values. `counts consistent` is `True`. `has divisions`, `has machines list`, `has activityLog`, and `has last_update` all print `True`.
**Pass/Fail:** [ ]

---

### Test 7.17: GET /api/health Returns All Required Fields
**Action:** Run:
```
curl -s http://localhost:3000/api/health | python3 -c "
import json, sys
data = json.load(sys.stdin)
for field in ['status', 'uptime', 'timestamp', 'machines_tracked', 'registered_teams']:
    val = data.get(field)
    print(field + ': ' + str(val) + ' (' + ('OK' if val is not None else 'MISSING') + ')')
"
```
**Expected Result:** Each of the five required fields prints a non-None value followed by `OK`. The `status` value is `operational`. The `uptime` is a positive number.
**Pass/Fail:** [ ]

---

### Test 7.18: GET /api/registered-teams Returns Valid Response
**Action:** Run:
```
curl -s http://localhost:3000/api/registered-teams | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('total teams:', data['total'])
print('has timestamp:', bool(data.get('timestamp')))
if data['teams']:
    t = data['teams'][0]
    required = ['team', 'organization', 'kanbanDir', 'terminals', 'registeredAt', 'lastSeen']
    print('first team has required fields:', all(k in t for k in required))
"
```
**Expected Result:** `total teams` is a non-negative integer. `has timestamp` is `True`. If any teams are registered, `first team has required fields` is `True`.
**Pass/Fail:** [ ]

---

### Test 7.19: GET /api/backup-status Returns Valid Structure
**Action:** Run:
```
curl -s http://localhost:3000/api/backup-status | python3 -c "
import json, sys
data = json.load(sys.stdin)
valid_statuses = ['operational', 'configured', 'not_configured', 'stale', 'error']
print('status:', data.get('status'))
print('status is valid:', data.get('status') in valid_statuses)
print('has boards:', isinstance(data.get('boards'), dict))
print('has sources:', isinstance(data.get('sources'), list))
"
```
**Expected Result:** `status is valid` is `True`. `has boards` and `has sources` are both `True`. No 500 error is returned.
**Pass/Fail:** [ ]

---

### Test 7.20: GET /api/machines/list Returns Correct Machine Data
**Action:** Run:
```
curl -s http://localhost:3000/api/machines/list | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('total:', data['total'])
print('online:', data['online'])
print('offline:', data['offline'])
print('counts consistent:', data['total'] == data['online'] + data['offline'])
if data['machines']:
    m = data['machines'][0]
    required = ['machine_id', 'hostname', 'display_name', 'status', 'session_count']
    print('has required fields:', all(k in m for k in required))
"
```
**Expected Result:** `counts consistent` is `True`. If machines exist, `has required fields` is `True`. Online machines appear before offline machines.
**Pass/Fail:** [ ]

---

### Test 7.21: GET /api/machine/:id/history Returns Paginated Results
**Action:** Use `$MACHINE_ID` from Test 7.15:
```
curl -s "http://localhost:3000/api/machine/$MACHINE_ID/history?limit=10&offset=0" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('machine_id present:', bool(data.get('machine_id')))
print('total entries:', data.get('total'))
print('limit:', data.get('limit'))
print('offset:', data.get('offset'))
print('has entries array:', isinstance(data.get('entries'), list))
"
```
**Expected Result:** `machine_id present` is `True`. `limit` is `10`. `offset` is `0`. `has entries array` is `True`.
**Pass/Fail:** [ ]

---

### 7.6 Team Registration

---

### Test 7.22: POST /api/team-register Registers a New Team
**Action:** Run:
```
curl -s -X POST http://localhost:3000/api/team-register \
  -H "Content-Type: application/json" \
  -d '{"team":"test-team","teamName":"Test Team","subtitle":"Testing Division","ship":"USS Test","series":"TNG","organization":"starfleet","orgColor":"blue","kanbanDir":"/tmp/test-kanban","fleetMonitorUrl":"http://localhost:3000","terminals":{"main":{"persona":"Tester Alpha","color":"blue"}}}' | python3 -m json.tool
```
**Expected Result:** Response JSON contains `"success": true`, a `"message"` containing `registered`, `"team": "test-team"`, `"organization": "starfleet"`, and `"terminal_count": 1`. HTTP status 201 (first registration) or 200 (re-registration).
**Pass/Fail:** [ ]

---

### Test 7.23: POST /api/team-register Rejects Missing Required Fields
**Action:** Run:
```
curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:3000/api/team-register \
  -H "Content-Type: application/json" \
  -d '{"team": "incomplete-team"}'
```
**Expected Result:** HTTP status code `400` is printed. The server rejects the request because `organization`, `kanbanDir`, and `terminals` are missing.
**Pass/Fail:** [ ]

---

### Test 7.24: GET /api/team-config Returns Registered Team Data
**Action:** Run (after Test 7.22):
```
curl -s "http://localhost:3000/api/team-config?team=test-team" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('team:', data.get('team'))
print('organization:', data.get('organization'))
print('terminals:', list(data.get('terminals', {}).keys()))
print('registeredAt present:', bool(data.get('registeredAt')))
print('lastSeen present:', bool(data.get('lastSeen')))
"
```
**Expected Result:** `team` is `test-team`. `organization` is `starfleet`. `terminals` includes `main`. Both `registeredAt` and `lastSeen` are non-empty.
**Pass/Fail:** [ ]

---

### Test 7.25: GET /api/team-config/:team/terminals Returns Terminal Map
**Action:** Run:
```
curl -s http://localhost:3000/api/team-config/test-team/terminals | python3 -m json.tool
```
**Expected Result:** Response JSON contains `"team": "test-team"` and a `"terminals"` object with a `"main"` key containing `persona` and `color` fields. No 404 or 500 error.
**Pass/Fail:** [ ]

---

### 7.7 Kanban Sync - Push and Pull

---

### Test 7.26: POST /api/kanban-push Stores Board Data
**Action:** Run:
```
curl -s -X POST http://localhost:3000/api/kanban-push \
  -H "Content-Type: application/json" \
  -d '{"team":"test-team","teamName":"Test Team","backlog":[{"id":"TT-0001","title":"Sample Item","status":"completed","priority":"medium","addedAt":"2026-03-01T00:00:00Z","completedAt":"2026-03-15T00:00:00Z","subitems":[]}],"epics":[]}' | python3 -m json.tool
```
**Expected Result:** Response JSON contains `"success": true`, `"team": "test-team"`, and a `pushedAt` timestamp. The server console logs a `[KANBAN-PUSH]` line.
**Pass/Fail:** [ ]

---

### Test 7.27: GET /api/kanban-stats Returns Stats for Pushed Board
**Action:** Run (after Test 7.26):
```
curl -s "http://localhost:3000/api/kanban-stats?team=test-team" | python3 -c "
import json, sys
data = json.load(sys.stdin)
stats = data.get('teams', {}).get('test-team', {})
print('teamId:', stats.get('teamId'))
print('totalItems:', stats.get('totalItems'))
print('completionRate:', stats.get('completionRate'))
print('has statusCounts:', isinstance(stats.get('statusCounts'), dict))
"
```
**Expected Result:** `teamId` is `test-team`. `totalItems` is `1`. `completionRate` is `100.0`. `has statusCounts` is `True`.
**Pass/Fail:** [ ]

---

### Test 7.28: GET /api/working-items Returns Empty When No Active Item
**Action:** Run:
```
curl -s http://localhost:3000/api/working-items | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('response is dict:', isinstance(data, dict))
print('test-team active item:', data.get('test-team'))
"
```
**Expected Result:** `response is dict` is `True`. `test-team active item` is `None` - no item has status `actively-working`.
**Pass/Fail:** [ ]

---

### Test 7.29: GET /api/epics Returns Empty for Board Without Epics
**Action:** Run:
```
curl -s http://localhost:3000/api/epics/test-team | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('team:', data.get('team'))
print('total:', data.get('total'))
print('epics is list:', isinstance(data.get('epics'), list))
"
```
**Expected Result:** `team` is `test-team`. `total` is `0`. `epics is list` is `True`. No 404 or 500 error.
**Pass/Fail:** [ ]

---

### 7.8 Knowledge Sync

---

### Test 7.30: POST /api/knowledge-push Stores Knowledge Stats
**Action:** Run:
```
curl -s -X POST http://localhost:3000/api/knowledge-push \
  -H "Content-Type: application/json" \
  -d '{"team":"test-team","knowledge":{"totalEntries":42,"contributingAgents":3,"categories":{"bugs":10,"patterns":20,"decisions":12},"tags":{"testing":15,"architecture":8},"recentEntries":[{"title":"Fleet Monitor test notes","date":"2026-03-31"}]}}' | python3 -m json.tool
```
**Expected Result:** Response JSON contains `"success": true`, `"team": "test-team"`, and a `pushedAt` timestamp. The server console logs a `[KNOWLEDGE-PUSH]` line.
**Pass/Fail:** [ ]

---

### Test 7.31: GET /api/knowledge-stats Returns Aggregated Data
**Action:** Run (after Test 7.30):
```
curl -s http://localhost:3000/api/knowledge-stats | python3 -c "
import json, sys
data = json.load(sys.stdin)
td = data.get('teams', {}).get('test-team', {})
overall = data.get('overall', {})
print('team totalEntries:', td.get('totalEntries'))
print('team contributingAgents:', td.get('contributingAgents'))
print('overall totalEntries:', overall.get('totalEntries'))
print('teamsWithEntries:', overall.get('teamsWithEntries'))
print('has topTags:', isinstance(overall.get('topTags'), list))
print('has recentEntries:', isinstance(overall.get('recentEntries'), list))
"
```
**Expected Result:** `team totalEntries` is `42`. `team contributingAgents` is `3`. `overall totalEntries` is at least `42`. `teamsWithEntries` is at least `1`. Both `has topTags` and `has recentEntries` are `True`.
**Pass/Fail:** [ ]

---

### 7.9 LCARS Dashboard - Browser Validation

These tests require a web browser. The server must be running from Test 7.8.

---

### Test 7.32: Root URL Serves Dashboard
**Action:** Open in a browser: `http://localhost:3000/`
**Expected Result:** A web page loads without a 404 or error. A fleet monitoring dashboard is displayed. No JavaScript network errors appear in the browser developer tools console.
**Pass/Fail:** [ ]

---

### Test 7.33: LCARS Shortcut Route Redirects Correctly
**Action:** Open in a browser (no trailing slash): `http://localhost:3000/lcars`
**Expected Result:** The browser follows a redirect (HTTP 302) and loads the LCARS unified dashboard at a URL ending in `lcars-dashboard.html?dashboard=academy`. The page displays without a blank screen or error.
**Pass/Fail:** [ ]

---

### Test 7.34: Academy Dashboard View Loads
**Action:** Open in a browser: `http://localhost:3000/lcars/lcars-dashboard.html?dashboard=academy`
**Expected Result:** The LCARS-styled dashboard page loads. The header references "Academy" or "Starfleet". No unhandled JavaScript error prevents render. Fleet status data or a "no data" state is shown.
**Pass/Fail:** [ ]

---

### Test 7.35: Main Event Dashboard View Loads
**Action:** Open in a browser: `http://localhost:3000/lcars/mainevent`
**Expected Result:** The browser redirects to `lcars-dashboard.html?dashboard=mainevent`. The LCARS dashboard loads filtered to the Main Event division without a blank screen.
**Pass/Fail:** [ ]

---

### Test 7.36: DoubleNode Dashboard View Loads
**Action:** Open in a browser: `http://localhost:3000/lcars/doublenode`
**Expected Result:** The browser redirects to `lcars-dashboard.html?dashboard=doublenode`. The LCARS dashboard loads filtered to the DoubleNode division without a blank screen.
**Pass/Fail:** [ ]

---

### Test 7.37: All-Fleet Dashboard View Loads
**Action:** Open in a browser: `http://localhost:3000/lcars/all`
**Expected Result:** The browser redirects to `lcars-dashboard.html?dashboard=all`. The LCARS dashboard loads showing all divisions without a blank screen.
**Pass/Fail:** [ ]

---

### Test 7.38: Static Assets Served Without 404
**Action:** In the browser developer tools Network tab, reload the LCARS dashboard from Test 7.34 and inspect network requests.
**Expected Result:** All CSS and JavaScript resources return HTTP 200. No resources return 404. The page is fully styled with the LCARS color scheme visible.
**Pass/Fail:** [ ]

---

### 7.10 Dashboard Data Accuracy

---

### Test 7.39: Registered Machine Appears in Machine List
**Action:** Run:
```
curl -s http://localhost:3000/api/machines/list | python3 -c "
import json, sys
data = json.load(sys.stdin)
match = [m for m in data['machines'] if m['hostname'] == 'test-machine-7a']
if match:
    m = match[0]
    print('FOUND:', m['hostname'])
    print('display_name:', m['display_name'])
    print('status:', m['status'])
else:
    print('NOT FOUND')
"
```
**Expected Result:** `FOUND: test-machine-7a` is printed. `display_name` is `Bridge Station Alpha` (or `test-machine-7a` if nickname not applied). `status` is `online` assuming a recent heartbeat.
**Pass/Fail:** [ ]

---

### Test 7.40: Fleet API Reflects Consistent Machine Counts
**Action:** Run:
```
curl -s http://localhost:3000/api/fleet | python3 -c "
import json, sys
data = json.load(sys.stdin)
f = data['fleet']
print('online:', f['online_machines'])
print('offline:', f['offline_machines'])
print('total:', f['total_machines'])
print('counts consistent:', f['total_machines'] == f['online_machines'] + f['offline_machines'])
"
```
**Expected Result:** `online` is at least `1`. `counts consistent` is `True`.
**Pass/Fail:** [ ]

---

### Test 7.41: Kanban Stats Reflect Pushed Board Data
**Action:** Run:
```
curl -s http://localhost:3000/api/kanban-stats | python3 -c "
import json, sys
data = json.load(sys.stdin)
overall = data['overall']
print('totalItems:', overall['totalItems'])
print('totalCompleted:', overall['totalCompleted'])
print('overallCompletionRate:', overall['overallCompletionRate'])
print('completed count:', overall['statusCounts'].get('completed', 0))
"
```
**Expected Result:** `totalItems` is at least `1`. `completed count` is at least `1`. `overallCompletionRate` is greater than `0`.
**Pass/Fail:** [ ]

---

### Test 7.42: Activity Log Updated After Heartbeats
**Action:** Run:
```
curl -s http://localhost:3000/api/fleet | python3 -c "
import json, sys
data = json.load(sys.stdin)
log = data.get('activityLog', [])
print('log entries:', len(log))
if log:
    latest = log[0]
    valid_types = ['CONNECT', 'RECONNECT', 'STATUS', 'OFFLINE', 'WARNING']
    print('latest type valid:', latest.get('type') in valid_types)
    print('has timestamp:', bool(latest.get('timestamp')))
    print('has message:', bool(latest.get('message')))
"
```
**Expected Result:** `log entries` is at least `1` and at most `20`. `latest type valid` is `True`. Both `has timestamp` and `has message` are `True`.
**Pass/Fail:** [ ]

---

### 7.11 Machine History Tracking

---

### Test 7.43: Machine History API Returns Data for Known Machine
**Action:** Use `$MACHINE_ID` from Test 7.15:
```
curl -s "http://localhost:3000/api/machine/$MACHINE_ID/history" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('total history entries:', data.get('total'))
print('entries returned:', len(data.get('entries', [])))
if data.get('entries'):
    e = data['entries'][0]
    print('first entry has type:', bool(e.get('type')))
    print('first entry has timestamp:', bool(e.get('timestamp')))
"
```
**Expected Result:** `total history entries` is at least `1`. The first entry has both a `type` and a `timestamp` field.
**Pass/Fail:** [ ]

---

### Test 7.44: Machine History Reflects Status Changes
**Action:** Run:
```
curl -s "http://localhost:3000/api/machine/$MACHINE_ID/history" | python3 -c "
import json, sys
data = json.load(sys.stdin)
entries = data.get('entries', [])
types_seen = list(set(e.get('type') for e in entries))
print('history entry types seen:', types_seen)
print('total entries:', data.get('total'))
"
```
**Expected Result:** `history entry types seen` contains at least one type from: `status_change`, `session_change`, `ip_change`, `nickname_change`, `first_seen`.
**Pass/Fail:** [ ]

---

### Test 7.45: Machine History Pagination Is Respected
**Action:** Run:
```
curl -s "http://localhost:3000/api/machine/$MACHINE_ID/history?limit=1&offset=0" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('limit:', data.get('limit'))
print('offset:', data.get('offset'))
print('entries in page:', len(data.get('entries', [])))
print('page size within total:', len(data.get('entries', [])) <= data.get('total', 0))
"
```
**Expected Result:** `limit` is `1`. `offset` is `0`. `entries in page` is `0` or `1`. `page size within total` is `True`.
**Pass/Fail:** [ ]

---

### 7.12 LaunchAgent Auto-Start Verification

---

### Test 7.46: Fleet Monitor LaunchAgent Plist Exists
**Action:** Run:
```
ls ~/Library/LaunchAgents/com.aiteamforge.fleet-monitor.plist 2>/dev/null && echo "EXISTS" || echo "MISSING"
```
**Expected Result:** Output is `EXISTS`. If `MISSING`, Fleet Monitor will not auto-start on login.
**Pass/Fail:** [ ]

---

### Test 7.47: Fleet Monitor LaunchAgent Is Loaded by launchctl
**Action:** Run:
```
launchctl list | grep "com.aiteamforge.fleet-monitor" || echo "NOT LOADED"
```
**Expected Result:** A line containing `com.aiteamforge.fleet-monitor` is printed with exit code `0` or `-` in the first column. If `NOT LOADED`, the LaunchAgent was not registered.
**Pass/Fail:** [ ]

---

### Test 7.48: Server Restarts Automatically After Stop
**Action:** Stop the server from Test 7.8 (Ctrl-C), then wait:
```
sleep 10
curl -s http://localhost:3000/api/health | python3 -c "import json,sys; d=json.load(sys.stdin); print('status:', d.get('status'))"
```
**Expected Result:** After 10 seconds, health check returns `status: operational`. If no LaunchAgent, start the server manually and record as `SKIPPED - no LaunchAgent`.
**Pass/Fail:** [ ]

---

### Test 7.49: Persistent Data Survives Server Restart
**Action:** After server restarts (Test 7.48):
```
curl -s http://localhost:3000/api/fleet | python3 -c "
import json, sys
data = json.load(sys.stdin)
match = [m for m in data['fleet']['machines'] if m['hostname'] == 'test-machine-7a']
print('test machine persisted:', bool(match))
if match:
    print('nickname persisted:', match[0].get('nickname'))
"
```
**Expected Result:** `test machine persisted` is `True`. `nickname persisted` is `Bridge Station Alpha`. Machine data survived because the server saves `machines.json` every 30 seconds and on SIGTERM/SIGINT.
**Pass/Fail:** [ ]

---

### 7.13 Dashboard Configuration CRUD

---

### Test 7.50: GET /api/dashboards Returns Dashboard List
**Action:** Run:
```
curl -s http://localhost:3000/api/dashboards | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('total dashboards:', data.get('total'))
print('dashboards is list:', isinstance(data.get('dashboards'), list))
if data.get('dashboards'):
    d = data['dashboards'][0]
    required = ['id', 'name', 'title', 'divisions', 'sort_order']
    print('has required fields:', all(k in d for k in required))
"
```
**Expected Result:** `dashboards is list` is `True`. If dashboards exist, `has required fields` is `True`.
**Pass/Fail:** [ ]

---

### Test 7.51: POST /api/dashboards Creates New Dashboard
**Action:** Run:
```
curl -s -X POST http://localhost:3000/api/dashboards \
  -H "Content-Type: application/json" \
  -d '{"name":"Test Dashboard","title":"TEST DASHBOARD","subtitle":"PHASE 7 TESTING","description":"Created by Phase 7 test suite","divisions":["academy"],"org_color":"blue"}' | python3 -c "
import json, sys
data = json.load(sys.stdin)
print('id:', data.get('id'))
print('name:', data.get('name'))
print('system flag:', data.get('system'))
print('sort_order:', data.get('sort_order'))
"
```
**Expected Result:** `id` is a URL-safe slug (e.g., `test-dashboard`). `name` is `Test Dashboard`. `system flag` is `False`. `sort_order` is a positive integer. HTTP status 201.
**Pass/Fail:** [ ]

---

### Test 7.52: DELETE Rejects System Dashboard
**Action:** Run:
```
SYS_DASH=$(curl -s http://localhost:3000/api/dashboards | python3 -c "
import json, sys
data = json.load(sys.stdin)
sys_dashes = [d['id'] for d in data.get('dashboards', []) if d.get('system')]
print(sys_dashes[0] if sys_dashes else '')
")
if [ -n "$SYS_DASH" ]; then
  curl -s -o /dev/null -w "%{http_code}" -X DELETE "http://localhost:3000/api/dashboards/$SYS_DASH"
else
  echo "no-system-dashboards"
fi
```
**Expected Result:** If a system dashboard exists, HTTP status `403` is returned and the dashboard is not deleted. If none exist, `no-system-dashboards` is printed - record as PASS with a note.
**Pass/Fail:** [ ]

---

### 7.14 Edge Cases and Error Handling

---

### Test 7.53: Server Handles Large Session Payloads Without Crash
**Action:** Run:
```
python3 -c "
import urllib.request, json
sessions = [{'name': 'session-' + str(i).zfill(2), 'division': 'academy', 'project': None, 'team': 'academy', 'windows': 2, 'attached': False, 'uptime_seconds': i * 60} for i in range(50)]
payload = {'machine': {'machine_id': 'b'*8+'-'+'c'*4+'-'+'d'*4+'-'+'e'*4+'-'+'f'*12, 'hostname': 'large-session-test', 'ip': '10.0.0.1', 'os': 'macOS 14.0'}, 'sessions': sessions}
data = json.dumps(payload).encode()
print('Payload size: ' + str(len(data)) + ' bytes')
req = urllib.request.Request('http://localhost:3000/api/status', data=data, headers={'Content-Type': 'application/json'}, method='POST')
try:
    resp = urllib.request.urlopen(req, timeout=10)
    body = json.loads(resp.read())
    print('sessions_count:', body.get('sessions_count'))
except Exception as e:
    print('Error:', e)
"
```
**Expected Result:** `Payload size` is well under 10 MB. The server returns `sessions_count: 50` without crashing. This confirms the 10 MB body limit is configured and normal large payloads are accepted.
**Pass/Fail:** [ ]

---

### Test 7.54: Unknown Team Returns 404 from Team Config Endpoint
**Action:** Run:
```
curl -s -o /dev/null -w "%{http_code}" "http://localhost:3000/api/team-config?team=definitely-not-a-team"
```
**Expected Result:** HTTP status `404` is returned. The server identifies the team as unknown rather than returning an empty object or 500.
**Pass/Fail:** [ ]

---

### Test 7.55: Machine Status Transitions to Offline After Threshold
**Action:** After Test 7.11, stop heartbeats for `test-machine-7a` and wait (the offline threshold is 180 seconds):
```
echo "Waiting 185 seconds for offline threshold..."
sleep 185
curl -s http://localhost:3000/api/fleet | python3 -c "
import json, sys
data = json.load(sys.stdin)
match = [m for m in data['fleet']['machines'] if m['hostname'] == 'test-machine-7a']
if match:
    print('status after threshold:', match[0]['status'])
    print('offline_machines count:', data['fleet']['offline_machines'])
else:
    print('machine not found')
"
```
**Expected Result:** `status after threshold: offline`. The server transitions the machine through `warning` (at 120 seconds) then `offline` (at 180 seconds) via the background update task that runs every 30 seconds.
**Pass/Fail:** [ ]

---

### Phase 7 Summary

Record the results for this phase before proceeding to Phase 8.

| Section | Tests | Passed | Failed | Skipped |
|---------|-------|--------|--------|---------|
| 7.1 Installation verification | 5 (7.1-7.5) | | | |
| 7.2 Server mode configuration | 2 (7.6-7.7) | | | |
| 7.3 Server startup | 3 (7.8-7.10) | | | |
| 7.4 Machine registration and heartbeat | 5 (7.11-7.15) | | | |
| 7.5 API endpoint testing | 6 (7.16-7.21) | | | |
| 7.6 Team registration | 4 (7.22-7.25) | | | |
| 7.7 Kanban sync - push and pull | 4 (7.26-7.29) | | | |
| 7.8 Knowledge sync | 2 (7.30-7.31) | | | |
| 7.9 LCARS dashboard - browser | 7 (7.32-7.38) | | | |
| 7.10 Dashboard data accuracy | 4 (7.39-7.42) | | | |
| 7.11 Machine history tracking | 3 (7.43-7.45) | | | |
| 7.12 LaunchAgent auto-start | 4 (7.46-7.49) | | | |
| 7.13 Dashboard configuration CRUD | 3 (7.50-7.52) | | | |
| 7.14 Edge cases and error handling | 3 (7.53-7.55) | | | |
| **Total** | **55** | | | |

**Phase 7 Pass/Fail Criteria:**
- The following tests are critical - Phase 7 FAILS if any are not PASS:
  - Test 7.8 (server starts)
  - Test 7.9 (health check responds)
  - Test 7.11 (heartbeat accepted)
  - Test 7.12 (machine appears in fleet)
  - Test 7.33 (LCARS redirect works)
- Tests 7.46-7.49 (LaunchAgent) may be SKIPPED if LaunchAgent setup was not performed
- Test 7.55 (offline threshold) may be SKIPPED to avoid a 3-minute wait; validate separately
- Phase 7 is PASS when all critical tests pass and no more than 5 non-critical tests are FAIL

**Phase 7 Result:** [ ] PASS   [ ] FAIL

**Notes (record any observations, version mismatches, or unexpected behavior):**

```
Server mode configured as: [ ] standalone  [ ] server  [ ] client
Node.js version in use:
Fleet Monitor port (default 3000):
LaunchAgent configured: [ ] Yes  [ ] No  [ ] Not tested
Machines registered during testing:
Kanban boards pushed: [ ] Yes  [ ] No
Known issues observed:
```

---

*Proceed to Phase 8: LCARS Kanban Service*


## Phase 11: Post-Testing Retrospective

**Purpose:** Document test outcomes, capture knowledge gained during testing, and prepare the
test record for team review. Run Phase 11 after all other phases are complete (or after the
test session ends if the full plan was not completed).

---

### 11.1 Post-Testing Debrief Checklist

Complete each item before closing the test record.

- [ ] **11.1.1** — All phase summary tables filled in (sections, tests passed, tests failed)
- [ ] **11.1.2** — Each phase has a recorded PASS or FAIL verdict
- [ ] **11.1.3** — All test failures have written notes explaining what was observed and what
  was expected
- [ ] **11.1.4** — Any unexpected behaviors (even in passing tests) are noted in the phase
  Notes block
- [ ] **11.1.5** — Environment details recorded (macOS version, Homebrew version, Git version,
  AITeamForge version installed)
- [ ] **11.1.6** — Tester name and test date recorded in the Results Summary (section 11.2)
- [ ] **11.1.7** — Any manual cleanup steps taken outside the test plan are documented
- [ ] **11.1.8** — Test record file saved and accessible to the team (not left only in a local
  worktree)

---

### 11.2 Test Results Summary Template

Fill in this table at the end of the test session.

**Tester:** _______________________________________________
**Date:** _______________________________________________
**Machine:** _______________________________________________
**macOS Version:** _______________________________________________
**Homebrew Version:** _______________________________________________
**AITeamForge Version Installed:** _______________________________________________

| Phase | Description | Total Tests | Passed | Failed | Verdict |
|-------|-------------|-------------|--------|--------|---------|
| 1 | Prerequisites and clean environment | 17 | | | [ ] PASS [ ] FAIL |
| 2 | Homebrew tap add and formula installation | | | | [ ] PASS [ ] FAIL |
| 3 | Setup wizard — dependencies and machine identity | | | | [ ] PASS [ ] FAIL |
| 4 | Setup wizard — team selection and feature config | | | | [ ] PASS [ ] FAIL |
| 5 | Setup wizard — installation and completion | | | | [ ] PASS [ ] FAIL |
| 6 | Post-install verification (`aiteamforge doctor`) | | | | [ ] PASS [ ] FAIL |
| 7 | Shell environment and alias functionality | | | | [ ] PASS [ ] FAIL |
| 8 | LCARS Kanban service | | | | [ ] PASS [ ] FAIL |
| 9 | Claude Code integration | | | | [ ] PASS [ ] FAIL |
| 10 | Teardown and uninstall | | | | [ ] PASS [ ] FAIL |
| **Total** | | | | | |

**Overall Test Run Verdict:** [ ] PASS (all phases pass)   [ ] FAIL (one or more phases fail)

**Summary of failures (if any):**

```
Phase N, Test N.N.N:
  Expected:
  Observed:
  Reproducible: [ ] Yes [ ] No
  Notes:

(repeat for each failure)
```

---

### 11.3 Knowledge Capture Guidelines

After completing the test session, review the following and capture any applicable knowledge
before closing the kanban item.

**Architecture knowledge to record if discovered during testing:**

- AITeamForge uses a two-layer installation: `aiteamforge-framework` (shared infrastructure)
  and `aiteamforge` (working layer that sources the framework). Both layers are installed as
  separate Homebrew formulae from the same tap.
- The setup wizard runs in stages: dependencies check, machine identity assignment, team
  selection, per-team feature flags, then orchestrated installation of all configured
  components.
- `aiteamforge doctor` performs post-install health checks across all installed components.
  Failures here indicate a partial install that should be remediated before relying on the tool.
- Fleet Monitor (`aiteamforge fleet`) provides multi-machine coordination and requires at least
  two machines with network visibility to test properly. Tailscale is the supported transport
  for remote access scenarios.
- Shell integration is loaded by appending to `~/.zshrc` during installation. Testing shell
  aliases requires starting a new shell session (or `source ~/.zshrc`) — not just reloading
  functions.

**Testing patterns to record if discovered:**

- New environment assumptions surfaced during testing (e.g., a required tool not listed in
  Phase 1 prerequisites) should be fed back as Phase 1 updates.
- Any command whose output format differed from the expected result in the test plan should be
  flagged for a test plan update, even if the actual behavior is functionally correct.
- Cleanup steps that were needed but not documented in Phase 10 should be added to Phase 10
  for the next test run.

---

### 11.4 Lessons Learned Documentation Steps

1. **Write observations during testing** — do not rely on memory after the session ends.
   Use the Notes blocks in each phase summary as a running log.

2. **Classify each lesson:**
   - *Product bug* — file a kanban item against AITeamForge
   - *Test plan gap* — update the relevant phase in this document
   - *Reusable pattern* — write a knowledge entry in the appropriate team knowledge directory
   - *Environment note* — add to the Phase 1 or Phase 3 prerequisites

3. **Create knowledge entries for significant discoveries:**
   - File path: `~/dev-team/kanban/knowledge/emh/k###-short-slug.md`
   - Update `~/dev-team/kanban/knowledge/emh/INDEX.md` with the new entry
   - Mirror to `~/.claude/knowledge/emh/` if applicable

4. **Write a brief retrospective** using the template at:
   `~/dev-team/kanban/knowledge/TEMPLATES/retrospective_template.md`
   File as: `kanban/XACA-XXXX_<slug>_RETROSPECTIVE.md`

5. **Mark the kanban item complete** only after the retrospective is filed and knowledge
   entries are updated.

---

### Phase 11 Completion Checklist

- [ ] **11.4.1** — Debrief checklist (11.1) completed
- [ ] **11.4.2** — Results summary table (11.2) filled in and saved
- [ ] **11.4.3** — At least one knowledge entry written or this retrospective filed
- [ ] **11.4.4** — Any product bugs filed as new kanban items
- [ ] **11.4.5** — Test plan updated with any gaps discovered during this run
- [ ] **11.4.6** — Kanban item marked complete via `kb-backlog sub done XACA-XXXX-NNN`

---

*End of AITeamForge Comprehensive Test Plan*
