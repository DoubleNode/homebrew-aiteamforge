#!/bin/bash

# test-xaca-0853-dns-team-conf.sh
#
# Regression + structural tests for XACA-0853: dns shipped NO share/teams/*.conf,
# which made it invisible to every code path that discovers teams by globbing
# that directory. The team could not be provisioned, and sweeps believed to be
# fleet-wide silently skipped it.
#
# WHY THIS BECAME LOAD-BEARING ON 2026-09-02. The previous arrangement — dns
# lifecycle scripts hand-authored and committed to the dev-team repo root —
# worked only because dns ran on the dev-source machine, where those files were
# simply present. On 2026-09-02 dns migrated to a TAP CONSUMER with no dev-team
# checkout. Measured there 2026-09-09: the 19GB umbrella tree, 7 personas and a
# live LCARS on :8180 were all present, and ALL FOUR lifecycle scripts
# (startup/shutdown/connect/disconnect) were absent. The team was running with
# no sanctioned way to be started, stopped, or attached to.
#
# NON-VACUITY. Structural greps are the failure mode this harness is prone to:
# a pattern that matches nothing reads identical to a pattern whose contract
# holds. Every structural assertion below therefore asserts on a RESOLVED LINE
# NUMBER or a COUNT, never on "grep found something". T0 is a negative control
# that fails loudly if the file under test cannot be located at all, so a moved
# or renamed installer can never present as a green suite.
#
# CONTRACT UNDER TEST:
#   1. share/teams/dns.conf exists, is shell-parseable, and sets TEAM_ID=dns.
#   2. It declares all 7 dns agents, each with a 4-window list — the data whose
#      absence XACA-0862 warned would ship broken tmux session names.
#   3. dns appears in share/teams/registry.json (the installable catalog).
#   4. The tap ships dns-connect.sh / dns-disconnect.sh and NOTHING ELSE for dns.
#      dns is a FLAT team, and flat teams ship no startup/shutdown/station
#      scripts — those are rendered/generated at install time. An earlier
#      revision of this ticket shipped them and would have broken dns on the
#      first upgrade; T4 now asserts the negative permanently.
#   5. _xaca0483_install_script is defined exactly ONCE, and BEFORE
#      _render_connect_disconnect — the ordering bug that would have made a
#      hand-authored connect script die with "command not found" on the
#      --connect-only path while working on the main install path.
#   6. The hand-authored branch is a FILE-PRESENCE contract, not a hardcoded
#      team id, and is evaluated BEFORE the parametric and flat template
#      branches so a team shipping its own scripts is never overwritten.

set -uo pipefail

# ---------------------------------------------------------------------------
# Harness (self-contained; matches the tap suite's test_pass/test_fail shape)
# ---------------------------------------------------------------------------
_PASS_COUNT=0
_FAIL_COUNT=0
_CURRENT_TEST=""

start_test() { _CURRENT_TEST="$1"; echo "  → $1"; }
test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }

# ---------------------------------------------------------------------------
# Self-locate the tap root from this script, so CWD never matters.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONF="$TAP_ROOT/share/teams/dns.conf"
REGISTRY="$TAP_ROOT/share/teams/registry.json"
INSTALLER="$TAP_ROOT/libexec/installers/install-team.sh"
TEAMS_SCRIPTS="$TAP_ROOT/share/scripts/teams"

echo "XACA-0853 — dns team conf + hand-authored connect provisioning"
echo "tap root: $TAP_ROOT"
echo

# ---------------------------------------------------------------------------
# T0 — NEGATIVE CONTROL. If the files under test cannot be found, every
# structural assertion below would trivially "not match" and could be misread
# as passing. Fail loudly and stop instead.
# ---------------------------------------------------------------------------
start_test "T0 negative control: files under test are present"
_t0_missing=""
for _f in "$CONF" "$REGISTRY" "$INSTALLER"; do
    [ -f "$_f" ] || _t0_missing="$_t0_missing $_f"
done
if [ -n "$_t0_missing" ]; then
    test_fail "cannot locate:$_t0_missing — every later assertion would be vacuous"
    echo
    echo "RESULT: $_PASS_COUNT passed, $_FAIL_COUNT failed (aborted at negative control)"
    exit 1
fi
test_pass

# ---------------------------------------------------------------------------
# T1 — conf exists, parses, and identifies dns
# ---------------------------------------------------------------------------
start_test "T1 dns.conf is shell-parseable and sets TEAM_ID=dns"
if ! bash -n "$CONF" 2>/dev/null; then
    test_fail "dns.conf is not shell-parseable"
else
    _tid="$(unset TEAM_ID; . "$CONF" >/dev/null 2>&1; echo "${TEAM_ID:-}")"
    if [ "$_tid" = "dns" ]; then test_pass; else test_fail "TEAM_ID resolved to '$_tid', expected 'dns'"; fi
fi

# ---------------------------------------------------------------------------
# T2 — all 7 agents present, each with exactly 4 windows.
# This is the data XACA-0862 named as the real missing input. Asserting the
# COUNT (not merely "some windows exist") is what makes this non-vacuous.
# ---------------------------------------------------------------------------
start_test "T2 all 7 dns agents declared, each with a 4-window list"
_t2_err=""
_t2_out="$(
    . "$CONF" >/dev/null 2>&1
    echo "COUNT=${#TEAM_AGENTS[@]}"
    for _a in "${TEAM_AGENTS[@]}"; do
        _v="AGENT_WINDOWS_$_a"
        _w="$(eval "printf '%s' \"\${$_v:-}\"")"
        echo "AGENT=$_a WINDOWS=$(printf '%s' "$_w" | wc -w | tr -d ' ')"
    done
)"
_t2_count="$(printf '%s\n' "$_t2_out" | sed -n 's/^COUNT=//p')"
[ "$_t2_count" = "7" ] || _t2_err="expected 7 agents, got '$_t2_count'"
while IFS= read -r _line; do
    case "$_line" in
        AGENT=*)
            _an="${_line#AGENT=}"; _an="${_an%% *}"
            _wc="${_line##*WINDOWS=}"
            [ "$_wc" = "4" ] || _t2_err="$_t2_err; agent '$_an' has $_wc windows, expected 4"
            ;;
    esac
done <<EOF
$_t2_out
EOF
if [ -z "$_t2_err" ]; then test_pass; else test_fail "$_t2_err"; fi

# ---------------------------------------------------------------------------
# T3 — dns is in the installable catalog
# ---------------------------------------------------------------------------
start_test "T3 dns present in registry.json and the file is valid JSON"
if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$REGISTRY" >/dev/null 2>&1; then
    test_fail "registry.json is not valid JSON"
else
    _n="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for t in d.get('teams',[]) if t.get('id')=='dns'))
" "$REGISTRY" 2>/dev/null)"
    if [ "$_n" = "1" ]; then test_pass; else test_fail "expected exactly 1 dns entry, found '$_n'"; fi
fi

# ---------------------------------------------------------------------------
# T4 — dns ships EXACTLY connect/disconnect, and deliberately NOT
# startup/shutdown/stations.
#
# Both halves matter, and the negative half is the one with teeth. dns is a
# FLAT team (TEAM_HAS_PROJECTS=false). Flat teams ship no startup/shutdown or
# station scripts — academy, android, command, firebase and ios ship none —
# because the installer renders the master from team-startup.sh.template and
# GENERATES the stations from personas.
#
# An earlier revision of this ticket shipped them anyway. That installs
# cleanly and breaks later, which is why it is asserted here permanently:
# install-team.sh's copy block is gated on _is_parametric_team (false for dns)
# so the files are never installed, but aiteamforge-upgrade.sh's
# update_team_scripts() globs share/scripts/teams/*-startup.sh and refreshes
# every target that already exists. dns joining that glob means the first
# upgrade overwrites the correctly generated stations with dev-machine copies
# pointing at the wrong layout — all seven sessions down, on a working install.
# ---------------------------------------------------------------------------
start_test "T4 dns ships connect/disconnect only — no startup/shutdown/stations (flat-team rule)"
_t4_err=""
for _f in dns-connect.sh dns-disconnect.sh; do
    [ -f "$TEAMS_SCRIPTS/$_f" ] || _t4_err="$_t4_err missing:$_f"
done
for _f in dns-startup.sh dns-shutdown.sh; do
    [ ! -f "$TEAMS_SCRIPTS/$_f" ] || _t4_err="$_t4_err must-not-ship:$_f"
done
if [ -d "$TEAMS_SCRIPTS/dns/scripts" ]; then
    _t4_n="$(find "$TEAMS_SCRIPTS/dns/scripts" -type f | wc -l | tr -d ' ')"
    _t4_err="$_t4_err must-not-ship:dns/scripts($_t4_n files)"
fi
# Cross-check the rule against a real flat peer, so this cannot pass by
# asserting a rule that has silently stopped applying to anyone.
if [ -f "$TEAMS_SCRIPTS/academy-startup.sh" ]; then
    _t4_err="$_t4_err flat-rule-broken: academy now ships a startup script, re-derive this contract"
fi
if [ -z "$_t4_err" ]; then test_pass; else test_fail "$_t4_err"; fi

# ---------------------------------------------------------------------------
# T4b — nothing dns ships may carry a literal developer home path. The install
# rewrite handles ~/dev-team, $HOME/dev-team and ${HOME}/dev-team; a literal
# /Users/<name>/dev-team matches none of them and ships verbatim to a machine
# that by definition has no such directory.
# ---------------------------------------------------------------------------
start_test "T4b shipped dns scripts carry no literal /Users/<user>/dev-team path"
_t4b_hits=""
for _f in "$TEAMS_SCRIPTS/dns-connect.sh" "$TEAMS_SCRIPTS/dns-disconnect.sh"; do
    [ -f "$_f" ] || continue
    if grep -qE '/Users/[A-Za-z0-9._-]+/dev-team' "$_f"; then
        _t4b_hits="$_t4b_hits $(basename "$_f")"
    fi
done
if [ -z "$_t4b_hits" ]; then test_pass; else test_fail "literal home path in:$_t4b_hits"; fi

# ---------------------------------------------------------------------------
# T5 — ORDERING GUARD. _render_connect_disconnect is called from the
# --connect-only early exit. If _xaca0483_install_script is defined after that
# call site, the hand-authored path dies with "command not found" on that path
# only — a split failure that passes a main-flow smoke test.
# Asserted on resolved line numbers, so a renamed function fails rather than
# silently matching nothing.
# ---------------------------------------------------------------------------
start_test "T5 _xaca0483_install_script defined exactly once, before every _render_connect_disconnect call"
_def_count="$(grep -c '^_xaca0483_install_script() {' "$INSTALLER" || true)"
_def_line="$(grep -n '^_xaca0483_install_script() {' "$INSTALLER" | head -1 | cut -d: -f1)"
_t5_err=""
if [ "$_def_count" != "1" ]; then
    _t5_err="expected exactly 1 definition, found $_def_count"
elif [ -z "$_def_line" ]; then
    _t5_err="could not resolve definition line number"
else
    _call_lines="$(grep -n '^[[:space:]]*_render_connect_disconnect[[:space:]]*$' "$INSTALLER" | cut -d: -f1)"
    if [ -z "$_call_lines" ]; then
        _t5_err="no _render_connect_disconnect call sites found — assertion would be vacuous"
    else
        for _cl in $_call_lines; do
            [ "$_cl" -gt "$_def_line" ] || _t5_err="$_t5_err; call at line $_cl precedes definition at $_def_line"
        done
    fi
fi
if [ -z "$_t5_err" ]; then test_pass; else test_fail "$_t5_err"; fi

# ---------------------------------------------------------------------------
# T6 — the hand-authored opt-in is a FILE-PRESENCE contract, not a team list.
# A hardcoded `dns` would be the sibling-heuristic that must be found and
# edited again for the next such team.
# ---------------------------------------------------------------------------
start_test "T6 _has_preauthored_connect keys on file presence, not a hardcoded team id"
_t6_body="$(sed -n '/^_has_preauthored_connect() {/,/^}/p' "$INSTALLER")"
if [ -z "$_t6_body" ]; then
    test_fail "_has_preauthored_connect not found — assertion would be vacuous"
elif printf '%s' "$_t6_body" | grep -qE '(==|=~|\[\[ *"?\$?\{?TEAM_ID)[^=]*(dns|mainevent)'; then
    test_fail "function hardcodes a team id; it must key on file presence only"
elif printf '%s' "$_t6_body" | grep -q 'share/scripts/teams/\${TEAM_ID}-connect.sh'; then
    test_pass
else
    test_fail "function does not test for share/scripts/teams/\${TEAM_ID}-connect.sh"
fi

# ---------------------------------------------------------------------------
# T7 — BRANCH ORDER. The hand-authored branch must be evaluated before the
# parametric and flat template branches, or a team shipping its own scripts
# gets them silently overwritten by a template render.
# ---------------------------------------------------------------------------
start_test "T7 hand-authored branch precedes the parametric branch in _render_connect_disconnect"
_fn_start="$(grep -n '^_render_connect_disconnect() {' "$INSTALLER" | head -1 | cut -d: -f1)"
if [ -z "$_fn_start" ]; then
    test_fail "_render_connect_disconnect not found — assertion would be vacuous"
else
    _pre_off="$(sed -n "${_fn_start},\$p" "$INSTALLER" | grep -n '_has_preauthored_connect' | head -1 | cut -d: -f1)"
    _par_off="$(sed -n "${_fn_start},\$p" "$INSTALLER" | grep -n '_is_parametric_team' | head -1 | cut -d: -f1)"
    if [ -z "$_pre_off" ] || [ -z "$_par_off" ]; then
        test_fail "could not resolve both branch offsets (pre='$_pre_off' par='$_par_off')"
    elif [ "$_pre_off" -lt "$_par_off" ]; then
        test_pass
    else
        test_fail "hand-authored branch at offset $_pre_off does not precede parametric at $_par_off"
    fi
fi

# ---------------------------------------------------------------------------
# T8 — WHICH BRANCH dns TAKES, not merely what the tap carries.
# (Review subitem 3.) Carriage and installation are different claims. dns must
# take the FLAT path: TEAM_HAS_PROJECTS=false makes _is_parametric_team false,
# which is exactly what keeps the parametric copy block from installing files
# — and is why shipping startup/station scripts for dns is incoherent.
# Asserted from both ends: the conf's value, and the gate the installer uses.
# ---------------------------------------------------------------------------
start_test "T8 dns takes the flat install path (TEAM_HAS_PROJECTS=false gates it out of the parametric copy)"
_t8_err=""
_t8_hasproj="$(unset TEAM_HAS_PROJECTS; . "$CONF" >/dev/null 2>&1; echo "${TEAM_HAS_PROJECTS:-}")"
[ "$_t8_hasproj" = "false" ] || _t8_err="TEAM_HAS_PROJECTS='$_t8_hasproj', expected 'false'"
_t8_fn="$(sed -n '/^_is_parametric_team() {/,/^}/p' "$INSTALLER")"
if [ -z "$_t8_fn" ]; then
    _t8_err="$_t8_err; _is_parametric_team not found — assertion would be vacuous"
elif ! printf '%s' "$_t8_fn" | grep -q 'TEAM_HAS_PROJECTS'; then
    _t8_err="$_t8_err; _is_parametric_team no longer keys on TEAM_HAS_PROJECTS — re-derive this contract"
fi
# The parametric copy block must remain gated on that predicate. If it ever
# becomes unconditional, dns's shipped-file exclusion stops protecting anything.
if ! grep -q '_PARAMETRIC_MODE" == "true"' "$INSTALLER"; then
    _t8_err="$_t8_err; parametric copy block is no longer gated on _PARAMETRIC_MODE"
fi
if [ -z "$_t8_err" ]; then test_pass; else test_fail "$_t8_err"; fi

# ---------------------------------------------------------------------------
# T9 — CROSS-REPO PREDICATE AGREEMENT. (Review subitem 2.)
# _has_preauthored_connect (tap install-team.sh) and _ships_handauthored_connect
# (dev-team render-cockpit-scripts.sh) are one rule implemented twice, in two
# repos. They read the same physical file, so they cannot disagree about its
# CONTENTS — but the predicate can drift, and it fails in the quiet direction:
# a green "rendered" that clobbers a hand-authored script. Assert both resolve
# the same path shape.
# SKIPPED (not failed) when the dev-team side is absent — this test also runs
# from a consumer tap checkout, where ../scripts/ does not exist. A skip here is
# reported, never silently counted as a pass.
# ---------------------------------------------------------------------------
start_test "T9 both hand-authored predicates key on the same share/scripts/teams/<team>-connect.sh path"
_t9_render="$TAP_ROOT/../scripts/render-cockpit-scripts.sh"
if [ ! -f "$_t9_render" ]; then
    echo "     SKIP: dev-team side not present (consumer checkout) — cross-repo pair not checkable here"
else
    _t9_a="$(sed -n '/^_has_preauthored_connect() {/,/^}/p' "$INSTALLER" \
             | grep -o 'share/scripts/teams/[^"]*connect\.sh' | head -1)"
    _t9_b="$(sed -n '/^_ships_handauthored_connect() {/,/^}/p' "$_t9_render" \
             | grep -o 'share/scripts/teams/[^"]*connect\.sh' | head -1)"
    # Normalise the differing variable spellings for the team id.
    _t9_an="$(printf '%s' "$_t9_a" | sed 's/\${TEAM_ID}/<team>/; s/\$TEAM_ID/<team>/')"
    _t9_bn="$(printf '%s' "$_t9_b" | sed 's/\${_team_id}/<team>/; s/\$_team_id/<team>/')"
    if [ -z "$_t9_an" ] || [ -z "$_t9_bn" ]; then
        test_fail "could not extract a path from both predicates (tap='$_t9_a' devteam='$_t9_b') — assertion would be vacuous"
    elif [ "$_t9_an" = "$_t9_bn" ]; then
        test_pass
    else
        test_fail "predicates disagree: tap resolves '$_t9_an', dev-team resolves '$_t9_bn'"
    fi
fi

# ---------------------------------------------------------------------------
# T10 — every dns agent has a shipped prompt file.
#
# Without one, cc-aliases.sh's launcher falls through to plain `claude` and the
# agent runs with NO PERSONA — generic assistant, no character, no team
# context. It warns loudly (XACA-0785 made sure of that), but a team whose
# seven agents all launch persona-less is not actually provisioned, which is
# the whole point of giving dns a conf. dns was the ONLY one of ten teams
# shipping personas with zero prompts; the other nine all ship both.
#
# Keyed off TEAM_AGENTS so adding an eighth agent without its prompt fails
# here rather than at a user's terminal.
# ---------------------------------------------------------------------------
start_test "T10 every dns TEAM_AGENT has a shipped prompt file"
_t10_dir="$TAP_ROOT/share/personas/dns/prompts"
_t10_missing=""
_t10_agents="$(. "$CONF" >/dev/null 2>&1; printf '%s ' "${TEAM_AGENTS[@]}")"
if [ -z "$_t10_agents" ]; then
    test_fail "TEAM_AGENTS empty — assertion would be vacuous"
elif [ ! -d "$_t10_dir" ]; then
    test_fail "no prompts directory shipped at share/personas/dns/prompts"
else
    for _a in $_t10_agents; do
        [ -f "$_t10_dir/dns-${_a}-prompt.txt" ] || _t10_missing="$_t10_missing $_a"
    done
    if [ -n "$_t10_missing" ]; then
        test_fail "agents with no shipped prompt:$_t10_missing"
    else
        # Non-empty as well as present — a 0-byte prompt is a persona-less agent
        # with none of the loud warnings, which is strictly worse than missing.
        _t10_empty=""
        for _a in $_t10_agents; do
            [ -s "$_t10_dir/dns-${_a}-prompt.txt" ] || _t10_empty="$_t10_empty $_a"
        done
        if [ -n "$_t10_empty" ]; then test_fail "empty prompt file(s):$_t10_empty"; else test_pass; fi
    fi
fi

# ---------------------------------------------------------------------------
# T11 — the shipped connect/disconnect fallback must still resolve to dns's
# canonical LCARS port, 8180.
#
# resolve_lcars_port_fallback computes base + cksum(input) % range, so the input
# STRING and the range decide the port. dns passes ("dns-framework", 8180, 20),
# which does NOT match dns.conf's TEAM_ID or its RANGE=10 — and that mismatch is
# LOAD-BEARING, not a bug. Measured: ("dns-framework",8180,20) -> 8180 (correct);
# ("dns",8180,10) -> 8187 (wrong). A reviewer reasonably flagged the two as
# contradictory sources of truth; "harmonizing" them would silently move dns off
# its canonical port. This test recomputes the arithmetic from whatever the
# shipped scripts actually pass, so the guard cannot rot into a restatement.
# ---------------------------------------------------------------------------
start_test "T11 shipped dns connect/disconnect fallback still resolves to canonical port 8180"
_t11_err=""
for _f in "$TEAMS_SCRIPTS/dns-connect.sh" "$TEAMS_SCRIPTS/dns-disconnect.sh"; do
    [ -f "$_f" ] || { _t11_err="$_t11_err missing:$(basename "$_f")"; continue; }
    _t11_args="$(grep -o 'resolve_lcars_port_fallback "[^"]*" [0-9]* [0-9]*' "$_f" | head -1)"
    if [ -z "$_t11_args" ]; then
        _t11_err="$_t11_err no-fallback-call:$(basename "$_f")"
        continue
    fi
    _t11_in="$(printf '%s' "$_t11_args" | sed -E 's/.*"([^"]*)".*/\1/')"
    _t11_base="$(printf '%s' "$_t11_args" | awk '{print $(NF-1)}')"
    _t11_range="$(printf '%s' "$_t11_args" | awk '{print $NF}')"
    _t11_h="$(printf '%s\n' "$_t11_in" | cksum | cut -d' ' -f1)"
    _t11_port=$(( _t11_base + _t11_h % _t11_range ))
    [ "$_t11_port" = "8180" ] || \
        _t11_err="$_t11_err $(basename "$_f") resolves to $_t11_port (input='$_t11_in' base=$_t11_base range=$_t11_range), expected 8180"
done
if [ -z "$_t11_err" ]; then test_pass; else test_fail "$_t11_err"; fi

# ---------------------------------------------------------------------------
# T12 — dns's shipped prompts must stay byte-identical to their canonical source.
#
# dns's canonical prompts live at dns-framework/scripts/prompts/ while the other
# nine teams use <team-id>/scripts/prompts/. That divergence is real and is the
# same enumeration-blindness class this whole ticket is about: a future mirror
# that globs "<team>/scripts/prompts" would silently SKIP dns, and the tap copies
# would rot with nothing reporting it. Relocating the canonical files was
# considered and rejected here — dns-startup.sh and all 8 station scripts resolve
# paths under dns-framework/, so a move is its own change with its own blast
# radius, not a drive-by.
#
# This assertion is the mitigation that does fit: it converts "silently skipped"
# into "loudly caught". If any future mirror misses dns, or someone edits one
# side only, the copies diverge and this fails. Measured at authoring time: all
# 7 are byte-identical. (For contrast, 5 prompts across ios/finance ARE currently
# drifted between canonical and tap — the exact rot this guards dns against.)
#
# SKIPPED, reported, never silently passed, when the dev-team side is absent.
# ---------------------------------------------------------------------------
start_test "T12 dns shipped prompts are byte-identical to canonical dns-framework/scripts/prompts"
_t12_canon="$TAP_ROOT/../dns-framework/scripts/prompts"
if [ ! -d "$_t12_canon" ]; then
    echo "     SKIP: dev-team side not present (consumer checkout) — canonical prompts not checkable here"
else
    _t12_err=""
    _t12_n=0
    for _f in "$TAP_ROOT/share/personas/dns/prompts/"*.txt; do
        [ -e "$_f" ] || continue
        _t12_n=$((_t12_n + 1))
        _t12_b="$(basename "$_f")"
        if [ ! -f "$_t12_canon/$_t12_b" ]; then
            _t12_err="$_t12_err no-canonical:$_t12_b"
        elif ! cmp -s "$_t12_canon/$_t12_b" "$_f"; then
            _t12_err="$_t12_err DRIFTED:$_t12_b"
        fi
    done
    if [ "$_t12_n" -eq 0 ]; then
        test_fail "no shipped prompts found — assertion would be vacuous"
    elif [ -n "$_t12_err" ]; then
        test_fail "$_t12_err"
    else
        test_pass
    fi
fi

# ---------------------------------------------------------------------------
echo
echo "RESULT: $_PASS_COUNT passed, $_FAIL_COUNT failed"
[ "$_FAIL_COUNT" -eq 0 ] || exit 1
exit 0
