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
    let expandedSystemMachineId = null;  // XACA-1092-005: DOM identity for the SYSTEM disclosure toggle -- string, not an element ref, so expand state survives renderMachines() rebuilding the list every refresh tick (mirrors v1's expandedBackupMachineId).

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
        // XACA-0416-004: getDivisionTitle() falls through to `code.toUpperCase()`
        // for ANY unrecognised division code, and `division` is copied verbatim
        // from the reporter's POSTed session payload (server.js parseFleetData ->
        // resolveDivisionKey), so an unknown code arrives here as attacker-
        // influenced text. Element content -> escapeHtml. data.total_sessions is a
        // server-side integer counter, never interpolated input -> unwrapped.
        header.innerHTML = escapeHtml(getDivisionTitle(name)) +
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
            // XACA-1002-014: LCARS terminals first, then live before
            // idle-registered, then alphabetical. Extracted to the shared
            // module -- this comparator was previously inline in all five
            // app files, the copy-paste shape that module exists to prevent.
            const teamNames = Object.keys(projectData.teams).sort(
                LCARS_TERMINAL_CARD.createTeamNameComparator(projectData.teams)
            );
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

    // XACA-0416 (UX/Test finding): session.theme_color is a CSS context, not an
    // HTML one -- the same class safeCssIdent() exists for, but a colour is not
    // an identifier, so it needs its own allowlist rather than that one.
    //
    // server.js stores theme_color VERBATIM from the reporter's POST (the
    // endpoint validates presence, not shape) and it was assigned straight into
    // `teamNameEl.style.cssText`. cssText REPLACES the whole declaration block,
    // so a value like `red; position:fixed; font-size:900px; z-index:9999` is a
    // genuine style injection on every operator's dashboard, not a cosmetic
    // glitch. No HTML escaper closes it: `;` and `:` are not HTML-special, so
    // escapeAttr() hands that payload back byte-for-byte intact.
    //
    // ACCEPTED: #RGB, #RGBA, #RRGGBB, #RRGGBBAA, plus a conservative set of CSS
    // named colours. Every theme file the fleet actually ships is #RRGGBB
    // (fleet-reporter.sh's get_theme_color() cats lcars-ports/<session>.theme),
    // so the hex branch covers production and the named set is slack for a
    // hand-edited file. rgb()/rgba() are deliberately NOT accepted: admitting
    // them means validating three or four numeric components and their
    // separators, and nothing in the fleet emits them, so that parser would be
    // untested surface bought for no caller.
    //
    // REJECTION TAKES THE NO-THEME PATH: it returns '' and the caller skips the
    // whole styling block, which is byte-identical to what already happens when
    // theme_color is absent. It does not substitute a colour of its own.
    var CSS_NAMED_COLORS = {
        aqua: 1, black: 1, blue: 1, cyan: 1, fuchsia: 1, gold: 1, gray: 1,
        green: 1, grey: 1, indigo: 1, lavender: 1, lime: 1, magenta: 1,
        maroon: 1, navy: 1, olive: 1, orange: 1, orchid: 1, pink: 1, purple: 1,
        red: 1, salmon: 1, silver: 1, tan: 1, teal: 1, tomato: 1, turquoise: 1,
        violet: 1, white: 1, yellow: 1
    };

    var _warnedCssColors = Object.create(null);

    function safeCssColor(value) {
        var s = (value === null || value === undefined) ? '' : String(value).trim();
        if (/^#(?:[0-9A-Fa-f]{8}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{4}|[0-9A-Fa-f]{3})$/.test(s)) {
            return s;
        }
        if (Object.prototype.hasOwnProperty.call(CSS_NAMED_COLORS, s.toLowerCase())) {
            return s;
        }
        // XACA-0416-025 (PR #784 UX gate): rejecting SILENTLY makes a mistyped or
        // unsupported theme indistinguishable from no theme at all -- the card
        // simply renders unstyled and nobody learns why. Warn once per distinct
        // value (not per render: createTeamCard runs on every poll, so an
        // unthrottled warn would flood the console). Measured zero live impact
        // today -- all 86 shipped .theme files are 6-digit hex -- so this is
        // diagnosability for hand-edited values, not a live fix.
        if (s && !_warnedCssColors[s]) {
            _warnedCssColors[s] = true;
            if (typeof console !== 'undefined' && console.warn) {
                console.warn('[LCARS] theme_color rejected, rendering untinted: ' + s +
                    ' (accepted: #RGB/#RGBA/#RRGGBB/#RRGGBBAA or a supported colour name)');
            }
        }
        return '';
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

    // XACA-1002: a team can be REGISTERED (present in the team registry /
    // port map) with no live session and no lcars_service -- server.js's
    // parseFleetData synthesizes a session-less "idle" bucket for it
    // (data.idle_registered). This shim preserves the local call site
    // pattern established by createServiceOnlyLcarsCard above; escapeHtml
    // (still defined in this file, it has other callers) is injected as
    // the module has no access to this scope.
    function createIdleTeamCard(name, idle) {
        return LCARS_TERMINAL_CARD.createIdleTeamCard(name, idle, escapeHtml);
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
            // XACA-1002: gate on the idle_registered marker specifically --
            // never call the idle renderer unconditionally, or a genuinely
            // malformed bucket (no sessions, no lcars_service, no marker)
            // would render a misleading "idle" card instead of the original
            // empty fallback below.
            if (data.idle_registered) {
                return createIdleTeamCard(name, data.idle_registered);
            }
            return card;
        }

        const status = session.machine_status || 'offline';
        const isOnline = status === 'online';

        card.innerHTML =
            '<div class="team-header">' +
                '<div class="team-name">' + escapeHtml(name) + (isLcars ? '<span class="lcars-badge">LCARS</span>' : '') + '</div>' +
                '<span class="status-indicator ' + status + '"></span>' +
            '</div>' +
            '<div class="session-info">' +
                '<div class="session-detail"><span class="session-label">Session:</span><span class="session-value">' + escapeHtml(session.name) + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Machine:</span><span class="session-value">' + escapeHtml(session.hostname) + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Windows:</span><span class="session-value">' + escapeHtml(session.windows == null ? '' : String(session.windows)) + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Uptime:</span><span class="session-value">' + escapeHtml(session.uptime_display) + '</span></div>' +
                '<div class="session-detail"><span class="session-label">Status:</span><span class="session-value text-' + status + '">' + status.toUpperCase() + '</span></div>' +
            '</div>';

        // Apply theme color to non-LCARS cards
        // XACA-0416: validate BEFORE either style sink, and gate the whole block
        // on the VALIDATED value -- an unrecognised theme_color renders exactly
        // like no theme_color at all.
        var themeColor = safeCssColor(session.theme_color);
        if (themeColor && !isLcars) {
            card.style.borderLeft = '4px solid ' + themeColor;
            var teamNameEl = card.querySelector('.team-name');
            if (teamNameEl) {
                // Single-property write instead of cssText: cssText replaces the
                // ENTIRE declaration block, and setProperty is the narrower sink.
                // Behaviour-preserving here -- teamNameEl is built fresh from this
                // card's innerHTML and carries no other inline declaration -- and
                // setProperty keeps the `!important` that a plain
                // `style.color = ...` assignment cannot express.
                teamNameEl.style.setProperty('color', themeColor, 'important');
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

    // ============================================================================
    // XACA-1092-004/-005: MACHINE SYSTEM TELEMETRY -- adapter, formatting,
    // badge/version-line/system-panel builders, and the SYSTEM disclosure
    // toggle. See fleet-monitor/server/public/lcars2/js/lcars-machine-health.js
    // (XACA-1092-003, do not modify) for the health-state derivation this
    // code wires up, and kanban/plans/XACA-1091/CONTRACT-system-block.md for
    // the frozen wire shape this adapter decouples from.
    //
    // Per XACA-1091-016 Design Decision 6 ("superseded in part"), no shared
    // helper is extracted across the 5 createMachineItem copies -- this
    // block is duplicated identically in all 4 lcars2 app files (byte-for-
    // byte) and adapted (different group/toggle class names, no data-*
    // string interpolation -- see below) in lcars-dashboard-app.js (v1).
    // ============================================================================

    const SYSTEM_BYTES_PER_GB = 1024 * 1024 * 1024;

    // Wire adapter (XACA-1092-005): maps the frozen system{} contract onto
    // the normalized primitives deriveMachineHealth() expects. ALL wire-
    // format coupling lives here -- if the contract is revised, this is the
    // one place in this file that needs to change.
    //
    // Guards on the LEAF, never the container ('percent' in disk, not
    // `if (system.disk)`) -- system{}/disk{}/memory{}/versions{} all ship
    // as `{}` (truthy) rather than omitted when unresolvable (contract §3),
    // so a container-level truthiness check would treat every unresolved
    // machine as having real data. See XACA-1092-002 ADDENDUM.
    function machineSystemToHealthInput(system) {
        const sys = system || {};
        const disk = sys.disk || {};
        return {
            diskPercentUsed: ('percent' in disk) ? disk.percent : undefined,
            swapUsedBytes: ('swap_used_bytes' in sys) ? sys.swap_used_bytes : undefined,
            loadAvg1: (Array.isArray(sys.load_average) && sys.load_average.length > 0) ? sys.load_average[0] : undefined,
            coreCount: ('cores' in sys) ? sys.cores : undefined
        };
    }

    // Byte formatter -- a COLLECTED ZERO IS DATA (contract §3): renders as
    // the plain, non-italic "0 B", never "0.0 GB". Any non-finite-number
    // input (missing, null, or a hostile non-numeric value -- see the
    // HostileDefensive fixture case) returns null so the caller can render
    // the same "not reported" treatment absence gets, rather than a literal
    // "NaN GB" ever reaching the DOM. One decimal of precision (UX spec
    // §3): a rounded/lossy figure is what hid the real state in the
    // swap-percentage postmortem this spec cites.
    function formatSystemBytes(value) {
        if (typeof value !== 'number' || !isFinite(value)) {
            return null;
        }
        if (value === 0) {
            return '0 B';
        }
        return (value / SYSTEM_BYTES_PER_GB).toFixed(1) + ' GB';
    }

    function systemRowValue(label, valueHtml) {
        return '<div class="machine-system-row"><span class="machine-system-row-label">' + label + '</span>' +
            '<span class="machine-system-row-value">' + valueHtml + '</span></div>';
    }

    // UX spec §5: an omitted/unreportable leaf renders as a full muted word,
    // never a bare dash -- "a lone dash on a small row, sitting next to
    // numerals, is exactly the kind of subtle mark ... misread as part of a
    // number at a glance."
    function systemRowAbsent(label) {
        return '<div class="machine-system-row"><span class="machine-system-row-label">' + label + '</span>' +
            '<span class="machine-system-row-value machine-system-row-value-empty">not reported</span></div>';
    }

    function systemGroupHasAny(obj, keys) {
        const source = obj || {};
        for (let i = 0; i < keys.length; i++) {
            if (keys[i] in source) {
                return true;
            }
        }
        return false;
    }

    // PLATFORM group -- os_name/os_version/os_build combine into one OS row
    // per UX spec §3's worked example ("OS  macOS 27.0 (26A5388g)").
    // Reporter-supplied strings -> escapeHtml (element content), matching
    // this file's existing XACA-0416-004 convention for machine.hostname.
    function buildSystemOsRow(system) {
        const hasName = 'os_name' in system;
        const hasVersion = 'os_version' in system;
        const hasBuild = 'os_build' in system;
        if (!hasName && !hasVersion && !hasBuild) {
            return systemRowAbsent('OS');
        }
        let text = hasName ? escapeHtml(String(system.os_name)) : 'Unknown';
        if (hasVersion) {
            text += ' ' + escapeHtml(String(system.os_version));
        }
        if (hasBuild) {
            text += ' (' + escapeHtml(String(system.os_build)) + ')';
        }
        return systemRowValue('OS', text);
    }

    function buildPlatformGroupHtml(system) {
        if (!systemGroupHasAny(system, ['os_name', 'os_version', 'os_build', 'model', 'arch', 'cores'])) {
            return '';
        }
        let rows = buildSystemOsRow(system);
        rows += ('model' in system) ? systemRowValue('MODEL', escapeHtml(String(system.model))) : systemRowAbsent('MODEL');
        rows += ('arch' in system) ? systemRowValue('ARCH', escapeHtml(String(system.arch))) : systemRowAbsent('ARCH');
        rows += ('cores' in system) ? systemRowValue('CORES', escapeHtml(String(system.cores))) : systemRowAbsent('CORES');
        return '<div class="status-row-system-group"><div class="machine-system-group-label">PLATFORM</div>' + rows + '</div>';
    }

    // MEMORY & SWAP group. memory.used/total combine into one MEMORY row;
    // swap_used_bytes (sibling of `memory`, NOT nested in it -- contract §1)
    // is its own row. NEVER a percentage -- see lcars-machine-health.js
    // module header ("DISK vs SWAP -- INVERSE RULES").
    function buildMemorySwapGroupHtml(system) {
        const memory = system.memory || {};
        const hasMemory = systemGroupHasAny(memory, ['used', 'total', 'pressure_percent']);
        const hasSwap = 'swap_used_bytes' in system;
        if (!hasMemory && !hasSwap) {
            return '';
        }

        let memoryRowHtml;
        if (!hasMemory) {
            memoryRowHtml = systemRowAbsent('MEMORY');
        } else {
            const usedStr = formatSystemBytes(memory.used);
            const totalStr = formatSystemBytes(memory.total);
            let text = (usedStr !== null ? usedStr : 'not reported') + ' / ' + (totalStr !== null ? totalStr : 'not reported');
            if ('pressure_percent' in memory) {
                text += '&nbsp;&nbsp;(' + escapeHtml(String(memory.pressure_percent)) + '% pressure)';
            }
            memoryRowHtml = systemRowValue('MEMORY', text);
        }

        let swapRowHtml;
        if (!hasSwap) {
            swapRowHtml = systemRowAbsent('SWAP');
        } else {
            const swapStr = formatSystemBytes(system.swap_used_bytes);
            swapRowHtml = systemRowValue('SWAP', swapStr !== null ? swapStr : 'not reported');
        }

        return '<div class="status-row-system-group"><div class="machine-system-group-label">MEMORY &amp; SWAP</div>' + memoryRowHtml + swapRowHtml + '</div>';
    }

    // DISK group. `disk.percent` is rendered EXACTLY as sent -- NEVER
    // recomputed from used/free (contract §5a: APFS df total is not
    // used+free; see lcars-machine-health.js module header for the ~20x
    // under-report this would otherwise silently produce).
    function buildDiskGroupHtml(system) {
        const disk = system.disk || {};
        if (!systemGroupHasAny(disk, ['used', 'free', 'percent'])) {
            return '';
        }
        const usedStr = formatSystemBytes(disk.used);
        const usedRow = systemRowValue('USED', usedStr !== null ? usedStr : 'not reported');

        const freeStr = formatSystemBytes(disk.free);
        let freeText = freeStr !== null ? freeStr : 'not reported';
        if ('percent' in disk) {
            freeText += '&nbsp;&nbsp;(' + escapeHtml(String(disk.percent)) + '%)';
        }
        const freeRow = systemRowValue('FREE', freeText);

        return '<div class="status-row-system-group"><div class="machine-system-group-label">DISK</div>' + usedRow + freeRow + '</div>';
    }

    // LOAD group. Shows the raw triple AND the 1-minute figure normalized
    // per core (UX spec §3: showing only the raw number "reads as a wildly
    // overloaded box" without the per-core context). Never applies a
    // threshold itself -- XACA-1092-003 owns that, and its two constants
    // are under user review; this function only formats whatever
    // load_average/cores the reporter sent.
    function buildLoadGroupHtml(system) {
        const load = system.load_average;
        if (!Array.isArray(load) || load.length === 0) {
            return '';
        }
        function fmtEntry(v) {
            return (typeof v === 'number' && isFinite(v)) ? v.toFixed(2) : '?';
        }
        const triple = fmtEntry(load[0]) + ' / ' + fmtEntry(load[1]) + ' / ' + fmtEntry(load[2]);

        let suffix = '';
        const cores = system.cores;
        if (typeof load[0] === 'number' && isFinite(load[0]) && typeof cores === 'number' && isFinite(cores) && cores > 0) {
            suffix = '&nbsp;&nbsp;(' + (load[0] / cores).toFixed(2) + '× per core)';
        }
        return '<div class="status-row-system-group"><div class="machine-system-group-label">LOAD</div>' +
            systemRowValue('1 / 5 / 15 MIN', triple + suffix) + '</div>';
    }

    // Version line (UX spec §6) -- ALWAYS visible when the reporter has told
    // us the installed version at all, independent of whether any health
    // group has data (this is what makes the VersionsOnlyDayOne fixture
    // case show a version line with zero SYSTEM groups). Three states, keyed
    // off `'outdated' in versions` via strict comparison against true/false,
    // never off the truthiness of `outdated` itself -- `false` (confirmed
    // current) must render differently from omitted (unknown), and a
    // hostile non-boolean value (e.g. the string "yes") must fall safely
    // into the "unknown" bucket rather than matching either branch.

    // HEALTH badge (UX spec §4 + ADDENDUM): shown ONLY for 'at_risk' --
    // 'healthy' and 'unknown' both render as NO badge (not the same fact,
    // but the same silence -- see the ADDENDUM's "why not show unknown").
    // deriveMachineHealth()'s overall state collapses warning+critical into
    // a single 'at_risk', so the CRITICAL/AT RISK text choice is this
    // renderer's own aggregation across the per-metric states, per the
    // spec's explicit precedence rule ("if any metric is CRITICAL, show
    // CRITICAL; else if any is WARNING, show AT RISK").
    // Returns null when no badge should render, else {className, text}.
    // Deliberately a SPEC rather than an HTML string: the badge is appended
    // with the DOM API after XACA-1031-018's versionEl is in place, because
    // extending item.innerHTML at that point would destroy versionEl.
    function healthBadgeSpec(healthResult) {
        if (!healthResult || healthResult.state !== 'at_risk') {
            return null;
        }
        const metrics = healthResult.metrics || {};
        const anyCritical = ['disk', 'swap', 'load'].some(function (key) {
            return metrics[key] && metrics[key].state === 'critical';
        });
        return anyCritical
            ? { className: 'status-badge health-critical', text: 'CRITICAL' }
            : { className: 'status-badge health-warning', text: 'AT RISK' };
    }

    // VERSION badge -- shown ONLY for outdated === true (UX spec §4): never
    // for false (confirmed current) or omitted (unknown), both of which are
    // non-actionable at a glance and are differentiated instead on the
    // always-visible version line.

    // SYSTEM disclosure toggle + panel, or the static NO DATA line, or
    // nothing -- UX spec §5's "two-tier presence signal":
    //   - no `schema_version` at all (whole block absent, pre-XACA-1031
    //     reporter) -> '' (nothing new, matches today's card exactly)
    //   - `schema_version` present but zero health groups have any field
    //     (the VersionsOnlyDayOne/NonMacOSHostVersionsOnly shape -- the
    //     default production state for the entire window between XACA-1031
    //     merging and XACA-1091 shipping, per XACA-1091-016's fixture note
    //     "why case 9 is the most important one, not a rare edge") -> the
    //     static "SYSTEM: NO DATA REPORTED" line, no chevron
    //   - at least one group has at least one field -> the real interactive
    //     toggle + panel
    // Deliberately does NOT embed machine_id into this returned HTML string
    // -- the toggle's data-machine-id is set via el.setAttribute() by the
    // caller instead (an imperative DOM call, never HTML-string
    // interpolation), so this file's existing "no untrusted value reaches a
    // quoted attribute" invariant (XACA-0416-004) holds and escapeAttr()
    // stays undefined here, matching the rest of this file.
    function buildSystemSectionHtml(system, isExpanded) {
        const groupsHtml = buildPlatformGroupHtml(system) + buildMemorySwapGroupHtml(system) +
            buildDiskGroupHtml(system) + buildLoadGroupHtml(system);

        if (groupsHtml !== '') {
            return (
                '<div class="status-row-system-toggle clickable">' +
                    '<span class="status-row-system-indicator' + (isExpanded ? ' expanded' : '') + '">▶</span>' +
                    '<span class="status-row-system-label">SYSTEM</span>' +
                '</div>' +
                '<div class="status-row-system-panel' + (isExpanded ? ' expanded' : '') + '">' + groupsHtml + '</div>'
            );
        }

        if ('schema_version' in system) {
            return '<div class="status-row-system-no-data">SYSTEM: NO DATA REPORTED</div>';
        }

        return '';
    }

    function toggleSystemPanel(machineId, detailEl) {
        const panel = detailEl.querySelector('.status-row-system-panel');
        const indicator = detailEl.querySelector('.status-row-system-indicator');
        if (!panel) return;

        if (expandedSystemMachineId === machineId) {
            expandedSystemMachineId = null;
            panel.classList.remove('expanded');
            if (indicator) indicator.classList.remove('expanded');
            return;
        }

        if (expandedSystemMachineId) {
            const prevToggle = document.querySelector('.status-row-system-toggle[data-machine-id="' + CSS.escape(expandedSystemMachineId) + '"]');
            if (prevToggle) {
                const prevDetail = prevToggle.parentElement;
                const prevPanel = prevDetail ? prevDetail.querySelector('.status-row-system-panel') : null;
                const prevIndicator = prevDetail ? prevDetail.querySelector('.status-row-system-indicator') : null;
                if (prevPanel) prevPanel.classList.remove('expanded');
                if (prevIndicator) prevIndicator.classList.remove('expanded');
            }
        }

        expandedSystemMachineId = machineId;
        panel.classList.add('expanded');
        if (indicator) indicator.classList.add('expanded');
    }

    function createMachineItem(machine) {
        const system = machine.system || {};
        const healthResult = (window.LCARS_MACHINE_HEALTH && window.LCARS_MACHINE_HEALTH.deriveMachineHealth)
            ? window.LCARS_MACHINE_HEALTH.deriveMachineHealth(machineSystemToHealthInput(system))
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
            '<span class="lcars-text-sm status-row-hostname" style="flex: 1;">' + escapeHtml(machine.hostname) + '</span>' +
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
        const badgeSpec = healthBadgeSpec(healthResult);
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

        const isSystemExpanded = expandedSystemMachineId === machine.machine_id;
        const detailHtml = buildSystemSectionHtml(system, isSystemExpanded);
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
                toggle.addEventListener('click', function (e) {
                    e.stopPropagation();
                    toggleSystemPanel(machine.machine_id, detail);
                });
            }
        }

        return fragment;    }

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
