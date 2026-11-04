#!/bin/bash
# installed-version.sh
# XACA-1102: ONE writer for the working-dir ".installed-version" stamp, plus the
# one-time backfill for boxes provisioned before the installer wrote it.
#
# Why this exists: the stamp used to be written ONLY by `aiteamforge upgrade`, so
# a box that was installed and never upgraded had no stamp, and every reader had
# to guess from weaker sources. The installer, the upgrade flow and the backfill
# now all go through aitf_write_installed_version.
#
# Contract for every function here: never abort the caller (safe under `set -e`),
# bash 3.2 compatible.

if [[ -n "${_AITF_INSTALLED_VERSION_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
_AITF_INSTALLED_VERSION_LOADED=1

# aitf_write_installed_version <dir> <version>
#   Atomically writes "<version>\n" to <dir>/.installed-version (temp file in the
#   same dir, then mv). Returns non-zero (writing nothing) if <dir> is missing,
#   the token does not look like a version, or the write fails.
aitf_write_installed_version() {
  local dir="${1:-}" ver="${2:-}" tmp
  # Digits and dots, optional suffix (brew revision "0.20.3_1", "1.2.3-rc1", "+meta").
  # Regex held in a variable: required for bash 3.2 =~ portability.
  local re='^[0-9]+(\.[0-9]+)*([_+-][0-9A-Za-z._+-]+)?$'
  # Trim only LEADING/TRAILING whitespace: an embedded newline or space must be
  # rejected by the regex, not squashed ("0.1.0\n0.2.0" must not become 0.1.00.2.0).
  ver="${ver#"${ver%%[![:space:]]*}"}"
  ver="${ver%"${ver##*[![:space:]]}"}"
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  # A directory at the stamp path would make `mv` move the temp file INTO it.
  [ -d "${dir}/.installed-version" ] && return 1
  [[ "$ver" =~ $re ]] || return 1
  tmp="$(mktemp "${dir}/.installed-version.XXXXXX" 2>/dev/null)" || return 1
  if printf '%s\n' "$ver" > "$tmp" 2>/dev/null && chmod 644 "$tmp" 2>/dev/null \
     && mv -f "$tmp" "${dir}/.installed-version" 2>/dev/null; then
    return 0
  fi
  [ -e "$tmp" ] && { rm "$tmp" 2>/dev/null || true; }
  return 1
}

# aitf_backfill_installed_version
#   One-time seed of a missing stamp from the legacy .aiteamforge-config
#   "version" value. That value is the version the working dir was INSTALLED at,
#   which is the truth on a box that was never upgraded. It is NEVER seeded from
#   the brew version (that would hide real working-dir drift), never overwrites
#   an existing NON-EMPTY stamp, and writes nothing if the config has no valid version.
#
#   THIS IS THE ONLY REMAINING READER THAT USES THE CONFIG "version" AS A VERSION
#   ANSWER (XACA-1102-012 retired it as a fallback in get_installed_version and
#   fleet-reporter.sh; validate-install.sh only prints it as a field-presence
#   check). Do not add another.
#
#   Silent on stdout, at most one stderr line, always returns 0.
aitf_backfill_installed_version() {
  local dir="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
  local cfg="${dir}/.aiteamforge-config" v=""
  [ -d "$dir" ] || return 0
  # -s, not -e: a zero-byte stamp is as good as none and must be repaired.
  [ -s "${dir}/.installed-version" ] && return 0
  [ -d "${dir}/.installed-version" ] && return 0
  [ -f "$cfg" ] || return 0

  if command -v jq >/dev/null 2>&1; then
    v="$(jq -r '.version // empty' "$cfg" 2>/dev/null | head -n1 || true)"
  else
    v="$(grep '"version"' "$cfg" 2>/dev/null | sed -E 's/.*"version": *"?([^",}]+)"?.*/\1/' | head -n1 || true)"
  fi
  v="$(printf '%s' "$v" | tr -d '[:space:]' | sed 's/^v//' || true)"
  [ -n "$v" ] || return 0

  if aitf_write_installed_version "$dir" "$v"; then
    echo "aiteamforge: stamped working-dir version ${v} (from install config)" >&2
  fi
  return 0
}
