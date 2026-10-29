#!/usr/bin/env python3

#
#  test_xaca1676_richmond_server_registration.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
XACA-1676-003: the richmond team is registered in lcars-ui/server.py.

Covers the four server.py registration sites (kanban dir, XAFC prefix
fallback, brand short name, funnel path prefix) and the plugins-manifest
entry (fleet-standard plugin set, connectors on, unlike finance/legal/medical).

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca1676_richmond_server_registration.py -q
"""

import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

LCARS_UI_DIR = Path(__file__).parent.parent
REPO_ROOT = LCARS_UI_DIR.parent
sys.path.insert(0, str(LCARS_UI_DIR))
sys.path.insert(0, str(REPO_ROOT))

_stub_modules = {
    "kanban_utils": MagicMock(
        log_activity=MagicMock(),
        read_activity_log=MagicMock(return_value={"entries": [], "itemId": ""}),
        get_lcars_tmp_dir=MagicMock(return_value="/tmp/"),
    ),
    "integrations": MagicMock(),
    "calendar": MagicMock(),
    "calendar.sync_service": MagicMock(),
    "calendar.apple_provider": MagicMock(),
    "calendar.provider": MagicMock(),
}
for _mod_name, _stub in _stub_modules.items():
    if _mod_name not in sys.modules:
        sys.modules[_mod_name] = _stub

_lcars_team_env_was_set = 'LCARS_TEAM' in os.environ
os.environ.setdefault('LCARS_TEAM', 'academy')
import server  # noqa: E402
if not _lcars_team_env_was_set:
    os.environ.pop('LCARS_TEAM', None)



class RichmondServerRegistration(unittest.TestCase):
    def test_kanban_dir_fallback(self):
        dirs = server._hardcoded_team_kanban_dirs()
        self.assertIn("richmond", dirs)
        self.assertEqual(Path(dirs["richmond"]).parts[-2:], ("richmond", "kanban"))

    def test_brand_short_name(self):
        self.assertEqual(server._BASE_BRAND_SHORT_NAMES["richmond"], "Richmond")

    def test_funnel_path_prefix(self):
        self.assertIn("/richmond", server.LCARSHandler.PATH_PREFIXES)

    def test_team_code_prefix(self):
        # Force the hardcoded fallback arm (registry map empty).
        with patch.object(server, "_aiteamforge_build_team_code_map",
                          return_value={}):
            self.assertEqual(server._build_item_prefix_to_team().get("XAFC"),
                             "richmond")


class RichmondPluginsManifest(unittest.TestCase):
    def test_fleet_standard_plugin_set(self):
        m = json.loads((REPO_ROOT / ".claude" / "plugins-manifest.json").read_text())
        teams = m["teams"]
        self.assertIn("richmond", teams)
        self.assertTrue(teams["richmond"]["deliver"])
        self.assertEqual(teams["richmond"]["enabledPlugins"],
                         teams["academy"]["enabledPlugins"])
        self.assertTrue(teams["richmond"]["enabledPlugins"])


if __name__ == "__main__":
    unittest.main()
