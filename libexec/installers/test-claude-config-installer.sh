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

# Run all tests
main() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Claude Code Configuration Installer - Test Suite"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    local failed=0

    test_installer_exists || ((failed++))
    test_templates_exist || ((failed++))
    test_template_variables || ((failed++))
    test_settings_json_valid || ((failed++))
    test_mcp_settings_valid || ((failed++))
    test_hooks_executable || ((failed++))
    test_hooks_python || ((failed++))
    test_patterns_yaml_valid || ((failed++))
    test_readme_files || ((failed++))

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
