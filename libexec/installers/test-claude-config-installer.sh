#!/usr/bin/env bash
# Test script for Claude Code configuration installer
# Runs a dry-run test to verify installer logic without modifying system

set -euo pipefail

# Colors
COLOR_BLUE='\033[0;34m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="/tmp/claude-config-test-$$"
TEMPLATE_DIR="${SCRIPT_DIR}/../../share/templates"

log_test() {
    echo -e "${COLOR_BLUE}[TEST]${COLOR_RESET} $*"
}

log_pass() {
    echo -e "${COLOR_GREEN}[PASS]${COLOR_RESET} $*"
}

log_fail() {
    echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} $*"
}

log_info() {
    echo -e "${COLOR_YELLOW}[INFO]${COLOR_RESET} $*"
}

cleanup() {
    if [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
        log_info "Cleaned up test directory"
    fi
}

trap cleanup EXIT

# Test 1: Verify installer script exists and is executable
test_installer_exists() {
    log_test "Checking installer script exists and is executable..."

    local installer="${SCRIPT_DIR}/install-claude-config.sh"

    if [[ ! -f "$installer" ]]; then
        log_fail "Installer not found: $installer"
        return 1
    fi

    if [[ ! -x "$installer" ]]; then
        log_fail "Installer is not executable"
        return 1
    fi

    log_pass "Installer script found and executable"
    return 0
}

# Test 2: Verify all template files exist
test_templates_exist() {
    log_test "Checking template files exist..."

    local missing=0
    local templates=(
        "claude/claude-md-global.template"
        "claude/claude-md-team.template"
        "claude/settings.json.template"
        "claude/mcp-settings.template"
        "claude/statusline-command.sh"
        "claude/agent-tracking.sh"
        "claude/hooks/damage-control/bash-tool-damage-control.py"
        "claude/hooks/damage-control/edit-tool-damage-control.py"
        "claude/hooks/damage-control/write-tool-damage-control.py"
        "claude/hooks/damage-control/patterns.yaml"
    )

    for template in "${templates[@]}"; do
        if [[ ! -f "${TEMPLATE_DIR}/${template}" ]]; then
            log_fail "Missing template: $template"
            ((missing++))
        fi
    done

    if [[ $missing -gt 0 ]]; then
        log_fail "$missing template files missing"
        return 1
    fi

    log_pass "All template files found"
    return 0
}

# Test 3: Verify template variable substitution
test_template_variables() {
    log_test "Checking template variable substitution..."

    mkdir -p "$TEST_DIR"

    # Test substitution function
    local test_template="${TEST_DIR}/test.template"
    local test_output="${TEST_DIR}/test.output"

    cat > "$test_template" <<'EOF'
AITEAMFORGE_DIR={{AITEAMFORGE_DIR}}
HOME={{HOME}}
CLAUDE_CONFIG_DIR={{CLAUDE_CONFIG_DIR}}
USER={{USER}}
EOF

    # Source the installer to get the apply_template function
    # But override variables to test values
    export AITEAMFORGE_DIR="/test/aiteamforge"
    export HOME="/test/home"
    export CLAUDE_CONFIG_DIR="/test/.claude"
    export USER="testuser"

    # Apply template substitution
    sed -e "s|{{AITEAMFORGE_DIR}}|${AITEAMFORGE_DIR}|g" \
        -e "s|{{HOME}}|${HOME}|g" \
        -e "s|{{CLAUDE_CONFIG_DIR}}|${CLAUDE_CONFIG_DIR}|g" \
        -e "s|{{USER}}|${USER}|g" \
        "$test_template" > "$test_output"

    # Verify substitution
    if grep -q "{{" "$test_output"; then
        log_fail "Template variables not fully substituted"
        cat "$test_output"
        return 1
    fi

    if ! grep -q "AITEAMFORGE_DIR=/test/aiteamforge" "$test_output"; then
        log_fail "AITEAMFORGE_DIR not substituted correctly"
        return 1
    fi

    log_pass "Template variable substitution works"
    return 0
}

# Test 4: Verify settings.json template is valid JSON
test_settings_json_valid() {
    log_test "Checking settings.json template is valid JSON (after substitution)..."

    if ! command -v jq &>/dev/null; then
        log_info "jq not found, skipping JSON validation"
        return 0
    fi

    local template="${TEMPLATE_DIR}/claude/settings.json.template"
    local temp_file="${TEST_DIR}/settings.json"

    # Apply substitution
    sed -e "s|{{AITEAMFORGE_DIR}}|/test/aiteamforge|g" \
        -e "s|{{HOME}}|/test/home|g" \
        -e "s|{{CLAUDE_CONFIG_DIR}}|/test/.claude|g" \
        -e "s|{{USER}}|testuser|g" \
        "$template" > "$temp_file"

    if ! jq . "$temp_file" >/dev/null 2>&1; then
        log_fail "settings.json template is invalid JSON"
        cat "$temp_file"
        return 1
    fi

    log_pass "settings.json template is valid JSON"
    return 0
}

# Test 5: Verify MCP settings template is valid JSON
test_mcp_settings_valid() {
    log_test "Checking mcp-settings.template is valid JSON (after substitution)..."

    if ! command -v jq &>/dev/null; then
        log_info "jq not found, skipping JSON validation"
        return 0
    fi

    local template="${TEMPLATE_DIR}/claude/mcp-settings.template"
    local temp_file="${TEST_DIR}/mcp-settings.json"

    # Apply substitution
    sed -e "s|{{AITEAMFORGE_DIR}}|/test/aiteamforge|g" \
        -e "s|{{HOME}}|/test/home|g" \
        "$template" > "$temp_file"

    if ! jq . "$temp_file" >/dev/null 2>&1; then
        log_fail "mcp-settings.template is invalid JSON"
        cat "$temp_file"
        return 1
    fi

    log_pass "mcp-settings.template is valid JSON"
    return 0
}

# Test 6: Verify hooks are executable
test_hooks_executable() {
    log_test "Checking damage control hooks are executable..."

    local hooks=(
        "bash-tool-damage-control.py"
        "edit-tool-damage-control.py"
        "write-tool-damage-control.py"
    )

    local hook_dir="${TEMPLATE_DIR}/claude/hooks/damage-control"

    for hook in "${hooks[@]}"; do
        if [[ ! -x "${hook_dir}/${hook}" ]]; then
            log_fail "Hook not executable: $hook"
            return 1
        fi
    done

    log_pass "All damage control hooks are executable"
    return 0
}

# Test 7: Verify damage control hooks have Python shebang
test_hooks_python() {
    log_test "Checking damage control hooks have Python shebang..."

    local hooks=(
        "bash-tool-damage-control.py"
        "edit-tool-damage-control.py"
        "write-tool-damage-control.py"
    )

    local hook_dir="${TEMPLATE_DIR}/claude/hooks/damage-control"

    for hook in "${hooks[@]}"; do
        if ! head -1 "${hook_dir}/${hook}" | grep -q "python"; then
            log_fail "Hook missing Python shebang: $hook"
            return 1
        fi
    done

    log_pass "All damage control hooks have Python shebang"
    return 0
}

# Test 8: Verify patterns.yaml is valid YAML
test_patterns_yaml_valid() {
    log_test "Checking patterns.yaml is valid YAML..."

    if ! command -v python3 &>/dev/null; then
        log_info "Python3 not found, skipping YAML validation"
        return 0
    fi

    # Check if pyyaml is available
    if ! python3 -c "import yaml" 2>/dev/null; then
        log_info "pyyaml not installed, skipping YAML validation"
        return 0
    fi

    local patterns="${TEMPLATE_DIR}/claude/hooks/damage-control/patterns.yaml"

    if ! python3 -c "import yaml; yaml.safe_load(open('$patterns'))" 2>/dev/null; then
        log_fail "patterns.yaml is invalid YAML"
        return 1
    fi

    log_pass "patterns.yaml is valid YAML"
    return 0
}

# Test 9: Verify README files exist
test_readme_files() {
    log_test "Checking README documentation exists..."

    local readmes=(
        "claude/README.md"
        "claude/hooks/damage-control/README.md"
    )

    local missing=0
    for readme in "${readmes[@]}"; do
        if [[ ! -f "${TEMPLATE_DIR}/${readme}" ]]; then
            log_fail "Missing README: $readme"
            ((missing++))
        fi
    done

    if [[ $missing -gt 0 ]]; then
        return 1
    fi

    log_pass "All README files found"
    return 0
}

#==============================================================================
# XACA-1605-008: fleet mods marketplace (install_claude_mods / _xaca1605_*)
#==============================================================================
# Every case runs the installer functions under `env -i` with HOME,
# AITEAMFORGE_DIR, CLAUDE_CONFIG_DIR and XACA1605_MODS_DIR all pointed at a
# per-case temp dir, with a PATH made of a symlink farm (so "claude absent" is
# real) plus a stub `claude` that emulates the settings writes of the real
# `claude plugin` CLI. One extra case drives the REAL CLI when it is installed.
# NOTHING here may touch the real ~/.claude, ~/aiteamforge or ~/.aiteamforge.

INSTALLER="${XACA1605_INSTALLER_UNDER_TEST:-${SCRIPT_DIR}/install-claude-config.sh}"
REAL_CLAUDE="$(command -v claude 2>/dev/null || true)"
MP="aiteamforge-mods"

# Per-case sandbox. Sets T, SETTINGS, RECEIPT, LOG. $1 = case name.
mods_case() {
    T="${TEST_DIR}/mods-$1"
    mkdir -p "$T/home" "$T/af" "$T/cc" "$T/mods/.claude-plugin" "$T/bin" "$T/tools"
    SETTINGS="$T/cc/settings.json"
    RECEIPT="$T/af/.xaca1605-mods.receipt"
    LOG="$T/calls.log"
    : > "$LOG"
    local tool p
    for tool in jq date mktemp mv rm mkdir dirname basename grep cat sed tr sort wc chmod cp head tail cut uniq find ls readlink env bash; do
        p="$(command -v "$tool" 2>/dev/null || true)"
        [[ -n "$p" && ! -e "$T/tools/$tool" ]] && ln -s "$p" "$T/tools/$tool"
    done
    mods_market alpha beta gamma
    mods_stub_claude
}

# $@ = plugin names listed by the fixture marketplace
mods_market() {
    local names=("$@") n out="" sep=""
    for n in "${names[@]}"; do out="${out}${sep}{\"name\":\"${n}\",\"source\":\"./${n}\"}"; sep=","; done
    printf '{"name":"%s","owner":{"name":"t"},"plugins":[%s]}\n' "$MP" "$out" > "$T/mods/.claude-plugin/marketplace.json"
}

mods_stub_claude() {
    cat > "$T/bin/claude" <<'STUB'
#!/bin/bash
set -u
S="$CLAUDE_CONFIG_DIR/settings.json"
LOG="${STUB_LOG:-/dev/null}"
[ "${1:-}" = "plugin" ] || exit 64
shift
sub="${1:-}"; shift
rw() { local tmp; [ -f "$S" ] || echo '{}' > "$S"; tmp="$(mktemp "$S.XXXX")"; jq "$@" "$S" > "$tmp" && mv "$tmp" "$S"; }
case "$sub" in
  marketplace)
    act="${1:-}"; shift
    case "$act" in
      add) dir="$1"; name="$(jq -r .name "$dir/.claude-plugin/marketplace.json")"
           echo "marketplace-add $name $dir" >> "$LOG"
           rw --arg n "$name" --arg p "$dir" '.extraKnownMarketplaces[$n]={source:{source:"directory",path:$p}}' ;;
      remove|rm) name="$1"; echo "marketplace-remove $name" >> "$LOG"
           rw --arg n "$name" 'del(.extraKnownMarketplaces[$n]) | .enabledPlugins |= ((. // {}) | with_entries(select((.key | endswith("@" + $n)) | not)))' ;;
      *) exit 64 ;;
    esac ;;
  install)
    id="$1"; rcpt=no; [ -f "$AITEAMFORGE_DIR/.xaca1605-mods.receipt" ] && rcpt=yes
    echo "install $id receipt=$rcpt" >> "$LOG"
    [ "${STUB_FAIL_INSTALL:-}" = "$id" ] && exit 1
    rw --arg i "$id" '.enabledPlugins[$i]=true' ;;
  uninstall)
    id="$1"; echo "uninstall $id" >> "$LOG"
    rw --arg i "$id" 'del(.enabledPlugins[$i])' ;;
  *) exit 64 ;;
esac
STUB
    chmod +x "$T/bin/claude"
}

# Run an installer function in the sandbox. $1 = "stub"|"none"|"real", rest = fn + args.
# Sets OUT, ERR, RC. Extra env for the child via the global MODS_EXTRA_ENV array.
MODS_EXTRA_ENV=()
mods_run() {
    local mode="$1"; shift
    local path="$T/tools"
    case "$mode" in
        stub) path="$T/bin:$T/tools" ;;
        real) path="$(dirname "$REAL_CLAUDE"):$T/tools" ;;
    esac
    RC=0
    env -i HOME="$T/home" PATH="$path" AITEAMFORGE_DIR="$T/af" CLAUDE_CONFIG_DIR="$T/cc" \
        XACA1605_MODS_DIR="$T/mods" STUB_LOG="$LOG" ${MODS_EXTRA_ENV[@]+"${MODS_EXTRA_ENV[@]}"} \
        "$(command -v bash)" -c 'source "$1"; shift; "$@"' _ "$INSTALLER" "$@" \
        > "$T/out" 2> "$T/err" || RC=$?
    OUT="$(cat "$T/out")"
    ERR="$(cat "$T/err")"
}

mods_fail() { log_fail "$1"; [[ -n "${OUT:-}" ]] && echo "  OUT: $OUT"; [[ -n "${ERR:-}" ]] && echo "  ERR: $ERR"; return 1; }
mods_plugin() { jq -r --arg k "$1" '.enabledPlugins[$k] | if . == null then "absent" else tostring end' "$SETTINGS" 2>/dev/null; }

test_mods_fresh_install() {
    log_test "mods: fresh install registers the marketplace and enables every listed mod..."
    mods_case fresh
    mods_run stub _xaca1605_sync_mods
    [[ "$RC" == 2 ]] || { mods_fail "expected rc 2 (changed), got $RC"; return 1; }
    local n
    for n in alpha beta gamma; do
        [[ "$(mods_plugin "$n@$MP")" == true ]] || { mods_fail "$n@$MP not enabled"; return 1; }
    done
    [[ "$(jq -r --arg m "$MP" '.extraKnownMarketplaces[$m].source.path' "$SETTINGS")" == "$T/mods" ]] \
        || { mods_fail "marketplace path not registered"; return 1; }
    [[ "$(jq -c '.targets | to_entries[0].value.enabled | sort' "$RECEIPT")" == '["alpha@aiteamforge-mods","beta@aiteamforge-mods","gamma@aiteamforge-mods"]' ]] \
        || { mods_fail "receipt does not record the 3 ids"; return 1; }
    grep -q 'added=3 retired=0' <<< "$OUT" || { mods_fail "summary line wrong"; return 1; }
    log_pass "fresh install enables all 3 and records them"
}

test_mods_opt_path_not_cellar() {
    log_test "mods: the marketplace path is the brew OPT spelling, never the Cellar..."
    mods_case optpath
    # A stub brew whose prefix is a fake tree, so the default resolution runs for real.
    mkdir -p "$T/fakebrew/opt/aiteamforge/libexec/share/claude-mods/.claude-plugin"
    cp "$T/mods/.claude-plugin/marketplace.json" "$T/fakebrew/opt/aiteamforge/libexec/share/claude-mods/.claude-plugin/"
    printf '#!/bin/bash\n[ "$1" = "--prefix" ] && echo "%s"\n' "$T/fakebrew" > "$T/bin/brew"
    chmod +x "$T/bin/brew"
    MODS_EXTRA_ENV=()
    # Drop the override by running with an env that does not set XACA1605_MODS_DIR.
    RC=0
    env -i HOME="$T/home" PATH="$T/bin:$T/tools" AITEAMFORGE_DIR="$T/af" CLAUDE_CONFIG_DIR="$T/cc" STUB_LOG="$LOG" \
        "$(command -v bash)" -c 'source "$1"; _xaca1605_sync_mods' _ "$INSTALLER" > "$T/out" 2> "$T/err" || RC=$?
    OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
    local want="$T/fakebrew/opt/aiteamforge/libexec/share/claude-mods" got
    got="$(jq -r --arg m "$MP" '.extraKnownMarketplaces[$m].source.path // "none"' "$SETTINGS" 2>/dev/null)"
    [[ "$got" == "$want" ]] || { mods_fail "registered '$got', wanted the opt path '$want'"; return 1; }
    case "$got" in */Cellar/*) mods_fail "Cellar path registered"; return 1 ;; esac
    log_pass "opt path written, no Cellar spelling"
}

test_mods_upgrade_preserves_existing() {
    log_test "mods: upgrade on an existing settings.json adds mods and keeps everything else..."
    mods_case upgrade
    cat > "$SETTINGS" <<'EOF'
{"theme":"dark","enabledPlugins":{"foo@other-market":true,"bar@other-market":false},
 "extraKnownMarketplaces":{"other-market":{"source":{"source":"github","repo":"x/y"}}}}
EOF
    mods_run stub _xaca1605_sync_mods
    [[ "$RC" == 2 ]] || { mods_fail "expected rc 2, got $RC"; return 1; }
    [[ "$(mods_plugin foo@other-market)" == true && "$(mods_plugin bar@other-market)" == false ]] \
        || { mods_fail "other-marketplace plugins changed"; return 1; }
    [[ "$(jq -r '.theme' "$SETTINGS")" == dark ]] || { mods_fail "unrelated key lost"; return 1; }
    [[ "$(jq -r '.extraKnownMarketplaces["other-market"].source.repo' "$SETTINGS")" == x/y ]] \
        || { mods_fail "other marketplace entry lost"; return 1; }
    [[ "$(mods_plugin alpha@$MP)" == true ]] || { mods_fail "alpha not added"; return 1; }
    log_pass "upgrade adds 3 mods, other keys untouched"
}

test_mods_idempotent_rerun() {
    log_test "mods: a second run is a no-op (no installs, settings unchanged)..."
    mods_case idem
    mods_run stub _xaca1605_sync_mods
    local before; before="$(jq -S -c . "$SETTINGS")"; : > "$LOG"
    mods_run stub _xaca1605_sync_mods
    [[ "$RC" == 0 ]] || { mods_fail "re-run rc $RC, wanted 0"; return 1; }
    [[ "$before" == "$(jq -S -c . "$SETTINGS")" ]] || { mods_fail "settings changed on re-run"; return 1; }
    if grep -q '^install \|^uninstall ' "$LOG"; then mods_fail "re-run installed/uninstalled something"; return 1; fi
    grep -q 'added=0 retired=0' <<< "$OUT" || { mods_fail "no-op summary missing"; return 1; }
    log_pass "re-run is idempotent"
}

test_mods_retired_mod_removed() {
    log_test "mods: a mod dropped from the marketplace is removed (recorded + still true)..."
    mods_case retire
    mods_run stub _xaca1605_sync_mods
    mods_market alpha beta
    : > "$LOG"
    mods_run stub _xaca1605_sync_mods
    [[ "$RC" == 2 ]] || { mods_fail "expected rc 2, got $RC"; return 1; }
    [[ "$(mods_plugin gamma@$MP)" == absent ]] || { mods_fail "gamma not retired"; return 1; }
    [[ "$(mods_plugin alpha@$MP)" == true && "$(mods_plugin beta@$MP)" == true ]] || { mods_fail "kept mods changed"; return 1; }
    grep -q '^uninstall gamma@aiteamforge-mods' "$LOG" || { mods_fail "no uninstall call for gamma"; return 1; }
    [[ "$(jq -c '.targets | to_entries[0].value.enabled | sort' "$RECEIPT")" == '["alpha@aiteamforge-mods","beta@aiteamforge-mods"]' ]] \
        || { mods_fail "receipt still lists gamma"; return 1; }
    log_pass "retired mod removed and dropped from the receipt"
}

test_mods_retired_but_user_disabled_stays() {
    log_test "mods: a retired mod the user set false is NOT removed (the 'still true' condition)..."
    mods_case retirefalse
    mods_run stub _xaca1605_sync_mods
    jq '.enabledPlugins["gamma@aiteamforge-mods"]=false' "$SETTINGS" > "$T/s.tmp" && mv "$T/s.tmp" "$SETTINGS"
    mods_market alpha beta
    : > "$LOG"
    mods_run stub _xaca1605_sync_mods
    [[ "$(mods_plugin gamma@$MP)" == false ]] || { mods_fail "user false on retired mod was removed/changed: $(mods_plugin gamma@$MP)"; return 1; }
    if grep -q '^uninstall ' "$LOG"; then mods_fail "uninstall ran on a user-false key"; return 1; fi
    log_pass "user false on a retired mod survives"
}

test_mods_user_false_preserved_on_upgrade() {
    log_test "mods: a user-disabled (false) listed mod survives every upgrade..."
    mods_case userfalse
    mods_run stub _xaca1605_sync_mods
    jq '.enabledPlugins["beta@aiteamforge-mods"]=false' "$SETTINGS" > "$T/s.tmp" && mv "$T/s.tmp" "$SETTINGS"
    : > "$LOG"
    mods_run stub _xaca1605_sync_mods
    mods_run stub _xaca1605_sync_mods
    [[ "$(mods_plugin beta@$MP)" == false ]] || { mods_fail "beta flipped back to $(mods_plugin beta@$MP)"; return 1; }
    if grep -q 'install beta' "$LOG"; then mods_fail "install ran for a present (false) key"; return 1; fi
    log_pass "user false preserved across upgrades"
}

test_mods_other_marketplace_untouched() {
    log_test "mods: plugins from other marketplaces are never touched, even if (wrongly) recorded..."
    mods_case other
    cat > "$SETTINGS" <<'EOF'
{"enabledPlugins":{"foo@other-market":true,"keepme@other-market":true}}
EOF
    # A receipt that names an out-of-marketplace id as ours must not retire it.
    local canon; canon="$(cd "$T/cc" && pwd -P)/settings.json"
    jq -n --arg k "$canon" '{ticket:"XACA-1605",version:1,targets:{($k):{marketplace:{name:"aiteamforge-mods",path:"x"},enabled:["foo@other-market","gamma@aiteamforge-mods"],at:"t"}}}' > "$RECEIPT"
    mods_market alpha beta
    mods_run stub _xaca1605_sync_mods
    [[ "$(mods_plugin foo@other-market)" == true && "$(mods_plugin keepme@other-market)" == true ]] \
        || { mods_fail "other-market plugin removed"; return 1; }
    if grep -q 'other-market' "$LOG"; then mods_fail "CLI called on an other-market plugin"; return 1; fi
    log_pass "other marketplaces untouched"
}

test_mods_unreadable_receipt_add_only() {
    log_test "mods: an unreadable receipt makes the run add-only and is never overwritten..."
    mods_case badreceipt
    cat > "$SETTINGS" <<'EOF'
{"enabledPlugins":{"gamma@aiteamforge-mods":true}}
EOF
    printf 'this is { not json' > "$RECEIPT"
    mods_market alpha beta
    mods_run stub _xaca1605_sync_mods
    [[ "$(mods_plugin alpha@$MP)" == true && "$(mods_plugin beta@$MP)" == true ]] || { mods_fail "adds not made in add-only mode"; return 1; }
    [[ "$(mods_plugin gamma@$MP)" == true ]] || { mods_fail "add-only run removed gamma"; return 1; }
    [[ "$(cat "$RECEIPT")" == 'this is { not json' ]] || { mods_fail "unreadable receipt was overwritten"; return 1; }
    grep -q 'unreadable' <<< "$ERR" || { mods_fail "no add-only warning"; return 1; }
    log_pass "add-only on an unreadable receipt; receipt untouched"
}

test_mods_claude_absent_skips() {
    log_test "mods: claude CLI absent -> clear skip, installer step returns 0, nothing written..."
    mods_case noclaude
    mods_run none _xaca1605_sync_mods
    [[ "$RC" == 1 ]] || { mods_fail "sync rc $RC, wanted 1 (skipped)"; return 1; }
    grep -q 'claude CLI not found' <<< "$OUT" || { mods_fail "no clear skip message"; return 1; }
    mods_run none install_claude_mods
    [[ "$RC" == 0 ]] || { mods_fail "install_claude_mods failed the installer (rc $RC)"; return 1; }
    [[ ! -e "$SETTINGS" && ! -e "$RECEIPT" ]] || { mods_fail "files written despite skip"; return 1; }
    log_pass "claude absent: skipped cleanly"
}

test_mods_marketplace_dir_absent_noop() {
    log_test "mods: shipped marketplace dir absent (installer ahead of the tap mirror) -> clean no-op..."
    mods_case nodir
    mv "$T/mods" "$T/mods-gone"
    mods_run stub _xaca1605_sync_mods
    [[ "$RC" == 0 ]] || { mods_fail "rc $RC, wanted 0"; return 1; }
    grep -q 'marketplace not shipped' <<< "$OUT" || { mods_fail "no clear message"; return 1; }
    mods_run stub install_claude_mods
    [[ "$RC" == 0 ]] || { mods_fail "install_claude_mods rc $RC"; return 1; }
    [[ ! -e "$SETTINGS" && ! -e "$RECEIPT" && ! -s "$LOG" ]] || { mods_fail "something was written/called"; return 1; }
    log_pass "absent marketplace dir is a clear no-op"
}

test_mods_invalid_marketplace_never_retires() {
    log_test "mods: an empty/malformed marketplace is rejected and retires nothing..."
    mods_case emptymp
    mods_run stub _xaca1605_sync_mods
    local before; before="$(jq -S -c . "$SETTINGS")"
    printf '{"name":"aiteamforge-mods","plugins":[]}\n' > "$T/mods/.claude-plugin/marketplace.json"
    : > "$LOG"
    mods_run stub _xaca1605_sync_mods
    [[ "$RC" == 1 ]] || { mods_fail "empty marketplace rc $RC, wanted 1"; return 1; }
    [[ "$before" == "$(jq -S -c . "$SETTINGS")" ]] || { mods_fail "settings changed on empty marketplace"; return 1; }
    printf 'garbage' > "$T/mods/.claude-plugin/marketplace.json"
    mods_run stub _xaca1605_sync_mods
    [[ "$RC" == 1 && "$before" == "$(jq -S -c . "$SETTINGS")" ]] || { mods_fail "malformed marketplace not rejected cleanly"; return 1; }
    if grep -q '^uninstall ' "$LOG"; then mods_fail "uninstall ran"; return 1; fi
    log_pass "empty/malformed marketplace rejected, nothing retired"
}

test_mods_receipt_written_before_settings() {
    log_test "mods: the receipt exists before the first plugin install (XACA-1227 ordering)..."
    mods_case order
    mods_run stub _xaca1605_sync_mods
    grep -q '^install ' "$LOG" || { mods_fail "no install calls"; return 1; }
    if grep '^install ' "$LOG" | grep -q 'receipt=no'; then
        mods_fail "an install ran before the receipt was written"; return 1
    fi
    log_pass "receipt precedes every settings write"
}

test_mods_failed_install_not_recorded() {
    log_test "mods: a failed install is reported, not recorded, and does not block the rest..."
    mods_case failinst
    MODS_EXTRA_ENV=(STUB_FAIL_INSTALL="beta@aiteamforge-mods")
    mods_run stub _xaca1605_sync_mods
    MODS_EXTRA_ENV=()
    [[ "$RC" == 1 ]] || { mods_fail "rc $RC, wanted 1"; return 1; }
    [[ "$(mods_plugin alpha@$MP)" == true && "$(mods_plugin gamma@$MP)" == true ]] || { mods_fail "other mods not installed"; return 1; }
    [[ "$(jq -c '.targets | to_entries[0].value.enabled | sort' "$RECEIPT")" == '["alpha@aiteamforge-mods","gamma@aiteamforge-mods"]' ]] \
        || { mods_fail "failed id left in the receipt"; return 1; }
    log_pass "failed install not recorded"
}

test_mods_dry_run_writes_nothing() {
    log_test "mods: --dry-run reports and writes nothing..."
    mods_case dry
    mods_run stub _xaca1605_sync_mods --dry-run
    [[ "$RC" == 0 ]] || { mods_fail "dry-run rc $RC"; return 1; }
    grep -q 'dry-run' <<< "$OUT" || { mods_fail "no dry-run marker"; return 1; }
    [[ ! -e "$SETTINGS" && ! -e "$RECEIPT" && ! -s "$LOG" ]] || { mods_fail "dry-run wrote something"; return 1; }
    log_pass "dry-run is read-only"
}

test_mods_interim_duplicate_warning() {
    log_test "mods: warns while CLAUDE_CODE_PLUGIN_DIRS still lists a ~/.claude/mods copy of a listed mod..."
    mods_case dup
    MODS_EXTRA_ENV=(CLAUDE_CODE_PLUGIN_DIRS="$T/home/.claude/mods/alpha:/elsewhere/x")
    mods_run stub _xaca1605_sync_mods --dry-run
    MODS_EXTRA_ENV=()
    grep -q 'duplicate load.*alpha' <<< "$ERR" || { mods_fail "no duplicate-load warning"; return 1; }
    mods_run stub _xaca1605_sync_mods --dry-run
    if grep -q 'duplicate load' <<< "$ERR"; then mods_fail "warned with no interim dirs"; return 1; fi
    log_pass "duplicate-load warning fires only when relevant"
}

test_mods_uninstall_removes_ours_only() {
    log_test "mods: uninstall removes the marketplace and recorded mods, keeps other plugins, clears the receipt..."
    mods_case uninst
    cat > "$SETTINGS" <<'EOF'
{"enabledPlugins":{"foo@other-market":true}}
EOF
    mods_run stub _xaca1605_sync_mods
    # The shipped-path guard needs the real opt tail; re-register at such a path.
    mkdir -p "$T/x/libexec/share"; cp -R "$T/mods" "$T/x/libexec/share/claude-mods"
    jq --arg p "$T/x/libexec/share/claude-mods" '.extraKnownMarketplaces["aiteamforge-mods"].source.path=$p' "$SETTINGS" > "$T/s.tmp" && mv "$T/s.tmp" "$SETTINGS"
    : > "$LOG"
    mods_run stub _xaca1605_remove_mods
    [[ "$RC" == 0 ]] || { mods_fail "remove rc $RC"; return 1; }
    [[ "$(jq -r --arg m "$MP" '.extraKnownMarketplaces[$m] // "gone"' "$SETTINGS")" == gone ]] || { mods_fail "marketplace still registered"; return 1; }
    [[ "$(mods_plugin alpha@$MP)" == absent ]] || { mods_fail "alpha still present"; return 1; }
    [[ "$(mods_plugin foo@other-market)" == true ]] || { mods_fail "other plugin removed"; return 1; }
    [[ ! -e "$RECEIPT" ]] || { mods_fail "receipt not cleared"; return 1; }
    log_pass "uninstall removes only aiteamforge-mods state"
}

test_mods_real_cli_smoke() {
    log_test "mods: real claude CLI against a folder marketplace (sandboxed config dir)..."
    if [[ -z "$REAL_CLAUDE" ]]; then log_info "claude not installed, skipping real-CLI smoke"; return 0; fi
    mods_case real
    local n
    for n in alpha beta gamma; do
        mkdir -p "$T/mods/$n/.claude-plugin"
        printf '{"name":"%s","version":"0.0.1","description":"fixture"}\n' "$n" > "$T/mods/$n/.claude-plugin/plugin.json"
    done
    mods_run real _xaca1605_sync_mods
    [[ "$RC" == 2 ]] || { mods_fail "real CLI run rc $RC"; return 1; }
    for n in alpha beta gamma; do
        [[ "$(mods_plugin "$n@$MP")" == true ]] || { mods_fail "$n not enabled by the real CLI"; return 1; }
    done
    [[ "$(jq -r --arg m "$MP" '.extraKnownMarketplaces[$m].source.path' "$SETTINGS")" == "$T/mods" ]] \
        || { mods_fail "real CLI did not register the folder path"; return 1; }
    mods_run real _xaca1605_sync_mods
    [[ "$RC" == 0 ]] || { mods_fail "real CLI re-run rc $RC"; return 1; }
    log_pass "real CLI: fresh + idempotent re-run"
}

# Run all tests
main() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Claude Code Configuration Installer - Test Suite"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    local failed=0

    test_installer_exists || failed=$((failed + 1))
    test_templates_exist || failed=$((failed + 1))
    test_template_variables || failed=$((failed + 1))
    test_settings_json_valid || failed=$((failed + 1))
    test_mcp_settings_valid || failed=$((failed + 1))
    test_hooks_executable || failed=$((failed + 1))
    test_hooks_python || failed=$((failed + 1))
    test_patterns_yaml_valid || failed=$((failed + 1))
    test_readme_files || failed=$((failed + 1))
    test_mods_fresh_install || failed=$((failed + 1))
    test_mods_opt_path_not_cellar || failed=$((failed + 1))
    test_mods_upgrade_preserves_existing || failed=$((failed + 1))
    test_mods_idempotent_rerun || failed=$((failed + 1))
    test_mods_retired_mod_removed || failed=$((failed + 1))
    test_mods_retired_but_user_disabled_stays || failed=$((failed + 1))
    test_mods_user_false_preserved_on_upgrade || failed=$((failed + 1))
    test_mods_other_marketplace_untouched || failed=$((failed + 1))
    test_mods_unreadable_receipt_add_only || failed=$((failed + 1))
    test_mods_claude_absent_skips || failed=$((failed + 1))
    test_mods_marketplace_dir_absent_noop || failed=$((failed + 1))
    test_mods_invalid_marketplace_never_retires || failed=$((failed + 1))
    test_mods_receipt_written_before_settings || failed=$((failed + 1))
    test_mods_failed_install_not_recorded || failed=$((failed + 1))
    test_mods_dry_run_writes_nothing || failed=$((failed + 1))
    test_mods_interim_duplicate_warning || failed=$((failed + 1))
    test_mods_uninstall_removes_ours_only || failed=$((failed + 1))
    test_mods_real_cli_smoke || failed=$((failed + 1))

    echo ""
    echo "═══════════════════════════════════════════════════════"
    if [[ $failed -eq 0 ]]; then
        log_pass "All tests passed!"
        echo "═══════════════════════════════════════════════════════"
        return 0
    else
        log_fail "$failed test(s) failed"
        echo "═══════════════════════════════════════════════════════"
        return 1
    fi
}

main "$@"
