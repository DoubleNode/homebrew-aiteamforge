#!/bin/bash

# test-xaca-1625-extensionless-upgrade-coverage.sh
# Guard (XACA-1625): EVERY extensionless top-level file in share/scripts/ must have
# an upgrade path, or a named exemption with a reason.
#
# REGRESSION INTENT: update_runtime_helpers' sweep is `for src in *.sh *.py <names...>`,
# so an extensionless script reaches an UPGRADED consumer only if it is listed by
# name. A brand-new one must ALSO be in _xaca0673_mandatory_materialize_basenames,
# because the sweep only refreshes files that already exist. Fresh installs are
# fine (setup bulk-copies share/scripts/), which is why this gap stays invisible
# until someone upgrades. It shipped four times: kb-pr-monitor (XACA-1275),
# kb-token-report (XACA-1300), kb-wiki and five peers (XACA-1460), kb-where
# (XACA-1607). The XACA-0673 PARITY test cannot catch it: it only checks names
# that ANOTHER shipped script references, and a standalone command is referenced
# by nothing.
#
# A file is covered when it is in:
#   (a) the mandatory-materialize list AND the sweep loop, or
#   (b) _xaca0608_aux_script_map (its own materialise + refresh path), or
#   (c) EXEMPT below, with a reason.
#
# Assertions:
#   1. Every extensionless top-level share/scripts file is covered (real tap).
#   2. Fail-closed: an unparseable/empty list is a FAIL, never a vacuous pass.
#   3. An uncovered new file is named in the failure.
#   4. Dropping a name from the sweep (mandatory-only) is a FAIL.
#   5. A stale exemption (now covered, or file gone) is a FAIL.
#
# Read-only on the tap; fixtures live in TEST_TMP_DIR. Never touches $HOME.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE_SH="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"
SCRIPTS_DIR="$TAP_ROOT/share/scripts"

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (works sourced by test-runner.sh OR invoked directly).
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _PASS_COUNT=0
    _FAIL_COUNT=0
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { _PASS_COUNT=$((_PASS_COUNT + 1)); echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

_OWN_TMP=false
if [ -z "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/xaca1625.XXXXXX")"
    _OWN_TMP=true
fi
# shellcheck disable=SC2329  # invoked by the EXIT trap
_cleanup() { if [ "$_OWN_TMP" = true ]; then rm -r -f -- "$TEST_TMP_DIR"; fi; }
trap _cleanup EXIT

# Named exemptions: "<name>|<reason>". A stale entry (file gone, or now covered) FAILS.
EXEMPT='kb-tap-release|dev-only: needs an outer dev-team checkout + kb-tap-lock.sh (see the comment above _xaca0673_mandatory_materialize_basenames)'

# check <upgrade.sh> <scripts dir>  -> exit 0 covered, 1 uncovered/stale, 2 parse failure
check() {
    EXEMPT="$EXEMPT" python3 -I - "$1" "$2" <<'PY'
import os, re, sys

upgrade, scripts = sys.argv[1], sys.argv[2]
src = open(upgrade).read()

m = re.search(r"^_xaca0673_mandatory_materialize_basenames\(\) \{\n  cat <<'EOF'\n(.*?)\nEOF\n", src, re.S | re.M)
mand = set(m.group(1).split()) if m else set()
loops = re.findall(r'^\s*for src in ("\$scripts_source"/\*\.sh[^\n]*); do$', src, re.M)
sweep = set(re.findall(r'"\$scripts_source"/([A-Za-z0-9_.-]+)', loops[0])) if len(loops) == 1 else set()
a = re.search(r"^_xaca0608_aux_script_map\(\) \{\n(.*?)\n\}", src, re.S | re.M)
aux = set(re.findall(r"\b((?:kb|aiteamforge)-[a-z0-9-]+)\b", a.group(1))) if a else set()

problems = []
if len(mand) < 10:
    problems.append("mandatory list parsed to %d name(s) (< 10 floor)" % len(mand))
if len(loops) != 1:
    problems.append("expected exactly 1 update_runtime_helpers sweep loop, found %d" % len(loops))
elif len(sweep) < 5:
    problems.append("sweep loop parsed to %d explicit name(s) (< 5 floor)" % len(sweep))
if not aux:
    problems.append("_xaca0608_aux_script_map parsed to 0 names")
if problems:
    for p in problems:
        print("     PARSE-FAIL (fail-closed): " + p, file=sys.stderr)
    sys.exit(2)

exempt = {}
for line in os.environ.get("EXEMPT", "").splitlines():
    if "|" in line:
        name, reason = line.split("|", 1)
        exempt[name.strip()] = reason.strip()

names = sorted(n for n in os.listdir(scripts) if "." not in n and os.path.isfile(os.path.join(scripts, n)))
bad = False
counts = {"mandatory+sweep": 0, "aux map": 0, "exempt": 0}
for n in names:
    if n in mand and n in sweep:
        counts["mandatory+sweep"] += 1
    elif n in aux:
        counts["aux map"] += 1
    elif n in exempt:
        counts["exempt"] += 1
    else:
        bad = True
        where = "mandatory only" if n in mand else "sweep only" if n in sweep else "no list"
        print("     UNCOVERED: share/scripts/%s (%s) - add it to BOTH _xaca0673_mandatory_materialize_basenames "
              "and the update_runtime_helpers sweep loop, or to EXEMPT with a reason" % (n, where), file=sys.stderr)
for n in exempt:
    if n not in names:
        bad = True
        print("     STALE-EXEMPTION: '%s' no longer exists in share/scripts" % n, file=sys.stderr)
    elif (n in mand and n in sweep) or n in aux:
        bad = True
        print("     STALE-EXEMPTION: '%s' now has an upgrade path - remove it from EXEMPT" % n, file=sys.stderr)
print("     %d extensionless file(s): %s" % (len(names), ", ".join("%s %d" % kv for kv in counts.items())))
sys.exit(1 if bad else 0)
PY
}

# fixture <name>: copies of upgrade.sh + share/scripts (names only) to mutate
fixture() {
    local d="$TEST_TMP_DIR/$1"
    mkdir -p "$d/scripts"
    cp "$UPGRADE_SH" "$d/upgrade.sh"
    for f in "$SCRIPTS_DIR"/*; do
        [ -f "$f" ] && : > "$d/scripts/$(basename "$f")"
    done
    echo "$d"
}

# ═══════════════════════════════════════════════════════════════════════════
# TEST 1: the real tap is fully covered
# ═══════════════════════════════════════════════════════════════════════════
test_start "every extensionless share/scripts file has an upgrade path (real tap)"
_out="$(check "$UPGRADE_SH" "$SCRIPTS_DIR" 2>&1)"; _rc=$?
echo "$_out"
if [ "$_rc" -eq 0 ]; then test_pass; else test_fail "rc=$_rc (see UNCOVERED / PARSE-FAIL lines above)"; fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 2: fail-closed when a list cannot be parsed
# ═══════════════════════════════════════════════════════════════════════════
test_start "an unparseable mandatory list is a FAIL (exit 2), never a vacuous pass"
_d="$(fixture failclosed)"
perl -pi -e 's/^_xaca0673_mandatory_materialize_basenames\(\) \{/_renamed_list() {/' "$_d/upgrade.sh"
check "$_d/upgrade.sh" "$_d/scripts" >/dev/null 2>&1; _rc=$?
if [ "$_rc" -eq 2 ]; then test_pass; else test_fail "expected exit 2, got $_rc"; fi

test_start "an empty aux map is a FAIL (exit 2)"
_d="$(fixture noaux)"
perl -pi -e 's/^_xaca0608_aux_script_map\(\) \{/_renamed_aux() {/' "$_d/upgrade.sh"
check "$_d/upgrade.sh" "$_d/scripts" >/dev/null 2>&1; _rc=$?
if [ "$_rc" -eq 2 ]; then test_pass; else test_fail "expected exit 2, got $_rc"; fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 3: a brand-new uncovered extensionless file is named
# ═══════════════════════════════════════════════════════════════════════════
test_start "a new uncovered extensionless file FAILS and is named"
_d="$(fixture newfile)"
: > "$_d/scripts/kb-zz-brand-new"
_out="$(check "$_d/upgrade.sh" "$_d/scripts" 2>&1)"; _rc=$?
if [ "$_rc" -eq 1 ] && [[ "$_out" == *"UNCOVERED: share/scripts/kb-zz-brand-new (no list)"* ]]; then
    test_pass
else
    test_fail "expected exit 1 naming kb-zz-brand-new, got rc=$_rc"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 4: mandatory-only (dropped from the sweep) is not enough
# ═══════════════════════════════════════════════════════════════════════════
test_start "a name dropped from the sweep loop FAILS (mandatory-only)"
_d="$(fixture sweepdrop)"
perl -pi -e 's| "\$scripts_source"/kb-where||' "$_d/upgrade.sh"
_out="$(check "$_d/upgrade.sh" "$_d/scripts" 2>&1)"; _rc=$?
if [ "$_rc" -eq 1 ] && [[ "$_out" == *"UNCOVERED: share/scripts/kb-where (mandatory only)"* ]]; then
    test_pass
else
    test_fail "expected exit 1 naming kb-where (mandatory only), got rc=$_rc"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 5: stale exemptions
# ═══════════════════════════════════════════════════════════════════════════
test_start "an exemption whose file is gone FAILS"
_d="$(fixture exemptgone)"
rm -f -- "$_d/scripts/kb-tap-release"
_out="$(check "$_d/upgrade.sh" "$_d/scripts" 2>&1)"; _rc=$?
if [ "$_rc" -eq 1 ] && [[ "$_out" == *"STALE-EXEMPTION: 'kb-tap-release' no longer exists"* ]]; then
    test_pass
else
    test_fail "expected exit 1 with a stale-exemption line, got rc=$_rc"
fi

test_start "an exemption that is now covered FAILS"
_d="$(fixture exemptcovered)"
perl -pi -e 's|^kb-wiki$|kb-wiki\nkb-tap-release|; s|"\$scripts_source"/kb-wiki |"\$scripts_source"/kb-wiki "\$scripts_source"/kb-tap-release |' "$_d/upgrade.sh"
_out="$(check "$_d/upgrade.sh" "$_d/scripts" 2>&1)"; _rc=$?
if [ "$_rc" -eq 1 ] && [[ "$_out" == *"STALE-EXEMPTION: 'kb-tap-release' now has an upgrade path"* ]]; then
    test_pass
else
    test_fail "expected exit 1 with a now-covered line, got rc=$_rc"
fi

if [ "$_STANDALONE" = true ]; then
    echo ""
    echo "Results: ${_PASS_COUNT} passed, ${_FAIL_COUNT} failed"
    [ "$_FAIL_COUNT" -gt 0 ] && exit 1
fi
exit 0
