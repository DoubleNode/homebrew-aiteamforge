"""Provider-agnostic notify library for the release workflow (XACA-1345).

Spec section 10.1. Three layers:

  * the NotifyProvider interface + ProviderRegistry (-001). slack/sms/email are
    registered but UnimplementedProvider: the seam exists, nothing behind it.
  * NotifyEngine (-002/-004/-005): alias lookup in the CALLING team's
    notify.json, template render (XACA-1343 layering + shared renderer),
    delivery through a provider, receipts.
  * concrete providers live in their own module (release_notify_teams.py).

SECRET HANDLING. A notify.json alias carries only a secretRef, never a
destination. The provider resolves it just-in-time inside `resolve_target` and
keeps the value in an opaque `Target` (repr=False). The engine passes the Target
through and never reads, logs, prints, receipts or puts it in an exception. All
error text in this module is static or names only aliases/providers/types.

`resolve_target(alias, session_ctx)` takes a SessionContext (not just a config
dict) so a future session-addressed provider, e.g. XACA-0757's phone push relay,
can route on the calling session instead of a notify.json alias.
"""
from __future__ import annotations

import abc
import fcntl
import importlib.util
import json
import os
import re
import sys
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

KANBAN_DIR_VAR = "KB_NOTIFY_KANBAN_DIR"  # test hook: sandbox the team kanban dir
NOTIFY_LOG_NAME = "notify-log.jsonl"
REF_RE = re.compile(r"^(REL|CR)-[A-Za-z0-9][A-Za-z0-9._-]*(?![\s\S])")  # not $: it matches before a final \n
REF_COLLECTIONS = {"REL": "releases", "CR": "crs"}  # board.json arrays holding the records
TEAM_RE = re.compile(r"^[a-z0-9][a-z0-9-]*(?![\s\S])")  # registry ids; a team id becomes a path segment

# ---------------------------------------------------------------- errors


class NotifyError(Exception):
    """Base for every notify failure. Messages never carry secrets."""


class NotifyConfigError(NotifyError):
    """Nothing was routed: bad/missing notify.json, unknown alias, unimplemented
    provider, missing template, unknown --ref. No receipt is written."""


class NotifySecretError(NotifyError):
    """The alias's secretRef could not be resolved to a non-empty value."""


class NotifySendError(NotifyError):
    """The provider attempted delivery and it failed (transport / HTTP status)."""


class NotifyReceiptError(NotifyError):
    """The notice may have been sent but its receipt could not be persisted."""


# ---------------------------------------------------------------- data


@dataclass(frozen=True)
class SessionContext:
    """What a provider may route on. `aliases` is the calling team's validated
    notify.json `aliases` map; `resolve_secret` is the team-bound JIT resolver."""

    team: str
    terminal: str = ""
    aliases: Mapping[str, Any] = field(default_factory=dict, repr=False)
    resolve_secret: Optional[Callable[[str], str]] = field(default=None, repr=False)


@dataclass(frozen=True)
class Target:
    """Opaque resolved route. `secret` is the destination; it never appears in
    repr/str, so an accidental format() or traceback cannot leak it."""

    provider: str
    alias: str
    secret: str = field(repr=False)
    options: Mapping[str, str] = field(default_factory=dict)

    def __str__(self) -> str:
        return "<Target %s/%s>" % (self.provider, self.alias)


@dataclass(frozen=True)
class NoticeMessage:
    text: str
    template: str = ""  # "" for --text sends (fact dictionary renders notices[].template)


@dataclass(frozen=True)
class SendResult:
    provider_message_id: Optional[str] = None


# ---------------------------------------------------------------- interface


class NotifyProvider(abc.ABC):
    """Every provider implements resolve_target + send; validate_target is an
    optional hook for `kb-notify test` (route sanity that sends nothing)."""

    name = ""

    @abc.abstractmethod
    def resolve_target(self, alias: str, session_ctx: SessionContext) -> Target:
        """Turn an alias (or, for session-addressed providers, the session) into a
        Target, resolving secrets just-in-time. NotifyConfigError for an unknown
        alias, NotifySecretError if the secret does not resolve non-empty."""

    @abc.abstractmethod
    def send(self, target: Target, message: NoticeMessage) -> SendResult:
        """Deliver once. No retries. NotifySendError on failure."""

    def validate_target(self, target: Target) -> None:
        """Raise NotifyConfigError if the resolved target is unusable. Must not
        touch the network."""

    # helpers shared by alias-based providers ------------------------------
    def alias_entry(self, alias: str, ctx: SessionContext) -> Mapping[str, Any]:
        entry = ctx.aliases.get(alias)
        if not isinstance(entry, dict):
            raise NotifyConfigError("unknown alias '%s'" % alias)
        if entry.get("provider") != self.name:
            raise NotifyConfigError("alias '%s' is not a %s alias" % (alias, self.name))
        return entry

    def resolve_alias_secret(self, alias: str, entry: Mapping[str, Any], ctx: SessionContext) -> str:
        ref = (entry.get("target") or {}).get("secretRef")
        if not isinstance(ref, str) or ctx.resolve_secret is None:
            raise NotifySecretError("alias '%s' has no resolvable secretRef" % alias)
        try:
            value = ctx.resolve_secret(ref)
        except NotifyError:
            raise
        except Exception as exc:  # noqa: BLE001 - never forward the resolver's text
            raise NotifySecretError(
                "secretRef for alias '%s' did not resolve (%s)" % (alias, type(exc).__name__)) from None
        if not isinstance(value, str) or not value.strip():
            raise NotifySecretError("secretRef for alias '%s' resolved empty" % alias)
        return value.strip()


class UnimplementedProvider(NotifyProvider):
    """slack/sms/email: registered so config validates and the error is precise."""

    def __init__(self, name: str) -> None:
        self.name = name

    def _refuse(self):
        raise NotifyConfigError("provider '%s' is not implemented yet (seam only)" % self.name)

    def resolve_target(self, alias, session_ctx):
        self._refuse()

    def send(self, target, message):
        self._refuse()


class ProviderRegistry:
    def __init__(self) -> None:
        self._factories: Dict[str, Callable[[], NotifyProvider]] = {}

    def register(self, name: str, factory: Callable[[], NotifyProvider]) -> None:
        self._factories[name] = factory

    def names(self) -> List[str]:
        return sorted(self._factories)

    def get(self, name: str) -> NotifyProvider:
        factory = self._factories.get(name)
        if factory is None:
            raise NotifyConfigError("unknown provider '%s'" % name)
        return factory()


def default_registry() -> ProviderRegistry:
    from release_notify_teams import TeamsProvider  # lazy: it imports this module

    reg = ProviderRegistry()
    from release_notify_hub import HubProvider  # lazy: it imports this module (XACA-1403)

    reg.register("teams", TeamsProvider)
    reg.register("hub", HubProvider)
    for name in ("slack", "sms", "email"):
        reg.register(name, lambda n=name: UnimplementedProvider(n))
    return reg


# ---------------------------------------------------------------- sibling modules


def _load_script_module(name: str):
    """Load scripts/<name>.py: scripts/ sits next to kanban-hooks/ in the dev tree
    and in the tap share/ layout; a flattened install puts it beside this file."""
    mod = sys.modules.get(name)
    if mod is not None:
        return mod
    here = Path(__file__).resolve().parent
    for cand in (here.parent / "scripts" / (name + ".py"), here / (name + ".py")):
        if cand.is_file():
            spec = importlib.util.spec_from_file_location(name, cand)
            mod = importlib.util.module_from_spec(spec)
            sys.modules[name] = mod  # the profile resolver looks the validator up here
            try:
                spec.loader.exec_module(mod)
            except BaseException as exc:
                # XACA-1463: any failure (not just ImportError) leaves a half-built
                # module registered, and the early sys.modules.get() above would hand
                # it to the next caller -> AttributeError. Identity check so we never
                # evict a foreign entry that exec_module itself put there.
                if sys.modules.get(name) is mod:
                    del sys.modules[name]
                if isinstance(exc, ImportError):  # e.g. jsonschema missing on system python
                    raise NotifyConfigError(
                        "cannot load %s (%s); install jsonschema or use a python that has it"
                        % (name, type(exc).__name__)) from None
                raise
            return mod
    raise NotifyConfigError("%s.py not found next to this module" % name)


_DEGRADED_NOTICE_PRINTED = False


def _note_degraded_validation() -> None:
    """One stderr notice per process when schema validation degrades (XACA-1504)."""
    global _DEGRADED_NOTICE_PRINTED
    if not _DEGRADED_NOTICE_PRINTED:
        _DEGRADED_NOTICE_PRINTED = True
        print("kb-notify: jsonschema unavailable; full schema validation skipped "
              "(structural + routing checks only; the hub re-validates)", file=sys.stderr)


# ---------------------------------------------------------------- engine


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class NotifyEngine:
    """Every dependency is injectable so tests never touch the network, the
    registry, the vault or a live board."""

    def __init__(self, team: str, *, kanban_dir=None, registry: Optional[ProviderRegistry] = None,
                 secret_resolver=None, validate_config=None, render_template=None,
                 board_read=None, board_update=None, clock=None, terminal: str = "",
                 macos_notifier=None) -> None:
        if not isinstance(team, str) or not TEAM_RE.match(team):
            raise NotifyConfigError("invalid team id %r" % (team,))  # e.g. '../x' must never reach a path
        self.team = team
        self._kanban_dir = Path(kanban_dir) if kanban_dir else None
        self._registry = registry
        self._secret_resolver = secret_resolver
        self._validate_config = validate_config
        self._render_template = render_template
        self._board_read = board_read
        self._board_update = board_update
        self._clock = clock or _utc_now
        self.terminal = terminal
        self._macos_notifier = macos_notifier  # (title, body) -> '' | reason code; test seam (XACA-1403)

    # -- paths / config ----------------------------------------------------
    def kanban_dir(self) -> Path:
        if self._kanban_dir is None:
            override = os.environ.get(KANBAN_DIR_VAR, "").strip()
            if override:
                self._kanban_dir = Path(override).expanduser()
            else:
                try:
                    import aiteamforge_paths  # noqa: PLC0415 - sibling in kanban-hooks/
                    self._kanban_dir = Path(aiteamforge_paths.get_team_kanban_dir(self.team))
                except KeyError as exc:
                    raise NotifyConfigError(str(exc)) from None
                except Exception as exc:  # noqa: BLE001 - registry failure: fail closed
                    raise NotifyConfigError(
                        "cannot resolve kanban dir for team '%s' (%s)" % (self.team, type(exc).__name__)) from None
        return self._kanban_dir

    def board_file(self) -> Path:
        return self.kanban_dir() / ("%s-board.json" % self.team)

    def load_config(self) -> Mapping[str, Any]:
        """Read + schema-validate the team's notify.json (v1 or v2)."""
        path = self.kanban_dir() / "config" / "notify.json"
        try:
            config = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            raise NotifyConfigError("team '%s' has no notify.json" % self.team) from None
        except (OSError, ValueError) as exc:
            raise NotifyConfigError("notify.json unreadable (%s)" % type(exc).__name__) from None
        validate = self._validate_config
        if validate is None:
            rcv = _load_script_module("release_config_validate")
            try:
                errors = rcv.validate_notify_config(config)
            except getattr(rcv, "SchemaValidatorUnavailable", ()):
                # XACA-1504: stock python (no jsonschema). Fail-CLOSED stdlib path;
                # see release_config_validate.validate_notify_config_degraded().
                _note_degraded_validation()
                try:
                    errors = rcv.validate_notify_config_degraded(config, self.kanban_dir())
                except NotifyConfigError:
                    raise
                except Exception as dexc:  # noqa: BLE001 - never fail open
                    raise NotifyConfigError(
                        "notify.json could not be validated (%s)" % type(dexc).__name__) from None
        else:
            errors = validate(config)
        if errors:  # the validator's messages are redaction-safe by contract
            raise NotifyConfigError("notify.json invalid: " + "; ".join(errors))
        return config

    def load_aliases(self) -> Mapping[str, Any]:
        # v1 always has aliases; in v2 they are optional (XACA-1399)
        return self.load_config().get("aliases") or {}

    # -- notice-type resolution (XACA-1399) --------------------------------
    def resolve_type(self, notice_type: str, *, ref: Optional[str] = None, now=None) -> Dict[str, Any]:
        """Resolve `--type`: effective severity (override > catalog default),
        hub connection ids from the v2 routes, the quiet-hours decision and the
        dedupe key/window. Delivers NOTHING (hub delivery is XACA-1400/1403).
        NotifyConfigError for an unknown type / v1 config / bad catalog."""
        import release_notify_routing as rr  # noqa: PLC0415 - sibling module
        config = self.load_config()
        if not rr.is_v2(config):
            raise NotifyConfigError("notify.json is release-notify/v1; --type needs a v2 config with routes")
        try:
            catalog = rr.load_catalog(self.kanban_dir())
            if notice_type not in catalog:
                raise NotifyConfigError("unknown notice type '%s'" % rr._safe_id(notice_type))
            errs = rr.validate_v2_semantics(config, catalog)
            if errs:
                raise NotifyConfigError("notify.json invalid: " + "; ".join(errs))
            return rr.resolve_notice(config, catalog, self.team, notice_type, ref=ref,
                                     now=now or datetime.now(timezone.utc))
        except rr.NoticeRoutingError as exc:
            raise NotifyConfigError(str(exc)) from None

    def _context(self, aliases: Mapping[str, Any]) -> SessionContext:
        resolver = self._secret_resolver
        if resolver is None:
            resolver = _load_script_module("release_config_validate").resolve_secret_ref
        team = self.team
        return SessionContext(team=team, terminal=self.terminal, aliases=aliases,
                              resolve_secret=lambda ref: resolver(ref, team))

    def _route(self, alias: str, aliases: Mapping[str, Any]):
        entry = aliases.get(alias)
        if not isinstance(entry, dict):
            raise NotifyConfigError("unknown alias '%s'" % alias)
        registry = self._registry or default_registry()
        provider = registry.get(entry["provider"])
        if isinstance(provider, UnimplementedProvider):
            provider._refuse()  # a seam is unroutable: config error, no receipt
        return provider, self._context(aliases)

    # -- typed send: hub first, local fallback chain (XACA-1403) -----------
    def send_type(self, notice_type: str, *, text: Optional[str] = None, title: Optional[str] = None,
                  ref: Optional[str] = None) -> Dict[str, Any]:
        """Deliver one `--type` notice and persist its receipt (EPIC-0068 D1).

        Order: (1) Fleet Monitor hub when an FM URL and the team's notify key
        resolve; (2) ONLY if the hub was skipped, unreachable or answered 5xx:
        the direct aliases whose name equals a connection id in
        routes[notice_type], then a macOS notification; (3) otherwise ok:false.
        A 4xx from the hub is a rejection and is NOT a fallback trigger. One hub
        attempt, no retries. Raises NotifyConfigError (no receipt) when nothing
        was routable: unknown type, v1 config, no route for the type."""
        if ref is not None:
            self._check_ref(ref)
        resolved = self.resolve_type(notice_type, ref=ref)  # NotifyConfigError for unknown type / v1
        connections = list(resolved["connections"])
        if not connections:
            raise NotifyConfigError("no route for notice type '%s' in notify.json" % notice_type)
        body = (text or "").strip()
        head = (title or "").strip() or "%s: %s" % (self.team, notice_type)
        attempts: List[Dict[str, Any]] = []
        hub_info: Dict[str, Any] = {}
        delivered_via, provider_name, ok, error = "none", "none", False, ""

        # 1. hub
        hub_outcome = self._try_hub(notice_type, head, body, resolved["severity"], ref, attempts, hub_info)
        if hub_outcome is not None and hub_info["status"] == "delivered":
            delivered_via, provider_name, ok = "hub", "hub", True
        elif hub_outcome is not None and not hub_info.get("fallback"):
            error = hub_info["error"]  # rejected / bad-response / delivered nothing: no fallback
        elif resolved["suppressed"]:
            # fallbacks honor quiet hours too; the hub applies its own rules server-side
            delivered_via, provider_name, ok = "none", "none", True
            hub_info["localSuppressed"] = "quiet-hours"
            attempts.append({"path": "fallback", "ok": True, "reason": "quiet-hours"})
        else:
            # 2. direct aliases, 3. macOS
            direct = self._try_direct(connections, "%s\n%s" % (head, body) if body else head, attempts)
            if direct:
                delivered_via, provider_name, ok = "direct:" + direct, direct, True
            else:
                reason = self._macos(head, body)
                attempts.append({"path": "macos-local", "ok": reason == "", "reason": reason or "shown"})
                if reason == "":
                    delivered_via, provider_name, ok = "macos-local", "macos", True
                else:
                    error = "all delivery paths failed (hub %s)" % hub_info.get("reason", "unavailable")
        if not ok and not error:
            error = "delivery failed"
        receipt: Dict[str, Any] = {
            "id": "ntc-" + uuid.uuid4().hex[:12], "ts": self._clock(), "provider": provider_name,
            "alias": "", "template": "", "type": notice_type, "severity": resolved["severity"],
            "ok": ok, "error": error, "deliveredVia": delivered_via,
            "hub": {k: v for k, v in hub_info.items() if k not in ("error", "fallback")},
            "attempts": attempts,
        }
        self._write_receipt(ref, receipt)
        return receipt

    def _try_hub(self, notice_type, head, body, severity, ref, attempts, hub_info):
        """Run the single hub attempt. Fills hub_info {status, reason, ...}.
        Returns None when the hub path was skipped (then hub_info['fallback'] is True)."""
        import release_notify_hub as hub  # noqa: PLC0415 - sibling module
        try:
            registry = self._registry or default_registry()
            if "hub" not in registry.names():
                raise hub.HubSkip("hub-not-registered")
            provider = registry.get("hub")
            ctx = self._context({})
            target = provider.resolve_target(notice_type, ctx, title=head, severity=severity, ref=ref)
            provider.validate_target(target)
        except hub.HubSkip as skip:
            hub_info.update(status="skipped", reason=skip.reason, fallback=True)
            attempts.append({"path": "hub", "ok": False, "reason": "skipped:" + skip.reason})
            return None
        except NotifyError as exc:  # resolver refusals etc.; text is ours, never a secret
            hub_info.update(status="skipped", reason="hub-config-error", fallback=True)
            attempts.append({"path": "hub", "ok": False, "reason": "skipped:hub-config-error"})
            return None
        try:
            outcome = provider.deliver(target, NoticeMessage(text=body))
        except hub.HubDeliveryError as exc:
            hub_info.update(status=exc.kind, reason=exc.reason, fallback=exc.fallback,
                            error="hub %s (%s)%s" % (exc.kind, exc.reason, " code=" + exc.error_code if exc.error_code else ""))
            if exc.http_status:
                hub_info["httpStatus"] = exc.http_status
            if exc.error_code:
                hub_info["errorCode"] = exc.error_code
            attempts.append({"path": "hub", "ok": False, "reason": "%s:%s" % (exc.kind, exc.reason)})
            return exc
        except Exception as exc:  # noqa: BLE001 - foreign failure: type only
            hub_info.update(status="unreachable", reason="provider-error-" + type(exc).__name__,
                            fallback=True, error="hub provider error (%s)" % type(exc).__name__)
            attempts.append({"path": "hub", "ok": False, "reason": "unreachable:provider-error"})
            return None
        hub_info.update(delivered=outcome.delivered, failed=outcome.failed, suppressed=outcome.suppressed)
        if outcome.ok:
            hub_info.update(status="delivered",
                            reason=outcome.reason or ("suppressed" if outcome.delivered == 0 else ""))
            if outcome.reason and outcome.delivered > 0:
                hub_info["warning"] = outcome.reason  # delivered, but FM flagged a problem (static code)
            attempts.append({"path": "hub", "ok": True, "reason": hub_info["reason"] or "delivered"})
        else:
            hub_info.update(status="delivered-nothing", reason=outcome.reason, fallback=False,
                            error="hub delivered nothing (%s)" % outcome.reason)
            attempts.append({"path": "hub", "ok": False, "reason": "nothing-delivered:" + outcome.reason})
        return outcome

    def _try_direct(self, connections, text, attempts) -> str:
        """Send to every route connection id that is also a local alias. Returns
        the first delivering provider's name, or ''. Failures are static codes."""
        try:
            aliases = self.load_aliases()
        except NotifyError:
            return ""
        first = ""
        for cid in connections:
            if cid not in aliases:
                continue
            try:
                provider, ctx = self._route(cid, aliases)
                target = provider.resolve_target(cid, ctx)
                provider.validate_target(target)
                provider.send(target, NoticeMessage(text=text))
            except NotifyError as exc:  # engine/provider messages are secret-free by contract
                attempts.append({"path": "direct:" + str(aliases[cid].get("provider", "?")), "ok": False,
                                 "alias": cid, "reason": type(exc).__name__})
                continue
            except Exception as exc:  # noqa: BLE001
                attempts.append({"path": "direct", "ok": False, "alias": cid, "reason": type(exc).__name__})
                continue
            name = provider.name
            attempts.append({"path": "direct:" + name, "ok": True, "alias": cid, "reason": "delivered"})
            first = first or name
        return first

    def _macos(self, head: str, body: str) -> str:
        if self._macos_notifier is not None:
            return self._macos_notifier(head, body)
        import release_notify_hub as hub  # noqa: PLC0415
        return hub.macos_notify(head, body)

    # -- test (-005) -------------------------------------------------------
    def test(self, alias: str) -> str:
        """Verify route + secret resolve non-empty. Sends nothing, writes nothing.
        Returns the provider name (the only thing the CLI prints besides alias)."""
        aliases = self.load_aliases()
        provider, ctx = self._route(alias, aliases)
        target = provider.resolve_target(alias, ctx)
        if not target.secret:
            raise NotifySecretError("secretRef for alias '%s' resolved empty" % alias)
        provider.validate_target(target)
        return provider.name

    # -- send (-002/-004) --------------------------------------------------
    def render(self, template: str, data: Mapping[str, Any]) -> str:
        if self._render_template is not None:
            return self._render_template(self.team, template, data, self.kanban_dir())
        resolver = _load_script_module("release_profile_resolver")
        renderer = _load_script_module("release_template_render")
        try:
            body = resolver.resolve_profile(self.team, "notice", kanban_dir=self.kanban_dir(),
                                            notice_name=template)["template"]
        except Exception as exc:  # noqa: BLE001 - ProfileResolutionError / validation
            raise NotifyConfigError("cannot resolve notice template '%s': %s" % (
                template, str(exc)[:200])) from None
        if body is None:
            raise NotifyConfigError("notice template '%s' not found" % template)
        try:
            return renderer.render(body, dict(data))
        except renderer.TemplateRenderError as exc:
            raise NotifyConfigError("template '%s' render failed: %s" % (template, str(exc)[:200])) from None

    def send(self, alias: str, *, template: Optional[str] = None, data: Optional[Mapping[str, Any]] = None,
             text: Optional[str] = None, ref: Optional[str] = None) -> Dict[str, Any]:
        """Deliver one notice and persist its receipt. Returns the receipt dict
        (`ok` False on a delivery failure). Raises NotifyConfigError when nothing
        was routed (no receipt), NotifyReceiptError when the receipt cannot be
        written. Never retries."""
        if (template is None) == (text is None):
            raise NotifyConfigError("exactly one of template or text is required")
        if ref is not None:
            self._check_ref(ref)  # fail before sending, not after
        aliases = self.load_aliases()
        provider, ctx = self._route(alias, aliases)
        body = text if text is not None else self.render(template, data or {})
        if not isinstance(body, str) or not body.strip():
            raise NotifyConfigError("refusing to send an empty notice")  # nothing routed, no receipt
        message = NoticeMessage(text=body, template=template or "")

        ok, error, message_id = True, "", None
        try:
            target = provider.resolve_target(alias, ctx)
            provider.validate_target(target)
            message_id = provider.send(target, message).provider_message_id
        except NotifyError as exc:  # routed, so every failure from here on is a receipted send
            ok, error = False, str(exc)  # our own messages never carry the target
        except Exception as exc:  # noqa: BLE001 - e.g. a future provider's unexpected failure
            # a foreign exception's text may embed the target: record its type only
            ok, error = False, "provider error (%s)" % type(exc).__name__
        receipt: Dict[str, Any] = {
            "id": "ntc-" + uuid.uuid4().hex[:12], "ts": self._clock(), "provider": provider.name,
            "alias": alias, "template": template or "", "ok": ok, "error": error,
        }
        if message_id:
            receipt["providerMessageId"] = message_id
        self._write_receipt(ref, receipt)
        return receipt

    # -- receipts (-004) ---------------------------------------------------
    def _board_io(self):
        if self._board_read is None or self._board_update is None:
            import kanban_utils  # noqa: PLC0415 - the sanctioned locked board writer
            self._board_read = self._board_read or kanban_utils.read_board_safely
            self._board_update = self._board_update or kanban_utils.update_board_safely
        return self._board_read, self._board_update

    @staticmethod
    def _collection(ref: str) -> str:
        if not REF_RE.match(ref):
            raise NotifyConfigError("invalid ref (expected REL-... or CR-...)")
        return REF_COLLECTIONS[ref.split("-", 1)[0]]

    def _check_ref(self, ref: str) -> None:
        collection = self._collection(ref)
        read, _ = self._board_io()
        board = read(str(self.board_file()))
        records = board.get(collection) if isinstance(board, dict) else None
        record = next((r for r in records if isinstance(r, dict) and r.get("id") == ref), None) \
            if isinstance(records, list) else None
        if record is None:
            raise NotifyConfigError("ref '%s' not found on the %s board" % (ref, self.team))
        if record.get("notices") is not None and not isinstance(record["notices"], list):
            raise NotifyConfigError("ref '%s' has a malformed notices field; not overwriting" % ref)

    def _write_receipt(self, ref: Optional[str], receipt: Dict[str, Any]) -> None:
        try:
            if ref is None:
                self._append_log(receipt)
            else:
                self._append_to_record(ref, receipt)
        except NotifyReceiptError:
            raise
        except Exception as exc:  # noqa: BLE001
            raise NotifyReceiptError("receipt write failed (%s)" % type(exc).__name__) from None

    def _append_to_record(self, ref: str, receipt: Dict[str, Any]) -> None:
        collection = self._collection(ref)
        _, update = self._board_io()
        found = []

        def mutate(board):
            for rec in board.get(collection) or []:
                if isinstance(rec, dict) and rec.get("id") == ref:
                    notices = rec.get("notices")
                    if notices is None:
                        notices = rec["notices"] = []
                    elif not isinstance(notices, list):
                        raise ValueError("notices is not a list")  # never overwrite unknown data
                    notices.append(receipt)
                    found.append(True)
                    return board
            return None  # skip the write

        if not update(str(self.board_file()), mutate) or not found:
            raise NotifyReceiptError("receipt write failed (record '%s' not updated)" % ref)

    def _append_log(self, receipt: Dict[str, Any]) -> None:
        path = self.kanban_dir() / NOTIFY_LOG_NAME
        line = (json.dumps(receipt, sort_keys=True) + "\n").encode("utf-8")
        fd = os.open(str(path), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            os.write(fd, line)
            os.fsync(fd)
        finally:
            os.close(fd)  # closing releases the flock
