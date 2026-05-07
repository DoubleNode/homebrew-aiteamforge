#!/bin/bash

#
#  launch-ccusage-collector.sh
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

# launch-ccusage-collector.sh
# Wrapper that starts the ccusage cache collector daemon in foreground mode.
#
# Designed to be managed by launchd, supervisord, or called directly from
# a process supervisor. exec-replaces the shell so the supervisor tracks
# the Python process PID directly.
#
# launch-lcars.sh starts the collector inline; this wrapper is for
# external supervisors (launchd, supervisord) that want their own PID.
#
# Usage:
#   ./launch-ccusage-collector.sh          # run via supervisor
#   bash launch-ccusage-collector.sh       # ad-hoc foreground run

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "${SCRIPT_DIR}/ccusage_collector.py" --foreground
