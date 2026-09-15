#!/usr/bin/env bash
# deploy-worktree-personas.sh — Deploy tap-installed personas into a worktree's .claude/agents/
# Part of XACA-0588: tap-machine worktree persona deployment (installer-driven).
#
# Usage:
#   deploy-worktree-personas.sh <worktree_path> <team> [--dry-run] [--force] [--verbose]
#   deploy-worktree-personas.sh --all <team> [<main_repo_path>] [--dry-run] [--force] [--verbose]
#   deploy-worktree-personas.sh --nested-main-root <project_dir> <team> [--dry-run] [--force] [--verbose]
#   deploy-worktree-personas.sh --flat-dir <target_dir> <team> [--dry-run] [--force] [--verbose]
#   deploy-worktree-personas.sh --verify-flat-dir <target_dir> <team>
#   deploy-worktree-personas.sh emit-transformed <src_file> [<char_name>]
#   deploy-worktree-personas.sh selftest
#
# --flat-dir (XACA-1216): deploy into <target_dir>/.claude/agents/ of a NON-GIT
#   team working dir (e.g. ~/.aiteamforge/spacedock on a tap consumer). Never
#   runs `git init`, never writes .git/info/exclude, never writes outside
#   <target_dir>/.claude/agents/. REFUSES (rc 4) any target inside a git work
#   tree -- those belong to the git-aware modes. Validation order: team id ->
#   target (exists, not / or $HOME, no .claude symlink escape) -> git refusal
#   -> source -> deploy -> prune. Callers should always pass --force.
#   Prune: a file is deleted ONLY if it is listed as `deployed_file:` in the
#   PRIOR .synced-from-tap marker, is absent from the current source, AND its
#   basename matches ^<team>_[^/]*_persona\.md$. Everything else is reported
#   `ORPHAN (not ours — left in place)`. Dotfiles are never touched.
#   Design: kanban/plans/XACA-1216/XACA-1216-design.md §1-§3.
#
# --verify-flat-dir (XACA-1216-018/019): READ-ONLY. Recomputes each source
#   persona's deployed bytes through the same render the deploy writes with and
#   compares the target's copies: rc 0 all present + matching, rc 5 any
#   MISSING/STALE (listed on stdout). Never reads the marker, never writes.
#   The single post-deploy evidence check for install, startup and upgrade.
#   Exit codes: see the table above _verify_flat_dir.
#
# emit-transformed (XACA-0931-003): read-only. Prints to stdout the EXACT
# transform _deploy_core would write for <src_file> -- the single authority
# aiteamforge-persona-parity-check.sh's deployed-vs-source surface compares
# against, so nothing outside this file reimplements the `name:` frontmatter
# rewrite. Never deploys, never writes.
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
# --flat-dir exit codes (0-2 keep their meaning; 3 and 4 exist ONLY in this mode):
#   0 — deployed/refreshed; also --dry-run, already-deployed without --force,
#       and DEFERRED on a dev machine (primary source absent, agents-master present)
#   1 — guard/usage failure: bad team id (^[A-Za-z0-9_-]+$), target missing or
#       not a dir, canonicalization failure, target is / or canonical $HOME,
#       .claude or .claude/agents (or a destination file/marker) is a symlink
#   2 — write/copy/prune failure, OR a partial deploy (any file skipped by the
#       transform) -- a partial deploy never prunes
#   3 — no persona source: primary dir absent (and no dev-machine deferral), or
#       it holds 0 *.md files. The other modes' warn+exit-0 path is NOT used.
#   4 — REFUSED, git territory: target is inside a git work tree (rev-parse
#       with GIT_* unset says so, OR a structural walk to / finds a .git entry)
#
# Canonical source: dev-team/scripts/deploy-worktree-personas.sh
# Tap mirror:       homebrew-tap/share/scripts/deploy-worktree-personas.sh (via sync-tap)
# SIBLING-DRIFT NOTE: this script is mirrored to homebrew-tap/share/scripts/ by sync-tap.sh.
# Any change here MUST be followed by sync-tap.sh to keep the tap copy current.

set -euo pipefail

PROG="deploy-worktree-personas"

# XACA-1216: additive side-channel out of _deploy_core / into _write_marker.
# _DWP_DEPLOYED_FILES — basenames _deploy_core actually wrote this run.
# _DWP_SKIPPED        — count of files _deploy_core skipped (transform error).
# _DWP_MARKER_MODE    — when non-empty, _write_marker emits `mode: <value>`.
# No existing mode reads these; they only add marker lines.
_DWP_DEPLOYED_FILES=()
_DWP_SKIPPED=0
_DWP_MARKER_MODE=""

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
# _dwp_render <src_file> <char_name> <action> [<path>]
#
# THE single definition of the bytes a deploy writes for one persona
# (XACA-1216-019). _deploy_core writes through it, emit-transformed prints
# through it, and --verify-flat-dir compares through it -- so "what a correct
# deployed file looks like" cannot drift between the writer and its checkers.
#   transform rc 0 (name: rewritten) or 3 (no name: in frontmatter)
#       -> printf '%s\n' of the transform output. Command substitution strips
#          trailing newlines; the printf restores exactly one.
#   transform rc 2 (no frontmatter) -> the source bytes verbatim (cp).
#   any other transform rc          -> nothing (transform failure).
# Actions: write <path>  |  emit (stdout)  |  cmp <path> (read-only)
# Sets _DWP_RENDER_TRC to the transform rc.
# Returns: 0 written / emitted / identical
#          1 cmp only: <path> differs from the expected bytes, or is unreadable
#          2 transform failure (nothing written or emitted)
#          3 write failure
# ---------------------------------------------------------------------------
_DWP_RENDER_TRC=0
_dwp_render() {
  local src="$1" char="$2" action="$3" path="${4:-}"
  local out="" trc=0
  out=$(_transform_persona "$src" "$char") || trc=$?
  _DWP_RENDER_TRC=$trc
  case "$trc" in
    0|3)
      case "$action" in
        write) printf '%s\n' "$out" > "$path" || return 3 ;;
        emit)  printf '%s\n' "$out" ;;
        cmp)   cmp -s "$path" <(printf '%s\n' "$out") || return 1 ;;
        *)     return 2 ;;
      esac
      ;;
    2)
      case "$action" in
        write) cp "$src" "$path" || return 3 ;;
        emit)  cat "$src" ;;
        cmp)   cmp -s "$path" "$src" || return 1 ;;
        *)     return 2 ;;
      esac
      ;;
    *)
      return 2
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Write .claude/agents/ into <project>/.git/info/exclude (idempotent).
# Mirrors the pattern in kb-sync-personas _kbsp_sync_worktrees (XACA-0660).
# Resolves exclude path via git-common-dir so it is shared across all
# worktrees of the same repo.
# Arguments: git_root  dry_run("true"|"false")
# ---------------------------------------------------------------------------

_write_exclude() {
  local git_root="$1"
  local dry_run="${2:-false}"

  local exclude_line=".claude/agents/"
  local common_dir_rel
  common_dir_rel=$(git -C "$git_root" rev-parse --git-common-dir 2>/dev/null) || common_dir_rel=""

  if [ -z "$common_dir_rel" ]; then
    _warn "[exclude] could not resolve git-common-dir for ${git_root} — skipping exclude update"
    return 0
  fi

  local exclude_file="${git_root}/${common_dir_rel}/info/exclude"

  if [ "$dry_run" = "true" ]; then
    if grep -qxF "$exclude_line" "$exclude_file" 2>/dev/null; then
      _info "[exclude] '${exclude_line}' already present in $(basename "$git_root")/.git/info/exclude"
    else
      _info "[exclude] (DRY RUN) would add '${exclude_line}' to $(basename "$git_root")/.git/info/exclude"
    fi
    return 0
  fi

  mkdir -p "$(dirname "$exclude_file")"
  if ! grep -qxF "$exclude_line" "$exclude_file" 2>/dev/null; then
    printf '# Academy persona deployment (untracked, ephemeral) — XACA infra\n%s\n' \
      "$exclude_line" >> "$exclude_file"
    _info "[exclude] added '${exclude_line}' to $(basename "$git_root")/.git/info/exclude"
  else
    _verbose "[exclude] '${exclude_line}' already present in $(basename "$git_root")/.git/info/exclude"
  fi
  return 0
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

  local df
  {
    printf 'synced_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'team: %s\n' "$team"
    printf 'source_path: %s\n' "$source_path"
    printf 'aiteamforge_dir: %s\n' "$aiteamforge_dir"
    # XACA-1216: additive keys. `mode:` only when a mode sets it (flat-dir);
    # one `deployed_file:` line per file written -- line-per-entry so the
    # prune reader stays bash-3.2-safe with plain read/case. No reader of the
    # four keys above is affected.
    if [ -n "${_DWP_MARKER_MODE:-}" ]; then
      printf 'mode: %s\n' "$_DWP_MARKER_MODE"
    fi
    for df in ${_DWP_DEPLOYED_FILES[@]+"${_DWP_DEPLOYED_FILES[@]}"}; do
      printf 'deployed_file: %s\n' "$df"
    done
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

  # XACA-1216: reset the additive side-channel before ANY return path so a
  # caller never reads a previous call's list (e.g. _deploy_all's loop).
  _DWP_DEPLOYED_FILES=()
  _DWP_SKIPPED=0

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

    # Transform + write through _dwp_render (XACA-1216-019): the same bytes
    # emit-transformed prints and --verify-flat-dir compares against.
    local render_rc=0
    _dwp_render "$src_file" "$char_name" write "$dest_file" || render_rc=$?

    case "$render_rc" in
      0) ;;
      2)
        _warn "[${team}] ${bname}: transform error (rc=${_DWP_RENDER_TRC}) — skipping"
        skipped=$((skipped + 1))
        continue
        ;;
      *)
        if [ "$_DWP_RENDER_TRC" = "2" ]; then
          _err "[${team}] Failed to copy: ${dest_file}"
        else
          _err "[${team}] Failed to write: ${dest_file}"
        fi
        return 2
        ;;
    esac

    case "$_DWP_RENDER_TRC" in
      0)
        # Success — get old name for logging
        local old_name
        old_name=$(awk '/^---/{f++} f==1 && /^name[[:space:]]*:/{print; exit}' "$src_file" | sed 's/^name[[:space:]]*:[[:space:]]*//')
        _info "[${team}] transform+copy ${bname} (name: ${old_name} → ${char_name})"
        ;;
      2)
        _warn "[${team}] ${bname}: no YAML frontmatter — copying verbatim"
        ;;
      3)
        _warn "[${team}] ${bname}: no 'name:' in frontmatter — copying verbatim"
        ;;
    esac
    deployed=$((deployed + 1))
    _DWP_DEPLOYED_FILES+=("$bname")
  done
  _DWP_SKIPPED=$skipped

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
# Nested-main-root deployment (XACA-0667): deploy tap personas into a nested
# git repo (i.e. the inner git root itself, not a linked worktree of it).
#
# Use case: legal/finance/medical teams on a tap-consumer box where each
# session starts inside ~/<team>/<PROJECTID> — the inner git repo — and
# kb-sync-personas is not available. This function closes the gap that the
# original _deploy_all NOTE (XACA-0660 k501-sibling-drift) deferred to
# kb-sync-personas, by deploying directly from the tap persona source.
#
# Guard semantics: target must be a real git repo root (not a linked
# worktree). We verify via `git rev-parse --show-toplevel` and confirm
# the canonical result equals the provided project_dir. Path traversal
# is defeated by _canon_path + git's own toplevel resolution.
#
# Also writes .claude/agents/ to the repo's .git/info/exclude so deployed
# personas stay untracked (invisible to git status), mirroring the pattern
# in kb-sync-personas _kbsp_sync_worktrees.
#
# Arguments: project_dir team
# Returns: 0 success/no-op, 1 guard failure, 2 write failure
# ---------------------------------------------------------------------------

_deploy_nested_main_root() {
  local project_dir="$1"
  local team="$2"

  # --- Resolve source directory (same logic as _deploy) ---
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

  # --- Validate project_dir is a real git repo root ---
  # Canonicalize the provided path first.
  local canon_project
  canon_project=$(_canon_path "$project_dir") || {
    _err "[${team}] Cannot canonicalize project dir: ${project_dir}"
    return 1
  }

  if [ ! -d "$canon_project" ]; then
    _err "[${team}] Project dir does not exist: ${canon_project}"
    return 1
  fi

  # Confirm it is a git repo and resolve its toplevel.
  local git_toplevel
  git_toplevel=$(git -C "$canon_project" rev-parse --show-toplevel 2>/dev/null) || {
    _err "[${team}] Not a git repo: ${canon_project}"
    return 1
  }

  local canon_toplevel
  canon_toplevel=$(_canon_path "$git_toplevel") || {
    _err "[${team}] Cannot canonicalize git toplevel: ${git_toplevel}"
    return 1
  }

  # The project_dir must resolve to exactly the git repo's toplevel.
  # This prevents a path that is merely INSIDE a repo (traversal safety).
  if [ "$canon_project" != "$canon_toplevel" ]; then
    _err "[${team}] project_dir (${canon_project}) is inside a git repo but is not its root (${canon_toplevel}). Pass the repo root."
    return 1
  fi

  # Confirm it is not a linked worktree (those go through _deploy, not this function).
  # A linked worktree has a .git FILE (not dir); the main/main-root has a .git DIR.
  # Also reject paths whose git-common-dir resolves into a different main repo
  # (i.e. this IS a linked worktree of some other repo).
  local git_dir_entry="${canon_project}/.git"
  if [ ! -d "$git_dir_entry" ] && [ -f "$git_dir_entry" ]; then
    _err "[${team}] ${canon_project} appears to be a linked worktree (has .git FILE not dir). Use single-worktree mode instead."
    return 1
  fi

  # --- Build the canonical target path ---
  local canon_target="${canon_project}/.claude/agents"

  # --- Write .git/info/exclude entry (idempotent) ---
  _write_exclude "$canon_project" "${OPT_DRY_RUN:-false}" || true

  # --- Deploy personas via shared core ---
  _deploy_core "$canon_target" "$team" "$primary_src" "$aiteamforge_dir"
}

# ---------------------------------------------------------------------------
# Flat-dir deployment (XACA-1216): deploy tap personas into
# <target_dir>/.claude/agents/ of a NON-GIT team working dir.
#
# Why a separate mode rather than a fallback inside --nested-main-root: that
# mode's contract is "must be a git root". Keying a fallback on "rev-parse
# failed" would turn every misclassification (dubious ownership, git missing,
# GIT_DIR leak) from a refusal into a write. This mode inverts it: it REFUSES
# git territory (rc 4) and only ever writes into a dir proven non-git.
#
# Validation order (design §1) -- target checks come first, so a git repo
# gets rc 4 even on a dev machine:
#   1 team id  2 target  3 git refusal  4 source  5 prior marker
#   6 _deploy_core  7 skipped>0 -> rc 2, no prune  8 prune + marker rewrite
#
# The wrapper exists so _DWP_MARKER_MODE is reset on EVERY return path. Note
# that `|| rc=$?` disables errexit inside the impl; the impl therefore checks
# every command explicitly and behaves identically from the CLI and selftest.
#
# Arguments: target_dir team
# Returns: 0/1/2/3/4 per the --flat-dir exit-code table in the header.
# ---------------------------------------------------------------------------

# Newline-delimited list membership (bash 3.2: no associative arrays).
# Arguments: list(each entry newline-terminated) item
_dwp_in_list() {
  case $'\n'"$1" in
    *$'\n'"$2"$'\n'*) return 0 ;;
  esac
  return 1
}

# Is <basename> a name this mode is allowed to have written, and therefore to
# prune? ^<team>_[^/]*_persona\.md$ -- plus: no '/', not a dotfile.
_dwp_flat_owned_name_ok() {
  local team="$1"
  local b="$2"
  case "$b" in
    ''|*/*|.*) return 1 ;;
  esac
  case "$b" in
    "${team}"_*_persona.md) return 0 ;;
  esac
  return 1
}

_deploy_flat_dir() {
  local rc=0
  _deploy_flat_dir_impl "$@" || rc=$?
  _DWP_MARKER_MODE=""
  return "$rc"
}

# ---------------------------------------------------------------------------
# _dwp_flat_target_guard <target> <team> <label>
#
# Steps 1-3 of the flat-dir contract, shared by --flat-dir (deploy) and
# --verify-flat-dir (read-only check) so the two can never disagree about what
# a valid flat-dir target is (XACA-1216-019). <label> is the CLI mode name
# used in messages ("--flat-dir" / "--verify-flat-dir").
# On rc 0 sets _DWP_FLAT_CANON (canonical target) and _DWP_FLAT_AGENTS
# (<canon>/.claude/agents). Writes nothing.
# Returns: 0 ok · 1 guard refusal · 4 git territory
# ---------------------------------------------------------------------------
_DWP_FLAT_CANON=""
_DWP_FLAT_AGENTS=""
_dwp_flat_target_guard() {
  local target="$1"
  local team="$2"
  local label="$3"
  _DWP_FLAT_CANON=""
  _DWP_FLAT_AGENTS=""

  # --- 1. Team id ---
  local team_re='^[A-Za-z0-9_-]+$'
  if ! [[ "$team" =~ $team_re ]]; then
    _err "[${label#--}] invalid team id '${team}' (must match ${team_re})"
    return 1
  fi

  # --- 2. Target ---
  if [ -z "$target" ]; then
    _err "[${team}] ${label}: empty target_dir"
    return 1
  fi
  local canon=""
  canon=$(_canon_path "$target") || canon=""
  if [ -z "$canon" ]; then
    _err "[${team}] ${label}: cannot canonicalize target: ${target}"
    return 1
  fi
  if [ ! -d "$canon" ]; then
    _err "[${team}] ${label}: target does not exist or is not a directory: ${canon}"
    return 1
  fi
  if [ "$canon" = "/" ]; then
    _err "[${team}] ${label}: refusing target '/'"
    return 1
  fi
  # Target == $HOME would deploy into USER-LEVEL ~/.claude/agents, leaking the
  # crew into every session on the machine. Compare canonical AND literal so a
  # canonicalization failure on $HOME cannot open this guard.
  if [ -n "${HOME:-}" ]; then
    local canon_home=""
    canon_home=$(_canon_path "$HOME") || canon_home=""
    if [ "$canon" = "$HOME" ] || { [ -n "$canon_home" ] && [ "$canon" = "$canon_home" ]; }; then
      _err "[${team}] ${label}: refusing target == \$HOME (${canon}) — that is user-level ~/.claude/agents"
      return 1
    fi
  fi
  local canon_target="${canon}/.claude/agents"
  # Symlink escape. Any symlink at .claude or .claude/agents necessarily
  # resolves outside <canon>/.claude/agents (the only way to resolve back to it
  # is a self-loop), so -L alone is decisive; the realpath comparison is kept
  # as a second, independent signal. -L also catches DANGLING links, which the
  # non-python _canon_path fallback would silently walk past.
  local resolved_target=""
  resolved_target=$(_canon_path "$canon_target") || resolved_target=""
  if [ -L "${canon}/.claude" ] || [ -L "$canon_target" ] || [ "$resolved_target" != "$canon_target" ]; then
    _err "[${team}] ${label}: .claude or .claude/agents is a symlink resolving outside ${canon_target} (resolves to: ${resolved_target:-<unresolvable>})"
    return 1
  fi

  # --- 3. Git refusal: BOTH signals run; either one refuses ---
  local git_why=""
  # (i) rev-parse with the env that could redirect it scrubbed. A leaked
  # GIT_DIR makes rev-parse print `true` for a plain non-git dir (measured),
  # and GIT_CEILING_DIRECTORIES can hide a real ancestor repo.
  if command -v git >/dev/null 2>&1; then
    local rp_out=""
    rp_out=$(unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_CEILING_DIRECTORIES
             git -C "$canon" rev-parse --is-inside-work-tree 2>/dev/null) || rp_out=""
    if [ "$rp_out" = "true" ]; then
      local rp_top=""
      rp_top=$(unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_CEILING_DIRECTORIES
               git -C "$canon" rev-parse --show-toplevel 2>/dev/null) || rp_top=""
      git_why="git rev-parse reports a work tree (toplevel: ${rp_top:-<unknown>})"
    fi
  fi
  # (ii) Structural walk to / for a .git entry (file or dir). Covers git
  # missing, "dubious ownership" making rev-parse fail over a real repo, and a
  # bare `.git` dir git itself does not recognise. An unsearchable ancestor
  # cannot be ruled out, so it refuses too (fail closed).
  local walk="$canon"
  while :; do
    if [ ! -x "$walk" ]; then
      git_why="${git_why:+${git_why}; }cannot search ${walk} to rule out a .git entry"
      break
    fi
    if [ -e "${walk}/.git" ] || [ -L "${walk}/.git" ]; then
      git_why="${git_why:+${git_why}; }.git entry found at ${walk}/.git"
      break
    fi
    if [ "$walk" = "/" ]; then
      break
    fi
    walk=$(dirname "$walk")
  done
  if [ -n "$git_why" ]; then
    _err "[${team}] ${label}: REFUSED (git territory) for ${canon}: ${git_why}. Use the git-aware modes (<worktree>, --all, --nested-main-root)."
    return 4
  fi

  _DWP_FLAT_CANON="$canon"
  _DWP_FLAT_AGENTS="$canon_target"
  return 0
}

_deploy_flat_dir_impl() {
  local target="$1"
  local team="$2"
  local dry="${OPT_DRY_RUN:-false}"

  # --- 1-3. Team id, target, git refusal (shared with --verify-flat-dir) ---
  local guard_rc=0
  _dwp_flat_target_guard "$target" "$team" "--flat-dir" || guard_rc=$?
  if [ "$guard_rc" -ne 0 ]; then
    return "$guard_rc"
  fi
  local canon="$_DWP_FLAT_CANON"
  local canon_target="$_DWP_FLAT_AGENTS"

  # --- 4. Source ---
  local aiteamforge_dir="${AITEAMFORGE_DIR:-${HOME:-}/aiteamforge}"
  local primary_src="${aiteamforge_dir}/${team}/personas/agents"
  local devmachine_fallback="${HOME:-}/dev-team/.claude/agents-master/${team}"
  if [ ! -d "$primary_src" ]; then
    if [ -n "${HOME:-}" ] && [ -d "$devmachine_fallback" ]; then
      _info "[${team}] DEFERRED: dev machine — kb-sync-personas owns this target (${canon})"
      return 0
    fi
    _err "[${team}] --flat-dir: no persona source at ${primary_src}"
    return 3
  fi
  local src_names=""
  local src_count=0
  local f b
  while IFS= read -r -d '' f; do
    b="${f##*/}"
    src_names="${src_names}${b}"$'\n'
    src_count=$((src_count + 1))
  done < <(find "$primary_src" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null | sort -z)
  if [ "$src_count" -eq 0 ]; then
    _err "[${team}] --flat-dir: persona source has 0 *.md files: ${primary_src}"
    return 3
  fi

  # --- 5. Prior marker's ownership set (read BEFORE _deploy_core rewrites it) ---
  local marker="${canon_target}/.synced-from-tap"
  if [ -L "$marker" ]; then
    _err "[${team}] --flat-dir: marker is a symlink, refusing to write through it: ${marker}"
    return 1
  fi
  local prior_owned=""
  local line pb
  if [ -f "$marker" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        'deployed_file: '*) pb="${line#deployed_file: }" ;;
        *) continue ;;
      esac
      if _dwp_flat_owned_name_ok "$team" "$pb" && ! _dwp_in_list "$prior_owned" "$pb"; then
        prior_owned="${prior_owned}${pb}"$'\n'
      fi
    done < "$marker"
  fi
  # A destination that is a symlink would make _deploy_core write THROUGH it,
  # outside .claude/agents. Refuse rather than follow.
  while IFS= read -r b; do
    if [ -n "$b" ] && [ -L "${canon_target}/${b}" ]; then
      _err "[${team}] --flat-dir: destination is a symlink, refusing to write through it: ${canon_target}/${b}"
      return 1
    fi
  done <<SRC_EOF
$src_names
SRC_EOF

  # --- 6. Deploy via the shared core ---
  if [ "${OPT_FORCE:-false}" != "true" ] && [ -f "$marker" ]; then
    # Already-deployed no-op: core writes nothing, so neither prune nor rewrite
    # the marker (that would drop the ownership list).
    _deploy_core "$canon_target" "$team" "$primary_src" "$aiteamforge_dir" || return 2
    return 0
  fi
  _DWP_MARKER_MODE="flat-dir"
  local core_rc=0
  _deploy_core "$canon_target" "$team" "$primary_src" "$aiteamforge_dir" || core_rc=$?
  if [ "$core_rc" -ne 0 ]; then
    _err "[${team}] --flat-dir: deploy failed (core rc=${core_rc}) — not pruning"
    return 2
  fi

  # --- 7. Partial deploy is a failure in this mode ---
  local partial=false
  if [ "${_DWP_SKIPPED:-0}" -gt 0 ]; then
    partial=true
    _err "[${team}] --flat-dir: partial deploy — ${_DWP_SKIPPED} file(s) skipped; NOT pruning"
  fi

  # --- 8. Prune (design §2) ---
  local pruned=0
  local prune_fail=0
  if [ "$partial" != true ]; then
    while IFS= read -r pb; do
      if [ -z "$pb" ] || _dwp_in_list "$src_names" "$pb"; then
        continue
      fi
      if [ ! -e "${canon_target}/${pb}" ] && [ ! -L "${canon_target}/${pb}" ]; then
        continue
      fi
      # Re-assert the invariant at the point of deletion, not just at parse.
      if ! _dwp_flat_owned_name_ok "$team" "$pb"; then
        continue
      fi
      if [ "$dry" = "true" ]; then
        _info "[${team}] WOULD PRUNE ${pb} (listed in prior marker, absent from source)"
      elif rm -f -- "${canon_target}/${pb}"; then
        _info "[${team}] PRUNED ${pb} (listed in prior marker, absent from source)"
        pruned=$((pruned + 1))
      else
        _err "[${team}] --flat-dir: failed to prune ${canon_target}/${pb}"
        prune_fail=$((prune_fail + 1))
      fi
    done <<PRIOR_EOF
$prior_owned
PRIOR_EOF
  fi

  # Orphans: *.md in the target that is neither in source nor ours by marker.
  local orphans=0
  if [ -d "$canon_target" ]; then
    while IFS= read -r -d '' f; do
      b="${f##*/}"
      if _dwp_in_list "$src_names" "$b" || _dwp_in_list "$prior_owned" "$b"; then
        continue
      fi
      _info "[${team}] ORPHAN (not ours — left in place): ${b}"
      orphans=$((orphans + 1))
    done < <(find "$canon_target" -maxdepth 1 -name '*.md' ! -name '.*' -print0 2>/dev/null | sort -z)
  fi

  # Marker rewrite. Ownership = files written this run PLUS prior-owned files
  # that still exist (skipped on a partial deploy, or a failed prune) -- so a
  # file we wrote never silently becomes an unowned ORPHAN that can no longer
  # be pruned once its source is gone.
  if [ "$dry" != "true" ]; then
    local final_list=""
    local df
    for df in ${_DWP_DEPLOYED_FILES[@]+"${_DWP_DEPLOYED_FILES[@]}"}; do
      if ! _dwp_in_list "$final_list" "$df"; then
        final_list="${final_list}${df}"$'\n'
      fi
    done
    while IFS= read -r pb; do
      if [ -n "$pb" ] && ! _dwp_in_list "$final_list" "$pb" \
         && { [ -e "${canon_target}/${pb}" ] || [ -L "${canon_target}/${pb}" ]; }; then
        final_list="${final_list}${pb}"$'\n'
      fi
    done <<OWN_EOF
$prior_owned
OWN_EOF
    _DWP_DEPLOYED_FILES=()
    while IFS= read -r df; do
      if [ -n "$df" ]; then
        _DWP_DEPLOYED_FILES+=("$df")
      fi
    done <<FINAL_EOF
$final_list
FINAL_EOF
    if ! _write_marker "$canon_target" "$team" "$primary_src" "$aiteamforge_dir"; then
      _err "[${team}] --flat-dir: failed to rewrite marker at ${marker}"
      return 2
    fi
  fi

  _info "[${team}] flat-dir: ${pruned} pruned, ${orphans} orphan(s) left in place."
  if [ "$partial" = true ] || [ "$prune_fail" -gt 0 ]; then
    return 2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# --verify-flat-dir <target_dir> <team>   (XACA-1216-018/019)
#
# READ-ONLY content verification of a flat-dir deploy, and the ONE evidence
# check install-team.sh, the rendered team startup ("Personas" health row) and
# aiteamforge upgrade all call after a deploy exits 0. A deploy's rc 0 is the
# deployer's claim; this is the evidence.
#
# For every source *.md in ${AITEAMFORGE_DIR}/<team>/personas/agents it
# recomputes the expected deployed bytes FROM THE SOURCE through _dwp_render
# (the function _deploy_core writes with, same char_name derivation) and
# compares <target_dir>/.claude/agents/<basename> against them. A no-op or
# stubbed deploy step cannot fake this: the expectation never comes from
# anything the deploy step produced.
#   * Never consults .synced-from-tap -- the marker is the deployer's own claim.
#   * Never writes anything, anywhere (no mkdir, no temp files).
#   * Extra files in the target (orphans, notes) are not its concern.
#   * No dev-machine DEFERRED: an absent source is rc 3, never a pass.
#
# Output: rc 0 -> one "verified:" line on stdout. rc 5 -> one line per bad
# file on stdout ("MISSING <basename>" / "STALE <basename>[ (reason)]"), then a
# "verify:" summary line. Guard/source/transform errors go to stderr.
#
# Exit codes (1, 3, 4 mean exactly what they mean for --flat-dir):
#   0 — every source persona present in the target with the expected content
#   1 — guard/usage refusal (same guards as --flat-dir: bad team id, target
#       missing or not a dir, target is / or $HOME, .claude symlink escape)
#   2 — expected content could not be computed (transform failed, e.g.
#       python3 unavailable) -- UNINSPECTABLE, never a pass
#   3 — no persona source (primary dir absent, or 0 *.md files)
#   4 — target is inside a git work tree (flat-dir never deploys there)
#   5 — at least one persona MISSING or STALE
# ---------------------------------------------------------------------------
_verify_flat_dir() {
  local target="$1"
  local team="$2"

  local guard_rc=0
  _dwp_flat_target_guard "$target" "$team" "--verify-flat-dir" || guard_rc=$?
  if [ "$guard_rc" -ne 0 ]; then
    return "$guard_rc"
  fi
  local agents="$_DWP_FLAT_AGENTS"

  local aiteamforge_dir="${AITEAMFORGE_DIR:-${HOME:-}/aiteamforge}"
  local primary_src="${aiteamforge_dir}/${team}/personas/agents"
  if [ ! -d "$primary_src" ]; then
    _err "[${team}] --verify-flat-dir: no persona source at ${primary_src} — nothing to verify against"
    return 3
  fi

  local total=0 missing=0 stale=0 uninspectable=0
  local f b char dest cmp_rc
  while IFS= read -r -d '' f; do
    b="${f##*/}"
    total=$((total + 1))
    dest="${agents}/${b}"
    if [ -L "$dest" ]; then
      # --flat-dir refuses to write through a symlinked destination, so a
      # symlink here was never written by it.
      printf 'STALE %s (symlink — not written by the deployer)\n' "$b"
      stale=$((stale + 1))
      continue
    fi
    if [ ! -f "$dest" ]; then
      printf 'MISSING %s\n' "$b"
      missing=$((missing + 1))
      continue
    fi
    char=$(_char_from_filename "$b")
    cmp_rc=0
    _dwp_render "$f" "$char" cmp "$dest" || cmp_rc=$?
    case "$cmp_rc" in
      0) ;;
      1)
        if [ -r "$dest" ]; then
          printf 'STALE %s\n' "$b"
        else
          printf 'STALE %s (unreadable)\n' "$b"
        fi
        stale=$((stale + 1))
        ;;
      *)
        _err "[${team}] --verify-flat-dir: could not compute the expected content of ${f} (transform rc=${_DWP_RENDER_TRC})"
        uninspectable=$((uninspectable + 1))
        ;;
    esac
  done < <(find "$primary_src" -maxdepth 1 -name '*.md' -type f -print0 2>/dev/null | sort -z)

  if [ "$total" -eq 0 ]; then
    _err "[${team}] --verify-flat-dir: persona source has 0 *.md files: ${primary_src}"
    return 3
  fi
  if [ "$uninspectable" -gt 0 ]; then
    _err "[${team}] --verify-flat-dir: ${uninspectable} of ${total} persona(s) uninspectable — NOT verified"
    return 2
  fi
  if [ $((missing + stale)) -gt 0 ]; then
    printf 'verify: %d of %d persona(s) do not match the source in %s (%d missing, %d stale)\n' \
      "$((missing + stale))" "$total" "$agents" "$missing" "$stale"
    return 5
  fi
  printf 'verified: %d of %d persona(s) match the source in %s\n' "$total" "$total" "$agents"
  return 0
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
    # NOTE (XACA-0660 / XACA-0667 k501-sibling-drift): kb-sync-personas
    # sync-worktrees also deploys to the nested main git root itself when
    # git_root != container. That gap IS now replicated here via
    # _deploy_nested_main_root (XACA-0667), which reads from the tap persona
    # source (~aiteamforge/.../personas/agents/). The --all backfill mode
    # enumerates linked worktrees only; startup-time nested-root deploy for
    # legal/finance/medical runs via deploy_team_personas in
    # lcars-launch-helpers.sh (which calls --nested-main-root on tap machines).
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
  # Test 20: --nested-main-root happy path
  # Passing the real git repo root deploys personas into <root>/.claude/agents/,
  # writes .claude/agents/ into .git/info/exclude, and leaves git status clean
  # (deployed files are untracked, not staged).
  # -----------------------------------------------------------------------
  printf '[selftest] Test 20: --nested-main-root happy path: files deployed + exclude written + status clean...\n'
  local nmr_main="${tmp}/nmr-main"
  mkdir -p "$nmr_main"
  git -C "$nmr_main" init -q
  git -C "$nmr_main" commit -q --allow-empty -m "init"

  local t20_out t20_rc=0
  t20_out=$(AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_nested_main_root "$nmr_main" "testteam" 2>&1) || t20_rc=$?

  local t20_alpha="${nmr_main}/.claude/agents/testteam_alpha_engineer_persona.md"
  local t20_exclude="${nmr_main}/.git/info/exclude"
  local t20_status
  t20_status=$(git -C "$nmr_main" status --porcelain 2>/dev/null) || t20_status=""

  if [ "$t20_rc" -eq 0 ] \
     && [ -f "$t20_alpha" ] \
     && grep -qxF ".claude/agents/" "$t20_exclude" 2>/dev/null \
     && [ -z "$t20_status" ]; then
    _pass "Test 20 (--nested-main-root happy path: files present + exclude written + status clean)"
  else
    _fail "Test 20 — rc=${t20_rc} alpha=$([ -f "$t20_alpha" ] && echo present || echo MISSING) exclude=$(grep -qxF '.claude/agents/' "$t20_exclude" 2>/dev/null && echo present || echo MISSING) status='${t20_status}' out: ${t20_out}"
  fi

  # -----------------------------------------------------------------------
  # Test 21: --nested-main-root inside-repo reject
  # Passing a path that is INSIDE a git repo but NOT the repo root must be
  # rejected with non-zero exit (traversal / subdirectory safety).
  # -----------------------------------------------------------------------
  printf '[selftest] Test 21: --nested-main-root rejects path inside repo (not root)...\n'
  local nmr_subdir="${nmr_main}/subdir"
  mkdir -p "$nmr_subdir"

  local t21_rc=0
  AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_nested_main_root "$nmr_subdir" "testteam" 2>/dev/null || t21_rc=$?

  if [ "$t21_rc" -ne 0 ]; then
    _pass "Test 21 (--nested-main-root rejects subdir-inside-repo, non-zero exit)"
  else
    _fail "Test 21 — expected non-zero exit for subdir inside repo, got rc=${t21_rc}"
  fi

  # -----------------------------------------------------------------------
  # Test 22: --nested-main-root linked-worktree reject
  # A linked worktree has a .git FILE not a dir; passing it must be rejected.
  # -----------------------------------------------------------------------
  printf '[selftest] Test 22: --nested-main-root rejects linked worktree (.git FILE)...\n'
  local nmr_wt="${nmr_main}/worktrees/feature-nmr"
  mkdir -p "$nmr_wt"
  git -C "$nmr_main" worktree add -q "$nmr_wt" -b selftest-nmr-wt 2>/dev/null

  local t22_rc=0
  AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=false OPT_VERBOSE=false \
    _deploy_nested_main_root "$nmr_wt" "testteam" 2>/dev/null || t22_rc=$?

  if [ "$t22_rc" -ne 0 ]; then
    _pass "Test 22 (--nested-main-root rejects linked worktree, non-zero exit)"
  else
    _fail "Test 22 — expected non-zero exit for linked worktree, got rc=${t22_rc}"
  fi

  # -----------------------------------------------------------------------
  # Test 23: --nested-main-root idempotent exclude
  # Running the deploy twice must NOT duplicate the .claude/agents/ line in
  # .git/info/exclude — exactly one occurrence after the second run.
  # -----------------------------------------------------------------------
  printf '[selftest] Test 23: --nested-main-root idempotent exclude (no duplicate lines)...\n'
  # nmr_main already has a deployment from Test 20; run again with --force to
  # exercise the exclude write path a second time.
  local t23_rc=0
  AITEAMFORGE_DIR="$fake_aitf" OPT_DRY_RUN=false OPT_FORCE=true OPT_VERBOSE=false \
    _deploy_nested_main_root "$nmr_main" "testteam" 2>/dev/null || t23_rc=$?

  local t23_count
  t23_count=$(grep -cxF ".claude/agents/" "${nmr_main}/.git/info/exclude" 2>/dev/null || true)

  if [ "$t23_rc" -eq 0 ] && [ "$t23_count" -eq 1 ]; then
    _pass "Test 23 (--nested-main-root idempotent exclude: exactly 1 occurrence after 2nd run)"
  else
    _fail "Test 23 — rc=${t23_rc} expected 1 occurrence in exclude, got ${t23_count}"
  fi

  # =======================================================================
  # --flat-dir (XACA-1216) — Tests 24-38.
  #
  # Every case runs the CLI as a SUBPROCESS ("$BASH" <subject> --flat-dir ...)
  # so exit codes are the real ones main() produces under set -e, and the
  # selftest's own interpreter is the one under test (/bin/bash 3.2 or 5.x).
  #
  # SANDBOX: HOME is a sandbox dir for every case, so the dev-machine DEFERRED
  # branch can never see the real ~/dev-team/.claude/agents-master, and the
  # $HOME guard is exercised against a sandbox home. TMUX/TMUX_PANE unset.
  #
  # DWP_SELFTEST_SUBJECT (test-only): the script the flat cases exec. Defaults
  # to this file. Point it at a pre-change copy to run the NEGATIVE CONTROL —
  # these cases must fail against a script that lacks --flat-dir.
  # =======================================================================
  local fd_subject="${DWP_SELFTEST_SUBJECT:-}"
  if [ -z "$fd_subject" ]; then
    fd_subject=$(_canon_path "${BASH_SOURCE[0]}") || fd_subject="${BASH_SOURCE[0]}"
  fi
  local fl="${tmp}/flat"
  local fhome="${fl}/home"
  local faitf="${fl}/aitf"
  local fsrc="${faitf}/fteam/personas/agents"
  mkdir -p "$fhome" "$fsrc"
  cat > "${fsrc}/fteam_alpha_engineer_persona.md" <<'PERSONA'
---
name: engineering
description: Alpha engineer (flat-dir).
---

# Alpha flat body
PERSONA
  cat > "${fsrc}/fteam_bravo_tester_persona.md" <<'PERSONA'
---
name: holodeck
description: Bravo tester (flat-dir).
---

# Bravo flat body
PERSONA

  # _fd <log> [VAR=val ...] -- <flat-dir args...>   → returns the CLI's rc.
  # Extra VAR=val entries come AFTER the sandbox defaults, so they override.
  _fd() {
    local log="$1"; shift
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    if [ $# -gt 0 ]; then shift; fi
    env -u TMUX -u TMUX_PANE HOME="$fhome" AITEAMFORGE_DIR="$faitf" \
      ${envs[@]+"${envs[@]}"} "$BASH" "$fd_subject" --flat-dir "$@" >"$log" 2>&1
  }
  _fd_name() { awk '/^---/{f++} f==1 && /^name[[:space:]]*:/{print; exit}' "$1" 2>/dev/null; }

  # A plain git repo used by several refusal cases.
  local frepo="${fl}/repo"
  mkdir -p "${frepo}/sub/deeper"
  git -C "$frepo" init -q
  git -C "$frepo" commit -q --allow-empty -m "init"

  # -----------------------------------------------------------------------
  # Test 24: non-git happy path
  # -----------------------------------------------------------------------
  printf '[selftest] Test 24: --flat-dir non-git happy path...\n'
  local wd24="${fl}/wd24"; mkdir -p "$wd24"
  local log24="${fl}/t24.log" t24_rc=0
  _fd "$log24" -- "$wd24" fteam --force || t24_rc=$?
  local a24="${wd24}/.claude/agents"
  local t24_df t24_mode
  t24_df=$(grep -c '^deployed_file: ' "${a24}/.synced-from-tap" 2>/dev/null || true)
  t24_mode=$(grep -c '^mode: flat-dir$' "${a24}/.synced-from-tap" 2>/dev/null || true)
  if [ "$t24_rc" -eq 0 ] \
     && [ "$(_fd_name "${a24}/fteam_alpha_engineer_persona.md")" = "name: alpha" ] \
     && [ "$(_fd_name "${a24}/fteam_bravo_tester_persona.md")" = "name: bravo" ] \
     && [ "${t24_mode:-0}" -eq 1 ] && [ "${t24_df:-0}" -eq 2 ] \
     && [ ! -e "${wd24}/.git" ] && [ ! -e "${fhome}/.claude" ]; then
    _pass "Test 24 (--flat-dir happy path: files + name: rewritten + mode/deployed_file marker + no .git, rc 0)"
  else
    _fail "Test 24 — rc=${t24_rc} mode=${t24_mode} deployed_file=${t24_df} git=$([ -e "${wd24}/.git" ] && echo PRESENT || echo absent). out: $(cat "$log24" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 25: repo root → rc 4, no .claude created
  # -----------------------------------------------------------------------
  printf '[selftest] Test 25: --flat-dir refuses a git repo root (rc 4)...\n'
  local log25="${fl}/t25.log" t25_rc=0
  _fd "$log25" -- "$frepo" fteam --force || t25_rc=$?
  if [ "$t25_rc" -eq 4 ] && [ ! -e "${frepo}/.claude" ] && grep -q 'REFUSED (git territory)' "$log25"; then
    _pass "Test 25 (--flat-dir repo root → rc 4, no .claude)"
  else
    _fail "Test 25 — rc=${t25_rc} (want 4) .claude=$([ -e "${frepo}/.claude" ] && echo PRESENT || echo absent). out: $(cat "$log25" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 26: subdir of a repo → rc 4
  # -----------------------------------------------------------------------
  printf '[selftest] Test 26: --flat-dir refuses a subdir of a git repo (rc 4)...\n'
  local log26="${fl}/t26.log" t26_rc=0
  _fd "$log26" -- "${frepo}/sub/deeper" fteam --force || t26_rc=$?
  if [ "$t26_rc" -eq 4 ] && [ ! -e "${frepo}/sub/deeper/.claude" ]; then
    _pass "Test 26 (--flat-dir repo subdir → rc 4)"
  else
    _fail "Test 26 — rc=${t26_rc} (want 4). out: $(cat "$log26" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 27: git unusable (PATH stub failing like "dubious ownership") over a
  # real repo → rc 4 via the structural walk; and a bare `.git` dir that git
  # itself does not recognise as a repo → rc 4 (walk only).
  # -----------------------------------------------------------------------
  printf '[selftest] Test 27: --flat-dir refuses when git is unusable / .git unrecognised (rc 4)...\n'
  local stub27="${fl}/stubbin"; mkdir -p "$stub27"
  printf '#!/bin/sh\necho "fatal: detected dubious ownership in repository" >&2\nexit 128\n' > "${stub27}/git"
  chmod +x "${stub27}/git"
  local log27a="${fl}/t27a.log" t27a_rc=0
  _fd "$log27a" "PATH=${stub27}:${PATH}" -- "${frepo}/sub" fteam --force || t27a_rc=$?
  local fake27="${fl}/fakegit"; mkdir -p "${fake27}/.git" "${fake27}/wd"
  local log27b="${fl}/t27b.log" t27b_rc=0
  _fd "$log27b" -- "${fake27}/wd" fteam --force || t27b_rc=$?
  if [ "$t27a_rc" -eq 4 ] && [ "$t27b_rc" -eq 4 ] \
     && [ ! -e "${frepo}/sub/.claude" ] && [ ! -e "${fake27}/wd/.claude" ]; then
    _pass "Test 27 (--flat-dir git stub failing over repo → rc 4; unrecognised ancestor .git → rc 4)"
  else
    _fail "Test 27 — stub rc=${t27a_rc} fake-.git rc=${t27b_rc} (want 4/4). out: $(cat "$log27a" "$log27b" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 28: GIT_DIR exported to an unrelated repo changes neither verdict.
  # (Measured: a leaked GIT_DIR makes rev-parse print `true` in a non-git dir.)
  # -----------------------------------------------------------------------
  printf '[selftest] Test 28: --flat-dir verdicts immune to a leaked GIT_DIR...\n'
  local log28a="${fl}/t28a.log" t28a_rc=0 log28b="${fl}/t28b.log" t28b_rc=0
  _fd "$log28a" "GIT_DIR=${frepo}/.git" -- "$wd24" fteam --force || t28a_rc=$?
  _fd "$log28b" "GIT_DIR=${frepo}/.git" -- "${frepo}/sub/deeper" fteam --force || t28b_rc=$?
  if [ "$t28a_rc" -eq 0 ] && [ "$t28b_rc" -eq 4 ]; then
    _pass "Test 28 (--flat-dir GIT_DIR leak: non-git still rc 0, repo subdir still rc 4)"
  else
    _fail "Test 28 — non-git rc=${t28a_rc} (want 0), subdir rc=${t28b_rc} (want 4). out: $(cat "$log28a" "$log28b" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 29: target == sandbox $HOME → rc 1, $HOME/.claude absent;
  # target == / → rc 1.
  # rc 1 alone is NOT evidence (XACA-1216-015): a script with no --flat-dir
  # also exits 1 (usage error), so this passed against the pre-change script.
  # Each case must print ITS guard's refusal text, and nothing may be written.
  # -----------------------------------------------------------------------
  printf '[selftest] Test 29: --flat-dir refuses target == HOME and / (rc 1)...\n'
  local log29="${fl}/t29.log" t29_rc=0 log29b="${fl}/t29b.log" t29b_rc=0
  _fd "$log29" -- "$fhome" fteam --force || t29_rc=$?
  _fd "$log29b" -- "/" fteam --force || t29b_rc=$?
  if [ "$t29_rc" -eq 1 ] && [ "$t29b_rc" -eq 1 ] && [ ! -e "${fhome}/.claude" ] \
     && grep -qF -- '--flat-dir: refusing target == $HOME (' "$log29" \
     && grep -qF -- "--flat-dir: refusing target '/'" "$log29b"; then
    _pass "Test 29 (--flat-dir target \$HOME → rc 1 + \$HOME refusal text + no ~/.claude; target / → rc 1 + / refusal text)"
  else
    _fail "Test 29 — HOME rc=${t29_rc} /-rc=${t29b_rc} (want 1/1 + guard refusal text) .claude=$([ -e "${fhome}/.claude" ] && echo PRESENT || echo absent). out: $(cat "$log29" "$log29b" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 30: nonexistent target → rc 1; invalid team id → rc 1; missing args → rc 1
  # Same rule as Tests 29/31 (XACA-1216-015): each arm must print its own
  # refusal text — the pre-change script's usage error is also rc 1.
  # -----------------------------------------------------------------------
  printf '[selftest] Test 30: --flat-dir nonexistent target / bad team id / missing args (rc 1)...\n'
  local log30="${fl}/t30.log" t30_rc=0 t30b_rc=0 t30c_rc=0
  _fd "$log30" -- "${fl}/does-not-exist" fteam --force || t30_rc=$?
  _fd "${fl}/t30b.log" -- "$wd24" 'bad/team' --force || t30b_rc=$?
  _fd "${fl}/t30c.log" -- "$wd24" || t30c_rc=$?
  if [ "$t30_rc" -eq 1 ] && [ "$t30b_rc" -eq 1 ] && [ "$t30c_rc" -eq 1 ] && [ ! -e "${fl}/does-not-exist" ] \
     && grep -qF -- '--flat-dir: target does not exist or is not a directory' "$log30" \
     && grep -qF -- "[flat-dir] invalid team id 'bad/team'" "${fl}/t30b.log" \
     && grep -qF -- '--flat-dir <target_dir> <team>' "${fl}/t30c.log"; then
    _pass "Test 30 (--flat-dir nonexistent target / bad team id / missing args → rc 1 + each arm's refusal text)"
  else
    _fail "Test 30 — nonexistent rc=${t30_rc} badteam rc=${t30b_rc} noargs rc=${t30c_rc} (want 1/1/1 + refusal text). out: $(cat "$log30" "${fl}/t30b.log" "${fl}/t30c.log" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 31: symlinked .claude / .claude/agents escaping → rc 1, nothing written
  # Asserts the symlink guard's refusal text per case, not just rc 1 — the
  # pre-change script's usage error is also rc 1 (XACA-1216-015).
  # -----------------------------------------------------------------------
  printf '[selftest] Test 31: --flat-dir refuses symlinked .claude / .claude/agents (rc 1)...\n'
  local wd31="${fl}/wd31" else31="${fl}/elsewhere31"
  mkdir -p "$wd31" "${else31}/agents"
  ln -s "$else31" "${wd31}/.claude"
  local t31a_rc=0 t31b_rc=0
  _fd "${fl}/t31a.log" -- "$wd31" fteam --force || t31a_rc=$?
  local wd31b="${fl}/wd31b" else31b="${fl}/elsewhere31b"
  mkdir -p "${wd31b}/.claude" "$else31b"
  ln -s "$else31b" "${wd31b}/.claude/agents"
  _fd "${fl}/t31b.log" -- "$wd31b" fteam --force || t31b_rc=$?
  local wd31c="${fl}/wd31c"; mkdir -p "$wd31c"
  ln -s "${fl}/dangling-nowhere" "${wd31c}/.claude"
  local t31c_rc=0
  _fd "${fl}/t31c.log" -- "$wd31c" fteam --force || t31c_rc=$?
  local t31_leak t31_msg=0 t31_log
  # Any FILE (persona or marker) under the symlink destinations is a leak.
  t31_leak=$(find "$else31" "$else31b" -type f 2>/dev/null | wc -l | tr -d ' ')
  for t31_log in "${fl}/t31a.log" "${fl}/t31b.log" "${fl}/t31c.log"; do
    grep -qF -- '--flat-dir: .claude or .claude/agents is a symlink resolving outside' "$t31_log" \
      && t31_msg=$((t31_msg + 1))
  done
  if [ "$t31a_rc" -eq 1 ] && [ "$t31b_rc" -eq 1 ] && [ "$t31c_rc" -eq 1 ] && [ "$t31_msg" -eq 3 ] \
     && [ "$t31_leak" = "0" ] && [ ! -e "${fl}/dangling-nowhere" ]; then
    _pass "Test 31 (--flat-dir symlinked .claude / .claude/agents / dangling .claude → rc 1 + symlink refusal text x3, nothing written)"
  else
    _fail "Test 31 — rc .claude=${t31a_rc} agents=${t31b_rc} dangling=${t31c_rc} (want 1/1/1) refusal-text=${t31_msg}/3 leaked=${t31_leak}. out: $(cat "${fl}/t31a.log" "${fl}/t31b.log" "${fl}/t31c.log" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 32: source absent → rc 3; empty source → rc 3 (never warn+0)
  # -----------------------------------------------------------------------
  printf '[selftest] Test 32: --flat-dir no persona source / empty source (rc 3)...\n'
  local wd32="${fl}/wd32"; mkdir -p "$wd32"
  local aitf32e="${fl}/aitf32-empty"; mkdir -p "${aitf32e}/fteam/personas/agents"
  touch "${aitf32e}/fteam/personas/agents/README.txt"
  local t32a_rc=0 t32b_rc=0
  _fd "${fl}/t32a.log" "AITEAMFORGE_DIR=${fl}/aitf32-absent" -- "$wd32" fteam --force || t32a_rc=$?
  _fd "${fl}/t32b.log" "AITEAMFORGE_DIR=${aitf32e}" -- "$wd32" fteam --force || t32b_rc=$?
  if [ "$t32a_rc" -eq 3 ] && [ "$t32b_rc" -eq 3 ] && [ ! -e "${wd32}/.claude" ]; then
    _pass "Test 32 (--flat-dir source absent → rc 3; 0 *.md → rc 3; nothing created)"
  else
    _fail "Test 32 — absent rc=${t32a_rc} empty rc=${t32b_rc} (want 3/3). out: $(cat "${fl}/t32a.log" "${fl}/t32b.log" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 33: --force re-run → byte-identical persona files, rc 0
  # -----------------------------------------------------------------------
  printf '[selftest] Test 33: --flat-dir --force re-run is byte-identical...\n'
  local snap33="${fl}/snap33"; mkdir -p "$snap33"
  # Setup steps from here on tolerate a missing deploy (|| true, mkdir -p) so
  # a script WITHOUT --flat-dir reports FAIL instead of aborting under set -e.
  cp "${a24}/"*.md "$snap33/" 2>/dev/null || true
  local t33_rc=0
  _fd "${fl}/t33.log" -- "$wd24" fteam --force || t33_rc=$?
  local t33_same=true f33 t33_n=0
  for f33 in "$snap33"/*.md; do
    [ -f "$f33" ] || continue
    t33_n=$((t33_n + 1))
    cmp -s "$f33" "${a24}/${f33##*/}" || t33_same=false
  done
  if [ "$t33_rc" -eq 0 ] && [ "$t33_same" = true ] && [ "$t33_n" -eq 2 ]; then
    _pass "Test 33 (--flat-dir --force re-run: byte-identical, rc 0)"
  else
    _fail "Test 33 — rc=${t33_rc} identical=${t33_same} compared=${t33_n} (want 2)"
  fi

  # -----------------------------------------------------------------------
  # Test 34: prune — only marker-listed, source-absent, pattern-matching files
  # -----------------------------------------------------------------------
  printf '[selftest] Test 34: --flat-dir prune policy...\n'
  local aitf34="${fl}/aitf34" wd34="${fl}/wd34"
  mkdir -p "${aitf34}/fteam/personas/agents" "$wd34"
  cp "${fsrc}/"*.md "${aitf34}/fteam/personas/agents/"
  printf -- '---\nname: ops\n---\n# charlie\n' > "${aitf34}/fteam/personas/agents/fteam_charlie_ops_persona.md"
  local t34a_rc=0
  _fd "${fl}/t34a.log" "AITEAMFORGE_DIR=${aitf34}" -- "$wd34" fteam --force || t34a_rc=$?
  local a34="${wd34}/.claude/agents"
  mkdir -p "$a34"
  printf 'mine\n' > "${a34}/my_notes.md"
  printf 'master marker\n' > "${a34}/.synced-from-master"
  printf 'other writer\n' > "${a34}/fteam_x_y_persona.md"
  # Tampered ownership claims that must NOT be honoured: a non-pattern name
  # and a path-traversal name.
  printf 'deployed_file: my_notes.md\ndeployed_file: ../fteam_evil_persona.md\n' >> "${a34}/.synced-from-tap"
  printf 'outside\n' > "${wd34}/.claude/fteam_evil_persona.md"
  rm -f "${aitf34}/fteam/personas/agents/fteam_charlie_ops_persona.md"
  local t34b_rc=0
  _fd "${fl}/t34b.log" "AITEAMFORGE_DIR=${aitf34}" -- "$wd34" fteam --force || t34b_rc=$?
  if [ "$t34a_rc" -eq 0 ] && [ "$t34b_rc" -eq 0 ] \
     && [ ! -e "${a34}/fteam_charlie_ops_persona.md" ] \
     && [ -f "${a34}/my_notes.md" ] && [ -f "${a34}/.synced-from-master" ] \
     && [ -f "${a34}/fteam_x_y_persona.md" ] && [ -f "${wd34}/.claude/fteam_evil_persona.md" ] \
     && [ -f "${a34}/fteam_alpha_engineer_persona.md" ] \
     && grep -q 'ORPHAN (not ours — left in place): fteam_x_y_persona.md' "${fl}/t34b.log" \
     && ! grep -q 'fteam_charlie_ops_persona.md' "${a34}/.synced-from-tap"; then
    _pass "Test 34 (--flat-dir prune: removed source file deleted; my_notes.md/.synced-from-master/unlisted persona kept + ORPHAN; tampered claims ignored)"
  else
    _fail "Test 34 — rc=${t34a_rc}/${t34b_rc} charlie=$([ -e "${a34}/fteam_charlie_ops_persona.md" ] && echo PRESENT || echo gone) notes=$([ -f "${a34}/my_notes.md" ] && echo kept || echo GONE) master=$([ -f "${a34}/.synced-from-master" ] && echo kept || echo GONE) xy=$([ -f "${a34}/fteam_x_y_persona.md" ] && echo kept || echo GONE). out: $(cat "${fl}/t34b.log" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 35: first deploy over a pre-populated dir WITHOUT a marker deletes nothing
  # -----------------------------------------------------------------------
  printf '[selftest] Test 35: --flat-dir first deploy over pre-populated dir deletes nothing...\n'
  local wd35="${fl}/wd35"; mkdir -p "${wd35}/.claude/agents"
  printf 'old\n' > "${wd35}/.claude/agents/fteam_old_gone_persona.md"
  printf 'notes\n' > "${wd35}/.claude/agents/notes.md"
  local t35_rc=0
  _fd "${fl}/t35.log" -- "$wd35" fteam --force || t35_rc=$?
  if [ "$t35_rc" -eq 0 ] && [ -f "${wd35}/.claude/agents/fteam_old_gone_persona.md" ] \
     && [ -f "${wd35}/.claude/agents/notes.md" ] \
     && [ -f "${wd35}/.claude/agents/fteam_alpha_engineer_persona.md" ]; then
    _pass "Test 35 (--flat-dir first deploy, no prior marker: nothing deleted, rc 0)"
  else
    _fail "Test 35 — rc=${t35_rc}. out: $(cat "${fl}/t35.log" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 36: --dry-run → no writes, WOULD PRUNE printed, rc 0
  # -----------------------------------------------------------------------
  printf '[selftest] Test 36: --flat-dir --dry-run writes nothing, prints WOULD PRUNE...\n'
  local aitf36="${fl}/aitf36" wd36="${fl}/wd36"
  mkdir -p "${aitf36}/fteam/personas/agents" "$wd36"
  cp "${fsrc}/"*.md "${aitf36}/fteam/personas/agents/"
  local t36a_rc=0
  _fd "${fl}/t36a.log" "AITEAMFORGE_DIR=${aitf36}" -- "$wd36" fteam --force || t36a_rc=$?
  rm -f "${aitf36}/fteam/personas/agents/fteam_bravo_tester_persona.md"
  printf -- '---\nname: x\n---\n# changed alpha\n' > "${aitf36}/fteam/personas/agents/fteam_alpha_engineer_persona.md"
  mkdir -p "${wd36}/.claude/agents"
  local sum36_before="" sum36_after=""
  sum36_before=$(cd "${wd36}/.claude/agents" 2>/dev/null && cksum .synced-from-tap ./*.md 2>/dev/null) || true
  local t36_rc=0
  _fd "${fl}/t36.log" "AITEAMFORGE_DIR=${aitf36}" -- "$wd36" fteam --force --dry-run || t36_rc=$?
  sum36_after=$(cd "${wd36}/.claude/agents" 2>/dev/null && cksum .synced-from-tap ./*.md 2>/dev/null) || true
  local wd36f="${fl}/wd36fresh"; mkdir -p "$wd36f"
  local t36f_rc=0
  _fd "${fl}/t36f.log" -- "$wd36f" fteam --force --dry-run || t36f_rc=$?
  if [ "$t36a_rc" -eq 0 ] && [ "$t36_rc" -eq 0 ] && [ "$t36f_rc" -eq 0 ] \
     && [ -n "$sum36_before" ] && [ "$sum36_before" = "$sum36_after" ] \
     && grep -q 'WOULD PRUNE fteam_bravo_tester_persona.md' "${fl}/t36.log" \
     && [ ! -e "${wd36f}/.claude" ]; then
    _pass "Test 36 (--flat-dir --dry-run: no writes, WOULD PRUNE printed, rc 0)"
  else
    _fail "Test 36 — rc=${t36a_rc}/${t36_rc}/${t36f_rc} unchanged=$([ "$sum36_before" = "$sum36_after" ] && echo yes || echo NO). out: $(cat "${fl}/t36.log" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 37: dev-machine DEFERRED — sandbox agents-master present, primary
  # absent → rc 0 + DEFERRED line + nothing written. Validation order: a git
  # target on the same "dev machine" is still rc 4, not DEFERRED.
  # -----------------------------------------------------------------------
  printf '[selftest] Test 37: --flat-dir dev-machine DEFERRED (rc 0) and git check precedes it...\n'
  local home37="${fl}/home37" wd37="${fl}/wd37"
  mkdir -p "${home37}/dev-team/.claude/agents-master/fteam" "$wd37"
  local t37_rc=0 t37b_rc=0
  _fd "${fl}/t37.log" "HOME=${home37}" "AITEAMFORGE_DIR=${fl}/aitf37-absent" -- "$wd37" fteam --force || t37_rc=$?
  _fd "${fl}/t37b.log" "HOME=${home37}" "AITEAMFORGE_DIR=${fl}/aitf37-absent" -- "$frepo" fteam --force || t37b_rc=$?
  if [ "$t37_rc" -eq 0 ] && grep -q 'DEFERRED: dev machine — kb-sync-personas owns this target' "${fl}/t37.log" \
     && [ ! -e "${wd37}/.claude" ] && [ "$t37b_rc" -eq 4 ]; then
    _pass "Test 37 (--flat-dir DEFERRED on sandbox dev machine → rc 0; git target still rc 4)"
  else
    _fail "Test 37 — rc=${t37_rc} (want 0) git rc=${t37b_rc} (want 4). out: $(cat "${fl}/t37.log" "${fl}/t37b.log" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 38: partial deploy (transform skips a file) → rc 2 and NO prune;
  # the unpruned file keeps its ownership in the rewritten marker.
  # -----------------------------------------------------------------------
  printf '[selftest] Test 38: --flat-dir partial deploy → rc 2, no prune...\n'
  local aitf38="${fl}/aitf38" wd38="${fl}/wd38"
  mkdir -p "${aitf38}/fteam/personas/agents" "$wd38"
  cp "${fsrc}/"*.md "${aitf38}/fteam/personas/agents/"
  local t38a_rc=0
  _fd "${fl}/t38a.log" "AITEAMFORGE_DIR=${aitf38}" -- "$wd38" fteam --force || t38a_rc=$?
  rm -f "${aitf38}/fteam/personas/agents/fteam_bravo_tester_persona.md"
  printf -- '---\nname: u\n---\n' > "${aitf38}/fteam/personas/agents/fteam_unreadable_x_persona.md"
  chmod 000 "${aitf38}/fteam/personas/agents/fteam_unreadable_x_persona.md"
  local t38_rc=0
  _fd "${fl}/t38.log" "AITEAMFORGE_DIR=${aitf38}" -- "$wd38" fteam --force || t38_rc=$?
  chmod 644 "${aitf38}/fteam/personas/agents/fteam_unreadable_x_persona.md"
  if [ "$t38a_rc" -eq 0 ] && [ "$t38_rc" -eq 2 ] \
     && [ -f "${wd38}/.claude/agents/fteam_bravo_tester_persona.md" ] \
     && grep -q '^deployed_file: fteam_bravo_tester_persona.md$' "${wd38}/.claude/agents/.synced-from-tap" 2>/dev/null; then
    _pass "Test 38 (--flat-dir partial deploy → rc 2, no prune, ownership retained)"
  else
    _fail "Test 38 — rc=${t38a_rc}/${t38_rc} (want 0/2) bravo=$([ -f "${wd38}/.claude/agents/fteam_bravo_tester_persona.md" ] && echo kept || echo GONE). out: $(cat "${fl}/t38.log" 2>/dev/null)"
  fi

  # =======================================================================
  # --verify-flat-dir (XACA-1216-018/019) — Tests 39-46.
  # Same subprocess + sandbox rules as the --flat-dir cases, same subject, so
  # DWP_SELFTEST_SUBJECT=<pre-change script> is the negative control here too.
  # Every assertion pins a SPECIFIC rc (0/2/3/4/5) plus output text, so a
  # subject without the mode (usage rc 1) cannot pass by accident.
  # =======================================================================
  # _fv <log> [VAR=val ...] -- <verify args...>   → returns the CLI's rc.
  _fv() {
    local log="$1"; shift
    local envs=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    if [ $# -gt 0 ]; then shift; fi
    env -u TMUX -u TMUX_PANE HOME="$fhome" AITEAMFORGE_DIR="$faitf" \
      ${envs[@]+"${envs[@]}"} "$BASH" "$fd_subject" --verify-flat-dir "$@" >"$log" 2>&1
  }
  # _fv_snap <dir> → a listing + checksum of everything under <dir> (read-only proof).
  _fv_snap() { (cd "$1" 2>/dev/null && find . -print 2>/dev/null | LC_ALL=C sort && find . -type f -exec cksum {} \; 2>/dev/null | LC_ALL=C sort) || true; }

  # -----------------------------------------------------------------------
  # Test 39: fresh deploy verifies (rc 0); marker is NOT consulted; read-only
  # -----------------------------------------------------------------------
  printf '[selftest] Test 39: --verify-flat-dir fresh deploy → rc 0, marker ignored, writes nothing...\n'
  local aitf39="${fl}/aitf39" wd39="${fl}/wd39"
  mkdir -p "${aitf39}/fteam/personas/agents" "$wd39"
  cp "${fsrc}/"*.md "${aitf39}/fteam/personas/agents/"
  local t39d_rc=0 t39_rc=0 t39b_rc=0
  _fd "${fl}/t39d.log" "AITEAMFORGE_DIR=${aitf39}" -- "$wd39" fteam --force || t39d_rc=$?
  local snap39_before="" snap39_after=""
  snap39_before=$(_fv_snap "$wd39")
  _fv "${fl}/t39.log" "AITEAMFORGE_DIR=${aitf39}" -- "$wd39" fteam || t39_rc=$?
  snap39_after=$(_fv_snap "$wd39")
  # Remove the marker entirely: verification must not care.
  rm -f "${wd39}/.claude/agents/.synced-from-tap"
  _fv "${fl}/t39b.log" "AITEAMFORGE_DIR=${aitf39}" -- "$wd39" fteam || t39b_rc=$?
  if [ "$t39d_rc" -eq 0 ] && [ "$t39_rc" -eq 0 ] && [ "$t39b_rc" -eq 0 ] \
     && grep -q '^verified: 2 of 2 persona(s) match the source in ' "${fl}/t39.log" \
     && grep -q '^verified: 2 of 2 ' "${fl}/t39b.log" \
     && [ -n "$snap39_before" ] && [ "$snap39_before" = "$snap39_after" ]; then
    _pass "Test 39 (--verify-flat-dir after a real deploy → rc 0 + verified line; still rc 0 with the marker removed; target unchanged)"
  else
    _fail "Test 39 — deploy rc=${t39d_rc} verify rc=${t39_rc}/${t39b_rc} (want 0/0/0) unchanged=$([ "$snap39_before" = "$snap39_after" ] && echo yes || echo NO). out: $(cat "${fl}/t39.log" "${fl}/t39b.log" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 40: one deployed byte changed → rc 5, STALE listed
  # -----------------------------------------------------------------------
  printf '[selftest] Test 40: --verify-flat-dir stale file → rc 5 STALE...\n'
  local aitf40="${fl}/aitf40" wd40="${fl}/wd40"
  mkdir -p "${aitf40}/fteam/personas/agents" "$wd40"
  cp "${fsrc}/"*.md "${aitf40}/fteam/personas/agents/"
  local t40d_rc=0 t40_rc=0
  _fd "${fl}/t40d.log" "AITEAMFORGE_DIR=${aitf40}" -- "$wd40" fteam --force || t40d_rc=$?
  # Flip one byte of the body ("Alpha" → "Blpha"), size unchanged.
  if [ -f "${wd40}/.claude/agents/fteam_alpha_engineer_persona.md" ]; then
    sed 's/# Alpha flat body/# Blpha flat body/' "${wd40}/.claude/agents/fteam_alpha_engineer_persona.md" > "${fl}/t40.tmp" \
      && cat "${fl}/t40.tmp" > "${wd40}/.claude/agents/fteam_alpha_engineer_persona.md"
  fi
  _fv "${fl}/t40.log" "AITEAMFORGE_DIR=${aitf40}" -- "$wd40" fteam || t40_rc=$?
  if [ "$t40d_rc" -eq 0 ] && [ "$t40_rc" -eq 5 ] \
     && grep -qx 'STALE fteam_alpha_engineer_persona.md' "${fl}/t40.log" \
     && ! grep -q 'bravo' "${fl}/t40.log" \
     && grep -q '^verify: 1 of 2 persona(s) do not match the source in .* (0 missing, 1 stale)$' "${fl}/t40.log"; then
    _pass "Test 40 (--verify-flat-dir one changed byte → rc 5 + STALE <file> + summary; untouched file not listed)"
  else
    _fail "Test 40 — deploy rc=${t40d_rc} verify rc=${t40_rc} (want 0/5). out: $(cat "${fl}/t40.log" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 41: a deployed file removed → rc 5, MISSING listed
  # -----------------------------------------------------------------------
  printf '[selftest] Test 41: --verify-flat-dir missing file → rc 5 MISSING...\n'
  local aitf41="${fl}/aitf41" wd41="${fl}/wd41"
  mkdir -p "${aitf41}/fteam/personas/agents" "$wd41"
  cp "${fsrc}/"*.md "${aitf41}/fteam/personas/agents/"
  local t41d_rc=0 t41_rc=0
  _fd "${fl}/t41d.log" "AITEAMFORGE_DIR=${aitf41}" -- "$wd41" fteam --force || t41d_rc=$?
  rm -f "${wd41}/.claude/agents/fteam_bravo_tester_persona.md"
  _fv "${fl}/t41.log" "AITEAMFORGE_DIR=${aitf41}" -- "$wd41" fteam || t41_rc=$?
  if [ "$t41d_rc" -eq 0 ] && [ "$t41_rc" -eq 5 ] \
     && grep -qx 'MISSING fteam_bravo_tester_persona.md' "${fl}/t41.log" \
     && grep -q '(1 missing, 0 stale)$' "${fl}/t41.log"; then
    _pass "Test 41 (--verify-flat-dir removed file → rc 5 + MISSING <file>)"
  else
    _fail "Test 41 — deploy rc=${t41d_rc} verify rc=${t41_rc} (want 0/5). out: $(cat "${fl}/t41.log" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 42: source changed + a no-op rc-0 deploy (already deployed, no
  # --force) → rc 5 STALE; a real --force refresh → rc 0 again
  # -----------------------------------------------------------------------
  printf '[selftest] Test 42: --verify-flat-dir no-op rc 0 deploy after a source change → rc 5...\n'
  local aitf42="${fl}/aitf42" wd42="${fl}/wd42"
  mkdir -p "${aitf42}/fteam/personas/agents" "$wd42"
  cp "${fsrc}/"*.md "${aitf42}/fteam/personas/agents/"
  local t42a_rc=0 t42b_rc=0 t42_rc=0 t42c_rc=0 t42v_rc=0
  _fd "${fl}/t42a.log" "AITEAMFORGE_DIR=${aitf42}" -- "$wd42" fteam --force || t42a_rc=$?
  printf -- '---\nname: engineering\ndescription: Alpha engineer v2.\n---\n\n# Alpha flat body v2\n' \
    > "${aitf42}/fteam/personas/agents/fteam_alpha_engineer_persona.md"
  _fd "${fl}/t42b.log" "AITEAMFORGE_DIR=${aitf42}" -- "$wd42" fteam || t42b_rc=$?
  _fv "${fl}/t42.log" "AITEAMFORGE_DIR=${aitf42}" -- "$wd42" fteam || t42_rc=$?
  _fd "${fl}/t42c.log" "AITEAMFORGE_DIR=${aitf42}" -- "$wd42" fteam --force || t42c_rc=$?
  _fv "${fl}/t42v.log" "AITEAMFORGE_DIR=${aitf42}" -- "$wd42" fteam || t42v_rc=$?
  if [ "$t42a_rc" -eq 0 ] && [ "$t42b_rc" -eq 0 ] && grep -q 'Already deployed' "${fl}/t42b.log" \
     && [ "$t42_rc" -eq 5 ] && grep -qx 'STALE fteam_alpha_engineer_persona.md' "${fl}/t42.log" \
     && [ "$t42c_rc" -eq 0 ] && [ "$t42v_rc" -eq 0 ]; then
    _pass "Test 42 (--verify-flat-dir: no-op rc 0 deploy over a changed source → rc 5 STALE; --force refresh → rc 0)"
  else
    _fail "Test 42 — rc deploy=${t42a_rc} noop=${t42b_rc} verify=${t42_rc} (want 5) force=${t42c_rc} reverify=${t42v_rc} (want 0). out: $(cat "${fl}/t42.log" "${fl}/t42v.log" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 43: nothing ever deployed → rc 5 MISSING x2, and no .claude created
  # -----------------------------------------------------------------------
  printf '[selftest] Test 43: --verify-flat-dir never-deployed target → rc 5, creates nothing...\n'
  local wd43="${fl}/wd43"; mkdir -p "$wd43"
  local t43_rc=0
  _fv "${fl}/t43.log" -- "$wd43" fteam || t43_rc=$?
  if [ "$t43_rc" -eq 5 ] && [ "$(grep -c '^MISSING ' "${fl}/t43.log")" -eq 2 ] \
     && grep -q '(2 missing, 0 stale)$' "${fl}/t43.log" && [ ! -e "${wd43}/.claude" ]; then
    _pass "Test 43 (--verify-flat-dir empty target → rc 5 + 2 MISSING; no .claude created)"
  else
    _fail "Test 43 — rc=${t43_rc} (want 5) claude=$([ -e "${wd43}/.claude" ] && echo CREATED || echo absent). out: $(cat "${fl}/t43.log" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 44: rc 3 (no source, empty source, dev-machine: NO DEFERRED pass) and
  # guard rcs shared with --flat-dir (1 + refusal text, 4 git territory)
  # -----------------------------------------------------------------------
  printf '[selftest] Test 44: --verify-flat-dir rc 3 / guard rc 1 / git rc 4...\n'
  local wd44="${fl}/wd44" aitf44e="${fl}/aitf44e" home44="${fl}/home44"
  mkdir -p "$wd44" "${aitf44e}/fteam/personas/agents" "${home44}/dev-team/.claude/agents-master/fteam"
  local t44a=0 t44b=0 t44c=0 t44d=0 t44e=0 t44f=0 t44g=0 t44h=0
  _fv "${fl}/t44a.log" "AITEAMFORGE_DIR=${fl}/aitf44-absent" -- "$wd44" fteam || t44a=$?
  _fv "${fl}/t44b.log" "AITEAMFORGE_DIR=${aitf44e}" -- "$wd44" fteam || t44b=$?
  _fv "${fl}/t44c.log" "HOME=${home44}" "AITEAMFORGE_DIR=${fl}/aitf44-absent" -- "$wd44" fteam || t44c=$?
  _fv "${fl}/t44d.log" -- "$wd44" 'bad/team' || t44d=$?
  _fv "${fl}/t44e.log" -- "${fl}/no-such-dir44" fteam || t44e=$?
  _fv "${fl}/t44f.log" -- "$fhome" fteam || t44f=$?
  _fv "${fl}/t44g.log" -- "${frepo}/sub" fteam || t44g=$?
  _fv "${fl}/t44h.log" -- "$wd44" || t44h=$?
  if [ "$t44a" -eq 3 ] && grep -qF -- '--verify-flat-dir: no persona source at' "${fl}/t44a.log" \
     && [ "$t44b" -eq 3 ] && grep -qF -- '--verify-flat-dir: persona source has 0 *.md files' "${fl}/t44b.log" \
     && [ "$t44c" -eq 3 ] && ! grep -q 'DEFERRED' "${fl}/t44c.log" \
     && [ "$t44d" -eq 1 ] && grep -qF -- "[verify-flat-dir] invalid team id 'bad/team'" "${fl}/t44d.log" \
     && [ "$t44e" -eq 1 ] && grep -qF -- '--verify-flat-dir: target does not exist or is not a directory' "${fl}/t44e.log" \
     && [ "$t44f" -eq 1 ] && grep -qF -- '--verify-flat-dir: refusing target == $HOME (' "${fl}/t44f.log" \
     && [ "$t44g" -eq 4 ] && grep -qF -- '--verify-flat-dir: REFUSED (git territory)' "${fl}/t44g.log" \
     && [ "$t44h" -eq 1 ] && grep -qF -- '--verify-flat-dir <target_dir> <team>' "${fl}/t44h.log" \
     && [ ! -e "${wd44}/.claude" ] && [ ! -e "${fhome}/.claude" ]; then
    _pass "Test 44 (--verify-flat-dir: source absent/empty/dev-machine → rc 3 (no DEFERRED pass); bad team/missing target/\$HOME/arg count → rc 1 + text; git subdir → rc 4)"
  else
    _fail "Test 44 — rcs absent=${t44a} empty=${t44b} devmachine=${t44c} (want 3/3/3) badteam=${t44d} nodir=${t44e} home=${t44f} (want 1/1/1) git=${t44g} (want 4) args=${t44h} (want 1). out: $(cat "${fl}"/t44?.log 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 45: render parity on the verbatim-copy edge cases — the verifier's
  # expectation equals what the deploy wrote AND what emit-transformed prints
  # -----------------------------------------------------------------------
  printf '[selftest] Test 45: --verify-flat-dir render parity (no frontmatter / no name: / trailing newlines)...\n'
  local aitf45="${fl}/aitf45" wd45="${fl}/wd45"
  local src45="${aitf45}/fteam/personas/agents"
  mkdir -p "$src45" "$wd45"
  printf '# no frontmatter, no trailing newline' > "${src45}/fteam_nofm_x_persona.md"
  printf -- '---\ndescription: no name line\n---\n\nbody\n\n\n' > "${src45}/fteam_noname_x_persona.md"
  printf -- '---\nname: role\n---\nbody\n\n' > "${src45}/fteam_trail_x_persona.md"
  local t45d_rc=0 t45_rc=0 t45_emit_ok=true f45 b45
  _fd "${fl}/t45d.log" "AITEAMFORGE_DIR=${aitf45}" -- "$wd45" fteam --force || t45d_rc=$?
  _fv "${fl}/t45.log" "AITEAMFORGE_DIR=${aitf45}" -- "$wd45" fteam || t45_rc=$?
  for f45 in "$src45"/*.md; do
    b45="${f45##*/}"
    env -u TMUX -u TMUX_PANE HOME="$fhome" "$BASH" "$fd_subject" emit-transformed "$f45" > "${fl}/t45-${b45}.emit" 2>/dev/null \
      || t45_emit_ok=false
    cmp -s "${fl}/t45-${b45}.emit" "${wd45}/.claude/agents/${b45}" || t45_emit_ok=false
  done
  if [ "$t45d_rc" -eq 0 ] && [ "$t45_rc" -eq 0 ] && grep -q '^verified: 3 of 3 ' "${fl}/t45.log" \
     && [ "$t45_emit_ok" = true ]; then
    _pass "Test 45 (--verify-flat-dir edge sources → rc 0 after deploy; emit-transformed byte-identical to every deployed file)"
  else
    _fail "Test 45 — deploy rc=${t45d_rc} verify rc=${t45_rc} (want 0/0) emit==deployed=${t45_emit_ok}. out: $(cat "${fl}/t45.log" 2>/dev/null)"
  fi

  # -----------------------------------------------------------------------
  # Test 46: expected content uncomputable (unreadable source) → rc 2, never 0
  # -----------------------------------------------------------------------
  printf '[selftest] Test 46: --verify-flat-dir uninspectable source → rc 2...\n'
  local aitf46="${fl}/aitf46" wd46="${fl}/wd46"
  mkdir -p "${aitf46}/fteam/personas/agents" "$wd46"
  cp "${fsrc}/"*.md "${aitf46}/fteam/personas/agents/"
  local t46d_rc=0 t46_rc=0
  _fd "${fl}/t46d.log" "AITEAMFORGE_DIR=${aitf46}" -- "$wd46" fteam --force || t46d_rc=$?
  chmod 000 "${aitf46}/fteam/personas/agents/fteam_alpha_engineer_persona.md"
  _fv "${fl}/t46.log" "AITEAMFORGE_DIR=${aitf46}" -- "$wd46" fteam || t46_rc=$?
  chmod 644 "${aitf46}/fteam/personas/agents/fteam_alpha_engineer_persona.md"
  if [ "$t46d_rc" -eq 0 ] && [ "$t46_rc" -eq 2 ] \
     && grep -qF -- 'uninspectable — NOT verified' "${fl}/t46.log" && ! grep -q '^verified:' "${fl}/t46.log"; then
    _pass "Test 46 (--verify-flat-dir unreadable source → rc 2 uninspectable, no verified line)"
  else
    _fail "Test 46 — deploy rc=${t46d_rc} verify rc=${t46_rc} (want 0/2). out: $(cat "${fl}/t46.log" 2>/dev/null)"
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
    printf '       %s --nested-main-root <project_dir> <team> [--dry-run] [--force] [--verbose]\n' "$PROG" >&2
    printf '       %s --flat-dir <target_dir> <team> [--dry-run] [--force] [--verbose]\n' "$PROG" >&2
    printf '       %s --verify-flat-dir <target_dir> <team>\n' "$PROG" >&2
    printf '       %s emit-transformed <src_file> [<char_name>]\n' "$PROG" >&2
    printf '       %s selftest\n' "$PROG" >&2
    exit 1
  fi

  if [ "$1" = "selftest" ]; then
    _selftest
    return
  fi

  # emit-transformed (XACA-0931-003): read-only, single-authority mode. Prints
  # the EXPECTED transform output of one source file to stdout -- exactly
  # what _deploy_core would write to a deployed target, without deploying
  # anything. Exists so aiteamforge-persona-parity-check.sh's deployed-vs-
  # source (S2<->S3) surface can compare against the real transform instead
  # of reimplementing the `name:` frontmatter rewrite (XACA-0931-001_decision
  # §4.2: "textbook k501 sibling-heuristic drift ... the checker's copy
  # silently deciding what correct means"). Purely additive: does not touch
  # OPT_DRY_RUN/OPT_FORCE/OPT_VERBOSE, does not write anywhere, and does not
  # alter any existing mode's exit codes.
  #
  # <char_name> is optional -- when omitted it is derived from <src_file>'s
  # basename via _char_from_filename(), the same derivation _deploy_core uses
  # for every real deployment. The override exists only so a caller (or a
  # test) can ask "what would this transform to as team X's <char>" without
  # needing a file whose name already encodes that character.
  #
  # Exit codes (independent of the main deploy exit-code table above --
  # this mode never deploys, so 1/2 there do not apply):
  #   0 = transform computed successfully (this also covers the two cases
  #       _deploy_core itself treats as non-fatal "copy verbatim" --
  #       no frontmatter, or frontmatter with no name: line -- because in
  #       BOTH cases the verbatim content IS the expected deployed output;
  #       reporting them as a failure here would make the checker flag a
  #       byte-for-byte-correct deploy as drift).
  #   1 = <src_file> does not exist, or is not a regular file.
  #   2 = the transform itself failed for a reason other than the two
  #       verbatim-copy cases above (e.g. python3 unavailable/errored) --
  #       the caller must treat this as UNINSPECTABLE, never as "clean" and
  #       never by falling back to a raw `cmp` against the untransformed
  #       source (XACA-0931-001_decision §4.2 forbids exactly that fallback).
  if [ "$1" = "emit-transformed" ]; then
    shift
    if [ $# -lt 1 ]; then
      printf 'Usage: %s emit-transformed <src_file> [<char_name>]\n' "$PROG" >&2
      exit 1
    fi
    local et_src="$1"
    local et_char="${2:-}"

    if [ ! -f "$et_src" ]; then
      _err "emit-transformed: source file not found: ${et_src}"
      exit 1
    fi

    if [ -z "$et_char" ]; then
      et_char=$(_char_from_filename "$(basename "$et_src")")
    fi

    # Through _dwp_render (XACA-1216-019): transform rc 0/2/3 print exactly the
    # bytes _deploy_core writes (for the no-frontmatter case that is now the
    # source verbatim, as cp writes it); any other rc prints nothing.
    local et_rc=0
    _dwp_render "$et_src" "$et_char" emit || et_rc=$?

    case "$et_rc" in
      0)
        exit 0
        ;;
      *)
        _err "emit-transformed: transform failed (rc=${_DWP_RENDER_TRC}) for ${et_src}"
        exit 2
        ;;
    esac
  fi

  OPT_DRY_RUN=false
  OPT_FORCE=false
  OPT_VERBOSE=false

  # --flat-dir mode (XACA-1216): deploy personas into a NON-GIT team working
  # dir's .claude/agents/. Refuses git territory with rc 4; see header table.
  if [ "$1" = "--flat-dir" ]; then
    shift
    if [ $# -lt 2 ]; then
      printf 'Usage: %s --flat-dir <target_dir> <team> [--dry-run] [--force] [--verbose]\n' "$PROG" >&2
      exit 1
    fi
    local fd_target="$1"
    local fd_team="$2"
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
    local fd_rc=0
    _deploy_flat_dir "$fd_target" "$fd_team" || fd_rc=$?
    exit "$fd_rc"
  fi

  # --verify-flat-dir mode (XACA-1216-018/019): read-only content verification
  # of a flat-dir deploy. No options; see the exit-code table above
  # _verify_flat_dir.
  if [ "$1" = "--verify-flat-dir" ]; then
    shift
    if [ $# -ne 2 ]; then
      printf 'Usage: %s --verify-flat-dir <target_dir> <team>\n' "$PROG" >&2
      exit 1
    fi
    local vf_rc=0
    _verify_flat_dir "$1" "$2" || vf_rc=$?
    exit "$vf_rc"
  fi

  # --nested-main-root mode: deploy personas into a nested git repo root
  # (used by deploy_team_personas fallback in lcars-launch-helpers.sh on
  # tap-consumer machines where kb-sync-personas is not available).
  if [ "$1" = "--nested-main-root" ]; then
    shift
    if [ $# -lt 2 ]; then
      printf 'Usage: %s --nested-main-root <project_dir> <team> [--dry-run] [--force] [--verbose]\n' "$PROG" >&2
      exit 1
    fi
    local nmr_project="$1"
    local nmr_team="$2"
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
    _deploy_nested_main_root "$nmr_project" "$nmr_team"
    return
  fi

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
