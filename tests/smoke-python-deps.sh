#!/usr/bin/env bash
# smoke-python-deps.sh — End-to-end smoke test for AITeamForge Python deps
#
# Tests that pyzipper is installed in the tap-owned venv and works correctly.
# Safe to run both pre-install (venv absent → clear error) and post-install.
#
# Usage:
#   bash tests/smoke-python-deps.sh
#   AITEAMFORGE_PYTHON=/path/to/venv/bin/python3 bash tests/smoke-python-deps.sh
#
# Exit codes:
#   0 — all tests passed
#   1 — failure (pyzipper import error, roundtrip mismatch, or venv missing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

_pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
_fail() { echo "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "=== AITeamForge Python Deps Smoke Test ==="
echo ""

# ------------------------------------------------------------------
# Step 1: Resolve AITEAMFORGE_PYTHON
# ------------------------------------------------------------------
echo "--- Step 1: Resolve AITEAMFORGE_PYTHON ---"

if [ -z "${AITEAMFORGE_PYTHON:-}" ]; then
    # Try to source python-env.sh relative to this script (dev-mode run from tests/)
    PYTHON_ENV_SH="$SCRIPT_DIR/../libexec/lib/python-env.sh"
    if [ -f "$PYTHON_ENV_SH" ]; then
        # shellcheck source=/dev/null
        . "$PYTHON_ENV_SH"
    else
        # Fallback: probe $HOMEBREW_PREFIX directly (brew-installed run)
        for _prefix in "${HOMEBREW_PREFIX:-}" "/opt/homebrew" "/usr/local"; do
            [ -z "$_prefix" ] && continue
            if [ -f "$_prefix/var/aiteamforge/env.sh" ]; then
                # shellcheck source=/dev/null
                . "$_prefix/var/aiteamforge/env.sh"
                break
            fi
        done
        unset _prefix
    fi
fi

# After sourcing, check if AITEAMFORGE_PYTHON is set and executable
if [ -z "${AITEAMFORGE_PYTHON:-}" ]; then
    echo ""
    echo "ERROR: AITEAMFORGE_PYTHON is not set and could not be resolved."
    echo "       The tap-owned venv may not be provisioned yet."
    echo "       Run: brew reinstall aiteamforge"
    echo ""
    echo "RESULT: FAIL (venv not provisioned)"
    exit 1
fi

if [ ! -x "$AITEAMFORGE_PYTHON" ]; then
    # Check if this is the fallback "python3" bare name (venv warned but not present)
    if [ "$AITEAMFORGE_PYTHON" = "python3" ]; then
        echo ""
        echo "ERROR: AITEAMFORGE_PYTHON resolved to bare 'python3' (venv fallback)."
        echo "       The tap-owned venv is not installed."
        echo "       Run: brew reinstall aiteamforge"
        echo ""
        echo "RESULT: FAIL (venv not provisioned)"
        exit 1
    fi
    echo ""
    echo "ERROR: AITEAMFORGE_PYTHON='$AITEAMFORGE_PYTHON' is not executable."
    echo "       Run: brew reinstall aiteamforge"
    echo ""
    echo "RESULT: FAIL (Python not executable)"
    exit 1
fi

echo "AITEAMFORGE_PYTHON = $AITEAMFORGE_PYTHON"
PYTHON_VERSION=$("$AITEAMFORGE_PYTHON" --version 2>&1)
echo "Python version: $PYTHON_VERSION"
_pass "AITEAMFORGE_PYTHON is set and executable"
echo ""

# ------------------------------------------------------------------
# Step 2: Verify pyzipper import and version
# ------------------------------------------------------------------
echo "--- Step 2: pyzipper import ---"

if ! PYZIPPER_VERSION=$("$AITEAMFORGE_PYTHON" -c "import pyzipper; print(pyzipper.__version__)" 2>&1); then
    _fail "pyzipper import failed: $PYZIPPER_VERSION"
    echo ""
    echo "RESULT: FAIL"
    exit 1
fi

echo "pyzipper version: $PYZIPPER_VERSION"
_pass "pyzipper imports successfully (version $PYZIPPER_VERSION)"
echo ""

# ------------------------------------------------------------------
# Step 3: AES-256 roundtrip functional smoke
# ------------------------------------------------------------------
echo "--- Step 3: AES-256 roundtrip ---"

if ! ROUNDTRIP_RESULT=$("$AITEAMFORGE_PYTHON" - <<'PYEOF'
import pyzipper, tempfile, os, sys

pw  = b"test-xaca-0175"
msg = b"XACA-0175 inaugural smoke test"

try:
    with tempfile.TemporaryDirectory() as d:
        zip_path = os.path.join(d, "smoke.zip")

        # Write: AES-encrypted LZMA-compressed zip
        with pyzipper.AESZipFile(zip_path, 'w',
                                 compression=pyzipper.ZIP_LZMA,
                                 encryption=pyzipper.WZ_AES) as zf:
            zf.setpassword(pw)
            zf.writestr("payload.txt", msg)

        # Read: decrypt and verify
        with pyzipper.AESZipFile(zip_path) as zf:
            zf.setpassword(pw)
            got = zf.read("payload.txt")

        assert got == msg, f"roundtrip mismatch: got={got!r}, want={msg!r}"
        print(f"OK: {len(msg)} bytes roundtripped (AES-256/LZMA)")
        sys.exit(0)

except AssertionError as e:
    print(f"MISMATCH: {e}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"ERROR: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(2)
PYEOF
); then
    _fail "AES-256 roundtrip failed: $ROUNDTRIP_RESULT"
    echo ""
    echo "RESULT: FAIL"
    exit 1
fi

echo "$ROUNDTRIP_RESULT"
_pass "AES-256 roundtrip succeeded"
echo ""

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "=== Results: $PASS_COUNT/$TOTAL passed ==="
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo "RESULT: PASS"
    exit 0
else
    echo "RESULT: FAIL ($FAIL_COUNT failed)"
    exit 1
fi
