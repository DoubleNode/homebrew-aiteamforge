#!/bin/bash
# test-xaca-1669-tmux-theme-contrast.sh
#
# XACA-1669-022: WCAG 1.4.3 contrast of the two-line tmux tab bar for the badge
# colours the INSTALLER actually assigns. dev-team's own contrast suite only reads
# */scripts/*-startup.sh; installed machines get their badge colour from
# libexec/installers/install-team.sh, so that source is checked here (dev-team's
# shell-suite CI checks out no submodules, which is why this lives in the tap).
#
# Which code is the badge: install-team.sh unpacks
#   bg_code, accent_code = THEME_COLORS.get(theme, DEFAULT_THEME_COLORS)
# and emits `status-left-style "bg=colour{accent_code},..."`. Only the ACCENT
# (second tuple element) reaches status-left-style, which is what the tab colours
# in share/templates/claude/tmux.conf derive from. bg_code feeds status-style /
# status-right-style / window-status-style, not the badge, so it is not checked.
# Codes covered = every accent in THEME_COLORS + DEFAULT_THEME_COLORS's accent,
# parsed dynamically; a new theme is covered automatically.
#
# LIMIT: teams may override colours per theme via THEME_COLORS_<THEME> in their
# .conf at runtime. Those values are not knowable here and are NOT covered.
#
# For each code the REAL window-status-format / -current-format are expanded in an
# isolated tmux server (private mktemp HOME + TMUX_TMPDIR, own -L socket, never the
# default socket or a team server) and the style tags are parsed: non-selected
# (fg on badge bg), selected (fg on black), and the Claude amber (both states).
# Each must reach >= 4.5:1. tmux is REQUIRED: missing tmux is a FAILURE, not a skip.
#
# Env: TMUX_CONF_UNDER_TEST=<path> tests a different config (default
#      share/templates/claude/tmux.conf), e.g. dev-team's claude/tmux.conf before the
#      publisher mirrors it, or a mutated scratch copy.
#
# Usage: bash tests/test-xaca-1669-tmux-theme-contrast.sh     Exit 0 = all passed.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE:-$0}")" 2>/dev/null && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
CONF="${TMUX_CONF_UNDER_TEST:-$REPO_ROOT/share/templates/claude/tmux.conf}"
INSTALLER="$REPO_ROOT/libexec/installers/install-team.sh"

if ! command -v tmux >/dev/null 2>&1; then
    echo "FAIL: tmux not found on PATH (this suite requires tmux; it never skips)"
    exit 1
fi
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 not found"; exit 1; }
[ -f "$CONF" ] || { echo "FAIL: config under test not found: $CONF"; exit 1; }
[ -f "$INSTALLER" ] || { echo "FAIL: installer not found: $INSTALLER"; exit 1; }

unset TMUX TMUX_PANE GIT_DIR GIT_WORK_TREE
WORK="$(mktemp -d)"
export HOME="$WORK/home"
export TMUX_TMPDIR="$WORK/tmux"
mkdir -p "$HOME" "$TMUX_TMPDIR" "$WORK/bin"
SOCK="x1669th$$"
cleanup() {
    tmux -L "$SOCK" kill-server >/dev/null 2>&1 || true
    find "$WORK" -delete >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Real executable named `claude` so pane_current_command reads `claude` (a symlink to
# sleep reports "sleep" on macOS); fall back to a symlink where there is no compiler.
printf '#include <unistd.h>\nint main(void){sleep(600);return 0;}\n' > "$WORK/sleeper.c"
if command -v cc >/dev/null 2>&1 && cc -o "$WORK/bin/claude" "$WORK/sleeper.c" 2>/dev/null; then
    :
else
    ln -s "$(command -v sleep)" "$WORK/bin/claude"
fi

export REPO_ROOT CONF INSTALLER SOCK WORK
python3 -I - <<'PY'
import ast, os, re, subprocess, sys, time

CONF, INSTALLER, SOCK, WORK = (os.environ[k] for k in ("CONF", "INSTALLER", "SOCK", "WORK"))
MIN_RATIO = 4.5

passed = failed = 0
def ok(msg):
    global passed
    passed += 1
    print("PASS: " + msg)
def bad(msg):
    global failed
    failed += 1
    print("FAIL: " + msg)
def check(cond, msg):
    (ok if cond else bad)(msg)
def finish():
    print("RESULT: %d passed, %d failed" % (passed, failed))
    sys.exit(1 if failed else 0)

# ---- xterm-256 -> sRGB -> WCAG ------------------------------------------------
ANSI16 = [(0,0,0),(128,0,0),(0,128,0),(128,128,0),(0,0,128),(128,0,128),(0,128,128),
          (192,192,192),(128,128,128),(255,0,0),(0,255,0),(255,255,0),(0,0,255),
          (255,0,255),(0,255,255),(255,255,255)]
def rgb(n):
    if n < 16: return ANSI16[n]
    if n < 232:
        n -= 16; v = [0, 95, 135, 175, 215, 255]
        return (v[n // 36], v[(n // 6) % 6], v[n % 6])
    g = 8 + 10 * (n - 232); return (g, g, g)
def lum(c):
    def f(x):
        x /= 255; return x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4
    r, g, b = map(f, c); return 0.2126 * r + 0.7152 * g + 0.0722 * b
def ratio(a, b):
    la, lb = lum(rgb(a)), lum(rgb(b)); hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)

# ---- badge codes from the installer, dynamically ---------------------------------
src = open(INSTALLER, errors="replace").read()
m_dict = re.search(r"^THEME_COLORS\s*=\s*(\{.*?^\})", src, re.S | re.M)
m_def = re.search(r"^DEFAULT_THEME_COLORS\s*=\s*(\(.*?\))", src, re.M)
if not m_dict or not m_def:
    bad("could not locate THEME_COLORS / DEFAULT_THEME_COLORS in install-team.sh (dict=%s default=%s)"
        % (bool(m_dict), bool(m_def)))
    finish()
try:
    theme_colors = ast.literal_eval(m_dict.group(1))
    default_colors = ast.literal_eval(m_def.group(1))
    assert isinstance(theme_colors, dict) and len(default_colors) == 2
    assert all(len(v) == 2 for v in theme_colors.values())
except Exception as e:
    bad("THEME_COLORS / DEFAULT_THEME_COLORS did not parse as (bg, accent) literals: %r" % (e,))
    finish()

# Anchor: the accent really is the status-left-style background. If the installer is
# refactored so another element becomes the badge, this fails loudly instead of
# silently checking the wrong codes.
check(re.search(r'status-left-style\s+"bg=colour\{accent_code\}', src) is not None,
      "install-team.sh still emits status-left-style bg=colour{accent_code} (accent is the badge)")
check(re.search(r"bg_code,\s*accent_code\s*=\s*THEME_COLORS\.get\(theme,\s*DEFAULT_THEME_COLORS\)", src) is not None,
      "install-team.sh still unpacks (bg_code, accent_code) from THEME_COLORS.get(theme, DEFAULT_THEME_COLORS)")

sources = {}   # accent code -> [labels]
for theme, (_bg, accent) in theme_colors.items():
    sources.setdefault(accent, []).append(theme)
sources.setdefault(default_colors[1], []).append("DEFAULT")
codes = sorted(sources)
check(len(theme_colors) > 0 and len(codes) > 0,
      "found %d themes -> %d distinct badge (accent) codes: %s" % (len(theme_colors), len(codes), codes))
if not codes:
    finish()

# ---- isolated tmux ----------------------------------------------------------------
def T(*a):
    r = subprocess.run(["tmux", "-L", SOCK] + list(a), capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("tmux %s failed: %s" % (" ".join(a[:3]), r.stderr.strip()))
    return r.stdout.rstrip("\n")

try:
    T("-f", CONF, "new-session", "-d", "-s", "s", "-x", "400", "-y", "20", "sleep 600")
    T("new-window", "-t", "s:1", "-n", "claudewin", os.path.join(WORK, "bin", "claude") + " 600")
    T("new-window", "-t", "s:2", "-n", "plain", "sleep 600")
except RuntimeError as e:
    bad("isolated tmux failed to start with %s: %s" % (CONF, e))
    finish()
v = ""
for _ in range(40):
    v = T("display", "-p", "-t", "s:1", "#{pane_current_command}")
    if v and v != "sh": break
    time.sleep(0.1)
check(v == "claude", "stub window reports pane_current_command=claude (got %r)" % v)
check(T("display", "-p", "-t", "s:2", "#{pane_current_command}") != "claude", "plain window is not detected as Claude")

TAG = re.compile(r"#\[([^\]]*)\]")
def parse(s):
    runs = []; cur = {"fg": "default", "bg": "default"}
    dflt = dict(cur); stack = []; pos = 0
    def emit(t):
        if t: runs.append((cur["fg"], cur["bg"], t))
    for m in TAG.finditer(s):
        emit(s[pos:m.start()]); pos = m.end()
        for tok in re.split(r"[ ,]+", m.group(1).strip()):
            if tok == "default": cur.update(dflt)
            elif tok == "push-default": stack.append(dict(dflt)); dflt = dict(cur)
            elif tok == "pop-default": dflt = stack.pop() if stack else dflt
            elif tok.startswith("fg="): cur["fg"] = tok[3:]
            elif tok.startswith("bg="): cur["bg"] = tok[3:]
    emit(s[pos:])
    return runs
def num(c):
    m = re.fullmatch(r"colour(\d+)", c); return int(m.group(1)) if m else None
def label_style(expanded):
    for fg, bg, t in parse(expanded):
        if t.strip(): return num(fg), num(bg)
    return None, None
def r_or_0(fg, bg):
    return ratio(fg, bg) if fg is not None and bg is not None else 0.0
def expand(win, opt):
    return T("display", "-p", "-t", "s:" + win, "#{T:%s}" % opt)

ambers = set()
for c in codes:
    who = ",".join(sorted(sources[c]))
    T("set", "-t", "s", "status-left-style", "bg=colour%d,fg=colour255,bold" % c)
    fg, bg = label_style(expand("2", "window-status-format"))
    if bg != c:
        bad("badge %3d (%s) non-selected: unexpected style fg=%s bg=%s" % (c, who, fg, bg))
    else:
        r = r_or_0(fg, bg)
        check(r >= MIN_RATIO, "badge %3d (%s) non-selected: fg colour%s on colour%s = %5.2f:1" % (c, who, fg, bg, r))
    fg, bg = label_style(expand("2", "window-status-current-format"))
    if bg != 16:
        bad("badge %3d (%s) selected: unexpected style fg=%s bg=%s" % (c, who, fg, bg))
    else:
        r = r_or_0(fg, bg)
        check(r >= MIN_RATIO, "badge %3d (%s) selected    : fg colour%s on colour%s = %5.2f:1" % (c, who, fg, bg, r))
    for st, opt in (("non-selected", "window-status-format"), ("selected    ", "window-status-current-format")):
        fg, bg = label_style(expand("1", opt))
        if st.startswith("non"): ambers.add(bg)
        r = r_or_0(fg, bg)
        check(r >= MIN_RATIO, "badge %3d (%s) Claude %s: fg colour%s on colour%s = %5.2f:1" % (c, who, st, fg, bg, r))
check(len(ambers) == 1 and None not in ambers,
      "Claude non-selected bg is one amber independent of the badge: %s" % sorted(map(str, ambers)))
finish()
PY
