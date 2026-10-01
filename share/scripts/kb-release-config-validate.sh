#!/usr/bin/env zsh
# kb-release-config-validate.sh -- thin zsh CLI dispatcher for the
# release-config validator (XACA-1342-005).
#
# Sourced by kanban-helpers.sh, same guard+source pattern as kb-cr.sh
# (kanban-helpers.sh, "CR lifecycle helpers" block). ALL argument parsing,
# team -> config-dir resolution, schema validation and secretRef
# resolve-checking happens in the Python library
# (scripts/release_config_validate.py) -- this file's only job is to
# locate python3 and that sibling script and exec it. Keeping the logic in
# Python (already implemented + unit-tested there for Phase 1) means this
# dispatcher has nothing team-specific, no JSON handling and no secretRef
# grammar to keep in sync with the Python copy.
#
# Self-location: ${(%):-%x} is the zsh idiom for "this file's own path
# when it is `source`d rather than executed" -- $0 is the CALLER's name in
# that case, under both bash and zsh, and BASH_SOURCE is a bash-ism this
# file (zsh-only, see below) does not rely on. See kb-cr.sh's
# _KB_CR_ROUTING_CORE line for the identical idiom used the same way.
#
# zsh-only, like kb-cr.sh: this file is always sourced by kanban-helpers.sh,
# which is itself zsh-only (a bash parse of kanban-helpers.sh aborts on a
# zsh glob qualifier long before reaching either guard block). Standalone
# use (outside kanban-helpers.sh) must also go through zsh:
#   zsh -c 'source scripts/kb-release-config-validate.sh; kb-release-config-validate <team> --all'
# A caller who wants a shell-agnostic standalone entry point should call
# the Python script directly instead:
#   python3 scripts/release_config_validate.py <team> --all

typeset -g _KB_RELEASE_CONFIG_VALIDATE_DIR="${${(%):-%x}:A:h}"

kb-release-config-validate() {
    local script_dir="$_KB_RELEASE_CONFIG_VALIDATE_DIR"
    local py_script="${script_dir}/release_config_validate.py"

    if [[ ! -f "$py_script" ]]; then
        echo "kb-release-config-validate: missing ${py_script}" >&2
        return 2
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "kb-release-config-validate: python3 not found on PATH" >&2
        return 2
    fi

    python3 "$py_script" "$@"
}
