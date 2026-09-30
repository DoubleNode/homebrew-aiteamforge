"""Microsoft Teams provider for release_notify (XACA-1345-003). stdlib only.

Two payload shapes, chosen per alias by notify.json `shape` (default "flow"):

  flow     Power Automate "When an HTTP request is received" flow: a `message`
           envelope carrying one Adaptive Card. This is what current Teams
           workflows accept.
  webhook  Plain Teams incoming webhook: {"text": ...}.

The webhook URL IS the secret. It is only ever held in a Target and passed to the
transport; every error string here is a static class name / HTTP status.
The transport is injected so tests never touch the network. One POST, a timeout,
no retries, no redirects.
"""
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Dict, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
from release_notify import (  # noqa: E402
    NoticeMessage, NotifyConfigError, NotifyProvider, NotifySendError, SendResult, SessionContext,
    Target,
)

SHAPES = ("flow", "webhook")
DEFAULT_SHAPE = "flow"
TIMEOUT_SECONDS = 10.0
ID_HEADERS = ("x-ms-workflow-run-id", "x-ms-request-id")  # not secrets; useful in a receipt

# transport(url, body, headers, timeout) -> (status, response_headers_lowercased)
Transport = Callable[[str, bytes, Dict[str, str], float], Tuple[int, Dict[str, str]]]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirected POST would be replayed as a GET to a URL we never vetted."""

    def redirect_request(self, *args, **kwargs):
        return None


def _urllib_transport(url: str, body: bytes, headers: Dict[str, str], timeout: float):
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.status, {k.lower(): v for k, v in resp.headers.items()}
    except urllib.error.HTTPError as exc:  # a status, not a transport failure
        return exc.code, {k.lower(): v for k, v in exc.headers.items()}


def build_payload(shape: str, text: str) -> dict:
    if shape == "webhook":
        return {"text": text}
    return {
        "type": "message",
        "attachments": [{
            "contentType": "application/vnd.microsoft.card.adaptive",
            "contentUrl": None,
            "content": {
                "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                "type": "AdaptiveCard",
                "version": "1.4",
                "body": [{"type": "TextBlock", "text": text, "wrap": True}],
            },
        }],
    }


class TeamsProvider(NotifyProvider):
    name = "teams"

    def __init__(self, transport: Optional[Transport] = None, timeout: float = TIMEOUT_SECONDS) -> None:
        self._transport = transport or _urllib_transport
        self._timeout = timeout

    def resolve_target(self, alias: str, session_ctx: SessionContext) -> Target:
        entry = self.alias_entry(alias, session_ctx)
        secret = self.resolve_alias_secret(alias, entry, session_ctx)
        return Target(provider=self.name, alias=alias, secret=secret,
                      options={"shape": entry.get("shape", DEFAULT_SHAPE)})

    def validate_target(self, target: Target) -> None:
        if target.options.get("shape") not in SHAPES:
            raise NotifyConfigError("alias '%s' has an unknown teams shape" % target.alias)
        try:
            parts = urllib.parse.urlsplit(target.secret)
        except ValueError:
            parts = None
        if parts is None or parts.scheme != "https" or not parts.hostname:
            raise NotifyConfigError("alias '%s' target is not an https URL" % target.alias)

    def send(self, target: Target, message: NoticeMessage) -> SendResult:
        self.validate_target(target)
        body = json.dumps(build_payload(target.options["shape"], message.text)).encode("utf-8")
        try:
            status, headers = self._transport(
                target.secret, body, {"Content-Type": "application/json"}, self._timeout)
        except Exception as exc:  # noqa: BLE001 - URLError/timeout text can embed the URL
            raise NotifySendError("teams transport error (%s)" % type(exc).__name__) from None
        if not 200 <= status < 300:
            raise NotifySendError("teams returned HTTP %d" % status)
        mid = next((headers[h] for h in ID_HEADERS if headers.get(h)), None)
        return SendResult(provider_message_id=mid)
