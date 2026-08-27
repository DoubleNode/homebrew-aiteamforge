#!/usr/bin/env python3

#
#  test_xaca0161_cockpit_pwa.py
#  DoubleNode Dev-Team Infrastructure (AITeamForge)
#
#  Copyright (c) 2026 - 2025 DoubleNode.com. All rights reserved.
#

"""XACA-0161-005 — regression tests for the cockpit PWA shell.

WHAT THESE TESTS ARE FOR, AND WHAT THEY DELIBERATELY ARE NOT.

The service worker's real behaviour was demonstrated in a browser during
development: a throwaway TLS server, Chromium under Playwright, the server
killed mid-session to produce a genuine "no route to the fleet", and
assertions read off live Cache Storage. That is the right way to prove a
worker works and the wrong thing to put in this suite -- it needs a browser
download, a certificate, and ~90 seconds.

So these tests guard the parts that a future edit can silently break WITHOUT
a browser, and they are chosen for exactly one property: each one fails if a
reasonable-looking change quietly re-opens the risk the subitem exists to
close.

THE RISK, RESTATED. Apple bug FB21416603 (open): iPadOS 26 tears down a
WebSocket to a local-network host about a second after handshake,
specifically in `display: standalone` PWA mode -- the mode this manifest
turns on. The 2026-08-26 device spike measured 90s+ survival over `wss://`,
so TLS is the mitigation. A service worker that cached the cockpit shell
would let a stale shell keep opening sockets long after anyone remembered
why the scheme mattered, which is why "the allow-list contains no HTML and
no JS" is asserted here as a hard invariant rather than left to review.
"""

from __future__ import annotations

import json
import re
import struct
import zlib
from pathlib import Path

import pytest

UI_DIR = Path(__file__).resolve().parents[1]
COCKPIT = UI_DIR / "cockpit"
MANIFEST = COCKPIT / "manifest.webmanifest"
SW = COCKPIT / "sw.js"
OFFLINE = COCKPIT / "offline.html"
PWA_JS = COCKPIT / "pwa.js"


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def png_size(path: Path) -> tuple[int, int]:
    """Read a PNG's real pixel dimensions from its IHDR.

    Deliberately not Pillow: this must run in CI with no image library, and
    the point of the check is that the file is a REAL PNG of the declared
    size rather than a placeholder or a copy of the wrong icon. Also
    validates the IHDR CRC, so a truncated or corrupt file fails here
    instead of on someone's home screen.
    """
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path.name} is not a PNG"
    length = struct.unpack(">I", data[8:12])[0]
    assert data[12:16] == b"IHDR", f"{path.name} has no IHDR chunk"
    chunk = data[12:16 + length]
    stored_crc = struct.unpack(">I", data[16 + length:20 + length])[0]
    assert zlib.crc32(chunk) & 0xFFFFFFFF == stored_crc, f"{path.name} IHDR CRC bad"
    width, height = struct.unpack(">II", data[16:24])
    return width, height


def sw_precache_urls() -> list[str]:
    """Extract the service worker's PRECACHE allow-list.

    Parsed out of the source rather than imported, because the file is
    JavaScript. The regex is anchored on the const declaration so a renamed
    or restructured list fails loudly here instead of silently returning an
    empty list and making every assertion below vacuous.
    """
    src = SW.read_text(encoding="utf-8")
    m = re.search(r"const PRECACHE = \[(.*?)\]\.map\(", src, re.S)
    assert m, "PRECACHE array not found in sw.js -- these tests would be vacuous"
    body = m.group(1)
    urls = re.findall(r"'([^']+)'", body)
    assert urls, "PRECACHE parsed as empty -- these tests would be vacuous"
    return urls


def precache_to_path(url: str) -> Path:
    """Map a PRECACHE entry to the file it resolves to on disk."""
    if url.startswith("./"):
        return COCKPIT / url[2:]
    if url.startswith("/"):
        return UI_DIR / url.lstrip("/")
    raise AssertionError(f"unexpected PRECACHE form: {url}")


# --------------------------------------------------------------------------
# manifest
# --------------------------------------------------------------------------

def test_manifest_is_valid_json_with_standalone_display():
    m = json.loads(MANIFEST.read_text(encoding="utf-8"))
    assert m["display"] == "standalone"
    assert m["scope"] == "/cockpit/"
    assert m["start_url"] == "./"
    assert m["theme_color"] == "#000000"
    assert m["background_color"] == "#000000"
    assert m["id"] == "/cockpit/"


def test_manifest_icons_all_exist_and_match_their_declared_sizes():
    """A manifest that declares an icon it does not have is worse than one
    that declares fewer icons: the install silently falls back and nobody
    finds out until the home screen shows a generic glyph."""
    m = json.loads(MANIFEST.read_text(encoding="utf-8"))
    assert m["icons"], "manifest declares no icons"
    for icon in m["icons"]:
        path = precache_to_path(icon["src"])
        assert path.is_file(), f"missing icon: {icon['src']}"
        declared = icon["sizes"]
        w, h = png_size(path)
        assert f"{w}x{h}" == declared, (
            f"{icon['src']} declares {declared} but is actually {w}x{h}")


def test_manifest_declares_a_maskable_icon():
    m = json.loads(MANIFEST.read_text(encoding="utf-8"))
    assert any(i.get("purpose") == "maskable" for i in m["icons"])


# --------------------------------------------------------------------------
# icons iOS actually asks for
# --------------------------------------------------------------------------

@pytest.mark.parametrize("size", [120, 152, 167, 180])
def test_apple_touch_icon_exists_at_each_size_ios_requests(size):
    path = COCKPIT / "icons" / f"apple-touch-icon-{size}x{size}.png"
    assert path.is_file(), f"missing apple-touch-icon at {size}x{size}"
    assert png_size(path) == (size, size)


@pytest.mark.parametrize("name,size", [
    # The four bare paths iOS probed during the 2026-08-26 device spike, seen
    # in ttyd's own request log when the iPad was told to "Add to Home
    # Screen" (evaluation doc section 7.1). iOS falls back to these when a
    # page declares no apple-touch-icon links, so they are covered for every
    # LCARS page, not just the cockpit.
    ("apple-touch-icon.png", 180),
    ("apple-touch-icon-precomposed.png", 180),
    ("apple-touch-icon-167x167.png", 167),
    ("apple-touch-icon-167x167-precomposed.png", 167),
])
def test_root_apple_touch_icon_fallbacks_the_device_probed(name, size):
    path = UI_DIR / name
    assert path.is_file(), f"missing root fallback probed by the device: /{name}"
    assert png_size(path) == (size, size)


def test_offline_page_declares_every_apple_touch_icon_it_ships():
    html = OFFLINE.read_text(encoding="utf-8")
    for size in (120, 152, 167, 180):
        assert f'sizes="{size}x{size}"' in html, f"offline.html omits {size}x{size}"


# --------------------------------------------------------------------------
# the service worker's structural guarantees
# --------------------------------------------------------------------------

def test_every_precached_asset_actually_exists():
    """`install` fails hard on a missing asset, so a typo here does not
    degrade the offline shell -- it removes it entirely, silently, on every
    device that has not already cached it."""
    for url in sw_precache_urls():
        path = precache_to_path(url)
        assert path.is_file(), f"PRECACHE references a missing file: {url}"


def test_precache_contains_no_html_shell_and_no_script():
    """THE load-bearing invariant of this subitem.

    A cached cockpit shell is code, and code served from cache outlives the
    reasoning that made its connection scheme safe. The offline page is the
    single permitted HTML entry precisely because it ships no script and
    cannot open a connection of any kind.
    """
    urls = sw_precache_urls()
    html = [u for u in urls if u.endswith(".html")]
    assert html == ["./offline.html"], (
        f"only offline.html may be precached; found {html}")
    scripts = [u for u in urls if u.endswith(".js")]
    assert not scripts, f"no script may EVER be precached; found {scripts}"


def test_precache_never_reaches_the_terminal_or_api_routes():
    for url in sw_precache_urls():
        assert not url.startswith("/terminal/"), url
        assert not url.startswith("/api/"), url


def test_service_worker_refuses_to_install_outside_tls():
    """Guards the FB21416603 mitigation. If this constant stops gating
    install, a worker can take hold on an http origin and start serving a
    shell to a page whose sockets iPadOS will kill."""
    src = SW.read_text(encoding="utf-8")
    assert "const SECURE = self.location.protocol === 'https:';" in src
    assert "if (!SECURE)" in src, "SECURE is computed but never enforced"
    assert src.count("if (!SECURE)") >= 3, (
        "SECURE must gate install, activate and fetch")
    assert "unregister()" in src, "a non-TLS worker must remove itself"


def test_pwa_js_does_not_register_over_plain_http():
    src = PWA_JS.read_text(encoding="utf-8")
    assert "var SECURE = window.location.protocol === 'https:';" in src
    assert "getRegistrations()" in src, (
        "pwa.js must tear down a worker left behind on a non-TLS origin")
    # The registration call must be unreachable when SECURE is false: the
    # early `return` in the !SECURE branch has to come first in the file.
    insecure_at = src.index("if (!SECURE) {")
    register_at = src.index(".register(")
    assert insecure_at < register_at, (
        "the non-TLS guard must precede registration, not follow it")


# --------------------------------------------------------------------------
# the offline page
# --------------------------------------------------------------------------

def test_offline_page_ships_no_javascript():
    """The offline shell must be a sign, not an application. No script tag
    means no code path exists that could open a socket from cache."""
    html = OFFLINE.read_text(encoding="utf-8")
    assert "<script" not in html.lower()
    assert not re.search(r"\son\w+\s*=\s*[\"']", html), "inline event handler found"


def test_offline_page_csp_forbids_script_and_connect():
    html = OFFLINE.read_text(encoding="utf-8")
    m = re.search(r'http-equiv="Content-Security-Policy" content="([^"]+)"', html)
    assert m, "offline.html has no meta CSP"
    csp = m.group(1)
    for directive in ("default-src 'none'", "script-src 'none'",
                      "connect-src 'none'", "frame-ancestors 'none'",
                      "base-uri 'none'", "form-action 'none'"):
        assert directive in csp, f"CSP missing: {directive}"


def test_offline_page_retry_is_a_plain_navigation():
    """Retry has to be a real navigation so the worker re-runs its
    network-first path. A JS reload would be script, which the CSP forbids
    and which would put connection logic back into the offline state."""
    html = OFFLINE.read_text(encoding="utf-8")
    assert 'class="retry" href="./"' in html


def test_offline_page_states_the_https_requirement():
    """Whoever reads this page is debugging a dead pane. The one fact that
    resolves the most likely cause -- and the bug number backing it -- has to
    be on the page, not only in the commit history."""
    html = OFFLINE.read_text(encoding="utf-8")
    assert "FB21416603" in html
    assert "https" in html


# --------------------------------------------------------------------------
# self-containment (merged threat model, section 7)
# --------------------------------------------------------------------------

@pytest.mark.parametrize("path", [
    "manifest.webmanifest", "sw.js", "pwa.js", "offline.html",
])
def test_no_external_host_is_referenced(path):
    """The cockpit route must be self-contained: no CDN, no font host, no
    remote anything. XACA-0572 already removed the Google Fonts dependency
    from LCARS; nothing this subitem adds may put one back."""
    text = (COCKPIT / path).read_text(encoding="utf-8")
    # Strip comments before scanning: the source deliberately cites
    # `wss://` and `http://` when explaining the FB21416603 mitigation, and
    # a naive scan would trip on the explanation rather than on real code.
    stripped = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    stripped = re.sub(r"^\s*//.*$", "", stripped, flags=re.M)
    stripped = re.sub(r"<!--.*?-->", "", stripped, flags=re.S)
    for pattern in (r"https?://(?!127\.0\.0\.1|localhost)[a-zA-Z0-9.-]+",
                    r"//fonts\.googleapis\.com", r"//cdn\."):
        hits = [h for h in re.findall(pattern, stripped)
                if "example.invalid" not in h]
        assert not hits, f"{path} references an external host: {hits}"
