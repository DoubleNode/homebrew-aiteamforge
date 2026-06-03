#!/usr/bin/env bash
# imgcat-provision.sh — XACA-0611
# Shared helper: provision ~/.iterm2/imgcat from the bundled tap asset.
#
# CONTRACT:
#   ensure_imgcat <share_dir>
#     share_dir : absolute path to the tap's share/ directory
#                 (e.g. "$FRAMEWORK_DIR/share"  — from aiteamforge-upgrade.sh)
#                 (e.g. "$INSTALL_ROOT/share"   — from install-shell.sh)
#   Returns:
#     0 — imgcat is present at ~/.iterm2/imgcat, executable, and non-empty
#     1 — all attempts failed; caller SHOULD emit a loud warning so the user
#         knows agent-panel images will not render
#
# BEHAVIOUR:
#   1. No-op if ~/.iterm2/imgcat already exists, is executable, and is non-empty
#      (cheap re-verify; saves needless copy on every upgrade).
#   2. Primary: copy bundled asset from share/iterm2/imgcat  →  ~/.iterm2/imgcat
#   3. Fallback: curl https://iterm2.com/utilities/imgcat (recovery only)
#   4. Verify: file present, executable, size > 0.  Exits non-zero on failure.
#      (does NOT suppress errors — callers own the user-visible warning message)
#
# SOURCING REQUIREMENT:
#   This file MUST be sourced AFTER common.sh (uses info/success/warning/error).
#   Guard against double-sourcing is provided below.

if [[ -n "${_IMGCAT_PROVISION_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
_IMGCAT_PROVISION_SH_LOADED=1

ensure_imgcat() {
    local share_dir="${1:-}"

    if [[ -z "$share_dir" ]]; then
        error "ensure_imgcat: share_dir argument is required"
        return 1
    fi

    local dest_dir="$HOME/.iterm2"
    local dest="$dest_dir/imgcat"

    # ── 1. Already present and valid? ─────────────────────────────────────────
    if [[ -f "$dest" && -x "$dest" && -s "$dest" ]]; then
        return 0
    fi

    # ── 2. Primary: copy from bundled tap asset ────────────────────────────────
    local bundled="${share_dir}/iterm2/imgcat"
    if [[ -f "$bundled" && -s "$bundled" ]]; then
        mkdir -p "$dest_dir"
        if cp "$bundled" "$dest"; then
            chmod +x "$dest"
            if [[ -f "$dest" && -x "$dest" && -s "$dest" ]]; then
                info "imgcat provisioned from bundled asset"
                return 0
            fi
        fi
        # Copy succeeded but verify failed — fall through to curl
        warning "imgcat copy verification failed; trying network fallback"
    else
        warning "Bundled imgcat not found at $bundled — trying network fallback"
    fi

    # ── 3. Fallback: curl from iterm2.com ─────────────────────────────────────
    mkdir -p "$dest_dir"
    if curl -sSL https://iterm2.com/utilities/imgcat -o "$dest"; then
        chmod +x "$dest"
        if [[ -f "$dest" && -x "$dest" && -s "$dest" ]]; then
            info "imgcat provisioned via network fallback"
            return 0
        fi
    fi

    # ── 4. All paths failed ───────────────────────────────────────────────────
    error "ensure_imgcat: all provisioning attempts failed — ~/.iterm2/imgcat unavailable"
    return 1
}
