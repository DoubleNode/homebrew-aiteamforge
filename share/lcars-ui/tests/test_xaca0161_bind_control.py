#!/usr/bin/env python3

#
#  test_xaca0161_bind_control.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""
Unit tests for the XACA-0161-006 LCARS network-layer bind control.

Before this change main() bound ("", port) — every interface — so anything on
the same LAN could reach the dashboard's TCP port. These tests pin the
replacement's contract, and in particular the property that matters most:
**no code path may silently widen the bind**. Every mode either returns a
narrow address set or refuses to start; the all-interfaces behaviour is
reachable only through two separate, explicit environment variables.

Tests cover:
  1.  Default (no env)                     -> loopback + tailscale ip
  2.  mode=loopback                        -> loopback ONLY
  3.  mode=tailscale, ip found             -> loopback + tailscale ip
  4.  mode=tailscale, ip NOT found         -> SystemExit (strict/fail-closed)
  5.  mode=auto, ip NOT found              -> loopback ONLY, never ""
  6.  mode=all without confirmation        -> SystemExit
  7.  mode=all WITH confirmation           -> [""] + loud stderr warning
  8.  Invalid mode                         -> SystemExit
  9.  Mode is case/whitespace tolerant
  10. LCARS_TAILSCALE_IP valid override    -> used verbatim
  11. LCARS_TAILSCALE_IP outside CGNAT     -> SystemExit (never ignored)
  12. CGNAT validator accepts/rejects correctly
  13. Detection never returns a non-tailnet address even if tooling emits one

Run with:
    python3 -m pytest lcars-ui/tests/test_xaca0161_bind_control.py -q
"""

import io
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Bootstrap: import server.py without launching a server or touching real dirs.
# Mirrors test_xaca0463_guard.py's bootstrap.
# ---------------------------------------------------------------------------

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

import server  # noqa: E402

# A syntactically valid Tailscale CGNAT address for fixtures. Not this or any
# other machine's real address — the tests must not depend on tailscaled.
FAKE_TS_IP = "100.101.102.103"

# Every bind-related variable, cleared before each test so a developer's own
# exported LCARS_BIND_MODE cannot silently change what these tests assert.
_BIND_ENV_VARS = (
    "LCARS_BIND_MODE",
    "LCARS_BIND_ALLOW_ALL_INTERFACES",
    "LCARS_TAILSCALE_IP",
)


class BindControlTestBase(unittest.TestCase):
    """Isolates each test from ambient env and from real Tailscale detection."""

    def setUp(self):
        self._env_patch = patch.dict(os.environ, {}, clear=False)
        self._env_patch.start()
        for var in _BIND_ENV_VARS:
            os.environ.pop(var, None)

    def tearDown(self):
        self._env_patch.stop()

    def resolve(self, detected_ip=FAKE_TS_IP):
        """Run resolve_bind_addresses_or_die with detection stubbed.

        Returns (hosts, combined_output). Detection is ALWAYS stubbed so the
        result never depends on whether the machine running the suite happens
        to be on a tailnet.
        """
        out = io.StringIO()
        with patch.object(server, "_lcars_detect_tailscale_ipv4", return_value=detected_ip):
            with patch.object(sys, "stdout", out), patch.object(sys, "stderr", out):
                hosts = server.resolve_bind_addresses_or_die()
        return hosts, out.getvalue()

    def resolve_expecting_exit(self, detected_ip=FAKE_TS_IP):
        """Same, but asserts SystemExit and returns (exit_code, output)."""
        out = io.StringIO()
        with patch.object(server, "_lcars_detect_tailscale_ipv4", return_value=detected_ip):
            with patch.object(sys, "stdout", out), patch.object(sys, "stderr", out):
                with self.assertRaises(SystemExit) as ctx:
                    server.resolve_bind_addresses_or_die()
        return ctx.exception.code, out.getvalue()


class TestDefaultAndExplicitModes(BindControlTestBase):

    def test_default_binds_loopback_plus_tailscale(self):
        """No env set: loopback AND the tailnet address, and nothing else."""
        hosts, _ = self.resolve()
        self.assertEqual(hosts, ["127.0.0.1", FAKE_TS_IP])
        self.assertNotIn("", hosts, "default must never include all-interfaces")

    def test_default_posture_line_names_every_bound_address(self):
        """An operator reading logs must be able to see the actual posture."""
        _, output = self.resolve()
        self.assertIn("posture:", output)
        self.assertIn("127.0.0.1", output)
        self.assertIn(FAKE_TS_IP, output)

    def test_loopback_mode_binds_loopback_only(self):
        os.environ["LCARS_BIND_MODE"] = "loopback"
        hosts, _ = self.resolve()
        self.assertEqual(hosts, ["127.0.0.1"])

    def test_loopback_mode_ignores_available_tailscale_ip(self):
        """Asking for loopback means loopback, even when a tailnet ip exists."""
        os.environ["LCARS_BIND_MODE"] = "loopback"
        hosts, _ = self.resolve(detected_ip=FAKE_TS_IP)
        self.assertNotIn(FAKE_TS_IP, hosts)

    def test_tailscale_mode_binds_loopback_plus_tailscale(self):
        os.environ["LCARS_BIND_MODE"] = "tailscale"
        hosts, _ = self.resolve()
        self.assertEqual(hosts, ["127.0.0.1", FAKE_TS_IP])

    def test_tailscale_mode_keeps_loopback_so_local_cockpit_still_works(self):
        """Regression guard: lcars-launch.sh health-checks localhost:PORT.

        Binding the tailnet address *instead of* loopback would break both the
        launcher's readiness probe and the iTerm2 cockpit. Loopback is not
        optional in any non-'all' mode.
        """
        for mode in ("auto", "tailscale", "loopback"):
            with self.subTest(mode=mode):
                os.environ["LCARS_BIND_MODE"] = mode
                hosts, _ = self.resolve()
                self.assertIn("127.0.0.1", hosts)

    def test_mode_is_case_and_whitespace_tolerant(self):
        os.environ["LCARS_BIND_MODE"] = "  LoopBack  "
        hosts, _ = self.resolve()
        self.assertEqual(hosts, ["127.0.0.1"])

    def test_empty_mode_string_falls_back_to_default(self):
        os.environ["LCARS_BIND_MODE"] = ""
        hosts, _ = self.resolve()
        self.assertEqual(hosts, ["127.0.0.1", FAKE_TS_IP])


class TestFailClosedBehaviour(BindControlTestBase):
    """The core property: an undetermined tailnet never widens the bind."""

    def test_auto_without_tailscale_ip_narrows_to_loopback(self):
        hosts, _ = self.resolve(detected_ip=None)
        self.assertEqual(
            hosts, ["127.0.0.1"],
            "auto must fail CLOSED to loopback, never open to all interfaces",
        )

    def test_auto_without_tailscale_ip_never_returns_all_interfaces(self):
        hosts, _ = self.resolve(detected_ip=None)
        self.assertNotIn("", hosts)

    def test_auto_without_tailscale_ip_says_so_out_loud(self):
        """A degraded start must be visible, not silent."""
        _, output = self.resolve(detected_ip=None)
        self.assertIn("NOTICE", output)
        self.assertIn("127.0.0.1", output)

    def test_tailscale_mode_without_ip_refuses_to_start(self):
        """Strict mode: a silent downgrade would be a broken deployment."""
        os.environ["LCARS_BIND_MODE"] = "tailscale"
        code, output = self.resolve_expecting_exit(detected_ip=None)
        self.assertNotEqual(code, 0)
        self.assertIn("FATAL", output)

    def test_tailscale_mode_failure_message_is_actionable(self):
        os.environ["LCARS_BIND_MODE"] = "tailscale"
        _, output = self.resolve_expecting_exit(detected_ip=None)
        self.assertIn("tailscale ip -4", output)
        self.assertIn("LCARS_TAILSCALE_IP", output)

    def test_invalid_mode_refuses_to_start(self):
        os.environ["LCARS_BIND_MODE"] = "bogus"
        code, output = self.resolve_expecting_exit()
        self.assertNotEqual(code, 0)
        self.assertIn("FATAL", output)
        self.assertIn("bogus", output)

    def test_invalid_mode_message_lists_the_valid_ones(self):
        os.environ["LCARS_BIND_MODE"] = "bogus"
        _, output = self.resolve_expecting_exit()
        for mode in ("auto", "loopback", "tailscale", "all"):
            self.assertIn(mode, output)


class TestAllInterfacesEscapeHatch(BindControlTestBase):

    def test_all_mode_without_confirmation_refuses(self):
        """One variable must never be enough to re-open every interface."""
        os.environ["LCARS_BIND_MODE"] = "all"
        code, output = self.resolve_expecting_exit()
        self.assertNotEqual(code, 0)
        self.assertIn("FATAL", output)

    def test_all_mode_refusal_points_at_the_safer_option(self):
        os.environ["LCARS_BIND_MODE"] = "all"
        _, output = self.resolve_expecting_exit()
        self.assertIn("LCARS_BIND_MODE=tailscale", output)

    def test_all_mode_with_confirmation_binds_all_interfaces(self):
        os.environ["LCARS_BIND_MODE"] = "all"
        os.environ["LCARS_BIND_ALLOW_ALL_INTERFACES"] = "1"
        hosts, _ = self.resolve()
        self.assertEqual(hosts, [""])

    def test_all_mode_with_confirmation_warns_loudly(self):
        os.environ["LCARS_BIND_MODE"] = "all"
        os.environ["LCARS_BIND_ALLOW_ALL_INTERFACES"] = "1"
        _, output = self.resolve()
        self.assertIn("WARNING", output)
        self.assertIn("ALL INTERFACES", output)

    def test_confirmation_alone_does_not_widen_the_default(self):
        """The confirmation flag is inert unless mode=all is also set."""
        os.environ["LCARS_BIND_ALLOW_ALL_INTERFACES"] = "1"
        hosts, _ = self.resolve()
        self.assertEqual(hosts, ["127.0.0.1", FAKE_TS_IP])

    def test_truthy_but_not_one_does_not_confirm(self):
        """Only the exact string '1' confirms — not 'true', 'yes', '0'."""
        os.environ["LCARS_BIND_MODE"] = "all"
        for value in ("true", "yes", "0", "TRUE", "on", ""):
            with self.subTest(value=value):
                os.environ["LCARS_BIND_ALLOW_ALL_INTERFACES"] = value
                self.resolve_expecting_exit()


class TestTailscaleIpOverride(BindControlTestBase):

    def test_valid_override_is_used(self):
        os.environ["LCARS_TAILSCALE_IP"] = "100.64.1.2"
        # Detection returns something different; the override must win.
        hosts, _ = self.resolve(detected_ip=FAKE_TS_IP)
        self.assertEqual(hosts, ["127.0.0.1", "100.64.1.2"])

    def test_valid_override_works_without_any_detection(self):
        """An explicit pin must not require tailscaled to be reachable."""
        os.environ["LCARS_BIND_MODE"] = "tailscale"
        os.environ["LCARS_TAILSCALE_IP"] = "100.64.1.2"
        hosts, _ = self.resolve(detected_ip=None)
        self.assertEqual(hosts, ["127.0.0.1", "100.64.1.2"])

    def test_non_cgnat_override_refuses_rather_than_ignoring(self):
        """A LAN address here is a config error, not something to skip past."""
        os.environ["LCARS_TAILSCALE_IP"] = "192.168.1.5"
        code, output = self.resolve_expecting_exit()
        self.assertNotEqual(code, 0)
        self.assertIn("FATAL", output)
        self.assertIn("100.64.0.0/10", output)

    def test_wildcard_override_is_rejected(self):
        """0.0.0.0 must not be smuggled in through the override."""
        os.environ["LCARS_TAILSCALE_IP"] = "0.0.0.0"
        self.resolve_expecting_exit()

    def test_garbage_override_is_rejected(self):
        for value in ("not-an-ip", "100.64.1", "999.999.999.999", "::1"):
            with self.subTest(value=value):
                os.environ["LCARS_TAILSCALE_IP"] = value
                self.resolve_expecting_exit()


class TestCgnatValidator(unittest.TestCase):
    """_lcars_validated_tailscale_ipv4 is what makes the loose ifconfig regex safe."""

    def test_accepts_addresses_across_the_cgnat_range(self):
        for value in ("100.64.0.0", "100.95.180.109", "100.127.255.255"):
            with self.subTest(value=value):
                self.assertEqual(server._lcars_validated_tailscale_ipv4(value), value)

    def test_strips_surrounding_whitespace(self):
        self.assertEqual(
            server._lcars_validated_tailscale_ipv4("  100.64.1.2\n"), "100.64.1.2"
        )

    def test_rejects_addresses_just_outside_the_range(self):
        """100.63.x and 100.128.x are ordinary internet space, not tailnet."""
        for value in ("100.63.255.255", "100.128.0.0"):
            with self.subTest(value=value):
                self.assertIsNone(server._lcars_validated_tailscale_ipv4(value))

    def test_rejects_lan_loopback_and_wildcard(self):
        for value in ("192.168.1.5", "10.0.0.1", "172.16.0.1", "127.0.0.1", "0.0.0.0"):
            with self.subTest(value=value):
                self.assertIsNone(server._lcars_validated_tailscale_ipv4(value))

    def test_rejects_ipv6_and_junk(self):
        for value in ("::1", "fd7a:115c:a1e0::1", "", None, "hello", "100.64"):
            with self.subTest(value=value):
                self.assertIsNone(server._lcars_validated_tailscale_ipv4(value))


class TestInterfaceScanSafety(unittest.TestCase):
    """The ifconfig fallback must not pick up a non-tailnet address."""

    def _fake_proc(self, stdout, returncode=0):
        proc = MagicMock()
        proc.stdout = stdout
        proc.returncode = returncode
        return proc

    def test_scan_skips_lan_addresses_and_finds_the_tailnet_one(self):
        ifconfig_output = (
            "lo0: flags=8049\n\tinet 127.0.0.1 netmask 0xff000000\n"
            "en0: flags=8863\n\tinet 192.168.4.83 netmask 0xffffff00\n"
            "utun4: flags=8051\n\tinet 100.95.180.109 --> 100.95.180.109\n"
        )
        with patch.object(server.subprocess, "run", return_value=self._fake_proc(ifconfig_output)):
            self.assertEqual(
                server._lcars_tailscale_ipv4_from_interfaces(), "100.95.180.109"
            )

    def test_scan_returns_none_when_no_tailnet_address_present(self):
        ifconfig_output = (
            "lo0:\n\tinet 127.0.0.1\n"
            "en0:\n\tinet 192.168.4.83\n"
        )
        with patch.object(server.subprocess, "run", return_value=self._fake_proc(ifconfig_output)):
            self.assertIsNone(server._lcars_tailscale_ipv4_from_interfaces())

    def test_scan_tolerates_missing_tooling(self):
        """No ifconfig and no ip(8) is 'undetermined', not a crash."""
        with patch.object(server.subprocess, "run", side_effect=FileNotFoundError):
            self.assertIsNone(server._lcars_tailscale_ipv4_from_interfaces())

    def test_cli_tolerates_timeout(self):
        with patch.object(server.subprocess, "run", side_effect=Exception("boom")):
            self.assertIsNone(server._lcars_tailscale_ipv4_from_cli())

    def test_cli_ignores_nonzero_exit(self):
        with patch.object(server.os.path, "exists", return_value=True):
            with patch.object(
                server.subprocess, "run",
                return_value=self._fake_proc("100.95.180.109\n", returncode=1),
            ):
                self.assertIsNone(server._lcars_tailscale_ipv4_from_cli())


if __name__ == "__main__":
    unittest.main(verbosity=2)
