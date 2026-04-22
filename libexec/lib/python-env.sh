#!/bin/sh
# python-env.sh — Resolves AITEAMFORGE_PYTHON for libexec scripts.
# Safe to source repeatedly (idempotent guard at top).
#
# After this file is sourced, AITEAMFORGE_PYTHON is set to one of:
#   1. $HOMEBREW_PREFIX/var/aiteamforge/venv/bin/python3  (tap-owned venv, preferred)
#   2. python3 from PATH  (fallback, with one-time warning to stderr)
#
# See docs/python-dep-channel-design.md for the full design rationale.

# Idempotent guard — if already resolved, bail out immediately.
[ -n "${AITEAMFORGE_PYTHON:-}" ] && return 0 2>/dev/null || true

# Try to locate env.sh in priority order: $HOMEBREW_PREFIX first, then
# common default prefixes for Apple Silicon and Intel Macs.
for _atf_prefix in "${HOMEBREW_PREFIX:-}" "/opt/homebrew" "/usr/local"; do
    [ -z "$_atf_prefix" ] && continue
    if [ -f "$_atf_prefix/var/aiteamforge/env.sh" ]; then
        # shellcheck source=/dev/null
        . "$_atf_prefix/var/aiteamforge/env.sh"
        unset _atf_prefix
        return 0 2>/dev/null || true
    fi
done
unset _atf_prefix

# No env.sh found — venv not provisioned (dev-mode clone, non-Homebrew install,
# or post_install not yet run).  Fall back to bare python3 with a one-time warning.
export AITEAMFORGE_PYTHON="${AITEAMFORGE_PYTHON:-python3}"
if [ "${_ATF_VENV_WARNED:-}" != "1" ]; then
    echo "aiteamforge: WARNING: tap-owned Python venv not found; using system python3" \
         "(run: brew reinstall aiteamforge)" >&2
    export _ATF_VENV_WARNED=1
fi
