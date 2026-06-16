# Contributing to AITeamForge Homebrew Tap

Thank you for your interest in contributing to the AITeamForge Homebrew Tap!

## Development Setup

### Prerequisites

- macOS Big Sur or later
- Homebrew installed
- Git

### Clone the Tap

```bash
brew tap DoubleNode/aiteamforge
cd $(brew --repository DoubleNode/aiteamforge)
```

### Enable Local Pre-Commit Hooks (Recommended)

This repository ships optional pre-commit hooks in `.githooks/`. Enable them
once per clone:

```bash
git config core.hooksPath .githooks
```

The hooks catch tap-hygiene issues (orphan formulas, version drift, stale
rebrand filenames) and setup-wizard drift before you push. The same checks run
authoritatively in CI, so enabling the hooks locally is optional but saves a
round-trip push-and-fix cycle.

## PR Review Workflow (Bot-Gate Exemption)

The upstream `dev-team` repo uses a dual-gate auto-merge flow that requires
approvals from `ai-security-review-bot[bot]` and `ds9-tester-bot[bot]`. **Those
bots are intentionally NOT installed on this repo.** This tap ships a Homebrew
formula plus setup scripts — it has no secrets, no runtime data path, and no
application logic for a security-review bot to meaningfully analyze. The
authoritative quality gate here is `.github/workflows/tests.yml` (formula audit,
`brew install`/`test`/`uninstall`, shellcheck, drift-guard, tap-hygiene), which
catches every failure mode a tap consumer can actually experience.

PRs merge on green `tests.yml` alone — no `--admin` override required, no bot
reviews to wait for. Branch protection for `main` must list only the
`tests.yml` jobs as required status checks; do not add bot-review requirements
to this repo. Maintainers may still hand-review any PR they consider
nontrivial; the exemption removes the auto-gate, not human judgment.

## Formula Development

### Testing Changes Locally

```bash
# Edit the formula
vim Formula/aiteamforge.rb

# Audit the formula
brew audit --strict --online Formula/aiteamforge.rb

# Install from source to test
brew install --build-from-source aiteamforge

# Run formula tests
brew test aiteamforge

# Test the actual commands
aiteamforge --version
aiteamforge-setup --help
aiteamforge-doctor --verbose

# Uninstall when done testing
brew uninstall aiteamforge
```

### Formula Style Guide

Follow Homebrew's formula style guide:
- Use Ruby 2.6+ syntax
- Keep formula class name in sync with filename
- Use double quotes for strings
- Indent with 2 spaces
- Keep dependencies alphabetically sorted

### Cellar post_install symlinks (XACA-0477)

Three specific file paths are converted to symlinks at `brew install` time via the formula's `post_install` block. These symlinks collapse duplicated CSS/JS assets shared between lcars-ui and fleet-monitor:

- `share/lcars-ui/css/lcars-fleet.css` → `../../fleet-monitor/server/public/lcars/css/lcars-fleet.css`
- `share/lcars-ui/css/lcars-fleet-theme.css` → `../../fleet-monitor/server/public/lcars/css/lcars-fleet-theme.css`
- `share/lcars-ui/js/lcars-fleet-core.js` → `../../fleet-monitor/server/public/lcars/js/lcars-fleet-core.js`

The tap repo continues to ship both lcars-ui and fleet-monitor paths as real files — `sync-tap.sh` dereferences symlinks from the dev-tree and copies the real files into the tap. At `brew install` time, the formula's `post_install` block replaces the lcars-ui copies with symlinks pointing to the canonical fleet-monitor equivalents. These symlinks dangle in the cellar layout (correct behavior: nothing reads from cellar at runtime) but resolve correctly in the user-dir sibling layout after `cp -r` plants both directories.

If new lcars-ui↔fleet-monitor symlinks are added in the dev-tree, the sentinel check `XACA-0477-001` in the subitem tracker will warn, and the formula's `overlap_pairs` array in `post_install` MUST be extended to match. See `kanban/plans/XACA-0477/PLAN.md` for rationale and implementation details.

### Updating the Formula

When updating the formula for a new release:

1. **Update version number**
   ```ruby
   version "1.1.0"
   ```

2. **Update URL**
   ```ruby
   url "https://github.com/DoubleNode/aiteamforge/archive/refs/tags/v1.1.0.tar.gz"
   ```

3. **Calculate new SHA256**
   ```bash
   # Download the release tarball
   curl -L -o aiteamforge-1.1.0.tar.gz \
     https://github.com/DoubleNode/aiteamforge/archive/refs/tags/v1.1.0.tar.gz

   # Calculate SHA256
   shasum -a 256 aiteamforge-1.1.0.tar.gz

   # Update formula
   sha256 "new_sha256_hash_here"
   ```

4. **Test the updated formula**
   ```bash
   brew reinstall --build-from-source aiteamforge
   brew test aiteamforge
   ```

5. **Commit changes**
   ```bash
   git add Formula/aiteamforge.rb
   git commit -m "aiteamforge: update to version 1.1.0"
   git push origin main
   ```

## Core Scripts Development

### Editing CLI Scripts

Scripts are located in `bin/`:
- `aiteamforge-cli.sh` - Main CLI dispatcher
- `aiteamforge-setup.sh` - Setup wizard
- `aiteamforge-doctor.sh` - Health check and diagnostics

### Testing Scripts

```bash
# Check syntax
bash -n bin/aiteamforge-cli.sh
bash -n bin/aiteamforge-setup.sh
bash -n bin/aiteamforge-doctor.sh

# Run ShellCheck
brew install shellcheck
shellcheck bin/*.sh

# Make executable
chmod +x bin/*.sh

# Test directly
./bin/aiteamforge-cli.sh help
./bin/aiteamforge-setup.sh --help
./bin/aiteamforge-doctor.sh --version
```

## Testing

### Adding a tap test — the CI manifest

Every new test script (`homebrew-tap/tests/test-*.sh`) **must be added to `tests/ci-manifest`** or CI's `manifest-completeness-guard` job will fail. The manifest classifies every test into one of four categories, enabling the right runner to execute it:

**Decision rules:**

1. **`plain-shell`** — Runs under stock `bash` with no special dependencies on a standard macOS runner (jq and bash pre-installed). All I/O sandboxed under `TEST_TMP_DIR`; no real `$HOME` mutation, no network, no launchctl, no brew formula install. Use this for unit tests, logic validation, and configuration tests.

2. **`brew-bash`** — Requires Homebrew bash 4+ (uses `declare -A` associative arrays or other bash-4-specific syntax). The runner auto-installs `bash` via Homebrew and invokes the test via `"$(brew --prefix)/bin/bash" tests/test-runner.sh tests/<filename>`. Use this when your test requires bash 4+ features that stock macOS `/bin/bash 3.2` doesn't support.

3. **`real-install`** — Requires a real `brew install aiteamforge` formula installed on the system before the test is meaningful (e.g., post-installation verification, durability checks, integration with actual brew-installed binaries). These belong in the dedicated E2E fresh-install job (`e2e-fresh-install`), not the plain-shell job. Use this for tests that cannot be sandboxed.

4. **`excluded:<reason>`** — Must NOT be auto-run by the plain-shell runner. Reason is mandatory — a concrete explanation of why (e.g., `excluded:harness-not-a-suite` for the test-runner itself, `excluded:requires-real-brew-install` for manual post-install verification). Excluded tests may be run manually or in specialized CI jobs, but they are not part of the automatic manifest-driven enrollment.

**Adding your test:**

```bash
# 1. Write the test at homebrew-tap/tests/test-myfeature.sh
# 2. Classify it in tests/ci-manifest
echo "test-myfeature.sh                              plain-shell" >> tests/ci-manifest
# (or brew-bash / real-install / excluded:<reason>)

# 3. Verify the manifest passes locally
bash tests/ci-manifest-check.sh
# Output: OK: ci-manifest complete — N entries (plain-shell=X, brew-bash=Y, real-install=Z, excluded=W)
```

**How plain-shell tests auto-enroll in CI:**

The `.github/workflows/tests.yml` job `test-shell-homebrew-tap` uses the manifest to discover and run all `plain-shell` tests automatically — no YAML edits needed:

```bash
# CI loop (lines 251–259)
awk '!/^#/ && NF>=2 && $2=="plain-shell" {print $1}' tests/ci-manifest | \
while read testfile; do
  bash tests/test-runner.sh "tests/${testfile}"
done
```

Adding a `plain-shell` test to the manifest instantly enrolls it in this loop. Brew-bash and real-install tests are run in separate special-case steps; excluded tests are skipped entirely.

**Verify completeness before pushing:**

The manifest-completeness gate (`tests/ci-manifest-check.sh`, run on every push in CI) fails if:
- Any `tests/test-*.sh` file on disk is missing from the manifest (drift risk)
- The manifest lists a file that no longer exists on disk (stale entry)
- A manifest line has an invalid category (missing category, typo, excluded with no reason)

Run the check locally to catch issues before push:

```bash
bash tests/ci-manifest-check.sh
```

Exit 0 = complete and consistent; exit 1 = manifest and disk disagree. Fix any reported drift before pushing.

### Manual Testing Workflow

1. **Install from source**
   ```bash
   brew install --build-from-source aiteamforge
   ```

2. **Run setup wizard**
   ```bash
   aiteamforge setup
   ```

3. **Test all commands**
   ```bash
   aiteamforge --version
   aiteamforge help
   aiteamforge-setup --help
   aiteamforge-doctor
   aiteamforge-doctor --verbose
   aiteamforge-doctor --check dependencies
   ```

4. **Test upgrade path**
   ```bash
   aiteamforge setup --upgrade
   ```

5. **Test uninstall**
   ```bash
   aiteamforge setup --uninstall
   brew uninstall aiteamforge
   ```

### Automated Testing

GitHub Actions run automatically on:
- Push to `main` or `develop`
- Pull requests
- Manual trigger

Tests include:
- Formula audit
- Formula style check
- Installation on Intel and ARM macOS
- Script syntax validation
- ShellCheck linting
- Test manifest completeness (XACA-0707)

## Pull Request Process

1. **Fork the repository**

2. **Create a feature branch**
   ```bash
   git checkout -b feature/my-improvement
   ```

3. **Make your changes**
   - Update formula if needed
   - Update scripts if needed
   - Update documentation if needed

4. **Test your changes**
   ```bash
   brew audit --strict Formula/aiteamforge.rb
   brew install --build-from-source aiteamforge
   brew test aiteamforge
   ```

5. **Commit with descriptive message**
   ```bash
   git commit -m "feat: Add support for custom port configuration

   - Add --port option to aiteamforge-setup
   - Update health check to verify custom ports
   - Document port configuration in README"
   ```

6. **Push to your fork**
   ```bash
   git push origin feature/my-improvement
   ```

7. **Create pull request**
   - Describe what changed and why
   - Reference any related issues
   - Include testing notes

## Release Process

### Refreshing the framework CHANGELOG snapshot

`share/CHANGELOG.md` is a **snapshot** of the dev-team framework `CHANGELOG.md`
captured at the time of the current tap tag. `show_changelog` in
`libexec/commands/aiteamforge-upgrade.sh` (around line 442) reads this file
after `aiteamforge upgrade` to show users what changed since their previous
version. If the snapshot is stale, users see outdated release notes.

**Refresh it immediately before tagging a new tap version** so the bottle
that ships under that tag carries fresh notes:

```bash
# from the tap clone root
cp ../dev-team/CHANGELOG.md share/CHANGELOG.md  # adjust path to your dev-team checkout
git add share/CHANGELOG.md
git commit -m "Chore: Refresh share/CHANGELOG.md snapshot for v<X.Y.Z>"
```

This is intentionally a manual cp at release time (per XACA-0511) rather than
a `sync-tap.sh` auto-sync rule — auto-sync would impose a drift-check tax on
every dev-team CHANGELOG update, which the project rejected. Reference:
XACA-0511.

### Creating a New Release

1. **Update version in formula**
   ```ruby
   version "1.1.0"
   ```

2. **Tag the main aiteamforge repository**
   ```bash
   cd /path/to/aiteamforge
   git tag -a v1.1.0 -m "Release v1.1.0"
   git push origin v1.1.0
   ```

3. **GitHub will create release tarball**
   ```
   https://github.com/DoubleNode/aiteamforge/archive/refs/tags/v1.1.0.tar.gz
   ```

4. **Update formula SHA256**
   ```bash
   curl -L -o aiteamforge-1.1.0.tar.gz \
     https://github.com/DoubleNode/aiteamforge/archive/refs/tags/v1.1.0.tar.gz
   shasum -a 256 aiteamforge-1.1.0.tar.gz
   ```

5. **Update formula with new SHA256**

6. **Test thoroughly**
   ```bash
   brew uninstall aiteamforge
   brew install --build-from-source aiteamforge
   brew test aiteamforge
   aiteamforge setup  # Full integration test
   ```

7. **Commit and tag**
   ```bash
   git add Formula/aiteamforge.rb
   git commit -m "aiteamforge: update to version 1.1.0"
   git tag -a v1.1.0 -m "Formula v1.1.0"
   git push origin main
   git push origin v1.1.0
   ```

## Common Issues

### Formula Not Found After Changes

```bash
brew untap DoubleNode/aiteamforge
brew tap DoubleNode/aiteamforge
```

### Installation Fails

```bash
# Check formula syntax
brew audit Formula/aiteamforge.rb

# Install with verbose output
brew install --build-from-source --verbose aiteamforge
```

### Test Failures

```bash
# Check what test block expects
cat Formula/aiteamforge.rb | grep -A 20 "test do"

# Run test with verbose output
brew test --verbose aiteamforge
```

## Code Style

### Ruby (Formula)
- Follow Homebrew Formula Cookbook
- Use `rubocop` for linting
- 2-space indentation

### Bash (Scripts)
- Use `#!/bin/bash` shebang
- Enable `set -eo pipefail`
- Quote all variables
- Use `shellcheck` for linting
- Follow Google Shell Style Guide

### Documentation
- Use Markdown
- Keep lines under 100 characters
- Include code examples
- Update CHANGELOG.md

## Questions?

- Open an issue on GitHub
- Check existing issues/PRs for similar problems
- Review Homebrew documentation: https://docs.brew.sh/

## License

By contributing, you agree that your contributions will be licensed under the same license as the project (MIT).
