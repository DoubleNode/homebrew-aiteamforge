#!/usr/bin/env bash
# iterm2-lcars-profile-repair.sh — repair iTerm2 3.7 dynamic-profile shadowing (XACA-1661)
#
# Symptom: an LCARS tab opens another team's board. iTerm2 keeps a stale
# 'LCARS Web' Initial URL in memory and never re-reads
# DynamicProfiles/aiteamforge-lcars.json (e.g. the file said :8240, later :8280,
# while iTerm2 held :8203).
#
# Cause: iTerm2 3.7.0 moved dynamic-profile detection from a 'Dynamic' tag to
# an 'Is Dynamic Profile' key with a one-shot migration
# (NoSyncMigratedDynamicProfileTagToFlag=1). When that migration fails, saved
# profiles in com.googlecode.iterm2 ('New Bookmarks') carrying the SAME GUID as
# a dynamic profile (AITEAMFORGE-DEFAULT-PROF-0001, AITEAMFORGE-AGENT-PANEL-0001)
# shadow the dynamic file.
#
# Ownership: only saved profiles whose GUID starts with AITEAMFORGE- are ever
# removed. A saved profile shadowing some OTHER dynamic profile (third-party) is
# reported as "not touched" and never modified.
#
# Modes:
#   (default)  dry run: report shadowing entries, change nothing. Safe while
#              iTerm2 runs.
#   --apply    back up the prefs, remove the shadowing saved profiles, clear the
#              migration flag. REFUSES while iTerm2 is running (quit it first;
#              tmux sessions survive). Edits go through `defaults export` ->
#              modify -> `defaults import` so cfprefsd sees them; the plist
#              file is never written directly.
#   --verify   after relaunch: compare iTerm2's in-memory 'LCARS Web' Initial URL
#              (via the iterm2 Python API) to the dynamic profile file. Fails
#              CLOSED: no verdict (no LCARS Web loaded, API/import failure) is
#              never exit 0.
#
# Exit codes (each code has exactly one meaning):
#   0  nothing to repair (dry run), repair applied (--apply), or verify OK
#   1  --apply refused: iTerm2 is running   |  --verify: in-memory URL is STALE
#      (the URL iTerm2 holds differs from the one in the dynamic profile file)
#   2  usage or environment error (bad flag, defaults export failed, interpreter
#      not found, a dynamic profile *.json that is unreadable or malformed)
#   3  aborted: the default profile is itself a shadowing copy; not touched
#   4  dry run: repair NEEDED (run again with --apply)
#   5  --verify could not reach a verdict: iterm2 module missing, iTerm2 API
#      unreachable/failed, no profile named 'LCARS Web' is loaded in iTerm2, or
#      the loaded profile's GUID has no URL in any dynamic profile file (nothing
#      to compare against; never reported as STALE)
#
# Environment overrides (tests / non-standard installs):
#   ITERM2_PREFS_DOMAIN           prefs domain (default com.googlecode.iterm2)
#   ITERM2_DYNAMIC_PROFILES_DIR   DynamicProfiles dir
#   ITERM2_REPAIR_BACKUP_DIR      backup dir (default ~/aiteamforge-backups)
#   ITERM2_REPAIR_FAKE_RUNNING    1 = pretend iTerm2 runs, 0 = pretend it does not
#   ITERM2_REPAIR_PYTHON          interpreter for --verify (default: python3 on
#                                 PATH; iterm2_venv_bootstrap.py next to this
#                                 script re-execs it under the venv that has the
#                                 iterm2 module, same as set-lcars-profile-browser.py)
#
# Bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN="${ITERM2_PREFS_DOMAIN:-com.googlecode.iterm2}"
DYN_DIR="${ITERM2_DYNAMIC_PROFILES_DIR:-$HOME/Library/Application Support/iTerm2/DynamicProfiles}"
BACKUP_DIR="${ITERM2_REPAIR_BACKUP_DIR:-$HOME/aiteamforge-backups}"
VERIFY_PY="${ITERM2_REPAIR_PYTHON:-python3}"
MODE="--dry-run"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

if [ $# -gt 1 ]; then usage >&2; exit 2; fi
if [ $# -eq 1 ]; then MODE="$1"; fi
case "$MODE" in
  -h|--help) usage; exit 0 ;;
  --dry-run|--apply|--verify) ;;
  *) echo "usage: $0 [--dry-run|--apply|--verify|--help]" >&2; exit 2 ;;
esac

iterm2_running() {
  case "${ITERM2_REPAIR_FAKE_RUNNING:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  # -a: macOS pgrep excludes the caller's ancestors without it, and this
  # script is normally run from inside an iTerm2 pane (XACA-1341).
  # Only rc 1 means "not running"; any pgrep error counts as running so
  # --apply fails closed.
  local rc=0
  pgrep -a -xq iTerm2 || rc=$?
  [ "$rc" -ne 1 ]
}

work="$(mktemp -d "${TMPDIR:-/tmp}/iterm2-repair.XXXXXX")"
cleanup() { rm -f "$work/prefs.plist" "$work/repair.py" "$work/verify.py" "$work/err"; rmdir "$work" 2>/dev/null || true; }
trap cleanup EXIT

# Python snippet shared by both helpers: load every dynamic-profile file.
# Exits 2 (environment error) on an unreadable/malformed file, because the
# ownership set would silently be incomplete.
read -r -d '' LOAD_DYN <<'PY' || true
def load_dynamic_profiles(dyn_dir):
    """Return [(basename, profile_dict)] for every *.json in dyn_dir."""
    out = []
    for f in sorted(glob.glob(os.path.join(dyn_dir, "*.json"))):
        try:
            with open(f) as fh:
                data = json.load(fh)
            profiles = data["Profiles"]
            if not isinstance(profiles, list):
                raise ValueError("'Profiles' is not a list")
        except Exception as exc:
            print(f"ERROR: unreadable dynamic profile file {f}: {type(exc).__name__}: {exc}", file=sys.stderr)
            sys.exit(2)
        out.extend((os.path.basename(f), p) for p in profiles if isinstance(p, dict))
    return out
PY

if [ "$MODE" = "--verify" ]; then
  if ! command -v "$VERIFY_PY" >/dev/null 2>&1; then
    echo "ERROR: python interpreter '$VERIFY_PY' not found (set ITERM2_REPAIR_PYTHON)" >&2
    exit 2
  fi
  {
    echo "import asyncio, glob, json, os, sys"
    printf '%s\n' "$LOAD_DYN"
    cat <<'PY'
dyn_dir, script_dir = sys.argv[1:3]


def die(code, msg):
    print(msg, file=sys.stderr)
    sys.exit(code)


want = {}
for _f, p in load_dynamic_profiles(dyn_dir):
    if p.get("Name") == "LCARS Web" and p.get("Guid"):
        want[p["Guid"]] = p.get("Initial URL")

# iterm2 normally lives only in the venv; the shared bootstrap (next to this
# script in both the dev and share/scripts layouts) re-execs under it.
sys.path.insert(0, script_dir)
try:
    import iterm2_venv_bootstrap  # noqa: F401
except ImportError:
    pass
try:
    import iterm2
except ImportError as exc:
    die(5, f"VERIFY UNAVAILABLE: iterm2 Python module not importable: {exc}")

T = 10


async def read_loaded():
    conn = await asyncio.wait_for(iterm2.Connection.async_create(), timeout=T)
    profs = await asyncio.wait_for(iterm2.PartialProfile.async_query(conn), timeout=T)
    found = []
    for p in profs:
        if p.name == "LCARS Web":
            full = await asyncio.wait_for(p.async_get_full_profile(), timeout=T)
            found.append((p.guid, full.all_properties.get("Initial URL")))
    return found


try:
    loaded = asyncio.run(read_loaded())
except Exception as exc:
    die(5, f"VERIFY UNAVAILABLE: iTerm2 API call failed ({type(exc).__name__}: {exc})")

if not loaded:
    die(5, "VERIFY UNAVAILABLE: no profile named 'LCARS Web' is loaded in iTerm2 "
           "(relaunch iTerm2 after --apply, and check the dynamic profile file exists)")

rc = 0
for guid, have in loaded:
    if want.get(guid) is None:
        print(f"UNVERIFIABLE LCARS Web: iTerm2 guid={guid} url={have}  "
              "file=<no URL for this guid in any dynamic profile file>", file=sys.stderr)
        rc = 5 if rc == 0 else rc
    elif have != want[guid]:
        print(f"STALE LCARS Web: iTerm2={have}  file={want[guid]}")
        rc = 1
    else:
        print(f"OK   LCARS Web: iTerm2={have}  file={want[guid]}")
sys.exit(rc)
PY
  } >"$work/verify.py"
  rc=0
  # No -I on purpose: PYTHONPATH is honoured so tests can inject a fake iterm2
  # module; sys.path[0] is the private temp dir holding verify.py.
  "$VERIFY_PY" "$work/verify.py" "$DYN_DIR" "$SCRIPT_DIR" || rc=$?
  case "$rc" in
    0|1|2|5) exit "$rc" ;;
    *) echo "ERROR: verify helper died unexpectedly (rc=$rc); no verdict" >&2; exit 5 ;;
  esac
fi

if [ "$MODE" = "--apply" ] && iterm2_running; then
  echo "ERROR: iTerm2 is running. Quit iTerm2 (Cmd-Q) first - your tmux sessions survive - then re-run with --apply." >&2
  echo "       Run this from Terminal.app, not from inside iTerm2." >&2
  exit 1
fi

if ! defaults export "$DOMAIN" "$work/prefs.plist" 2>"$work/err"; then
  echo "ERROR: defaults export $DOMAIN failed: $(cat "$work/err")" >&2
  exit 2
fi

# Python helper: "plan" reports and exits 0/4/3; "apply" also rewrites the
# exported copy (never the live prefs; that goes through `defaults import`).
{
  echo "import glob, json, os, plistlib, sys"
  printf '%s\n' "$LOAD_DYN"
  cat <<'PY'
OWNED_PREFIX = "AITEAMFORGE-"
prefs_path, dyn_dir, mode = sys.argv[1:4]
with open(prefs_path, "rb") as fh:
    prefs = plistlib.load(fh)
dyn = {}
for fname, p in load_dynamic_profiles(dyn_dir):
    if p.get("Guid"):
        dyn[p["Guid"]] = (p.get("Name"), fname)
saved = prefs.get("New Bookmarks", [])
# Only AITeamForge-owned GUIDs are ever removed; other shadowed dynamic
# profiles are third-party config and are reported, never modified.
shadow = [b for b in saved if str(b.get("Guid", "")).startswith(OWNED_PREFIX) and b.get("Guid") in dyn]
foreign = [b for b in saved if not str(b.get("Guid", "")).startswith(OWNED_PREFIX) and b.get("Guid") in dyn]
shadow_ids = {id(b) for b in shadow}
keep = [b for b in saved if id(b) not in shadow_ids]
default_guid = prefs.get("Default Bookmark Guid")
flag = prefs.get("NoSyncMigratedDynamicProfileTagToFlag")
print(f"saved profiles: {len(saved)}   dynamic-profile GUIDs on disk: {len(dyn)}")
for b in shadow:
    name, f = dyn[b["Guid"]]
    print(f"  SHADOW: saved '{b.get('Name')}' {b['Guid']}  (dynamic '{name}' in {f})")
for b in foreign:
    name, f = dyn[b["Guid"]]
    print(f"  NOTE (not touched, not AITeamForge-owned): saved '{b.get('Name')}' {b['Guid']}  (dynamic '{name}' in {f})")
print(f"  NoSyncMigratedDynamicProfileTagToFlag = {flag!r}")
if any(b.get("Guid") == default_guid for b in shadow):
    print(f"ABORT: the default profile ({default_guid}) is one of the shadowing copies; not touching it.")
    sys.exit(3)
if not shadow and flag is None:
    print("Nothing to repair.")
    sys.exit(0)
if mode != "apply":
    print("DRY RUN: repair needed, nothing changed. Quit iTerm2, then re-run with --apply.")
    sys.exit(4)
prefs["New Bookmarks"] = keep
prefs.pop("NoSyncMigratedDynamicProfileTagToFlag", None)
with open(prefs_path, "wb") as fh:
    plistlib.dump(prefs, fh, fmt=plistlib.FMT_BINARY)
print(f"Removed {len(shadow)} shadowing saved profile(s); cleared the migration flag.")
PY
} >"$work/repair.py"

# Map anything unexpected (e.g. a traceback's exit 1) to 2 so it can never be
# mistaken for "apply refused".
run_helper() {
  local hrc=0
  python3 -I "$work/repair.py" "$work/prefs.plist" "$DYN_DIR" "$1" || hrc=$?
  case "$hrc" in
    0|2|3|4) return "$hrc" ;;
    *) echo "ERROR: repair helper failed unexpectedly (rc=$hrc)" >&2; return 2 ;;
  esac
}

# Always analyse first (read-only) so the backup precedes any edit.
rc=0
run_helper plan || rc=$?
if [ "$MODE" != "--apply" ]; then exit "$rc"; fi
if [ "$rc" -ne 4 ]; then exit "$rc"; fi      # 0 nothing to repair; 3 abort; 2 error

mkdir -p "$BACKUP_DIR"
backup="$BACKUP_DIR/iterm2-prefs-$(date +%Y%m%d-%H%M%S).plist"
defaults export "$DOMAIN" "$backup"
echo "Backup written: $backup   (restore: defaults import $DOMAIN \"$backup\")"

run_helper apply || exit $?
defaults import "$DOMAIN" "$work/prefs.plist"
# `defaults import` MERGES top-level keys (a key absent from the file survives),
# so the migration flag removal must be an explicit cfprefsd-mediated delete.
defaults delete "$DOMAIN" NoSyncMigratedDynamicProfileTagToFlag 2>/dev/null || true
echo "Done. Relaunch iTerm2, restart the team, then run: $0 --verify"
