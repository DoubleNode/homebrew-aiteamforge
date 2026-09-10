#!/usr/bin/env python3
"""Window-scoped local watcher that mirrors a REMOTE Claude session's
"claude_active" OSC 1337 user-var onto its iTerm2 tab's titleOverride.

XACA-1144 / DESIGN-DECISION-005 ("window-scoped local watcher")
-----------------------------------------------------------------
`iterm2_tab_title_prefix.py` (XACA-0214) drives the LOCAL iTerm2 API and
resolves its target session via tmux `#{client_tty}` or `$ITERM_SESSION_ID`
in the environment it is invoked from. That works when Claude itself runs on
the SAME machine as the iTerm2 that must be updated. A remote-team Claude
session runs on the remote host, has no local iTerm2, and cannot reach one —
that script structurally cannot work across machines.

The fix is not a new transport: `iterm2_set_user_var()` in
iterm2_badge_helper.sh already fires OSC 1337 `SetUserVar=claude_active=<val>`
wrapped in tmux DCS passthrough when `$TMUX` is set, and that escape is
verified to cross ssh+tmux to the viewing terminal (`allow-passthrough on`,
tmux 3.6a). What's missing on the VIEWING side is something to listen for it
and re-render the tab, because the render channel that beat every other
option in this feature area (XACA-0214 round 2) is `tab.titleOverride`, which
is a LOCAL iTerm2 object mutated only through the Python API.

This script is that listener. It is started by <team>-connect.sh once per
connect invocation (after every agent tab and panel for that window already
exists) and killed by the matching <team>-disconnect.sh — window-scoped and
lifecycle-bound to the connect flow, not a persistent daemon (rejected as
DESIGN-DECISION-005 R3: unnecessary supervised surface for a LaunchAgent that
buys nothing a window-scoped process doesn't already give for free).

Label derivation (must be DERIVED, not passed):
    Each tab's base label is seeded at subscribe time by reading that tab's
    current `titleOverride` and stripping the "C " prefix if already
    present, and cached for the lifetime of this process. It is
    re-derived (XACA-1144-016) on every 0->1 activation edge — never on
    every transition — by re-reading `titleOverride` at that moment and
    stripping the prefix defensively, then re-caching the result. This
    matters because a tab is only ever read while it is KNOWN unprefixed
    (deactivation always leaves it that way first), so a manual rename made
    any time between a deactivation and the next activation is picked up
    instead of silently overwritten and permanently lost — matching
    iterm2_tab_title_prefix.py's local-path behaviour — while an in-flight
    "C <label>" write can never be misread as the base label, because the
    read never happens mid-activation. The value is otherwise stable across
    a remote ssh/tmux reconnect (the local iTerm2 tab/session identity — and
    hence its titleOverride — does not change when the underlying ssh drops
    and remote-tmux-attach.sh's retry loop reattaches; only the remote
    connection state does).

Idempotency (must match iterm2_tab_title_prefix.py's contract exactly):
    Every title write recomputes the FULL target string from the cached base
    label (`"C " + base_label` or `base_label`) and compares it against the
    tab's current titleOverride before writing — never string-concatenates
    onto whatever is currently displayed. Activating twice therefore cannot
    produce "C C "; deactivating a tab whose title is not currently prefixed
    is a pure no-op (the computed target equals the current value, so no
    write happens).

Refcounting for multiple Claude sessions in one tab (XACA-0214's
_iterm_refcount_file / set_claude_active, DELIBERATELY MIRRORED, not reused):
    iterm2_badge_helper.sh refcounts in a FILE under
    ~/.claude/.iterm_tab_refcount/ because each hook invocation there is an
    independent, short-lived process (a SessionStart/Stop hook) that needs to
    coordinate with sibling processes it cannot hold a reference to. This
    watcher is a single long-lived asyncio process that already holds live
    handles to every session it watches, so the same "don't clear until the
    last active session says so" rule is implemented as an in-memory set of
    session ids per tab (see _apply_transition) guarded by one asyncio.Lock
    per watcher — no file, no lock directory, no cross-process race, because
    there is no second process to race against. The externally-visible
    behaviour matches the badge helper's refcount exactly: the tab is
    prefixed on the first session's 0->1 transition and unprefixed only when
    the LAST active session in that tab goes back to 0.

Fail-safe, always (per DESIGN-DECISION-005's failure-direction argument):
    If the iTerm2 API is unreachable, the socket is denied, the target
    window/tab/session cannot be resolved, or literally anything else goes
    wrong, this script exits 0 without ever mutating titleOverride. A dead or
    absent watcher degrades to exactly today's behaviour — correct tab
    labels, no "C " indicator — which is the whole reason this design won
    over the Dynamic Profile alternative (R2), which fails in the opposite,
    unsafe direction.

Termination and crash recovery (XACA-1144-017/018):
    A single session's watch task exiting via an UNEXPECTED exception
    (never `CancelledError`, never a real claude_active=0) discards that
    session from its tab's in-memory active-set exactly as a real
    deactivation would (see `_watch_session`'s except block), so a tab whose
    only active session dies this way still reverts its "C " prefix instead
    of sticking on for the rest of the watcher's life. Separately, if this
    whole PROCESS is killed (SIGTERM — socket drop, sleep/wake, a disconnect
    whose AppleScript window-close step failed, or anything else that ends
    it outright rather than through the normal per-session path), a SIGTERM
    handler installed in `_main` reverts every tab this watcher ever
    prefixed before the process exits (see `_clear_all_tabs`). Both paths
    exist because they cover different failures: the first is one session
    among several misbehaving while the watcher itself stays alive; the
    second is the watcher itself dying with no code left running to notice.

Invocation:
    iterm2_claude_active_watch.py --window-title "<instance> @ <host>"

This process is not expected to return under normal operation — it runs for
the life of the connect window and is terminated (SIGTERM) by
<team>-disconnect.sh. See ADDENDUM 2 in DESIGN-DECISION-005.md for the exact
connect/disconnect call sites.
"""

from __future__ import annotations

import argparse
import asyncio
import os
import signal
import sys

# Bootstrap: re-exec under the tap-owned venv that has `iterm2` if running
# under system python3. Must come before any `import iterm2`. Mirrors
# iterm2_tab_title_prefix.py exactly — both files live in scripts/, so the
# bootstrap module resolves from the same directory on every install layout
# (dev-team checkout, worktree, or tap consumer once XACA-1144-002 ships it).
_bootstrap_dir = os.path.dirname(os.path.abspath(__file__))
if _bootstrap_dir not in sys.path:
    sys.path.insert(0, _bootstrap_dir)
try:
    import iterm2_venv_bootstrap  # noqa: F401 — side-effect: re-exec if needed
except ImportError:
    pass  # dev machine: iterm2 installed globally, bootstrap not required

# The fully-qualified iTerm2 user-variable name (session-scoped) and the
# literal "active" value convention agreed in DESIGN-DECISION-005 (`<1|0>`).
# NOTE: this is a NEW use of the existing iterm2_set_user_var() transport —
# today it is only wired up for claude_badge. Wiring the remote hooks
# (kanban-session-start.py / kanban-stop.py, via set_claude_active /
# clear_claude_active in iterm2_badge_helper.sh) to also fire
# `iterm2_set_user_var claude_active 1|0` at the same 0->1 / ->0 refcount
# transitions they already detect is XACA-1144-006/007's other half — see
# the CHANGELOG entry for the exact call sites touched alongside this file.
USER_VAR_NAME = "user.claude_active"
ACTIVE_VALUE = "1"
CLAUDE_PREFIX = "C "


async def _find_window_by_title(app, title: str):
    """Find a window by its `user.window_title` variable.

    Mirrors iterm2_window_manager.py's find_window_by_title() exactly (same
    resolution convention connect.sh already relies on for --window-title
    lookups) but is duplicated here rather than imported: that module is a
    multi-action CLI with its own argument parsing and top-level side
    effects, and every sibling script in this family (iterm2_tab_title_prefix.py
    included) already keeps its own small lookup helper rather than
    depending on it as a library.
    """
    for window in app.windows:
        try:
            var_title = await window.async_get_variable("user.window_title")
        except Exception:
            continue
        if var_title == title:
            return window
    return None


async def _set_tab_title(tab, base_label: str, activate: bool) -> None:
    """Idempotently set `tab`'s titleOverride to the prefixed/unprefixed form.

    Always recomputes the FULL target from `base_label` (never strips/appends
    onto whatever is currently displayed) and only writes when the computed
    target differs from the current value. Any failure to read or write
    leaves the tab untouched — fail-safe per the module docstring.
    """
    try:
        current = await tab.async_get_variable("titleOverride")
    except Exception:
        return
    current = current or ""

    target = (CLAUDE_PREFIX + base_label) if activate else base_label
    if target == current:
        return  # already in the desired state — idempotent no-op

    try:
        await tab.async_set_title(target)
    except Exception:
        return


async def _derive_base_label(tab, fallback: str) -> str:
    """XACA-1144-016: re-read `tab`'s CURRENT titleOverride and strip the
    "C " prefix defensively, so a manual rename made while the tab was
    unprefixed is picked up instead of the value cached at process startup.

    Only ever called at a 0->1 activation edge — i.e. only when the tab is
    already known to be in its unprefixed state — so this can never read
    back an in-flight "C <label>" write as though it were the base label.
    Falls back to the previously-cached label (never to an empty string) on
    any read failure or an empty/missing titleOverride: fail-safe, per the
    module docstring — a rename that can't be read is not a reason to lose
    the label entirely.
    """
    try:
        current = await tab.async_get_variable("titleOverride")
    except Exception:
        return fallback
    current = current or ""
    if not current:
        return fallback
    return current[len(CLAUDE_PREFIX):] if current.startswith(CLAUDE_PREFIX) else current


async def _clear_all_tabs(tab_state: dict, lock: asyncio.Lock) -> None:
    """XACA-1144-017: best-effort revert every known tab to its unprefixed
    label. Called from the SIGTERM handler wired up in `_main` so a watcher
    that is killed outright (crash, sleep/wake socket drop, a disconnect
    whose AppleScript window-close step failed) never leaves a tab stuck
    showing "C <label>" for the rest of the session — the same stuck-on
    failure family XACA-0223 fixed for the local heuristic clear.

    Deactivating an already-unprefixed tab is a no-op per `_set_tab_title`'s
    own idempotency check, so this runs unconditionally against every tab
    regardless of its in-memory active-set state — no need to check `active`
    first. Must never raise: a cleanup handler that throws mid-shutdown is
    worse than no handler at all (per DESIGN-DECISION-005's fail-safe
    invariant), so each tab's cleanup is isolated from its siblings'.
    """
    for state in list(tab_state.values()):
        try:
            async with lock:
                state["active"].clear()
            await _set_tab_title(state["tab"], state["base_label"], activate=False)
        except Exception:
            continue


async def _apply_transition(
    tab_state: dict,
    lock: asyncio.Lock,
    tab_id: str,
    session_id: str,
    is_active: bool,
) -> None:
    """Update one session's membership in its tab's active-set and, only on
    a 0<->nonzero refcount edge, mutate that tab's title. See the module
    docstring's "Refcounting" section for why this is an in-memory set
    rather than iterm2_badge_helper.sh's file-based refcount.
    """
    async with lock:
        state = tab_state.get(tab_id)
        if state is None:
            return
        active = state["active"]
        was_empty = len(active) == 0
        if is_active:
            active.add(session_id)
        else:
            active.discard(session_id)
        now_empty = len(active) == 0

        if was_empty and not now_empty:
            # --- XACA-1144-016 BEGIN ---
            state["base_label"] = await _derive_base_label(state["tab"], state["base_label"])
            # --- XACA-1144-016 END ---
            await _set_tab_title(state["tab"], state["base_label"], activate=True)
        elif not was_empty and now_empty:
            await _set_tab_title(state["tab"], state["base_label"], activate=False)


async def _watch_session(
    connection,
    session,
    tab_id: str,
    tab_state: dict,
    lock: asyncio.Lock,
) -> None:
    """Subscribe to one session's claude_active user var for the life of
    this watcher process. Never raises — any failure (API unavailable,
    session closed, socket denied) simply ends this one task; sibling
    sessions/tabs are unaffected.
    """
    import iterm2  # local import: safe even if the module-level bootstrap failed

    try:
        async with iterm2.VariableMonitor(
            connection,
            iterm2.VariableScopes.SESSION,
            USER_VAR_NAME,
            session.session_id,
        ) as monitor:
            # Seed with the CURRENT value now that we are subscribed (not
            # before) — reading first and subscribing second would risk
            # missing a transition that lands in between. A redundant seed
            # transition (already-active session re-reported active) is a
            # harmless no-op per _apply_transition's idempotent set logic.
            try:
                initial = await session.async_get_variable(USER_VAR_NAME)
            except Exception:
                initial = None
            await _apply_transition(
                tab_state, lock, tab_id, session.session_id, initial == ACTIVE_VALUE
            )

            while True:
                new_value = await monitor.async_get()
                await _apply_transition(
                    tab_state, lock, tab_id, session.session_id, new_value == ACTIVE_VALUE
                )
    except asyncio.CancelledError:
        raise
    except Exception:
        # --- XACA-1144-018 BEGIN ---
        # An unexpected exception (never CancelledError, never a real
        # claude_active=0) must not leave this session stuck in its tab's
        # active-set — discard it exactly as a real deactivation would, so a
        # tab whose only active session died this way reverts its "C "
        # prefix instead of sticking on for the life of the watcher.
        try:
            await _apply_transition(tab_state, lock, tab_id, session.session_id, False)
        except Exception:
            pass
        # --- XACA-1144-018 END ---
        return


async def _main(connection, window_title: str) -> None:
    import iterm2

    app = await iterm2.async_get_app(connection)
    window = await _find_window_by_title(app, window_title)
    if window is None:
        return  # window not found (yet, or ever) — fail-safe: do nothing

    # Enumerate the window's tabs/sessions ONCE, at startup. The connect
    # script starts this watcher only after every agent tab and panel for
    # this window already exists (see ADDENDUM 2 in DESIGN-DECISION-005.md),
    # so this snapshot is the complete, final tab set for this connect
    # invocation — a tab created after this point would not be picked up,
    # which never happens in the current connect flow.
    tab_state: dict[str, dict] = {}
    watch_tasks: list[asyncio.Task] = []
    # One lock shared by every watched session in this window: transitions on
    # the SAME tab (e.g. the main session and its split agent panel both
    # touching claude_active) must be serialized so the active-set read and
    # the resulting title write can't interleave. Cross-tab contention on the
    # same lock is harmless — these are cheap, infrequent UI-decoration writes.
    lock = asyncio.Lock()
    for tab in window.tabs:
        try:
            current_title = await tab.async_get_variable("titleOverride")
        except Exception:
            current_title = ""
        current_title = current_title or ""
        base_label = (
            current_title[len(CLAUDE_PREFIX):]
            if current_title.startswith(CLAUDE_PREFIX)
            else current_title
        )
        tab_state[tab.tab_id] = {"tab": tab, "base_label": base_label, "active": set()}

        for session in tab.sessions:
            watch_tasks.append(
                asyncio.ensure_future(
                    _watch_session(connection, session, tab.tab_id, tab_state, lock)
                )
            )

    if not watch_tasks:
        return

    # --- XACA-1144-017 BEGIN ---
    # Revert every prefixed tab if this PROCESS is killed outright (SIGTERM
    # — sent normally by <team>-disconnect.sh, but also delivered on a
    # crash/OOM-adjacent kill) rather than shutting down through the normal
    # per-session 0-refcount path. The signal callback itself only sets an
    # asyncio.Event — it does no I/O and cannot raise — so the actual
    # cleanup always runs on the event loop below, never inside a raw
    # signal handler.
    shutdown_event = asyncio.Event()

    def _on_sigterm() -> None:
        shutdown_event.set()

    loop = asyncio.get_running_loop()
    try:
        loop.add_signal_handler(signal.SIGTERM, _on_sigterm)
    except (NotImplementedError, RuntimeError):
        # Platform/loop combination without signal-handler support. Fail-safe:
        # no cleanup on SIGTERM, which is exactly pre-017 behaviour — never
        # worse than what shipped before.
        pass

    gather_task = asyncio.ensure_future(
        asyncio.gather(*watch_tasks, return_exceptions=True)
    )
    shutdown_task = asyncio.ensure_future(shutdown_event.wait())
    try:
        # Runs until every session task ends on its own, or SIGTERM arrives —
        # not expected to return under normal operation.
        await asyncio.wait(
            {gather_task, shutdown_task}, return_when=asyncio.FIRST_COMPLETED
        )
        if shutdown_task.done() and not gather_task.done():
            for task in watch_tasks:
                task.cancel()
            try:
                await _clear_all_tabs(tab_state, lock)
            except Exception:
                pass
    finally:
        for pending in (gather_task, shutdown_task):
            if not pending.done():
                pending.cancel()
        # Await every task above, cancelled or not: an already-done task's
        # await just returns/re-raises its stored result immediately (no
        # re-execution), so this is always safe, and it prevents asyncio
        # from logging a spurious "exception was never retrieved" warning
        # for the cancelled gather future on every normal SIGTERM shutdown.
        for pending in (gather_task, shutdown_task):
            try:
                await pending
            except asyncio.CancelledError:
                # Expected: this is the task we just cancelled ourselves,
                # two lines up — swallow it here rather than letting it
                # escape (CancelledError is BaseException, not Exception,
                # in Python 3.8+, so a bare `except Exception` would NOT
                # catch it and this cleanup would itself abort _main).
                pass
            except Exception:
                pass
    # --- XACA-1144-017 END ---


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    ap.add_argument(
        "--window-title",
        required=True,
        help='The connect script\'s $ITERM_WINDOW_NAME ("<instance> @ <host>").',
    )
    args = ap.parse_args()

    try:
        import iterm2
    except ImportError:
        print("[iterm2_claude_active_watch] iterm2 module unavailable; exiting", file=sys.stderr)
        return 0

    try:
        iterm2.run_until_complete(lambda conn: _main(conn, args.window_title))
    except Exception as exc:  # noqa: BLE001 — best-effort UI decoration, never fatal
        print(f"[iterm2_claude_active_watch] iTerm2 API call failed: {exc}", file=sys.stderr)
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
