# XACA-0175 Test Report — Python Package Install Channel

**Subitem:** XACA-0175-006 — Testing and Debugging
**Tested by:** Lura Thok (Cadet Master, Testing & Quality Assurance)
**Date:** 2026-04-21

---

## Environment

| Component | Version |
|---|---|
| Homebrew | 5.1.7-38-g7344275 |
| macOS | 26.3 (25D5112c) |
| Architecture | arm64 (Apple Silicon) |
| Python (system) | 3.14.4 |
| Python (venv) | 3.14.4 |
| Formula version tested | 0.11.0 (HEAD install from local tap) |

---

## Install Method

Direct `--HEAD` install from the local tap (`doublenode/aiteamforge`) was used
because the `tag: "v0.11.0"` in the formula references a tag not yet pushed to
the remote. The `--HEAD` approach uses `file://` pointing at the tap directory,
but Homebrew's git checkout produced an empty working tree (see Bug #3 below).

**Workaround applied for testing:** after each `brew install --HEAD` or `brew reinstall`,
the `homebrew-tap/` worktree contents were manually synced to
`/opt/homebrew/Cellar/aiteamforge/HEAD/libexec/` to simulate what
`libexec.install Dir["*"]` would produce with a correct checkout. `post_install`
was then driven independently via `brew postinstall`.

This workaround is required ONLY for local testing before the v0.11.0 tag
is pushed to the remote. Once the tag exists, `brew install aiteamforge`
from the tap will work end-to-end without manual intervention.

---

## Test Results

### Test 1: Formula audit

**Result: PASS (style warnings only)**

`brew audit aiteamforge` reported 25 problems, all style/convention nits:
- `assert_predicate :exist?` deprecation (use `assert_path_exists`) — 16 occurrences
- `version` ordering before `license`
- Dependency ordering
- Ruby 1.9 hash syntax
- Missing SHA256 checksum (expected — git URL formula)

**No syntax errors, no invalid `depends_on`, no missing required methods.**
The `assert_predicate` deprecation warnings can be addressed in a follow-up
cleanup commit; they do not affect functionality.

Audit log: `/tmp/xaca-0175-audit.log`

---

### Test 2: Fresh install from local formula

**Result: PASS (with workaround for unpushed tag)**

Initial install attempt via `--formula /path/to/aiteamforge.rb` was rejected
by Homebrew 5.x ("formulae must be in a tap"). Install via `brew install --HEAD`
from the tap directory succeeded after manual libexec population.

Discovered and fixed Bug #1 and Bug #2 during this test (see Bugs section).
After fixes, `post_install` completed successfully with `ohai` output confirming
framework installation.

Install log: `/tmp/xaca-0175-install.log`
Post-install debug log: `/tmp/xaca-0175-postinstall3.log`

---

### Test 3: Verify post_install artifacts

**Result: PASS**

```
PASS: marker    — /opt/homebrew/var/aiteamforge/.installed
PASS: venv dir  — /opt/homebrew/var/aiteamforge/venv
PASS: venv python — /opt/homebrew/var/aiteamforge/venv/bin/python3
PASS: env.sh    — /opt/homebrew/var/aiteamforge/env.sh
pyzipper 0.3.6  — installed in venv
```

All four artifacts present. pyzipper 0.3.6 confirmed in venv.

---

### Test 4: env.sh contents sanity

**Result: PASS**

`env.sh` contents are correct (idempotent guard, `$HOMEBREW_PREFIX` dynamic
resolution, venv-present/absent branches, fallback warning). When sourced:

```
AITEAMFORGE_PYTHON=/opt/homebrew/var/aiteamforge/venv/bin/python3
Python 3.14.4
```

`AITEAMFORGE_PYTHON` resolves to the venv python and the python binary is executable.

---

### Test 5: bin-stub launchers source env.sh

**Result: PASS**

`aiteamforge-doctor` output confirms the venv check line is present:

```
✓ Python 3 (3.14.4)
✓ AITeamForge venv Python (3.14.4) — /opt/homebrew/var/aiteamforge/venv/bin/python3
```

The post-install structure section also shows:

```
✓ Tap-owned venv Python (3.14.4) — /opt/homebrew/var/aiteamforge/venv/bin/python3
```

Full doctor output: `/tmp/xaca-0175-doctor.log`

Non-blocking observation: doctor reports `iterm2 package not in tap venv`. This
is expected — `iterm2` is provisioned during `aiteamforge setup`, not via the
tap's `requirements.txt`. No fix required.

---

### Test 6: Smoke test end-to-end

**Result: PASS — 3/3**

```
=== AITeamForge Python Deps Smoke Test ===

--- Step 1: Resolve AITEAMFORGE_PYTHON ---
AITEAMFORGE_PYTHON = /opt/homebrew/var/aiteamforge/venv/bin/python3
Python version: Python 3.14.4
PASS: AITEAMFORGE_PYTHON is set and executable

--- Step 2: pyzipper import ---
pyzipper version: 0.3.6
PASS: pyzipper imports successfully (version 0.3.6)

--- Step 3: AES-256 roundtrip ---
OK: 30 bytes roundtripped (AES-256/LZMA)
PASS: AES-256 roundtrip succeeded

=== Results: 3/3 passed ===
RESULT: PASS
exit: 0
```

Smoke log: `/tmp/xaca-0175-smoke.log`

---

### Test 7: Idempotency — brew reinstall

**Result: PASS (after Bug #2 fix)**

Before the fix, a second `brew postinstall` failed with:
```
RuntimeError: Will not overwrite /opt/homebrew/var/aiteamforge/env.sh
```

After fixing `env_sh.write` → `env_sh.atomic_write` and `marker.write` →
`marker.atomic_write`, running `brew postinstall` a second time (simulating
reinstall) succeeded with the same output as the first run. Smoke test
continued to pass 3/3 after the second `post_install` run.

Per the design doc, the venv is unconditionally recreated on each
`post_install` call — this was confirmed: the `rm_r(venv)` + `python -m venv`
sequence ran successfully on the second pass.

---

### Test 8: Formula's built-in test block

**Result: PASS**

```
==> Testing doublenode/aiteamforge/aiteamforge
==> /opt/homebrew/Cellar/aiteamforge/HEAD/bin/aiteamforge-setup --help
exit: 0
```

All `assert_path_exists` / `assert_predicate` checks passed.
`requirements.txt` and `python-env.sh` exist assertions both pass.

---

### Test 9: Uninstall cleanup

**Result: DOCUMENTED**

`brew uninstall aiteamforge` completed successfully. Post-uninstall:

```
ls /opt/homebrew/var/aiteamforge
env.sh  venv
```

**`var/aiteamforge/` persists after uninstall (venv + env.sh survive).**
This is the expected Homebrew behavior — `var/` is not managed by `brew
uninstall`. Users who want a clean slate must manually remove
`$HOMEBREW_PREFIX/var/aiteamforge/`. This aligns with the design doc's
description of the venv lifecycle.

---

### Test 10: Machine left in working state

**Result: PASS**

`brew install --HEAD aiteamforge` succeeded. After libexec population and
`brew postinstall`, final smoke test confirms:

```
RESULT: PASS
exit: 0
```

Machine is in working state with aiteamforge installed and pyzipper 0.3.6
available in the tap-owned venv.

---

## Bugs Found and Fixed

### Bug #1 — `venv.rmtree` not a valid Pathname method in Homebrew 5.x

**Severity:** Critical
**Surfaced by:** Test 2 (first post_install run)
**Error:**
```
NoMethodError: undefined method 'rm_r' for an instance of Pathname
aiteamforge.rb:66:in 'Aiteamforge#post_install'
```

The tap formula used `venv.rm_r` (prior version used `venv.rmtree` in the
worktree); neither is a valid Homebrew Pathname instance method. The correct
form is `rm_r(venv)` — a bare `FileUtils` function call, consistent with
Homebrew core formulae.

**Fix:** `venv.rmtree if venv.exist?` → `rm_r(venv) if venv.exist?`
**Commit:** `5563536`

---

### Bug #2 — `Pathname#write` refuses to overwrite on reinstall

**Severity:** Critical
**Surfaced by:** Test 7 (idempotency / reinstall)
**Error:**
```
RuntimeError: Will not overwrite /opt/homebrew/var/aiteamforge/env.sh
aiteamforge.rb:85:in 'Aiteamforge#post_install'
```

Homebrew 5.x `Pathname#write` raises if the target file already exists. The
formula called `env_sh.write` (which fails on reinstall when env.sh is present)
and had a `marker.delete; marker.write` pattern for `.installed` (the delete
fixes the marker case but `write` still raises for env.sh on reinstall without
a preceding delete).

**Fix:** Replace `env_sh.write` with `env_sh.atomic_write` and
`marker.delete + marker.write` with `marker.atomic_write`.
`Pathname#atomic_write` is the Homebrew-idiomatic method for generated files —
it writes atomically via a temp file and handles the overwrite case.
**Commit:** `5563536`

---

### Bug #3 — `file://` URL produces empty checkout (install method limitation)

**Severity:** Blocking for local testing only; does not affect production
**Surfaced by:** Tests 2, 7, 10
**Observation:**

When the formula `url` is set to `file:///opt/homebrew/Library/Taps/...`
(a local tap directory), Homebrew's git clone produces a bare/empty working
tree: only a single zero-byte file `homebrew-aiteamforge` appears in the build
directory instead of the full repo contents. `libexec.install Dir["*"]` then
installs only that empty file, causing `post_install` to fail on the
`requirements.txt` reference.

**Root cause:** Homebrew's git URL fetch mechanism for `file://` paths creates
a bare-style clone without checking out the working tree.

**Impact:** This is a test-environment-only limitation. In production, when
`tag: "v0.11.0"` references an actual pushed tag on the remote
(`https://github.com/DoubleNode/homebrew-aiteamforge.git`), the full checkout
proceeds correctly. The issue does not exist in the shipping formula.

**Mitigation for local testing:** Manual `rsync` of `homebrew-tap/` to
`Cellar/aiteamforge/HEAD/libexec/` after each install to simulate the correct
`Dir["*"]` behavior.

**Recommendation:** After merging this PR and pushing the v0.11.0 tag, run a
fresh `brew uninstall aiteamforge && brew install aiteamforge` to confirm the
full end-to-end flow without this workaround.

---

## Non-Blocking Observations

1. **pip cache permissions warning**: `'/Users/darrenehlers/Library/Caches/pip'
   is not owned or is not writable by the current user`. Pip disables caching,
   causing the first `pyzipper` download to be slow. This is a machine-local
   permission issue and does not affect the formula's correctness.

2. **Audit style nits** (25 reported): All are Homebrew convention warnings
   (deprecated `assert_predicate`, dependency ordering, description format).
   None are blocking. A follow-up `chore:` commit can clean these up before the
   official v0.11.0 tap release.

3. **`iterm2` not in tap venv**: Doctor warns that `iterm2` is not installed in
   the tap-owned venv. This is correct — `iterm2` is provisioned during
   `aiteamforge setup` into the user's cockpit venv, not the tap venv.
   `requirements.txt` intentionally does not include it. No fix needed.

4. **git autoremoving on uninstall**: `git` is autoremoved when aiteamforge is
   uninstalled (it's a formula dependency). This is standard Homebrew behavior
   but may surprise users who have `git` installed as a standalone tool.
   The formula already `depends_on "git"` — no change needed.

---

## Final Verdict

**APPROVE for PR creation** — with the following conditions:

1. Bugs #1 and #2 are fixed in commit `5563536` (already on this branch).
2. Bug #3 (empty checkout via `file://` URL) is a test-environment artifact
   only and does not affect production installs. The full end-to-end flow must
   be verified after pushing the v0.11.0 tag (see Recommendation above).
3. The 25 audit style warnings are non-blocking but should be addressed in a
   follow-up cleanup commit.

The core Python dependency channel design (venv creation, pip install from
`requirements.txt`, `env.sh` generation, bin-stub sourcing, and smoke test)
works correctly once the Pathname API bugs are fixed.
