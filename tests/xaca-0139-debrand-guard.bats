#!/usr/bin/env bats
# XACA-0139: De-brand guard — shipped live code must be client-agnostic
#
# This test verifies that no unmarked client-brand references (Main Event,
# DoubleNode) appear in shipped live-code paths.  Justified survivors from
# subitems 002–007 must be annotated with a # xaca-0139:allowed marker on
# the same line or the line immediately above the hit.
#
# Scanned directories (live shipped code — must be client-agnostic):
#   homebrew-tap/libexec/       — shell libs & commands
#   homebrew-tap/share/kanban-hooks/  — Python hooks
#   homebrew-tap/share/scripts/ — utility scripts
#   homebrew-tap/share/templates/ — installer templates
#   homebrew-tap/bin/           — entry-point scripts
#
# Forbidden pattern (case-sensitive):
#   [Mm]ain ?[Ee]vent|MainEvent|MAIN ?EVENT|[Dd]ouble[Nn]ode|doublenode|DOUBLENODE
#
# Allow strategy:
#   Each surviving reference must be annotated with:
#     # xaca-0139:allowed — <reason>
#   on the same line or the line immediately above the hit.
#
# To add a new justified survivor:
#   Add  # xaca-0139:allowed — <reason>  as a trailing comment or on the
#   line above the hit.  Run this test to confirm it passes.
#
# To add a new violation:
#   Do NOT add a marker.  The test will fail and identify the file:line.
#   Fix the branding issue instead (use {{ORG_NAME}} templates or resolver).

FORBIDDEN='[Mm]ain ?[Ee]vent|MainEvent|MAIN ?EVENT|[Dd]ouble[Nn]ode|doublenode|DOUBLENODE'
SCANNED_DIRS=(libexec share/kanban-hooks share/scripts share/templates bin)
TAP_ROOT="${BATS_TEST_DIRNAME}/.."

@test "xaca-0139: no unmarked client-brand references in shipped live code" {
  cd "$TAP_ROOT"

  local violations=()

  while IFS= read -r hit; do
    # hit format: "relpath/to/file:LINENO:content"
    local file lineno
    file="${hit%%:*}"
    local rest="${hit#*:}"
    lineno="${rest%%:*}"

    # Validate that lineno is numeric (guard against paths with colons)
    if ! [[ "$lineno" =~ ^[0-9]+$ ]]; then
      continue
    fi

    # Check same line for the allow-marker
    local same_line_marker=0
    same_line_marker=$(sed -n "${lineno}p" "$file" 2>/dev/null | grep -c 'xaca-0139:allowed' || true)

    # Check the line immediately above for the allow-marker
    local above_line_marker=0
    if (( lineno > 1 )); then
      above_line_marker=$(sed -n "$((lineno-1))p" "$file" 2>/dev/null | grep -c 'xaca-0139:allowed' || true)
    fi

    if (( same_line_marker == 0 && above_line_marker == 0 )); then
      violations+=("$hit")
    fi
  done < <(grep -rnE "$FORBIDDEN" "${SCANNED_DIRS[@]}" 2>/dev/null \
            | grep -v '\.bats:' \
            | grep -v 'xaca-0139:allowed' \
            || true)

  if (( ${#violations[@]} > 0 )); then
    echo "" >&2
    echo "UNMARKED client-brand reference(s) found." >&2
    echo "Either fix the branding (prefer {{ORG_NAME}} or resolver) or add:" >&2
    echo "  # xaca-0139:allowed — <reason>" >&2
    echo "on the same line or the line above each hit." >&2
    echo "" >&2
    echo "Violations (${#violations[@]}):" >&2
    local v
    for v in "${violations[@]}"; do
      printf '  %s\n' "$v" >&2
    done
    return 1
  fi
}
