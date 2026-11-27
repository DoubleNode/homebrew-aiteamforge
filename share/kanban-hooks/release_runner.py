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

Interpreter preflight (XACA-1800): a provider whose command is `<python> [flags] -m <module> ...` (e.g. `python3 -m
pytest {file}`) is checked ONCE, before anything is listed or run: its interpreter must `import <module>` plus every
name in the provider's optional `requires` list. Resolution order: $AITEAMFORGE_TEST_PYTHON (an explicit override:
it is the only candidate, a failing override is never fallen past); else a token containing '/' is the only
candidate; else every `<token>` on the provider env's PATH, in PATH order, and the FIRST that passes wins and is
substituted for the token. If no candidate passes, run_stage raises PreflightError (a RunnerError): nothing is
recorded and nothing is posted. Why not one `<provider>::harness` FAIL: a harness id enters the stage's expected set
and the server's add-only lock (XACA-1628) keeps it there; a machine fault is not a fact about the code, so it must
not land on the release at all. Commands that are not `python -m` are not probed (an unrunnable binary already fails
once, on the first file, as an OSError harness FAIL).

pytest exit 5 (XACA-1800-004): pytest exits 5 when it collected no tests, which is ALSO what a module-level skip
(`pytest.importorskip` with the dependency missing) looks like. A perFile file of a `-m pytest` provider is graded
SKIP only on positive evidence: exit 5, pytest's own final summary says ONLY "<n> skipped" (warnings allowed), the
output parsed, and no parsed row is anything but SKIP. Every other exit-5 shape ("no tests ran", empty output, an
error or failure in the summary, any non-SKIP row) stays FAIL. A SKIP is not a pass: the gate fails a non-optional
SKIP until a lead waives it; the record now says why the file did not run instead of blaming the code.

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


TEST_PYTHON_ENV = "AITEAMFORGE_TEST_PYTHON"
PREFLIGHT_TIMEOUT_SEC = 60
_PYTHON_TOKEN = re.compile(r"^python[0-9]*(?:\.[0-9]+)*$")
MODULE_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*")   # fullmatch: it becomes code
# pytest's closing line, e.g. "==== 1 skipped in 0.01s ====" or "=== 2 skipped, 1 warning in 0.3s (0:00:00) ==="
_PYTEST_SUMMARY = re.compile(r"^=+ (?P<body>.+?) in [0-9.]+s(?: \([^)]*\))? =+$")
_SUMMARY_PART = re.compile(r"^(?P<n>[0-9]+) (?P<what>[a-z]+)$")


class RunnerError(Exception):
    """A named refusal (bad SHA, dirty tree, GAMMA safety, unreadable case file)."""


class PreflightError(RunnerError):
    """XACA-1800: the machine cannot run a provider (its interpreter lacks a module). Nothing runs, nothing is posted."""


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


_HARNESS_RESOLVED = "harness OK: %s at this SHA; resolves the earlier harness record in the expected set (XACA-1628)"


def _recorded_harness_ids(recorded):
    """`<name>::harness` names in a stored expected set ([str | {test, optional}] or None)."""
    out = set()
    for e in recorded if isinstance(recorded, (list, tuple)) else []:
        n = e.get("test") if isinstance(e, dict) else e
        if isinstance(n, str) and n.endswith("::harness"):
            out.add(n)
    return out


def _entry(name, optional):
    return {"test": name, "optional": True} if optional else name


def _provider_cwd(provider, repo_dir):
    return _under(repo_dir, provider.get("cwd") or ".", "cwd")


# --------------------------------------------------------------------- interpreter preflight (XACA-1800)
def python_module_command(argv):
    """`[python3, -u, -m, pytest, ...]` -> (0, "pytest"); None when argv is not `<python> [flags] -m <module>`.
    Only leading single-token flags are skipped; a flag that takes a value (-W x, -X y) ends the scan, so the
    command is then simply not probed (never mis-probed)."""
    if not argv or not _PYTHON_TOKEN.match(os.path.basename(argv[0])):
        return None
    for i in range(1, len(argv)):
        a = argv[i]
        if a == "-m":
            mod = argv[i + 1] if i + 1 < len(argv) else ""
            return (0, mod) if MODULE_NAME.fullmatch(mod) else None
        if not a.startswith("-") or a in ("-W", "-X", "-c") or a.startswith("--"):
            return None
    return None


def _interpreter_candidates(token, env, cwd):
    """-> ([(path, origin)], problem|None). See the module docstring for the order."""
    override = (env.get(TEST_PYTHON_ENV) or "").strip()
    if override:
        if not os.path.isabs(override):
            return [], "%s=%r must be an absolute path" % (TEST_PYTHON_ENV, override)
        return [(override, "$%s" % TEST_PYTHON_ENV)], None
    if "/" in token:
        return [(token if os.path.isabs(token) else os.path.join(cwd, token), "the command")], None
    out, seen = [], set()
    for d in (env.get("PATH") or "").split(os.pathsep):
        if not d or not os.path.isabs(d):
            continue   # an empty or relative PATH entry would resolve inside the tree under test
        cand = os.path.normpath(os.path.join(d, token))
        # NOT realpath: a venv's python3 symlinks to the same binary as the base install but imports differently
        if cand in seen or not os.path.isfile(cand) or not os.access(cand, os.X_OK):
            continue
        seen.add(cand)
        out.append((cand, "PATH entry %s" % d))
    if not out:
        return [], "no '%s' found on the provider's PATH" % token
    return out, None


LIST_KEY = "%s::list"   # preflight key of a provider's listCommand ('::' is reserved in provider names)


def resolve_interpreter(p, *, repo_dir, environ=None, run=subprocess.run, field="command"):
    """Probe one provider's `field` ("command" or "listCommand"). -> None (not a `python -m` command: nothing to check), or a dict
    {"interpreter": path|None, "token": str, "modules": [...], "tried": [(path, origin, why|None)], "problem": str|None}.
    `interpreter` is the first candidate whose `import` of every module succeeded (None when none did)."""
    environ = os.environ if environ is None else environ
    try:
        argv = shlex.split(p.get(field) or "")
        cwd = _provider_cwd(p, repo_dir)
    except (RunnerError, ValueError):
        return None   # not preparable: _run_provider records that as a harness FAIL, exactly as before
    shape = python_module_command(argv)
    if shape is None:
        return None
    env, missing, secrets = _resolve_env(p, environ)
    if missing:
        return None   # _run_provider records the missing secret; probing without it could mis-report
    modules = [shape[1]] + [m for m in (p.get("requires") or []) if m != shape[1]] if field == "command" else [shape[1]]
    bad = [m for m in modules if not (isinstance(m, str) and MODULE_NAME.fullmatch(m))]
    out = {"interpreter": None, "token": argv[0], "modules": modules, "tried": [], "problem": None}
    if bad:
        out["problem"] = "requires has invalid module name(s): %s" % ", ".join(repr(b) for b in bad)
        return out
    cands, problem = _interpreter_candidates(argv[0], env, cwd)
    if problem:
        out["problem"] = problem
        return out
    probe = "import " + ", ".join(modules)
    for path, origin in cands:
        code, _o, err, timed, oserr = _exec(run, [path, "-c", probe], cwd, env, PREFLIGHT_TIMEOUT_SEC, secrets)
        if oserr:
            why = "could not start: %s" % _redact(oserr, secrets, 160)
        elif timed:
            why = "import probe timed out after %ss" % PREFLIGHT_TIMEOUT_SEC
        elif code != 0:
            lines = [ln for ln in (err or "").strip().splitlines() if ln.strip()]
            why = _redact(lines[-1] if lines else "exited %s" % code, secrets, 160)
        else:
            out["tried"].append((path, origin, None))
            out["interpreter"] = path
            return out
        out["tried"].append((path, origin, why))
    return out


def _preflight_message(name, res):
    tried = "; ".join("%s (%s): %s" % (path, origin, why) for path, origin, why in res["tried"])
    who = ("provider '%s' listCommand" % name[:-len("::list")] if name.endswith("::list")
           else "provider '%s'" % name)
    return ("%s cannot run on this machine: %s. No test ran and nothing was recorded. Fix: install %s "
            "into the interpreter, put one that has %s first on PATH, or set %s=<absolute path to a python that has "
            "it>; then re-run" % (who, res["problem"] or ("no interpreter can `import %s` (tried %s)"
                                                            % (", ".join(res["modules"]), tried)),
                                  " and ".join(res["modules"]), "it" if len(res["modules"]) == 1 else "them",
                                  TEST_PYTHON_ENV))


def preflight(providers, *, repo_dir, environ=None, run=subprocess.run, select=None, include_scheduled=False):
    """Probe every automated provider this run would execute (honours `select` and `schedule`, like run_stage).
    -> {provider name: resolve_interpreter result} for the probed `python -m` providers.
    A `python -m` listCommand is probed for EVERY automated provider (the expected set lists them all, selected or
    not) and recorded under LIST_KEY % name; build_expected then runs it with the resolved interpreter too.
    Raises PreflightError naming every provider that cannot run (all of them, so one fix pass is enough)."""
    found, faults = {}, []
    for p in providers:
        if p.get("kind") == "manual":
            continue
        res = resolve_interpreter(p, repo_dir=repo_dir, environ=environ, run=run, field="listCommand")
        if res is not None:
            found[LIST_KEY % p.get("name")] = res
            if res["interpreter"] is None:
                faults.append(_preflight_message(LIST_KEY % p.get("name"), res))
        if select is not None and p.get("name") not in select:
            continue
        if p.get("schedule") and not include_scheduled:
            continue
        res = resolve_interpreter(p, repo_dir=repo_dir, environ=environ, run=run)
        if res is None:
            continue
        found[p.get("name")] = res
        if res["interpreter"] is None:
            faults.append(_preflight_message(p.get("name"), res))
    if faults:
        raise PreflightError("environment fault: " + " | ".join(faults))
    return found


def preflight_notes(found):
    """Human lines for the CLI: which interpreter each probed provider uses, and which candidates it passed over."""
    lines = []
    for name in sorted(found):
        res = found[name]
        label = "%s (listCommand)" % name[:-len("::list")] if name.endswith("::list") else name
        lines.append("interpreter: %s -> %s" % (label, res["interpreter"]))
        for path, origin, why in res["tried"]:
            if why:
                lines.append("  passed over %s (%s): %s" % (path, origin, why))
    return lines


def _pytest_all_skipped(out, protos, parse_error):
    """XACA-1800-004 positive evidence that a pytest exit-5 file only skipped. -> the summary body, or None."""
    if parse_error or any(r["result"] != "SKIP" or any(c["result"] != "SKIP" for c in r["children"])
                          for r in protos):
        return None
    lines = [ln.strip() for ln in (out or "").splitlines() if ln.strip()]
    m = _PYTEST_SUMMARY.match(lines[-1]) if lines else None
    if not m:
        return None
    skipped = 0
    for part in m.group("body").split(", "):
        pm = _SUMMARY_PART.match(part.strip())
        if not pm:
            return None   # "no tests ran", or anything else we do not recognise
        if pm.group("what") == "skipped":
            skipped += int(pm.group("n"))
        elif pm.group("what") not in ("warning", "warnings"):
            return None   # passed / failed / error(s) / deselected / xfailed / xpassed: not "only skipped"
    return m.group("body") if skipped > 0 else None


def _automated_expected(p, repo_dir, environ, run, list_timeout, interpreters=None):
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
    resolved = ((interpreters or {}).get(LIST_KEY % p.get("name")) or {}).get("interpreter")
    if resolved and python_module_command(argv) is not None:   # XACA-1800: the preflight-resolved python
        argv = [resolved] + argv[1:]
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


def _provider_expected(p, repo_dir, kanban_dir, environ, run, list_timeout, interpreters=None):
    if p.get("kind") == "manual":
        return _manual_expected(p, kanban_dir)
    return _automated_expected(p, repo_dir, environ, run, list_timeout, interpreters)


def build_expected(providers, *, repo_dir, kanban_dir, run=subprocess.run, environ=None,
                   list_timeout=LIST_TIMEOUT_SEC, interpreters=None):
    """Spec 7.2.1 -> (expected_list, problems).

    expected_list entries are a str, or {"test", "optional": True} when the provider is optional
    (the shape release_gate._norm_expected reads). A provider whose list/cases cannot be produced
    adds a human-readable problem AND the plain (never optional) `<provider>::harness` entry, so
    the gate cannot pass on an empty set.
    """
    environ = os.environ if environ is None else environ
    return _assemble(_disjoint([(p,) + _provider_expected(p, repo_dir, kanban_dir, environ, run, list_timeout,
                                                          interpreters)
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
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class _Records(object):
    """Accumulates proto records with local refs r1, r2, ..."""

    def __init__(self, stage, sha, ts):
        self.stage, self.sha, self.ts, self.items = stage, sha, ts, []
        self._n = 0                 # monotonic: a dropped record (run_stage `only`) must never free its ref for reuse
        self.names = set()          # every record name already written (run-wide uniqueness, XACA-1347-030)

    def add(self, test, result, notes, env, parent_ref=None):
        self.names.add(test)
        self._n += 1
        ref = "r%d" % self._n
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


def _run_provider(p, rec, names, repo_dir, environ, run, owner, interpreter=None):
    """Run one automated provider into `rec`; return True if a harness FAIL was written.
    `interpreter` (XACA-1800): the preflight-resolved python, substituted for the command's first token."""
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
    shape = python_module_command(base)
    if interpreter and shape is not None:
        base = [interpreter] + base[1:]
    is_pytest = shape is not None and shape[1] == "pytest"
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
        elif code == 5 and is_pytest:
            body = _pytest_all_skipped(out, pr.results, pr.error)
            if body:   # XACA-1800-004: positive evidence only; every other exit-5 shape stays FAIL
                g, gnotes = "SKIP", "pytest exit 5: every test in this file was skipped (%s)" % body
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
              include_scheduled=False, list_timeout=LIST_TIMEOUT_SEC, only=None, select=None, recorded=None):
    """Verify the stage SHA, build the expected set, run AUTOMATED providers.

    `select` (XACA-1694, `kb-release test --provider`): None runs every provider; a set of provider names runs only
    those. It narrows what RUNS, never what is EXPECTED: `providers` must be EVERY provider of the stage, all of them
    are listed into `expected`, and an unselected provider is skipped like an `only`-excluded one (no run, no
    records, no harness record for a listing problem; its `<name>::harness` id stays expected, so the gate stays
    closed). Narrowing the list instead let a single-provider run grade a stage passed on missing evidence.

    `only` (XACA-1350-004, spec 5.2 "running only the expected tests with no current record"): None runs everything;
    a set of test names runs only those. A provider whose tests are all outside `only` is NOT run; a perFile provider
    runs just its files in `only`; any other provider runs whole but the records of tests outside `only` are dropped,
    so a record that is still current is never re-run or re-posted.

    `recorded` (XACA-1628): the stage's stored expected set when its expectedSha is THIS stage SHA, else None. The
    server lets that set only grow, so a `<name>::harness` id in it can never be dropped from the post. When that
    provider now lists and runs clean, the runner keeps the id and writes `<name>::harness PASS` (the latest record
    per name is what the gate grades, so it supersedes the earlier FAIL). When the provider does not run, the id is
    carried with no new record. When it is still broken, it records FAIL again. Under `only`, a recorded harness id
    in `only` makes its provider run (a perFile provider with no other file due runs every file and posts only the
    harness record), so a PASS is never written for a run that executed nothing.

    Returns {"expected": [...], "records": [proto...], "problems": [...], "interpreters": {name: preflight result}}.
    Raises RunnerError (nothing run) on a GAMMA safety violation, a missing/invalid stageSha, a dirty
    tree or HEAD mismatch, and PreflightError (XACA-1800) when a provider's interpreter cannot import its modules. `verify` is injectable for tests; `run` is used for providers.
    """
    check_gamma(stage, providers)
    sha = (release.get("stageSha") or {}).get(stage)
    if not sha:
        raise RunnerError("release has no stageSha.%s; nothing to verify or run against" % stage)
    verify(repo_dir, sha)
    environ = os.environ if environ is None else environ
    # XACA-1800: before anything is listed or run. Raises PreflightError (nothing recorded, nothing posted).
    interpreters = preflight(providers, repo_dir=repo_dir, environ=environ, run=run, select=select,
                             include_scheduled=include_scheduled)
    ts = _iso(now if now is not None else (lambda: datetime.datetime.now(datetime.timezone.utc)))
    rec = _Records(stage, sha, ts)
    per_provider = _disjoint([(p,) + _provider_expected(p, repo_dir, kanban_dir, environ, run, list_timeout,
                                                        interpreters)
                              for p in providers])
    expected, problems = _assemble(per_provider)
    owner = {n: p.get("name") for p, names, problem in per_provider if not problem for n in names}
    rec_h = _recorded_harness_ids(recorded)
    for p, names, problem in per_provider:
        if not p.get("envLabel") and env_label_default:
            p = dict(p, envLabel=env_label_default)
        h = _harness(p)
        if select is not None and p.get("name") not in select:
            continue   # XACA-1694: listed above (its ids are expected), but the operator did not ask to run it
        if problem:  # automated AND manual: the reason must reach the board, not only this process's stderr
            if only is None or h in only:
                rec.add(h, "FAIL", problem, p["envLabel"])
            continue
        if p.get("kind") == "manual":
            # XACA-1628: a manual provider's harness id only ever comes from its case file failing to load. It
            # loaded this time, so a recorded entry is satisfied (the walkthrough records the cases themselves).
            if h in rec_h and (only is None or h in only):
                rec.add(h, "PASS", _HARNESS_RESOLVED % "its case file loaded", p["envLabel"])
            continue
        if p.get("schedule") and not include_scheduled:
            continue
        drop_current = only is not None and not p.get("perFile")
        keep_fail = False
        if only is not None:
            due = [n for n in names if n in only]
            if not due and not (h in only and h in rec_h):   # XACA-1628: a recorded harness with no PASS is due
                continue   # every test of this provider already has a current record
            if p.get("perFile"):
                if due:
                    names = due
                else:
                    # only its harness is due: run every file to prove it and post just the harness, EXCEPT a file
                    # that now FAILs. That is new failing evidence on this SHA; dropping it would leave the stale
                    # PASS current beside a fresh harness PASS (XACA-1628-014). Posting it only tightens the gate.
                    drop_current = keep_fail = True
        start = len(rec.items)
        failed = _run_provider(p, rec, names, repo_dir, environ, run, owner,
                               (interpreters.get(p.get("name")) or {}).get("interpreter"))
        if drop_current:
            drop = {r["ref"] for r in rec.items[start:]
                    if not r["parentRef"] and r["test"] not in only and not r["test"].endswith("::harness")
                    and not (keep_fail and r["result"] != "PASS")}
            rec.items[start:] = [r for r in rec.items[start:] if r["ref"] not in drop and r["parentRef"] not in drop]
        if failed:
            if h not in expected:
                expected.append(h)
        elif h in rec_h and (only is None or h in only):
            # XACA-1628: the recorded entry leaves only by being SATISFIED, never by being omitted (the server's
            # add-only lock refuses the omission). The provider ran clean, so the runner writes the PASS.
            rec.add(h, "PASS", _HARNESS_RESOLVED % "it listed and ran clean", p["envLabel"])
    for p, _names, _problem in per_provider:
        h = _harness(p)
        if h in rec_h and h not in expected:
            # XACA-1628: a recorded harness id of a provider this run did not run (unselected, scheduled, or already
            # current under --only-missing) is CARRIED so the post stays a superset. Carried is not satisfied: its
            # latest record (FAIL, or none) still decides the gate.
            expected.append(h)
    counts = collections.Counter(r["test"] for r in rec.items if not r["test"].endswith("::harness"))
    dup = sorted(n for n, c in counts.items() if c > 1)
    if dup:   # defence in depth: the per-provider checks should make this unreachable
        raise RunnerError("internal inconsistency: duplicate test name(s) in the run's records: %s; nothing posted"
                          % ", ".join(dup[:5]))
    return {"expected": expected, "records": rec.items, "problems": problems, "interpreters": interpreters}


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
