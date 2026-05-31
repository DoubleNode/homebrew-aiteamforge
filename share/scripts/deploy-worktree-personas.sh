#!/usr/bin/env bash
# deploy-worktree-personas.sh — Deploy tap-installed personas into a worktree's .claude/agents/
# Part of XACA-0588: tap-machine worktree persona deployment (installer-driven).
#
# Usage:
#   deploy-worktree-personas.sh <worktree_path> <team> [--dry-run] [--force] [--verbose]
#   deploy-worktree-personas.sh --all <team> [<main_repo_path>] [--dry-run] [--force] [--verbose]
#   deploy-worktree-personas.sh selftest
#
# Single-worktree mode:
#   Deploys personas from the tap install path into one worktree's .claude/agents/.
#   Called automatically by the wt-new hook on every new worktree creation.
#
# --all backfill mode:
#   Enumerates ALL existing worktrees under <main_repo>/worktrees/ and deploys
#   personas into each one. Tap-machine equivalent of `kb-sync-personas sync-worktrees --all`
#   for pre-existing worktrees (e.g. after a fresh tap install on a machine that already
#   has worktrees). <main_repo_path> defaults to cwd's git common dir root when omitted.
#
# Source resolution (in priority order):
#   PRIMARY : ${AITEAMFORGE_DIR:-$HOME/aiteamforge}/<team>/personas/agents/
#   FALLBACK: dev-machine detected (agents-master present, PRIMARY absent) → no-op
#   NONE    : neither present → warning, exit 0
#
# Guard: only writes to <worktree>/.claude/agents/ when the worktree lives under
#        <main_repo>/worktrees/. Rejects path-traversal and main-repo roots.
#
# Marker: <wt>/.claude/agents/.synced-from-tap (distinct from kb-sync-personas'
#         .synced-from-master). Idempotent — no-op if marker present without --force.
#
# Transform: source filenames are <team>_<character>_<role>_persona.md with a
#            role-based 'name:' frontmatter value. Deployed files keep the same
#            filename but have the 'name:' value rewritten to the character name
#            (2nd '_'-delimited segment of the filename).
#
# Exit codes:
#   0 — success or benign no-op (no personas, dev no-op, already-synced)
#   1 — guard failure (invalid worktree target)
#   2 — copy/write failure
#
# Canonical source: dev-team/scripts/deploy-worktree-personas.sh
# Tap mirror:       homebrew-tap/share/scripts/deploy-worktree-personas.sh (via sync-tap)
# SIBLING-DRIFT NOTE: this script is mirrored to homebrew-tap/share/scripts/ by sync-tap.sh.
# Any change here MUST be followed by sync-tap.sh to keep the tap copy current.

set -euo pipefail

PROG="deploy-worktree-personas"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

_err()     { printf '[%s] ERROR: %s\n' "$PROG" "$*" >&2; }
_warn()    { printf '[%s] WARN: %s\n' "$PROG" "$*" >&2; }
_info()    { printf '[%s] %s\n' "$PROG" "$*"; }
_verbose() {
  if [ "${OPT_VERBOSE:-false}" = "true" ]; then
    printf '[%s] %s\n' "$PROG" "$*"
  fi
}

# ---------------------------------------------------------------------------
# Portable path canonicalizer (no realpath on macOS bash 3.2)
# ---------------------------------------------------------------------------

_canon_path() {
  local p="$1"
  # Fast path: python3 handles symlinks + nonexistent tails
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$p"
    return
  fi
  # Fallback: walk up to nearest existing ancestor, cd+pwd -P, reattach suffix.
  local suffix=""
  local cur="$p"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    if [ -e "$cur" ]; then
      local real
      real=$(cd "$cur" 2>/dev/null && pwd -P) || return 1
      if [ -n "$suffix" ]; then
        printf '%s/%s\n' "$real" "$suffix"
      else
        printf '%s\n' "$real"
      fi
      return 0
    fi
    local base
    base=$(basename "$cur")
    suffix="${base}${suffix:+/$suffix}"
    cur=$(dirname "$cur")
  done
  return 1
}

# ---------------------------------------------------------------------------
# Guard: assert write target is <worktree>/.claude/agents/ under repo/worktrees/
# Mirrors the _guard_worktree_target logic in scripts/kb-sync-personas.
# ---------------------------------------------------------------------------

_guard_worktree_target() {
  local wt_path="$1"
  local main_root="$2"

  # Canonicalize main repo root (must exist).
  local canon_root
  canon_root=$(_canon_path "$main_root") || {
    _err "Cannot canonicalize repo root: $main_root"
    return 1
  }

  # Canonicalize the worktree path (wt root must exist).
  local canon_wt
  canon_wt=$(_canon_path "$wt_path") || {
    _err "Cannot canonicalize worktree path: $wt_path"
    return 1
  }

  local canon_target="${canon_wt}/.claude/agents"

  # Must be under <canon_root>/worktrees/ (not the main repo itself).
  local canon_worktrees="${canon_root}/worktrees"
  if [ "$canon_wt" = "$canon_root" ]; then
    # wt_path IS the main repo — caller is wt-new on a non-worktree path, or
    # someone passed the main repo by mistake. Warn and exit 0 (benign no-op).
    _warn "wt_path resolves to the main repo root — not a worktree. Skipping deploy."
    return 0
  fi

  if [[ "$canon_target" != "${canon_worktrees}/"* ]]; then
    _err "Worktree target does not live under repo worktrees/ dir (${canon_worktrees}): ${canon_target}"
    return 1
  fi

  # Output the validated canonical target path for the caller to use.
  printf '%s\n' "$canon_target"
}

# ---------------------------------------------------------------------------
# Determine main repo root from a worktree path
# ---------------------------------------------------------------------------

_main_root_from_wt() {
  local wt_path="$1"
  local git_common
  git_common=$(git -C "$wt_path" rev-parse --git-common-dir 2>/dev/null) || {
    _err "Not a git repo (or git not available): $wt_path"
    return 1
  }
  # git-common-dir is <main_repo>/.git for both main and worktrees.
  # git -C <path> may return a RELATIVE common-dir (e.g. ".git") when the
  # target IS the main repo. cd from wt_path first so the relative path resolves
  # correctly regardless of the caller's cwd.
  local main_git
  main_git=$(cd "$wt_path" 2>/dev/null && cd "$git_common" 2>/dev/null && pwd -P) || {
    _err "Cannot resolve git common dir: $git_common"
    return 1
  }
  # If it ends in /.git, strip it; otherwise it's already the repo root (bare).
  local root="${main_git%/.git}"
  if [ "$root" = "$main_git" ]; then
    # common dir didn't end in /.git — bare repo or worktree .git file points elsewhere
    root="$main_git"
  fi
  printf '%s\n' "$root"
}

# ---------------------------------------------------------------------------
# Extract character name from tap persona filename
# e.g. academy_reno_engineer_persona.md → "reno"
#      ios_worf_leadtester_persona.md   → "worf"
# ---------------------------------------------------------------------------

_char_from_filename() {
  local bname="$1"
  local tmp="${bname#*_}"     # strip first segment (team_)
  printf '%s\n' "${tmp%%_*}"  # take up to next _
}

# ---------------------------------------------------------------------------
# Rewrite the 'name:' line within the YAML frontmatter block.
# Rules:
#   - Frontmatter is the block between the first --- and the second ---.
#   - Only the FIRST 'name:' line in that block is rewritten.
#   - If no frontmatter or no 'name:' in frontmatter → copy verbatim, warn.
# Output written to stdout; caller redirects to dest file.
# ---------------------------------------------------------------------------

_transform_persona() {
  local src_file="$1"
  local new_name="$2"

  python3 - "$src_file" "$new_name" <<'PYEOF'
import sys, re

src_path = sys.argv[1]
new_name = sys.argv[2]

with open(src_path, 'r', encoding='utf-8') as fh:
    content = fh.read()

lines = content.splitlines(keepends=True)

if not lines or lines[0].strip() != '---':
    # No frontmatter — copy verbatim (warn emitted by caller).
    sys.stdout.write(content)
    sys.exit(2)  # signal "no frontmatter" to caller

in_front = False
end_found = False
name_rewritten = False
out = []

for i, line in enumerate(lines):
    if i == 0 and line.strip() == '---':
        in_front = True
        out.append(line)
        continue
    if in_front and not end_found and line.strip() == '---':
        end_found = True
        in_front = False
        out.append(line)
        continue
    if in_front and not name_rewritten and re.match(r'^name\s*:', line):
        out.append(f'name: {new_name}\n')
        name_rewritten = True
        continue
    out.append(line)

if not name_rewritten:
    # No 'name:' found in frontmatter block — copy verbatim.
    sys.stdout.write(content)
    sys.exit(3)  # signal "no name: found"

sys.stdout.write(''.join(out))
sys.exit(0)
PYEOF
}

# ---------------------------------------------------------------------------
# Write the .synced-from-tap marker file
# ---------------------------------------------------------------------------

_write_marker() {
  local target_dir="$1"
  local team="$2"
  local source_path="$3"
  local aiteamforge_dir="$4"
  local marker="${target_dir}/.synced-from-tap"

  {
    printf 'synced_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'team: %s\n' "$team"
    printf 'source_path: %s\n' "$source_path"
    printf 'aiteamforge_dir: %s\n' "$aiteamforge_dir"
  } > "$marker"
}

# ---------------------------------------------------------------------------
# Core deployment logic — operates on a pre-validated canon_target path.
# Called by both _deploy (single-worktree) and _deploy_all (batch backfill).
# Arguments: canon_target team primary_src aiteamforge_dir
# Returns: 0 success/no-op, 2 write failure
# ---------------------------------------------------------------------------

_deploy_core() {
  local canon_target="$1"
  local team="$2"
  local primary_src="$3"
  local aiteamforge_dir="$4"

  local marker="${canon_target}/.synced-from-tap"

  # --- Idempotency check ---
  if [ "${OPT_FORCE:-false}" != "true" ] && [ -f "$marker" ]; then
    _info "[${team}] Already deployed at ${canon_target} (use --force to refresh)."
    return 0
  fi

  # --- Enumerate source files ---
  local persona_files
  # Build list safely — avoid glob expanding to literal '*.md' when empty.
  persona_files=()
  while IFS= read -r -d '' f; do
    persona_files+=("$f")
  done < <(find "$primary_src" -maxdepth 1 -name '*.md' -type f -print0 | sort -z) || true

  if [ ${#persona_files[@]} -eq 0 ]; then
    _warn "[${team}] No .md files found in ${primary_src} — skipping."
    return 0
  fi

  # --- Create target dir ---
  if [ "${OPT_DRY_RUN:-false}" = "true" ]; then
    _info "[${team}] [DRY-RUN] Would create: ${canon_target}/"
  else
    mkdir -p "$canon_target" || {
      _err "[${team}] Failed to create target dir: ${canon_target}"
      return 2
    }
  fi

  # --- Copy + transform each file ---
  local deployed=0
  local skipped=0

  for src_file in "${persona_files[@]}"; do
    local bname
    bname=$(basename "$src_file")
    local char_name
    char_name=$(_char_from_filename "$bname")
    local dest_file="${canon_target}/${bname}"

    if [ "${OPT_DRY_RUN:-false}" = "true" ]; then
      _info "[${team}] [DRY-RUN] Would transform+copy: ${bname} (name: ${char_name})"
      deployed=$((deployed + 1))
      continue
    fi

    # Transform: rewrite name: in frontmatter; detect issues via exit code.
    local transform_out
    local transform_rc=0
    transform_out=$(_transform_persona "$src_file" "$char_name") || transform_rc=$?

    case "$transform_rc" in
      0)
        # Success — get old name for logging
        local old_name
        old_name=$(awk '/^---/{f++} f==1 && /^name[[:space:]]*:/{print; exit}' "$src_file" | sed 's/^name[[:space:]]*:[[:space:]]*//')
        printf '%s\n' "$transform_out" > "$dest_file" || {
          _err "[${team}] Failed to write: ${dest_file}"
          return 2
        }
        _info "[${team}] transform+copy ${bname} (name: ${old_name} → ${char_name})"
        deployed=$((deployed + 1))
        ;;
      2)
        # No frontmatter — copy verbatim
        _warn "[${team}] ${bname}: no YAML frontmatter — copying verbatim"
        cp "$src_file" "$dest_file" || {
          _err "[${team}] Failed to copy: ${dest_file}"
          return 2
        }
        deployed=$((deployed + 1))
        ;;
      3)
        # No name: in frontmatter — copy verbatim
        _warn "[${team}] ${bname}: no 'name:' in frontmatter — copying verbatim"
        printf '%s\n' "$transform_out" > "$dest_file" || {
          _err "[${team}] Failed to write: ${dest_file}"
          return 2
        }
        deployed=$((deployed + 1))
        ;;
      *)
        _warn "[${team}] ${bname}: transform error (rc=${transform_rc}) — skipping"
        skipped=$((skipped + 1))
        ;;
    esac
  done

  # --- Write marker ---
  if [ "${OPT_DRY_RUN:-false}" != "true" ]; then
    _write_marker "$canon_target" "$team" "$primary_src" "$aiteamforge_dir" || {
      _err "[${team}] Failed to write marker at: ${marker}"
      return 2
    }
    _verbose "[${team}] Marker written: ${marker}"
  fi

  _info "[${team}] Done: ${deployed} deployed, ${skipped} skipped."
}

# ---------------------------------------------------------------------------
# Single-worktree deployment: resolve source + guard, then call _deploy_core.
# ---------------------------------------------------------------------------

_deploy() {
  local wt_path="$1"
  local team="$2"

  # --- Resolve source directory ---
  local aiteamforge_dir="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
  local primary_src="${aiteamforge_dir}/${team}/personas/agents"
  local devmachine_fallback="${HOME}/dev-team/.claude/agents-master/${team}"

  if [ ! -d "$primary_src" ]; then
    # Check dev-machine fallback
    if [ -d "$devmachine_fallback" ]; then
      _info "[${team}] Dev-machine detected: use kb-sync-personas sync-worktrees ${team} instead."
      return 0
    fi
    _warn "[${team}] No personas found at ${primary_src} — skipping."
    return 0
  fi

  # --- Validate worktree target via guard ---
  local main_root
  main_root=$(_main_root_from_wt "$wt_path") || return 1

  local canon_target
  # _guard_worktree_target prints the canonical target path on success, or
  # returns non-zero on failure. The main-repo-is-wt case returns 0 but prints
  # nothing — we detect that by checking if canon_target is empty.
  canon_target=$(_guard_worktree_target "$wt_path" "$main_root") || {
    _err "[${team}] Guard rejected worktree target. Aborting."
    return 1
  }

  if [ -z "$canon_target" ]; then
    # Benign: main repo root passed as wt_path (guard already warned).
    return 0
  fi

  _deploy_core "$canon_target" "$team" "$primary_src" "$aiteamforge_dir"
}

# ---------------------------------------------------------------------------
# Batch backfill: enumerate all worktrees under <main_repo>/worktrees/ and
# deploy personas into each. Tap-machine equivalent of:
#   kb-sync-personas sync-worktrees --all
# for pre-existing worktrees on tap machines.
#
# Arguments: team [main_repo_path]
# main_repo_path defaults to cwd's git common dir root when omitted.
# ---------------------------------------------------------------------------

_deploy_all() {
  local team="$1"
  local main_repo="${2:-}"

  # --- Resolve main repo if not provided ---
  if [ -z "$main_repo" ]; then
    main_repo=$(_main_root_from_wt "$PWD") || {
      _err "Cannot determine main repo root from cwd. Pass <main_repo_path> explicitly."
      return 1
    }
  fi

  # Canonicalize main_repo
  local canon_main
  canon_main=$(_canon_path "$main_repo") || {
    _err "Cannot canonicalize main repo path: $main_repo"
    return 1
  }

  local worktrees_dir="${canon_main}/worktrees"
  if [ ! -d "$worktrees_dir" ]; then
    _info "[${team}] No worktrees/ directory at ${canon_main} — nothing to backfill."
    return 0
  fi

  # --- Resolve source directory (shared with single-worktree mode) ---
  local aiteamforge_dir="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
  local primary_src="${aiteamforge_dir}/${team}/personas/agents"
  local devmachine_fallback="${HOME}/dev-team/.claude/agents-master/${team}"

  if [ ! -d "$primary_src" ]; then
    if [ -d "$devmachine_fallback" ]; then
      _info "[${team}] Dev-machine detected: use kb-sync-personas sync-worktrees ${team} instead."
      return 0
    fi
    _warn "[${team}] No personas found at ${primary_src} — skipping."
    return 0
  fi

  # --- Enumerate worktrees via git porcelain output ---
  # Parse "worktree <path>" lines; skip the first entry (main worktree).
  local wt_paths
  wt_paths=()
  local first=true
  local wt_line
  while IFS= read -r wt_line; do
    if [[ "$wt_line" == worktree\ * ]]; then
      local wt_candidate="${wt_line#worktree }"
      if [ "$first" = true ]; then
        first=false
        continue   # skip main worktree
      fi
      # Only include worktrees under <main_repo>/worktrees/
      local canon_candidate
      canon_candidate=$(_canon_path "$wt_candidate") || continue
      if [[ "$canon_candidate" == "${worktrees_dir}/"* ]]; then
        wt_paths+=("$canon_candidate")
      fi
    fi
  done < <(git -C "$canon_main" worktree list --porcelain 2>/dev/null) || true

  if [ ${#wt_paths[@]} -eq 0 ]; then
    _info "[${team}] No worktrees found under ${worktrees_dir} — nothing to backfill."
    return 0
  fi

  _info "[${team}] Backfilling ${#wt_paths[@]} worktree(s) under ${worktrees_dir}..."

  local overall_rc=0
  for wt_path in "${wt_paths[@]}"; do
    local canon_target
    canon_target=$(_guard_worktree_target "$wt_path" "$canon_main") || {
      _warn "[${team}] Guard rejected: ${wt_path} — skipping."
      continue
    }
    if [ -z "$canon_target" ]; then
      continue
    fi
    _deploy_core "$canon_target" "$team" "$primary_src" "$aiteamforge_dir" || overall_rc=$?
  done

  return $overall_rc
}

# ---------------------------------------------------------------------------
# Self-test suite
# ---------------------------------------------------------------------------

_selftest() {
  local fail=0
  local pass=0
  local total=0

  _pass() { printf '[selftest] PASS: %s\n' "$1"; pass=$((pass + 1)); total=$((total + 1)); }
  _fail() { printf '[selftest] FAIL: %s\n' "$1" >&2; fail=$((fail + 1)); total=$((total + 1)); }

  printf '[selftest] Running deploy-worktree-personas self-test suite...\n'

  # Create temp sandbox — use a script-global so the EXIT trap can see it.
  # 'local' in a function has function scope; the EXIT trap fires after the
  # function returns, at which point local vars are gone (unbound under set -u).
  _SELFTEST_TMP=$(mktemp -d)
  trap 'rm -rf "${_SELFTEST_TMP:-}"' EXIT INT TERM

  local tmp="$_SELFTEST_TMP"

  # Build a fake main repo tree with a worktrees/ subdir
  local fake_main="${tmp}/fake-main"
  local fake_wt="${fake_main}/worktrees/feature-xyz"
  local fake_wt_agents="${fake_wt}/.claude/agents"
  mkdir -p "${fake_main}/.git"
  mkdir -p "$fake_wt"

  # Seed fake aiteamforge dir with test team personas
  local fake_aitf="${tmp}/fake-aiteamforge"
  local fake_src="${fake_aitf}/testteam/personas/agents"
  mkdir -p "$fake_src"

  # Create persona files with role-based name:
  cat > "${fake_src}/testteam_alpha_engineer_persona.md" <<'PERSONA'
---
name: engineering
description: Alpha engineer persona for testing.
model: sonnet
---

# Alpha Engineer Body
PERSONA

  cat > "${fake_src}/testteam_bravo_tester_persona.md" <<'PERSONA'
---
name: holodeck
description: Bravo tester persona for testing.
model: sonnet
---

# Bravo Tester Body
PERSONA

  # Create a persona with no frontmatter (edge case)
  cat > "${fake_src}/testteam_charlie_nofrontmatter_persona.md" <<'PERSONA'
# Charlie — no YAML frontmatter at all
Just body content.
PERSONA

  # Create a persona with frontmatter but no name: line (edge case)
  cat > "${fake_src}/testteam_delta_noname_persona.md" <<'PERSONA'
---
description: Delta persona with no name field.
model: haiku
---

# Delta Body
PERSONA

  # -----------------------------------------------------------------------
  # Test 1: _char_from_filename — extracts second segment correctly
  # -----------------------------------------------------------------------
  printf '[selftest] Test 1: _char_from_filename extracts character name...\n'
  local c1; c1=$(_char_from_filename "testteam_alpha_engineer_persona.md")
  local c2; c2=$(_char_from_filename "ios_worf_leadtester_persona.md")
  local c3; c3=$(_char_from_filename "academy_reno_engineer_persona.md")
  if [ "$c1" = "alpha" ] && [ "$c2" = "worf" ] && [ "$c3" = "reno" ]; then
    _pass "Test 1 (_char_from_filename)"
  else
    _fail "Test 1 — got '$c1'/'$c2'/'$c3' expected alpha/worf/reno"
  fi

  # -----------------------------------------------------------------------
  # Test 2: _guard_worktree_target — accepts valid worktree path
  # -----------------------------------------------------------------------
  printf '[selftest] Test 2: _guard_worktree_target accepts valid worktree...\n'
  local accepted_path
  accepted_path=$(_guard_worktree_target "$fake_wt" "$fake_main" 2>/dev/null) || true
  # Canonicalize expected path too — macOS /tmp is a symlink to /private/tmp,
  # so mktemp returns /tmp/... but _canon_path resolves to /private/tmp/...
  local expected_path
  expected_path=$(_canon_path "${fake_wt}/.claude/agents") || expected_path="${fake_wt}/.claude/agents"
  if [ "$accepted_path" = "$expected_path" ]; then
    _pass "Test 2 (_guard_worktree_target accepts valid path)"
  else
    _fail "Test 2 — expected '${expected_path}', got '${accepted_path}'"
  fi

  # -----------------------------------------------------------------------
  # Test 3: _guard_worktree_target — rejects main repo root (not a worktree)
  # -----------------------------------------------------------------------
  printf '[selftest] Test 3: _guard_worktree_target rejects main repo as wt_path...\n'
  local t3_out t3_rc=0
  t3_out=$(_guard_worktree_target "$fake_main" "$fake_main" 2>/dev/null) || t3_rc=$?
  # Should return 0 (benign) but print empty — the warn-and-return-0 path
  if [ -z "$t3_out" ] && [ "$t3_rc" -eq 0 ]; then
    _pass "Test 3 (_guard_worktree_target treats main repo as benign no-op)"
  else
    _fail "Test 3 — expected empty output + rc=0, got '${t3_out}' rc=${t3_rc}"
  fi

  # -----------------------------------------------------------------------
  # Test 4: _guard_worktree_target — rejects path traversal (outside worktrees/)
  # -----------------------------------------------------------------------
  printf '[selftest] Test 4: _guard_worktree_target rejects traversal path...\n'
  local outside_wt="${tmp}/outside-dir"
  mkdir -p "$outside_wt"
  local t4_rc=0
  _guard_worktree_target "$outside_wt" "$fake_main" 2>/dev/null || t4_rc=$?
  if [ "$t4_rc" -ne 0 ]; then
    _pass "Test 4 (_guard_worktree_target rejects path outside worktrees/)"
  else
    _fail "Test 4 — should have failed (rc=$t4_rc) for path outside worktrees/"
  fi

  # -----------------------------------------------------------------------
  # Test 5: _transform_persona — rewrites name: correctly
  # -----------------------------------------------------------------------
  printf '[selftest] Test 5: _transform_persona rewrites name: correctly...\n'
  local t5_src="${fake_src}/testteam_alpha_engineer_persona.md"
  local t5_out
  t5_out=$(_transform_persona "$t5_src" "alpha")
  local t5_name
  t5_name=$(printf '%s\n' "$t5_out" | awk '/^---/{f++} f==1 && /^name[[:space:]]*:/{print; exit}')
  if [ "$t5_name" = "name: alpha" ]; then
    _pass "Test 5 (_transform_persona name: rewritten to 'alpha')"
  else
    _fail "Test 5 — expected 'name: alpha', got '${t5_name}'"
  fi

  # -----------------------------------------------------------------------
  # Test 6: _transform_persona — body preserved verbatim
  # -----------------------------------------------------------------------
  printf '[selftest] Test 6: _transform_persona preserves body...\n'
  local t6_body
  t6_body=$(printf '%s\n' "$t5_out" | grep "# Alpha Engineer Body") || true
  if [ -n "$t6_body" ]; then
    _pass "Test 6 (_transform_persona body preserved)"
  else
    _fail "Test 6 — body not preserved in transform output"
  fi

  # -----------------------------------------------------------------------
  # Test 7: Full deploy — correct files created + name: rewritten
  # -----------------------------------------------------------------------
  printf '[selftest] Test 7: Full deploy creates files with rewritten name:...\n'
  AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_with_fake_git "$fake_wt" "$fake_main" "testteam" 2>/dev/null || true

  local t7_alpha="${fake_wt_agents}/testteam_alpha_engineer_persona.md"
  local t7_bravo="${fake_wt_agents}/testteam_bravo_tester_persona.md"
  if [ -f "$t7_alpha" ] && [ -f "$t7_bravo" ]; then
    local n_alpha n_bravo
    n_alpha=$(awk '/^---/{f++} f==1 && /^name[[:space:]]*:/{print; exit}' "$t7_alpha")
    n_bravo=$(awk '/^---/{f++} f==1 && /^name[[:space:]]*:/{print; exit}' "$t7_bravo")
    if [ "$n_alpha" = "name: alpha" ] && [ "$n_bravo" = "name: bravo" ]; then
      _pass "Test 7 (full deploy: files present + name: rewritten)"
    else
      _fail "Test 7 — name: not rewritten. alpha='${n_alpha}' bravo='${n_bravo}'"
    fi
  else
    _fail "Test 7 — deployed files not found"
  fi

  # -----------------------------------------------------------------------
  # Test 8: Marker file written with correct fields
  # -----------------------------------------------------------------------
  printf '[selftest] Test 8: Marker file written with correct fields...\n'
  local marker="${fake_wt_agents}/.synced-from-tap"
  if [ -f "$marker" ]; then
    local has_at has_team has_src has_aitf
    has_at=$(grep -c "synced_at:" "$marker" 2>/dev/null || true)
    has_team=$(grep -c "team: testteam" "$marker" 2>/dev/null || true)
    has_src=$(grep -c "source_path:" "$marker" 2>/dev/null || true)
    has_aitf=$(grep -c "aiteamforge_dir:" "$marker" 2>/dev/null || true)
    if [ "$has_at" -gt 0 ] && [ "$has_team" -gt 0 ] && [ "$has_src" -gt 0 ] && [ "$has_aitf" -gt 0 ]; then
      _pass "Test 8 (marker file has all required fields)"
    else
      _fail "Test 8 — marker missing fields: at=${has_at} team=${has_team} src=${has_src} aitf=${has_aitf}"
    fi
  else
    _fail "Test 8 — marker file not created at: ${marker}"
  fi

  # -----------------------------------------------------------------------
  # Test 9: Idempotency — re-running without --force is a no-op
  # -----------------------------------------------------------------------
  printf '[selftest] Test 9: Idempotency (re-run without --force is no-op)...\n'
  local t9_out
  t9_out=$(AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_with_fake_git "$fake_wt" "$fake_main" "testteam" 2>&1) || true
  if printf '%s\n' "$t9_out" | grep -q "Already deployed"; then
    _pass "Test 9 (idempotency: already-deployed message)"
  else
    _fail "Test 9 — expected 'Already deployed' message, got: ${t9_out}"
  fi

  # -----------------------------------------------------------------------
  # Test 10: --force re-deploys even when marker present
  # -----------------------------------------------------------------------
  printf '[selftest] Test 10: --force re-deploys over existing deployment...\n'
  local t10_out
  t10_out=$(AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=true OPT_VERBOSE=false \
    _deploy_with_fake_git "$fake_wt" "$fake_main" "testteam" 2>&1) || true
  if printf '%s\n' "$t10_out" | grep -q "Done:"; then
    _pass "Test 10 (--force triggers re-deploy)"
  else
    _fail "Test 10 — expected 'Done:' output, got: ${t10_out}"
  fi

  # -----------------------------------------------------------------------
  # Test 11: Dev-machine no-op fallback (PRIMARY absent, agents-master present)
  # -----------------------------------------------------------------------
  printf '[selftest] Test 11: Dev-machine no-op fallback...\n'
  # Make a fake agents-master with the team dir
  local fake_devteam="${tmp}/fake-devteam"
  mkdir -p "${fake_devteam}/.claude/agents-master/testteam"
  # Use an aiteamforge dir that has NO testteam personas
  local fake_aitf_empty="${tmp}/fake-aitf-empty"
  mkdir -p "$fake_aitf_empty"
  local t11_out
  t11_out=$(HOME="${tmp}/fake-home-with-devteam" AITEAMFORGE_DIR="$fake_aitf_empty" \
    OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_devmachine_check "testteam" "$fake_devteam" "$fake_aitf_empty" 2>&1) || true
  if printf '%s\n' "$t11_out" | grep -q "Dev-machine detected"; then
    _pass "Test 11 (dev-machine no-op fallback triggered)"
  else
    _fail "Test 11 — expected dev-machine message, got: ${t11_out}"
  fi

  # -----------------------------------------------------------------------
  # Test 12: No-personas path (neither source exists) → warning, exit 0
  # -----------------------------------------------------------------------
  printf '[selftest] Test 12: No personas found → warning, no error...\n'
  local t12_aitf="${tmp}/fake-aitf-nopers"
  mkdir -p "$t12_aitf"
  local t12_out t12_rc=0
  t12_out=$(AITEAMFORGE_DIR="$t12_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_devmachine_check "testteam" "/nonexistent/devteam" "$t12_aitf" 2>&1) || t12_rc=$?
  if printf '%s\n' "$t12_out" | grep -q "No personas found" && [ "$t12_rc" -eq 0 ]; then
    _pass "Test 12 (no-personas: warning + exit 0)"
  else
    _fail "Test 12 — expected warning + exit 0, got rc=${t12_rc}: ${t12_out}"
  fi

  # -----------------------------------------------------------------------
  # Test 13: --all happy-path — 2 worktrees both get personas
  # -----------------------------------------------------------------------
  printf '[selftest] Test 13: --all backfill: 2 worktrees both get personas...\n'
  local fake_main2="${tmp}/fake-main2"
  local fake_wt_a="${fake_main2}/worktrees/feature-aaa"
  local fake_wt_b="${fake_main2}/worktrees/feature-bbb"
  mkdir -p "${fake_main2}/.git"
  mkdir -p "$fake_wt_a"
  mkdir -p "$fake_wt_b"

  local t13_out t13_rc=0
  t13_out=$(AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_all_with_fake_wts "testteam" "$fake_main2" "$fake_aitf" \
      "$fake_wt_a" "$fake_wt_b" 2>&1) || t13_rc=$?

  local wt_a_agents="${fake_wt_a}/.claude/agents"
  local wt_b_agents="${fake_wt_b}/.claude/agents"
  if [ -f "${wt_a_agents}/testteam_alpha_engineer_persona.md" ] && \
     [ -f "${wt_b_agents}/testteam_alpha_engineer_persona.md" ] && \
     [ "$t13_rc" -eq 0 ]; then
    _pass "Test 13 (--all backfill: both worktrees got personas, exit 0)"
  else
    _fail "Test 13 — --all backfill: missing persona files or bad rc=${t13_rc}. out: ${t13_out}"
  fi

  # -----------------------------------------------------------------------
  # Test 14: --all with no worktrees — benign no-op (exit 0, no crash)
  # -----------------------------------------------------------------------
  printf '[selftest] Test 14: --all backfill: no worktrees → benign no-op...\n'
  local fake_main3="${tmp}/fake-main3"
  mkdir -p "${fake_main3}/.git"
  # No worktrees/ subdir at all

  local t14_out t14_rc=0
  t14_out=$(AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_all_with_fake_wts "testteam" "$fake_main3" "$fake_aitf" 2>&1) || t14_rc=$?
  if [ "$t14_rc" -eq 0 ]; then
    _pass "Test 14 (--all backfill: no worktrees → benign no-op, exit 0)"
  else
    _fail "Test 14 — expected exit 0 with no worktrees, got rc=${t14_rc}: ${t14_out}"
  fi

  # -----------------------------------------------------------------------
  # Summary
  # -----------------------------------------------------------------------
  printf '\n[selftest] Results: %d/%d passed\n' "$pass" "$total"
  if [ "$fail" -gt 0 ]; then
    printf '[selftest] FAILED: %d test(s) failed\n' "$fail" >&2
    return 1
  fi
  printf '[selftest] All tests passed.\n'
  return 0
}

# Helper: like _deploy but with git-common-dir stubbed for selftest
# (fake_wt has no real git repo; we bypass _main_root_from_wt).
# Uses _deploy_core directly after guard validation — no logic duplication.
_deploy_with_fake_git() {
  local wt_path="$1"
  local main_root="$2"
  local team="$3"

  local aiteamforge_dir="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
  local primary_src="${aiteamforge_dir}/${team}/personas/agents"
  local devmachine_fallback="${HOME}/dev-team/.claude/agents-master/${team}"

  if [ ! -d "$primary_src" ]; then
    if [ -d "$devmachine_fallback" ]; then
      _info "[${team}] Dev-machine detected: use kb-sync-personas sync-worktrees ${team} instead."
      return 0
    fi
    _warn "[${team}] No personas found at ${primary_src} — skipping."
    return 0
  fi

  local canon_target
  canon_target=$(_guard_worktree_target "$wt_path" "$main_root") || {
    _err "[${team}] Guard rejected worktree target. Aborting."
    return 1
  }

  if [ -z "$canon_target" ]; then
    return 0
  fi

  _deploy_core "$canon_target" "$team" "$primary_src" "$aiteamforge_dir"
}

# Helper: test the dev-machine/no-personas detection path in isolation
_deploy_devmachine_check() {
  local team="$1"
  local devteam_root="$2"
  local aitf_dir="$3"

  local primary_src="${aitf_dir}/${team}/personas/agents"
  local devmachine_fallback="${devteam_root}/.claude/agents-master/${team}"

  if [ ! -d "$primary_src" ]; then
    if [ -d "$devmachine_fallback" ]; then
      _info "[${team}] Dev-machine detected: use kb-sync-personas sync-worktrees ${team} instead."
      return 0
    fi
    _warn "[${team}] No personas found at ${primary_src} — skipping."
    return 0
  fi
}

# Helper: --all mode with a pre-built fake git worktree list (bypasses real git)
# Arguments: team main_root aiteamforge_dir [wt_path ...]
_deploy_all_with_fake_wts() {
  local team="$1"
  local canon_main="$2"
  local aiteamforge_dir="$3"
  shift 3
  local wt_paths=("$@")

  local primary_src="${aiteamforge_dir}/${team}/personas/agents"

  if [ ! -d "$primary_src" ]; then
    _warn "[${team}] No personas found at ${primary_src} — skipping."
    return 0
  fi

  if [ ${#wt_paths[@]} -eq 0 ]; then
    _info "[${team}] No worktrees found — nothing to backfill."
    return 0
  fi

  _info "[${team}] Backfilling ${#wt_paths[@]} worktree(s)..."

  local overall_rc=0
  for wt_path in "${wt_paths[@]}"; do
    local canon_target
    canon_target=$(_guard_worktree_target "$wt_path" "$canon_main") || {
      _warn "[${team}] Guard rejected: ${wt_path} — skipping."
      continue
    }
    if [ -z "$canon_target" ]; then
      continue
    fi
    _deploy_core "$canon_target" "$team" "$primary_src" "$aiteamforge_dir" || overall_rc=$?
  done

  return $overall_rc
}

# ---------------------------------------------------------------------------
# Argument parsing + entry point
# ---------------------------------------------------------------------------

main() {
  if [ $# -eq 0 ]; then
    printf 'Usage: %s <worktree_path> <team> [--dry-run] [--force] [--verbose]\n' "$PROG" >&2
    printf '       %s --all <team> [<main_repo_path>] [--dry-run] [--force] [--verbose]\n' "$PROG" >&2
    printf '       %s selftest\n' "$PROG" >&2
    exit 1
  fi

  if [ "$1" = "selftest" ]; then
    _selftest
    return
  fi

  OPT_DRY_RUN=false
  OPT_FORCE=false
  OPT_VERBOSE=false

  # --all backfill mode: deploy to all existing worktrees
  if [ "$1" = "--all" ]; then
    shift
    if [ $# -eq 0 ]; then
      printf 'Usage: %s --all <team> [<main_repo_path>] [--dry-run] [--force] [--verbose]\n' "$PROG" >&2
      exit 1
    fi
    local all_team="$1"
    shift
    local all_repo=""
    # Consume optional positional main_repo_path (not starting with --)
    if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
      all_repo="$1"
      shift
    fi
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run)  OPT_DRY_RUN=true  ;;
        --force)    OPT_FORCE=true    ;;
        --verbose)  OPT_VERBOSE=true  ;;
        *)
          _err "Unknown option: $1"
          exit 1
          ;;
      esac
      shift
    done
    export OPT_DRY_RUN OPT_FORCE OPT_VERBOSE
    _deploy_all "$all_team" "$all_repo"
    return
  fi

  if [ $# -lt 2 ]; then
    printf 'Usage: %s <worktree_path> <team> [--dry-run] [--force] [--verbose]\n' "$PROG" >&2
    exit 1
  fi

  local wt_path="$1"
  local team="$2"
  shift 2

  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)  OPT_DRY_RUN=true  ;;
      --force)    OPT_FORCE=true    ;;
      --verbose)  OPT_VERBOSE=true  ;;
      *)
        _err "Unknown option: $1"
        exit 1
        ;;
    esac
    shift
  done

  export OPT_DRY_RUN OPT_FORCE OPT_VERBOSE

  _deploy "$wt_path" "$team"
}

main "$@"
