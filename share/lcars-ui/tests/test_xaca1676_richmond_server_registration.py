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


def _load_kb_sync_plugins(manifest):
    """Import scripts/kb-sync-plugins (no .py suffix) with MANIFEST pinned to THIS checkout's manifest; it is
    resolved at import time, so KBSPL_MANIFEST must be set before the module executes."""
    from importlib.machinery import SourceFileLoader
    from importlib.util import module_from_spec, spec_from_loader
    loader = SourceFileLoader("kb_sync_plugins_xaca1676", str(REPO_ROOT / "scripts" / "kb-sync-plugins"))
    mod = module_from_spec(spec_from_loader(loader.name, loader))
    with patch.dict(os.environ, {"KBSPL_MANIFEST": str(manifest)}):
        loader.exec_module(mod)
    return mod


class RichmondPluginsManifest(unittest.TestCase):
    def test_fleet_standard_plugin_set(self):
        # XACA-1643 replaced the per-team `teams` lists with one fleet list rendered per team by
        # kb-sync-plugins' effective_team_cfg() (the only place a team's list is computed), so the
        # XACA-1676 intent -- richmond is delivered the fleet-standard set, same as academy -- is
        # asserted through that renderer rather than on raw manifest keys.
        manifest = REPO_ROOT / ".claude" / "plugins-manifest.json"
        ksp = _load_kb_sync_plugins(manifest)
        m = ksp.load_manifest()
        self.assertIn("richmond", m["teamTargets"])
        self.assertTrue(m["teamTargets"]["richmond"]["deliver"])
        richmond = ksp.effective_team_cfg(m, "richmond")["enabledPlugins"]
        academy = ksp.effective_team_cfg(m, "academy")["enabledPlugins"]
        self.assertEqual(richmond, academy)
        self.assertTrue(richmond)
        self.assertTrue(all(richmond.values()), "richmond must not lose any fleet plugin to an exception")


if __name__ == "__main__":
    unittest.main()
