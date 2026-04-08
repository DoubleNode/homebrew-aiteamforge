/**
 * LCARS Analytics Pages Module
 * Sub-screen navigation system for the analytics section.
 *
 * Breaks analytics into multiple full-screen pages:
 *   - Static pages: Overview, Charts (always present)
 *   - Dynamic team pages: one per visible team (filtered by dashboard)
 *   - Kiosk-only pages: registered via registerKioskPage(), NOT shown as nav tabs
 *
 * Page count varies by dashboard config (divisions filter).
 * Provides public API for kiosk mode to cycle through analytics pages.
 *
 * Requires: lcars-fleet-core.js loaded before this script.
 * Exposes: window.LCARSAnalyticsPages
 */

/* global LCARSCharts */

// Assign to window explicitly — const/let don't create window properties,
// and kiosk.js + dashboard-app.js check window.LCARSAnalyticsPages.
window.LCARSAnalyticsPages = (function () {
    'use strict';

    // =========================================================================
    // CONFIGURATION
    // =========================================================================

    /** Static pages — always present in this order (team pages inserted before trailing pages) */
    const STATIC_PAGES = [
        { id: 'overview',      label: 'OVERVIEW' },
        { id: 'charts',        label: 'CHARTS' },
        { id: 'divisions',     label: 'DIVISIONS' },
        { id: 'knowledge',     label: 'KNOWLEDGE' },
        { id: 'knowledge-log', label: 'KNOWLEDGE LOG' }
        // Dynamic team pages go here at runtime
        // Trailing pages appended after team pages
    ];

    /** Trailing pages — appended after dynamic team pages */
    const TRAILING_PAGES = [
    ];

    // =========================================================================
    // STATE
    // =========================================================================

    let config = {
        divisions: null,   // Array of division IDs or null (all fleet)
        dashboardId: null
    };

    /**
     * Ordered list of all page descriptors: { id, label, isTeam, kioskOnly }
     * Includes ALL pages — both regular (tab-visible) and kiosk-only.
     * This is the source of truth for kiosk navigation.
     */
    let allPages = [];

    /** Index of the currently visible page within allPages */
    let currentPageIndex = 0;

    /** Whether the module has been initialized */
    let initialized = false;

    /** Cached knowledge data — stored so team pages built after knowledge arrives still get populated */
    let lastKnowledgeTeams = null;

    /** Cached kanban teams data — used to lazily render team page doughnuts when pages become visible */
    let lastKanbanTeams = null;

    /** Chart instances created by this module (team page doughnuts) */
    const teamCharts = {};

    /**
     * Registry of kiosk-only pages.
     * Key: page ID. Value: { id, label, renderFn }.
     * renderFn(container) is called to populate the analytics content area.
     */
    const kioskPageRegistry = {};

    // Team color palette — matches lcars-analytics-kanban.js
    const TEAM_COLORS = [
        '#99CCFF', '#FFCC99', '#CC99CC', '#99CC99',
        '#FF9900', '#9999CC', '#FFFF99', '#CC6666'
    ];

    function teamColor(index) {
        return TEAM_COLORS[index % TEAM_COLORS.length];
    }

    // =========================================================================
    // DIVISION FILTERING
    // Maps team IDs to dashboard division IDs (from dashboards.json).
    // Dashboard configs use division IDs like "mainevent", "academy", etc.
    // Team IDs from the API are "android", "ios", "firebase", etc.
    // =========================================================================

    const DIVISION_MAP = {
        academy:  'academy',
        command:  'mainevent',
        android:  'mainevent',
        firebase: 'mainevent',
        ios:      'mainevent',
        dns:      'dns'
    };

    function getTeamDivision(teamId) {
        var id = teamId.toLowerCase();
        if (id.startsWith('freelance')) return id;
        return DIVISION_MAP[id] || id;
    }

    function isTeamVisible(teamId, divisions) {
        if (!divisions) return true; // All Fleet — no filter
        var id = teamId.toLowerCase();
        // Match either: direct team ID or mapped division group.
        // Dashboard configs may contain team IDs ("android") or group IDs ("mainevent").
        return divisions.indexOf(id) !== -1 ||
            divisions.indexOf(getTeamDivision(id)) !== -1;
    }

    // =========================================================================
    // NAV PILLS
    // =========================================================================

    /** Render nav pills into #analytics-page-nav based on allPages.
     *  Kiosk-only pages are excluded from the tab strip — they are not
     *  clickable from the analytics section header. */
    function renderNavPills() {
        var nav = document.getElementById('analytics-page-nav');
        if (!nav) return;

        // Only tab-visible (non-kiosk-only) pages appear as pills
        var tabPages = allPages.filter(function (p) { return !p.kioskOnly; });

        // Build: prev arrow + pills + next arrow
        var html = '<button class="analytics-page-arrow" id="analytics-prev-page" title="Previous Page">&#9664;</button>';

        html += tabPages.map(function (page) {
            // Active state: check if this page is the current one
            var activeClass = (page.id === _getCurrentPageId()) ? ' active' : '';
            var teamClass = page.isTeam ? ' team-pill' : '';
            return '<button class="analytics-page-pill' + activeClass + teamClass + '" ' +
                'data-page-id="' + page.id + '">' +
                page.label +
                '</button>';
        }).join('');

        html += '<button class="analytics-page-arrow" id="analytics-next-page" title="Next Page">&#9654;</button>';

        // Page counter badge — shows position within tab-visible pages only
        var tabIdx = _currentTabIndex(tabPages);
        html += '<span class="analytics-page-counter">' + (tabIdx + 1) + ' / ' + tabPages.length + '</span>';

        nav.innerHTML = html;

        // Attach click handlers — pills
        nav.querySelectorAll('.analytics-page-pill').forEach(function (pill) {
            pill.addEventListener('click', function () {
                var pageId = pill.getAttribute('data-page-id');
                switchPage(pageId);
            });
        });

        // Attach click handlers — arrows (navigate within tab-visible pages only)
        var prevBtn = document.getElementById('analytics-prev-page');
        var nextBtn = document.getElementById('analytics-next-page');
        if (prevBtn) {
            prevBtn.addEventListener('click', function () {
                prevPage();
            });
        }
        if (nextBtn) {
            nextBtn.addEventListener('click', function () {
                nextPage();
            });
        }
    }

    /** Get the ID of the current page from allPages */
    function _getCurrentPageId() {
        if (allPages.length === 0) return null;
        return allPages[currentPageIndex] ? allPages[currentPageIndex].id : null;
    }

    /**
     * Find the index of the current page within tab-visible (non-kiosk-only) pages.
     * Used to drive the counter badge. Returns 0 if current page is kiosk-only.
     */
    function _currentTabIndex(tabPages) {
        var currentId = _getCurrentPageId();
        for (var i = 0; i < tabPages.length; i++) {
            if (tabPages[i].id === currentId) return i;
        }
        // Current page is kiosk-only — counter shows last known tab position
        return 0;
    }

    /** Update the active state on nav pills and page counter */
    function updateNavPillActive() {
        var nav = document.getElementById('analytics-page-nav');
        if (!nav) return;

        var currentId = _getCurrentPageId();
        var tabPages = allPages.filter(function (p) { return !p.kioskOnly; });

        // Update pill active states by page ID (not index) — kiosk-only pages
        // don't have pills, so there's no pill to activate for them
        nav.querySelectorAll('.analytics-page-pill').forEach(function (pill) {
            pill.classList.toggle('active', pill.getAttribute('data-page-id') === currentId);
        });

        // Update counter badge — shows position within tab-visible pages
        var counter = nav.querySelector('.analytics-page-counter');
        if (counter) {
            var tabIdx = _currentTabIndex(tabPages);
            counter.textContent = (tabIdx + 1) + ' / ' + tabPages.length;
        }
    }

    // =========================================================================
    // PAGE MANAGEMENT
    // =========================================================================

    /**
     * Switch to a specific page by ID.
     * For regular pages: hides current page DOM element, shows target.
     * For kiosk-only pages: calls renderKioskPage() to populate content area.
     * Updates nav, dispatches event.
     */
    function switchPage(pageId) {
        // Find target index
        var targetIdx = -1;
        for (var i = 0; i < allPages.length; i++) {
            if (allPages[i].id === pageId) {
                targetIdx = i;
                break;
            }
        }
        if (targetIdx === -1) return;

        var targetPage = allPages[targetIdx];

        // Shared reference to the kiosk content container
        var kioskContent = document.getElementById('analytics-content');

        if (targetPage.kioskOnly) {
            // Kiosk-only page: hide any currently active DOM page,
            // then render the kiosk page into the content area
            var currentEl = document.querySelector('.analytics-page.active');
            if (currentEl) {
                currentEl.classList.remove('active');
            }

            // Show the kiosk content area (must override CSS display:none)
            if (kioskContent) {
                kioskContent.style.display = 'block';
            }

            currentPageIndex = targetIdx;
            updateNavPillActive();

            // Render using the registered renderFn
            renderKioskPage(pageId);

        } else {
            // Regular page: show the corresponding .analytics-page DOM element

            // Hide current page
            var currentPage = document.querySelector('.analytics-page.active');
            if (currentPage) {
                currentPage.classList.remove('active');
            }

            // Hide the kiosk content area — a regular page is taking over
            if (kioskContent) {
                kioskContent.style.display = 'none';
            }

            // Show target page
            var targetEl = document.querySelector('.analytics-page[data-analytics-page="' + pageId + '"]');
            if (targetEl) {
                targetEl.classList.add('active');
            }

            currentPageIndex = targetIdx;
            updateNavPillActive();
        }

        // Dispatch page change event for chart resize
        document.dispatchEvent(new CustomEvent('lcars:analyticsPageChange', {
            detail: { page: pageId, index: targetIdx }
        }));
    }

    /**
     * Advance to the next tab-visible page (with wraparound). Returns new page ID.
     * Skips kiosk-only pages — those are only reachable during kiosk rotation.
     */
    function nextPage() {
        if (allPages.length === 0) return null;
        var idx = currentPageIndex;
        for (var i = 0; i < allPages.length; i++) {
            idx = (idx + 1) % allPages.length;
            if (!allPages[idx].kioskOnly) {
                switchPage(allPages[idx].id);
                return allPages[idx].id;
            }
        }
        return null;
    }

    /**
     * Go to the previous tab-visible page (with wraparound). Returns new page ID.
     * Skips kiosk-only pages — those are only reachable during kiosk rotation.
     */
    function prevPage() {
        if (allPages.length === 0) return null;
        var idx = currentPageIndex;
        for (var i = 0; i < allPages.length; i++) {
            idx = (idx - 1 + allPages.length) % allPages.length;
            if (!allPages[idx].kioskOnly) {
                switchPage(allPages[idx].id);
                return allPages[idx].id;
            }
        }
        return null;
    }

    /**
     * Advance to the next page including kiosk-only pages (with wraparound).
     * Used by kiosk mode rotation. Returns new page ID.
     */
    function nextFullPage() {
        if (allPages.length === 0) return null;
        var nextIdx = (currentPageIndex + 1) % allPages.length;
        var pageId = allPages[nextIdx].id;
        switchPage(pageId);
        return pageId;
    }

    /**
     * Go to the previous page including kiosk-only pages (with wraparound).
     * Used by kiosk mode rotation. Returns new page ID.
     */
    function prevFullPage() {
        if (allPages.length === 0) return null;
        var prevIdx = (currentPageIndex - 1 + allPages.length) % allPages.length;
        var pageId = allPages[prevIdx].id;
        switchPage(pageId);
        return pageId;
    }

    /** Get the ID of the currently active page */
    function getCurrentPage() {
        return _getCurrentPageId();
    }

    /**
     * Get the count of tab-visible (non-kiosk-only) pages.
     * Backward compatible — this is what the nav tabs use.
     */
    function getPageCount() {
        return allPages.filter(function (p) { return !p.kioskOnly; }).length;
    }

    /**
     * Get ordered list of tab-visible (non-kiosk-only) page descriptors.
     * Backward compatible.
     */
    function getPageList() {
        return allPages.filter(function (p) { return !p.kioskOnly; });
    }

    /**
     * Get the count of ALL pages including kiosk-only pages.
     * Used by kiosk system to determine whether to enter analytics mode.
     */
    function getFullPageCount() {
        return allPages.length;
    }

    /**
     * Get ordered list of ALL page descriptors including kiosk-only pages.
     * Used by kiosk system for page dots and rotation.
     */
    function getFullPageList() {
        return allPages.slice();
    }

    // =========================================================================
    // KIOSK-ONLY PAGE REGISTRATION & RENDERING
    // =========================================================================

    /**
     * Register a kiosk-only page that will appear during kiosk rotation
     * but NOT as a clickable tab in the analytics section header.
     *
     * Call this before init() or after init() — the page will be appended
     * to allPages at the end (after trailing pages). If allPages has already
     * been built, it is updated immediately and nav is re-rendered.
     *
     * @param {object} pageConfig - Page configuration object
     * @param {string} pageConfig.id - Unique page identifier
     * @param {string} pageConfig.label - Display label (used in page dots)
     * @param {function} pageConfig.renderFn - function(container) that populates
     *   the #analytics-content area when this page is shown
     */
    function registerKioskPage(pageConfig) {
        if (!pageConfig || !pageConfig.id || typeof pageConfig.renderFn !== 'function') {
            console.warn('[LCARSAnalyticsPages] registerKioskPage: invalid pageConfig', pageConfig);
            return;
        }

        // Store in registry for renderKioskPage() to find
        kioskPageRegistry[pageConfig.id] = {
            id: pageConfig.id,
            label: pageConfig.label || pageConfig.id.toUpperCase(),
            renderFn: pageConfig.renderFn
        };

        // Create the page descriptor (kioskOnly: true)
        var descriptor = {
            id: pageConfig.id,
            label: pageConfig.label || pageConfig.id.toUpperCase(),
            kioskOnly: true
        };

        // If allPages is already built, append and re-render nav
        // (If not yet initialized, _rebuildPageList will pick up registry entries)
        if (initialized) {
            // Remove any existing entry with this ID first (idempotent re-registration)
            allPages = allPages.filter(function (p) { return p.id !== pageConfig.id; });
            allPages.push(descriptor);
            renderNavPills();
        }

        console.log('[LCARSAnalyticsPages] Kiosk page registered:', pageConfig.id);
    }

    /**
     * Render a kiosk-only page into the analytics content area.
     * Finds the registered renderFn and calls it with the content container.
     *
     * @param {string} pageId - The kiosk page ID to render
     * @returns {boolean} true if the page was found and rendered, false otherwise
     */
    function renderKioskPage(pageId) {
        var pageConfig = kioskPageRegistry[pageId];
        if (!pageConfig) {
            console.warn('[LCARSAnalyticsPages] renderKioskPage: page not in registry:', pageId);
            return false;
        }

        var container = document.getElementById('analytics-content');
        if (!container) {
            console.warn('[LCARSAnalyticsPages] renderKioskPage: #analytics-content not found');
            return false;
        }

        try {
            pageConfig.renderFn(container);
            return true;
        } catch (err) {
            console.error('[LCARSAnalyticsPages] renderKioskPage: renderFn threw for', pageId, err);
            return false;
        }
    }

    // =========================================================================
    // TEAM PAGE BUILDING
    // =========================================================================

    /**
     * Build dynamic team pages from kanban data.
     * Called when lcars:kanbanDataReady fires.
     *
     * @param {object} teamsData - teams object keyed by teamId
     */
    function buildTeamPages(teamsData) {
        var container = document.getElementById('analytics-team-pages-container');
        if (!container) return;

        // Cache kanban teams for lazy doughnut rendering on page switch
        lastKanbanTeams = teamsData;

        // Destroy existing team charts
        Object.keys(teamCharts).forEach(function (id) {
            if (teamCharts[id]) {
                teamCharts[id].destroy();
                delete teamCharts[id];
            }
        });

        // Clear existing team page elements
        container.innerHTML = '';

        if (!teamsData || Object.keys(teamsData).length === 0) {
            _rebuildPageList([]);
            return;
        }

        // Filter and sort teams
        var visibleTeams = Object.values(teamsData)
            .filter(function (t) { return !t.error; })
            .filter(function (t) { return isTeamVisible(t.teamId || '', config.divisions); })
            .sort(function (a, b) { return (b.totalItems || 0) - (a.totalItems || 0); });

        // Build page elements and page descriptors
        var teamPageDescs = [];

        visibleTeams.forEach(function (team, idx) {
            var teamId = team.teamId || 'unknown';
            var pageId = 'team-' + teamId;
            var displayName = (team.displayName || teamId).toUpperCase();
            var color = teamColor(idx);
            var sc = team.statusCounts || {};
            var totalItems = team.totalItems || 0;
            var completed = sc.completed || 0;
            var todo = sc.todo || 0;
            var rate = team.completionRate || 0;
            var inProgress = (sc.in_progress || 0) + (sc.coding || 0) + (sc.planning || 0);
            var recent = team.recentActivity || {};
            var subitems = team.subitemStats || {};
            var canvasId = 'team-page-doughnut-' + teamId;

            // Build the page div
            var pageDiv = document.createElement('div');
            pageDiv.className = 'analytics-page';
            pageDiv.setAttribute('data-analytics-page', pageId);

            pageDiv.innerHTML =
                '<div class="analytics-team-page-content" style="display: flex; flex-direction: column; height: calc(100vh - 140px);">' +
                    '<div class="team-header" style="border-left: 4px solid ' + color + '; padding-left: 12px; margin-top: 10px; flex-shrink: 0;">' +
                        '<div style="color: ' + color + '; font-family: \'Antonio\', sans-serif; font-size: 24px; font-weight: 600; letter-spacing: 0.08em;">' + displayName + '</div>' +
                    '</div>' +
                    // Metrics row — full width
                    '<div class="team-metrics-grid" style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; margin-top: 10px; flex-shrink: 0;">' +
                        _metricCard(totalItems, 'TOTAL ITEMS', '#99CCFF') +
                        _metricCard(completed, 'COMPLETED', '#99CC99') +
                        _metricCard(todo, 'TODO', '#FF9900') +
                        _metricCard(rate + '%', 'COMPLETION', '#CC99CC') +
                        _metricCard(inProgress, 'IN PROGRESS', '#FFCC99') +
                        _metricCard(recent.completedLast7Days || 0, 'DONE / 7D', '#99CC99') +
                        _metricCard(subitems.total || 0, 'SUBITEMS', '#9999CC') +
                        _metricCard(subitems.pending || 0, 'PENDING', '#FFFF99') +
                    '</div>' +
                    // Three-column: Knowledge | Epic Progress | Status Doughnut
                    '<div style="display: flex; gap: 20px; margin-top: 10px; flex: 1; min-height: 0;">' +
                        '<div style="flex: 5; min-width: 0; display: flex; flex-direction: column;">' +
                            '<div id="team-knowledge-' + teamId + '" style="flex: 1; overflow-y: auto;">' +
                                '<div style="color: rgba(255,204,153,0.4); font-family: \'Antonio\', sans-serif; font-size: 12px;">LOADING KNOWLEDGE...</div>' +
                            '</div>' +
                        '</div>' +
                        '<div style="flex: 2; min-width: 0; display: flex; flex-direction: column; overflow-y: auto;">' +
                            _buildTeamEpicBars(team, color) +
                        '</div>' +
                        '<div class="team-doughnut-wrapper" style="flex: 3; min-width: 0; display: flex; flex-direction: column;">' +
                            '<div style="background: rgba(0,0,0,0.3); border-radius: 8px; padding: 15px; flex: 1; display: flex; flex-direction: column; min-height: 0;">' +
                                '<div style="color: #FFCC99; font-family: \'Antonio\', sans-serif; font-size: 16px; margin-bottom: 8px; flex-shrink: 0;">STATUS DISTRIBUTION</div>' +
                                '<div style="flex: 1; min-height: 0; position: relative;">' +
                                    '<canvas id="' + canvasId + '"></canvas>' +
                                '</div>' +
                            '</div>' +
                        '</div>' +
                    '</div>' +
                '</div>';

            container.appendChild(pageDiv);

            teamPageDescs.push({ id: pageId, label: displayName, isTeam: true });
        });

        // Rebuild page list and nav
        _rebuildPageList(teamPageDescs);

        // Apply cached knowledge data after DOM is ready.
        // Team page doughnuts are rendered LAZILY when the page becomes visible
        // (via analyticsPageChange listener) — creating Chart.js instances on
        // off-screen canvases (left: -9999px) produces broken charts.
        setTimeout(function () {
            // Render the doughnut for the CURRENTLY ACTIVE team page only
            var activePage = allPages[currentPageIndex];
            if (activePage && activePage.isTeam) {
                var activeTeamId = activePage.id.replace('team-', '');
                var activeTeam = visibleTeams.find(function (t) { return t.teamId === activeTeamId; });
                if (activeTeam) {
                    try { _renderTeamPageDoughnut(activeTeam); }
                    catch (err) { console.error('[LCARSAnalyticsPages] Doughnut render error for', activeTeamId, err); }
                }
            }

            // Re-apply cached knowledge data to newly built team pages
            if (lastKnowledgeTeams) {
                _updateTeamKnowledge(lastKnowledgeTeams);
            }
        }, 50);
    }

    /** Rebuild the allPages list with static + dynamic team pages + trailing pages + kiosk-only pages */
    function _rebuildPageList(teamPageDescs) {
        allPages = STATIC_PAGES.slice();

        // Insert team pages
        teamPageDescs.forEach(function (desc) {
            allPages.push(desc);
        });

        // Append trailing pages (epics, divisions)
        TRAILING_PAGES.forEach(function (page) {
            allPages.push(page);
        });

        // Append kiosk-only pages after all regular pages.
        // These come from the registry — they were registered via registerKioskPage().
        Object.values(kioskPageRegistry).forEach(function (regEntry) {
            allPages.push({
                id: regEntry.id,
                label: regEntry.label,
                kioskOnly: true
            });
        });

        // Re-render nav pills (filters out kiosk-only automatically)
        renderNavPills();

        // Ensure current page index is valid
        if (currentPageIndex >= allPages.length) {
            currentPageIndex = 0;
        }

        // Restore the active page after DOM rebuild (data refresh wipes elements)
        var pageToRestore = allPages[currentPageIndex];
        if (pageToRestore && !pageToRestore.kioskOnly) {
            switchPage(pageToRestore.id);
        } else if (allPages.length > 0) {
            // If current page is kiosk-only after rebuild, fall back to first tab page
            var firstTabPage = allPages.find(function (p) { return !p.kioskOnly; });
            if (firstTabPage) {
                currentPageIndex = allPages.indexOf(firstTabPage);
                switchPage(firstTabPage.id);
            }
        }
    }

    /** Build a large metric card for team pages */
    function _metricCard(value, label, color) {
        return '<div style="background: rgba(0,0,0,0.3); border-radius: 8px; padding: 14px; text-align: center;">' +
            '<div style="color: ' + color + '; font-family: \'Antonio\', sans-serif; font-size: 32px; font-weight: 600;">' + value + '</div>' +
            '<div style="color: rgba(255,204,153,0.7); font-family: \'Antonio\', sans-serif; font-size: 13px; margin-top: 4px; letter-spacing: 0.05em;">' + label + '</div>' +
            '</div>';
    }

    /** Build epic progress bars HTML for a team page */
    function _buildTeamEpicBars(team, color) {
        if (!team.epics || team.epics.length === 0) return '';

        var bars = team.epics.map(function (epic) {
            var progress = Math.min(100, Math.max(0, epic.progress || 0));
            var epicName = (epic.name || 'Unnamed Epic').toUpperCase();
            var completed = epic.completedItems || 0;
            var total = epic.totalItems || 0;
            var barColor = progress >= 80 ? '#99CC99' : progress >= 40 ? '#FFCC99' : '#9999CC';

            return '<div style="margin-bottom: 10px;">' +
                '<div style="display: flex; justify-content: space-between; margin-bottom: 3px;">' +
                    '<span style="color: #FFCC99; font-family: \'Antonio\', sans-serif; font-size: 14px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1; padding-right: 8px;">' + epicName + '</span>' +
                    '<span style="color: rgba(255,204,153,0.7); font-family: \'Antonio\', sans-serif; font-size: 13px; white-space: nowrap;">' + completed + '/' + total + ' — ' + progress + '%</span>' +
                '</div>' +
                '<div style="background: rgba(255,255,255,0.08); border-radius: 4px; height: 10px; overflow: hidden;">' +
                    '<div style="background: ' + barColor + '; height: 100%; width: ' + progress + '%; border-radius: 4px; transition: width 1s ease;"></div>' +
                '</div>' +
                '</div>';
        }).join('');

        return '<div style="margin-top: 8px;">' +
            '<div style="color: ' + color + '; font-family: \'Antonio\', sans-serif; font-size: 15px; font-weight: 600; margin-bottom: 10px; letter-spacing: 0.08em;">EPIC PROGRESS</div>' +
            bars +
            '</div>';
    }

    /**
     * Update knowledge sections on each team page.
     * Called when lcars:knowledgeDataReady fires.
     * @param {object} teams - knowledge teams object keyed by teamId
     */
    function _updateTeamKnowledge(teams) {
        if (!teams) return;

        // Cache for later — team pages may be rebuilt after this data arrives
        lastKnowledgeTeams = teams;

        // Find all team knowledge containers in the DOM
        var containers = document.querySelectorAll('[id^="team-knowledge-"]');
        containers.forEach(function (container) {
            var teamId = container.id.replace('team-knowledge-', '');
            var teamData = teams[teamId];

            if (!teamData || (teamData.totalEntries || 0) === 0) {
                container.innerHTML =
                    '<div style="color: rgba(255,204,153,0.3); font-family: \'Antonio\', sans-serif; font-size: 12px; padding: 6px 0;">NO KNOWLEDGE ENTRIES</div>';
                return;
            }

            var agents = teamData.agents || {};
            var recent = teamData.recentEntries || [];
            var total = teamData.totalEntries || 0;
            var contributing = teamData.contributingAgents || 0;

            // Build agent entry counts (left column)
            var agentHtml = '';
            var sortedAgents = Object.keys(agents)
                .filter(function (a) { return agents[a].count > 0; })
                .sort(function (a, b) { return agents[b].count - agents[a].count; });

            sortedAgents.forEach(function (agentName) {
                var count = agents[agentName].count;
                agentHtml += '<div style="display: flex; justify-content: space-between; padding: 2px 0;">' +
                    '<span style="color: #FFCC99; font-family: \'Antonio\', sans-serif; font-size: 12px; text-transform: uppercase;">' + agentName + '</span>' +
                    '<span style="color: #CC99CC; font-family: \'Antonio\', sans-serif; font-size: 12px; font-weight: 600;">' + count + '</span>' +
                    '</div>';
            });

            // Build recent entries (right column, top 3)
            var recentHtml = '';
            recent.slice(0, 3).forEach(function (entry) {
                var title = entry.title || 'Untitled';
                var agent = entry.agent || '';
                var date = entry.date || '';
                recentHtml += '<div style="margin-bottom: 6px; padding: 4px 0; border-bottom: 1px solid rgba(255,255,255,0.05);">' +
                    '<div style="color: #FFCC99; font-family: \'Antonio\', sans-serif; font-size: 11px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">' + title + '</div>' +
                    '<div style="color: rgba(255,204,153,0.5); font-family: \'Antonio\', sans-serif; font-size: 10px;">' + agent.toUpperCase() + ' — ' + date + '</div>' +
                    '</div>';
            });

            container.innerHTML =
                '<div style="color: #CC99CC; font-family: \'Antonio\', sans-serif; font-size: 13px; font-weight: 600; margin-bottom: 6px; letter-spacing: 0.08em;">KNOWLEDGE BASE <span style="font-weight: 400; color: rgba(255,204,153,0.6);">(' + total + ' entries, ' + contributing + ' agents)</span></div>' +
                '<div style="display: grid; grid-template-columns: 1fr 1fr; gap: 4px 12px;">' +
                    agentHtml +
                '</div>' +
                '<div style="margin-top: 8px;">' + recentHtml + '</div>';
        });
    }

    /** Render a doughnut chart on a team page */
    function _renderTeamPageDoughnut(team) {
        if (typeof LCARSCharts === 'undefined') return;

        var teamId = team.teamId || 'unknown';
        var canvasId = 'team-page-doughnut-' + teamId;
        var canvas = document.getElementById(canvasId);
        if (!canvas) return;

        var sc = team.statusCounts || {};
        var statusOrder = ['completed', 'in_progress', 'coding', 'planning', 'todo', 'review', 'backlog', 'cancelled', 'blocked'];
        var labels = [];
        var values = [];
        var colors = [];

        statusOrder.forEach(function (status) {
            if (sc[status] && sc[status] > 0) {
                labels.push(status.replace(/_/g, ' ').toUpperCase());
                values.push(sc[status]);
                colors.push(LCARSCharts.statusColors[status] || LCARSCharts.colors.tan);
            }
        });

        // Catch remaining statuses
        Object.keys(sc).forEach(function (status) {
            if (statusOrder.indexOf(status) === -1 && sc[status] > 0) {
                labels.push(status.replace(/_/g, ' ').toUpperCase());
                values.push(sc[status]);
                colors.push(LCARSCharts.statusColors[status] || LCARSCharts.colors.tan);
            }
        });

        if (labels.length === 0) return;

        var chartData = {
            labels: labels,
            datasets: [{
                data: values,
                backgroundColor: colors,
                borderColor: LCARSCharts.colors.background,
                borderWidth: 2,
                hoverBorderColor: LCARSCharts.colors.tan,
                hoverBorderWidth: 3
            }]
        };

        teamCharts[teamId] = LCARSCharts.createDoughnut(canvasId, chartData, {
            cutout: '55%',
            plugins: {
                legend: {
                    display: true,
                    position: 'bottom',
                    labels: {
                        color: LCARSCharts.colors.text,
                        font: { family: "'Antonio', sans-serif", size: 14 },
                        padding: 10,
                        boxWidth: 12,
                        boxHeight: 12,
                        usePointStyle: true,
                        pointStyle: 'rectRounded'
                    }
                }
            },
            animation: { duration: 800, easing: 'easeInOutQuart' }
        });
    }

    // =========================================================================
    // INIT
    // =========================================================================

    /**
     * Initialize the analytics pages module.
     * @param {{ divisions: string[]|null, dashboardId: string }} opts
     */
    function init(opts) {
        if (opts) {
            config.divisions = opts.divisions || null;
            config.dashboardId = opts.dashboardId || null;
        }

        // Build initial page list (static pages only until kanban data arrives)
        _rebuildPageList([]);

        // Listen for kanban data ready
        document.addEventListener('lcars:kanbanDataReady', function (e) {
            if (e.detail && e.detail.teams) {
                buildTeamPages(e.detail.teams);
            }
        });

        // Listen for knowledge data ready — populate team knowledge sections
        document.addEventListener('lcars:knowledgeDataReady', function (e) {
            if (e.detail && e.detail.teams) {
                _updateTeamKnowledge(e.detail.teams);
            }
        });

        // Lazily render team page doughnuts when switching to a team page.
        // Chart.js instances created on off-screen canvases (position: absolute;
        // left: -9999px) get zero/wrong dimensions.  Destroy and recreate when
        // the page becomes visible via requestAnimationFrame.
        document.addEventListener('lcars:analyticsPageChange', function (e) {
            var page = e.detail && e.detail.page;
            if (!page || !page.startsWith('team-') || !lastKanbanTeams) return;

            var teamId = page.replace('team-', '');
            requestAnimationFrame(function () {
                // Destroy stale instance that was created off-screen
                if (teamCharts[teamId]) {
                    teamCharts[teamId].destroy();
                    delete teamCharts[teamId];
                }

                // Find team data from cached kanban data
                var teams = Object.values(lastKanbanTeams);
                var team = teams.find(function (t) { return t.teamId === teamId; });
                if (team) {
                    try { _renderTeamPageDoughnut(team); }
                    catch (err) { console.error('[LCARSAnalyticsPages] Doughnut render error for', teamId, err); }
                }
            });
        });

        // Listen for section change — when analytics becomes active, ensure first page is shown
        document.addEventListener('lcars:sectionChange', function (e) {
            if (e.detail && e.detail.section === 'analytics') {
                // If no page is currently active, show the first tab-visible page
                var activePage = document.querySelector('.analytics-page.active');
                if (!activePage && allPages.length > 0) {
                    var firstTabPage = allPages.find(function (p) { return !p.kioskOnly; });
                    if (firstTabPage) {
                        switchPage(firstTabPage.id);
                    }
                }
            }
        });

        initialized = true;
        console.log('[LCARSAnalyticsPages] Initialized. Dashboard:', config.dashboardId,
            'Divisions:', config.divisions ? config.divisions.join(', ') : 'ALL');
    }

    // =========================================================================
    // PUBLIC API
    // =========================================================================

    return {
        init: init,
        buildTeamPages: buildTeamPages,
        switchPage: switchPage,
        nextPage: nextPage,
        prevPage: prevPage,
        // Full navigation — includes kiosk-only pages (for kiosk rotation)
        nextFullPage: nextFullPage,
        prevFullPage: prevFullPage,
        getCurrentPage: getCurrentPage,
        // Backward-compatible methods — return only tab-visible (non-kiosk-only) pages
        getPageCount: getPageCount,
        getPageList: getPageList,
        // Full page list methods — include kiosk-only pages (for kiosk system)
        getFullPageCount: getFullPageCount,
        getFullPageList: getFullPageList,
        // Kiosk-only page registration and rendering
        registerKioskPage: registerKioskPage,
        renderKioskPage: renderKioskPage
    };

}());
