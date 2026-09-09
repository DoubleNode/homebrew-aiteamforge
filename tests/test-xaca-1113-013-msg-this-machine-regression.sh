#!/bin/bash
# test-xaca-1113-013-msg-this-machine-regression.sh
#
# XACA-1113-013: regression test for the "23rd defect" this ticket's port
# (tap commit edfbef8) closes as a SIDE EFFECT, with no test of its own --
# and a defect closed as a side effect, untested, is a defect that comes
# back the next time someone prunes the template.
#
# THE DEFECT (pre-port state of share/templates/kanban/kanban-helpers.
# template.sh): _kb_register_team_impl CALLED _kb_msg_this_machine (one
# call site) while the template DEFINED it zero times:
#
#     if slug=$(_kb_msg_this_machine 2>/dev/null) && [[ -n "$slug" ]]; then
#
# Under a consumer's shell the undefined function returns 127 ("command not
# found"), and `2>/dev/null` swallows that stderr entirely. The `if`
# therefore evaluates false and the whole XACA-1089 machine-identity block
# silently no-ops on EVERY consumer -- while _kb_register_team_impl still
# writes its status file and team registration still reports success, so
# nothing anywhere surfaces the gap. This is this ticket's recurring
# signature: the check that never runs is indistinguishable from the check
# that passes.
#
# The port now DEFINES _kb_msg_this_machine (share/templates/kanban/
# kanban-helpers.template.sh, "this box's vault machine slug, from the
# AUTHORITY"). This suite is the missing regression coverage.
#
# Coverage, and why each half is necessary (per this ticket's requirements):
#
#   1. STRUCTURAL: _kb_msg_this_machine is DEFINED exactly once in the
#      rendered template, AND the one real call site inside
#      _kb_register_team_impl's own function body still exists (isolated by
#      function-body extraction, not a file-wide grep). Neither alone is
#      sufficient: "defined" alone would still pass if the call site were
#      later deleted (function present, never invoked); "called" alone is
#      exactly the pre-fix state this suite exists to catch.
#
#   2. BEHAVIORAL, positive fixture: under a sandbox where a machine slug
#      IS resolvable (a stub vault-keygen.js dropped on AITEAMFORGE_DIR's
#      lookup path, real node, and a stub `curl` on PATH answering the vault
#      registry / team-register / registered-teams endpoints), the rendered
#      template is sourced and _kb_register_team_impl invoked directly. The
#      OUTGOING POST payload to .../api/team-register (captured via the
#      curl stub) must carry `"machineSlug":"<the resolved slug>"` -- proof
#      the block did not merely get entered, but changed the function's
#      real output. This is what a call-site grep, by itself, cannot prove:
#      a regression where the `if` condition silently evaluates false again
#      (this ticket's exact defect shape) leaves both static facts in (1)
#      true while this assertion goes red.
#      SKIPS (not fails) when node is not on PATH -- matches
#      test-msg-client-install.sh's convention; the plain-shell CI job
#      installs only jq/bash/tmux, not node.
#
#   3. BEHAVIORAL, negative fixture: under a sandbox where NO vault-keygen.js
#      exists anywhere on the lookup chain (slug genuinely unresolvable),
#      the same call must NOT carry machineSlug, AND team registration must
#      still report a real, non-aborted outcome -- the documented fallback
#      contract ("NEVER let anything in this block fail or delay team
#      registration") holds. No node dependency (the loop over candidate
#      vault-keygen.js paths finds none and returns before ever invoking
#      node).
#
#   4. DEFECT REPRODUCTION, in-process: _kb_msg_this_machine is `unfunction`-ed
#      (zsh builtin) immediately after sourcing the rendered template --
#      the exact pre-port state, reproduced live rather than by editing a
#      copy of the file. The call site's `$(_kb_msg_this_machine 2>/dev/null)`
#      then genuinely resolves via PATH lookup, fails with 127, and that
#      127 is swallowed by `2>/dev/null` -- byte-for-byte the mechanism
#      described above. Asserts the same two properties as Coverage 3
#      (no machineSlug in the payload; registration still completes) via
#      the precise defect mechanism instead of a proxy for it.
#
# NEGATIVE CONTROL (mandatory per this ticket, performed manually against
# this suite before it was finalized -- not re-run by CI, which would be
# redundant with Coverage 4's live reproduction of the same mechanism):
# Coverage 2's own assertion (expects machineSlug PRESENT in the payload)
# was run against the Coverage-4-style "function unfunction'd" fixture
# instead of its own positive fixture. It failed exactly as expected --
# proof this suite's core assertion is sensitive to the defect it exists to
# catch, not vacuously green. See the session report for the exact
# transcript.
#
# Sandboxed per house convention (test-xaca-0819 / test-xaca-0862-022):
# AITEAMFORGE_DIR and HOME are both redirected under TEST_TMP_DIR for every
# invocation -- _kb_register_team_impl unconditionally writes
# $HOME/.aiteamforge/run/kb-team-register-status-<team>, so HOME must never
# be the real one. All network is stubbed via a `curl` shim placed first on
# PATH -- nothing in this suite makes a real HTTP call, and nothing in this
# suite installs, taps, or brew-installs AITeamForge itself (repo-wide rule
# -- this machine is dev-team's sole source of truth).
#
# The template is a zsh script (#!/usr/bin/env zsh); every function
# invocation below runs under `zsh -c "source <rendered>; ..."`. Validate
# THIS file (a bash test) with `bash -n` / run under bash; validate the
# TEMPLATE separately with `zsh -n`, never `bash -n` (the template carries a
# pre-existing zsh-only glob qualifier bash cannot parse -- not a
# regression, not this suite's concern).
#
# Runs standalone (`bash tests/test-xaca-1113-013-msg-this-machine-
# regression.sh`) OR via tests/test-runner.sh. Exit 0 = all assertions
# pass, exit 1 = any fail. Requires: bash, zsh, jq. node is a SOFT
# prerequisite (Coverage 2 only; see above).

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_PATH="${X1113_013_TEST_TEMPLATE_PATH:-$TAP_ROOT/share/templates/kanban/kanban-helpers.template.sh}"

if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "FATAL: kanban-helpers.template.sh not found at: $TEMPLATE_PATH" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Hard prerequisites.
# ─────────────────────────────────────────────────────────────────────────────
for _tool in zsh jq; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "FATAL: required tool '$_tool' not on PATH — cannot run this suite." >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Standalone framework (mirrors test-xaca-0819's pattern): provide
# test_start/test_pass/test_fail when test-runner.sh has NOT exported them.
# ─────────────────────────────────────────────────────────────────────────────
_STANDALONE=false
if ! type -t test_start >/dev/null 2>&1; then
    _STANDALONE=true
    _CURRENT_TEST=""
    test_start() { _CURRENT_TEST="$1"; echo "  >> $1"; }
    test_pass()  { echo "     PASS: $_CURRENT_TEST"; }
    test_fail()  { echo "     FAIL: $_CURRENT_TEST — $1" >&2; }
fi

# ─────────────────────────────────────────────────────────────────────────────
# EXPLICIT pass/fail counters — independent of the outer harness
# (feedback_tap_test_harness_vacuous_green: tap assert_* helpers record only
# on FAILURE, so a suite that runs 0 real assertions prints "All tests
# passed" vacuously). Every assertion below goes through ok(), which
# increments one of these on every call, and the suite prints an explicit
# "Passed: N / Total: M" and exits non-zero on any failure OR on zero
# assertions run.
# ─────────────────────────────────────────────────────────────────────────────
_X013_PASS=0
_X013_FAIL=0
_X013_SKIP=0

ok() {
    local label="$1" cond="$2" detail="${3:-}"
    test_start "$label"
    if [ "$cond" = "1" ]; then
        _X013_PASS=$((_X013_PASS + 1)); test_pass
    else
        _X013_FAIL=$((_X013_FAIL + 1)); test_fail "$detail"
    fi
}

skip() {
    local label="$1" reason="$2"
    _X013_SKIP=$((_X013_SKIP + 1))
    echo "  >> $label"
    echo "     SKIP: $reason"
}

# ─────────────────────────────────────────────────────────────────────────────
# Temp directory.
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "${TEST_TMP_DIR:-}" ] || [ ! -d "${TEST_TMP_DIR:-}" ]; then
    TEST_TMP_DIR="$(mktemp -d -t xaca1113013-msg-this-machine-test.XXXXXX)"
    _OWN_TMP=true
else
    _OWN_TMP=false
fi
TEST_TMP_DIR="$(cd "$TEST_TMP_DIR" && pwd -P)"
WORK_DIR="$TEST_TMP_DIR/xaca1113013"
mkdir -p "$WORK_DIR/aiteamforge" "$WORK_DIR/fakehome" "$WORK_DIR/curl-stub" "$WORK_DIR/fixtures"

cleanup() {
    if [ "${_OWN_TMP:-false}" = true ] && [ -n "${TEST_TMP_DIR:-}" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup EXIT

TEAM_ID="xtst1113013$$"
SLUG="test-machine-slug-1113-013-$$"

# ─────────────────────────────────────────────────────────────────────────────
# Render the template into the sandbox (no {{placeholder}} may survive).
# ─────────────────────────────────────────────────────────────────────────────
AITEAMFORGE_DIR_SANDBOX="$WORK_DIR/aiteamforge"
RENDERED="$WORK_DIR/kanban-helpers-rendered.sh"
sed "s|{{AITEAMFORGE_DIR}}|$AITEAMFORGE_DIR_SANDBOX|g; \
     s|{{SHARED_DEV_ROOT}}|$WORK_DIR/shared|g; \
     s|{{ORG_NAME}}|TestOrg|g; \
     s|{{ORG_SLUG}}|testorg|g" \
    "$TEMPLATE_PATH" > "$RENDERED"

_LEFT=$(grep -c '{{' "$RENDERED" 2>/dev/null)
[ -n "$_LEFT" ] || _LEFT=0
ok "render: no {{placeholder}} survives in the rendered template" \
   "$([ "$_LEFT" -eq 0 ] && echo 1 || echo 0)" \
   "found $_LEFT residual '{{' placeholder(s): $(grep -oE '\{\{[A-Z_]+\}\}' "$RENDERED" | sort -u | tr '\n' ' ')"

# ─────────────────────────────────────────────────────────────────────────────
# Grounding: the two symbols this suite depends on for its function-body
# extractions must still exist, verbatim, or the awk ranges below go
# silently empty and every downstream assertion would pass vacuously.
# ─────────────────────────────────────────────────────────────────────────────
_HAS_DEF_HEADER=$(grep -c '^_kb_msg_this_machine() {' "$RENDERED" 2>/dev/null)
[ -n "$_HAS_DEF_HEADER" ] || _HAS_DEF_HEADER=0
_HAS_IMPL_HEADER=$(grep -c '^_kb_register_team_impl() {' "$RENDERED" 2>/dev/null)
[ -n "$_HAS_IMPL_HEADER" ] || _HAS_IMPL_HEADER=0
ok "grounding: both _kb_msg_this_machine() {  and  _kb_register_team_impl() {  headers exist verbatim" \
   "$([ "$_HAS_DEF_HEADER" -ge 1 ] && [ "$_HAS_IMPL_HEADER" -ge 1 ] && echo 1 || echo 0)" \
   "expected both headers present; found _kb_msg_this_machine()={${_HAS_DEF_HEADER}} _kb_register_team_impl()={${_HAS_IMPL_HEADER}} — if this fails, every awk-range assertion below is extracting an empty range and cannot be trusted"

# ─────────────────────────────────────────────────────────────────────────────
# Coverage 1: STRUCTURAL — defined exactly once, called exactly once, and
# the call site is INSIDE _kb_register_team_impl's own body (not merely
# somewhere in the file).
# ─────────────────────────────────────────────────────────────────────────────
_DEF_COUNT=$(grep -c '^_kb_msg_this_machine() {' "$RENDERED" 2>/dev/null)
[ -n "$_DEF_COUNT" ] || _DEF_COUNT=0
ok "1a: exactly 1 _kb_msg_this_machine() definition in the rendered template (the defect: this was 0)" \
   "$([ "$_DEF_COUNT" -eq 1 ] && echo 1 || echo 0)" \
   "expected 1 definition, found $_DEF_COUNT"

IMPL_BODY="$WORK_DIR/register-team-impl-body.txt"
awk '
  /^_kb_register_team_impl\(\) \{/ { flag=1; print; next }
  flag && /^\}$/ { print; flag=0; next }
  flag { print }
' "$RENDERED" > "$IMPL_BODY"
_IMPL_LINES=$(wc -l < "$IMPL_BODY" | tr -d '[:space:]')
_CALL_IN_IMPL=$(grep -c '_kb_msg_this_machine 2>/dev/null' "$IMPL_BODY" 2>/dev/null)
[ -n "$_CALL_IN_IMPL" ] || _CALL_IN_IMPL=0
ok "1b: exactly 1 call-shaped '_kb_msg_this_machine 2>/dev/null' site inside _kb_register_team_impl's own body (body=${_IMPL_LINES} lines)" \
   "$([ -n "$_IMPL_LINES" ] && [ "$_IMPL_LINES" -gt 20 ] && [ "$_CALL_IN_IMPL" -eq 1 ] && echo 1 || echo 0)" \
   "expected _kb_register_team_impl body >20 lines with exactly 1 call site; got ${_IMPL_LINES} lines / ${_CALL_IN_IMPL} calls — a grep for 'defined' alone (1a) would still pass if this call site were deleted"

# ─────────────────────────────────────────────────────────────────────────────
# Shared curl stub: answers the three endpoints _kb_register_team_impl's
# call chain hits, and logs every invocation (one block per call, fields
# joined by \x1f) so assertions below can inspect exactly what was sent.
# ─────────────────────────────────────────────────────────────────────────────
CURL_LOG="$WORK_DIR/curl.log"
: > "$CURL_LOG"
cat > "$WORK_DIR/fixtures/vault-machines.json" <<JSON
{"machines":[{"id":"${SLUG}"}]}
JSON
cat > "$WORK_DIR/fixtures/team-register-response.json" <<JSON
{"machines":{}}
JSON
cat > "$WORK_DIR/fixtures/registered-teams.json" <<JSON
{"teams":[{"team":"${TEAM_ID}","machines":{"${SLUG}":{}}}]}
JSON

cat > "$WORK_DIR/curl-stub/curl" <<'STUB'
#!/bin/bash
# Test double for curl — routes on the LAST positional argument (the URL, in
# every call this suite's target code makes) and logs every invocation for
# later inspection. Never touches the network.
LOGFILE="${CURL_STUB_LOG:?CURL_STUB_LOG not set}"
FIXTURES="${CURL_STUB_FIXTURES:?CURL_STUB_FIXTURES not set}"
{
    echo "=== CALL ==="
    for a in "$@"; do printf '%s\x1f' "$a"; done
    echo
} >> "$LOGFILE"

last="${*: -1}"
case "$last" in
    */api/vault/machines)     cat "$FIXTURES/vault-machines.json" ;;
    */api/team-register)      cat "$FIXTURES/team-register-response.json" ;;
    */api/registered-teams)   cat "$FIXTURES/registered-teams.json" ;;
    *) ;;  # unrecognized endpoint — real curl -s would still exit 0; stay silent
esac
exit 0
STUB
chmod +x "$WORK_DIR/curl-stub/curl"

# Isolate the LAST complete log block whose args match $1 (a grep-style
# pattern, e.g. a URL suffix). Each block runs from one "=== CALL ===" marker
# to the next; a block is only considered once it is COMPLETE (the next
# marker, or EOF, has been seen) so a partially-accumulated block can never
# be returned.
_curl_block_for() {
    local pattern="$1"
    awk -v pat="$pattern" '
      BEGIN { block = ""; have = 0; last = "" }
      /^=== CALL ===$/ {
          if (have && block ~ pat) { last = block }
          block = ""; have = 1; next
      }
      { block = block $0 "\n" }
      END {
          if (have && block ~ pat) { last = block }
          print last
      }
    ' "$CURL_LOG"
}

# ─────────────────────────────────────────────────────────────────────────────
# Coverage 2: BEHAVIORAL, positive fixture — slug IS resolvable.
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
    skip "2: positive fixture — machineSlug reaches the outgoing team-register payload" \
         "node not on PATH (plain-shell CI job installs jq/bash/tmux only, not node — matches test-msg-client-install.sh's convention)"
else
    mkdir -p "$AITEAMFORGE_DIR_SANDBOX/fleet-monitor/client"
    cat > "$AITEAMFORGE_DIR_SANDBOX/fleet-monitor/client/vault-keygen.js" <<JS
module.exports = { defaultMachineSlug: function () { return "${SLUG}"; } };
JS

    : > "$CURL_LOG"
    OUT_POS="$WORK_DIR/coverage2.out"
    PATH="$WORK_DIR/curl-stub:$PATH" \
    AITEAMFORGE_DIR="$AITEAMFORGE_DIR_SANDBOX" \
    HOME="$WORK_DIR/fakehome" \
    CURL_STUB_LOG="$CURL_LOG" \
    CURL_STUB_FIXTURES="$WORK_DIR/fixtures" \
        zsh -c "source '$RENDERED' >/dev/null 2>&1; _kb_register_team_impl '{\"team\":\"${TEAM_ID}\"}' 'http://127.0.0.1:9' '${TEAM_ID}' 1" \
        > "$OUT_POS" 2>&1

    REGISTER_BLOCK=$(_curl_block_for '/api/team-register')
    ok "2a: positive fixture — outgoing team-register payload carries machineSlug:\"${SLUG}\"" \
       "$(printf '%s' "$REGISTER_BLOCK" | grep -qF "\"machineSlug\":\"${SLUG}\"" && echo 1 || echo 0)" \
       "team-register call block did not contain machineSlug:\"${SLUG}\": $(printf '%s' "$REGISTER_BLOCK" | tr '\n' ' ')"

    ok "2b: positive fixture — reported outcome is 'registered' (proves the block ran end to end, not just entered)" \
       "$(grep -qF -- "-- registered" "$OUT_POS" && echo 1 || echo 0)" \
       "expected \"-- registered\" in output; got: $(cat "$OUT_POS")"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Coverage 3: BEHAVIORAL, negative fixture — slug is NOT resolvable (no
# vault-keygen.js anywhere on the lookup chain). No node dependency: the
# loop in _kb_msg_this_machine exhausts all three candidate paths and
# returns 1 before ever invoking node.
# ─────────────────────────────────────────────────────────────────────────────
AITEAMFORGE_DIR_NOVK="$WORK_DIR/aiteamforge-novk"
mkdir -p "$AITEAMFORGE_DIR_NOVK"
: > "$CURL_LOG"
OUT_NEG="$WORK_DIR/coverage3.out"
PATH="$WORK_DIR/curl-stub:$PATH" \
AITEAMFORGE_DIR="$AITEAMFORGE_DIR_NOVK" \
HOME="$WORK_DIR/fakehome-novk" \
CURL_STUB_LOG="$CURL_LOG" \
CURL_STUB_FIXTURES="$WORK_DIR/fixtures" \
    zsh -c "source '$RENDERED' >/dev/null 2>&1; _kb_register_team_impl '{\"team\":\"${TEAM_ID}\"}' 'http://127.0.0.1:9' '${TEAM_ID}' 1" \
    > "$OUT_NEG" 2>&1

REGISTER_BLOCK_NEG=$(_curl_block_for '/api/team-register')
ok "3a: negative fixture (no vault-keygen.js) — outgoing payload does NOT carry machineSlug" \
   "$(printf '%s' "$REGISTER_BLOCK_NEG" | grep -qF '"machineSlug"' && echo 0 || echo 1)" \
   "expected no machineSlug field; team-register call block: $(printf '%s' "$REGISTER_BLOCK_NEG" | tr '\n' ' ')"

ok "3b: negative fixture — team registration STILL reports a real outcome (fallback contract holds, nothing aborted)" \
   "$(grep -qE -- '-- (registered|not_stored|server_not_deployed|no_identity_sent|unreachable)' "$OUT_NEG" && echo 1 || echo 0)" \
   "expected a real 'kb-register: team ... -- <outcome>' line; got: $(cat "$OUT_NEG")"

# ─────────────────────────────────────────────────────────────────────────────
# Coverage 4: DEFECT REPRODUCTION, in-process. _kb_msg_this_machine is
# unfunction'd immediately after sourcing — the exact pre-port shape: the
# call site's `$(_kb_msg_this_machine 2>/dev/null)` resolves via PATH
# lookup, fails 127, and 2>/dev/null swallows it. No throwaway copy of the
# template is needed; this reproduces the real mechanism live.
# ─────────────────────────────────────────────────────────────────────────────
: > "$CURL_LOG"
OUT_UNDEF="$WORK_DIR/coverage4.out"
PATH="$WORK_DIR/curl-stub:$PATH" \
AITEAMFORGE_DIR="$AITEAMFORGE_DIR_SANDBOX" \
HOME="$WORK_DIR/fakehome-undef" \
CURL_STUB_LOG="$CURL_LOG" \
CURL_STUB_FIXTURES="$WORK_DIR/fixtures" \
    zsh -c "source '$RENDERED' >/dev/null 2>&1; unfunction _kb_msg_this_machine 2>/dev/null; _kb_register_team_impl '{\"team\":\"${TEAM_ID}\"}' 'http://127.0.0.1:9' '${TEAM_ID}' 1" \
    > "$OUT_UNDEF" 2>&1

REGISTER_BLOCK_UNDEF=$(_curl_block_for '/api/team-register')
ok "4a [DEFECT REPRODUCTION]: with _kb_msg_this_machine undefined, outgoing payload does NOT carry machineSlug" \
   "$(printf '%s' "$REGISTER_BLOCK_UNDEF" | grep -qF '"machineSlug"' && echo 0 || echo 1)" \
   "expected no machineSlug field with the function undefined; team-register call block: $(printf '%s' "$REGISTER_BLOCK_UNDEF" | tr '\n' ' ')"

ok "4b [DEFECT REPRODUCTION]: with _kb_msg_this_machine undefined, team registration STILL reports a real outcome (the pre-port silent-no-op-but-reports-success behavior, confirmed still true post-port when the function is absent)" \
   "$(grep -qE -- '-- (registered|not_stored|server_not_deployed|no_identity_sent|unreachable)' "$OUT_UNDEF" && echo 1 || echo 0)" \
   "expected a real 'kb-register: team ... -- <outcome>' line; got: $(cat "$OUT_UNDEF")"

# ─────────────────────────────────────────────────────────────────────────────
# Summary — explicit pass/fail/skip count, never vacuous.
# ─────────────────────────────────────────────────────────────────────────────
_X013_TOTAL=$((_X013_PASS + _X013_FAIL))
echo
echo "XACA-1113-013: Passed: ${_X013_PASS} / Failed: ${_X013_FAIL} / Skipped: ${_X013_SKIP} / Total assertions: ${_X013_TOTAL}"

if [ "$_X013_TOTAL" -eq 0 ]; then
    echo "FATAL: zero assertions executed — this would be a vacuous pass." >&2
    exit 1
fi

if [ "$_X013_FAIL" -gt 0 ]; then
    exit 1
fi

exit 0
