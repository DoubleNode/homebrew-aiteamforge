"""
release_providers.py -- test-providers.json schema + loader/validator (XACA-1347, spec RELEASE-LIFECYCLE 6.4/6.6/7.1/7.2).

Pure module: stdlib only, py3.9-safe. Reads <team kanban>/config/test-providers.json and
validates it against `release-test-providers/v1`. Validation COLLECTS every violation
(never first-only) so a lead fixes the file in one pass.

A missing, unreadable, non-JSON or schema-invalid config each raise ProvidersError with a
DISTINCT named message: a missing config must never look like "no providers".
"""
import json
import os
import re

from release_schema import STAGES

SCHEMA_ID = "release-test-providers/v1"
PARSERS = ("tap", "junit", "jsonl", "line-regex")
KINDS = ("automated", "manual")

_COMMON = {"name", "kind", "envLabel", "optional"}
_AUTOMATED = _COMMON | {"command", "parser", "listCommand", "cwd", "env", "timeoutSec",
                        "perFile", "continueOnFailure", "readOnly", "schedule", "pattern"}
_MANUAL = _COMMON | {"cases", "device", "filter"}
_BOOL_FIELDS = ("perFile", "continueOnFailure", "readOnly", "optional")
_SECRET_KEY = re.compile(r"(KEY|TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|CRED|BEARER|COOKIE|SIGNATURE)", re.IGNORECASE)
# Short words that only count as a WHOLE `_`-delimited token, so PATH / PATTERN / AUTHOR don't trigger
# (XACA-1347-020): GH_PAT, AUTH, BASIC_AUTH, PRIVATE_KEY_PEM, PRIVATE_FOO, DB_PASS, MYSQL_PWD
# (PASSTHROUGH / BYPASS_CACHE / PWDIR stay allowed).
_SECRET_TOKEN = re.compile(r"(?:^|_)(?:PAT|AUTH|PRIVATE|PASS|PWD)(?:_|$)", re.IGNORECASE)
_SECRETREF = re.compile(r"env:[A-Za-z_][A-Za-z0-9_]*")   # used with fullmatch: `$` would accept a trailing newline
_SCHEDULE = re.compile(r"T\+[0-9]+[hm]")             # used with fullmatch; ASCII digits only
_DEVICE_FIELDS = ("required", "description")


class ProvidersError(Exception):
    """Raised by load_providers. `.problems` is the list of individual messages."""

    def __init__(self, problems):
        if isinstance(problems, str):
            problems = [problems]
        self.problems = list(problems)
        Exception.__init__(self, "; ".join(self.problems))


def _nonempty_str(v):
    return isinstance(v, str) and bool(v.strip())


def _bad_relpath(p):
    """Why a repo/kanban-relative path is unacceptable, or None. Rejects absolute and '..'."""
    if not _nonempty_str(p):
        return "must be a non-empty string"
    if any(ord(c) < 32 or ord(c) == 127 for c in p):
        return "must not contain control characters"
    if p.startswith("/") or p.startswith("~") or re.match(r"^[A-Za-z]:[\\/]", p):
        return "must be repo-relative (absolute paths are not allowed)"
    if ".." in re.split(r"[\\/]+", p):
        return "must not contain a '..' segment"
    return None


def _validate_env(where, env, errs):
    if not isinstance(env, dict):
        errs.append("%s: env must be an object" % where)
        return
    for k, v in env.items():
        if isinstance(v, str):
            if _SECRET_KEY.search(str(k)) or _SECRET_TOKEN.search(str(k)):
                errs.append("%s: env.%s looks like a secret but is a literal string; "
                            "secrets MUST be {\"secretRef\": \"env:<NAME>\"}" % (where, k))
        elif isinstance(v, dict):
            ref = v.get("secretRef")
            if set(v.keys()) != {"secretRef"} or not isinstance(ref, str) or not _SECRETREF.fullmatch(ref):
                errs.append("%s: env.%s must be a string or exactly {\"secretRef\": \"env:<NAME>\"}" % (where, k))
        else:
            errs.append("%s: env.%s must be a string or a secretRef object" % (where, k))


def _validate_provider(stage, idx, p, seen, errs):
    where = "stages.%s[%d]" % (stage, idx)
    if not isinstance(p, dict):
        errs.append("%s: provider must be an object" % where)
        return
    name = p.get("name")
    if not _nonempty_str(name):
        errs.append("%s: name must be a non-empty string" % where)
    else:
        where = "stages.%s[%d] (%s)" % (stage, idx, name)
        if name != name.strip() or any(ord(c) < 32 or ord(c) == 127 for c in name):
            errs.append("%s: name must not have leading/trailing whitespace or control characters" % where)
        if "::" in name:
            errs.append("%s: name must not contain '::' (reserved for <provider>::harness)" % where)
        if name in seen:
            errs.append("%s: duplicate provider name '%s' within stage %s" % (where, name, stage))
        seen.add(name)
    kind = p.get("kind")
    if kind not in KINDS:
        errs.append("%s: kind must be one of %s" % (where, list(KINDS)))
        return
    allowed = _AUTOMATED if kind == "automated" else _MANUAL
    for f in sorted(p):
        if f not in allowed:
            if kind == "manual" and f in _AUTOMATED:
                errs.append("%s: field '%s' is forbidden on a manual provider" % (where, f))
            else:
                errs.append("%s: unknown field '%s'" % (where, f))
    if not _nonempty_str(p.get("envLabel")):
        errs.append("%s: envLabel is required and must be a non-empty string" % where)
    for f in _BOOL_FIELDS:
        if f in p and not isinstance(p[f], bool):
            errs.append("%s: %s must be a boolean" % (where, f))

    if kind == "automated":
        if not _nonempty_str(p.get("command")):
            errs.append("%s: command is required (non-empty string)" % where)
        if not _nonempty_str(p.get("listCommand")):
            errs.append("%s: listCommand is required (automated providers MUST be able to list their tests)" % where)
        parser = p.get("parser")
        if parser not in PARSERS:
            errs.append("%s: parser is required and must be one of %s" % (where, list(PARSERS)))
        if parser == "line-regex":
            pat = p.get("pattern")
            if not isinstance(pat, str) or not pat:
                errs.append("%s: parser 'line-regex' requires a pattern string" % where)
            else:
                try:
                    groups = re.compile(pat).groupindex
                except re.error as e:
                    errs.append("%s: pattern does not compile: %s" % (where, e))
                else:
                    for g in ("test", "result"):
                        if g not in groups:
                            errs.append("%s: pattern must define a named group '%s'" % (where, g))
        elif "pattern" in p:
            errs.append("%s: pattern is only allowed with parser 'line-regex'" % where)
        if "cwd" in p:
            why = _bad_relpath(p["cwd"])
            if why:
                errs.append("%s: cwd %s" % (where, why))
        if "env" in p:
            _validate_env(where, p["env"], errs)
        if "timeoutSec" in p:
            t = p["timeoutSec"]
            if isinstance(t, bool) or not isinstance(t, int) or t <= 0:
                errs.append("%s: timeoutSec must be a positive integer" % where)
        if "schedule" in p:
            s = p["schedule"]
            if stage != "GAMMA":
                errs.append("%s: schedule is only allowed in GAMMA" % where)
            if not isinstance(s, list) or not s or not all(isinstance(x, str) and _SCHEDULE.fullmatch(x) for x in s):
                errs.append("%s: schedule must be a non-empty list of \"T+<n>h\" / \"T+<n>m\"" % where)
        if stage == "GAMMA" and p.get("readOnly") is not True:
            errs.append("%s: every automated provider in GAMMA MUST set readOnly: true" % where)
    else:
        why = _bad_relpath(p.get("cases")) if "cases" in p else "is required"
        if why:
            errs.append("%s: cases %s" % (where, why))
        dev = p.get("device")
        if not isinstance(dev, dict):
            errs.append("%s: device is required and must be an object {required, description}" % where)
        else:
            for f in sorted(dev):
                if f not in _DEVICE_FIELDS:
                    errs.append("%s: unknown device field '%s'" % (where, f))
            if not isinstance(dev.get("required"), bool):
                errs.append("%s: device.required must be a boolean" % where)
            if not isinstance(dev.get("description"), str):
                errs.append("%s: device.description must be a string" % where)
        if "filter" in p and p["filter"] != "prodSafe":
            errs.append("%s: filter may only be \"prodSafe\"" % where)
        if stage == "GAMMA" and p.get("filter") != "prodSafe":
            errs.append("%s: every manual provider in GAMMA MUST set filter: \"prodSafe\"" % where)


def validate_providers(doc):
    """Return a list of problems with a parsed test-providers document ([] = valid)."""
    if not isinstance(doc, dict):
        return ["document must be a JSON object"]
    errs = []
    if doc.get("$schema") != SCHEMA_ID:
        errs.append("$schema must be %r (got %r)" % (SCHEMA_ID, doc.get("$schema")))
    for k in sorted(doc):
        if k not in ("$schema", "stages"):
            errs.append("unknown top-level key: %s" % k)
    stages = doc.get("stages")
    if not isinstance(stages, dict):
        errs.append("stages must be an object keyed by stage name")
        return errs
    for stage, plist in stages.items():
        if stage not in STAGES:
            errs.append("unknown stage '%s' (must be one of %s)" % (stage, list(STAGES)))
            continue
        if not isinstance(plist, list):
            errs.append("stages.%s must be a list of providers" % stage)
            continue
        seen = set()
        for i, p in enumerate(plist):
            _validate_provider(stage, i, p, seen, errs)
    return errs


def _no_dup_keys(pairs):
    """A duplicated key is ambiguous (json keeps the LAST) and could hide e.g. readOnly:false."""
    out = {}
    for k, v in pairs:
        if k in out:
            raise ValueError("duplicate JSON key %r" % k)
        out[k] = v
    return out


def load_providers(path):
    """Read + validate a test-providers.json. Raises ProvidersError (distinct message per cause)."""
    path = str(path)
    if not os.path.exists(path):
        raise ProvidersError("test-providers config not found: %s (a missing config is NOT "
                             "'no providers'; create it per spec 7.1)" % path)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError) as e:
        raise ProvidersError("test-providers config unreadable: %s (%s)" % (path, e))
    try:
        doc = json.loads(text, object_pairs_hook=_no_dup_keys)
    except ValueError as e:
        raise ProvidersError("test-providers config is not valid JSON: %s (%s); the file is strict "
                             "JSON - no // comments, no trailing commas (the spec's jsonc example "
                             "is illustrative only)" % (path, e))
    problems = validate_providers(doc)
    if problems:
        raise ProvidersError(["test-providers config failed schema validation (%s):" % path] + problems)
    return doc


def providers_for_stage(doc, stage):
    """Providers declared for `stage` ([] when none). Expects a validated doc."""
    stages = doc.get("stages") if isinstance(doc, dict) else None
    plist = stages.get(stage) if isinstance(stages, dict) else None
    return list(plist) if isinstance(plist, list) else []
