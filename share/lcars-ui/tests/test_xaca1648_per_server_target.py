#!/usr/bin/env python3

#
#  test_xaca1648_per_server_target.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 DoubleNode.com. All rights reserved.
#

"""
XACA-1648 regression suite: every LCARS server answers /lcars-target.js with
its OWN team, not whatever the last-started team wrote into the machine-wide
runtime file.

Real servers are started as subprocesses (one process per synthetic team) so
the assertions exercise the actual GET/HEAD dispatch, not a mocked handler.

Isolation (memory: feedback_lcars_health_daemon_heals_test_servers,
feedback_sandboxed_config_does_not_sandbox_resolved_paths):
  - synthetic team names only ("zz-*") with LCARS_SKIP_TEAM_VALIDATION=1;
    the live lcars-health daemon never sees them;
  - HOME, TMPDIR and LCARS_TARGET_RUNTIME_FILE point into a private temp dir;
  - TMUX / TMUX_PANE are stripped; cwd is the temp dir;
  - ports come from binding port 0 (the OS ephemeral range, not 8200-8299).

Assertions compare EXACT payload lines, never substrings a hijacked body would
also satisfy.

Run:
    python3 -m pytest lcars-ui/tests/test_xaca1648_per_server_target.py -v
Mutation check against another copy of lcars-ui (e.g. the pre-fix server.py):
    XACA1648_LCARS_UI_DIR=/path/to/lcars-ui python3 -m pytest <this file>
"""

from __future__ import annotations

import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
LCARS_UI_DIR = Path(os.environ.get("XACA1648_LCARS_UI_DIR") or (REPO_ROOT / "lcars-ui"))
SERVER_PY = LCARS_UI_DIR / "server.py"

TEAM_A = "zz-a"
TEAM_B = "zz-b"
SESSION_A = "zz-a-lcars"
# Hostile-but-synthetic team name: quote, backslash, script closer, HTML comment.
HOSTILE_TEAM = "zz-x\"';</script><!--\\"

_JS_ASSIGN_RE = re.compile(r'^window\.(LCARS_TARGET_[A-Z]+) = (".*");$')


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _request(port: int, method: str, path: str):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        conn.request(method, path)
        resp = conn.getresponse()
        body = resp.read()
        return resp.status, dict(resp.getheaders()), body
    finally:
        conn.close()


def _snapshot(root: Path):
    out = {}
    for p in sorted(root.rglob("*")):
        if "__pycache__" in p.parts:
            continue
        try:
            st = p.stat()
        except OSError:
            continue
        out[str(p.relative_to(root))] = (st.st_mtime_ns, st.st_size)
    return out


class _Server:
    def __init__(self, base: Path, name: str, team, session=None):
        self.name = name
        self.team = team
        self.port = _free_port()
        self.home = base / "home"
        self.runtime_file = base / "runtime-target.js"
        child_env = {k: v for k, v in os.environ.items()
                     if not k.startswith(("TMUX", "LCARS_", "AITEAMFORGE_", "KB_"))}
        child_env.update({
            "HOME": str(self.home),
            "TMPDIR": str(base / "tmp"),
            "LCARS_SKIP_TEAM_VALIDATION": "1",
            "AITEAMFORGE_REQUIRE_AUTH": "0",
            "LCARS_BIND_MODE": "loopback",
            "LCARS_TARGET_RUNTIME_FILE": str(self.runtime_file),
            "PYTHONDONTWRITEBYTECODE": "1",
        })
        if team is not None:
            child_env["LCARS_TEAM"] = team
        if session is not None:
            child_env["LCARS_SESSION_NAME"] = session
        self.log = open(base / f"{name}.log", "wb")
        # Plain python3 (not -I): server.py needs its sibling imports.
        self.proc = subprocess.Popen(
            [sys.executable, str(SERVER_PY), str(self.port)],
            env=child_env, cwd=str(base), stdout=self.log, stderr=subprocess.STDOUT,
        )

    def wait_ready(self, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"{self.name} exited early rc={self.proc.returncode}")
            try:
                status, _, body = _request(self.port, "GET", "/api/team")
                if status == 200:
                    return json.loads(body)
            except (OSError, ValueError):
                pass
            time.sleep(0.25)
        raise RuntimeError(f"{self.name} not ready in {timeout}s")

    def get(self, path="/lcars-target.js"):
        return _request(self.port, "GET", path)

    def head(self, path="/lcars-target.js"):
        return _request(self.port, "HEAD", path)

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.log.close()


class PerServerTargetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base = Path(tempfile.mkdtemp(prefix="xaca1648-"))
        (cls.base / "home" / ".aiteamforge").mkdir(parents=True)
        (cls.base / "tmp").mkdir()
        cls.runtime_file = cls.base / "runtime-target.js"
        cls.local_file = cls.base / "home" / ".aiteamforge" / "lcars-target.local.js"
        cls.servers = []
        cls.ui_before = _snapshot(LCARS_UI_DIR)
        try:
            cls.a = cls._start("a", TEAM_A, SESSION_A)
            cls.b = cls._start("b", TEAM_B, None)
            cls.n = cls._start("n", None, None)          # no LCARS_TEAM at all
            cls.h = cls._start("h", HOSTILE_TEAM, None)  # escaping probe
            cls.api = {s.name: s.wait_ready() for s in cls.servers}
        except Exception:
            cls.tearDownClass()
            raise

    @classmethod
    def _start(cls, name, team, session):
        s = _Server(cls.base, name, team, session)
        cls.servers.append(s)
        return s

    @classmethod
    def tearDownClass(cls):
        for s in cls.servers:
            s.stop()
        shutil.rmtree(cls.base, ignore_errors=True)

    def setUp(self):
        for p in (self.runtime_file, self.local_file):
            if p.exists():
                p.unlink()

    # -- helpers -----------------------------------------------------------
    def _write_runtime(self, team, session=None):
        text = f"window.LCARS_TARGET_TEAM = '{team}';\n"
        if session:
            text += f"window.LCARS_TARGET_SESSION = '{session}';\n"
        self.runtime_file.write_text(text)
        return text

    @staticmethod
    def _lines(body: bytes):
        return body.decode("utf-8").splitlines()

    # -- sanity: the fixtures really are what the tests assume -------------
    def test_00_servers_report_expected_identity(self):
        self.assertEqual(self.api["a"]["team"], TEAM_A)
        self.assertEqual(self.api["b"]["team"], TEAM_B)
        self.assertTrue(self.api["a"]["team_was_explicit"])
        self.assertTrue(self.api["b"]["team_was_explicit"])
        self.assertFalse(self.api["n"]["team_was_explicit"])

    # -- 1. two servers, one shared runtime file, both orders --------------
    def test_01_each_server_serves_its_own_team_file_names_a(self):
        self._write_runtime(TEAM_A)
        sa, _, ba = self.a.get()
        sb, _, bb = self.b.get()
        self.assertEqual((sa, sb), (200, 200))
        self.assertEqual(self._lines(ba), [f'window.LCARS_TARGET_TEAM = "{TEAM_A}";',
                                           f'window.LCARS_TARGET_SESSION = "{SESSION_A}";'])
        self.assertEqual(self._lines(bb), [f'window.LCARS_TARGET_TEAM = "{TEAM_B}";'])

    def test_02_each_server_serves_its_own_team_file_names_b(self):
        self._write_runtime(TEAM_B)
        _, _, ba = self.a.get()
        _, _, bb = self.b.get()
        self.assertEqual(self._lines(ba), [f'window.LCARS_TARGET_TEAM = "{TEAM_A}";',
                                           f'window.LCARS_TARGET_SESSION = "{SESSION_A}";'])
        self.assertEqual(self._lines(bb), [f'window.LCARS_TARGET_TEAM = "{TEAM_B}";'])

    def test_03_served_team_matches_api_team_not_a_hardcoded_string(self):
        self._write_runtime("zz-foreign")
        for srv in (self.a, self.b):
            team = json.loads(srv.get("/api/team")[2])["team"]
            self.assertEqual(self._lines(srv.get()[2])[0],
                             f'window.LCARS_TARGET_TEAM = "{team}";')

    # -- 2. HEAD parity -----------------------------------------------------
    def test_04_head_matches_get_status_and_length_with_empty_body(self):
        self._write_runtime(TEAM_B)
        for srv in (self.a, self.b):
            gs, gh, gb = srv.get()
            hs, hh, hb = srv.head()
            self.assertEqual(hs, gs)
            self.assertEqual(hh.get("Content-Length"), gh.get("Content-Length"))
            self.assertEqual(int(hh["Content-Length"]), len(gb))
            self.assertEqual(hh.get("Content-Type"), gh.get("Content-Type"))
            self.assertEqual(hb, b"")

    # -- 3. session line ----------------------------------------------------
    def test_05_session_line_matches_api_status_session_name(self):
        _, _, body = self.a.get()
        status = json.loads(self.a.get("/api/status")[2])
        self.assertEqual(status["session_name"], SESSION_A)
        self.assertIn(f'window.LCARS_TARGET_SESSION = "{status["session_name"]}";',
                      self._lines(body))

    def test_06_no_session_env_emits_no_session_line(self):
        _, _, body = self.b.get()
        self.assertEqual([l for l in self._lines(body) if "LCARS_TARGET_SESSION" in l], [])
        self.assertNotIn(b"LCARS_TARGET_SESSION", body)

    # -- 4. stale foreign session must not leak -----------------------------
    def test_07_stale_foreign_session_in_runtime_file_does_not_leak(self):
        self._write_runtime("zz-foreign", "zz-foreign-lcars")
        for srv in (self.a, self.b):
            self.assertNotIn(b"zz-foreign", srv.get()[2])
        # B has no session of its own, so no session line may appear at all.
        self.assertNotIn(b"LCARS_TARGET_SESSION", self.b.get()[2])

    # -- 5. fallback preserved (XACA-0798) ----------------------------------
    def test_08_no_team_server_serves_runtime_file_verbatim(self):
        text = self._write_runtime("zz-fallback", "zz-fallback-lcars")
        status, _, body = self.n.get()
        self.assertEqual(status, 200)
        self.assertEqual(body, text.encode())
        hs, hh, hb = self.n.head()
        self.assertEqual((hs, hb), (200, b""))
        self.assertEqual(int(hh["Content-Length"]), len(text.encode()))

    def test_09_no_team_server_without_runtime_file_does_not_name_a_team(self):
        status, _, body = self.n.get()
        # Shipped default or 404 are both acceptable; another server's team is not.
        self.assertNotIn(TEAM_A.encode(), body)
        self.assertNotIn(TEAM_B.encode(), body)
        self.assertIn(status, (200, 404))

    # -- 6. XACA-0301 local override ----------------------------------------
    def test_10_local_override_served_and_404_when_absent(self):
        for srv in (self.a, self.b, self.n):
            self.assertEqual(srv.get("/lcars-target.local.js")[0], 404)
            self.assertEqual(srv.head("/lcars-target.local.js")[0], 404)
        override = "window.LCARS_TARGET_TEAM = 'zz-override';\n"
        self.local_file.write_text(override)
        for srv in (self.a, self.b, self.n):
            status, _, body = srv.get("/lcars-target.local.js")
            self.assertEqual((status, body), (200, override.encode()))

    # -- 7. escaping ---------------------------------------------------------
    def test_11_hostile_team_name_stays_inside_the_string_literal(self):
        self.assertEqual(self.api["h"]["team"], HOSTILE_TEAM)
        body = self.h.get()[2].decode()
        self.assertNotIn("</script", body.lower())
        self.assertNotIn("<!--", body)
        lines = body.splitlines()
        self.assertEqual(len(lines), 1)
        m = _JS_ASSIGN_RE.match(lines[0])
        self.assertIsNotNone(m, lines[0])
        # The literal is valid JSON, so it round-trips to exactly the input.
        self.assertEqual(json.loads(m.group(2)), HOSTILE_TEAM)

    def test_12_every_response_is_well_formed_assignments_only(self):
        for srv in (self.a, self.b, self.h):
            lines = self._lines(srv.get()[2])
            self.assertTrue(lines)
            for line in lines:
                self.assertRegex(line, _JS_ASSIGN_RE)

    # -- 8. XACA-0798 invariant ---------------------------------------------
    def test_13_nothing_written_under_lcars_ui_and_runtime_file_untouched(self):
        text = self._write_runtime(TEAM_B, "zz-b-lcars")
        before_rt = (self.runtime_file.stat().st_mtime_ns, self.runtime_file.read_bytes())
        for srv in (self.a, self.b, self.n, self.h):
            srv.get()
            srv.head()
            srv.get("/lcars-target.local.js")
        after_rt = (self.runtime_file.stat().st_mtime_ns, self.runtime_file.read_bytes())
        self.assertEqual(before_rt, after_rt)
        self.assertEqual(self.runtime_file.read_text(), text)
        self.assertEqual(_snapshot(LCARS_UI_DIR), self.ui_before)


if __name__ == "__main__":
    unittest.main()
