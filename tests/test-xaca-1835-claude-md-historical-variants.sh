#!/bin/bash
# test-xaca-1835-claude-md-historical-variants.sh
#
# XACA-1835: table-driven guard for the historical-render corpus that
# _xaca1159_bootstrap_claude_md_provenance (libexec/installers/
# install-claude-config.sh) uses to recognise a receipt-less ~/.claude/CLAUDE.md
# as "pristine, just stale" rather than "customized".
#
# Why this exists: the installer's comment says "before changing the template,
# register the OUTGOING render here, or you strand every receipt-less box
# currently sitting on it". That rule lived only in a comment and was missed
# four times after 75b6f33 (cd5aafc, ab2af77, 89fddb2, 6c3e4ce all shipped in
# tagged releases unregistered). A stranded box fails provenance, is treated as
# customized (refresh rc 3), and never receives any later template.
#
# Checks:
#   A1  every row of _xaca1159_claude_md_historical_variants names a file that
#       exists under share/templates/claude/historical/
#   A2  every historical/*.template file is listed (no orphan the bootstrap
#       silently ignores)
#   A3  each row's placeholder token is one apply_template history actually
#       used (DEV_TEAM_DIR / AITEAMFORGE_DIR) and appears in that file
#   C   for EACH row: a receipt-less fixture rendered from that variant makes
#       the REAL bootstrap function return 0. Run against a sandbox
#       TEMPLATE_DIR whose CURRENT template is a dummy, so every row is proven
#       on its own and never through the "try the current template first"
#       shortcut.
#   C+  the real current template's render also bootstraps (rc 0)
#   N1  negative control: a variant fixture with one byte appended -> rc 1
#   N2  mutation sentinel: with the newest row removed from the list, that
#       row's own fixture -> rc 1 (rows are load-bearing, not decorative)
#   B   (only when this checkout has full history and tags) every template
#       blob that shipped at a release tag is either the current template or
#       byte-identical to a registered historical file. CI checks out depth 1,
#       so this usually prints a NOTE instead; the pre-merge enforcement of
#       the same rule is dev-team's
#       tests/test-xaca-1835-claude-md-outgoing-render-registered.sh.
#
# The corpus is mirrored by the tap publisher from dev-team's canonical
# scripts/templates/tap/claude-md-historical/; dev-team CI overlays that
# directory onto this checkout before running this suite, so a PR is tested
# against the corpus it will ship.
#
# Sandboxed: HOME/AITEAMFORGE_DIR/CLAUDE_CONFIG_DIR/TEMPLATE_DIR all point
# under a mktemp dir. Exit 0 = all pass; exit 1 = any fail or zero assertions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$TAP_ROOT/libexec/installers/install-claude-config.sh"
REAL_TEMPLATE_DIR="$TAP_ROOT/share/templates"
HIST_DIR="$REAL_TEMPLATE_DIR/claude/historical"
CUR_TEMPLATE="$REAL_TEMPLATE_DIR/claude/claude-md-global.template"

for _need in "$INSTALLER" "$CUR_TEMPLATE"; do
    [ -f "$_need" ] || { echo "FATAL: required file not found: $_need" >&2; exit 1; }
done
[ -d "$HIST_DIR" ] || { echo "FATAL: historical dir not found: $HIST_DIR" >&2; exit 1; }

_PASS=0; _FAIL=0
ok()  { _PASS=$((_PASS + 1)); echo "  PASS: $1"; }
bad() { _FAIL=$((_FAIL + 1)); echo "  FAIL: $1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/xaca1835-hist.XXXXXX")" || exit 1
trap 'find "$WORK" -depth -delete 2>/dev/null' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
unset TMUX GIT_DIR GIT_WORK_TREE
export AITEAMFORGE_DIR="$WORK/atf"
export CLAUDE_CONFIG_DIR="$WORK/claude"
export USER="${USER:-tester}"
mkdir -p "$AITEAMFORGE_DIR" "$CLAUDE_CONFIG_DIR"

# Sandbox TEMPLATE_DIR: the real historical corpus, a DUMMY current template.
SB_TPL="$WORK/templates"
mkdir -p "$SB_TPL/claude/historical"
cp "$HIST_DIR"/*.template "$SB_TPL/claude/historical/" || { echo "FATAL: could not copy historical corpus" >&2; exit 1; }
printf '# dummy current template (XACA-1835 test)\n{{AITEAMFORGE_DIR}}\n' > "$SB_TPL/claude/claude-md-global.template"
export TEMPLATE_DIR="$SB_TPL"

# Source the REAL installer (its main is guarded by BASH_SOURCE == $0).
# shellcheck disable=SC1090
source "$INSTALLER"
set +e +u +o pipefail
for _fn in _xaca1159_claude_md_historical_variants _xaca1159_bootstrap_claude_md_provenance apply_template; do
    type -t "$_fn" >/dev/null || { echo "FATAL: installer did not define $_fn" >&2; exit 1; }
done
TEMPLATE_DIR="$SB_TPL"   # the installer's own default must not override the sandbox

ROWS="$(_xaca1159_claude_md_historical_variants)"

# Render a raw historical template the way an install at that time did, using
# this sandbox's values. Independent of the function under test on purpose.
render_fixture() { # src token out
    sed -e "s|{{$2}}|${AITEAMFORGE_DIR}|g" \
        -e "s|{{HOME}}|${HOME}|g" \
        -e "s|{{CLAUDE_CONFIG_DIR}}|${CLAUDE_CONFIG_DIR}|g" \
        -e "s|{{USER}}|${USER}|g" \
        "$1" > "$3"
}

echo "== A: registry <-> corpus bijection =="
n_rows=0
while IFS='|' read -r fname token; do
    [ -n "$fname" ] || continue
    n_rows=$((n_rows + 1))
    if [ -f "$HIST_DIR/$fname" ]; then ok "A1 row has its file: $fname"; else bad "A1 row names a missing file: $fname"; continue; fi
    case "$token" in
        DEV_TEAM_DIR|AITEAMFORGE_DIR)
            if grep -qF "{{$token}}" "$HIST_DIR/$fname"; then ok "A3 $fname uses its declared token {{$token}}"
            else bad "A3 $fname declares {{$token}} but never contains it"; fi ;;
        *) bad "A3 $fname declares unknown token '$token'" ;;
    esac
done <<< "$ROWS"
[ "$n_rows" -ge 1 ] || bad "A0 variants list is empty"
for f in "$HIST_DIR"/*.template; do
    b="$(basename "$f")"
    if printf '%s\n' "$ROWS" | awk -F'|' -v b="$b" '$1==b{found=1} END{exit !found}'; then
        ok "A2 file is registered: $b"
    else
        bad "A2 orphan historical file never consulted by the bootstrap: $b"
    fi
done

echo "== C: every registered variant bootstraps on its own (dummy current template) =="
newest_fname=""; newest_token=""
while IFS='|' read -r fname token; do
    [ -n "$fname" ] && [ -f "$HIST_DIR/$fname" ] || continue
    newest_fname="$fname"; newest_token="$token"
    live="$WORK/live.$fname"
    render_fixture "$HIST_DIR/$fname" "$token" "$live"
    _xaca1159_bootstrap_claude_md_provenance "$live"; rc=$?
    if [ "$rc" -eq 0 ]; then ok "C  receipt-less render of $fname -> bootstrap rc 0"
    else bad "C  receipt-less render of $fname -> bootstrap rc $rc (box would be stranded)"; fi
done <<< "$ROWS"

echo "== C+: the real current template bootstraps =="
TEMPLATE_DIR="$WORK/templates-real"; mkdir -p "$TEMPLATE_DIR/claude/historical"
cp "$CUR_TEMPLATE" "$TEMPLATE_DIR/claude/claude-md-global.template"
cp "$HIST_DIR"/*.template "$TEMPLATE_DIR/claude/historical/"
apply_template "$CUR_TEMPLATE" "$WORK/live.current" >/dev/null 2>&1
_xaca1159_bootstrap_claude_md_provenance "$WORK/live.current"; rc=$?
if [ "$rc" -eq 0 ]; then ok "C+ render of the shipped current template -> rc 0"; else bad "C+ current template render -> rc $rc"; fi
TEMPLATE_DIR="$SB_TPL"

echo "== N: negative controls =="
if [ -n "$newest_fname" ]; then
    cp "$WORK/live.$newest_fname" "$WORK/live.mut"; printf 'x' >> "$WORK/live.mut"
    _xaca1159_bootstrap_claude_md_provenance "$WORK/live.mut"; rc=$?
    if [ "$rc" -eq 1 ]; then ok "N1 one appended byte -> rc 1 (customized is never mistaken for pristine)"
    else bad "N1 appended-byte fixture -> rc $rc, expected 1"; fi

    # N2: drop the newest row and prove its own fixture is no longer recognised.
    eval "$(declare -f _xaca1159_claude_md_historical_variants | sed '1s/_xaca1159_claude_md_historical_variants/_x1835_orig_variants/')"
    _xaca1159_claude_md_historical_variants() { _x1835_orig_variants | grep -vF "$newest_fname|"; }
    _xaca1159_bootstrap_claude_md_provenance "$WORK/live.$newest_fname"; rc=$?
    if [ "$rc" -eq 1 ]; then ok "N2 with row $newest_fname removed, its fixture -> rc 1 (the row is load-bearing)"
    else bad "N2 removing row $newest_fname did not change the verdict (rc $rc): the test cannot see a missing registration"; fi
    eval "$(declare -f _x1835_orig_variants | sed '1s/_x1835_orig_variants/_xaca1159_claude_md_historical_variants/')"
else
    bad "N  no usable variant to build negative controls from"
fi

echo "== B: every release-tagged template blob is current or registered (needs full history) =="
P="share/templates/claude/claude-md-global.template"
if git -C "$TAP_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
   && [ "$(git -C "$TAP_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" = "false" ] \
   && [ -n "$(git -C "$TAP_ROOT" tag 2>/dev/null | head -1)" ]; then
    reg_blobs="$(for f in "$HIST_DIR"/*.template; do git -C "$TAP_ROOT" hash-object "$f"; done; git -C "$TAP_ROOT" hash-object "$CUR_TEMPLATE")"
    seen=" "
    for t in $(git -C "$TAP_ROOT" tag); do
        b="$(git -C "$TAP_ROOT" rev-parse -q --verify "$t:$P" 2>/dev/null)" || continue
        case "$seen" in *" $b "*) continue ;; esac
        seen="$seen$b "
        if printf '%s\n' "$reg_blobs" | grep -qx "$b"; then ok "B  blob ${b:0:7} (first seen at $t) is registered or current"
        else bad "B  blob ${b:0:7} shipped at $t but is neither current nor registered"; fi
    done
else
    echo "  NOTE: shallow or tagless checkout; B not evaluated here (dev-team's pre-merge guard enforces it)."
fi

_TOTAL=$((_PASS + _FAIL))
echo ""
echo "XACA-1835 historical-variants tests: ${_PASS} passed, ${_FAIL} failed (${_TOTAL} assertions)"
[ "$_TOTAL" -gt 0 ] || { echo "FATAL: zero assertions executed" >&2; exit 1; }
[ "$_FAIL" -eq 0 ] || exit 1
exit 0
