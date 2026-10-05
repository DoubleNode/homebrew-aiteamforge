#!/bin/bash
# atomic-write.sh
# XACA-1240: install an executable script by temp-file + rename, never in place.
#
# WHY: `cmd > "$dst"` and `cp src dst` onto an EXISTING file truncate and
# rewrite the SAME inode. If $dst is the script currently executing (auto-
# upgrade.sh and cellar-watch-trigger.sh both run `aiteamforge upgrade`), bash
# resumes reading at its old byte offset inside the new content and dies with a
# syntax error. rename(2) swaps in a NEW inode; the running process keeps its
# open fd on the old one and finishes cleanly.

if [[ -n "${_AITF_ATOMIC_WRITE_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_AITF_ATOMIC_WRITE_LOADED=1

# _aitf_atomic_write_script <dst> <cmd> [args...]
#   Runs <cmd> with its stdout captured into a temp file created in dst's own
#   directory (same filesystem, so the final mv is a true atomic rename), sets
#   the mode (dst's existing mode if present, else 755; then +x), and mv -f's it
#   over <dst>. On any failure the temp file is removed, <dst> is untouched and
#   the return is non-zero. Empty output is NOT an error: callers that need that
#   check do it themselves (this mirrors the redirect it replaces).
#   Examples:  _aitf_atomic_write_script "$dst" sed -e 's|a|b|' "$src"
#              _aitf_atomic_write_script "$dst" cat "$src"
_aitf_atomic_write_script() {
    local dst="$1"; shift
    local tmp mode=""
    tmp="$(mktemp "$(dirname "$dst")/.$(basename "$dst").XXXXXX" 2>/dev/null)" || return 1
    if ! "$@" > "$tmp"; then
        rm -f "$tmp"; return 1
    fi
    if [ -f "$dst" ]; then
        mode="$(stat -f '%Lp' "$dst" 2>/dev/null)"        # BSD / macOS
        case "$mode" in ''|*[!0-7]*) mode="$(stat -c '%a' "$dst" 2>/dev/null)" ;; esac  # GNU
        case "$mode" in ''|*[!0-7]*) mode="" ;; esac
    fi
    if ! chmod "${mode:-755}" "$tmp" || ! chmod +x "$tmp" || ! mv -f "$tmp" "$dst"; then
        rm -f "$tmp"; return 1
    fi
    return 0
}
