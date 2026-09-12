#!/bin/bash
# mandatory-teams.sh — Single source of truth for "mandatory" teams.
#
# XACA-1070 — Space Dock 3/4: mandatory fleet install.
#
# A "mandatory" team is one every machine in the fleet is expected to carry
# (force-appended into the setup wizard's selection, backfilled onto
# already-installed machines by `aiteamforge upgrade`, and reported as a
# fault by `aiteamforge doctor` when missing). This file is the ONE place
# that reads the `"mandatory": true` key out of share/teams/registry.json —
# the setup wizard, the upgrade backfill, and the doctor check all source
# this lib rather than each re-parsing the registry with their own jq/python
# incantation, so the three can never silently disagree about which teams
# are mandatory or what "provisioned" means.
#
# XACA-1070-001 confirmed (2026-09-10, `grep -rn "recommended" libexec/ bin/`)
# that registry.json's existing `"recommended"` boolean is declared but read
# by ZERO installer code (7 hits, all unrelated prose — "not recommended",
# "recommended for single machine"). Setting a flag nothing consumes is
# exactly the shape of a change that looks done and does nothing, so
# "mandatory" gets its own real key and its own real consumer (this file),
# not a repurposed alias of "recommended".
#
# IMPORTANT — team-agnostic by design: the intended first mandatory team
# (`spacedock`, XACA-1068/1069) does not exist yet as of this writing. Zero
# teams carry `"mandatory": true` today. atf_mandatory_teams() returning
# empty with exit 0 is the CORRECT, EXPECTED result right now — every
# consumer of this lib must treat an empty list as "nothing to do", never as
# an error. Do not hard-code any team id anywhere in this file.
#
# SHELL COMPATIBILITY: consumer machines run /bin/bash 3.2. No `declare -A`,
# no `mapfile`/`readarray`, no `${var^^}`. Verified under /bin/bash directly
# (see XACA-1070-001 subitem report) — a PATH bash 5.x check is a false
# green here (see feedback_verify_under_bin_bash_not_path_bash.md).
#
# JSON PARSING: jq preferred, python3 fallback — same priority order as
# libexec/lib/aiteamforge-paths.sh's _aiteamforge_get_field(). jq is a hard
# Formula dependency (`depends_on "jq"` in Formula/aiteamforge.rb), so it is
# always present on a brew-installed consumer; python3 is kept as the
# fallback anyway because dev-mode clones and non-Homebrew installs can run
# this lib before `brew install` has ever executed, and both interpreters
# are handled identically everywhere else in this directory.
#
# Author: Reno's Engineering Lab (Academy Team)

# Guard against double-sourcing (readonly errors in subshells; matches the
# guard idiom used by every other lib in this directory).
if [ -n "${_ATF_MANDATORY_TEAMS_SH_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi
_ATF_MANDATORY_TEAMS_SH_LOADED=1

# ─────────────────────────────────────────────────────────────────────────────
# Internal: locate share/teams/registry.json
#
# Must resolve correctly no matter which of the four caller directories
# sources this file (bin/, libexec/installers/, libexec/commands/ — twice).
# The established pattern in this directory (aiteamforge-paths.sh,
# install-team.sh) is to self-locate via THIS FILE's own BASH_SOURCE[0]
# rather than trust the caller's $PWD or the caller's own script directory —
# that is what makes it caller-location-independent in the first place.
#
# Priority:
#   1. $AITEAMFORGE_HOME, when set. PR #865 review, item 3: this used to
#      guess "${AITEAMFORGE_HOME}/../share/teams/registry.json" on the
#      theory that AITEAMFORGE_HOME is "the installed libexec dir" with
#      share/ as its sibling. That is NOT how AITEAMFORGE_HOME actually
#      behaves anywhere else in this codebase: bin/aiteamforge-doctor.sh
#      (the real Formula bin stub) sets AITEAMFORGE_HOME to
#      "$(brew --prefix)/opt/aiteamforge/libexec" and then reads
#      "${AITEAMFORGE_HOME}/share/templates/...",
#      "${AITEAMFORGE_HOME}/bin/aiteamforge-cli.sh", and
#      "${AITEAMFORGE_HOME}/libexec/lib/validate-install.sh" — i.e. it
#      treats AITEAMFORGE_HOME as the TAP ROOT (bin/, libexec/, share/ all
#      direct children), the same way bin/aiteamforge-setup.sh's own
#      self-location fallback does. The correct installed-layout guess is
#      therefore "${AITEAMFORGE_HOME}/share/teams/registry.json" — no
#      "..". The old guess was one directory too high; it happened to be
#      harmless today only because it never matched and priority 2 (self-
#      location) has always silently carried the real answer (see Section
#      G8 in tests/test-xaca-1070-mandatory-install.sh) — but a future
#      reorg that put a real "share/" one level above AITEAMFORGE_HOME
#      (e.g. XACA-0340's canonical-source tree) would have made this
#      branch silently select the WRONG registry instead of correctly
#      missing. Fixed to match the rest of the codebase rather than
#      removed: AITEAMFORGE_HOME is normally set on every real invocation
#      (Formula bin stubs, CLI) and is a cheaper/more direct resolution
#      than self-location, so keeping it as priority 1 — now pointed at
#      the right path — is still worth doing.
#   2. Self-location: this file lives at libexec/lib/mandatory-teams.sh, so
#      two levels up from its own directory is the tap root, regardless of
#      who sourced it or from where (mirrors install-team.sh's
#      HOMEBREW_TAP_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)" computed from
#      ITS OWN BASH_SOURCE[0], not the caller's).
# ─────────────────────────────────────────────────────────────────────────────
_atf_mandatory_teams_registry_path() {
    # 1. AITEAMFORGE_HOME (installed/tap-root layout: $AITEAMFORGE_HOME/share/...)
    if [ -n "${AITEAMFORGE_HOME:-}" ] && [ -f "${AITEAMFORGE_HOME}/share/teams/registry.json" ]; then
        echo "$(cd "${AITEAMFORGE_HOME}" 2>/dev/null && pwd)/share/teams/registry.json"
        return 0
    fi

    # 2. Self-location fallback (dev-mode clone, or AITEAMFORGE_HOME unset).
    local _self_dir _tap_root
    _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    if [ -n "$_self_dir" ]; then
        _tap_root="$(cd "$_self_dir/../.." 2>/dev/null && pwd)"
        if [ -n "$_tap_root" ] && [ -f "$_tap_root/share/teams/registry.json" ]; then
            echo "$_tap_root/share/teams/registry.json"
            return 0
        fi
    fi

    # Neither resolved to an existing file. Echo the best-guess path anyway
    # (self-location branch, if we got that far) so callers' error messages
    # can name where they looked; the missing-file case is handled by the
    # callers below, which all test -f before trusting this.
    if [ -n "${_tap_root:-}" ]; then
        echo "$_tap_root/share/teams/registry.json"
    else
        echo "share/teams/registry.json"
    fi
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# _atf_mandatory_teams_reject_parameterized <newline-separated candidate ids> <registry_path>
#
# XACA-1070-030 (PR #865 round 4 review, "the feature assumes
# template_id == instance_id"): this is the THIRD iteration of one bug —
# read this header before touching it again.
#
# atf_mandatory_teams() yields REGISTRY/TEMPLATE ids (share/teams/registry.json
# keys them by template — "finance", "legal", "freelance"), but
# install-team.sh:2028 names the on-disk board by INSTANCE_ID, not the
# template id ("contract §6, invariant 8"), and team-paths.json is keyed by
# instance id too, with no template back-link. For an UNPARAMETERIZED team
# (TEAM_HAS_PROJECTS != "true") template == instance, so every downstream
# consumer of atf_mandatory_teams()'s output — atf_team_has_board() (×2,
# this file + aiteamforge-upgrade.sh's _xaca1070_mandatory_team_has_board
# fallback) and the team-paths.json lookup inside
# aiteamforge-upgrade.sh's _xaca1070_add_team_working_dir_to_config() (via
# aiteamforge_team_working_dir()) — happens to resolve correctly by
# coincidence. For a PARAMETERIZED team (finance/legal/medical/freelance-
# shaped: TEAM_HAS_PROJECTS="true", optionally TEAM_REQUIRES_CLIENT_ID=
# "true" too) they diverge, and all three sites read the wrong (template)
# key forever — the upgrade backfill would then re-attempt provisioning
# that team on EVERY upgrade, exactly the outcome atf_team_has_board() was
# factored out to prevent (see that function's own header comment).
#
# TWO WAYS TO CLOSE THIS GAP — EVIDENCE FOR THE ONE CHOSEN:
#
#   (a) Auto-resolve the instance id before checking. REJECTED. Investigated
#       whether the mapping already exists rather than inventing one:
#       install-team.sh's own compute_instance_id() (and
#       bin/aiteamforge-setup.sh's _atf_resolve_team_defaults(), added in
#       THIS SAME PR for the cockpit/UPGRADE_HYDRATED workdir gap,
#       XACA-1070-021/026) DOES compute a deterministic default —
#       "<template>-<TEAM_DEFAULT_PROJECT>", or
#       "<template>-default-client-<TEAM_DEFAULT_PROJECT>" when
#       TEAM_REQUIRES_CLIENT_ID="true" too. But that default does not even
#       agree with THIS fleet's real deployed instances: legal.conf's own
#       TEAM_DEFAULT_PROJECT is "default" (confirmed by reading
#       share/teams/legal.conf), not "coparenting" — the instance this
#       machine's owner actually uses (get_board_id() in kanban-paths.sh
#       hard-codes finance→finance-personal, legal→legal-coparenting,
#       medical→medical-general as THIS repo's own already-chosen
#       instances, not a convention a fresh fleet machine could derive).
#       A deterministic backfill would therefore silently create
#       "legal-default" — a second, empty, WRONG board sitting next to the
#       real one — not detect the real one. And TEAM_REQUIRES_CLIENT_ID=
#       "true" (freelance) has no default client at all:
#       compute_instance_id() hard-`exit 1`s without one, so "deterministic"
#       isn't even reachable for that shape when update_mandatory_teams()
#       invokes install-team.sh with no --client (confirmed by reading its
#       call site: no --project/--client flags are passed there at all).
#       Manufacturing a plausible-looking but wrong instance is a WORSE
#       failure than a loud rejection — it is indistinguishable from a
#       correctly-provisioned team until a human notices the board is empty.
#
#   (b) Reject mandatory+parameterized loudly at the source. CHOSEN. "mandatory"
#       means every machine in the fleet gets this EXACT team with NO human
#       input (see this file's own header comment + the setup wizard's
#       _atf_apply_mandatory_teams). A parameterized team is the opposite of
#       that by design: its real instance encodes a PERSON's own
#       client/project/case, which nothing can choose automatically. Filtering
#       here — the single choke point EVERY consumer (wizard force-append,
#       upgrade backfill, doctor fault check) already reads through — means
#       the three affected call sites above never see a parameterized id in
#       the first place, so they need no individual patching and cannot
#       independently drift again.
#
# NOT A WHOLE-FUNCTION FAILURE: mirrors the existing no-usable-"id" malformed-
# entry handling immediately below in atf_mandatory_teams() — a rejected
# entry is skipped (with a loud stderr diagnostic naming it and why) and
# atf_mandatory_teams() still returns 0 with every OTHER, valid mandatory
# team's enforcement intact. One bad registry entry must not poison the rest,
# the exact rule the id-less-entry fix above this one already established.
#
# _atf_resolve_team_defaults() in bin/aiteamforge-setup.sh is NOT removed by
# this fix. Its TEAM_HAS_PROJECTS/TEAM_REQUIRES_CLIENT_ID branches exist
# solely to fill in _WORKDIR_/_PROJECT_/_CLIENT_ for a team that reached the
# cockpit/UPGRADE_HYDRATED branches WITHOUT running the interactive Step 2
# working-dir loop — which, by inspection of that function's own four call
# sites, only ever happens for a team force-appended by
# _atf_apply_mandatory_teams(). Once THIS filter guarantees a parameterized
# id can never reach SELECTED_TEAMS through that door, those two branches
# are UNREACHABLE BY DESIGN (documented at the function itself, not removed —
# see its header comment) rather than dead weight silently rotting.
#
# HOW: looks up each candidate id's conf at
# "$(dirname "$registry_path")/<id>.conf" — share/teams/ holds registry.json
# and every *.conf side by side, confirmed by `ls share/teams/`. Greps for an
# uncommented TEAM_HAS_PROJECTS="true" or TEAM_REQUIRES_CLIENT_ID="true" line
# — the SAME two flags install-team.sh's compute_instance_id() itself
# branches on, so this can never disagree with what the installer would
# actually do. A team with no conf file at all, or neither flag set to
# "true", is treated as unparameterized — fail-OPEN on "no evidence of
# parameterization found", not fail-closed, because an absent/unreadable
# conf is a different, pre-existing failure this file does not otherwise
# treat as fatal (install-team.sh's own conf validation is where a
# genuinely missing conf gets caught).
#
# Prints the filtered id list, one per line, order preserved. Always
# "succeeds" (no return-code contract of its own) — the caller's rc already
# reflects whether the REGISTRY itself was readable; this step only ever
# operates on an already-successfully-parsed candidate list.
# ─────────────────────────────────────────────────────────────────────────────
_atf_mandatory_teams_reject_parameterized() {
    local _candidates="$1"
    local _registry_path="$2"
    local _teams_dir
    _teams_dir="$(dirname "$_registry_path")"

    local _id _conf
    while IFS= read -r _id; do
        [ -n "$_id" ] || continue
        _conf="${_teams_dir}/${_id}.conf"
        # XACA-1070-034 (PR #865 round 5 review): match every quoting and
        # invocation variant, not just the one the shipped confs happen to use.
        # The narrow form ('...="true"') missed `=true`, `='true'`, and
        # `export TEAM_HAS_PROJECTS="true"` — so a parameterized team written in
        # any of those styles would pass this filter as UNPARAMETERIZED and be
        # force-installed with a manufactured instance id, which is precisely
        # the failure this filter exists to prevent. All 11 shipped confs use
        # the double-quoted form today, so this is hardening rather than a live
        # fix — but nothing tells a future conf author that the quoting style
        # is load-bearing, and an audit grep that only matches the form you were
        # shown is not an audit.
        #
        # KNOWN REMAINING GAP, deliberately not closed here: a conf that sets
        # the flag indirectly (via `source`, or computed in a conditional) still
        # evades a text grep. Closing that means SOURCING the conf, which is a
        # different trust model and diverges from the grep-based convention used
        # by aiteamforge-doctor.sh, aiteamforge-migrate.sh and
        # aiteamforge-setup.sh. That belongs in its own ticket covering all four
        # sites, not a one-off divergence here.
        if [ -f "$_conf" ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?TEAM_(HAS_PROJECTS|REQUIRES_CLIENT_ID)[[:space:]]*=[[:space:]]*("true"|'"'"'true'"'"'|true)[[:space:]]*(#.*)?$' "$_conf" 2>/dev/null; then
            echo "mandatory-teams.sh: \"${_id}\" is flagged \"mandatory\": true in ${_registry_path} but ${_conf} declares TEAM_HAS_PROJECTS/TEAM_REQUIRES_CLIENT_ID=\"true\" (parameterized) — mandatory + parameterized is not supported (no fleet-wide-correct instance id can be derived; see this function's own header comment in mandatory-teams.sh). Skipping this team from mandatory enforcement — fix the registry (unset \"mandatory\") or make the team unparameterized (XACA-1070-030)." >&2
            continue
        fi
        echo "$_id"
    done <<EOF
$_candidates
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# atf_mandatory_teams
#
# Echoes one mandatory team id per line, read from share/teams/registry.json
# (every entry where "mandatory" is boolean true). Order follows the
# registry's own "order" field, same as the wizard's selection list.
#
# XACA-1070-030: an entry whose OWN conf declares it parameterized
# (TEAM_HAS_PROJECTS/TEAM_REQUIRES_CLIENT_ID="true") is silently excluded
# from this list — see _atf_mandatory_teams_reject_parameterized()'s header
# comment (immediately above this function) for why "mandatory" +
# "parameterized" is unsupported by design, not a bug to auto-resolve. This
# does not change the return-code contract below: a rejected entry is
# treated exactly like the existing no-usable-"id" malformed-entry case —
# skipped, with a loud stderr diagnostic, never a whole-function failure.
#
# Return codes distinguish "genuinely zero mandatory teams" from "could not
# read the registry at all" — collapsing those two into the same silent
# empty-output-and-exit-0 result would make this whole feature quietly no-op
# the moment registry.json went missing or got corrupted, which is exactly
# the failure XACA-1070 exists to prevent:
#   0  — read the registry successfully. Stdout is the (possibly empty,
#        expected-empty-today) list of mandatory team ids.
#   1  — registry.json could not be found or could not be parsed as JSON.
#        Stdout is empty; a diagnostic is printed to stderr. Callers MUST
#        treat this as a fault, not as "no mandatory teams".
# ─────────────────────────────────────────────────────────────────────────────
atf_mandatory_teams() {
    local registry_path
    registry_path="$(_atf_mandatory_teams_registry_path)"

    if [ ! -f "$registry_path" ]; then
        echo "mandatory-teams.sh: registry.json not found at ${registry_path} — cannot determine mandatory teams (XACA-1070)" >&2
        return 1
    fi

    # ── Try jq ────────────────────────────────────────────────────────────
    if command -v jq >/dev/null 2>&1; then
        local out jq_rc bad_count
        # PR #865 review, BLOCKING 2: the filter below used to be
        # "[.teams[]? | select(.mandatory == true)] | sort_by(.order // 0) |
        # .[].id" with no guard on `.id` at all. `jq -e`'s exit code is keyed
        # to the LAST emitted value: 0 only when that last value is truthy.
        # A registry with a valid mandatory entry (id present) PLUS one
        # mandatory entry missing "id" emits a trailing `null` for the
        # id-less entry (`.id` on an object with no "id" key is `null`, not
        # an error) — `-e` sees that final `null`, exits 1, and the "valid
        # JSON, filter just matched nothing" branch below then confirms
        # `.teams` exists and returns 0 with EMPTY stdout, discarding the
        # valid entry too. rc=0-with-empty-stdout is this function's OWN
        # contract for "zero mandatory teams, all fine" (see the header
        # comment above) — this is the exact conflation that contract
        # exists to prevent, reached through a different door, inside the
        # one function whose entire purpose is preventing it. Reproduced
        # live: REG with a valid `alpha` (mandatory:true) + one mandatory
        # entry with no "id" returned rc=0 / empty stdout, silently
        # dropping `alpha`.
        #
        # Fix: exclude null/empty ids INSIDE the filter, before `.id` is
        # ever the value `-e` inspects — `(.id // "") != ""` catches both a
        # missing key (`.id` is `null`, `// ""` turns that into `""`) and an
        # explicit `"id": ""`. A malformed sibling can no longer poison
        # `-e`'s last-value check for the valid entries around it.
        out="$(jq -e -r '
            [.teams[]? | select(.mandatory == true and (.id // "") != "")]
            | sort_by(.order // 0)
            | .[].id
        ' "$registry_path" 2>/dev/null)"
        jq_rc=$?
        # -e's exit code is NOT a simple 0/1: 0 = last output truthy, 1 = last
        # output was false/null, and — MEASURED here, not assumed — 4 = the
        # filter produced NO output at all (an empty result set), which is
        # exactly what happens when zero teams are mandatory (today's real
        # state) OR every mandatory-flagged entry lacked a usable id (the
        # fixed filter above now excludes all of them, correctly, rather
        # than letting one poison the rest). rc 2 (jq usage/compile error)
        # and 5 (bad --arg type etc.) are real errors and must NOT be
        # treated as "just empty".
        if [ "$jq_rc" -eq 0 ]; then
            # XACA-1070-030: filter out any candidate whose OWN conf declares
            # it parameterized before ever emitting it — see
            # _atf_mandatory_teams_reject_parameterized's header comment
            # (immediately above this function) for the full rationale.
            out="$(printf '%s\n' "$out" | sed '/^$/d')"
            out="$(_atf_mandatory_teams_reject_parameterized "$out" "$registry_path")"
            printf '%s\n' "$out" | sed '/^$/d'
        elif [ "$jq_rc" -eq 1 ] || [ "$jq_rc" -eq 4 ]; then
            # Valid JSON, filter just matched nothing (or the array itself is
            # empty) — confirm the document actually HAS a .teams array
            # before calling this "fine"; a registry with no .teams key at
            # all is still a malformed registry, not "zero mandatory teams".
            if jq -e '.teams' "$registry_path" >/dev/null 2>&1; then
                :  # fall through to the malformed-entry surfacing below, then return 0
            else
                echo "mandatory-teams.sh: ${registry_path} is not valid JSON (or has no .teams array) — cannot determine mandatory teams (XACA-1070)" >&2
                return 1
            fi
        else
            echo "mandatory-teams.sh: ${registry_path} is not valid JSON (or has no .teams array) — cannot determine mandatory teams (XACA-1070)" >&2
            return 1
        fi

        # Surface malformed siblings rather than dropping them silently — a
        # missing "id" on a "mandatory": true entry is a real registry
        # defect (someone will wonder why their team never got installed),
        # even though this function's contract is to keep going with the
        # entries that ARE valid rather than fail the whole read over it.
        bad_count="$(jq '[.teams[]? | select(.mandatory == true and ((.id // "") == ""))] | length' "$registry_path" 2>/dev/null)"
        if [ -n "$bad_count" ] && [ "$bad_count" != "0" ]; then
            echo "mandatory-teams.sh: ${registry_path} has ${bad_count} \"mandatory\": true entr$( [ "$bad_count" = "1" ] && echo y || echo ies) with no usable \"id\" — skipped, not treated as an error (XACA-1070)" >&2
        fi
        return 0
    fi

    # ── Try python3 (jq unavailable) ────────────────────────────────────────
    #
    # XACA-1070-022 (PR #865 round 3): the two branches must AGREE — a
    # registry that reads fine under jq must read the same way here, not
    # get misreported as corrupt.
    #
    # Bug 1 — sort key: `t.get('order', 0)` only substitutes the default
    # 0 when the "order" KEY IS ABSENT. A present-but-null "order" (valid
    # JSON — someone wrote `"order": null` instead of omitting the key
    # entirely) returns `None` unchanged, not 0. `list.sort()` compares
    # keys pairwise even when they turn out equal, and Python 3's `None`
    # has no `__lt__` — comparing `None < None` (two mandatory teams that
    # both have `"order": null`) raises `TypeError` on its own, with no
    # third value needed. That TypeError was swallowed by the blanket
    # `except Exception: sys.exit(2)` below, so it never "crashed" this
    # script, but rc=2 fails the `rc -eq 0` check a few lines down and the
    # registry gets reported as "not valid JSON" even though it parsed
    # fine and every entry was well-formed — a false fault on a valid
    # registry, and a real disagreement with the jq branch, which treats
    # `.order // 0` (jq's null-coalescing operator) as 0 for exactly this
    # case and returns both ids successfully (MEASURED: reproduced this
    # exact TypeError with a 2-mandatory/both-null-order fixture, jq
    # exit 0 vs python3 exit 2 on the identical registry).
    #
    # Fix: `t.get('order') or 0` collapses BOTH "key absent" (None) and
    # "key present but null" (also None) to 0, the same tiebreak value
    # jq's `.order // 0` already uses for both cases — `or 0` is safe here
    # specifically because "order" is a rank number and the only falsy
    # number, 0, already maps to the same 0 default. Python's sort is
    # stable (Timsort), matching jq's `sort_by` stability, so two entries
    # that tie at 0 keep their original registry order in BOTH branches.
    #
    # XACA-1070-025 (PR #865 round 3 review): Bug 1's `or 0` fix above only
    # handles the null/absent case — it leaves a NON-null, NON-falsy "order"
    # untouched, whatever its type. A registry with "order" a STRING on one
    # mandatory entry and a NUMBER on another (both valid JSON, both
    # genuinely present) survives `or 0` unchanged and reaches
    # `list.sort()` with a str key on one entry and an int key on the
    # other — Python 3 raises TypeError comparing str/int with no default
    # ordering, caught by the SAME blanket `except Exception: sys.exit(2)`
    # below, and misreported as "not valid JSON" exactly like Bug 1's
    # None/None case (REPRODUCED: rc=1 + the false diagnostic under a
    # jq-free PATH; jq itself succeeds on the identical registry, printing
    # both ids). Same failure shape -022 fixed, reached through the type
    # -022 did not cover.
    #
    # Fix: rank by JSON TYPE first, value second — jq's `sort_by` does this
    # implicitly (jq's type ordering places numbers before strings,
    # regardless of value; MEASURED: {"order":"1"} vs {"order":2} sorts the
    # number-order entry FIRST, i.e. "2" before "1" as a STRING would read —
    # jq is comparing types, not numeric/lexical value). `_order_sort_key`
    # below reproduces that: rank 0 for numbers (None/absent already
    # coalesced to the number 0 by `or 0`), rank 1 for strings, rank 2 for
    # anything else (list/dict — no realistic registry produces these, but
    # a rank is still owed so sort() never sees mixed incomparable types
    # again). Two entries in the SAME rank compare their raw values exactly
    # as before (numeric compare for numbers, lexical for strings) —
    # unchanged for every registry that was already working correctly
    # under both branches.
    #
    # Bug 2 — malformed-entry diagnostic: the jq branch (above) separately
    # counts "mandatory": true entries with no usable "id" and warns to
    # stderr; this branch had no equivalent, so the exact same malformed
    # sibling that jq reports was silently dropped here without a trace.
    # Fixed by counting id-less mandatory entries in Python too and
    # relaying the count back through a stderr sentinel line
    # (`XACA1070_BAD_COUNT=<n>`) that the shell side below parses and
    # re-announces in the SAME wording the jq branch uses, so a caller
    # cannot tell — and does not need to know — which parser produced it.
    if command -v python3 >/dev/null 2>&1; then
        local out rc err_file bad_count
        err_file="$(mktemp "${TMPDIR:-/tmp}/atf-mandatory-teams-py.XXXXXX" 2>/dev/null || echo "${TMPDIR:-/tmp}/atf-mandatory-teams-py.$$")"
        out="$("${AITEAMFORGE_PYTHON:-python3}" - "$registry_path" <<'PYEOF' 2>"$err_file"
import sys, json
path = sys.argv[1]
try:
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
    teams = data['teams']
    mandatory = [t for t in teams if t.get('mandatory') is True]
    # XACA-1070-022: `or 0` -- not `.get('order', 0)` -- so a present-but-
    # null "order" ties at 0 exactly like jq's `.order // 0`, instead of
    # staying None and blowing up list.sort()'s pairwise comparison.
    #
    # XACA-1070-025: `or 0` alone still leaves a present, non-falsy "order"
    # untouched -- a STRING on one mandatory entry and a NUMBER on another
    # (both valid) reach sort() with incomparable key types and raise
    # TypeError. Rank by JSON type first (numbers before strings, matching
    # the type ordering jq itself already applies -- MEASURED), raw value
    # second, so two entries of the SAME type still compare exactly as
    # before.
    def _order_sort_key(t):
        # XACA-1070-030 (prose finding, PR #865 round 4 review, third
        # iteration of this exact shape): `or 0` collapses EVERY
        # Python-falsy value -- not just None/False -- into the default,
        # but jqs `//` operator only substitutes on `null`/`false`. An
        # order value of empty string (or an empty object/array) is
        # falsy in Python and truthy in jq, so `or 0` silently
        # reassigned it to 0 here while the jq branch kept the original
        # value and ranked it as a string (or object/array) instead --
        # ordering-only divergence (mandatory membership itself is
        # unaffected), but a real, avoidable disagreement between the
        # two branches. Coalesce ONLY on the two values jqs `//` treats
        # as absent -- None (JSON null) and False (JSON false) -- so a
        # present-but-Python-falsy order value survives untouched,
        # matching the jq branch exactly for ANY value type.
        _raw_order = t.get('order')
        order = 0 if (_raw_order is None or _raw_order is False) else _raw_order
        if isinstance(order, bool):
            # jq: false < true, both before numbers/strings.
            return (0, int(order))
        if isinstance(order, (int, float)):
            return (1, order)
        if isinstance(order, str):
            return (2, order)
        # list/dict or anything else -- no realistic registry produces this,
        # but still needs a rank so sort() never sees mixed types again.
        return (3, str(order))
    mandatory.sort(key=_order_sort_key)
    bad = 0
    for t in mandatory:
        tid = t.get('id')
        if tid:
            print(tid)
        else:
            bad += 1
    if bad:
        # Sentinel line on stderr only -- never mixed into the id list on
        # stdout. The shell side parses this back out below.
        print('XACA1070_BAD_COUNT=%d' % bad, file=sys.stderr)
except Exception:
    sys.exit(2)
PYEOF
)"
        rc=$?
        bad_count="$(grep -o 'XACA1070_BAD_COUNT=[0-9]*' "$err_file" 2>/dev/null | tail -1 | cut -d= -f2)"
        rm -f "$err_file" 2>/dev/null
        if [ "$rc" -eq 0 ]; then
            # XACA-1070-030: same shared filter the jq branch calls above —
            # ONE implementation, applied identically to both parsers' raw
            # output, so they cannot independently disagree about which
            # candidates are parameterized (see
            # _atf_mandatory_teams_reject_parameterized's header comment).
            out="$(printf '%s\n' "$out" | sed '/^$/d')"
            out="$(_atf_mandatory_teams_reject_parameterized "$out" "$registry_path")"
            printf '%s\n' "$out" | sed '/^$/d'
            # Mirror the jq branch's malformed-entry diagnostic verbatim
            # (same wording) so the two parsers never silently disagree
            # about whether a corrupt "mandatory": true entry (no usable
            # id) was noticed.
            if [ -n "$bad_count" ] && [ "$bad_count" != "0" ]; then
                echo "mandatory-teams.sh: ${registry_path} has ${bad_count} \"mandatory\": true entr$( [ "$bad_count" = "1" ] && echo y || echo ies) with no usable \"id\" — skipped, not treated as an error (XACA-1070)" >&2
            fi
            return 0
        fi
        echo "mandatory-teams.sh: ${registry_path} is not valid JSON (or has no .teams array) — cannot determine mandatory teams (XACA-1070)" >&2
        return 1
    fi

    echo "mandatory-teams.sh: neither jq nor python3 is available — cannot parse ${registry_path} (XACA-1070)" >&2
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# atf_is_mandatory_team <team_id>
#
# Exit 0 if $1 is a mandatory team id, 1 otherwise (including "could not read
# the registry" — fail closed on the membership question: an unreadable
# registry must never be treated as "yes, mandatory" OR silently treated as
# a normal negative that a caller stops investigating. Callers that need to
# distinguish those two failure shapes should call atf_mandatory_teams()
# directly and check ITS return code; this wrapper is for the common
# single-team membership test).
# No stdout.
# ─────────────────────────────────────────────────────────────────────────────
atf_is_mandatory_team() {
    local team_id="$1"
    [ -n "$team_id" ] || return 1

    local mandatory_list
    mandatory_list="$(atf_mandatory_teams)" || return 1

    local line
    while IFS= read -r line; do
        [ "$line" = "$team_id" ] && return 0
    done <<EOF
$mandatory_list
EOF
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# atf_team_has_board <team_id>
#
# Exit 0 when a real "*-board.json" file exists in team $1's kanban
# directory, 1 otherwise (including "cannot even determine the kanban dir at
# all" — a lookup failure is never treated as proof of absence, it is just
# "cannot verify"). No stdout.
#
# XACA-1070-017: this glob used to be duplicated VERBATIM in two places —
# atf_team_provisioned() immediately below, and
# libexec/commands/aiteamforge-upgrade.sh's own
# _xaca1070_mandatory_team_has_board(). Two independent definitions of "does
# this team have a board on disk" is exactly the drift vector that produced
# this ticket's worst defect: the upgrade backfill provisioning a board
# `aiteamforge start` would never launch, because two components disagreed
# about what "provisioned" meant (see XACA-1070's own "DEFECT FOUND IN THIS
# TICKET'S OWN FIX" note). Factored out so there is exactly ONE definition
# of the shared evidence primitive.
#
# Deliberately NOT the same predicate as atf_team_provisioned(): this
# function does not check .aiteamforge-config membership. The two composite
# checks built on top of this primitive need DIFFERENT policies —
# atf_team_provisioned() additionally requires config-list membership,
# while aiteamforge-upgrade.sh's backfill deliberately does not (gating the
# backfill's skip-vs-provision decision on the full atf_team_provisioned()
# predicate would re-invoke the installer on every mandatory team, every
# upgrade, forever — see that call site's own header comment). Only the
# board-evidence HALF is common to both; that is all this factors out.
#
# XACA-1070-029 (PR #865 round 3 review): this used to glob "$kdir"/*-board.json
# and return 0 on ANY match — so a team whose kanban_dir happens to be a
# directory SHARED with other teams' boards (e.g. multiple teams installed
# under one working dir, or a mis-resolved kanban_dir from BLOCKING A/-026)
# reports "has a board" for a team that has none of its own, as long as
# SOME *-board.json sits in that directory. REPRODUCED: with only
# "academy-board.json" present in $kdir, `atf_team_has_board widget`
# returned 0 (true). This primitive was factored out (XACA-1070-017)
# precisely so atf_team_provisioned() and the upgrade backfill could not
# disagree about "does this team have a board" — a glob that answers for
# the WRONG team defeats that purpose identically in both callers: sharing
# the primitive made them consistent, not correct, and now both would be
# wrong in the same way. Fixed to check for the SPECIFIC team's own board
# file by exact name, never a wildcard match against whatever else the
# directory contains.
# ─────────────────────────────────────────────────────────────────────────────
atf_team_has_board() {
    local team_id="$1"
    [ -n "$team_id" ] || return 1
    command -v aiteamforge_team_kanban_dir >/dev/null 2>&1 || return 1

    local kdir
    kdir="$(aiteamforge_team_kanban_dir "$team_id" 2>/dev/null)" || return 1
    [ -n "$kdir" ] && [ -d "$kdir" ] || return 1

    [ -f "${kdir}/${team_id}-board.json" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# atf_team_provisioned <team_id>
#
# Exit 0 if team $1 appears provisioned on THIS host, 1 otherwise. No stdout.
#
# DEFINITION OF "PROVISIONED" (derived from real on-disk/config evidence,
# not guessed): a team is provisioned when BOTH are true —
#   1. It is a member of get_configured_teams() (libexec/lib/config.sh) —
#      the SAME team-enumeration function aiteamforge-doctor.sh's
#      check_board_resolution() and aiteamforge-upgrade.sh already use to
#      decide which teams are configured on this box (see the "Team
#      enumeration is get_configured_teams()" comment in
#      aiteamforge-upgrade.sh). Deferring to it means this check can never
#      silently disagree with the doctor/upgrade about team membership.
#   2. Its kanban board actually exists on disk: aiteamforge_team_kanban_dir()
#      (libexec/lib/aiteamforge-paths.sh) resolves to a real directory that
#      contains at least one "*-board.json" file — see atf_team_has_board()
#      immediately above, the single shared definition of this half
#      (XACA-1070-017).
#
# Membership in the config list alone is NOT sufficient — .aiteamforge-config
# can list a team whose install was interrupted before the board was
# written, or whose board.json was later removed by hand. Requiring the
# on-disk board file is the same standard aiteamforge-doctor.sh's
# check_board_resolution() already holds a team to (a missing board is a
# doctor FAULT, not a shrug). Used by the doctor check (XACA-1070-007) and
# by XACA-1071's kb-spacedock, which sources this lib rather than scraping
# doctor's human-readable output.
# ─────────────────────────────────────────────────────────────────────────────
atf_team_provisioned() {
    local team_id="$1"
    [ -n "$team_id" ] || return 1

    _atf_mandatory_teams_load_config_lib || return 1
    # aiteamforge-paths.sh is optional here: if it can't be loaded we still
    # answer based on config-list membership alone rather than hard-failing
    # the whole question (degrade, don't fail closed on a *sibling* lib being
    # absent — that's different from the registry itself being unreadable).
    _atf_mandatory_teams_load_paths_lib || true

    command -v get_configured_teams >/dev/null 2>&1 || return 1

    local configured
    configured="$(get_configured_teams 2>/dev/null)" || return 1
    [ -n "$configured" ] || return 1

    local found=1 t
    for t in $configured; do
        if [ "$t" = "$team_id" ]; then
            found=0
            break
        fi
    done
    [ "$found" -eq 0 ] || return 1

    # Membership confirmed. Now require real on-disk evidence, when we have
    # a way to look for it. XACA-1070-017: the evidence check itself is
    # atf_team_has_board() above — this is the ONLY caller-visible change
    # from the factor-out; the outer `command -v aiteamforge_team_kanban_dir`
    # guard is kept here (not inside atf_team_has_board) because it decides
    # whether to skip the board requirement ENTIRELY when the paths lib
    # isn't loaded (degrade to config-membership-only), which is a different
    # decision than atf_team_has_board() correctly returning 1 for "cannot
    # verify" when called directly by some other consumer.
    if command -v aiteamforge_team_kanban_dir >/dev/null 2>&1; then
        atf_team_has_board "$team_id" || return 1
    fi

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Internal: lazy-load sibling libs this file depends on for
# atf_team_provisioned(). Both config.sh and aiteamforge-paths.sh carry their
# own double-source guards, so sourcing them here is always safe even if a
# caller already sourced one directly.
# ─────────────────────────────────────────────────────────────────────────────
_atf_mandatory_teams_load_config_lib() {
    command -v get_configured_teams >/dev/null 2>&1 && return 0

    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    [ -n "$self_dir" ] && [ -f "$self_dir/config.sh" ] || return 1
    # shellcheck source=./config.sh
    # shellcheck disable=SC1091
    . "$self_dir/config.sh" 2>/dev/null || return 1
    command -v get_configured_teams >/dev/null 2>&1
}

_atf_mandatory_teams_load_paths_lib() {
    command -v aiteamforge_team_kanban_dir >/dev/null 2>&1 && return 0

    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    [ -n "$self_dir" ] && [ -f "$self_dir/aiteamforge-paths.sh" ] || return 1
    # shellcheck source=./aiteamforge-paths.sh
    # shellcheck disable=SC1091
    . "$self_dir/aiteamforge-paths.sh" 2>/dev/null || return 1
    command -v aiteamforge_team_kanban_dir >/dev/null 2>&1
}
