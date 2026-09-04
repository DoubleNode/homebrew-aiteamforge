#!/usr/bin/env bash
# aiteamforge-paths-init.sh — Bootstrap ~/.aiteamforge/team-paths.json from defaults
#
# XACA-0168-001 — Wave 1: Config schema + loader module
#
# Creates the canonical team-paths config file from the baked-in defaults
# defined in kanban-hooks/aiteamforge_paths.py.  Idempotent: refuses to
# overwrite an existing file unless --force is passed.
#
# This script is standalone — it can be called directly or will be wired into
# the interactive setup wizard (XACA-0168-002) later.
#
# USAGE:
#   bash scripts/aiteamforge-paths-init.sh [--force] [--config /path/to/file]
#   bash scripts/aiteamforge-paths-init.sh --help
#
# OPTIONS:
#   --force           Overwrite an existing config file
#   --config PATH     Write to PATH instead of ~/.aiteamforge/team-paths.json
#   --dry-run         Print the config that would be written without writing it
#   --help / -h       Show this message

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────

FORCE=0
DRY_RUN=0
CONFIG_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)    FORCE=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --config)
            shift
            CONFIG_PATH="$1"
            shift
            ;;
        --help|-h)
            sed -n '/^# USAGE:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Resolve config path
# ─────────────────────────────────────────────────────────────────────────────

if [[ -z "$CONFIG_PATH" ]]; then
    if [[ -n "${AITEAMFORGE_CONFIG:-}" ]]; then
        CONFIG_PATH="$AITEAMFORGE_CONFIG"
    else
        CONFIG_PATH="${HOME}/.aiteamforge/team-paths.json"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Guard: refuse to overwrite unless --force
# ─────────────────────────────────────────────────────────────────────────────

if [[ -f "$CONFIG_PATH" && "$FORCE" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    echo "Config already exists at: $CONFIG_PATH"
    echo "Use --force to overwrite, or --dry-run to preview the defaults."
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Locate the Python loader module
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve relative to this script's location in ~/dev-team/scripts/
DEV_TEAM_DIR="$(dirname "$SCRIPT_DIR")"
PYTHON_LOADER="${DEV_TEAM_DIR}/kanban-hooks/aiteamforge_paths.py"

if [[ ! -f "$PYTHON_LOADER" ]]; then
    echo "ERROR: Python loader not found at: $PYTHON_LOADER" >&2
    echo "Make sure you are running from the dev-team repository." >&2
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required but not found in PATH." >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Generate config JSON via the Python loader's DEFAULT_TEAMS
# ─────────────────────────────────────────────────────────────────────────────

CONFIG_JSON=$(python3 - "$PYTHON_LOADER" <<'PYEOF'
import sys, json
from pathlib import Path
import importlib.util

loader_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("aiteamforge_paths", loader_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

config = {
    "schema_version": mod.SUPPORTED_SCHEMA_VERSION,
    "teams": mod.DEFAULT_TEAMS,
}
print(json.dumps(config, indent=2))
PYEOF
)

# ─────────────────────────────────────────────────────────────────────────────
# Dry-run: just print
# ─────────────────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Would write to: $CONFIG_PATH"
    echo "─────────────────────────────────────────────────────"
    echo "$CONFIG_JSON"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Write config
# ─────────────────────────────────────────────────────────────────────────────

CONFIG_DIR="$(dirname "$CONFIG_PATH")"
mkdir -p "$CONFIG_DIR"

# XACA-1059-005: this used to be `printf ... > "$CONFIG_PATH"` -- truncates the
# target on open, single write call, no tmp file, no fsync, no lock. --force
# makes this path reachable against a LIVE, already-populated registry (not
# just a first-time bootstrap), so a crash/kill mid-write here could leave a
# truncated/0-byte team-paths.json the same way scripts/kb-port-reconcile's
# non-atomic writer could (XACA-1059 writer inventory). Bounced through a
# throwaway tmp file rather than a bash heredoc-as-stdin because the Python
# program below already needs stdin's usual role (`python3 -`) for the
# program source itself; a second stdin stream for the payload would fight it.
_json_src="$(mktemp -t aiteamforge-paths-init-json.XXXXXX)"
trap 'rm -f "$_json_src"' EXIT
printf '%s\n' "$CONFIG_JSON" > "$_json_src"

# Same tmp-in-same-dir + fsync + os.replace + fcntl.flock convention this
# ticket applied to scripts/kb-port-reconcile and that
# kanban-hooks/aiteamforge_paths.py's _rewrite_config_on_disk already used
# (XACA-0794-008/-009/-012): mode preserved across the replace, lock file
# never truncated on open and never unlinked (a racing writer -- the LCARS
# server's account/copyright handlers, or a self-heal pass -- must always
# resolve the SAME lock inode as this process).
#
# Exit code contract (XACA-1059, PR #817 review round -- matches
# scripts/kb-port-reconcile's _update_team_paths_json convention, documented
# there): 0 = wrote successfully. 2 = a write was attempted and refused for a
# real reason (the plausibility floor below, or the lock file could not be
# opened/created) -- this script's OTHER top-level errors (bad args, missing
# loader, file exists without --force) stay at the generic 1 used throughout
# the rest of this script; only a REFUSED WRITE gets the distinct code, so
# a refusal is never confused with an ordinary usage error.
python3 - "$_json_src" "$CONFIG_PATH" "$PYTHON_LOADER" <<'PYEOF'
import fcntl
import importlib.util
import os
import stat
import sys
import tempfile
from pathlib import Path

json_src = Path(sys.argv[1])
config_path = Path(sys.argv[2])
loader_path = sys.argv[3] if len(sys.argv) > 3 else ""
payload = json_src.read_text(encoding="utf-8")

resolved = config_path.resolve()
lock_path = resolved.with_name(f"{resolved.name}.lock")

# XACA-1059: single-source the write-side plausibility floor from the
# canonical module (this script already importlib.exec_module()s it above,
# to read SUPPORTED_SCHEMA_VERSION/DEFAULT_TEAMS -- the "this script does not
# otherwise depend on that module being importable" justification the review
# flagged was false for exactly this file). Falls back to the known value if
# the module can't be loaded, so this floor is never itself a hard
# dependency.
_MIN_PLAUSIBLE_REGISTRY_BYTES = 200
if loader_path:
    try:
        _spec = importlib.util.spec_from_file_location("_aiteamforge_init_floor_mod", loader_path)
        if _spec is not None and _spec.loader is not None:
            _mod = importlib.util.module_from_spec(_spec)
            _spec.loader.exec_module(_mod)
            _MIN_PLAUSIBLE_REGISTRY_BYTES = getattr(
                _mod, "_MIN_PLAUSIBLE_REGISTRY_BYTES", _MIN_PLAUSIBLE_REGISTRY_BYTES
            )
    except Exception:
        pass  # keep the fallback

# A rendered DEFAULT_TEAMS config is never legitimately this small; if it
# ever were, something upstream (the loader import, DEFAULT_TEAMS itself) is
# already broken. Fail CLOSED: refuse and report loudly, before any tmp file
# is created, rather than writing a short/placeholder file over a possibly-
# live registry (--force makes this reachable against a live, already-
# populated registry, not just a first-time bootstrap).
_payload_bytes = len(payload.encode("utf-8"))
if _payload_bytes < _MIN_PLAUSIBLE_REGISTRY_BYTES:
    print(
        f"aiteamforge-paths-init.sh: REFUSING to write {resolved} -- payload "
        f"is only {_payload_bytes} bytes, below the "
        f"{_MIN_PLAUSIBLE_REGISTRY_BYTES}-byte plausibility floor for a real "
        f"registry (XACA-1059-006). No write performed; the file on disk "
        f"(if any) is untouched.",
        file=sys.stderr,
    )
    sys.exit(2)

try:
    lock = open(lock_path, "a")
except OSError as exc:
    print(f"aiteamforge-paths-init.sh: cannot create/open lock file {lock_path}: {exc}", file=sys.stderr)
    sys.exit(2)

with lock:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    try:
        try:
            orig_mode = stat.S_IMODE(os.stat(resolved).st_mode)
        except OSError:
            orig_mode = None

        fd, tmp_name = tempfile.mkstemp(
            prefix=f"{resolved.name}.tmp.", dir=str(resolved.parent)
        )
        tmp_path = Path(tmp_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(payload)
                f.flush()
                os.fsync(f.fileno())
            if orig_mode is not None:
                os.chmod(tmp_path, orig_mode)
            else:
                # XACA-1059: mkstemp() always creates at 0600 regardless of
                # umask -- fine for a throwaway scratch file, wrong for a
                # config meant to land at the conventional umask-respecting
                # mode. This IS the first-time-bootstrap path (no pre-
                # existing file to inherit a mode from is the common case
                # here, unlike kb-port-reconcile's writer), so silently
                # landing at 0600 instead of ~0644 is a real, easily-hit
                # behaviour change, not a corner case. Compute what a plain
                # open() would have produced under the CURRENT umask and
                # apply that instead, matching every other writer in this
                # codebase (they all use plain open(), which already
                # respects umask automatically -- existing-file mode
                # preservation above is unaffected by this branch).
                _umask = os.umask(0o022)
                os.umask(_umask)
                os.chmod(tmp_path, 0o666 & ~_umask)
            os.replace(str(tmp_path), str(resolved))
            try:
                _dir_fd = os.open(str(resolved.parent), os.O_RDONLY)
                try:
                    os.fsync(_dir_fd)
                finally:
                    os.close(_dir_fd)
            except OSError:
                pass  # best-effort -- the rename itself already succeeded
        except Exception:
            tmp_path.unlink(missing_ok=True)
            raise
    except Exception as exc:
        # XACA-1059 (PR #817 review round): a read-only target DIRECTORY (as
        # opposed to the lock file itself, handled above) still let an
        # unguarded step -- tempfile.mkstemp(), which needs to CREATE a new
        # file, unlike the lock file open() above which only needs an
        # EXISTING file to already be writable -- raise straight past every
        # other handler here as a raw Python traceback instead of a clean,
        # actionable message. Last-resort catch-all for any other
        # unanticipated write failure too.
        print(f"aiteamforge-paths-init.sh: write to {resolved} failed: {exc}", file=sys.stderr)
        sys.exit(2)
    finally:
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        # Intentionally no lock_path.unlink() -- see XACA-0794-012 note above.
PYEOF

rm -f "$_json_src"
trap - EXIT

echo "Created: $CONFIG_PATH"
echo "Teams:"
# XACA-0794-010: this listing used to re-implement the board-less check inline AND
# re-type the _ABSENT_SENTINELS tuple as a literal (None, '', 'null') — a fourth
# copy of a heuristic that already had a named owner in the loader this very script
# importlib-loads a few lines above (k501 sibling-heuristic drift). It now imports
# team_is_board_less / board_less_alias_of / _ABSENT_SENTINELS from the loader, so
# the sentinel set has exactly ONE owner and cannot drift out from under this file.
# Reads the config back from the file just written (rather than stdin) so the loader
# path can travel in argv without fighting the heredoc for stdin.
python3 - "$PYTHON_LOADER" "$CONFIG_PATH" <<'PYEOF'
import json, sys
import importlib.util
from pathlib import Path

loader_path, config_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("aiteamforge_paths", loader_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

config = json.loads(Path(config_path).read_text(encoding="utf-8"))
for team, entry in sorted(config['teams'].items()):
    port = entry.get('lcars_port')
    port_str = f'  (LCARS :{port})' if port else ''
    # Board-less teams (e.g. mainevent) carry NO kanban_dir — the key is ABSENT in
    # DEFAULT_TEAMS. An unguarded entry['kanban_dir'] subscript used to raise
    # KeyError here, killing the whole listing AFTER the config was already written.
    # The explicit marker is checked first, then the legacy sentinel forms, exactly
    # as get_team_kanban_dir() does.
    kanban_dir = entry.get('kanban_dir')
    if mod.team_is_board_less(entry) or kanban_dir in mod._ABSENT_SENTINELS:
        alias = mod.board_less_alias_of(team, entry)
        label = f'(board-less alias — use {alias!r})' if alias else '(board-less — no kanban board)'
    else:
        label = kanban_dir
    print(f'  {team:<45} {label}{port_str}')
PYEOF
