#!/bin/bash
# lcars-restart-manifest.sh
# Cross-process handoff so `aiteamforge restart lcars` stops and starts the SAME
# set of LCARS servers.  (XACA-0799)
#
# ═══════════════════════════════════════════════════════════════════════════════
# THE BUG THIS EXISTS TO FIX
# ═══════════════════════════════════════════════════════════════════════════════
# `aiteamforge restart` is literally two processes:
#     aiteamforge-stop.sh  "$@"   &&   exec aiteamforge-start.sh "$@"
# (bin/aiteamforge-cli.sh). They share no memory, so the two phases were free to
# disagree about which teams exist — and they did:
#
#   STOP  — stop_lcars() is a DELIBERATE kill-all. It matches `server\.py [0-9]`
#           with no port, so it reaps EVERY LCARS server on the box, including
#           the ones a per-team `*-startup.sh` launched by hand.
#   START — start_lcars() iterates ONLY `.teams[]` from .aiteamforge-config.
#
# On M4Mini (v0.17.7, i.e. WITH the XACA-0792 instance-id fix already in place) an
# lcars-ui refresh fired lcars-watch → `aiteamforge restart lcars`. STOP killed all
# 8 running servers; START relaunched the 1 team in `.teams[]` (finance-personal,
# port 8361). ios/android/firebase/academy/dns/command/legal were all DOWN. The
# 300s `lcars-health` LaunchAgent restored them ~5 minutes later — so every restart
# cost a fleet-wide LCARS outage of up to 5 minutes.
#
# XACA-0792 fixed "start skips project-scoped teams". This is the REMAINING half:
# start skips teams that were never in `.teams[]` at all.
#
# ═══════════════════════════════════════════════════════════════════════════════
# WHY CAPTURE-AND-RESTORE, NOT NARROW-THE-TEARDOWN
# ═══════════════════════════════════════════════════════════════════════════════
# The obvious alternative is to scope STOP to the same set START will bring back
# (i.e. kill only `.teams[]` teams). That was rejected:
#
#   * It does not restart the stranded servers, it merely SPARES them. The whole
#     reason lcars-watch calls restart is that lcars-ui changed on disk — the
#     spared servers would keep serving STALE code, indefinitely and invisibly.
#     That trades a loud 5-minute outage for silent permanent staleness. Worse.
#   * It is not actually symmetric. It narrows stop to match a start set that is
#     still wrong; the manually-started teams remain outside BOTH phases forever.
#
# Capturing the running set makes the two phases symmetric BY CONSTRUCTION: start
# restores exactly what stop tore down, so every server is genuinely restarted
# onto the new code AND comes back. The captured set is the union'd superset of
# `.teams[]`, never a replacement for it.
#
# ═══════════════════════════════════════════════════════════════════════════════
# CRASH SAFETY
# ═══════════════════════════════════════════════════════════════════════════════
#   * The manifest is written BEFORE the first kill. A crash mid-teardown still
#     leaves a complete record on disk for the next start to consume.
#   * Writes are atomic (temp file in the same directory + rename), so a reader
#     never observes a half-written manifest.
#   * The manifest carries a written_at stamp and is IGNORED once older than
#     LCARS_RESTART_MANIFEST_TTL (default 600s). A stop whose start never happened
#     cannot resurrect a long-dead topology days later.
#   * An absent, stale, or empty manifest degrades start to its historical
#     `.teams[]`-only behavior — never a hard failure.
#   * start clears the manifest only once every team named in it is actually
#     serving. If a restore is partial the record SURVIVES, so both a subsequent
#     `aiteamforge start` and the lcars-health LaunchAgent get another chance.
#
# ═══════════════════════════════════════════════════════════════════════════════
# LAYERING (why the seams are where they are)
# ═══════════════════════════════════════════════════════════════════════════════
# Exactly one function touches the process table (lcars_running_lcars_ports). The
# mapping, serialization, and freshness layers are pure and stream-oriented, which
# is what lets the regression suite exercise them against synthetic port lists
# instead of spawning real servers. Production takes the same path; there is no
# test-only branch anywhere in this file.

# Guard against double-sourcing (stop.sh and start.sh both pull this in, and a
# future caller may source it alongside a lib that already did).
if [ -n "${_LCARS_RESTART_MANIFEST_SOURCED:-}" ]; then
  return 0 2>/dev/null || true
fi
_LCARS_RESTART_MANIFEST_SOURCED=1

# ─────────────────────────────────────────────────────────────────────────────
# Paths and tunables
# ─────────────────────────────────────────────────────────────────────────────

# Runtime directory. Matches the ccusage collector convention established in
# XACA-0385 (~/.aiteamforge/run, mode 0700, owner-only) rather than world-writable
# /tmp — this file names which services to launch, so a writable path would be a
# straightforward injection vector.
lcars_restart_runtime_dir() {
  if [ -n "${LCARS_RESTART_RUNTIME_DIR:-}" ]; then
    echo "$LCARS_RESTART_RUNTIME_DIR"
  else
    echo "${HOME}/.aiteamforge/run"
  fi
}

lcars_restart_manifest_path() {
  echo "$(lcars_restart_runtime_dir)/lcars-restart-manifest"
}

# Seconds after which a manifest is considered stale and ignored.
lcars_restart_manifest_ttl() {
  echo "${LCARS_RESTART_MANIFEST_TTL:-600}"
}

# Create the runtime dir 0700 if absent. Refuses to use a symlink (symlink-swap
# would redirect the manifest write to an attacker-chosen path).
_lcars_restart_ensure_runtime_dir() {
  local dir
  dir=$(lcars_restart_runtime_dir)

  if [ -L "$dir" ]; then
    echo "lcars-restart-manifest: runtime dir is a symlink, refusing: ${dir}" >&2
    return 1
  fi

  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 700 "$dir" 2>/dev/null || true
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Layer 1 (impure) — what is actually running right now
# ─────────────────────────────────────────────────────────────────────────────

# lcars_running_lcars_ports
# Prints one port per line for every running LCARS server, deduplicated + sorted.
#
# The matcher is intentionally IDENTICAL to stop_lcars()'s kill-all matcher
# (`server\.py [0-9]`, XACA-0560). That is the entire point: the capture must see
# precisely the population the teardown is about to kill. If someone ever narrows
# one of the two, they MUST narrow the other or this whole mechanism silently
# under-captures and we are back to stranding servers.
lcars_running_lcars_ports() {
  local pids pid port
  pids=$(pgrep -f "server\.py [0-9]" 2>/dev/null || true)

  [ -z "$pids" ] && return 0

  # Iterate line-by-line via read rather than `for pid in $pids`. The
  # word-splitting form is NOT portable: zsh does not split unquoted parameter
  # expansions, so under zsh the loop would run ONCE with the whole multi-line
  # PID blob as a single value, every ps lookup would fail, and this function
  # would return an EMPTY port set while still exiting 0. That is the worst
  # possible failure shape here — a vacuous success writes an empty manifest,
  # start restores nothing, and the outage returns looking entirely healthy.
  printf '%s\n' "$pids" | while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    # Recover the port from the process args. `python3 server.py 8203` → 8203.
    #
    # Anchored on `server.py` and taking the token IMMEDIATELY after it. A
    # right-to-left "last all-numeric token" scan looks equivalent and is not:
    # it returns the LAST number on the line, so any trailing numeric argument
    # (`server.py 8203 --workers 2`) yields 2 and the manifest records a port no
    # team owns. Anchoring is what actually tolerates trailing flags.
    port=$(ps -o args= -p "$pid" 2>/dev/null \
      | sed -n 's/.*server\.py[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p')
    [ -n "$port" ] && echo "$port"
  done | sort -un

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Layer 2 (pure) — port → team
# ─────────────────────────────────────────────────────────────────────────────

# lcars_port_to_team <port>
# Prints the team INSTANCE id that owns <port>, or returns 1 with no output.
#
# Reverse-maps through the SAME registry helpers start_lcars() uses forward
# (aiteamforge_list_teams + aiteamforge_team_lcars_port) instead of re-parsing
# team-paths.json. XACA-0792 was caused by exactly that mistake — a second,
# competing derivation that disagreed with the canonical one — so this defers
# rather than reimplements.
#
# READ-ONLY: aiteamforge_team_lcars_port() materializes a default registry on
# first lookup when none exists. `stop` must not create state just by being run
# (the precedent aiteamforge-status.sh set in XACA-0792-001), so when the registry
# file is absent this maps nothing and the caller degrades to `.teams[]`-only.
lcars_port_to_team() {
  local want="$1"
  [ -z "$want" ] && return 1

  # The helpers must be sourced by the caller; without them we cannot map.
  command -v aiteamforge_list_teams >/dev/null 2>&1 || return 1
  command -v aiteamforge_team_lcars_port >/dev/null 2>&1 || return 1

  local registry
  registry=$(aiteamforge_config_path 2>/dev/null || true)
  [ -n "$registry" ] && [ ! -f "$registry" ] && return 1

  local team port
  while IFS= read -r team; do
    [ -z "$team" ] && continue
    port=$(aiteamforge_team_lcars_port "$team" 2>/dev/null) || continue
    if [ "$port" = "$want" ]; then
      echo "$team"
      return 0
    fi
  done < <(aiteamforge_list_teams 2>/dev/null)

  return 1
}

# lcars_ports_to_manifest
# Reads ports on stdin (one per line), writes `<team><TAB><port>` on stdout.
#
# Ports that reverse-map to no known team are emitted with the sentinel team id
# "-". They are recorded rather than dropped so the manifest stays an honest
# census of what was killed, and so start can warn about a server it cannot
# relaunch (LCARS_TEAM is mandatory since XACA-0555 — there is no way to start a
# server for an unidentifiable port).
lcars_ports_to_manifest() {
  local port team
  while IFS= read -r port; do
    [ -z "$port" ] && continue
    case "$port" in
      *[!0-9]*) continue ;;
    esac
    team=$(lcars_port_to_team "$port" 2>/dev/null) || team="-"
    [ -z "$team" ] && team="-"
    printf '%s\t%s\n' "$team" "$port"
  done
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Layer 3 (pure-ish) — serialization
# ─────────────────────────────────────────────────────────────────────────────

# lcars_restart_manifest_write
# Reads `<team><TAB><port>` lines on stdin and writes the manifest atomically.
#
# Always writes, even when stdin is empty: an empty manifest is a MEANINGFUL
# record ("nothing was running, so restore nothing"), and it also overwrites any
# earlier manifest that would otherwise linger and be replayed.
lcars_restart_manifest_write() {
  local manifest tmp
  manifest=$(lcars_restart_manifest_path)

  _lcars_restart_ensure_runtime_dir || return 1

  tmp=$(mktemp "${manifest}.XXXXXX" 2>/dev/null) || return 1

  {
    echo "# aiteamforge LCARS restart manifest (XACA-0799)"
    echo "# Written by \`aiteamforge stop lcars\` immediately BEFORE teardown."
    echo "# Consumed by \`aiteamforge start\` to restore the same server set."
    echo "# Format: <team-instance-id><TAB><port>   ('-' = port owned by no known team)"
    echo "written_at=$(date +%s)"
    cat
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }

  chmod 600 "$tmp" 2>/dev/null || true

  # Atomic publish — a concurrent reader sees either the old file or the new one,
  # never a partial write.
  mv -f "$tmp" "$manifest" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }

  return 0
}

# lcars_restart_manifest_capture
# The one convenience wrapper for callers: snapshot the live server set to disk.
# stop_lcars() calls exactly this, before it kills anything.
lcars_restart_manifest_capture() {
  lcars_running_lcars_ports | lcars_ports_to_manifest | lcars_restart_manifest_write
}

# lcars_restart_manifest_age
# Prints the manifest's age in seconds, or returns 1 if absent/unreadable/unstamped.
lcars_restart_manifest_age() {
  local manifest stamp now
  manifest=$(lcars_restart_manifest_path)
  [ -f "$manifest" ] || return 1

  stamp=$(grep -m1 '^written_at=' "$manifest" 2>/dev/null | cut -d= -f2)
  [ -z "$stamp" ] && return 1
  case "$stamp" in
    *[!0-9]*) return 1 ;;
  esac

  now=$(date +%s)
  echo "$(( now - stamp ))"
  return 0
}

# lcars_restart_manifest_is_fresh
# True (0) when a manifest exists and is younger than the TTL.
lcars_restart_manifest_is_fresh() {
  local age ttl
  age=$(lcars_restart_manifest_age) || return 1
  ttl=$(lcars_restart_manifest_ttl)

  if [ "$age" -lt 0 ]; then
    # Clock moved backwards (NTP step, timezone-independent but still possible).
    # Treat as fresh rather than silently discarding a just-written manifest.
    return 0
  fi

  if [ "$age" -le "$ttl" ]; then
    return 0
  fi
  return 1
}

# lcars_restart_manifest_teams
# Prints one team instance id per line from a FRESH manifest; prints nothing (and
# returns 0) when the manifest is absent, stale, or empty. Unmappable "-" entries
# are filtered here — lcars_restart_manifest_unmapped_ports reports those.
#
# Returning 0 on "no manifest" is deliberate: start.sh runs under `set -eo
# pipefail`, and a missing manifest is a normal state, not an error.
lcars_restart_manifest_teams() {
  local manifest team port
  manifest=$(lcars_restart_manifest_path)

  lcars_restart_manifest_is_fresh || return 0

  while IFS=$'\t' read -r team port; do
    case "$team" in
      '#'*|written_at=*|'') continue ;;
      '-') continue ;;
    esac
    echo "$team"
  done < "$manifest"

  return 0
}

# lcars_restart_manifest_unmapped_ports
# Prints the ports from a fresh manifest that mapped to no team, so start can say
# so out loud rather than dropping them on the floor.
lcars_restart_manifest_unmapped_ports() {
  local manifest team port
  manifest=$(lcars_restart_manifest_path)

  lcars_restart_manifest_is_fresh || return 0

  while IFS=$'\t' read -r team port; do
    [ "$team" = "-" ] && [ -n "$port" ] && echo "$port"
  done < "$manifest"

  return 0
}

# lcars_restart_manifest_clear
# Remove the manifest. Called by start ONLY after a fully successful restore.
lcars_restart_manifest_clear() {
  rm -f "$(lcars_restart_manifest_path)" 2>/dev/null || true
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Layer 4 (pure) — the symmetry contract itself
# ─────────────────────────────────────────────────────────────────────────────

# _lcars_restart_resolve_key <team-id>
# Normalize an id to the registry INSTANCE key when the resolver is available,
# else echo it unchanged. Degrading to the raw id keeps this library usable when
# sourced standalone, and matches what start_lcars() would do anyway.
_lcars_restart_resolve_key() {
  local id="$1"
  [ -z "$id" ] && return 1

  if command -v aiteamforge_resolve_team_key >/dev/null 2>&1; then
    local key=""
    key=$(aiteamforge_resolve_team_key "$id" 2>/dev/null) || key=""
    if [ -n "$key" ]; then
      echo "$key"
      return 0
    fi
  fi

  echo "$id"
  return 0
}

# lcars_restart_union_teams <configured-teams-space-separated>
# Prints the deduplicated set start must launch: the configured `.teams[]` teams
# PLUS every team captured in a fresh manifest. Order is stable — configured
# teams first (preserving historical start order), captured extras appended.
#
# This is THE symmetry contract, isolated in one pure function precisely so the
# regression suite can assert on it directly.
#
# DEDUPES IN RESOLVED-KEY SPACE, AND EMITS RESOLVED KEYS. This is load-bearing,
# not tidiness: `.teams[]` holds BASE ids ("finance") while the manifest holds
# registry INSTANCE ids ("finance-personal"), and those two name the SAME server
# (XACA-0792). A naive string dedupe lets both through, so start processes one
# server twice — the second pass finding it already serving and emitting a
# confusing "LCARS already running" warning on a fresh restart. The equivalence
# is only visible after resolution, so the dedupe has to happen there.
lcars_restart_union_teams() {
  local configured="$1"
  local seen=" "
  local t key

  # Split on whitespace via tr + read rather than an unquoted `for t in
  # $configured`. zsh does not word-split unquoted expansions, so the loop form
  # would treat the entire ".teams[]" string as ONE team id, resolve it to
  # nothing, and silently drop every configured team from the union. Same class
  # of trap as the PID loop in lcars_running_lcars_ports.
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    key=$(_lcars_restart_resolve_key "$t")
    case "$seen" in
      *" ${key} "*) continue ;;
    esac
    seen="${seen}${key} "
    echo "$key"
  done < <(printf '%s\n' "$configured" | tr ' \t' '\n\n')

  while IFS= read -r t; do
    [ -z "$t" ] && continue
    key=$(_lcars_restart_resolve_key "$t")
    case "$seen" in
      *" ${key} "*) continue ;;
    esac
    seen="${seen}${key} "
    echo "$key"
  done < <(lcars_restart_manifest_teams)

  return 0
}
