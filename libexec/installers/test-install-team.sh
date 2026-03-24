#!/bin/bash
# Test script for team installer
# Runs a dry-run installation to verify team definitions work

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="/tmp/aiteamforge-test-$$"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Testing Team Installer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Test directory: $TEST_DIR"
echo ""

# Create test directory
mkdir -p "$TEST_DIR"

# Test each team definition
TEAMS_DIR="$SCRIPT_DIR/../../share/teams"
TEAMS_TESTED=0
TEAMS_PASSED=0
TEAMS_FAILED=0

for conf in "$TEAMS_DIR"/*.conf; do
    if [[ -f "$conf" ]]; then
        TEAM_ID=$(basename "$conf" .conf)

        echo "────────────────────────────────────────────────────────"
        echo "Testing team: $TEAM_ID"
        echo ""

        # Try to load the configuration
        if source "$conf"; then
            echo "  ✓ Configuration loaded successfully"
            echo "    Name: $TEAM_NAME"
            echo "    Category: $TEAM_CATEGORY"
            echo "    Agents: ${#TEAM_AGENTS[@]}"
            echo "    Brew deps: ${#TEAM_BREW_DEPS[@]}"

            # Validate required variables
            VALIDATION_OK=true

            if [[ -z "$TEAM_ID" ]]; then
                echo "  ✗ Missing TEAM_ID"
                VALIDATION_OK=false
            fi

            if [[ -z "$TEAM_NAME" ]]; then
                echo "  ✗ Missing TEAM_NAME"
                VALIDATION_OK=false
            fi

            if [[ -z "$TEAM_CATEGORY" ]]; then
                echo "  ✗ Missing TEAM_CATEGORY"
                VALIDATION_OK=false
            fi

            if [[ -z "$TEAM_STARTUP_SCRIPT" ]]; then
                echo "  ✗ Missing TEAM_STARTUP_SCRIPT"
                VALIDATION_OK=false
            fi

            if [[ -z "$TEAM_SHUTDOWN_SCRIPT" ]]; then
                echo "  ✗ Missing TEAM_SHUTDOWN_SCRIPT"
                VALIDATION_OK=false
            fi

            if $VALIDATION_OK; then
                echo "  ✓ Validation passed"
                TEAMS_PASSED=$((TEAMS_PASSED + 1))
            else
                echo "  ✗ Validation failed"
                TEAMS_FAILED=$((TEAMS_FAILED + 1))
            fi
        else
            echo "  ✗ Failed to load configuration"
            TEAMS_FAILED=$((TEAMS_FAILED + 1))
        fi

        TEAMS_TESTED=$((TEAMS_TESTED + 1))
        echo ""
    fi
done

# Test the installer script itself (syntax check)
echo "────────────────────────────────────────────────────────"
echo "Testing installer script syntax..."
if bash -n "$SCRIPT_DIR/install-team.sh"; then
    echo "  ✓ Installer script syntax is valid"
else
    echo "  ✗ Installer script has syntax errors"
    TEAMS_FAILED=$((TEAMS_FAILED + 1))
fi
echo ""

# Test registry.json
echo "────────────────────────────────────────────────────────"
echo "Testing team registry..."
REGISTRY_FILE="$TEAMS_DIR/registry.json"
if [[ -f "$REGISTRY_FILE" ]]; then
    if command -v jq &>/dev/null; then
        if jq empty "$REGISTRY_FILE" 2>/dev/null; then
            echo "  ✓ Registry JSON is valid"

            # Count teams in registry
            REGISTRY_TEAMS=$(jq -r '.teams | length' "$REGISTRY_FILE")
            echo "    Teams in registry: $REGISTRY_TEAMS"

            # Verify each team in registry has a corresponding .conf file
            MISSING_CONFS=0
            while IFS= read -r team_id; do
                if [[ ! -f "$TEAMS_DIR/$team_id.conf" ]]; then
                    echo "  ⚠️  Registry contains team '$team_id' but no .conf file exists"
                    MISSING_CONFS=$((MISSING_CONFS + 1))
                fi
            done < <(jq -r '.teams[].id' "$REGISTRY_FILE")

            if [[ $MISSING_CONFS -eq 0 ]]; then
                echo "  ✓ All registry teams have configuration files"
            else
                echo "  ✗ $MISSING_CONFS teams missing configuration files"
            fi
        else
            echo "  ✗ Registry JSON is invalid"
        fi
    else
        echo "  ⚠️  jq not installed, skipping JSON validation"
    fi
else
    echo "  ✗ Registry file not found: $REGISTRY_FILE"
fi
echo ""

# Cleanup
rm -rf "$TEST_DIR"

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Test Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Teams tested: $TEAMS_TESTED"
echo "Teams passed: $TEAMS_PASSED"
echo "Teams failed: $TEAMS_FAILED"
echo ""

if [[ $TEAMS_FAILED -eq 0 ]]; then
    echo "✅ All tests passed!"
    exit 0
else
    echo "❌ Some tests failed"
    exit 1
fi
