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
    reg.register("teams", TeamsProvider)
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


# ---------------------------------------------------------------- engine


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class NotifyEngine:
    """Every dependency is injectable so tests never touch the network, the
    registry, the vault or a live board."""

    def __init__(self, team: str, *, kanban_dir=None, registry: Optional[ProviderRegistry] = None,
                 secret_resolver=None, validate_config=None, render_template=None,
                 board_read=None, board_update=None, clock=None, terminal: str = "") -> None:
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

    def load_aliases(self) -> Mapping[str, Any]:
        path = self.kanban_dir() / "config" / "notify.json"
        try:
            config = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            raise NotifyConfigError("team '%s' has no notify.json" % self.team) from None
        except (OSError, ValueError) as exc:
            raise NotifyConfigError("notify.json unreadable (%s)" % type(exc).__name__) from None
        validate = self._validate_config
        if validate is None:
            validate = _load_script_module("release_config_validate").validate_notify_config
        errors = validate(config)
        if errors:  # the validator's messages are redaction-safe by contract
            raise NotifyConfigError("notify.json invalid: " + "; ".join(errors))
        return config["aliases"]

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
