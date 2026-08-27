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
import socket
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

    def test_all_mode_with_confirmation_prints_a_posture_line(self):
        """XACA-0397-019: docs/homebrew-tap/LCARS-NETWORK-BINDING.md claims
        every mode prints a `posture:` line an operator can grep — this is
        the widest, most dangerous mode, and it must not be the one silent
        exception."""
        os.environ["LCARS_BIND_MODE"] = "all"
        os.environ["LCARS_BIND_ALLOW_ALL_INTERFACES"] = "1"
        _, output = self.resolve()
        self.assertIn("posture:", output)
        self.assertIn("mode=all", output)

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


class TestAggregateDetectionDeadline(unittest.TestCase):
    """XACA-0397-015: the aggregate cap must stop issuing further detection
    subprocess calls once the shared deadline is exhausted, rather than
    letting each phase (CLI candidates, then interface-scan fallback) spend
    its own full per-call budget independently — that's how a worst case of
    up to 6 subprocess calls x 5s each could reach ~30s, comfortably past
    the launcher's 15s readiness window.

    Uses a simulated monotonic clock so this runs in milliseconds. A real
    wall-clock measurement against a genuinely hanging subprocess (not
    mocked) was done manually while writing this fix and is reported in the
    PR/ticket — this test instead pins the CUTOFF LOGIC so a regression
    (e.g. someone reverting to a per-phase budget) fails fast in CI.
    """

    def test_deadline_stops_further_subprocess_calls_once_exhausted(self):
        """XACA-0397-018/022: a COMBINED threshold across both phases cannot
        detect a regression confined to just one of them. Measured on this
        same fake clock: the shipped code (both phases' early-breaks intact)
        makes 2 combined calls; a mutant with ONLY the CLI phase's
        `if remaining <= 0: break` removed (interface-scan's break left
        intact) makes 4 combined calls — still under the old `< 6` bound, so
        that assertion passed over the regression. Tracking and asserting
        the CLI phase's own call count, independent of whatever the
        interface-scan phase does afterward, closes that gap: 2 (shipped)
        vs. 4 (mutant), where there are only 4 CLI candidates total, so a
        mutant that lets the CLI loop run unchecked hits every one of them.
        """
        cli_call_timeouts = []
        iface_call_timeouts = []
        # Fake monotonic clock: starts at 0, advances 3s on every read. An
        # 8s budget / 3s per read exhausts partway through the CLI phase,
        # well before all 6 real candidates (4 CLI + 2 interface-scan
        # commands) would otherwise be tried.
        state = {"t": 0.0}

        def fake_monotonic():
            state["t"] += 3.0
            return state["t"]

        def fake_run(cmd, **kwargs):
            if cmd and cmd[0] in server._TAILSCALE_BINARY_CANDIDATES:
                cli_call_timeouts.append(kwargs.get("timeout"))
            else:
                iface_call_timeouts.append(kwargs.get("timeout"))
            raise Exception("simulated: tailscale unreachable")

        with patch.object(server.os.path, "exists", return_value=True):
            with patch.object(server.time, "monotonic", side_effect=fake_monotonic):
                with patch.object(server.subprocess, "run", side_effect=fake_run):
                    result = server._lcars_detect_tailscale_ipv4()

        self.assertIsNone(result)
        # There are exactly 4 CLI candidates (_TAILSCALE_BINARY_CANDIDATES).
        # Asserted on the CLI phase ALONE — not combined with the
        # interface-scan phase's count — so a regression that only strips
        # the CLI phase's own early-break cannot hide behind the other
        # phase's break still being intact.
        self.assertLess(
            len(cli_call_timeouts), 4,
            "the CLI phase's own early-break did not stop it mid-loop — "
            "asserting on its count alone (not the combined total) is what "
            "catches this regression",
        )
        # Sanity check retained: without ANY aggregate cap at all this would
        # be 6 (4 CLI + 2 interface-scan).
        self.assertLess(
            len(cli_call_timeouts) + len(iface_call_timeouts), 6,
            "aggregate deadline did not stop the detection phases early",
        )

    def test_cli_and_interface_scan_default_to_independent_full_budgets_when_uncoupled(self):
        """Direct/unit-test callers that invoke the phase functions WITHOUT a
        shared deadline (as TestInterfaceScanSafety above does) must keep
        working unchanged — each gets its own default full budget rather
        than raising a TypeError for a missing argument."""
        with patch.object(server.subprocess, "run", side_effect=Exception("boom")):
            self.assertIsNone(server._lcars_tailscale_ipv4_from_cli())
            self.assertIsNone(server._lcars_tailscale_ipv4_from_interfaces())


class TestServeForeverGuards(unittest.TestCase):
    """XACA-0397-016: an empty bind_hosts list must fail with a clear FATAL
    message in this file's established voice, not a bare IndexError three
    frames down at servers[0]."""

    def test_empty_bind_hosts_exits_nonzero_with_fatal_message(self):
        out = io.StringIO()
        with patch.object(sys, "stderr", out):
            with self.assertRaises(SystemExit) as ctx:
                server._lcars_serve_forever_on([], 8901)
        self.assertNotEqual(ctx.exception.code, 0)
        self.assertIn("FATAL", out.getvalue())


class TestServeForeverOrchestration(unittest.TestCase):
    """XACA-0397-017: covers _lcars_serve_forever_on's bind/threading/
    cleanup orchestration with a lightweight fake server class standing in
    for LCARSServer.

    A fake is used here (rather than real sockets on two distinct
    addresses) because this machine does not bind a second loopback alias
    by default — `socket().bind(("127.0.0.2", port))` fails with
    "Can't assign requested address" (errno 49) on macOS without extra
    `ifconfig lo0 alias` setup, verified empirically while writing this
    test — so a real-socket version of "one listener per address" would be
    flaky/non-portable across dev machines and CI. The genuine bind-failure
    + cleanup path IS tested with real sockets below in
    TestServeForeverPartialBindCleanup, where a duplicate host entry
    produces a real, deterministic EADDRINUSE without needing a second
    address at all.
    """

    def _make_fake_server_class(self, fail_hosts=frozenset()):
        created = []

        class _FakeServer:
            def __init__(self, address, handler_cls):
                if address[0] in fail_hosts:
                    raise OSError(48, "Address already in use")
                self.server_address = address
                self.handler_cls = handler_cls
                self.serve_forever_calls = 0
                self.shutdown_calls = 0
                self.server_close_calls = 0
                created.append(self)

            def serve_forever(self):
                self.serve_forever_calls += 1

            def shutdown(self):
                self.shutdown_calls += 1

            def server_close(self):
                self.server_close_calls += 1

        return _FakeServer, created

    def test_one_server_instance_per_resolved_address(self):
        fake_cls, created = self._make_fake_server_class()
        with patch.object(server, "LCARSServer", fake_cls):
            server._lcars_serve_forever_on(["127.0.0.1", "100.101.102.103"], 8901)
        self.assertEqual(len(created), 2)
        self.assertEqual(
            [s.server_address[0] for s in created],
            ["127.0.0.1", "100.101.102.103"],
        )

    def test_first_server_runs_on_calling_thread_rest_get_daemon_threads(self):
        fake_cls, created = self._make_fake_server_class()
        with patch.object(server, "LCARSServer", fake_cls):
            with patch.object(
                server.threading, "Thread", wraps=server.threading.Thread
            ) as thread_spy:
                server._lcars_serve_forever_on(
                    ["127.0.0.1", "100.101.102.103", "100.101.102.104"], 8901
                )
        # The first server is served directly on the calling thread — no
        # threading.Thread wraps it.
        self.assertEqual(created[0].serve_forever_calls, 1)
        # The remaining two each get their own daemon thread.
        self.assertEqual(thread_spy.call_count, 2)
        for call in thread_spy.call_args_list:
            self.assertTrue(call.kwargs.get("daemon"))

    def test_all_servers_shut_down_and_closed_on_normal_completion(self):
        fake_cls, created = self._make_fake_server_class()
        with patch.object(server, "LCARSServer", fake_cls):
            server._lcars_serve_forever_on(["127.0.0.1", "100.101.102.103"], 8901)
        for srv in created:
            self.assertEqual(srv.shutdown_calls, 1)
            self.assertEqual(srv.server_close_calls, 1)

    def test_bind_failure_still_closes_sockets_opened_before_it_fake_level(self):
        """The orchestration-level mirror of the real-socket test below:
        proves server_close() runs for every PRIOR successfully-opened
        server even when a later host in the list fails to bind."""
        fake_cls, created = self._make_fake_server_class(
            fail_hosts={"100.101.102.103"}
        )
        with patch.object(server, "LCARSServer", fake_cls):
            with patch.object(sys, "stderr", io.StringIO()):
                with self.assertRaises(SystemExit) as ctx:
                    server._lcars_serve_forever_on(
                        ["127.0.0.1", "100.101.102.103"], 8901
                    )
        self.assertNotEqual(ctx.exception.code, 0)
        # Only the first host's server was ever created (the second raised
        # during construction, before being appended) — and it must have
        # been closed, not leaked.
        self.assertEqual(len(created), 1)
        self.assertEqual(created[0].server_close_calls, 1)


class TestServeForeverPartialBindCleanup(unittest.TestCase):
    """XACA-0397-017: real-socket test proving a mid-list bind failure
    closes sockets that were already opened rather than leaking a listener.

    Uses a duplicate host entry (the SAME host:port twice) to force a
    genuine second-bind EADDRINUSE without needing a second bindable
    loopback address (127.0.0.2 does not bind on this machine by default —
    see TestServeForeverOrchestration's docstring). SO_REUSEADDR (set on
    LCARSServer per XACA-0889-018) only allows rebinding a port stuck in
    TIME_WAIT from a previously-closed connection — it does NOT allow two
    simultaneously-active listeners on the identical (address, port) pair,
    so the second LCARSServer(...) construction below is expected to
    genuinely fail while the first is still open.
    """

    PORT = 8902  # throwaway port, per XACA-0397 task instructions (8901-8903)

    def test_partial_bind_failure_exits_nonzero_and_frees_the_port(self):
        """XACA-0397-021: the port-rebind probe alone does not structurally
        prove server_close() ran — CPython's refcount-based GC closes the
        orphaned socket's underlying fd as soon as the local `servers` list
        inside _lcars_serve_forever_on drops out of scope (which
        unittest.assertRaises' SystemExit handling does immediately), so a
        mutant that deletes the `finally: srv.server_close()` block still
        leaves the port re-bindable and this test green.

        Fix: spy on LCARSServer.server_close (inherited from
        socketserver.TCPServer — patched via patch.object so the spy is
        restored afterward) so the assertion is on whether the *method* was
        actually invoked by the code, not on the port's eventual
        rebindability. The spy still forwards to the real implementation, so
        the socket genuinely closes and the port-rebind probe keeps working
        as a secondary, behavioural check.
        """
        original_init = server.LCARSServer.__init__
        original_server_close = server.LCARSServer.server_close
        constructed = []
        close_calls = []

        def spy_init(self, *args, **kwargs):
            original_init(self, *args, **kwargs)
            # Only reached if original_init returned normally — a failed
            # bind raises out of it, so this records ONLY the
            # successfully-bound-and-activated instance.
            constructed.append(self)

        def spy_server_close(self):
            close_calls.append(self)
            return original_server_close(self)

        out = io.StringIO()
        with patch.object(server.LCARSServer, "__init__", spy_init):
            with patch.object(server.LCARSServer, "server_close", spy_server_close):
                with patch.object(sys, "stderr", out):
                    with self.assertRaises(SystemExit) as ctx:
                        server._lcars_serve_forever_on(["127.0.0.1", "127.0.0.1"], self.PORT)
        self.assertNotEqual(ctx.exception.code, 0)
        self.assertIn("FATAL", out.getvalue())

        # Exactly one host successfully bound — the second raises
        # EADDRINUSE during construction, before it is ever appended to
        # _lcars_serve_forever_on's own `servers` list.
        self.assertEqual(len(constructed), 1)

        # Structural: that successfully-opened server's server_close() must
        # actually have been invoked by the code's own cleanup path. (There
        # may be a SECOND, unrelated server_close() call recorded here too —
        # stdlib's own TCPServer.__init__ calls self.server_close() on the
        # second, FAILED instance as part of its own internal exception
        # cleanup; that is not what this test is about, hence checking
        # membership on the successful instance specifically rather than a
        # bare call count.)
        self.assertIn(
            constructed[0], close_calls,
            "server_close() was not called on the successfully-opened "
            "server — a bare port-rebind probe cannot tell this apart from "
            "CPython's GC finalizer closing the orphaned socket once the "
            "SystemExit severs the traceback",
        )

        # Behavioural check retained: no leaked listener, the port must be
        # immediately re-bindable. If the first, successfully-opened server
        # were never closed, this bind would itself raise "Address already
        # in use".
        probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            probe.bind(("127.0.0.1", self.PORT))
        finally:
            probe.close()


class TestBindStatusDiagnostic(BindControlTestBase):
    """XACA-0988-005: resolve_bind_addresses_or_die() must leave a durable,
    in-process record of what it decided (_LCARS_BIND_STATUS), independent of
    the stderr "posture:"/"NOTICE:" lines it also prints.

    Why this exists: those stderr lines are the ONLY other record of a bind
    decision, and start_lcars_server 2>>'s them into a per-team log file that
    XACA-0661 rotates (mv -f to .old) at the START of every subsequent launch
    for that team name — including a test-suite invocation that passes a real
    team name on a scratch port (this file's own `self.resolve()` helper is
    exactly that shape, minus the log). That rotation is what destroyed the
    evidence trail for the XACA-0988 loopback-only-bind incident: two
    unrelated test-suite launches 13s apart rotated lcars-server-academy.log
    out from under a still-running production process before its posture line
    could be read. _LCARS_BIND_STATUS survives for the life of the process
    regardless of what happens to the log.
    """

    def _status(self):
        return dict(server._LCARS_BIND_STATUS)

    def test_default_success_records_dual_bind_not_degraded(self):
        self.resolve()
        status = self._status()
        self.assertEqual(status["mode"], "auto")
        self.assertEqual(status["hosts"], ["127.0.0.1", FAKE_TS_IP])
        self.assertTrue(status["tailnet_bound"])
        self.assertEqual(status["tailscale_ip"], FAKE_TS_IP)
        self.assertEqual(status["source"], "detected")
        self.assertFalse(
            status["degraded"], "a successful dual bind must not read as degraded"
        )

    def test_auto_fallback_to_loopback_is_recorded_as_degraded(self):
        """The exact condition this ticket investigates: detection failed and
        auto mode narrowed to loopback-only. The record must say so plainly —
        this is the durable substitute for the log line that got rotated
        away for PID 7437."""
        self.resolve(detected_ip=None)
        status = self._status()
        self.assertEqual(status["mode"], "auto")
        self.assertEqual(status["hosts"], ["127.0.0.1"])
        self.assertFalse(status["tailnet_bound"])
        self.assertIsNone(status["tailscale_ip"])
        self.assertTrue(
            status["degraded"],
            "auto-mode fallback to loopback-only must be flagged degraded",
        )

    def test_explicit_loopback_mode_is_not_degraded(self):
        """Negative control for the previous test: loopback-only is only
        'degraded' when it is an unwanted fallback. An operator who explicitly
        asked for LCARS_BIND_MODE=loopback got exactly what they asked for."""
        os.environ["LCARS_BIND_MODE"] = "loopback"
        self.resolve()
        status = self._status()
        self.assertEqual(status["mode"], "loopback")
        self.assertEqual(status["hosts"], ["127.0.0.1"])
        self.assertFalse(status["tailnet_bound"])
        self.assertFalse(
            status["degraded"],
            "an explicitly-requested loopback bind is not a degraded fallback",
        )

    def test_tailscale_mode_success_records_dual_bind(self):
        os.environ["LCARS_BIND_MODE"] = "tailscale"
        self.resolve()
        status = self._status()
        self.assertEqual(status["mode"], "tailscale")
        self.assertTrue(status["tailnet_bound"])
        self.assertFalse(status["degraded"])

    def test_all_mode_records_tailnet_bound_true(self):
        """mode=all binds 0.0.0.0, which reaches the tailnet address too —
        tailnet_bound must read True, not False, for this host list."""
        os.environ["LCARS_BIND_MODE"] = "all"
        os.environ["LCARS_BIND_ALLOW_ALL_INTERFACES"] = "1"
        self.resolve()
        status = self._status()
        self.assertEqual(status["mode"], "all")
        self.assertEqual(status["hosts"], [""])
        self.assertTrue(status["tailnet_bound"])
        self.assertFalse(status["degraded"])

    def test_env_override_ip_records_its_source(self):
        os.environ["LCARS_TAILSCALE_IP"] = FAKE_TS_IP
        self.resolve()
        status = self._status()
        self.assertEqual(status["source"], "env-override")
        self.assertEqual(status["tailscale_ip"], FAKE_TS_IP)

    def test_a_fatal_exit_leaves_no_stale_success_status(self):
        """Negative control: a mode that refuses to start (tailscale, ip not
        found) must not leave behind a status dict claiming success from a
        PRIOR test's resolve() call in the same process. Establish a known
        dual-bound baseline, then force a FATAL and confirm the baseline
        status was never overwritten by a fabricated success — the FATAL
        path correctly never calls _lcars_record_bind_status at all, so the
        last real decision (the baseline) is what remains visible."""
        self.resolve()  # baseline: dual-bound success
        baseline = self._status()
        self.assertTrue(baseline["tailnet_bound"])

        os.environ["LCARS_BIND_MODE"] = "tailscale"
        self.resolve_expecting_exit(detected_ip=None)
        after_fatal = self._status()
        self.assertEqual(
            after_fatal, baseline,
            "a FATAL exit must not mutate _LCARS_BIND_STATUS — the last "
            "successful decision should remain the visible record",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
