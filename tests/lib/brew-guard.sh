#!/bin/bash
# tests/lib/brew-guard.sh — systemic backstop so NO test suite can ever reach
# a real, unstubbed, MUTATING `brew` command (XACA-1222).
#
# Background: test-xaca-0463-port-allocation.sh ran install-team.sh with a
# REAL brew on PATH during a full tests/test-runner.sh run, and install-team.sh
# executed `brew install --cask android-studio` — a real network fetch/host
# mutation from inside a supposedly-sandboxed test run (see ci-manifest, which
# classifies that suite "plain-shell": no real brew mutation is ever supposed
# to be reachable from it). That suite is being fixed directly under
# XACA-1222-001; THIS file is the systemic guard so no other suite — present
# or future — can reach the same failure mode, even one that forgets to stub
# brew itself.
#
# Design (fail-closed allowlist, not a denylist):
#   - A shim `brew` executable is written to a throwaway directory, and that
#     directory is prepended to PATH (exported, so every CHILD PROCESS —
#     which is how test-runner.sh's run_test_file() invokes every suite —
#     inherits it automatically; no per-suite opt-in required).
#   - The shim inspects argv[1] (brew's subcommand, or a leading `--flag`
#     global option — brew's own grammar always puts one of these first).
#     Only a small, explicit ALLOWLIST of READ-ONLY subcommands is passed
#     through to the real brew (resolved once, at guard-install time, before
#     the shim directory is on PATH, so it can never resolve to itself).
#     EVERYTHING ELSE — every mutating subcommand (install, reinstall,
#     upgrade, uninstall/remove/rm, tap, untap, link, unlink, cleanup,
#     services, update, bundle, pin/unpin, autoremove, postinstall, ...) and
#     any subcommand this guard does not recognize — is BLOCKED. Unknown is
#     treated as mutating. This is deliberate: a new brew subcommand nobody
#     has taught this guard about must fail closed, not pass through.
#   - A suite that already installs its OWN brew stub (there are several —
#     test-xaca-1216-flat-persona-deploy.sh, test-xaca-1162-dry-run-is-
#     read-only.sh, test-xaca-0704-positive.sh, test-xaca-0676-tap-trust.sh,
#     etc.) is UNAFFECTED: PATH is a stack, and a suite that prepends its own
#     stub directory after this guard has already run simply puts its own
#     `brew` ahead of this one. Its stub wins, exactly as before.
#   - The shim is fail-closed even if the block is somehow ignored by its
#     caller: install-team.sh's real code does
#       brew install "$dep" || { warn "..."; ... }
#     which swallows a non-zero exit code entirely. The shim ALSO appends a
#     line to a marker file every time it blocks something, independent of
#     what its own exit code does or does not trigger downstream. Callers
#     that can (test-runner.sh's run_test_file(), via brew_guard_assert
#     below) check that marker file after every suite and fail the suite
#     regardless of what the suite itself reported.
#
# Portability: this file and the shim it writes MUST work under /bin/bash 3.2
# (macOS's shipped bash) AND bash 5 (CI installs a newer bash for some
# suites — see the ci-manifest "brew-bash" category note). No associative
# arrays, no ${var,,}, no mapfile, no `[[ ... ]]` string comparisons using
# operators zsh's `[` would choke on (this file is bash-only, invoked via
# `bash`/`source`, never zsh, but is written defensively anyway).

# ─────────────────────────────────────────────────────────────────────────
# _brew_guard_sweep_stale_dirs — XACA-1222-013: standalone-mode leak sweep.
#
# Three suites in this directory (test-tailscale.sh, test-xaca-0650-doctor-
# venv.sh, test-doctor-fix.sh) `source` test-runner.sh directly and then
# install their OWN `trap ... EXIT` — test-xaca-0650-doctor-venv.sh and
# test-doctor-fix.sh replace test-runner.sh's `_runner_exit_cleanup`
# outright (a later `trap ... EXIT` simply overwrites the earlier one, it
# does not chain), so `brew_guard_cleanup` never runs when either of those
# two is invoked standalone; test-tailscale.sh chains onto whatever EXIT
# trap it captures via `trap -p EXIT` at that point in its own script,
# which is only as reliable as exactly when that capture happens to run.
# Either way, cleanup of the shim dir must not depend on an EXIT trap
# actually being wired up in these processes by the time they exit.
#
# Fix: every brew_guard_install() call sweeps its OWN family of sibling
# dirs under the temp root FIRST, before creating a new one, removing any
# whose embedded PID (parsed from the dir NAME itself — never trusted from
# anywhere else) is no longer alive. `kill -0 <pid>` is the standard
# liveness probe (sends no signal, only checks the process exists and is
# signalable) — a dead PID can never come back to use or clean up its own
# dir, so removing it is safe. A dir whose PID IS alive, or whose name does
# not parse as this exact naming shape, is left strictly alone: this must
# never sweep something it cannot positively attribute to a dead brew-guard
# instance of its own.
# ─────────────────────────────────────────────────────────────────────────
_brew_guard_sweep_stale_dirs() {
  local _root="${TMPDIR:-/tmp}"
  local _d _base _pid
  # A literal, non-matching glob (no `aiteamforge-brewguard.*` dirs present)
  # expands to itself under bash 3.2's default (non-nullglob) globbing —
  # the `[ -d "$_d" ] || continue` guard below filters that case out
  # without depending on `shopt -s nullglob`, which this file avoids since
  # it is sourced into callers' shells and must not change their glob
  # behavior as a side effect.
  for _d in "$_root"/aiteamforge-brewguard.*; do
    [ -d "$_d" ] || continue
    _base="$(basename "$_d")"
    _pid="$(printf '%s' "$_base" | sed -n 's/^aiteamforge-brewguard\.\([0-9][0-9]*\)\..*/\1/p')"
    [ -n "$_pid" ] || continue
    if ! kill -0 "$_pid" 2>/dev/null; then
      rm -rf "$_d" 2>/dev/null || true
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────────
# brew_guard_install — idempotent. Creates the shim + prepends it to PATH.
# Safe to call multiple times (e.g. once from test-runner.sh's own top-level
# code, and again when a suite `source`s test-runner.sh) — every call after
# the first is a cheap no-op guarded by AITEAMFORGE_BREW_GUARD_ACTIVE.
# ─────────────────────────────────────────────────────────────────────────
brew_guard_install() {
  if [ "${AITEAMFORGE_BREW_GUARD_ACTIVE:-}" = "1" ]; then
    # Already installed in this process tree (inherited via export, or a
    # prior call in this same process). Nothing to do — PATH already carries
    # the shim dir, and any suite-local stub prepended in front of it is
    # left exactly where the suite put it.
    return 0
  fi

  # Resolve the REAL brew BEFORE the shim dir is anywhere near PATH, so this
  # can never resolve to itself. Empty means no real brew on this host/PATH;
  # that case is handled immediately below by not installing a shim at all.
  local _real_brew
  _real_brew="$(command -v brew 2>/dev/null || true)"

  # No real brew on this host (e.g. the ubuntu CI runner): there is nothing to
  # protect — an unstubbed `brew install` already dies with command-not-found.
  # Installing the shim here would be actively harmful: it would make
  # `command -v brew` SUCCEED where it used to fail, steering code under test
  # (and suites that probe for brew) down brew-present branches they never
  # took before. Mark the guard active so repeat calls stay no-ops, and leave
  # PATH untouched.
  if [ -z "$_real_brew" ]; then
    export AITEAMFORGE_BREW_GUARD_ACTIVE=1
    if [ "${VERBOSE:-false}" = "true" ]; then
      echo "XACA-1222 BREW GUARD: no real brew on PATH — nothing to guard, shim not installed" >&2
    fi
    return 0
  fi

  # XACA-1222-013: sweep any sibling dirs left behind by a DEAD prior
  # instance before creating our own — see _brew_guard_sweep_stale_dirs's
  # own header comment for why this cannot rely on a trap having run.
  _brew_guard_sweep_stale_dirs

  # XACA-1222-013: a full path template (not `-t PREFIX`) so BSD/macOS
  # mktemp expands the trailing XXXXXX correctly. `-t PREFIX` on BSD/macOS
  # treats the ENTIRE argument as a filename prefix and appends its own
  # random suffix — the literal characters "XXXXXX" are NOT treated as a
  # template there (same gotcha test-runner.sh's own setup_test_env
  # documents for TEST_TMP_DIR), so the old `-t aiteamforge-brewguard.XXXXXX`
  # form produced dirs literally named ...XXXXXX.<random> on macOS. The
  # embedded "$$" here is the CURRENT process's PID at creation time — this
  # is what makes the created dir attributable to a specific process for
  # the sweep above, on the NEXT brew_guard_install() call anywhere.
  local _dir
  _dir="$(mktemp -d "${TMPDIR:-/tmp}/aiteamforge-brewguard.$$.XXXXXX")" || {
    echo "XACA-1222 BREW GUARD: mktemp -d failed — cannot install the brew guard. Refusing to continue without it (fail closed)." >&2
    return 1
  }

  local _marker="$_dir/violations.log"
  : > "$_marker"

  # Single-quoted heredoc: nothing here expands at WRITE time. The shim reads
  # its configuration from the exported AITEAMFORGE_BREW_GUARD_* env vars at
  # RUN time instead, so brew_guard_reset can rotate the marker file per
  # suite without ever having to rewrite this script.
  cat > "$_dir/brew" <<'SHIM_EOF'
#!/bin/bash
# AUTO-GENERATED by tests/lib/brew-guard.sh (XACA-1222). Do not edit by hand —
# regenerate via brew_guard_install. See that file for the full rationale.
set -u

_sub="${1:-}"
_argv_display="brew $*"

# Fail-closed ALLOWLIST of read-only brew invocations. Anything not
# explicitly listed here — including a subcommand this list has never heard
# of — falls through to the BLOCK path below.
_readonly=0
case "$_sub" in
  --prefix|--version|--cellar|--repository|--repo|--cache|--caskroom|--env|\
  list|ls|info|abv|outdated|deps|uses|leaves|desc|options|\
  config|formulae|casks|--help|-h|help)
    _readonly=1
    ;;
  tap)
    # BARE `brew tap` (no further args) only LISTS installed taps, and
    # production code calls exactly that (aiteamforge-doctor.sh
    # check_tap_trust(), aiteamforge-setup.sh's XACA-0676 tap-trust block).
    # Any argument at all — a tap name, --repair, --force — is a mutation.
    if [ "$#" -eq 1 ]; then
      _readonly=1
    fi
    ;;
esac
# Deliberately NOT allowlisted, although they sound read-only: `analytics`
# (`brew analytics off` writes config), `style` (bundle-installs gems),
# `which-update` (writes a DB), `search`/`home`/`homepage` (network / open a
# browser), `doctor`/`audit`/`readall`/`command`/`commands` (can load
# taps/cmds and run arbitrary Ruby). No production path under test calls any
# of them; they fall through to BLOCK like any other unknown.
#
# XACA-1222-012: `shellenv` was removed from the allowlist above. Passing it
# through to the real brew is actively dangerous under test — code under
# test that ran `eval "$(brew shellenv)"` would put the REAL brew's bin dir
# ahead of this shim on PATH for the rest of that process, defeating the
# guard for everything after. A tree-wide grep (libexec/, bin/, share/)
# found no shipped caller of `brew shellenv`, so removing it is
# behavior-neutral for production code; unknown now falls through to BLOCK
# like any other unrecognized subcommand.

# XACA-1222-012: even an ALLOWLISTED subcommand must not reach the network
# or the browser via a flag that changes what it actually does. Checked
# only when the subcommand itself was otherwise allowlisted above — this is
# a narrowing of the allowlist, never a way to allow something new.
#   --github      info/related flags that fetch GitHub API data
#   --analytics   info --analytics fetches installation analytics over the network
#   --fetch-HEAD  outdated/info --fetch-HEAD forces a live git fetch
#   --search      desc --search scans/searches EVERY formula's description —
#                 a materially heavier, different operation than a plain
#                 `brew desc <formula>` lookup
if [ "$_readonly" -eq 1 ]; then
  for _flag_arg in "$@"; do
    case "$_flag_arg" in
      --github|--analytics|--fetch-HEAD|--search)
        _readonly=0
        break
        ;;
    esac
  done
fi

# Even an allowlisted subcommand must not reach the network or rewrite the
# Homebrew repo: `outdated` and `info` both trigger brew's auto-update.
#
# Do NOT add HOMEBREW_NO_INSTALL_FROM_API here (PR #902 review round 2). It
# sounds like "stay offline" and does the opposite: with it set, a lookup of
# a name no installed tap knows (`brew list aiteamforge`, `brew info
# aiteamforge` — both reached from shipped config.sh/common.sh) falls through
# to the core-tap path, which on a Homebrew 4+ host without homebrew/core
# tapped runs a full `git clone` of homebrew-core into the brew prefix.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ANALYTICS=1

if [ "$_readonly" -eq 1 ]; then
  _real="${AITEAMFORGE_BREW_GUARD_REAL_BREW:-}"
  if [ -n "$_real" ] && [ -x "$_real" ]; then
    exec "$_real" "$@"
  fi
  echo "XACA-1222 BREW GUARD: read-only call ($_argv_display) but no real brew was found on PATH at guard-install time — cannot pass through. Failing closed." >&2
  exit 97
fi

# Everything else: MUTATING or UNRECOGNIZED. Block. Never touch the real brew.
_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown-time)"
_msg="XACA-1222 BREW GUARD: BLOCKED mutating/unrecognized brew invocation: ${_argv_display} (pid=$$ cwd=${PWD:-?} ts=${_ts} test_file=${CURRENT_TEST_FILE:-unset}) — this suite reached a REAL brew mutation path. It must stub brew itself (see tests/README.md 'Brew Guard' section and tests/lib/brew-guard.sh), or the code path under test must not shell out to a mutating brew subcommand during tests. The real brew was NEVER invoked."
echo "$_msg" >&2

_marker="${AITEAMFORGE_BREW_GUARD_MARKER:-}"
if [ -n "$_marker" ]; then
  echo "$_msg" >> "$_marker" 2>/dev/null || true
fi

exit 97
SHIM_EOF

  chmod +x "$_dir/brew" || {
    echo "XACA-1222 BREW GUARD: chmod +x on the shim failed — refusing to continue without an executable guard (fail closed)." >&2
    return 1
  }

  export AITEAMFORGE_BREW_GUARD_ACTIVE=1
  # Only the process that CREATED the shim dir removes it (brew_guard_cleanup);
  # child suites inherit ACTIVE=1 and never create or delete one.
  export AITEAMFORGE_BREW_GUARD_OWNER_PID="$$"
  export AITEAMFORGE_BREW_GUARD_DIR="$_dir"
  export AITEAMFORGE_BREW_GUARD_MARKER="$_marker"
  export AITEAMFORGE_BREW_GUARD_REAL_BREW="$_real_brew"
  export PATH="$_dir:$PATH"

  if [ "${VERBOSE:-false}" = "true" ]; then
    echo "XACA-1222 BREW GUARD: installed (shim=$_dir/brew, real_brew=${_real_brew:-<none found>})" >&2
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────
# brew_guard_reset — truncate the violations marker. Call before running a
# suite so each suite's marker reflects only what THAT suite triggered.
# No-op (not an error) if the guard was never installed.
# ─────────────────────────────────────────────────────────────────────────
brew_guard_reset() {
  if [ -n "${AITEAMFORGE_BREW_GUARD_MARKER:-}" ]; then
    # XACA-1222 BLOCKING fix: `: > "$m" 2>/dev/null` applies the redirects
    # left-to-right — if `> "$m"` itself fails to open (e.g. its directory
    # was already removed, exactly the "guard lost" scenario this ticket's
    # other fix addresses), bash's own "cannot create" diagnostic is
    # written to the CURRENT (still unredirected) stderr, because the
    # `2>/dev/null` that was meant to silence it is applied AFTER the
    # failing redirect in that same left-to-right list, and a failed
    # redirect aborts the command before the later ones take effect. Group
    # the truncation itself so `2>/dev/null` wraps the WHOLE group,
    # including any redirection failure inside it. brew_guard_assert is
    # what reports a lost guard loudly and on purpose; this function must
    # stay silent either way.
    { : > "$AITEAMFORGE_BREW_GUARD_MARKER"; } 2>/dev/null || true
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────
# brew_guard_assert [--strict] — returns 1 (and prints the violation log) if
# the current suite tripped the guard since the last brew_guard_reset.
# Mirrors the shape of test-runner.sh's own leak_guard_assert so callers can
# treat a trip as its own independent, unambiguous failure signal rather
# than trusting the suite's own (possibly swallowed) exit code or pass/fail
# bookkeeping.
#
# --strict (XACA-1222 BLOCKING fix): additionally verify the guard ITSELF is
# still intact — a "guard lost" detector, independent of (and a backstop
# for) test-runner.sh's own split EXIT/INT/TERM traps. Without this, a
# suite that deletes shared test infrastructure (accidentally or via a
# stray `rm -rf`), or any other way the shim dir/executable/marker go
# missing mid-run, leaves brew_guard_assert with nothing to check — no
# marker file means "nothing tripped it" even though the guard is gone and
# every REMAINING suite is now running with a real, unstubbed `brew` on
# PATH. Only run_test_file() passes --strict, exactly once per suite, from
# the OWNER process, after the suite's child `bash` has already exited.
# test-xaca-1222-brew-guard.sh's own positive/negative CONTROL fixtures
# (no-brew-host, suite-owns-its-own-stub, etc.) must NEVER pass --strict —
# those deliberately produce guard states (no shim installed at all, or a
# suite-local override winning the PATH race) that are correct by design,
# not a lost guard.
#
# The resolution check ("brew" in the CALLING shell still resolves to the
# guard's own shim) only makes sense in the runner's OWN shell: a suite can
# legitimately prepend its own stub ahead of the guard inside its OWN child
# `bash "$test_file"` process (see brew_guard_install's header comment,
# point 3) — but that process has already exited by the time run_test_file()
# calls this, and the runner's own shell never carries such an override. So
# in the runner, a mismatch can only mean the guard's position on PATH was
# disturbed, never a suite's legitimate choice.
# ─────────────────────────────────────────────────────────────────────────
brew_guard_assert() {
  local _strict=false
  if [ "${1:-}" = "--strict" ]; then
    _strict=true
    shift
  fi

  local _marker="${AITEAMFORGE_BREW_GUARD_MARKER:-}"

  # Set true only by the two "guard lost" branches below, so a caller can tell
  # "this suite tripped the guard" (the run can continue safely) from "the
  # guard is gone" (every later suite would run unprotected — stop).
  BREW_GUARD_LOST=false

  if [ "$_strict" = true ] && [ -n "${AITEAMFORGE_BREW_GUARD_DIR:-}" ]; then
    if [ ! -d "$AITEAMFORGE_BREW_GUARD_DIR" ] \
       || [ ! -x "$AITEAMFORGE_BREW_GUARD_DIR/brew" ] \
       || [ -z "$_marker" ] \
       || [ ! -f "$_marker" ]; then
      echo "XACA-1222 BREW GUARD: guard lost — $AITEAMFORGE_BREW_GUARD_DIR (its shim executable or marker file) no longer exists after this suite ran. A suite that deletes shared test infrastructure, or any interruption that skips cleanup ordering, can leave every REMAINING suite unprotected against a real brew mutation. Failing closed." >&2
      BREW_GUARD_LOST=true
      return 1
    fi

    local _resolved
    _resolved="$(command -v brew 2>/dev/null || true)"
    if [ -n "$_resolved" ] && [ "$_resolved" != "$AITEAMFORGE_BREW_GUARD_DIR/brew" ]; then
      echo "XACA-1222 BREW GUARD: guard lost — 'brew' in the runner's own shell now resolves to '$_resolved', not the guard shim '$AITEAMFORGE_BREW_GUARD_DIR/brew'. The runner's own PATH never carries a suite-local override (only a suite's own already-exited child process can add one), so this can only mean the guard's position on PATH was disturbed. Failing closed." >&2
      BREW_GUARD_LOST=true
      return 1
    fi
  fi

  if [ -z "$_marker" ] || [ ! -f "$_marker" ]; then
    # Guard not installed / marker missing — nothing to assert. This is not
    # itself a failure: callers that care whether the guard is active check
    # AITEAMFORGE_BREW_GUARD_ACTIVE separately. (When --strict applies and
    # the guard WAS installed, the block above already turned a missing
    # marker into a hard failure; this remaining branch covers the
    # legitimate "guard never installed at all" no-brew-host case.)
    return 0
  fi
  if [ -s "$_marker" ]; then
    echo "XACA-1222 BREW GUARD TRIPPED — this suite reached a blocked (mutating/unrecognized) brew invocation:" >&2
    cat "$_marker" >&2
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────
# brew_guard_cleanup — remove the shim dir, but ONLY from the process that
# created it. A child suite inherits AITEAMFORGE_BREW_GUARD_DIR via export;
# letting it delete the dir would strip the guard from every suite that runs
# after it in the same test-runner.sh invocation.
# ─────────────────────────────────────────────────────────────────────────
brew_guard_cleanup() {
  if [ "${AITEAMFORGE_BREW_GUARD_OWNER_PID:-}" = "$$" ] \
     && [ -n "${AITEAMFORGE_BREW_GUARD_DIR:-}" ] \
     && [ -d "$AITEAMFORGE_BREW_GUARD_DIR" ]; then
    rm -rf "$AITEAMFORGE_BREW_GUARD_DIR"
  fi
  return 0
}
