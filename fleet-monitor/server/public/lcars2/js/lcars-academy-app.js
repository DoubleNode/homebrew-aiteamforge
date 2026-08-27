//
//  lcars-academy-app.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * LCARS Academy Dashboard Application
 * Filtered view showing only Academy division
 *
 * Divisions: academy
 */

(function() {
    'use strict';

    // ============================================================================
    // CONFIGURATION
    // ============================================================================

    const CONFIG = {
        apiBase: window.location.origin,
        refreshInterval: 60000,
        stardateOffset: 41000,
        divisions: ['academy'],
        dashboardName: 'ACADEMY',
        emptyMessage: 'No active Academy sessions detected'
    };

    const LCARS_PORT = 8080;

    // ============================================================================
    // STATE
    // ============================================================================

    let fleetData = null;
    let refreshTimer = null;

    // ============================================================================
    // INITIALIZATION
    // ============================================================================

    document.addEventListener('DOMContentLoaded', function() {
        console.log('[LCARS] Academy Dashboard initializing...');

        // Initialize LCARS core
        if (window.LCARS_CORE) {
            LCARS_CORE.init({
                candyOptions: { section: 'overview' }
            });
        }

        // Initialize Kiosk Mode (auto-rotation on idle)
        if (window.LCARS_KIOSK) {
            LCARS_KIOSK.init();
        }

        // XACA-0989: Expand All / Collapse All control for the divisions
        // section -- wired once; #divisions-container's re-renders don't
        // touch it.
        if (window.LCARS_DIVISIONS) {
            const divisionsContainer = document.getElementById('divisions-container');
            const sectionHeader = divisionsContainer && divisionsContainer.previousElementSibling;
            if (sectionHeader) {
                window.LCARS_DIVISIONS.wireExpandCollapseAll(sectionHeader);
            }
        }

        // Initial data fetch
        fetchFleetData();

        // Set up auto-refresh
        refreshTimer = setInterval(fetchFleetData, CONFIG.refreshInterval);

        // Update stardate
        updateStardate();
        setInterval(updateStardate, 1000);

        console.log('[LCARS] Academy Dashboard initialized');
    });

    // ============================================================================
    // DATA FETCHING
    // ============================================================================

    async function fetchFleetData() {
        try {
            const response = await fetch(CONFIG.apiBase + '/api/fleet');
            if (!response.ok) {
                throw new Error('HTTP ' + response.status + ': ' + response.statusText);
            }
            fleetData = await response.json();
            const filteredData = filterData(fleetData);
            renderDashboard(filteredData);
            updateConnectionStatus(true);
        } catch (error) {
            console.error('[LCARS] Failed to fetch fleet data:', error);
            updateConnectionStatus(false);
        }
    }

    function filterData(data) {
        if (!data || !data.fleet) return data;

        const fleet = data.fleet;
        const filteredDivisions = {};
        let filteredTotalSessions = 0;

        for (const divisionName in fleet.divisions || {}) {
            if (CONFIG.divisions.includes(divisionName.toLowerCase())) {
                filteredDivisions[divisionName] = fleet.divisions[divisionName];
                filteredTotalSessions += fleet.divisions[divisionName].total_sessions || 0;
            }
        }

        const filteredMachines = (fleet.machines || []).map(function(machine) {
            const filteredSessions = (machine.sessions || []).filter(function(session) {
                return CONFIG.divisions.includes((session.division || '').toLowerCase());
            });
            return Object.assign({}, machine, {
                sessions: filteredSessions,
                session_count: filteredSessions.length
            });
        }).filter(function(machine) {
            return machine.session_count > 0;
        });

        const onlineMachines = filteredMachines.filter(function(m) { return m.status === 'online'; }).length;
        const offlineMachines = filteredMachines.filter(function(m) { return m.status === 'offline'; }).length;

        return {
            fleet: {
                total_machines: filteredMachines.length,
                online_machines: onlineMachines,
                offline_machines: offlineMachines,
                total_sessions: filteredTotalSessions,
                divisions: filteredDivisions,
                machines: filteredMachines
            },
            last_update: data.last_update
        };
    }

    // ============================================================================
    // RENDERING
    // ============================================================================

    function renderDashboard(data) {
        if (!data || !data.fleet) {
            console.warn('[LCARS] No fleet data to render');
            return;
        }

        const fleet = data.fleet;
        const lastUpdate = data.last_update;

        // Update summary cards
        updateElement('total-machines', fleet.total_machines || 0);
        updateElement('online-machines', fleet.online_machines || 0);
        updateElement('offline-machines', fleet.offline_machines || 0);
        updateElement('total-sessions', fleet.total_sessions || 0);
        updateElement('last-update', formatTimestamp(lastUpdate));

        // Update LCARS candy pills
        if (window.LCARS_CORE && LCARS_CORE.candy) {
            LCARS_CORE.candy.updateData({
                totalMachines: fleet.total_machines || 0,
                onlineMachines: fleet.online_machines || 0,
                offlineMachines: fleet.offline_machines || 0,
                totalSessions: fleet.total_sessions || 0
            });
        }

        // Render divisions
        renderDivisions(fleet.divisions);

        // Render machines
        renderMachines(fleet.machines);
    }

    function renderOrganizationNav(sortedOrgs, organizationGroups) {
        const navContainer = document.getElementById('organization-nav');
        if (!navContainer) return;

        navContainer.innerHTML = '';

        sortedOrgs.forEach(function(orgName) {
            const divisionCount = organizationGroups[orgName].length;
            const totalSessions = organizationGroups[orgName].reduce(function(sum, item) {
                return sum + item[1].total_sessions;
            }, 0);

            const navButton = document.createElement('button');
            navButton.className = 'org-nav-button ' + getGroupColor(orgName);
            // textContent, not innerHTML: orgName arrives from the `organization`
            // field of /api/team-register's body, validated for presence only, so
            // innerHTML made this an injection sink for any API-key holder.
            // (XACA-0970, review gate.)
            const navName = document.createElement('span');
            navName.className = 'org-nav-name';
            navName.textContent = orgName;
            navButton.appendChild(navName);

            const navStats = document.createElement('span');
            navStats.className = 'org-nav-stats';
            navStats.textContent = divisionCount + ' Divisions • ' + totalSessions + ' Sessions';
            navButton.appendChild(navStats);

            navButton.onclick = function() {
                const targetId = 'org-' + orgName.toLowerCase().replace(/\s+/g, '-');
                const targetElement = document.getElementById(targetId);
                if (targetElement) {
                    targetElement.scrollIntoView({ behavior: 'smooth', block: 'start' });
                }
            };

            navContainer.appendChild(navButton);
        });
    }

    function renderDivisions(divisions) {
        const container = document.getElementById('divisions-container');
        // XACA-0989-019: beginRenderPass()/endRenderPass() must bracket the
        // ENTIRE render pass, including this early "no container" exit --
        // not just the body below it. Before this fix, a missing container
        // returned before beginRenderPass() ever ran, so the PREVIOUS pass's
        // controllers array was left in place, still registered against
        // whatever nodes it pointed at (now potentially detached, since a
        // container going missing usually means the DOM around it changed).
        // A later notifyStateChange() (e.g. from a toggle click elsewhere)
        // would then call applyState() against those stale controllers.
        if (window.LCARS_DIVISIONS) window.LCARS_DIVISIONS.beginRenderPass();
        if (!container) {
            if (window.LCARS_DIVISIONS) window.LCARS_DIVISIONS.endRenderPass();
            return;
        }

        container.innerHTML = '';

        if (!divisions || Object.keys(divisions).length === 0) {
            container.innerHTML = '<p class="empty-message">' + CONFIG.emptyMessage + '</p>';
            if (window.LCARS_DIVISIONS) window.LCARS_DIVISIONS.endRenderPass();
            return;
        }

        // Group divisions by organization
        const organizationGroups = {};

        for (const divisionName in divisions) {
            const orgGroup = getOrganizationGroup(divisionName);
            if (!organizationGroups[orgGroup]) {
                organizationGroups[orgGroup] = [];
            }
            organizationGroups[orgGroup].push([divisionName, divisions[divisionName]]);
        }

        const sortedOrgs = Object.keys(organizationGroups).sort();
        renderOrganizationNav(sortedOrgs, organizationGroups);

        sortedOrgs.forEach(function(orgName) {
            const orgContainer = document.createElement('div');
            orgContainer.className = 'organization-panel ' + getGroupColor(orgName);
            orgContainer.id = 'org-' + orgName.toLowerCase().replace(/\s+/g, '-');

            const totalSessions = organizationGroups[orgName].reduce(function(sum, item) {
                return sum + item[1].total_sessions;
            }, 0);

            const orgHeader = document.createElement('div');
            orgHeader.className = 'organization-header';
            // textContent, not innerHTML -- same untrusted `organization` field as the
            // nav button above. (XACA-0970, review gate.)
            const orgTitle = document.createElement('span');
            orgTitle.className = 'organization-title';
            orgTitle.textContent = orgName;
            orgHeader.appendChild(orgTitle);

            const orgCount = document.createElement('span');
            orgCount.className = 'organization-count';
            orgCount.textContent = totalSessions + ' Sessions';
            orgHeader.appendChild(orgCount);
            // XACA-0970-012: the UNKNOWN heading carries its own remediation.
            // All of the policy lives in the shared module -- see decorateHeading().
            if (window.LCARS_ORG && window.LCARS_ORG.decorateHeading) {
                window.LCARS_ORG.decorateHeading(orgHeader, orgName);
            }
            orgContainer.appendChild(orgHeader);

            // Sort divisions by priority
            const sortedDivisions = organizationGroups[orgName].sort(function(a, b) {
                const priorityA = getDivisionPriority(a[0]);
                const priorityB = getDivisionPriority(b[0]);
                if (priorityA !== priorityB) return priorityA - priorityB;
                return getDivisionTitle(a[0]).localeCompare(getDivisionTitle(b[0]));
            });

            sortedDivisions.forEach(function(item) {
                const divisionPanel = createDivisionPanel(item[0], item[1]);
                orgContainer.appendChild(divisionPanel);
            });

            container.appendChild(orgContainer);
        });

        // XACA-0989: refresh the Expand All / Collapse All label now that
        // this pass's division set (and each panel's initial paint) is final.
        if (window.LCARS_DIVISIONS) window.LCARS_DIVISIONS.endRenderPass();
    }

    function createDivisionPanel(name, data) {
        const panel = document.createElement('div');
        panel.className = 'division-container';
        panel.id = 'div-' + name.toLowerCase().replace(/\s+/g, '-');

        const header = document.createElement('div');
        header.className = 'division-header';
        // XACA-0989: '.division-toggle-icon' is filled in by
        // LCARS_DIVISIONS.wireDivisionToggle() below -- empty here.
        header.innerHTML = getDivisionTitle(name) +
            '<span class="division-stats">' + data.total_sessions + ' Sessions' +
            '<span class="division-toggle-icon" aria-hidden="true"></span></span>';
        panel.appendChild(header);

        const content = document.createElement('div');
        content.className = 'teams-grid';

        // XACA-0989: collected alongside the (unchanged) expanded cards so
        // the collapsed chip view never has to re-walk data.projects.
        const chipEntries = [];

        for (const projectKey in data.projects) {
            const projectData = data.projects[projectKey];
            // Sort teams with LCARS terminals first
            const teamNames = Object.keys(projectData.teams).sort(function(a, b) {
                const aIsLcars = isLcarsTerminal(projectData.teams[a]);
                const bIsLcars = isLcarsTerminal(projectData.teams[b]);
                if (aIsLcars && !bIsLcars) return -1;
                if (!aIsLcars && bIsLcars) return 1;
                return a.localeCompare(b);
            });
            teamNames.forEach(function(teamName) {
                const teamCard = createTeamCard(teamName, projectData.teams[teamName]);
                content.appendChild(teamCard);
                chipEntries.push([teamName, projectData.teams[teamName]]);
            });
        }

        panel.appendChild(content);

        // XACA-0989: collapsed-by-default chip view, single shared renderer
        // (shared/js/lcars-division-collapse.js). Fails safe to the
        // pre-XACA-0989 always-expanded behavior if the module didn't load.
        if (window.LCARS_DIVISIONS) {
            const chipRow = window.LCARS_DIVISIONS.buildChipRow(chipEntries, {
                isLcarsTerminal: isLcarsTerminal,
                getLcarsUrl: getLcarsUrl
            });
            panel.insertBefore(chipRow, content);
            window.LCARS_DIVISIONS.wireDivisionToggle(panel, header, chipRow, content);
        }

        return panel;
    }

    function escapeHtml(text) {
        if (!text) return '';
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    // XACA-0983 fix (b), third render state: a team can be a KNOWN LCARS
    // service (data.lcars_service, from server.js's parseFleetData -- see
    // fleet-reporter.sh's get_lcars_services()) with NO live tmux session.
    // Before this, createTeamCard returned an EMPTY card for every
    // session-less team, so a genuinely-down (or simply session-less-but-
    // healthy) LCARS terminal rendered identically to "not an LCARS
    // terminal at all" -- the same silent-absence bug this ticket exists to
    // fix, just moved one layer up. This function is called ONLY when
    // isLcarsTerminal(data) is true AND there is no session, so a team that
    // was never an LCARS terminal is unaffected and still gets the original
    // empty card below.
    // XACA-0990: extracted to shared/js/lcars-terminal-card.js. This shim
    // preserves the local call site verbatim; escapeHtml (still defined in
    // this file, it has other callers) is injected as the module has no
    // access to this scope.
    function createServiceOnlyLcarsCard(name, svc) {
        return LCARS_TERMINAL_CARD.createServiceOnlyLcarsCard(name, svc, escapeHtml);
    }

    function createTeamCard(name, data) {
        const card = document.createElement('div');
        const isLcars = isLcarsTerminal(data);
        card.className = isLcars ? 'team-card lcars-terminal' : 'team-card';

        const session = data.sessions && data.sessions[0];
        if (!session) {
            if (isLcars && data.lcars_service) {
                return createServiceOnlyLcarsCard(name, data.lcars_service);
            }
            return card;
        }

        const status = session.machine_status || 'offline';
        const isOnline = status === 'online';

        // XACA-0983-015 scope note: name/session.name/session.hostname
        // below are interpolated unescaped, same as before this ticket.
        // That is pre-existing debt already tracked and scoped for a
        // shared fix under XACA-0416 (todo, high) -- not addressed here
        // to avoid colliding with that ticket's broader sweep across
        // these same 5 files. Only the NEW createServiceOnlyLcarsCard
        // code above got escapeHtml() as part of this ticket.
        card.innerHTML =
            '<div class="team-header">' +
                '<div class="team-name">' + name + (isLcars ? '<span class="lcars-badge">LCARS</span>' : '') + '</div>' +
                '<span class="status-indicator ' + status + '"></span>' +
            '</div>' +
            '<div class="session-info">' +
                '<div class="session-detail"><span class="session-label">Session:</span><span class="session-value">' + session.name + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Machine:</span><span class="session-value">' + session.hostname + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Windows:</span><span class="session-value">' + session.windows + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Uptime:</span><span class="session-value">' + session.uptime_display + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Status:</span><span class="session-value text-' + status + '">' + status.toUpperCase() + '</span></div>' +
            '</div>';

        // Apply theme color to non-LCARS cards
        if (session.theme_color && !isLcars) {
            card.style.borderLeft = '4px solid ' + session.theme_color;
            var teamNameEl = card.querySelector('.team-name');
            if (teamNameEl) {
                teamNameEl.style.cssText = 'color: ' + session.theme_color + ' !important;';
            }
        }

        if (isLcars) {
            const lcarsUrl = getLcarsUrl(data);
            if (lcarsUrl && isOnline) {
                card.classList.add('lcars-clickable');
                card.title = 'Click to open LCARS terminal: ' + lcarsUrl;
                // XACA-0983-014: same keyboard-activation support as the
                // service-only card above -- see createServiceOnlyLcarsCard.
                card.setAttribute('tabindex', '0');
                card.setAttribute('role', 'button');
                card.addEventListener('click', function() {
                    window.open(lcarsUrl, '_blank');
                });
                card.addEventListener('keydown', function(evt) {
                    if (evt.key === 'Enter' || evt.key === ' ' || evt.key === 'Spacebar' || evt.keyCode === 13 || evt.keyCode === 32) {
                        evt.preventDefault();
                        window.open(lcarsUrl, '_blank');
                    }
                });
            } else if (lcarsUrl && !isOnline) {
                // XACA-0979: match the flat dashboards' offline treatment so one
                // team's card behaves identically in every dashboard view.
                card.classList.add('lcars-offline');
                card.title = 'LCARS terminal unavailable - machine is ' + status;
            } else {
                // XACA-0979: no hostname reported for this session - never leave
                // the card looking actionable without saying why.
                card.classList.add('lcars-offline');
                card.title = 'LCARS terminal misconfigured - no hostname reported for this session';
            }
        }

        return card;
    }

    function renderMachines(machines) {
        const container = document.getElementById('machines-list');
        if (!container) return;

        container.innerHTML = '';

        if (!machines || machines.length === 0) {
            container.innerHTML = '<p class="empty-message">No machines detected</p>';
            return;
        }

        const sortedMachines = machines.sort(function(a, b) {
            if (a.status !== b.status) {
                return a.status === 'online' ? -1 : 1;
            }
            return a.hostname.localeCompare(b.hostname);
        });

        sortedMachines.forEach(function(machine) {
            const item = createMachineItem(machine);
            container.appendChild(item);
        });
    }

    function createMachineItem(machine) {
        const item = document.createElement('div');
        item.className = 'status-row ' + machine.status;

        item.innerHTML =
            '<span class="status-indicator ' + machine.status + '"></span>' +
            '<span class="lcars-text-sm" style="flex: 1;">' + machine.hostname + '</span>' +
            '<span class="lcars-text-xs" style="color: var(--lcars-tan);">' + machine.session_count + ' sessions</span>';

        return item;
    }

    // ============================================================================
    // DIVISION MAPPINGS
    // ============================================================================

    function getDivisionTitle(divisionCode) {
        const code = divisionCode.toLowerCase();
        const titles = {
            'academy': 'STARFLEET ACADEMY',
            'android': 'ANDROID - STAR TREK: TOS',
            'command': 'STARFLEET COMMAND',
            'dns': 'DNS FRAMEWORK - STAR TREK: LOWER DECKS',
            'firebase': 'FIREBASE - STAR TREK: DS9',
            'freelance': 'FREELANCE - STAR TREK: ENT',
            'ios': 'IOS - STAR TREK: TNG',
            'legal': 'COPARENTING',
            'legal-coparenting': 'COPARENTING'
        };
        // Fallback for any legal-* variant
        if (!titles[code] && code.startsWith('legal')) {
            const suffix = code.replace('legal-', '').toUpperCase();
            return suffix || 'LEGAL';
        }
        return titles[code] || code.toUpperCase();
    }

    function getOrganizationGroup(divisionCode) {
        // Delegates to THE single implementation (XACA-0970):
        //   shared/js/lcars-org-resolution.js
        //
        // Do NOT reintroduce a local copy. This function previously existed in
        // FOURTEEN files across multiple variants -- and the only copy that handled
        // `finance` lived in a file no page loaded, so the bug looked fixed and
        // never ran. Add teams in the shared module, nowhere else.
        if (!window.LCARS_ORG) {
            // Loud on purpose: a missing module must not masquerade as a team
            // with no organization, which is the exact silent failure this
            // ticket exists to remove. Check script order in the page.
            console.error('[LCARS][org] shared/js/lcars-org-resolution.js is not '
                + 'loaded -- it must appear BEFORE this script. Falling back to UNKNOWN.');
            return 'UNKNOWN';
        }
        var cfg = (typeof teamConfig !== 'undefined') ? teamConfig : null;
        return window.LCARS_ORG.resolve(divisionCode, cfg);
    }

    function getGroupColor(group) {
        // Delegates to the shared module (XACA-0970), same as
        // getOrganizationGroup above. FINANCE was missing from every one of
        // the 14 copies of this map, so the org this ticket exists to surface
        // would have rendered with a fallback colour instead of its own.
        if (!window.LCARS_ORG) {
            console.error('[LCARS][org] shared/js/lcars-org-resolution.js is not '
                + 'loaded -- it must appear BEFORE this script.');
            return 'org-academy';
        }
        return window.LCARS_ORG.resolveColor(group);
    }

    function getDivisionPriority(divisionCode) {
        const priorities = {
            'command': 1,
            'android': 2,
            'firebase': 3,
            'ios': 4,
            'academy': 100,
            'dns': 100,
            'freelance': 100,
            'legal': 100,
            'legal-coparenting': 100
        };
        return priorities[divisionCode.toLowerCase()] || 100;
    }

    // ============================================================================
    // UTILITY FUNCTIONS
    // ============================================================================

    // XACA-0990: extracted to shared/js/lcars-terminal-card.js. This shim
    // preserves the local call site verbatim. Unlike createServiceOnlyLcarsCard
    // below, isLcarsTerminal takes no injected dependencies -- it has no
    // escapeHtml (or any other) callback to thread through.
    function isLcarsTerminal(teamData) {
        return LCARS_TERMINAL_CARD.isLcarsTerminal(teamData);
    }

    function getLcarsUrl(teamData) {
        if (!teamData) {
            return null;
        }

        const lcarsSession = teamData.sessions && teamData.sessions.find(function(session) {
            return session.name && session.name.toLowerCase().includes('lcars');
        });

        if (lcarsSession) {
            const localPort = lcarsSession.lcars_port || LCARS_PORT;

            if (!lcarsSession.hostname) {
                console.warn('No hostname reported for LCARS session on port ' + localPort);
                return null;
            }

            return 'http://' + lcarsSession.hostname + ':' + localPort;
        }

        // No session -- fall back to the reported service record directly
        // (XACA-0983 fix (b)).
        if (teamData.lcars_service && teamData.lcars_service.hostname) {
            return 'http://' + teamData.lcars_service.hostname + ':' + teamData.lcars_service.port;
        }

        return null;
    }

    function updateElement(id, value) {
        const el = document.getElementById(id);
        if (el) el.textContent = value;
    }

    function updateStardate() {
        const now = new Date();
        const year = now.getFullYear();
        const start = new Date(year, 0, 0);
        const diff = now - start;
        const oneDay = 1000 * 60 * 60 * 24;
        const dayOfYear = Math.floor(diff / oneDay);

        const stardate = CONFIG.stardateOffset + (year - 2024) * 1000 + (dayOfYear / 365 * 1000);
        updateElement('stardate', stardate.toFixed(1));
    }

    function formatTimestamp(timestamp) {
        if (!timestamp) return '--:--:--';

        const date = new Date(timestamp);
        const hours = String(date.getHours()).padStart(2, '0');
        const minutes = String(date.getMinutes()).padStart(2, '0');
        const seconds = String(date.getSeconds()).padStart(2, '0');

        return hours + ':' + minutes + ':' + seconds;
    }

    function updateConnectionStatus(connected) {
        const statusText = document.getElementById('connection-status');
        const statusIndicator = document.getElementById('connection-indicator');

        if (connected) {
            if (statusText) statusText.textContent = 'MONITORING ACTIVE';
            if (statusIndicator) statusIndicator.className = 'status-indicator online';
        } else {
            if (statusText) statusText.textContent = 'CONNECTION LOST';
            if (statusIndicator) statusIndicator.className = 'status-indicator offline';
        }
    }

    // ============================================================================
    // CLEANUP
    // ============================================================================

    window.addEventListener('beforeunload', function() {
        if (refreshTimer) {
            clearInterval(refreshTimer);
        }
    });

})();
