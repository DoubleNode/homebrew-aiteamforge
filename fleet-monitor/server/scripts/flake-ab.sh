#!/bin/bash
# flake-ab.sh -- interleaved A/B harness for attributing intermittent test failures
# (XACA-1065-001). Runs CONTROL and TREATMENT arms alternately (ABAB/BABA...) so that
# machine-load drift hits both arms equally; sequential batches are NOT admissible
# evidence for load-dependent flakes (XACA-1030 conclusion was withdrawn for exactly that).
#
# Must run under /bin/bash 3.2 (macOS). Parsing is done by an embedded python3 (-I, 3.9-safe).
# Usage: flake-ab.sh --help
set -u

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"          # fleet-monitor/server of this tree
REPO_ROOT="$(git -C "$SERVER_DIR" rev-parse --show-toplevel 2>/dev/null || true)"

usage() {
  cat <<'EOF'
flake-ab.sh -- interleaved A/B flake harness for fleet-monitor/server tests

USAGE
  flake-ab.sh [options]
  flake-ab.sh --selftest            parse a fabricated TAP sample, verify classification
  flake-ab.sh --help

ARMS (each arm = a fleet-monitor/server dir + a command + optional env)
  Default CONTROL    git archive of --control-ref (default dev-team/develop) extracted to a
                     temp dir (fleet-monitor/ + kanban-hooks/, homebrew-tap symlinked from the
                     worktree), node_modules symlinked in.
  Default TREATMENT  this worktree's fleet-monitor/server.
  --control-ref REF         git ref for the archived control            [dev-team/develop]
  --control-dir DIR         use DIR (a fleet-monitor/server tree) as control instead of archiving
  --treatment-dir DIR       treatment tree                              [this worktree]
  --same-tree               control = treatment dir (A/B env/command/files on ONE tree; no archive)
  --control-cmd CMD         command run in the control dir              [npm test]
  --treatment-cmd CMD       command run in the treatment dir            [npm test]
  --cmd CMD                 set both commands
  --files "a.test.js b.test.js"   set both commands to `node --test <files>` (paths relative to tree)
  --control-env K=V         extra env for the control arm (repeatable)
  --treatment-env K=V       extra env for the treatment arm (repeatable)
  --node-modules DIR        node_modules to symlink into archived trees [auto: tree's, else main repo's]

RUN CONTROL
  -n, --rounds N            rounds; each round runs both arms, order alternates      [3]
  --first A|B               which arm leads round 1 (A=control, B=treatment)         [A]
  --out DIR                 results dir (persisted)                                  [/tmp/flake-ab-out.<ts>]
  --keep                    keep temp trees and per-run TMPDIRs (default: removed on exit)

The TAP reporter is injected automatically (`node --test` -> `node --test --test-reporter=tap`,
`npm test` -> `npm test -- --test-reporter=tap`); a command that already names a reporter is left
alone but must emit TAP. Each run gets its OWN fresh TMPDIR.

OUTPUT (in --out DIR)
  runs.tsv       round arm start_iso wall_s exit load_before load_after pass fail cancelled unsafe_traffic
  failures.tsv   round arm file test duration_ms signature
  raw/r<N>-<CONTROL|TREATMENT>.{tap,err}   full raw output per run
Summary per arm: runs, failing runs, failure rate, Wilson 95% CI, signature histogram, top files.
Exit status: 0 always for the harness itself (2 on usage errors).
EOF
}

die() { echo "flake-ab: $*" >&2; exit 2; }

# ------------------------------------------------------------------ python helpers
# Writes the embedded python to $1. Subcommands: parse <tap> <err> | summary <out> | selftest
write_py() {
cat > "$1" <<'PYEOF'
import sys, re, math, json, collections

STATUS_RES = [
    re.compile(r'\b[1-5]\d\d\s*!==\s*[1-5]\d\d\b'),
    re.compile(r'expected\s+"?[1-5]\d\d\b', re.I),
    re.compile(r'\bgot\s+"?[1-5]\d\d\b', re.I),
    re.compile(r'\b[1-5]\d\d\s+expected\b', re.I),
]

def classify(fields):
    blob = " ".join(str(fields.get(k, "")) for k in ("error", "code", "stack", "failureType"))
    ft = str(fields.get("failureType", ""))
    if "ETIMEDOUT" in blob:
        return "ETIMEDOUT"
    if ft == "cancelledByParent" or "cancelledByParent" in blob:
        return "cancelledByParent"
    for r in STATUS_RES:
        if r.search(blob):
            return "status-mismatch"
    return "other"

def unq(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        v = v[1:-1]
    return v

def parse_tap(text):
    """Return (failures, counts). A failure is a leaf 'not ok' (not a subtestsFailed parent)."""
    lines = text.splitlines()
    fails = []
    counts = {"pass": None, "fail": None, "cancelled": None}
    i, n = 0, len(lines)
    cur_file = None
    while i < n:
        ln = lines[i]
        m = re.match(r'^# (pass|fail|cancelled) (\d+)\s*$', ln)
        if m:
            counts[m.group(1)] = int(m.group(2))
        m = re.match(r'^(\s*)not ok \d+ - (.*?)(?:\s+# .*)?$', ln)
        if m:
            indent, name = len(m.group(1)), m.group(2)
            fields, j = {}, i + 1
            if j < n and lines[j].strip() == "---":
                j += 1
                key = None
                while j < n and lines[j].strip() != "...":
                    raw = lines[j]
                    km = re.match(r'^\s{2,}([A-Za-z_]+):\s?(.*)$', raw)
                    if km and not raw.startswith(" " * (indent + 4)):
                        key = km.group(1)
                        val = km.group(2)
                        if val in ("|-", "|", "|+", ">-", ">"):
                            val = ""
                        fields[key] = unq(val)
                    elif key:
                        fields[key] = fields.get(key, "") + "\n" + raw.strip()
                    j += 1
            loc = fields.get("location", "")
            lm = re.match(r'^(.*?):\d+:\d+$', loc)
            if indent == 0 and name.endswith((".js", ".mjs", ".cjs")):
                cur_file = name
            if fields.get("failureType") != "subtestsFailed":
                f = lm.group(1) if lm else (cur_file or "?")
                try:
                    dur = float(fields.get("duration_ms", "nan"))
                except ValueError:
                    dur = float("nan")
                fails.append({"file": f, "test": name, "duration_ms": dur,
                              "signature": classify(fields)})
            i = j
        i += 1
    return fails, counts

def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), min(1.0, c + h))

def cmd_parse(tap, err, out_fail, rnd, arm):
    t = open(tap, errors="replace").read()
    e = open(err, errors="replace").read() if err else ""
    fails, c = parse_tap(t)
    unsafe = 1 if ("Unsafe traffic blocked" in t or "Unsafe traffic blocked" in e) else 0
    with open(out_fail, "a") as fh:
        for f in fails:
            fh.write("\t".join([rnd, arm, f["file"], f["test"].replace("\t", " "),
                                "%.1f" % f["duration_ms"], f["signature"]]) + "\n")
    z = lambda v: "NA" if v is None else str(v)
    print("\t".join([z(c["pass"]), z(c["fail"]), z(c["cancelled"]), str(unsafe), str(len(fails))]))

def cmd_summary(out):
    rows = [l.rstrip("\n").split("\t") for l in open(out + "/runs.tsv")][1:]
    fr = [l.rstrip("\n").split("\t") for l in open(out + "/failures.tsv")][1:]
    for arm in ("CONTROL", "TREATMENT"):
        runs = [r for r in rows if r[1] == arm]
        if not runs:
            continue
        # failing run = nonzero exit OR parsed failures (covers crashed runs with no TAP)
        failing = set(r[0] for r in runs if r[4] != "0")
        walls = [float(r[3]) for r in runs]
        k, n = len(failing), len(runs)
        lo, hi = wilson(k, n)
        sig = collections.Counter(f[5] for f in fr if f[1] == arm)
        files = collections.Counter(f[2].split("/")[-1] for f in fr if f[1] == arm)
        unsafe = sum(1 for r in runs if r[10] == "1")
        print("%-9s runs=%d failing_runs=%d rate=%.1f%% wilson95=[%.1f%%, %.1f%%] "
              "mean_wall=%.1fs unsafe_traffic_runs=%d" %
              (arm, n, k, 100.0 * k / n, 100 * lo, 100 * hi, sum(walls) / n, unsafe))
        print("          signatures: " + (", ".join("%s=%d" % kv for kv in sig.most_common()) or "none"))
        print("          top files:  " + (", ".join("%s(%d)" % kv for kv in files.most_common(5)) or "none"))
        print("          failing rounds: " + (",".join(sorted(failing, key=int)) or "none"))

SAMPLE = """TAP version 13
# Subtest: /x/tests/a.test.js
    # Subtest: slow route
    not ok 1 - slow route
      ---
      duration_ms: 7812.4
      location: '/x/tests/a.test.js:10:3'
      failureType: 'testCodeFailure'
      error: 'ETIMEDOUT: Operation timed out'
      code: 'ETIMEDOUT'
      stack: |-
        Test.assert (/x/node_modules/supertest/lib/test.js:200:13)
        Server.emitCloseNT (node:net:2000:8)
      ...
    1..1
not ok 1 - /x/tests/a.test.js
  ---
  duration_ms: 8000
  failureType: 'subtestsFailed'
  error: '1 subtest failed'
  ...
# Subtest: /x/tests/b.test.js
    not ok 1 - bad input is 400
      ---
      duration_ms: 12.5
      location: '/x/tests/b.test.js:22:5'
      failureType: 'testCodeFailure'
      error: |-
        Expected values to be strictly equal:

        503 !== 400

      code: 'ERR_ASSERTION'
      ...
    not ok 2 - cancelled sibling
      ---
      duration_ms: 0
      location: '/x/tests/b.test.js:40:5'
      failureType: 'cancelledByParent'
      error: 'test did not finish before its parent and was cancelled'
      ...
    not ok 3 - supertest style
      ---
      duration_ms: 3
      location: '/x/tests/b.test.js:50:5'
      failureType: 'testCodeFailure'
      error: 'expected 400 "Bad Request", got 404 "Not Found"'
      ...
    not ok 4 - plain
      ---
      duration_ms: 1
      location: '/x/tests/b.test.js:60:5'
      failureType: 'testCodeFailure'
      error: 'boom'
      ...
# tests 6
# pass 2
# fail 4
# cancelled 1
"""

def cmd_selftest():
    fails, c = parse_tap(SAMPLE)
    got = [(f["file"].split("/")[-1], f["test"], f["signature"]) for f in fails]
    want = [("a.test.js", "slow route", "ETIMEDOUT"),
            ("b.test.js", "bad input is 400", "status-mismatch"),
            ("b.test.js", "cancelled sibling", "cancelledByParent"),
            ("b.test.js", "supertest style", "status-mismatch"),
            ("b.test.js", "plain", "other")]
    for g in got:
        print("  parsed:", g, " dur=%.1f" % [f for f in fails if f["test"] == g[1]][0]["duration_ms"])
    print("  counts:", c)
    ok = got == want and c == {"pass": 2, "fail": 4, "cancelled": 1}
    print("selftest:", "PASS" if ok else "FAIL")
    lo, hi = wilson(1, 8)
    print("  wilson(1/8) = [%.3f, %.3f] (expect ~[0.022, 0.471])" % (lo, hi))
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    a = sys.argv[1:]
    if a[0] == "parse":
        cmd_parse(a[1], a[2], a[3], a[4], a[5])
    elif a[0] == "summary":
        cmd_summary(a[1])
    elif a[0] == "selftest":
        cmd_selftest()
PYEOF
}

# ------------------------------------------------------------------ args
ROUNDS=3; FIRST=A; KEEP=0; OUT=""; CREF="dev-team/develop"
CDIR=""; TDIR="$SERVER_DIR"; CCMD=""; TCMD=""; FILES=""; SAME=0; NM=""
CENV=(); TENV=()

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --selftest) PYF="$(mktemp /tmp/flake-ab-py.XXXXXX)"; write_py "$PYF"; python3 -I "$PYF" selftest; rc=$?; rm -f "$PYF"; exit $rc ;;
    -n|--rounds) ROUNDS="${2:-}"; shift 2 ;;
    --first) FIRST="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --control-ref) CREF="${2:-}"; shift 2 ;;
    --control-dir) CDIR="${2:-}"; shift 2 ;;
    --treatment-dir) TDIR="${2:-}"; shift 2 ;;
    --same-tree) SAME=1; shift ;;
    --control-cmd) CCMD="${2:-}"; shift 2 ;;
    --treatment-cmd) TCMD="${2:-}"; shift 2 ;;
    --cmd) CCMD="${2:-}"; TCMD="${2:-}"; shift 2 ;;
    --files) FILES="${2:-}"; shift 2 ;;
    --control-env) CENV+=("${2:-}"); shift 2 ;;
    --treatment-env) TENV+=("${2:-}"); shift 2 ;;
    --node-modules) NM="${2:-}"; shift 2 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

case "$ROUNDS" in ''|*[!0-9]*) die "--rounds must be a positive integer" ;; esac
[ "$ROUNDS" -ge 1 ] || die "--rounds must be >= 1"
case "$FIRST" in A|B) ;; *) die "--first must be A or B" ;; esac
[ -d "$TDIR" ] || die "treatment dir not found: $TDIR"
[ -n "$FILES" ] && { CCMD="node --test $FILES"; TCMD="node --test $FILES"; }
[ -n "$CCMD" ] || CCMD="npm test"
[ -n "$TCMD" ] || TCMD="npm test"
for e in ${CENV[@]+"${CENV[@]}"} ${TENV[@]+"${TENV[@]}"}; do
  case "$e" in *=*) ;; *) die "env must be K=V: $e" ;; esac
done
# Never run the suite with GIT_DIR/GIT_WORK_TREE exported (fixture `git config` would hit the real repo).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

TS="$(date +%Y%m%d-%H%M%S)"
[ -n "$OUT" ] || OUT="/tmp/flake-ab-out.$TS"
mkdir -p "$OUT/raw" || die "cannot create $OUT"
WORK="$(mktemp -d /tmp/flake-ab.XXXXXX)" || die "mktemp failed"
PYF="$WORK/fab.py"; write_py "$PYF"

LINKS=()   # symlinks we created inside user-visible trees (removed on exit)
unlink_all() { local l; for l in ${LINKS[@]+"${LINKS[@]}"}; do if [ -L "$l" ]; then rm -f "$l"; fi; done; }
cleanup() {
  unlink_all
  if [ "$KEEP" = 1 ]; then echo "flake-ab: kept $WORK" >&2; else rm -rf "$WORK"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------------ node_modules
# Tests need server/node_modules AND client/node_modules (msg-client.js -> libsodium-wrappers). A worktree has
# neither; the main repo's copy can be STALE (lacks nodemailer/jsdom) -> deterministic MODULE_NOT_FOUND failures
# that masquerade as results. Rule: use a candidate only if it satisfies the tree's package.json, else `npm ci`
# into a cache dir keyed by lockfile hash (/tmp/flake-ab-nm.<sha>, persists across runs, never touches the tree).
MAIN=""
if [ -n "$REPO_ROOT" ]; then
  COMMON="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"
  MAIN="$(cd "$REPO_ROOT" && cd "$COMMON/.." 2>/dev/null && pwd)"
fi
nm_complete() { # $1 = package dir (has package.json), $2 = node_modules dir
  [ -d "$2" ] || return 1
  node -e 'const p=require(process.argv[1]+"/package.json");const fs=require("fs");
    const d=Object.assign({},p.dependencies,p.devDependencies);
    process.exit(Object.entries(d).every(([n])=>fs.existsSync(process.argv[2]+"/"+n))?0:1)' "$1" "$2" 2>/dev/null
}
nm_resolve() { # $1 = package dir, $2.. = candidate node_modules dirs ; echoes a complete node_modules path
  local pkg="$1" c sum cache; shift
  for c in "$@"; do
    if [ -n "$c" ] && nm_complete "$pkg" "$c"; then echo "$c"; return 0; fi
  done
  [ -f "$pkg/package-lock.json" ] || return 1
  sum="$(shasum -a 256 "$pkg/package-lock.json" | cut -c1-10)"; cache="/tmp/flake-ab-nm.$sum"
  if ! nm_complete "$pkg" "$cache/node_modules"; then
    echo "flake-ab: node_modules incomplete for $pkg; npm ci into $cache (one-time)" >&2
    mkdir -p "$cache" && cp "$pkg/package.json" "$pkg/package-lock.json" "$cache/" \
      && ( cd "$cache" && npm ci --no-audit --no-fund --loglevel=error >&2 ) || return 1
  fi
  echo "$cache/node_modules"
}
link_nm() { # $1 = dir that should contain node_modules, $2 = target
  [ -e "$1/node_modules" ] && return 0
  ln -s "$2" "$1/node_modules" || return 1
  LINKS+=("$1/node_modules")
}

SRV_NM="$(nm_resolve "$TDIR" "$NM" "$TDIR/node_modules" "$MAIN/fleet-monitor/server/node_modules")" || die "cannot provision server node_modules"
TROOT="$(cd "$TDIR/../.." && pwd)"
CLI_NM=""
if [ -f "$TROOT/fleet-monitor/client/package.json" ]; then
  CLI_NM="$(nm_resolve "$TROOT/fleet-monitor/client" "$TROOT/fleet-monitor/client/node_modules" "$MAIN/fleet-monitor/client/node_modules")" || die "cannot provision client node_modules"
fi

# ------------------------------------------------------------------ build arms
ARCHIVE_PATHS="${FLAKE_AB_ARCHIVE_PATHS:-fleet-monitor kanban-hooks docs sync-tap.sh .gitignore .gitmodules}"
if [ "$SAME" = 1 ]; then
  CDIR="$TDIR"
elif [ -z "$CDIR" ]; then
  [ -n "$REPO_ROOT" ] || die "not in a git tree; pass --control-dir"
  git -C "$REPO_ROOT" rev-parse --verify -q "$CREF^{commit}" >/dev/null || die "bad --control-ref: $CREF"
  A="$WORK/control"; mkdir -p "$A"
  # shellcheck disable=SC2086
  ( git -C "$REPO_ROOT" archive "$CREF" $ARCHIVE_PATHS | tar -x -C "$A" ) || die "git archive failed"
  [ -e "$REPO_ROOT/homebrew-tap" ] && ln -s "$REPO_ROOT/homebrew-tap" "$A/homebrew-tap"
  CDIR="$A/fleet-monitor/server"
  [ -d "$CDIR" ] || die "archive lacks fleet-monitor/server at $CREF"
fi
[ -d "$CDIR" ] || die "control dir not found: $CDIR"
CROOT="$(cd "$CDIR/../.." && pwd)"
link_nm "$TDIR" "$SRV_NM" || die "cannot link treatment node_modules"
link_nm "$CDIR" "$SRV_NM" || die "cannot link control node_modules"
if [ -n "$CLI_NM" ]; then
  link_nm "$TROOT/fleet-monitor/client" "$CLI_NM"
  if [ -d "$CROOT/fleet-monitor/client" ]; then link_nm "$CROOT/fleet-monitor/client" "$CLI_NM"; fi
fi

inject_tap() {
  case "$1" in
    *test-reporter*) echo "$1" ;;
    *"node --test"*) echo "${1/node --test/node --test --test-reporter=tap}" ;;
    "npm test"*|"npm run test"*) case "$1" in *" -- "*) echo "$1 --test-reporter=tap" ;; *) echo "$1 -- --test-reporter=tap" ;; esac ;;
    *) echo "$1" ;;
  esac
}
CCMD_X="$(inject_tap "$CCMD")"; TCMD_X="$(inject_tap "$TCMD")"

load1() { sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{},]/,""); print $1}' || uptime | sed 's/.*load averages*: *//' | awk '{gsub(/,/,""); print $1}'; }
now_s() { python3 -I -c 'import time;print("%.3f"%time.time())'; }

printf 'round\tarm\tstart_iso\twall_s\texit\tload_before\tload_after\tpass\tfail\tcancelled\tunsafe_traffic\tfailing_tests\n' > "$OUT/runs.tsv"
printf 'round\tarm\tfile\ttest\tduration_ms\tsignature\n' > "$OUT/failures.tsv"

echo "flake-ab: out=$OUT rounds=$ROUNDS"
echo "  CONTROL   dir=$CDIR cmd=[$CCMD_X] env=[${CENV[*]:-}]"
echo "  TREATMENT dir=$TDIR cmd=[$TCMD_X] env=[${TENV[*]:-}]"

run_one() { # round arm
  local rnd="$1" arm="$2" dir cmd rtmp tap err l0 l1 t0 t1 rc start parsed
  if [ "$arm" = CONTROL ]; then dir="$CDIR"; cmd="$CCMD_X"; else dir="$TDIR"; cmd="$TCMD_X"; fi
  rtmp="$WORK/t/r$rnd-${arm:0:1}"; mkdir -p "$rtmp"
  tap="$OUT/raw/r$rnd-$arm.tap"; err="$OUT/raw/r$rnd-$arm.err"
  l0="$(load1)"; start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; t0="$(now_s)"
  if [ "$arm" = CONTROL ]; then
    ( cd "$dir" && env ${CENV[@]+"${CENV[@]}"} TMPDIR="$rtmp" bash -c "$cmd" >"$tap" 2>"$err" </dev/null ); rc=$?
  else
    ( cd "$dir" && env ${TENV[@]+"${TENV[@]}"} TMPDIR="$rtmp" bash -c "$cmd" >"$tap" 2>"$err" </dev/null ); rc=$?
  fi
  t1="$(now_s)"; l1="$(load1)"
  parsed="$(python3 -I "$PYF" parse "$tap" "$err" "$OUT/failures.tsv" "$rnd" "$arm")"
  # parsed = pass fail cancelled unsafe nfails
  local pass fail canc unsafe nf
  IFS=$'\t' read -r pass fail canc unsafe nf <<EOF
$parsed
EOF
  printf '%s\t%s\t%s\t%.1f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rnd" "$arm" "$start" \
    "$(python3 -I -c "print($t1-$t0)")" "$rc" "$l0" "$l1" "$pass" "$fail" "$canc" "$unsafe" "$nf" >> "$OUT/runs.tsv"
  echo "  r$rnd $arm exit=$rc pass=$pass fail=$fail failing_tests=$nf load=$l0->$l1$([ "$unsafe" = 1 ] && echo ' UNSAFE-TRAFFIC')"
  [ "$KEEP" = 1 ] || rm -rf "$rtmp"
}

r=1
while [ "$r" -le "$ROUNDS" ]; do
  # alternate lead arm each round: ABAB... then BABA... cancels linear load drift
  if [ $(( (r % 2) )) -eq 1 ]; then LEAD=$FIRST; else [ "$FIRST" = A ] && LEAD=B || LEAD=A; fi
  if [ "$LEAD" = A ]; then run_one "$r" CONTROL; run_one "$r" TREATMENT
  else run_one "$r" TREATMENT; run_one "$r" CONTROL; fi
  r=$((r+1))
done

echo
echo "=== SUMMARY ($OUT) ==="
python3 -I "$PYF" summary "$OUT"
exit 0
