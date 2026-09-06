//
//  lcars-fleet-core.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * LCARS Fleet Monitor Core JavaScript
 *
 * Modular candy pill system with data-driven values,
 * animations, and section-specific color schemes.
 *
 * Port from lcars-ui with Fleet Monitor enhancements
 */

// Global namespace
window.LCARS_CORE = window.LCARS_CORE || {};

(function(LCARS) {
    'use strict';

    // Every surface that can navigate to a section: sidebar buttons plus the
    // top utility-bar pills (XACA-0963). Shared so the click binding and the
    // active-state toggle cannot drift apart -- if they ever diverge, a pill
    // navigates but never highlights.
    // MUST stay BELOW 'use strict': a declaration above it breaks the directive
    // prologue, turning 'use strict' into an inert string literal.
    var NAV_SELECTOR = '.sidebar-button[data-section], .legend-pill[data-section]';

    // =========================================================================
    // CANDY PILL SYSTEM
    // =========================================================================

    LCARS.candy = {
        // State management
        state: {
            values: ['00000', '0000', '0000', '00000', '00000', '0000'],
            previousValues: ['00000', '0000', '0000', '00000', '00000', '0000'],
            timers: [],
            currentSection: 'overview',
            inversionTimer: null,
            alertMode: false,
            // Last value pushed to the offline aria-live region. `null` (not 0)
            // so a genuine first reading of 0 still initialises the element.
            offlineIndicatorValue: null,
            alertTimers: []
        },

        // Data source - will be updated by Fleet Monitor
        data: {
            totalMachines: 0,
            onlineMachines: 0,
            offlineMachines: 0,
            totalSessions: 0
        },

        // Color schemes per section
        schemes: {
            overview: {
                order: [0, 1, 2, 3, 4, 5],
                colors: ['blue', 'cyan', 'red', 'orange', 'tan', 'peach']
            },
            machines: {
                order: [2, 0, 1, 4, 3, 5],
                colors: ['cyan', 'blue', 'lavender', 'blue', 'cyan', 'lavender']
            },
            sessions: {
                order: [3, 1, 4, 0, 5, 2],
                colors: ['orange', 'peach', 'tan', 'brown', 'mauve', 'orange']
            },
            alerts: {
                order: [2, 4, 0, 5, 1, 3],
                colors: ['red', 'orange', 'red', 'orange', 'red', 'orange']
            },
            settings: {
                order: [4, 2, 5, 1, 3, 0],
                colors: ['lavender', 'mauve', 'tan', 'peach', 'brown', 'lavender']
            }
        },

        // Update intervals for each pill (staggered for visual variety)
        intervals: [50, 75, 100, 200, 500, 1500],

        /**
         * Initialize the candy pill system
         * @param {Object} options - Configuration options
         */
        init: function(options) {
            options = options || {};

            // Set initial section
            if (options.section) {
                this.state.currentSection = options.section;
            }

            // Initialize displays
            this.initDisplays();

            // Start inversion effect
            this.initInversion();

            // Apply initial color scheme
            this.applyColorScheme(this.state.currentSection);

            console.log('[LCARS] Candy pill system initialized');
        },

        /**
         * Initialize candy displays with staggered update timers
         */
        initDisplays: function() {
            const self = this;

            // Clear any existing timers
            this.clearTimers();

            // Pill 0: Total machines (updates every 50ms with real data)
            this.state.timers.push(setInterval(function() {
                self.updatePill(0, self.formatNumber(self.data.totalMachines, 5));
            }, this.intervals[0]));

            // Pill 1: Online machines (updates every 75ms)
            this.state.timers.push(setInterval(function() {
                self.updatePill(1, self.formatNumber(self.data.onlineMachines, 4));
            }, this.intervals[1]));

            // Pill 2: Offline machines (updates every 100ms)
            this.state.timers.push(setInterval(function() {
                self.updatePill(2, self.formatNumber(self.data.offlineMachines, 4));
                // Persistent utility-bar cue - independent of the dormant pill above.
                self.updateOfflineIndicator(self.data.offlineMachines);
            }, this.intervals[2]));

            // Pill 3: Total sessions (updates every 200ms)
            this.state.timers.push(setInterval(function() {
                self.updatePill(3, self.formatNumber(self.data.totalSessions, 5));
            }, this.intervals[3]));

            // Pill 4: Random LCARS data (updates every 500ms)
            this.state.timers.push(setInterval(function() {
                self.updatePill(4, self.generateRandomValue('numeric', 5));
            }, this.intervals[4]));

            // Pill 5: Random LCARS data (updates every 1500ms)
            this.state.timers.push(setInterval(function() {
                self.updatePill(5, self.generateRandomValue('alphanumeric', 4));
            }, this.intervals[5]));
        },


        /**
         * Update the persistent OFFLINE indicator in the utility bar.
         *
         * Deliberately NOT routed through updatePill(): that early-returns when
         * its .candy-pill is absent, which is now always the case, so anything
         * hung off it would silently never run. Driven from live data instead.
         *
         * @param {number} count - machines currently offline
         */
        updateOfflineIndicator: function(count) {
            var el = document.getElementById('fleet-offline-indicator');
            if (!el) return;

            var n = Number(count) || 0;

            // Bail out when nothing changed. This is NOT a micro-optimisation:
            // this runs on a 100ms interval and the element is an aria-live
            // region, so writing to it unconditionally makes a screen reader
            // re-announce the offline count ten times a second -- during exactly
            // the incident this indicator exists to surface. updatePill() right
            // above gates on its previous value for the same reason; this must
            // follow that pattern. (XACA-0963 review round.)
            if (this.state.offlineIndicatorValue === n) return;
            this.state.offlineIndicatorValue = n;

            var countEl = document.getElementById('fleet-offline-count');
            if (countEl) countEl.textContent = String(n);

            // The pill stays visible at zero (restoring the pre-XACA-0963 pattern);
            // only the alert state is toggled.
            el.classList.toggle('offline-active', n > 0);
        },
        /**
         * Update a specific candy pill
         * @param {number} index - Pill index (0-5)
         * @param {string} value - New value to display
         */
        updatePill: function(index, value) {
            const pill = document.querySelector('.candy-pill[data-candy="' + index + '"]');
            if (!pill) return;

            const valueEl = pill.querySelector('.candy-value');
            if (!valueEl) return;

            // Store previous value for pulse detection
            const previousValue = this.state.values[index];
            this.state.values[index] = value;

            // Update display
            valueEl.textContent = value;

            // Trigger pulse animation if value changed significantly
            if (previousValue !== value && this.isSignificantChange(previousValue, value)) {
                this.triggerPulse(pill);
            }
        },

        /**
         * Check if a value change is significant enough for pulse
         * @param {string} oldVal - Previous value
         * @param {string} newVal - New value
         * @returns {boolean}
         */
        isSignificantChange: function(oldVal, newVal) {
            // For numeric values, check if the integer part changed
            const oldNum = parseInt(oldVal, 10);
            const newNum = parseInt(newVal, 10);

            if (!isNaN(oldNum) && !isNaN(newNum)) {
                return Math.abs(newNum - oldNum) >= 1;
            }

            // For alphanumeric, any change is significant
            return oldVal !== newVal;
        },

        /**
         * Trigger pulse animation on a candy pill
         * @param {HTMLElement} pill - The pill element
         */
        triggerPulse: function(pill) {
            pill.classList.add('candy-pulse');

            // Remove class after animation completes
            setTimeout(function() {
                pill.classList.remove('candy-pulse');
            }, 300);
        },

        /**
         * Format a number with leading zeros
         * @param {number} num - Number to format
         * @param {number} digits - Total digits
         * @returns {string}
         */
        formatNumber: function(num, digits) {
            return String(num).padStart(digits, '0');
        },

        /**
         * Generate random LCARS-style value
         * @param {string} type - 'numeric' or 'alphanumeric'
         * @param {number} length - Value length
         * @returns {string}
         */
        generateRandomValue: function(type, length) {
            if (type === 'alphanumeric') {
                const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789';
                let result = '';
                for (let i = 0; i < length; i++) {
                    result += chars.charAt(Math.floor(Math.random() * chars.length));
                }
                return result;
            }

            // Numeric
            const max = Math.pow(10, length) - 1;
            return this.formatNumber(Math.floor(Math.random() * max), length);
        },

        /**
         * Initialize candy inversion effect
         */
        initInversion: function() {
            const self = this;

            // Random inversion every 5-15 seconds
            function scheduleInversion() {
                const delay = 5000 + Math.random() * 10000;

                self.state.inversionTimer = setTimeout(function() {
                    self.triggerInversion();
                    scheduleInversion();
                }, delay);
            }

            scheduleInversion();
        },

        /**
         * Trigger inversion effect on random candy pills
         */
        triggerInversion: function() {
            // Only target data-driven pills (not static demo pills)
            const pills = document.querySelectorAll('.candy-pill[data-candy]');
            if (pills.length === 0) return;

            // Pick 1-3 random pills
            const count = 1 + Math.floor(Math.random() * 3);
            const indices = [];

            while (indices.length < count && indices.length < pills.length) {
                const idx = Math.floor(Math.random() * pills.length);
                if (indices.indexOf(idx) === -1) {
                    indices.push(idx);
                }
            }

            // Apply inversion
            indices.forEach(function(idx) {
                const pill = pills[idx];
                pill.classList.add('candy-inverted');

                // Remove after 200-500ms
                setTimeout(function() {
                    pill.classList.remove('candy-inverted');
                }, 200 + Math.random() * 300);
            });
        },

        /**
         * Apply color scheme for a section
         * @param {string} section - Section name
         */
        applyColorScheme: function(section) {
            const scheme = this.schemes[section] || this.schemes.overview;
            // Only target data-driven pills (not static demo pills)
            const pills = document.querySelectorAll('.candy-pill[data-candy]');

            pills.forEach(function(pill, index) {
                const schemeIndex = scheme.order[index] || index;
                const color = scheme.colors[schemeIndex] || 'blue';

                // Remove all color classes
                pill.className = pill.className.replace(/candy-\w+/g, '').trim();
                pill.classList.add('candy-pill', 'candy-' + color);
            });

            this.state.currentSection = section;
        },

        /**
         * Change to a new section
         * @param {string} section - Section name
         */
        changeSection: function(section) {
            if (this.schemes[section]) {
                this.applyColorScheme(section);
                console.log('[LCARS] Changed to section:', section);
            }
        },

        /**
         * Update data values from Fleet Monitor
         * @param {Object} data - Data object with machine/session counts
         */
        updateData: function(data) {
            if (data.totalMachines !== undefined) {
                this.data.totalMachines = data.totalMachines;
            }
            if (data.onlineMachines !== undefined) {
                this.data.onlineMachines = data.onlineMachines;
            }
            if (data.offlineMachines !== undefined) {
                this.data.offlineMachines = data.offlineMachines;
            }
            if (data.totalSessions !== undefined) {
                this.data.totalSessions = data.totalSessions;
            }

            // Check for alert condition (any offline machines)
            this.checkAlertCondition();
        },

        /**
         * Check if alert mode should be activated
         */
        checkAlertCondition: function() {
            const hasOffline = this.data.offlineMachines > 0;

            if (hasOffline && !this.state.alertMode) {
                this.enterAlertMode();
            } else if (!hasOffline && this.state.alertMode) {
                this.exitAlertMode();
            }
        },

        /**
         * Enter alert mode - offline machines detected
         */
        enterAlertMode: function() {
            const self = this;
            this.state.alertMode = true;

            // Get the offline pill (index 2)
            const offlinePill = document.querySelector('.candy-pill[data-candy="2"]');
            if (!offlinePill) return;

            // Add alert class
            offlinePill.classList.add('candy-alert');

            // Start alert pulse cycle
            function alertPulse() {
                if (!self.state.alertMode) return;

                offlinePill.classList.add('candy-alert-pulse');

                setTimeout(function() {
                    offlinePill.classList.remove('candy-alert-pulse');
                }, 500);
            }

            // Pulse every 2 seconds
            alertPulse();
            this.state.alertTimers.push(setInterval(alertPulse, 2000));

            console.log('[LCARS] Alert mode activated - offline machines detected');
        },

        /**
         * Exit alert mode - all machines online
         */
        exitAlertMode: function() {
            this.state.alertMode = false;

            // Clear alert timers
            this.state.alertTimers.forEach(function(timer) {
                clearInterval(timer);
            });
            this.state.alertTimers = [];

            // Remove alert classes from data-driven pills only
            const pills = document.querySelectorAll('.candy-pill[data-candy]');
            pills.forEach(function(pill) {
                pill.classList.remove('candy-alert', 'candy-alert-pulse');
            });

            console.log('[LCARS] Alert mode deactivated - all machines online');
        },

        /**
         * Clear all timers
         */
        clearTimers: function() {
            this.state.timers.forEach(function(timer) {
                clearInterval(timer);
            });
            this.state.timers = [];

            if (this.state.inversionTimer) {
                clearTimeout(this.state.inversionTimer);
                this.state.inversionTimer = null;
            }
        },

        /**
         * Destroy the candy system
         */
        destroy: function() {
            this.clearTimers();
            this.exitAlertMode();
            console.log('[LCARS] Candy pill system destroyed');
        }
    };

    // =========================================================================
    // UTILITY FUNCTIONS
    // =========================================================================

    LCARS.utils = {
        /**
         * Escape text for safe HTML interpolation (XACA-1100-018: promoted
         * from a private copy inside the MACHINE STATUS-ROW section below,
         * escapeHtmlForMachineItem, so the core has one canonical escaper
         * new callers can use instead of writing another local copy). Each
         * lcars2/lcars app file still carries its own local escapeHtml()
         * with several call sites unrelated to machine rendering -- this
         * promotion does NOT touch or delegate those; see the XACA-1100
         * plan doc for why that rewrite is a separate, larger-blast-radius
         * change left for a follow-up ticket.
         * @param {string} text
         * @returns {string}
         */
        escapeHtml: function(text) {
            if (!text) return '';
            const div = document.createElement('div');
            div.textContent = text;
            return div.innerHTML;
        },

        /**
         * Debounce function calls
         * @param {Function} func - Function to debounce
         * @param {number} wait - Wait time in ms
         * @returns {Function}
         */
        debounce: function(func, wait) {
            let timeout;
            return function() {
                const context = this;
                const args = arguments;
                clearTimeout(timeout);
                timeout = setTimeout(function() {
                    func.apply(context, args);
                }, wait);
            };
        },

        /**
         * Format timestamp for LCARS display
         * @param {Date} date - Date object
         * @returns {string}
         */
        formatStardate: function(date) {
            date = date || new Date();
            const year = date.getFullYear();
            const dayOfYear = Math.floor((date - new Date(year, 0, 0)) / 86400000);
            const fraction = Math.floor((date.getHours() * 60 + date.getMinutes()) / 1.44);
            return year + '.' + String(dayOfYear).padStart(3, '0') + '.' + String(fraction).padStart(2, '0');
        },

        /**
         * Format time for LCARS display (HH:MM:SS)
         * @param {Date} date - Date object
         * @returns {string}
         */
        formatTime: function(date) {
            date = date || new Date();
            return String(date.getHours()).padStart(2, '0') + ':' +
                   String(date.getMinutes()).padStart(2, '0') + ':' +
                   String(date.getSeconds()).padStart(2, '0');
        },

        /**
         * Animate a number from start to end value with easing
         * @param {HTMLElement} element - Element to update
         * @param {number} start - Starting value
         * @param {number} end - Target value
         * @param {number} duration - Animation duration in ms (default 500)
         * @param {string} suffix - Optional suffix (e.g., '%', 'ms')
         */
        animateNumber: function(element, start, end, duration, suffix) {
            if (!element) return;

            duration = duration || 500;
            suffix = suffix || '';

            const range = end - start;
            const startTime = performance.now();

            // Easing function (ease-out cubic)
            function easeOutCubic(t) {
                return 1 - Math.pow(1 - t, 3);
            }

            function update(currentTime) {
                const elapsed = currentTime - startTime;
                const progress = Math.min(elapsed / duration, 1);
                const eased = easeOutCubic(progress);
                const current = Math.round(start + (range * eased));

                element.textContent = current + suffix;

                // Add flash class when value changes
                if (progress < 1) {
                    requestAnimationFrame(update);
                } else {
                    // Ensure final value is exact
                    element.textContent = end + suffix;
                    // Trigger value-flash animation
                    element.classList.add('value-updated');
                    setTimeout(function() {
                        element.classList.remove('value-updated');
                    }, 300);
                }
            }

            requestAnimationFrame(update);
        },

        /**
         * Animate multiple numbers in parallel
         * @param {Array} animations - Array of {element, start, end, duration, suffix}
         */
        animateNumbers: function(animations) {
            var self = this;
            animations.forEach(function(anim) {
                self.animateNumber(anim.element, anim.start, anim.end, anim.duration, anim.suffix);
            });
        }
    };

    // =========================================================================
    // SECTION NAVIGATION
    // =========================================================================

    LCARS.sections = {
        // Available sections in order (XACA-0540: added 'engines')
        list: ['overview', 'organizations', 'machines', 'settings', 'engines'],

        // Current state
        active: 'overview',
        activeIndex: 0,

        // Storage key
        storageKey: 'lcars-fleet-section',

        // Animation duration in ms
        animationDuration: 300,

        /**
         * Initialize section navigation
         */
        init: function() {
            const self = this;

            // Restore saved section
            const saved = this.loadSavedSection();
            if (saved && this.list.indexOf(saved) !== -1) {
                this.switchSection(saved, true); // Skip animation on init
            } else {
                this.switchSection('overview', true);
            }

            // Bind sidebar button clicks
            document.querySelectorAll(NAV_SELECTOR).forEach(function(btn) {
                btn.addEventListener('click', function() {
                    self.switchSection(btn.dataset.section);
                });
                // The utility-bar pills are divs with role="button" and tabindex="0",
                // so they are focusable but get NO keyboard activation for free
                // (XACA-0963). Without this they are reachable by Tab and inert on Enter.
                btn.addEventListener('keydown', function(e) {
                    if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault();
                        self.switchSection(btn.dataset.section);
                    }
                });
            });

            // Bind keyboard navigation
            this.initKeyboardNav();

            console.log('[LCARS] Section navigation initialized');
        },

        /**
         * Switch to a new section
         * @param {string} sectionName - Name of section to switch to
         * @param {boolean} skipAnimation - Skip slide animation
         */
        switchSection: function(sectionName, skipAnimation) {
            const newIndex = this.list.indexOf(sectionName);
            if (newIndex === -1) return;

            // Determine direction
            const direction = newIndex > this.activeIndex ? 'right' : 'left';
            const previousSection = this.active;

            // Update state
            this.active = sectionName;
            this.activeIndex = newIndex;

            // Save to localStorage
            this.saveSection(sectionName);

            // Update sidebar buttons
            document.querySelectorAll(NAV_SELECTOR).forEach(function(btn) {
                btn.classList.toggle('active', btn.dataset.section === sectionName);
            });

            // Update section visibility with animation
            const self = this;
            this.list.forEach(function(section, idx) {
                const el = document.querySelector('.lcars-section[data-section="' + section + '"]');
                if (!el) return;

                // Remove previous animation classes
                el.classList.remove('slide-in-right', 'slide-in-left', 'slide-out-left', 'slide-out-right');

                if (section === sectionName) {
                    // Show new section
                    el.classList.add('active');
                    if (!skipAnimation) {
                        el.classList.add(direction === 'right' ? 'slide-in-right' : 'slide-in-left');
                    }
                } else {
                    // Hide other sections
                    if (section === previousSection && !skipAnimation) {
                        // Animate out
                        el.classList.add(direction === 'right' ? 'slide-out-left' : 'slide-out-right');
                        setTimeout(function() {
                            el.classList.remove('active', 'slide-out-left', 'slide-out-right');
                        }, 200);
                    } else {
                        el.classList.remove('active');
                    }
                }
            });

            // Update candy colors if available
            if (LCARS.candy && LCARS.candy.changeSection) {
                LCARS.candy.changeSection(sectionName);
            }

            console.log('[LCARS] Switched to section:', sectionName);

            // XACA-0540: Emit section-change event for modules (e.g. lcars-engines.js)
            document.dispatchEvent(new CustomEvent('lcars:sectionChange', { detail: { section: sectionName } }));
        },

        /**
         * Save active section to localStorage
         * @param {string} sectionName - Section name
         */
        saveSection: function(sectionName) {
            try {
                localStorage.setItem(this.storageKey, sectionName);
            } catch (e) {
                // localStorage not available
            }
        },

        /**
         * Load saved section from localStorage
         * @returns {string|null}
         */
        loadSavedSection: function() {
            try {
                return localStorage.getItem(this.storageKey);
            } catch (e) {
                return null;
            }
        },

        /**
         * Initialize keyboard navigation
         */
        initKeyboardNav: function() {
            const self = this;

            document.addEventListener('keydown', function(e) {
                // Option/Alt + keys for section switching
                if (e.altKey && !e.ctrlKey && !e.metaKey) {

                    // Use e.code for number keys (works on Mac where Option+number = special char)
                    if (e.code === 'Digit1' || e.code === 'Numpad1') {
                        e.preventDefault();
                        self.switchSection(self.list[0]);
                        return;
                    }
                    if (e.code === 'Digit2' || e.code === 'Numpad2') {
                        e.preventDefault();
                        self.switchSection(self.list[1]);
                        return;
                    }
                    if (e.code === 'Digit3' || e.code === 'Numpad3') {
                        e.preventDefault();
                        self.switchSection(self.list[2]);
                        return;
                    }
                    if (e.code === 'Digit4' || e.code === 'Numpad4') {
                        e.preventDefault();
                        self.switchSection(self.list[3]);
                        return;
                    }
                    // XACA-0540: Digit5 → engines
                    if (e.code === 'Digit5' || e.code === 'Numpad5') {
                        if (self.list.length > 4) {
                            e.preventDefault();
                            self.switchSection(self.list[4]);
                        }
                        return;
                    }

                }

                // Arrow keys for section navigation (when not in input)
                if (!e.target.matches('input, textarea, select')) {
                    if (e.key === 'ArrowLeft' && e.altKey) {
                        e.preventDefault();
                        self.previousSection();
                    } else if (e.key === 'ArrowRight' && e.altKey) {
                        e.preventDefault();
                        self.nextSection();
                    }
                }
            });
        },

        /**
         * Go to previous section
         */
        previousSection: function() {
            const newIndex = Math.max(0, this.activeIndex - 1);
            this.switchSection(this.list[newIndex]);
        },

        /**
         * Go to next section
         */
        nextSection: function() {
            const newIndex = Math.min(this.list.length - 1, this.activeIndex + 1);
            this.switchSection(this.list[newIndex]);
        },

        /**
         * Get keyboard shortcuts for display
         * @returns {Array}
         */
        getShortcuts: function() {
            // Use Option symbol for Mac, Alt for others
            var isMac = navigator.platform.toUpperCase().indexOf('MAC') >= 0;
            var modKey = isMac ? '⌥' : 'Alt';

            const shortcuts = [];
            this.list.forEach(function(section, idx) {
                shortcuts.push({
                    key: modKey + ' + ' + (idx + 1),
                    description: section.charAt(0).toUpperCase() + section.slice(1)
                });
            });
            shortcuts.push({ key: modKey + ' + R', description: 'Refresh' });
            shortcuts.push({ key: modKey + ' + ←', description: 'Previous Section' });
            shortcuts.push({ key: modKey + ' + →', description: 'Next Section' });
            return shortcuts;
        }
    };

    // =========================================================================
    // STARTUP BOOT SEQUENCE
    // =========================================================================

    LCARS.startup = {
        // Configuration
        duration: 4000,         // Total startup time in ms
        enabled: true,          // Can be disabled via localStorage
        storageKey: 'lcars-skip-startup',

        // State
        isRunning: false,
        timers: [],
        skipped: false,

        // Status messages shown during boot
        messages: [
            'LCARS INTERFACE v47.112',
            'LOADING KERNEL MODULES...',
            'INITIALIZING DISPLAY MATRIX...',
            'CONNECTING TO FLEET DATABASE...',
            'LOADING TERMINAL CONFIGURATIONS...',
            'SYNCHRONIZING MONITOR PROTOCOLS...',
            'ESTABLISHING SECURE CHANNELS...',
            'LOADING MACHINE PROFILES...',
            'CALIBRATING STATUS ENGINE...',
            'FLEET MONITOR READY'
        ],

        /**
         * Check if startup should be shown
         * @returns {boolean}
         */
        shouldShow: function() {
            if (!this.enabled) return false;
            try {
                return localStorage.getItem(this.storageKey) !== 'true';
            } catch (e) {
                return true;
            }
        },

        /**
         * Initialize and run startup sequence
         * @param {Function} onComplete - Callback when startup finishes
         */
        init: function(onComplete) {
            if (!this.shouldShow()) {
                console.log('[LCARS] Startup skipped (disabled)');
                if (onComplete) onComplete();
                return;
            }

            const section = document.querySelector('.startup-section');
            if (!section) {
                console.log('[LCARS] Startup section not found');
                if (onComplete) onComplete();
                return;
            }

            this.isRunning = true;
            this.skipped = false;
            this.onComplete = onComplete;

            // Set up click-to-skip
            const self = this;
            section.addEventListener('click', function() {
                self.skip();
            });

            // Load logo
            this.loadLogo();

            // Start data scroll
            this.startDataScroll();

            // Start progress bar
            this.startProgress();

            // Start status updates
            this.startStatusUpdates();

            // Schedule completion
            this.timers.push(setTimeout(function() {
                self.complete();
            }, this.duration));

            console.log('[LCARS] Startup sequence initiated');
        },

        /**
         * Load team logo with fallback
         */
        loadLogo: function() {
            const logoContainer = document.getElementById('startup-logo');
            if (!logoContainer) return;

            // Try to load image, fallback to text
            const img = document.createElement('img');
            img.src = 'images/academy_logo.png';
            img.alt = 'Starfleet Academy';

            img.onerror = function() {
                // Try SVG fallback
                this.onerror = function() {
                    // Final fallback to text
                    logoContainer.innerHTML = '<div class="startup-logo-fallback">⟐</div>';
                };
                this.src = 'images/academy_logo.svg';
            };

            img.onload = function() {
                logoContainer.appendChild(img);
            };

            // If image doesn't load quickly, show fallback
            setTimeout(function() {
                if (!logoContainer.querySelector('img')) {
                    logoContainer.innerHTML = '<div class="startup-logo-fallback">⟐</div>';
                }
            }, 500);
        },

        /**
         * Generate random LCARS-style data line
         * @returns {string}
         */
        generateDataLine: function() {
            const templates = [
                'SECTOR {HEX} RESPONSE: {HEX}',
                'NODE {NUM}: STATUS {STATUS}',
                'BUFFER {HEX} ALLOCATED',
                'CHANNEL {NUM} SYNC: {PCT}%',
                'MATRIX [{NUM}x{NUM}] INITIALIZED',
                'SUBSYSTEM {ALPHA}: {STATUS}',
                'PORT {NUM} BINDING: {HEX}',
                'CACHE BLOCK {HEX}: VALID',
                'PROTOCOL {ALPHA}-{NUM} ACTIVE',
                'MEMORY SEGMENT {HEX}: OK'
            ];

            const template = templates[Math.floor(Math.random() * templates.length)];

            return template
                .replace(/{HEX}/g, function() {
                    return '0x' + Math.floor(Math.random() * 0xFFFFFF).toString(16).toUpperCase().padStart(6, '0');
                })
                .replace(/{NUM}/g, function() {
                    return Math.floor(Math.random() * 999).toString().padStart(3, '0');
                })
                .replace(/{PCT}/g, function() {
                    return Math.floor(Math.random() * 100);
                })
                .replace(/{STATUS}/g, function() {
                    return ['ONLINE', 'READY', 'ACTIVE', 'OK'][Math.floor(Math.random() * 4)];
                })
                .replace(/{ALPHA}/g, function() {
                    return String.fromCharCode(65 + Math.floor(Math.random() * 26));
                });
        },

        /**
         * Start scrolling data lines
         */
        startDataScroll: function() {
            const scrollContainer = document.getElementById('startup-data-scroll');
            if (!scrollContainer) return;

            const self = this;
            let messageIndex = 0;
            const maxLines = 12;

            const interval = setInterval(function() {
                if (!self.isRunning) return;

                const line = document.createElement('div');
                line.className = 'data-line';

                // Mix status messages with random data
                if (messageIndex < self.messages.length && Math.random() > 0.6) {
                    line.textContent = '[OK] ' + self.messages[messageIndex];
                    line.classList.add('status');
                    messageIndex++;
                } else {
                    line.textContent = self.generateDataLine();
                    if (Math.random() > 0.7) line.classList.add('hex');
                }

                scrollContainer.appendChild(line);

                // Keep only last N lines
                while (scrollContainer.children.length > maxLines) {
                    scrollContainer.removeChild(scrollContainer.firstChild);
                }

                // Auto-scroll to bottom
                scrollContainer.scrollTop = scrollContainer.scrollHeight;
            }, 80);

            this.timers.push(interval);
        },

        /**
         * Start progress bar animation
         */
        startProgress: function() {
            const progressBar = document.getElementById('startup-progress-bar');
            if (!progressBar) return;

            const self = this;
            let progress = 0;

            const interval = setInterval(function() {
                if (!self.isRunning) return;

                progress += Math.random() * 6 + 2;
                if (progress > 100) progress = 100;

                progressBar.style.width = progress + '%';

                if (progress >= 100) {
                    clearInterval(interval);
                    progressBar.classList.add('complete');
                }
            }, 100);

            this.timers.push(interval);
        },

        /**
         * Start status text updates
         */
        startStatusUpdates: function() {
            const statusEl = document.getElementById('startup-status');
            if (!statusEl) return;

            const phases = [
                'INITIALIZING...',
                'LOADING SUBSYSTEMS...',
                'ESTABLISHING CONNECTIONS...',
                'VERIFYING INTEGRITY...',
                'SYSTEM READY'
            ];

            const self = this;
            let phase = 0;

            const interval = setInterval(function() {
                if (!self.isRunning) return;

                phase++;
                if (phase < phases.length) {
                    statusEl.textContent = phases[phase];
                    if (phase === phases.length - 1) {
                        statusEl.classList.add('ready');
                    }
                }
            }, 700);

            this.timers.push(interval);
        },

        /**
         * Skip startup sequence
         */
        skip: function() {
            if (this.skipped || !this.isRunning) return;
            this.skipped = true;
            console.log('[LCARS] Startup skipped by user');
            this.complete();
        },

        /**
         * Complete startup and transition out
         */
        complete: function() {
            if (!this.isRunning) return;
            this.isRunning = false;

            // Clear all timers
            this.timers.forEach(function(timer) {
                clearInterval(timer);
                clearTimeout(timer);
            });
            this.timers = [];

            // Update final state
            const progressBar = document.getElementById('startup-progress-bar');
            const statusEl = document.getElementById('startup-status');

            if (progressBar) {
                progressBar.style.width = '100%';
                progressBar.classList.add('complete');
            }
            if (statusEl) {
                statusEl.textContent = 'SYSTEM READY';
                statusEl.classList.add('ready');
            }

            // Fade out and remove
            const section = document.querySelector('.startup-section');
            const self = this;

            if (section) {
                section.classList.add('fade-out');
                setTimeout(function() {
                    section.classList.add('hidden');
                    if (self.onComplete) self.onComplete();
                }, 500);
            } else {
                if (this.onComplete) this.onComplete();
            }

            console.log('[LCARS] Startup sequence complete');
        },

        /**
         * Disable startup for future loads
         */
        disable: function() {
            try {
                localStorage.setItem(this.storageKey, 'true');
            } catch (e) {}
        },

        /**
         * Re-enable startup for future loads
         */
        enable: function() {
            try {
                localStorage.removeItem(this.storageKey);
            } catch (e) {}
        }
    };

    // =========================================================================
    // MACHINE STATUS-ROW RENDERING (XACA-1100-002)
    // =========================================================================
    //
    // createMachineItem() was byte-identical across all 4 lcars2 app files
    // (lcars-academy-app.js, lcars-doublenode-app.js, lcars-mainevent-app.js,
    // lcars-all-app.js -- md5 3f6dc7d190b7db92f7c2fbb4d43ee4cf over the
    // function extent) with no lcars2-specific logic of its own, so it is
    // extracted here as the single shared implementation. It does NOT touch
    // lcars-dashboard-app.js's own createMachineItem() (v1, lcars/js/) --
    // that is a genuinely different, much larger component (nickname editor,
    // backup panel, history panel, sparkline) that merely shares a name; see
    // XACA-1100 plan doc.
    //
    // This function runs in the CORE's closure, not the calling app file's,
    // so it cannot see that file's own machineSystemToHealthInput(),
    // healthBadgeSpec(), buildSystemSectionHtml(), toggleSystemPanel(), or
    // expandedSystemMachineId -- all of which remain owned by each app file
    // (per-dashboard state and logic that XACA-1100 does not attempt to
    // unify; see the Design Decision 6 note in each app file). The caller
    // wires them in via `deps` instead.
    //
    // escapeHtml() is the one exception: rather than take it via `deps`,
    // createMachineItem() below calls LCARS.utils.escapeHtml() -- the core's
    // own canonical escaper (XACA-1100-018; previously a private copy
    // named escapeHtmlForMachineItem lived right here, promoted to
    // LCARS.utils above so the core owns one shared implementation instead
    // of an implementation detail nothing else could reach). Each app
    // file's own escapeHtml() has several OTHER call sites unrelated to
    // createMachineItem (team name / session details / system-panel rows)
    // and is NOT rewritten to delegate here -- that is a separate,
    // larger-blast-radius change (~15 call sites per file) left for a
    // follow-up ticket; see the XACA-1100 plan doc.

    LCARS.machines = {
        /**
         * Build the machine status-row DOM fragment (status indicator,
         * hostname, session count, version indicator, health badge, and the
         * SYSTEM disclosure detail panel) for one machine entry.
         *
         * @param {Object} machine - machine record from the fleet API
         * @param {Object} deps - caller-supplied hooks. REQUIRED -- every key
         *   below except isSystemExpanded is invoked unconditionally further
         *   down; there is no fallback path that renders correctly without
         *   them (see the module comment above for why they can't be
         *   resolved from here instead of threaded in):
         *   - machineSystemToHealthInput(system) -> health-derivation input
         *   - healthBadgeSpec(healthResult) -> {className, text} | falsy
         *   - buildSystemSectionHtml(system, isSystemExpanded) -> HTML string | ''
         *   - toggleSystemPanel(machineId, detailEl) -> expand/collapse this machine's panel
         *   - isSystemExpanded {boolean} [optional, default false] -> whether
         *     THIS machine's panel is currently expanded -- the one genuinely
         *     optional key, coerced with `!!` below.
         * @throws {Error} if deps or any required hook function is missing --
         *   fails loud and names the missing key(s), rather than the
         *   `deps = deps || {}` fallback this replaced (XACA-1100-014):
         *   that produced an empty object which was just as unusable as no
         *   object at all, throwing one line later on the first unguarded
         *   hook call with a generic "cannot read properties of undefined"
         *   instead of a message that says what's actually missing. A guard
         *   that cannot prevent the failure it looks like it guards against
         *   is worse than no guard -- it reads as safety that isn't there.
         * @returns {DocumentFragment}
         */
        createMachineItem: function(machine, deps) {
            var REQUIRED_DEPS = ['machineSystemToHealthInput', 'healthBadgeSpec', 'buildSystemSectionHtml', 'toggleSystemPanel'];
            var missingDeps = REQUIRED_DEPS.filter(function (key) {
                return !deps || typeof deps[key] !== 'function';
            });
            if (missingDeps.length) {
                throw new Error('LCARS.machines.createMachineItem: deps.' + missingDeps.join('(), deps.') +
                    '() must be supplied as function(s) -- see the deps JSDoc on this method.');
            }
            const system = machine.system || {};
            const healthResult = (window.LCARS_MACHINE_HEALTH && window.LCARS_MACHINE_HEALTH.deriveMachineHealth)
                ? window.LCARS_MACHINE_HEALTH.deriveMachineHealth(deps.machineSystemToHealthInput(system))
                : { state: 'unknown', metrics: {} };

            const item = document.createElement('div');
            item.className = 'status-row ' + machine.status;

            // XACA-1031-006 (EPIC-0061 Decision 8): version lives at
            // machine.system.versions.*, not machine.versions.*. An OLD reporter
            // that predates this feature sends no `system` key at all -- that is
            // most of the fleet today, including this very machine -- so guard
            // with optional chaining and render NO version indicator for that
            // case rather than "undefined". Additive only: this is the 18-line
            // minimal renderer, not the 196-line rich one in lcars/js -- no
            // shared helper is being extracted here (see XACA-1031 plan doc).
            //
            // XACA-1031-006 BUGFIX: the frozen contract has the reporter ALWAYS
            // emit the `versions` container, sending `versions: {}` when the
            // version itself is unresolvable -- `{}` is truthy, so gating on
            // `sysVersions` alone rendered "vUnknown UNKNOWN" on every card
            // fleet-wide (this machine included -- the tap isn't installed here
            // either). "no version reported" and "version known, staleness
            // undetermined" are different facts and must render differently, so
            // the whole indicator (including the 'v' prefix) is now gated on
            // `aiteamforge` PRESENCE, not on `sysVersions` truthiness.
            const sysVersions = machine.system && machine.system.versions;
            const hasInstalledVersion = !!sysVersions && sysVersions.aiteamforge !== undefined && sysVersions.aiteamforge !== null;
            let installedVersionText, versionColor, versionSuffix, outdated;
            if (hasInstalledVersion) {
                installedVersionText = String(sysVersions.aiteamforge);
                // 'outdated' is an EXISTENCE check, not a null check: the key is
                // OMITTED (not set to null) when the server could not determine
                // it (version known, but its own latest-version fetch failed).
                // A null-check here would silently render "unknown" as
                // "confirmed current" -- the exact failure this ticket exists
                // to prevent.
                const hasOutdatedKey = Object.prototype.hasOwnProperty.call(sysVersions, 'outdated');
                outdated = hasOutdatedKey ? sysVersions.outdated : undefined;

                versionColor = 'var(--lcars-amber)';
                versionSuffix = ' UNKNOWN';
                if (outdated === true) {
                    versionColor = 'var(--lcars-alert-red)';
                    versionSuffix = ' OUTDATED';
                } else if (outdated === false) {
                    versionColor = 'var(--lcars-green)';
                    versionSuffix = '';
                }
            }

            // XACA-0416-004 UPDATE (XACA-1031-018): the version indicator is no
            // longer built by string-interpolating installedVersionText into an
            // innerHTML template -- it is built below with document.
            // createElement()/textContent/setAttribute(), AFTER the
            // item.innerHTML assignment (innerHTML REPLACES all children, so an
            // element built before that assignment would be destroyed by it --
            // that is why the insertBefore call is down in the `if
            // (hasInstalledVersion)` block below, not up here). textContent and
            // setAttribute cannot be made to produce markup -- the browser does
            // the escaping structurally at the DOM-API boundary -- so there is
            // deliberately no escapeHtml()/escapeAttr() call on
            // installedVersionText anywhere in this function any more,
            // including for the new aria-label. If you are reverting this back
            // to a string-interpolated innerHTML template (the shape
            // XACA-1031-006 originally shipped), you are reintroducing that
            // escaping obligation for BOTH the visible text and the aria-label
            // -- re-add escapeHtml()/escapeAttr() calls at every interpolation
            // point when you do.
            //
            // XACA-0416-004 (unchanged): machine.hostname is stored verbatim
            // from the POST /api/status body -- untrusted, ELEMENT CONTENT ->
            // escapeHtml. machine.status is server-derived by
            // updateMachineStatuses(), which only ever writes 'online'/
            // 'offline'/'warning', and machine.session_count is a computed
            // integer; both stay unwrapped. No untrusted value reaches a quoted
            // attribute via string interpolation in this file, so escapeAttr()
            // is deliberately NOT defined here -- do not add a helper with no
            // call site.
            item.innerHTML =
                '<span class="status-indicator ' + machine.status + '"></span>' +
                '<span class="lcars-text-sm status-row-hostname" style="flex: 1;">' + LCARS.utils.escapeHtml(machine.hostname) + '</span>' +
                '<span class="lcars-text-xs" style="color: var(--lcars-tan);">' + machine.session_count + ' sessions</span>';

            if (hasInstalledVersion) {
                // XACA-1031-018 ([UX] NICE-TO-HAVE): a bare title="..." on a
                // non-focusable span has weak/inconsistent screen-reader
                // support. aria-label mirrors the FULL visible text (version
                // number plus its outdated/up-to-date/unknown state) so
                // assistive tech announces the same information a sighted user
                // reads off the card. title= is kept as-is for the sighted
                // mouse-hover tooltip -- the two are not in tension, aria-label
                // simply gives the accessibility tree a reliable value.
                const versionEl = document.createElement('span');
                versionEl.className = 'lcars-text-xs status-row-version';
                versionEl.setAttribute('style', 'color: ' + versionColor + '; white-space: nowrap;');
                versionEl.setAttribute('title', 'aiteamforge version');
                versionEl.textContent = 'v' + installedVersionText + versionSuffix;
                const versionStateText = outdated === true ? 'outdated' : outdated === false ? 'up to date' : 'update status unknown';
                versionEl.setAttribute('aria-label', 'AITeamForge version ' + installedVersionText + ', ' + versionStateText);
                // Insert between the hostname span and the session-count span
                // -- item.lastElementChild is the session-count span at this
                // point (it is always the last child the innerHTML assignment
                // above produces), which stays correct regardless of what else
                // is or isn't a sibling. Do not reorder -- XACA-1031-016's
                // overflow guard and this row's visual layout both depend on
                // this exact position.
                item.insertBefore(versionEl, item.lastElementChild);
            }

            // XACA-1092-005: the HEALTH badge is appended AFTER XACA-1031's
            // version indicator is inserted above, and via the DOM API rather
            // than by extending the innerHTML template. Both are deliberate.
            // Appending to innerHTML here would destroy the versionEl built
            // above (innerHTML REPLACES all children); and XACA-1031-018's
            // insertBefore(versionEl, item.lastElementChild) is documented to
            // rely on lastElementChild being the session-count span at that
            // moment, which stops being true the instant this badge is added --
            // so the badge must come after, never before. The badge class comes
            // from a fixed literal set this file chooses (health-warning /
            // health-critical), never from reporter data, so no escaping
            // obligation is introduced; `unknown` and `healthy` render NO node
            // at all (UX spec addendum 1) -- on a fleet where nothing reports
            // system data yet, a visible "unknown" pill would appear on every
            // card simultaneously.
            const badgeSpec = deps.healthBadgeSpec(healthResult);
            if (badgeSpec) {
                const badgeEl = document.createElement('span');
                badgeEl.className = badgeSpec.className;
                badgeEl.textContent = badgeSpec.text;
                badgeEl.setAttribute('aria-label', 'machine health: ' + badgeSpec.text);
                item.appendChild(badgeEl);
            }

            // XACA-1092-004/-005: lcars2's `.status-row` is today a single flex
            // row (no vertical stacking) and is also used by other, non-machine
            // listings on this page, so it is deliberately left alone -- the
            // version line / SYSTEM toggle / SYSTEM panel are built as a
            // SEPARATE sibling block ("detail") and returned together with
            // `item` inside a DocumentFragment, the same way v1's
            // createMachineItem() already returns its own `.machine-item-container`
            // plus a sibling `.machine-history-panel`. This is lcars2's first
            // click affordance (UX spec §1) -- following v1's backup-toggle
            // mechanics (chevron + `.expanded` class, no async fetch; the panel
            // content is already in the DOM from the initial render, unlike the
            // history panel's fetch-driven "Loading history..." placeholder).
            const fragment = document.createDocumentFragment();
            fragment.appendChild(item);

            const isSystemExpanded = !!deps.isSystemExpanded;
            const detailHtml = deps.buildSystemSectionHtml(system, isSystemExpanded);
            if (detailHtml !== '') {
                const detail = document.createElement('div');
                detail.className = 'status-row-detail';
                detail.innerHTML = detailHtml;
                fragment.appendChild(detail);

                const toggle = detail.querySelector('.status-row-system-toggle');
                if (toggle) {
                    // data-machine-id is set via the DOM API, not baked into the
                    // innerHTML string above -- see buildSystemSectionHtml()'s
                    // comment on why that keeps escapeAttr() unneeded here.
                    toggle.setAttribute('data-machine-id', machine.machine_id);
                    // XACA-1092-021 (WCAG 2.1.1): this is lcars2's FIRST
                    // click affordance and shipped with no keyboard path at all
                    // -- give it the same tabindex/role/keydown shape the
                    // LCARS-terminal card above already uses (see the
                    // card.setAttribute('tabindex', '0') / keydown block near
                    // XACA-0983-014), applied via setAttribute rather than
                    // baked into the innerHTML template for the same reason
                    // data-machine-id is (see buildSystemSectionHtml()'s
                    // comment). aria-expanded is initialized to the real
                    // current state here and kept in sync by
                    // toggleSystemPanel() on every subsequent transition,
                    // including when a DIFFERENT machine's panel is closed as
                    // a side effect of opening this one.
                    toggle.setAttribute('tabindex', '0');
                    toggle.setAttribute('role', 'button');
                    toggle.setAttribute('aria-expanded', isSystemExpanded ? 'true' : 'false');
                    toggle.addEventListener('click', function (e) {
                        e.stopPropagation();
                        deps.toggleSystemPanel(machine.machine_id, detail);
                    });
                    toggle.addEventListener('keydown', function (e) {
                        // Enter and Space both activate, matching the
                        // LCARS-terminal card's keydown handler above. Space
                        // must be preventDefault()'d or the page scrolls --
                        // the browser's default action for Space on a
                        // non-native-button element with a keydown listener is
                        // to scroll the viewport.
                        if (e.key === 'Enter' || e.key === ' ' || e.key === 'Spacebar' || e.keyCode === 13 || e.keyCode === 32) {
                            // No stopPropagation() here, matching the
                            // LCARS-terminal card's own keydown handler
                            // precedent (XACA-0983-014) -- only the CLICK
                            // handler above needs it (to stop a click from
                            // also reaching a row-level click handler); no
                            // parent keydown listener exists in this file for
                            // Enter/Space to conflict with.
                            e.preventDefault();
                            deps.toggleSystemPanel(machine.machine_id, detail);
                        }
                    });
                }
            }

            return fragment;
        }
    };

    // =========================================================================
    // UI PREFERENCE MANAGEMENT
    // =========================================================================

    LCARS.ui = {
        // Storage key for UI preference
        storageKey: 'fleet-ui-preference',

        // Available UI options
        options: {
            classic: 'classic',
            lcars: 'lcars'
        },

        // Route mappings: classic path -> LCARS path
        routeMap: {
            '/': '/lcars',
            '/mainevent': '/lcars/mainevent',
            '/doublenode': '/lcars/doublenode',
            '/all': '/lcars/all'
        },

        // Reverse route mappings: LCARS path -> classic path
        reverseRouteMap: {
            '/lcars': '/',
            '/lcars/mainevent': '/mainevent',
            '/lcars/doublenode': '/doublenode',
            '/lcars/all': '/all'
        },

        /**
         * Set UI preference
         * @param {string} ui - 'classic' or 'lcars'
         */
        setPreference: function(ui) {
            try {
                localStorage.setItem(this.storageKey, ui);
                console.log('[LCARS] UI preference set to:', ui);
            } catch (e) {
                console.warn('[LCARS] Could not save UI preference');
            }
        },

        /**
         * Get current UI preference
         * @returns {string} - 'classic' or 'lcars'
         */
        getPreference: function() {
            try {
                return localStorage.getItem(this.storageKey) || 'classic';
            } catch (e) {
                return 'classic';
            }
        },

        /**
         * Check if currently on LCARS interface
         * @returns {boolean}
         */
        isLcarsInterface: function() {
            return window.location.pathname.startsWith('/lcars');
        },

        /**
         * Get equivalent path in the other UI
         * @param {string} targetUI - 'classic' or 'lcars'
         * @returns {string} - The path to navigate to
         */
        getEquivalentPath: function(targetUI) {
            const currentPath = window.location.pathname;

            if (targetUI === 'lcars') {
                // Find matching LCARS path
                return this.routeMap[currentPath] || '/lcars';
            } else {
                // Find matching classic path
                return this.reverseRouteMap[currentPath] || '/';
            }
        },

        /**
         * Switch to classic UI
         */
        switchToClassic: function() {
            this.setPreference('classic');
            const newPath = this.getEquivalentPath('classic');
            window.location.href = newPath;
        },

        /**
         * Switch to LCARS UI
         */
        switchToLcars: function() {
            this.setPreference('lcars');
            const newPath = this.getEquivalentPath('lcars');
            window.location.href = newPath;
        },

        /**
         * Auto-redirect based on preference (call on page load if desired)
         * Only redirects if preference doesn't match current interface
         */
        autoRedirect: function() {
            const preference = this.getPreference();
            const isLcars = this.isLcarsInterface();

            if (preference === 'lcars' && !isLcars) {
                // User prefers LCARS but is on classic
                const lcarsPath = this.getEquivalentPath('lcars');
                console.log('[LCARS] Auto-redirecting to LCARS interface:', lcarsPath);
                window.location.href = lcarsPath;
                return true;
            } else if (preference === 'classic' && isLcars) {
                // User prefers classic but is on LCARS - don't auto-redirect
                // (Let them stay on LCARS if they navigated there directly)
                return false;
            }

            return false;
        }
    };

    // Expose convenience functions at LCARS level
    LCARS.setUIPreference = function(ui) {
        LCARS.ui.setPreference(ui);
    };

    LCARS.getUIPreference = function() {
        return LCARS.ui.getPreference();
    };

    LCARS.switchToClassic = function() {
        LCARS.ui.switchToClassic();
    };

    LCARS.switchToLcars = function() {
        LCARS.ui.switchToLcars();
    };

    // =========================================================================
    // INITIALIZATION
    // =========================================================================

    /**
     * Initialize LCARS Core when DOM is ready
     */
    LCARS.init = function(options) {
        options = options || {};

        const initSystems = function() {
            // Initialize candy system
            if (options.candy !== false) {
                LCARS.candy.init(options.candyOptions || {});
            }

            // Initialize section navigation
            if (options.sections !== false) {
                LCARS.sections.init();
            }

            // XACA-0538-005: Check vault mode signal once after startup.
            // Shows a one-time warning popup if secrets are in env-var failover mode.
            // Fully defensive — absent endpoint or any error = silent no-op.
            if (window.VaultOfflinePopup && typeof window.VaultOfflinePopup.check === 'function') {
                window.VaultOfflinePopup.check();
            }

            console.log('[LCARS] Core initialized');
        };

        // Run startup sequence first if enabled
        if (options.startup !== false && LCARS.startup.shouldShow()) {
            LCARS.startup.init(initSystems);
        } else {
            // Hide startup section if it exists
            const startupSection = document.querySelector('.startup-section');
            if (startupSection) {
                startupSection.classList.add('hidden');
            }
            initSystems();
        }
    };

    // Auto-initialize on DOM ready if not explicitly disabled
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function() {
            if (window.LCARS_AUTO_INIT !== false) {
                LCARS.init();
            }
        });
    }

})(window.LCARS_CORE);
