#!/usr/bin/env bash
# kb-live-config-drift-check.sh
#
# Detects drift between the TRACKED deploy sources (claude/, claude-hooks/, ...)
# and the LIVE copies they deploy to (~/.claude/...), plus staleness of the
# installed git hooks.
#
# WHY THIS EXISTS (XACA-0208 follow-up, 2026-09-09):
#   XACA-0208 automated tracked -> live via a post-merge hook. Nothing ever
#   watched the reverse direction. Measured on this machine: the live
#   ~/.claude/CLAUDE.md carried XACA-0822 and XACA-1122 edits that existed
#   nowhere in git, and the installed post-merge + pre-commit hooks were both
#   stale — the installed post-merge was the revision that fails SILENTLY when
#   its deploy script is missing, while the tracked source had been fixed to
#   warn. None of it was visible to anyone.
#
#   CI STRUCTURALLY CANNOT CATCH THIS CLASS. deploy-sources-check.yml verifies
#   that deploy-to-production.sh's source paths exist, and it passes — but the
#   live copy does not exist on a GitHub runner, so no workflow can ever compare
#   them. A local session-start check is the only layer with visibility.
#
# EXIT CODES (meaningful for direct/CI use):
#   0  no drift
#   1  drift detected (live differs from tracked, and/or hooks stale)
#   2  could not run the comparison (no dev checkout AND no installed tap templates)
#
# TWO MODES, picked by sentinel files (XACA-1753-006), never by path guessing:
#   dev       deploy-to-production.sh exists at the repo root (KB_LIVE_DRIFT_REPO,
#             else this script's own checkout, else ~/dev-team): tracked sources
#             vs live. M3Pro.
#   consumer  no dev checkout, but the installed tap ships claude/settings.json.template
#             (KB_LIVE_DRIFT_TEMPLATES, else <framework_home>/share/templates from
#             $AITEAMFORGE_DIR/.aiteamforge-config, $AITEAMFORGE_HOME, the brew opt
#             path, then the setup-seeded $AITEAMFORGE_DIR/templates): the templates,
#             rendered the way install-claude-config.sh renders them, vs live. For
#             settings.json only template-declared hook commands/keys that are MISSING
#             or DIFFERENT in live count; box-local live-only keys are never reported
#             (merge_settings_json unions them on purpose).
#
# Never mutates anything. Never prescribes a direction: this script does not
# know whether live or tracked is correct. It reports, a human decides.
#
# Usage:
#   scripts/kb-live-config-drift-check.sh          human-readable report
#   scripts/kb-live-config-drift-check.sh --quiet  exit code only
#   scripts/kb-live-config-drift-check.sh --ack    record the CURRENT divergence
#                                                  as an accepted baseline

set -u

QUIET=false
ACK=false
case "${1:-}" in
    --quiet) QUIET=true ;;
    --ack)   ACK=true ;;
    --help|-h) sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) echo "Error: unknown argument: $1" >&2; exit 2 ;;
esac

ACK_FILE="${KB_LIVE_DRIFT_ACK:-$HOME/.claude/.live-drift-ack}"
MARKER="${KB_LIVE_DRIFT_MARKER:-$HOME/.claude/.live-drift-marker}"
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
# Install dir: the session env if it says so; else, when this checker is the
# INSTALLED copy (<AF>/scripts/), the dir that holds it -- a non-default install
# that does not export AITEAMFORGE_DIR to sessions must not render every
# template against the wrong root (XACA-1753-016); else the default.
if [ -n "${AITEAMFORGE_DIR:-}" ]; then
    AF="$AITEAMFORGE_DIR"
elif [ -n "$SELF_DIR" ] && [ -r "$SELF_DIR/../.aiteamforge-config" ]; then
    # Prefer the default spelling when it IS this dir: the installer rendered the
    # templates with that path, and the guard may reach us via a resolved symlink
    # (/var -> /private/var on macOS), which would otherwise read as drift.
    if [ "$HOME/aiteamforge" -ef "$SELF_DIR/.." ]; then AF="$HOME/aiteamforge"
    else AF="$(cd "$SELF_DIR/.." && pwd)"; fi
else
    AF="$HOME/aiteamforge"
fi
CCD="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# ── pick the mode from evidence ───────────────────────────────────────────────
MODE=""; REPO=""; TPL=""; LOOKED=""
if [ -n "${KB_LIVE_DRIFT_REPO:-}" ]; then
    # Explicit dev request: it must be valid, never silently fall through to consumer.
    REPO="$KB_LIVE_DRIFT_REPO"
    [ -d "$REPO" ] || { $QUIET || echo "kb-live-config-drift-check: repo not found: $REPO" >&2; exit 2; }
    [ -r "$REPO/deploy-to-production.sh" ] || { $QUIET || echo "kb-live-config-drift-check: cannot read $REPO/deploy-to-production.sh" >&2; exit 2; }
    MODE=dev
else
    for c in "$SELF_DIR/.." "$HOME/dev-team"; do
        LOOKED="$LOOKED $c/deploy-to-production.sh"
        if [ -r "$c/deploy-to-production.sh" ]; then REPO="$(cd "$c" && pwd)"; MODE=dev; break; fi
    done
fi
if [ -z "$MODE" ]; then
    FH=""
    [ -r "$AF/.aiteamforge-config" ] && FH=$(sed -n 's/.*"framework_home"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$AF/.aiteamforge-config" | head -1)
    for c in "${KB_LIVE_DRIFT_TEMPLATES:-}" "${FH:+$FH/share/templates}" "${AITEAMFORGE_HOME:+$AITEAMFORGE_HOME/share/templates}" \
             "${HOMEBREW_PREFIX:-/opt/homebrew}/opt/aiteamforge/libexec/share/templates" "$AF/templates"; do
        [ -n "$c" ] || continue
        LOOKED="$LOOKED $c/claude/settings.json.template"
        if [ -r "$c/claude/settings.json.template" ]; then TPL="$c"; MODE=consumer; break; fi
    done
fi
if [ -z "$MODE" ]; then
    $QUIET || echo "kb-live-config-drift-check: could not check: no dev checkout and no installed tap templates (looked in:$LOOKED)" >&2
    exit 2
fi
DEPLOY="$REPO/deploy-to-production.sh"
[ "$MODE" = dev ] && REF="$REPO" || REF="$TPL"

# ── collect divergences ───────────────────────────────────────────────────────
# The SOURCE resolves against $REPO and the DEST against $HOME. They are
# different roots; expanding the source against $HOME is wrong the moment
# $HOME/dev-team is not this checkout, and it fails silently (nothing matches,
# the check reports clean). Derive the repo-relative path, then rebuild.
DRIFTED=""
CONTENT_FP=""
DRIFT_N=0
while IFS= read -r line; do
    set -- $line
    src="${2:-}"; dest="${3:-}"
    [ -n "$src" ] && [ -n "$dest" ] || continue
    rel="${src#\~/}"; rel="${rel#*/}"
    src="$REPO/$rel"
    dest="${dest/#\~/$HOME}"
    [ -f "$src" ] || continue
    if [ ! -f "$dest" ]; then
        DRIFTED="${DRIFTED}  MISSING live: $dest  (tracked: $rel)"$'\n'
        CONTENT_FP="${CONTENT_FP}missing:$rel"$'\n'
        DRIFT_N=$((DRIFT_N + 1))
        continue
    fi
    if ! cmp -s "$src" "$dest"; then
        n=$(diff "$src" "$dest" 2>/dev/null | grep -c '^[<>]' || true)
        DRIFTED="${DRIFTED}  $rel  <->  $dest  (${n} differing line(s))"$'\n'
        # Fingerprint the CONTENT of the difference, not merely the file name and
        # line count. Counting alone is not identity: two entirely different
        # edits of the same size produce the same count, so an --ack of one would
        # silently suppress the other. Caught by negative control (iv), which
        # returned a reassuring exit 0 for drift that had completely changed —
        # the precise failure mode --ack exists to avoid creating.
        CONTENT_FP="${CONTENT_FP}$(diff "$src" "$dest" 2>/dev/null | cksum)"$'\n'
        DRIFT_N=$((DRIFT_N + 1))
    fi
done < <([ "$MODE" = dev ] && grep -E '^deploy_file ' "$DEPLOY" 2>/dev/null || true)

# ── consumer mode: rendered tap templates vs live ─────────────────────────────
# Renders with the installer's OWN apply_template (sourced in a subshell) so the
# substitution cannot drift from what install-claude-config.sh writes; the inline
# sed is a byte-for-byte mirror used only when the installer is not found.
_render() {
    (   export AITEAMFORGE_DIR="$AF" CLAUDE_CONFIG_DIR="$CCD" TEMPLATE_DIR="$TPL" USER="${USER:-$(id -un)}"
        inst="$(dirname "$TPL")/../libexec/installers/install-claude-config.sh"
        [ -f "$inst" ] && . "$inst" >/dev/null 2>&1
        if type apply_template >/dev/null 2>&1; then apply_template "$1" "$2" >/dev/null 2>&1
        else sed -e "s|{{AITEAMFORGE_DIR}}|$AF|g" -e "s|{{HOME}}|$HOME|g" \
                 -e "s|{{CLAUDE_CONFIG_DIR}}|$CCD|g" -e "s|{{USER}}|$USER|g" "$1" > "$2"; fi )
}
_note() { DRIFTED="${DRIFTED}  $1"$'\n'; CONTENT_FP="${CONTENT_FP}$1"$'\n'; DRIFT_N=$((DRIFT_N + 1)); }
if [ "$MODE" = consumer ]; then
    command -v jq >/dev/null 2>&1 || { $QUIET || echo "kb-live-config-drift-check: could not check: jq is required for settings.json comparison" >&2; exit 2; }
    CTMP="$(mktemp "${TMPDIR:-/tmp}/kb-drift.XXXXXX")" || exit 2
    trap 'rm "$CTMP"' EXIT
    for pair in settings.json.template:settings.json claude-md-global.template:CLAUDE.md \
                statusline-command.sh:statusline-command.sh agent-tracking.sh:agent-tracking.sh; do
        tmpl="$TPL/claude/${pair%%:*}"; live="$CCD/${pair##*:}"
        [ -f "$tmpl" ] || continue
        if ! _render "$tmpl" "$CTMP" || [ ! -s "$CTMP" ]; then
            $QUIET || echo "kb-live-config-drift-check: could not check: rendering $tmpl failed" >&2; exit 2
        fi
        if [ ! -f "$live" ]; then _note "MISSING live: $live  (template: ${pair%%:*})"; continue; fi
        if [ "${pair##*:}" = settings.json ]; then
            out=$(jq -r -n --slurpfile t "$CTMP" --slurpfile l "$live" '
                ($t[0]) as $T | ($l[0]) as $L |
                [($T.hooks // {}) | to_entries[] | .key as $ev | .value[]? | .hooks[]? | select(.command != null) | {ev: $ev, c: .command}] as $th |
                [($L.hooks // {}) | to_entries[] | .key as $ev | .value[]? | .hooks[]? | select(.command != null) | $ev + "\u0001" + .command] as $lh |
                ($th[] | . as $h | select(($lh | index($h.ev + "\u0001" + $h.c)) == null) | "hook missing from live: \($h.ev): \($h.c)"),
                ([$T | paths(scalars)] | map(select(all(.[]; type == "string") and .[0] != "hooks")) | .[] as $p |
                    ($T | getpath($p)) as $tv | (try ($L | getpath($p)) catch null) as $lv |
                    select($tv != null and $tv != $lv) | (if $lv == null then "key missing from live: \($p | join(".")) (template=\($tv | tojson))" else "key differs: \($p | join(".")) (template=\($tv | tojson) live=\($lv | tojson))" end))' 2>&1) \
                || { $QUIET || echo "kb-live-config-drift-check: could not check: $live is not comparable JSON: $out" >&2; exit 2; }
            while IFS= read -r l; do [ -n "$l" ] && _note "settings.json: $l"; done <<EOF
$out
EOF
        elif ! cmp -s "$CTMP" "$live"; then
            _note "${pair%%:*} (rendered)  <->  $live  ($(diff "$CTMP" "$live" 2>/dev/null | grep -c '^[<>]' || true) differing line(s); fingerprint $(diff "$CTMP" "$live" 2>/dev/null | cksum))"
        fi
    done
fi

# ── installed git hooks vs tracked ────────────────────────────────────────────
HOOKS_STALE=""
if [ "$MODE" = dev ] && [ -x "$REPO/scripts/install-git-hooks.sh" ]; then
    HOOKS_STALE=$("$REPO/scripts/install-git-hooks.sh" --check 2>/dev/null | grep '^drift:' || true)
fi

# ── a fingerprint of the CURRENT divergence, so an accepted state stays quiet ──
# Without this the report fires every session on a known, in-flight divergence
# and is ignored inside a week — the failure mode of every warning nobody scoped.
FP=$(printf '%s|%s|%s' "$DRIFTED" "$CONTENT_FP" "$HOOKS_STALE" | cksum | awk '{print $1}')

if [ "$ACK" = true ]; then
    mkdir -p "$(dirname "$ACK_FILE")"
    printf '%s\n' "$FP" > "$ACK_FILE"
    echo "Recorded current config-drift state as accepted (fingerprint $FP)."
    echo "You will be warned again only when the drift CHANGES."
    exit 0
fi

ACKED=""
[ -r "$ACK_FILE" ] && ACKED=$(head -1 "$ACK_FILE" 2>/dev/null || true)

HAVE_MARKER=false
[ -s "$MARKER" ] && HAVE_MARKER=true

if [ "$DRIFT_N" -eq 0 ] && [ -z "$HOOKS_STALE" ] && [ "$HAVE_MARKER" = false ]; then
    $QUIET || echo "✓ live config matches tracked; installed hooks current."
    exit 0
fi

# An unchanged, already-acknowledged state is not news — unless post-merge left
# a marker, which always means real edits were overwritten and must be reviewed.
if [ "$FP" = "$ACKED" ] && [ "$HAVE_MARKER" = false ]; then
    $QUIET || echo "✓ config drift unchanged from the accepted baseline (fingerprint $FP)."
    exit 0
fi

if [ "$QUIET" = true ]; then exit 1; fi

echo ""
echo "────────────────────────────────────────────────────────────"
echo " ⚠ LIVE CONFIG DRIFT (XACA-0208 follow-up)"
echo "────────────────────────────────────────────────────────────"
if [ "$HAVE_MARKER" = true ]; then
    echo ""
    echo " A post-merge deploy OVERWROTE live edits that were not in git."
    echo " Copies were preserved. Review them before they are forgotten:"
    sed 's/^/   /' "$MARKER"
    echo "   (clear this notice with:  rm $MARKER )"
fi
if [ "$DRIFT_N" -gt 0 ]; then
    echo ""
    echo " $DRIFT_N item(s) differ between tracked and live ($MODE mode, source: $REF):"
    printf '%s' "$DRIFTED"
    echo ""
    if [ "$MODE" = dev ]; then
        echo " The live copy is a DEPLOY TARGET, not a place to author changes."
        echo " Anything only in live is lost on the next pull that touches it."
        echo " Reconcile toward claude/ and commit, or accept this state with:"
    else
        echo " Compared against the installed tap templates; live-only keys are not reported."
        echo " Review which side is right, or accept this state with:"
    fi
    echo "   $SELF_DIR/kb-live-config-drift-check.sh --ack"
fi
if [ -n "$HOOKS_STALE" ]; then
    echo ""
    echo " Installed git hooks are stale (a stale hook can fail silently):"
    printf '%s\n' "$HOOKS_STALE" | sed 's/^/   /'
    echo "   Fix: $REPO/scripts/install-git-hooks.sh"
fi
echo "────────────────────────────────────────────────────────────"
echo ""
exit 1
