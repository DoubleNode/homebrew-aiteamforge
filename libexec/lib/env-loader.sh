#!/bin/bash
# env-loader.sh
# DoubleNode Dev-Team Infrastructure (AITeamForge)
#
# XACA-0730: the ONE renderer for $AITEAMFORGE_DIR/share/aiteamforge-env.sh,
# shared VERBATIM between install-shell.sh (install_env_loader, fresh installs)
# and aiteamforge-upgrade.sh (update_env_loader, already-installed machines).
#
# Root cause: install rendered the env loader, upgrade never touched it. M1Pro
# kept a May-dated copy without the XACA-0494 worktree-helpers block through
# ~10 upgrades. Keeping the substitution here means the two paths cannot
# render it differently, so upgrade can decide current/stale by plain cmp.
#
# No side effects when sourced: defines one function, runs nothing. Safe under
# both callers' strictness (`set -euo pipefail` / `set -eo pipefail`): every
# branch returns explicitly.

# aitf_render_env_loader <template> <aiteamforge_dir> <out>
#   Renders <template> into <out>, substituting {{AITEAMFORGE_DIR}}.
#   Returns 0 ok | 1 template missing | 2 render failed or produced empty output.
#   Errors go to stderr (never swallowed here); callers decide how to report.
aitf_render_env_loader() {
    local template="$1" aitf_dir="$2" out="$3"

    if [ ! -f "$template" ]; then
        echo "env loader template not found: $template" >&2
        return 1
    fi
    if ! sed -e "s|{{AITEAMFORGE_DIR}}|${aitf_dir}|g" "$template" > "$out"; then
        echo "failed to render $template -> $out" >&2
        return 2
    fi
    if [ ! -s "$out" ]; then
        echo "render of $template produced an empty file" >&2
        return 2
    fi
    return 0
}
