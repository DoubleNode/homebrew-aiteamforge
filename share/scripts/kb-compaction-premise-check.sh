#!/usr/bin/env bash
# kb-compaction-premise-check.sh — XACA-1277 ratchet
#
# XACA-1277 decided to HOLD a P=50 CLAUDE_AUTOCOMPACT_PCT_OVERRIDE pilot on
# M3Pro only. That decision rests on premises that are KNOWN to be movable.
# Memory entry `feedback_completed_fixes_expire_when_premises_change` records
# that XACA-0284 regrew four times precisely because it shipped prose with no
# mechanism to notice when its premise moved. This script is that mechanism.
#
# It checks four things and FAILS CLOSED — an unreadable binary, an
# unparseable version, or an unavailable measurement reports COULD NOT VERIFY
# and exits non-zero. "Could not verify" is never a pass.
#
#   A. The compaction formula in the INSTALLED Claude Code binary still has the
#      shape XACA-1277-001/004 read, and its two constants (13000, 20000) and
#      its coded bufferFraction default (0.2) are unchanged.
#   B. The derived thresholds still equal the recorded baselines.
#   C. No 200K-tier (Haiku 4.5) session's observed peak has crept up toward
#      NOTE: the 200K tier is PINNED in code to TIER_200K ("haiku-4-5"), not
#      inferred from the substring `haiku`. Haiku 4.5 is 200K; that is a fact
#      about 4.5, not about the name. Any OTHER Haiku is excluded from C with
#      a printed note telling you to re-derive its tier, rather than being
#      compared against 90,000 and failing at rc=1 with the wrong cause.
#      Update TIER_200K deliberately when a new Haiku ships.
#      threshold(P). Trips on MOVEMENT from the recorded XACA-1277-005 baseline
#      (80,702), not on a fixed fraction: warn on any growth past it, fail at
#      >=95% and at >=100% of threshold(P). A fixed "warn at 85%" was rejected
#      during review -- Haiku's resting margin is 11.5%, i.e. 89.7% of
#      threshold(50), so an 85% trip point fires on day one and every day
#      after, and a warning that is always on carries no information.
#      (This comment previously described the rejected 85% design -- the same
#      docstring-vs-implementation mismatch class this ratchet exists to catch,
#      found in review as XACA-1277-016.)
# KNOWN RESIDUAL (stated, not hidden). The size floor can only catch truncation
# it can measure against a known-good size. Three things must hold for it to be
# bypassed: BASE_BIN_BYTES must be badly stale (real bundle far larger), the
# versions dir must be pruned so no complete sibling remains, AND the file must
# be truncated. In that combination a truncation above the stale floor reaches
# the shape checks and reports rc=1 (DRIFTED) rather than rc=2. It is bounded --
# the floor never drops below BIN_MIN_PCT% of BASE_BIN_BYTES.
#
# An earlier revision of this note claimed "the staleness warning above fires
# first, telling you to refresh the baseline." THAT IS FALSE and is exactly the
# false-reassurance this ticket is about: the staleness warning compares
# BASE_BIN_BYTES against $BIN_SIZE, which on a TRUNCATED file is small -- so in
# the very scenario described here it cannot fire. The warning helps when the
# bundle has legitimately grown; it is no help at all against a truncation. The
# all-shapes-failed downgrade catches the severe end of this (nothing readable),
# but NOT the partial case: `tengu_amber_rokovoko` sits at ~35% of the bundle, so
# A3 still passes on a mid-file truncation and the run reads as selective drift.
# Deliberately NOT "fixed" by loosening that downgrade to a majority vote --
# that would start swallowing genuine multi-part drift, which is strictly worse
# for a drift detector than the narrow false-alarm it would prevent.
#
#   D. CLAUDE_CODE_ENTRYPOINT has not become `remote_cowork` or `local-agent`
#      anywhere in THIS MACHINE's transcripts (~/.claude/projects — it is a
#      single-machine scan, not a fleet-wide one), and is not set to one now.
#
# NOT wired into CI, and NOT wired into any hook. Run it by hand:
#
#     bash scripts/kb-compaction-premise-check.sh
#     KB_COMPACTION_P=50 bash scripts/kb-compaction-premise-check.sh   # explicit P
#
# Suggested cadence: after every Claude Code version bump, and at the
# MODEL_SELECTION.md quarterly review.
#
# Exit codes:  0 = all premises hold   1 = a premise has DRIFTED
#              2 = COULD NOT VERIFY (treat as failure, not as a pass)

set -uo pipefail

# Real path to THIS script, for the pin-remediation hint (`$0` resolves to the
# caller's shell when the hint is pasted into an interactive prompt: rc=126).
SELF="$0"
P="${KB_COMPACTION_P:-50}"
# Non-blocking (PR #927 round 2): an out-of-range or non-numeric P silently
# produced a confident-looking FAIL at rc=1 -- a wrong answer that looks like a
# finding. Refuse the input instead.
case "$P" in ''|*[!0-9]*) echo "kb-compaction-premise-check: KB_COMPACTION_P must be an integer 1-100, got '$P'" >&2; exit 2 ;; esac
if [ "$P" -lt 1 ] || [ "$P" -gt 100 ]; then
  echo "kb-compaction-premise-check: KB_COMPACTION_P must be 1-100, got '$P'" >&2; exit 2
fi

# ── Recorded baselines (XACA-1277, measured 2026-09-17 against 2.1.274) ──────
BASE_RESERVE_HEADROOM=13000     # qPe:  W6 - 13000
BASE_RESERVE_OUTPUT=20000       # W6:   window - min(maxOutputTokens, 20000)
BASE_BUFFER_DEFAULT="0.2"       # zPe:  coded precomputeBufferFraction default
BASE_DEFAULT_1M=967000          # default threshold, 1M-window tier
BASE_DEFAULT_200K=167000        # default threshold, 200K tier (Haiku 4.5)
BASE_P50_1M=490000
BASE_P50_200K=90000
BASE_HAIKU_PEAK=80702           # XACA-1277-005 observed peak, N=194 turns

RC=0
FAIL_N=0
UNVER_N=0
SHAPE_FAILS=0
SHAPE_TOTAL=0
note()  { printf '  %s\n' "$*"; }
pass()  { printf 'PASS   %s\n' "$*"; }
warn()  { printf 'WARN   %s\n' "$*"; }
fail()  { printf 'FAIL   %s\n' "$*"; FAIL_N=$((FAIL_N+1)); RC=1; }
unver() { printf 'COULD NOT VERIFY  %s\n' "$*"; UNVER_N=$((UNVER_N+1)); if [ "$RC" -eq 0 ]; then RC=2; fi; return 0; }

echo "kb-compaction-premise-check — XACA-1277 ratchet"
echo "configured P = ${P}"
echo

# ── Locate the installed binary ─────────────────────────────────────────────
# XACA-1282-002: CLAUDE_VERSIONS_DIR stays the highest-precedence override,
# validated exactly as it always was (same two failure messages, same
# behavior) -- only the DEFAULT changes. The OLD default
# ($HOME/.local/share/claude/versions) was measured EMPTY on M4Mini and
# ABSENT on M1Pro/M1Mini (kanban/XACA-1282_fleet_compaction_rollout.md), so a
# mirrored copy of this ratchet exited rc=2 before running a single check on
# 3 of the 4 fleet machines -- fail-closed and correct, but useless
# everywhere it would newly land. The fix is not to loosen fail-closed; it is
# to try more than exactly one path before giving up, and to say what was
# tried when nothing is found.
# XACA-1282-024 (PR #929 review): pick the newest VERSION-SHAPED entry, filtering
# BEFORE taking the max. The previous `sort -V | tail -1` took the max over EVERY
# entry and only then asked whether it parsed -- so a single unrelated directory
# that sorts high silently disqualified an otherwise valid versions dir (measured:
# 'staging' sorts above 2.1.276 under sort -V). The failure was doubly bad because
# the remedy it printed (export CLAUDE_VERSIONS_DIR=<that very dir>) then failed
# identically, sending the operator in a circle.
#
# Applied to BOTH the explicit-override branch and _candidate_ok, deliberately
# going beyond the review finding's literal wording (it named _candidate_ok only).
# The two sites had the IDENTICAL defect from the same copied line; fixing one and
# leaving the other would have made the override path pass by coincidence.
# Prints empty when no entry parses -- callers keep their own '<none>' wording.
_newest_version_entry() {
  find "$1" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' \
    | sort -V | tail -1
}

# _non_version_entries <dir> -- space-joined basenames that did NOT parse, for the
# failure message. An operator who sees "entries present: staging" can act; one who
# sees only "<none>" against a visibly non-empty directory cannot.
_non_version_entries() {
  find "$1" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null \
    | grep -Ev '^[0-9]+\.[0-9]+\.[0-9]+' \
    | sort | tr '\n' ' '
}

if [ -n "${CLAUDE_VERSIONS_DIR:-}" ]; then
  VERSIONS_DIR="$CLAUDE_VERSIONS_DIR"
  if [ ! -d "$VERSIONS_DIR" ]; then
    unver "A. no Claude Code versions directory at $VERSIONS_DIR — cannot re-derive the formula."
    echo; echo "RESULT: could not verify (rc=$RC)"; exit "$RC"
  fi
  # SC2012: find, not ls, so odd directory entries cannot corrupt the parse.
  VERSION=$(_newest_version_entry "$VERSIONS_DIR")
  if [ -z "$VERSION" ]; then
    _others=$(_non_version_entries "$VERSIONS_DIR")
    _others=${_others% }
    unver "A. newest entry in $VERSIONS_DIR is '<none>' — not a parseable version.${_others:+ (non-version entries present: $_others)}"
    echo; echo "RESULT: could not verify (rc=$RC)"; exit "$RC"
  fi
else
  # No override given -- probe a short list of plausible install locations.
  # Every candidate is held to the SAME bar the explicit override always
  # was: the directory must exist AND contain at least one entry that parses
  # as a version. An existing-but-EMPTY directory (the exact M4Mini shape)
  # is correctly rejected here, not accepted as "found" -- that is what the
  # old single-path default got wrong, not the fail-closed exit itself.

  # Portable "readlink -f" substitute: older BSD readlink (pre-Sequoia
  # macOS) lacks -f, and this must also run under CI's Linux /bin/bash.
  # Read-only; only ever used to trace 'command -v claude' to its real
  # target. Bounded to 20 hops so a symlink cycle cannot hang the script.
  _resolve_symlink_chain() {
    _p="$1"; _n=0
    while [ -L "$_p" ] && [ "$_n" -lt 20 ]; do
      _link=$(readlink "$_p" 2>/dev/null || true)
      [ -z "$_link" ] && break
      case "$_link" in
        /*) _p="$_link" ;;
        *) _p="$(dirname "$_p")/$_link" ;;
      esac
      _n=$((_n + 1))
    done
    printf '%s\n' "$_p"
  }

  # _candidate_ok <dir> -- rc=0 and sets $_CAND_VERSION when <dir> exists AND
  # its newest `sort -V` entry parses as a version. Identical validation to
  # the explicit-override branch above, applied to each guess in turn.
  _candidate_ok() {
    _d="$1"
    [ -d "$_d" ] || return 1
    _v=$(_newest_version_entry "$_d")
    [ -n "$_v" ] || return 1
    _CAND_VERSION="$_v"; return 0
  }

  # Candidates, in probe order. VERIFIED against this machine (M3Pro,
  # 2026-09-18) means: observed to exist and resolve as described here, not
  # that every fleet machine uses it -- the three tap machines (M4Mini,
  # M1Pro, M1Mini) were not reachable from this session and get Claude Code
  # by a different route than this dev machine's native installer, per the
  # plan doc. Unverified candidates are included because they are plausible
  # and cheap to probe, and are gated by _candidate_ok so a directory that
  # merely exists for an unrelated reason is harmlessly skipped.
  _CAND_PATH=()
  _CAND_LABEL=()

  # 1. VERIFIED (M3Pro): the native Claude Code installer's own layout; this
  #    machine's `claude` resolves into exactly this directory.
  _CAND_PATH+=("$HOME/.local/share/claude/versions")
  _CAND_LABEL+=("default native-installer path")

  # 2. VERIFIED MECHANISM (M3Pro; resolves to the same path as #1 here,
  #    since this machine uses the native installer) -- but this candidate
  #    is the one that generalizes past $HOME/a custom install prefix on a
  #    machine this session cannot reach, by deriving the versions dir from
  #    whatever `claude` on PATH actually resolves to, rather than assuming
  #    the default prefix.
  _claude_bin=$(command -v claude 2>/dev/null || true)
  if [ -n "$_claude_bin" ]; then
    _resolved=$(_resolve_symlink_chain "$_claude_bin")
    _resolved_parent=$(dirname "$_resolved" 2>/dev/null || true)
    if [ -n "$_resolved_parent" ] && [ "$(basename "$_resolved_parent")" = "versions" ]; then
      _CAND_PATH+=("$_resolved_parent")
      _CAND_LABEL+=("resolved from 'command -v claude' ($_claude_bin -> $_resolved)")
    fi
  fi

  # 3. UNVERIFIED: no claude-code homebrew formula exists on this machine to
  #    confirm against, and by design (XACA-0212, CLAUDE.md) this dev
  #    machine must never carry the aiteamforge tap that would install one.
  #    Gated by _candidate_ok, so this is a no-op guess where it doesn't
  #    apply.
  if command -v brew >/dev/null 2>&1; then
    _brew_prefix=$(brew --prefix 2>/dev/null || true)
    if [ -n "$_brew_prefix" ]; then
      _CAND_PATH+=("$_brew_prefix/opt/claude-code/versions")
      _CAND_LABEL+=("homebrew opt (formula: claude-code)")
    fi
  fi

  # 4. UNVERIFIED: no @anthropic-ai/claude-code npm package is installed on
  #    this machine (checked 2026-09-18: `npm ls -g` returned empty).
  if command -v npm >/dev/null 2>&1; then
    _npm_root=$(npm root -g 2>/dev/null || true)
    if [ -n "$_npm_root" ]; then
      _CAND_PATH+=("$_npm_root/@anthropic-ai/claude-code/versions")
      _CAND_LABEL+=("npm global root (@anthropic-ai/claude-code)")
    fi
  fi

  # 5. UNVERIFIED: no such directory exists under ~/.aiteamforge on this
  #    machine; included because the tap machines route Claude Code
  #    provisioning through AITeamForge and might place it here.
  _CAND_PATH+=("$HOME/.aiteamforge/claude/versions")
  _CAND_LABEL+=("aiteamforge tap install root")

  VERSIONS_DIR=""
  _i=0
  while [ "$_i" -lt "${#_CAND_PATH[@]}" ]; do
    _try="${_CAND_PATH[$_i]}"
    if _candidate_ok "$_try"; then
      VERSIONS_DIR="$_try"
      VERSION="$_CAND_VERSION"
      note "auto-discovered Claude Code versions dir at $VERSIONS_DIR (${_CAND_LABEL[$_i]})"
      break
    fi
    _i=$((_i + 1))
  done

  if [ -z "$VERSIONS_DIR" ]; then
    unver "A. no Claude Code versions directory found on $(hostname 2>/dev/null || echo '<unknown host>') after probing ${#_CAND_PATH[@]} locations:"
    _i=0
    while [ "$_i" -lt "${#_CAND_PATH[@]}" ]; do
      note "  - ${_CAND_PATH[$_i]}  (${_CAND_LABEL[$_i]})"
      _i=$((_i + 1))
    done
    note "Remedy: export CLAUDE_VERSIONS_DIR=/path/to/claude/versions and re-run, e.g.:"
    note "  CLAUDE_VERSIONS_DIR=/path/to/versions bash $SELF"
    echo; echo "RESULT: could not verify (rc=$RC)"; exit "$RC"
  fi
fi
BIN="$VERSIONS_DIR/$VERSION"
if [ ! -r "$BIN" ]; then
  unver "A. binary $BIN is not readable."
  echo; echo "RESULT: could not verify (rc=$RC)"; exit "$RC"
fi
echo "binary: $BIN (version $VERSION)"
echo

# ── A. Formula shape + constants ────────────────────────────────────────────
# XACA-1277 (found live 2026-09-17): a Claude Code upgrade lands the NEW version
# file before it finishes writing it. `sort -V | tail -1` correctly selects it,
# and every `bin_has` shape check then finds nothing -- which the A0-A3 arms
# reported as fail() / "a premise has DRIFTED" (rc=1). That is the wrong verdict
# and the same defect class this whole ticket is about: absence of a pattern in
# a 0-byte file is ABSENCE OF EVIDENCE, not evidence that the formula changed.
# Measured: 2.1.275 appeared at 17:47 as a 0-byte file alongside a complete
# 214MB 2.1.274, and the ratchet reported DRIFTED across A0-A3.
#
# An earlier test matrix listed "empty binary -> rc=1" as EXPECTED and it was
# re-verified as correct twice; the contract itself was wrong.
#
# Refuse to judge a binary too small to contain the bundle. Exit 2, never 1.
# XACA-1277-0xx (PR #927 round 2): relative floor, not absolute.
BIN_MIN_PCT="${BIN_MIN_PCT:-90}"
case "$BIN_MIN_PCT" in ''|*[!0-9]*)
  echo "kb-compaction-premise-check: BIN_MIN_PCT must be an integer, got '$BIN_MIN_PCT'" >&2; exit 2 ;;
esac
if [ "$BIN_MIN_PCT" -lt 1 ] || [ "$BIN_MIN_PCT" -gt 100 ]; then
  echo "kb-compaction-premise-check: BIN_MIN_PCT must be 1-100, got '$BIN_MIN_PCT'" >&2; exit 2
fi
# XACA-1277 PR #927 round 3 (BLOCKING, found by probing "can the floor be
# fooled?"): "90% of the largest sibling" is SELF-REFERENTIAL when the dir holds
# only one file, or only similarly-truncated files -- a truncated binary
# trivially clears 90% OF ITSELF. Reproduced with a lone 1MB file and with two
# truncated 5MB files: both yielded FAIL A0-A3 / rc=1, i.e. the very false-DRIFT
# this guard exists to prevent, reached via directory state instead of byte
# count. That is the same shape as the original A5 tautology -- a check
# comparing a value against itself -- so the remedy must be an anchor that
# directory state cannot move.
#
# BASE_BIN_BYTES is that anchor: a real measured size, recorded here, which no
# amount of pruning or truncation in $VERSIONS_DIR can shrink. The floor is 90%
# of whichever is LARGER, the recorded baseline or the largest sibling, so:
#   - a pruned dir still gets a real floor (baseline wins);
#   - a genuinely bigger future release raises it (sibling wins);
#   - the 10% margin is a JUDGEMENT, not a derived bound. An earlier revision
#     justified it with measured release-to-release GROWTH (+0.90% across five
#     versions), which is a non-sequitur: this margin constrains SHRINKAGE, and
#     we have no shrinkage data at all. It is chosen so a modest genuine shrink
#     does not trip it, and the failure direction is rc=2 -- a human looks --
#     which is the acceptable way to be wrong here.
# If it ever does, the result is rc=2 (could-not-verify) -- a human looks, which
# is the correct failure direction.
BASE_BIN_BYTES="${BASE_BIN_BYTES:-215643408}"   # 2.1.275, measured 2026-09-17
case "$BASE_BIN_BYTES" in ''|*[!0-9]*)
  echo "kb-compaction-premise-check: BASE_BIN_BYTES must be an integer, got '$BASE_BIN_BYTES'" >&2; exit 2 ;;
esac
_LARGEST="$BASE_BIN_BYTES"
for _f in "$VERSIONS_DIR"/*; do
  [ -f "$_f" ] || continue
  # Exclude the file under test: including it would make the floor "is this file
  # >=90% of itself?", which is always true.
  #
  # HONEST SCOPE (PR #927 r4/r5/r6, measured then reasoned). This line cannot
  # change a VERDICT, and the reason is structural rather than statistical: it
  # only moves $_LARGEST when $BIN is the largest file, and in that case the
  # floor cannot trip anyway. (It CAN change the printed floor VALUE -- measured
  # differing in 3 of 12 cells, all at BASE_BIN_BYTES=0. An earlier revision of
  # this comment claimed "no floor value differs, including BASE=0", which was
  # simply false; the revision before that hedged it as "under the current
  # baseline", which was weaker than the truth. Both are recorded here because
  # over-correcting a hedge into a falsehood is its own failure mode.)
  #
  # Kept because it is correct in principle and becomes load-bearing if
  # BASE_BIN_BYTES is ever removed -- not for a benefit it currently delivers.
  [ "$_f" = "$BIN" ] && continue
  _fs=$(wc -c < "$_f" 2>/dev/null | tr -d ' ')
  case "$_fs" in ''|*[!0-9]*) _fs=0 ;; esac
  [ "$_fs" -gt "$_LARGEST" ] && _LARGEST="$_fs"
done
if [ -n "${BIN_MIN_BYTES:-}" ]; then
  # Explicit override still honoured, but a non-numeric one must NOT fail open.
  case "$BIN_MIN_BYTES" in ''|*[!0-9]*)
    echo "kb-compaction-premise-check: BIN_MIN_BYTES must be an integer, got '$BIN_MIN_BYTES'" >&2; exit 2 ;;
  esac
else
  BIN_MIN_BYTES=$(( _LARGEST * BIN_MIN_PCT / 100 ))
fi
BIN_SIZE=$(wc -c < "$BIN" 2>/dev/null | tr -d ' ')
case "$BIN_SIZE" in ''|*[!0-9]*) BIN_SIZE=0 ;; esac
# The floor is only as good as the best-known-complete size it derives from.
# If the real bundle has grown well past BASE_BIN_BYTES and the versions dir has
# been pruned to a single file, the floor stays anchored to a stale baseline and
# can no longer catch a truncation that still exceeds it. That is a bounded
# limitation, not a tautology -- the floor never falls below 90% of the baseline
# -- but it degrades silently with age, which is precisely the failure mode this
# whole ticket is about. Make the ratchet report its OWN staleness.
if [ "$BIN_SIZE" -gt $(( BASE_BIN_BYTES + BASE_BIN_BYTES / 10 )) ]; then
  warn "A. BASE_BIN_BYTES ($BASE_BIN_BYTES) is >10% below the installed bundle ($BIN_SIZE) — the recorded"
  note "baseline is STALE. The size floor still works but its coverage has degraded;"
  note "refresh BASE_BIN_BYTES to $BIN_SIZE in this script."
fi

if [ "$BIN_SIZE" -lt "$BIN_MIN_BYTES" ]; then
  unver "A. binary $BIN is $BIN_SIZE bytes (< $BIN_MIN_BYTES = ${BIN_MIN_PCT}% of $_LARGEST, the larger of the recorded baseline $BASE_BIN_BYTES and the largest sibling) — empty, truncated, or still downloading."
  note "A newer version file appears before its download completes; this is NOT drift."
  note "Re-run once the upgrade finishes, or pin to a complete version:"
  note "  d=\$(mktemp -d); ln -s $VERSIONS_DIR/<complete-version> \"\$d/\"; \\"
  note "  CLAUDE_VERSIONS_DIR=\"\$d\" bash $SELF"
  note "Complete versions present:"
  for f in "$VERSIONS_DIR"/*; do
    [ -f "$f" ] || continue
    fs=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
    case "$fs" in ''|*[!0-9]*) fs=0 ;; esac
    [ "$fs" -ge "$BIN_MIN_BYTES" ] && note "  $(basename "$f")  (${fs} bytes)"
  done
  echo; echo "RESULT: COULD NOT VERIFY (rc=$RC) — this is a failure, not a pass. Do not read it as 'premises hold'."
  exit "$RC"
fi

echo "A. Formula shape and constants in the installed binary"

# Identifiers are minified and CHANGE between builds, so every pattern below
# matches on STRUCTURE with wildcard identifiers, never on a specific name.
IDENT='[A-Za-z0-9_$]+'

bin_has() { LC_ALL=C grep -a -q -E "$1" "$BIN"; }

# XACA-1277-018 (PR #927 review): escape `$` before interpolating a harvested
# minified identifier into an ERE, where a bare `$` is an end-anchor rather
# than a literal. A build minifying to `$a` / `a$b` would otherwise make A5 and
# A6 permanently unverifiable — fail-closed, but silently defeated.
esc_ere() { printf '%s' "$1" | sed 's/[$]/\\$/g'; }

# XACA-1277 PR #927 r4: count definition sites WITHOUT a consuming left
# boundary. `grep -o` is non-overlapping and a leading [^A-Za-z0-9_$] eats the
# delimiter the NEXT match needs, so `,K=20000,K=30000,` counted 1 and resolved
# 20000 with two definitions present -- worst case a false green. Enumerate
# every <ident>=<digits> and count exact-name matches instead.
count_defs() { # count_defs <ident>
  [ -n "$1" ] || { printf 0; return 0; }
  LC_ALL=C grep -a -o -E "[A-Za-z0-9_$]+=([0-9]+(\.[0-9]+)?|\.[0-9]+)[,;]" "$BIN" | grep -c -E "^$(esc_ere "$1")=" || true
}

# qPe body: `let <x>=e-13000, <s>=<n>.testPctOverride`
# XACA-1277-032 (r5): A4 had NO uniqueness assertion — a second qPe-shaped site
# would have been resolved by head -1 without a word. This harvest is structural
# rather than an identifier lookup, so assert the PATTERN's uniqueness directly.
_RH_HITS=$(LC_ALL=C grep -a -o -E "=${IDENT}-[0-9]+,${IDENT}=${IDENT}\.testPctOverride" "$BIN" | wc -l | tr -d ' ')
case "$_RH_HITS" in ''|*[!0-9]*) _RH_HITS=0 ;; esac
[ "$_RH_HITS" -gt 1 ] && note "A4 the qPe headroom anchor matched $_RH_HITS sites — ambiguous, refusing to guess."
RESERVE_HEADROOM=$(LC_ALL=C grep -a -o -E "=${IDENT}-[0-9]+,${IDENT}=${IDENT}\.testPctOverride" "$BIN" \
                    | head -1 | sed -E 's/^.*-([0-9]+),.*$/\1/')
[ "$_RH_HITS" -eq 1 ] || RESERVE_HEADROOM=""   # ambiguous or unreadable -> could-not-verify
# W6 body: `function W6(e,n){let r=Math.min(<maxOutputFn>(e), <K>)`.
#
# XACA-1277-008 BLOCKING FIX. The previous pattern was `${IDENT}=20000[,;]` --
# it hardcoded the very value it claimed to verify into the search target, with
# NO anchor to the W6/qPe site despite a comment asserting one. That grep has 41
# unrelated matches in the real 2.1.274 bundle, so `head -1` returned some other
# constant's 20000 and A5 reported PASS *by construction*: a fixture whose real
# reserve had drifted to 25000 still produced `PASS A5 ... = 20000` and rc=0.
# A check that cannot fail is worse than no check -- it manufactures confidence
# about exactly the drift this ratchet exists to catch.
#
# Now two structurally-anchored steps, with the NUMBER WILDCARDED:
#   1. find the unique `function W6(..){let ..=Math.min(..(..),<K>)` site and
#      read <K>'s IDENTIFIER off it (measured: this shape matches exactly once
#      in the 210MB bundle, the same uniqueness A1/A2/A4 rely on);
#   2. read <K>'s own definition as `<K>=[0-9]+`, so a drifted value is
#      EXTRACTED and then compared, rather than being pattern-matched away.
# Name-free: harvest <K> from the structural site, never from `function W6(`.
# XACA-1277-028 (PR #927 r3 review): the comment above claims this anchor
# "matches EXACTLY ONCE"; head -1 asserted no such thing. Enforce the claim
# rather than merely stating it -- a second match means we cannot tell which
# site is the real W6, and picking one would be a guess dressed as a reading.
_A0_HITS=$(LC_ALL=C grep -a -o -E "Math\.min\(${IDENT}\(${IDENT}\),${IDENT}\),${IDENT}=${IDENT}\(\)\?" "$BIN" | wc -l | tr -d ' ')
case "$_A0_HITS" in ''|*[!0-9]*) _A0_HITS=0 ;; esac
if [ "$_A0_HITS" -eq 1 ]; then
  RESERVE_OUTPUT_ID=$(LC_ALL=C grep -a -o -E "Math\.min\(${IDENT}\(${IDENT}\),${IDENT}\),${IDENT}=${IDENT}\(\)\?" "$BIN" \
                       | head -1 | sed -E 's/^Math\.min\([^,]*,([A-Za-z0-9_$]+)\).*$/\1/')
else
  RESERVE_OUTPUT_ID=""
  [ "$_A0_HITS" -gt 1 ] && note "A5 the W6 anchor matched $_A0_HITS sites — ambiguous, refusing to guess which is the real one."
fi
if [ -n "$RESERVE_OUTPUT_ID" ]; then
  # XACA-1277-0xx (PR #927 round 2): assert UNIQUENESS before trusting head -1.
  # A0's whole claim is that its anchor matches exactly once; the identifier
  # lookup it feeds asserted nothing, so a colliding definition would be
  # silently resolved by head -1 -- the original A5 bug one level indirected.
  _RO_HITS=$(count_defs "$RESERVE_OUTPUT_ID")
  case "$_RO_HITS" in ''|*[!0-9]*) _RO_HITS=0 ;; esac
  if [ "$_RO_HITS" -eq 1 ]; then
    RESERVE_OUTPUT=$(LC_ALL=C grep -a -o -E "[^A-Za-z0-9_$]$(esc_ere "$RESERVE_OUTPUT_ID")=[0-9]+[,;]" "$BIN" \
                      | head -1 | sed -E 's/^.*=([0-9]+)[,;]$/\1/')
  else
    # 0 hits = cannot read it; >1 = ambiguous, and picking one would be a guess.
    RESERVE_OUTPUT=""
    [ "$_RO_HITS" -gt 1 ] && note "A5 '$RESERVE_OUTPUT_ID' has $_RO_HITS definition sites — ambiguous, refusing to guess."
  fi
else
  RESERVE_OUTPUT=""
fi
# Name-free: `Att` is minifier output (2.1.274 `Att` -> 2.1.275 `utt`).
BUFFER_DEFAULT=$(LC_ALL=C grep -a -o -E "${IDENT}=0\.[0-9]+[,;]?function ${IDENT}\(\)\{let ${IDENT}=${IDENT}\(\"tengu_amber_rokovoko\"" "$BIN" | head -1 | sed -E 's/^[^=]*=(0\.[0-9]+).*$/\1/')
# Direct read of the fallback constant name used by Att().
ATT_CONST=$(LC_ALL=C grep -a -o -E "function ${IDENT}\(\)\{let ${IDENT}=${IDENT}\(\"tengu_amber_rokovoko\",${IDENT}\)" "$BIN" \
             | head -1 | sed -E 's/^.*tengu_amber_rokovoko","?([A-Za-z0-9_$]+)\)$/\1/')
if [ -n "$ATT_CONST" ]; then
  # Same uniqueness assertion as A5 above — A6 rests entirely on this path
  # (its primary pattern was measured to match ZERO times in real 2.1.274).
  _AC_HITS=$(count_defs "$ATT_CONST")
  case "$_AC_HITS" in ''|*[!0-9]*) _AC_HITS=0 ;; esac
  if [ "$_AC_HITS" -eq 1 ]; then
    V=$(LC_ALL=C grep -a -o -E "[^A-Za-z0-9_$]$(esc_ere "$ATT_CONST")=(0?\.[0-9]+)[,;]" "$BIN" | head -1 | sed -E 's/^.*=([0-9.]+)[,;]$/\1/')
  else
    V=""
    [ "$_AC_HITS" -gt 1 ] && note "A6 '$ATT_CONST' has $_AC_HITS definition sites — ambiguous, refusing to guess."
  fi
  [ -n "$V" ] && BUFFER_DEFAULT="$V"
fi

# XACA-1277 (found by the ratchet ON ITSELF, 2.1.275, 2026-09-17):
# NEVER anchor on a minified identifier. `W6`, `h4e`, `Lkn`, `zPe` are minifier
# output and are re-assigned on every build: 2.1.274's
#   function W6(e,n){let r=Math.min(h4e(e),Lkn)
# is 2.1.275's
#   function T6(e,n){let r=Math.min(dKe(e),xkn)
# A check keyed on `function W6\(` therefore reports "PREMISE DRIFTED" on EVERY
# release regardless of whether the formula changed -- and a ratchet that cries
# wolf each release is one nobody reads.
#
# Worse, it can fail OPEN: `function W6(` still occurs TWICE in 2.1.275, now
# naming unrelated functions that inherited the recycled name. Matching one of
# those would have read as success.
#
# The surviving anchors are the ones keyed on things the minifier cannot rename:
# structural shape (A1), and property/string literals crossing an API boundary
# -- `precomputeBufferFraction` (A2), `tengu_amber_rokovoko` (A3),
# `testPctOverride` (A4). Measured: the name-free shape below matches EXACTLY
# ONCE in both 2.1.274 and 2.1.275.
if bin_has "Math\.min\(${IDENT}\(${IDENT}\),${IDENT}\),${IDENT}=${IDENT}\(\)\?"; then
  SHAPE_TOTAL=$((SHAPE_TOTAL+1)); pass "A0 W6 max-output clamp site present: W6 = window - min(maxOutputTokens, K)"
else
  SHAPE_TOTAL=$((SHAPE_TOTAL+1)); SHAPE_FAILS=$((SHAPE_FAILS+1)); fail "A0 the W6 max-output clamp site is GONE from the binary — the formula's shape has changed; re-derive it before trusting any threshold below."
fi

if bin_has "Math\.min\(Math\.floor\(${IDENT}\*\(${IDENT}/100\)\),${IDENT}\)"; then
  SHAPE_TOTAL=$((SHAPE_TOTAL+1)); pass "A1 percentage clamp present: min(floor(W6 * P/100), W6 - headroom)"
else
  SHAPE_TOTAL=$((SHAPE_TOTAL+1)); SHAPE_FAILS=$((SHAPE_FAILS+1)); fail "A1 percentage clamp NOT found — qPe's shape has changed. Re-read the binary before trusting any threshold in the docs."
fi

if bin_has "Math\.min\(${IDENT}-Math\.round\(${IDENT}\*${IDENT}\.precomputeBufferFraction\),"; then
  SHAPE_TOTAL=$((SHAPE_TOTAL+1)); pass "A2 outer bufferFraction clamp present: min(W6 - round(W6*f), qPe(...))"
else
  SHAPE_TOTAL=$((SHAPE_TOTAL+1)); SHAPE_FAILS=$((SHAPE_FAILS+1)); fail "A2 outer bufferFraction clamp NOT found — the XACA-1277-004 outer clamp has changed shape."
fi

if bin_has 'tengu_amber_rokovoko'; then
  SHAPE_TOTAL=$((SHAPE_TOTAL+1)); pass "A3 bufferFraction is still remote-config gated via tengu_amber_rokovoko"
else
  SHAPE_TOTAL=$((SHAPE_TOTAL+1)); SHAPE_FAILS=$((SHAPE_FAILS+1)); fail "A3 tengu_amber_rokovoko gate is gone — bufferFraction sourcing has changed; the 'f is live ~0' premise no longer applies."
fi

if [ "${RESERVE_HEADROOM:-}" = "$BASE_RESERVE_HEADROOM" ]; then
  pass "A4 headroom reserve = $RESERVE_HEADROOM (baseline $BASE_RESERVE_HEADROOM)"
elif [ -z "${RESERVE_HEADROOM:-}" ]; then
  unver "A4 could not read the headroom reserve constant out of the binary."
else
  fail "A4 headroom reserve is $RESERVE_HEADROOM, baseline was $BASE_RESERVE_HEADROOM — every derived threshold below is now wrong."
fi

if [ "${RESERVE_OUTPUT:-}" = "$BASE_RESERVE_OUTPUT" ]; then
  pass "A5 max-output reserve cap = $RESERVE_OUTPUT (baseline $BASE_RESERVE_OUTPUT)"
elif [ -z "${RESERVE_OUTPUT:-}" ]; then
  unver "A5 could not read the max-output reserve cap out of the binary."
else
  fail "A5 max-output reserve cap is $RESERVE_OUTPUT, baseline was $BASE_RESERVE_OUTPUT."
fi

if [ -z "${BUFFER_DEFAULT:-}" ]; then
  unver "A6 could not read the coded precomputeBufferFraction default."
elif [ "$BUFFER_DEFAULT" = "$BASE_BUFFER_DEFAULT" ]; then
  pass "A6 coded bufferFraction default = $BUFFER_DEFAULT (baseline $BASE_BUFFER_DEFAULT)"
else
  # The outer clamp binds only when f > 0.5 at P=50. A rise past that is the
  # condition under which P=50 stops being robust.
  BINDS=$(awk -v f="$BUFFER_DEFAULT" -v p="$P" 'BEGIN{print ((1-f) < (p/100)) ? "yes" : "no"}')
  if [ "$BINDS" = "yes" ]; then
    fail "A6 coded bufferFraction default moved to $BUFFER_DEFAULT — at P=$P the OUTER clamp now binds and the effective threshold is no longer P% of W6."
  else
    warn "A6 coded bufferFraction default moved to $BUFFER_DEFAULT (baseline $BASE_BUFFER_DEFAULT). At P=$P the outer clamp still does not bind, so the pilot's threshold is unchanged — but the premise text is stale."
  fi
fi
echo

# XACA-1277 PR #927 round 3: if EVERY shape check failed, the parsimonious
# explanation is that we could not read the bundle -- not that four independent,
# separately-anchored parts of the formula changed simultaneously in one
# release. A size floor can only ever catch truncation it can measure against a
# known-good size; this catches the rest, whatever the cause (corrupt file,
# stale baseline on a pruned dir, a packaging change that defeats grep).
# Downgrade to COULD NOT VERIFY so the exit contract holds: rc=2, never rc=1,
# when the evidence is "nothing was readable".
if [ "$SHAPE_TOTAL" -gt 0 ] && [ "$SHAPE_FAILS" -eq "$SHAPE_TOTAL" ]; then
  echo
  unver "A. ALL $SHAPE_TOTAL shape checks failed — treating this as an unreadable/unexpected bundle, NOT as drift."
  note "Four independently-anchored parts of the formula changing at once is far less"
  note "likely than a bad read. Verify the binary is complete and is a Claude Code bundle."
  RC=2; FAIL_N=0
  echo; echo "RESULT: COULD NOT VERIFY (rc=$RC) — this is a failure, not a pass. Do not read it as 'premises hold'."
  exit "$RC"
fi

# ── B. Derived thresholds vs recorded baselines ─────────────────────────────
echo "B. Derived thresholds (bufferFraction taken as the live ~0; see A6)"
# XACA-1277-008 (medium): this used to hardcode 20000/13000 as awk literals, so
# section B stayed tautologically self-consistent with its own constants while
# section A was busy reporting that the REAL ones had drifted -- B printed stale
# baseline numbers during exactly the incident it exists to inform. It now
# derives from the values A actually read out of this binary. If either could
# not be extracted we do NOT fall back to a literal: B reports could-not-verify,
# because a plausible-looking number we cannot source is the failure mode here.
derive() { # derive <window> <maxOutput> <P|"">
  awk -v w="$1" -v mo="$2" -v p="$3" -v ro="$RESERVE_OUTPUT" -v rh="$RESERVE_HEADROOM" 'BEGIN{
    r = (mo < ro) ? mo : ro
    W6 = w - r
    cap = W6 - rh
    if (p == "") { t = cap } else { q = int(W6 * p / 100); t = (q < cap) ? q : cap }
    print t
  }'
}
# XACA-1277 PR #927 review (BOTH gate bots, independently): these four were
# assigned only inside `if [ "$DERIVE_OK" = yes ]`, while section C references
# $P200 unconditionally. On the could-not-derive path `set -u` aborted the whole
# script mid-run: checks C and D never executed, no RESULT: banner printed, and
# the exit code came out 1 ("a premise DRIFTED") despite zero fail() calls and a
# tracked RC of 2 -- inverting the script's own documented exit contract and
# making rc=2 UNREACHABLE on the one path designed to produce it. Initialising
# them here means a missing value degrades to a reported could-not-verify
# instead of an abort. Reproduced under bash 3.2, bash 5.x and zsh.
D1M=""; D200=""; P1M=""; P200=""
case "${RESERVE_OUTPUT}|${RESERVE_HEADROOM}" in
  *[!0-9]*\|*|*\|*[!0-9]*|\|*|*\|)
    unver "B  reserves could not be read from the binary (output='${RESERVE_OUTPUT:-<none>}', headroom='${RESERVE_HEADROOM:-<none>}') — refusing to print thresholds derived from hardcoded fallbacks."
    DERIVE_OK=no ;;
  *) DERIVE_OK=yes ;;
esac

if [ "$DERIVE_OK" = yes ]; then
B_FAILS_BEFORE="$FAIL_N"
D1M=$(derive   1000000 128000 "")
D200=$(derive    200000  64000 "")
P1M=$(derive   1000000 128000 "$P")
P200=$(derive    200000  64000 "$P")
note "1M tier   (Opus 5 / Sonnet 5 / Fable 5):  default $D1M   |  P=$P -> $P1M"
note "200K tier (Haiku 4.5):                    default $D200   |  P=$P -> $P200"
[ "$D1M"  = "$BASE_DEFAULT_1M"   ] || fail "B1 1M default threshold $D1M != baseline $BASE_DEFAULT_1M"
[ "$D200" = "$BASE_DEFAULT_200K" ] || fail "B2 200K default threshold $D200 != baseline $BASE_DEFAULT_200K"
if [ "$P" = "50" ]; then
  [ "$P1M"  = "$BASE_P50_1M"   ] || fail "B3 1M P=50 threshold $P1M != baseline $BASE_P50_1M"
  [ "$P200" = "$BASE_P50_200K" ] || fail "B4 200K P=50 threshold $P200 != baseline $BASE_P50_200K"
  [ "$FAIL_N" -eq "$B_FAILS_BEFORE" ] && pass "B  all four thresholds match the XACA-1277 baselines"
else
  warn "B  P=$P is not the piloted P=50; baselines B3/B4 not compared."
fi
fi   # DERIVE_OK
echo

# ── C. 200K-tier observed peak vs threshold(P) ──────────────────────────────
if [ -z "$P200" ]; then
  unver "C  200K-tier threshold unavailable (section B could not derive it) - the Haiku peak premise was NOT checked this run."
else
echo "C. 200K-tier (Haiku 4.5) observed peak vs threshold($P) = $P200"
PEAK=$(python3 - "$P200" <<'PY' 2>/dev/null
import glob, json, os, sys
# XACA-1277-034: the 200K tier is PINNED to a specific model family, not
# inferred from the substring "haiku". Haiku 4.5 is 200K; that is a fact about
# 4.5, not about the name. A future 1M-window Haiku matched by substring would
# be compared against threshold(P) for 200K and FAIL at rc=1 naming the wrong
# cause -- this ratchet exists to catch premises that move, so its own is pinned
# rather than left to a substring. Update deliberately when a new Haiku ships.
TIER_200K = "haiku-4-5"
_seen_other_haiku = set()
root = os.path.expanduser("~/.claude/projects")
peak = 0; turns = 0
for path in glob.iglob(os.path.join(root, "**", "*.jsonl"), recursive=True):
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                if "haiku" not in line:      # family prefilter; tier discrimination below
                    continue
                try: d = json.loads(line)
                except Exception: continue
                m = d.get("message")
                if not isinstance(m, dict): continue
                _mid = str(m.get("model", ""))
                if TIER_200K not in _mid:
                    if "haiku" in _mid and _mid not in _seen_other_haiku:
                        _seen_other_haiku.add(_mid)
                        print("NOTE|%s is a Haiku that is NOT %s — window NOT assumed 200K; excluded from check C. Re-derive its tier." % (_mid, TIER_200K))
                    continue
                u = m.get("usage")
                if not isinstance(u, dict): continue
                tot = (u.get("input_tokens", 0) or 0) \
                    + (u.get("cache_creation_input_tokens", 0) or 0) \
                    + (u.get("cache_read_input_tokens", 0) or 0)
                turns += 1
                if tot > peak: peak = tot
    except Exception:
        pass
print("%d %d" % (peak, turns))
PY
)
# Surface any NOTE| lines the scan emitted (excluded non-4.5 Haiku ids), then
# strip them so the peak/turns parse sees only its own line. PR #927 r6: the
# note was DEAD CODE via two independent suppressors — the prefilter tested
# TIER_200K so such a record never reached the branch, and the note went to
# stderr, which this invocation discards. The CHANGELOG shipped it as
# delivered behaviour regardless.
printf '%s\n' "$PEAK" | grep -E "^NOTE\|" | sed 's/^NOTE|/  /' || true
PEAK=$(printf '%s\n' "$PEAK" | grep -vE "^NOTE\|" | tail -1)
if [ -z "$PEAK" ]; then
  unver "C  transcript scan failed — cannot establish the 200K-tier peak."
else
  # NOT `set -- $PEAK`: zsh does not word-split an unquoted parameter, so $2
  # would be unset and `set -u` aborts the script mid-check (verified).
  OBS=$(printf '%s\n' "$PEAK" | cut -d' ' -f1)
  TURNS=$(printf '%s\n' "$PEAK" | cut -d' ' -f2)
  if [ "${TURNS:-0}" -eq 0 ] || [ "${OBS:-0}" -eq 0 ]; then
    unver "C  no Haiku turns found in ~/.claude/projects — the peak premise is UNMEASURED on this machine, not clear."
  else
    PCT=$(awk -v o="$OBS" -v t="$P200" 'BEGIN{printf "%.1f", 100*o/t}')
    note "observed peak $OBS over $TURNS Haiku turns = ${PCT}% of threshold($P)  [XACA-1277-005 baseline peak: $BASE_HAIKU_PEAK / N=194]"
    # Trip on MOVEMENT from the recorded baseline, not on a fixed fraction of
    # the threshold. The margin at rest is only 11.5% ($BASE_HAIKU_PEAK vs
    # $P200), so an 85%-of-threshold warn would fire on day one and every day
    # after — a warning that is always on carries no information. What this
    # ratchet actually needs to notice is the peak CREEPING UP, which is the
    # workload shift XACA-1277-005's N=194 could not rule out.
    OVER=$(awk -v o="$OBS" -v t="$P200" 'BEGIN{print (o>=t)?"1":"0"}')
    GREW=$(awk -v o="$OBS" -v b="$BASE_HAIKU_PEAK" 'BEGIN{print (o>b)?"1":"0"}')
    NEAR=$(awk -v o="$OBS" -v t="$P200" 'BEGIN{print (o>=0.95*t)?"1":"0"}')
    if [ "$OVER" = "1" ]; then
      fail "C  Haiku peak has REACHED threshold($P) — P=$P now compacts Haiku sessions early. Raise P, or stop applying the override to 200K-tier work."
    elif [ "$NEAR" = "1" ]; then
      fail "C  Haiku peak is within 5% of threshold($P). Treat as drift: the margin XACA-1277-005 cleared P=$P on has effectively gone."
    elif [ "$GREW" = "1" ]; then
      warn "C  Haiku peak has GROWN past the XACA-1277-005 baseline ($BASE_HAIKU_PEAK -> $OBS). Still under threshold($P), but the 'Haiku structurally tops out near 80K' reading is weakening — re-run 005's analysis and re-record the baseline."
    else
      pass "C  Haiku peak has not grown past the XACA-1277-005 baseline (margin to threshold($P): $((P200-OBS)) tokens)"
    fi
  fi
fi
echo

fi   # C threshold available

# ── D. Entrypoint premise ───────────────────────────────────────────────────
echo "D. CLAUDE_CODE_ENTRYPOINT premise (remote_cowork / local-agent)"
note "Under those entrypoints Sonnet 5 may map to a 500,000 window; at P=50 that"
note "is 240,000 against observed Sonnet subagent peaks near 920K — a severe"
note "regression. XACA-1277-005's clearance is CONDITIONAL on neither appearing."
case "${CLAUDE_CODE_ENTRYPOINT:-}" in
  remote_cowork|local-agent)
    fail "D1 CLAUDE_CODE_ENTRYPOINT is currently '$CLAUDE_CODE_ENTRYPOINT' — the clearance is void for this shell." ;;
  *) pass "D1 CLAUDE_CODE_ENTRYPOINT is '${CLAUDE_CODE_ENTRYPOINT:-<unset>}' (not a gated value)" ;;
esac
EP=$(python3 - <<'PY' 2>/dev/null
import glob, json, os, collections
root = os.path.expanduser("~/.claude/projects")
c = collections.Counter(); n = 0
KEYS = ("entrypoint", "claudeCodeEntrypoint", "CLAUDE_CODE_ENTRYPOINT")
for path in glob.iglob(os.path.join(root, "**", "*.jsonl"), recursive=True):
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                if "ntrypoint" not in line: continue
                try: d = json.loads(line)
                except Exception: continue
                if not isinstance(d, dict): continue
                for k in KEYS:
                    if k in d:
                        c[str(d[k])] += 1; n += 1
    except Exception:
        pass
print(n)
for v, k in c.most_common(20):
    print("%s\t%d" % (v, k))
PY
)
if [ -z "$EP" ]; then
  unver "D2 transcript entrypoint scan failed — cannot confirm this machine still emits only the cleared values."
else
  TOTAL=$(printf '%s\n' "$EP" | head -1)
  if [ "${TOTAL:-0}" -eq 0 ]; then
    unver "D2 no entrypoint-bearing records found — the premise is unmeasured, not clear."
  else
    note "observed over $TOTAL records on THIS machine:"
    printf '%s\n' "$EP" | tail -n +2 | while IFS=$'\t' read -r v k; do note "  $v  ($k)"; done
    if printf '%s\n' "$EP" | tail -n +2 | grep -qE '^(remote_cowork|local-agent)\b'; then
      fail "D2 a gated entrypoint has APPEARED in this machine's transcripts — re-derive the Sonnet window before leaving P=$P in place."
    else
      pass "D2 only cleared entrypoint values observed"
    fi
  fi
fi

echo
case "$RC" in
  0) echo "RESULT: all XACA-1277 premises hold (rc=0)" ;;
  1) echo "RESULT: a premise has DRIFTED (rc=1) — re-open the XACA-1277 decision before trusting claude/MODEL_SELECTION.md §5."
     [ "$UNVER_N" -gt 0 ] && echo "        NOTE: $UNVER_N check(s) ALSO could not be verified this run — rc=1 takes precedence over rc=2, so the exit code alone does not show them. Read the COULD NOT VERIFY lines above; the drift below may not be the whole story." ;;
  2) echo "RESULT: COULD NOT VERIFY (rc=2) — this is a failure, not a pass. Do not read it as 'premises hold'." ;;
esac
exit "$RC"
