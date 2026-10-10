#!/usr/bin/env bash
# install-imessage-relay.sh - install / remove the iMessage relay LaunchAgent
# (XACA-1402-011, EPIC-0068, design doc section 2.3).
#
#   bash install-imessage-relay.sh install [--opt-in] [--dry-run]
#   bash install-imessage-relay.sh uninstall [--dry-run]
#   bash install-imessage-relay.sh status
#
# Run it as the consuming user, in the GUI session. NOT with sudo: Messages lives in the
# user's GUI session, so this is a LaunchAgent (~/Library/LaunchAgents), never a daemon.
#
# OPT-IN ONLY. `install` proceeds only when ALL are true:
#   1. this is not the dev-team source machine (hard refusal, no override);
#   2. the operator opted in: --opt-in, or an interactive "y" at the prompt. Without a
#      TTY and without --opt-in it refuses (exit 4), so nothing installs by accident;
#   3. a Node 18+ binary exists (command -v node, /opt/homebrew/bin/node, /usr/local/bin/node);
#   4. `node imessage-relay.js probe` exits 0 (Messages has an enabled iMessage account).
#      Probe exit 3 = not capable (exit 3 here); any other failure exits 1.
# A refusal changes nothing on disk.
#
# WHAT INSTALL DOES (idempotent: a re-run IS the upgrade)
#   1. copies imessage-relay.js into $AITEAMFORGE_DIR/scripts/ (next to vault-keygen.js,
#      which the relay requires; msg-client's install already puts that file there);
#   2. renders imessage-relay.template.plist -> ~/Library/LaunchAgents/
#      com.aiteamforge.imessage-relay.plist, plutil -lint checked;
#   3. launchctl bootout (ignored if not loaded) then bootstrap gui/<uid>.
# The first send raises a one-time macOS Automation -> Messages prompt: approve it at the
# console of each machine.
#
# UNINSTALL: bootout + remove the plist. Idempotent (a second run is a no-op, exit 0). The
# copied imessage-relay.js and the logs are left in place (the relay is inert without the agent).
#
# TEST SEAMS: IR_LAUNCHD_DIR IR_LOG_DIR IR_DEST_DIR IR_NODE IR_UID are honoured ONLY when
# IR_TESTING=1. Without it the real paths are used.
#
# Exit codes: 0 ok | 1 failure | 2 usage | 3 probe says not capable | 4 not opted in
#             5 no usable Node 18+ | 10 refused: dev-team source machine | 11 refused: source checkout
#
# Bash 3.2 compatible (macOS /bin/bash): no associative arrays, no ${x,,}.

set -euo pipefail

LABEL="com.aiteamforge.imessage-relay"
IR_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
IR_ROOT="$(cd "${IR_SELF_DIR}/../.." 2>/dev/null && pwd -P)" || IR_ROOT=""

AITF_DIR="${AITEAMFORGE_DIR:-$HOME/aiteamforge}"
LAUNCHD_DIR="${HOME}/Library/LaunchAgents"
LOG_DIR="${HOME}/Library/Logs/aiteamforge"
DEST_DIR="${AITF_DIR}/scripts"
NODE_OVERRIDE=""
UID_NUM="$(id -u)"
if [ "${IR_TESTING:-}" = "1" ]; then
  LAUNCHD_DIR="${IR_LAUNCHD_DIR:-$LAUNCHD_DIR}"
  LOG_DIR="${IR_LOG_DIR:-$LOG_DIR}"
  DEST_DIR="${IR_DEST_DIR:-$DEST_DIR}"
  NODE_OVERRIDE="${IR_NODE:-}"
  UID_NUM="${IR_UID:-$UID_NUM}"
fi
PLIST="${LAUNCHD_DIR}/${LABEL}.plist"
TEMPLATE="${IR_SELF_DIR}/imessage-relay.template.plist"
RELAY_NAME="imessage-relay.js"
CLIENT_DIR="${IR_SELF_DIR}/client"

err() { echo "ERROR: $*" >&2; }
info() { echo "$*"; }

usage() {
  cat <<'USAGE'
Usage:
  bash install-imessage-relay.sh install [--opt-in] [--dry-run]   install or upgrade the LaunchAgent
  bash install-imessage-relay.sh uninstall [--dry-run]             remove it (idempotent)
  bash install-imessage-relay.sh status                            read-only health report

install is opt-in: pass --opt-in, or answer y at the prompt (needs a TTY).
--dry-run prints what would happen and changes nothing.
USAGE
}

MODE=""; DRY=0; OPT_IN=0
while [ $# -gt 0 ]; do
  case "$1" in
    install|uninstall|status) [ -z "$MODE" ] || { err "only one of install|uninstall|status"; exit 2; }; MODE="$1" ;;
    --dry-run) DRY=1 ;;
    --opt-in) OPT_IN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$MODE" ] || { usage >&2; exit 2; }
[ "$OPT_IN" = 0 ] || [ "$MODE" = install ] || { err "--opt-in only applies to install"; exit 2; }

# ---- dev-machine guard (install only; NO override) --------------------------
# Same signal family as install-power-guard.sh / ci-enable-guard.sh (XACA-0497 / XACA-0564):
# the .aiteamforge-source-tree sentinel at the tree this script runs from, at the resolved
# AITEAMFORGE_DIR, or at $HOME/dev-team; or this script's tree / AITEAMFORGE_DIR is a git
# work-tree. Messages with a personal Apple ID must never be driven from the dev source.
dev_machine_guard() {
  local real top
  real="$(cd "$AITF_DIR" 2>/dev/null && pwd -P)" || real=""
  if { [ -n "$IR_ROOT" ] && [ -f "${IR_ROOT}/.aiteamforge-source-tree" ]; } \
     || { [ -n "$real" ] && [ -f "$real/.aiteamforge-source-tree" ]; } \
     || [ -f "${HOME:-/nonexistent}/dev-team/.aiteamforge-source-tree" ]; then
    err "this is the AITeamForge dev-team source machine (.aiteamforge-source-tree sentinel found)."
    err "The iMessage relay must never be installed here (XACA-0212). Install it on a consumer Mac. There is no override."
    return 10
  fi
  if command -v git >/dev/null 2>&1; then
    top="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$IR_SELF_DIR" rev-parse --show-toplevel 2>/dev/null)" || top=""
    if [ -z "$top" ] && [ -n "$real" ]; then
      top="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$real" rev-parse --show-toplevel 2>/dev/null)" || top=""
    fi
    if [ -n "$top" ]; then
      err "$top is a git work-tree; refusing to install on a source checkout. There is no override."
      return 11
    fi
  fi
  return 0
}

# ---- opt-in -----------------------------------------------------------------
require_opt_in() {
  [ "$OPT_IN" = 1 ] && return 0
  if [ -t 0 ] && [ -t 1 ]; then
    printf 'Install the iMessage relay? This Mac will send FLEET iMessage notifications through Messages.app. [y/N] '
    local a=""; read -r a || a=""
    case "$a" in y|Y|yes|YES|Yes) return 0 ;; esac
    err "not opted in; nothing was changed."
    return 4
  fi
  err "the iMessage relay is opt-in. Re-run with --opt-in to install it. Nothing was changed."
  return 4
}

# ---- node -------------------------------------------------------------------
node_major() { "$1" -p 'process.versions.node.split(".")[0]' 2>/dev/null; }

resolve_node() {
  local c m cands
  if [ -n "$NODE_OVERRIDE" ]; then
    cands="$NODE_OVERRIDE"
  else
    cands="$(command -v node 2>/dev/null || true) /opt/homebrew/bin/node /usr/local/bin/node"
  fi
  for c in $cands; do
    [ -x "$c" ] || continue
    m="$(node_major "$c")" || m=""
    case "$m" in ''|*[!0-9]*) continue ;; esac
    if [ "$m" -ge 18 ]; then printf '%s\n' "$c"; return 0; fi
  done
  err "no usable Node 18+ found (tried: ${cands}). Install Node 18 or newer and re-run."
  return 5
}

# ---- payload ----------------------------------------------------------------
relay_source() { # prefer the shipped sibling, else the already-installed copy
  if [ -f "${CLIENT_DIR}/${RELAY_NAME}" ]; then printf '%s\n' "${CLIENT_DIR}/${RELAY_NAME}"; return 0; fi
  if [ -f "${DEST_DIR}/${RELAY_NAME}" ]; then printf '%s\n' "${DEST_DIR}/${RELAY_NAME}"; return 0; fi
  return 1
}
keygen_source() {
  if [ -f "${CLIENT_DIR}/vault-keygen.js" ]; then printf '%s\n' "${CLIENT_DIR}/vault-keygen.js"; return 0; fi
  if [ -f "${DEST_DIR}/vault-keygen.js" ]; then printf '%s\n' "${DEST_DIR}/vault-keygen.js"; return 0; fi
  return 1
}

# Probe from a throwaway staging dir so a refusal leaves nothing behind.
run_probe() { # run_probe <node> <relay_src> <keygen_src>
  local node="$1" rsrc="$2" ksrc="$3" stage rc=0
  stage="$(mktemp -d "${TMPDIR:-/tmp}/imessage-relay-probe.XXXXXX")" || { err "mktemp failed"; return 1; }
  if ! { cp "$rsrc" "${stage}/${RELAY_NAME}" && cp "$ksrc" "${stage}/vault-keygen.js"; }; then
    cleanup_stage "$stage"; err "could not stage the probe"; return 1
  fi
  # Let the probe resolve node_modules (libsodium) from the install dir when it is there.
  if [ -d "${DEST_DIR}/node_modules" ]; then ln -s "${DEST_DIR}/node_modules" "${stage}/node_modules" 2>/dev/null || true; fi
  "$node" "${stage}/${RELAY_NAME}" probe || rc=$?
  cleanup_stage "$stage"
  case "$rc" in
    0) return 0 ;;
    3) err "Messages has no enabled iMessage account on this Mac (probe exit 3). Sign in to iMessage in Messages.app, then re-run. Nothing was changed."; return 3 ;;
    *) err "capability probe failed (exit ${rc}). Nothing was changed."; return 1 ;;
  esac
}
cleanup_stage() { # the stage holds two files and maybe one symlink: remove them by name, then the dir
  local s="$1"
  [ -n "$s" ] && [ -d "$s" ] || return 0
  unlink "${s}/${RELAY_NAME}" 2>/dev/null || true
  unlink "${s}/vault-keygen.js" 2>/dev/null || true
  unlink "${s}/node_modules" 2>/dev/null || true
  rmdir "$s" 2>/dev/null || true
}

run() { if [ "$DRY" = 1 ]; then info "  [dry-run] $*"; else "$@"; fi; }

safe_value() { # reject characters that cannot be rendered into the plist via sed/XML
  case "$2" in
    *[\<\>\&\"\'\\\|]*) err "$1 contains characters that cannot be rendered safely: $2"; return 1 ;;
  esac
  case "$2" in /*) ;; *) err "$1 is not an absolute path: $2"; return 1 ;; esac
  if [ "$(printf '%s' "$2" | wc -l | tr -d ' ')" != "0" ]; then err "$1 contains a newline"; return 1; fi
}

render_plist() { # render_plist <out> <node> <relay>
  sed -e "s|{{NODE}}|$2|g" \
      -e "s|{{RELAY}}|$3|g" \
      -e "s|{{HOME}}|${HOME}|g" \
      -e "s|{{AITEAMFORGE_DIR}}|${AITF_DIR}|g" \
      -e "s|{{LOG_DIR}}|${LOG_DIR}|g" "$TEMPLATE" >"$1"
  if grep -q '{{[A-Z_]*}}' "$1"; then err "unsubstituted placeholder left in rendered plist"; return 1; fi
}

lint_plist() {
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$1" >/dev/null || { err "plutil -lint rejected $1"; return 1; }
  else
    info "WARNING: plutil not found; rendered plist not linted"
  fi
}

# ---- install ----------------------------------------------------------------
do_install() {
  dev_machine_guard || exit $?
  if [ "${IR_TESTING:-}" != "1" ] && [ "$(uname -s)" != "Darwin" ]; then err "the iMessage relay needs macOS."; exit 1; fi
  require_opt_in || exit $?
  [ -f "$TEMPLATE" ] || { err "plist template missing: $TEMPLATE"; exit 1; }
  local node rsrc ksrc tmp relay
  node="$(resolve_node)" || exit $?
  rsrc="$(relay_source)" || { err "${RELAY_NAME} not found in ${CLIENT_DIR} or ${DEST_DIR}. Nothing was changed."; exit 1; }
  ksrc="$(keygen_source)" || { err "vault-keygen.js not found in ${CLIENT_DIR} or ${DEST_DIR} (the relay requires it; msg-client's install provides it). Nothing was changed."; exit 1; }
  safe_value node "$node" && safe_value home "$HOME" && safe_value aiteamforge_dir "$AITF_DIR" \
    && safe_value log_dir "$LOG_DIR" && safe_value dest_dir "$DEST_DIR" || exit 1

  run_probe "$node" "$rsrc" "$ksrc" || exit $?

  relay="${DEST_DIR}/${RELAY_NAME}"
  info "Installing ${LABEL}"
  run mkdir -p "$DEST_DIR" "$LAUNCHD_DIR" "$LOG_DIR"
  if [ "$rsrc" != "$relay" ]; then
    if [ "$DRY" = 1 ]; then
      info "  [dry-run] cp $rsrc $relay"
    else
      cp "$rsrc" "${relay}.new.$$" && mv -f "${relay}.new.$$" "$relay" && chmod 0644 "$relay"
    fi
  fi
  if [ "$DRY" = 1 ]; then
    info "  [dry-run] render ${TEMPLATE} -> ${PLIST} (node=${node} relay=${relay})"
    info "  [dry-run] launchctl bootout gui/${UID_NUM}/${LABEL}"
    info "  [dry-run] launchctl bootstrap gui/${UID_NUM} ${PLIST}"
    return 0
  fi
  tmp="$(mktemp "${LAUNCHD_DIR}/.${LABEL}.XXXXXX")" || { err "mktemp failed in ${LAUNCHD_DIR}"; exit 1; }
  if ! render_plist "$tmp" "$node" "$relay" || ! lint_plist "$tmp"; then unlink "$tmp" 2>/dev/null || true; exit 1; fi
  chmod 0644 "$tmp"; mv -f "$tmp" "$PLIST"
  launchctl bootout "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${UID_NUM}" "$PLIST" || { err "launchctl bootstrap failed for $PLIST"; exit 1; }
  info "Installed. Logs: ${LOG_DIR}/imessage-relay.log"
  info "The first send raises a one-time macOS Automation -> Messages prompt: approve it at this Mac's console."
}

# ---- uninstall --------------------------------------------------------------
do_uninstall() {
  info "Removing ${LABEL}"
  if [ "$DRY" = 1 ]; then
    info "  [dry-run] launchctl bootout gui/${UID_NUM}/${LABEL}"
    info "  [dry-run] remove ${PLIST}"
    return 0
  fi
  launchctl bootout "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1 || true
  if [ -e "$PLIST" ] || [ -L "$PLIST" ]; then unlink "$PLIST"; fi
  info "Removed (the copied ${RELAY_NAME} and the logs are left in place)."
}

# ---- status -----------------------------------------------------------------
do_status() {
  local rc=0
  if [ -f "$PLIST" ]; then info "plist:    present ($PLIST)"; else info "plist:    absent"; rc=1; fi
  if launchctl print "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1; then info "launchd:  loaded"; else info "launchd:  not loaded"; rc=1; fi
  if [ -f "${DEST_DIR}/${RELAY_NAME}" ]; then info "relay:    ${DEST_DIR}/${RELAY_NAME}"; else info "relay:    not installed"; rc=1; fi
  return $rc
}

case "$MODE" in
  install) do_install ;;
  uninstall) do_uninstall ;;
  status) do_status ;;
esac
