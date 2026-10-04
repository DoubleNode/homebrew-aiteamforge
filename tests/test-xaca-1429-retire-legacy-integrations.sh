#!/bin/bash
# test-xaca-1429-retire-legacy-integrations.sh
#
# XACA-1429: kanban-hooks/integrations/ (credential store) was renamed to
# kanban-hooks/kanban_credentials/ because LCARS puts kanban-hooks/ at
# sys.path[0] and a package named `integrations` there shadows
# lcars-ui/integrations, disabling every LCARS import/sync endpoint.
#
# install_kanban_hooks (cp -r) and update_kanban_hooks (rsync, no --delete) are
# both additive, so an upgraded or re-installed machine would keep the old
# directory and keep the bug. retire_legacy_kanban_integrations moves it aside.
#
# This suite proves, under the scripts' own `set -eo pipefail` and /bin/bash:
#   1. absent legacy dir        -> no-op, rc 0
#   2. shipped-files-only dir   -> moved to integrations.xaca-1429-retired-*
#   3. .DS_Store + __pycache__  -> still treated as shipped, moved
#   4. unexpected operator file -> left in place, warning, rc 0
#   5. end-to-end: after retirement, server-style sys.path order resolves
#      `integrations` to lcars-ui and `from integrations import get_manager`
#      works (uses the tap's share/ copies, no network, sandbox only)
#   6. both scripts define the helper and call it after their copy step

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$TAP_ROOT/libexec/installers/install-kanban.sh"
UPGRADE="$TAP_ROOT/libexec/commands/aiteamforge-upgrade.sh"

TEST_TMP_DIR="$(mktemp -d)"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$TEST_TMP_DIR"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# Extract the helper verbatim from a script (function body ends at the first
# line that is exactly "}").
extract_helper() {
  awk '/^retire_legacy_kanban_integrations\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$1"
}

make_legacy() {
  local hooks="$1"
  mkdir -p "$hooks/integrations"
  local f
  for f in __init__.py credential_cli.py credential_store.py jira_provider.py keychain.py; do
    echo "# legacy $f" > "$hooks/integrations/$f"
  done
}

run_case() {
  # $1 = script to take the helper from, $2 = hooks dir; prints helper output
  local src="$1" hooks="$2"
  /bin/bash -c '
    set -eo pipefail
    info() { echo "INFO: $*"; }
    warning() { echo "WARN: $*"; }
    print_info() { echo "INFO: $*"; }
    print_warning() { echo "WARN: $*"; }
    eval "$1"
    retire_legacy_kanban_integrations "$2"
    echo "RC0"
  ' _ "$(extract_helper "$src")" "$hooks"
}

for src in "$INSTALLER" "$UPGRADE"; do
  label="$(basename "$src")"
  echo "== $label =="

  if [ -n "$(extract_helper "$src")" ]; then pass "$label defines helper"; else fail "$label defines helper"; continue; fi

  # 1. absent
  h="$TEST_TMP_DIR/$label/absent/kanban-hooks"; mkdir -p "$h"
  out="$(run_case "$src" "$h")"
  if echo "$out" | grep -q RC0 && [ ! -e "$h/integrations" ]; then pass "absent: no-op"; else fail "absent: no-op ($out)"; fi

  # 2. shipped files only
  h="$TEST_TMP_DIR/$label/shipped/kanban-hooks"; make_legacy "$h"
  out="$(run_case "$src" "$h")"
  if [ ! -e "$h/integrations" ] && ls -d "$h"/integrations.xaca-1429-retired-* >/dev/null 2>&1 && echo "$out" | grep -q RC0; then
    pass "shipped-only: moved aside"
  else
    fail "shipped-only: moved aside ($out)"
  fi
  if [ -f "$(ls -d "$h"/integrations.xaca-1429-retired-* | head -1)/credential_store.py" ]; then pass "shipped-only: content preserved"; else fail "shipped-only: content preserved"; fi

  # 3. .DS_Store + __pycache__
  h="$TEST_TMP_DIR/$label/dsstore/kanban-hooks"; make_legacy "$h"
  touch "$h/integrations/.DS_Store"; mkdir -p "$h/integrations/__pycache__"
  out="$(run_case "$src" "$h")"
  if [ ! -e "$h/integrations" ] && echo "$out" | grep -q RC0; then pass ".DS_Store/__pycache__: moved aside"; else fail ".DS_Store/__pycache__: moved aside ($out)"; fi

  # 4. unexpected operator file
  h="$TEST_TMP_DIR/$label/operator/kanban-hooks"; make_legacy "$h"
  echo "# mine" > "$h/integrations/my_tool.py"
  out="$(run_case "$src" "$h")"
  if [ -f "$h/integrations/my_tool.py" ] && echo "$out" | grep -q "WARN:.*my_tool.py" && echo "$out" | grep -q RC0; then
    pass "operator file: left in place with warning, rc 0"
  else
    fail "operator file: left in place with warning, rc 0 ($out)"
  fi
done

# 5. end-to-end import resolution against the tap's shipped copies
echo "== end-to-end =="
E2E="$TEST_TMP_DIR/e2e"
mkdir -p "$E2E"
cp -R "$TAP_ROOT/share/lcars-ui/integrations" "$E2E/lcars-integrations"
mkdir -p "$E2E/lcars-ui" "$E2E/kanban-hooks"
mv "$E2E/lcars-integrations" "$E2E/lcars-ui/integrations"
cp -R "$TAP_ROOT/share/kanban-hooks/kanban_credentials" "$E2E/kanban-hooks/kanban_credentials"
[ -f "$TAP_ROOT/share/kanban-hooks/aiteamforge_paths.py" ] && cp "$TAP_ROOT/share/kanban-hooks/aiteamforge_paths.py" "$E2E/kanban-hooks/"
make_legacy "$E2E/kanban-hooks"
# Make the legacy package look like the real one (it must SHADOW to prove the fix).
echo "from .credential_store import *" > "$E2E/kanban-hooks/integrations/__init__.py"
echo "x = 1" > "$E2E/kanban-hooks/integrations/credential_store.py"

probe() {
  (cd "$E2E/lcars-ui" && HOME="$E2E/home" python3 -c '
import os, sys
sys.path.insert(0, os.path.abspath("../kanban-hooks"))
import integrations
print("FILE=" + integrations.__file__)
from integrations import get_manager
print("OK")
' 2>&1) || true
}

before="$(probe)"
if echo "$before" | grep -q "kanban-hooks/integrations"; then pass "precondition: legacy dir shadows lcars-ui"; else fail "precondition: legacy dir shadows lcars-ui ($before)"; fi

run_case "$UPGRADE" "$E2E/kanban-hooks" >/dev/null
after="$(probe)"
if echo "$after" | grep -q "FILE=.*lcars-ui/integrations" && echo "$after" | grep -q "^OK$"; then
  pass "after retirement: integrations resolves to lcars-ui, get_manager imports"
else
  fail "after retirement: integrations resolves to lcars-ui ($after)"
fi

# 6. call sites
if awk '/^install_kanban_hooks\(\) \{/{p=1} p&&/retire_legacy_kanban_integrations "\$hooks_dest"/{f=1} p&&/^\}$/{exit} END{exit !f}' "$INSTALLER"; then
  pass "install_kanban_hooks calls helper"
else
  fail "install_kanban_hooks calls helper"
fi
if awk '/^update_kanban_hooks\(\) \{/{p=1} p&&/retire_legacy_kanban_integrations "\$\{hooks_target\}"/{f=1} p&&/^\}$/{exit} END{exit !f}' "$UPGRADE"; then
  pass "update_kanban_hooks calls helper"
else
  fail "update_kanban_hooks calls helper"
fi

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
