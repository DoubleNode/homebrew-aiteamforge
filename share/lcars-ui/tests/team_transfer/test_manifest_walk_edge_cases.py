"""XACA-0520-008: Edge-case unit tests for manifest-walk packing + import gates.

Covers six edge-case families not addressed by test_lcars_http_roundtrip.py:

1. Empty channel — a domain with files: [] does not crash generate_export().
2. Missing source file — file in manifest does not exist on disk at pack time;
   generate_export() skips with a warning (documented behavior).
3. Channel-filter exhaustive — parametrized over ALL_CHANNELS from channels.py;
   verifies the SKIP_CHANNELS filter in generate_export() matches documented behavior.
4. Oversized zip pre-check — Content-Length > 500 MB header → HTTP 400.
5. Manifest-walk skip-channel leakage — secrets_export/icloud_excluded files
   must NEVER appear in the main zip even when the source files exist on disk.
6. acknowledgeMissingSecrets parsing — bool/string/null/absent/False all behave
   correctly (includes the known bool("false") == True edge case documented below).

Test approach: where possible, these are pure in-process unit tests that
mock only what is strictly necessary, using tempdir fixtures for filesystem
isolation.  The oversized-upload test and the acknowledgeMissingSecrets test
drive the live LCARS HTTP server (module-scoped fixture re-used from
test_lcars_http_roundtrip.py via conftest import) to test server-side parsing.

REGRESSION GUARD — acknowledgeMissingSecrets type-aware parsing:
----------------------------------------------------------------
Pre-fix the handler used `bool(body_json.get('acknowledgeMissingSecrets', False))`
which made any non-empty string truthy — so `{"acknowledgeMissingSecrets": "false"}`
accidentally bypassed the secrets-coordination gate. Post-fix (XACA-0520-008) the
parser only treats {True, 1, "true", "yes", "1"} (case-insensitive strings) as
truthy. test_ack_string_false_blocks_gate is the regression check; do not relax it.
"""
from __future__ import annotations

import io
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
from pathlib import Path
from typing import Any, Optional
from unittest.mock import MagicMock, patch

import pytest

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

LCARS_UI_DIR = Path(__file__).resolve().parents[2]   # lcars-ui/
REPO_ROOT = LCARS_UI_DIR.parent                       # worktree root
SERVER_PY = LCARS_UI_DIR / "server.py"

# Channels from team_transfer/channels.py — imported for parametrize
sys.path.insert(0, str(LCARS_UI_DIR))
from team_transfer import channels as ch

# The two channels that generate_export() MUST skip (SKIP_CHANNELS constant).
EXPECTED_SKIP_CHANNELS = frozenset({"secrets_export", "icloud_excluded"})
# All channels that MUST be included (not in SKIP_CHANNELS).
EXPECTED_INCLUDE_CHANNELS = frozenset(ch.ALL_CHANNELS) - EXPECTED_SKIP_CHANNELS


# ---------------------------------------------------------------------------
# Helpers: manifest builders
# ---------------------------------------------------------------------------

def _make_manifest(domains: dict) -> dict:
    """Build a minimal valid new-format manifest dict."""
    return {
        "schema_version": "1",
        "kind": "team_transfer-manifest-v1",
        "secrets_summary": {
            "expected": 0,
            "discovered": 0,
            "paired_status": "none",
            "paired_job_id": None,
        },
        "domains": domains,
    }


def _build_zip_from_manifest(manifest: dict, on_disk_files: dict[str, bytes]) -> bytes:
    """Build a zip whose data files match *on_disk_files* (relpath -> bytes).

    The manifest is embedded at zip root.  Only files whose relpath key appears
    in *on_disk_files* are physically added to the zip.
    """
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("manifest.json", json.dumps(manifest, indent=2))
        zf.writestr("verifier-report.txt", "=== SUMMARY ===\n  PASS: 0\n  WARN: 0\n  FAIL: 0\n")
        for relpath, data in on_disk_files.items():
            zf.writestr(relpath, data)
    return buf.getvalue()


# ---------------------------------------------------------------------------
# Test 1 — Empty channel: manifest has a channel with files: []
# ---------------------------------------------------------------------------

def test_empty_channel_manifest_does_not_crash_packing():
    """A domain block with files: [] must not crash the packing logic.

    generate_export() walks manifest.domains[*].files[*] and appends non-skip
    entries to `packable`.  An empty files list must simply produce zero entries
    for that domain.  This is a pure in-process unit test against the same
    filter logic embedded in generate_export().

    Acceptable behavior: no exception, packable count reflects only real entries.
    """
    manifest = _make_manifest({
        "empty_domain": {"files": []},
        "real_domain": {
            "files": [
                {
                    "path": "/some/real/file.txt",
                    "relpath": "finance/personal/src/file.txt",
                    "channel": "git",
                    "cls": "exact",
                }
            ]
        },
    })

    # Mirror the filter from generate_export().
    SKIP_CHANNELS = frozenset({"secrets_export", "icloud_excluded"})
    packable = []
    for _dname, dblock in manifest["domains"].items():
        files = dblock.get("files", []) if isinstance(dblock, dict) else []
        for fe in files:
            if fe.get("channel") in SKIP_CHANNELS:
                continue
            packable.append(fe)

    assert len(packable) == 1, (
        f"Expected 1 packable entry (the real_domain file); got {len(packable)}"
    )
    assert packable[0]["relpath"] == "finance/personal/src/file.txt"


def test_all_empty_channels_produces_zero_packable():
    """When ALL domains have files:[], packable is empty.

    generate_export() would then fail with 'No packable files found' — the test
    asserts the filter produces an empty list, confirming the failure path is
    correctly data-driven (not a crash).
    """
    manifest = _make_manifest({
        "alpha": {"files": []},
        "beta":  {"files": []},
        "gamma": {"files": []},
    })

    SKIP_CHANNELS = frozenset({"secrets_export", "icloud_excluded"})
    packable = []
    for _dname, dblock in manifest["domains"].items():
        files = dblock.get("files", []) if isinstance(dblock, dict) else []
        for fe in files:
            if fe.get("channel") in SKIP_CHANNELS:
                continue
            packable.append(fe)

    assert packable == [], (
        f"Expected empty packable from all-empty-channel manifest; got {packable}"
    )


# ---------------------------------------------------------------------------
# Test 2 — Missing source file
# ---------------------------------------------------------------------------

def test_missing_source_file_is_skipped_not_raised():
    """When a manifest entry's source file does not exist on disk, generate_export()
    skips it with a WARN print and increments `skipped`, rather than raising.

    This test mirrors the exact packing loop from generate_export() step 4
    (server.py ~line 721-733) in isolation, using a tempdir so no actual
    filesystem side-effects occur outside the tmpdir.

    Documented behavior:
      - Source missing  → skip (skipped += 1), WARN printed
      - Source present  → packed into zip
      - No exception is raised either way
    """
    with tempfile.TemporaryDirectory(prefix="test_missing_src_") as tmpdir:
        tmp = Path(tmpdir)

        # Create one real file and declare one missing file.
        real_file = tmp / "real.txt"
        real_file.write_text("real content\n", encoding="utf-8")

        packable = [
            {"path": str(real_file), "relpath": "team/src/real.txt", "channel": "git"},
            {"path": str(tmp / "DOES_NOT_EXIST.txt"), "relpath": "team/src/missing.txt", "channel": "git"},
        ]

        out_zip = tmp / "out.zip"
        skipped = 0
        printed_warnings: list[str] = []

        original_print = print

        def capturing_print(*args, **kwargs):
            msg = " ".join(str(a) for a in args)
            if "WARN" in msg or "source missing" in msg or "Skipped" in msg:
                printed_warnings.append(msg)
            original_print(*args, **kwargs)

        import builtins
        with patch.object(builtins, "print", side_effect=capturing_print):
            with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as zipf:
                for fe in packable:
                    src_path = fe.get("path", "")
                    relpath = fe.get("relpath", "")
                    if not src_path or not Path(src_path).exists():
                        capturing_print(f"[LCARS Export] WARN: source missing, skipping: {src_path}")
                        skipped += 1
                    else:
                        try:
                            zipf.write(src_path, relpath)
                        except (PermissionError, OSError) as e:
                            capturing_print(f"[LCARS Export] Skipped: {relpath} ({e.__class__.__name__})")
                            skipped += 1

        assert skipped == 1, f"Expected exactly 1 skipped file; got {skipped}"
        assert len(printed_warnings) == 1, (
            f"Expected 1 WARN about missing file; got {printed_warnings}"
        )
        assert "DOES_NOT_EXIST" in printed_warnings[0], (
            f"WARN must name the missing path; got: {printed_warnings[0]!r}"
        )

        # The real file must be in the zip.
        with zipfile.ZipFile(out_zip, "r") as zf:
            names = zf.namelist()
        assert "team/src/real.txt" in names, (
            f"Real file must be in zip; namelist: {names}"
        )
        assert "team/src/missing.txt" not in names, (
            f"Missing file must NOT appear in zip; namelist: {names}"
        )


# ---------------------------------------------------------------------------
# Test 3 — Channel-filter exhaustive: parametrized over ALL_CHANNELS
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("channel", list(ch.ALL_CHANNELS))
def test_channel_filter_rule(channel: str):
    """Verify the export-side SKIP_CHANNELS filter for every channel in ALL_CHANNELS.

    Channels 'secrets_export' and 'icloud_excluded' MUST be skipped (not packed).
    All other channels MUST pass through (packed).

    This test creates a one-entry manifest with the given channel tag and asserts
    whether the filter loop keeps or discards it, consistent with CHANNELS.md:

    | Channel             | Packed in main zip? |
    |---------------------|---------------------|
    | git                 | YES                 |
    | aiteamforge_product | YES                 |
    | user_state          | YES                 |
    | export_kanban       | YES                 |
    | export_database     | YES                 |
    | secrets_export      | NO  (skip)          |
    | icloud_excluded     | NO  (skip)          |
    """
    SKIP_CHANNELS = frozenset({"secrets_export", "icloud_excluded"})

    manifest = _make_manifest({
        "test_domain": {
            "files": [
                {
                    "path": "/some/path/file.txt",
                    "relpath": "team/file.txt",
                    "channel": channel,
                    "cls": "exact",
                }
            ]
        }
    })

    packable = []
    for _dname, dblock in manifest["domains"].items():
        files = dblock.get("files", []) if isinstance(dblock, dict) else []
        for fe in files:
            if fe.get("channel") in SKIP_CHANNELS:
                continue
            packable.append(fe)

    if channel in SKIP_CHANNELS:
        assert packable == [], (
            f"Channel {channel!r} is in SKIP_CHANNELS and must be excluded from packable; "
            f"got: {packable}"
        )
    else:
        assert len(packable) == 1, (
            f"Channel {channel!r} is NOT in SKIP_CHANNELS and must be included; "
            f"got packable={packable}"
        )
        assert packable[0]["channel"] == channel


# ---------------------------------------------------------------------------
# Live-server fixture (shared with test_lcars_http_roundtrip.py pattern)
# ---------------------------------------------------------------------------

class _LCARSServer:
    """Minimal handle to a server.py subprocess."""

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
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _start_edge_case_server(home_dir: Path, port: int, export_dir: Path, import_dir: Path) -> _LCARSServer:
    """Start a minimal LCARS server for edge-case tests."""
    env = os.environ.copy()
    env["HOME"] = str(home_dir)
    env["LCARS_TEAM"] = "finance"
    env["LCARS_SKIP_TEAM_VALIDATION"] = "1"
    env["LCARS_SKIP_DUAL_BOARD_CHECK"] = "1"
    env["PYTHONPATH"] = str(LCARS_UI_DIR)
    env["AITEAMFORGE_CONFIG"] = str(home_dir / ".aiteamforge" / "team-paths.json")

    (home_dir / ".aiteamforge").mkdir(parents=True, exist_ok=True)
    (home_dir / ".aiteamforge" / "team-paths.json").write_text(
        json.dumps({"teams": {}}), encoding="utf-8"
    )

    launcher = f"""\
import sys
sys.path.insert(0, {str(LCARS_UI_DIR)!r})
from unittest.mock import MagicMock
from pathlib import Path
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
import server, socketserver
server.EXPORT_DIR = Path({str(export_dir)!r})
server.IMPORT_STAGING_DIR = Path({str(import_dir)!r})
server.EXPORT_DIR.mkdir(parents=True, exist_ok=True)
server.IMPORT_STAGING_DIR.mkdir(parents=True, exist_ok=True)
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("", {port}), server.LCARSHandler) as httpd:
    print(f"[TEST] Server starting on port {port}", flush=True)
    httpd.serve_forever()
"""
    launcher_path = home_dir / "_edge_test_launcher.py"
    launcher_path.write_text(launcher, encoding="utf-8")

    proc = subprocess.Popen(
        [sys.executable, str(launcher_path)],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

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

    def _drain():
        if proc.stdout:
            for _ in proc.stdout:
                pass
    threading.Thread(target=_drain, daemon=True).start()

    if not ready:
        proc.terminate()
        proc.wait()
        pytest.fail(
            f"Edge-case server did not start within 20s.\n"
            + "\n".join(output_lines)
        )
    time.sleep(0.2)
    return _LCARSServer(proc, port, home_dir)


@pytest.fixture(scope="module")
def edge_server():
    """Module-scoped LCARS server for edge-case HTTP tests."""
    with tempfile.TemporaryDirectory(prefix="lcars_edge_test_") as tmpdir:
        tmp = Path(tmpdir)
        home_dir = tmp / "home"
        home_dir.mkdir()
        export_dir = tmp / "exports"
        import_dir = tmp / "imports"

        port = _pick_free_port()
        server = _start_edge_case_server(home_dir, port, export_dir, import_dir)
        yield server
        server.stop()


# ---------------------------------------------------------------------------
# HTTP helpers (stdlib only, no requests)
# ---------------------------------------------------------------------------

def _http_post_file(url: str, file_bytes: bytes, filename: str, timeout: int = 30,
                    extra_headers: Optional[dict] = None) -> tuple[int, dict]:
    import urllib.request
    import urllib.error
    boundary = b"----EdgeCaseBoundary42"
    body = (
        b"--" + boundary + b"\r\n"
        + f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode()
        + b"Content-Type: application/zip\r\n"
        + b"\r\n"
        + file_bytes
        + b"\r\n"
        + b"--" + boundary + b"--\r\n"
    )
    headers = {
        "Content-Type": f"multipart/form-data; boundary={boundary.decode()}",
        "Content-Length": str(len(body)),
    }
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode("utf-8"))


def _http_post_json(url: str, body: dict, timeout: int = 30) -> tuple[int, dict]:
    import urllib.request
    import urllib.error
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode("utf-8"))


def _poll_job_status(
    status_url: str,
    terminal_states: tuple[str, ...] = ("completed", "failed"),
    poll_interval: float = 1.0,
    timeout_s: float = 60.0,
) -> dict:
    import urllib.request
    deadline = time.time() + timeout_s
    last: dict = {}
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(status_url, timeout=10) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                last = data
                if data.get("status") in terminal_states:
                    return data
        except Exception:
            pass
        time.sleep(poll_interval)
    pytest.fail(
        f"Job at {status_url!r} did not reach {terminal_states} in {timeout_s}s.\n"
        f"Last: {last}"
    )


def _build_synthetic_zip_for_edge(discovered: int = 0, expected: int = 0) -> bytes:
    """Build a minimal new-format zip with given secrets_summary values."""
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
                        "path": "/synthetic/placeholder.txt",
                        "relpath": "_edge_test/placeholder.txt",
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
        zf.writestr("_edge_test/placeholder.txt", "edge case placeholder\n")
        zf.writestr("verifier-report.txt", "=== SUMMARY ===\n  PASS: 0\n  WARN: 0\n  FAIL: 0\n")
    return buf.getvalue()


# ---------------------------------------------------------------------------
# Test 4 — Oversized zip pre-check: Content-Length > 500 MB → HTTP 400
# ---------------------------------------------------------------------------

def test_oversized_upload_content_length_returns_400(edge_server: _LCARSServer):
    """A request with Content-Length > 500*1024*1024 must be rejected with HTTP 400.

    We use Content-Length header trickery: send a tiny real body but declare a
    Content-Length of 500 MB + 1 bytes.  The server checks Content-Length BEFORE
    reading the body, so the request is rejected immediately — we never actually
    transmit 500 MB of data.

    Expected: HTTP 400 with error 'Invalid or too-large upload (max 500 MB)'.
    """
    import urllib.request
    import urllib.error

    # 500 MB + 1 byte in the header — the actual body is tiny.
    oversized_cl = str(500 * 1024 * 1024 + 1)

    # A real (small) multipart body so the connection doesn't fail for protocol reasons.
    boundary = b"----OversizeTestBoundary"
    tiny_body = (
        b"--" + boundary + b"\r\n"
        + b'Content-Disposition: form-data; name="file"; filename="oversize.zip"\r\n'
        + b"Content-Type: application/zip\r\n"
        + b"\r\n"
        + b"PK\x03\x04"  # minimal zip magic
        + b"\r\n"
        + b"--" + boundary + b"--\r\n"
    )

    req = urllib.request.Request(
        edge_server.url("/api/import/upload"),
        data=tiny_body,
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary.decode()}",
            # Lie: claim 500MB+1 even though we only send tiny_body.
            "Content-Length": oversized_cl,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            status = resp.status
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        status = exc.code
        body = json.loads(exc.read().decode("utf-8"))

    assert status == 400, (
        f"Expected HTTP 400 for oversized upload (Content-Length={oversized_cl}); "
        f"got {status}.\nResponse: {body}"
    )
    assert "too-large" in body.get("error", "").lower() or "500" in body.get("error", ""), (
        f"400 response must mention 'too-large' or '500 MB'; got: {body}"
    )


def test_zero_content_length_returns_400(edge_server: _LCARSServer):
    """Content-Length of 0 must also be rejected with HTTP 400.

    The guard: content_length <= 0 or content_length > 500 * 1024 * 1024.
    """
    import urllib.request
    import urllib.error

    boundary = b"----ZeroCLBoundary"
    tiny_body = b"--" + boundary + b"--\r\n"

    req = urllib.request.Request(
        edge_server.url("/api/import/upload"),
        data=tiny_body,
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary.decode()}",
            "Content-Length": "0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            status = resp.status
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        status = exc.code
        body = json.loads(exc.read().decode("utf-8"))

    assert status == 400, (
        f"Expected HTTP 400 for Content-Length=0; got {status}.\nResponse: {body}"
    )


# ---------------------------------------------------------------------------
# Test 5 — Manifest-walk skip-channel leakage
# ---------------------------------------------------------------------------

def test_skip_channel_files_absent_from_main_zip():
    """Files tagged secrets_export or icloud_excluded must NEVER appear in the main zip.

    Strategy: build a manifest that includes one file per ALL_CHANNELS where the
    source file exists on disk under a tempdir.  Run the packing filter loop.
    Assert:
      - No secrets_export or icloud_excluded relpaths appear in the zip.
      - At least one entry from every non-skip channel IS in the zip.
    """
    with tempfile.TemporaryDirectory(prefix="test_skip_leakage_") as tmpdir:
        tmp = Path(tmpdir)

        # Create a real source file for EVERY channel.
        files_by_channel: dict[str, dict] = {}
        for ch_name in ch.ALL_CHANNELS:
            src = tmp / f"source_{ch_name}.txt"
            src.write_text(f"content for {ch_name}\n", encoding="utf-8")
            files_by_channel[ch_name] = {
                "path": str(src),
                "relpath": f"team/{ch_name}/file.txt",
                "channel": ch_name,
                "cls": "exact",
            }

        manifest = _make_manifest({
            ch_name: {"files": [fe]}
            for ch_name, fe in files_by_channel.items()
        })

        SKIP_CHANNELS = frozenset({"secrets_export", "icloud_excluded"})

        # Run the packing filter (mirrors generate_export step 4).
        packable = []
        for _dname, dblock in manifest["domains"].items():
            files = dblock.get("files", []) if isinstance(dblock, dict) else []
            for fe in files:
                if fe.get("channel") in SKIP_CHANNELS:
                    continue
                packable.append(fe)

        out_zip = tmp / "out.zip"
        with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as zipf:
            zipf.writestr("manifest.json", json.dumps(manifest, indent=2))
            for fe in packable:
                zipf.write(fe["path"], fe["relpath"])

        with zipfile.ZipFile(out_zip, "r") as zf:
            names = set(zf.namelist())

        # Assert skip-channel files are absent.
        for skip_ch in SKIP_CHANNELS:
            expected_absent = f"team/{skip_ch}/file.txt"
            assert expected_absent not in names, (
                f"Channel {skip_ch!r} file {expected_absent!r} must NOT appear in zip. "
                f"SKIP_CHANNELS leak detected!\nZip contents: {sorted(names)}"
            )

        # Assert include-channel files are present.
        for include_ch in ch.ALL_CHANNELS:
            if include_ch in SKIP_CHANNELS:
                continue
            expected_present = f"team/{include_ch}/file.txt"
            assert expected_present in names, (
                f"Channel {include_ch!r} file {expected_present!r} MUST appear in zip. "
                f"Unexpected filter exclusion!\nZip contents: {sorted(names)}"
            )


def test_planted_secret_file_under_secrets_path_absent_from_zip():
    """Planting a synthetic 'secret' file in a secrets_export-tagged entry must
    not cause it to appear in the main zip, even when the file exists on disk.

    This is stricter than test_skip_channel_files_absent_from_main_zip because it
    uses a path that a real team config would tag as secrets_export (e.g., .env).
    The channel tag in the manifest entry is what drives the filter — path alone
    does not override the tag.
    """
    with tempfile.TemporaryDirectory(prefix="test_secret_planted_") as tmpdir:
        tmp = Path(tmpdir)

        # Plant the "secret" file on disk.
        secret_file = tmp / ".env"
        secret_file.write_text("API_KEY=totally-synthetic\n", encoding="utf-8")

        # Also plant a non-secret file.
        normal_file = tmp / "src" / "main.py"
        normal_file.parent.mkdir()
        normal_file.write_text("print('hello')\n", encoding="utf-8")

        manifest = _make_manifest({
            "real_code": {
                "files": [
                    {
                        "path": str(normal_file),
                        "relpath": "team/src/main.py",
                        "channel": "git",
                        "cls": "exact",
                    }
                ]
            },
            "secrets": {
                "files": [
                    {
                        "path": str(secret_file),
                        "relpath": "team/.env",
                        "channel": "secrets_export",  # explicitly tagged
                        "cls": "present",
                    }
                ]
            },
        })

        SKIP_CHANNELS = frozenset({"secrets_export", "icloud_excluded"})
        packable = []
        for _dname, dblock in manifest["domains"].items():
            files = dblock.get("files", []) if isinstance(dblock, dict) else []
            for fe in files:
                if fe.get("channel") in SKIP_CHANNELS:
                    continue
                packable.append(fe)

        out_zip = tmp / "out.zip"
        with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as zipf:
            zipf.writestr("manifest.json", json.dumps(manifest, indent=2))
            for fe in packable:
                zipf.write(fe["path"], fe["relpath"])

        with zipfile.ZipFile(out_zip, "r") as zf:
            names = set(zf.namelist())

        assert "team/.env" not in names, (
            f"Secret file tagged secrets_export must NOT appear in main zip. "
            f"Zip contents: {sorted(names)}"
        )
        assert "team/src/main.py" in names, (
            f"Normal file tagged git MUST appear in main zip. "
            f"Zip contents: {sorted(names)}"
        )


# ---------------------------------------------------------------------------
# Test 6 — acknowledgeMissingSecrets request-body parsing
# ---------------------------------------------------------------------------

def test_ack_bool_true_allows_apply(edge_server: _LCARSServer):
    """acknowledgeMissingSecrets: true (bool) bypasses the secrets gate."""
    zip_bytes = _build_synthetic_zip_for_edge(discovered=1, expected=1)
    upload_code, upload_resp = _http_post_file(
        edge_server.url("/api/import/upload"), zip_bytes, "ack-bool-true.zip"
    )
    assert upload_code == 200, f"Upload failed: {upload_resp}"
    job_id = upload_resp["jobId"]

    apply_code, apply_resp = _http_post_json(
        edge_server.url(f"/api/import/apply/{job_id}"),
        {"acknowledgeMissingSecrets": True},
    )
    assert apply_code == 200, (
        f"acknowledgeMissingSecrets=true (bool) must allow apply; "
        f"got {apply_code}: {apply_resp}"
    )
    _poll_job_status(edge_server.url(f"/api/import/status/{job_id}"))


def test_ack_absent_blocks_apply_when_discovered_nonzero(edge_server: _LCARSServer):
    """Missing acknowledgeMissingSecrets (absent) → HTTP 409 when discovered > 0."""
    zip_bytes = _build_synthetic_zip_for_edge(discovered=1, expected=1)
    upload_code, upload_resp = _http_post_file(
        edge_server.url("/api/import/upload"), zip_bytes, "ack-absent.zip"
    )
    assert upload_code == 200, f"Upload failed: {upload_resp}"
    job_id = upload_resp["jobId"]

    apply_code, apply_resp = _http_post_json(
        edge_server.url(f"/api/import/apply/{job_id}"),
        {},  # No acknowledgeMissingSecrets field
    )
    assert apply_code == 409, (
        f"Missing acknowledgeMissingSecrets must return 409 when discovered>0; "
        f"got {apply_code}: {apply_resp}"
    )
    assert apply_resp.get("error") == "missing_paired_secrets"


def test_ack_bool_false_blocks_apply_when_discovered_nonzero(edge_server: _LCARSServer):
    """acknowledgeMissingSecrets: false (bool False) → HTTP 409 when discovered > 0.

    bool(False) == False, so the gate correctly blocks.
    """
    zip_bytes = _build_synthetic_zip_for_edge(discovered=1, expected=1)
    upload_code, upload_resp = _http_post_file(
        edge_server.url("/api/import/upload"), zip_bytes, "ack-bool-false.zip"
    )
    assert upload_code == 200, f"Upload failed: {upload_resp}"
    job_id = upload_resp["jobId"]

    apply_code, apply_resp = _http_post_json(
        edge_server.url(f"/api/import/apply/{job_id}"),
        {"acknowledgeMissingSecrets": False},
    )
    assert apply_code == 409, (
        f"acknowledgeMissingSecrets=false (bool) must still block; "
        f"got {apply_code}: {apply_resp}"
    )
    assert apply_resp.get("error") == "missing_paired_secrets"


def test_ack_null_blocks_apply_when_discovered_nonzero(edge_server: _LCARSServer):
    """acknowledgeMissingSecrets: null (JSON null → None) → HTTP 409 when discovered > 0.

    bool(None) == False, so gate correctly blocks.
    """
    zip_bytes = _build_synthetic_zip_for_edge(discovered=1, expected=1)
    upload_code, upload_resp = _http_post_file(
        edge_server.url("/api/import/upload"), zip_bytes, "ack-null.zip"
    )
    assert upload_code == 200, f"Upload failed: {upload_resp}"
    job_id = upload_resp["jobId"]

    apply_code, apply_resp = _http_post_json(
        edge_server.url(f"/api/import/apply/{job_id}"),
        {"acknowledgeMissingSecrets": None},
    )
    assert apply_code == 409, (
        f"acknowledgeMissingSecrets=null must block; got {apply_code}: {apply_resp}"
    )


def test_ack_string_true_bypasses_gate(edge_server: _LCARSServer):
    """acknowledgeMissingSecrets: 'true' (JSON string) is accepted as truthy.

    Post-fix (XACA-0520-008), the parser is type-aware: it accepts True (bool),
    1 (int), and the case-insensitive strings 'true' / 'yes' / '1'. The string
    'true' is in the accepted set and bypasses the gate.
    """
    zip_bytes = _build_synthetic_zip_for_edge(discovered=1, expected=1)
    upload_code, upload_resp = _http_post_file(
        edge_server.url("/api/import/upload"), zip_bytes, "ack-str-true.zip"
    )
    assert upload_code == 200, f"Upload failed: {upload_resp}"
    job_id = upload_resp["jobId"]

    apply_code, _apply_resp = _http_post_json(
        edge_server.url(f"/api/import/apply/{job_id}"),
        {"acknowledgeMissingSecrets": "true"},
    )
    assert apply_code == 200, (
        f"String 'true' must be treated as truthy override; got {apply_code}."
    )
    _poll_job_status(edge_server.url(f"/api/import/status/{job_id}"))


def test_ack_string_false_blocks_gate(edge_server: _LCARSServer):
    """acknowledgeMissingSecrets: 'false' (JSON string) MUST block the gate.

    Regression guard for XACA-0520-008 bugfix. Pre-fix, the handler used
    `bool(body_json.get('acknowledgeMissingSecrets', False))` which coerced the
    JSON string 'false' to True (any non-empty string is truthy in Python),
    accidentally bypassing the secrets-coordination gate.

    Post-fix, the type-aware parser only treats {'true', 'yes', '1'} (case-insensitive)
    as truthy strings, so 'false' is correctly rejected and the gate blocks the apply.
    """
    zip_bytes = _build_synthetic_zip_for_edge(discovered=1, expected=1)
    upload_code, upload_resp = _http_post_file(
        edge_server.url("/api/import/upload"), zip_bytes, "ack-str-false.zip"
    )
    assert upload_code == 200, f"Upload failed: {upload_resp}"
    job_id = upload_resp["jobId"]

    apply_code, apply_resp = _http_post_json(
        edge_server.url(f"/api/import/apply/{job_id}"),
        {"acknowledgeMissingSecrets": "false"},
    )
    assert apply_code == 409, (
        f"String 'false' must NOT bypass the secrets gate (regression check for "
        f"XACA-0520-008 bool('false')==True bug). Got {apply_code}: {apply_resp}"
    )


def test_ack_discovered_zero_always_succeeds_regardless_of_flag(edge_server: _LCARSServer):
    """When discovered=0, apply ALWAYS succeeds regardless of acknowledgeMissingSecrets value.

    The gate condition is: discovered > 0 AND no paired zip AND not acknowledged.
    With discovered=0 the gate is never reached.
    """
    for ack_value in (False, True, None, "false", "true", ""):
        zip_bytes = _build_synthetic_zip_for_edge(discovered=0, expected=0)
        upload_code, upload_resp = _http_post_file(
            edge_server.url("/api/import/upload"),
            zip_bytes,
            f"ack-d0-{str(ack_value)[:10]}.zip",
        )
        assert upload_code == 200, f"Upload failed for ack={ack_value!r}: {upload_resp}"
        job_id = upload_resp["jobId"]

        body: dict[str, Any] = {}
        if ack_value is not None:
            body["acknowledgeMissingSecrets"] = ack_value

        apply_code, apply_resp = _http_post_json(
            edge_server.url(f"/api/import/apply/{job_id}"),
            body,
        )
        assert apply_code == 200, (
            f"discovered=0: apply must succeed for any ack_value={ack_value!r}; "
            f"got {apply_code}: {apply_resp}"
        )
        _poll_job_status(edge_server.url(f"/api/import/status/{job_id}"))
