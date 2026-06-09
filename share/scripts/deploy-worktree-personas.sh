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
#   Enumerates ALL registered linked worktrees of the repo (via git worktree list)
#   and deploys personas into each one. Layout-agnostic — works with dev layout
#   (<repo>/worktrees/X) and tap/container layout (dirname(repo)/worktrees/X).
#   Tap-machine equivalent of `kb-sync-personas sync-worktrees --all` for pre-existing
#   worktrees (e.g. after a fresh tap install on a machine that already has worktrees).
#   <main_repo_path> defaults to cwd's git common dir root when omitted.
#
# Source resolution (in priority order):
#   PRIMARY : ${AITEAMFORGE_DIR:-$HOME/aiteamforge}/<team>/personas/agents/
#   FALLBACK: dev-machine detected (agents-master present, PRIMARY absent) → no-op
#   NONE    : neither present → warning, exit 0
#
# Guard: only writes to <worktree>/.claude/agents/ when the worktree is a
#        registered linked worktree of the repo (layout-agnostic). Rejects
#        path-traversal, non-git paths, and main-repo roots.
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
# Guard: assert write target is a GENUINE LINKED WORKTREE of the repo.
# Layout-agnostic: accepts both <repo>/worktrees/X (dev layout) and
# dirname(repo)/worktrees/X (tap/container layout). Traversal safety is
# preserved by canonicalization + git-registry membership check rather than
# a fixed path-prefix test.
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

  # Benign no-op: wt_path IS the main repo root.
  # (Caller is wt-new on a non-worktree path, or main repo passed by mistake.)
  if [ "$canon_wt" = "$canon_root" ]; then
    _warn "wt_path resolves to the main repo root — not a worktree. Skipping deploy."
    return 0
  fi

  # --- Verify canon_wt is a REGISTERED LINKED WORKTREE of this repo ---
  # Parse 'git worktree list --porcelain' from the main repo.
  # The first 'worktree <path>' line is always the main worktree; all
  # subsequent 'worktree <path>' lines are linked worktrees.
  # We canonicalize each path to handle symlinks robustly.
  #
  # Security: a path that appears in git's own registry is by definition
  # inside the git object store's worktree list — it can't be a path-
  # traversal artifact injected by the caller, because git resolves each
  # worktree's on-disk path independently when it writes the worktree list.
  local wt_list
  wt_list=$(git -C "$canon_root" worktree list --porcelain 2>/dev/null) || {
    _err "git worktree list failed for repo: ${canon_root}"
    return 1
  }

  local found_as_linked=false
  local wt_line
  local first_wt=true
  while IFS= read -r wt_line; do
    if [[ "$wt_line" == worktree\ * ]]; then
      local candidate="${wt_line#worktree }"
      if [ "$first_wt" = true ]; then
        first_wt=false
        continue   # skip main worktree entry
      fi
      local canon_candidate
      canon_candidate=$(_canon_path "$candidate") || continue
      if [ "$canon_candidate" = "$canon_wt" ]; then
        found_as_linked=true
        break
      fi
    fi
  done <<< "$wt_list"

  if [ "$found_as_linked" != true ]; then
    _err "Not a registered linked worktree of repo (${canon_root}): ${canon_wt}"
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
# Resolve git root(s) from a path that may be a git repo OR a container dir.
#
# Semantics (identical to XACA-0606's _resolve_git_roots in kb-sync-personas):
#   - If <path> is itself a git repo (toplevel == canonicalized <path>) → print it.
#   - Else scan immediate child directories for git repos and print each root.
#   - Prints nothing if no roots found (caller warns).
#
# SIBLING-DRIFT NOTE (k501): this helper and the one in kb-sync-personas must
# be kept semantically in sync.  If either is changed, audit the other.
# ---------------------------------------------------------------------------

_resolve_git_roots() {
  local container="$1"

  # Case 1: container is itself a git repo
  local top
  top=$(git -C "$container" rev-parse --show-toplevel 2>/dev/null) || top=""
  if [ -n "$top" ]; then
    local canon_container canon_top
    canon_container=$(_canon_path "$container") || canon_container="$container"
    canon_top=$(_canon_path "$top")             || canon_top="$top"
    if [ "$canon_container" = "$canon_top" ]; then
      echo "$top"
      return 0
    fi
  fi

  # Case 2: scan immediate children for git repos (handles container-layout teams
  # where the container dir itself is not a git repo — e.g. MainEventApp-iOS/).
  # Declare loop-locals before the loop (k501: zsh local-in-loop stdout-leak).
  local found=false
  local child
  local root
  for child in "$container"/*/; do
    [ -d "$child" ] || continue
    # Quick check: must have a .git entry (file for worktrees, dir for main repo)
    [ -e "${child}.git" ] || continue
    # Confirm it is a valid work-tree root
    if git -C "$child" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      root=$(git -C "$child" rev-parse --show-toplevel 2>/dev/null) || continue
      echo "$root"
      found=true
    fi
  done

  # Return 0 regardless — caller checks output emptiness and warns.
  return 0
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
# Batch backfill: enumerate ALL registered linked worktrees of the repo and
# deploy personas into each. Layout-agnostic: works with both dev layout
# (<repo>/worktrees/X) and tap/container layout (dirname(repo)/worktrees/X).
# Tap-machine equivalent of:
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
    # Try to resolve from cwd via git common dir.  When cwd is a container (not
    # a git repo) _main_root_from_wt will fail — fall back to using cwd itself
    # as the container candidate so _resolve_git_roots can probe its children.
    local resolved_from_wt
    resolved_from_wt=$(_main_root_from_wt "$PWD" 2>/dev/null) && main_repo="$resolved_from_wt" \
      || main_repo="$PWD"
  fi

  # Canonicalize the provided/resolved path
  local canon_main
  canon_main=$(_canon_path "$main_repo") || {
    _err "Cannot canonicalize main repo path: $main_repo"
    return 1
  }

  # --- Resolve source directory (shared with single-worktree mode) ---
  # Resolved once here; reused across all git roots.
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

  # --- Resolve git root(s) from the canonicalized path ---
  # If canon_main is a plain git repo this yields just canon_main (no regression).
  # If it is a container dir (iOS/Android/DNS topology) this yields the inner
  # git repo(s) found as immediate children.
  local git_roots
  git_roots=()
  local gr
  while IFS= read -r gr; do
    [ -n "$gr" ] && git_roots+=("$gr")
  done < <(_resolve_git_roots "$canon_main")

  if [ ${#git_roots[@]} -eq 0 ]; then
    _warn "[${team}] ${canon_main} is not a git repo and has no inner git repos — nothing to backfill."
    return 0
  fi

  # --- For each resolved git root: enumerate + deploy linked worktrees ---
  # Declare all loop-locals BEFORE the loops to avoid the zsh local-in-loop
  # stdout-leak (k501: `local VAR` inside a loop emits VAR=value on zsh when
  # VAR is reassigned on the 2nd+ iteration).
  local overall_rc=0
  local git_root
  local wt_paths
  local first
  local wt_line
  local wt_candidate
  local canon_candidate
  local wt_path
  local canon_target
  for git_root in "${git_roots[@]}"; do
    _info "[${team}] Processing git root: ${git_root}"

    # Enumerate all linked worktrees for this root.
    # NOTE (XACA-0660 k501-sibling-drift): kb-sync-personas sync-worktrees gained
    # a parallel loop that ALSO deploys to the nested main git root itself
    # (e.g. <container>/develop/) when git_root != container. That gap is NOT
    # replicated here because this script deploys from the tap installation
    # (~aiteamforge/.../personas/agents/) — a path only available on tap consumer
    # machines — whereas the nested-main-root deploy in kb-sync-personas reads
    # from the dev-team master. On tap machines, `kb-sync-personas sync-worktrees`
    # is the authoritative command for nested-main-root persona deployment.
    wt_paths=()
    first=true
    while IFS= read -r wt_line; do
      if [[ "$wt_line" == worktree\ * ]]; then
        wt_candidate="${wt_line#worktree }"
        if [ "$first" = true ]; then
          first=false
          continue   # skip main worktree entry (see NOTE above for nested-main-root context)
        fi
        canon_candidate=$(_canon_path "$wt_candidate") || continue
        wt_paths+=("$canon_candidate")
      fi
    done < <(git -C "$git_root" worktree list --porcelain 2>/dev/null) || true

    if [ ${#wt_paths[@]} -eq 0 ]; then
      _info "[${team}] No linked worktrees registered for repo at ${git_root} — nothing to backfill."
      continue
    fi

    _info "[${team}] Backfilling ${#wt_paths[@]} worktree(s) under ${git_root}..."

    for wt_path in "${wt_paths[@]}"; do
      canon_target=$(_guard_worktree_target "$wt_path" "$git_root") || {
        _warn "[${team}] Guard rejected: ${wt_path} — skipping."
        continue
      }
      if [ -z "$canon_target" ]; then
        continue
      fi
      _deploy_core "$canon_target" "$team" "$primary_src" "$aiteamforge_dir" || overall_rc=$?
    done
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

  # -----------------------------------------------------------------------
  # Build real git repos for guard tests (guard now calls git worktree list).
  # -----------------------------------------------------------------------

  # --- Dev layout: worktree UNDER <repo>/worktrees/X ---
  # Layout: tmp/dev-repo/  (main repo)
  #         tmp/dev-repo/worktrees/feature-xyz  (linked worktree, dev layout)
  local dev_main="${tmp}/dev-repo"
  local dev_wt="${dev_main}/worktrees/feature-xyz"
  mkdir -p "$dev_wt"
  git -C "$dev_main" init -q
  git -C "$dev_main" commit -q --allow-empty -m "init"
  git -C "$dev_main" worktree add -q "$dev_wt" -b selftest-dev-layout 2>/dev/null

  # --- Tap/sibling layout: worktree at dirname(repo)/worktrees/X ---
  # Layout: tmp/tap-base/main/       (main repo)
  #         tmp/tap-base/worktrees/feature-tapxyz  (linked worktree, sibling layout)
  local tap_base="${tmp}/tap-base"
  local tap_main="${tap_base}/main"
  local tap_wt="${tap_base}/worktrees/feature-tapxyz"
  mkdir -p "$tap_main" "$tap_wt"
  git -C "$tap_main" init -q
  git -C "$tap_main" commit -q --allow-empty -m "init"
  git -C "$tap_main" worktree add -q "$tap_wt" -b selftest-tap-layout 2>/dev/null

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
  # Test 2: guard — accepts dev layout (worktree UNDER <repo>/worktrees/X)
  # -----------------------------------------------------------------------
  printf '[selftest] Test 2: guard accepts dev-layout worktree (under repo/worktrees/)...\n'
  local t2_out t2_rc=0
  t2_out=$(_guard_worktree_target "$dev_wt" "$dev_main" 2>/dev/null) || t2_rc=$?
  local t2_expected
  t2_expected=$(_canon_path "${dev_wt}/.claude/agents") || t2_expected="${dev_wt}/.claude/agents"
  if [ "$t2_rc" -eq 0 ] && [ "$t2_out" = "$t2_expected" ]; then
    _pass "Test 2 (guard accepts dev-layout worktree)"
  else
    _fail "Test 2 — rc=${t2_rc} expected '${t2_expected}', got '${t2_out}'"
  fi

  # -----------------------------------------------------------------------
  # Test 3: guard — accepts tap/sibling layout (worktree at dirname(repo)/worktrees/X)
  # -----------------------------------------------------------------------
  printf '[selftest] Test 3: guard accepts tap/sibling-layout worktree (sibling of repo)...\n'
  local t3_out t3_rc=0
  t3_out=$(_guard_worktree_target "$tap_wt" "$tap_main" 2>/dev/null) || t3_rc=$?
  local t3_expected
  t3_expected=$(_canon_path "${tap_wt}/.claude/agents") || t3_expected="${tap_wt}/.claude/agents"
  if [ "$t3_rc" -eq 0 ] && [ "$t3_out" = "$t3_expected" ]; then
    _pass "Test 3 (guard accepts tap/sibling-layout worktree)"
  else
    _fail "Test 3 — rc=${t3_rc} expected '${t3_expected}', got '${t3_out}'"
  fi

  # -----------------------------------------------------------------------
  # Test 4: guard — rejects main repo root (benign no-op, exit 0, empty output)
  # -----------------------------------------------------------------------
  printf '[selftest] Test 4: guard treats main repo root as benign no-op...\n'
  local t4_out t4_rc=0
  t4_out=$(_guard_worktree_target "$dev_main" "$dev_main" 2>/dev/null) || t4_rc=$?
  if [ -z "$t4_out" ] && [ "$t4_rc" -eq 0 ]; then
    _pass "Test 4 (guard: main repo root → benign no-op, exit 0)"
  else
    _fail "Test 4 — expected empty output + rc=0, got '${t4_out}' rc=${t4_rc}"
  fi

  # -----------------------------------------------------------------------
  # Test 5: guard — rejects a random non-worktree directory (exit 1)
  # -----------------------------------------------------------------------
  printf '[selftest] Test 5: guard rejects random non-worktree directory...\n'
  local t5_notawt="${tmp}/not-a-worktree"
  mkdir -p "$t5_notawt"
  local t5_rc=0
  _guard_worktree_target "$t5_notawt" "$dev_main" 2>/dev/null || t5_rc=$?
  if [ "$t5_rc" -ne 0 ]; then
    _pass "Test 5 (guard rejects non-registered path, exit 1)"
  else
    _fail "Test 5 — expected exit 1 for non-worktree dir, got rc=${t5_rc}"
  fi

  # -----------------------------------------------------------------------
  # Test 6: _transform_persona — rewrites name: correctly
  # -----------------------------------------------------------------------
  printf '[selftest] Test 6: _transform_persona rewrites name: correctly...\n'
  local t6_src="${fake_src}/testteam_alpha_engineer_persona.md"
  local t6_out
  t6_out=$(_transform_persona "$t6_src" "alpha")
  local t6_name
  t6_name=$(printf '%s\n' "$t6_out" | awk '/^---/{f++} f==1 && /^name[[:space:]]*:/{print; exit}')
  if [ "$t6_name" = "name: alpha" ]; then
    _pass "Test 6 (_transform_persona name: rewritten to 'alpha')"
  else
    _fail "Test 6 — expected 'name: alpha', got '${t6_name}'"
  fi

  # -----------------------------------------------------------------------
  # Test 7: _transform_persona — body preserved verbatim
  # -----------------------------------------------------------------------
  printf '[selftest] Test 7: _transform_persona preserves body...\n'
  local t7_body
  t7_body=$(printf '%s\n' "$t6_out" | grep "# Alpha Engineer Body") || true
  if [ -n "$t7_body" ]; then
    _pass "Test 7 (_transform_persona body preserved)"
  else
    _fail "Test 7 — body not preserved in transform output"
  fi

  # -----------------------------------------------------------------------
  # Test 8: Full deploy (dev layout) — files created + name: rewritten
  # -----------------------------------------------------------------------
  printf '[selftest] Test 8: Full deploy on dev-layout worktree...\n'
  local dev_wt_agents="${dev_wt}/.claude/agents"
  AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy "$dev_wt" "testteam" 2>/dev/null || true

  local t8_alpha="${dev_wt_agents}/testteam_alpha_engineer_persona.md"
  local t8_bravo="${dev_wt_agents}/testteam_bravo_tester_persona.md"
  if [ -f "$t8_alpha" ] && [ -f "$t8_bravo" ]; then
    local n_alpha n_bravo
    n_alpha=$(awk '/^---/{f++} f==1 && /^name[[:space:]]*:/{print; exit}' "$t8_alpha")
    n_bravo=$(awk '/^---/{f++} f==1 && /^name[[:space:]]*:/{print; exit}' "$t8_bravo")
    if [ "$n_alpha" = "name: alpha" ] && [ "$n_bravo" = "name: bravo" ]; then
      _pass "Test 8 (dev-layout full deploy: files present + name: rewritten)"
    else
      _fail "Test 8 — name: not rewritten. alpha='${n_alpha}' bravo='${n_bravo}'"
    fi
  else
    _fail "Test 8 — deployed files not found in dev-layout worktree"
  fi

  # -----------------------------------------------------------------------
  # Test 9: Full deploy (tap/sibling layout) — files created + name: rewritten
  # -----------------------------------------------------------------------
  printf '[selftest] Test 9: Full deploy on tap/sibling-layout worktree...\n'
  local tap_wt_agents="${tap_wt}/.claude/agents"
  AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy "$tap_wt" "testteam" 2>/dev/null || true

  local t9_alpha="${tap_wt_agents}/testteam_alpha_engineer_persona.md"
  if [ -f "$t9_alpha" ]; then
    local t9_name
    t9_name=$(awk '/^---/{f++} f==1 && /^name[[:space:]]*:/{print; exit}' "$t9_alpha")
    if [ "$t9_name" = "name: alpha" ]; then
      _pass "Test 9 (tap/sibling-layout full deploy: file present + name: rewritten)"
    else
      _fail "Test 9 — name: not rewritten in tap-layout worktree: '${t9_name}'"
    fi
  else
    _fail "Test 9 — deployed files not found in tap/sibling-layout worktree"
  fi

  # -----------------------------------------------------------------------
  # Test 10: Marker file written with correct fields
  # -----------------------------------------------------------------------
  printf '[selftest] Test 10: Marker file written with correct fields...\n'
  local marker="${dev_wt_agents}/.synced-from-tap"
  if [ -f "$marker" ]; then
    local has_at has_team has_src has_aitf
    has_at=$(grep -c "synced_at:" "$marker" 2>/dev/null || true)
    has_team=$(grep -c "team: testteam" "$marker" 2>/dev/null || true)
    has_src=$(grep -c "source_path:" "$marker" 2>/dev/null || true)
    has_aitf=$(grep -c "aiteamforge_dir:" "$marker" 2>/dev/null || true)
    if [ "$has_at" -gt 0 ] && [ "$has_team" -gt 0 ] && [ "$has_src" -gt 0 ] && [ "$has_aitf" -gt 0 ]; then
      _pass "Test 10 (marker file has all required fields)"
    else
      _fail "Test 10 — marker missing fields: at=${has_at} team=${has_team} src=${has_src} aitf=${has_aitf}"
    fi
  else
    _fail "Test 10 — marker file not created at: ${marker}"
  fi

  # -----------------------------------------------------------------------
  # Test 11: Idempotency — re-running without --force is a no-op
  # -----------------------------------------------------------------------
  printf '[selftest] Test 11: Idempotency (re-run without --force is no-op)...\n'
  local t11_out
  t11_out=$(AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy "$dev_wt" "testteam" 2>&1) || true
  if printf '%s\n' "$t11_out" | grep -q "Already deployed"; then
    _pass "Test 11 (idempotency: already-deployed message)"
  else
    _fail "Test 11 — expected 'Already deployed' message, got: ${t11_out}"
  fi

  # -----------------------------------------------------------------------
  # Test 12: --force re-deploys even when marker present
  # -----------------------------------------------------------------------
  printf '[selftest] Test 12: --force re-deploys over existing deployment...\n'
  local t12_out
  t12_out=$(AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=true OPT_VERBOSE=false \
    _deploy "$dev_wt" "testteam" 2>&1) || true
  if printf '%s\n' "$t12_out" | grep -q "Done:"; then
    _pass "Test 12 (--force triggers re-deploy)"
  else
    _fail "Test 12 — expected 'Done:' output, got: ${t12_out}"
  fi

  # -----------------------------------------------------------------------
  # Test 13: Dev-machine no-op fallback (PRIMARY absent, agents-master present)
  # -----------------------------------------------------------------------
  printf '[selftest] Test 13: Dev-machine no-op fallback...\n'
  local fake_devteam="${tmp}/fake-devteam"
  mkdir -p "${fake_devteam}/.claude/agents-master/testteam"
  local fake_aitf_empty="${tmp}/fake-aitf-empty"
  mkdir -p "$fake_aitf_empty"
  local t13_out
  t13_out=$(AITEAMFORGE_DIR="$fake_aitf_empty" \
    OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_devmachine_check "testteam" "$fake_devteam" "$fake_aitf_empty" 2>&1) || true
  if printf '%s\n' "$t13_out" | grep -q "Dev-machine detected"; then
    _pass "Test 13 (dev-machine no-op fallback triggered)"
  else
    _fail "Test 13 — expected dev-machine message, got: ${t13_out}"
  fi

  # -----------------------------------------------------------------------
  # Test 14: No-personas path (neither source exists) → warning, exit 0
  # -----------------------------------------------------------------------
  printf '[selftest] Test 14: No personas found → warning, no error...\n'
  local t14_aitf="${tmp}/fake-aitf-nopers"
  mkdir -p "$t14_aitf"
  local t14_out t14_rc=0
  t14_out=$(AITEAMFORGE_DIR="$t14_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_devmachine_check "testteam" "/nonexistent/devteam" "$t14_aitf" 2>&1) || t14_rc=$?
  if printf '%s\n' "$t14_out" | grep -q "No personas found" && [ "$t14_rc" -eq 0 ]; then
    _pass "Test 14 (no-personas: warning + exit 0)"
  else
    _fail "Test 14 — expected warning + exit 0, got rc=${t14_rc}: ${t14_out}"
  fi

  # -----------------------------------------------------------------------
  # Test 15: --all backfill — both registered worktrees get personas
  # Real git repo with 2 linked worktrees (both under worktrees/ subdir of main).
  # -----------------------------------------------------------------------
  printf '[selftest] Test 15: --all backfill: 2 worktrees both get personas...\n'
  local all_main="${tmp}/all-main"
  local all_wt_a="${all_main}/worktrees/feature-aaa"
  local all_wt_b="${all_main}/worktrees/feature-bbb"
  mkdir -p "$all_wt_a" "$all_wt_b"
  git -C "$all_main" init -q
  git -C "$all_main" commit -q --allow-empty -m "init"
  git -C "$all_main" worktree add -q "$all_wt_a" -b selftest-all-aaa 2>/dev/null
  git -C "$all_main" worktree add -q "$all_wt_b" -b selftest-all-bbb 2>/dev/null

  local t15_out t15_rc=0
  t15_out=$(AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_all "testteam" "$all_main" 2>&1) || t15_rc=$?

  local wt_a_agents="${all_wt_a}/.claude/agents"
  local wt_b_agents="${all_wt_b}/.claude/agents"
  if [ -f "${wt_a_agents}/testteam_alpha_engineer_persona.md" ] && \
     [ -f "${wt_b_agents}/testteam_alpha_engineer_persona.md" ] && \
     [ "$t15_rc" -eq 0 ]; then
    _pass "Test 15 (--all backfill: both worktrees got personas, exit 0)"
  else
    _fail "Test 15 — --all backfill: missing persona files or bad rc=${t15_rc}. out: ${t15_out}"
  fi

  # -----------------------------------------------------------------------
  # Test 16: --all with no linked worktrees → benign no-op
  # -----------------------------------------------------------------------
  printf '[selftest] Test 16: --all backfill: no worktrees → benign no-op...\n'
  local nolink_main="${tmp}/nolink-main"
  mkdir -p "$nolink_main"
  git -C "$nolink_main" init -q
  git -C "$nolink_main" commit -q --allow-empty -m "init"
  # No 'git worktree add' calls — no linked worktrees

  local t16_out t16_rc=0
  t16_out=$(AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_all "testteam" "$nolink_main" 2>&1) || t16_rc=$?
  if [ "$t16_rc" -eq 0 ]; then
    _pass "Test 16 (--all backfill: no linked worktrees → benign no-op, exit 0)"
  else
    _fail "Test 16 — expected exit 0 with no worktrees, got rc=${t16_rc}: ${t16_out}"
  fi

  # -----------------------------------------------------------------------
  # Test 17: --all backfill with a CONTAINER path (single inner git repo)
  # The container dir itself is NOT a git repo; the inner repo has 2 worktrees.
  # Pre-fix code would call `git worktree list` on the container and find nothing.
  # -----------------------------------------------------------------------
  printf '[selftest] Test 17: --all backfill: container path with one inner git repo...\n'
  local ctr_base="${tmp}/container-single"
  local ctr_inner="${ctr_base}/DEV"
  local ctr_wt_a="${ctr_base}/worktrees/feature-c1"
  local ctr_wt_b="${ctr_base}/worktrees/feature-c2"
  mkdir -p "$ctr_inner" "$ctr_wt_a" "$ctr_wt_b"
  git -C "$ctr_inner" init -q
  git -C "$ctr_inner" commit -q --allow-empty -m "init"
  git -C "$ctr_inner" worktree add -q "$ctr_wt_a" -b selftest-ctr-c1 2>/dev/null
  git -C "$ctr_inner" worktree add -q "$ctr_wt_b" -b selftest-ctr-c2 2>/dev/null

  local t17_out t17_rc=0
  t17_out=$(AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_all "testteam" "$ctr_base" 2>&1) || t17_rc=$?

  if [ -f "${ctr_wt_a}/.claude/agents/testteam_alpha_engineer_persona.md" ] && \
     [ -f "${ctr_wt_b}/.claude/agents/testteam_alpha_engineer_persona.md" ] && \
     [ "$t17_rc" -eq 0 ]; then
    _pass "Test 17 (--all backfill: container→inner-git: both worktrees got personas)"
  else
    _fail "Test 17 — container backfill failed. rc=${t17_rc} wt_a=$(ls ${ctr_wt_a}/.claude/agents/ 2>/dev/null || echo MISSING) wt_b=$(ls ${ctr_wt_b}/.claude/agents/ 2>/dev/null || echo MISSING). out: ${t17_out}"
  fi

  # -----------------------------------------------------------------------
  # Test 18: --all backfill with a CONTAINER path holding TWO inner git repos
  # (DNS-style umbrella topology). Each inner repo has one worktree; both
  # worktrees (2 total, 1 per inner repo) should receive personas.
  # -----------------------------------------------------------------------
  printf '[selftest] Test 18: --all backfill: container path with two inner git repos (DNS topology)...\n'
  local dns_base="${tmp}/container-dns"
  local dns_repo_a="${dns_base}/DNSProtocols"
  local dns_repo_b="${dns_base}/DNSCore"
  local dns_wt_a1="${dns_base}/worktrees/proto-feat1"
  local dns_wt_b1="${dns_base}/worktrees/core-feat1"
  mkdir -p "$dns_repo_a" "$dns_repo_b" "$dns_wt_a1" "$dns_wt_b1"
  git -C "$dns_repo_a" init -q
  git -C "$dns_repo_a" commit -q --allow-empty -m "init"
  git -C "$dns_repo_a" worktree add -q "$dns_wt_a1" -b selftest-dns-a1 2>/dev/null
  git -C "$dns_repo_b" init -q
  git -C "$dns_repo_b" commit -q --allow-empty -m "init"
  git -C "$dns_repo_b" worktree add -q "$dns_wt_b1" -b selftest-dns-b1 2>/dev/null

  local t18_out t18_rc=0
  t18_out=$(AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_all "testteam" "$dns_base" 2>&1) || t18_rc=$?

  if [ -f "${dns_wt_a1}/.claude/agents/testteam_alpha_engineer_persona.md" ] && \
     [ -f "${dns_wt_b1}/.claude/agents/testteam_alpha_engineer_persona.md" ] && \
     [ "$t18_rc" -eq 0 ]; then
    _pass "Test 18 (--all backfill: DNS container with 2 inner repos: all worktrees got personas)"
  else
    _fail "Test 18 — DNS backfill failed. rc=${t18_rc} a1=$(ls ${dns_wt_a1}/.claude/agents/ 2>/dev/null || echo MISSING) b1=$(ls ${dns_wt_b1}/.claude/agents/ 2>/dev/null || echo MISSING). out: ${t18_out}"
  fi

  # -----------------------------------------------------------------------
  # Test 19: --all backfill with a CONTAINER that has NO inner git repos
  # Should warn and return 0 (benign no-op, not an error).
  # -----------------------------------------------------------------------
  printf '[selftest] Test 19: --all backfill: container with no inner git repos → benign warn + exit 0...\n'
  local empty_ctr="${tmp}/container-empty"
  mkdir -p "${empty_ctr}/subdir-notgit"

  local t19_out t19_rc=0
  t19_out=$(AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_all "testteam" "$empty_ctr" 2>&1) || t19_rc=$?

  if [ "$t19_rc" -eq 0 ] && printf '%s\n' "$t19_out" | grep -qi "not a git repo\|no inner git"; then
    _pass "Test 19 (--all backfill: empty container → benign warn + exit 0)"
  else
    _fail "Test 19 — expected warn + exit 0 for empty container, got rc=${t19_rc}: ${t19_out}"
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
