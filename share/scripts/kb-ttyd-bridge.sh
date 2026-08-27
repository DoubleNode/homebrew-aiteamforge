#!/usr/bin/env bash
# kb-ttyd-bridge.sh — provision the ttyd terminal-bridge LaunchAgents (XACA-0161-002)
#
# Renders and installs ONE launchd job per (team, terminal) pair, each running a
# loopback-bound, read-only `ttyd` attached to that terminal's tmux session, so
# XACA-0161-003's in-server reverse proxy has something to proxy to.
#
# USAGE
#   kb-ttyd-bridge.sh ports [--team <team>]    Print the computed port table
#   kb-ttyd-bridge.sh check-ports              Collision audit over ALL configured
#                                              teams; exit 1 if anything collides
#   kb-ttyd-bridge.sh reconcile [--dry-run]    THE idempotent entry point (below)
#   kb-ttyd-bridge.sh install                  Alias for reconcile
#   kb-ttyd-bridge.sh uninstall [--team <t>]   Unload + remove bridge plists
#   kb-ttyd-bridge.sh status [--team <t>]      What is loaded / listening
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THERE IS ONE `reconcile` AND NOT SEPARATE install/upgrade PATHS
# ─────────────────────────────────────────────────────────────────────────────
# "Install-time provisioning that never runs on upgrade" is a RECURRING defect
# class in this codebase, not a hypothetical:
#
#   XACA-0734  every NET-NEW mandatory LaunchAgent was permanently unreachable on
#              already-installed boxes, because upgrade skipped any plist that was
#              absent — including com.aiteamforge.auto-upgrade.plist, the agent
#              that PERFORMS upgrades. Self-sealing: the box could never receive
#              the fix that would have installed it.
#   XACA-0673  upgraded machines got a refreshed importer but never the module it
#              imports, because the sweep only refreshed targets already on disk.
#   XACA-0814  `aiteamforge upgrade` never regenerated *-connect.sh at all.
#   XACA-0395  kb-api-key shipped only through install_helper_scripts(), which is
#              called from setup.sh and NEVER from the upgrade command.
#
# The shape is always the same: two code paths, one of which is forgotten. So
# this script has exactly ONE state-changing path — `reconcile` — which is
# level-triggered rather than edge-triggered. It compares desired state (config +
# board terminals map) against actual state (plists on disk) and converges:
# renders what is missing, refreshes what has drifted, prunes what is no longer
# wanted. Running it twice is the same as running it once; running it on a fresh
# install and on an upgrade are the same operation. There is no "upgrade path" to
# forget to wire up, because there is no separate install path to diverge from.
#
# VERIFIED (2026-08-26, ttyd 1.7.7, this machine):
#   * `-i lo0` binds 127.0.0.1 ONLY: lsof showed a single 127.0.0.1:<port> LISTEN
#     and a probe from this host's LAN address returned exit=7.
#   * `-H X-WEBAUTH-USER` makes ttyd answer 407 to any request with a missing OR
#     EMPTY header value, on the index and /token alike — not just on /ws.
#     Supplying `X-WEBAUTH-USER: lcars` returns 200. The proxy MUST inject this
#     header on EVERY proxied request.
#   * Without -W ttyd logs "will start in readonly mode".
#   * ttyd accepts `<options> <command> <args...>` with no `--` separator, and
#     passes `-f ignore-size` through to tmux untouched.
#
# DEPENDENCIES: python3 (board/config JSON + port arithmetic). No jq: this script
# must parse the kanban board, and the board is read elsewhere in this repo with
# python3.
#
# ─────────────────────────────────────────────────────────────────────────────
# TAP-SIDE WIRING — REQUIRED, AND NOT YET APPLIED
# ─────────────────────────────────────────────────────────────────────────────
# This file and its template are CANONICAL SOURCE in dev-team and are mirrored to
# the tap by sync-tap.sh (both sync_file entries are already added). But
# `libexec/` is NOT mirrored by sync-tap.sh — it is tap-native with no dev-team
# source — so the three call-site edits below must be made INSIDE the
# homebrew-tap submodule, which was uninitialized in the worktree where this was
# written. They are listed here so the wiring cannot be silently forgotten; an
# unwired reconciler is inert, which is precisely the XACA-0814 failure shape.
#
#   1. libexec/commands/aiteamforge-upgrade.sh
#      _xaca0673_mandatory_materialize_basenames() — add:
#          kb-ttyd-bridge.sh
#      WHY: update_runtime_helpers' self-maintaining *.sh glob sweep refreshes
#      only targets that ALREADY exist in WORKING_DIR/scripts/. This is a
#      brand-new file, so on every already-installed box the target is absent and
#      the sweep's default rule skips it forever. This is the exact XACA-0774 /
#      XACA-0395 case, and the reason those entries exist.
#
#   2. libexec/commands/aiteamforge-upgrade.sh
#      Add a call to the top-level run sequence (the flat `update_*` list),
#      AFTER update_runtime_helpers (which is what materializes this script):
#          update_ttyd_bridge
#      with:
#          update_ttyd_bridge() {
#            print_section "Terminal Bridge"
#            local s="${WORKING_DIR}/scripts/kb-ttyd-bridge.sh"
#            [ -x "$s" ] || return 0
#            if [ "$DRY_RUN" = true ]; then "$s" reconcile --dry-run; else "$s" reconcile; fi
#          }
#      Reconcile is a no-op when the feature is disabled (the default), so this
#      is safe to run unconditionally on every box.
#
#   3. libexec/installers/install-kanban.sh
#      Call the SAME entry point from install_kanban_system(), next to
#      install_cr_confluence_poller_launchagent:
#          "$AITEAMFORGE_DIR/scripts/kb-ttyd-bridge.sh" reconcile || true
#      Install and upgrade deliberately share ONE command; see the reconcile
#      rationale above.
#
#   NOT wanted: an entry in _xaca0734_launchagent_map / the mandatory set in
#   libexec/lib/launchagents.sh. That map is for STATIC, singleton plist
#   basenames rendered by _render_launchagent_template; these agents are
#   per-(team, terminal), dynamic, and config-gated OFF by default — the same
#   reasons com.aiteamforge.cr-confluence-poller is deliberately excluded from
#   that map. Force-materializing a terminal bridge on boxes that never asked for
#   one would be actively wrong.

set -uo pipefail

#──────────────────────────────────────────────────────────────────────────────
# Sandbox-overridable locations. Every path this script writes to is overridable
# so the whole thing can be exercised against a TEST_TMP_DIR without going
# anywhere near ~/Library/LaunchAgents.
#──────────────────────────────────────────────────────────────────────────────
KB_TTYD_LAUNCHAGENTS_DIR="${KB_TTYD_LAUNCHAGENTS_DIR:-$HOME/Library/LaunchAgents}"
KB_TTYD_TEAM_PATHS="${KB_TTYD_TEAM_PATHS:-$HOME/.aiteamforge/team-paths.json}"
KB_TTYD_CONFIG="${KB_TTYD_CONFIG:-$HOME/.aiteamforge/ttyd-bridge.json}"
KB_TTYD_OPTOUT_FILE="${KB_TTYD_OPTOUT_FILE:-${AITF_LAUNCHAGENT_OPTOUT_FILE:-$HOME/.aiteamforge/launchagents.optout}}"
KB_TTYD_LOG_DIR="${KB_TTYD_LOG_DIR:-$HOME/Library/Logs/aiteamforge/ttyd-bridge}"
_KB_TTYD_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
KB_TTYD_TEMPLATE="${KB_TTYD_TEMPLATE:-}"

# Tests may point launchctl at a stub; the real binary is the default.
KB_TTYD_LAUNCHCTL="${KB_TTYD_LAUNCHCTL:-launchctl}"

LABEL_PREFIX="com.aiteamforge.ttyd-bridge"

# Port scheme constants — see _ttyd_port() for the derivation and its rationale.
TTYD_PORT_BASE=21000
LCARS_BAND_FLOOR=8000
LCARS_BAND_CEIL=8999
SLOTS_PER_TEAM=16

DRY_RUN=false
ONLY_TEAM=""

_say()  { printf '%s\n' "$*"; }
_info() { printf '  %s\n' "$*"; }
_warn() { printf 'WARNING: %s\n' "$*" >&2; }
_err()  { printf 'ERROR: %s\n' "$*" >&2; }

#──────────────────────────────────────────────────────────────────────────────
# Template resolution — works from the dev repo, from a tap checkout, and from
# an installed working dir, in that order of specificity.
#──────────────────────────────────────────────────────────────────────────────
_resolve_template() {
    if [ -n "$KB_TTYD_TEMPLATE" ]; then
        printf '%s\n' "$KB_TTYD_TEMPLATE"; return 0
    fi
    local c
    for c in \
        "${_KB_TTYD_SELF_DIR}/templates/ttyd-bridge-launchagent.template.plist" \
        "${_KB_TTYD_SELF_DIR}/../share/templates/terminal-bridge/ttyd-bridge-launchagent.template.plist" \
        "${AITEAMFORGE_DIR:-$HOME/aiteamforge}/share/templates/terminal-bridge/ttyd-bridge-launchagent.template.plist"
    do
        [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

#──────────────────────────────────────────────────────────────────────────────
# PORT ALLOCATION
#──────────────────────────────────────────────────────────────────────────────
#   port(team, idx) = TTYD_PORT_BASE
#                   + (lcars_port - LCARS_BAND_FLOOR) * SLOTS_PER_TEAM
#                   + idx
#
# Deterministic: derived entirely from the team's ALREADY-UNIQUE LCARS port
# (the authoritative registry value in team-paths.json) plus the terminal's
# index in the board's terminals map, sorted by name. No state, no allocation
# file, no "next free port" scan that could hand out different answers on two
# machines or on two runs.
#
# Collision-free BY CONSTRUCTION: distinct LCARS ports are distinct integers, so
# multiplying by SLOTS_PER_TEAM maps each team to a disjoint block of 16
# consecutive ports. Two teams can only collide if they share an LCARS port —
# which would already be a fatal LCARS misconfiguration, and which check-ports
# reports explicitly rather than silently papering over.
#
# WHY 16 SLOTS AND NOT 4 OR 8. Academy has 4 terminals, and 4 is the number the
# interface contract quotes — but academy is NOT representative. Measured across
# every configured team's board on this machine, the maximum is SEVEN
# (android, dns, firebase). A block of 8 would leave exactly one spare slot for
# the widest team on the fleet today; 16 leaves nine. This is the cheap half of
# the tradeoff — the ports are free and the band has room — and the expensive
# half is a team quietly gaining an eighth terminal and stepping on its
# neighbour's block.
#
# WHY THE BLOCKS MUST BE MULTIPLIED AND NOT MERELY OFFSET. The naive scheme
# `lcars_port + K + idx` is broken on this exact fleet: the mainevent LCARS
# ports are CONSECUTIVE (8400, 8401, 8402, 8403, 8404, 8405). Any scheme that
# adds a small per-terminal increment to a base one apart overlaps its
# neighbour immediately — mainevent's terminal 1 would land on
# mainevent-dev-team's terminal 0. Multiplication is what makes the blocks
# disjoint regardless of how tightly the LCARS ports are packed.
#
# BAND CHOICE. 21000-36999 (the full range this scheme can emit for a valid
# 8000-8999 LCARS port) sits above every LCARS band in use (8180-8405, plus
# freelance at 8500-8600) and below macOS's ephemeral floor, measured on this
# machine as net.inet.ip.portrange.first = 49152. Nothing here can be handed out
# by the kernel as a source port, and nothing here can collide with LCARS.
#
# FAILS CLOSED. An LCARS port outside 8000-8999 makes the arithmetic meaningless
# (it could go negative or overshoot the ephemeral floor), so the team is
# REFUSED and reported, never assigned a computed-anyway port.
_ttyd_port() {
    local lcars_port="$1" idx="$2"
    case "$lcars_port" in ''|*[!0-9]*) return 1 ;; esac
    case "$idx" in ''|*[!0-9]*) return 1 ;; esac
    [ "$lcars_port" -ge "$LCARS_BAND_FLOOR" ] || return 1
    [ "$lcars_port" -le "$LCARS_BAND_CEIL" ] || return 1
    [ "$idx" -lt "$SLOTS_PER_TEAM" ] || return 1
    printf '%s\n' "$(( TTYD_PORT_BASE + (lcars_port - LCARS_BAND_FLOOR) * SLOTS_PER_TEAM + idx ))"
}

#──────────────────────────────────────────────────────────────────────────────
# Desired-state enumeration.
#
# Emits one TSV row per (team, terminal) the machine SHOULD have a bridge for:
#     <team>\t<terminal>\t<idx>\t<lcars_port>\t<ttyd_port>
# Rows are derived from team-paths.json (which teams exist + their LCARS port)
# joined against each team's board `terminals` map (which terminals exist).
#
# Teams whose LCARS port is out of band, or whose kanban dir holds zero or more
# than one *-board.json, are reported on stderr and SKIPPED — never guessed at.
#──────────────────────────────────────────────────────────────────────────────
_enumerate_desired() {
    TTYD_PORT_BASE="$TTYD_PORT_BASE" \
    LCARS_BAND_FLOOR="$LCARS_BAND_FLOOR" \
    LCARS_BAND_CEIL="$LCARS_BAND_CEIL" \
    SLOTS_PER_TEAM="$SLOTS_PER_TEAM" \
    KB_TTYD_TEAM_PATHS="$KB_TTYD_TEAM_PATHS" \
    ONLY_TEAM="$ONLY_TEAM" \
    python3 - <<'PY'
import json, os, sys, glob, re

base   = int(os.environ["TTYD_PORT_BASE"])
floor  = int(os.environ["LCARS_BAND_FLOOR"])
ceil_  = int(os.environ["LCARS_BAND_CEIL"])
slots  = int(os.environ["SLOTS_PER_TEAM"])
only   = os.environ.get("ONLY_TEAM") or ""
tp     = os.environ["KB_TTYD_TEAM_PATHS"]

NAME_RE = re.compile(r'^[a-zA-Z0-9_-]+$')

try:
    with open(tp) as fh:
        doc = json.load(fh)
except Exception as exc:
    print(f"cannot read team-paths registry {tp}: {exc}", file=sys.stderr)
    sys.exit(2)

teams = doc.get("teams", doc)
if not isinstance(teams, dict):
    print(f"team-paths registry has no usable teams map: {tp}", file=sys.stderr)
    sys.exit(2)

for team in sorted(teams):
    if only and team != only:
        continue
    meta = teams[team]
    if not isinstance(meta, dict):
        continue
    if not NAME_RE.match(team):
        print(f"skip team {team!r}: name must match [a-zA-Z0-9_-]+ to form a launchd label",
              file=sys.stderr)
        continue

    port = meta.get("lcars_port", meta.get("port"))
    try:
        port = int(port)
    except (TypeError, ValueError):
        print(f"skip team {team!r}: no numeric lcars_port in registry", file=sys.stderr)
        continue
    if not (floor <= port <= ceil_):
        print(f"skip team {team!r}: lcars_port {port} outside {floor}-{ceil_}; "
              f"port derivation would be meaningless", file=sys.stderr)
        continue

    kdir = meta.get("kanban_dir") or meta.get("kanban_path") or ""
    kdir = os.path.expanduser(kdir) if kdir else ""
    if not kdir or not os.path.isdir(kdir):
        print(f"skip team {team!r}: kanban dir not present ({kdir or 'unset'})", file=sys.stderr)
        continue

    boards = sorted(glob.glob(os.path.join(kdir, "*-board.json")))
    if len(boards) != 1:
        print(f"skip team {team!r}: expected exactly 1 *-board.json in {kdir}, found {len(boards)}",
              file=sys.stderr)
        continue

    try:
        with open(boards[0]) as fh:
            board = json.load(fh)
    except Exception as exc:
        print(f"skip team {team!r}: cannot parse {boards[0]}: {exc}", file=sys.stderr)
        continue

    terminals = board.get("terminals")
    if not isinstance(terminals, dict) or not terminals:
        print(f"skip team {team!r}: board has no terminals map", file=sys.stderr)
        continue

    # Sorted by name so the index -> port mapping is stable across runs and
    # machines. Dict order in the JSON is NOT a contract.
    #
    # FILTER BEFORE INDEXING -- this ordering is load-bearing and must match
    # lcars_terminal.terminal_names() exactly. That function drops names failing
    # the shape check and THEN indexes the survivors. An earlier version of this
    # script indexed first and skipped invalid names inside the loop, so a board
    # containing one unusable name gave every later terminal a DIFFERENT index
    # here than the proxy computed -- e.g. {alpha, "bad name!", charlie} yields
    # charlie=2 in the shell and charlie=1 in Python. The LaunchAgent would then
    # listen on one port while the proxy dialled another, and with enough
    # terminals the proxy lands on a DIFFERENT AGENT'S SHELL. Silent, and the
    # worst failure this component can produce.
    #
    # Latent today (all 10 boards have only valid names), which is exactly why
    # it needs to be structural rather than left to chance.
    names = sorted(t for t in terminals if isinstance(t, str) and NAME_RE.match(t))
    for bad in sorted(t for t in terminals if not (isinstance(t, str) and NAME_RE.match(t))):
        print(f"skip {team}/{bad!r}: terminal name must match [a-zA-Z0-9_-]+ "
              f"(dropped BEFORE indexing, to stay in step with the proxy)",
              file=sys.stderr)
    if not names:
        print(f"skip team {team!r}: no terminal names survive the shape check", file=sys.stderr)
        continue
    if len(names) > slots:
        print(f"skip team {team!r}: {len(names)} terminals exceeds {slots} slots per team; "
              f"raise SLOTS_PER_TEAM (this changes every port)", file=sys.stderr)
        continue

    for idx, term in enumerate(names):
        print(f"{team}\t{term}\t{idx}\t{port}\t{base + (port - floor) * slots + idx}")
PY
}

#──────────────────────────────────────────────────────────────────────────────
# Config gate. DISABLED BY DEFAULT.
#
# A terminal bridge is a shell-adjacent network surface; it must not appear on a
# machine merely because the machine upgraded. This mirrors the CR poller, which
# is likewise config-gated and disabled by default rather than being force-
# materialized by the XACA-0734 mandatory set.
#
#   ~/.aiteamforge/ttyd-bridge.json
#   { "enabled": true,
#     "writable": false,
#     "max_clients": 4,
#     "teams": { "academy": true } }
#
# Absent / unparseable / enabled=false  ->  the feature is OFF, and reconcile
# PRUNES any bridge plists it finds. Off means off, not "left lying around".
#──────────────────────────────────────────────────────────────────────────────
_config_get() {
    local key="$1" default="$2"
    [ -f "$KB_TTYD_CONFIG" ] || { printf '%s\n' "$default"; return 0; }
    KEY="$key" DEFAULT="$default" CFG="$KB_TTYD_CONFIG" python3 - <<'PY' 2>/dev/null || printf '%s\n' "$default"
import json, os, sys
key, default, cfg = os.environ["KEY"], os.environ["DEFAULT"], os.environ["CFG"]
try:
    with open(cfg) as fh:
        doc = json.load(fh)
    if not isinstance(doc, dict):
        raise ValueError("root is not an object")
except Exception:
    print(default); sys.exit(0)
val = doc.get(key, default)
if isinstance(val, bool):
    print("true" if val else "false")
else:
    print(val)
PY
}

_feature_enabled() { [ "$(_config_get enabled false)" = "true" ]; }

_team_enabled() {
    local team="$1"
    [ -f "$KB_TTYD_CONFIG" ] || return 1
    TEAM="$team" CFG="$KB_TTYD_CONFIG" python3 - <<'PY' 2>/dev/null
import json, os, sys
try:
    with open(os.environ["CFG"]) as fh:
        doc = json.load(fh)
    teams = doc.get("teams") if isinstance(doc, dict) else None
    sys.exit(0 if isinstance(teams, dict) and teams.get(os.environ["TEAM"]) is True else 1)
except Exception:
    sys.exit(1)
PY
}

#──────────────────────────────────────────────────────────────────────────────
# Opt-out sentinel — REUSES the existing XACA-0734 file and format rather than
# inventing a parallel one. One line per plist BASENAME; blank lines and
# `#` comments ignored; whitespace and a trailing CR tolerated, because a human
# edits this file in a text editor.
#
# The bare label `com.aiteamforge.ttyd-bridge` (no team/terminal suffix) opts out
# of the ENTIRE feature in one line, which is the form a user actually wants.
#──────────────────────────────────────────────────────────────────────────────
_is_opted_out() {
    local agent="$1"
    [ -f "$KB_TTYD_OPTOUT_FILE" ] || return 1
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        [ "$line" = "$agent" ] && return 0
        [ "$line" = "$LABEL_PREFIX" ] && return 0
    done < "$KB_TTYD_OPTOUT_FILE"
    return 1
}

#──────────────────────────────────────────────────────────────────────────────
# Render one plist.
#──────────────────────────────────────────────────────────────────────────────
_render() {
    local template="$1" dest="$2" team="$3" terminal="$4" ttyd_port="$5"

    local ttyd_bin tmux_bin
    ttyd_bin="$(command -v ttyd 2>/dev/null || echo /opt/homebrew/bin/ttyd)"
    tmux_bin="$(command -v tmux 2>/dev/null || echo /opt/homebrew/bin/tmux)"

    local max_clients; max_clients="$(_config_get max_clients 4)"
    case "$max_clients" in ''|*[!0-9]*) max_clients=4 ;; esac
    [ "$max_clients" -lt 1 ] && max_clients=4

    # Read-only is the default and the safe posture. When writable is NOT
    # requested we DELETE the placeholder line outright — emitting an empty
    # <string/> would hand ttyd a stray empty argv entry.
    local writable_sed
    if [ "$(_config_get writable false)" = "true" ]; then
        writable_sed="s|{{WRITABLE_ARG}}|<string>-W</string>|g"
    else
        writable_sed="/{{WRITABLE_ARG}}/d"
    fi

    # Resolve the tmux socket dir exactly as kanban-helpers.sh does, because
    # launchd hands the job a minimal environment with no TMUX_TMPDIR.
    local tmux_tmpdir="${TMUX_TMPDIR:-/tmp}"

    sed -e "s|{{LABEL}}|${LABEL_PREFIX}.${team}.${terminal}|g" \
        -e "s|{{TEAM}}|${team}|g" \
        -e "s|{{TERMINAL}}|${terminal}|g" \
        -e "s|{{TMUX_SESSION}}|${team}-${terminal}|g" \
        -e "s|{{TTYD_BIN}}|${ttyd_bin}|g" \
        -e "s|{{TMUX_BIN}}|${tmux_bin}|g" \
        -e "s|{{TTYD_PORT}}|${ttyd_port}|g" \
        -e "s|{{MAX_CLIENTS}}|${max_clients}|g" \
        -e "s|{{BASE_PATH}}|/terminal/${terminal}|g" \
        -e "$writable_sed" \
        -e "s|{{LOG_DIR}}|${KB_TTYD_LOG_DIR}|g" \
        -e "s|{{HOME_DIR}}|${HOME}|g" \
        -e "s|{{AITEAMFORGE_DIR}}|${AITEAMFORGE_DIR:-$HOME/aiteamforge}|g" \
        -e "s|{{TMUX_TMPDIR}}|${tmux_tmpdir}|g" \
        "$template" > "$dest" || return 1

    # An unresolved {{TOKEN}} means the template gained a placeholder this
    # renderer does not know about — the XACA-0571-014 sibling-drift failure.
    # Fail LOUDLY here rather than shipping launchd a plist it will reject.
    if grep -q '{{[A-Z_]*}}' "$dest" 2>/dev/null; then
        _err "unresolved placeholders in rendered plist $dest:"
        grep -o '{{[A-Z_]*}}' "$dest" | sort -u | sed 's/^/    /' >&2
        return 1
    fi

    # plutil is the only check that proves launchd will actually accept this
    # file. A rendered value containing a stray XML metacharacter produces a
    # plist that looks fine to grep and is rejected silently at load time.
    if command -v plutil >/dev/null 2>&1; then
        if ! plutil -lint "$dest" >/dev/null 2>&1; then
            _err "rendered plist is not valid: $dest"
            plutil -lint "$dest" >&2 2>&1 || true
            return 1
        fi
    fi
    return 0
}

_launchctl_is_loaded() {
    "$KB_TTYD_LAUNCHCTL" list 2>/dev/null | awk -v want="$1" '$NF == want { f = 1 } END { exit f ? 0 : 1 }'
}

#──────────────────────────────────────────────────────────────────────────────
# reconcile — the one state-changing path.
#──────────────────────────────────────────────────────────────────────────────
cmd_reconcile() {
    local template
    if ! template="$(_resolve_template)"; then
        _err "ttyd bridge plist template not found (set KB_TTYD_TEMPLATE to override)"
        return 1
    fi

    if ! command -v ttyd >/dev/null 2>&1; then
        _warn "ttyd is not installed (brew install ttyd) — rendering plists anyway;"
        _warn "the jobs will fail to start until it is present."
    fi

    local want_file; want_file="$(mktemp -t kbttydwant)" || return 1
    : > "$want_file"

    local enabled=true
    if ! _feature_enabled; then
        enabled=false
        _say "Terminal bridge is DISABLED (${KB_TTYD_CONFIG}); pruning any bridge LaunchAgents."
        _say "  Enable with: {\"enabled\": true, \"teams\": {\"<team>\": true}}"
    fi

    local rendered=0 refreshed=0 skipped=0 pruned=0

    if [ "$enabled" = true ]; then
        local team terminal idx lcars_port ttyd_port
        while IFS="$(printf '\t')" read -r team terminal idx lcars_port ttyd_port; do
            [ -n "${team:-}" ] || continue

            if ! _team_enabled "$team"; then
                skipped=$((skipped + 1)); continue
            fi

            local agent="${LABEL_PREFIX}.${team}.${terminal}.plist"
            if _is_opted_out "${agent}"; then
                _info "skip ${agent} — opted out (${KB_TTYD_OPTOUT_FILE})"
                skipped=$((skipped + 1)); continue
            fi

            printf '%s\n' "$agent" >> "$want_file"

            local target="${KB_TTYD_LAUNCHAGENTS_DIR}/${agent}"
            local tmpfile="${target}.new"

            if [ "$DRY_RUN" = true ]; then
                if [ -f "$target" ]; then
                    _info "would refresh ${agent} (port ${ttyd_port})"
                else
                    _info "would install ${agent} (port ${ttyd_port})"
                fi
                rendered=$((rendered + 1)); continue
            fi

            mkdir -p "$KB_TTYD_LAUNCHAGENTS_DIR" "$KB_TTYD_LOG_DIR" 2>/dev/null || true

            if ! _render "$template" "$tmpfile" "$team" "$terminal" "$ttyd_port"; then
                _warn "render failed for ${agent}"
                rm "$tmpfile" 2>/dev/null || true
                continue
            fi

            # Level-triggered: only touch launchd when the rendered content
            # actually differs from what is already on disk. This is what makes
            # a re-run a no-op instead of a fleet-wide terminal reconnect.
            if [ -f "$target" ] && cmp -s "$tmpfile" "$target"; then
                rm "$tmpfile" 2>/dev/null || true
                # Content is right but the job may not be registered (e.g. first
                # boot after a manual unload). Converge that too.
                if ! _launchctl_is_loaded "${agent%.plist}"; then
                    "$KB_TTYD_LAUNCHCTL" load "$target" 2>/dev/null || true
                fi
                continue
            fi

            local was_new=true; [ -f "$target" ] && was_new=false

            "$KB_TTYD_LAUNCHCTL" unload "$target" 2>/dev/null || true
            mv "$tmpfile" "$target" || { _warn "could not install ${agent}"; continue; }
            "$KB_TTYD_LAUNCHCTL" load "$target" 2>/dev/null || true

            # `launchctl load` returns 0 even when the job is REJECTED, so verify
            # registration via `launchctl list` (the XACA-0651-009 pattern).
            if _launchctl_is_loaded "${agent%.plist}"; then
                if [ "$was_new" = true ]; then
                    _info "installed + loaded ${agent} (127.0.0.1:${ttyd_port})"
                    rendered=$((rendered + 1))
                else
                    _info "refreshed ${agent} (127.0.0.1:${ttyd_port})"
                    refreshed=$((refreshed + 1))
                fi
            else
                _warn "${agent} written but did not register — load with: launchctl load ${target}"
            fi
        done < <(_enumerate_desired)
    fi

    # ── Prune: any bridge plist NOT in the desired set is removed. This is the
    # half that a pure "install what's missing" routine always forgets, and it
    # is what makes a terminal renamed on the board stop listening.
    if [ -d "$KB_TTYD_LAUNCHAGENTS_DIR" ]; then
        local f base
        for f in "$KB_TTYD_LAUNCHAGENTS_DIR"/${LABEL_PREFIX}.*.plist; do
            [ -e "$f" ] || continue
            base="$(basename "$f")"
            if [ -n "$ONLY_TEAM" ]; then
                case "$base" in "${LABEL_PREFIX}.${ONLY_TEAM}."*) ;; *) continue ;; esac
            fi
            if grep -qxF "$base" "$want_file" 2>/dev/null; then
                continue
            fi
            if [ "$DRY_RUN" = true ]; then
                _info "would prune ${base} (no longer desired)"
            else
                _info "pruning ${base} (no longer desired)"
                "$KB_TTYD_LAUNCHCTL" unload "$f" 2>/dev/null || true
                rm "$f" 2>/dev/null || true
            fi
            pruned=$((pruned + 1))
        done
    fi

    rm "$want_file" 2>/dev/null || true
    _say "reconcile: ${rendered} installed, ${refreshed} refreshed, ${skipped} skipped, ${pruned} pruned"
    return 0
}

cmd_uninstall() {
    local removed=0 f base
    [ -d "$KB_TTYD_LAUNCHAGENTS_DIR" ] || { _say "nothing to remove"; return 0; }
    for f in "$KB_TTYD_LAUNCHAGENTS_DIR"/${LABEL_PREFIX}.*.plist; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        if [ -n "$ONLY_TEAM" ]; then
            case "$base" in "${LABEL_PREFIX}.${ONLY_TEAM}."*) ;; *) continue ;; esac
        fi
        if [ "$DRY_RUN" = true ]; then _info "would remove ${base}"; removed=$((removed+1)); continue; fi
        "$KB_TTYD_LAUNCHCTL" unload "$f" 2>/dev/null || true
        rm "$f" 2>/dev/null || true
        # Verify the job is really gone from launchd, not merely unlinked from
        # disk — an unloaded-but-still-registered job keeps holding the port.
        if _launchctl_is_loaded "${base%.plist}"; then
            _warn "${base} removed from disk but STILL REGISTERED with launchd;"
            _warn "  force with: launchctl remove ${base%.plist}"
        else
            _info "removed ${base}"
        fi
        removed=$((removed + 1))
    done
    _say "uninstall: ${removed} agent(s) processed"
    _say "Logs are preserved at ${KB_TTYD_LOG_DIR} (matches the lcars-health convention)."
    return 0
}

cmd_status() {
    printf '%-56s %-8s %-10s %s\n' AGENT PORT LOADED LISTENING
    local team terminal idx lcars_port ttyd_port agent loaded listening
    while IFS="$(printf '\t')" read -r team terminal idx lcars_port ttyd_port; do
        [ -n "${team:-}" ] || continue
        agent="${LABEL_PREFIX}.${team}.${terminal}"
        loaded=no;    _launchctl_is_loaded "$agent" && loaded=yes
        listening=no
        lsof -nP -iTCP:"$ttyd_port" -sTCP:LISTEN >/dev/null 2>&1 && listening=yes
        printf '%-56s %-8s %-10s %s\n' "$agent" "$ttyd_port" "$loaded" "$listening"
    done < <(_enumerate_desired)
}

cmd_ports() {
    printf '%-34s %-14s %-5s %-11s %s\n' TEAM TERMINAL IDX LCARS_PORT TTYD_PORT
    local team terminal idx lcars_port ttyd_port
    while IFS="$(printf '\t')" read -r team terminal idx lcars_port ttyd_port; do
        [ -n "${team:-}" ] || continue
        printf '%-34s %-14s %-5s %-11s %s\n' "$team" "$terminal" "$idx" "$lcars_port" "$ttyd_port"
    done < <(_enumerate_desired)
}

# check-ports — the audit that must actually be RUN, not asserted. Verifies:
#   1. no two (team, terminal) pairs share a ttyd port
#   2. no ttyd port collides with ANY configured team's LCARS port
#   3. every ttyd port is below the kernel ephemeral floor
#   4. nothing on this machine is already LISTENing on a computed port
#
# ROWS ARRIVE IN A FILE, NOT ON STDIN — and that is deliberate. The first cut of
# this function was `_enumerate_desired | cmd_check_ports` with the analysis in a
# `python3 - <<'PY'` heredoc. That CANNOT work: the heredoc IS python's stdin (it
# is the program text), so `sys.stdin.read()` returned nothing and the audit ran
# over ZERO rows. It then printed `RESULT: PASS` — a check that examined nothing
# and reported the reassuring answer. Every collision assertion below is vacuously
# true on an empty list, so the failure was invisible in exactly the direction that
# matters. The row count is now printed and asserted non-zero for the same reason:
# a port audit that found no ports has not passed, it has not run.
cmd_check_ports() {
    local rows_file="$1"
    local eph; eph="$(sysctl -n net.inet.ip.portrange.first 2>/dev/null || echo 49152)"
    KB_TTYD_TEAM_PATHS="$KB_TTYD_TEAM_PATHS" EPHEMERAL_FLOOR="$eph" ROWS_FILE="$rows_file" python3 - <<'PY'
import json, os, subprocess, sys
with open(os.environ["ROWS_FILE"]) as fh:
    rows = [l.split("\t") for l in fh.read().splitlines() if l.strip()]
eph  = int(os.environ["EPHEMERAL_FLOOR"])

# A zero-row audit is NOT a pass — it is a check that did not run. Fail loudly.
if not rows:
    print("NO ENDPOINTS ENUMERATED — nothing was audited.")
    print("RESULT: FAIL (vacuous: an audit over zero rows proves nothing)")
    sys.exit(1)
with open(os.environ["KB_TTYD_TEAM_PATHS"]) as fh:
    doc = json.load(fh)
teams = doc.get("teams", doc)
lcars = {}
for t, m in teams.items():
    if isinstance(m, dict):
        try:
            lcars[int(m.get("lcars_port", m.get("port")))] = t
        except (TypeError, ValueError):
            pass

fail = 0
seen = {}
for team, term, idx, lp, tp in rows:
    tp = int(tp)
    owner = f"{team}/{term}"
    if tp in seen:
        print(f"COLLISION: {owner} and {seen[tp]} both computed ttyd port {tp}"); fail = 1
    seen[tp] = owner
    if tp in lcars:
        print(f"COLLISION: {owner} ttyd port {tp} is team {lcars[tp]}'s LCARS port"); fail = 1
    if tp >= eph:
        print(f"OUT OF RANGE: {owner} ttyd port {tp} >= ephemeral floor {eph}"); fail = 1

print(f"teams with bridges : {len(set(r[0] for r in rows))}")
print(f"endpoints          : {len(rows)}")
if rows:
    ports = sorted(int(r[4]) for r in rows)
    print(f"ttyd port range    : {ports[0]}-{ports[-1]}")
    print(f"distinct ttyd ports: {len(set(ports))} (must equal endpoints)")
print(f"LCARS ports checked : {len(lcars)} -> {sorted(lcars)}")
print(f"ephemeral floor     : {eph}")

# 4. Nothing already listening on a computed port.
busy = []
for team, term, idx, lp, tp in rows:
    r = subprocess.run(["lsof", "-nP", f"-iTCP:{tp}", "-sTCP:LISTEN"],
                       capture_output=True, text=True)
    if r.returncode == 0 and r.stdout.strip():
        busy.append((f"{team}/{term}", tp, r.stdout.splitlines()[1:2]))
if busy:
    for owner, tp, detail in busy:
        print(f"IN USE: {owner} port {tp} already has a listener: {detail}")
    fail = 1
else:
    print("live-port probe     : no computed port is currently in use")

print("RESULT: " + ("FAIL" if fail else "PASS"))
sys.exit(1 if fail else 0)
PY
}

usage() {
    sed -n '2,20p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
}

main() {
    local cmd="${1:-}"; shift 2>/dev/null || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY_RUN=true ;;
            --team) ONLY_TEAM="${2:-}"; shift ;;
            -h|--help) usage; return 0 ;;
            *) _err "unknown option: $1"; return 2 ;;
        esac
        shift
    done
    case "$cmd" in
        ports)                 cmd_ports ;;
        check-ports)
            local rf rc
            rf="$(mktemp -t kbttydrows)" || return 1
            _enumerate_desired > "$rf"
            cmd_check_ports "$rf"; rc=$?
            rm "$rf" 2>/dev/null || true
            return $rc
            ;;
        reconcile|install)     cmd_reconcile ;;
        uninstall)             cmd_uninstall ;;
        status)                cmd_status ;;
        -h|--help|help|'')     usage ;;
        *) _err "unknown command: $cmd"; usage; return 2 ;;
    esac
}

main "$@"
