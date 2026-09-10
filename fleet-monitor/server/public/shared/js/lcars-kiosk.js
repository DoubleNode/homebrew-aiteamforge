//
//  lcars-kiosk.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * LCARS Kiosk Mode Module
 *
 * Standalone kiosk system for the Fleet Monitor dashboard.
 * Handles idle detection, automatic section rotation, and orgs auto-scroll.
 *
 * Import this file in all 4 dashboard app HTML files.
 * Exposes: window.LCARS_KIOSK
 *
 * Subitem coverage:
 *   001 - Idle detection (this file's primary concern)
 *   002 - Section rotation (enterKioskMode, rotateToNextSection, startRotation, stopRotation)
 *   003 - Orgs auto-scroll (startOrgsAutoScroll, stopOrgsAutoScroll)
 *   005 - Exit kiosk mode (exitKioskMode full implementation)
 */

(function() {
    'use strict';

    // =========================================================================
    // CONFIGURATION
    // =========================================================================

    const KIOSK_CONFIG = {
        enabled: true,             // in-memory/default kiosk enable state — see isEnabled()/setEnabled()
        idleTimeout: 150000,       // ms before kiosk activates (2.5 min)
        rotationInterval: 8000,    // ms between section rotations
        transitionDuration: 600,   // ms for transition animations
        enabledSections: ['overview', 'organizations', 'machines'],  // sections to rotate through
        orgsScrollDelay: 2000,     // ms between org/division scrolls
        debug: false,              // set true to enable console.log output
    };

    // XACA-1154-002: persisted enable/disable preference key. Follows the
    // 'lcars-<feature>-<state>' naming convention used elsewhere in this
    // codebase (e.g. 'lcars-sound-muted' in lcars-sound.js, 'lcars-section'
    // in lcars-dashboard-app.js, 'lcars-orgs-expanded' in
    // lcars-division-collapse.js).
    const KIOSK_ENABLED_STORAGE_KEY = 'lcars-kiosk-enabled';

    /** Log only when debug mode is enabled. */
    function _log() {
        if (KIOSK_CONFIG.debug) {
            console.log.apply(console, arguments);
        }
    }

    // =========================================================================
    // STATE
    // =========================================================================

    let idleTimer = null;
    let isKioskActive = false;
    let rotationTimer = null;
    let currentSectionIndex = 0;
    let priorSection = null;  // section active before kiosk started
    let orgsScrollTimer = null;
    let orgsScrollIndex = 0;
    let kioskMode = 'sections'; // 'sections' (legacy) or 'analytics' (new)

    // XACA-1154-016: shared idle-tracking event list, used by BOTH
    // startIdleMonitoring() and stopIdleMonitoring() so attach and remove can
    // never drift apart. This is the exact same drift hazard XACA-1154-005
    // eliminated for the exit set via KIOSK_EXIT_EVENTS_IMMEDIATE /
    // KIOSK_EXIT_EVENTS_MOVEMENT below — each of those had one definition
    // used by both add and remove; this list previously had two separate
    // inline copies (one per function) that a future edit could update in
    // one place and not the other.
    //
    // XACA-1154-020: 'scroll' stays on this list even though the same probe
    // session that excluded it from the EXIT set below (6145 scroll events
    // in 118s, largely self-inflicted by the page's own DOM updates)
    // measured it here too. The IDLE list and the EXIT set have OPPOSITE
    // risk polarity, so the same noise evidence does not imply the same
    // fix: a false positive here (the page's own DOM churn resetting the
    // idle countdown a bit more than necessary) is mildly wasteful at
    // worst. A false NEGATIVE here — dropping 'scroll' and missing a
    // genuine user scroll — lets the countdown expire while someone is
    // actively scrolling a long list, and kiosk seizes the dashboard out
    // from under them. That is not a theoretical risk: it is the
    // ORIGINATING bug report this entire ticket exists to fix (kiosk
    // seizing the dashboard roughly every 2.5 minutes), which is direct
    // empirical evidence that idle activation fires in practice on a real,
    // busy dashboard. Do not "fix" the scroll noise by removing it from
    // this list — that trades a fixed bug for a worse one. If the
    // self-inflicted DOM-churn noise ever needs addressing, do it by
    // reducing the page's own scroll/update volume, not by blinding idle
    // detection to real user scrolling.
    const KIOSK_IDLE_EVENTS = ['mousemove', 'mousedown', 'keypress', 'keydown', 'touchstart', 'scroll', 'click'];

    // Stored reference to the kiosk exit interaction handlers so they can be removed cleanly.
    // Split in two: events in KIOSK_EXIT_EVENTS_IMMEDIATE are unambiguous intent and exit on
    // the first occurrence; events in KIOSK_EXIT_EVENTS_MOVEMENT (mousemove/pointermove) only
    // exit once cumulative movement crosses KIOSK_MOVEMENT_EXIT_THRESHOLD_PX — see
    // _setupKioskExitHandler for the measured data behind these numbers (XACA-1154-005).
    let _boundKioskExitHandlerImmediate = null;
    let _boundKioskExitHandlerMovement = null;

    // XACA-1154-005: events that represent unambiguous user intent — exit immediately.
    // touchstart/touchend contribute nothing on a Mac trackpad (measured 0 occurrences in a
    // 118s probe session) but are kept for real touchscreen hardware. scroll is deliberately
    // EXCLUDED — a probe session measured 6145 scroll events in 118s (vastly more than any
    // other event, largely self-inflicted by the page's own DOM updates), making it unreliable
    // as an intent signal. wheel (221 in the same session) is the real user gesture and stays.
    const KIOSK_EXIT_EVENTS_IMMEDIATE = ['click', 'mousedown', 'pointerdown', 'keydown', 'touchstart', 'touchend', 'wheel'];

    // XACA-1154-005: movement events. A trackpad tap with "Tap to click" OFF emits NEITHER
    // mousedown NOR pointerdown NOR click — nothing at all (measured: the first 98s of a 118s
    // probe session had zero mousedown/pointerdown/click while mousemove/wheel fired
    // continuously). mousemove/pointermove is the only signal that configuration produces, so
    // it must be in the exit set — but gated behind a cumulative-distance threshold (below) so
    // stationary cursor noise can never exit on its own.
    const KIOSK_EXIT_EVENTS_MOVEMENT = ['mousemove', 'pointermove'];

    // XACA-1154-005: cumulative movement distance (px, Euclidean over movementX/movementY)
    // required before a run of mousemove/pointermove events is treated as exit intent. Measured
    // on real hardware (macOS Safari trackpad, 118s instrumented session):
    //   - noise at rest: movementX/Y=0/0 fires in bulk (hundreds of times) with the cursor
    //     stationary, contributing 0 to the accumulator; occasional micro-drift of +/-1-3px per
    //     axis was also observed (worst case hypot(3,3) = ~4.24px in a single event).
    //   - deliberate movement: single-event deltas of -18/-29, -21/-25, -40/-5, -62/-9, 20/-4,
    //     17/-3, 15/-2 (hypot ranges ~15.1px-71px).
    // 10px sits ~2.4x above the worst measured single-event noise (4.24px) and safely below the
    // smallest measured deliberate single-event signal (15.1px), so one or two real cursor
    // moves cross it immediately while stationary jitter never does.
    const KIOSK_MOVEMENT_EXIT_THRESHOLD_PX = 10;

    // XACA-1154-005: a movement event arriving more than this many ms after the previous one
    // starts a FRESH accumulation window (accumulator resets to 0 first). This is what prevents
    // slow drift over minutes from creeping across the threshold: the accumulator only sums
    // movement across a tight burst of closely-spaced events (a real, continuous cursor gesture
    // fires far faster than this, typically every 16-60ms), never across the gaps between
    // sparse, spontaneous noise events separated by hundreds of ms or more.
    const KIOSK_MOVEMENT_GAP_RESET_MS = 250;

    // Cumulative-movement accumulator state (reset on each kiosk entry and on threshold cross).
    let _kioskMoveAccumDist = 0;
    let _kioskMoveAccumLastTime = 0;

    // XACA-1154-005 follow-up: which movement event type this kiosk session is accumulating
    // from. A browser fires BOTH pointermove AND mousemove for a single physical cursor
    // motion, ~1-3ms apart, carrying IDENTICAL movementX/movementY — measured directly in the
    // probe trace, e.g. `pointermove -18/-29` at 17055ms followed by `mousemove -18/-29` at
    // 17058ms. Accumulating from both therefore counts every real movement TWICE, silently
    // halving the effective threshold: verified in jsdom that a 6px move delivered as the real
    // browser pair (6 + 6 = 12) crossed a 10px threshold, and that two worst-case noise pairs
    // (hypot(3,3) = 4.24 each, 8.49px of real motion) also crossed it — below the documented
    // design intent. Latching onto whichever type arrives first makes KIOSK_MOVEMENT_
    // EXIT_THRESHOLD_PX mean what it says: 10px of REAL cursor motion. It also degrades
    // correctly by construction — a browser with Pointer Events latches pointermove, one
    // without latches mousemove, and neither can double-count the other.
    let _kioskMoveAccumEventType = null;

    // XACA-1154-017: clientX/clientY fallback baseline, used ONLY when an engine never
    // populates movementX/movementY at all (typeof !== 'number' — the cockpit WKWebView is an
    // unverified surface and a real candidate). Without this fallback, dx/dy below would
    // permanently read 0/0 on such an engine, every movement event would hit the "pure noise"
    // early return, and the load-bearing half of this whole fix — the ability for cursor
    // movement to exit kiosk without a click — would be silently inert. null means "no previous
    // point yet"; the next fallback event establishes it without contributing distance. Reset
    // alongside the rest of the accumulator state: kiosk entry (_setupKioskExitHandler), kiosk
    // exit (_removeKioskExitHandler), and the >KIOSK_MOVEMENT_GAP_RESET_MS gap reset inside the
    // movement handler itself (a stale point from before a gap is not a meaningful baseline).
    let _kioskMovePrevClientX = null;
    let _kioskMovePrevClientY = null;

    // =========================================================================
    // IDLE DETECTION
    // =========================================================================

    // Single bound handler shared across all tracked events.
    // Using a named reference (not anonymous) so we can remove it cleanly.
    let _boundResetIdleTimer = null;

    /**
     * Reset the idle countdown timer.
     * Called on every tracked user interaction event.
     * When the timer fires, kiosk mode activates.
     */
    function resetIdleTimer() {
        clearTimeout(idleTimer);
        idleTimer = setTimeout(function() {
            enterKioskMode();
        }, KIOSK_CONFIG.idleTimeout);
    }

    /**
     * Start monitoring for user idle state.
     * Attaches a single handler to all tracked interaction events.
     * Safe to call multiple times — removes old listeners before re-adding.
     */
    function startIdleMonitoring() {
        // Clean up any prior state before starting fresh
        stopIdleMonitoring();

        _boundResetIdleTimer = resetIdleTimer;

        KIOSK_IDLE_EVENTS.forEach(function(eventName) {
            document.addEventListener(eventName, _boundResetIdleTimer, { passive: true });
        });

        // Kick off the first idle countdown immediately
        resetIdleTimer();

        _log('[LCARS KIOSK] Idle monitoring started. Timeout:', KIOSK_CONFIG.idleTimeout + 'ms');
    }

    /**
     * Stop monitoring for user idle state.
     * Removes all event listeners and clears the idle timer.
     */
    function stopIdleMonitoring() {
        if (_boundResetIdleTimer) {
            KIOSK_IDLE_EVENTS.forEach(function(eventName) {
                // Must match the capture value used in addEventListener (false/omitted).
                // { passive: true } is NOT a valid removeEventListener option and is
                // treated as truthy useCapture=true, which would never match the listener.
                document.removeEventListener(eventName, _boundResetIdleTimer, false);
            });
            _boundResetIdleTimer = null;
        }

        clearTimeout(idleTimer);
        idleTimer = null;

        _log('[LCARS KIOSK] Idle monitoring stopped.');
    }

    // =========================================================================
    // KIOSK MODE CONTROL
    // =========================================================================

    /**
     * Enter kiosk mode.
     * Saves the currently active section so exitKioskMode can restore it,
     * then starts section rotation.
     */
    function enterKioskMode() {
        if (isKioskActive) return;

        isKioskActive = true;

        // Save where the user was so we can return them on exit
        if (window.LCARS_CORE && LCARS_CORE.sections) {
            priorSection = LCARS_CORE.sections.active;
        } else {
            priorSection = null;
        }

        // Determine kiosk mode: analytics pages (if available) or legacy section rotation.
        // Use getFullPageCount() so kiosk-only pages count toward the total — a dashboard
        // with only kiosk-only pages (no regular tab pages) still enters analytics kiosk mode.
        if (window.LCARSAnalyticsPages && LCARSAnalyticsPages.getFullPageCount() > 0) {
            kioskMode = 'analytics';
        } else {
            kioskMode = 'sections';
        }

        // Add body class for full-screen CSS overrides
        document.body.classList.add('kiosk-active');

        // Dispatch event — app files can listen for this to adjust UI state
        document.dispatchEvent(new CustomEvent('lcars:kioskEnter', {
            detail: {
                priorSection: priorSection,
                kioskMode: kioskMode
            }
        }));

        _log('[LCARS KIOSK] Kiosk mode entered. Mode:', kioskMode, 'Prior section:', priorSection);

        // Stop idle monitoring — no need to track user while we're rotating
        stopIdleMonitoring();

        // Show the visual kiosk mode badge and attach exit-on-interaction listener
        _createKioskIndicator();
        _setupKioskExitHandler();

        // For analytics mode, switch to analytics section first and create page dots
        if (kioskMode === 'analytics') {
            if (window.LCARS_CORE && LCARS_CORE.sections && LCARS_CORE.sections.active !== 'analytics') {
                LCARS_CORE.sections.switchSection('analytics');
            }
            _createKioskPageDots();
        }

        // Start rotation
        startRotation();
    }

    /**
     * Exit kiosk mode.
     * Instant exit — stops rotation, restores prior section, removes visual indicator,
     * removes exit handler, and restarts idle monitoring so kiosk can re-activate.
     *
     * @param {Object} [options] - Exit options
     * @param {boolean} [options.skipRestart=false] - If true, skip restarting idle
     *   monitoring after exit. Used by destroy() to avoid a brief start/stop cycle.
     */
    function exitKioskMode(options) {
        if (!isKioskActive) return;

        isKioskActive = false;

        // Remove body class
        document.body.classList.remove('kiosk-active');

        // Stop rotation and clean up any in-progress scroll
        stopRotation();
        stopOrgsAutoScroll();

        // Remove page dots (analytics mode)
        _removeKioskPageDots();

        // Remove the visual badge and exit interaction listener
        _removeKioskIndicator();
        _removeKioskExitHandler();

        // Restore the section the user was on before kiosk activated — instant, no delay
        if (priorSection && window.LCARS_CORE && LCARS_CORE.sections) {
            LCARS_CORE.sections.switchSection(priorSection);
        }

        // Strip any lingering kiosk transition classes from all section elements
        document.querySelectorAll('.lcars-section').forEach(function(el) {
            el.classList.remove('kiosk-fade-out', 'kiosk-fade-in', 'kiosk-slide-out-left', 'kiosk-slide-in-right');
        });

        // Dispatch exit event — listeners can react to kiosk ending
        document.dispatchEvent(new CustomEvent('lcars:kioskExit', {
            detail: {
                priorSection: priorSection
            }
        }));

        _log('[LCARS KIOSK] Kiosk mode exited. Restored section:', priorSection);

        // Restart idle monitoring so kiosk will re-activate after next idle period
        // (skipped when called from destroy() to avoid pointless start/stop cycle)
        //
        // XACA-1154: the isEnabled() term is NOT redundant with the call-site
        // gating. Kiosk can be entered while the preference is OFF — enterKioskMode
        // is reachable via LCARS_KIOSK.enter() and via the #kiosk-enter-btn FAB on
        // lcars-dashboard.html, neither of which consults the preference (entering
        // is an explicit user action, like setEnabled(true)). Without this check,
        // exiting that manually-entered kiosk re-armed idle monitoring and the
        // dashboard was seized again 2.5 minutes later, with the toggle still
        // reading "off" — silently resurrecting the exact behaviour the user
        // turned off. Restart only when kiosk is actually meant to be running.
        if (!(options && options.skipRestart) && isEnabled()) {
            startIdleMonitoring();
            // XACA-1154-015: kiosk is armed to recur, so point the user at the control
            // that stops it. Guarded internally to once per page load.
            _showKioskExitHint();
        }
    }

    /**
     * Create and inject the "KIOSK MODE" visual indicator badge into the DOM.
     * The .kiosk-indicator CSS class provides the fixed positioning and glow animation.
     */
    function _createKioskIndicator() {
        // Remove any stale indicator before creating a fresh one
        _removeKioskIndicator();

        const indicator = document.createElement('div');
        indicator.className = 'kiosk-indicator';
        indicator.id = 'kiosk-indicator';
        indicator.textContent = 'KIOSK MODE';
        document.body.appendChild(indicator);
    }

    /**
     * Remove the "KIOSK MODE" visual indicator badge from the DOM.
     * Safe to call even if the indicator doesn't exist.
     */
    function _removeKioskIndicator() {
        const indicator = document.getElementById('kiosk-indicator');
        if (indicator && indicator.parentNode) {
            indicator.parentNode.removeChild(indicator);
        }
    }

    /**
     * Attach interaction listeners that exit kiosk mode on user action.
     * Uses named function references so they can be cleanly removed by _removeKioskExitHandler.
     * Delayed 100ms to prevent the idle timer's triggering event from immediately firing exit.
     *
     * XACA-1154-005: the 100ms delay is unchanged and was judged still adequate even with
     * mousemove/pointermove added to the set. The delay exists to stop the OLD interaction
     * stream's tail event (the one that fired the idle timer) from instantly re-triggering
     * exit. That risk doesn't carry over to movement events the same way: the idle timer only
     * fires after KIOSK_CONFIG.idleTimeout (2.5 min) with NO tracked events at all, so the
     * cursor is already stationary at the moment kiosk activates — there is no in-flight
     * mousemove gesture for the delay to guard against. The real risk this ticket is about
     * (ambient cursor jitter causing a false exit) is handled by the cumulative-distance
     * threshold below, not by extending the grace window; a single noisy event still can't
     * cross KIOSK_MOVEMENT_EXIT_THRESHOLD_PX regardless of how soon after activation it fires.
     * No separate movement warm-up was added for the same reason — the threshold IS the guard.
     */
    // XACA-1154-015 (UX gate, PR #851): a user who has just escaped kiosk still has to
    // rediscover the PREFERENCES panel unaided in order to stop it happening again.
    // Shown at most ONCE per page load, and only when kiosk is still armed to recur —
    // a hint that reappears on every exit would be its own undismissable nag, which is
    // precisely the defect class this ticket exists to close.
    let _kioskExitHintShown = false;
    let _kioskExitHintEl = null;
    let _kioskExitHintTimer = null;

    /** Tear down the exit hint and its timer. Safe to call when nothing is showing. */
    function _removeKioskExitHint() {
        clearTimeout(_kioskExitHintTimer);
        _kioskExitHintTimer = null;
        if (_kioskExitHintEl && _kioskExitHintEl.parentNode) {
            _kioskExitHintEl.parentNode.removeChild(_kioskExitHintEl);
        }
        _kioskExitHintEl = null;
    }

    /**
     * Show a transient, dismissible pointer to the auto-start preference.
     * role="status" + aria-live="polite" so it is announced rather than seen only —
     * this ticket is about a UI that could not be escaped, so a sighted-only
     * affordance would miss the users most affected by it.
     */
    function _showKioskExitHint() {
        if (_kioskExitHintShown) return;
        _kioskExitHintShown = true;

        _removeKioskExitHint();

        var el = document.createElement('div');
        el.className = 'kiosk-exit-hint';
        el.setAttribute('role', 'status');
        el.setAttribute('aria-live', 'polite');
        el.textContent = 'Kiosk auto-start is on — turn it off under Preferences';
        el.addEventListener('click', _removeKioskExitHint);
        document.body.appendChild(el);
        _kioskExitHintEl = el;

        // Next frame, so the opacity transition actually runs rather than being
        // collapsed into the initial paint.
        setTimeout(function() {
            if (_kioskExitHintEl === el) el.classList.add('kiosk-exit-hint-visible');
        }, 20);

        _kioskExitHintTimer = setTimeout(_removeKioskExitHint, 8000);
    }

    function _setupKioskExitHandler() {
        // Defensive: clear any existing handler before attaching a new one
        _removeKioskExitHandler();

        // Fresh accumulator for this kiosk session.
        _kioskMoveAccumDist = 0;
        _kioskMoveAccumLastTime = 0;
        _kioskMoveAccumEventType = null;
        _kioskMovePrevClientX = null;
        _kioskMovePrevClientY = null;

        _boundKioskExitHandlerImmediate = function(e) {
            // Arrow keys navigate kiosk pages instead of exiting
            if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') return;
            exitKioskMode();
        };

        _boundKioskExitHandlerMovement = function(e) {
            const now = Date.now();
            const usingClientFallback = !(typeof e.movementX === 'number' && typeof e.movementY === 'number');

            // XACA-1154-018: gap detection runs FIRST — before computing this event's delta and
            // before the type-latch check below (previously it ran after both). A gap zeroes
            // the distance accumulator, the latched event type, and (XACA-1154-017) the
            // clientX/clientY fallback baseline — all three are meaningless once continuity is
            // broken. Moving this earlier is what makes the latch self-healing: previously, once
            // a type was latched, an event of the OTHER type hit the mismatch `return` below
            // before ever reaching this gap check, so if the latched type's own events stopped
            // arriving, _kioskMoveAccumLastTime was never touched again by ANYONE and the gap
            // could never be observed — the latch was permanent and movement could no longer
            // exit kiosk at all. Checking it here means: once >KIOSK_MOVEMENT_GAP_RESET_MS has
            // passed since the last accumulating event (of the latched type), the very next real
            // motion event of ANY type clears the accumulator and re-latches onto itself. This
            // cannot reintroduce the intra-burst double-count the latch exists to prevent,
            // because the accumulator is zeroed in the same reset.
            if (now - _kioskMoveAccumLastTime > KIOSK_MOVEMENT_GAP_RESET_MS) {
                _kioskMoveAccumDist = 0;
                _kioskMoveAccumEventType = null;
                _kioskMovePrevClientX = null;
                _kioskMovePrevClientY = null;
            }

            let dx, dy;
            if (!usingClientFallback) {
                dx = e.movementX || 0;
                dy = e.movementY || 0;
                if (dx === 0 && dy === 0) return; // pure noise — contributes nothing, never exits alone, and must not refresh the gap clock (see KIOSK_MOVEMENT_GAP_RESET_MS)
            } else if (_kioskMovePrevClientX === null) {
                // XACA-1154-017: movementX/movementY are genuinely absent on this engine (e.g.
                // the cockpit WKWebView is an unverified surface for this) — the branch above
                // would otherwise always compute dx=dy=0 and this handler, the load-bearing half
                // of the whole fix, would silently never exit kiosk on movement again. Fall back
                // to a clientX/clientY delta against the previous point, tracked per kiosk
                // session. This is the first fallback sample since a reset (session start or gap
                // above), so there is no previous point to diff against — it can only establish
                // the baseline, never contribute a (spurious) delta. It still marks this moment
                // as the last-seen-activity time so the very next sample is compared against a
                // fresh gap window rather than the stale pre-reset one, which would otherwise
                // re-clear the baseline forever and distance could never accumulate.
                _kioskMovePrevClientX = e.clientX;
                _kioskMovePrevClientY = e.clientY;
                _kioskMoveAccumLastTime = now;
                return;
            } else {
                dx = e.clientX - _kioskMovePrevClientX;
                dy = e.clientY - _kioskMovePrevClientY;
                _kioskMovePrevClientX = e.clientX;
                _kioskMovePrevClientY = e.clientY;
                if (dx === 0 && dy === 0) return; // pure noise — contributes nothing, never exits alone, and must not refresh the gap clock
            }

            // Latch onto the first movement event type that reports real motion, then ignore
            // the other for the rest of this accumulation window. Without this, pointermove and
            // mousemove — which a browser fires as a pair for one physical motion, carrying the
            // same deltas — each add to the accumulator and halve the effective threshold.
            // See _kioskMoveAccumEventType for the measured evidence.
            if (_kioskMoveAccumEventType === null) {
                _kioskMoveAccumEventType = e.type;
            } else if (e.type !== _kioskMoveAccumEventType) {
                return;
            }

            _kioskMoveAccumLastTime = now;
            _kioskMoveAccumDist += Math.hypot(dx, dy);
            if (_kioskMoveAccumDist >= KIOSK_MOVEMENT_EXIT_THRESHOLD_PX) {
                exitKioskMode();
            }
        };

        // Small delay — prevents the idle system's last event from immediately triggering exit
        setTimeout(function() {
            // Guard: kiosk may have been exited during the delay window
            if (!isKioskActive || !_boundKioskExitHandlerImmediate) return;

            KIOSK_EXIT_EVENTS_IMMEDIATE.forEach(function(eventName) {
                document.addEventListener(eventName, _boundKioskExitHandlerImmediate, { capture: true });
            });
            KIOSK_EXIT_EVENTS_MOVEMENT.forEach(function(eventName) {
                document.addEventListener(eventName, _boundKioskExitHandlerMovement, { capture: true });
            });

            _log('[LCARS KIOSK] Exit handler attached.');
        }, 100);
    }

    /**
     * Remove the kiosk exit interaction listeners.
     * Safe to call even if the handlers were never attached.
     */
    function _removeKioskExitHandler() {
        let removedAny = false;

        if (_boundKioskExitHandlerImmediate) {
            KIOSK_EXIT_EVENTS_IMMEDIATE.forEach(function(eventName) {
                document.removeEventListener(eventName, _boundKioskExitHandlerImmediate, { capture: true });
            });
            _boundKioskExitHandlerImmediate = null;
            removedAny = true;
        }
        if (_boundKioskExitHandlerMovement) {
            KIOSK_EXIT_EVENTS_MOVEMENT.forEach(function(eventName) {
                document.removeEventListener(eventName, _boundKioskExitHandlerMovement, { capture: true });
            });
            _boundKioskExitHandlerMovement = null;
            removedAny = true;
        }

        if (removedAny) {
            _kioskMoveAccumDist = 0;
            _kioskMoveAccumLastTime = 0;
            _kioskMoveAccumEventType = null;
            _kioskMovePrevClientX = null;
            _kioskMovePrevClientY = null;
            _log('[LCARS KIOSK] Exit handler removed.');
        }
    }

    // =========================================================================
    // SECTION ROTATION
    // =========================================================================

    /**
     * Advance to the next enabled section in the rotation.
     *
     * Applies CSS fade transitions, calls LCARS_CORE.sections.switchSection,
     * handles orgs auto-scroll start/stop, dispatches lcars:kioskRotate,
     * and resets the progress bar animation.
     */
    function rotateToNextSection() {
        // Analytics mode — cycle through analytics sub-pages instead of sections.
        // nextFullPage() traverses ALL pages including kiosk-only pages.
        // switchPage() internally calls renderKioskPage() for kiosk-only pages.
        if (kioskMode === 'analytics' && window.LCARSAnalyticsPages) {
            (LCARSAnalyticsPages.nextFullPage || LCARSAnalyticsPages.nextPage)();
            _updateKioskPageDots();

            // Reset the progress bar animation by replacing the element
            var existingBar = document.getElementById('kiosk-progress-bar');
            if (existingBar) {
                var newBar = document.createElement('div');
                newBar.className = 'kiosk-progress-bar';
                newBar.id = 'kiosk-progress-bar';
                existingBar.parentNode.replaceChild(newBar, existingBar);
            }

            // Dispatch rotation event
            document.dispatchEvent(new CustomEvent('lcars:kioskRotate', {
                detail: {
                    mode: 'analytics',
                    page: LCARSAnalyticsPages.getCurrentPage(),
                    index: 0
                }
            }));

            _log('[LCARS KIOSK] Analytics page rotated to:', LCARSAnalyticsPages.getCurrentPage());
            return;
        }

        // Legacy section rotation
        if (!window.LCARS_CORE || !LCARS_CORE.sections) {
            console.warn('[LCARS KIOSK] LCARS_CORE not available — skipping rotation.');
            return;
        }

        const sections = KIOSK_CONFIG.enabledSections;
        const currentSection = sections[currentSectionIndex];

        // Advance index with wraparound
        currentSectionIndex = (currentSectionIndex + 1) % sections.length;
        const nextSection = sections[currentSectionIndex];

        _log('[LCARS KIOSK] Rotating: ' + currentSection + ' -> ' + nextSection + ' (index ' + currentSectionIndex + ')');

        // Apply fade-out to the currently active section element
        const activeEl = document.querySelector('.lcars-section.active');
        if (activeEl) {
            activeEl.classList.add('kiosk-fade-out');
        }

        // If we're leaving 'organizations', stop the auto-scroll
        if (currentSection === 'organizations') {
            stopOrgsAutoScroll();
        }

        // Mid-transition: switch the section after half the transition duration
        setTimeout(function() {
            LCARS_CORE.sections.switchSection(nextSection);

            // The newly active element after the switch
            const newActiveEl = document.querySelector('.lcars-section.active');
            if (newActiveEl) {
                newActiveEl.classList.add('kiosk-fade-in');
            }

            // If we're entering 'organizations', start the auto-scroll
            if (nextSection === 'organizations') {
                startOrgsAutoScroll();
            }

        }, KIOSK_CONFIG.transitionDuration / 2);

        // Clean up all kiosk transition classes after the full transition completes
        setTimeout(function() {
            document.querySelectorAll('.lcars-section').forEach(function(el) {
                el.classList.remove('kiosk-fade-out', 'kiosk-fade-in', 'kiosk-slide-out-left', 'kiosk-slide-in-right');
            });
        }, KIOSK_CONFIG.transitionDuration);

        // Reset the progress bar animation by replacing the element
        var progressBarEl = document.getElementById('kiosk-progress-bar');
        if (progressBarEl) {
            var freshBar = document.createElement('div');
            freshBar.className = 'kiosk-progress-bar';
            freshBar.id = 'kiosk-progress-bar';
            progressBarEl.parentNode.replaceChild(freshBar, progressBarEl);
        }

        // Dispatch rotation event for any interested listeners
        document.dispatchEvent(new CustomEvent('lcars:kioskRotate', {
            detail: {
                from: currentSection,
                to: nextSection,
                index: currentSectionIndex
            }
        }));
    }

    /**
     * Start the section rotation interval.
     *
     * Resets to index 0, fires the first rotation immediately,
     * then sets up the repeating interval. Also injects the progress bar.
     */
    function startRotation() {
        // Reset to the beginning of the rotation sequence
        currentSectionIndex = 0;

        // Sync the CSS progress bar animation duration with the JS config value.
        // This drives the --kiosk-rotation-interval custom property so CSS never needs
        // to hardcode the same duration value that KIOSK_CONFIG.rotationInterval owns.
        document.documentElement.style.setProperty(
            '--kiosk-rotation-interval',
            KIOSK_CONFIG.rotationInterval + 'ms'
        );

        // Insert the progress bar into the DOM
        const existingBar = document.getElementById('kiosk-progress-bar');
        if (!existingBar) {
            const progressBar = document.createElement('div');
            progressBar.className = 'kiosk-progress-bar';
            progressBar.id = 'kiosk-progress-bar';
            document.body.appendChild(progressBar);
        }

        // Rotate immediately so we don't just sit on the current section
        // Note: currentSectionIndex is 0 here, so first rotation goes to index 1
        rotateToNextSection();

        // Then repeat on interval
        rotationTimer = setInterval(rotateToNextSection, KIOSK_CONFIG.rotationInterval);

        _log('[LCARS KIOSK] Rotation started. Interval:', KIOSK_CONFIG.rotationInterval + 'ms');
    }

    /**
     * Stop the section rotation interval.
     * Removes the progress bar and cleans up any lingering transition classes.
     */
    function stopRotation() {
        clearInterval(rotationTimer);
        rotationTimer = null;

        // Remove the progress bar from DOM
        const progressBar = document.getElementById('kiosk-progress-bar');
        if (progressBar) {
            progressBar.parentNode.removeChild(progressBar);
        }

        // Clean up any lingering kiosk transition classes on all sections
        document.querySelectorAll('.lcars-section').forEach(function(el) {
            el.classList.remove('kiosk-fade-out', 'kiosk-fade-in', 'kiosk-slide-out-left', 'kiosk-slide-in-right');
        });

        _log('[LCARS KIOSK] Rotation stopped.');
    }

    // =========================================================================
    // ORGS AUTO-SCROLL
    // =========================================================================

    /**
     * Start auto-scrolling through org panels in the organizations section.
     *
     * Queries all .organization-panel elements inside #divisions-container,
     * scrolls to each one in sequence using scrollIntoView with smooth behavior,
     * and applies the .kiosk-scroll-target pulse class as a scroll highlight.
     * Repeats on KIOSK_CONFIG.orgsScrollDelay interval.
     */
    function startOrgsAutoScroll() {
        // XACA-1060: excludes panels the MACHINES filter bar has hidden (via
        // the `hidden` attribute, never style.display) -- without
        // :not([hidden]) here, kiosk auto-scroll could park on (or cycle
        // through) a filtered-out, invisible panel. This skin's own
        // scroll-index arithmetic below is otherwise unaware of the filter.
        const panels = document.querySelectorAll('#divisions-container .organization-panel:not([hidden])');

        if (!panels || panels.length === 0) {
            _log('[LCARS KIOSK] startOrgsAutoScroll: no organization panels found — skipping.');
            return;
        }

        // Reset to the beginning
        orgsScrollIndex = 0;

        // Scroll to the first panel immediately
        panels[0].scrollIntoView({ behavior: 'smooth', block: 'start' });
        panels[0].classList.add('kiosk-scroll-target');
        _log('[LCARS KIOSK] Orgs scroll -> panel 0 of ' + panels.length);

        // Remove the highlight after the 1s animation completes
        setTimeout(function() {
            if (panels[0]) {
                panels[0].classList.remove('kiosk-scroll-target');
            }
        }, 1000);

        // Set up repeating scroll through panels
        orgsScrollTimer = setInterval(function() {
            // Re-query in case DOM updated between ticks. XACA-1060: same
            // :not([hidden]) exclusion as the initial query above -- a poll
            // between ticks can change which panels the MACHINES filter has
            // hidden, and this re-query is exactly what's supposed to catch that.
            const currentPanels = document.querySelectorAll('#divisions-container .organization-panel:not([hidden])');
            if (!currentPanels || currentPanels.length === 0) return;

            const prevIndex = orgsScrollIndex;
            orgsScrollIndex = (orgsScrollIndex + 1) % currentPanels.length;
            const target = currentPanels[orgsScrollIndex];

            _log('[LCARS KIOSK] Orgs scroll -> panel ' + orgsScrollIndex + ' of ' + currentPanels.length);

            target.scrollIntoView({ behavior: 'smooth', block: 'start' });
            target.classList.add('kiosk-scroll-target');

            // Remove highlight from previous panel after 800ms
            const prevPanel = currentPanels[prevIndex];
            setTimeout(function() {
                if (prevPanel) {
                    prevPanel.classList.remove('kiosk-scroll-target');
                }
            }, 800);

        }, KIOSK_CONFIG.orgsScrollDelay);

        _log('[LCARS KIOSK] Orgs auto-scroll started. ' + panels.length + ' panels, interval: ' + KIOSK_CONFIG.orgsScrollDelay + 'ms');
    }

    /**
     * Stop the orgs auto-scroll timer and clean up all scroll highlight classes.
     */
    function stopOrgsAutoScroll() {
        clearInterval(orgsScrollTimer);
        orgsScrollTimer = null;

        // Strip the scroll highlight from all panels
        document.querySelectorAll('#divisions-container .organization-panel').forEach(function(panel) {
            panel.classList.remove('kiosk-scroll-target');
        });

        orgsScrollIndex = 0;

        _log('[LCARS KIOSK] Orgs auto-scroll stopped.');
    }

    // =========================================================================
    // KIOSK PAGE DOTS (analytics mode only)
    // =========================================================================

    /**
     * Create the page dots indicator at the bottom center of the screen.
     * One dot per analytics page, active dot highlighted.
     */
    function _createKioskPageDots() {
        _removeKioskPageDots();

        if (!window.LCARSAnalyticsPages) return;

        // Use getFullPageList() so kiosk-only pages get dots in the indicator
        var pages = LCARSAnalyticsPages.getFullPageList();
        if (pages.length <= 1) return;

        var dotsContainer = document.createElement('div');
        dotsContainer.className = 'kiosk-page-dots';
        dotsContainer.id = 'kiosk-page-dots';

        pages.forEach(function (page, idx) {
            var dot = document.createElement('div');
            dot.className = 'kiosk-page-dot';
            if (idx === 0) dot.classList.add('active');
            dot.setAttribute('data-dot-index', idx);
            dotsContainer.appendChild(dot);
        });

        document.body.appendChild(dotsContainer);
    }

    /** Update which page dot is active */
    function _updateKioskPageDots() {
        var container = document.getElementById('kiosk-page-dots');
        if (!container || !window.LCARSAnalyticsPages) return;

        var currentPage = LCARSAnalyticsPages.getCurrentPage();
        // Use getFullPageList() to match the dot set created by _createKioskPageDots()
        var pages = LCARSAnalyticsPages.getFullPageList();

        var dots = container.querySelectorAll('.kiosk-page-dot');
        dots.forEach(function (dot, idx) {
            dot.classList.toggle('active', pages[idx] && pages[idx].id === currentPage);
        });
    }

    /** Remove page dots from the DOM */
    function _removeKioskPageDots() {
        var container = document.getElementById('kiosk-page-dots');
        if (container && container.parentNode) {
            container.parentNode.removeChild(container);
        }
    }

    // =========================================================================
    // KIOSK BUTTON WIRING
    // =========================================================================

    document.addEventListener('DOMContentLoaded', function () {
        var btn = document.getElementById('kiosk-enter-btn');
        if (btn) {
            btn.addEventListener('click', function () {
                if (!isKioskActive) enterKioskMode();
            });
        }
    });

    // =========================================================================
    // ARROW KEY NAVIGATION
    // =========================================================================

    /**
     * Global arrow key handler for analytics page navigation.
     * Works in both kiosk mode (resets rotation timer) and normal browsing.
     */
    document.addEventListener('keydown', function(e) {
        if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
        if (!window.LCARSAnalyticsPages) return;

        var isLeft = e.key === 'ArrowLeft';

        // Kiosk mode: navigate and reset the auto-rotation timer
        if (isKioskActive && kioskMode === 'analytics') {
            e.preventDefault();

            if (isLeft) {
                (LCARSAnalyticsPages.prevFullPage || LCARSAnalyticsPages.prevPage)();
            } else {
                (LCARSAnalyticsPages.nextFullPage || LCARSAnalyticsPages.nextPage)();
            }
            _updateKioskPageDots();

            // Reset rotation timer so it doesn't fire immediately after manual nav
            clearInterval(rotationTimer);
            var existingBar = document.getElementById('kiosk-progress-bar');
            if (existingBar) {
                var newBar = document.createElement('div');
                newBar.className = 'kiosk-progress-bar';
                newBar.id = 'kiosk-progress-bar';
                existingBar.parentNode.replaceChild(newBar, existingBar);
            }
            rotationTimer = setInterval(rotateToNextSection, KIOSK_CONFIG.rotationInterval);
            return;
        }

        // Non-kiosk: navigate analytics pages if analytics section is active
        if (!isKioskActive && window.LCARS_CORE && LCARS_CORE.sections &&
            LCARS_CORE.sections.active === 'analytics') {
            e.preventDefault();
            if (isLeft) {
                LCARSAnalyticsPages.prevPage();
            } else {
                LCARSAnalyticsPages.nextPage();
            }
        }
    });

    // =========================================================================
    // PERSISTED ENABLE/DISABLE PREFERENCE
    // =========================================================================

    /**
     * Read a value from localStorage, tolerating a throw.
     * localStorage can throw (Private Browsing, disabled storage/cookies,
     * SecurityError in a sandboxed WebView — these dashboards also render
     * inside the iTerm2 LCARS cockpit WKWebView). Never let a storage read
     * abort dashboard init; degrade to "nothing stored" instead.
     */
    function _lsGet(key) {
        try {
            return localStorage.getItem(key);
        } catch (e) {
            return null;
        }
    }

    /**
     * Write a value to localStorage, tolerating a throw.
     * Same rationale as _lsGet — a write failure means the preference
     * simply won't persist; it must never be fatal to the caller.
     */
    function _lsSet(key, val) {
        try {
            localStorage.setItem(key, val);
        } catch (e) {
            // storage unavailable — preference won't persist; non-fatal
        }
    }

    /**
     * Resolve the current kiosk enabled/disabled preference.
     * localStorage only ever stores strings, so the stored value is read
     * literally: the string 'true' means enabled, the string 'false' means
     * disabled, and anything else (nothing stored yet, or a garbage value)
     * falls back to the KIOSK_CONFIG.enabled in-memory default rather than
     * being coerced through a truthy check (`"false"` is truthy).
     *
     * @returns {boolean}
     */
    function isEnabled() {
        var stored = _lsGet(KIOSK_ENABLED_STORAGE_KEY);
        if (stored === 'true') return true;
        if (stored === 'false') return false;
        return KIOSK_CONFIG.enabled;
    }

    /**
     * Fully disable kiosk: exit kiosk mode if currently active (without
     * restarting idle monitoring afterward) and stop idle monitoring.
     * Shared by destroy() and setEnabled(false) so the exit/stop pairing
     * lives in exactly one place. Both underlying calls are self-guarding
     * (exitKioskMode no-ops when inactive; stopIdleMonitoring no-ops when
     * no listeners are attached), so this is safe to call repeatedly.
     */
    function _disableKiosk() {
        if (isKioskActive) {
            exitKioskMode({ skipRestart: true });
        }
        stopIdleMonitoring();
        // XACA-1154-015: tear down any visible hint and, importantly, its pending
        // timers. destroy() routes through here, so a test or a torn-down dashboard
        // never leaves a stray timeout holding the event loop open.
        _removeKioskExitHint();
    }

    /**
     * Public init() entry point — the single choke point for kiosk startup.
     * Starts idle monitoring only when the persisted enabled/disabled
     * preference (isEnabled()) currently resolves true.
     *
     * XACA-1154-003: gating call SITES (the two dashboard app.js files) is
     * a denylist — every site we happen to enumerate respects the
     * preference, and any future call site that forgets to check first
     * fails OPEN (kiosk seizes the dashboard even though the user saved
     * "off"). Gating init() itself instead makes the preference check
     * unconditional for every caller, present or future, so a missed call
     * site fails CLOSED. The two known call sites are still gated directly
     * (see lcars-fleet-dashboard-app.js / lcars-dashboard-app.js) as
     * defense in depth — legible intent at the point of use — but init()
     * no longer trusts them to have done it.
     *
     * Idempotent / safe to call repeatedly: when enabled, delegates to
     * startIdleMonitoring(), which already tears down any prior listeners
     * via stopIdleMonitoring() before re-adding them. When disabled, this
     * is a pure no-op — it does not touch state, does not call
     * stopIdleMonitoring(), and does not throw.
     *
     * Does NOT gate setEnabled(true) on the PREFERENCE: that function applies
     * the change directly (see _applyKioskEnabled/setEnabled below), not
     * through init(). That is intentional — setEnabled(true) is the
     * toggle-ON action itself, so it must apply unconditionally rather than
     * re-deriving "should I start?" from a preference read. Routing it
     * through init() here would re-introduce a race: _lsSet() in
     * setEnabled() and the localStorage read in isEnabled() would need to
     * agree perfectly, and a storage write failure (see _lsSet) would
     * silently make setEnabled(true) a no-op instead of starting
     * monitoring as the caller explicitly asked. (It IS gated on kiosk
     * ACTIVE state — see _applyKioskEnabled / XACA-1154-021 — which is an
     * orthogonal, state-machine-safety concern, not a preference re-check.)
     */
    function init() {
        if (!isEnabled()) {
            _log('[LCARS KIOSK] init() skipped — kiosk disabled by preference.');
            return;
        }
        startIdleMonitoring();
    }

    /**
     * Apply the enabled/disabled state: start or stop idle monitoring
     * accordingly. Shared by setEnabled() (this tab's own toggle) and the
     * XACA-1154-019 'storage' listener (another tab's toggle) so both apply
     * the exact same rules — this function does NOT touch localStorage,
     * callers are responsible for persisting first if needed.
     *
     * @param {boolean} enabled
     */
    function _applyKioskEnabled(enabled) {
        if (enabled) {
            // XACA-1154-021: don't start idle monitoring while kiosk is
            // currently ACTIVE. enterKioskMode() stops idle monitoring for
            // the duration of an active kiosk session (see its call to
            // stopIdleMonitoring()) — that is the "monitoring off while
            // kiosk active" invariant. Starting it here regardless would run
            // idle monitoring concurrently with a running kiosk, breaking
            // that invariant. Benign today (the idle timer would just fire
            // into enterKioskMode()'s own isKioskActive early-return), but
            // it's a state-machine inconsistency worth not introducing.
            // Nothing is lost by skipping the start here: exitKioskMode()
            // already restarts idle monitoring on exit when isEnabled() is
            // true.
            if (!isKioskActive) {
                startIdleMonitoring();
            }
        } else {
            _disableKiosk();
        }
    }

    /**
     * Set the kiosk enabled/disabled preference and apply it immediately.
     * Persists to localStorage (best-effort — see _lsSet) and:
     *   - setEnabled(false): exits kiosk mode if active and stops idle
     *     monitoring, via the same pairing destroy() uses.
     *   - setEnabled(true): (re)starts idle monitoring, unless kiosk is
     *     currently active (XACA-1154-021 — see _applyKioskEnabled).
     *     startIdleMonitoring already calls stopIdleMonitoring() first, so
     *     this is safe to call even when monitoring is already running.
     * Idempotent in both directions — calling with the same value twice in
     * a row does not throw or double-remove listeners.
     *
     * @param {boolean} value
     */
    function setEnabled(value) {
        var enabled = !!value;
        _lsSet(KIOSK_ENABLED_STORAGE_KEY, enabled ? 'true' : 'false');
        _applyKioskEnabled(enabled);
        _log('[LCARS KIOSK] setEnabled(' + enabled + ')');
    }

    /**
     * XACA-1154-019: keep THIS tab's toggle and monitoring state in sync
     * when the enabled/disabled preference changes elsewhere — another
     * dashboard tab's toggle, the console, or another module calling
     * localStorage.setItem directly. Without this, a tab's checkbox and its
     * idle-monitoring state could silently diverge from the persisted
     * preference until the next page load/init().
     *
     * The native 'storage' event fires only in OTHER same-origin documents,
     * never in the document that performed the write — so this handler can
     * never receive an event caused by THIS tab's own setEnabled() call,
     * and cannot create a feedback loop on its own. It deliberately calls
     * _applyKioskEnabled() directly rather than setEnabled() — applying the
     * change without re-persisting a value that is already stored (and
     * already the reason this handler is running).
     */
    window.addEventListener('storage', function(e) {
        if (e.key !== KIOSK_ENABLED_STORAGE_KEY) return;

        // Re-read via isEnabled() rather than trusting e.newValue directly —
        // isEnabled() already encodes the 'true'/'false'/anything-else
        // fallback rules (see its own doc comment), including the key
        // having been removed entirely (e.newValue === null).
        var enabled = isEnabled();

        var toggle = document.getElementById('kiosk-mode-toggle');
        if (toggle) {
            toggle.checked = enabled;
        }

        _applyKioskEnabled(enabled);
        _log('[LCARS KIOSK] storage sync: enabled=' + enabled);
    });

    // =========================================================================
    // PUBLIC API
    // =========================================================================

    window.LCARS_KIOSK = {
        init: init,
        destroy: function() {
            _disableKiosk();
        },
        enter: enterKioskMode,
        isActive: function() { return isKioskActive; },
        isEnabled: isEnabled,
        setEnabled: setEnabled,
        config: KIOSK_CONFIG,
    };

    _log('[LCARS KIOSK] Module loaded.');

})();
