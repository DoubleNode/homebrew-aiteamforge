#!/bin/bash
# aiteamforge-paths.sh — Canonical team path config loader (shell layer)
#
# XACA-0168-001 — Wave 1: Config schema + loader module
# XACA-0139-002 — De-branding: org-resolver integration
#
# This file is the shell counterpart to kanban-hooks/aiteamforge_paths.py.
# Both must produce identical results for the same ~/.aiteamforge/team-paths.json
# input.
#
# XACA-1161 — ABOUT THE BAKED-IN TABLE BELOW: it is ASPIRATIONALLY in sync with
# DEFAULT_TEAMS in aiteamforge_paths.py, and MEASURABLY is not. Do not read the
# old "must stay in sync" wording as a statement of fact about the current file.
# This table is TAP-NATIVE: there is no canonical twin for it in dev-team/, and
# sync-tap.sh copies only into $TAP/share/, never into libexec/. So every
# canonical registry change lands in share/kanban-hooks/aiteamforge_paths.py and
# NOTHING propagates here — the drift is structural, not an oversight anyone can
# fix by being careful. Measured 2026-09-10: 13 rows here vs 15 entries there,
# with membership differences in BOTH directions. When you change either side,
# change this one by hand and say so.
#
# Relationship to kanban-paths.sh (existing file in this directory):
#   kanban-paths.sh   — reads from ~/aiteamforge/.aiteamforge-config (old
#                       installer config, get_kanban_dir function).
#   aiteamforge-paths.sh (THIS FILE) — reads from ~/.aiteamforge/team-paths.json
#                       (new schema, Wave 1 of XACA-0168 migration).
#   Both files are kept for backward compatibility.  Consumers should migrate
#   to the aiteamforge_* functions in this file.
#
# USAGE:
#   source /path/to/aiteamforge-paths.sh
#   kanban_dir=$(aiteamforge_team_kanban_dir "academy") || exit 1
#   port=$(aiteamforge_team_lcars_port "ios") || echo "no port"
#
# DEPENDENCIES:
#   jq (preferred) or python3 (fallback).  Both are optional — if neither
#   is available the built-in shell defaults are used directly.
#
# ENVIRONMENT:
#   AITEAMFORGE_CONFIG — override config path (for testing)
#
# Author: Reno's Engineering Lab (Academy Team)

# Guard against double-sourcing
if [ -n "${_AITEAMFORGE_PATHS_LOADED:-}" ]; then
    return 0
fi
_AITEAMFORGE_PATHS_LOADED=1

# Resolve tap-owned Python venv interpreter ($AITEAMFORGE_PYTHON).
# python-env.sh lives alongside this file in the same lib/ directory.
_atf_paths_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
# shellcheck source=./python-env.sh
# shellcheck disable=SC1091  # source guarded by file-test or `|| true`; default-mode can't follow
[ -f "$_atf_paths_script_dir/python-env.sh" ] && . "$_atf_paths_script_dir/python-env.sh" 2>/dev/null || true
# shellcheck source=./aiteamforge-org-paths.sh
# shellcheck disable=SC1091  # source guarded by file-test or `|| true`; default-mode can't follow
[ -f "$_atf_paths_script_dir/aiteamforge-org-paths.sh" ] && . "$_atf_paths_script_dir/aiteamforge-org-paths.sh" 2>/dev/null || true
unset _atf_paths_script_dir

# ─────────────────────────────────────────────────────────────────────────────
# Internal: org-resolver helpers for path composition
#
# These helpers allow the DEFAULT_TEAMS heredoc and any other path builder to
# reference organization-specific directory segments without hard-coding client
# names.  All helpers are safe to call when the org resolver is not loaded
# (they produce the legacy fallback values so existing installs keep working).
# ─────────────────────────────────────────────────────────────────────────────

# _atf_paths_org_shared_dev_root
# Echoes the shared_dev_root from the org resolver, or empty string.
# Used when composing /Users/Shared/Development or equivalent.
_atf_paths_org_shared_dev_root() {
    if command -v _aiteamforge_org_shared_dev_root >/dev/null 2>&1; then
        _aiteamforge_org_shared_dev_root 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# _atf_paths_org_name
# Echoes the org name from the resolver.  Falls back to empty so callers
# can detect "no resolver / not configured" and use the legacy literal.
_atf_paths_org_name() {
    if command -v _aiteamforge_org_slug >/dev/null 2>&1; then
        local slug
        slug=$(_aiteamforge_org_slug 2>/dev/null || echo "example-org")
        # Treat the placeholder as "not configured" — return empty so callers
        # fall back to their baked-in legacy value.
        if [ "$slug" = "example-org" ] || [ -z "$slug" ]; then
            echo ""
            return 0
        fi
        _aiteamforge_org_name 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# _atf_paths_org_plugin_dir_name <legacy_dir_name>
# xaca-0139:allowed — doc comment naming legacy dir names as examples for the resolver function
# Given a legacy hard-coded directory name (e.g. "Main Event", "DoubleNode"),
# returns the org-resolver name when the resolver is configured and the plugin
# matching the legacy name appears to be active; otherwise returns the legacy
# name unchanged.  This keeps directory resolution correct for existing installs
# that have not yet run `aiteamforge setup` to write organization.yaml.
#
# Usage is internal to _AITEAMFORGE_DEFAULT_TEAMS_DATA.
_atf_paths_org_plugin_dir_name() {
    local legacy_name="$1"
    local org_name
    org_name=$(_atf_paths_org_name)
    if [ -n "$org_name" ]; then
        echo "$org_name"
    else
        echo "$legacy_name"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Config path
# ─────────────────────────────────────────────────────────────────────────────

aiteamforge_config_path() {
    if [ -n "${AITEAMFORGE_CONFIG:-}" ]; then
        echo "$AITEAMFORGE_CONFIG"
    else
        echo "${HOME}/.aiteamforge/team-paths.json"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Baked-in defaults (shell representation)
#
# Schema columns (XACA-0463, XACA-0542): team_id, kanban_dir, working_dir,
#   lcars_port, lcars_port_base, lcars_port_range, team_code
#
# Format: one line per team, TAB-separated:
#   team_id<TAB>kanban_dir<TAB>working_dir<TAB>lcars_port<TAB>lcars_port_base<TAB>lcars_port_range<TAB>team_code
# lcars_port uses the STRING SENTINEL "null" when not yet allocated — NOT an
#   empty string. (XACA-1161 corrects this line, which said "empty string" while
#   every row has always emitted "null". The distinction is load-bearing, not
#   pedantic: an empty whitespace-delimited field collapses under the
#   `IFS=$'\t' read -r t kd wd lp lb lr tc` parser every consumer uses and shifts
#   every later column left by one — see the XACA-0727 note on the mainevent row.)
# lcars_port_base is the first port in the template's band (XACA-0463).
# lcars_port_range is the inclusive count of ports in the band (XACA-0463).
# team_code is the 3-letter identifier (e.g. ACA, IOS) used in item prefixes
#   like XACA-0001.  Empty for alias entries. (XACA-0542)
# DEPRECATED: lcars_port — use lcars_port_base/lcars_port_range for band queries.
#
# XACA-1161: the line that used to read "THIS LIST MUST MIRROR DEFAULT_TEAMS in
# kanban-hooks/aiteamforge_paths.py" has been removed because it is false and was
# actively misleading — see the structural explanation in this file's header.
#
# XACA-0139-002: Paths for org-specific teams (ios, android, firebase, command,
# and legacy mainevent alias) are now composed via the org resolver so the same # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
# defaults work for any org whose shared_dev_root and name are configured.
# When the resolver returns placeholder / empty values the literal legacy paths
# are used — this preserves backward compatibility for existing installs that
# have not yet run `aiteamforge setup` to write organization.yaml.
#
# xaca-0139:allowed — doc comment explaining DoubleNode dir name is a stable project-family path, not org branding
# DoubleNode freelance team paths use the same resolver-driven composition:
# <shared_dev_root>/DoubleNode/<project> is replaced with # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
# <shared_dev_root>/<doublenode_dir>/<project> where doublenode_dir is the # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
# literal string "DoubleNode" (a stable project-family directory name, not an # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
# org display name) — kept as-is to avoid breaking existing disk layouts.
# ─────────────────────────────────────────────────────────────────────────────

_AITEAMFORGE_DEFAULT_TEAMS_DATA() {
    # Emit: team_id TAB kanban_dir TAB working_dir TAB lcars_port TAB lcars_port_base TAB lcars_port_range TAB team_code
    # lcars_port is empty when not yet allocated; lcars_port_base/lcars_port_range are always set.
    # team_code is the 3-letter code (e.g. ACA); empty for alias entries with no own code.
    # Schema version: XACA-0463 + XACA-0542 (7 columns)

    # Resolve org-driven path prefix for the primary org's shared projects.
    # Falls back to the hardcoded legacy prefix when the resolver is not yet
    # configured (org slug = "example-org" or resolver unavailable).
    local _shared_dev
    _shared_dev=$(_atf_paths_org_shared_dev_root)
    # If shared_dev_root is not configured use the canonical shared-Mac path.
    if [ -z "$_shared_dev" ]; then
        _shared_dev="/Users/Shared/Development"
    fi

    # Primary org name as a directory segment (e.g. "Main Event"). # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
    # Empty when resolver is not configured → falls back to legacy literal.
    local _org_name
    _org_name=$(_atf_paths_org_name)

    # Compose the org-named project root.  If the org name is not yet known
    # we use the legacy "Main Event" literal so existing installs keep working. # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
    local _org_prefix
    if [ -n "$_org_name" ]; then
        _org_prefix="${_shared_dev}/${_org_name}"
    else
        # xaca-0139:allowed — backward-compat fallback for pre-XACA-0139 installs without organization.yaml
        _org_prefix="${_shared_dev}/Main Event"
    fi

    # Shared-dev prefix used for org-agnostic third-party project families
    # (DNSFramework, Liquidstyle) — these never carry the org name.
    local _shared_prefix="${_shared_dev}"

    # XACA-0862: every caller of this function reads it through either a
    # literal pipe (`_AITEAMFORGE_DEFAULT_TEAMS_DATA | _aiteamforge_write_defaults`,
    # `| cut -f1`) or a `while read ... done < <(_AITEAMFORGE_DEFAULT_TEAMS_DATA)`
    # loop that `break`s as soon as it finds the team it wants (e.g. the
    # lcars_port_base prefix scan in aiteamforge_compute_instance_port). Both
    # are legitimate, expected consumption patterns for a static lookup table
    # — but they mean the reader can close its end of the pipe before every
    # row below has been written. A `printf` writing into an already-closed
    # pipe fails with EPIPE ("write error: Broken pipe") and a non-zero exit;
    # under the `set -euo pipefail` every caller here inherits, that failure
    # would otherwise abort the CALLER's script — for data that is 100%
    # static and can never legitimately fail. Confirmed on Linux CI
    # (tap-connect-disconnect-parity, XACA-0862): install-team.sh finance
    # --project personal --connect-only aborted non-zero with exactly this
    # broken-pipe printf trace once the reader (the port-base prefix scan)
    # matched "finance-personal" and stopped reading, mid-table, before the
    # trailing rows were written. Reproduced locally by forcing an
    # early-closing reader (`$(_AITEAMFORGE_DEFAULT_TEAMS_DATA | grep -m1 ...)`)
    # which raises the identical SIGPIPE/EPIPE abort under set -e.
    #
    # Wrapping the whole emission as the LHS of `|| true` suspends errexit for
    # every command inside the group (verified: a deliberate `false` mid-block
    # does not abort under this construct — bash defers the -e check to the
    # group's own exit status, which `|| true` then absorbs), and 2>/dev/null
    # silences the write-error message so a legitimately early-closing reader
    # (which already got everything it needed) produces no noise. This does
    # NOT weaken any real failure detection: this block only ever emits a
    # fixed literal table, so there is no genuine error condition here to mask.
    #
    # `trap '' PIPE` is required too, not optional: when SIGPIPE has its
    # default disposition, the kernel can terminate this process on the write
    # syscall itself (confirmed locally: a >64KB write into a reader that
    # already closed kills the process outright with no message and no
    # command-completion for `|| true` to even run against — exit 128+13=141,
    # unrecoverable from inside the function). Ignoring SIGPIPE converts that
    # syscall failure into an ordinary EPIPE return from `printf`, which the
    # `{ ... } || true` group above can then actually catch.
    trap '' PIPE
    {
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "academy"      "${HOME}/dev-team/kanban"                                    "${HOME}/dev-team"                                          "8203"  "8200" "10"  "ACA"
        # xaca-0139:allowed — MainEventApp-* are stable per-project repo directory names (not org branding); resolved via _org_prefix
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "ios"           "${_org_prefix}/MainEventApp-iOS/kanban"                    "${_org_prefix}/MainEventApp-iOS"                           "8260"  "8260" "10"  "IOS"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "android"       "${_org_prefix}/MainEventApp-Android/kanban"                "${_org_prefix}/MainEventApp-Android"                       "8280"  "8280" "10"  "AND" # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "firebase"      "${_org_prefix}/MainEventApp-Functions/kanban"              "${_org_prefix}/MainEventApp-Functions"                     "8240"  "8240" "10"  "FIR" # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "command"       "${_org_prefix}/dev-team/kanban"                            "${_org_prefix}/dev-team"                                   "8234"  "8230" "10"  "CMD"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "dns"           "${_shared_prefix}/DNSFramework/kanban"                     "${_shared_prefix}/DNSFramework"                            "8180"  "8180" "10"  "DNS"
        # ── Freelance — per-client/project entries (overlay-only, XACA-0628) ──
        # The 9 per-CLIENT/PROJECT freelance slugs (DoubleNode/Liquidstyle/Bandwear)
        # were removed from this registry in XACA-0628 and now live solely in the
        # per-machine overlay (~/.aiteamforge/team-paths.json). Overlay team_codes
        # MERGE on top of these defaults, so the overlay entries
        # (FSW/FAP/FWS/FLB/VAN/FAS/FLA/FLI/BWA/BWD) supply routing on machines that
        # actually host those client repos. The generic `freelance` (FRE) entry below
        # STAYS here as the universal fallback.
        #
        # XACA-1161 — DO NOT trust the old "Mirrors aiteamforge_paths.py DEFAULT_TEAMS"
        # claim that used to end this comment: it was measurably FALSE and has been
        # removed. This table and DEFAULT_TEAMS diverge in MEMBERSHIP, not just in
        # detail: this table carries `freelance` and `medical`, which XACA-0643
        # deliberately removed from DEFAULT_TEAMS as bare-key team-id-contract
        # violations; DEFAULT_TEAMS carries 5 `mainevent-<project>` instances
        # (XACA-0806, ports 8401-8405) that this table has never had. Treat the two
        # as separate seeds that must be reconciled per-field, never as a mirror.
        #
        # XACA-1161 — the `freelance` row below is LOAD-BEARING, not decorative.
        # It is the ONLY declaration of the freelance port band (8500/100) reachable
        # from this file: `aiteamforge_compute_instance_port freelance` (which
        # install-team.sh calls for every `install-team freelance --client X
        # --project Y`, freelance being one of the 10 installable templates in
        # share/teams/registry.json) resolves it at step 1. There are no
        # `freelance-*` rows for the step-3 prefix scan to find, and this shell has
        # no equivalent of the Python `_TEMPLATE_PORT_BANDS` step that XACA-0643's
        # follow-up (d5cd6877) had to add for exactly this reason. MEASURED: deleting
        # this row makes that call exit 1 with "Template 'freelance' has no
        # lcars_port_base declared". Do not remove it until this shell grows an
        # explicit template-band table.
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "legal-coparenting"  "${HOME}/legal/coparenting/kanban"                     "${HOME}/legal/coparenting"          "8320" "8320" "10"  "LCP"
        # XACA-1161: lcars_port was the "null" sentinel here while the canonical
        # Python seed carried 8340. XACA-0740 (2026-06-30) set medical-general's
        # lcars_port None -> 8340 "matches band base + team-paths.json overlay";
        # that fix mirrored into homebrew-tap/share/kanban-hooks/aiteamforge_paths.py
        # but NOT into this file — sync-tap.sh only writes under $TAP/share/, and
        # this table is tap-native with no canonical twin, so it received nothing.
        # Result: the SAME tap package shipped two contradictory seeds for one team.
        # Python is authoritative (it moved deliberately; this side never moved).
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "medical-general"    "${HOME}/medical/general/kanban"                       "${HOME}/medical/general"            "8340" "8340" "10"  "MED"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "finance-personal"   "${HOME}/finance/personal/kanban"                      "${HOME}/finance/personal"           "8360" "8360" "10"  "FIN"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "spacedock"     "${HOME}/.aiteamforge/spacedock/kanban"     "${HOME}/.aiteamforge/spacedock"     "8380"  "8380" "10" "SDK"
        # Legacy alias kept for backward compatibility with pre-XACA-0139 installs.
        # The "mainevent" team ID was used before the org plugin system existed; # xaca-0139:allowed — justified survivor (backward-compat default, overridden by org resolver)
        # new installs use the "command" team or enable the primary org plugin.
        # xaca-0139:allowed — "mainevent" is a registered legacy team slug (backward-compat alias, not user-facing org branding)
        # NOTE (XACA-0463): mainevent moves from 8234 → 8400 to resolve collision with command (band 8230–8239).
        # XACA-0727: mainevent is BOARD-LESS — kanban_dir/working_dir are the "null"
        # sentinel (NOT empty: empty whitespace-delimited fields collapse under the
        # IFS=$'\t' read parser and shift the port into the kanban_dir slot). "null"
        # is the established absent-field sentinel here (see ports on lines above) and
        # is treated as absent by the jq path. mainevent previously duplicated
        # command's dev-team/kanban dir, so kb-* ops resolving team 'mainevent'
        # derived a phantom mainevent-board.json and failed. 'command' is the
        # operative kanban identity; mainevent persists only as a crew-launcher/port
        # alias (LCARS 8400, team_code MEV).
        # XACA-1161: lcars_port_range narrowed 10 -> 1 to match the canonical
        # Python seed. XACA-0806 (2026-07-23) narrowed the bare board-less alias's
        # band from [8400,8410) to [8400,8401) because the wider band OVERLAPPED
        # the per-project band _TEMPLATE_PORT_BANDS["mainevent"] = (8401, 19) ->
        # [8401,8420) — the same span written inclusively as [8401,8419] elsewhere
        # — on ports 8401-8409, violating the team-id-contract "bands MUST NOT
        # overlap" rule. That fix mirrored into share/kanban-hooks/aiteamforge_paths.py
        # (tap commit 01700a93) but NOT into this file — sync-tap.sh writes only
        # under $TAP/share/, and this table is tap-native. So every tap consumer has
        # been carrying the pre-fix overlap ever since. A board-less alias binds
        # exactly its one fixed port (8400) and is never dynamically allocated.
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "mainevent"     "null"                                                      "null"                                                      "8400"  "8400" "1"   "MEV"
        # XACA-1161 — this bare `medical` row is RECOMMENDED FOR REMOVAL but is
        # deliberately LEFT IN PLACE here; removing a row this tap already ships is
        # a separate, approval-gated change, not part of a value reconciliation.
        # Why it should go: XACA-0643 removed the bare `medical` key from the
        # canonical Python seed as a team-id-contract violation (medical is a
        # PARAMETERIZED template — it needs a project — so a bare key is invalid, and
        # lcars-ui/server.py:_filter_contract_violating_teams() drops it with a loud
        # warning on every read). It also emits an EMPTY team_code in column 7, and
        # declares band [8340,8350) — byte-identical to medical-general's band right
        # above, i.e. a duplicate-band pair the Python seed does not have.
        # Why removing it is SAFE, measured (unlike the freelance row above):
        # `aiteamforge_compute_instance_port medical` still resolves to 8340 without
        # it, via the step-3 prefix scan onto `medical-general`. Verified by deleting
        # the row in a scratch copy and re-running the allocator: identical output,
        # rc=0, 8340. This is the same mechanism `finance` and `legal` already rely
        # on — both are installable templates in share/teams/registry.json and
        # NEITHER has a bare row here.
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "medical"        "${HOME}/medical/general/kanban"                           "${HOME}/medical/general"            "null" "8340" "10"  ""
        # XACA-1161 — DO NOT DELETE THE ROW BELOW. It is the only reachable
        # declaration of the freelance 8500/100 band; removing it breaks
        # `install-team freelance` with a hard exit 1. Full rationale in the
        # "Freelance" comment block further up this function.
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "freelance"      "${HOME}/dev-team/kanban"                                  "${HOME}/dev-team"                                          "8505"  "8500" "100" "FRE"
    } 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal: bootstrap helpers
# ─────────────────────────────────────────────────────────────────────────────

_aiteamforge_is_interactive() {
    # Returns 0 (true) if stdin is a terminal
    [ -t 0 ]
}

_aiteamforge_write_defaults() {
    local config_path
    config_path=$(aiteamforge_config_path)
    local config_dir
    config_dir="$(dirname "$config_path")"
    mkdir -p "$config_dir" 2>/dev/null || true

    # Build JSON from the default data using python3 (always available on macOS)
    # Schema: team_id TAB kanban_dir TAB working_dir TAB lcars_port TAB lcars_port_base TAB lcars_port_range TAB team_code
    "${AITEAMFORGE_PYTHON:-python3}" - "$config_path" <<'PYEOF'
import sys, json
from pathlib import Path
import os

config_path = sys.argv[1]
home = str(Path.home())

teams = {}
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line:
        continue
    parts = line.split('\t')
    if len(parts) < 3:
        continue
    team_id = parts[0]
    kanban_dir = parts[1].replace('${HOME}', home).replace('$HOME', home)
    working_dir = parts[2].replace('${HOME}', home).replace('$HOME', home)
    port_str = parts[3] if len(parts) > 3 else ''
    base_str = parts[4] if len(parts) > 4 else ''
    range_str = parts[5] if len(parts) > 5 else ''
    team_code = parts[6].strip() if len(parts) > 6 else ''
    entry = {"kanban_dir": kanban_dir, "working_dir": working_dir}
    entry["lcars_port"] = int(port_str) if (port_str and port_str != 'null') else None
    entry["lcars_port_base"] = int(base_str) if (base_str and base_str != 'null') else None
    entry["lcars_port_range"] = int(range_str) if (range_str and range_str != 'null') else None
    if team_code:
        entry["team_code"] = team_code
    teams[team_id] = entry

config = {"schema_version": 1, "teams": teams}
Path(config_path).parent.mkdir(parents=True, exist_ok=True)
Path(config_path).write_text(json.dumps(config, indent=2) + '\n', encoding='utf-8')
PYEOF
}

# ─────────────────────────────────────────────────────────────────────────────
# XACA-1161 — READ-PATH CONVERGENCE (the shell half of K830)
#
# Everything from here to the end of _aiteamforge_get_field() is ONE decision
# procedure, expressed once. Before this ticket, four public accessors
# (aiteamforge_team_from_code, aiteamforge_lcars_port_team_map,
# aiteamforge_compute_instance_port, aiteamforge_list_teams) each carried their
# own jq/python3/seed chain with its own idea of what counts as "no value" —
# K501 sibling-heuristic drift inside a single file. They now all resolve
# through the helpers below.
#
# The resolution order MIRRORS kanban-hooks/aiteamforge_registry.py exactly:
#
#     OVERLAY  ->  DEFAULT_TEAMS  ->  DERIVED  ->  ABSENT
#
#   1. OVERLAY       ~/.aiteamforge/team-paths.json — the machine's
#                    authoritative registry. It wins TIES; it is NOT asserted to
#                    be more correct. (K962: this host's `command` entry points
#                    at a $TMPDIR pytest fixture and is canonical-and-wrong,
#                    tracked as XACA-0939. We return it faithfully. A resolver
#                    that "corrected" toward the healthier-looking tier would be
#                    a stale-data propagator with full confidence.)
#   2. DEFAULT_TEAMS the baked-in table below. MIGRATION TOLERANCE ONLY — it is
#                    what lets an overlay written before a field existed still
#                    resolve. Not a "more correct" tier.
#   3. DERIVED       only working_dir, only as kanban_dir's parent, and only
#                    when NO tier declared it. Deriving a PATH from a declared
#                    sibling is permitted; deriving an IDENTITY (team_code, a
#                    slug, a port) is not, ever — K659 / XACA-1058. A phantom
#                    identity is worse than a hard failure, because callers go
#                    on to mint item IDs against a code nothing else recognises.
#   4. ABSENT        return 1. Never a guess.
#
# A team registered in NEITHER tier resolves to nothing and returns 1 — the
# shell's equivalent of the Python resolver's UnknownTeamError. The public
# accessors turn that into a loud "Team 'x' not found. Available: ..." message.
#
# THREE STATES, NOT TWO (knowledge S002). A collected zero/false/"" is DATA, not
# absence. Each tier lookup reports one of:
#     NOTEAM   — the team is not in this tier at all      -> consult next tier
#     NOKEY    — team present, field key genuinely absent  -> consult next tier
#     PRESENT  — key present; the VALUE then decides, per this field's sentinels
#
# THE SENTINEL VOCABULARY IS PER FIELD, NEVER GLOBAL. That is the substance of
# this change. The old _aiteamforge_get_field gated every field on one rule,
#     [ -n "$value" ] && [ "$value" != "null" ]
# which collapses DECLARED-absent into NOT-DECLARED and gets the answer wrong in
# BOTH directions: it drops `primary_host: ""` (a declared "unowned",
# XACA-0802-004) and it cannot distinguish a board-less `kanban_dir: null` from
# a team the overlay simply has not heard of. See _aiteamforge_is_declared_value.
# ─────────────────────────────────────────────────────────────────────────────

# _aiteamforge_field_sentinel_class <field>  ->  PATHISH | NULLISH | KEYONLY
#
# Mirrors the _PATHISH_/_NULLISH_/_KEYONLY_SENTINELS tuples on the FieldSpec
# rows in kanban-hooks/aiteamforge_registry.py. Fields with no explicit row
# there fall to the conservative path-ish rule, and so do they here — the
# registry is schema-open on purpose, so an overlay-only field a future
# kb-init-team introduces is resolved rather than dropped. (Measured on this
# host 2026-09-10, the live overlay already carries `local_only`, which has no
# FieldSpec row; it lands on the default rule on both sides.)
#
# SETS THE GLOBAL _ATF_SENTINEL_CLASS; prints nothing. That is a PERFORMANCE
# CONTRACT, not a style preference. This is consulted once per registry ROW
# inside the fan-out resolver, and wrapping it in `$(...)` forks a subshell
# every single time. Measured on this host: that one command substitution was
# 130 ms of aiteamforge_team_from_code's 160 ms (79 rows x ~1.6 ms per fork),
# which is what made the accessor several times slower than the single jq query
# it replaced. The RULE is unchanged and still lives in exactly one place - only
# the return mechanism moved. Callers read $_ATF_SENTINEL_CLASS.
_aiteamforge_field_sentinel_class() {
    case "$1" in
        primary_host)
            _ATF_SENTINEL_CLASS="NULLISH" ;;
        board_less|ai)
            _ATF_SENTINEL_CLASS="KEYONLY" ;;
        *)
            _ATF_SENTINEL_CLASS="PATHISH" ;;
    esac
}

# _aiteamforge_is_declared_value <field> <json_type> <value>
# Returns 0 when the value is a real DECLARED value for this field, 1 when it
# matches one of THIS FIELD's absence sentinels.
#
#   PATHISH  (None, "", "null")  — kanban_dir, working_dir, every lcars_port*,
#            team_code, alias_of, and every unregistered field. A positional
#            table cannot OMIT a column, so it spells absence in-band as the
#            literal text "null" (XACA-0727); JSON null and "" are the other two
#            spellings the same absence arrives in.
#   NULLISH  (None, "null")      — "" is a DECLARED value meaning "unowned" /
#            "none configured" and must NOT fall through to the seed.
#            XACA-0802-004 records that a blanket `if not host` fallback made
#            Python and shell disagree about the identical overlay entry.
#            primary_host is now the ONLY member. XACA-1184 retired the
#            anthropic_account_id / anthropic_account_nickname /
#            anthropic_api_key_env_var trio that used to sit here; they are no
#            longer declared in Python either, so they resolve through
#            _default_spec() — PATHISH — on BOTH sides via the `*` arm below.
#            Leaving them listed here would have been a silent divergence: the
#            field is gone, but the rule for it would have disagreed.
#   KEYONLY  (None,)             — only a JSON null is absence. `board_less:
#            false` is DATA, and so is `ai.credential: null`. On `ai` this
#            class is load-bearing rather than incidental: TWO different nulls
#            live one level apart meaning opposite things. `ai: null` (the key
#            this function is asked about) is NO BLOCK and is absence;
#            `ai.credential: null` one level in is a DECLARED decision — "no
#            team credential, the CLI falls back to its own login". Only the
#            OUTER null is a sentinel. Copying primary_host's NULLISH tuple
#            onto `ai` would be actively WRONG, and PATHISH doubly so: "" and
#            the string "null" are CORRUPTION on a structured block, not an
#            in-band absence, and the accessor has to SEE them to warn.
#            Mirrors the `ai` FieldSpec's own note in aiteamforge_registry.py.
#            This is the one class where <json_type> carries
#            information the text cannot: jq renders both JSON null and the
#            JSON string "null" as the bare text `null`, so the type is what
#            separates them.
_aiteamforge_is_declared_value() {
    local _field="$1"
    local _jtype="$2"
    local _value="$3"
    if [ "$_jtype" = "null" ]; then
        return 1          # a JSON null (Python None) is absence in ALL classes
    fi
    # Direct call, NOT $( ... ): see the performance contract on that function.
    _aiteamforge_field_sentinel_class "$_field"
    case "$_ATF_SENTINEL_CLASS" in
        KEYONLY)
            return 0 ;;   # false / "" / 0 / "null"-the-string are all DATA here
        NULLISH)
            if [ "$_value" = "null" ]; then return 1; fi
            return 0 ;;
        *)
            if [ -z "$_value" ] || [ "$_value" = "null" ]; then return 1; fi
            return 0 ;;
    esac
}

# _aiteamforge_field_absent_stops_chain <field>
# Returns 0 when a DECLARED-absent value at one tier is the final answer, and 1
# when the chain should keep looking in the next tier.
#
# Mirrors FieldSpec.absent_stops_chain. Only team_code and alias_of continue:
# both preserve a pre-existing migration fallback (get_team_code() gated on
# truthiness and so fell through to DEFAULT_TEAMS on an empty code;
# board_less_alias_of() falls back so guidance still resolves on overlays
# predating XACA-0794). Everything else STOPS: "this team has no kanban dir" is
# an authoritative statement about a board-less alias, not a gap for a lower
# tier to fill (XACA-0727).
_aiteamforge_field_absent_stops_chain() {
    case "$1" in
        team_code|alias_of) return 1 ;;
        *)                  return 0 ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Tier readers
#
# Both emit the SAME row language, so one scanner serves both tiers:
#
#   <team>\tTEAM\t\t                     — team exists in this tier (roster row)
#   <team>\tROW\t<json_type>\t<value>    — the field key is present on that team
#   __SCHEMA__\tSCHEMA\t<version>\t      — unsupported schema_version (overlay)
#
# WHY WHOLE-TIER ROWS RATHER THAN A PER-(TEAM,FIELD) QUERY: a jq fork measured
# 22-36 ms on this host, and aiteamforge_lcars_port_team_map fans out across the
# whole team union on the `aiteamforge restart` path — the exact cost
# XACA-0799-004 was raised to remove (it measured 1.35 s there). One fork per
# TIER lets every fan-out caller pay a single fork and then resolve in-process,
# so convergence does not undo that fix. It also makes _aiteamforge_get_field
# itself CHEAPER than before: one jq fork instead of the two it used to take
# (schema probe + value probe), measured 2.13 s -> ~1.0 s over the 29-team union.
# ─────────────────────────────────────────────────────────────────────────────

# _aiteamforge_overlay_rows <field> [config_path]   — tier 1
_aiteamforge_overlay_rows() {
    local _field="$1"
    local _config_path="${2:-}"
    [ -z "$_config_path" ] && _config_path=$(aiteamforge_config_path)
    [ -f "$_config_path" ] || return 0

    if command -v jq >/dev/null 2>&1; then
        jq -r --arg f "$_field" '
            ((.schema_version // 0) | tostring) as $sv
            | (if ($sv == "0" or $sv == "1" or $sv == "2") then empty
               else ("__SCHEMA__\tSCHEMA\t" + $sv + "\t") end),
              (if ((.teams // {}) | type) == "object"
               then (.teams | to_entries[]
                     | .["key"] as $t
                     | .["value"] as $e
                     | ($t + "\tTEAM\t\t"),
                       (if ($e | type) == "object" and ($e | has($f))
                        then ($t + "\tROW\t" + ($e[$f] | type) + "\t"
                              + ($e[$f] | if type == "string" then . else tostring end))
                        else empty end))
               else empty end)
        ' "$_config_path" 2>/dev/null
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        "${AITEAMFORGE_PYTHON:-python3}" - "$_config_path" "$_field" <<'PYEOF' 2>/dev/null
import json, sys
from pathlib import Path

config_path, field = sys.argv[1], sys.argv[2]
try:
    config = json.loads(Path(config_path).read_text(encoding='utf-8'))
except Exception:
    raise SystemExit(0)
if not isinstance(config, dict):
    raise SystemExit(0)

version = str(config.get('schema_version', 0))
if version not in ('0', '1', '2'):
    print("__SCHEMA__\tSCHEMA\t%s\t" % version)

teams = config.get('teams')
if not isinstance(teams, dict):
    raise SystemExit(0)

for team, entry in teams.items():
    print("%s\tTEAM\t\t" % team)
    if not isinstance(entry, dict) or field not in entry:
        continue
    value = entry[field]
    # bool BEFORE int: bool is an int subclass, and `board_less: false` must
    # report type "boolean" so the KEYONLY rule can keep it as DATA.
    if value is None:
        jtype, text = "null", "null"
    elif isinstance(value, bool):
        jtype, text = "boolean", ("true" if value else "false")
    elif isinstance(value, (int, float)):
        jtype, text = "number", ("%g" % value if isinstance(value, float) else str(value))
    elif isinstance(value, str):
        jtype, text = "string", value
    else:
        jtype = "array" if isinstance(value, list) else "object"
        text = json.dumps(value, separators=(',', ':'))
    print("%s\tROW\t%s\t%s" % (team, jtype, text))
PYEOF
        return 0
    fi

    return 0
}

# _aiteamforge_default_rows <field>   — tier 2, pure shell, no forks
#
# The 7-column positional table can express exactly SIX of the registry's
# fields. Any other field yields a roster row and NO value row — i.e. NOKEY,
# "this tier genuinely does not declare it", which is the honest answer and the
# one that lets the chain continue. It is NOT the same as declaring absence.
_aiteamforge_default_rows() {
    local _field="$1"
    local _home="$HOME"
    local t="" kd="" wd="" lp="" lb="" lr="" tc="" raw=""

    while IFS=$'\t' read -r t kd wd lp lb lr tc; do
        [ -z "$t" ] && continue
        printf '%s\tTEAM\t\t\n' "$t"
        case "$_field" in
            kanban_dir)       raw="$kd" ;;
            working_dir)      raw="$wd" ;;
            lcars_port)       raw="$lp" ;;
            lcars_port_base)  raw="$lb" ;;
            lcars_port_range) raw="$lr" ;;
            team_code)        raw="$tc" ;;
            *)                continue ;;
        esac
        # The heredoc stores paths with a literal ${HOME}; expand it here.
        raw="${raw/\$\{HOME\}/$_home}"
        raw="${raw/\$HOME/$_home}"
        if [ "$raw" = "null" ]; then
            # The positional table's in-band absence sentinel (XACA-0727).
            # Reported as json_type "null" so it is indistinguishable from a
            # JSON null to the sentinel rule — which is exactly what it means.
            printf '%s\tROW\tnull\tnull\n' "$t"
        else
            # Every column is text by construction; the table has no type system.
            printf '%s\tROW\tstring\t%s\n' "$t" "$raw"
        fi
    done < <(_AITEAMFORGE_DEFAULT_TEAMS_DATA)
}

# _aiteamforge_load_overlay_rows <field> [config_path]  -> sets _ATF_OVR_ROWS
# _aiteamforge_load_default_rows <field>                -> sets _ATF_DEF_ROWS
#
# Same rows as _aiteamforge_overlay_rows / _aiteamforge_default_rows, returned
# through a GLOBAL rather than stdout. That is the whole point: every hot caller
# wrote `rows=$(_aiteamforge_..._rows ...)`, and a command substitution is a
# subshell fork, so (a) it cost a fork per call and (b) any memo set inside the
# function died with the subshell. Returning through a global fixes both.
#
# WHAT IS MEMOIZED AND WHAT DELIBERATELY IS NOT:
#
#   DEFAULT_TEAMS rows ARE memoized. That table is a constant compiled into this
#   file; for a given <field> its content varies only with $HOME and with the
#   org resolver, which is loaded once when this file is sourced. So the cache
#   key is "<field>|$HOME" and validating it costs ZERO forks.
#
#   OVERLAY rows are NOT memoized, on purpose. team-paths.json is MUTABLE
#   mid-process - kb-init-team, kb-port-reconcile and the installers all rewrite
#   it - so a correct cache would have to key on the file's mtime+size, and
#   MEASURED on this host a `stat` fork costs 15 ms, the same as the jq fork it
#   would save. Paying a fork to avoid an equal fork buys nothing and buys it at
#   the price of a stale-registry failure mode, which is precisely the class of
#   bug this ticket exists to remove. If a future consumer makes the overlay
#   read materially more expensive than one stat, revisit - the split is a
#   measurement, not a principle.
_aiteamforge_load_overlay_rows() {
    local _field="$1"
    local _cfg="${2:-}"
    [ -z "$_cfg" ] && _cfg=$(aiteamforge_config_path)
    _ATF_OVR_ROWS=$(_aiteamforge_overlay_rows "$_field" "$_cfg")
    return 0
}

_aiteamforge_load_default_rows() {
    local _field="$1"
    local _key="${_field}|${HOME}"
    if [ "${_ATF_MEMO_DEF_KEY:-}" = "$_key" ]; then
        _ATF_DEF_ROWS="$_ATF_MEMO_DEF_ROWS"
        return 0
    fi
    _ATF_DEF_ROWS=$(_aiteamforge_default_rows "$_field")
    _ATF_MEMO_DEF_KEY="$_key"
    _ATF_MEMO_DEF_ROWS="$_ATF_DEF_ROWS"
    return 0
}

# _aiteamforge_scan_rows <team> <rows>
# Scans one tier's rows for <team>. Sets the globals below rather than echoing,
# so fan-out callers can resolve a whole union without a subshell per team:
#   _ATF_ROW_STATE  NOTEAM | NOKEY | PRESENT
#   _ATF_ROW_TYPE   json type of the value  (only meaningful when PRESENT)
#   _ATF_ROW_VALUE  the value as text       (only meaningful when PRESENT)
# Any __SCHEMA__ row is surfaced on stderr as it is encountered, preserving the
# warning the previous jq arm emitted.
_aiteamforge_scan_rows() {
    local _team="$1"
    local _rows="$2"
    local t="" kind="" ty="" val=""

    _ATF_ROW_STATE="NOTEAM"
    _ATF_ROW_TYPE=""
    _ATF_ROW_VALUE=""
    [ -z "$_rows" ] && return 0

    while IFS=$'\t' read -r t kind ty val; do
        [ -z "$t" ] && continue
        if [ "$t" = "__SCHEMA__" ]; then
            # Warn ONCE per version per process, not once per team scanned. The
            # __SCHEMA__ row travels inside the tier blob, and a fan-out caller
            # scans that same blob once per team — so an un-guarded echo here
            # printed the warning 29 times (measured) for one config read, where
            # the arm this replaced printed it once per _aiteamforge_get_field
            # call. Accessors invoke that through `$( ... )`, a fresh subshell,
            # so the guard resets per call and their behaviour is unchanged;
            # only the in-process fan-out loops get quieter. Never louder.
            if [ "${_ATF_SCHEMA_WARNED:-}" != "$ty" ]; then
                echo "[aiteamforge-paths] WARNING: schema_version=${ty} unsupported" >&2
                _ATF_SCHEMA_WARNED="$ty"
            fi
            continue
        fi
        [ "$t" = "$_team" ] || continue
        if [ "$kind" = "TEAM" ]; then
            if [ "$_ATF_ROW_STATE" = "NOTEAM" ]; then
                _ATF_ROW_STATE="NOKEY"
            fi
            continue
        fi
        _ATF_ROW_STATE="PRESENT"
        _ATF_ROW_TYPE="$ty"
        _ATF_ROW_VALUE="$val"
    done <<EOF
$_rows
EOF
    return 0
}

# _aiteamforge_resolve_into <team> <field> <overlay_rows> <default_rows>
# THE choke point. Walks OVERLAY -> DEFAULT_TEAMS applying this field's own
# sentinel and stop-chain rules, and reports through globals so a fan-out loop
# costs no forks:
#   _ATF_RESOLVED     the declared value (only meaningful on return 0)
#   _ATF_TEAM_KNOWN   1 if the team exists in either tier, else 0
#   _ATF_SOURCE       OVERLAY | DEFAULT_TEAMS | NONE — which tier answered.
#                     Provenance matters when two TEAMS collide on one value:
#                     the per-team chain gets each team right individually, but a
#                     reverse index still has to break the tie, and it must break
#                     it the same way the chain does. See
#                     aiteamforge_lcars_port_team_map.
# Returns 0 = DECLARED, 1 = declared-absent / not-declared / unknown team.
#
# DERIVATION IS NOT DONE HERE, on purpose: the tier rows handed in are for ONE
# field, so this function cannot see the sibling kanban_dir that working_dir is
# derived from. _aiteamforge_get_field owns tier 3 for that reason, and it is
# the only entry point that can be asked for working_dir — every fan-out caller
# in this file asks for lcars_port, lcars_port_base, lcars_port_range or
# team_code, none of which has a deriver (and none of which may ever get one:
# they are identities, K659).
_aiteamforge_resolve_into() {
    local _team="$1"
    local _field="$2"
    local _ovr="$3"
    local _def="$4"

    _ATF_RESOLVED=""
    _ATF_TEAM_KNOWN=0
    _ATF_SOURCE="NONE"

    # ── Tier 1: OVERLAY ──────────────────────────────────────────────────
    _aiteamforge_scan_rows "$_team" "$_ovr"
    case "$_ATF_ROW_STATE" in
        PRESENT)
            _ATF_TEAM_KNOWN=1
            if _aiteamforge_is_declared_value "$_field" "$_ATF_ROW_TYPE" "$_ATF_ROW_VALUE"; then
                _ATF_RESOLVED="$_ATF_ROW_VALUE"
                _ATF_SOURCE="OVERLAY"
                return 0
            fi
            if _aiteamforge_field_absent_stops_chain "$_field"; then
                return 1   # DECLARED_ABSENT — an answer, not a gap to fill
            fi
            ;;
        NOKEY)
            _ATF_TEAM_KNOWN=1
            ;;
    esac

    # ── Tier 2: DEFAULT_TEAMS ────────────────────────────────────────────
    _aiteamforge_scan_rows "$_team" "$_def"
    case "$_ATF_ROW_STATE" in
        PRESENT)
            _ATF_TEAM_KNOWN=1
            if _aiteamforge_is_declared_value "$_field" "$_ATF_ROW_TYPE" "$_ATF_ROW_VALUE"; then
                _ATF_RESOLVED="$_ATF_ROW_VALUE"
                _ATF_SOURCE="DEFAULT_TEAMS"
                return 0
            fi
            if _aiteamforge_field_absent_stops_chain "$_field"; then
                return 1
            fi
            ;;
        NOKEY)
            _ATF_TEAM_KNOWN=1
            ;;
    esac

    return 1
}


# _aiteamforge_resolve_all <field> <overlay_rows> <default_rows>
# Emits "<team>	<value>	<OVERLAY|DEFAULT_TEAMS>" for every team resolving
# to a DECLARED value for <field>, applying the SAME per-field sentinel and
# stop-chain rules as _aiteamforge_resolve_into. TWO blob passes total, however
# many teams there are.
#
# WHY THIS EXISTS RATHER THAN A LOOP OVER _aiteamforge_resolve_into: that
# function re-scans BOTH blobs for every team, and each scan reads a heredoc,
# which bash materialises as a TEMP FILE. Over a 29-team union that is 58 temp
# files per call. Measured on this host, a per-team loop made
# aiteamforge_team_from_code 5x SLOWER than the single jq query it replaced
# (0.20s -> 1.12s per call) - and that function sits under
# _kb_get_team_from_code in the shipped kanban helpers, i.e. on the path of
# every kb-* command that resolves an item prefix. Converging the rule must not
# cost the hot path. One rule, one pass.
#
# Emission order is overlay-resolved teams first, then seed-resolved. That is
# load-bearing for reverse indexes - see aiteamforge_lcars_port_team_map.
_aiteamforge_resolve_all() {
    local _field="$1"
    local _ovr="$2"
    local _def="$3"
    local t="" kind="" ty="" val=""
    local _decided="|"
    local _out_ovr=""
    local _out_def=""

    # Pass 1 - OVERLAY.
    while IFS=$'\t' read -r t kind ty val; do
        [ -z "$t" ] && continue
        [ "$t" = "__SCHEMA__" ] && continue
        [ "$kind" = "ROW" ] || continue
        case "$_decided" in *"|$t|"*) continue ;; esac
        if _aiteamforge_is_declared_value "$_field" "$ty" "$val"; then
            _out_ovr="${_out_ovr}${t}	${val}	OVERLAY
"
            _decided="${_decided}${t}|"
        elif _aiteamforge_field_absent_stops_chain "$_field"; then
            # DECLARED_ABSENT is an answer: this team is settled, with no value.
            _decided="${_decided}${t}|"
        fi
    done <<XACA1161_OVR
$_ovr
XACA1161_OVR

    # Pass 2 - DEFAULT_TEAMS, for teams tier 1 did not settle.
    while IFS=$'\t' read -r t kind ty val; do
        [ -z "$t" ] && continue
        [ "$kind" = "ROW" ] || continue
        case "$_decided" in *"|$t|"*) continue ;; esac
        if _aiteamforge_is_declared_value "$_field" "$ty" "$val"; then
            _out_def="${_out_def}${t}	${val}	DEFAULT_TEAMS
"
            _decided="${_decided}${t}|"
        elif _aiteamforge_field_absent_stops_chain "$_field"; then
            _decided="${_decided}${t}|"
        fi
    done <<XACA1161_DEF
$_def
XACA1161_DEF

    # Global, not stdout: the callers below are loops-free but were paying a
    # command-substitution fork just to receive this string.
    _ATF_RESOLVED_ALL="${_out_ovr}${_out_def}"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal: low-level field lookup
#
# _aiteamforge_get_field <team> <field>
#   field: any registry field. The six the positional table can express
#          (kanban_dir | working_dir | lcars_port | lcars_port_base |
#          lcars_port_range | team_code) resolve from either tier; everything
#          else resolves from the overlay only, because the table cannot
#          declare it.
#
# Stdout: the declared value.  Exit 0 = DECLARED; 1 = declared-absent,
# not-declared, or unknown team.
# ─────────────────────────────────────────────────────────────────────────────

_aiteamforge_get_field() {
    local team="$1"
    local field="$2"
    local config_path=""
    config_path=$(aiteamforge_config_path)
    local ovr=""
    local def=""
    local kd=""

    ovr=$(_aiteamforge_overlay_rows "$field" "$config_path")

    # ── Bootstrap: config missing ─────────────────────────────────────────
    # XACA-0804: the auto-write used to fire on every non-interactive read
    # (hooks, subagents, CI, the LCARS server are overwhelmingly non-interactive
    # AND read-only) — a read must never mutate the registry as a side effect.
    # The write is now opt-in only, via AITEAMFORGE_ALLOW_BOOTSTRAP_WRITE=1 —
    # the same env var + truthiness rule as the Python canonical
    # (kanban-hooks/aiteamforge_paths.py:_bootstrap_write_allowed), since this
    # is the shared contract that survives the shell->python3 heredoc handoff
    # used by _aiteamforge_write_defaults below.
    if [ ! -f "$config_path" ]; then
        if _aiteamforge_is_interactive; then
            echo "[aiteamforge-paths] Config not found at ${config_path}." >&2
            echo "  Run: aiteamforge-paths init" >&2
            echo "  Falling back to built-in defaults." >&2
        elif [ "${AITEAMFORGE_ALLOW_BOOTSTRAP_WRITE:-}" = "1" ]; then
            echo "[aiteamforge-paths] Config missing — writing defaults to ${config_path}" >&2
            _AITEAMFORGE_DEFAULT_TEAMS_DATA | _aiteamforge_write_defaults
        fi
        # else: non-interactive with no opt-in — silent fallback to the shell
        # default-table lookup below, no disk write, no stderr hint (XACA-0804:
        # read-only must not write; opt-in only).
    fi

    def=$(_aiteamforge_default_rows "$field")

    # ── Tiers 1 and 2 ─────────────────────────────────────────────────────
    if _aiteamforge_resolve_into "$team" "$field" "$ovr" "$def"; then
        printf '%s\n' "$_ATF_RESOLVED"
        return 0
    fi

    # ── Tier 3: DERIVED ───────────────────────────────────────────────────
    # working_dir is the ONE derivable field, and only for a team some tier
    # actually knows. Reading a declared SIBLING field (kanban_dir) is not an
    # identity derivation — see the K659 note in this section's header. An
    # unregistered team falls straight through to ABSENT and never derives.
    if [ "$_ATF_TEAM_KNOWN" -eq 1 ] && [ "$field" = "working_dir" ]; then
        if kd=$(_aiteamforge_get_field "$team" "kanban_dir"); then
            printf '%s\n' "$(dirname "$kd")"
            return 0
        fi
    fi

    # ── Tier 4: ABSENT ──────────────────────────────────────
    # The exit code carries the one distinction a `$( ... )` subshell cannot hand
    # back: 2 means the team is registered in NO tier (this shell's equivalent of
    # the Python resolver's UnknownTeamError), 1 means the team IS registered but
    # this field resolved to declared-absent / not-declared. Every pre-existing
    # caller tests only for "nonzero", so both remain failures and nothing that
    # worked changes; the accessors below use the split to stop reporting an
    # intentional board-less alias as a missing team.
    if [ "$_ATF_TEAM_KNOWN" -eq 1 ]; then
        return 1
    fi
    return 2
}

# _aiteamforge_report_missing <team> <field> <rc>
# One diagnostic, shared by the three path/port accessors.
#
# XACA-1161: all three printed "Team 'x' not found" for BOTH failure shapes.
# That wording only became reachable for a REGISTERED team once the sentinel rule
# started applying to the baked-in table as well as to the overlay — measured on
# this host, `aiteamforge_team_kanban_dir mainevent` previously exited 0 and
# printed the literal string "null" AS THE PATH, because the shell-table arm gated
# on `[ -n "$result" ]` and "null" is four non-empty characters. Consumers guard
# with exactly that test (share/scripts/lcars-tmp-dir.sh does), so a phantom
# relative directory named `null` sailed straight through. Now that it is
# correctly a failure, blaming a missing team would be the wrong story: the team
# is registered and deliberately board-less (XACA-0727 / XACA-0794). The Python
# resolver raises two distinct exceptions here for the same reason.
_aiteamforge_report_missing() {
    local _team="$1"
    local _field="$2"
    local _rc="$3"
    local _config_path=""
    _config_path=$(aiteamforge_config_path)

    if [ "$_rc" = "2" ]; then
        echo "Team '${_team}' not found. Available: $(aiteamforge_list_teams | tr '\n' ' ') — edit ${_config_path} or run \`aiteamforge-paths init\`." >&2
    else
        echo "Team '${_team}' is registered but declares no ${_field} (absent, or explicitly null — board-less aliases are like this by design). Edit ${_config_path} if that is wrong." >&2
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Public API
# ─────────────────────────────────────────────────────────────────────────────

# aiteamforge_team_kanban_dir <team>
# Prints the kanban directory for the given team, or returns nonzero.
aiteamforge_team_kanban_dir() {
    local team="$1"
    local result=""
    local rc=0
    result=$(_aiteamforge_get_field "$team" "kanban_dir") || rc=$?
    if [ "$rc" -ne 0 ]; then
        _aiteamforge_report_missing "$team" "kanban_dir" "$rc"
        return 1
    fi
    echo "$result"
}

# aiteamforge_team_working_dir <team>
# Prints the working directory (project root) for the given team.
aiteamforge_team_working_dir() {
    local team="$1"
    local result=""
    local rc=0
    result=$(_aiteamforge_get_field "$team" "working_dir") || rc=$?
    if [ "$rc" -ne 0 ]; then
        _aiteamforge_report_missing "$team" "working_dir" "$rc"
        return 1
    fi
    echo "$result"
}

# aiteamforge_team_lcars_port <team>
# Prints the LCARS port number, or returns nonzero if not applicable / unknown team.
aiteamforge_team_lcars_port() {
    local team="$1"
    local result=""
    local rc=0
    result=$(_aiteamforge_get_field "$team" "lcars_port") || rc=$?
    if [ "$rc" -ne 0 ]; then
        _aiteamforge_report_missing "$team" "lcars_port" "$rc"
        return 1
    fi
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        return 1  # team exists but has no LCARS port
    fi
    echo "$result"
}

# aiteamforge_resolve_team_key <team>
# Resolve a CONFIGURED team id to the key that actually exists in this registry.
#
# `.aiteamforge-config`'s `.teams[]` stores BASE ids ("finance", "legal"), but the
# registry keys profile-scoped teams by their INSTANCE id ("finance-personal",
# "legal-coparenting"). Callers that skip this mapping miss the registry entirely
# and silently skip the team (XACA-0792).
#
# Candidates are tried in order and the FIRST that exists in the registry wins:
#   1. get_board_id  — the canonical deterministic map (kanban-paths.sh). This is
#      the authority. It is first because a team's configured project_id is NOT
#      reliably the registry suffix: legal's TEAM_DEFAULT_PROJECT is "default",
#      which would derive "legal-default" — a key that does not exist. finance
#      ("personal") and medical ("general") only agree with the registry by
#      coincidence, so deriving from project_id alone fixes 2 of 3 teams.
#   2. get_team_instance_id — derived from .team_paths[<base>].project_id. Covers
#      genuinely project-scoped installs the static map cannot know about (e.g. a
#      freelance team on a custom project).
#   3. the base id unchanged — single-instance teams (academy, ios), and installs
#      whose .teams[] already holds instance ids.
#
# Prints the resolved key, or returns 1 with no output if none resolve.
aiteamforge_resolve_team_key() {
    local team="$1"
    [ -z "$team" ] && return 1

    local -a candidates=()
    local mapped=""

    # Both helpers live in sibling libs that a caller may not have sourced; guard
    # on presence rather than assume, and always fall back to the base id.
    #
    # A candidate is only worth trying if it actually MAPS to something other than
    # the base id. Both helpers echo their input unchanged when they have nothing
    # to say, and an unmapped base id must NOT be tried early: registry lookups
    # fall back to baked-in DEFAULT_TEAMS rows, so a bare base id can "resolve" to
    # a default port that is not the one this install configured (e.g. `freelance`
    # hits the default 8505 while the configured `freelance-acme` is on 8420). The
    # base id therefore belongs LAST, after every real mapping has had its turn.
    # get_team_instance_id already DEFERS to get_board_id internally (XACA-0792-003),
    # so for canonically-mapped teams the two agree and the duplicate is skipped.
    # get_board_id is still consulted directly as a safety net for callers that
    # sourced aiteamforge-paths.sh + kanban-paths.sh but NOT config.sh — without it,
    # `legal` would silently fall through to its base id.
    if type get_board_id >/dev/null 2>&1; then
        mapped=$(get_board_id "$team" 2>/dev/null || true)
        [ -n "$mapped" ] && [ "$mapped" != "$team" ] && candidates+=("$mapped")
    fi
    if type get_team_instance_id >/dev/null 2>&1; then
        mapped=$(get_team_instance_id "$team" 2>/dev/null || true)
        if [ -n "$mapped" ] && [ "$mapped" != "$team" ]; then
            local already=false
            local seen
            for seen in ${candidates[@]+"${candidates[@]}"}; do
                [ "$seen" = "$mapped" ] && already=true && break
            done
            [ "$already" = false ] && candidates+=("$mapped")
        fi
    fi
    candidates+=("$team")

    local cand
    for cand in "${candidates[@]}"; do
        [ -z "$cand" ] && continue
        if aiteamforge_team_lcars_port "$cand" >/dev/null 2>&1; then
            echo "$cand"
            return 0
        fi
    done

    return 1
}

# aiteamforge_team_code <team>
# Prints the 3-letter team code (e.g. ACA) for the given team, or returns
# nonzero with no output for teams that have no own code (alias entries).
# XACA-0542: exposes team_code from the registry to shell consumers so they
# can derive code<->team maps without hardcoded case statements.
aiteamforge_team_code() {
    local team="$1"
    local result
    result=$(_aiteamforge_get_field "$team" "team_code") || return 1
    if [ -z "$result" ] || [ "$result" = "null" ]; then
        return 1  # alias entry — no own code
    fi
    echo "$result"
}

# aiteamforge_team_from_code <code>
# Prints the team id for the given 3-letter code (e.g. ACA -> academy), or
# returns nonzero if no registered team declares it.
# XACA-0542: reverse lookup so shell consumers can resolve item prefixes
# (XACA-0001 -> code ACA -> team academy) via the registry.
#
# XACA-1161: this used to carry its own two-arm chain — a jq query over the
# config, then an independent scan of the baked-in table — and the two arms did
# not agree with each other or with _aiteamforge_get_field:
#   * the jq arm compared the STORED code against an upper-cased needle without
#     folding the stored side, so an overlay holding a lower-case code was
#     invisible to it while the table scan (which folded both sides) matched;
#   * neither arm applied team_code's sentinel rule, so an overlay entry with
#     `team_code: ""` was simply "no match" rather than a declared absence that
#     falls through to the seed — the right answer by luck, not by rule.
# It now resolves every team through _aiteamforge_resolve_into, which is the
# same chain aiteamforge_team_code() uses, so forward and reverse lookup cannot
# disagree. team_code has absent_stops_chain=FALSE, so an empty overlay code
# still falls through to the seed — that migration fallback is preserved by the
# rule now rather than by coincidence.
#
# One awk fork does the case-folded compare over the whole candidate list
# instead of one `tr` fork per team.
aiteamforge_team_from_code() {
    local code="$1"
    [ -z "$code" ] && return 1

    local ovr=""
    local def=""
    local team=""
    local pairs=""
    local result=""

    # ONE pass over both tiers - not one re-scan per team, and no call out to
    # aiteamforge_list_teams. See the cost note on _aiteamforge_resolve_all.
    # Overlay-resolved teams are emitted first, so an overlay code wins a
    # collision against a seed code, matching the per-team chain.
    # All three calls return through globals, so this whole accessor forks only
    # for the jq overlay read and the final awk case-fold.
    _aiteamforge_load_overlay_rows "team_code"
    _aiteamforge_load_default_rows "team_code"
    _aiteamforge_resolve_all "team_code" "$_ATF_OVR_ROWS" "$_ATF_DEF_ROWS"
    pairs="$_ATF_RESOLVED_ALL"

    [ -z "$pairs" ] && return 1

    result=$(printf '%s' "$pairs" | awk -F'	' -v want="$code" '
        BEGIN { want = toupper(want) }
        toupper($2) == want { print $1; exit }
    ')

    [ -z "$result" ] && return 1
    printf '%s\n' "$result"
    return 0
}

# aiteamforge_team_for_lcars_port <port>
# Prints the team id that owns the given LCARS port, or returns nonzero with no
# output if no team does.
#
# XACA-0799: the reverse of aiteamforge_team_lcars_port. `aiteamforge restart`
# snapshots the ports that are actually SERVING before it tears them down, then
# maps them back to team ids here so start can bring back exactly what stop
# reaped (stop is kill-all by design; start only covers configured teams).
#
# Delegates to aiteamforge_lcars_port_team_map(): an independent jq query over
# the config PLUS a forward-lookup fill for whatever jq misses. That fill is what
# preserves the round-trip invariant with the forward lookup start_lcars() uses —
# jq alone sees a strictly narrower set (XACA-0799-010). A separate
# query could disagree with the forward path on config-vs-baked-in-defaults
# precedence or null-port handling, and would then hand start a team/port pair
# the forward lookup never actually assigns — resurrecting a server on the wrong
# port. Reusing the forward function makes that class of drift impossible.
aiteamforge_team_for_lcars_port() {
    local want="$1"
    [ -z "$want" ] && return 1

    local team port
    while IFS=$'\t' read -r port team; do
        [ -z "$port" ] && continue
        if [ "$port" = "$want" ]; then
            echo "$team"
            return 0
        fi
    done < <(aiteamforge_lcars_port_team_map)

    return 1  # no team in the registry owns this port
}

# aiteamforge_lcars_port_team_map
# Prints one "<port><TAB><team>" line per team that has an LCARS port declared.
#
# XACA-0799-004: the reverse lookup used to scan aiteamforge_list_teams and call
# aiteamforge_team_lcars_port per team — two jq forks per probe, repeated for
# EVERY port. At 15 teams x 8 ports that measured 1.35s added to the restart
# path, sitting directly in front of a teardown that lcars-watch fires on every
# lcars-ui change. Callers hold the map and probe it fork-free via
# aiteamforge_team_for_lcars_port_in_map().
#
# XACA-1161 — WHAT CHANGED AND WHAT DID NOT. The batching is intact and so is
# its cost profile; what went away is the SECOND COPY OF THE RESOLUTION RULE.
# This function used to run its own jq filter,
#     select(.value.lcars_port != null and .value.lcars_port != "")
# which is a hand-rolled sentinel vocabulary: it knows about JSON null and "",
# and does NOT know about the string "null" that the positional table uses as
# its in-band absence marker (XACA-0727). An overlay carrying
# `"lcars_port": "null"` was therefore emitted as a team owning a port literally
# named `null`. It then patched its own coverage gap with a forward-lookup fill
# loop, in BOTH arms (XACA-0799-010 / -018), and hand-built the team union
# because aiteamforge_list_teams was narrower than the registry — three
# workarounds for one missing shared rule. All of it collapses into: ask
# _aiteamforge_resolve_into, which is the same chain the forward lookup uses.
# The round-trip invariant XACA-0799 asserts is now structural rather than
# maintained by a fill loop.
#
# A team whose overlay entry DECLARES a null port is now correctly absent from
# the map rather than being filled in from the baked-in table: lcars_port has
# absent_stops_chain=TRUE, so "this team has no port" is an answer, not a gap.
# A team merely MISSING from the overlay still resolves from the table exactly
# as the fill loop used to make it — that was the fill's stated purpose and it
# is preserved.
#
# NOT memoized. An in-function cache was tried and deleted: every caller invokes
# this through $( ... ), a SUBSHELL, so the cache never survived back to the
# parent and was dead code that merely looked like an optimisation.
#
# READ-ONLY by construction: it returns empty when the config file is absent.
# The old per-team path went through aiteamforge_team_lcars_port, which could
# MATERIALIZE a default registry on first lookup — so a reverse lookup could
# create state just by being run. Emitting nothing for a missing config is the
# correct degrade: the caller falls back to configured teams only.
aiteamforge_lcars_port_team_map() {
    local config_path=""
    config_path=$(aiteamforge_config_path)

    if [ ! -f "$config_path" ]; then
        return 0
    fi

    local ovr=""
    local def=""
    local team=""
    local map=""

    _aiteamforge_load_overlay_rows "lcars_port" "$config_path"
    _aiteamforge_load_default_rows "lcars_port"

    # TWO BUCKETS, OVERLAY FIRST — this is a tie-break, not cosmetics.
    # aiteamforge_team_for_lcars_port() returns the FIRST team in this map that
    # owns a port, so when two DIFFERENT teams claim the same port the map order
    # decides the winner. That happens on live data: measured on this host
    # 2026-09-10, port 8505 is claimed by `freelance-bandwear-android` in the
    # overlay AND by the `freelance` template row in the baked-in seed. Emitting
    # a single list in team-name order would hand 8505 to `freelance` purely
    # because f-r-e sorts before f-r-e-e-l-a-n-c-e-'-'-b, inverting the tier
    # precedence every other lookup in this file obeys — and `aiteamforge
    # restart` would then resurrect the wrong team on a port that is actually
    # serving the other one. Bucketing by provenance keeps the reverse index
    # agreeing with the forward chain: overlay-declared ownership wins, exactly
    # as it does per-team.
    #
    # (The duplicate itself is a real registry defect, not something to paper
    # over here. Reported as a finding for the XACA-1161-007 drift report.)
    # ONE pass over both tiers, already ordered overlay-first by
    # _aiteamforge_resolve_all, then flipped from "<team> <value>" into the
    # "<port>	<team>" shape this function's callers parse.
    _aiteamforge_resolve_all "lcars_port" "$_ATF_OVR_ROWS" "$_ATF_DEF_ROWS"
    map=$(printf '%s' "$_ATF_RESOLVED_ALL" \
          | awk -F'	' 'NF >= 2 && $2 != "" { print $2 "	" $1 }')

    [ -n "$map" ] && map="${map}
"
    printf '%s' "$map"
    return 0
}

# aiteamforge_team_for_lcars_port_in_map <port> <map>
# Pure-shell lookup against a map already built by aiteamforge_lcars_port_team_map.
# Prints the owning team, or returns 1.
#
# XACA-0799-004: this is what actually removes the per-port cost. Callers that
# probe several ports build the map ONCE and then call this, so a batch costs a
# single jq fork total instead of one per port.
#
# A memoizing cache inside aiteamforge_lcars_port_team_map was tried first and
# deleted: every caller invokes these through `$( ... )`, which runs in a
# SUBSHELL, so the cache variable never survives back to the parent and the
# memoization was dead code that merely looked like an optimisation. Passing the
# map explicitly is the only form that actually holds across calls.
aiteamforge_team_for_lcars_port_in_map() {
    local want="$1"
    local map="$2"
    [ -z "$want" ] && return 1

    local port team
    while IFS=$'\t' read -r port team; do
        [ -z "$port" ] && continue
        if [ "$port" = "$want" ]; then
            echo "$team"
            return 0
        fi
    done <<EOF
$map
EOF
    return 1
}

# aiteamforge_compute_instance_port <template_id> [<team_paths_json_path>]
#
# Allocate the lowest free port in template_id's band per XACA-0463 /
# team-id-contract §4.1. If team_paths_json_path is omitted it defaults to
# $HOME/.aiteamforge/team-paths.json. If the file is missing or has no "teams"
# key the band is treated as fully free.
#
# Tolerant input: if template_id is not found in DEFAULT_TEAMS directly (e.g.
# caller passed an instance id like 'finance-personal'), the first dash-
# separated component is extracted and retried as the template id.
#
# Stdout: chosen port (integer).
# Exit 0 on success; >0 with stderr message on failure (unknown template,
# band not declared, band exhausted).
aiteamforge_compute_instance_port() {
    local template_id="$1"
    local team_paths="${2:-$HOME/.aiteamforge/team-paths.json}"

    # ── Resolve the band (base + range) ─────────────────────────────
    # All three steps below now resolve through the shared OVERLAY -> DEFAULT_TEAMS
    # chain. Steps 1 and 2 already did (via _aiteamforge_get_field); step 3 did
    # NOT — it read _AITEAMFORGE_DEFAULT_TEAMS_DATA directly, so a template whose
    # only instances live in the per-machine overlay was undiscoverable no matter
    # what that overlay declared. It now scans the same union every other
    # accessor does.
    #
    # NOTE ON WHICH FILE THIS READS: steps 1-3 resolve against
    # aiteamforge_config_path(), while the used-ports scan further down reads the
    # $team_paths argument, and those can be different files. That asymmetry is
    # PRE-EXISTING and is deliberately left alone — changing which file a band
    # comes from is a behaviour change with allocation consequences, not a
    # read-path convergence. Recorded as a finding for XACA-1161-007/-008 rather
    # than fixed in passing.
    local base=""
    local range=""
    local ovr_base=""
    local def_base=""
    local ovr_range=""
    local def_range=""

    ovr_base=$(_aiteamforge_overlay_rows "lcars_port_base")
    def_base=$(_aiteamforge_default_rows "lcars_port_base")
    ovr_range=$(_aiteamforge_overlay_rows "lcars_port_range")
    def_range=$(_aiteamforge_default_rows "lcars_port_range")

    # Step 1: direct key lookup.
    if _aiteamforge_resolve_into "$template_id" "lcars_port_base" "$ovr_base" "$def_base"; then
        base="$_ATF_RESOLVED"
        if _aiteamforge_resolve_into "$template_id" "lcars_port_range" "$ovr_range" "$def_range"; then
            range="$_ATF_RESOLVED"
        fi
    fi

    # Step 2: tolerant input — strip to first dash-separated component and retry.
    if [ -z "$base" ]; then
        local base_template=""
        base_template="${template_id%%-*}"
        if [ "$base_template" != "$template_id" ]; then
            if _aiteamforge_resolve_into "$base_template" "lcars_port_base" "$ovr_base" "$def_base"; then
                base="$_ATF_RESOLVED"
                if _aiteamforge_resolve_into "$base_template" "lcars_port_range" "$ovr_range" "$def_range"; then
                    range="$_ATF_RESOLVED"
                fi
            fi
        fi
    fi

    # Step 3: prefix scan — a template id may appear ONLY as the prefix of its
    # instance keys (e.g. "finance" exists solely as "finance-personal"). Walks
    # aiteamforge_list_teams (the overlay+seed union) instead of the seed table
    # alone, so an instance provisioned into the overlay by kb-init-team supplies
    # its template's band too. First match in sorted order wins, as before.
    if [ -z "$base" ]; then
        local prefix=""
        local cand=""
        prefix="${template_id}-"
        while IFS= read -r cand; do
            [ -z "$cand" ] && continue
            case "$cand" in
                "$prefix"*) ;;
                *) continue ;;
            esac
            if _aiteamforge_resolve_into "$cand" "lcars_port_base" "$ovr_base" "$def_base"; then
                base="$_ATF_RESOLVED"
                if _aiteamforge_resolve_into "$cand" "lcars_port_range" "$ovr_range" "$def_range"; then
                    range="$_ATF_RESOLVED"
                fi
                break
            fi
        done < <(aiteamforge_list_teams)
    fi

    # XACA-1161: these also tested [ "$base" = "null" ], because the old chain
    # could hand back the positional table's in-band "null" sentinel as a literal
    # value. _aiteamforge_resolve_into applies the sentinel rule itself and
    # reports absence as a nonzero return, so "$base" is now either a declared
    # value or empty. The dead arm is removed rather than left as a check that
    # can never fire. The message keeps the word "declared" and the three-step
    # wording that test-xaca-0463-allocator.sh's sibling assertions read.
    if [ -z "$base" ]; then
        printf "Template '%s' has no lcars_port_base declared (not found in the registry directly, by stripping dashes, or via prefix scan).\n" \
            "$template_id" >&2
        return 1
    fi
    if [ -z "$range" ]; then
        printf "Template '%s' has no lcars_port_range declared.\n" "$template_id" >&2
        return 1
    fi

    # ── Collect all used ports from team-paths.json ────────────────────────
    local used_ports
    if [ -f "$team_paths" ] && command -v jq &>/dev/null; then
        used_ports=$(jq -r '.teams // {} | to_entries[] | .value.lcars_port // empty' \
            "$team_paths" 2>/dev/null | grep -E '^[0-9]+$' | sort -nu)
    elif [ -f "$team_paths" ] && command -v python3 &>/dev/null; then
        used_ports=$("${AITEAMFORGE_PYTHON:-python3}" - "$team_paths" <<'PYEOF' 2>/dev/null
import sys, json
from pathlib import Path
try:
    config = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
    for entry in config.get('teams', {}).values():
        p = entry.get('lcars_port')
        if p is not None:
            print(int(p))
except Exception:
    pass
PYEOF
)
    else
        used_ports=""
    fi

    # ── Scan band for first free port ──────────────────────────────────────
    local end
    end=$(( base + range ))
    local port
    for port in $(seq "$base" $(( end - 1 ))); do
        if ! printf '%s\n' "$used_ports" | grep -qx "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
    done

    # Band exhausted.
    printf "Port band exhausted for template '%s': band [%s, %s), all %s ports used. Extend TEAM_LCARS_PORT_RANGE in <template>.conf and rerun.\n" \
        "$template_id" "$base" "$end" "$range" >&2
    return 1
}

# aiteamforge_export_exclusions
# Prints one exclusion pattern per line, suitable for use with:
#   zip --exclude or rsync --exclude
# Mirrors EXPORT_EXCLUSION_SUFFIXES / EXPORT_EXCLUSION_NAMES / EXPORT_EXCLUSION_PATTERNS
# in kanban-hooks/aiteamforge_paths.py — keep in sync. (XACA-0168-017)
aiteamforge_export_exclusions() {
    # Suffix-based exclusions
    printf '*.lock\n'
    # Exact-name exclusions
    printf '.DS_Store\n'
    printf 'firebase-debug.log\n'
    # Pattern exclusions
    printf '*-debug.log\n'
}

# aiteamforge_list_teams
# Prints one team ID per line: the sorted UNION of the overlay's teams and the
# baked-in DEFAULT_TEAMS rows.
#
# XACA-1161: this used to return the OVERLAY's keys ONLY whenever a config file
# existed, falling back to the seed rows only when it did not — so a team that
# lives solely in the seed was invisible to every caller. That is strictly
# narrower than the Python resolver's registered_teams(), which is "the union,
# never either tier alone". The gap was already being papered over twice INSIDE
# THIS FILE: aiteamforge_lcars_port_team_map hand-built
#   { aiteamforge_list_teams; _AITEAMFORGE_DEFAULT_TEAMS_DATA | cut -f1; } | sort -u
# in both its jq and its no-jq arm (XACA-0799-010 / -018) for exactly this
# reason. Making the union THE definition deletes the duplicated heuristic
# instead of adding a third copy of it (K501).
#
# MEASURED on this host 2026-09-10: overlay 27 slugs, seed 13 rows, union 29,
# with `freelance` and `medical` seed-only. DO NOT PIN THOSE NUMBERS —
# `spacedock` was provisioned into the overlay mid-session (26 -> 27), so the
# count is host- AND time-dependent and must be computed at runtime.
#
# The empty field name asks _aiteamforge_overlay_rows for roster rows only: no
# team declares a field called "", so only the per-team TEAM rows come back.
aiteamforge_list_teams() {
    {
        _aiteamforge_overlay_rows ""
        _AITEAMFORGE_DEFAULT_TEAMS_DATA
    } 2>/dev/null | awk -F'	' '
        $1 == "__SCHEMA__" { next }
        $2 == "TEAM"       { print $1; next }
        NF >= 7            { print $1 }
    ' | LC_ALL=C sort -u
}
