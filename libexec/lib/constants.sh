#!/bin/bash
# constants.sh
# Single source of truth for shared shell constants used across the homebrew-tap.
# Source from any tap script that needs these defaults; env-var overrides still
# win (the `:=` operator only sets the variable when unset).
#
# Added by XACA-0516 to eliminate the sibling-drift pattern that XACA-0510 and
# XACA-0512 worked around with paired "NOTE: change one, change the other"
# comments. See XACA-0510-013 ([Review] subitem from PR #30) for origin.

# Kanban backup cadence (seconds). 900s = 15 minutes.
# Consumers:
#   - libexec/installers/install-kanban.sh
#   - libexec/commands/aiteamforge-upgrade.sh
#   - libexec/commands/aiteamforge-migrate.sh
#
# Consumers resolve the runtime value with ${KANBAN_BACKUP_INTERVAL:-$KANBAN_BACKUP_INTERVAL_DEFAULT}.
# The `:-` operator substitutes the default when the variable is unset OR empty,
# so setting KANBAN_BACKUP_INTERVAL='' explicitly falls through to 900 — empty
# strings never reach the rendered plist as a literal empty interval. To force
# a non-default cadence, set KANBAN_BACKUP_INTERVAL to a positive integer
# (e.g., KANBAN_BACKUP_INTERVAL=1800 for 30 minutes).
: "${KANBAN_BACKUP_INTERVAL_DEFAULT:=900}"
readonly KANBAN_BACKUP_INTERVAL_DEFAULT
