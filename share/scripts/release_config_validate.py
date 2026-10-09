#!/usr/bin/env python3
"""
release_config_validate.py -- XACA-1342 Phase 1.

Schema validation + secretRef resolution for the release engine's per-team
config files (notify.json, wiki.json, profile.json). Spec:
docs/release-workflow/RELEASE-LIFECYCLE.md (MainEventEntertainment/dev-team,
develop) § 2.2, § 10.1, § 11.3-11.5.

Ownership (§ 2.2 "never shared" config rule): a team's notify.json,
wiki.json and profile.json live only under that team's own
`<team kanban>/config/` tree. Config files hold *secret references*
(a vault key or an environment-variable name) -- never secret values.

This module is imported by:
  - scripts/kb-release-config-validate.sh (XACA-1342-005, Phase 2 CLI)
  - kb-notify test (XACA-1345, downstream)
  - kb-wiki doctor (XACA-1344, downstream)

Redaction discipline (spec § 10.1 "Secrets resolve just-in-time... never
logged", handoff Requested Work #4): no function in this module ever prints,
logs, or includes a secret value -- or the raw literal that a malformed
secretRef/target/credential field carried -- in an exception message,
returned string, or anywhere else besides the direct return value of
resolve_secret_ref() itself. jsonschema's default ValidationError.message
embeds the offending instance value, so every error surfaced by this module
is rebuilt through _describe_error() rather than passed through verbatim.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
from functools import lru_cache
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError

# ---------------------------------------------------------------------------
# secretRef grammar (XACA-1342-001, DECIDED 2026-09-25)
#
# Only two forms are legal anywhere a secretRef/target/credential value is
# expected:
#   vault:<engine_slug>/<account_slug>   -- exactly two segments, each
#                                            matching the vault's own slug
#                                            pattern (fleet-monitor/server/
#                                            lib/vault-store.js SLUG_RE:
#                                            ^[a-z][a-z0-9-]*$, <=64 chars)
#   env:RELEASE_<TEAM>_<PURPOSE>         -- ^RELEASE_[A-Z][A-Z0-9_]*$ (team-owned, XACA-1342-018)
#
# This pattern string is duplicated verbatim in each *.schema.json file's
# "secretRef" property (JSON Schema files can't $ref a Python constant).
# tests/test_xaca1342_release_config_validate.py asserts the schema files'
# patterns stay byte-identical to this constant so the two can't drift.
#
# NOTE: the end anchor is (?![\s\S]), not $ or \Z. Python's re module (used both here and
# by jsonschema's "pattern" keyword) treats a bare trailing $ as matching
# either the true end of string OR the position just before a single
# trailing "\n" -- so "env:FOO\n" / "vault:aa/bb\n" would otherwise pass
# both the schema pattern check and this module's own grammar check, then
# get forwarded (with an embedded newline) into env-var lookup / vault-fetch
# argv. \Z would fix Python but is not ECMA-262: JSON Schema patterns are
# ECMA-262, where \Z is a literal "Z" (or a syntax error under /u), so an
# Ajv consumer would reject every valid ref. (?![\s\S]) is a true
# end-of-string assertion in both dialects.
#
# env: names must start with RELEASE_ (XACA-1342-018): a release config can
# then never name an unrelated process variable (CLAUDE_ACCT_*,
# TEAM_*_API_KEY, ...). Which TEAM may read a RELEASE_ name is enforced at
# resolve time -- see _team_owns_env_var().
# ---------------------------------------------------------------------------
SECRET_REF_PATTERN = r"^(vault:[a-z][a-z0-9-]{0,63}/[a-z][a-z0-9-]{0,63}|env:RELEASE_[A-Z][A-Z0-9_]*)(?![\s\S])"
SECRET_REF_RE = re.compile(SECRET_REF_PATTERN)

# Field names that MUST never have their instance value echoed in an error
# message -- they either directly hold a secretRef, or (target/credential)
# are the object wrapping one, so a shape error on the wrapper itself (e.g.
# someone wrote a literal string instead of {secretRef: ...}) is just as
# sensitive as a pattern mismatch on the inner secretRef string.
_SECRET_SENSITIVE_FIELD_NAMES = frozenset({"secretRef", "target", "credential"})

_SCHEMAS_DIR = Path(__file__).resolve().parent / "release_config_schemas"


class ReleaseConfigValidationError(Exception):
    """
    Raised by the validate_*_config() functions when a config fails schema
    validation. `.errors` is a list of redaction-safe messages (field path +
    reason only -- never the offending instance value). str(exc) joins them
    with newlines for convenient CLI/log printing.
    """

    def __init__(self, errors: list[str]):
        self.errors = list(errors)
        super().__init__("\n".join(self.errors))


class SecretResolutionError(Exception):
    """
    Raised by resolve_secret_ref() when a secretRef cannot be resolved to a
    plaintext value. The message NEVER contains a secret value -- there is
    none to leak at this point, since resolution failed -- and never echoes
    a raw literal ref that failed the grammar check either.
    """


# ---------------------------------------------------------------------------
# Schema loading
# ---------------------------------------------------------------------------

@lru_cache(maxsize=None)
def _load_schema(filename: str) -> dict:
    path = _SCHEMAS_DIR / filename
    with open(path, "r", encoding="utf-8") as f:
        schema = json.load(f)
    Draft202012Validator.check_schema(schema)
    return schema


# ---------------------------------------------------------------------------
# Redaction-safe error formatting
# ---------------------------------------------------------------------------

# Alias names in notify.json are user-chosen map KEYS and get printed in error
# paths and --resolve-check labels, so they are constrained to a short slug
# (mirrored byte-identically in notify.schema.json's aliases.propertyNames).
ALIAS_NAME_PATTERN = r"^[a-z][a-z0-9-]{0,31}(?![\s\S])"
_ALIAS_NAME_RE = re.compile(ALIAS_NAME_PATTERN)

REDACTED_KEY = "<redacted-key>"


def _declared_property_names(node: Any, acc: set) -> set:
    """Every property name the schema itself declares (``properties`` keys)."""
    if isinstance(node, dict):
        props = node.get("properties")
        if isinstance(props, dict):
            acc.update(props.keys())
        for v in node.values():
            _declared_property_names(v, acc)
    elif isinstance(node, list):
        for v in node:
            _declared_property_names(v, acc)
    return acc


_KNOWN_KEYS: set | None = None


def _render_key(key: str) -> str:
    """
    Render a mapping key for output only when it cannot be a stray secret:
    a property name one of the release schemas declares, or a key matching
    the alias-name grammar. Anything else (a URL, token or phone number
    pasted into a key slot) prints as REDACTED_KEY. Deliberately not "any
    identifier": an AWS key id such as AKIA... is a valid identifier.
    """
    global _KNOWN_KEYS
    if _KNOWN_KEYS is None:
        known: set = set()
        for name in ("notify.schema.json", "notify-v2.schema.json",
                     "wiki.schema.json", "profile.schema.json"):
            _declared_property_names(_load_schema(name), known)
        _KNOWN_KEYS = known
    if key in _KNOWN_KEYS or _ALIAS_NAME_RE.search(key):
        return key
    return REDACTED_KEY


def _format_path(path: list) -> str:
    out = "$"
    for seg in path:
        if isinstance(seg, int):
            out += f"[{seg}]"
        else:
            out += f".{_render_key(str(seg))}"
    return out


def _path_touches_secret_field(path: list) -> bool:
    return any(isinstance(seg, str) and seg in _SECRET_SENSITIVE_FIELD_NAMES for seg in path)


def _describe_error(e: ValidationError) -> str:
    """
    Build a redaction-safe description of a single jsonschema ValidationError:
    field path + reason, NEVER the instance value. Requirement: any error on
    a secretRef/target/credential field says exactly "literal value not
    permitted" and nothing else about the value.
    """
    path = list(e.absolute_path)
    label = _format_path(path)

    if _path_touches_secret_field(path):
        return f"{label}: literal value not permitted"

    kw = e.validator
    if kw == "required":
        # jsonschema's default message here names only the missing
        # property, never a data value -- safe to reuse verbatim.
        return f"{label}: {e.message}"
    if kw == "additionalProperties":
        # jsonschema's default message enumerates the offending property
        # KEY(S) verbatim (e.g. "Additional properties are not allowed
        # ('SENTINEL-...' was unexpected)"). Those keys come straight from
        # the instance the caller supplied -- a mistyped or malicious
        # config could use a URL/token/webhook-shaped string as a dict key
        # in any additionalProperties:false object, not only inside a
        # secretRef/target/credential field, so e.message is NOT safe to
        # reuse here. Never echo it.
        return f"{label}: unexpected additional field(s) not permitted"
    if kw in ("enum", "const"):
        return f"{label}: value is not one of the allowed options"
    if kw == "type":
        expected = e.validator_value
        return f"{label}: wrong type (expected {expected})"
    if kw == "pattern":
        return f"{label}: value does not match the required pattern"
    if kw == "minProperties":
        return f"{label}: requires at least one entry"
    if kw == "oneOf":
        return f"{label}: does not match exactly one of the allowed shapes"
    if kw == "minLength":
        return f"{label}: value is too short"
    # Fallback: still never include e.instance.
    return f"{label}: schema validation failed ({kw})"


def _validate_against_schema(instance: Any, schema: dict) -> list[str]:
    validator = Draft202012Validator(schema)
    errors = sorted(
        validator.iter_errors(instance),
        key=lambda e: [str(p) for p in e.absolute_path],
    )
    return [_describe_error(e) for e in errors]


# ---------------------------------------------------------------------------
# Public validate_*_config() API
#
# Each returns a list of redaction-safe error message strings; an empty list
# means the config is valid. (Callers that want an exception on failure can
# wrap the call: `if errors: raise ReleaseConfigValidationError(errors)`.)
# ---------------------------------------------------------------------------

def validate_notify_config(config: dict) -> list[str]:
    """Validate a notify.json dict. § 11.4.

    Dispatches on the "$schema" discriminator (XACA-1399): release-notify/v2
    (notice-type routes) is checked against notify-v2.schema.json; EVERYTHING
    else -- including a missing or garbled "$schema" -- goes to the unchanged
    v1 schema, so v1 configs and v1 error messages are byte-for-byte as before.
    Schema-only: route ids are cross-checked against the notice-type catalog by
    notify_v2_semantic_errors() (needs the team's catalog layer).
    """
    if isinstance(config, dict) and config.get("$schema") == "release-notify/v2":
        return _validate_against_schema(config, _load_schema("notify-v2.schema.json"))
    return _validate_against_schema(config, _load_schema("notify.schema.json"))


def notify_v2_semantic_errors(config: dict, kanban_dir) -> list[str]:
    """Schema-valid v2 config -> catalog/quiet-hours cross-checks (XACA-1399).
    Unknown notice-type ids in routes fail closed. [] for non-v2 configs."""
    if not (isinstance(config, dict) and config.get("$schema") == "release-notify/v2"):
        return []
    here = Path(__file__).resolve().parent
    for cand in (here.parent / "kanban-hooks", here):
        if (cand / "release_notify_routing.py").is_file():
            sys.path.insert(0, str(cand))
            try:
                import release_notify_routing as rr  # noqa: PLC0415
            finally:
                sys.path.remove(str(cand))
            break
    else:
        return ["cannot find kanban-hooks/release_notify_routing.py; v2 routes not cross-checked"]
    try:
        catalog = rr.load_catalog(kanban_dir)
    except rr.NoticeRoutingError as exc:
        return [str(exc)]
    return rr.validate_v2_semantics(config, catalog)


def validate_wiki_config(config: dict) -> list[str]:
    """Validate a wiki.json dict against release-wiki/v1. § 11.5."""
    errors = _validate_against_schema(config, _load_schema("wiki.schema.json"))
    if not (isinstance(config, dict) and config.get("provider") == "local"):
        return errors
    # XACA-1370-015: the local branch forbids Confluence-only fields with
    # `false` subschemas. jsonschema reports those with validator None, drops
    # the property from the path and puts the VALUE in its message, so the
    # generic formatter can only say "schema validation failed (None)". Name
    # the forbidden fields here instead. The names are schema constants and
    # docType keys (already printed in paths); values are never echoed.
    named = []
    for field in _LOCAL_FORBIDDEN_TOP:
        if field in config:
            named.append(f"{_format_path([field])}: not permitted for provider 'local'")
    doc_types = config.get("docTypes")
    if isinstance(doc_types, dict):
        for key, entry in doc_types.items():
            if isinstance(entry, dict):
                for field in _LOCAL_FORBIDDEN_DOCTYPE:
                    if field in entry:
                        named.append(f"{_format_path(['docTypes', key, field])}: "
                                     "not permitted for provider 'local'")
    if not named:
        return errors
    vague = [e for e in errors if e.endswith("schema validation failed (None)")
             or e.endswith("literal value not permitted") and e.startswith("$.credential")]
    return [e for e in errors if e not in vague] + named


# Fields the wiki schema's provider=local branch forbids (kept in step with
# release_config_schemas/wiki.schema.json allOf[1].then).
_LOCAL_FORBIDDEN_TOP = ("credential", "baseUrl")
_LOCAL_FORBIDDEN_DOCTYPE = ("space", "parent")


def validate_profile_config(config: dict) -> list[str]:
    """Validate a profile.json dict against release-profile/v1. § 11.3."""
    return _validate_against_schema(config, _load_schema("profile.schema.json"))


# ---------------------------------------------------------------------------
# resolve_secret_ref() -- XACA-1342-004
# ---------------------------------------------------------------------------

# fleet-monitor/client/vault-fetch.sh exit codes (see its own header for the
# authoritative doc). 0 and 5 are success; every other code is a failure.
_VAULT_FETCH_SUCCESS_CODES = frozenset({0, 5})
_VAULT_FETCH_EXIT_DESCRIPTIONS = {
    1: "usage error (malformed engine/account slug)",
    3: "vault not configured on this machine (no keypair)",
    4: "vault unreachable",
    6: "vault decrypt failed (wrong or rotated key)",
    7: "secret not found in vault for this engine/account",
    8: "no fleet server URL configured",
}

# Test-only escape hatch, same pattern as _ALLOW_ANY_CONFIG_DIR_ENV_VAR
# below: not documented in --help, exists only so an out-of-process test
# (a real `python3 release_config_validate.py ...` subprocess, e.g. via the
# zsh dispatcher) can point the vault: branch of resolve_secret_ref() at a
# fake vault-fetch.sh instead of the real fleet-monitor client -- there is
# no other way to redirect this fixed, __file__-relative path from outside
# the process. In-process tests should keep using
# monkeypatch.setattr(rcv, "VAULT_FETCH_SH", fake) instead.
_VAULT_FETCH_SH_OVERRIDE_ENV_VAR = "RELEASE_CONFIG_VALIDATE_VAULT_FETCH_SH_OVERRIDE"


def _resolve_vault_fetch_sh(base_dir: Path | None = None) -> Path:
    """
    Resolve the vault-fetch.sh path through a candidate list, the same
    pattern _load_aiteamforge_paths_module() already uses for
    aiteamforge_paths.py -- __file__-relative layout differs between the
    dev tree and the flattened tap layout (XACA-1342-020):

      - dev tree: this file lives in scripts/, vault-fetch.sh lives in the
        sibling fleet-monitor/client/ directory.
      - tap layout: sync-tap.sh (~:1135) flattens vault-fetch.sh to
        share/scripts/vault-fetch.sh -- a direct SIBLING of this module
        (share/scripts/release_config_validate.py) -- because there is no
        share/fleet-monitor/ in the tap.

    The override env var wins outright (test-only escape hatch, see above);
    otherwise the dev-tree path is tried first, then the flattened sibling.
    If neither exists, the dev-tree path is returned anyway so the
    "not found" error downstream names a stable, predictable path rather
    than whichever candidate happened to be tried last.

    `base_dir` is a test-only override for `Path(__file__).resolve().parent`
    -- it lets a test build a mock tap layout without touching the real
    file tree the module was loaded from.
    """
    override = os.environ.get(_VAULT_FETCH_SH_OVERRIDE_ENV_VAR)
    if override:
        return Path(override)

    this_dir = base_dir if base_dir is not None else Path(__file__).resolve().parent
    candidates = [
        this_dir.parent / "fleet-monitor" / "client" / "vault-fetch.sh",  # dev layout
        this_dir / "vault-fetch.sh",  # tap layout: flattened sibling
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return candidates[0]


VAULT_FETCH_SH = _resolve_vault_fetch_sh()


def resolve_secret_ref(ref: str, team: str) -> str:
    """
    Resolve a validated secretRef to its plaintext value, just-in-time.
    The returned value is intended for the immediate caller only -- never
    log it, print it, or write it to a file.

    Args:
        ref: a secretRef string, either "vault:<engine_slug>/<account_slug>"
             or "env:RELEASE_<TEAM>_<PURPOSE>".
        team: the calling team's id, used to enforce team isolation on
              vault: and env: refs (§ 2.2) -- the vault seals per machine,
              not per team, and the environment is shared, so this is the
              enforcement point.

    Raises:
        SecretResolutionError: on any failure. The message never contains
        the ref's value (there isn't one to leak) nor a resolved secret.
    """
    if not isinstance(ref, str):
        raise SecretResolutionError("secretRef must be a string")
    if not isinstance(team, str) or not team:
        raise SecretResolutionError("team must be a non-empty string")

    match = SECRET_REF_RE.match(ref)
    if not match:
        raise SecretResolutionError(
            "secretRef does not match the vault:<engine>/<account> or "
            "env:RELEASE_<TEAM>_<PURPOSE> grammar"
        )

    if ref.startswith("env:"):
        return _resolve_env_ref(ref[len("env:"):], team)

    # ref.startswith("vault:") -- the only other branch SECRET_REF_RE allows.
    path = ref[len("vault:"):]
    engine_slug, _, account_slug = path.partition("/")
    return _resolve_vault_ref(engine_slug, account_slug, team)


# Test-only hook (XACA-1342-021): a module-level override for the
# registered-team-id set, so a test can exercise _resolve_vault_ref()'s
# team-isolation logic against a fixture registry (e.g. one that includes
# the real mainevent-* / freelance-doublenode-* collision shapes) without
# touching the live ~/.aiteamforge/team-paths.json. None (the default)
# means "load the real registry". Set via
# monkeypatch.setattr(rcv, "_TEAM_IDS_OVERRIDE", frozenset({...})).
_TEAM_IDS_OVERRIDE: frozenset[str] | None = None


def _resolve_registered_team_ids() -> frozenset[str]:
    """
    Return every registered team id, from the same canonical registry
    accessor (aiteamforge_paths.list_teams()) the CLI already uses to
    resolve --config-dir.

    FAILS CLOSED (XACA-1342-021): if the registry cannot be loaded for any
    reason -- missing module, corrupt/unreadable config, anything -- this
    raises SecretResolutionError rather than falling back to a bare prefix
    check. Team isolation must never silently degrade to "allow".
    """
    if _TEAM_IDS_OVERRIDE is not None:
        return _TEAM_IDS_OVERRIDE
    try:
        aiteamforge_paths = _load_aiteamforge_paths_module()
        return frozenset(aiteamforge_paths.list_teams())
    except Exception as exc:  # noqa: BLE001 - deliberately broad: fail
        # closed on ANY registry-load error, and never forward str(exc)
        # (could echo a config path or content) -- only the type name.
        raise SecretResolutionError(
            "refusing vault resolution: team registry unavailable "
            f"({type(exc).__name__})"
        ) from None


def _team_owns_account_slug(
    team: str, account_slug: str, registered_team_ids: frozenset[str]
) -> bool:
    """
    True iff `account_slug` belongs to `team` under the "<team>-<purpose>"
    convention (XACA-1342-001), even when registered team ids collide as
    prefixes of one another (e.g. "mainevent" vs.
    "mainevent-maineventapp-ios" -- both real registered team ids).

    A bare `account_slug.startswith(f"{team}-")` is ambiguous here: since
    team ids themselves may contain "-", a SHORTER team id can be a
    false-positive prefix match for an account slug that actually belongs
    to a longer, more specific team id. This finds the LONGEST registered
    team id `T` such that `account_slug` starts with `"T-"`, and requires
    `T == team` -- so only the most specific owning team ever passes.
    """
    longest_owner: str | None = None
    for candidate in registered_team_ids:
        if account_slug.startswith(f"{candidate}-"):
            if longest_owner is None or len(candidate) > len(longest_owner):
                longest_owner = candidate
    return longest_owner == team


def _env_prefix_for_team(team_id: str) -> str:
    """RELEASE_<TEAM>_ with the team id uppercased and '-' mapped to '_'."""
    return "RELEASE_" + team_id.upper().replace("-", "_") + "_"


def _team_owns_env_var(
    team: str, var_name: str, registered_team_ids: frozenset[str]
) -> bool:
    """
    True iff `var_name` belongs to `team` under RELEASE_<TEAM>_<PURPOSE>
    (XACA-1342-018). Same longest-owner rule as _team_owns_account_slug():
    RELEASE_MAINEVENT_MAINEVENTAPP_IOS_X belongs to mainevent-maineventapp-ios,
    never to mainevent, even though both prefixes match.
    """
    longest_owner: str | None = None
    for candidate in registered_team_ids:
        if var_name.startswith(_env_prefix_for_team(candidate)):
            if longest_owner is None or len(candidate) > len(longest_owner):
                longest_owner = candidate
    return longest_owner == team


def _resolve_env_ref(var_name: str, team: str) -> str:
    # Team isolation for env: refs (XACA-1342-018), checked before the
    # environment is read, so --resolve-check cannot act as a set/unset
    # oracle for another team's variables. Fails closed with the registry.
    registered_team_ids = _resolve_registered_team_ids()
    if team not in registered_team_ids:
        raise SecretResolutionError(
            f"refusing env resolution: '{team}' is not a registered team id"
        )
    if not _team_owns_env_var(team, var_name, registered_team_ids):
        raise SecretResolutionError(
            "refusing cross-team secret: environment variable does not belong "
            f"to team '{team}' (expected {_env_prefix_for_team(team)}<PURPOSE>)"
        )
    value = os.environ.get(var_name)
    if not value:
        raise SecretResolutionError(
            f"environment variable '{var_name}' is unset or empty"
        )
    return value


def _resolve_vault_ref(engine_slug: str, account_slug: str, team: str) -> str:
    # Team isolation (§ 2.2): refuse any vault: ref whose account slug does
    # not belong to `team` under the "<team>-<purpose>" convention.
    # Checked before ever touching vault-fetch.sh. See
    # _team_owns_account_slug() for why a bare startswith(f"{team}-") is
    # unsafe (XACA-1342-021): team ids themselves contain "-", so a shorter
    # team id can be a false-positive prefix of a longer, unrelated team id.
    registered_team_ids = _resolve_registered_team_ids()
    if team not in registered_team_ids:
        raise SecretResolutionError(
            f"refusing vault resolution: '{team}' is not a registered team id"
        )
    if not _team_owns_account_slug(team, account_slug, registered_team_ids):
        raise SecretResolutionError(
            f"refusing cross-team secret: account slug does not belong to team '{team}'"
        )

    if not VAULT_FETCH_SH.is_file():
        raise SecretResolutionError(
            "vault-fetch.sh not found; this machine may not be vault-provisioned"
        )

    # The override swaps the program that produces plaintext secrets; it
    # must never be silent, so a stray export outside tests is visible.
    if os.environ.get(_VAULT_FETCH_SH_OVERRIDE_ENV_VAR):
        print(
            f"WARNING: {_VAULT_FETCH_SH_OVERRIDE_ENV_VAR} is set; vault: refs are "
            "resolved by a non-standard vault-fetch (test mode)",
            file=sys.stderr,
        )

    try:
        result = subprocess.run(
            [str(VAULT_FETCH_SH), engine_slug, account_slug],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except Exception as exc:  # noqa: BLE001 - deliberately broad, message is generic
        raise SecretResolutionError(
            f"vault-fetch invocation failed: {type(exc).__name__}"
        ) from None

    if result.returncode not in _VAULT_FETCH_SUCCESS_CODES:
        reason = _VAULT_FETCH_EXIT_DESCRIPTIONS.get(
            result.returncode, f"exit code {result.returncode}"
        )
        raise SecretResolutionError(
            f"vault-fetch failed for {engine_slug}/{account_slug}: {reason}"
        )

    # Contract (vault-fetch.sh header): "stdout carries ONLY the plaintext.
    # All diagnostics go to stderr." We deliberately never read/log stderr
    # here, even on failure, to keep this function's failure surface free of
    # any content that might carry partial secret material.
    value = result.stdout.rstrip("\n")
    if not value:
        raise SecretResolutionError(
            f"vault-fetch returned an empty value for {engine_slug}/{account_slug}"
        )
    return value


# ---------------------------------------------------------------------------
# CLI -- kb-release-config-validate (XACA-1342-005)
#
# Standalone entry point per Requirement 6 ("runnable on its own"), reused
# unmodified by kb-notify test (XACA-1345) and kb-wiki doctor (XACA-1344)
# via a plain import of this module -- the CLI below is a thin wrapper
# around the same validate_*_config()/resolve_secret_ref() functions those
# tickets import directly, not a second implementation.
#
# Config lives ONLY under <team kanban>/config/ (spec § 2.2, Requirement 8).
# This CLI never reads or writes anywhere else: --config-dir exists purely
# so tests can point it at a temp fixture tree, and is refused unless the
# path plausibly IS a team's kanban/config directory (see
# _is_allowed_config_dir) or the test escape hatch below is set.
# ---------------------------------------------------------------------------

PROFILE_KINDS = ("cr", "testing-log", "cr-record", "notice")

# Test-only escape hatch for _is_allowed_config_dir(). Named verbosely and
# deliberately NOT documented in --help: this is not a feature for normal
# use, only for tests/test_xaca1342_cli.py to point --config-dir at a
# tmp_path fixture tree that (correctly) does not end in kanban/config.
_ALLOW_ANY_CONFIG_DIR_ENV_VAR = "RELEASE_CONFIG_VALIDATE_ALLOW_ANY_DIR"


class _UsageError(Exception):
    """Raised for any usage/env problem the CLI should report as exit 2."""


def _is_allowed_config_dir(path: Path) -> bool:
    if os.environ.get(_ALLOW_ANY_CONFIG_DIR_ENV_VAR) == "1":
        return True
    return path.parts[-2:] == ("kanban", "config")


def _load_aiteamforge_paths_module():
    """
    Import aiteamforge_paths from the sibling kanban-hooks/ directory,
    matching the loader used by scripts/aiteamforge-team-paths-wizard.py
    (kanban-hooks/ is a sibling of scripts/ in both the dev tree and the
    tap layout -- sync-tap.sh mirrors both directories independently, so
    this relative lookup holds in either).
    """
    this_dir = Path(__file__).resolve().parent
    candidates = [
        this_dir.parent / "kanban-hooks" / "aiteamforge_paths.py",
        this_dir / "aiteamforge_paths.py",  # fallback: same dir
    ]
    for candidate in candidates:
        if candidate.is_file():
            spec = importlib.util.spec_from_file_location(
                "aiteamforge_paths", candidate
            )
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    raise _UsageError(
        "cannot find kanban-hooks/aiteamforge_paths.py relative to this script"
    )


def _resolve_config_dir(team: str, config_dir_arg: str | None) -> Path:
    if config_dir_arg is not None:
        candidate = Path(config_dir_arg).expanduser().resolve()
        if not _is_allowed_config_dir(candidate):
            raise _UsageError(
                f"--config-dir must be a team's <kanban>/config directory "
                f"(got {candidate}); refusing a path outside any team's "
                f"kanban/config (spec § 2.2)"
            )
        return candidate

    aiteamforge_paths = _load_aiteamforge_paths_module()
    try:
        kanban_dir = aiteamforge_paths.get_team_kanban_dir(team)
    except KeyError as exc:
        raise _UsageError(str(exc)) from None

    config_dir = (Path(kanban_dir) / "config").resolve()
    if not _is_allowed_config_dir(config_dir):
        # Defense in depth: should be unreachable given a well-formed
        # registry, but never silently validate outside kanban/config.
        raise _UsageError(
            f"resolved config dir {config_dir} does not end in "
            f"kanban/config -- refusing"
        )
    return config_dir


def _notify_secret_refs(config: dict) -> list[tuple[str, str]]:
    out = []
    for alias, alias_cfg in sorted(config.get("aliases", {}).items()):
        target = alias_cfg.get("target")
        if isinstance(target, dict) and isinstance(target.get("secretRef"), str):
            out.append((f"$.aliases.{_render_key(alias)}.target.secretRef", target["secretRef"]))
    return out


def _wiki_secret_refs(config: dict) -> list[tuple[str, str]]:
    credential = config.get("credential")
    if isinstance(credential, dict) and isinstance(credential.get("secretRef"), str):
        return [("$.credential.secretRef", credential["secretRef"])]
    return []


def _profile_secret_refs(config: dict) -> list[tuple[str, str]]:
    # release-profile/v1 has no secretRef field -- nothing to resolve-check.
    return []


# (label, relative path parts, validate_fn, secret_ref_fn, explicit_only)
# explicit_only=True means: only included when the caller asked for this
# target specifically (--notify/--wiki/--profile <kind>), never via --all.
def _build_targets(args: argparse.Namespace) -> list[tuple]:
    targets = []
    if args.all:
        targets.append(
            ("notify.json", ("notify.json",), validate_notify_config,
             _notify_secret_refs, False)
        )
        targets.append(
            ("wiki.json", ("wiki.json",), validate_wiki_config,
             _wiki_secret_refs, False)
        )
        for kind in PROFILE_KINDS:
            targets.append((
                f"profiles/{kind}/profile.json",
                ("profiles", kind, "profile.json"),
                validate_profile_config,
                _profile_secret_refs,
                False,
            ))
    elif args.notify:
        targets.append(
            ("notify.json", ("notify.json",), validate_notify_config,
             _notify_secret_refs, True)
        )
    elif args.wiki:
        targets.append(
            ("wiki.json", ("wiki.json",), validate_wiki_config,
             _wiki_secret_refs, True)
        )
    elif args.profile:
        targets.append((
            f"profiles/{args.profile}/profile.json",
            ("profiles", args.profile, "profile.json"),
            validate_profile_config,
            _profile_secret_refs,
            True,
        ))
    return targets


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="kb-release-config-validate",
        description=(
            "Validate a team's release-workflow config (notify.json, "
            "wiki.json, profiles/<kind>/profile.json) against the "
            "release-notify/v1, release-wiki/v1 and release-profile/v1 "
            "schemas. Config is read ONLY from <team kanban>/config/ "
            "(spec § 2.2) -- never any shared or tap path."
        ),
    )
    parser.add_argument("team", help="team id, e.g. academy, ios, android")
    selector = parser.add_mutually_exclusive_group(required=True)
    selector.add_argument("--notify", action="store_true",
                           help="validate notify.json")
    selector.add_argument("--wiki", action="store_true",
                           help="validate wiki.json")
    selector.add_argument("--profile", metavar="KIND", choices=PROFILE_KINDS,
                           help="validate profiles/<KIND>/profile.json")
    selector.add_argument("--all", action="store_true",
                           help="validate every config file present (missing "
                                "files are skipped, not an error)")
    parser.add_argument(
        "--resolve-check", action="store_true",
        help="for each secretRef in a valid config, resolve it and report "
             "resolved/FAILED per field path -- never the resolved value",
    )
    parser.add_argument(
        "--config-dir", metavar="DIR", default=None,
        help="override the team's <kanban>/config dir (tests only; must "
             "end in kanban/config unless %s=1 is set)"
        % _ALLOW_ANY_CONFIG_DIR_ENV_VAR,
    )
    # argparse itself exits 2 on a usage error (missing team, unknown flag,
    # more than one of --notify/--wiki/--profile/--all, ...), matching this
    # CLI's exit-code contract without any extra handling here.
    return parser.parse_args(argv)


def _run(argv: list[str]) -> int:
    args = _parse_args(argv)

    try:
        config_dir = _resolve_config_dir(args.team, args.config_dir)
    except _UsageError as exc:
        print(f"kb-release-config-validate: {exc}", file=sys.stderr)
        return 2

    # XACA-1342-024 (Advisory, folded in): a missing config DIRECTORY is a
    # real error, not "nothing to validate" -- without this, --all against
    # a directory that doesn't exist prints "not present (skipped)" for
    # every target and exits 0, which reads as a pass even though nothing
    # was actually validated. A missing individual FILE under an existing
    # directory keeps the current skip/explicit-only behavior below.
    if not config_dir.is_dir():
        print(
            f"kb-release-config-validate: config directory not found: {config_dir}",
            file=sys.stderr,
        )
        return 1

    had_failure = False
    for label, rel_parts, validate_fn, secret_ref_fn, explicit_only in _build_targets(args):
        path = config_dir.joinpath(*rel_parts)

        if not path.is_file():
            if explicit_only:
                print(f"{label}: not found at {path}", file=sys.stderr)
                had_failure = True
            else:
                print(f"{label}: not present (skipped)")
            continue

        try:
            with open(path, "r", encoding="utf-8") as f:
                config = json.load(f)
        except Exception as exc:  # noqa: BLE001 - deliberately broad
            # (XACA-1342-022): OSError/json.JSONDecodeError alone missed
            # UnicodeDecodeError (invalid UTF-8), RecursionError (deeply
            # nested JSON) and ValueError (an int literal past json's
            # digit-count limit) -- each left main() to propagate a raw
            # traceback. Same redaction discipline as the resolve-check
            # handler below: report only the exception TYPE name, never
            # str(exc) (which for some of these can embed a snippet of the
            # offending content) and never the file's content.
            print(
                f"{label}: could not read/parse config ({type(exc).__name__})",
                file=sys.stderr,
            )
            had_failure = True
            continue

        errors = validate_fn(config)
        if not errors and validate_fn is validate_notify_config:
            # XACA-1399: v2 route ids must exist in the team's merged catalog
            errors = notify_v2_semantic_errors(config, config_dir.parent)
        if errors:
            had_failure = True
            print(f"{label}: INVALID")
            for err in errors:
                print(f"  {err}")
            continue

        print(f"{label}: valid")
        if args.resolve_check:
            for field_path, ref in secret_ref_fn(config):
                try:
                    resolve_secret_ref(ref, args.team)
                except SecretResolutionError as exc:
                    had_failure = True
                    print(f"  resolve-check {field_path}: FAILED: {exc}")
                except Exception as exc:  # noqa: BLE001 - deliberately broad:
                    # an unexpected exception type from resolve_secret_ref
                    # (or anything it calls) is not guaranteed to carry the
                    # same redaction discipline as SecretResolutionError --
                    # a future defect upstream (or in a third-party
                    # dependency) could embed data in str(exc). Left
                    # uncaught, this would propagate past main() and the
                    # interpreter's own unhandled-exception traceback printer
                    # would put that message on real stderr. Never forward
                    # str(exc) here, only the type name, matching the same
                    # pattern _resolve_vault_ref() already uses for its
                    # subprocess.run() call.
                    had_failure = True
                    print(
                        f"  resolve-check {field_path}: FAILED: "
                        f"unexpected error ({type(exc).__name__})"
                    )
                else:
                    print(f"  resolve-check {field_path}: resolved")

    return 1 if had_failure else 0


def main(argv: list[str] | None = None) -> int:
    return _run(sys.argv[1:] if argv is None else argv)


if __name__ == "__main__":
    sys.exit(main())
