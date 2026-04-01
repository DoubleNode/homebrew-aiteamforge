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
            // Pulse animation
            pill.classList.add('candy-pulse');

            // Add brief glow effect for extra visual feedback
            pill.classList.add('lcars-glow-fast');

            // Remove classes after animation completes
            setTimeout(function() {
                pill.classList.remove('candy-pulse');
            }, 300);

            setTimeout(function() {
                pill.classList.remove('lcars-glow-fast');
            }, 1000);
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

            // Add alert classes - red alert effect on just the OFFLINE pill
            offlinePill.classList.add('candy-alert', 'lcars-red-alert-border');

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
                pill.classList.remove('candy-alert', 'candy-alert-pulse', 'lcars-red-alert-border');
            });

            console.log('[LCARS] Alert mode deactivated - all machines online');
        },

        /**
         * Trigger shimmer effect on all data pills (for loading state)
         */
        triggerShimmer: function() {
            const pills = document.querySelectorAll('.candy-pill[data-candy]');
            pills.forEach(function(pill, index) {
                // Stagger the shimmer effect
                setTimeout(function() {
                    pill.classList.remove('lcars-shimmer');
                    void pill.offsetWidth; // Force reflow
                    pill.classList.add('lcars-shimmer');
                    setTimeout(function() {
                        pill.classList.remove('lcars-shimmer');
                    }, 2000);
                }, index * 100);
            });
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
    // PERSONA AVATAR SYSTEM
    // =========================================================================

    LCARS.personas = {
        // API-driven team config cache
        teamConfigCache: null,
        teamConfigFetchInProgress: false,

        // Persona metadata map (name -> display info)
        // FALLBACK ONLY - real data comes from API
        metadata: {
            // Academy
            'reno': { name: 'Commander Jett Reno', role: 'Chief Technical Instructor - Development & Infrastructure', team: 'Academy' },
            'nahla': { name: 'Captain Nahla Ake', role: 'Chancellor & Strategic Leader - Starfleet Academy', team: 'Academy' },
            'emh': { name: 'The Doctor (EMH Mark I)', role: 'Training Officer - Documentation & Knowledge Management', team: 'Academy' },
            'thok': { name: 'Lura Thok', role: 'Cadet Master - Testing & Quality Assurance', team: 'Academy' },

            // iOS
            'captain': { name: 'Jean-Luc Picard', role: 'Lead Feature Developer - iOS Team', team: 'iOS' },
            'data': { name: 'Data', role: 'Lead Refactoring Developer - iOS Team', team: 'iOS' },
            'doctor': { name: 'Beverly Crusher', role: 'iOS Bug Fix Developer', team: 'iOS' },
            'counselor': { name: 'Deanna Troi', role: 'iOS Documentation Expert', team: 'iOS' },
            'geordi': { name: 'Geordi La Forge', role: 'iOS Release Developer', team: 'iOS' },
            'worf': { name: 'Worf', role: 'Lead Tester - iOS Team', team: 'iOS' },
            'wesley': { name: 'Wesley Crusher', role: 'iOS UX Expert & Design Systems Developer', team: 'iOS' },

            // Android
            'kirk': { name: 'James T. Kirk', role: 'Lead Feature Developer - Android Team', team: 'Android' },
            'spock': { name: 'Spock', role: 'Lead Refactoring Developer - Android Team', team: 'Android' },
            'mccoy': { name: 'Leonard McCoy', role: 'Bug Fix Developer - Android Team', team: 'Android' },
            'scotty': { name: 'Montgomery Scott', role: 'Release Developer - Android Team', team: 'Android' },
            'uhura': { name: 'Nyota Uhura', role: 'UX Expert - Android Team', team: 'Android' },
            'sulu': { name: 'Hikaru Sulu', role: 'Documentation Expert - Android Team', team: 'Android' },
            'chekov': { name: 'Pavel Chekov', role: 'Lead Tester - Android Team', team: 'Android' },

            // Firebase
            'sisko': { name: 'Benjamin Sisko', role: 'Lead Feature Developer - Firebase Team', team: 'Firebase' },
            'dax': { name: 'Jadzia Dax', role: 'Lead Refactoring Developer - Firebase Team', team: 'Firebase' },
            'kira': { name: 'Major Kira Nerys', role: 'Documentation Expert - Firebase Team', team: 'Firebase' },
            'obrien': { name: 'Miles Edward O\'Brien', role: 'Release Developer & DevOps - Firebase Team', team: 'Firebase' },
            'odo': { name: 'Odo', role: 'Lead Tester & Security - Firebase Team', team: 'Firebase' },
            'bashir': { name: 'Julian Bashir', role: 'Bug Fix Developer & Diagnostician - Firebase Team', team: 'Firebase' },
            'quark': { name: 'Quark', role: 'UX Expert & API Design - Firebase Team', team: 'Firebase' },

            // DNS Framework
            'mariner': { name: 'Beckett Mariner', role: 'Lead Feature Developer - DNS Framework Team', team: 'DNS Framework' },
            'tendi': { name: 'D\'Vana Tendi', role: 'Lead Refactoring Developer - DNS Framework Team', team: 'DNS Framework' },
            'tana': { name: 'Dr. T\'Ana', role: 'Bug Fix Developer - DNS Framework Team', team: 'DNS Framework' },
            'rutherford': { name: 'Sam Rutherford', role: 'Release Engineer - DNS Framework Team', team: 'DNS Framework' },
            'shaxs': { name: 'Lieutenant Shaxs', role: 'Lead Tester - DNS Framework Team', team: 'DNS Framework' },
            'ransom': { name: 'Commander Jack Ransom', role: 'Documentation Lead - DNS Framework Team', team: 'DNS Framework' },
            'boimler': { name: 'Brad Boimler', role: 'API Design & Developer Experience Expert - DNS Framework Team', team: 'DNS Framework' },

            // Freelance
            'archer': { name: 'Captain Jonathan Archer', role: 'Lead Feature Developer - Freelance Team', team: 'Freelance' },
            'tpol': { name: 'Sub-Commander T\'Pol', role: 'Lead Refactoring Developer - Freelance Team', team: 'Freelance' },
            'phlox': { name: 'Dr. Phlox', role: 'Bug Fix Developer - Freelance Team', team: 'Freelance' },
            'tucker': { name: 'Commander Charles "Trip" Tucker III', role: 'Release Engineer - Freelance Team', team: 'Freelance' },
            'reed': { name: 'Lieutenant Malcolm Reed', role: 'Security & Testing Lead - Freelance Team', team: 'Freelance' },
            'sato': { name: 'Ensign Hoshi Sato', role: 'Documentation Expert - Freelance Team', team: 'Freelance' },
            'mayweather': { name: 'Ensign Travis Mayweather', role: 'UX/UI Developer - Freelance Team', team: 'Freelance' },

            // MainEvent
            'me_janeway': { name: 'Captain Kathryn Janeway', role: 'Strategic Development & Feature Architecture', team: 'MainEvent' },
            'me_doctor': { name: 'The Doctor (EMH)', role: 'Bug Diagnosis & Rapid Resolution', team: 'MainEvent' },
            'me_seven': { name: 'Seven of Nine', role: 'Code Optimization & Refactoring', team: 'MainEvent' },
            'me_torres': { name: 'B\'Elanna Torres', role: 'Release Engineering & Deployment Systems', team: 'MainEvent' },
            'me_paris': { name: 'Tom Paris', role: 'User Experience & Interface Design', team: 'MainEvent' },
            'me_kim': { name: 'Harry Kim', role: 'Technical Documentation & API Design', team: 'MainEvent' },
            'me_tuvok': { name: 'Tuvok', role: 'Security Validation & Quality Assurance', team: 'MainEvent' },

            // Command
            'vance': { name: 'Admiral Charles Vance', role: 'Commander, Starfleet / Supreme Commander', team: 'Command' },
            'janeway': { name: 'Admiral Kathryn Janeway', role: 'Strategic Operations Director', team: 'Command' },
            'ross': { name: 'Admiral William Ross', role: 'Chief of Operations / Release Management', team: 'Command' },
            'nechayev': { name: 'Admiral Alynna Nechayev', role: 'Intelligence Director / Security Chief', team: 'Command' },
            'paris': { name: 'Admiral Owen Paris', role: 'Communications Director', team: 'Command' },

            // Legal (Boston Legal)
            'crane': { name: 'Denny Crane', role: 'Lead Counsel & Senior Partner', team: 'Legal' },
            'shore': { name: 'Alan Shore', role: 'Mediation Specialist & Settlement Negotiator', team: 'Legal' },
            'schmidt': { name: 'Shirley Schmidt', role: 'Timeline Coordinator & Managing Partner', team: 'Legal' },
            'chase': { name: 'Brad Chase', role: 'Filing Specialist & Motion Drafter', team: 'Legal' },
            'sack': { name: 'Carl Sack', role: 'Legal Researcher & Case Law Analyst', team: 'Legal' },
            'espenson': { name: 'Jerry Espenson', role: 'Discovery Specialist & Evidence Analyst', team: 'Legal' }
        },

        // Tooltip state
        tooltipState: {
            element: null,
            visible: false,
            currentPersona: null,
            hideTimer: null
        },

        /**
         * Initialize persona avatar tooltip system
         */
        init: function() {
            const self = this;

            // Fetch team config from API
            this.fetchTeamConfig();

            // Refresh team config every 60 seconds
            setInterval(function() {
                self.fetchTeamConfig();
            }, 60000);

            // Create tooltip element
            this.createTooltipElement();

            // Use event delegation for all avatars and terminal logos
            document.addEventListener('mouseenter', function(e) {
                const avatar = e.target.closest('.lcars-avatar');
                const terminalLogo = e.target.closest('.team-terminal-logo');
                if (avatar) {
                    self.showTooltip(avatar);
                } else if (terminalLogo) {
                    self.showTerminalTooltip(terminalLogo);
                }
            }, true);

            document.addEventListener('mouseleave', function(e) {
                const avatar = e.target.closest('.lcars-avatar');
                const terminalLogo = e.target.closest('.team-terminal-logo');
                if (avatar || terminalLogo) {
                    self.scheduleHideTooltip();
                }
            }, true);

            // Keep tooltip visible when hovering over it
            if (this.tooltipState.element) {
                this.tooltipState.element.addEventListener('mouseenter', function() {
                    self.cancelHideTooltip();
                });

                this.tooltipState.element.addEventListener('mouseleave', function() {
                    self.scheduleHideTooltip();
                });
            }

            console.log('[LCARS] Persona avatar tooltip system initialized');
        },

        /**
         * Fetch team configuration from API
         */
        fetchTeamConfig: async function() {
            // Prevent concurrent fetches
            if (this.teamConfigFetchInProgress) return;

            this.teamConfigFetchInProgress = true;

            try {
                const response = await fetch('/api/team-config');
                if (!response.ok) {
                    throw new Error('Failed to fetch team config: ' + response.status);
                }

                const data = await response.json();
                this.teamConfigCache = data;
                console.log('[LCARS] Team config loaded from API:', Object.keys(data.teams || {}).length, 'teams');
            } catch (error) {
                console.warn('[LCARS] Failed to fetch team config, using fallback metadata:', error);
                // Keep existing cache or use fallback metadata
            } finally {
                this.teamConfigFetchInProgress = false;
            }
        },

        /**
         * Get persona metadata from API cache or fallback
         * @param {string} personaKey - Persona key (avatar codename like 'reno', 'picard', 'data')
         * @returns {Object|null} - {name, role, team} or null if not found
         */
        getPersonaMetadata: function(personaKey) {
            if (!personaKey) return null;

            // Try API cache first
            if (this.teamConfigCache && this.teamConfigCache.teams) {
                for (const [teamId, teamData] of Object.entries(this.teamConfigCache.teams)) {
                    if (teamData.terminals) {
                        for (const [terminalName, terminalData] of Object.entries(teamData.terminals)) {
                            // Match by avatar codename (persona key)
                            if (terminalData.avatar && terminalData.avatar.toLowerCase() === personaKey.toLowerCase()) {
                                return {
                                    name: terminalData.name || terminalName,
                                    role: terminalData.role || 'Developer',
                                    team: teamData.teamName || teamId
                                };
                            }
                        }
                    }
                }
            }

            // Fallback to hardcoded metadata (only if API data not available)
            return this.metadata[personaKey] || null;
        },

        /**
         * Create the tooltip DOM element
         */
        createTooltipElement: function() {
            const tooltip = document.createElement('div');
            tooltip.className = 'lcars-avatar-tooltip';
            tooltip.style.display = 'none';

            tooltip.innerHTML =
                '<div class="tooltip-arrow"></div>' +
                '<div class="tooltip-content">' +
                    '<div class="tooltip-name"></div>' +
                    '<div class="tooltip-divider"></div>' +
                    '<div class="tooltip-role"></div>' +
                    '<div class="tooltip-team"></div>' +
                '</div>';

            document.body.appendChild(tooltip);
            this.tooltipState.element = tooltip;
        },

        /**
         * Show tooltip for an avatar element
         * @param {HTMLElement} avatar - Avatar element with data-persona attribute
         */
        showTooltip: function(avatar) {
            if (!this.tooltipState.element) return;

            const personaKey = avatar.dataset.persona;
            if (!personaKey) return;

            // Get persona from API cache or fallback
            const persona = this.getPersonaMetadata(personaKey);
            if (!persona) {
                console.warn('[LCARS] Unknown persona:', personaKey);
                return;
            }

            this.cancelHideTooltip();

            // Update tooltip content
            const tooltip = this.tooltipState.element;
            tooltip.querySelector('.tooltip-name').textContent = persona.name;
            tooltip.querySelector('.tooltip-role').textContent = persona.role;
            tooltip.querySelector('.tooltip-team').textContent = persona.team;

            // Set team color class
            tooltip.className = 'lcars-avatar-tooltip team-' + persona.team.toLowerCase().replace(/\s+/g, '-');

            // Position tooltip
            this.positionTooltip(avatar);

            // Show with fade-in
            tooltip.style.display = 'block';
            setTimeout(function() {
                tooltip.classList.add('visible');
            }, 10);

            this.tooltipState.visible = true;
            this.tooltipState.currentPersona = personaKey;
        },

        /**
         * Show tooltip for a terminal logo element
         * @param {HTMLElement} logo - Terminal logo element with data-terminal-* attributes
         */
        showTerminalTooltip: function(logo) {
            if (!this.tooltipState.element) return;

            const terminalName = logo.dataset.terminalName;
            const division = logo.dataset.terminalDivision;
            const agent = logo.dataset.terminalAgent;

            if (!terminalName && !division) return;

            this.cancelHideTooltip();

            const tooltip = this.tooltipState.element;
            tooltip.querySelector('.tooltip-name').textContent = terminalName || 'Terminal';
            tooltip.querySelector('.tooltip-role').textContent = agent ? agent.charAt(0).toUpperCase() + agent.slice(1) + ' Terminal' : 'Terminal';
            tooltip.querySelector('.tooltip-team').textContent = division || '';

            // Set team color class based on division
            var teamClass = division ? division.toLowerCase().replace(/[\s-]+/g, '-') : 'academy';
            tooltip.className = 'lcars-avatar-tooltip team-' + teamClass;

            this.positionTooltip(logo);

            tooltip.style.display = 'block';
            setTimeout(function() {
                tooltip.classList.add('visible');
            }, 10);

            this.tooltipState.visible = true;
            this.tooltipState.currentPersona = 'terminal-' + (agent || 'unknown');
        },

        /**
         * Position tooltip relative to avatar
         * @param {HTMLElement} avatar - Avatar element
         */
        positionTooltip: function(avatar) {
            const tooltip = this.tooltipState.element;
            const rect = avatar.getBoundingClientRect();
            const tooltipRect = tooltip.getBoundingClientRect();

            const viewportHeight = window.innerHeight;
            const spaceAbove = rect.top;
            const spaceBelow = viewportHeight - rect.bottom;

            // Default: show below
            let top = rect.bottom + 8;
            let showAbove = false;

            // If not enough space below, show above
            if (spaceBelow < tooltipRect.height + 20 && spaceAbove > spaceBelow) {
                top = rect.top - tooltipRect.height - 8;
                showAbove = true;
            }

            // Center horizontally on avatar
            const avatarCenterX = rect.left + (rect.width / 2);
            let left = avatarCenterX - (tooltipRect.width / 2);

            // Keep tooltip within viewport
            const margin = 10;
            if (left < margin) {
                left = margin;
            } else if (left + tooltipRect.width > window.innerWidth - margin) {
                left = window.innerWidth - tooltipRect.width - margin;
            }

            tooltip.style.top = top + 'px';
            tooltip.style.left = left + 'px';

            // Position arrow to point at the avatar center
            const arrow = tooltip.querySelector('.tooltip-arrow');
            if (arrow) {
                const arrowLeft = avatarCenterX - left;
                // Clamp arrow within tooltip bounds (16px from edges)
                const clampedLeft = Math.max(16, Math.min(arrowLeft, tooltipRect.width - 16));
                arrow.style.left = clampedLeft + 'px';
            }

            // Update arrow direction class
            if (showAbove) {
                tooltip.classList.add('arrow-bottom');
                tooltip.classList.remove('arrow-top');
            } else {
                tooltip.classList.add('arrow-top');
                tooltip.classList.remove('arrow-bottom');
            }
        },

        /**
         * Schedule tooltip hide with delay
         */
        scheduleHideTooltip: function() {
            const self = this;
            this.tooltipState.hideTimer = setTimeout(function() {
                self.hideTooltip();
            }, 150);
        },

        /**
         * Cancel scheduled tooltip hide
         */
        cancelHideTooltip: function() {
            if (this.tooltipState.hideTimer) {
                clearTimeout(this.tooltipState.hideTimer);
                this.tooltipState.hideTimer = null;
            }
        },

        /**
         * Hide the tooltip
         */
        hideTooltip: function() {
            if (!this.tooltipState.visible) return;

            const tooltip = this.tooltipState.element;
            tooltip.classList.remove('visible');

            setTimeout(function() {
                tooltip.style.display = 'none';
            }, 200);

            this.tooltipState.visible = false;
            this.tooltipState.currentPersona = null;
        }
    };

    // =========================================================================
    // UTILITY FUNCTIONS
    // =========================================================================

    LCARS.utils = {
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
        // Available sections in order
        list: ['overview', 'organizations', 'machines', 'analytics', 'settings', 'admin'],

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
            document.querySelectorAll('.sidebar-button[data-section]').forEach(function(btn) {
                btn.addEventListener('click', function() {
                    self.switchSection(btn.dataset.section);
                });
            });

            // Bind keyboard navigation
            this.initKeyboardNav();

            console.log('[LCARS] Section navigation initialized');
        },

        /**
         * Switch to a new section
         * @param {string} sectionName - Name of section to switch to
         * @param {boolean} skipAnimation - Skip transition animation
         */
        switchSection: function(sectionName, skipAnimation) {
            const newIndex = this.list.indexOf(sectionName);
            if (newIndex === -1) return;

            const previousSection = this.active;

            // Don't switch if already on this section
            if (sectionName === previousSection) return;

            // Update state
            this.active = sectionName;
            this.activeIndex = newIndex;

            // Save to localStorage
            this.saveSection(sectionName);

            // Update sidebar buttons
            document.querySelectorAll('.sidebar-button[data-section]').forEach(function(btn) {
                btn.classList.toggle('active', btn.dataset.section === sectionName);
            });

            // Get section elements
            const newEl = document.querySelector('.lcars-section[data-section="' + sectionName + '"]');
            const oldEl = document.querySelector('.lcars-section[data-section="' + previousSection + '"]');

            if (oldEl && oldEl !== newEl) {
                if (skipAnimation) {
                    // Instant switch
                    oldEl.classList.remove('active', 'exiting');
                } else {
                    // Start exit animation - reverse cascade
                    oldEl.classList.remove('active');
                    oldEl.classList.add('exiting');

                    // Clean up exiting class after reverse cascade completes
                    // (200ms max delay + 150ms transition = 350ms)
                    setTimeout(function() {
                        oldEl.classList.remove('exiting');
                    }, 400);
                }
            }

            if (newEl) {
                // Clean up any lingering classes
                newEl.classList.remove('exiting');

                if (skipAnimation || !oldEl || oldEl === newEl) {
                    // Activate immediately
                    newEl.classList.add('active');
                } else {
                    // Delay new section slightly so exit starts first
                    setTimeout(function() {
                        newEl.classList.add('active');
                    }, 80);
                }
            }

            // Update candy colors if available
            if (LCARS.candy && LCARS.candy.changeSection) {
                LCARS.candy.changeSection(sectionName);
            }

            // Dispatch custom event for section change (allows app-specific handlers)
            document.dispatchEvent(new CustomEvent('lcars:sectionChange', {
                detail: {
                    section: sectionName,
                    previousSection: previousSection
                }
            }));

            console.log('[LCARS] Switched to section:', sectionName);
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
                    if (e.code === 'Digit5' || e.code === 'Numpad5') {
                        e.preventDefault();
                        self.switchSection(self.list[4]);
                        return;
                    }

                    // Option+R for refresh (check both e.code and e.key for compatibility)
                    if (e.code === 'KeyR' || e.key === 'r' || e.key === 'R' || e.key === '®') {
                        e.preventDefault();
                        self.refresh();
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
         * Refresh current section data
         */
        refresh: function() {
            console.log('[LCARS] Refresh triggered');

            // Trigger shimmer on data bar
            if (LCARS.candy && LCARS.candy.triggerShimmer) {
                LCARS.candy.triggerShimmer();
            }

            // Re-trigger section animations by briefly removing active class
            const activeSection = document.querySelector('.lcars-section.active');
            if (activeSection) {
                // Add refreshing class to reset animations
                activeSection.classList.add('refreshing');
                activeSection.classList.remove('active');

                // Force reflow
                void activeSection.offsetWidth;

                // Re-add active class after brief delay to trigger cascade
                setTimeout(function() {
                    activeSection.classList.remove('refreshing');
                    activeSection.classList.add('active');
                }, 50);
            }

            // Dispatch custom event for app to handle
            const event = new CustomEvent('lcars:refresh', {
                detail: { section: this.active }
            });
            document.dispatchEvent(event);

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

            // Clear container and append image directly (prevents duplicates)
            const img = document.createElement('img');
            img.alt = 'Fleet Monitor';

            img.onerror = function() {
                logoContainer.innerHTML = '<div class="startup-logo-fallback">⟐</div>';
            };

            logoContainer.innerHTML = '';
            logoContainer.appendChild(img);
            img.src = '/avatars/fleet_logo.png';
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

            // Initialize persona avatar tooltips
            if (options.personas !== false) {
                LCARS.personas.init();
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

    // =========================================================================
    // BACKUP DISPLAY NAME FORMATTING
    // =========================================================================

    /**
     * Format a board name for compact backup status display.
     * Shortens long names to prevent overflow in the inline status row.
     *
     * Examples:
     *   "academy"                         -> "ACADEMY"
     *   "ios"                             -> "IOS"
     *   "freelance"                       -> "FREELANCE"
     *   "freelance-doublenode-starwords"   -> "FL-STARWORDS"
     *   "freelance-doublenode-appplanning" -> "FL-APPPLANNING"
     *   "freelance-doublenode-workstats"   -> "FL-WORKSTATS"
     *   "freelance-appplanning"           -> "FL-APPPLANNING"
     *   "legal-coparenting"               -> "LEGAL-COPARENTING"
     */
    LCARS.formatBackupDisplayName = function(boardName) {
        var name = boardName.toUpperCase();
        // Shorten "FREELANCE-DOUBLENODE-X" to "FL-X"
        name = name.replace(/^FREELANCE-DOUBLENODE-/, 'FL-');
        // Shorten "FREELANCE-X" to "FL-X"
        name = name.replace(/^FREELANCE-/, 'FL-');
        return name;
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
