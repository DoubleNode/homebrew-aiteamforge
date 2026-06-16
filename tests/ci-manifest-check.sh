#!/usr/bin/env bash
# ci-manifest-check.sh — XACA-0707 manifest-completeness gate
#
# FAIL when:
#   1. A tests/test-*.sh file on disk is absent from ci-manifest (drift risk)
#   2. ci-manifest lists a file that no longer exists on disk (stale entry)
#   3. A non-comment, non-blank line has an invalid category
#
# Invoke: bash tests/ci-manifest-check.sh
# Exit 0 = manifest and disk agree; exit 1 = drift or malformed entry detected.
#
# Valid categories: plain-shell | brew-bash | real-install | excluded:<reason>
# "excluded" with no reason suffix is rejected (reason is mandatory).

set -euo pipefail

# ---------------------------------------------------------------------------
# Self-locate so the script works from any CWD
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$SCRIPT_DIR"
MANIFEST="$TESTS_DIR/ci-manifest"

# ---------------------------------------------------------------------------
# Validate manifest exists
# ---------------------------------------------------------------------------
if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: manifest not found at $MANIFEST" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Valid category pattern
# plain-shell | brew-bash | real-install | excluded:<non-empty-reason>
# ---------------------------------------------------------------------------
VALID_CATEGORY_RE='^(plain-shell|brew-bash|real-install|excluded:.+)$'

# ---------------------------------------------------------------------------
# Parse manifest: collect classified filenames + validate category syntax
# ---------------------------------------------------------------------------
declare -A manifest_entries  # filename -> category
malformed_lines=()
line_num=0

while IFS= read -r line; do
    line_num=$(( line_num + 1 ))
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]]  && continue

    filename=$(awk '{print $1}' <<< "$line")
    category=$(awk '{print $2}' <<< "$line")

    # Validate category
    if [[ -z "$category" ]] || ! [[ "$category" =~ $VALID_CATEGORY_RE ]]; then
        malformed_lines+=("  line $line_num: '$line'")
        continue
    fi

    manifest_entries["$filename"]="$category"
done < "$MANIFEST"

# ---------------------------------------------------------------------------
# Enumerate on-disk test files
# ---------------------------------------------------------------------------
disk_files=()
while IFS= read -r -d '' f; do
    disk_files+=("$(basename "$f")")
done < <(find "$TESTS_DIR" -maxdepth 1 -name 'test-*.sh' -print0 | LC_ALL=C sort -z)

# ---------------------------------------------------------------------------
# Compare: find unclassified (on disk but absent from manifest)
# ---------------------------------------------------------------------------
unclassified=()
for f in "${disk_files[@]}"; do
    if [[ -z "${manifest_entries[$f]+set}" ]]; then
        unclassified+=("$f")
    fi
done

# ---------------------------------------------------------------------------
# Compare: find dangling (in manifest but absent from disk)
# ---------------------------------------------------------------------------
dangling=()
for f in "${!manifest_entries[@]}"; do
    if [[ ! -f "$TESTS_DIR/$f" ]]; then
        dangling+=("$f")
    fi
done
# Sort for stable output
IFS=$'\n' dangling=($(LC_ALL=C sort <<< "${dangling[*]+${dangling[*]}}")); unset IFS

# ---------------------------------------------------------------------------
# Tally per-category counts for the success line
# ---------------------------------------------------------------------------
declare -A category_counts
for cat in "${manifest_entries[@]}"; do
    # Normalise excluded:* into "excluded"
    key="${cat%%:*}"
    category_counts["$key"]=$(( ${category_counts["$key"]:-0} + 1 ))
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
exit_code=0

if [[ ${#malformed_lines[@]} -gt 0 ]]; then
    echo "FAIL: ${#malformed_lines[@]} malformed manifest line(s):"
    for m in "${malformed_lines[@]}"; do
        echo "$m"
    done
    echo "  Valid categories: plain-shell | brew-bash | real-install | excluded:<reason>"
    exit_code=1
fi

if [[ ${#unclassified[@]} -gt 0 ]]; then
    echo "FAIL: ${#unclassified[@]} test file(s) on disk NOT in ci-manifest:"
    for f in "${unclassified[@]}"; do
        echo "  $f  <category>   # add to tests/ci-manifest with the correct category"
    done
    exit_code=1
fi

if [[ ${#dangling[@]} -gt 0 ]]; then
    echo "FAIL: ${#dangling[@]} manifest entry(s) whose file no longer exists on disk:"
    for f in "${dangling[@]}"; do
        echo "  $f   # remove from tests/ci-manifest"
    done
    exit_code=1
fi

if [[ $exit_code -eq 0 ]]; then
    total="${#manifest_entries[@]}"
    ps="${category_counts[plain-shell]:-0}"
    bb="${category_counts[brew-bash]:-0}"
    ri="${category_counts[real-install]:-0}"
    ex="${category_counts[excluded]:-0}"
    echo "OK: ci-manifest complete — ${total} entries (plain-shell=${ps}, brew-bash=${bb}, real-install=${ri}, excluded=${ex})"
fi

exit $exit_code
