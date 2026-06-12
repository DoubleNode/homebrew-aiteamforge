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

# Fleet monitor HTTP server port. 3000 is the conventional default; override
# via FLEET_MONITOR_PORT env var before sourcing.
# Consumers:
#   - libexec/installers/install-fleet-monitor.sh
#   - libexec/commands/aiteamforge-migrate.sh
#
# Consumers resolve the runtime value with ${FLEET_MONITOR_PORT:-$FLEET_MONITOR_PORT_DEFAULT}.
: "${FLEET_MONITOR_PORT_DEFAULT:=3000}"
readonly FLEET_MONITOR_PORT_DEFAULT

# Fleet monitor port-scan range. Ports probed (in order) when locating a running
# Fleet Monitor HTTP server. 3000 is FLEET_MONITOR_PORT_DEFAULT; the range covers
# the default plus two fallback ports. Override via FLEET_MONITOR_PORT_SCAN_RANGE
# (space-delimited) before sourcing.
# Consumers:
#   - libexec/commands/aiteamforge-start.sh   (2 sites)
#   - libexec/commands/aiteamforge-status.sh
#   - libexec/commands/aiteamforge-doctor.sh
#
# Consumers iterate with:  for port in $FLEET_MONITOR_PORT_SCAN_RANGE; do
# (intentional word-splitting — add `# shellcheck disable=SC2086` at the loop).
: "${FLEET_MONITOR_PORT_SCAN_RANGE:=3000 3001 3002}"
readonly FLEET_MONITOR_PORT_SCAN_RANGE

# Homebrew tap name. Single source of truth for the "<org>/<tap>" identifier used
# in `brew tap`, `brew trust --tap`, and untrusted-tap detection. Override via
# AITF_TAP_NAME before sourcing (e.g. a fork that re-taps under a different org).
#
# XACA-0676: recent Homebrew gates formula loading behind tap-trust when
# $HOMEBREW_REQUIRE_TAP_TRUST is set; an untrusted tap makes `brew outdated`/
# `brew upgrade` silently no-op, leaving a box stuck on an old version. The trust
# helpers in libexec/lib/common.sh (ensure_tap_trusted / tap_load_refused) resolve
# the tap with ${AITF_TAP_NAME:-$AITF_TAP_NAME_DEFAULT}.
# Consumers:
#   - libexec/lib/common.sh                    (ensure_tap_trusted / tap_load_refused)
#   - libexec/commands/aiteamforge-upgrade.sh  (check_brew_updates)
#   - libexec/commands/aiteamforge-doctor.sh   (check_tap_trust)
#   - bin/aiteamforge-setup.sh                 (post-dependency trust)
: "${AITF_TAP_NAME_DEFAULT:=doublenode/aiteamforge}"
readonly AITF_TAP_NAME_DEFAULT
