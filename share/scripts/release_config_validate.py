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
#   env:<VAR_NAME>                       -- ^[A-Z_][A-Z0-9_]*$
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
# ---------------------------------------------------------------------------
SECRET_REF_PATTERN = r"^(vault:[a-z][a-z0-9-]{0,63}/[a-z][a-z0-9-]{0,63}|env:[A-Z_][A-Z0-9_]*)(?![\s\S])"
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
        for name in ("notify.schema.json", "wiki.schema.json", "profile.schema.json"):
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
    """Validate a notify.json dict against release-notify/v1. § 11.4."""
    return _validate_against_schema(config, _load_schema("notify.schema.json"))


def validate_wiki_config(config: dict) -> list[str]:
    """Validate a wiki.json dict against release-wiki/v1. § 11.5."""
    return _validate_against_schema(config, _load_schema("wiki.schema.json"))


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

VAULT_FETCH_SH = Path(
    os.environ.get(_VAULT_FETCH_SH_OVERRIDE_ENV_VAR)
    or (Path(__file__).resolve().parent.parent / "fleet-monitor" / "client" / "vault-fetch.sh")
)


def resolve_secret_ref(ref: str, team: str) -> str:
    """
    Resolve a validated secretRef to its plaintext value, just-in-time.
    The returned value is intended for the immediate caller only -- never
    log it, print it, or write it to a file.

    Args:
        ref: a secretRef string, either "vault:<engine_slug>/<account_slug>"
             or "env:<VAR_NAME>".
        team: the calling team's id, used to enforce team isolation on
              vault: refs (§ 2.2) -- the vault seals per machine, not per
              team, so this is the enforcement point.

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
            "env:<VAR_NAME> grammar"
        )

    if ref.startswith("env:"):
        return _resolve_env_ref(ref[len("env:"):])

    # ref.startswith("vault:") -- the only other branch SECRET_REF_RE allows.
    path = ref[len("vault:"):]
    engine_slug, _, account_slug = path.partition("/")
    return _resolve_vault_ref(engine_slug, account_slug, team)


def _resolve_env_ref(var_name: str) -> str:
    value = os.environ.get(var_name)
    if not value:
        raise SecretResolutionError(
            f"environment variable '{var_name}' is unset or empty"
        )
    return value


def _resolve_vault_ref(engine_slug: str, account_slug: str, team: str) -> str:
    # Team isolation (§ 2.2): refuse any vault: ref whose account slug does
    # not start with "<team>-". Checked before ever touching vault-fetch.sh.
    prefix = f"{team}-"
    if not account_slug.startswith(prefix):
        raise SecretResolutionError(
            f"refusing cross-team secret: account slug does not start with '{prefix}'"
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
        except (OSError, json.JSONDecodeError) as exc:
            print(
                f"{label}: could not read/parse config ({type(exc).__name__})",
                file=sys.stderr,
            )
            had_failure = True
            continue

        errors = validate_fn(config)
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
