#!/bin/bash
# msg-client-deps.sh
# DoubleNode Dev-Team Infrastructure (AITeamForge)
#
# XACA-1225-001: idempotent, fail-soft installer for the kb-msg Tier-2 sealed-
# relay client's Node dependency (libsodium-wrappers), shared VERBATIM between
# install-shell.sh (fresh installs) and aiteamforge-upgrade.sh (already-
# provisioned machines) so the two paths can never drift out of sync with each
# other — the exact install-only-reaches-fresh-installs bug class this repo
# has hit before (XACA-0747/0751/0814/1078-004; see also
# feedback_install_time_provisioning_unreachable_from_upgrade.md).
#
# ROOT CAUSE (measured on M1Mini 2026-09-14, fresh tap v0.20.13, fleet=skip):
# install-shell.sh's install_helper_scripts() ships
# ~/aiteamforge/scripts/{msg-client.js,vault-keygen.js,package.json,
# package-lock.json}, but no installer ever ran `npm ci` there. The only
# `npm ci` anywhere in the tap is install-fleet-monitor.sh's Fleet Monitor
# SERVER install, which a fleet=skip consumer never reaches. kb-msg-provision
# then runs `node vault-keygen.js` DIRECTLY — bypassing msg-client.sh's own
# lazy-bootstrap-with-cooldown (msg-client.sh's bootstrap only fires when
# msg-client.sh itself is invoked, e.g. by fleet-reporter.sh's pull_messages())
# — and dies with "Cannot find module 'libsodium-wrappers'".
#
# Call sites:
#   - install-shell.sh: install_shell_environment(), right after
#     install_helper_scripts() lays the files down (fresh install).
#   - aiteamforge-upgrade.sh: update_msg_client_deps(), wired into the main
#     run sequence right after update_runtime_helpers() and right before
#     provision_msg_routing() — the exact call that fails today without this
#     step ever having run (already-provisioned machines).
#
# Must tolerate BOTH callers' shell strictness: install-kanban.sh-family
# scripts run `set -euo pipefail`; aiteamforge-upgrade.sh runs `set -eo
# pipefail` (no -u, but still `set -e`). Never end a function here on a bare
# `[[ cond ]] && cmd` — under `set -e` that silently aborts the CALLING
# script's entire run when cond is false
# (feedback_set_e_last_line_short_circuit.md) — every branch below returns
# explicitly via an `if`/`return 0`, never via `&&` short-circuit.

# _aitf_consumer_datafiles: the non-executed require()/import payload that
# must ship alongside the executable helper scripts in
# $AITEAMFORGE_DIR/scripts/ on EVERY consumer box — msg-client.js's and
# vault-fetch.js's require()'d siblings, plus the package manifest/lockfile
# that anchors provision_msg_client_node_deps()'s `npm ci` above.
#
# XACA-1322-001: previously this exact five-name list was hand-duplicated in
# install-shell.sh's install_helper_scripts() (fresh installs) only.
# aiteamforge-upgrade.sh's update_runtime_helpers() never re-shipped it (its
# sweep targets *.sh/*.py, plus a vault-fetch.js-only special case) — so an
# upgraded box could end up with a NEW vault-fetch.js next to a STALE
# vault-keygen.js, e.g. vault-fetch.js calling a function
# (kg.resolveFleetUrl) that the old sibling doesn't define yet, and `cc`
# crashing with a TypeError at the require() boundary. This function is now
# the ONE place either caller reads the list from, so they can never drift
# apart again — same "shared source of truth" discipline this file already
# applies to provision_msg_client_node_deps() itself (see the file header).
#
# Call sites:
#   - install-shell.sh: install_helper_scripts()'s datafile loop (fresh
#     install).
#   - aiteamforge-upgrade.sh: update_runtime_helpers()'s datafile loop
#     (XACA-1322-002; replaces the vault-fetch.js-only XACA-1312 special
#     case) — already-provisioned machines, on upgrade.
#
# Style/compat: heredoc-to-stdout, mirroring
# _xaca0673_mandatory_materialize_basenames() in aiteamforge-upgrade.sh —
# bash 3.2 safe (no associative arrays, no mapfile), safe to source twice
# (plain function definition, no top-level side effects), and consumable
# with either `for f in $(_aitf_consumer_datafiles)` (word-splits on
# whitespace/newlines; every entry here is a bare filename with no spaces or
# glob metacharacters) or `case $'\n'"$(_aitf_consumer_datafiles)"$'\n' in`
# for a membership test.
_aitf_consumer_datafiles() {
  cat <<'EOF'
msg-client.js
vault-keygen.js
vault-fetch.js
package.json
package-lock.json
EOF
}

# Compute a cheap, portable content stamp for package-lock.json so repeat
# upgrades skip a reinstall unless the shipped lockfile actually changed.
# shasum/sha256sum preferred (content-addressed, both ship on stock macOS);
# falls back to size+mtime on a box with neither — a weaker but still
# functional change detector, never a hard failure.
_xaca1225_lockfile_stamp() {
  local f="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'
  else
    local sz mt
    sz=$(wc -c <"$f" 2>/dev/null | tr -d ' ')
    mt=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "")
    printf 'sz%s-mt%s' "$sz" "$mt"
  fi
}

# provision_msg_client_node_deps <scripts_dir> [dry_run]
#
# <scripts_dir>: directory containing the shipped msg-client.js/vault-keygen.js/
#   package.json/package-lock.json (normally $AITEAMFORGE_DIR/scripts, the
#   flattened tap-consumer layout — see msg-client.sh's own SCRIPT_DIR
#   resolution for why these files are always siblings on a consumer box).
# [dry_run]: "true" to preview only, never invokes npm. Defaults to
#   ${DRY_RUN:-false} so aiteamforge-upgrade.sh's own --dry-run flag is
#   honoured for free without every call site having to thread it through.
#
# ALWAYS returns 0 — every failure mode here (files not shipped, no node/npm
# on PATH, a network failure, npm exiting non-zero) is fail-soft: this must
# never abort `aiteamforge setup` or `aiteamforge upgrade`. A missing Node.js
# only disables cross-machine kb-msg (Tier 2, sealed relay) — same-machine
# kb-msg (Tier 1) is unaffected. Callers that need to know whether deps ended
# up installed should test scripts_dir/node_modules/libsodium-wrappers
# themselves rather than trusting this function's exit code for that.
provision_msg_client_node_deps() {
  local scripts_dir="${1:?provision_msg_client_node_deps: scripts_dir required}"
  local dry_run="${2:-${DRY_RUN:-false}}"

  local lockfile="$scripts_dir/package-lock.json"
  local pkgjson="$scripts_dir/package.json"
  local node_modules_dir="$scripts_dir/node_modules"
  local stamp_file="$node_modules_dir/.xaca1225-lockfile-stamp"

  # Nothing shipped to this box yet (older tap install predating XACA-0777,
  # or a layout that never received the msg-client files) — silent no-op,
  # not an error: there is nothing to provision deps FOR.
  if [ ! -f "$lockfile" ] || [ ! -f "$pkgjson" ]; then
    return 0
  fi

  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "Note: Node.js/npm not found on PATH — skipping kb-msg client dependency install." >&2
    echo "      Cross-machine kb-msg (Tier 2, sealed relay) will be unavailable until Node.js >= 18 is installed; same-machine kb-msg is unaffected." >&2
    return 0
  fi

  local current_stamp
  current_stamp="$(_xaca1225_lockfile_stamp "$lockfile")"

  # Skip reinstalling on every nightly upgrade unless the shipped lockfile
  # actually changed since the last successful install.
  if [ -d "$node_modules_dir/libsodium-wrappers" ] && [ -f "$stamp_file" ]; then
    local prior_stamp
    prior_stamp="$(cat "$stamp_file" 2>/dev/null || echo "")"
    if [ -n "$current_stamp" ] && [ "$prior_stamp" = "$current_stamp" ]; then
      return 0
    fi
  fi

  if [ "$dry_run" = "true" ]; then
    echo "Would run: npm ci --omit=dev (kb-msg client Node deps) in $scripts_dir"
    return 0
  fi

  echo "Installing kb-msg client Node dependencies (npm ci --omit=dev) in $scripts_dir..."
  if ( cd "$scripts_dir" && npm ci --omit=dev --silent >/dev/null 2>&1 ); then
    # npm ci recreates node_modules from scratch, so the stamp can only be
    # written AFTER a successful install (writing it earlier would survive
    # npm ci's own directory wipe and lie about what's actually installed).
    if mkdir -p "$node_modules_dir" 2>/dev/null; then
      printf '%s' "$current_stamp" >"$stamp_file" 2>/dev/null || true
    fi
    echo "kb-msg client Node dependencies installed."
    return 0
  fi

  # Fail soft: a network hiccup or a stale registry cache are both plausible
  # and recoverable later — never abort setup/upgrade over this.
  echo "Warning: npm ci failed for kb-msg client deps in $scripts_dir." >&2
  echo "         Cross-machine kb-msg (Tier 2, sealed relay) will be unavailable until this is resolved by hand:" >&2
  echo "         (cd \"$scripts_dir\" && npm ci --omit=dev)" >&2
  return 0
}
