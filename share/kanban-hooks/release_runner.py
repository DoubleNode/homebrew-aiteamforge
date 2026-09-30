"""
release_runner.py -- stage test runner library (XACA-1347-002/004, spec RELEASE-LIFECYCLE 6.4/7.1/7.2).

Stdlib only, py3.9-safe. NO board access: this library never touches kanban JSON. It returns
plain data ({"expected", "records", "problems"}); the caller POSTs it to
/api/releases/<id>/stages/<STAGE>/tests, the ONE sanctioned writer of stages.<S>.expected and
tests[]. Records here are PROTO records (local `ref` / `parentRef`, no id/parent/supersededBy);
the server assigns ids (T0001...) and maps refs.

Order of operations in run_stage (spec 7.2, with one deliberate swap, see "Ambiguity"):
  1. GAMMA enforcement (defence in depth; the provider validator checks it too): refuse, run
     NOTHING, if a GAMMA automated provider lacks readOnly is True or a GAMMA manual provider
     lacks filter == "prodSafe".
  2. verify_stage_sha: git checkout --detach stageSha[STAGE], HEAD must equal it, tree must be clean.
  3. build the expected set (listCommand / cases) -- AFTER the checkout, because a listCommand
     reads code that only exists at the stage SHA.
  4. run AUTOMATED providers (manual providers contribute to expected only; the walkthrough is
     a separate flow) and parse into records.
Ambiguity resolved: spec 7.2 lists "build expected" before "checkout"; listing the wrong tree
would store a wrong expected set, so checkout comes first.

Why shlex.split and never shell=True: provider commands come from a per-team config file;
shell=True would make env values, test ids (perFile) and secrets shell-injectable.

perFile: the command is run once per expected test id. The literal token "{file}" inside any
argv element is replaced by the id (a plain str.replace AFTER shlex.split, so ids with spaces
or quotes stay one argument). A perFile command with no "{file}" is a FAIL (harness), never
run blind. continueOnFailure defaults to True when absent; an explicit False stops that
provider after its first FAIL and the unrun files simply get NO record (the gate treats a
missing record as failing -- nothing is fabricated).
A single perFile run that times out / exits nonzero FAILs that file's own record (it IS the
expected test); a provider that cannot start at all (OSError) or whose listCommand fails
records `<provider>::harness` (spec 7.2.4).

Secrets: env values {"secretRef": "env:NAME"} resolve from os.environ. Missing/blank -> harness
FAIL for that provider, it is NOT run. Values are never logged; any provider output copied into
notes is tail-truncated and has resolved secret values replaced by "***".

Scheduled providers (`schedule`, GAMMA soak): they join the expected set (so the gate cannot pass
before they run) but are NOT run by run_stage unless include_scheduled=True.

No "intentionallyEmpty" is ever produced or sent (XACA-1347-008): the provider schema has no way to
declare a stage intentionally empty, a missing/empty provider set must never read as "passed", and
the /tests endpoint refuses that field with a 400.

Manual case-file format (load_cases): markdown.

    ## ALPHA-01: Sign in with email        <- "## <ID>: <title>"; ID has no spaces
    - prodSafe: true                         <- true|false (default false)
    - preconditions: Fresh install, test account exists
    - steps:
      1. Open the app
      2. Tap Sign in                         <- "N. x", "N) x", "- x" or "* x", indented or not
    - expected: Home screen appears          <- continuation lines (indented) extend a value

Text before the first heading is ignored. Unknown keys, a missing title, a bad prodSafe value
and duplicate IDs raise RunnerError. The expected test name for a case is "<ID> <title>".
"""
import collections
import datetime
import json
import os
import re
import shlex
import subprocess
from xml.sax.saxutils import escape as _xml_escape

from release_parsers import CHILD_SEP, grade_parent, harness_fail, parse  # noqa: F401  (CHILD_SEP re-exported)

DEFAULT_TIMEOUT_SEC = 900
LIST_TIMEOUT_SEC = 120
_SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")
_SECRETREF = re.compile(r"^env:([A-Za-z_][A-Za-z0-9_]*)$")
_GIT_ENV_SCRUB = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR")
_CASE_KEYS = ("prodSafe", "preconditions", "steps", "expected")
_HEADING = re.compile(r"^##\s+(\S+?):\s*(.+?)\s*$")
_KEYLINE = re.compile(r"^[-*]\s+([A-Za-z]+):\s*(.*)$")
_STEPLINE = re.compile(r"^\s*(?:\d+[.)]|[-*])\s+(.*)$")


class RunnerError(Exception):
    """A named refusal (bad SHA, dirty tree, GAMMA safety, unreadable case file)."""


# --------------------------------------------------------------------- helpers
def _git_env():
    return {k: v for k, v in os.environ.items() if k not in _GIT_ENV_SCRUB}


def _git(run, repo_dir, *args):
    try:
        cp = run(["git", "-C", str(repo_dir)] + list(args), stdin=subprocess.DEVNULL,
                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
                 env=_git_env())
    except (OSError, subprocess.SubprocessError) as e:
        raise RunnerError("git %s could not run: %s" % (args[0], e))
    if cp.returncode != 0:
        raise RunnerError("git %s failed (exit %s): %s" % (" ".join(args), cp.returncode,
                                                            (cp.stderr or "").strip()[-300:]))
    return (cp.stdout or "").strip()


def verify_stage_sha(repo_dir, sha, *, checkout=True, run=subprocess.run):
    """Check out (detached) and verify `sha`; return the verified HEAD. RunnerError otherwise.

    Refuses: sha not 40-hex; dirty tree (`git status --porcelain` non-empty -- never test
    uncommitted code); HEAD != sha after the checkout (full 40-hex compare, case-insensitive).
    The dirty check runs BEFORE the checkout so a refused run changes nothing.
    """
    if not isinstance(sha, str) or not _SHA_RE.match(sha):
        raise RunnerError("stage SHA must be a full 40-hex commit id (got %r)" % (sha,))
    if _git(run, repo_dir, "status", "--porcelain"):
        raise RunnerError("working tree at %s is dirty; refusing to test uncommitted code" % repo_dir)
    if checkout:
        _git(run, repo_dir, "checkout", "--detach", sha)
    head = _git(run, repo_dir, "rev-parse", "HEAD")
    if head.lower() != sha.lower():
        raise RunnerError("HEAD %s != stage SHA %s; refusing to run" % (head, sha))
    return head


def load_cases(path):
    """Parse a manual case file (format in the module docstring) -> list of case dicts
    {id, title, preconditions, steps[list], expected, prodSafe(bool)}."""
    try:
        with open(str(path), "r", encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except (OSError, UnicodeDecodeError) as e:
        raise RunnerError("case file unreadable: %s (%s)" % (path, e))
    cases, cur, key, seen = [], None, None, set()

    def _close():
        if cur is not None:
            cur["preconditions"] = cur["preconditions"].strip()
            cur["expected"] = cur["expected"].strip()
            cases.append(cur)

    for n, line in enumerate(lines, 1):
        h = _HEADING.match(line)
        if h:
            _close()
            if h.group(1) in seen:
                raise RunnerError("%s:%d: duplicate case id %s" % (path, n, h.group(1)))
            seen.add(h.group(1))
            cur = {"id": h.group(1), "title": h.group(2), "preconditions": "", "steps": [],
                   "expected": "", "prodSafe": False}
            key = None
            continue
        if line.startswith("## "):
            raise RunnerError("%s:%d: case heading must be '## <ID>: <title>'" % (path, n))
        if cur is None or not line.strip():
            continue
        k = _KEYLINE.match(line)
        if k:
            key, val = k.group(1), k.group(2).strip()
            if key not in _CASE_KEYS:
                raise RunnerError("%s:%d: unknown case key '%s' (allowed: %s)" % (path, n, key, list(_CASE_KEYS)))
            if key == "prodSafe":
                if val.lower() not in ("true", "false"):
                    raise RunnerError("%s:%d: prodSafe must be true or false" % (path, n))
                cur["prodSafe"] = val.lower() == "true"
            elif key == "steps":
                if val:
                    cur["steps"].append(val)
            else:
                cur[key] = val
            continue
        if key == "steps":
            s = _STEPLINE.match(line)
            cur["steps"].append(s.group(1).strip() if s else line.strip())
        elif key in ("preconditions", "expected"):
            cur[key] = (cur[key] + " " + line.strip()).strip()
    _close()
    return cases


def _under(base, rel, what):
    """Resolve `rel` under `base`; RunnerError if it escapes (symlink / '..')."""
    root = os.path.realpath(str(base))
    full = os.path.realpath(os.path.join(root, rel))
    if full != root and not full.startswith(root + os.sep):
        raise RunnerError("%s '%s' resolves outside %s" % (what, rel, base))
    return full


def _resolve_env(provider, environ):
    """-> (env dict for the child, [names of missing secrets]). Never returns secret values in messages."""
    env = dict(environ)
    missing, secrets = [], []
    for k, v in (provider.get("env") or {}).items():
        if isinstance(v, dict):
            m = _SECRETREF.match(str(v.get("secretRef", "")))
            name = m.group(1) if m else None
            val = environ.get(name) if name else None
            if not val:
                missing.append(name or str(v.get("secretRef")))
                continue
            env[k] = val
            secrets.append(val)
        else:
            env[k] = str(v)
    return env, missing, secrets


def _secret_forms(secrets):
    """Every spelling of each secret that can reach our text: verbatim, JSON-escaped (a multi-line value
    printed by a jsonl provider) and XML-escaped (junit), plus each line of a multi-line value on its own
    (output that prints the lines apart). Longest first, so a full value is replaced before its fragments."""
    forms = set()
    for s in secrets:
        if not s:
            continue
        parts = [s]
        if "\n" in s or "\r" in s:
            parts += [ln.strip() for ln in s.splitlines() if len(ln.strip()) >= 4]
        for part in parts:
            forms.add(part)
            forms.add(json.dumps(part)[1:-1])
            forms.add(_xml_escape(part, {'"': "&quot;", "'": "&apos;"}))
    return sorted((f for f in forms if f), key=len, reverse=True)


def _scrub(text, secrets):
    for f in _secret_forms(secrets):
        text = text.replace(f, "***")
    return text


def _redact(text, secrets, n=300):
    """Scrub FIRST, truncate second: a tail window that starts inside a secret would otherwise leave the
    unmatched remainder of the value in the note."""
    return _scrub((text or "").strip(), secrets)[-n:]


def _exec(run, argv, cwd, env, timeout, secrets=()):
    """-> (exit_code|None, stdout, stderr, timed_out, os_error|None). Output is scrubbed of `secrets` HERE,
    at the source, so parsed notes, test names and listed ids can never carry a resolved secret."""
    try:
        cp = run(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                 stderr=subprocess.PIPE, universal_newlines=True, errors="replace", timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "", "", True, None
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        return None, "", "", False, _scrub(str(e), secrets)
    return cp.returncode, _scrub(cp.stdout or "", secrets), _scrub(cp.stderr or "", secrets), False, None


def _harness(provider):
    return "%s::harness" % provider["name"]


def _entry(name, optional):
    return {"test": name, "optional": True} if optional else name


def _provider_cwd(provider, repo_dir):
    return _under(repo_dir, provider.get("cwd") or ".", "cwd")


def _automated_expected(p, repo_dir, environ, run, list_timeout):
    """-> (test ids, problem|None) from listCommand. Empty/failed is a PROBLEM, never an empty set."""
    try:
        cwd = _provider_cwd(p, repo_dir)
        argv = shlex.split(p["listCommand"])
    except (RunnerError, ValueError) as e:
        return [], "listCommand could not be prepared: %s" % e
    env, missing, secrets = _resolve_env(p, environ)
    if missing:
        return [], "listCommand not run: secret env var(s) not set: %s" % ", ".join(missing)
    if not argv:
        return [], "listCommand is empty"
    code, out, err, timed, oserr = _exec(run, argv, cwd, env, list_timeout, secrets)
    if oserr:
        return [], "listCommand could not start: %s" % _redact(oserr, secrets)
    if timed:
        return [], "listCommand timed out after %ss" % list_timeout
    if code != 0:
        return [], "listCommand exited %s: %s" % (code, _redact(err, secrets))
    ids = []
    for line in out.splitlines():
        line = line.strip()
        if line and line not in ids:
            ids.append(line)
    if not ids:
        return [], "listCommand printed no test ids (an empty expected set is never silent)"
    if p.get("perFile"):
        # A perFile id becomes an argv element. One starting with '-' would be read by the test command
        # as a FLAG (argument injection), so the whole list is refused: harness FAIL, nothing is run.
        dashed = [i for i in ids if i.startswith("-")]
        if dashed:
            return [], ("listCommand printed test id(s) starting with '-' (would be read as a command-line "
                        "flag by the perFile command): %s" % ", ".join(repr(i) for i in dashed[:5]))
    return ids, None


def _manual_expected(p, kanban_dir):
    try:
        cases = load_cases(_under(kanban_dir, p["cases"], "cases"))
    except RunnerError as e:
        return [], str(e)
    if p.get("filter") == "prodSafe":
        cases = [c for c in cases if c["prodSafe"]]
    if not cases:
        return [], "case file yields no cases%s" % (" after the prodSafe filter" if p.get("filter") == "prodSafe" else "")
    return ["%s %s" % (c["id"], c["title"]) for c in cases], None


def _provider_expected(p, repo_dir, kanban_dir, environ, run, list_timeout):
    if p.get("kind") == "manual":
        return _manual_expected(p, kanban_dir)
    return _automated_expected(p, repo_dir, environ, run, list_timeout)


def build_expected(providers, *, repo_dir, kanban_dir, run=subprocess.run, environ=None,
                   list_timeout=LIST_TIMEOUT_SEC):
    """Spec 7.2.1 -> (expected_list, problems).

    expected_list entries are a str, or {"test", "optional": True} when the provider is optional
    (the shape release_gate._norm_expected reads). A provider whose list/cases cannot be produced
    adds a human-readable problem AND the plain (never optional) `<provider>::harness` entry, so
    the gate cannot pass on an empty set.
    """
    environ = os.environ if environ is None else environ
    return _assemble(_disjoint([(p,) + _provider_expected(p, repo_dir, kanban_dir, environ, run, list_timeout)
                                for p in providers]))


def check_gamma(stage, providers):
    """Refuse (RunnerError) unless every GAMMA provider is production-safe. No-op for other stages."""
    if stage != "GAMMA":
        return
    bad = []
    for p in providers:
        if p.get("kind") == "manual":
            if p.get("filter") != "prodSafe":
                bad.append("%s (manual: filter must be 'prodSafe')" % p.get("name"))
        elif p.get("readOnly") is not True:
            bad.append("%s (automated: readOnly must be true)" % p.get("name"))
    if bad:
        raise RunnerError("GAMMA runs against production; refusing to run anything. Unsafe provider(s): "
                          + "; ".join(bad))


def _iso(now):
    v = now() if callable(now) else now
    if isinstance(v, datetime.datetime):
        if v.tzinfo is not None:
            v = v.astimezone(datetime.timezone.utc).replace(tzinfo=None)
        return v.strftime("%Y-%m-%dT%H:%M:%SZ")
    if isinstance(v, str) and v:
        return v
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


class _Records(object):
    """Accumulates proto records with local refs r1, r2, ..."""

    def __init__(self, stage, sha, ts):
        self.stage, self.sha, self.ts, self.items = stage, sha, ts, []
        self.names = set()          # every record name already written (run-wide uniqueness, XACA-1347-030)

    def add(self, test, result, notes, env, parent_ref=None):
        self.names.add(test)
        ref = "r%d" % (len(self.items) + 1)
        self.items.append({"ref": ref, "parentRef": parent_ref, "stage": self.stage, "type": "Automated",
                           "ts": self.ts, "env": env, "sha": self.sha, "test": test, "result": result,
                           "runBy": "pipeline", "notes": notes or ""})
        return ref

    def proto(self, proto, env, parent_ref=None):
        ref = self.add(proto["test"], proto["result"], proto["notes"], env, parent_ref)
        for c in proto.get("children") or []:
            self.add(c["test"], c["result"], c["notes"], env, ref)
        return ref


def _name_problems(pname, names, owner, seen, *, top_own=None):
    """Names a provider may NOT emit -> ["<name> (<why>)"] ([] = fine). The gate grades the LATEST record
    per test name, so a name that is another provider's, a harness name or one already recorded lets a
    later PASS mask an earlier FAIL (XACA-1347-030/-032/-033). Checked per name, first hit wins:
      * `*::harness` is reserved: only the runner writes those;
      * a name listed by ANOTHER provider (`owner`) is foreign;
      * `top_own` (a set, or None to skip): the name must be one of the provider's own listed ids;
      * a name already recorded this run (`seen`) or repeated in this batch is a duplicate."""
    bad, local = [], set()
    for n in names:
        if n.endswith("::harness"):
            why = "reserved for harness records"
        elif owner.get(n, pname) != pname:
            why = "listed by provider '%s'" % owner[n]
        elif top_own is not None and n not in top_own:
            why = "not one of this provider's listed ids"
        elif n in seen or n in local:
            why = "emitted more than once in this run"
        else:
            why = None
        if why:
            bad.append("%s (%s)" % (n, why))
        local.add(n)
    return bad


def _violation_note(bad):
    return ("provider output used test names it does not own or repeated a name (%d); none of it was recorded: %s%s"
            % (len(bad), "; ".join(bad[:5]), " ..." if len(bad) > 5 else ""))


def _proto_names(proto):
    return [c["test"] for c in proto.get("children") or []]


def _run_provider(p, rec, names, repo_dir, environ, run, owner):
    """Run one automated provider into `rec`; return True if a harness FAIL was written."""
    env_label, name = p["envLabel"], p["name"]
    hname = _harness(p)
    timeout = p.get("timeoutSec") or DEFAULT_TIMEOUT_SEC
    env, missing, secrets = _resolve_env(p, environ)
    if missing:
        rec.add(hname, "FAIL", "secret env var(s) not set: %s; provider not run" % ", ".join(missing), env_label)
        return True
    try:
        cwd = _provider_cwd(p, repo_dir)
        base = shlex.split(p["command"])
    except (RunnerError, ValueError) as e:
        rec.add(hname, "FAIL", "command could not be prepared: %s" % e, env_label)
        return True
    if not base:
        rec.add(hname, "FAIL", "command is empty", env_label)
        return True
    parser, pattern = p["parser"], p.get("pattern")

    if not p.get("perFile"):
        code, out, err, timed, oserr = _exec(run, base, cwd, env, timeout, secrets)
        if oserr:
            rec.add(hname, "FAIL", "command could not start: %s" % _redact(oserr, secrets), env_label)
            return True
        if timed:
            rec.add(hname, "FAIL", "timed out after %ss" % timeout, env_label)
            return True
        pr = parse(parser, out, pattern=pattern)
        g, gnotes = grade_parent(code, pr)
        tail = _redact(err, secrets)
        if pr.error or not pr.results:
            rec.add(hname, "FAIL", gnotes + (" | stderr: " + tail if tail else ""), env_label)
            return True
        # Ownership + run-wide uniqueness (XACA-1347-030): top-level names must be this provider's own
        # listed ids; child names must not be foreign/harness/duplicate. A violation drops EVERYTHING this
        # provider parsed (its expected entries then have no record: missing != passing).
        bad = _name_problems(name, [r["test"] for r in pr.results], owner, rec.names, top_own=set(names))
        bad += _name_problems(name, [c for r in pr.results for c in _proto_names(r)], owner,
                              rec.names | {r["test"] for r in pr.results})
        if bad:
            rec.add(hname, "FAIL", _violation_note(bad), env_label)
            return True
        for proto in pr.results:
            rec.proto(proto, env_label)
        has_fail = any(r["result"] == "FAIL" or any(c["result"] == "FAIL" for c in r["children"])
                       for r in pr.results)
        if g == "FAIL" and not has_fail:  # e.g. nonzero exit with nothing failing in the output
            rec.add(hname, "FAIL", gnotes + (" | stderr: " + tail if tail else ""), env_label)
            return True
        return False

    if not any("{file}" in a for a in base):
        rec.add(hname, "FAIL", "perFile provider command has no {file} token; refusing to run it blind", env_label)
        return True
    violations = []
    for fid in names:
        argv = [a.replace("{file}", fid) for a in base]
        code, out, err, timed, oserr = _exec(run, argv, cwd, env, timeout, secrets)
        if oserr:
            rec.add(hname, "FAIL", "command could not start: %s" % _redact(oserr, secrets), env_label)
            return True
        pr = parse(parser, out, default_test=fid, pattern=pattern)
        g, gnotes = grade_parent(code, pr, timed_out=timed)
        if timed:
            gnotes = "timed out after %ss" % timeout
        if g == "FAIL" and not timed and code not in (0, None):
            tail = _redact(err, secrets)
            if tail:
                gnotes += " | stderr: " + tail
        rows, bad = _per_file_rows(fid, pr.results, name, owner, rec.names)
        if bad:
            # Scope: THIS file run only. Its parent record is not written either (a PASS parent over
            # dropped children would be a lie), so `fid` has no record and the gate fails it as missing.
            # Other files are separate processes with their own expected ids; their results stand.
            violations.append("%s: %s" % (fid, "; ".join(bad[:5])))
        else:
            parent_ref = rec.add(fid, g, gnotes, env_label)
            for t, r, n in rows:
                rec.add(t, r, n, env_label, parent_ref)
        if g == "FAIL" and p.get("continueOnFailure") is False:
            break
    if violations:
        rec.add(hname, "FAIL", _violation_note(violations), env_label)   # ONE harness record per provider
        return True
    return False


def _per_file_rows(fid, protos, pname, owner, seen):
    """-> ([(test, result, notes)] all direct children of `fid`, [violations]).
    A proto named `fid` contributes its children. Any other top-level name (a JUnit suite name, a TAP/JSONL
    parent) is namespaced under the file, `fid > name` (+ `fid > name > child`), so it can never equal a
    name another provider or file owns; but a top-level name that IS an id someone owns (any provider,
    this one included) or a harness name is a violation, not something to quietly re-home."""
    rows, raw, bad = [], [], []
    for pr in protos:
        t = pr["test"]
        if t == fid:
            for c in pr["children"]:
                rows.append((c["test"], c["result"], c["notes"]))
        else:
            if t in owner or t.endswith("::harness"):
                bad.append("%s (top-level name is not this file's id '%s')" % (t, fid))
            rows.append((fid + CHILD_SEP + t, pr["result"], pr["notes"]))
            for c in pr["children"]:
                rows.append((fid + CHILD_SEP + c["test"], c["result"], c["notes"]))
    bad += _name_problems(pname, [r[0] for r in rows], owner, seen)
    return rows, bad


def run_stage(release, stage, providers, *, repo_dir, kanban_dir, env_label_default=None,
              now=None, run=subprocess.run, environ=None, verify=verify_stage_sha,
              include_scheduled=False, list_timeout=LIST_TIMEOUT_SEC):
    """Verify the stage SHA, build the expected set, run AUTOMATED providers.

    Returns {"expected": [...], "records": [proto...], "problems": [...]}.
    Raises RunnerError (nothing run) on a GAMMA safety violation, a missing/invalid stageSha, a dirty
    tree or HEAD mismatch. `verify` is injectable for tests; `run` is used for providers.
    """
    check_gamma(stage, providers)
    sha = (release.get("stageSha") or {}).get(stage)
    if not sha:
        raise RunnerError("release has no stageSha.%s; nothing to verify or run against" % stage)
    verify(repo_dir, sha)
    environ = os.environ if environ is None else environ
    ts = _iso(now if now is not None else datetime.datetime.utcnow)
    rec = _Records(stage, sha, ts)
    per_provider = _disjoint([(p,) + _provider_expected(p, repo_dir, kanban_dir, environ, run, list_timeout)
                              for p in providers])
    expected, problems = _assemble(per_provider)
    owner = {n: p.get("name") for p, names, problem in per_provider if not problem for n in names}
    for p, names, problem in per_provider:
        if not p.get("envLabel") and env_label_default:
            p = dict(p, envLabel=env_label_default)
        if problem:  # automated AND manual: the reason must reach the board, not only this process's stderr
            rec.add(_harness(p), "FAIL", problem, p["envLabel"])
            continue
        if p.get("kind") == "manual":
            continue
        if p.get("schedule") and not include_scheduled:
            continue
        if _run_provider(p, rec, names, repo_dir, environ, run, owner):
            h = _harness(p)
            if h not in expected:
                expected.append(h)
    counts = collections.Counter(r["test"] for r in rec.items if not r["test"].endswith("::harness"))
    dup = sorted(n for n, c in counts.items() if c > 1)
    if dup:   # defence in depth: the per-provider checks should make this unreachable
        raise RunnerError("internal inconsistency: duplicate test name(s) in the run's records: %s; nothing posted"
                          % ", ".join(dup[:5]))
    return {"expected": expected, "records": rec.items, "problems": problems}


def _disjoint(per_provider):
    """Make the providers' test ids disjoint. The gate reads the LATEST record per test name, so a name
    produced by two providers lets a later PASS overwrite an earlier FAIL (for manual cases: one answer
    satisfies both). A provider whose ids collide with an earlier provider's, or with any provider's
    `<name>::harness` record, contributes NOTHING and becomes a problem (-> its own harness FAIL)."""
    reserved = {_harness(p) for p, _n, _pr in per_provider}
    owner, out = {}, []
    for p, names, problem in per_provider:
        if not problem:
            clash = [n for n in names if n in reserved]
            dup = [n for n in names if n in owner]
            if clash:
                problem = "test id(s) %s are reserved for harness records; rename them" % ", ".join(clash)
            elif dup:
                problem = ("test id(s) also listed by provider '%s': %s; ids must be unique across providers"
                           % (owner[dup[0]], ", ".join(dup)))
        if problem:
            names = []
        else:
            for n in names:
                owner[n] = p.get("name")
        out.append((p, names, problem))
    return out


def _assemble(per_provider):
    expected, problems = [], []
    for p, names, problem in per_provider:
        if problem:
            problems.append("%s: %s" % (p.get("name"), problem))
            entry = _harness(p)
            if entry not in expected:
                expected.append(entry)
            continue
        for n in names:
            e = _entry(n, p.get("optional") is True)
            if e not in expected:
                expected.append(e)
    return expected, problems
