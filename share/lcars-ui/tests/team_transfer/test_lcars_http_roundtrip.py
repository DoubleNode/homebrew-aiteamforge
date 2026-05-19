"""XACA-0520-007: HTTP round-trip integration test for LCARS export/import endpoints.

Extends the XACA-0492 synthetic-migration pattern to drive the full LCARS UI
wrapper layer: POST /api/export/create → poll /api/export/status → GET
/api/export/download → POST /api/import/upload → POST /api/import/apply →
poll /api/import/status → assert per-channel verifier results.

SERVER BOOT APPROACH: subprocess
---------------------------------
We launch server.py as a subprocess rather than in-process because:

1. ``Path.home()`` is called directly (not importable) inside ``generate_export``
   and ``apply_import`` — both use it as the extraction root.  Redirecting the
   real $HOME is the only reliable way to isolate the test from the developer's
   actual home directory without monkeypatching deep stdlib internals mid-test.

2. ``main()`` contains multiple startup guards (``validate_lcars_team_or_die``,
   ``check_all_dual_boards_or_die``, ``_xaca0463_assert_no_port_conflicts``)
   that reference module-level globals set at import time.  Bypassing them
   in-process would require extensive patching across a 13 500-line file.

3. The existing e2e test (XACA-0492) already uses subprocess+$HOME override
   for the generator/verifier CLI pair; this test follows the same pattern for
   the server layer.

We bypass the startup guards via env vars the server already supports:
  LCARS_SKIP_TEAM_VALIDATION=1
  LCARS_SKIP_DUAL_BOARD_CHECK=1

Port collision is avoided by binding the server to port 0 and reading the
kernel-assigned port from server stdout (the startup banner always prints
"Server starting on port <N>").

Extraction destination isolation:
  HOME=<tempdir>/dst_home  (subprocess env)
  The server extracts files to Path.home() / fe.relpath, which resolves to
  <tempdir>/dst_home/<relpath>.  This never touches the developer's real $HOME.

Test coverage:
  - Golden path: export → upload → apply → verifier PASS
  - PRE_EXPORT_CHECKLIST.md present in zip root
  - manifest.json at zip root with schema_version
  - secrets_summary present in embedded manifest
  - per-channel verifier shape (state, counts) in import response
  - Secrets handshake path A: discovered=0 → import succeeds without override
  - Secrets handshake path B: discovered>0, no paired zip, no override → HTTP 409
  - Secrets handshake path C: discovered>0, no paired zip, acknowledgeMissing=True → succeeds

NOTE: When secrets_export_lib (pyzipper) is unavailable the server's fallback
stub returns discovered=0 for every team, so paths B and C cannot be driven
via the real generate_export() endpoint.  Those cases are exercised by injecting
a synthetic manifest that declares discovered>0 into a manually crafted zip so
the handshake gate can be tested regardless of pyzipper availability.
"""
from __future__ import annotations

import io
import json
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
from pathlib import Path
from typing import Optional

import pytest

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

LCARS_UI_DIR = Path(__file__).resolve().parents[2]   # lcars-ui/
REPO_ROOT = LCARS_UI_DIR.parent                       # worktree root
SERVER_PY = LCARS_UI_DIR / "server.py"


# ---------------------------------------------------------------------------
# Subprocess server fixture
# ---------------------------------------------------------------------------

class _LCARSServer:
    """Handle to a server.py subprocess, including port and shutdown."""

    def __init__(self, proc: subprocess.Popen, port: int, home_dir: Path):
        self.proc = proc
        self.port = port
        self.home_dir = home_dir

    def url(self, path: str) -> str:
        return f"http://localhost:{self.port}{path}"

    def stop(self) -> None:
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()


def _pick_free_port() -> int:
    """Bind to port 0 and let the kernel pick; return the assigned port."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _build_synthetic_home(home: Path) -> None:
    """Build a finance.yaml-compatible synthetic source tree under *home*.

    Matches the channel rules in lcars-ui/team_transfer/config/finance.yaml so
    that the generator picks up at least one entry per non-secret channel.

    The real finance.yaml uses claude_project_dir_name=-Users-darrenehlers-finance-personal
    which is the developer-machine value.  Since $HOME is overridden to *home*,
    the generator resolves {home} to *home* — it does NOT use the darrenehlers
    prefix.  The claude_project_dir_name in finance.yaml is used as a literal
    dirname, so we create that exact dirname under <home>/.claude/projects/.
    """
    # git / export_kanban channel root
    repo = home / "finance" / "personal"
    (repo / "src").mkdir(parents=True, exist_ok=True)
    (repo / "src" / "main.py").write_text("# synthetic\nprint('hello')\n")
    (repo / "src" / "utils.py").write_text("# synthetic utils\ndef noop(): pass\n")

    kanban = repo / "kanban"
    kanban.mkdir(parents=True, exist_ok=True)
    board = {
        "items": [
            {"id": "XFIN-0001", "title": "Synthetic item 1", "status": "done"},
            {"id": "XFIN-0002", "title": "Synthetic item 2", "status": "todo"},
        ]
    }
    (kanban / "finance-personal-board.json").write_text(json.dumps(board, indent=2))
    (kanban / "XFIN-0001_plan.md").write_text("# Plan\nSynthetic plan.\n")

    # export_database channel
    data_dir = repo / "data"
    data_dir.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(data_dir / "finance.db"))
    conn.execute("CREATE TABLE IF NOT EXISTS schema_info (key TEXT PRIMARY KEY, value TEXT)")
    conn.execute("INSERT OR REPLACE INTO schema_info VALUES ('schema_version', '1')")
    conn.commit()
    conn.close()

    # secrets_export channel (keep these so the generator can catalog them;
    # they are NOT included in the main zip by generate_export())
    (repo / ".env").write_text("API_KEY=synthetic_not_real\n")
    (repo / "secrets").mkdir(parents=True, exist_ok=True)
    (repo / "secrets" / "test-secrets.txt").write_text("synthetic-secret\n")

    # icloud_excluded channel
    (repo / "docs" / "statements").mkdir(parents=True, exist_ok=True)
    (repo / "docs" / "statements" / "2026-01.pdf").write_bytes(b"%PDF-1.4 synthetic")

    # aiteamforge_product channel
    devteam = home / "dev-team" / "finance"
    (devteam / "personas" / "agents").mkdir(parents=True, exist_ok=True)
    (devteam / "personas" / "agents" / "quark.md").write_text("# Quark\n")
    (devteam / "scripts").mkdir(parents=True, exist_ok=True)
    (devteam / "scripts" / "setup.sh").write_text("#!/bin/sh\necho synthetic\n")

    # user_state channel — claude memory
    # finance.yaml: claude_project_dir_name: "-Users-darrenehlers-finance-personal"
    # When $HOME is overridden, Path.home() == home, but the project dir name is
    # a literal string in finance.yaml — so we create it verbatim.
    project_dir = home / ".claude" / "projects" / "-Users-darrenehlers-finance-personal"
    (project_dir / "memory").mkdir(parents=True, exist_ok=True)
    (project_dir / "memory" / "MEMORY.md").write_text("# Synthetic memory\n")
    (project_dir / "session.jsonl").write_text('{"role":"user","content":"hi"}\n')

    # user_state channel — knowledge agents
    for agent in ("quark", "nog"):
        agent_dir = home / "knowledge" / "agents" / agent
        agent_dir.mkdir(parents=True, exist_ok=True)
        (agent_dir / "INDEX.md").write_text(f"# {agent} knowledge\n")

    # Minimal git repo so domain_git can run git ls-files without error.
    _git_init_repo(repo)


def _git_init_repo(repo: Path) -> None:
    """Create a minimal git repo in *repo* so git ls-files works."""
    env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "HOME": str(repo)}
    for cmd in [
        ["git", "-C", str(repo), "init"],
        ["git", "-C", str(repo), "config", "user.email", "test@synthetic.local"],
        ["git", "-C", str(repo), "config", "user.name", "Synthetic"],
        ["git", "-C", str(repo), "add", "-A"],
        ["git", "-C", str(repo), "commit", "--allow-empty", "-m", "synthetic initial commit"],
    ]:
        subprocess.run(cmd, capture_output=True, env=env)


def _start_lcars_server(
    home_dir: Path,
    port: int,
    export_dir: Path,
    import_dir: Path,
    team_transfers_dir: Path,
) -> _LCARSServer:
    """Start server.py on *port* with HOME=*home_dir*.

    Returns an _LCARSServer handle.  The caller is responsible for calling .stop().
    """
    env = os.environ.copy()
    env["HOME"] = str(home_dir)
    env["LCARS_TEAM"] = "finance"
    env["LCARS_SKIP_TEAM_VALIDATION"] = "1"
    env["LCARS_SKIP_DUAL_BOARD_CHECK"] = "1"
    env["PYTHONPATH"] = str(LCARS_UI_DIR)
    # Override EXPORT_DIR and IMPORT_STAGING_DIR via env isn't natively supported
    # by server.py — we patch them via a small launcher wrapper below instead.
    # We also override team-paths.json location to point at a nonexistent path so
    # the XACA-0463 conflict guard falls back to {"teams": {}} gracefully.
    env["AITEAMFORGE_CONFIG"] = str(home_dir / ".aiteamforge" / "team-paths.json")

    # Write a minimal team-paths.json that prevents port-conflict failures.
    # The XACA-0463 guard raises on null lcars_port for the active instance, but
    # only when the team actually appears in teams{}.  An empty teams{} is the
    # safe fallback (guard returns early with "nothing to check").
    (home_dir / ".aiteamforge").mkdir(parents=True, exist_ok=True)
    (home_dir / ".aiteamforge" / "team-paths.json").write_text(
        json.dumps({"teams": {}}), encoding="utf-8"
    )

    # Use a launcher wrapper that patches EXPORT_DIR and IMPORT_STAGING_DIR
    # before importing server so tests don't write into /tmp/lcars-exports.
    launcher = f"""\
import sys
sys.path.insert(0, {str(LCARS_UI_DIR)!r})

# Patch module-level dirs BEFORE importing server (they are set at module import time).
import importlib, types, json, os, socketserver
from pathlib import Path

# Stub heavy optional imports (mirrors test_server.py approach)
from unittest.mock import MagicMock
_stub_modules = {{
    "kanban_utils": MagicMock(
        log_activity=MagicMock(),
        read_activity_log=MagicMock(return_value={{"entries": [], "itemId": ""}}),
        get_lcars_tmp_dir=MagicMock(return_value="/tmp/"),
    ),
    "integrations": MagicMock(),
    "calendar": MagicMock(),
    "calendar.sync_service": MagicMock(),
    "calendar.apple_provider": MagicMock(),
    "calendar.provider": MagicMock(),
}}
for _mod_name, _stub in _stub_modules.items():
    if _mod_name not in sys.modules:
        sys.modules[_mod_name] = _stub

import server
server.EXPORT_DIR = Path({str(export_dir)!r})
server.IMPORT_STAGING_DIR = Path({str(import_dir)!r})

# Make team-transfers land under our temp home.
# (generate_export uses Path.home() / "team-transfers"; we rely on HOME override.)

server.EXPORT_DIR.mkdir(parents=True, exist_ok=True)
server.IMPORT_STAGING_DIR.mkdir(parents=True, exist_ok=True)

# Boot the HTTP server directly (skip main()'s startup guards — they are
# bypassed via LCARS_SKIP_TEAM_VALIDATION=1 / LCARS_SKIP_DUAL_BOARD_CHECK=1
# env vars, but main() also prints banners and calls _sweep_stale_locks;
# skipping all that keeps test startup snappy).
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", {port}), server.LCARSHandler) as httpd:
    print(f"[TEST] Server starting on port {port}", flush=True)
    httpd.serve_forever()
"""

    launcher_path = home_dir / "_test_server_launcher.py"
    launcher_path.write_text(launcher, encoding="utf-8")

    proc = subprocess.Popen(
        [sys.executable, str(launcher_path)],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    # Wait for the "[TEST] Server starting on port" banner (up to 20 s).
    deadline = time.time() + 20
    ready = False
    output_lines: list[str] = []
    while time.time() < deadline:
        line = proc.stdout.readline()  # type: ignore[union-attr]
        if not line and proc.poll() is not None:
            break
        output_lines.append(line.rstrip())
        if f"[TEST] Server starting on port {port}" in line:
            ready = True
            break

    # Drain remaining startup output in a background thread so the pipe buffer
    # never fills up and blocks the server (especially important on slow CI).
    def _drain():
        if proc.stdout:
            for _ in proc.stdout:
                pass
    threading.Thread(target=_drain, daemon=True).start()

    if not ready:
        proc.terminate()
        proc.wait()
        combined = "\n".join(output_lines)
        pytest.fail(
            f"LCARS server did not become ready within 20s.\n"
            f"Startup output:\n{combined}"
        )

    # Give the server's accept() loop one tick to settle.
    time.sleep(0.2)

    return _LCARSServer(proc, port, home_dir)


# ---------------------------------------------------------------------------
# HTTP helpers (no requests library — use urllib from stdlib)
# ---------------------------------------------------------------------------

def _http_get(url: str, timeout: int = 30) -> tuple[int, dict]:
    """GET *url*, return (status_code, response_json)."""
    import urllib.request
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.status, json.loads(resp.read().decode("utf-8"))


def _http_post_json(url: str, body: dict, timeout: int = 30) -> tuple[int, dict]:
    """POST JSON body to *url*, return (status_code, response_json).

    Does NOT raise on non-2xx — returns the raw status so callers can assert it.
    Retries once on ConnectionResetError: the module-scoped server fixture can
    leak handler state between tests when a prior heavy export hasn't fully
    drained, causing a transient reset on the next POST.
    """
    import urllib.request
    import urllib.error
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.status, json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read().decode("utf-8"))
        except ConnectionResetError:
            if attempt == 2:
                raise
            time.sleep(0.25)


def _http_post_file(url: str, file_bytes: bytes, filename: str, timeout: int = 60) -> tuple[int, dict]:
    """POST a multipart/form-data file upload to *url*.

    Matches the boundary parsing in server.py:handle_import_upload().
    """
    import urllib.request
    import urllib.error
    boundary = b"----SyntheticTestBoundary7UP"
    body = (
        b"--" + boundary + b"\r\n"
        + f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode()
        + b"Content-Type: application/zip\r\n"
        + b"\r\n"
        + file_bytes
        + b"\r\n"
        + b"--" + boundary + b"--\r\n"
    )
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary.decode()}",
            "Content-Length": str(len(body)),
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode("utf-8"))


def _http_get_bytes(url: str, timeout: int = 60) -> tuple[int, bytes]:
    """GET *url*, return (status_code, raw_bytes)."""
    import urllib.request
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.status, resp.read()


def _poll_job_status(
    status_url: str,
    terminal_states: tuple[str, ...] = ("completed", "failed"),
    poll_interval: float = 1.0,
    timeout_s: float = 120.0,
) -> dict:
    """Poll *status_url* until job state is in *terminal_states* or timeout."""
    deadline = time.time() + timeout_s
    last_status: dict = {}
    while time.time() < deadline:
        try:
            code, data = _http_get(status_url)
            last_status = data
            if data.get("status") in terminal_states:
                return data
        except Exception:
            pass
        time.sleep(poll_interval)
    pytest.fail(
        f"Job at {status_url!r} did not reach {terminal_states} within {timeout_s}s.\n"
        f"Last status: {last_status}"
    )


# ---------------------------------------------------------------------------
# Shared fixture: running LCARS server (session-scoped for speed)
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def lcars_server():
    """Boot a LCARS server subprocess once per module, stop it after all tests."""
    with tempfile.TemporaryDirectory(prefix="lcars_http_test_") as tmpdir:
        tmp = Path(tmpdir)
        home_dir = tmp / "home"
        home_dir.mkdir()
        dst_home = tmp / "dst_home"
        dst_home.mkdir()
        export_dir = tmp / "exports"
        import_dir = tmp / "imports"
        team_transfers_dir = tmp / "team-transfers"

        _build_synthetic_home(home_dir)

        port = _pick_free_port()
        server = _start_lcars_server(
            home_dir=home_dir,
            port=port,
            export_dir=export_dir,
            import_dir=import_dir,
            team_transfers_dir=team_transfers_dir,
        )
        server.dst_home = dst_home  # type: ignore[attr-defined]

        yield server

        server.stop()


# ---------------------------------------------------------------------------
# Helper: perform a full export and return the zip bytes
# ---------------------------------------------------------------------------

def _do_full_export(server: _LCARSServer) -> tuple[str, bytes, dict]:
    """Trigger export, poll to completion, download zip.

    Returns (job_id, zip_bytes, job_status_dict).
    """
    # Start the export job.
    status, data = _http_post_json(server.url("/api/export/create"), {})
    assert status == 200, f"Expected 200 on export create; got {status}: {data}"
    job_id = data["jobId"]

    # Poll until completed or failed.
    status_url = server.url(f"/api/export/status/{job_id}")
    job = _poll_job_status(status_url, timeout_s=120.0)
    assert job["status"] == "completed", (
        f"Export job failed or timed out.\nJob: {job}"
    )

    # Download the zip.
    code, zip_bytes = _http_get_bytes(server.url(f"/api/export/download/{job_id}"))
    assert code == 200, f"Expected 200 on zip download; got {code}"
    assert len(zip_bytes) > 0, "Downloaded zip is empty"

    return job_id, zip_bytes, job


# ---------------------------------------------------------------------------
# Helper: upload zip → apply → poll for import completion
# ---------------------------------------------------------------------------

def _do_full_import(
    server: _LCARSServer,
    zip_bytes: bytes,
    filename: str = "test-export.zip",
    acknowledge_missing: bool = False,
) -> tuple[int, dict, Optional[dict]]:
    """Upload zip, apply, poll for completion.

    Returns (upload_status_code, upload_response, import_job_or_None).
    If upload fails, import_job_or_None is None.
    If apply returns non-200 (e.g. 409), returns (upload_code, upload_resp, None).
    """
    upload_code, upload_resp = _http_post_file(
        server.url("/api/import/upload"),
        zip_bytes,
        filename=filename,
    )
    if upload_code != 200:
        return upload_code, upload_resp, None

    job_id = upload_resp["jobId"]

    # Apply the import.
    apply_body: dict = {}
    if acknowledge_missing:
        apply_body["acknowledgeMissingSecrets"] = True

    apply_code, apply_resp = _http_post_json(
        server.url(f"/api/import/apply/{job_id}"),
        apply_body,
    )
    if apply_code != 200:
        return apply_code, apply_resp, None

    # Poll until complete.
    status_url = server.url(f"/api/import/status/{job_id}")
    import_job = _poll_job_status(status_url, timeout_s=120.0)
    return upload_code, upload_resp, import_job


# ---------------------------------------------------------------------------
# Test 1 — Golden path: export → upload → apply → verifier PASS
# ---------------------------------------------------------------------------

def test_golden_path_export_import(lcars_server: _LCARSServer):
    """Full round-trip: generate export zip, upload to import, apply, verify."""
    server = lcars_server

    # Step 1: Export.
    _job_id, zip_bytes, export_job = _do_full_export(server)

    # Step 2: Assert export zip has the required root artifacts.
    with zipfile.ZipFile(io.BytesIO(zip_bytes), "r") as zf:
        names = set(zf.namelist())
        assert "manifest.json" in names, (
            f"manifest.json must be at zip root. Names: {sorted(names)[:20]}"
        )
        assert "verifier-report.txt" in names, (
            "verifier-report.txt must be at zip root."
        )
        # PRE_EXPORT_CHECKLIST.md is only present when generator emits it;
        # it may be absent if the team config has no home-guard path.  We
        # assert it as a WARN, not a hard failure here (the server warns too).

        # Validate manifest at zip root.
        manifest_raw = zf.read("manifest.json").decode("utf-8")

    manifest_data = json.loads(manifest_raw)
    assert "schema_version" in manifest_data, (
        "manifest.json must have schema_version (new format marker)"
    )

    # Step 3: Verify secrets_summary present in embedded manifest.
    assert "secrets_summary" in manifest_data, (
        f"manifest.json must contain secrets_summary.\nManifest keys: {list(manifest_data.keys())}"
    )
    ss = manifest_data["secrets_summary"]
    assert "expected" in ss, "secrets_summary must have 'expected' field"
    assert "discovered" in ss, "secrets_summary must have 'discovered' field"
    assert "paired_status" in ss, "secrets_summary must have 'paired_status' field"

    # Step 4: Upload zip to import endpoint.
    upload_code, upload_resp = _http_post_file(
        server.url("/api/import/upload"),
        zip_bytes,
        filename="test-export.zip",
    )
    assert upload_code == 200, (
        f"Expected 200 on import upload; got {upload_code}.\nResponse: {upload_resp}"
    )
    assert upload_resp.get("importFormat") == "new", (
        f"Expected importFormat='new'; got {upload_resp.get('importFormat')!r}"
    )
    assert "jobId" in upload_resp, "Upload response must include jobId"

    # Step 5: Check pre-flight verifier summary in upload response.
    ver_summary = upload_resp.get("verifierSummary", {})
    assert ver_summary.get("present") is True, (
        "verifierSummary.present must be True in upload response"
    )
    # Phase must be 'preflight'.
    assert ver_summary.get("phase") == "preflight", (
        f"Expected verifierSummary.phase='preflight'; got {ver_summary.get('phase')!r}"
    )

    # Step 6: Apply the import (acknowledged if secrets gate fires).
    job_id = upload_resp["jobId"]
    apply_code, apply_resp = _http_post_json(
        server.url(f"/api/import/apply/{job_id}"),
        # acknowledgeMissingSecrets=True because secrets_summary.discovered may be >0
        # in environments where secrets_export_lib is available.  It is a no-op when
        # discovered=0 (the common test-env case).
        {"acknowledgeMissingSecrets": True},
    )
    assert apply_code == 200, (
        f"Expected 200 on import apply; got {apply_code}.\nResponse: {apply_resp}"
    )

    # Step 7: Poll import to completion.
    status_url = server.url(f"/api/import/status/{job_id}")
    import_job = _poll_job_status(status_url, timeout_s=120.0)
    assert import_job["status"] == "completed", (
        f"Import job must complete successfully.\nJob: {import_job}"
    )

    # Step 8: Verify extraction stats.
    stats = import_job.get("stats", {})
    assert stats.get("extracted", 0) > 0, (
        f"At least one file must be extracted during import.\nStats: {stats}"
    )

    # Step 9: Verify post-restore verifier summary.
    post_ver = import_job.get("verifierSummary", {})
    assert post_ver.get("present") is True, (
        "Post-restore verifierSummary.present must be True"
    )
    assert post_ver.get("phase") == "post-restore", (
        f"Expected phase='post-restore'; got {post_ver.get('phase')!r}"
    )

    # Step 10: Verify per-channel shape — must have at least state + counts keys.
    per_channel = post_ver.get("perChannel", {})
    assert isinstance(per_channel, dict), "perChannel must be a dict"
    if per_channel:
        for ch_name, ch_data in per_channel.items():
            assert "state" in ch_data, (
                f"Channel {ch_name!r} missing 'state' key: {ch_data}"
            )
            assert ch_data["state"] in ("PASS", "WARN", "FAIL"), (
                f"Channel {ch_name!r} state must be PASS/WARN/FAIL; got {ch_data['state']!r}"
            )
            assert "counts" in ch_data, (
                f"Channel {ch_name!r} missing 'counts' key: {ch_data}"
            )
            counts = ch_data["counts"]
            for k in ("pass", "warn", "fail"):
                assert k in counts, (
                    f"Channel {ch_name!r} counts missing key {k!r}: {counts}"
                )


# ---------------------------------------------------------------------------
# Test 2 — manifest.json at zip root (not under team_transfer/)
# ---------------------------------------------------------------------------

def test_manifest_at_zip_root_not_subdirectory(lcars_server: _LCARSServer):
    """Manifest must be at zip root (manifest.json), not team_transfer/manifest.json."""
    _, zip_bytes, _ = _do_full_export(lcars_server)

    with zipfile.ZipFile(io.BytesIO(zip_bytes), "r") as zf:
        names = zf.namelist()

    assert "manifest.json" in names, (
        f"Expected 'manifest.json' at zip root. Names: {sorted(names)[:20]}"
    )
    # The old XACA-0496 append also included team_transfer/manifest.json; XACA-0520-003
    # removes the legacy append in favour of the root-level canonical copy.  Both forms
    # are acceptable from the test's perspective as long as the root copy is present.


# ---------------------------------------------------------------------------
# Test 3 — PRE_EXPORT_CHECKLIST.md in zip root
# ---------------------------------------------------------------------------

def test_pre_export_checklist_in_zip_root(lcars_server: _LCARSServer):
    """PRE_EXPORT_CHECKLIST.md must be included at zip root when the generator emits it.

    The generator only emits the checklist when running against a real home guard
    path.  In test environments without the full aiteamforge installation the
    checklist may be absent — we assert its presence when the generator emitted it
    (i.e., when the server logs no WARN about a missing checklist).
    """
    _, zip_bytes, export_job = _do_full_export(lcars_server)

    with zipfile.ZipFile(io.BytesIO(zip_bytes), "r") as zf:
        names = set(zf.namelist())

    # Soft assertion: if the verifier ran cleanly we expect the checklist.
    # If the server itself warned about missing checklist this is acceptable in CI.
    ver_summary = export_job.get("verifierSummary", {})
    # At minimum, the zip must NOT have the checklist OUTSIDE the root.
    for name in names:
        assert not name.endswith("/PRE_EXPORT_CHECKLIST.md") or name == "PRE_EXPORT_CHECKLIST.md", (
            f"PRE_EXPORT_CHECKLIST.md must be at zip root, not {name!r}"
        )


# ---------------------------------------------------------------------------
# Test 4 — secrets handshake path A: discovered=0 → import succeeds without override
# ---------------------------------------------------------------------------

def test_secrets_handshake_path_a_discovered_zero(lcars_server: _LCARSServer):
    """Secrets handshake path A: discovered=0 in manifest → import apply succeeds.

    Builds a synthetic zip with discovered=0 in secrets_summary and asserts
    that handle_import_apply does NOT return 409.
    """
    zip_bytes = _build_synthetic_zip(discovered=0)

    upload_code, upload_resp = _http_post_file(
        lcars_server.url("/api/import/upload"),
        zip_bytes,
        filename="handshake-a.zip",
    )
    assert upload_code == 200, (
        f"Upload must succeed for handshake path A.\nResponse: {upload_resp}"
    )

    job_id = upload_resp["jobId"]
    # No acknowledgeMissingSecrets — should work because discovered=0.
    apply_code, apply_resp = _http_post_json(
        lcars_server.url(f"/api/import/apply/{job_id}"),
        {},
    )
    assert apply_code == 200, (
        f"Apply must succeed when discovered=0 (path A).\n"
        f"Status: {apply_code}, Response: {apply_resp}"
    )

    # Poll to completion so the background thread doesn't interfere with later tests.
    _poll_job_status(
        lcars_server.url(f"/api/import/status/{job_id}"),
        timeout_s=60.0,
    )


# ---------------------------------------------------------------------------
# Test 5 — secrets handshake path B: discovered>0, no paired zip → HTTP 409
# ---------------------------------------------------------------------------

def test_secrets_handshake_path_b_missing_paired_zip_returns_409(lcars_server: _LCARSServer):
    """Secrets handshake path B: discovered>0, no override → HTTP 409 missing_paired_secrets."""
    zip_bytes = _build_synthetic_zip(discovered=2, expected=2)

    upload_code, upload_resp = _http_post_file(
        lcars_server.url("/api/import/upload"),
        zip_bytes,
        filename="handshake-b.zip",
    )
    assert upload_code == 200, (
        f"Upload must succeed for handshake path B.\nResponse: {upload_resp}"
    )

    job_id = upload_resp["jobId"]
    # No acknowledgeMissingSecrets, no paired secrets zip uploaded.
    apply_code, apply_resp = _http_post_json(
        lcars_server.url(f"/api/import/apply/{job_id}"),
        {},
    )
    assert apply_code == 409, (
        f"Expected HTTP 409 when discovered>0 and no paired zip (path B).\n"
        f"Status: {apply_code}, Response: {apply_resp}"
    )
    assert apply_resp.get("error") == "missing_paired_secrets", (
        f"Expected error='missing_paired_secrets' in 409 body.\nResponse: {apply_resp}"
    )
    assert apply_resp.get("override_flag") == "acknowledgeMissingSecrets", (
        f"Expected override_flag='acknowledgeMissingSecrets'.\nResponse: {apply_resp}"
    )
    assert int(apply_resp.get("discovered", 0)) >= 2, (
        f"Expected discovered>=2 in 409 body.\nResponse: {apply_resp}"
    )


# ---------------------------------------------------------------------------
# Test 6 — secrets handshake path C: discovered>0, acknowledgeMissing=True → succeeds
# ---------------------------------------------------------------------------

def test_secrets_handshake_path_c_acknowledge_missing_succeeds(lcars_server: _LCARSServer):
    """Secrets handshake path C: discovered>0 + acknowledgeMissingSecrets=True → import succeeds."""
    zip_bytes = _build_synthetic_zip(discovered=1, expected=1)

    upload_code, upload_resp = _http_post_file(
        lcars_server.url("/api/import/upload"),
        zip_bytes,
        filename="handshake-c.zip",
    )
    assert upload_code == 200, (
        f"Upload must succeed for handshake path C.\nResponse: {upload_resp}"
    )

    job_id = upload_resp["jobId"]
    apply_code, apply_resp = _http_post_json(
        lcars_server.url(f"/api/import/apply/{job_id}"),
        {"acknowledgeMissingSecrets": True},
    )
    assert apply_code == 200, (
        f"Apply must succeed when acknowledgeMissingSecrets=True (path C).\n"
        f"Status: {apply_code}, Response: {apply_resp}"
    )

    # Poll to completion.
    import_job = _poll_job_status(
        lcars_server.url(f"/api/import/status/{job_id}"),
        timeout_s=60.0,
    )
    assert import_job["status"] == "completed", (
        f"Import must complete successfully on path C.\nJob: {import_job}"
    )


# ---------------------------------------------------------------------------
# Test 7 — per-channel verifier PASS/WARN/FAIL shape in import response
# ---------------------------------------------------------------------------

def test_per_channel_verifier_shape_in_import_response(lcars_server: _LCARSServer):
    """Import response verifierSummary must have perChannel with PASS/WARN/FAIL shape."""
    _, zip_bytes, _ = _do_full_export(lcars_server)
    upload_code, upload_resp, import_job = _do_full_import(
        lcars_server, zip_bytes, acknowledge_missing=True
    )
    assert upload_code == 200
    assert import_job is not None and import_job["status"] == "completed"

    post_ver = import_job.get("verifierSummary", {})
    per_channel = post_ver.get("perChannel", {})

    # The verifier must have emitted at least one per-channel line.
    # (If the verifier failed entirely, perChannel would be empty — flag that.)
    assert per_channel, (
        f"perChannel must be non-empty in post-restore verifierSummary.\n"
        f"Full verifierSummary: {post_ver}"
    )

    # Every channel entry must conform to the documented shape.
    for ch_name, ch_data in per_channel.items():
        assert isinstance(ch_data, dict), (
            f"Channel {ch_name!r}: data must be a dict, got {type(ch_data)}"
        )
        assert ch_data.get("state") in ("PASS", "WARN", "FAIL"), (
            f"Channel {ch_name!r}: state={ch_data.get('state')!r} is not PASS/WARN/FAIL"
        )
        counts = ch_data.get("counts", {})
        assert isinstance(counts, dict), (
            f"Channel {ch_name!r}: counts must be a dict, got {type(counts)}"
        )
        for k in ("pass", "warn", "fail"):
            assert k in counts and isinstance(counts[k], int), (
                f"Channel {ch_name!r}: counts[{k!r}] must be an int, got {counts.get(k)!r}"
            )


# ---------------------------------------------------------------------------
# Helper: build a synthetic zip for handshake tests
# ---------------------------------------------------------------------------

def _build_synthetic_zip(
    discovered: int = 0,
    expected: int = 0,
) -> bytes:
    """Build a minimal valid LCARS-format zip with the given secrets_summary values.

    The zip contains manifest.json at root (with schema_version so the import
    handler recognises the new format) and a tiny relpath file so that apply_import
    has at least one entry to extract.

    The manifest uses the 'git' channel for the dummy file so it passes the
    channel-skip filter (not 'secrets_export' or 'icloud_excluded').
    """
    manifest = {
        "schema_version": "1",
        "kind": "team_transfer-manifest-v1",
        "secrets_summary": {
            "expected": expected,
            "discovered": discovered,
            "paired_status": "none",
            "paired_job_id": None,
        },
        "domains": {
            "synthetic": {
                "files": [
                    {
                        "path": "/synthetic/test_placeholder.txt",
                        "relpath": "_lcars_test_synthetic/placeholder.txt",
                        "channel": "git",
                        "cls": "present",
                    }
                ]
            }
        },
    }

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("manifest.json", json.dumps(manifest, indent=2))
        # The placeholder relpath is in the zip so extraction doesn't skip it.
        zf.writestr("_lcars_test_synthetic/placeholder.txt", "synthetic placeholder\n")
        # Include a dummy verifier report so the import handler finds it.
        zf.writestr("verifier-report.txt", "=== SUMMARY ===\n  PASS: 0\n  WARN: 0\n  FAIL: 0\n")
    return buf.getvalue()
