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
        idleTimeout: 150000,       // ms before kiosk activates (2.5 min)
        rotationInterval: 8000,    // ms between section rotations
        transitionDuration: 600,   // ms for transition animations
        enabledSections: ['overview', 'organizations', 'machines'],  // sections to rotate through
        orgsScrollDelay: 2000,     // ms between org/division scrolls
        debug: false,              // set true to enable console.log output
    };

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

    // Stored reference to the kiosk exit interaction handler so it can be removed cleanly.
    let _boundKioskExitHandler = null;

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

        const events = ['mousemove', 'mousedown', 'keypress', 'keydown', 'touchstart', 'scroll', 'click'];
        events.forEach(function(eventName) {
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
            const events = ['mousemove', 'mousedown', 'keypress', 'keydown', 'touchstart', 'scroll', 'click'];
            events.forEach(function(eventName) {
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
        if (!(options && options.skipRestart)) {
            startIdleMonitoring();
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
     * Attach an interaction listener that exits kiosk mode on the first user action.
     * Uses a named function reference so it can be cleanly removed by _removeKioskExitHandler.
     * Delayed 100ms to prevent the idle timer's triggering event from immediately firing exit.
     */
    function _setupKioskExitHandler() {
        // Defensive: clear any existing handler before attaching a new one
        _removeKioskExitHandler();

        _boundKioskExitHandler = function(e) {
            // Arrow keys navigate kiosk pages instead of exiting
            if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') return;
            exitKioskMode();
        };

        // Small delay — prevents the idle system's last event from immediately triggering exit
        setTimeout(function() {
            // Guard: kiosk may have been exited during the delay window
            if (!isKioskActive || !_boundKioskExitHandler) return;

            const events = ['click', 'mousedown', 'keydown', 'touchstart'];
            events.forEach(function(eventName) {
                document.addEventListener(eventName, _boundKioskExitHandler, { capture: true });
            });

            _log('[LCARS KIOSK] Exit handler attached.');
        }, 100);
    }

    /**
     * Remove the kiosk exit interaction listener.
     * Safe to call even if the handler was never attached.
     */
    function _removeKioskExitHandler() {
        if (_boundKioskExitHandler) {
            const events = ['click', 'mousedown', 'keydown', 'touchstart'];
            events.forEach(function(eventName) {
                document.removeEventListener(eventName, _boundKioskExitHandler, { capture: true });
            });
            _boundKioskExitHandler = null;
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
        const panels = document.querySelectorAll('#divisions-container .organization-panel');

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
            // Re-query in case DOM updated between ticks
            const currentPanels = document.querySelectorAll('#divisions-container .organization-panel');
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
    // PUBLIC API
    // =========================================================================

    window.LCARS_KIOSK = {
        init: startIdleMonitoring,
        destroy: function() {
            if (isKioskActive) {
                exitKioskMode({ skipRestart: true });
            }
            stopIdleMonitoring();
        },
        enter: enterKioskMode,
        isActive: function() { return isKioskActive; },
        config: KIOSK_CONFIG,
    };

    _log('[LCARS KIOSK] Module loaded.');

})();
