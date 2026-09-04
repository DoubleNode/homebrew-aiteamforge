//
//  lcars.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * LCARS - Library Computer Access/Retrieval System
 * Kanban Workflow Monitor - JavaScript Controller
 *
 * Handles data loading, real-time updates, and UI interactions
 * Now supports window-based tracking with worktree info
 */

// ═══════════════════════════════════════════════════════════════════════════════
// CONFIGURATION
// ═══════════════════════════════════════════════════════════════════════════════

const CONFIG = {
    dataPath: 'data/freelance-board.json',
    team: 'freelance',
    refreshInterval: 60000,
    autoRefresh: true
};

// ═══════════════════════════════════════════════════════════════════════════════
// BASE PATH DETECTION (for Tailscale Funnel path prefix support)
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Detect the base path prefix from the current URL.
 * Handles paths like /academy/, /firebase/, /ios/, etc.
 * Returns empty string if at root.
 */
function getBasePath() {
    const path = window.location.pathname;
    const knownPrefixes = [
        '/academy', '/firebase', '/dns', '/freelance',
        '/freelance-workstats', '/freelance-starwords',
        '/freelance-doublenode-workstats', '/freelance-doublenode-starwords',
        '/freelance-appplanning', '/freelance-doublenode-appplanning',
        '/command', '/ios', '/android', '/mainevent',
        '/legal', '/legal-coparenting'
    ];

    for (const prefix of knownPrefixes) {
        if (path.startsWith(prefix + '/') || path === prefix) {
            return prefix;
        }
    }
    return '';
}

/**
 * Convert an API path to include the base path prefix and, for team-scoped
 * endpoints, inject ?team=<CONFIG.team> so the server never silently falls
 * back to its LCARS_TEAM env default (or hard-coded "freelance").
 *
 * XACA-0249: team param injection
 *   - Only injects when CONFIG.team is truthy (set by loadServerConfig()).
 *   - Only injects for known team-scoped API prefixes — leaves unscoped
 *     endpoints (status, backup, integrations, rag-engines …) untouched.
 *   - Extra params can be passed as a plain object; they are merged after
 *     the team param so callers don't have to rebuild query strings by hand.
 *   - Does NOT overwrite an already-present ?team= in the raw path string
 *     (e.g. the calendar/items call that builds its own ?team=).
 *
 * e.g., '/api/epics' -> '/academy/api/epics?team=academy' when at /academy/
 */
// MAINTENANCE CONTRACT (XACA-0249):
//   When adding a new team-scoped endpoint to server.py (one that reads the
//   `team` query param and serves data per-team), add its path prefix here
//   so apiUrl() auto-injects ?team=<CONFIG.team>. Forgetting this step
//   reintroduces the silent-misrouting bug XACA-0249 fixed: the UI will
//   call without team= and the server will fall back to LCARS_TEAM env
//   (or hardcoded "freelance" when env is unset). The smoke test
//   (lcars-smoke-test.sh) catches the worst case but not per-endpoint drift.
const TEAM_SCOPED_PREFIXES = [
    '/api/epics',
    '/api/releases',
    '/api/todos',
    '/api/items',
    '/api/release-config',
    '/api/calendar/items',
    '/api/daily-overview',   // XACA-0334: Daily Overview aggregator
];

function apiUrl(path, extraParams) {
    const base = getBasePath();
    const withBase = path.startsWith('/') ? base + path : path;

    // Only inject team for known team-scoped paths, and only when CONFIG.team
    // is populated and the URL doesn't already carry a team= query param.
    const needsTeam = CONFIG.team &&
        TEAM_SCOPED_PREFIXES.some(p => path.startsWith(p)) &&
        !path.includes('team=');

    if (!needsTeam && !extraParams) {
        return withBase;
    }

    // Build URLSearchParams from any existing query string in path.
    const qmark = withBase.indexOf('?');
    const pathname = qmark === -1 ? withBase : withBase.slice(0, qmark);
    const existing = qmark === -1 ? '' : withBase.slice(qmark + 1);
    const sp = new URLSearchParams(existing);

    if (needsTeam) {
        sp.set('team', CONFIG.team);
    }
    if (extraParams) {
        for (const [k, v] of Object.entries(extraParams)) {
            if (v !== undefined && v !== null) {
                sp.set(k, String(v));
            }
        }
    }

    const qs = sp.toString();
    return qs ? pathname + '?' + qs : pathname;
}

// ═══════════════════════════════════════════════════════════════════════════════
// STATE
// ═══════════════════════════════════════════════════════════════════════════════

// `var` (not `let`) so the binding is exposed on `window.boardData`. lcars-cr-tab.js
// runs inside an IIFE and reads `window.boardData`; with `let` at top-level the
// global lexical declaration is not attached to `window` and the IIFE sees undefined,
// making the CHANGE REQ list permanently render "No change requests for this team."
var boardData = null;
let refreshTimer = null;

// RAG Engines health polling interval
let ragEnginesHealthInterval = null;

// HOME tab chart instances (preserved across re-renders to enable smooth updates)
let homeCharts = {
    statusDoughnut: null,
    subitemDoughnut: null,
    knowledgeDoughnut: null
};

// HOME tab carousel state
let currentHomePanel = 0;      // Physical panel index (data-panel-index value) of the active panel
let currentLogicalPanel = 0;   // Logical index within the visible (mode-filtered) panel set — XACA-0164-008
let TOTAL_HOME_PANELS = 7; // Base panels (0–6, incl. XACA-0630 Estimation Accuracy); increases dynamically with RAG engines
let carouselAutoTimer = null;
const CAROUSEL_AUTO_INTERVAL = 10000; // 10 seconds
let carouselPaused = false;
let carouselInitialized = false;
let homeFullscreen = false;

// RAG engine carousel state
let ragEngineData = [];          // Cached RAG engine summary data
let ragEnginePanelCount = 0;     // Number of active RAG engine panels
let _ragAbortController = null;  // AbortController for summary fetch

// Knowledge panel async fetch state — prevents orphaned chart injection on rapid navigation.
// _knowledgeAbortController: AbortController for the in-flight /api/knowledge-stats fetch.
//   Aborted and replaced each time panel 4 renders; null when no fetch is in flight.
// _knowledgeDebounceTimer: setTimeout handle for the 150ms debounce that precedes the fetch.
//   Cleared on rapid re-navigation so only one fetch fires per "landing".
let _knowledgeAbortController = null;
let _knowledgeDebounceTimer = null;
const KNOWLEDGE_DEBOUNCE_MS = 150;

// Tab navigation state
let activeSection = 'startup';
let activeSectionIndex = 0;
const SECTION_KEY = 'lcars-active-section';
const SECTIONS = ['startup', 'daily-overview', 'home', 'todos', 'calendar', 'workflow', 'details', 'backlog', 'change-req', 'epics', 'releases', 'roadmap', 'knowledge-graph', 'team-config', 'integrations', 'rag-engines', 'backups', 'commands', 'export-import', 'persona-browser', 'role-matcher', 'change-history', 'usage'];
const STARTUP_DELAY = 4000; // 4 seconds

// Mode state machine (XACA-0164)
let activeMode = null;  // no mode applied yet — first switchMode() call must run full setup
const MODES = ['team', 'kanban', 'data', 'settings'];
const MODE_KEY = 'lcars.activeMode';
// Per-mode section memory — XACA-0164-013
const MODE_SECTIONS_KEY = 'lcars.modeSections'; // JSON: { team, kanban, data, settings }

// Queue filter state
const BACKLOG_FILTER_KEY = 'lcars-queue-filter';
let backlogFilterState = { activeFilters: ['all'], searchText: '', sortBy: 'priority', osFilter: 'all', releaseFilter: 'all', epicFilter: 'all', categoryFilter: 'all' };

// Release/Epic search state (XACA-0209 round 5 — replaces pill-filter bars).
// Client-side substring search over id/title/shortTitle/description/tags.
// Storage keys are NEW (not the round-3/4 "*-tags-filter" keys) so legacy
// selectedTags arrays sitting in user localStorage are orphaned, not loaded.
const RELEASE_SEARCH_KEY = 'lcars-release-search';
let releaseSearchText = '';
const EPIC_SEARCH_KEY = 'lcars-epic-search';
let epicSearchText = '';

// Calendar state
const CALENDAR_VIEW_KEY = 'lcars-calendar-view';
const CALENDAR_EXTERNAL_KEY = 'lcars-calendar-show-external';
const CALENDAR_EPIC_FILTER_KEY = 'lcars-calendar-epic-filter';
let calendarState = {
    viewMode: localStorage.getItem(CALENDAR_VIEW_KEY) || 'week', // 'week' or 'month'
    currentDate: new Date(),
    showExternalEvents: localStorage.getItem(CALENDAR_EXTERNAL_KEY) === 'true',
    epicFilter: localStorage.getItem(CALENDAR_EPIC_FILTER_KEY) || 'all',
    hasCalendarIntegration: false,  // Set during init
    externalEvents: [],  // Cached external events
    cachedItems: null,  // Cached calendar items from API
    cachedEpics: null,  // Cached calendar epics from API
    cacheStartDate: null,  // Start date of cached range
    cacheEndDate: null,   // End date of cached range
    // Sync status tracking (XACA-0039-010)
    syncStatus: 'not_connected',  // 'synced' | 'syncing' | 'error' | 'not_connected'
    lastSyncTime: null,           // Date object or null
    syncError: null,              // Error message or null
    isSyncing: false              // Active sync operation flag
};

// Plan document existence cache (XACA-0045-006)
// Structure: itemId -> {exists: boolean, timestamp: number}
const planDocExistsCache = new Map();

// ═══════════════════════════════════════════════════════════════════════════════
// OS PLATFORM CONFIGURATION
// ═══════════════════════════════════════════════════════════════════════════════

const OS_PLATFORMS = ['iOS', 'Android', 'Firebase', 'Web'];

const OS_CONFIG = {
    'iOS': {
        color: 'var(--div-ios)',
        logo: 'images/ios_logo.png',
        label: 'iOS'
    },
    'Android': {
        color: 'var(--div-android)',
        logo: 'images/android_logo.png',
        label: 'Android'
    },
    'Firebase': {
        color: 'var(--div-firebase)',
        logo: 'images/firebase_logo.png',
        label: 'Firebase'
    },
    'Web': {
        color: 'var(--div-web)',
        logo: 'images/web_logo.svg',
        label: 'Web'
    },
    'None': {
        color: 'var(--lcars-purple)',
        logo: null,  // Uses inline SVG grid icon
        label: 'None'
    }
};

/**
 * Extract OS platform from tags array
 * @param {string[]} tags - Array of tag strings
 * @returns {string|null} - The OS platform or null if none found
 */
function getOSFromTags(tags) {
    if (!tags || !Array.isArray(tags)) return null;
    for (const tag of tags) {
        if (OS_PLATFORMS.includes(tag)) {
            return tag;
        }
    }
    return null;
}

/**
 * Filter OS tags from regular tag display
 * @param {string[]} tags - Array of tag strings
 * @returns {string[]} - Tags with OS platforms removed
 */
function filterOSTags(tags) {
    if (!tags || !Array.isArray(tags)) return [];
    return tags.filter(tag => !OS_PLATFORMS.includes(tag));
}

/**
 * Update OS in tags array (replace existing OS or add new)
 * @param {string[]} tags - Current tags array
 * @param {string} newOS - New OS value (iOS, Android, Firebase) or null to remove
 * @returns {string[]} - Updated tags array
 */
function updateOSInTags(tags, newOS) {
    // Start with filtered tags (no OS)
    const filtered = filterOSTags(tags);
    // If new OS specified, prepend it
    if (newOS && OS_PLATFORMS.includes(newOS)) {
        return [newOS, ...filtered];
    }
    return filtered;
}

// ═══════════════════════════════════════════════════════════════════════════════
// UTILITY FUNCTIONS
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Get the logo team name - maps sub-teams to their parent for logo lookup
 * e.g., 'freelance-starwords' -> 'freelance'
 * e.g., 'freelance-doublenode-starwords' -> 'freelance'
 */
function getLogoTeamName(team) {
    if (!team) return null;
    // Map freelance sub-projects (with or without group) to freelance logo
    if (team.startsWith('freelance-')) {
        return 'freelance';
    }
    // Map legal sub-teams to legal logo
    if (team.startsWith('legal-')) {
        return 'legal';
    }
    // Map medical sub-teams to medical logo
    if (team.startsWith('medical-')) {
        return 'medical';
    }
    // Map finance sub-projects to finance logo
    if (team.startsWith('finance-')) {
        return 'finance';
    }
    return team;
}

/**
 * Get epic title by ID from board data
 * Looks up the epic in boardData.epics and returns its title
 * @param {string} epicId - The epic ID (e.g., "EPIC-0001")
 * @returns {string|null} - The epic title or null if not found
 */
function getEpicTitleById(epicId) {
    if (!epicId || !boardData || !boardData.epics) return null;
    const epic = boardData.epics.find(e => e.id === epicId);
    return epic ? (epic.title || epic.name) : null;
}

/**
 * Get epic short title by ID from board data (XACA-0050)
 * Looks up the epic and returns shortTitle if available, otherwise falls back to full title
 * @param {string} epicId - The epic ID (e.g., "EPIC-0001")
 * @returns {string|null} - The epic short title or null if not found
 */
function getEpicShortTitleById(epicId) {
    if (!epicId || !boardData || !boardData.epics) return null;
    const epic = boardData.epics.find(e => e.id === epicId);
    return epic ? (epic.shortTitle || epic.title || epic.name) : null;
}

/**
 * Show a toast notification (XACA-0026)
 * @param {string} message - The message to display
 * @param {string} type - Toast type: 'success', 'error', 'warning', 'info' (default: 'info')
 * @param {number} duration - Duration in ms (default: 3000, use 0 for persistent)
 */
function showToast(message, type = 'info', duration = null) {
    // Default duration: errors/warnings stay longer so users can read them
    if (duration === null) {
        duration = (type === 'error' || type === 'warning') ? 6000 : 3000;
    }
    // Create toast container if it doesn't exist
    let container = document.getElementById('toast-container');
    if (!container) {
        container = document.createElement('div');
        container.id = 'toast-container';
        container.className = 'toast-container';
        document.body.appendChild(container);
    }

    // Create toast element
    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;

    // XACA-0395 [UX-14]: make toasts audible to assistive tech. error/warning use
    // role="alert" (implicit aria-live="assertive" + aria-atomic="true") so a failed
    // action — including a security-relevant auth failure — is announced immediately,
    // interrupting whatever the screen reader was doing, matching the visual urgency
    // (6s dwell above) and the fact the user's action did not happen. success/info use
    // role="status" (implicit aria-live="polite" + aria-atomic="true") so routine
    // confirmations are announced without interrupting the user's current task — a
    // barrage of polite status toasts should never cut off in-progress speech the way
    // an alert does. Both roles are applied before the element is appended to the DOM,
    // which is the pattern screen readers expect for dynamically-inserted live regions.
    toast.setAttribute('role', (type === 'error' || type === 'warning') ? 'alert' : 'status');

    // Icon based on type
    const icons = {
        success: '✓',
        error: '✗',
        warning: '⚠',
        info: 'ℹ'
    };

    // XACA-0217: build with textContent — message is untrusted (server errors, IDs, user input)
    const iconSpan = document.createElement('span');
    iconSpan.className = 'toast-icon';
    iconSpan.textContent = icons[type] || icons.info;

    const messageSpan = document.createElement('span');
    messageSpan.className = 'toast-message';
    messageSpan.textContent = message;

    const closeBtn = document.createElement('button');
    closeBtn.className = 'toast-close';
    closeBtn.textContent = '×';
    closeBtn.addEventListener('click', () => toast.remove());

    toast.append(iconSpan, messageSpan, closeBtn);

    // Add to container
    container.appendChild(toast);

    // Trigger entrance animation
    requestAnimationFrame(() => {
        toast.classList.add('toast-visible');
    });

    // Auto-remove after duration (unless duration is 0)
    if (duration > 0) {
        setTimeout(() => {
            toast.classList.remove('toast-visible');
            setTimeout(() => toast.remove(), 300);
        }, duration);
    }

    return toast;
}

/**
 * Check plan document existence cache (XACA-0045-006)
 * @param {string} itemId - The kanban item ID
 * @returns {boolean|null} - true/false if cached and fresh, null if cache miss/expired
 */
function getPlanDocExistsFromCache(itemId) {
    const cached = planDocExistsCache.get(itemId);
    if (cached && (Date.now() - cached.timestamp) < 60000) {
        return cached.exists;
    }
    return null; // Cache miss or expired
}

/**
 * Set plan document existence cache (XACA-0045-006)
 * @param {string} itemId - The kanban item ID
 * @param {boolean} exists - Whether the plan doc exists
 */
function setPlanDocExistsCache(itemId, exists) {
    planDocExistsCache.set(itemId, {
        exists: exists,
        timestamp: Date.now()
    });
}

/**
 * Clear plan document existence cache (XACA-0045-006)
 * Called when board data is refreshed to ensure cache coherency
 */
function clearPlanDocExistsCache() {
    planDocExistsCache.clear();
}

/**
 * Calculate optimal viewport position for a popup element (XACA-0053-001)
 * Detects viewport boundaries and adjusts position to prevent clipping by screen edges
 *
 * @param {Object} element - Popup element or object with width/height properties
 * @param {number} preferredX - Preferred X coordinate (absolute position)
 * @param {number} preferredY - Preferred Y coordinate (absolute position)
 * @param {Object} options - Configuration options
 * @param {number} options.padding - Minimum padding from viewport edges (default: 10)
 * @param {boolean} options.flipVertical - Allow vertical flip if needed (default: true)
 * @param {boolean} options.flipHorizontal - Allow horizontal flip if needed (default: true)
 * @param {number} options.triggerHeight - Height of trigger element for flip calculation (default: 0)
 * @param {number} options.triggerWidth - Width of trigger element for flip calculation (default: 0)
 * @returns {Object} - Adjusted position { x, y, flippedVertical, flippedHorizontal }
 */
function calculateViewportPosition(element, preferredX, preferredY, options = {}) {
    // Default options
    const {
        padding = 10,
        flipVertical = true,
        flipHorizontal = true,
        triggerHeight = 0,
        triggerWidth = 0
    } = options;

    // Get element dimensions
    const elementWidth = element.offsetWidth || element.width || 0;
    const elementHeight = element.offsetHeight || element.height || 0;

    // Get viewport dimensions and scroll position
    const viewportWidth = window.innerWidth;
    const viewportHeight = window.innerHeight;
    const scrollX = window.scrollX || window.pageXOffset;
    const scrollY = window.scrollY || window.pageYOffset;

    // Calculate viewport boundaries (in absolute coordinates)
    const viewportLeft = scrollX + padding;
    const viewportRight = scrollX + viewportWidth - padding;
    const viewportTop = scrollY + padding;
    const viewportBottom = scrollY + viewportHeight - padding;

    // Start with preferred position
    let adjustedX = preferredX;
    let adjustedY = preferredY;
    let flippedVertical = false;
    let flippedHorizontal = false;

    // Check horizontal boundaries
    if (adjustedX + elementWidth > viewportRight) {
        if (flipHorizontal && triggerWidth > 0) {
            // Try flipping to the left of trigger
            const flippedX = preferredX - elementWidth - triggerWidth;
            if (flippedX >= viewportLeft) {
                adjustedX = flippedX;
                flippedHorizontal = true;
            } else {
                // Can't flip, just constrain to viewport
                adjustedX = Math.max(viewportLeft, viewportRight - elementWidth);
            }
        } else {
            // Just constrain to viewport right
            adjustedX = viewportRight - elementWidth;
        }
    }

    if (adjustedX < viewportLeft) {
        adjustedX = viewportLeft;
    }

    // Check vertical boundaries
    if (adjustedY + elementHeight > viewportBottom) {
        if (flipVertical && triggerHeight > 0) {
            // Try flipping above trigger
            const flippedY = preferredY - elementHeight - triggerHeight;
            if (flippedY >= viewportTop) {
                adjustedY = flippedY;
                flippedVertical = true;
            } else {
                // Can't flip, just constrain to viewport
                adjustedY = Math.max(viewportTop, viewportBottom - elementHeight);
            }
        } else {
            // Just constrain to viewport bottom
            adjustedY = viewportBottom - elementHeight;
        }
    }

    if (adjustedY < viewportTop) {
        adjustedY = viewportTop;
    }

    return {
        x: adjustedX,
        y: adjustedY,
        flippedVertical,
        flippedHorizontal
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// DATA LOADING
// ═══════════════════════════════════════════════════════════════════════════════

async function loadBoardData() {
    try {
        // Clear plan doc cache on refresh (XACA-0045-006)
        clearPlanDocExistsCache();

        // Preserve expansion states before refresh
        const expansionStates = {};
        if (boardData && boardData.backlog) {
            boardData.backlog.forEach(item => {
                if (item.title && item.collapsed !== undefined) {
                    expansionStates[item.title] = item.collapsed;
                }
            });
        }

        const response = await fetch(CONFIG.dataPath);
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        boardData = await response.json();

        // XACA-0056: Also fetch archived releases for release name lookups
        // Items assigned to archived releases need to display the correct shortTitle
        try {
            const archivedResponse = await fetch(apiUrl('/api/releases?status=archived'));
            if (archivedResponse.ok) {
                const archivedData = await archivedResponse.json();
                boardData.archivedReleases = archivedData.releases || [];
            }
        } catch (e) {
            console.log('Could not load archived releases:', e);
            boardData.archivedReleases = [];
        }

        // Restore expansion states after refresh
        if (boardData && boardData.backlog) {
            boardData.backlog.forEach(item => {
                if (item.title && expansionStates.hasOwnProperty(item.title)) {
                    item.collapsed = expansionStates[item.title];
                }
            });
        }

        renderBoard();
        updateTimestamp();
        return true;
    } catch (error) {
        console.error('Error loading board data:', error);
        loadEmbeddedData();
        return false;
    }
}

function loadEmbeddedData() {
    boardData = {
        team: "freelance",
        ship: "Enterprise NX-01",
        series: "ENT",
        lastUpdated: new Date().toISOString(),
        terminals: {
            command: { developer: "Captain Jonathan Archer", role: "Lead Feature Developer", color: "command" },
            engineering: { developer: "Commander Trip Tucker", role: "Release Engineer", color: "operations" },
            science: { developer: "Sub-Commander T'Pol", role: "Lead Refactoring Developer", color: "science" },
            sickbay: { developer: "Dr. Phlox", role: "Bug Fix Developer", color: "medical" },
            tactical: { developer: "Lt. Malcolm Reed", role: "Security & Testing Lead", color: "operations" },
            comms: { developer: "Ensign Hoshi Sato", role: "Documentation Expert", color: "science" },
            helm: { developer: "Ensign Travis Mayweather", role: "UX Expert", color: "operations" }
        },
        activeWindows: [],
        backlog: []
    };
    renderBoard();
}

// ═══════════════════════════════════════════════════════════════════════════════
// RENDERING
// ═══════════════════════════════════════════════════════════════════════════════

function renderBoard() {
    if (!boardData) return;

    renderShipInfo();
    renderKanbanColumns();
    renderTerminalDetails();
    renderMissionBacklog();
    populateEpicFilterOptions();
    populateReleaseFilterOptions();
    populateCRFilterOptions();
    updateStardate();
    updateContentWatermark();

    // Render calendar if calendar section is active
    if (activeSection === 'calendar') {
        renderCalendar();
    }

    // Render home analytics if home section is active
    if (activeSection === 'home') {
        renderHomeAnalytics();
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// HOME CAROUSEL
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Navigate to a specific carousel panel by index.
 * Clamps index to valid range [0, TOTAL_HOME_PANELS-1] with wraparound.
 * Updates track transform, dot/panel active classes, and resets auto-advance timer.
 */
function navigateToPanel(logicalIndex) {
    // Build the ordered list of visible (non-hidden) panels — XACA-0164-008
    // When homeFullscreen is active, ALL panels are visible regardless of mode.
    const visiblePanels = Array.from(document.querySelectorAll('.carousel-panel'))
        .filter(p => !p.classList.contains('hidden-by-mode'));

    const visibleCount = visiblePanels.length;

    // With no visible panels (e.g. TEAM mode), nothing to do
    if (visibleCount === 0) {
        currentLogicalPanel = 0;
        currentHomePanel = 0;
        return;
    }

    // Wrap around within the visible set
    if (logicalIndex < 0) {
        logicalIndex = visibleCount - 1;
    } else if (logicalIndex >= visibleCount) {
        logicalIndex = 0;
        // Refresh RAG engine data on carousel wrap-around (once per full cycle)
        _refreshRAGEnginePanels();
    }

    // Resolve physical panel index from the visible panel at this logical position
    const targetPanel = visiblePanels[logicalIndex];
    const physicalIndex = parseInt(targetPanel.dataset.panelIndex, 10);

    // If leaving a knowledge/adoption panel (4 or 5), cancel any pending debounce
    // or in-flight fetch so the async continuation cannot inject stale DOM content.
    // Both panels share the same /api/knowledge-stats fetch infrastructure.
    const leavingKnowledgePanel = (currentHomePanel === 4 || currentHomePanel === 5)
        && (physicalIndex !== 4 && physicalIndex !== 5);
    if (leavingKnowledgePanel) {
        if (_knowledgeDebounceTimer !== null) {
            clearTimeout(_knowledgeDebounceTimer);
            _knowledgeDebounceTimer = null;
        }
        if (_knowledgeAbortController !== null) {
            _knowledgeAbortController.abort();
            _knowledgeAbortController = null;
        }
    }

    // If leaving the Estimation Accuracy panel (6), cancel its in-flight fetch — XACA-0630
    if (currentHomePanel === 6 && physicalIndex !== 6 && window.LCARSEstimates) {
        window.LCARSEstimates.cancelFetch();
    }

    currentLogicalPanel = logicalIndex;
    currentHomePanel = physicalIndex;

    // Slide the track using logical position (visible panels occupy sequential flex slots)
    const track = document.querySelector('.carousel-track');
    if (track) {
        track.style.transform = `translateX(-${logicalIndex * 100}%)`;
    }

    // Update active dot (dots are rebuilt to match only visible panels, so dot index = logical index)
    document.querySelectorAll('.carousel-dot:not(.hidden-by-mode)').forEach((dot, i) => {
        dot.classList.toggle('active', i === logicalIndex);
    });

    // Update active panel (among visible panels only)
    visiblePanels.forEach((panel, i) => {
        panel.classList.toggle('active', i === logicalIndex);
    });

    // Lazy-render panel content (always re-render on navigate for fresh data;
    // the _renderHome* functions handle create-vs-update via homeCharts checks)
    renderHomePanel(physicalIndex);

    // Trigger chart resize for the newly visible panel after CSS transition completes
    // Chart.js canvases need explicit resize when their container transitions from hidden
    // Scope to only the target panel's charts to avoid unnecessary work
    const panelChartKeys = {
        0: [],
        1: ['statusDoughnut'],
        2: [],
        3: ['subitemDoughnut'],
        4: ['knowledgeDoughnut'],
        5: []
    };
    setTimeout(() => {
        (panelChartKeys[physicalIndex] || []).forEach(key => {
            if (homeCharts[key]) {
                homeCharts[key].resize();
            }
        });
    }, 50);

    // Reset auto-advance timer so panel gets its full 30 seconds
    _resetCarouselAutoTimer();
}

/**
 * Start the 30-second auto-advance timer.
 * Advances to next panel (with wraparound) unless paused.
 */
function _startCarouselAutoTimer() {
    _stopCarouselAutoTimer();
    carouselAutoTimer = setInterval(() => {
        if (!carouselPaused) {
            navigateToPanel(currentLogicalPanel + 1);
        }
    }, CAROUSEL_AUTO_INTERVAL);
}

/**
 * Stop the auto-advance timer.
 */
function _stopCarouselAutoTimer() {
    if (carouselAutoTimer) {
        clearInterval(carouselAutoTimer);
        carouselAutoTimer = null;
    }
}

/**
 * Reset auto-advance timer to give current panel a fresh 30 seconds.
 */
function _resetCarouselAutoTimer() {
    if (carouselAutoTimer !== null) {
        _startCarouselAutoTimer();
    }
}

/**
 * Initialize the carousel: set up event listeners, activate first panel,
 * start auto-advance timer. Safe to call multiple times (idempotent).
 */
function initCarousel() {
    if (carouselInitialized) {
        // Already initialized — re-apply mode filter and reset to panel 0
        applyCarouselModeFilter(activeMode, homeFullscreen);
        _startCarouselAutoTimer();
        return;
    }

    carouselInitialized = true;

    // Prev/Next arrow buttons
    const prevBtn = document.getElementById('carousel-prev');
    const nextBtn = document.getElementById('carousel-next');

    if (prevBtn) {
        prevBtn.addEventListener('click', () => {
            navigateToPanel(currentLogicalPanel - 1);
        });
    }

    if (nextBtn) {
        nextBtn.addEventListener('click', () => {
            navigateToPanel(currentLogicalPanel + 1);
        });
    }

    // Pause auto-advance when user hovers over viewport
    const viewport = document.querySelector('.carousel-viewport');
    if (viewport) {
        viewport.addEventListener('mouseenter', () => {
            carouselPaused = true;
        });

        viewport.addEventListener('mouseleave', () => {
            carouselPaused = false;
        });
    }

    // Fullscreen button
    const fsBtn = document.getElementById('carousel-fullscreen');
    if (fsBtn) {
        fsBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            toggleHomeFullscreen();
        });
    }

    // Fetch RAG engine data for dynamic panels
    _refreshRAGEnginePanels();

    // Apply mode filter before generating dots — panels tagged data-home-mode get hidden-by-mode
    // applied immediately so the initial dot build and navigateToPanel(0) see the right set
    // XACA-0164-008
    applyCarouselModeFilter(activeMode, homeFullscreen);

    // applyCarouselModeFilter calls _rebuildCarouselDots and navigateToPanel(0), so no need
    // to call them again. Just start the timer.
    _startCarouselAutoTimer();
}

/**
 * Stop carousel auto-advance (called when leaving HOME tab).
 * Also cancels any in-flight knowledge-panel fetch so stale async
 * continuations cannot inject DOM content after the HOME tab is hidden.
 */
function stopCarousel() {
    _stopCarouselAutoTimer();
    carouselPaused = false;
    // Cancel any pending knowledge-panel debounce or fetch
    if (_knowledgeDebounceTimer !== null) {
        clearTimeout(_knowledgeDebounceTimer);
        _knowledgeDebounceTimer = null;
    }
    if (_knowledgeAbortController !== null) {
        _knowledgeAbortController.abort();
        _knowledgeAbortController = null;
    }
    // Exit fullscreen when leaving HOME tab
    if (homeFullscreen) _exitHomeFullscreen();
    // Cancel any pending RAG engine fetch
    if (_ragAbortController) {
        _ragAbortController.abort();
        _ragAbortController = null;
    }
    // Cancel any pending Estimation Accuracy panel fetch — XACA-0630
    if (window.LCARSEstimates) {
        window.LCARSEstimates.cancelFetch();
    }
}

/**
 * Fetch RAG engine summary and dynamically update carousel panels.
 * Called on HOME tab init and periodically to detect engine changes.
 */
async function _refreshRAGEnginePanels() {
    // Abort any prior in-flight fetch
    if (_ragAbortController) _ragAbortController.abort();
    _ragAbortController = new AbortController();

    try {
        const resp = await fetch('/api/rag-engines/summary', {
            signal: _ragAbortController.signal
        });
        if (!resp.ok) return;
        const data = await resp.json();

        const engines = (data.engines || []).filter(e => e.status === 'running' || e.status === 'installed');

        // Only rebuild if engine count changed
        if (engines.length !== ragEnginePanelCount) {
            ragEngineData = engines;
            ragEnginePanelCount = engines.length;
            TOTAL_HOME_PANELS = 7 + ragEnginePanelCount;
            _rebuildRAGPanelsDOM(engines);
            _rebuildCarouselDots();
        } else {
            // Just update data for re-render
            ragEngineData = engines;
        }
    } catch (e) {
        if (e.name !== 'AbortError') {
            console.warn('[RAG Carousel] Failed to fetch engine summary:', e.message);
        }
    }
}

/**
 * Rebuild the RAG engine panel DOM elements inside #rag-engine-panels-container.
 * Security: all dynamic string values use DOM API (textContent, dataset) — no innerHTML.
 */
function _rebuildRAGPanelsDOM(engines) {
    const container = document.getElementById('rag-engine-panels-container');
    if (!container) return;
    container.textContent = '';

    engines.forEach((engine, i) => {
        const panelIndex = 7 + i;
        const typeLabel = (engine.type || '').toUpperCase().replace(/-/g, ' ');
        const statusClass = engine.status === 'running' ? 'rag-status-running' :
                           engine.status === 'installed' ? 'rag-status-installed' : 'rag-status-offline';

        // Build panel via DOM API to avoid innerHTML with untrusted data
        const panel = document.createElement('div');
        panel.className = 'carousel-panel';
        panel.dataset.panelIndex = panelIndex;
        panel.dataset.homeMode = 'data'; // RAG engine panels belong to DATA mode — XACA-0164-008

        const header = document.createElement('div');
        header.className = 'section-header cyan';

        const title = document.createElement('span');
        title.className = 'section-title';
        title.textContent = (engine.name || engine.id) + ' ENGINE';

        const bar = document.createElement('div');
        bar.className = 'section-bar';

        header.appendChild(title);
        header.appendChild(bar);

        const content = document.createElement('div');
        content.className = 'rag-engine-panel-content';
        content.dataset.engineId = engine.id;

        const statusRow = document.createElement('div');
        statusRow.className = 'rag-engine-status-row';

        const indicator = document.createElement('span');
        indicator.className = 'rag-status-indicator ' + statusClass;

        const statusLabel = document.createElement('span');
        statusLabel.className = 'rag-status-label';
        statusLabel.textContent = (engine.status || 'unknown').toUpperCase();

        const typeBadge = document.createElement('span');
        typeBadge.className = 'rag-type-badge';
        typeBadge.textContent = typeLabel;

        statusRow.appendChild(indicator);
        statusRow.appendChild(statusLabel);
        statusRow.appendChild(typeBadge);

        if (engine.port) {
            const portLabel = document.createElement('span');
            portLabel.className = 'rag-port-label';
            portLabel.textContent = 'PORT ' + engine.port;
            statusRow.appendChild(portLabel);
        }

        const statsGrid = document.createElement('div');
        statsGrid.className = 'rag-engine-stats-grid';
        statsGrid.id = 'rag-stats-' + engine.id;

        content.appendChild(statusRow);
        content.appendChild(statsGrid);

        panel.appendChild(header);
        panel.appendChild(content);
        container.appendChild(panel);
    });
}

/**
 * Rebuild carousel dots to match current TOTAL_HOME_PANELS count.
 * Dots are created for ALL panels, then hidden-by-mode is applied for filtered-out ones.
 * Only visible dots get click handlers that use logical indices — XACA-0164-008.
 */
function _rebuildCarouselDots() {
    const dotsContainer = document.getElementById('carousel-dots');
    if (!dotsContainer) return;
    dotsContainer.textContent = '';

    // Collect all panels and the visible subset for logical → physical mapping
    const allPanels = Array.from(document.querySelectorAll('.carousel-panel'));
    const visiblePanels = allPanels.filter(p => !p.classList.contains('hidden-by-mode'));

    for (let i = 0; i < TOTAL_HOME_PANELS; i++) {
        const dot = document.createElement('span');
        const panel = allPanels[i];
        const isHidden = panel && panel.classList.contains('hidden-by-mode');

        const logicalIndex = visiblePanels.indexOf(panel);
        dot.className = 'carousel-dot' + (!isHidden && logicalIndex === currentLogicalPanel ? ' active' : '') + (isHidden ? ' hidden-by-mode' : '');
        dot.dataset.panel = i;
        if (!isHidden && logicalIndex !== -1) {
            dot.addEventListener('click', () => navigateToPanel(logicalIndex));
        }
        dotsContainer.appendChild(dot);
    }
}


/**
 * Apply carousel mode filter — show only panels matching activeMode (or all when fullscreen).
 * Toggles .hidden-by-mode on panels and dots, rebuilds dot active state,
 * and navigates to the first visible panel. — XACA-0164-008
 *
 * @param {string} mode - The current active mode ('kanban', 'data', 'team', 'settings')
 * @param {boolean} [showAll=false] - When true (VIEWSCREEN), show all panels regardless of mode
 */
function applyCarouselModeFilter(mode, showAll) {
    const allPanels = document.querySelectorAll('.carousel-panel');
    allPanels.forEach(panel => {
        if (showAll) {
            panel.classList.remove('hidden-by-mode');
        } else {
            const panelMode = panel.dataset.homeMode;
            if (panelMode && panelMode !== mode) {
                panel.classList.add('hidden-by-mode');
            } else {
                panel.classList.remove('hidden-by-mode');
            }
        }
    });

    // Rebuild dots to reflect updated visibility
    _rebuildCarouselDots();

    // Reset to first visible panel
    currentLogicalPanel = 0;
    navigateToPanel(0);
}

/**
 * Toggle fullscreen mode for the HOME dashboard.
 * Uses the browser Fullscreen API for true device fullscreen (hides browser chrome,
 * dock, menubar — the works). Also adds .home-fullscreen class to hide LCARS chrome.
 */
function toggleHomeFullscreen() {
    if (homeFullscreen) {
        _exitHomeFullscreen();
        return;
    }

    // VIEWSCREEN always shows HOME tab content — switch there first if needed.
    // Use skipAnimation=true so the transition is instant before fullscreen kicks in.
    if (activeSection !== 'home') {
        switchSection('home', true);
    }

    // Ensure home section is active before entering fullscreen.
    // switchSection uses setTimeout for entrance — force it synchronously here
    // so the Fullscreen API captures the HOME content, not the previous tab.
    const homeEl = document.querySelector('.home-section');
    if (homeEl) homeEl.classList.add('active');

    const container = document.querySelector('.lcars-container');
    if (!container) return;

    homeFullscreen = true;
    container.classList.add('home-fullscreen');

    // VIEWSCREEN shows ALL panels regardless of mode — XACA-0164-008
    applyCarouselModeFilter(activeMode, true /* showAll */);

    // Request true device fullscreen via Fullscreen API
    const el = document.documentElement;
    const requestFS = el.requestFullscreen || el.webkitRequestFullscreen || el.mozRequestFullScreen || el.msRequestFullscreen;
    if (requestFS) {
        requestFS.call(el).catch(() => {
            // Fullscreen API blocked (e.g. iframe sandbox) — CSS-only fallback still works
        });
    }

    // Resize charts after fullscreen transition settles
    setTimeout(_resizeHomeCharts, 200);

    // Any click/tap exits fullscreen (added on next frame to avoid immediate trigger)
    requestAnimationFrame(() => {
        document.addEventListener('click', _fullscreenClickHandler, { once: true, capture: true });
    });
}

/**
 * Handle click to exit fullscreen. Ignores clicks on carousel controls.
 */
function _fullscreenClickHandler(e) {
    // Let carousel nav buttons work without exiting
    if (e.target.closest('.carousel-arrow') || e.target.closest('.carousel-dot')) {
        requestAnimationFrame(() => {
            document.addEventListener('click', _fullscreenClickHandler, { once: true, capture: true });
        });
        return;
    }
    _exitHomeFullscreen();
}

/**
 * Exit fullscreen mode — exits browser fullscreen and restores normal LCARS layout.
 */
function _exitHomeFullscreen() {
    const container = document.querySelector('.lcars-container');
    if (!container) return;

    homeFullscreen = false;
    container.classList.remove('home-fullscreen');
    document.removeEventListener('click', _fullscreenClickHandler, { capture: true });

    // Exit browser fullscreen if active
    const exitFS = document.exitFullscreen || document.webkitExitFullscreen || document.mozCancelFullScreen || document.msExitFullscreen;
    if (exitFS && document.fullscreenElement) {
        exitFS.call(document);
    }

    // Re-apply mode filter now that we're back to normal HOME (not VIEWSCREEN) — XACA-0164-008
    applyCarouselModeFilter(activeMode, false);

    // Force full re-render of current panel after layout settles.
    // Simple resize() doesn't always work because Chart.js caches fullscreen dimensions.
    // Destroying and re-creating via renderHomePanel ensures correct sizing.
    // Double-tap: re-render at 300ms, then resize at 600ms as safety net.
    setTimeout(() => {
        renderHomePanel(currentHomePanel);
        setTimeout(_resizeHomeCharts, 300);
    }, 300);
}

/**
 * Listen for browser-level fullscreen exit (e.g. user presses Escape natively).
 * Syncs our state if the browser exits fullscreen without going through our handler.
 */
document.addEventListener('fullscreenchange', () => {
    if (!document.fullscreenElement && homeFullscreen) {
        homeFullscreen = false;
        const container = document.querySelector('.lcars-container');
        if (container) container.classList.remove('home-fullscreen');
        document.removeEventListener('click', _fullscreenClickHandler, { capture: true });
        // Re-apply mode filter on browser-native fullscreen exit — XACA-0164-008
        applyCarouselModeFilter(activeMode, false);
        setTimeout(() => { renderHomePanel(currentHomePanel); }, 300);
    }
});

/**
 * Keyboard handlers for fullscreen mode:
 * - Escape: exit fullscreen (CSS-only fallback for iTerm2/embedded WebKit)
 * - ArrowLeft/ArrowRight: navigate panels (replaces hidden arrow buttons)
 */
document.addEventListener('keydown', (e) => {
    if (!homeFullscreen) return;
    if (e.repeat) return; // Ignore key auto-repeat to prevent skipping panels

    if (e.key === 'Escape') {
        _exitHomeFullscreen();
    } else if (e.key === 'ArrowLeft') {
        e.preventDefault();
        navigateToPanel(currentLogicalPanel - 1);
    } else if (e.key === 'ArrowRight') {
        e.preventDefault();
        navigateToPanel(currentLogicalPanel + 1);
    }
});

/**
 * Resize all active home charts (used after fullscreen transitions).
 */
function _resizeHomeCharts() {
    Object.values(homeCharts).forEach(chart => {
        if (chart && typeof chart.resize === 'function') chart.resize();
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// HOME ANALYTICS
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Destroy any orphaned Chart.js instance on a canvas before re-creating.
 * Prevents memory leaks when a previous createChart call succeeded but
 * the reference wasn't stored (e.g., null guard path).
 */
function _destroyOrphanedChart(canvasId) {
    const canvas = document.getElementById(canvasId);
    if (canvas && typeof Chart !== 'undefined') {
        const existing = Chart.getChart(canvas);
        if (existing) existing.destroy();
    }
}

/**
 * Renders the analytics content for a single carousel panel.
 * Lazy-initializes chart panels — each _renderHome* function handles
 * create-vs-update internally via homeCharts instance checks.
 *
 * Panel mapping:
 *   0 — MISSION STATUS       : summary metrics (2x2 grid)
 *   1 — MISSION CHARTS       : status doughnut + completion bar
 *   2 — EPIC PROGRESS        : epic progress bars
 *   3 — SUBITEM INTEL        : subitem statistics doughnut
 *   4 — KNOWLEDGE BASE       : knowledge file doughnut + summary metrics
 *   5 — RETRO COVERAGE       : retrospective adoption coverage bar + per-team breakdown
 *   6 — ESTIMATION ACCURACY  : estimate-vs-actual handicap analytics (XACA-0630)
 *   7+ — Dynamic RAG engine panels
 *
 * @param {number} panelIndex - The carousel panel index to render (0–6 static, 7+ dynamic).
 */
function renderHomePanel(panelIndex) {
    if (!boardData) return;

    // Defense-in-depth: destroy existing charts before re-init to prevent
    // orphaned Chart.js instances accumulating across board refreshes.
    // The individual render functions use LCARSCharts.updateChart() when
    // homeCharts[key] is non-null, so we only destroy on intentional re-init.
    Object.keys(homeCharts).forEach(key => {
        if (homeCharts[key] && typeof homeCharts[key].destroy === 'function') {
            homeCharts[key].destroy();
            homeCharts[key] = null;
        }
    });

    const backlog = boardData.backlog || [];
    const epics   = boardData.epics   || [];

    switch (panelIndex) {
        case 0:
            _renderHomeSummaryMetrics(backlog);
            break;
        case 1:
            _renderHomeStatusDoughnut(backlog);
            _renderHomeCompletionBar(backlog);
            break;
        case 2:
            _renderHomeEpicProgress(backlog, epics);
            break;
        case 3:
            _renderHomeSubitemStats(backlog);
            break;
        case 4:
            _renderHomeKnowledgeStats();
            break;
        case 5:
            _renderHomeAdoptionStats();
            break;
        case 6:
            // ESTIMATION ACCURACY panel (XACA-0630)
            if (window.LCARSEstimates) {
                window.LCARSEstimates.renderPanel();
            }
            break;
        default:
            // Dynamic RAG engine panels (index 7+)
            if (panelIndex >= 7 && panelIndex < 7 + ragEnginePanelCount) {
                _renderHomeRAGPanel(panelIndex - 7);
            }
            break;
    }
}

/**
 * Entry point for HOME tab analytics rendering.
 * Only renders the currently visible carousel panel (lazy initialization).
 * Navigation to other panels triggers their rendering via navigateToPanel().
 * On board data refresh, re-renders the active panel with updated data.
 */
function renderHomeAnalytics() {
    if (!boardData) return;
    renderHomePanel(currentHomePanel);
}

/**
 * Populate #home-summary-metrics with LCARS-styled metric cards.
 * Shows: TOTAL ITEMS, COMPLETED, IN PROGRESS, COMPLETION RATE
 */
function _renderHomeSummaryMetrics(backlog) {
    const container = document.getElementById('home-summary-metrics');
    if (!container) return;

    const total       = backlog.length;
    const completed   = backlog.filter(i => i.status === 'completed').length;
    const inProgress  = backlog.filter(i => i.status === 'in_progress' || i.status === 'coding' || i.status === 'planning' || i.status === 'testing' || i.status === 'commit' || i.status === 'pr_review').length;
    const rate        = total > 0 ? Math.round((completed / total) * 100) : 0;

    const metrics = [
        { value: total,         label: 'TOTAL ITEMS',    color: '#99CCFF' },
        { value: completed,     label: 'COMPLETED',      color: '#99CC99' },
        { value: inProgress,    label: 'IN PROGRESS',    color: '#FFCC99' },
        { value: rate + '%',    label: 'COMPLETION RATE', color: '#CC99CC' }
    ];

    container.innerHTML = metrics.map(m => `
        <div class="summary-card lcars-fade-in-up" style="background: rgba(0,0,0,0.35); border-radius: 12px; padding: 20px 16px; text-align: center; border-left: 4px solid ${m.color}; display: flex; flex-direction: column; justify-content: center; align-items: center;">
            <div class="summary-value" style="font-family: 'Antonio', sans-serif; font-size: 48px; font-weight: 700; color: ${m.color}; line-height: 1;">${m.value}</div>
            <div class="summary-label" style="font-family: 'Antonio', sans-serif; font-size: 13px; color: rgba(255,204,153,0.65); margin-top: 8px; letter-spacing: 0.12em;">${m.label}</div>
        </div>
    `).join('');
}

/**
 * Render status distribution doughnut chart in #home-status-doughnut.
 * Counts items by status and maps colors via LCARSCharts.statusColors.
 */
function _renderHomeStatusDoughnut(backlog) {
    // Count items per status, normalizing undefined/null to 'backlog'
    const counts = {};
    backlog.forEach(item => {
        const s = item.status || 'backlog';
        counts[s] = (counts[s] || 0) + 1;
    });

    // Sort by count descending for a cleaner chart
    const entries  = Object.entries(counts).sort((a, b) => b[1] - a[1]);
    const labels   = entries.map(([s]) => s.toUpperCase().replace(/_/g, ' '));
    const data     = entries.map(([, c]) => c);
    const bgColors = entries.map(([s]) => LCARSCharts.statusColors[s] || LCARSCharts.colors.tan);

    const chartData = {
        labels,
        datasets: [{
            data,
            backgroundColor: bgColors,
            borderColor:      LCARSCharts.colors.background,
            borderWidth:      2,
            hoverBorderColor: LCARSCharts.colors.tan,
            hoverBorderWidth: 3
        }]
    };

    if (homeCharts.statusDoughnut) {
        LCARSCharts.updateChart(homeCharts.statusDoughnut, chartData);
    } else {
        _destroyOrphanedChart('home-status-doughnut');
        homeCharts.statusDoughnut = LCARSCharts.createDoughnut('home-status-doughnut', chartData, {
            maintainAspectRatio: false,
            responsive: true
        });
    }
}

/**
 * Render LCARS-styled horizontal bars showing completed vs active vs pending
 * vs cancelled in #home-completion-bars.
 *
 * Uses pure HTML/CSS instead of Chart.js — more reliable and fits the LCARS
 * aesthetic naturally. Chart.js bar charts were persistently blank in this
 * carousel context despite multiple approaches.
 */
function _renderHomeCompletionBar(backlog) {
    const container = document.getElementById('home-completion-bars');
    if (!container) return;

    const total     = backlog.length;
    const completed = backlog.filter(i => i.status === 'completed').length;
    const cancelled = backlog.filter(i => i.status === 'cancelled').length;
    const active    = backlog.filter(i => i.status && i.status !== 'completed' && i.status !== 'cancelled').length;
    const pending   = total - completed - cancelled - active;
    const maxVal    = Math.max(completed, active, pending, cancelled, 1);

    const bars = [
        { label: 'COMPLETED', value: completed, color: '#99CC99' },
        { label: 'ACTIVE',    value: active,    color: '#99CCFF' },
        { label: 'PENDING',   value: pending > 0 ? pending : 0, color: '#FFCC99' },
        { label: 'CANCELLED', value: cancelled, color: '#CC6666' }
    ];

    container.innerHTML = bars.map(b => {
        const pct = maxVal > 0 ? Math.round((b.value / maxVal) * 100) : 0;
        return `
            <div style="display: flex; align-items: center; gap: 10px;">
                <div style="width: 90px; font-family: 'Antonio', sans-serif; font-size: 11px; color: rgba(255,204,153,0.65); text-align: right; letter-spacing: 0.05em; flex-shrink: 0;">${b.label}</div>
                <div style="flex: 1; height: 20px; background: rgba(255,204,153,0.08); border-radius: 4px; overflow: hidden;">
                    <div style="height: 100%; width: ${pct}%; background: ${b.color}; border-radius: 4px; transition: width 0.6s ease;"></div>
                </div>
                <div style="width: 30px; font-family: 'Antonio', sans-serif; font-size: 13px; color: ${b.color}; text-align: right; flex-shrink: 0;">${b.value}</div>
            </div>
        `;
    }).join('');
}

/**
 * Render animated horizontal progress bars for each epic in #home-epic-progress.
 * Counts how many of each epic's itemIds have status === 'completed'.
 */
function _renderHomeEpicProgress(backlog, epics) {
    const container = document.getElementById('home-epic-progress');
    if (!container) return;

    if (epics.length === 0) {
        container.innerHTML = `<div style="color: rgba(255,204,153,0.45); font-family: 'Antonio', sans-serif; font-size: 13px; text-align: center; padding: 20px 0;">NO EPICS DEFINED</div>`;
        return;
    }

    // Build a quick lookup from item ID to status
    const itemStatusMap = {};
    backlog.forEach(item => {
        itemStatusMap[item.id] = item.status || 'backlog';
    });

    const rows = epics.map(epic => {
        const ids       = epic.itemIds || [];
        // Exclude cancelled items from the denominator (XACA-0206 parity).
        // An epic with only cancelled items has nothing left to do — show 100%.
        const activeIds  = ids.filter(id => itemStatusMap[id] !== 'cancelled');
        const cancelled  = ids.length - activeIds.length;
        const epicTotal  = activeIds.length;
        const done       = activeIds.filter(id => itemStatusMap[id] === 'completed').length;
        const pct        = epicTotal > 0 ? Math.round((done / epicTotal) * 100) : 100;
        const cancelTag  = cancelled > 0 ? ` <span style="color:var(--lcars-red);">(${cancelled} cx)</span>` : '';
        const title      = (epic.title || epic.name || epic.id || 'UNKNOWN').toUpperCase();

        // Color based on completion percentage
        let barColor;
        if (pct >= 100) {
            barColor = `linear-gradient(90deg, ${LCARSCharts.colors.green}, #66CC99)`;
        } else if (pct >= 60) {
            barColor = `linear-gradient(90deg, ${LCARSCharts.colors.cyan}, ${LCARSCharts.colors.blue})`;
        } else if (pct >= 30) {
            barColor = `linear-gradient(90deg, ${LCARSCharts.colors.orange}, ${LCARSCharts.colors.tan})`;
        } else {
            barColor = `linear-gradient(90deg, ${LCARSCharts.colors.purple}, ${LCARSCharts.colors.blue})`;
        }

        return `
            <div class="epic-progress-row" style="margin-bottom: 8px;">
                <div style="display: flex; justify-content: space-between; align-items: baseline; color: #FFCC99; font-family: 'Antonio', sans-serif; font-size: 13px; margin-bottom: 5px;">
                    <span style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 75%;">${escapeHtml(title)}</span>
                    <span style="color: rgba(255,204,153,0.7); font-size: 12px; flex-shrink: 0; margin-left: 8px;">${done}/${epicTotal}${cancelTag} &bull; ${pct}%</span>
                </div>
                <div style="background: rgba(255,255,255,0.08); border-radius: 4px; height: 10px; overflow: hidden;">
                    <div style="background: ${barColor}; height: 100%; width: ${pct}%; border-radius: 4px; transition: width 1s ease;"></div>
                </div>
            </div>
        `;
    });

    container.innerHTML = rows.join('');
}

/**
 * Render subitem tracking doughnut (#home-subitem-doughnut) and text metrics (#home-subitem-metrics).
 * Counts all subitems across all items by status (completed vs everything else).
 */
function _renderHomeSubitemStats(backlog) {
    const metricsEl = document.getElementById('home-subitem-metrics');

    // Gather all subitems from all items
    let totalSubs     = 0;
    let completedSubs = 0;
    let cancelledSubs = 0;
    let activeSubs    = 0;

    backlog.forEach(item => {
        if (!item.subitems || !Array.isArray(item.subitems)) return;
        item.subitems.forEach(sub => {
            totalSubs++;
            const s = sub.status || 'todo';
            if (s === 'completed') {
                completedSubs++;
            } else if (s === 'cancelled') {
                cancelledSubs++;
            } else if (s === 'in_progress' || s === 'started') {
                activeSubs++;
            }
        });
    });

    const pendingSubs = totalSubs - completedSubs - cancelledSubs - activeSubs;
    const subRate     = totalSubs > 0 ? Math.round((completedSubs / totalSubs) * 100) : 0;

    // Doughnut chart: completed / active / pending / cancelled
    const chartData = {
        labels: ['COMPLETED', 'ACTIVE', 'PENDING', 'CANCELLED'],
        datasets: [{
            data: [completedSubs, activeSubs, pendingSubs > 0 ? pendingSubs : 0, cancelledSubs],
            backgroundColor: [
                LCARSCharts.colors.green,
                LCARSCharts.colors.cyan,
                LCARSCharts.colors.tan,
                LCARSCharts.colors.red
            ],
            borderColor:      LCARSCharts.colors.background,
            borderWidth:      2,
            hoverBorderColor: LCARSCharts.colors.tan,
            hoverBorderWidth: 3
        }]
    };

    if (homeCharts.subitemDoughnut) {
        LCARSCharts.updateChart(homeCharts.subitemDoughnut, chartData);
    } else {
        _destroyOrphanedChart('home-subitem-doughnut');
        homeCharts.subitemDoughnut = LCARSCharts.createDoughnut('home-subitem-doughnut', chartData, {
            maintainAspectRatio: false,
            responsive: true
        });
    }

    // Text metrics
    if (metricsEl) {
        const metricRows = [
            { label: 'TOTAL SUBITEMS',  value: totalSubs,     color: '#99CCFF' },
            { label: 'COMPLETED',       value: completedSubs, color: '#99CC99' },
            { label: 'ACTIVE',          value: activeSubs,    color: '#FFCC99' },
            { label: 'PENDING',         value: pendingSubs > 0 ? pendingSubs : 0, color: 'rgba(255,204,153,0.55)' },
            { label: 'CANCELLED',       value: cancelledSubs, color: '#CC6666' },
            { label: 'COMPLETION RATE', value: subRate + '%', color: '#CC99CC' }
        ];

        metricsEl.innerHTML = metricRows.map(r => `
            <div style="display: flex; justify-content: space-between; align-items: center; padding: 6px 0; border-bottom: 1px solid rgba(255,204,153,0.08);">
                <span style="font-family: 'Antonio', sans-serif; font-size: 12px; color: rgba(255,204,153,0.65); letter-spacing: 0.06em;">${r.label}</span>
                <span style="font-family: 'Antonio', sans-serif; font-size: 18px; font-weight: 700; color: ${r.color};">${r.value}</span>
            </div>
        `).join('');
    }
}

/**
 * Render knowledge base analytics panel (panel index 4).
 * Fetches /api/knowledge-stats and populates:
 *   - #home-knowledge-doughnut: Chart.js doughnut showing file distribution by type
 *   - #home-knowledge-metrics: stat rows with summary numbers
 * Rapid navigation guard: uses a debounce timer (KNOWLEDGE_DEBOUNCE_MS) to coalesce
 * repeated calls, and an AbortController to cancel any in-flight request when the
 * user navigates away from panel 4. After each await point the panel index is
 * re-checked so that a stale resolution cannot inject DOM content or charts when a
 * different panel is now active.
 */
async function _renderHomeKnowledgeStats() {
    // ── Debounce: abort any queued (but not yet started) fetch ────────────────
    if (_knowledgeDebounceTimer !== null) {
        clearTimeout(_knowledgeDebounceTimer);
        _knowledgeDebounceTimer = null;
    }

    // ── Abort any in-flight fetch from a previous call ────────────────────────
    if (_knowledgeAbortController !== null) {
        _knowledgeAbortController.abort();
        _knowledgeAbortController = null;
    }

    const metricsEl   = document.getElementById('home-knowledge-metrics');

    // Show loading state while fetching
    if (metricsEl) {
        metricsEl.innerHTML = `<div style="color: rgba(255,204,153,0.45); font-family: 'Antonio', sans-serif; font-size: 13px; text-align: center; padding: 20px 0;">LOADING...</div>`;
    }

    // ── Debounce: wait KNOWLEDGE_DEBOUNCE_MS before firing the real fetch ─────
    // If the user navigates away during this window, the outer call will have
    // already cleared this timer (above), so the fetch never starts.
    await new Promise((resolve, reject) => {
        _knowledgeDebounceTimer = setTimeout(resolve, KNOWLEDGE_DEBOUNCE_MS);
        // Store a reject path so an abort signal can cancel the debounce too.
        // We reuse the abort signal check after the debounce resolves.
    });
    _knowledgeDebounceTimer = null;

    // ── Navigation guard: bail if user has already left panel 4 ──────────────
    if (currentHomePanel !== 4) {
        if (metricsEl) metricsEl.innerHTML = '';
        return;
    }

    // ── Create a fresh AbortController for this fetch ─────────────────────────
    const controller = new AbortController();
    _knowledgeAbortController = controller;

    let stats;
    try {
        const response = await fetch('/api/knowledge-stats', { signal: controller.signal });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        stats = await response.json();
    } catch (err) {
        // Suppress abort errors — they are intentional navigation cancellations.
        if (err.name === 'AbortError') {
            return;
        }
        console.warn('[LCARS] Failed to fetch /api/knowledge-stats:', err);
        // Only update DOM if still on the knowledge panel.
        if (currentHomePanel === 4 && metricsEl) {
            metricsEl.innerHTML = `<div style="color: rgba(204,102,102,0.75); font-family: 'Antonio', sans-serif; font-size: 13px; text-align: center; padding: 20px 0;">DATA UNAVAILABLE</div>`;
        }
        return;
    } finally {
        // Clear the controller reference once the fetch has settled.
        if (_knowledgeAbortController === controller) {
            _knowledgeAbortController = null;
        }
    }

    // ── Navigation guard: bail if user navigated away while fetch was in-flight
    if (currentHomePanel !== 4) {
        return;
    }

    const summary = stats.summary || {};

    // ── Doughnut chart: Agent KB files vs Team KB files vs Memory files ──────
    // Derive agent-only file count (total KB files minus team files)
    // Note: memoryFiles are from a separate directory (~/.claude/projects/*/memory/)
    // and are NOT included in totalKnowledgeFiles, so must not be subtracted
    const teamFiles   = summary.totalKnowledgeFiles
        ? Object.values(stats.teams || {}).reduce((sum, t) => sum + (t.fileCount || 0), 0)
        : 0;
    const memoryFiles = summary.totalMemoryFiles || 0;
    const agentFiles  = Math.max(0, (summary.totalKnowledgeFiles || 0) - teamFiles);

    const chartData = {
        labels: ['AGENT FILES', 'TEAM FILES', 'MEMORY FILES'],
        datasets: [{
            data: [agentFiles, teamFiles, memoryFiles],
            backgroundColor: [
                LCARSCharts.colors.orange,
                LCARSCharts.colors.tan,
                LCARSCharts.colors.yellow
            ],
            borderColor:      LCARSCharts.colors.background,
            borderWidth:      2,
            hoverBorderColor: LCARSCharts.colors.tan,
            hoverBorderWidth: 3
        }]
    };

    if (homeCharts.knowledgeDoughnut) {
        LCARSCharts.updateChart(homeCharts.knowledgeDoughnut, chartData);
    } else {
        _destroyOrphanedChart('home-knowledge-doughnut');
        homeCharts.knowledgeDoughnut = LCARSCharts.createDoughnut('home-knowledge-doughnut', chartData, {
            maintainAspectRatio: false,
            responsive: true
        });
    }

    // ── Metrics panel ─────────────────────────────────────────────────────────
    if (!metricsEl) return;

    // Format bytes to human-readable (KB or MB)
    function _fmtBytes(bytes) {
        if (!bytes || bytes === 0) return '0 KB';
        if (bytes < 1024 * 1024) return Math.round(bytes / 1024) + ' KB';
        return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
    }

    // Format ISO timestamp as short relative time or date
    function _fmtDate(iso) {
        if (!iso) return 'N/A';
        const d = new Date(iso);
        if (isNaN(d)) return 'N/A';
        const diffMs  = Date.now() - d.getTime();
        const diffMin = Math.floor(diffMs / 60000);
        if (diffMin < 1)   return 'JUST NOW';
        if (diffMin < 60)  return diffMin + 'M AGO';
        const diffHr = Math.floor(diffMin / 60);
        if (diffHr < 24)   return diffHr + 'H AGO';
        const diffDay = Math.floor(diffHr / 24);
        if (diffDay < 7)   return diffDay + 'D AGO';
        return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' }).toUpperCase();
    }

    const mostActive = summary.mostActiveAgent
        ? escapeHtml(summary.mostActiveAgent)
        : 'N/A';

    const metricRows = [
        { label: 'TOTAL AGENTS',      value: summary.totalAgents        || 0,  color: LCARSCharts.colors.cyan   },
        { label: 'TOTAL TEAMS',       value: summary.totalTeams         || 0,  color: LCARSCharts.colors.blue   },
        { label: 'KNOWLEDGE FILES',   value: summary.totalKnowledgeFiles || 0, color: LCARSCharts.colors.orange },
        { label: 'KNOWLEDGE ENTRIES', value: summary.totalKnowledgeEntries || 0, color: LCARSCharts.colors.tan  },
        { label: 'KB SIZE',           value: _fmtBytes(summary.totalKnowledgeSizeBytes), color: LCARSCharts.colors.yellow },
        { label: 'PROJECTS W/ MEMORY',value: summary.projectsWithMemory || 0,  color: LCARSCharts.colors.purple },
        { label: 'MOST ACTIVE',       value: mostActive,                        color: LCARSCharts.colors.tan   },
        { label: 'LAST UPDATED',      value: _fmtDate(summary.lastUpdated),     color: LCARSCharts.colors.green },
    ];

    metricsEl.innerHTML = metricRows.map(r => `
        <div class="knowledge-stat-row">
            <div class="knowledge-stat-value" style="color: ${r.color};">${r.value}</div>
            <div class="knowledge-stat-label">${r.label}</div>
        </div>
    `).join('');
}

/**
 * Render retrospective adoption coverage metrics on panel 5.
 *
 * Fetches /api/knowledge-stats (same endpoint as panel 4) and renders the
 * adoption section: overall coverage bar + per-team breakdown rows.
 *
 * Uses the same debounce/abort infrastructure as _renderHomeKnowledgeStats
 * to prevent stale DOM injection on rapid navigation.
 */
async function _renderHomeAdoptionStats() {
    // ── Debounce: abort any queued (but not yet started) fetch ────────────────
    if (_knowledgeDebounceTimer !== null) {
        clearTimeout(_knowledgeDebounceTimer);
        _knowledgeDebounceTimer = null;
    }

    // ── Abort any in-flight fetch from a previous call ────────────────────────
    if (_knowledgeAbortController !== null) {
        _knowledgeAbortController.abort();
        _knowledgeAbortController = null;
    }

    const adoptionEl = document.getElementById('home-knowledge-adoption');
    if (!adoptionEl) return;

    // Show loading state
    adoptionEl.innerHTML = `<div style="color: rgba(255,204,153,0.45); font-family: 'Antonio', sans-serif; font-size: 13px; text-align: center; padding: 40px 0;">LOADING...</div>`;

    // ── Debounce: wait before firing the real fetch ──────────────────────────
    await new Promise((resolve) => {
        _knowledgeDebounceTimer = setTimeout(resolve, KNOWLEDGE_DEBOUNCE_MS);
    });
    _knowledgeDebounceTimer = null;

    // ── Navigation guard: bail if user has already left panel 5 ──────────────
    if (currentHomePanel !== 5) {
        adoptionEl.innerHTML = '';
        return;
    }

    // ── Create a fresh AbortController for this fetch ───────────────────────
    const controller = new AbortController();
    _knowledgeAbortController = controller;

    let stats;
    try {
        const response = await fetch('/api/knowledge-stats', { signal: controller.signal });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        stats = await response.json();
    } catch (err) {
        if (err.name === 'AbortError') return;
        console.warn('[LCARS] Failed to fetch /api/knowledge-stats:', err);
        if (currentHomePanel === 5 && adoptionEl) {
            adoptionEl.innerHTML = `<div style="color: rgba(204,102,102,0.75); font-family: 'Antonio', sans-serif; font-size: 13px; text-align: center; padding: 40px 0;">DATA UNAVAILABLE</div>`;
        }
        return;
    } finally {
        if (_knowledgeAbortController === controller) {
            _knowledgeAbortController = null;
        }
    }

    // ── Navigation guard: bail if user navigated away during fetch ───────────
    if (currentHomePanel !== 5) return;

    const adoption = stats.adoption || {};
    const overallPct = adoption.overall_coverage_pct || 0;
    const totalCompleted = adoption.total_completed || 0;
    const totalWithRetros = adoption.total_with_retros || 0;
    const teamRows = adoption.teams || [];

    // Coverage bar color: red < 25%, yellow 25-50%, green > 50%
    function _coverageColor(pct) {
        if (pct >= 50) return LCARSCharts.colors.green || '#66cc66';
        if (pct >= 25) return LCARSCharts.colors.yellow || '#ffff99';
        return '#cc6666';
    }

    const overallColor = _coverageColor(overallPct);
    const overallBarWidth = Math.min(100, overallPct).toFixed(1);

    const teamRowsHtml = teamRows.slice(0, 8).map(t => {
        const pct = t.coverage_pct || 0;
        const barColor = _coverageColor(pct);
        const barWidth = Math.min(100, pct).toFixed(1);
        const teamLabel = escapeHtml(t.team.toUpperCase());
        return `
        <div class="knowledge-adoption-team-row">
            <div class="knowledge-adoption-team-name">${teamLabel}</div>
            <div class="knowledge-adoption-bar-wrap">
                <div class="knowledge-adoption-bar" style="width: ${barWidth}%; background: ${barColor};"></div>
            </div>
            <div class="knowledge-adoption-team-pct" style="color: ${barColor};">${pct}%</div>
            <div class="knowledge-adoption-team-detail">${t.items_with_retros}/${t.completed_items}</div>
        </div>`;
    }).join('');

    adoptionEl.innerHTML = `
        <div class="knowledge-adoption-overall">
            <div class="knowledge-adoption-overall-label">OVERALL: <span style="color: ${overallColor};">${overallPct}%</span>
                <span class="knowledge-adoption-overall-sub">(${totalWithRetros} of ${totalCompleted} items)</span>
            </div>
            <div class="knowledge-adoption-bar-wrap">
                <div class="knowledge-adoption-bar" style="width: ${overallBarWidth}%; background: ${overallColor};"></div>
            </div>
        </div>
        <div class="knowledge-adoption-teams">
            ${teamRowsHtml || '<div class="knowledge-adoption-empty">No completed items with retrospective data</div>'}
        </div>
    `;
}

/**
 * Render content stats for a RAG engine carousel panel.
 * @param {number} engineIndex - Index into ragEngineData (0-based).
 */
function _renderHomeRAGPanel(engineIndex) {
    if (engineIndex < 0 || engineIndex >= ragEngineData.length) return;
    const engine = ragEngineData[engineIndex];
    const container = document.getElementById('rag-stats-' + engine.id);
    if (!container) return;

    const stats = engine.contentStats || {};
    const processed = stats.processed || {};
    const failed = stats.failed || {};
    const total = stats.total || {};
    const health = engine.health || {};

    const docCount = total.documents || 0;
    const chunkCount = total.chunks || 0;
    const processedDocs = processed.documents || 0;
    const failedDocs = failed.documents || 0;
    const successRate = docCount > 0 ? Math.round((processedDocs / docCount) * 100) : 0;

    // Build stats grid via DOM API (no innerHTML with dynamic data)
    container.textContent = '';

    function makeStatCard(value, label, extraClass) {
        const card = document.createElement('div');
        card.className = 'rag-stat-card' + (extraClass ? ' ' + extraClass : '');
        const valEl = document.createElement('div');
        valEl.className = 'rag-stat-value' + (extraClass ? ' ' + extraClass : '');
        valEl.textContent = typeof value === 'number' ? value.toLocaleString() : value;
        const labelEl = document.createElement('div');
        labelEl.className = 'rag-stat-label';
        labelEl.textContent = label;
        card.appendChild(valEl);
        card.appendChild(labelEl);
        return card;
    }

    container.appendChild(makeStatCard(docCount, 'TOTAL DOCUMENTS'));
    container.appendChild(makeStatCard(chunkCount, 'TOTAL CHUNKS'));

    const processedCard = makeStatCard(processedDocs, 'PROCESSED');
    processedCard.querySelector('.rag-stat-value').classList.add('rag-stat-success');
    container.appendChild(processedCard);

    const failedCard = makeStatCard(failedDocs, 'FAILED');
    if (failedDocs > 0) {
        failedCard.querySelector('.rag-stat-value').classList.add('rag-stat-error');
    }
    container.appendChild(failedCard);

    // Progress bar card
    const progressCard = document.createElement('div');
    progressCard.className = 'rag-stat-card rag-stat-wide';
    const progressBar = document.createElement('div');
    progressBar.className = 'rag-progress-bar';
    const progressFill = document.createElement('div');
    progressFill.className = 'rag-progress-fill';
    progressFill.style.width = successRate + '%';
    progressBar.appendChild(progressFill);
    const progressLabel = document.createElement('div');
    progressLabel.className = 'rag-stat-label';
    progressLabel.textContent = successRate + '% SUCCESS RATE';
    progressCard.appendChild(progressBar);
    progressCard.appendChild(progressLabel);
    container.appendChild(progressCard);

    if (health.message) {
        const healthCard = document.createElement('div');
        healthCard.className = 'rag-stat-card rag-stat-wide';
        const healthMsg = document.createElement('div');
        healthMsg.className = 'rag-health-message';
        healthMsg.textContent = health.message;
        healthCard.appendChild(healthMsg);
        container.appendChild(healthCard);
    }
}

function updateContentWatermark() {
    const logo = document.getElementById('content-watermark-logo');
    const logoTeam = getLogoTeamName(CONFIG.team);
    if (logo && logoTeam) {
        logo.src = `images/${logoTeam}_logo.png`;
        logo.onerror = function() {
            this.onerror = null;
            this.src = `images/${logoTeam}_logo.svg`;
        };
    }
}

function renderShipInfo() {
    document.getElementById('ship-name').textContent = boardData.ship || 'Unknown Vessel';

    const lastUpdate = boardData.lastUpdated
        ? new Date(boardData.lastUpdated).toLocaleTimeString()
        : 'Awaiting Data';
    document.getElementById('last-update').textContent = lastUpdate;

    // Set header team logo
    const headerLogo = document.getElementById('header-team-logo');
    const logoTeam = getLogoTeamName(CONFIG.team);
    if (headerLogo && logoTeam) {
        headerLogo.src = `images/${logoTeam}_lcars_logo.png`;
        headerLogo.onerror = function() {
            // Try team logo PNG, then SVG as final fallback
            this.onerror = function() {
                this.onerror = null;
                this.src = `images/${logoTeam}_logo.svg`;
            };
            this.src = `images/${logoTeam}_logo.png`;
        };
    }

    // Update header info from board data
    const teamNameEl = document.getElementById('team-name');
    const groupIdEl = document.getElementById('group-id');

    // Determine display values from board data or fallback to legacy logic
    let displayTeamName = null;
    let displayGroupName = null;
    let titleDisplayName = null;

    // Priority 1: Use board data fields if available (organization, subtitle, teamName)
    if (boardData.subtitle) {
        displayTeamName = boardData.subtitle;
    }

    if (boardData.organization) {
        displayGroupName = boardData.organization;
    }

    titleDisplayName = boardData.teamName;

    // Priority 2: Legacy fallback logic for teams without these fields
    if (!displayGroupName) {
        const mainEventTeams = ['command', 'ios', 'android', 'firebase', 'mainevent'];
        const academyTeams = ['academy'];

        if (CONFIG.team === 'freelance' && CONFIG.sessionName) {
            const parts = CONFIG.sessionName.split('-');
            // Format: freelance-<group>-<project>-lcars
            if (parts.length >= 4) {
                displayGroupName = parts[1].toUpperCase();
                const projectName = parts[2].toUpperCase();
                if (!displayTeamName) {
                    displayTeamName = projectName;
                }
                if (!titleDisplayName) {
                    titleDisplayName = projectName;
                }
            }
        } else if (mainEventTeams.includes(CONFIG.team)) {
            displayGroupName = 'MAIN EVENT';
        } else if (academyTeams.includes(CONFIG.team)) {
            displayGroupName = 'DEVTEAM';
        } else if (CONFIG.team && CONFIG.team.startsWith('legal-')) {
            displayGroupName = 'LEGAL';
        } else {
            displayGroupName = 'DOUBLENODE';
        }
    }

    // Final fallback: use teamName if nothing else set
    if (!displayTeamName && boardData.teamName) {
        displayTeamName = boardData.teamName;
    }
    if (!titleDisplayName) {
        titleDisplayName = boardData.teamName || null;
    }

    // Update sidebar team name
    if (teamNameEl && displayTeamName) {
        teamNameEl.textContent = displayTeamName;
    }

    // Update sidebar group/organization
    if (groupIdEl && displayGroupName) {
        groupIdEl.textContent = displayGroupName;
        groupIdEl.style.display = '';
    }

    // Update the main title (3 levels: full / medium / short)
    const titleFullEl = document.querySelector('.lcars-title .title-full');
    const titleMediumEl = document.querySelector('.lcars-title .title-medium');

    if (titleFullEl) {
        if (displayGroupName && titleDisplayName) {
            titleFullEl.textContent = `${displayGroupName} ${titleDisplayName}`;
        } else if (displayGroupName) {
            titleFullEl.textContent = `${displayGroupName}`;
        } else if (titleDisplayName) {
            titleFullEl.textContent = `${titleDisplayName}`;
        }
    }
    if (titleMediumEl && titleDisplayName) {
        titleMediumEl.textContent = `${titleDisplayName}`;
    }

    // Update page title to match the display
    if (displayGroupName && titleDisplayName) {
        document.title = `${displayGroupName} ${titleDisplayName}`;
    } else if (displayGroupName) {
        document.title = `${displayGroupName}`;
    } else if (titleDisplayName) {
        document.title = `${titleDisplayName}`;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// RESPONSIVE SWIMLANE CONFIGURATION
// ═══════════════════════════════════════════════════════════════════════════════

// Column priority: 'critical' always shows, 'important' shows if non-empty, 'optional' hides when empty
const COLUMN_PRIORITY = {
    // XACA-0778-005: crash-recovery lane. 'important' (not 'critical') so it
    // collapses cleanly when there is nothing orphaned -- the whole point is
    // to surface orphans without adding permanent visual noise for the
    // common case (tmux is fine, nothing needs reconnecting).
    needs_reconnect: 'important',
    paused:    'critical',   // Always show - alerts need visibility
    ready:     'critical',   // Always show - work backlog entry point
    coding:    'critical',   // Always show - active development
    planning:  'important',  // Show if has cards
    testing:   'important',  // Show if has cards
    commit:    'optional',   // Hide when empty
    pr_review: 'optional'    // Hide when empty
};

// All column names in display order. 'needs_reconnect' leads the board --
// crash-orphaned in_progress work (XACA-0778-005) is the thing an operator
// is most likely to miss, so it gets first billing, ahead of even PAUSED.
const KANBAN_COLUMNS = ['needs_reconnect', 'paused', 'ready', 'planning', 'coding', 'testing', 'commit', 'pr_review'];

// Toggle state - show all columns or intelligent hiding
let showAllKanbanColumns = localStorage.getItem('showAllKanbanColumns') === 'true';

function renderKanbanColumns() {
    // Clear all columns
    KANBAN_COLUMNS.forEach(col => {
        const container = document.getElementById(`col-${col}`);
        if (container) container.innerHTML = '';
    });

    // Get active windows from new format
    const activeWindows = boardData.activeWindows || [];

    // Track which columns have cards
    const columnCardCounts = {};
    KANBAN_COLUMNS.forEach(col => columnCardCounts[col] = 0);

    // Populate columns from activeWindows
    activeWindows.forEach(win => {
        const column = document.getElementById(`col-${win.status}`);
        if (column) {
            const card = createKanbanCard(win);
            column.appendChild(card);
            columnCardCounts[win.status] = (columnCardCounts[win.status] || 0) + 1;
        }
    });

    // Show "no active windows" message in ready column if board is empty
    const readyCol = document.getElementById('col-ready');
    if (activeWindows.length === 0 && readyCol) {
        readyCol.innerHTML = '<div class="empty-column">No active windows</div>';
    }

    // XACA-0778-005: NEEDS RECONNECT lane -- backlog[].status == "in_progress"
    // work the server-side reconciler (kb-reconcile-inprogress, XACA-0778-001)
    // classified ORPHANED: no live tmux window backs it (dead pointer, or the
    // whole tmux server is down post-crash). This is the persistent-truth
    // view, unlike activeWindows[] above which is entirely tmux-session-keyed
    // and goes silent the instant tmux dies -- exactly when an operator most
    // needs to see what was mid-flight. Additive: never touches activeWindows.
    const reconnectCol = document.getElementById('col-needs_reconnect');
    if (reconnectCol) {
        const reconciled = boardData.reconciledInProgress || [];
        const orphaned = reconciled.filter(r => r.classification === 'ORPHANED');
        orphaned.forEach(item => {
            const card = createReconnectCard(item);
            reconnectCol.appendChild(card);
            columnCardCounts.needs_reconnect = (columnCardCounts.needs_reconnect || 0) + 1;
        });
    }

    // Apply responsive swimlane logic
    updateKanbanColumnVisibility(columnCardCounts);
}

/**
 * Update column visibility based on card counts and priority
 * Critical columns always show, optional columns hide when empty
 */
function updateKanbanColumnVisibility(columnCardCounts) {
    const kanbanBoard = document.querySelector('.kanban-board');
    if (!kanbanBoard) return;

    let visibleCount = 0;
    let hiddenCount = 0;

    KANBAN_COLUMNS.forEach(colName => {
        const colEl = document.querySelector(`.kanban-column[data-status="${colName}"]`);
        if (!colEl) return;

        const cardCount = columnCardCounts[colName] || 0;
        const priority = COLUMN_PRIORITY[colName] || 'optional';
        const isEmpty = cardCount === 0;

        // Determine visibility
        let shouldShow = true;
        if (!showAllKanbanColumns) {
            if (priority === 'critical') {
                shouldShow = true; // Always show
            } else if (priority === 'important') {
                shouldShow = !isEmpty; // Show if has cards
            } else {
                shouldShow = !isEmpty; // Optional: hide if empty
            }
        }

        // Apply visibility classes
        colEl.classList.toggle('empty', isEmpty);
        colEl.classList.toggle('hidden-empty', !shouldShow && isEmpty);
        colEl.classList.toggle('priority-critical', priority === 'critical');
        colEl.classList.toggle('priority-important', priority === 'important');
        colEl.classList.toggle('priority-optional', priority === 'optional');

        if (shouldShow) {
            visibleCount++;
        } else {
            hiddenCount++;
        }
    });

    // Update grid layout based on visible columns
    kanbanBoard.setAttribute('data-visible-columns', visibleCount);

    // Toggle the show-all class on the board
    kanbanBoard.classList.toggle('show-all-columns', showAllKanbanColumns);

    // Update hidden columns indicator
    updateHiddenColumnsIndicator(hiddenCount);
}

/**
 * Update the hidden columns indicator badge
 */
function updateHiddenColumnsIndicator(hiddenCount) {
    let indicator = document.querySelector('.hidden-columns-indicator');

    // Create indicator if it doesn't exist
    if (!indicator) {
        const kanbanSection = document.querySelector('.kanban-section .section-header');
        if (!kanbanSection) return;

        indicator = document.createElement('div');
        indicator.className = 'hidden-columns-indicator';
        kanbanSection.appendChild(indicator);
    }

    if (hiddenCount > 0 && !showAllKanbanColumns) {
        indicator.innerHTML = `
            <span class="hidden-count">${hiddenCount} empty ${hiddenCount === 1 ? 'column' : 'columns'} hidden</span>
            <button class="toggle-columns-btn" onclick="toggleShowAllColumns()">SHOW ALL</button>
        `;
        indicator.classList.add('visible');
    } else if (showAllKanbanColumns) {
        indicator.innerHTML = `
            <span class="hidden-count">Showing all columns</span>
            <button class="toggle-columns-btn" onclick="toggleShowAllColumns()">SMART HIDE</button>
        `;
        indicator.classList.add('visible');
    } else {
        indicator.classList.remove('visible');
    }
}

/**
 * Toggle between showing all columns and intelligent hiding
 */
function toggleShowAllColumns() {
    showAllKanbanColumns = !showAllKanbanColumns;
    localStorage.setItem('showAllKanbanColumns', showAllKanbanColumns);

    // Re-render with new visibility settings
    renderKanbanColumns();
}

function createKanbanCard(win) {
    const card = document.createElement('div');
    // Add 'paused' class for pulsing animation when status is paused
    const pausedClass = win.status === 'paused' ? ' paused' : '';
    card.className = `kanban-card ${win.color || 'operations'}${pausedClass}`;

    // Line 1: Header with avatar and terminal name
    const headerLine = document.createElement('div');
    headerLine.className = 'card-header';

    const cardAvatar = document.createElement('img');
    cardAvatar.className = 'card-avatar lcars-avatar';
    cardAvatar.src = getDeveloperAvatarUrl(boardData?.team, win.terminal);
    cardAvatar.alt = win.developer || '';
    cardAvatar.dataset.developer = win.developer || '';
    cardAvatar.dataset.role = boardData?.terminals?.[win.terminal]?.role || '';
    cardAvatar.dataset.terminal = win.terminal || '';
    cardAvatar.onerror = function() { this.style.display = 'none'; };
    headerLine.appendChild(cardAvatar);

    const terminalLine = document.createElement('div');
    terminalLine.className = 'card-terminal';
    terminalLine.textContent = win.terminal;
    headerLine.appendChild(terminalLine);

    card.appendChild(headerLine);

    // Line 2: Window name with index
    const windowLine = document.createElement('div');
    windowLine.className = 'card-window';
    windowLine.textContent = `${win.windowName} [${win.window}]`;
    card.appendChild(windowLine);

    // Line 3: Working ID (prominent) - shows subitem ID or item ID
    // Clickable to navigate to the backlog item
    if (win.workingOnId) {
        const workingLine = document.createElement('div');
        workingLine.className = 'card-working-id clickable';
        workingLine.textContent = `⚡ ${win.workingOnId}`;
        workingLine.title = `Click to view ${win.workingOnId} in Queue`;
        workingLine.addEventListener('click', (e) => {
            e.stopPropagation();
            navigateToBacklogItemById(win.workingOnId);
        });
        card.appendChild(workingLine);
    }

    // Paused reason (shown prominently when status is paused)
    if (win.status === 'paused' && win.pausedReason) {
        const pausedLine = document.createElement('div');
        pausedLine.className = 'card-paused-reason';
        pausedLine.textContent = `⏸️ ${win.pausedReason}`;
        card.appendChild(pausedLine);
    }

    // Line 4: Task/status
    const taskLine = document.createElement('div');
    taskLine.className = 'card-task';
    taskLine.textContent = win.task || 'No task';
    card.appendChild(taskLine);

    card.title = `${win.developer || 'Unknown'}\nWorktree: ${win.worktree || 'N/A'}`;
    card.onclick = () => showWindowDetails(win);
    return card;
}

/**
 * XACA-0778-005: Build a card for the NEEDS RECONNECT lane from a single
 * reconciled-in-progress entry (see kb-reconcile-inprogress / kanban-helpers.sh
 * _kb_reconcile_inprogress for the output contract). Unlike createKanbanCard,
 * `item` is NOT an activeWindows[] entry -- there is no live tmux window, no
 * terminal, no developer/avatar to show. The card's job is purely "here's
 * what's orphaned and how to get back to it": id, title, worktree/branch, and
 * an explicit recovery hint.
 */
function createReconnectCard(item) {
    const card = document.createElement('div');
    card.className = 'kanban-card needs-reconnect';

    // Line 1: Alert header -- distinct from the live-session card header
    // (no avatar/terminal to show since nothing is actually connected).
    const headerLine = document.createElement('div');
    headerLine.className = 'card-header';
    const alertIcon = document.createElement('span');
    alertIcon.className = 'card-reconnect-icon';
    alertIcon.textContent = '🔌'; // 🔌 plug -- disconnected work, self-contained unicode glyph
    alertIcon.setAttribute('aria-hidden', 'true');
    headerLine.appendChild(alertIcon);
    const alertLabel = document.createElement('div');
    alertLabel.className = 'card-terminal';
    alertLabel.textContent = 'ORPHANED';
    headerLine.appendChild(alertLabel);
    card.appendChild(headerLine);

    // Line 2: ID (prominent, clickable -- navigates to the backlog item,
    // same behavior as the working-id line on live cards).
    const idLine = document.createElement('div');
    idLine.className = 'card-working-id clickable';
    idLine.textContent = `⚡ ${item.id}`;
    idLine.title = `Click to view ${item.id} in Queue`;
    idLine.addEventListener('click', (e) => {
        e.stopPropagation();
        navigateToBacklogItemById(item.id);
    });
    card.appendChild(idLine);

    // Parent relationship, when this is an orphaned subitem
    if (item.parentId) {
        const parentLine = document.createElement('div');
        parentLine.className = 'card-window';
        parentLine.textContent = `part of ${item.parentId}`;
        card.appendChild(parentLine);
    }

    // Line 3: Title/task
    const taskLine = document.createElement('div');
    taskLine.className = 'card-task';
    taskLine.textContent = item.title || 'Untitled';
    card.appendChild(taskLine);

    // Worktree / branch, when known
    if (item.worktree || item.branch) {
        const worktreeLine = document.createElement('div');
        worktreeLine.className = 'card-worktree';
        const parts = [];
        if (item.branch) parts.push(item.branch);
        if (item.worktree) parts.push(item.worktree);
        worktreeLine.textContent = parts.join(' — ');
        card.appendChild(worktreeLine);
    }

    // Recovery hint -- the actionable line, styled like the paused-reason
    // callout so it reads as "do something about this", not just FYI.
    const hintLine = document.createElement('div');
    hintLine.className = 'card-reconnect-hint';
    hintLine.textContent = `Run kb-resume ${item.id} (or kb-recover) to reconnect`;
    card.appendChild(hintLine);

    card.title = `${item.id}\nOrphaned in-progress work -- no live tmux window backs it.\nWorktree: ${item.worktree || 'N/A'}\nBranch: ${item.branch || 'N/A'}\nRun kb-resume ${item.id} or kb-recover to reconnect.`;
    card.setAttribute('role', 'button');
    card.setAttribute('tabindex', '0');
    card.setAttribute('aria-label', `Orphaned item ${item.id}: ${item.title || 'Untitled'}, activate to reconnect`);
    card.onclick = () => navigateToBacklogItemById(item.id);
    card.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            e.stopPropagation();
            navigateToBacklogItemById(item.id);
        }
    });
    return card;
}

function renderTerminalDetails() {
    const container = document.getElementById('terminal-details');
    if (!container) return;

    container.innerHTML = '';

    const activeWindows = boardData.activeWindows || [];

    if (activeWindows.length === 0) {
        container.innerHTML = `
            <div class="empty-watermark">
                <div class="empty-text">No active windows</div>
            </div>`;
        return;
    }

    // Sort by lastActivity descending (most recent first)
    const sorted = [...activeWindows].sort((a, b) => {
        const timeA = new Date(a.lastActivity || 0).getTime();
        const timeB = new Date(b.lastActivity || 0).getTime();
        return timeB - timeA;
    });

    sorted.forEach(win => {
        const row = createDetailRow(win);
        container.appendChild(row);
    });
}

/**
 * Make an element clickable to activate a terminal (switch iTerm2 tab + tmux window).
 * Adds click/keydown handlers, accessibility attributes, and CSS class.
 */
function makeClickableTerminal(el, win) {
    el.classList.add('clickable-terminal');
    el.tabIndex = 0;
    el.setAttribute('role', 'button');
    el.title = `Click to switch to ${win.terminal} terminal`;
    el.addEventListener('click', (e) => {
        e.stopPropagation();
        activateTerminal(win.terminal, win.window);
    });
    el.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            e.stopPropagation();
            activateTerminal(win.terminal, win.window);
        }
    });
}

/**
 * Activate a terminal by switching iTerm2 tab and tmux window.
 * Calls POST /api/terminal/activate endpoint.
 */
async function activateTerminal(terminal, windowIndex) {
    try {
        const response = await apiFetch(apiUrl('/api/terminal/activate'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ terminal, window: windowIndex })
        });

        if (!response.ok) {
            const error = await response.json().catch(() => ({ error: 'Unknown error' }));
            console.warn('Terminal activation failed:', error);
        }
    } catch (err) {
        console.warn('Terminal activation error:', err);
    }
}

function createDetailRow(win) {
    const row = document.createElement('div');
    row.className = `detail-row ${win.color || 'operations'}`;
    // Add data attributes for navigation highlighting
    row.dataset.terminal = win.terminal;
    row.dataset.window = win.window;

    // Main container with two sections (terminal + avatar)
    const container = document.createElement('div');
    container.className = 'detail-container';

    // === TOP SECTION: Terminal Logo + Lines 1-3 ===
    const topSection = document.createElement('div');
    topSection.className = 'detail-section detail-section-top';

    // Terminal logo
    const terminalLogo = document.createElement('img');
    terminalLogo.className = 'detail-logo terminal-logo';
    terminalLogo.src = getTerminalLogoUrl(boardData?.team, win.terminal);
    terminalLogo.alt = win.terminal;
    terminalLogo.onerror = function() { this.src = 'images/default_terminal_logo.svg'; };
    makeClickableTerminal(terminalLogo, win);
    topSection.appendChild(terminalLogo);

    // Top lines container
    const topLines = document.createElement('div');
    topLines.className = 'detail-lines';

    // Line 1: Terminal ID + Window ID + Last Activity
    const line1 = document.createElement('div');
    line1.className = 'detail-line';

    const terminal = document.createElement('span');
    terminal.className = 'detail-terminal';
    terminal.textContent = win.terminal;
    makeClickableTerminal(terminal, win);
    line1.appendChild(terminal);

    const windowName = document.createElement('span');
    windowName.className = 'detail-window-name';
    windowName.textContent = `${win.windowName} [${win.window}]`;
    line1.appendChild(windowName);

    const timestamp = document.createElement('span');
    timestamp.className = 'detail-timestamp';
    timestamp.textContent = formatRelativeTime(win.lastActivity);
    line1.appendChild(timestamp);

    topLines.appendChild(line1);

    // Line 2: Status History + Time in Status
    const line2 = document.createElement('div');
    line2.className = 'detail-line detail-line-history';

    const history = document.createElement('span');
    history.className = 'detail-status-history';
    const currentColor = getStatusColor(win.status);

    // Half pill for current status (rounded left, straight right)
    const currentStatusPill = `<span class="status-half-pill-left" style="background-color: ${currentColor}">${escapeHtml(String(win.status).toUpperCase())}</span>`;
    // Black divider
    const divider = '<span class="status-pill-divider"></span>';
    // Half pill for time (straight left, rounded right)
    const timePill = win.statusChangedAt
        ? `<span class="status-half-pill-right" style="background-color: ${currentColor}">${formatSessionDuration(win.statusChangedAt)}</span>`
        : '';
    const currentDisplay = timePill ? `${currentStatusPill}${divider}${timePill}` : currentStatusPill;

    if (win.statusHistory && win.statusHistory.length > 0) {
        // Limit to last 8 history items, then reverse for display (newest first)
        const trimmedHistory = win.statusHistory.slice(-8).reverse();
        const wasTrimmed = win.statusHistory.length > 8;
        // Color each status with its swimlane color
        const coloredHistory = trimmedHistory.map(s =>
            `<span style="color: ${getStatusColor(s)}">${escapeHtml(String(s).toUpperCase())}</span>`
        ).join(' <span style="color: #666">←</span> ');
        const suffix = wasTrimmed ? ' <span style="color: #666">←</span>' : '';
        history.innerHTML = `${currentDisplay} <span style="color: #666">←</span> ${coloredHistory}${suffix}`;
    } else {
        // No history, just show current status with time
        history.innerHTML = currentDisplay;
    }
    line2.appendChild(history);

    topLines.appendChild(line2);

    // Paused reason line (shown prominently when status is paused)
    if (win.status === 'paused' && win.pausedReason) {
        const linePaused = document.createElement('div');
        linePaused.className = 'detail-line detail-line-paused';

        const pausedLabel = document.createElement('span');
        pausedLabel.className = 'detail-paused-label';
        pausedLabel.textContent = '⏸️ PAUSED:';
        linePaused.appendChild(pausedLabel);

        const pausedReason = document.createElement('span');
        pausedReason.className = 'detail-paused-reason';
        pausedReason.textContent = win.pausedReason;
        linePaused.appendChild(pausedReason);

        topLines.appendChild(linePaused);
    }

    // Line 2.5: Working On (if set) - shows the backlog item/subitem being worked on
    // Subitem IDs include parent ID (e.g., XFRE-0001-001), so just display the ID directly
    // Clickable to navigate to Queue tab
    if (win.workingOnId) {
        const lineWorking = document.createElement('div');
        lineWorking.className = 'detail-line detail-line-working';

        const workingLabel = document.createElement('span');
        workingLabel.className = 'detail-working-label';
        workingLabel.textContent = 'WORKING ON:';
        lineWorking.appendChild(workingLabel);

        const workingId = document.createElement('span');
        workingId.className = 'detail-working-id clickable';
        workingId.textContent = win.workingOnId;
        workingId.title = `Click to view ${win.workingOnId} in Queue`;
        workingId.addEventListener('click', (e) => {
            e.stopPropagation();
            navigateToBacklogItemById(win.workingOnId);
        });
        lineWorking.appendChild(workingId);

        topLines.appendChild(lineWorking);
    }

    // Line 3: Task (text message)
    const line3 = document.createElement('div');
    line3.className = 'detail-line detail-line-task';

    const task = document.createElement('span');
    task.className = 'detail-task';
    task.textContent = win.task || 'No task';
    line3.appendChild(task);

    topLines.appendChild(line3);
    topSection.appendChild(topLines);
    container.appendChild(topSection);

    // === BOTTOM SECTION: Avatar + Lines 4-6 ===
    const bottomSection = document.createElement('div');
    bottomSection.className = 'detail-section detail-section-bottom';

    // Developer avatar
    const developerAvatar = document.createElement('img');
    developerAvatar.className = 'detail-logo developer-avatar lcars-avatar';
    developerAvatar.src = getDeveloperAvatarUrl(boardData?.team, win.terminal);
    developerAvatar.alt = win.developer || 'Developer';
    developerAvatar.dataset.developer = win.developer || '';
    developerAvatar.dataset.role = boardData?.terminals?.[win.terminal]?.role || '';
    developerAvatar.dataset.terminal = win.terminal || '';
    developerAvatar.onerror = function() { this.src = 'images/default_avatar.svg'; };
    // Set division-color glow
    const divColor = getDivisionColor(win.color);
    developerAvatar.style.setProperty('--division-glow-color', divColor);
    bottomSection.appendChild(developerAvatar);

    // Bottom lines container
    const bottomLines = document.createElement('div');
    bottomLines.className = 'detail-lines';

    // Line 4: Developer
    const line4 = document.createElement('div');
    line4.className = 'detail-line detail-line-developer';

    const developer = document.createElement('span');
    developer.className = 'detail-developer';
    developer.textContent = win.developer || 'Unknown';
    developer.style.color = getDivisionColor(win.color);
    line4.appendChild(developer);

    bottomLines.appendChild(line4);

    // Line 5: Worktree
    const line5 = document.createElement('div');
    line5.className = 'detail-line detail-line-worktree';

    const worktree = document.createElement('span');
    worktree.className = 'detail-worktree';
    worktree.textContent = win.worktree || '-';
    line5.appendChild(worktree);

    bottomLines.appendChild(line5);

    // Line 6: Branch + Git Status + Line Counts + Runtime
    const line6 = document.createElement('div');
    line6.className = 'detail-line detail-line-git';

    if (win.gitBranch) {
        const branch = document.createElement('span');
        branch.className = 'detail-branch';
        branch.textContent = `⎇ ${win.gitBranch}`;
        line6.appendChild(branch);
    }

    if (win.gitModified !== undefined && win.gitModified > 0) {
        const modified = document.createElement('span');
        modified.className = 'detail-modified';
        modified.textContent = `${win.gitModified} files`;
        line6.appendChild(modified);
    }

    if (win.gitLines && (win.gitLines.added > 0 || win.gitLines.deleted > 0)) {
        const lines = document.createElement('span');
        lines.className = 'detail-lines-changed';
        const added = document.createElement('span');
        added.className = 'lines-added';
        added.textContent = `+${win.gitLines.added}`;
        const deleted = document.createElement('span');
        deleted.className = 'lines-deleted';
        deleted.textContent = `-${win.gitLines.deleted}`;
        lines.append(added, document.createTextNode(' '), deleted);
        line6.appendChild(lines);
    }

    const runtime = document.createElement('span');
    runtime.className = 'detail-runtime';
    runtime.textContent = `⏱ ${formatSessionDuration(win.startedAt)}`;
    line6.appendChild(runtime);

    bottomLines.appendChild(line6);
    bottomSection.appendChild(bottomLines);
    container.appendChild(bottomSection);

    row.appendChild(container);
    return row;
}

function getTerminalLogoUrl(team, terminal) {
    if (!team || !terminal) return '';
    // Use terminal name for logos
    return `images/${team}_${terminal}_logo.png`;
}

function getDeveloperAvatarUrl(team, terminal) {
    if (!team || !terminal) return '';
    // Get avatar name from board config if available, otherwise use terminal name
    const terminalConfig = boardData?.terminals?.[terminal];
    const avatarName = terminalConfig?.avatar || terminal;
    return `images/${team}_${avatarName}_avatar.png`;
}

function renderMissionBacklog() {
    const container = document.getElementById('mission-backlog');
    const countEl = document.getElementById('backlog-count');
    if (!container) return;

    // XACA-0021: Clear dependency filter before re-rendering to prevent stuck state
    if (container.classList.contains('dependency-filter-active')) {
        container.classList.remove('dependency-filter-active');
    }

    const backlog = boardData.backlog || [];

    // Apply filters
    const filteredBacklog = backlog.filter(item => itemMatchesFilter(item));

    // Update count display with filter info
    const hasTextFilter = backlogFilterState.searchText && backlogFilterState.searchText.trim().length > 0;
    const hasActiveFilter = !backlogFilterState.activeFilters.includes('all');
    const showingCompleted = backlogFilterState.activeFilters.includes('completed');

    // Count active (non-completed, non-cancelled) items for display
    const activeCount = backlog.filter(item => item.status !== 'completed' && item.status !== 'cancelled').length;
    const completedCount = backlog.filter(item => item.status === 'completed' || item.status === 'cancelled').length;

    if (!hasTextFilter && !hasActiveFilter) {
        countEl.textContent = `${activeCount} PENDING`;
    } else if (showingCompleted) {
        countEl.textContent = `${filteredBacklog.length} COMPLETED / CANCELLED`;
    } else {
        countEl.textContent = `${filteredBacklog.length}/${backlog.length} SHOWN`;
    }

    if (filteredBacklog.length === 0) {
        if (backlog.length === 0) {
            container.innerHTML = `
                <div class="empty-watermark">
                    <div class="empty-text">No pending missions</div>
                </div>`;
        } else if (showingCompleted) {
            container.innerHTML = `
                <div class="empty-watermark">
                    <div class="empty-text">No completed or cancelled missions</div>
                </div>`;
        } else {
            container.innerHTML = `
                <div class="empty-watermark">
                    <div class="empty-text">No missions match current filters</div>
                </div>`;
        }
        return;
    }

    // Sort based on current sort setting
    // XACA-0022: Removed 'blocked' - it's a state, not a priority
    const priorityOrder = { critical: 0, high: 1, medium: 2, med: 2, low: 3 };
    const sortBy = backlogFilterState.sortBy || 'priority';

    const sorted = [...filteredBacklog].sort((a, b) => {
        // Completed/cancelled items always sort to the end (unless viewing completed filter)
        if (!showingCompleted) {
            const aDone = a.status === 'completed' || a.status === 'cancelled';
            const bDone = b.status === 'completed' || b.status === 'cancelled';
            if (aDone && !bDone) return 1;
            if (!aDone && bDone) return -1;
        }

        // When viewing completed/cancelled items, sort by completedAt/cancelledAt descending
        if (showingCompleted) {
            const dateA = a.completedAt || a.cancelledAt ? new Date(a.completedAt || a.cancelledAt) : new Date(0);
            const dateB = b.completedAt || b.cancelledAt ? new Date(b.completedAt || b.cancelledAt) : new Date(0);
            return dateB - dateA; // Descending (most recent first)
        }

        if (sortBy === 'due_date') {
            // Sort by due date: items with due dates first, then by urgency
            // Use effective due date (direct or inherited from subitems)
            const aEffectiveDue = getEffectiveDueDate(a);
            const bEffectiveDue = getEffectiveDueDate(b);

            // Items without due dates go to end
            if (aEffectiveDue && !bEffectiveDue) return -1;
            if (!aEffectiveDue && bEffectiveDue) return 1;

            // Both have due dates - sort by date (earliest first)
            if (aEffectiveDue && bEffectiveDue) {
                const dateA = parseLocalDate(aEffectiveDue.date);
                const dateB = parseLocalDate(bEffectiveDue.date);
                if (dateA < dateB) return -1;
                if (dateA > dateB) return 1;
            }

            // Same date or both no date - check blocking, then fall back to priority
            const aBlocksBDue = Array.isArray(b.blockedBy) && b.blockedBy.includes(a.id);
            const bBlocksADue = Array.isArray(a.blockedBy) && a.blockedBy.includes(b.id);
            if (aBlocksBDue && !bBlocksADue) return -1;  // A blocks B, A comes first
            if (bBlocksADue && !aBlocksBDue) return 1;   // B blocks A, B comes first

            const prioA = priorityOrder[(a.priority || 'medium').toLowerCase()] ?? 2;
            const prioB = priorityOrder[(b.priority || 'medium').toLowerCase()] ?? 2;
            return prioA - prioB;
        } else {
            // Sort by priority (default)
            const prioA = priorityOrder[(a.priority || 'medium').toLowerCase()] ?? 2;
            const prioB = priorityOrder[(b.priority || 'medium').toLowerCase()] ?? 2;
            if (prioA !== prioB) return prioA - prioB;

            // Same priority - check if one blocks the other (blocker sorts first)
            const aBlocksBPrio = Array.isArray(b.blockedBy) && b.blockedBy.includes(a.id);
            const bBlocksAPrio = Array.isArray(a.blockedBy) && a.blockedBy.includes(b.id);
            if (aBlocksBPrio && !bBlocksAPrio) return -1;  // A blocks B, A comes first
            if (bBlocksAPrio && !aBlocksBPrio) return 1;   // B blocks A, B comes first

            // Same priority, no blocking - sort by due date (items with due dates first, then by date)
            // Use effective due date (direct or inherited from subitems)
            const aEffectiveDue = getEffectiveDueDate(a);
            const bEffectiveDue = getEffectiveDueDate(b);
            if (aEffectiveDue && !bEffectiveDue) return -1;
            if (!aEffectiveDue && bEffectiveDue) return 1;
            if (aEffectiveDue && bEffectiveDue) {
                const dateA = parseLocalDate(aEffectiveDue.date);
                const dateB = parseLocalDate(bEffectiveDue.date);
                return dateA - dateB;
            }
            return 0;
        }
    });

    container.innerHTML = '';
    sorted.forEach((item, index) => {
        // Find original index for display purposes
        const originalIndex = backlog.indexOf(item);
        const backlogItem = createBacklogItem(item, originalIndex);
        container.appendChild(backlogItem);
    });
}

/**
 * Create tag pills element with black vertical separators
 * OS tags (iOS, Android, Firebase) are filtered out - they display separately as logos
 * @param {string[]} tags - Array of tag strings
 * @returns {HTMLElement|null} - Tags row element or null if no tags
 */
function createTagsElement(tags) {
    // Filter out OS tags - they display separately as logos
    const displayTags = filterOSTags(tags);

    if (!displayTags || displayTags.length === 0) {
        return null;
    }

    const row = document.createElement('div');
    row.className = 'backlog-tags-row';

    const container = document.createElement('div');
    container.className = 'backlog-tags';

    displayTags.forEach((tag, idx) => {
        // Add separator before each tag except the first
        if (idx > 0) {
            const separator = document.createElement('div');
            separator.className = 'backlog-tag-separator';
            container.appendChild(separator);
        }

        const tagEl = document.createElement('div');
        tagEl.className = 'backlog-tag';
        tagEl.textContent = tag;
        tagEl.title = `Filter by: ${tag}`;
        tagEl.dataset.tag = tag.toLowerCase();

        // Check if this tag matches current search filter
        const currentSearch = (backlogFilterState.searchText || '').toLowerCase().trim();
        if (currentSearch && tag.toLowerCase().includes(currentSearch)) {
            tagEl.classList.add('active');
        }

        tagEl.addEventListener('click', (e) => {
            e.stopPropagation();
            // Update the search input and filter
            const searchInput = document.getElementById('backlog-filter-text');
            if (searchInput) {
                searchInput.value = tag;
            }
            setQueueSearchFilter(tag);
        });
        container.appendChild(tagEl);
    });

    row.appendChild(container);
    return row;
}

/**
 * Create OS logo element for display below priority pill
 * @param {string|null} os - The OS platform (iOS, Android, Firebase) or null for None
 * @param {string} className - CSS class name (backlog-os-logo or subitem-os-logo)
 * @param {boolean} isEditable - Whether the logo should be clickable (false for completed items)
 * @returns {HTMLElement} - The OS logo element
 */
function createOSLogoElement(os, className = 'backlog-os-logo', isEditable = true) {
    const logoEl = document.createElement('div');
    logoEl.className = className;
    logoEl.dataset.os = os || 'None';

    const config = OS_CONFIG[os] || OS_CONFIG['None'];
    logoEl.style.borderColor = config.color;
    logoEl.title = config.label;

    if (config.logo) {
        // Use image for iOS/Android/Firebase
        const img = document.createElement('img');
        img.src = config.logo;
        img.alt = config.label;
        logoEl.appendChild(img);
    } else {
        // Use inline SVG question mark for "None" (unspecified platform)
        logoEl.innerHTML = `<svg viewBox="0 0 24 24" fill="currentColor">
            <circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="2"/>
            <text x="12" y="17" text-anchor="middle" font-size="14" font-weight="bold" font-family="Arial, sans-serif">?</text>
        </svg>`;
    }

    if (!isEditable) {
        logoEl.classList.add('readonly');
    }

    return logoEl;
}

/**
 * Navigate to a blocker item or subitem (XACA-0025)
 * Handles both parent items (XACA-0016) and subitems (XACA-0016-001)
 * @param {string} blockerId - The ID of the blocker
 */
function navigateToBlocker(blockerId) {
    // Check if it's a subitem ID (XACA-0016-001 format)
    const subitemMatch = blockerId.match(/^(X[A-Z]{2,4}-\d+)-(\d+)$/);

    if (subitemMatch) {
        // It's a subitem - expand parent first
        const parentId = subitemMatch[1];
        const parentItem = document.querySelector(`.backlog-item[data-item-id="${parentId}"]`);

        if (parentItem) {
            // Expand parent if collapsed
            if (!parentItem.classList.contains('expanded')) {
                const expander = parentItem.querySelector('.subitem-expander');
                if (expander) expander.click();
            }

            // Find subitem after brief delay for expansion animation
            setTimeout(() => {
                const subitem = document.querySelector(`.subitem[data-subitem-id="${blockerId}"]`);
                if (subitem) {
                    subitem.scrollIntoView({ behavior: 'smooth', block: 'center' });
                    subitem.classList.add('highlight-pulse');
                    setTimeout(() => subitem.classList.remove('highlight-pulse'), 2000);
                }
            }, 100);
        }
    } else {
        // It's a parent item - existing logic
        const blockerItem = document.querySelector(`.backlog-item[data-item-id="${blockerId}"]`);
        if (blockerItem) {
            blockerItem.scrollIntoView({ behavior: 'smooth', block: 'center' });
            blockerItem.classList.add('highlight-pulse');
            setTimeout(() => blockerItem.classList.remove('highlight-pulse'), 2000);
        }
    }
}

/**
 * Activate dependency filter mode (XACA-0021)
 * Shows only the blocked item and its blockers when hovering over blocked-by row
 * @param {string} itemId - The ID of the blocked item
 * @param {string[]} blockerIds - Array of blocker IDs
 */
function activateDependencyFilter(itemId, blockerIds) {
    const backlogList = document.getElementById('mission-backlog');
    if (!backlogList) {
        console.warn('[LCARS] Dependency filter: backlog list not found');
        return;
    }

    console.log('[LCARS] Activating dependency filter for:', itemId, 'blocked by:', blockerIds);

    // Add filter mode to container
    backlogList.classList.add('dependency-filter-active');

    // Mark the source (blocked) item as visible
    // Handle both parent items and subitems as the source
    const sourceSubitemMatch = itemId.match(/^(X[A-Z]{2,4}-\d+)-(\d+)$/);

    if (sourceSubitemMatch) {
        // Source is a subitem - mark and expand its parent, and mark the specific subitem
        const parentId = sourceSubitemMatch[1];
        const parentItem = document.querySelector(`.backlog-item[data-item-id="${parentId}"]`);
        if (parentItem) {
            parentItem.classList.add('dependency-visible', 'dependency-source');
            // Auto-expand to show the subitem
            if (!parentItem.classList.contains('expanded')) {
                const expander = parentItem.querySelector('.subitem-expander');
                if (expander) expander.click();
            }
            // Mark the specific subitem as visible
            const sourceSubitem = parentItem.querySelector(`.subitem[data-subitem-id="${itemId}"]`);
            if (sourceSubitem) {
                sourceSubitem.classList.add('dependency-visible', 'dependency-source');
            }
            console.log('[LCARS] Marked source subitem parent visible:', parentId, 'for subitem:', itemId);
        } else {
            console.warn('[LCARS] Source subitem parent not found in DOM:', parentId);
        }
    } else {
        // Source is a parent item
        const sourceItem = document.querySelector(`.backlog-item[data-item-id="${itemId}"]`);
        if (sourceItem) {
            sourceItem.classList.add('dependency-visible', 'dependency-source');
            console.log('[LCARS] Marked source item visible:', itemId);
        } else {
            console.warn('[LCARS] Source item not found in DOM:', itemId);
        }
    }

    // Mark each blocker as visible
    blockerIds.forEach(blockerId => {
        // Handle both parent items (XACA-0016) and subitems (XACA-0016-001)
        const subitemMatch = blockerId.match(/^(X[A-Z]{2,4}-\d+)-(\d+)$/);

        if (subitemMatch) {
            // It's a subitem - mark the parent item visible, expand it, and mark the specific subitem
            const parentId = subitemMatch[1];
            const parentItem = document.querySelector(`.backlog-item[data-item-id="${parentId}"]`);
            if (parentItem) {
                parentItem.classList.add('dependency-visible');
                // Auto-expand to show the subitem
                if (!parentItem.classList.contains('expanded')) {
                    const expander = parentItem.querySelector('.subitem-expander');
                    if (expander) expander.click();
                }
                // Mark the specific blocker subitem as visible
                const blockerSubitem = parentItem.querySelector(`.subitem[data-subitem-id="${blockerId}"]`);
                if (blockerSubitem) {
                    blockerSubitem.classList.add('dependency-visible');
                }
            }
        } else {
            // It's a parent item
            const blockerItem = document.querySelector(`.backlog-item[data-item-id="${blockerId}"]`);
            if (blockerItem) {
                blockerItem.classList.add('dependency-visible');
            }
        }
    });
}

/**
 * Deactivate dependency filter mode (XACA-0021)
 * Restores normal view by removing all filter classes
 */
function deactivateDependencyFilter() {
    const backlogList = document.getElementById('mission-backlog');
    if (!backlogList) return;

    // Only log if filter was actually active
    if (backlogList.classList.contains('dependency-filter-active')) {
        console.log('[LCARS] Deactivating dependency filter');
    }

    // Remove filter mode from container
    backlogList.classList.remove('dependency-filter-active');

    // Remove visible/source classes from all items and subitems
    backlogList.querySelectorAll('.backlog-item.dependency-visible').forEach(item => {
        item.classList.remove('dependency-visible', 'dependency-source');
    });
    backlogList.querySelectorAll('.subitem.dependency-visible').forEach(subitem => {
        subitem.classList.remove('dependency-visible', 'dependency-source');
    });

    // Also remove filter-hover from any blocked rows or subitem blocker containers
    backlogList.querySelectorAll('.backlog-blocked-row.filter-hover, .subitem-blocker-container.filter-hover').forEach(row => {
        row.classList.remove('filter-hover');
    });
}

/**
 * Check if dependency filter is stuck and clear it (XACA-0021 safety fallback)
 * Called on document click to ensure filter doesn't get stuck
 */
function checkAndClearStuckDependencyFilter(event) {
    const backlogList = document.getElementById('mission-backlog');
    if (!backlogList || !backlogList.classList.contains('dependency-filter-active')) return;

    // If filter is active but no blocked row/container has filter-hover, it's stuck - clear it
    const activeHoverRow = backlogList.querySelector('.backlog-blocked-row.filter-hover, .subitem-blocker-container.filter-hover');
    if (!activeHoverRow) {
        console.log('[LCARS] Clearing stuck dependency filter');
        deactivateDependencyFilter();
    }
}

// Global click handler to clear stuck dependency filter
document.addEventListener('click', checkAndClearStuckDependencyFilter);

function createBacklogItem(item, index) {
    const div = document.createElement('div');
    const hasSubitems = item.subitems && item.subitems.length > 0;
    const isCollapsed = item.collapsed !== false; // Default to collapsed
    const isCompleted = item.status === 'completed';
    const isCancelled = item.status === 'cancelled';

    div.className = 'backlog-item';
    if (isCompleted) {
        div.classList.add('completed');
    } else if (isCancelled) {
        div.classList.add('cancelled');
    }
    if (hasSubitems) {
        div.classList.add('has-subitems');
        if (!isCollapsed) {
            div.classList.add('expanded');
        }
    }
    if (itemHasOverdue(item)) {
        div.classList.add('has-overdue');
    }
    if (item.activelyWorking) {
        div.classList.add('actively-working');
    }
    const itemPausedStatus = getPausedStatus(item.id);
    if (itemPausedStatus || itemIsPaused(item)) {
        div.classList.add('is-paused');
    }
    // Add blocked class for dependency-blocked items
    if (item.status === 'blocked' || (item.blockedBy && item.blockedBy.length > 0)) {
        div.classList.add('is-blocked');
    }
    div.dataset.itemIndex = index;
    div.dataset.itemId = item.id || '';

    // Header row container
    const header = document.createElement('div');
    header.className = 'backlog-header';

    // XACA-0046: Zone 1 - IDENTITY (left-aligned, always visible)
    const identityZone = document.createElement('div');
    identityZone.className = 'identity-zone';

    // Expand/collapse indicator (only for items with subitems)
    if (hasSubitems) {
        const expander = document.createElement('div');
        expander.className = 'subitem-expander';
        expander.textContent = isCollapsed ? '▶' : '▼';
        expander.title = isCollapsed ? 'Expand subitems' : 'Collapse subitems';
        expander.setAttribute('role', 'button');
        expander.setAttribute('aria-expanded', isCollapsed ? 'false' : 'true');
        expander.setAttribute('aria-label', isCollapsed ? 'Expand subitems' : 'Collapse subitems');
        expander.setAttribute('tabindex', '0');
        expander.addEventListener('click', (e) => {
            e.stopPropagation();
            toggleBacklogItemExpansion(div, item, index);
        });
        expander.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                e.stopPropagation();
                toggleBacklogItemExpansion(div, item, index);
            }
        });
        identityZone.appendChild(expander);
    }

    // Priority pill
    const currentOS = getOSFromTags(item.tags);
    const priority = document.createElement('div');
    const priorityValue = (item.priority || 'medium').toLowerCase();
    priority.className = `backlog-priority ${priorityValue}`;
    priority.textContent = priorityValue.toUpperCase();
    priority.setAttribute('aria-label', `Priority: ${priorityValue}`);
    // Only make editable if not completed
    if (!isCompleted) {
        priority.classList.add('editable');
        priority.title = 'Click to change priority';
        priority.setAttribute('role', 'button');
        priority.setAttribute('tabindex', '0');
        priority.addEventListener('click', (e) => {
            e.stopPropagation();
            showPriorityDropdown(priority, item, index);
        });
        priority.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                e.stopPropagation();
                showPriorityDropdown(priority, item, index);
            }
        });
    }
    identityZone.appendChild(priority);

    // Category pill (after priority)
    const category = document.createElement('div');
    if (item.category) {
        category.className = `backlog-category ${item.category.toLowerCase().replace(/\s+/g, '-')}`;
        category.textContent = item.category.toUpperCase();
        category.title = `Category: ${item.category}\nClick to change`;
        category.setAttribute('aria-label', `Category: ${item.category}`);
    } else {
        category.className = 'backlog-category no-category';
        category.textContent = 'NO CAT';
        category.title = 'No category assigned\nClick to set';
        category.setAttribute('aria-label', 'No category assigned');
    }
    // Make editable if not completed
    if (!isCompleted) {
        category.classList.add('editable');
        category.setAttribute('role', 'button');
        category.setAttribute('tabindex', '0');
        category.addEventListener('click', (e) => {
            e.stopPropagation();
            showCategoryDropdown(category, item, index);
        });
        category.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                e.stopPropagation();
                showCategoryDropdown(category, item, index);
            }
        });
    }
    identityZone.appendChild(category);

    // Due date pill - in identity zone for always-visible importance
    const dueDatePill = document.createElement('div');
    const effectiveDueDate = getEffectiveDueDate(item);
    if (effectiveDueDate) {
        const status = getDueDateStatus(effectiveDueDate.date);
        // Completed items should never show as overdue - use neutral 'was-due' class instead
        const displayStatus = (isCompleted && status === 'past_due') ? 'was-due' : status;
        dueDatePill.className = `backlog-due-date ${displayStatus.replaceAll('_', '-')}`;
        // Add inherited class if the date came from subitems
        if (effectiveDueDate.source === 'inherited') {
            dueDatePill.classList.add('inherited');
        }
        dueDatePill.textContent = formatDueDate(effectiveDueDate.date, isCompleted);
        const dueDateStr = parseLocalDate(effectiveDueDate.date).toLocaleDateString();
        if (!isCompleted) {
            dueDatePill.classList.add('editable');
            const sourceLabel = effectiveDueDate.source === 'inherited' ? ' (from subitems)' : '';
            dueDatePill.title = `Due: ${dueDateStr}${sourceLabel} - Click to edit`;
            dueDatePill.setAttribute('aria-label', `Due date: ${dueDateStr}${sourceLabel}`);
            dueDatePill.setAttribute('role', 'button');
            dueDatePill.setAttribute('tabindex', '0');
        } else {
            const sourceLabel = effectiveDueDate.source === 'inherited' ? ' (from subitems)' : '';
            dueDatePill.title = `Due: ${dueDateStr}${sourceLabel}`;
            dueDatePill.setAttribute('aria-label', `Due date: ${dueDateStr}${sourceLabel}`);
        }
    } else {
        dueDatePill.className = 'backlog-due-date no-date';
        if (!isCompleted) {
            dueDatePill.classList.add('editable');
            dueDatePill.textContent = '+DUE';
            dueDatePill.title = 'Click to set due date';
            dueDatePill.setAttribute('aria-label', 'No due date set');
            dueDatePill.setAttribute('role', 'button');
            dueDatePill.setAttribute('tabindex', '0');
        } else {
            dueDatePill.textContent = 'NO DUE';
            dueDatePill.title = 'No due date was set';
            dueDatePill.setAttribute('aria-label', 'No due date');
        }
    }
    if (!isCompleted) {
        dueDatePill.addEventListener('click', (e) => {
            e.stopPropagation();
            showDueDateEditor(dueDatePill, item, index);
        });
        dueDatePill.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                e.stopPropagation();
                showDueDateEditor(dueDatePill, item, index);
            }
        });
    }
    identityZone.appendChild(dueDatePill);

    // XACA-0624: Points (effort estimate) pill — sibling to due-date pill
    // Displays "<n>h" when estimated, "—" when null/absent.
    const pointsPill = document.createElement('div');
    const hasPoints = (item.points != null && typeof item.points === 'number' && item.points >= 0);
    if (hasPoints) {
        pointsPill.className = 'backlog-points';
        pointsPill.textContent = `${item.points}h`;
        pointsPill.title = `Estimate: ${item.points} developer-hour${item.points === 1 ? '' : 's'}`;
        pointsPill.setAttribute('aria-label', `Effort estimate: ${item.points}h`);
        if (!isCompleted) {
            pointsPill.classList.add('editable');
            pointsPill.title += ' — Click to edit';
        }
    } else {
        pointsPill.className = 'backlog-points no-estimate';
        if (!isCompleted) {
            pointsPill.classList.add('editable');
            pointsPill.textContent = '—'; // em dash
            pointsPill.title = 'No estimate — Click to set developer-hours';
            pointsPill.setAttribute('aria-label', 'No effort estimate set');
        } else {
            pointsPill.textContent = '—';
            pointsPill.title = 'No estimate was set';
            pointsPill.setAttribute('aria-label', 'No effort estimate');
        }
    }
    if (!isCompleted) {
        pointsPill.setAttribute('role', 'button');
        pointsPill.setAttribute('tabindex', '0');
        pointsPill.addEventListener('click', (e) => {
            e.stopPropagation();
            showPointsEditor(pointsPill, item, index);
        });
        pointsPill.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                e.stopPropagation();
                showPointsEditor(pointsPill, item, index);
            }
        });
    }
    identityZone.appendChild(pointsPill);

    // XACA-0067-003: Developer avatar (shows who's working on this item)
    // Try direct workingOnId match first, then fall back to worktreeWindowId lookup
    const workingWindow = getWorkingWindow(item.id);
    const effectiveWindow = workingWindow || (item.activelyWorking && item.worktreeWindowId ? getWindowById(item.worktreeWindowId) : null);
    const avatarTerminal = effectiveWindow?.terminal || (item.activelyWorking && item.worktreeWindowId ? item.worktreeWindowId.split(':')[0] : null);
    if (avatarTerminal) {
        const backlogAvatar = document.createElement('img');
        backlogAvatar.className = 'backlog-item-avatar lcars-avatar';
        backlogAvatar.src = getDeveloperAvatarUrl(boardData?.team, avatarTerminal);
        backlogAvatar.alt = effectiveWindow?.developer || boardData?.terminals?.[avatarTerminal]?.developer || avatarTerminal;
        backlogAvatar.dataset.developer = effectiveWindow?.developer || boardData?.terminals?.[avatarTerminal]?.developer || avatarTerminal;
        backlogAvatar.dataset.role = boardData?.terminals?.[avatarTerminal]?.role || '';
        backlogAvatar.dataset.terminal = avatarTerminal || '';
        backlogAvatar.onerror = function() { this.style.display = 'none'; };
        identityZone.appendChild(backlogAvatar);
    }

    const idx = document.createElement('div');
    idx.className = 'backlog-index';
    idx.textContent = `[${item.id || index}]`;
    idx.setAttribute('role', 'button');
    idx.setAttribute('tabindex', '0');
    idx.setAttribute('aria-label', `Item ID: ${item.id || index}. Click to copy.`);
    idx.title = 'Click to copy ID to clipboard';
    idx.addEventListener('click', (e) => {
        e.stopPropagation();
        copyToClipboard(item.id || index);
    });
    idx.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            e.stopPropagation();
            copyToClipboard(item.id || index);
        }
    });
    identityZone.appendChild(idx);

    header.appendChild(identityZone);

    // XACA-0046: Zone 2 - TITLE (center, flex-grow, always visible)
    const titleZone = document.createElement('div');
    titleZone.className = 'title-zone';

    const title = document.createElement('div');
    title.className = 'backlog-title';
    title.textContent = item.title || 'Untitled mission';
    titleZone.appendChild(title);

    header.appendChild(titleZone);

    // XACA-0046: Zone 4 - WORKFLOW (right-aligned, always visible if active)
    const workflowZone = document.createElement('div');
    workflowZone.className = 'workflow-zone';

    // XACA-0020: Working window badge (shows which terminal is actively working on this)
    // workingWindow already declared above for avatar (line 1683)
    if (workingWindow || (item.activelyWorking && item.worktreeWindowId)) {
        const windowBadge = document.createElement('div');
        windowBadge.className = 'backlog-window-badge';

        // Prefer live window info, fall back to stored worktreeWindowId
        const windowId = workingWindow?.windowId || item.worktreeWindowId;
        const developer = workingWindow?.developer || 'Unknown';
        const windowStatus = workingWindow?.status || 'working';

        // Extract just the terminal:window for display
        const displayWindow = windowId || 'unknown';
        windowBadge.textContent = `⚡ ${displayWindow}`;
        windowBadge.title = `Working in: ${windowId}\nDeveloper: ${developer}\nStatus: ${windowStatus}`;
        windowBadge.setAttribute('aria-label', `Working in window: ${windowId}, Developer: ${developer}, Status: ${windowStatus}`);

        // Add status-based styling
        if (windowStatus === 'paused') {
            windowBadge.classList.add('paused');
        } else if (windowStatus === 'coding') {
            windowBadge.classList.add('coding');
        } else if (windowStatus === 'planning') {
            windowBadge.classList.add('planning');
        }
        workflowZone.appendChild(windowBadge);
    }

    // Worktree badge (if actively working with worktree info) - now secondary to window badge
    if (item.activelyWorking && item.worktreeBranch && !workingWindow) {
        const worktreeBadge = document.createElement('div');
        worktreeBadge.className = 'backlog-worktree-badge';
        // Show branch name (truncated if long)
        const branchName = item.worktreeBranch;
        const displayBranch = branchName.length > 25 ? branchName.substring(0, 22) + '...' : branchName;
        worktreeBadge.textContent = `🌳 ${displayBranch}`;
        worktreeBadge.title = `Worktree: ${item.worktree || 'unknown'}\nBranch: ${branchName}\nWindow: ${item.worktreeWindowId || 'unknown'}`;
        worktreeBadge.setAttribute('aria-label', `Worktree branch: ${branchName}`);
        workflowZone.appendChild(worktreeBadge);
    }

    // Tags in workflow zone (after badges)
    const tagsElement = createTagsElement(item.tags);
    if (tagsElement) {
        tagsElement.classList.add('header-tags');
        workflowZone.appendChild(tagsElement);
    }

    // NOTE: workflowZone appended AFTER trackingZone (see below) so tracking slides in to the LEFT of tags

    // XACA-0046: Zone 3 - TRACKING (hover-to-reveal, positioned)
    const trackingZone = document.createElement('div');
    trackingZone.className = 'tracking-zone';
    trackingZone.setAttribute('aria-hidden', 'true'); // Hidden by default, revealed on hover

    // XACA-0040: Epic assignment badge (XACA-0050: Use shortTitle when available)
    const epicBadge = document.createElement('div');
    if (item.epicId) {
        // XACA-0050: Look up epic for shortTitle - display shortTitle exactly, only truncate fallback
        const epic = boardData?.epics?.find(e => e.id === item.epicId);
        const epicFullTitle = getEpicTitleById(item.epicId) || item.epicName || item.epicId;
        let displayName;
        if (epic?.shortTitle) {
            // If shortTitle exists, use it exactly as-is (no truncation)
            displayName = epic.shortTitle;
        } else {
            // Fallback: truncate full title for display (first 15 chars)
            const fallbackName = epicFullTitle;
            displayName = fallbackName.length > 15 ? fallbackName.substring(0, 15) + '…' : fallbackName;
        }
        epicBadge.className = 'backlog-epic-badge assigned';
        const epicNameSpan = document.createElement('span');
        epicNameSpan.className = 'backlog-epic-badge-name';
        epicNameSpan.textContent = displayName;
        epicBadge.appendChild(epicNameSpan);
        epicBadge.title = `Epic: ${epicFullTitle}\nID: ${item.epicId}\nClick to change`;
        epicBadge.setAttribute('aria-label', `Epic: ${epicFullTitle}`);
    } else {
        epicBadge.className = 'backlog-epic-badge';
        epicBadge.textContent = '+EPIC';
        epicBadge.title = 'Click to assign to an epic';
        epicBadge.setAttribute('aria-label', 'No epic assigned');
    }
    // XACA-0121: Epic badge is always editable (removed XACA-0056 isCompleted guard)
    epicBadge.classList.add('editable');
    epicBadge.setAttribute('role', 'button');
    epicBadge.setAttribute('tabindex', '0');
    epicBadge.addEventListener('click', (e) => {
        e.stopPropagation();
        showEpicAssignModal(item.id, item.title, CONFIG.team, item.epicId);
    });
    epicBadge.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            e.stopPropagation();
            showEpicAssignModal(item.id, item.title, CONFIG.team, item.epicId);
        }
    });
    trackingZone.appendChild(epicBadge);

    // XACA-0023: Release assignment badge
    const releaseBadge = document.createElement('div');
    if (item.releaseAssignment) {
        const releaseId = item.releaseAssignment.releaseId;
        // Look up release details from board releases
        let releaseName = item.releaseAssignment.releaseName;
        let releaseShortTitle = null;

        // Always check boardData for shortTitle and fallback name
        if (boardData && boardData.releases) {
            let release = boardData.releases.find(r => r.id === releaseId);
            // XACA-0056: Also check archived releases if not found in active
            if (!release && boardData.archivedReleases) {
                release = boardData.archivedReleases.find(r => r.id === releaseId);
            }
            if (release) {
                // XACA-0050: Always get shortTitle when available
                releaseShortTitle = release.shortTitle;
                // Use board's name if assignment doesn't have one
                if (!releaseName) {
                    releaseName = release.name;
                }
            }
        }
        releaseName = releaseName || releaseId; // Final fallback to ID

        // XACA-0050: Display shortTitle exactly as-is, only truncate fallback name
        let displayName;
        if (releaseShortTitle) {
            // If shortTitle exists, use it exactly (no truncation)
            displayName = releaseShortTitle;
        } else {
            // Fallback: truncate full name for display (first 20 chars)
            displayName = releaseName.length > 20 ? releaseName.substring(0, 20) + '…' : releaseName;
        }

        releaseBadge.className = 'backlog-release-badge assigned';
        const releaseNameSpan = document.createElement('span');
        releaseNameSpan.className = 'backlog-release-badge-name';
        releaseNameSpan.textContent = displayName;
        releaseBadge.appendChild(releaseNameSpan);
        releaseBadge.title = `Release: ${releaseName}\nID: ${releaseId}\nPlatform: ${item.releaseAssignment.platform}\nClick to change`;
        releaseBadge.setAttribute('aria-label', `Release: ${releaseName}, Platform: ${item.releaseAssignment.platform}`);
    } else {
        releaseBadge.className = 'backlog-release-badge';
        releaseBadge.textContent = '+REL';
        releaseBadge.title = 'Click to assign to a release';
        releaseBadge.setAttribute('aria-label', 'No release assigned');
    }
    // XACA-0121: Release badge is always editable (removed XACA-0056 isCompleted guard)
    releaseBadge.classList.add('editable');
    releaseBadge.setAttribute('role', 'button');
    releaseBadge.setAttribute('tabindex', '0');
    releaseBadge.addEventListener('click', (e) => {
        e.stopPropagation();
        showReleaseAssignModal(item.id, item.title, CONFIG.team, item.releaseAssignment);
    });
    releaseBadge.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            e.stopPropagation();
            showReleaseAssignModal(item.id, item.title, CONFIG.team, item.releaseAssignment);
        }
    });
    trackingZone.appendChild(releaseBadge);

    // Due date pill moved to identity zone (always visible)

    // JIRA link (if present) - supports jiraId, jiraKey, and jira field names
    // Click to edit, Cmd/Ctrl+Click to open in Jira
    // XACA-0056: Read-only for completed items
    const jiraTicket = item.jiraId || item.jiraKey || item.jira;
    if (jiraTicket) {
        const jiraLink = document.createElement('a');
        jiraLink.className = isCompleted ? 'backlog-jira readonly' : 'backlog-jira editable';
        jiraLink.href = getJiraUrl(jiraTicket);
        jiraLink.target = '_blank';
        jiraLink.rel = 'noopener noreferrer';
        jiraLink.textContent = jiraTicket;
        jiraLink.title = isCompleted ? `${jiraTicket} - Cmd+Click to open` : `${jiraTicket} - Click to edit, Cmd+Click to open`;
        jiraLink.setAttribute('aria-label', `JIRA ticket: ${jiraTicket}`);

        if (!isCompleted) {
            jiraLink.addEventListener('click', (e) => {
                // Cmd/Ctrl+Click opens the link normally
                if (e.metaKey || e.ctrlKey) {
                    return; // Let default behavior happen
                }
                e.preventDefault();
                e.stopPropagation();
                showJiraEditor(jiraLink, item, index);
            });
        }

        trackingZone.appendChild(jiraLink);
    } else if (!isCompleted) {
        // No Jira ID - show "+LINK" button to add one (only for non-completed items)
        const addJiraBtn = document.createElement('a');
        addJiraBtn.className = 'backlog-jira add-jira editable';
        addJiraBtn.textContent = '+LINK';
        addJiraBtn.title = 'Click to link ticket';
        addJiraBtn.setAttribute('role', 'button');
        addJiraBtn.setAttribute('tabindex', '0');
        addJiraBtn.setAttribute('aria-label', 'Add JIRA ticket link');

        addJiraBtn.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            showJiraEditor(addJiraBtn, item, index);
        });
        addJiraBtn.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                e.stopPropagation();
                showJiraEditor(addJiraBtn, item, index);
            }
        });

        trackingZone.appendChild(addJiraBtn);
    }

    // GitHub issue link (if present) - supports githubIssue field
    // Format: "owner/repo#123" (full) or "#123" (uses team default)
    const githubIssue = item.githubIssue || item.github;
    if (githubIssue) {
        const githubLink = document.createElement('a');
        githubLink.className = 'backlog-github';
        githubLink.href = getGitHubUrl(githubIssue, CONFIG.team);
        githubLink.target = '_blank';
        githubLink.rel = 'noopener noreferrer';
        githubLink.textContent = formatGitHubIssue(githubIssue);
        githubLink.title = `Open ${githubIssue} on GitHub`;
        githubLink.setAttribute('aria-label', `GitHub issue: ${githubIssue}`);
        trackingZone.appendChild(githubLink);
    }

    // XACA-0045: Plan document button (conditionally displayed)
    const docsButton = document.createElement('div');
    docsButton.className = 'backlog-docs-btn';
    docsButton.textContent = 'DOCS';
    docsButton.title = 'View plan document';
    docsButton.style.display = 'none'; // Hidden by default until we check
    docsButton.setAttribute('role', 'button');
    docsButton.setAttribute('tabindex', '0');
    docsButton.setAttribute('aria-label', 'View plan document');
    docsButton.addEventListener('click', (e) => {
        e.stopPropagation();
        showPlanDocModal(item.id, docsButton.getAttribute('data-retro-exists') === 'true', docsButton.getAttribute('data-cr-exists') === 'true');
    });
    docsButton.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            e.stopPropagation();
            showPlanDocModal(item.id, docsButton.getAttribute('data-retro-exists') === 'true', docsButton.getAttribute('data-cr-exists') === 'true');
        }
    });
    trackingZone.appendChild(docsButton);

    // Check if plan document exists (async)
    checkPlanExists(item.id, docsButton);

    // XACA-0117: Activity timeline button
    const activityBtn = document.createElement('div');
    activityBtn.className = 'backlog-activity-btn';
    activityBtn.textContent = '\u25D7'; // ◗ clock-like history symbol
    activityBtn.title = 'View activity history';
    activityBtn.setAttribute('role', 'button');
    activityBtn.setAttribute('tabindex', '0');
    activityBtn.setAttribute('aria-label', 'View activity history');
    activityBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        ActivityTimeline.open(item.id);
    });
    activityBtn.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            e.stopPropagation();
            ActivityTimeline.open(item.id);
        }
    });
    trackingZone.appendChild(activityBtn);

    header.appendChild(trackingZone);
    header.appendChild(workflowZone); // Appended AFTER trackingZone so tags stay to the right

    // XACA-0046: aria-hidden now controlled by view toggle, not hover

    // Paused state now indicated by pulsing left-edge via is-paused class (XACA-0022)

    div.appendChild(header);

    // Blocked by pills row (XACA-0020)
    if (item.blockedBy && item.blockedBy.length > 0) {
        const blockedRow = document.createElement('div');
        blockedRow.className = 'backlog-blocked-row';

        const blockedLabel = document.createElement('span');
        blockedLabel.className = 'blocked-label';
        blockedLabel.textContent = 'Blocked by: ';
        blockedRow.appendChild(blockedLabel);

        item.blockedBy.forEach(blockerId => {
            const blockerPill = document.createElement('span');
            blockerPill.className = 'blocker-pill';
            blockerPill.textContent = blockerId;
            blockerPill.title = `Click to view ${blockerId}`;
            blockerPill.setAttribute('role', 'button');
            blockerPill.setAttribute('tabindex', '0');
            blockerPill.setAttribute('aria-label', `View blocker: ${blockerId}`);
            blockerPill.addEventListener('click', (e) => {
                e.stopPropagation();
                navigateToBlocker(blockerId);  // XACA-0025: Use shared navigation helper
            });
            blockerPill.addEventListener('keydown', (e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    e.stopPropagation();
                    navigateToBlocker(blockerId);
                }
            });
            blockedRow.appendChild(blockerPill);
        });

        // Hover-to-filter: show only this item and its blockers (XACA-0021)
        const itemId = item.id;
        const blockerIds = [...item.blockedBy];
        blockedRow.addEventListener('mouseenter', () => {
            blockedRow.classList.add('filter-hover');
            activateDependencyFilter(itemId, blockerIds);
        });
        blockedRow.addEventListener('mouseleave', () => {
            blockedRow.classList.remove('filter-hover');
            deactivateDependencyFilter();
        });

        div.appendChild(blockedRow);
    }

    // Content row: [OS logo] [description] ... [subitem count] [timestamp]
    const hasDescription = item.description && item.description.trim();

    const contentArea = document.createElement('div');
    contentArea.className = 'backlog-content-area';

    // OS Logo (clickable to change OS)
    const contentOsLogo = createOSLogoElement(currentOS, 'backlog-os-logo-inline', !isCompleted);
    if (!isCompleted) {
        contentOsLogo.classList.add('editable');
        contentOsLogo.setAttribute('role', 'button');
        contentOsLogo.setAttribute('tabindex', '0');
        contentOsLogo.setAttribute('aria-label', `Platform: ${currentOS || 'Not set'}. Click to change.`);
        contentOsLogo.addEventListener('click', (e) => {
            e.stopPropagation();
            showOSDropdown(contentOsLogo, item, index);
        });
        contentOsLogo.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                e.stopPropagation();
                showOSDropdown(contentOsLogo, item, index);
            }
        });
    } else {
        contentOsLogo.setAttribute('aria-label', `Platform: ${currentOS || 'Not set'}`);
    }
    contentArea.appendChild(contentOsLogo);

    // Description (to the right of OS logo)
    if (hasDescription) {
        const description = document.createElement('div');
        description.className = 'backlog-description';
        description.textContent = item.description;
        contentArea.appendChild(description);
    }

    // Spacer to push meta to the right
    const spacer = document.createElement('div');
    spacer.className = 'backlog-spacer';
    contentArea.appendChild(spacer);

    // Meta info (subitem count + timestamp) on right
    if (hasSubitems) {
        const completedCount = item.subitems.filter(s => s.status === 'completed' || s.status === 'cancelled').length;
        const totalCount = item.subitems.length;
        const countBadge = document.createElement('div');
        countBadge.className = 'subitem-count';
        countBadge.textContent = `${completedCount}/${totalCount}`;
        countBadge.title = `${completedCount} of ${totalCount} subitems resolved`;
        if (completedCount === totalCount) {
            countBadge.classList.add('all-complete');
        }
        contentArea.appendChild(countBadge);
    }

    const timestamp = document.createElement('div');
    timestamp.className = 'backlog-timestamp';
    if (isCompleted) {
        timestamp.textContent = '✓ ' + formatAbsoluteTime(item.completedAt);
        timestamp.title = 'Completed: ' + formatRelativeTime(item.completedAt);
        // XACA-0029: Show rolled-up time worked for completed parent items
        const totalWorkTime = calculateParentWorkTime(item);
        if (totalWorkTime > 0) {
            const workTimeStr = formatWorkTime(totalWorkTime);
            if (workTimeStr) {
                const workTimeSpan = document.createElement('span');
                workTimeSpan.className = 'item-time-worked';
                workTimeSpan.textContent = ` (${workTimeStr})`;
                workTimeSpan.title = `Total time worked: ${workTimeStr}`;
                timestamp.appendChild(workTimeSpan);
            }
        }
        // XACA-0551: Active effort on the parent item itself
        const activeEffort = calculateActiveEffort(item);
        if (activeEffort > 0) {
            const effortStr = formatWorkTime(activeEffort);
            if (effortStr) {
                const effortSpan = document.createElement('span');
                effortSpan.className = 'item-time-worked item-active-effort';
                effortSpan.textContent = ` ⏱ ${effortStr}`;
                effortSpan.title = `Active effort: ${effortStr}`;
                timestamp.appendChild(effortSpan);
            }
        }
        // XACA-0551: Lead time for completed items (createdAt||addedAt → completedAt)
        const leadOrigin = item.createdAt || item.addedAt;
        const leadTimeMs = item.leadTimeMs ||
            ((item.completedAt && leadOrigin)
                ? Math.max(0, new Date(item.completedAt).getTime() - new Date(leadOrigin).getTime())
                : 0);
        if (leadTimeMs > 0) {
            const leadStr = formatLeadTime(leadTimeMs);
            if (leadStr) {
                const leadSpan = document.createElement('span');
                leadSpan.className = 'item-lead-time';
                leadSpan.textContent = ` · ${leadStr} lead`;
                leadSpan.title = `Lead time (created → completed): ${leadStr}`;
                timestamp.appendChild(leadSpan);
            }
        }
    } else {
        const displayTime = item.updatedAt || item.addedAt;
        timestamp.textContent = formatRelativeTime(displayTime);
        const label = item.updatedAt ? 'Last Updated' : 'Created';
        timestamp.title = label + ': ' + formatAbsoluteTime(displayTime);
        // XACA-0029: Show rolled-up time worked from completed subitems (partial progress)
        const totalWorkTime = calculateParentWorkTime(item);
        if (totalWorkTime > 0) {
            const workTimeStr = formatWorkTime(totalWorkTime);
            if (workTimeStr) {
                const workTimeSpan = document.createElement('span');
                workTimeSpan.className = 'item-time-worked partial';
                workTimeSpan.textContent = ` (${workTimeStr} worked)`;
                workTimeSpan.title = `Time worked on completed subitems: ${workTimeStr}`;
                timestamp.appendChild(workTimeSpan);
            }
        }
        // XACA-0551: Active effort on parent item (accumulated + any live in-flight span)
        const activeEffort = calculateActiveEffort(item);
        if (activeEffort > 0) {
            const effortStr = formatWorkTime(activeEffort);
            if (effortStr) {
                const effortSpan = document.createElement('span');
                effortSpan.className = 'item-time-worked item-active-effort';
                effortSpan.textContent = ` ⏱ ${effortStr}`;
                // XACA-0552: only label "live" when the span is actually accruing —
                // a completed/cancelled item with a stale workStartedAt is frozen.
                const isLiveEffort = item.workStartedAt
                    && item.status !== 'completed' && item.status !== 'cancelled';
                effortSpan.title = isLiveEffort
                    ? `Active effort (including live session): ${effortStr}`
                    : `Active effort: ${effortStr}`;
                timestamp.appendChild(effortSpan);
            }
        }
        // XACA-0551: Live lead time for in-progress items (startedAt/createdAt → now)
        if (item.status === 'in_progress' || item.activelyWorking) {
            const liveLeadMs = calculateLiveLeadTime(item);
            if (liveLeadMs > 0) {
                const leadStr = formatLeadTime(liveLeadMs);
                if (leadStr) {
                    const leadSpan = document.createElement('span');
                    leadSpan.className = 'item-lead-time item-lead-time-live';
                    leadSpan.textContent = ` · ${leadStr} open`;
                    leadSpan.title = `Lead time so far (created → now): ${leadStr}`;
                    timestamp.appendChild(leadSpan);
                }
            }
        }
    }

    // XACA-0053: Status change button for ALL items (not just completed)
    // Allows changing to any status including completing or reverting
    const statusBtn = document.createElement('button');
    statusBtn.className = 'status-change-btn';
    statusBtn.innerHTML = '⇄';
    statusBtn.title = 'Change status';
    statusBtn.setAttribute('aria-label', 'Change item status');
    statusBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        // Show status selection modal
        showStatusChangeModal(item, false, (selectedStatus) => {
            // Show confirmation dialog
            showStatusChangeConfirmDialog(item, selectedStatus, false,
                async () => {
                    // User confirmed - use helper function to change the status
                    const success = await changeItemStatus(item, selectedStatus);
                    if (!success) {
                        alert('Failed to change status. Check console for details.');
                    }
                },
                () => {
                    // User cancelled - do nothing
                    console.log('Status change cancelled');
                }
            );
        });
    });
    timestamp.appendChild(statusBtn);

    contentArea.appendChild(timestamp);

    div.appendChild(contentArea);

    // XACA-0551: Time metrics detail row — shown in expanded view (CSS controls visibility).
    // XACA-0624: Also shows points (effort estimate) when present.
    // Displays Active effort, Lead time, and Estimate with clear labels when data is present.
    (function appendTimeMetricsRow() {
        const activeEffort = calculateActiveEffort(item);
        const isInProgress = item.status === 'in_progress' || item.activelyWorking;
        const liveLeadMs = (isCompleted || isInProgress) ? calculateLiveLeadTime(item) : 0;
        const leadOriginMetrics = item.createdAt || item.addedAt;
        const leadTimeMs = item.leadTimeMs ||
            ((isCompleted && item.completedAt && leadOriginMetrics)
                ? Math.max(0, new Date(item.completedAt).getTime() - new Date(leadOriginMetrics).getTime())
                : liveLeadMs);

        const hasEffort = activeEffort > 0;
        const hasLead = leadTimeMs > 0;
        // XACA-0624: points is a top-level field (number >=0); null/absent = unestimated
        const hasPoints = (item.points != null && typeof item.points === 'number' && item.points >= 0);
        if (!hasEffort && !hasLead && !hasPoints) return;

        const metricsRow = document.createElement('div');
        metricsRow.className = 'item-time-metrics-row';

        // XACA-0624: Points (estimate) shown first in the detail row
        if (hasPoints) {
            const pointsEl = document.createElement('span');
            pointsEl.className = 'item-metrics-points';
            pointsEl.innerHTML = `<span class="item-metrics-label">Estimate:</span> ${item.points}h`;
            pointsEl.title = `Developer-hours estimate: ${item.points}h`;
            metricsRow.appendChild(pointsEl);
        }

        if (hasEffort) {
            const effortStr = formatWorkTime(activeEffort);
            if (effortStr) {
                const effortEl = document.createElement('span');
                effortEl.className = 'item-metrics-effort';
                // XACA-0552: a completed/cancelled item with a stale workStartedAt is
                // frozen — don't tag it "(live)".
                const isLiveEffort = item.workStartedAt
                    && item.status !== 'completed' && item.status !== 'cancelled';
                const liveIndicator = isLiveEffort ? ' (live)' : '';
                effortEl.innerHTML = `<span class="item-metrics-label">Active effort:</span> ${effortStr}${liveIndicator}`;
                effortEl.title = isLiveEffort
                    ? `Accumulated effort plus current in-flight session`
                    : `Total accumulated active effort`;
                metricsRow.appendChild(effortEl);
            }
        }

        if (hasLead) {
            const leadStr = formatLeadTime(leadTimeMs);
            if (leadStr) {
                const leadEl = document.createElement('span');
                leadEl.className = 'item-metrics-lead';
                const leadLabel = isCompleted ? 'Lead time:' : 'Open for:';
                leadEl.innerHTML = `<span class="item-metrics-label">${leadLabel}</span> ${leadStr}`;
                leadEl.title = isCompleted
                    ? `Wall-clock time from creation to completion`
                    : `Wall-clock time since first started (creation → now)`;
                metricsRow.appendChild(leadEl);
            }
        }

        if (metricsRow.childNodes.length > 0) {
            div.appendChild(metricsRow);
        }
    })();

    // Subitems container (collapsed/expanded state handled by CSS)
    if (hasSubitems) {
        const subitemsContainer = document.createElement('div');
        subitemsContainer.className = 'subitems-container';
        // CSS handles visibility via .backlog-item.expanded class

        // Sort subitems: completed last, then by blocking, due date, and priority
        const priorityOrder = { critical: 0, high: 1, medium: 2, low: 3 };
        const getPriorityValue = (sub) => {
            const priority = (sub.priority || 'medium').toLowerCase();
            return priorityOrder[priority] !== undefined ? priorityOrder[priority] : 2;
        };
        const getDueDateValue = (sub) => {
            // Returns timestamp for sorting, Infinity if no due date
            return sub.dueDate ? new Date(sub.dueDate).getTime() : Infinity;
        };

        const sortedSubitems = [...item.subitems].map((sub, idx) => ({ sub, originalIndex: idx }));
        sortedSubitems.sort((a, b) => {
            const aCompleted = a.sub.status === 'completed';
            const bCompleted = b.sub.status === 'completed';
            // Completed items go to the end
            if (aCompleted && !bCompleted) return 1;
            if (!aCompleted && bCompleted) return -1;
            // Both completed: sort by completedAt descending (most recent first)
            if (aCompleted && bCompleted) {
                const dateA = a.sub.completedAt ? new Date(a.sub.completedAt) : new Date(0);
                const dateB = b.sub.completedAt ? new Date(b.sub.completedAt) : new Date(0);
                return dateB - dateA;
            }
            // Both non-completed: first check blocking relationship (blocker sorts first)
            const aBlocksBSub = Array.isArray(b.sub.blockedBy) && b.sub.blockedBy.includes(a.sub.id);
            const bBlocksASub = Array.isArray(a.sub.blockedBy) && a.sub.blockedBy.includes(b.sub.id);
            if (aBlocksBSub && !bBlocksASub) return -1;  // A blocks B, A comes first
            if (bBlocksASub && !aBlocksBSub) return 1;   // B blocks A, B comes first
            // No blocking: sort by due date (earliest first, no due date last)
            const aDueDate = getDueDateValue(a.sub);
            const bDueDate = getDueDateValue(b.sub);
            if (aDueDate !== bDueDate) return aDueDate - bDueDate;
            // Same due date: sort by priority (critical > high > medium > low)
            const aPriority = getPriorityValue(a.sub);
            const bPriority = getPriorityValue(b.sub);
            if (aPriority !== bPriority) return aPriority - bPriority;
            // Same priority: preserve original order
            return 0;
        });

        sortedSubitems.forEach(({ sub, originalIndex }) => {
            const subitemEl = createSubitemElement(sub, item, index, originalIndex);
            subitemsContainer.appendChild(subitemEl);
        });

        div.appendChild(subitemsContainer);
    }

    return div;
}

function createSubitemElement(subitem, parentItem, parentIndex, subIndex) {
    const div = document.createElement('div');
    div.className = 'subitem';
    // If parent item is cancelled, all subitems display as cancelled
    if (parentItem.status === 'cancelled') {
        div.classList.add('cancelled');
    } else if (subitem.status === 'completed') {
        div.classList.add('completed');
    } else if (subitem.status === 'cancelled') {
        div.classList.add('cancelled');
    } else if (subitem.status === 'in_progress') {
        div.classList.add('in-progress');
    }
    if (subitem.activelyWorking) {
        div.classList.add('actively-working');
    }
    const subitemPausedStatus = getPausedStatus(subitem.id);
    if (subitemPausedStatus) {
        div.classList.add('is-paused');
    }
    // Add blocked class for dependency-blocked subitems (XACA-0025)
    if (subitem.status === 'blocked' || (subitem.blockedBy && subitem.blockedBy.length > 0)) {
        div.classList.add('is-blocked');
    }
    div.dataset.parentIndex = parentIndex;
    div.dataset.subIndex = subIndex;
    div.dataset.subitemId = subitem.id || '';  // XACA-0025: Enable navigation to subitems

    // Subitem header
    const header = document.createElement('div');
    header.className = 'subitem-header';

    // XACA-0053: Status indicator - now clickable for ALL subitems to change status
    const statusIndicator = document.createElement('div');
    statusIndicator.className = 'subitem-status-indicator clickable';
    statusIndicator.title = 'Click to change status';

    // Set icon based on current status
    if (subitem.status === 'completed') {
        statusIndicator.textContent = '✓';
        statusIndicator.classList.add('completed');
    } else if (subitem.status === 'in_progress') {
        statusIndicator.textContent = '●';
        statusIndicator.classList.add('in-progress');
    } else {
        statusIndicator.textContent = '○';
    }

    // Wire up status change functionality for ALL subitems
    statusIndicator.addEventListener('click', (e) => {
        e.stopPropagation();

        // Show status selection modal
        showStatusChangeModal(subitem, true, (selectedStatus) => {
            // Show confirmation dialog
            showStatusChangeConfirmDialog(subitem, selectedStatus, true,
                // onConfirm - change the subitem status
                async () => {
                    // Pass indices for API call
                    const success = await changeSubitemStatus(subitem, selectedStatus, parentItem, parentIndex, subIndex);
                    if (!success) {
                        alert('Failed to change subitem status. Check console for details.');
                    }
                },
                // onCancel - do nothing
                () => {
                    console.log('Status change cancelled');
                }
            );
        });
    });

    header.appendChild(statusIndicator);

    const isSubitemCompleted = subitem.status === 'completed';

    // OS Logo (to the left of priority pill)
    const currentOS = getOSFromTags(subitem.tags);
    const osLogo = createOSLogoElement(currentOS, 'subitem-os-logo', !isSubitemCompleted);
    if (!isSubitemCompleted) {
        osLogo.classList.add('editable');
        osLogo.addEventListener('click', (e) => {
            e.stopPropagation();
            showSubitemOSDropdown(osLogo, subitem, parentIndex, subIndex);
        });
    }
    header.appendChild(osLogo);

    // Priority pill (editable only if not completed)
    const priority = document.createElement('div');
    const priorityValue = (subitem.priority || 'medium').toLowerCase();
    priority.className = `backlog-priority subitem-priority ${priorityValue}`;
    priority.textContent = priorityValue.substring(0, 3).toUpperCase();
    if (!isSubitemCompleted) {
        priority.classList.add('editable');
        priority.title = `Priority: ${priorityValue} - Click to change`;
        priority.addEventListener('click', (e) => {
            e.stopPropagation();
            showSubitemPriorityDropdown(priority, subitem, parentIndex, subIndex);
        });
    }
    header.appendChild(priority);

    // ID or Index
    const idx = document.createElement('div');
    idx.className = 'subitem-index';
    // Use subitem ID if available (e.g., XFRE-0001-001), otherwise fall back to index notation
    idx.textContent = subitem.id ? `[${subitem.id}]` : `[${parentIndex}.${subIndex}]`;
    header.appendChild(idx);

    // Actively working badge - prominent indicator for THE subitem being worked on
    if (subitem.activelyWorking) {
        const workingBadge = document.createElement('div');
        workingBadge.className = 'subitem-working-badge';
        workingBadge.textContent = '⚡ WORKING';
        workingBadge.title = 'This subitem is currently being worked on';
        header.appendChild(workingBadge);
    }

    // Paused state now indicated by pulsing left-edge via is-paused class (XACA-0022)

    // JIRA link (subitems have their own JIRA links)
    // Click to edit, Cmd/Ctrl+Click to open in Jira
    const jiraTicket = subitem.jiraId || subitem.jiraKey || subitem.jira;
    if (jiraTicket) {
        const jiraLink = document.createElement('a');
        jiraLink.className = 'backlog-jira subitem-jira editable';
        jiraLink.href = getJiraUrl(jiraTicket);
        jiraLink.target = '_blank';
        jiraLink.rel = 'noopener noreferrer';
        jiraLink.textContent = jiraTicket;
        jiraLink.title = `${jiraTicket} - Click to edit, Cmd+Click to open`;

        jiraLink.addEventListener('click', (e) => {
            // Cmd/Ctrl+Click opens the link normally
            if (e.metaKey || e.ctrlKey) {
                return; // Let default behavior happen
            }
            e.preventDefault();
            e.stopPropagation();
            showJiraEditor(jiraLink, subitem, subIndex, true, parentIndex, subIndex);
        });

        header.appendChild(jiraLink);
    } else {
        // No Jira ID - show "+JIRA" button to add one
        const addJiraBtn = document.createElement('a');
        addJiraBtn.className = 'backlog-jira subitem-jira add-jira editable';
        addJiraBtn.textContent = '+LINK';
        addJiraBtn.title = 'Click to link ticket';

        addJiraBtn.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            showJiraEditor(addJiraBtn, subitem, subIndex, true, parentIndex, subIndex);
        });

        header.appendChild(addJiraBtn);
    }

    // GitHub issue link (subitems have their own GitHub links)
    const githubIssue = subitem.githubIssue || subitem.github;
    if (githubIssue) {
        const githubLink = document.createElement('a');
        githubLink.className = 'backlog-github subitem-github';
        githubLink.href = getGitHubUrl(githubIssue, CONFIG.team);
        githubLink.target = '_blank';
        githubLink.rel = 'noopener noreferrer';
        githubLink.textContent = formatGitHubIssue(githubIssue);
        githubLink.title = `Open ${githubIssue} on GitHub`;
        header.appendChild(githubLink);
    }

    // Due date pill (always show, editable only if not completed)
    const dueDatePill = document.createElement('div');
    if (subitem.dueDate) {
        const status = getDueDateStatus(subitem.dueDate);
        // Completed subitems should never show as overdue - use neutral 'was-due' class instead
        const displayStatus = (isSubitemCompleted && status === 'past_due') ? 'was-due' : status;
        dueDatePill.className = `backlog-due-date subitem-due-date ${displayStatus.replaceAll('_', '-')}`;
        dueDatePill.textContent = formatDueDate(subitem.dueDate, isSubitemCompleted);
        if (!isSubitemCompleted) {
            dueDatePill.classList.add('editable');
            dueDatePill.title = `Due: ${parseLocalDate(subitem.dueDate).toLocaleDateString()} - Click to edit`;
        } else {
            dueDatePill.title = `Due: ${parseLocalDate(subitem.dueDate).toLocaleDateString()}`;
        }
    } else {
        dueDatePill.className = 'backlog-due-date subitem-due-date no-date';
        if (!isSubitemCompleted) {
            dueDatePill.classList.add('editable');
            dueDatePill.textContent = '+DUE';
            dueDatePill.title = 'Click to set due date';
        } else {
            dueDatePill.textContent = 'NO DUE';
            dueDatePill.title = 'No due date was set';
        }
    }
    if (!isSubitemCompleted) {
        dueDatePill.addEventListener('click', (e) => {
            e.stopPropagation();
            showSubitemDueDateEditor(dueDatePill, subitem, parentIndex, subIndex);
        });
    }
    header.appendChild(dueDatePill);

    // XACA-0020: Working window badge for subitems
    const subWorkingWindow = getWorkingWindow(subitem.id);
    if (subWorkingWindow || (subitem.activelyWorking && subitem.worktreeWindowId)) {
        const windowBadge = document.createElement('div');
        windowBadge.className = 'subitem-window-badge';

        // Prefer live window info, fall back to stored worktreeWindowId
        const windowId = subWorkingWindow?.windowId || subitem.worktreeWindowId;
        const developer = subWorkingWindow?.developer || 'Unknown';
        const windowStatus = subWorkingWindow?.status || 'working';

        // Extract just the terminal:window for display
        const displayWindow = windowId || 'unknown';
        windowBadge.textContent = `⚡ ${displayWindow}`;
        windowBadge.title = `Working in: ${windowId}\nDeveloper: ${developer}\nStatus: ${windowStatus}`;

        // Add status-based styling
        if (windowStatus === 'paused') {
            windowBadge.classList.add('paused');
        } else if (windowStatus === 'coding') {
            windowBadge.classList.add('coding');
        } else if (windowStatus === 'planning') {
            windowBadge.classList.add('planning');
        }
        header.appendChild(windowBadge);

        // XACA-0067-003: Developer avatar for subitems (when actively working)
        // Try direct window match first, then fall back to worktreeWindowId lookup
        const subEffectiveWindow = subWorkingWindow || (subitem.worktreeWindowId ? getWindowById(subitem.worktreeWindowId) : null);
        const subAvatarTerminal = subEffectiveWindow?.terminal || (subitem.worktreeWindowId ? subitem.worktreeWindowId.split(':')[0] : null);
        if (subAvatarTerminal) {
            const subitemAvatar = document.createElement('img');
            subitemAvatar.className = 'subitem-avatar lcars-avatar';
            subitemAvatar.src = getDeveloperAvatarUrl(boardData?.team, subAvatarTerminal);
            subitemAvatar.alt = subEffectiveWindow?.developer || boardData?.terminals?.[subAvatarTerminal]?.developer || subAvatarTerminal;
            subitemAvatar.dataset.developer = subEffectiveWindow?.developer || boardData?.terminals?.[subAvatarTerminal]?.developer || subAvatarTerminal;
            subitemAvatar.dataset.role = boardData?.terminals?.[subAvatarTerminal]?.role || '';
            subitemAvatar.dataset.terminal = subAvatarTerminal || '';
            subitemAvatar.onerror = function() { this.style.display = 'none'; };
            header.appendChild(subitemAvatar);
        }
    }

    // Worktree badge (if actively working with worktree info) - now secondary to window badge
    if (subitem.activelyWorking && subitem.worktreeBranch && !subWorkingWindow) {
        const worktreeBadge = document.createElement('div');
        worktreeBadge.className = 'subitem-worktree-badge';
        // Show branch name (truncated if long)
        const branchName = subitem.worktreeBranch;
        const displayBranch = branchName.length > 20 ? branchName.substring(0, 17) + '...' : branchName;
        worktreeBadge.textContent = `🌳 ${displayBranch}`;
        worktreeBadge.title = `Worktree: ${subitem.worktree || 'unknown'}\nBranch: ${branchName}\nWindow: ${subitem.worktreeWindowId || 'unknown'}`;
        header.appendChild(worktreeBadge);
    }

    // Title
    const title = document.createElement('div');
    title.className = 'subitem-title';
    title.textContent = subitem.title || 'Untitled subitem';
    header.appendChild(title);

    // Tags in header row (right-aligned) - moved from separate row to reduce vertical space
    const tagsRow = createTagsElement(subitem.tags);
    if (tagsRow) {
        tagsRow.classList.add('subitem-header-tags');
        header.appendChild(tagsRow);
    }

    // Blocked by pills (inline for subitems) - XACA-0025
    if (subitem.blockedBy && subitem.blockedBy.length > 0) {
        const blockerContainer = document.createElement('span');
        blockerContainer.className = 'subitem-blocker-container';

        const blockedLabel = document.createElement('span');
        blockedLabel.className = 'subitem-blocked-label';
        blockedLabel.textContent = 'Blocked: ';
        blockerContainer.appendChild(blockedLabel);

        subitem.blockedBy.forEach(blockerId => {
            const blockerPill = document.createElement('span');
            blockerPill.className = 'blocker-pill subitem-blocker-pill';
            blockerPill.textContent = blockerId;
            blockerPill.title = `Click to view ${blockerId}`;
            blockerPill.addEventListener('click', (e) => {
                e.stopPropagation();
                navigateToBlocker(blockerId);
            });
            blockerContainer.appendChild(blockerPill);
        });

        // XACA-0021: Hover-to-filter for subitems - show only this subitem's parent and its blockers
        const subitemId = subitem.id;
        const blockerIds = [...subitem.blockedBy];
        blockerContainer.addEventListener('mouseenter', () => {
            blockerContainer.classList.add('filter-hover');
            activateDependencyFilter(subitemId, blockerIds);
        });
        blockerContainer.addEventListener('mouseleave', () => {
            blockerContainer.classList.remove('filter-hover');
            deactivateDependencyFilter();
        });

        header.appendChild(blockerContainer);
    }

    div.appendChild(header);

    // Meta row: description (left) + timestamp (right) on same line
    const hasDescription = subitem.description && subitem.description.trim();
    const hasTimestamp = isSubitemCompleted ? subitem.completedAt : (subitem.updatedAt || subitem.addedAt);

    if (hasDescription || hasTimestamp) {
        const metaRow = document.createElement('div');
        metaRow.className = 'subitem-meta-row';

        // Description (if present)
        if (hasDescription) {
            const description = document.createElement('div');
            description.className = 'subitem-description';
            description.textContent = subitem.description;
            metaRow.appendChild(description);
        }

        // Timestamp - show completedAt (absolute) for completed, else updatedAt (relative)
        if (hasTimestamp) {
            const subTimestamp = document.createElement('div');
            subTimestamp.className = 'subitem-timestamp';
            if (isSubitemCompleted && subitem.completedAt) {
                subTimestamp.textContent = '✓ ' + formatAbsoluteTime(subitem.completedAt);
                subTimestamp.title = 'Completed: ' + formatRelativeTime(subitem.completedAt);
                // XACA-0029: Show time worked for completed subitems
                if (subitem.timeWorkedMs && subitem.timeWorkedMs > 0) {
                    const workTimeStr = formatWorkTime(subitem.timeWorkedMs);
                    if (workTimeStr) {
                        const workTimeSpan = document.createElement('span');
                        workTimeSpan.className = 'subitem-time-worked';
                        workTimeSpan.textContent = ` (${workTimeStr})`;
                        workTimeSpan.title = `Time worked: ${workTimeStr}`;
                        subTimestamp.appendChild(workTimeSpan);
                    }
                }
            } else {
                const subDisplayTime = subitem.updatedAt || subitem.addedAt;
                subTimestamp.textContent = formatRelativeTime(subDisplayTime);
                const label = subitem.updatedAt ? 'Last Updated' : 'Created';
                subTimestamp.title = label + ': ' + formatAbsoluteTime(subDisplayTime);
            }
            metaRow.appendChild(subTimestamp);
        }

        div.appendChild(metaRow);
    }

    return div;
}

function toggleBacklogItemExpansion(element, item, index) {
    const isCurrentlyExpanded = element.classList.contains('expanded');
    const subitemsContainer = element.querySelector('.subitems-container');
    const expander = element.querySelector('.subitem-expander');

    if (isCurrentlyExpanded) {
        // Collapse - CSS handles visibility transition
        element.classList.remove('expanded');
        if (expander) {
            expander.textContent = '▶';
            expander.title = 'Expand subitems';
            expander.setAttribute('aria-expanded', 'false');
            expander.setAttribute('aria-label', 'Expand subitems');
        }
        item.collapsed = true;
    } else {
        // Expand - CSS handles visibility transition
        element.classList.add('expanded');
        if (expander) {
            expander.textContent = '▼';
            expander.title = 'Collapse subitems';
            expander.setAttribute('aria-expanded', 'true');
            expander.setAttribute('aria-label', 'Collapse subitems');
        }
        item.collapsed = false;
    }

    // Persist collapsed state to the server using item ID
    persistCollapsedState(item, item.collapsed);
}

async function persistCollapsedState(item, collapsed) {
    const payload = {
        team: CONFIG.team,
        id: item.id,
        collapsed: collapsed
    };

    console.log('Persisting collapsed state:', payload);

    try {
        const response = await apiFetch(apiUrl('/api/toggle-collapsed'), {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            const errorText = await response.text();
            console.error('Failed to persist collapsed state:', response.status, errorText);
        } else {
            console.log('Successfully persisted collapsed state for', item.id);
        }
    } catch (error) {
        console.error('Error persisting collapsed state:', error);
    }
}

// Priority levels for dropdown (in order of severity)
// XACA-0022: Removed 'blocked' - it's a state, not a priority
const PRIORITY_LEVELS = ['critical', 'high', 'medium', 'low'];

/**
 * Show a dropdown menu for changing item priority
 * @param {HTMLElement} element - The priority pill element
 * @param {Object} item - The kanban item
 * @param {number} index - The item index
 */
function showPriorityDropdown(element, item, index) {
    // Remove any existing dropdown
    const existingDropdown = document.querySelector('.priority-dropdown');
    if (existingDropdown) {
        existingDropdown.remove();
    }

    const dropdown = document.createElement('div');
    dropdown.className = 'priority-dropdown';

    const currentPriority = (item.priority || 'medium').toLowerCase();

    PRIORITY_LEVELS.forEach(priority => {
        const option = document.createElement('div');
        option.className = `priority-option ${priority}`;
        if (priority === currentPriority) {
            option.classList.add('selected');
        }
        option.textContent = priority.toUpperCase();
        option.addEventListener('click', (e) => {
            e.stopPropagation();
            updateItemPriority(item, priority, element);
            dropdown.remove();
        });
        dropdown.appendChild(option);
    });

    // Position dropdown below the priority pill
    const rect = element.getBoundingClientRect();
    dropdown.style.position = 'fixed';
    dropdown.style.top = `${rect.bottom + 2}px`;
    dropdown.style.left = `${rect.left}px`;
    dropdown.style.zIndex = '1000';

    document.body.appendChild(dropdown);

    // Close dropdown when clicking outside
    const closeDropdown = (e) => {
        if (!dropdown.contains(e.target) && e.target !== element) {
            dropdown.remove();
            document.removeEventListener('click', closeDropdown);
        }
    };
    setTimeout(() => document.addEventListener('click', closeDropdown), 0);
}

/**
 * Update item priority via API
 * @param {Object} item - The kanban item
 * @param {string} newPriority - The new priority value
 * @param {HTMLElement} element - The priority pill element to update
 */
async function updateItemPriority(item, newPriority, element) {
    const payload = {
        team: CONFIG.team,
        id: item.id,
        updates: {
            priority: newPriority,
            updatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
        }
    };

    console.log('Updating priority:', payload);

    try {
        const response = await apiFetch(apiUrl('/api/update-item'), {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            const errorText = await response.text();
            console.error('Failed to update priority:', response.status, errorText);
            return;
        }

        // Update UI immediately
        item.priority = newPriority;
        element.className = `backlog-priority ${newPriority} editable`;
        element.textContent = newPriority.toUpperCase();
        console.log('Successfully updated priority for', item.id, 'to', newPriority);
    } catch (error) {
        console.error('Error updating priority:', error);
    }
}

// Category levels for dropdown
const CATEGORY_LEVELS = [
    'feature', 'bugfix', 'technical', 'testing', 'security',
    'performance', 'documentation', 'refactor', 'operations',
    'release', 'epic', 'chore'
];

/**
 * Show a dropdown menu for changing item category
 * @param {HTMLElement} element - The category pill element
 * @param {Object} item - The kanban item
 * @param {number} index - The item index in the backlog
 */
function showCategoryDropdown(element, item, index) {
    // Remove any existing dropdown
    const existingDropdown = document.querySelector('.category-dropdown');
    if (existingDropdown) {
        existingDropdown.remove();
    }

    const dropdown = document.createElement('div');
    dropdown.className = 'category-dropdown';

    const currentCategory = (item.category || '').toLowerCase();

    // Add "None" option first
    const noneOption = document.createElement('div');
    noneOption.className = 'category-option no-category';
    if (!currentCategory) {
        noneOption.classList.add('selected');
    }
    noneOption.textContent = 'NONE';
    noneOption.addEventListener('click', (e) => {
        e.stopPropagation();
        updateItemCategory(item, null, element);
        dropdown.remove();
    });
    dropdown.appendChild(noneOption);

    // Add separator
    const separator = document.createElement('div');
    separator.className = 'category-separator';
    dropdown.appendChild(separator);

    // Add all category options
    CATEGORY_LEVELS.forEach(cat => {
        const option = document.createElement('div');
        option.className = `category-option ${cat}`;
        if (cat === currentCategory) {
            option.classList.add('selected');
        }
        option.textContent = cat.toUpperCase();
        option.addEventListener('click', (e) => {
            e.stopPropagation();
            updateItemCategory(item, cat, element);
            dropdown.remove();
        });
        dropdown.appendChild(option);
    });

    // Position dropdown below the category pill
    const rect = element.getBoundingClientRect();
    dropdown.style.position = 'fixed';
    dropdown.style.top = `${rect.bottom + 2}px`;
    dropdown.style.left = `${rect.left}px`;
    dropdown.style.zIndex = '1000';

    document.body.appendChild(dropdown);

    // Close dropdown when clicking outside
    const closeDropdown = (e) => {
        if (!dropdown.contains(e.target) && e.target !== element) {
            dropdown.remove();
            document.removeEventListener('click', closeDropdown);
        }
    };
    setTimeout(() => document.addEventListener('click', closeDropdown), 0);
}

/**
 * Update item category via API
 * @param {Object} item - The kanban item
 * @param {string|null} newCategory - The new category value (null to remove)
 * @param {HTMLElement} element - The category pill element to update
 */
async function updateItemCategory(item, newCategory, element) {
    const payload = {
        team: CONFIG.team,
        id: item.id,
        updates: {
            category: newCategory,
            updatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
        }
    };

    console.log('Updating category:', payload);

    try {
        const response = await apiFetch(apiUrl('/api/update-item'), {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            const errorText = await response.text();
            console.error('Failed to update category:', response.status, errorText);
            return;
        }

        // Update UI immediately
        item.category = newCategory;
        if (newCategory) {
            element.className = `backlog-category ${newCategory} editable`;
            element.textContent = newCategory.toUpperCase();
            element.title = `Category: ${newCategory}\nClick to change`;
        } else {
            element.className = 'backlog-category no-category editable';
            element.textContent = 'NO CAT';
            element.title = 'No category assigned\nClick to set';
        }
        console.log('Successfully updated category for', item.id, 'to', newCategory);
    } catch (error) {
        console.error('Error updating category:', error);
    }
}

/**
 * Show OS selection dropdown for items
 * @param {HTMLElement} element - The OS logo element
 * @param {Object} item - The kanban item
 * @param {number} index - The item index
 */
function showOSDropdown(element, item, index) {
    // Remove any existing dropdown
    const existingDropdown = document.querySelector('.os-dropdown');
    if (existingDropdown) {
        existingDropdown.remove();
    }

    const dropdown = document.createElement('div');
    dropdown.className = 'os-dropdown';

    const currentOS = getOSFromTags(item.tags) || 'None';

    // Add all OS options including None
    const osOptions = [...OS_PLATFORMS, 'None'];
    osOptions.forEach(os => {
        const option = document.createElement('div');
        option.className = 'os-option';
        const config = OS_CONFIG[os];
        option.style.borderLeftColor = config.color;

        if (os === currentOS) {
            option.classList.add('selected');
        }

        // Create logo preview
        if (config.logo) {
            const img = document.createElement('img');
            img.src = config.logo;
            img.alt = config.label;
            option.appendChild(img);
        } else {
            // Question mark icon for "None" (unspecified platform)
            const iconSpan = document.createElement('span');
            iconSpan.innerHTML = `<svg viewBox="0 0 24 24" fill="currentColor" width="16" height="16">
                <circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="2"/>
                <text x="12" y="17" text-anchor="middle" font-size="14" font-weight="bold" font-family="Arial, sans-serif">?</text>
            </svg>`;
            option.appendChild(iconSpan);
        }

        const label = document.createElement('span');
        label.textContent = config.label;
        option.appendChild(label);

        option.addEventListener('click', (e) => {
            e.stopPropagation();
            updateItemOS(item, os === 'None' ? null : os, element);
            dropdown.remove();
        });
        dropdown.appendChild(option);
    });

    // Position dropdown below the OS logo
    const rect = element.getBoundingClientRect();
    dropdown.style.position = 'fixed';
    dropdown.style.top = `${rect.bottom + 2}px`;
    dropdown.style.left = `${rect.left}px`;
    dropdown.style.zIndex = '1000';

    document.body.appendChild(dropdown);

    // Close dropdown when clicking outside
    const closeDropdown = (e) => {
        if (!dropdown.contains(e.target) && e.target !== element) {
            dropdown.remove();
            document.removeEventListener('click', closeDropdown);
        }
    };
    setTimeout(() => document.addEventListener('click', closeDropdown), 0);
}

/**
 * Update item OS via API (updates tags array)
 * @param {Object} item - The kanban item
 * @param {string|null} newOS - The new OS value (iOS, Android, Firebase) or null
 * @param {HTMLElement} element - The OS logo element to update
 */
async function updateItemOS(item, newOS, element) {
    const newTags = updateOSInTags(item.tags || [], newOS);
    const payload = {
        team: CONFIG.team,
        id: item.id,
        updates: {
            tags: newTags,
            updatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
        }
    };

    console.log('Updating OS:', payload);

    try {
        const response = await apiFetch(apiUrl('/api/update-item'), {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            const errorText = await response.text();
            console.error('Failed to update OS:', response.status, errorText);
            return;
        }

        // Update UI immediately
        item.tags = newTags;
        const config = OS_CONFIG[newOS] || OS_CONFIG['None'];
        element.style.borderColor = config.color;
        element.dataset.os = newOS || 'None';
        element.title = config.label;
        element.innerHTML = '';

        if (config.logo) {
            const img = document.createElement('img');
            img.src = config.logo;
            img.alt = config.label;
            element.appendChild(img);
        } else {
            element.innerHTML = `<svg viewBox="0 0 24 24" fill="currentColor">
                <rect x="2" y="2" width="9" height="9" rx="1"/>
                <rect x="13" y="2" width="9" height="9" rx="1"/>
                <rect x="2" y="13" width="9" height="9" rx="1"/>
                <rect x="13" y="13" width="9" height="9" rx="1"/>
            </svg>`;
        }

        console.log('Successfully updated OS for', item.id, 'to', newOS || 'None');
    } catch (error) {
        console.error('Error updating OS:', error);
    }
}

/**
 * Show a date editor popup for changing item due date
 * @param {HTMLElement} element - The due date pill element
 * @param {Object} item - The kanban item
 * @param {number} index - The item index
 */
function showDueDateEditor(element, item, index) {
    // Remove any existing editor
    const existingEditor = document.querySelector('.due-date-editor');
    if (existingEditor) {
        existingEditor.remove();
    }

    const editor = document.createElement('div');
    editor.className = 'due-date-editor';

    // Date input
    const dateInput = document.createElement('input');
    dateInput.type = 'date';
    dateInput.className = 'due-date-input';
    if (item.dueDate) {
        dateInput.value = item.dueDate;
    }

    // Quick preset buttons
    const presets = document.createElement('div');
    presets.className = 'due-date-presets';

    const presetDays = [
        { label: 'Today', days: 0 },
        { label: '+1d', days: 1 },
        { label: '+3d', days: 3 },
        { label: '+1w', days: 7 },
        { label: '+2w', days: 14 }
    ];

    presetDays.forEach(preset => {
        const btn = document.createElement('button');
        btn.className = 'due-date-preset';
        btn.textContent = preset.label;
        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            const date = new Date();
            date.setDate(date.getDate() + preset.days);
            const dateStr = getLocalDateString(date);
            updateItemDueDate(item, dateStr, element);
            editor.remove();
        });
        presets.appendChild(btn);
    });

    // Clear button (always visible, clears existing date or just closes if none)
    const clearBtn = document.createElement('button');
    clearBtn.className = 'due-date-preset clear';
    clearBtn.textContent = 'Clear';
    clearBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        if (item.dueDate) {
            updateItemDueDate(item, null, element);
        }
        editor.remove();
    });
    presets.appendChild(clearBtn);

    // Track date changes for debugging
    dateInput.addEventListener('change', (e) => {
        console.log('Date input changed to:', e.target.value);
    });

    // Set button for custom date
    const setBtn = document.createElement('button');
    setBtn.className = 'due-date-set';
    setBtn.textContent = 'Set';
    setBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        // Force blur to commit any typed value (Safari quirk)
        dateInput.blur();
        const dateValue = dateInput.value;
        console.log('Set button clicked, dateInput.value =', dateValue);
        if (dateValue) {
            updateItemDueDate(item, dateValue, element);
        } else {
            console.warn('No date value to set');
        }
        editor.remove();
    });

    editor.appendChild(dateInput);
    editor.appendChild(presets);
    editor.appendChild(setBtn);

    // Position editor below the due date pill
    const rect = element.getBoundingClientRect();
    editor.style.position = 'fixed';
    editor.style.top = `${rect.bottom + 2}px`;
    editor.style.left = `${rect.left}px`;
    editor.style.zIndex = '1000';

    document.body.appendChild(editor);

    // Focus the date input
    dateInput.focus();

    // Close editor when clicking outside
    const closeEditor = (e) => {
        if (!editor.contains(e.target) && e.target !== element) {
            editor.remove();
            document.removeEventListener('click', closeEditor);
        }
    };
    setTimeout(() => document.addEventListener('click', closeEditor), 0);

    // Handle Enter key in date input
    dateInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && dateInput.value) {
            updateItemDueDate(item, dateInput.value, element);
            editor.remove();
        } else if (e.key === 'Escape') {
            editor.remove();
        }
    });
}

/**
 * Update item due date via API
 * @param {Object} item - The kanban item
 * @param {string|null} newDueDate - The new due date (YYYY-MM-DD) or null to clear
 * @param {HTMLElement} element - The due date pill element to update
 */
async function updateItemDueDate(item, newDueDate, element) {
    const updates = {
        updatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
    };

    if (newDueDate) {
        updates.dueDate = newDueDate;
    }

    const payload = {
        team: CONFIG.team,
        id: item.id,
        updates: updates
    };

    // Handle clearing - need to delete the field
    if (!newDueDate && item.dueDate) {
        payload.clearFields = ['dueDate'];
    }

    console.log('Updating due date:', payload);

    try {
        const response = await apiFetch(apiUrl('/api/update-item'), {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            const errorText = await response.text();
            console.error('Failed to update due date:', response.status, errorText);
            return;
        }

        // Update UI immediately
        item.dueDate = newDueDate;
        if (newDueDate) {
            const status = getDueDateStatus(newDueDate);
            element.className = `backlog-due-date ${status.replaceAll('_', '-')} editable`;
            element.textContent = formatDueDate(newDueDate);
            element.title = `Due: ${parseLocalDate(newDueDate).toLocaleDateString()} - Click to edit`;
        } else {
            element.className = 'backlog-due-date no-date editable';
            element.textContent = '+DUE';
            element.title = 'Click to set due date';
        }
        console.log('Successfully updated due date for', item.id, 'to', newDueDate);
    } catch (error) {
        console.error('Error updating due date:', error);
    }
}

/**
 * XACA-0624: Show inline editor for effort estimate (points)
 * Mirrors showDueDateEditor — popup with numeric input, common presets, clear, set.
 * @param {HTMLElement} element - The points pill element
 * @param {Object} item - The kanban item
 * @param {number} index - The item index in the backlog
 */
function showPointsEditor(element, item, index) {
    // Remove any existing editor of this type
    const existingEditor = document.querySelector('.points-editor');
    if (existingEditor) {
        existingEditor.remove();
    }

    const editor = document.createElement('div');
    editor.className = 'points-editor';

    // Label
    const label = document.createElement('div');
    label.style.cssText = 'font-size:10px;color:var(--lcars-cyan);font-weight:600;';
    label.textContent = 'ESTIMATE (developer-hours)';
    editor.appendChild(label);

    // Numeric input
    const numInput = document.createElement('input');
    numInput.type = 'number';
    numInput.className = 'points-input';
    numInput.min = '0';
    numInput.step = '0.5';
    numInput.placeholder = 'e.g. 4, 0.5, 1.25';
    if (item.points != null && typeof item.points === 'number') {
        numInput.value = item.points;
    }

    // Common preset values (developer-hours)
    const presets = document.createElement('div');
    presets.className = 'points-presets';

    [0.5, 1, 2, 4, 8].forEach(hrs => {
        const btn = document.createElement('button');
        btn.className = 'points-preset';
        btn.textContent = `${hrs}h`;
        btn.title = `Set estimate to ${hrs} developer-hour${hrs === 1 ? '' : 's'}`;
        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            updateItemPoints(item, hrs, element);
            editor.remove();
        });
        presets.appendChild(btn);
    });

    // Clear button
    const clearBtn = document.createElement('button');
    clearBtn.className = 'points-preset clear';
    clearBtn.textContent = 'Clear';
    clearBtn.title = 'Remove estimate (back to unestimated)';
    clearBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        if (item.points != null) {
            updateItemPoints(item, null, element);
        }
        editor.remove();
    });
    presets.appendChild(clearBtn);

    // Set button for custom value
    const setBtn = document.createElement('button');
    setBtn.className = 'points-set';
    setBtn.textContent = 'Set';
    setBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        numInput.blur();
        const raw = numInput.value.trim();
        if (raw === '' || raw === '-') {
            editor.remove();
            return;
        }
        const val = parseFloat(raw);
        if (isNaN(val) || val < 0) {
            numInput.style.borderColor = 'var(--lcars-red)';
            numInput.title = 'Must be a non-negative number';
            return;
        }
        updateItemPoints(item, val, element);
        editor.remove();
    });

    editor.appendChild(numInput);
    editor.appendChild(presets);
    editor.appendChild(setBtn);

    // Position below the pill (mirrors showDueDateEditor positioning)
    const rect = element.getBoundingClientRect();
    editor.style.position = 'fixed';
    editor.style.top = `${rect.bottom + 2}px`;
    editor.style.left = `${rect.left}px`;
    editor.style.zIndex = '1000';

    document.body.appendChild(editor);
    numInput.focus();
    numInput.select();

    // Close when clicking outside
    const closeEditor = (e) => {
        if (!editor.contains(e.target) && e.target !== element) {
            editor.remove();
            document.removeEventListener('click', closeEditor);
        }
    };
    setTimeout(() => document.addEventListener('click', closeEditor), 0);

    // Keyboard: Enter = set, Escape = close
    numInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            const raw = numInput.value.trim();
            if (raw !== '') {
                const val = parseFloat(raw);
                if (!isNaN(val) && val >= 0) {
                    updateItemPoints(item, val, element);
                    editor.remove();
                } else {
                    numInput.style.borderColor = 'var(--lcars-red)';
                }
            } else {
                editor.remove();
            }
        } else if (e.key === 'Escape') {
            editor.remove();
        }
    });
}

/**
 * XACA-0624: Update item effort estimate (points) via API
 * @param {Object} item - The kanban item
 * @param {number|null} newPoints - Developer-hours (>=0, fractional OK) or null to clear
 * @param {HTMLElement} element - The points pill element to update visually
 */
async function updateItemPoints(item, newPoints, element) {
    const payload = {
        team: CONFIG.team,
        id: item.id,
        updates: {
            updatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
        }
    };

    if (newPoints != null) {
        payload.updates.points = newPoints;  // stored as JSON number by the server
    } else {
        // Clearing: delete the field
        payload.clearFields = ['points'];
    }

    console.log('Updating points:', payload);

    try {
        const response = await apiFetch(apiUrl('/api/update-item'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            const errorText = await response.text();
            console.error('Failed to update points:', response.status, errorText);
            return;
        }

        // Update item model and pill DOM immediately (optimistic update)
        item.points = newPoints;
        if (newPoints != null) {
            element.className = 'backlog-points editable';
            element.textContent = `${newPoints}h`;
            element.title = `Estimate: ${newPoints} developer-hour${newPoints === 1 ? '' : 's'} — Click to edit`;
            element.setAttribute('aria-label', `Effort estimate: ${newPoints}h`);
        } else {
            element.className = 'backlog-points no-estimate editable';
            element.textContent = '—';
            element.title = 'No estimate — Click to set developer-hours';
            element.setAttribute('aria-label', 'No effort estimate set');
        }
        console.log('Successfully updated points for', item.id, 'to', newPoints);
    } catch (error) {
        console.error('Error updating points:', error);
    }
}

/**
 * Show inline editor for Jira ID
 * @param {HTMLElement} element - The Jira pill element (or placeholder)
 * @param {Object} item - The kanban item
 * @param {number} index - The item index
 * @param {boolean} isSubitem - Whether this is a subitem
 * @param {number} parentIndex - Parent index (for subitems)
 * @param {number} subIndex - Subitem index (for subitems)
 */
function showJiraEditor(element, item, index, isSubitem = false, parentIndex = null, subIndex = null) {
    // Remove any existing editor
    const existingEditor = document.querySelector('.jira-editor');
    if (existingEditor) {
        existingEditor.remove();
    }

    const currentJira = item.jiraId || item.jiraKey || item.jira || '';

    const editor = document.createElement('div');
    editor.className = 'jira-editor';

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTEGRATION SELECTOR
    // ═══════════════════════════════════════════════════════════════════════════════

    // Create integration selector header
    const selectorHeader = document.createElement('div');
    selectorHeader.className = 'integration-selector-header';

    // Mode toggle (Link Existing vs Create New)
    const modeToggle = document.createElement('div');
    modeToggle.className = 'integration-mode-toggle';

    const linkModeBtn = document.createElement('button');
    linkModeBtn.className = 'integration-mode-btn active';
    linkModeBtn.textContent = 'Link Existing';
    linkModeBtn.dataset.mode = 'link';

    const createModeBtn = document.createElement('button');
    createModeBtn.className = 'integration-mode-btn';
    createModeBtn.textContent = 'Create New';
    createModeBtn.dataset.mode = 'create';

    modeToggle.appendChild(linkModeBtn);
    modeToggle.appendChild(createModeBtn);

    // Integration selector dropdown
    const selectorRow = document.createElement('div');
    selectorRow.className = 'integration-selector-row';

    const selectorLabel = document.createElement('label');
    selectorLabel.className = 'integration-selector-label';
    selectorLabel.textContent = 'Integration:';

    const integrationSelect = document.createElement('select');
    integrationSelect.className = 'integration-selector';

    // Placeholder option
    const placeholderOption = document.createElement('option');
    placeholderOption.value = '';
    placeholderOption.textContent = 'Loading integrations...';
    placeholderOption.disabled = true;
    placeholderOption.selected = true;
    integrationSelect.appendChild(placeholderOption);

    selectorRow.appendChild(selectorLabel);
    selectorRow.appendChild(integrationSelect);

    selectorHeader.appendChild(modeToggle);
    selectorHeader.appendChild(selectorRow);

    // State to track selected integration and mode
    let selectedIntegration = null;
    let currentMode = 'link';

    // Load available integrations
    const loadIntegrations = async () => {
        try {
            const response = await fetch(apiUrl('/api/integrations/list'));
            const data = await response.json();

            integrationSelect.innerHTML = '';

            if (data.error || !data.integrations || data.integrations.length === 0) {
                const noIntegrationOption = document.createElement('option');
                noIntegrationOption.value = '';
                noIntegrationOption.textContent = 'No integrations configured';
                noIntegrationOption.disabled = true;
                integrationSelect.appendChild(noIntegrationOption);
                return;
            }

            // Add integrations to dropdown
            data.integrations.forEach(integration => {
                if (!integration.enabled) return;

                const option = document.createElement('option');
                option.value = integration.id;
                option.textContent = integration.name;
                option.dataset.type = integration.type;
                option.dataset.pattern = integration.ticketPattern || '';
                option.dataset.icon = getIntegrationIcon(integration.type);
                integrationSelect.appendChild(option);
            });

            // Select first integration by default
            if (integrationSelect.options.length > 0) {
                integrationSelect.selectedIndex = 0;
                selectedIntegration = data.integrations[0];
                updateInputPlaceholder();
            }

        } catch (error) {
            console.error('Failed to load integrations:', error);
            const errorOption = document.createElement('option');
            errorOption.value = '';
            errorOption.textContent = 'Failed to load integrations';
            errorOption.disabled = true;
            integrationSelect.innerHTML = '';
            integrationSelect.appendChild(errorOption);
        }
    };

    // Helper to get integration icon
    const getIntegrationIcon = (type) => {
        const icons = {
            'jira': '📋',
            'monday': '📊',
            'github': '🐙',
            'linear': '📐',
            'asana': '✓',
            'trello': '📌',
            'custom': '🔗'
        };
        return icons[type] || '🔗';
    };

    // Update input placeholder based on selected integration
    const updateInputPlaceholder = () => {
        const selectedOption = integrationSelect.options[integrationSelect.selectedIndex];
        if (selectedOption && selectedOption.value) {
            const icon = selectedOption.dataset.icon || '🔗';
            const type = selectedOption.dataset.type || '';

            if (currentMode === 'link') {
                // Link existing mode - show ticket ID format
                if (type === 'jira') {
                    input.placeholder = `${icon} ME-123`;
                } else if (type === 'github') {
                    input.placeholder = `${icon} owner/repo#123`;
                } else if (type === 'monday') {
                    input.placeholder = `${icon} Item ID or URL`;
                } else {
                    input.placeholder = `${icon} Ticket ID`;
                }
            } else {
                // Create new mode
                input.placeholder = `${icon} New ticket title...`;
            }
        }
    };

    // Mode toggle event listeners
    linkModeBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        currentMode = 'link';
        linkModeBtn.classList.add('active');
        createModeBtn.classList.remove('active');
        updateInputPlaceholder();
        searchBtn.style.display = 'inline-block';
    });

    createModeBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        currentMode = 'create';
        createModeBtn.classList.add('active');
        linkModeBtn.classList.remove('active');
        updateInputPlaceholder();
        searchBtn.style.display = 'none'; // Hide search in create mode
        resultsContainer.style.display = 'none';
    });

    // Integration selector change listener
    integrationSelect.addEventListener('change', (e) => {
        e.stopPropagation();
        const selectedOption = integrationSelect.options[integrationSelect.selectedIndex];
        if (selectedOption && selectedOption.value) {
            selectedIntegration = {
                id: selectedOption.value,
                name: selectedOption.textContent,
                type: selectedOption.dataset.type,
                pattern: selectedOption.dataset.pattern
            };
            updateInputPlaceholder();
        }
    });

    // Load integrations on initialization
    loadIntegrations();

    // ═══════════════════════════════════════════════════════════════════════════════
    // END INTEGRATION SELECTOR
    // ═══════════════════════════════════════════════════════════════════════════════

    // ═══════════════════════════════════════════════════════════════════════════════
    // CREATE NEW ITEM FORM
    // ═══════════════════════════════════════════════════════════════════════════════

    const createForm = document.createElement('div');
    createForm.className = 'integration-create-form';
    createForm.style.display = 'none'; // Hidden by default (starts in Link mode)

    // Title field
    const titleRow = document.createElement('div');
    titleRow.className = 'integration-create-row';

    const titleLabel = document.createElement('label');
    titleLabel.className = 'integration-create-label';
    titleLabel.textContent = 'Title:';

    const titleInput = document.createElement('input');
    titleInput.type = 'text';
    titleInput.className = 'integration-create-input';
    titleInput.placeholder = 'Enter title for new item...';
    titleInput.required = true;
    // Pre-fill with kanban item title
    titleInput.value = item.title || '';

    titleRow.appendChild(titleLabel);
    titleRow.appendChild(titleInput);

    // Description field
    const descRow = document.createElement('div');
    descRow.className = 'integration-create-row';

    const descLabel = document.createElement('label');
    descLabel.className = 'integration-create-label';
    descLabel.textContent = 'Description:';

    const descInput = document.createElement('textarea');
    descInput.className = 'integration-create-textarea';
    descInput.placeholder = 'Optional description...';
    descInput.rows = 4;
    // Pre-fill with kanban item description if available
    descInput.value = item.description || '';

    descRow.appendChild(descLabel);
    descRow.appendChild(descInput);

    // Create button
    const createBtnRow = document.createElement('div');
    createBtnRow.className = 'integration-create-row';

    const createBtn = document.createElement('button');
    createBtn.className = 'jira-btn save integration-create-btn';
    createBtn.textContent = 'Create Item';
    createBtn.title = 'Create new integration item';

    createBtnRow.appendChild(createBtn);

    // Assemble create form
    createForm.appendChild(titleRow);
    createForm.appendChild(descRow);
    createForm.appendChild(createBtnRow);

    // ═══════════════════════════════════════════════════════════════════════════════
    // END CREATE NEW ITEM FORM
    // ═══════════════════════════════════════════════════════════════════════════════

    // Input field (for Link Existing mode)
    const input = document.createElement('input');
    input.type = 'text';
    input.className = 'jira-input';
    input.value = currentJira;
    input.placeholder = 'ME-123';
    input.maxLength = 20;

    // Save button
    const saveBtn = document.createElement('button');
    saveBtn.className = 'jira-btn save';
    saveBtn.textContent = '✓';
    saveBtn.title = 'Save';

    // Cancel button
    const cancelBtn = document.createElement('button');
    cancelBtn.className = 'jira-btn cancel';
    cancelBtn.textContent = '✕';
    cancelBtn.title = 'Cancel';

    // Clear button (only show if there's a current value)
    const clearBtn = document.createElement('button');
    clearBtn.className = 'jira-btn clear';
    clearBtn.textContent = 'Clear';
    clearBtn.title = 'Remove Jira ID';
    clearBtn.style.display = currentJira ? 'inline-block' : 'none';

    // Search button
    const searchBtn = document.createElement('button');
    searchBtn.className = 'jira-btn search';
    searchBtn.textContent = '🔍';
    searchBtn.title = 'Search Jira';

    // Search results container (initially hidden)
    const resultsContainer = document.createElement('div');
    resultsContainer.className = 'jira-search-results';
    resultsContainer.style.display = 'none';

    let searchTimeout = null;

    // Debounce timeout tracker for resize/scroll (declared early for cleanup function)
    let resizeScrollTimeout = null;
    let debouncedReposition = null;
    let closeOnOutsideClick = null;

    // Enhanced cleanup function that removes all event listeners and cleans up
    // (Defined early so button handlers and other functions can use it)
    const cleanupEditor = () => {
        editor.remove();
        if (debouncedReposition) {
            window.removeEventListener('resize', debouncedReposition);
            window.removeEventListener('scroll', debouncedReposition, true);
        }
        if (closeOnOutsideClick) {
            document.removeEventListener('click', closeOnOutsideClick);
        }
        if (resizeScrollTimeout) {
            clearTimeout(resizeScrollTimeout);
        }
    };

    const doSearch = async () => {
        const query = input.value.trim();
        if (!query) {
            resultsContainer.style.display = 'none';
            return;
        }

        resultsContainer.innerHTML = '<div class="jira-search-loading">Searching...</div>';
        resultsContainer.style.display = 'block';

        try {
            const response = await apiFetch(apiUrl('/api/integrations/search'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ query })
            });

            const data = await response.json();

            if (data.error) {
                resultsContainer.innerHTML = `<div class="jira-search-error">${escapeHtml(data.error)}</div>`;
                return;
            }

            // Flatten results from all integrations
            const allTickets = [];
            if (data.results) {
                for (const [integrationId, result] of Object.entries(data.results)) {
                    if (result.error) {
                        console.warn(`Integration ${integrationId} error:`, result.error);
                        continue;
                    }
                    if (result.tickets) {
                        allTickets.push(...result.tickets);
                    }
                }
            }

            if (allTickets.length === 0) {
                resultsContainer.innerHTML = '<div class="jira-search-empty">No results found</div>';
                return;
            }

            resultsContainer.innerHTML = '';
            allTickets.forEach(issue => {
                const resultItem = document.createElement('div');
                resultItem.className = 'jira-search-result';
                resultItem.innerHTML = `
                    <span class="jira-result-key">${escapeHtml(issue.ticketId)}</span>
                    <span class="jira-result-summary">${escapeHtml(issue.summary)}</span>
                `;
                resultItem.title = `${issue.ticketId}: ${issue.summary}`;
                resultItem.addEventListener('click', (e) => {
                    e.stopPropagation();
                    input.value = issue.ticketId;
                    resultsContainer.style.display = 'none';
                });
                resultsContainer.appendChild(resultItem);
            });
        } catch (error) {
            console.error('Search error:', error);
            resultsContainer.innerHTML = '<div class="jira-search-error">Search failed</div>';
        }
    };

    const doSave = async () => {
        const inputValue = input.value.trim();

        // Validate that an integration is selected
        if (!selectedIntegration) {
            resultsContainer.innerHTML = '<div class="jira-search-error">❌ Please select an integration</div>';
            resultsContainer.style.display = 'block';
            return;
        }

        // Skip verification if clearing the value
        if (!inputValue) {
            if (isSubitem) {
                await updateSubitemJira(item, null, element, parentIndex, subIndex);
            } else {
                await updateItemJira(item, null, element);
            }
            cleanupEditor();
            return;
        }

        // Handle "Create New" mode
        if (currentMode === 'create') {
            resultsContainer.innerHTML = '<div class="jira-search-loading">Creating new ticket...</div>';
            resultsContainer.style.display = 'block';
            saveBtn.disabled = true;
            input.disabled = true;

            try {
                // Emit integration selection event with create mode
                const selectionEvent = new CustomEvent('integration-ticket-create', {
                    detail: {
                        integration: selectedIntegration,
                        title: inputValue,
                        mode: 'create',
                        item: item,
                        isSubitem: isSubitem,
                        parentIndex: parentIndex,
                        subIndex: subIndex
                    }
                });
                document.dispatchEvent(selectionEvent);

                // TODO: Implement actual ticket creation API call
                // For now, show a message that this will be implemented
                resultsContainer.innerHTML = '<div class="jira-search-warning">⚠️ Create mode coming soon - use Link mode for now</div>';
                await new Promise(resolve => setTimeout(resolve, 1500));

                saveBtn.disabled = false;
                input.disabled = false;
                return;

            } catch (error) {
                console.error('Create ticket error:', error);
                resultsContainer.innerHTML = '<div class="jira-search-error">Failed to create ticket</div>';
                saveBtn.disabled = false;
                input.disabled = false;
            }
            return;
        }

        // Handle "Link Existing" mode
        const newJira = inputValue.toUpperCase();

        // Show verification status
        resultsContainer.innerHTML = '<div class="jira-search-loading">Verifying ticket...</div>';
        resultsContainer.style.display = 'block';
        saveBtn.disabled = true;
        input.disabled = true;

        try {
            const response = await apiFetch(apiUrl('/api/integrations/verify'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    ticketId: newJira,
                    integrationId: selectedIntegration.id
                })
            });

            const data = await response.json();

            if (!data.valid) {
                // Ticket doesn't exist or invalid format - show error
                resultsContainer.innerHTML = `<div class="jira-search-error">❌ ${escapeHtml(data.error)}</div>`;
                saveBtn.disabled = false;
                input.disabled = false;
                return;
            }

            // Valid - show success and proceed
            if (data.exists) {
                resultsContainer.innerHTML = `<div class="jira-search-success">✓ ${escapeHtml(data.ticketId)}: ${escapeHtml(data.summary || 'Verified')}</div>`;
            } else if (data.warning) {
                resultsContainer.innerHTML = `<div class="jira-search-warning">⚠️ ${escapeHtml(data.warning)}</div>`;
            }

            // Brief pause to show success feedback
            await new Promise(resolve => setTimeout(resolve, 300));

            // Emit integration selection event
            const selectionEvent = new CustomEvent('integration-ticket-link', {
                detail: {
                    integration: selectedIntegration,
                    ticketId: data.ticketId || newJira,
                    summary: data.summary,
                    mode: 'link',
                    item: item,
                    isSubitem: isSubitem,
                    parentIndex: parentIndex,
                    subIndex: subIndex
                }
            });
            document.dispatchEvent(selectionEvent);

            // Now save the verified ticket ID
            if (isSubitem) {
                await updateSubitemJira(item, data.ticketId || newJira, element, parentIndex, subIndex);
            } else {
                await updateItemJira(item, data.ticketId || newJira, element);
            }
            cleanupEditor();

        } catch (error) {
            console.error('Verification error:', error);
            resultsContainer.innerHTML = '<div class="jira-search-error">Verification failed - try again</div>';
            saveBtn.disabled = false;
            input.disabled = false;
        }
    };

    const doClear = async () => {
        if (isSubitem) {
            await updateSubitemJira(item, null, element, parentIndex, subIndex);
        } else {
            await updateItemJira(item, null, element);
        }
        cleanupEditor();
    };

    saveBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        doSave();
    });

    cancelBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        cleanupEditor();
    });

    clearBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        doClear();
    });

    // Create new item handler
    const doCreateItem = async () => {
        const title = titleInput.value.trim();
        const description = descInput.value.trim();

        // Validate integration is selected
        if (!selectedIntegration) {
            resultsContainer.innerHTML = '<div class="jira-search-error">❌ Please select an integration</div>';
            resultsContainer.style.display = 'block';
            return;
        }

        // Validate title is not empty
        if (!title) {
            titleInput.focus();
            titleInput.style.borderColor = 'var(--lcars-red)';
            setTimeout(() => {
                titleInput.style.borderColor = '';
            }, 2000);
            return;
        }

        // Show loading state
        resultsContainer.innerHTML = '<div class="jira-search-loading">Creating new item...</div>';
        resultsContainer.style.display = 'block';
        createBtn.disabled = true;
        titleInput.disabled = true;
        descInput.disabled = true;

        try {
            // Call create item API
            const response = await apiFetch(apiUrl('/api/integrations/create-item'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    integrationId: selectedIntegration.id,
                    title: title,
                    description: description
                })
            });

            const data = await response.json();

            if (!response.ok || data.error) {
                throw new Error(data.error || 'Failed to create item');
            }

            // Success - update kanban item with the new linked ticket
            const ticketId = data.ticketId || data.key || data.id;
            const ticketUrl = data.url;

            resultsContainer.innerHTML = `<div class="jira-search-success">✓ Created ${escapeHtml(ticketId)}</div>`;

            // Update the kanban item
            if (isSubitem) {
                await updateSubitemJira(item, ticketId, element, parentIndex, subIndex);
            } else {
                await updateItemJira(item, ticketId, element);
            }

            // Close after a brief delay to show success message
            setTimeout(() => {
                cleanupEditor();
            }, 1000);

        } catch (error) {
            console.error('Create item error:', error);
            resultsContainer.innerHTML = `<div class="jira-search-error">❌ ${escapeHtml(error.message || 'Failed to create item')}</div>`;
            createBtn.disabled = false;
            titleInput.disabled = false;
            descInput.disabled = false;
        }
    };

    createBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        doCreateItem();
    });

    // Allow Enter key in title input to submit
    titleInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            e.preventDefault();
            doCreateItem();
        } else if (e.key === 'Escape') {
            e.preventDefault();
            cleanupEditor();
        }
    });

    input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            e.preventDefault();
            doSave();
        } else if (e.key === 'Escape') {
            e.preventDefault();
            cleanupEditor();
        }
    });

    // Debounced search on input
    input.addEventListener('input', () => {
        if (searchTimeout) clearTimeout(searchTimeout);
        searchTimeout = setTimeout(doSearch, 300);
    });

    searchBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        doSearch();
    });

    // Build editor row
    const inputRow = document.createElement('div');
    inputRow.className = 'jira-editor-row';
    inputRow.appendChild(input);
    inputRow.appendChild(searchBtn);
    inputRow.appendChild(saveBtn);
    inputRow.appendChild(cancelBtn);
    if (currentJira) {
        inputRow.appendChild(clearBtn);
    }

    // Assemble editor with integration selector
    editor.appendChild(selectorHeader);
    editor.appendChild(createForm); // Create form (hidden by default)
    editor.appendChild(inputRow); // Input row (shown by default)
    editor.appendChild(resultsContainer);

    // Update mode toggle handlers to show/hide appropriate elements
    const originalLinkClick = linkModeBtn.onclick;
    linkModeBtn.onclick = (e) => {
        e.stopPropagation();
        currentMode = 'link';
        linkModeBtn.classList.add('active');
        createModeBtn.classList.remove('active');
        updateInputPlaceholder();
        searchBtn.style.display = 'inline-block';
        // Show input row, hide create form
        inputRow.style.display = 'flex';
        createForm.style.display = 'none';
        resultsContainer.style.display = 'none';
    };

    const originalCreateClick = createModeBtn.onclick;
    createModeBtn.onclick = (e) => {
        e.stopPropagation();
        currentMode = 'create';
        createModeBtn.classList.add('active');
        linkModeBtn.classList.remove('active');
        updateInputPlaceholder();
        searchBtn.style.display = 'none';
        // Show create form, hide input row
        inputRow.style.display = 'none';
        createForm.style.display = 'flex';
        resultsContainer.style.display = 'none';
    };

    // ═══════════════════════════════════════════════════════════════════════════════
    // VIEWPORT-AWARE POSITIONING WITH RESIZE/SCROLL HANDLERS
    // ═══════════════════════════════════════════════════════════════════════════════

    editor.style.position = 'fixed';
    editor.style.zIndex = '1000';

    // Add to DOM first so it has dimensions for viewport calculation
    document.body.appendChild(editor);

    // Store positioning options for repositioning on resize/scroll
    const positioningOptions = {
        padding: 10,
        flipVertical: true,
        flipHorizontal: false, // Don't flip horizontally, editor aligns to left of trigger
        gap: 4 // Gap between trigger and popup
    };

    // Function to reposition the editor based on trigger element
    const repositionEditor = () => {
        const rect = element.getBoundingClientRect();

        // Store trigger dimensions in positioning options
        positioningOptions.triggerHeight = rect.height;
        positioningOptions.triggerWidth = rect.width;

        // Calculate preferred position (below trigger with gap)
        const preferredX = rect.left + window.scrollX;
        const preferredY = rect.bottom + positioningOptions.gap + window.scrollY;

        const position = calculateViewportPosition(editor, preferredX, preferredY, positioningOptions);

        // Apply adjusted position (convert back to viewport coordinates for fixed positioning)
        editor.style.left = `${position.x - window.scrollX}px`;
        editor.style.top = `${position.y - window.scrollY}px`;
    };

    // Debounced reposition handler for performance
    debouncedReposition = () => {
        if (resizeScrollTimeout) {
            clearTimeout(resizeScrollTimeout);
        }
        resizeScrollTimeout = setTimeout(repositionEditor, 100); // 100ms debounce
    };

    // Add resize and scroll event listeners
    window.addEventListener('resize', debouncedReposition);
    window.addEventListener('scroll', debouncedReposition, true); // Use capture to catch all scroll events

    // Initial positioning
    repositionEditor();

    // Focus input
    input.focus();
    input.select();

    // Close when clicking outside
    closeOnOutsideClick = (e) => {
        if (!editor.contains(e.target) && e.target !== element) {
            cleanupEditor();
        }
    };
    setTimeout(() => document.addEventListener('click', closeOnOutsideClick), 0);

    // ═══════════════════════════════════════════════════════════════════════════════
    // END VIEWPORT-AWARE POSITIONING
    // ═══════════════════════════════════════════════════════════════════════════════
}

/**
 * Update item Jira ID via API
 * @param {Object} item - The kanban item
 * @param {string|null} newJira - The new Jira ID or null to clear
 * @param {HTMLElement} element - The Jira pill element to update
 */
async function updateItemJira(item, newJira, element) {
    const updates = {
        updatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
    };

    if (newJira) {
        updates.jiraId = newJira;
    }

    const payload = {
        team: CONFIG.team,
        id: item.id,
        updates: updates
    };

    // Handle clearing
    if (!newJira) {
        payload.clearFields = ['jiraId', 'jiraKey', 'jira'];
    }

    console.log('Updating Jira ID:', payload);

    try {
        const response = await apiFetch(apiUrl('/api/update-item'), {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            const errorText = await response.text();
            console.error('Failed to update Jira ID:', response.status, errorText);
            return;
        }

        // Update item data
        if (newJira) {
            item.jiraId = newJira;
            delete item.jiraKey;
            delete item.jira;
        } else {
            delete item.jiraId;
            delete item.jiraKey;
            delete item.jira;
        }

        // Update UI
        if (newJira) {
            element.className = 'backlog-jira editable';
            element.textContent = newJira;
            element.title = `${newJira} - Click to edit, Cmd+Click to open`;
            element.href = getJiraUrl(newJira);
        } else {
            // Transform into "add" button
            element.className = 'backlog-jira add-jira editable';
            element.textContent = '+LINK';
            element.title = 'Click to link ticket';
            element.removeAttribute('href');
        }

        console.log('Successfully updated Jira ID for', item.id, 'to', newJira);
    } catch (error) {
        console.error('Error updating Jira ID:', error);
    }
}

/**
 * Update subitem Jira ID via API
 * @param {Object} subitem - The subitem object
 * @param {string|null} newJira - The new Jira ID or null to clear
 * @param {HTMLElement} element - The Jira pill element to update
 * @param {number} parentIndex - Parent item index
 * @param {number} subIndex - Subitem index
 */
async function updateSubitemJira(subitem, newJira, element, parentIndex, subIndex) {
    const updates = {
        updatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
    };

    if (newJira) {
        updates.jiraKey = newJira;
    }

    const payload = {
        team: CONFIG.team,
        parentIndex: parentIndex,
        subIndex: subIndex,
        updates: updates
    };

    // Handle clearing
    if (!newJira) {
        payload.clearFields = ['jiraKey', 'jiraId', 'jira'];
    }

    console.log('Updating subitem Jira ID:', payload);

    try {
        const response = await apiFetch(apiUrl('/api/update-subitem'), {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            const errorText = await response.text();
            console.error('Failed to update subitem Jira ID:', response.status, errorText);
            return;
        }

        // Update subitem data
        if (newJira) {
            subitem.jiraKey = newJira;
            delete subitem.jiraId;
            delete subitem.jira;
        } else {
            delete subitem.jiraKey;
            delete subitem.jiraId;
            delete subitem.jira;
        }

        // Update UI
        if (newJira) {
            element.className = 'backlog-jira subitem-jira editable';
            element.textContent = newJira;
            element.title = `${newJira} - Click to edit, Cmd+Click to open`;
            element.href = getJiraUrl(newJira);
        } else {
            // Transform into "add" button
            element.className = 'backlog-jira subitem-jira add-jira editable';
            element.textContent = '+LINK';
            element.title = 'Click to link ticket';
            element.removeAttribute('href');
        }

        console.log('Successfully updated subitem Jira ID to', newJira);
    } catch (error) {
        console.error('Error updating subitem Jira ID:', error);
    }
}

/**
 * Show a dropdown menu for changing subitem priority
 * @param {HTMLElement} element - The priority pill element
 * @param {Object} subitem - The subitem object
 * @param {number} parentIndex - The parent item index
 * @param {number} subIndex - The subitem index
 */
function showSubitemPriorityDropdown(element, subitem, parentIndex, subIndex) {
    // Remove any existing dropdown
    const existingDropdown = document.querySelector('.priority-dropdown');
    if (existingDropdown) {
        existingDropdown.remove();
    }

    const dropdown = document.createElement('div');
    dropdown.className = 'priority-dropdown';

    const currentPriority = (subitem.priority || 'medium').toLowerCase();

    PRIORITY_LEVELS.forEach(priority => {
        const option = document.createElement('div');
        option.className = `priority-option ${priority}`;
        if (priority === currentPriority) {
            option.classList.add('selected');
        }
        option.textContent = priority.toUpperCase();
        option.addEventListener('click', (e) => {
            e.stopPropagation();
            updateSubitemField(subitem, parentIndex, subIndex, 'priority', priority, element, (el, val) => {
                el.className = `backlog-priority subitem-priority ${val} editable`;
                el.textContent = val.substring(0, 3).toUpperCase();
                el.title = `Priority: ${val} - Click to change`;
            });
            dropdown.remove();
        });
        dropdown.appendChild(option);
    });

    // Position dropdown below the priority pill
    const rect = element.getBoundingClientRect();
    dropdown.style.position = 'fixed';
    dropdown.style.top = `${rect.bottom + 2}px`;
    dropdown.style.left = `${rect.left}px`;
    dropdown.style.zIndex = '1000';

    document.body.appendChild(dropdown);

    // Close dropdown when clicking outside
    const closeDropdown = (e) => {
        if (!dropdown.contains(e.target) && e.target !== element) {
            dropdown.remove();
            document.removeEventListener('click', closeDropdown);
        }
    };
    setTimeout(() => document.addEventListener('click', closeDropdown), 0);
}

/**
 * Show OS selection dropdown for subitems
 * @param {HTMLElement} element - The OS logo element
 * @param {Object} subitem - The subitem object
 * @param {number} parentIndex - The parent item index
 * @param {number} subIndex - The subitem index
 */
function showSubitemOSDropdown(element, subitem, parentIndex, subIndex) {
    // Remove any existing dropdown
    const existingDropdown = document.querySelector('.os-dropdown');
    if (existingDropdown) {
        existingDropdown.remove();
    }

    const dropdown = document.createElement('div');
    dropdown.className = 'os-dropdown';

    const currentOS = getOSFromTags(subitem.tags) || 'None';

    // Add all OS options including None
    const osOptions = [...OS_PLATFORMS, 'None'];
    osOptions.forEach(os => {
        const option = document.createElement('div');
        option.className = 'os-option';
        const config = OS_CONFIG[os];
        option.style.borderLeftColor = config.color;

        if (os === currentOS) {
            option.classList.add('selected');
        }

        // Create logo preview
        if (config.logo) {
            const img = document.createElement('img');
            img.src = config.logo;
            img.alt = config.label;
            option.appendChild(img);
        } else {
            // Question mark icon for "None" (unspecified platform)
            const iconSpan = document.createElement('span');
            iconSpan.innerHTML = `<svg viewBox="0 0 24 24" fill="currentColor" width="16" height="16">
                <circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" stroke-width="2"/>
                <text x="12" y="17" text-anchor="middle" font-size="14" font-weight="bold" font-family="Arial, sans-serif">?</text>
            </svg>`;
            option.appendChild(iconSpan);
        }

        const label = document.createElement('span');
        label.textContent = config.label;
        option.appendChild(label);

        option.addEventListener('click', (e) => {
            e.stopPropagation();
            updateSubitemOS(subitem, parentIndex, subIndex, os === 'None' ? null : os, element);
            dropdown.remove();
        });
        dropdown.appendChild(option);
    });

    // Position dropdown below the OS logo
    const rect = element.getBoundingClientRect();
    dropdown.style.position = 'fixed';
    dropdown.style.top = `${rect.bottom + 2}px`;
    dropdown.style.left = `${rect.left}px`;
    dropdown.style.zIndex = '1000';

    document.body.appendChild(dropdown);

    // Close dropdown when clicking outside
    const closeDropdown = (e) => {
        if (!dropdown.contains(e.target) && e.target !== element) {
            dropdown.remove();
            document.removeEventListener('click', closeDropdown);
        }
    };
    setTimeout(() => document.addEventListener('click', closeDropdown), 0);
}

/**
 * Update subitem OS via API (updates tags array)
 * @param {Object} subitem - The subitem object
 * @param {number} parentIndex - The parent item index
 * @param {number} subIndex - The subitem index
 * @param {string|null} newOS - The new OS value (iOS, Android, Firebase) or null
 * @param {HTMLElement} element - The OS logo element to update
 */
async function updateSubitemOS(subitem, parentIndex, subIndex, newOS, element) {
    const newTags = updateOSInTags(subitem.tags || [], newOS);
    const parentItem = boardData.backlog[parentIndex];

    const payload = {
        team: CONFIG.team,
        id: parentItem.id,
        subitemIndex: subIndex,
        updates: {
            tags: newTags,
            updatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
        }
    };

    console.log('Updating subitem OS:', payload);

    try {
        const response = await apiFetch(apiUrl('/api/update-subitem'), {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            const errorText = await response.text();
            console.error('Failed to update subitem OS:', response.status, errorText);
            return;
        }

        // Update UI immediately
        subitem.tags = newTags;
        const config = OS_CONFIG[newOS] || OS_CONFIG['None'];
        element.style.borderColor = config.color;
        element.dataset.os = newOS || 'None';
        element.title = config.label;
        element.innerHTML = '';

        if (config.logo) {
            const img = document.createElement('img');
            img.src = config.logo;
            img.alt = config.label;
            element.appendChild(img);
        } else {
            element.innerHTML = `<svg viewBox="0 0 24 24" fill="currentColor">
                <rect x="2" y="2" width="9" height="9" rx="1"/>
                <rect x="13" y="2" width="9" height="9" rx="1"/>
                <rect x="2" y="13" width="9" height="9" rx="1"/>
                <rect x="13" y="13" width="9" height="9" rx="1"/>
            </svg>`;
        }

        console.log('Successfully updated subitem OS for', subitem.id, 'to', newOS || 'None');
    } catch (error) {
        console.error('Error updating subitem OS:', error);
    }
}

/**
 * Show a date editor popup for changing subitem due date
 * @param {HTMLElement} element - The due date pill element
 * @param {Object} subitem - The subitem object
 * @param {number} parentIndex - The parent item index
 * @param {number} subIndex - The subitem index
 */
function showSubitemDueDateEditor(element, subitem, parentIndex, subIndex) {
    // Remove any existing editor
    const existingEditor = document.querySelector('.due-date-editor');
    if (existingEditor) {
        existingEditor.remove();
    }

    const editor = document.createElement('div');
    editor.className = 'due-date-editor';

    // Date input
    const dateInput = document.createElement('input');
    dateInput.type = 'date';
    dateInput.className = 'due-date-input';
    if (subitem.dueDate) {
        dateInput.value = subitem.dueDate;
    }

    // Quick preset buttons
    const presets = document.createElement('div');
    presets.className = 'due-date-presets';

    const presetDays = [
        { label: 'Today', days: 0 },
        { label: '+1d', days: 1 },
        { label: '+3d', days: 3 },
        { label: '+1w', days: 7 },
        { label: '+2w', days: 14 }
    ];

    presetDays.forEach(preset => {
        const btn = document.createElement('button');
        btn.className = 'due-date-preset';
        btn.textContent = preset.label;
        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            const date = new Date();
            date.setDate(date.getDate() + preset.days);
            const dateStr = getLocalDateString(date);
            updateSubitemDueDate(subitem, parentIndex, subIndex, dateStr, element);
            editor.remove();
        });
        presets.appendChild(btn);
    });

    // Clear button (always visible, clears existing date or just closes if none)
    const clearBtn = document.createElement('button');
    clearBtn.className = 'due-date-preset clear';
    clearBtn.textContent = 'Clear';
    clearBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        if (subitem.dueDate) {
            updateSubitemDueDate(subitem, parentIndex, subIndex, null, element);
        }
        editor.remove();
    });
    presets.appendChild(clearBtn);

    // Track date changes for debugging
    dateInput.addEventListener('change', (e) => {
        console.log('Subitem date input changed to:', e.target.value);
    });

    // Set button for custom date
    const setBtn = document.createElement('button');
    setBtn.className = 'due-date-set';
    setBtn.textContent = 'Set';
    setBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        // Force blur to commit any typed value (Safari quirk)
        dateInput.blur();
        const dateValue = dateInput.value;
        console.log('Subitem Set button clicked, dateInput.value =', dateValue);
        if (dateValue) {
            updateSubitemDueDate(subitem, parentIndex, subIndex, dateValue, element);
        } else {
            console.warn('No date value to set for subitem');
        }
        editor.remove();
    });

    editor.appendChild(dateInput);
    editor.appendChild(presets);
    editor.appendChild(setBtn);

    // Position editor below the due date pill
    const rect = element.getBoundingClientRect();
    editor.style.position = 'fixed';
    editor.style.top = `${rect.bottom + 2}px`;
    editor.style.left = `${rect.left}px`;
    editor.style.zIndex = '1000';

    document.body.appendChild(editor);

    // Focus the date input
    dateInput.focus();

    // Close editor when clicking outside
    const closeEditor = (e) => {
        if (!editor.contains(e.target) && e.target !== element) {
            editor.remove();
            document.removeEventListener('click', closeEditor);
        }
    };
    setTimeout(() => document.addEventListener('click', closeEditor), 0);

    // Handle Enter key in date input
    dateInput.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' && dateInput.value) {
            updateSubitemDueDate(subitem, parentIndex, subIndex, dateInput.value, element);
            editor.remove();
        } else if (e.key === 'Escape') {
            editor.remove();
        }
    });
}

/**
 * Update a subitem field via API
 * @param {Object} subitem - The subitem object
 * @param {number} parentIndex - The parent item index
 * @param {number} subIndex - The subitem index
 * @param {string} field - The field to update
 * @param {*} value - The new value
 * @param {HTMLElement} element - The element to update
 * @param {Function} updateUI - Callback to update the UI element
 */
async function updateSubitemField(subitem, parentIndex, subIndex, field, value, element, updateUI) {
    const payload = {
        team: CONFIG.team,
        parentIndex: parentIndex,
        subIndex: subIndex,
        updates: {
            [field]: value,
            updatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
        }
    };

    console.log('Updating subitem field:', payload);

    try {
        const response = await apiFetch(apiUrl('/api/update-subitem'), {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            const errorText = await response.text();
            console.error('Failed to update subitem:', response.status, errorText);
            return;
        }

        // Update local data and UI
        subitem[field] = value;
        if (updateUI) {
            updateUI(element, value);
        }
        console.log('Successfully updated subitem field', field, 'to', value);
    } catch (error) {
        console.error('Error updating subitem:', error);
    }
}

/**
 * Update subitem due date via API
 * @param {Object} subitem - The subitem object
 * @param {number} parentIndex - The parent item index
 * @param {number} subIndex - The subitem index
 * @param {string|null} newDueDate - The new due date (YYYY-MM-DD) or null to clear
 * @param {HTMLElement} element - The due date pill element to update
 */
async function updateSubitemDueDate(subitem, parentIndex, subIndex, newDueDate, element) {
    const updates = {
        updatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
    };

    if (newDueDate) {
        updates.dueDate = newDueDate;
    }

    const payload = {
        team: CONFIG.team,
        parentIndex: parentIndex,
        subIndex: subIndex,
        updates: updates
    };

    // Handle clearing - need to delete the field
    if (!newDueDate && subitem.dueDate) {
        payload.clearFields = ['dueDate'];
    }

    console.log('Updating subitem due date:', payload);

    try {
        const response = await apiFetch(apiUrl('/api/update-subitem'), {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            const errorText = await response.text();
            console.error('Failed to update subitem due date:', response.status, errorText);
            return;
        }

        // Update UI immediately
        subitem.dueDate = newDueDate;
        if (newDueDate) {
            const status = getDueDateStatus(newDueDate);
            element.className = `backlog-due-date subitem-due-date ${status.replaceAll('_', '-')} editable`;
            element.textContent = formatDueDate(newDueDate);
            element.title = `Due: ${parseLocalDate(newDueDate).toLocaleDateString()} - Click to edit`;
        } else {
            element.className = 'backlog-due-date subitem-due-date no-date editable';
            element.textContent = '+DUE';
            element.title = 'Click to set due date';
        }
        console.log('Successfully updated subitem due date to', newDueDate);
    } catch (error) {
        console.error('Error updating subitem due date:', error);
    }
}

// Generate JIRA URL from ticket ID
function getJiraUrl(jiraId) {
    // Configure your JIRA base URL here
    const JIRA_BASE_URL = 'https://mainevent.atlassian.net/browse';
    return `${JIRA_BASE_URL}/${jiraId}`;
}

// Team default GitHub repos for shorthand issue format (#123)
const GITHUB_TEAM_REPOS = {
    academy: 'doublenode/dev-team',
    dns: 'doublenode/dns-framework',
    freelance: 'doublenode/dev-team'  // Default, can be overridden with full format
};

// Parse GitHub issue and generate URL
// Supports: "owner/repo#123" (full) or "#123" (uses team default)
function getGitHubUrl(issueRef, team) {
    const GITHUB_BASE = 'https://github.com';

    // Full format: owner/repo#123
    const fullMatch = issueRef.match(/^([^/]+)\/([^#]+)#(\d+)$/);
    if (fullMatch) {
        const [, owner, repo, issue] = fullMatch;
        return `${GITHUB_BASE}/${owner}/${repo}/issues/${issue}`;
    }

    // Shorthand format: #123 (uses team default repo)
    const shortMatch = issueRef.match(/^#?(\d+)$/);
    if (shortMatch) {
        const issue = shortMatch[1];
        const defaultRepo = GITHUB_TEAM_REPOS[team] || GITHUB_TEAM_REPOS.academy;
        return `${GITHUB_BASE}/${defaultRepo}/issues/${issue}`;
    }

    // Fallback: assume it's a full URL or return search
    return issueRef.startsWith('http') ? issueRef : `${GITHUB_BASE}/search?q=${encodeURIComponent(issueRef)}`;
}

// Format GitHub issue for display
function formatGitHubIssue(issueRef) {
    // Full format: show as-is
    if (issueRef.includes('/')) {
        return issueRef;
    }
    // Shorthand: ensure # prefix
    return issueRef.startsWith('#') ? issueRef : `#${issueRef}`;
}

// ═══════════════════════════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════════════════════════

function getDivisionColor(color) {
    const colors = {
        command: '#9999ff',
        operations: '#ff9900',
        science: '#99ffff',
        medical: '#99ff99'
    };
    return colors[color] || '#ffcc99';
}

function getStatusColor(status) {
    // Match swimlane column header colors
    const colors = {
        paused: '#ff6666',     // --lcars-red - paused/waiting
        ready: '#cc9966',      // --lcars-tan
        planning: '#cc99ff',   // --lcars-purple
        coding: '#99ccff',     // --lcars-cyan
        testing: '#99ff99',    // --lcars-green
        commit: '#ffff99',     // --lcars-yellow
        pr_review: '#ccccff'   // --lcars-lavender - awaiting PR review
    };
    return colors[status] || '#ffcc99';
}

/**
 * Copy text to clipboard and show feedback.
 *
 * XACA-0920: two-tier chain. Tier 1 (async Clipboard API) is attempted
 * first; on EITHER absence of the API OR a rejected writeText() promise,
 * control falls through to Tier 2 (legacy execCommand('copy')). The root
 * cause of the original intermittent failures is UNCONFIRMED — the ticket's
 * "unfocused document" hypothesis has not been reproduced — so this
 * function is written to be correct whether or not that hypothesis holds,
 * rather than assuming it either way.
 *
 * @param {string|number} text - Text to copy. Non-string values (e.g. a
 *   Number, such as `item.id || index` when `item.id` is falsy) are coerced
 *   to a string once, up front — see XACA-0920-015.
 * @param {Object} [options] - Optional behavior overrides
 * @param {string} [options.successMessage] - Toast message on confirmed
 *   success. Defaults to `Copied: ${text}`, which echoes the text back —
 *   pass this explicitly for large/multi-line content (e.g. release notes)
 *   where echoing the payload into a toast would be bad UX.
 * @returns {Promise<boolean>} Resolves true only when a copy was ACTUALLY
 *   confirmed (writeText() resolved, or execCommand('copy') returned
 *   true). Never rejects — existing fire-and-forget callers are unaffected;
 *   callers that care can `await` it or chain `.then()`.
 *
 * XACA-0920-013/016: `text` is checked against null/undefined/'' ONLY — NOT
 * a bare falsy check. `copyToClipboard(item.id || index)` yields the Number
 * `0` for an item with no id at index 0, and `0` is valid, copyable content.
 * A falsy guard would silently swallow that legitimate case as "nothing to
 * copy".
 */
function copyToClipboard(text, options) {
    if (text === null || text === undefined || text === '') {
        // XACA-0920-013/016: previously a silent `Promise.resolve(false)` —
        // clicking COPY on an empty editor/generated relnotes tab produced
        // zero user-visible feedback. Every click of the COPY button must
        // now produce a toast.
        showToast('Nothing to copy', 'info');
        return Promise.resolve(false);
    }

    // XACA-0920-015: coerce ONCE, up front, so every downstream use (toast
    // text, textarea.value, and — critically — textarea.setSelectionRange's
    // .length operand) operates on a real string. `text.length` on a raw
    // Number is `undefined`, which collapses the fallback's selection to
    // (0,0) and copies nothing.
    const value = String(text);
    const successMessage = (options && options.successMessage) || `Copied: ${value}`;

    // Tier 2: legacy execCommand('copy') fallback. Reachable from BOTH
    // "API missing" and "API rejected" (XACA-0920-002).
    function attemptExecCommandFallback() {
        const previousActiveElement = document.activeElement;

        // XACA-0920-003: avoid opacity:0 — WebKit can refuse to select text
        // inside a fully-transparent element. Position offscreen instead.
        const textarea = document.createElement('textarea');
        textarea.value = value;
        textarea.style.position = 'fixed';
        textarea.style.top = '0';
        textarea.style.left = '-9999px';
        textarea.readOnly = true; // suppress the iOS/WebKit on-screen keyboard
        document.body.appendChild(textarea);

        let succeeded = false;
        let thrownErr = null;
        try {
            textarea.select();
            // select() alone is unreliable on readonly textareas under WebKit.
            textarea.setSelectionRange(0, value.length);
            // execCommand('copy') returns false on failure WITHOUT throwing —
            // the return value MUST be captured, never assumed true.
            succeeded = document.execCommand('copy');
        } catch (err) {
            thrownErr = err;
        } finally {
            // Guarantee removal + focus restore on EVERY path, including
            // exceptions thrown between append and remove.
            document.body.removeChild(textarea);
            if (previousActiveElement && typeof previousActiveElement.focus === 'function') {
                try {
                    previousActiveElement.focus();
                } catch (restoreErr) {
                    // Best-effort focus restore only — never fatal.
                }
            }
        }

        return { succeeded, thrownErr };
    }

    // Tier 1: modern async Clipboard API.
    if (!(navigator.clipboard && navigator.clipboard.writeText)) {
        const { succeeded, thrownErr } = attemptExecCommandFallback();
        if (succeeded) {
            console.log('[LCARS] Copied to clipboard (fallback, API unavailable):', value);
            showToast(successMessage, 'success');
        } else {
            const reason = thrownErr ? `${thrownErr.name}: ${thrownErr.message}` : 'execCommand returned false';
            // XACA-0920-014: short, discriminating toast for a cockpit
            // (iTerm2 WKWebView) where a dev console may be unreachable —
            // the FULL diagnostic payload stays in console.error below,
            // which remains the mechanism for field-diagnosing this bug's
            // still-unconfirmed root cause.
            console.error('[LCARS] Fallback copy failed (API unavailable):', reason);
            showToast('Copy failed: clipboard unavailable — see console', 'error');
        }
        return Promise.resolve(succeeded);
    }

    // XACA-0920: defensive, cause-agnostic mitigation. The ticket's
    // hypothesis is that writeText() rejects with NotAllowedError when the
    // document isn't focused under WebKit — that is UNCONFIRMED, not
    // established fact. Attempting focus() first can only help if the
    // hypothesis is true; it's a harmless no-op (or throw, swallowed below)
    // if the hypothesis is false or the host doesn't support it.
    try {
        window.focus();
    } catch (focusErr) {
        // Ignore — best-effort only.
    }

    return navigator.clipboard.writeText(value).then(() => {
        console.log('[LCARS] Copied to clipboard:', value);
        showToast(successMessage, 'success');
        return true;
    }).catch(err => {
        // XACA-0920-001: instrumentation — surface the ACTUAL rejection
        // reason instead of swallowing it. err.name/err.message discriminate
        // DOMException causes (e.g. NotAllowedError); hasFocus()/
        // visibilityState are the signals for the (still unconfirmed)
        // "unfocused document" hypothesis at the moment of rejection.
        const hasFocus = document.hasFocus();
        const visibilityState = document.visibilityState;
        console.warn('[LCARS] Clipboard API rejected, falling back to execCommand:', err && err.name, err && err.message, {
            hasFocus: hasFocus,
            visibilityState: visibilityState,
            err: err
        });

        const { succeeded, thrownErr } = attemptExecCommandFallback();
        if (succeeded) {
            console.log('[LCARS] Copied to clipboard (fallback, API rejected):', value);
            showToast(successMessage, 'success');
        } else {
            // XACA-0920-004/014: distinct from the "API unavailable" message
            // above AND from a bare fallback failure — carries 001's full
            // API-tier diagnostic payload (err name/message, focus,
            // visibility, and the fallback's own failure reason) into
            // console.error so a field report still tells us both which
            // tier failed and why, even though the toast itself stays short
            // (a WKWebView cockpit console may not be reachable).
            const fallbackReason = thrownErr ? `${thrownErr.name}: ${thrownErr.message}` : 'execCommand returned false';
            console.error('[LCARS] Fallback copy also failed after API rejection:', fallbackReason, {
                apiErrName: err && err.name,
                apiErrMessage: err && err.message,
                hasFocus: hasFocus,
                visibilityState: visibilityState
            });
            showToast(`Copy failed: ${err && err.name} (focus=${hasFocus}) — see console`, 'error');
        }
        return succeeded;
    });
}

/**
 * Show a temporary toast notification
 * @param {string} message - Message to display
 * @param {string} type - Type: 'success', 'error', 'info'
 */
// NOTE: showToast() is defined at line 229 with close button, configurable duration, and proper LCARS styling

function formatRelativeTime(isoString) {
    if (!isoString) return '-';

    const now = Date.now();
    const then = new Date(isoString).getTime();
    const diff = now - then;

    const seconds = Math.floor(diff / 1000);
    const minutes = Math.floor(seconds / 60);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);

    if (seconds < 60) return 'just now';
    if (minutes < 60) return `${minutes}m ago`;
    if (hours < 24) return `${hours}h ${minutes % 60}m ago`;
    return `${days}d ${hours % 24}h ago`;
}

function formatAbsoluteTime(isoString) {
    if (!isoString) return '-';

    const date = new Date(isoString);
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    const hours = String(date.getHours()).padStart(2, '0');
    const minutes = String(date.getMinutes()).padStart(2, '0');

    return `${year}-${month}-${day} ${hours}:${minutes}`;
}

function formatSessionDuration(startedAt) {
    if (!startedAt) return '';

    const now = Date.now();
    const start = new Date(startedAt).getTime();
    const diff = now - start;

    const minutes = Math.floor(diff / 60000);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);

    if (minutes < 1) return '< 1m';
    if (minutes < 60) return `${minutes}m`;
    if (hours < 24) return `${hours}h ${minutes % 60}m`;
    return `${days}d ${hours % 24}h`;
}

// XACA-0029: Format accumulated work time from milliseconds
function formatWorkTime(ms) {
    if (!ms || ms <= 0) return '';

    const minutes = Math.floor(ms / 60000);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);

    if (minutes < 1) return '< 1m';
    if (minutes < 60) return `${minutes}m`;
    if (hours < 24) return `${hours}h ${minutes % 60}m`;
    return `${days}d ${hours % 24}h`;
}

// XACA-0029: Calculate total work time for a parent item by summing completed subitems
function calculateParentWorkTime(item) {
    if (!item || !item.subitems || item.subitems.length === 0) return 0;

    return item.subitems
        .filter(sub => sub.status === 'completed' && sub.timeWorkedMs)
        .reduce((total, sub) => total + (sub.timeWorkedMs || 0), 0);
}

// XACA-0551: Calculate active effort for an item — accumulated ms plus any live in-flight span.
// Returns total ms, or 0 if no effort data is present.
function calculateActiveEffort(item) {
    if (!item) return 0;
    const accumulated = Number(item.timeWorkedMs) || 0;
    // XACA-0552: freeze the clock for completed/cancelled items. A stale
    // workStartedAt left on a finished item would otherwise make the live span
    // (now - workStartedAt) tick up forever. Only in-flight items get the span.
    const finished = item.status === 'completed' || item.status === 'cancelled';
    if (!finished && item.workStartedAt) {
        // Guard against malformed timestamps: Math.max(0, NaN) is NaN, not 0.
        const started = new Date(item.workStartedAt).getTime();
        if (Number.isFinite(started)) {
            return accumulated + Math.max(0, Date.now() - started);
        }
    }
    return accumulated;
}

// XACA-0551: Format lead time — same granularity as formatWorkTime but semantically distinct.
// Lead times are typically hours/days so we always show days when >= 1d.
function formatLeadTime(ms) {
    if (!ms || ms <= 0) return '';

    const minutes = Math.floor(ms / 60000);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);

    if (minutes < 1) return '< 1m';
    if (minutes < 60) return `${minutes}m`;
    if (hours < 24) return `${hours}h ${minutes % 60}m`;
    return `${days}d ${hours % 24}h`;
}

// XACA-0551: Calculate live lead time ms for an in-progress item (createdAt||addedAt → now).
// Anchors on creation origin (same as completed lead time) so the number doesn't jump on completion.
function calculateLiveLeadTime(item) {
    if (!item) return 0;
    const originStr = item.createdAt || item.addedAt;
    if (!originStr) return 0;
    // Guard against malformed timestamps: Math.max(0, NaN) is NaN, not 0.
    const origin = new Date(originStr).getTime();
    if (!Number.isFinite(origin)) return 0;
    return Math.max(0, Date.now() - origin);
}

function getShortName(fullName) {
    if (!fullName) return 'Unknown';
    const parts = fullName.split(' ');
    return parts[parts.length - 1];
}

function updateStardate() {
    const now = new Date();
    const start = new Date(now.getFullYear(), 0, 0);
    const diff = now - start;
    const oneDay = 1000 * 60 * 60 * 24;
    const dayOfYear = Math.floor(diff / oneDay);
    const stardate = `${now.getFullYear()}.${String(dayOfYear).padStart(3, '0')}`;
    const el = document.getElementById('stardate');
    if (!el) return;
    // Only replace the leading text node so nested #tap-version span survives.
    if (el.firstChild && el.firstChild.nodeType === Node.TEXT_NODE) {
        el.firstChild.nodeValue = stardate;
    } else {
        el.textContent = stardate;
    }
}

function updateTimestamp() {
    const now = new Date().toLocaleTimeString();
    document.getElementById('last-update').textContent = now;
}

function showWindowDetails(win) {
    // Navigate to DETAILS tab
    switchSection('details');

    // Find and highlight the matching detail row
    setTimeout(() => {
        const detailRows = document.querySelectorAll('.detail-row');
        detailRows.forEach(row => {
            row.classList.remove('highlighted');
            if (row.dataset.terminal === win.terminal && row.dataset.window === String(win.window)) {
                row.classList.add('highlighted');
                row.scrollIntoView({ behavior: 'smooth', block: 'center' });
                // Remove highlight after animation
                setTimeout(() => {
                    row.classList.remove('highlighted');
                }, 2000);
            }
        });
    }, 300); // Allow section switch animation
}

function navigateToBacklogItem(itemIndex, subIndex = null) {
    // Navigate to BACKLOG tab
    switchSection('backlog');

    // Reset scroll position of the backlog section itself before navigating
    // The backlog-section is the actual scrollable container (position: absolute with overflow-y: auto)
    const backlogSection = document.querySelector('.backlog-section');
    if (backlogSection) {
        backlogSection.scrollTop = 0;
    }

    // Find, expand, scroll and highlight the backlog item
    setTimeout(() => {
        const backlogItems = document.querySelectorAll('.backlog-item');
        backlogItems.forEach(item => {
            item.classList.remove('highlighted');
            if (parseInt(item.dataset.itemIndex) === itemIndex) {
                // Expand the item if it has subitems and is collapsed
                if (item.classList.contains('has-subitems') && !item.classList.contains('expanded')) {
                    const expander = item.querySelector('.subitem-expander');
                    if (expander) {
                        expander.click();
                    }
                }

                // If targeting a specific subitem
                if (subIndex !== null) {
                    setTimeout(() => {
                        const subitem = item.querySelector(`.subitem[data-sub-index="${subIndex}"]`);
                        if (subitem) {
                            subitem.classList.add('highlighted');
                            // Use custom scroll to account for fixed status legend
                            scrollToElementInSection(subitem, backlogSection);
                            setTimeout(() => {
                                subitem.classList.remove('highlighted');
                            }, 2000);
                        }
                    }, 200); // Allow expansion animation
                } else {
                    item.classList.add('highlighted');
                    // Use custom scroll to account for fixed status legend
                    scrollToElementInSection(item, backlogSection);
                    setTimeout(() => {
                        item.classList.remove('highlighted');
                    }, 2000);
                }
            }
        });
    }, 300); // Allow section switch animation
}

/**
 * Scroll to an element within a section, accounting for the fixed status legend
 * @param {HTMLElement} element - The element to scroll to
 * @param {HTMLElement} container - The scrollable section container
 */
function scrollToElementInSection(element, container) {
    if (!element || !container) return;

    // The section has padding-top: 55px to account for the fixed status legend
    // We want to scroll so the element appears below that padding area
    const sectionPadding = 55;
    const desiredOffsetFromTop = -45; // Position element to show a peek of previous item

    // Get element's position relative to the scrollable container
    // Need to account for nested elements (element might be inside .backlog-list)
    let elementOffsetTop = 0;
    let current = element;
    while (current && current !== container) {
        elementOffsetTop += current.offsetTop;
        current = current.offsetParent;
    }

    // Calculate scroll position to place element at desired offset below status legend
    const targetScrollTop = elementOffsetTop - sectionPadding - desiredOffsetFromTop;

    // Smooth scroll to the target position
    container.scrollTo({
        top: Math.max(0, targetScrollTop),
        behavior: 'smooth'
    });
}

function navigateToBacklogItemById(itemId) {
    // Navigate to BACKLOG tab and find item by ID
    // ID can be a parent ID (e.g., "XACA-0001") or subitem ID (e.g., "XACA-0001-001")
    switchSection('backlog');

    setTimeout(() => {
        const backlog = boardData?.backlog || [];
        let foundItemIndex = -1;
        let foundSubIndex = null;
        let foundItem = null;
        let isFiltered = false;

        // Check if this is a subitem ID (has 3 segments like XACA-0001-001)
        const idParts = itemId.split('-');
        const isSubitemId = idParts.length >= 3 && /^\d{3}$/.test(idParts[idParts.length - 1]);

        if (isSubitemId) {
            // Subitem ID - find parent and subitem
            const parentId = idParts.slice(0, -1).join('-');
            backlog.forEach((item, idx) => {
                if (item.id === parentId && item.subitems) {
                    item.subitems.forEach((sub, subIdx) => {
                        if (sub.id === itemId) {
                            foundItem = item;
                            // Check if parent item matches current filters
                            if (itemMatchesFilter(item)) {
                                foundItemIndex = idx;
                                foundSubIndex = subIdx;
                            } else {
                                isFiltered = true;
                            }
                        }
                    });
                }
            });
        } else {
            // Parent item ID
            backlog.forEach((item, idx) => {
                if (item.id === itemId) {
                    foundItem = item;
                    // Check if item matches current filters
                    if (itemMatchesFilter(item)) {
                        foundItemIndex = idx;
                    } else {
                        isFiltered = true;
                    }
                }
            });
        }

        if (foundItemIndex >= 0) {
            navigateToBacklogItem(foundItemIndex, foundSubIndex);
        } else if (isFiltered) {
            // Item exists but is hidden by current filters
            showToast(`Item ${itemId} exists but is hidden by current backlog filters`, 'warning', 5000);
        } else if (foundItem) {
            // Item exists but filtering state is unclear (shouldn't happen)
            showToast(`Item ${itemId} not found in current backlog view`, 'warning');
        } else {
            // Item doesn't exist in backlog at all
            showToast(`Item ${itemId} not found in backlog`, 'warning');
        }
    }, 100);
}

// ─── XACA-0657-005: CR↔Release bidirectional navigation ─────────────────────

/**
 * Navigate from a CR row to its linked release.
 * Switches to the Releases section, then focuses and highlights the release card.
 * Called by the `.cr-release-link` click handler in lcars-cr-tab.js.
 */
function navigateToCRLinkedRelease(releaseId) {
    switchSection('releases');
    // Wait for the section to become active and releases to render, then scroll/highlight
    setTimeout(() => {
        const card = document.querySelector(`.release-card[data-release-id="${CSS.escape(releaseId)}"]`);
        if (!card) return;
        card.scrollIntoView({ behavior: 'smooth', block: 'center' });
        card.classList.add('highlight-pulse');
        setTimeout(() => card.classList.remove('highlight-pulse'), 2000);
    }, 150);
}

/**
 * Navigate from a release's linked-CR chip to the CR row.
 * Switches to the CHANGE REQ section, then focuses and highlights the CR row.
 * Called by the `.release-cr-link` click handler inline in renderReleaseCard().
 */
function navigateToReleaseCR(crId) {
    switchSection('change-req');
    // Wait for renderChangeReqList() to fire (triggered by switchSection change-req hook)
    setTimeout(() => {
        const row = document.querySelector(`.cr-row[data-cr-id="${CSS.escape(crId)}"]`);
        if (!row) return;
        row.scrollIntoView({ behavior: 'smooth', block: 'center' });
        row.classList.add('highlight-pulse');
        setTimeout(() => row.classList.remove('highlight-pulse'), 2000);
    }, 150);
}

// ═══════════════════════════════════════════════════════════════════════════════
// DUE DATE HELPERS
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Get the due date status category for a given date
 * Returns granular status for color gradient:
 * - past_due: overdue (red with pulse)
 * - due_today: today (orange)
 * - due_tomorrow: tomorrow
 * - due_2 through due_7: days until due (green→orange gradient)
 * - due_weeks: 1-2 weeks out (green)
 * - due_distant: > 2 weeks (dark green)
 *
 * @param {string} dueDateString - ISO date string (e.g., "2026-01-10")
 * @returns {string|null} - Status string for CSS class, or null
 */
function getDueDateStatus(dueDateString) {
    if (!dueDateString) return null;

    const today = new Date();
    today.setHours(0, 0, 0, 0);

    const dueDate = parseLocalDate(dueDateString);
    dueDate.setHours(0, 0, 0, 0);

    const diffTime = dueDate.getTime() - today.getTime();
    const diffDays = Math.floor(diffTime / (1000 * 60 * 60 * 24));

    if (diffDays < 0) return 'past_due';
    if (diffDays === 0) return 'due_today';
    if (diffDays === 1) return 'due_tomorrow';
    if (diffDays <= 7) return `due_${diffDays}`;
    if (diffDays <= 14) return 'due_weeks';
    return 'due_distant';
}

/**
 * Map due date status to urgency CSS class for calendar items
 * @param {string} status - Status from getDueDateStatus()
 * @returns {string} - CSS class name (urgency-overdue, urgency-imminent, urgency-soon, urgency-future)
 */
function getUrgencyClass(status) {
    if (!status) return 'urgency-future';

    // Overdue (past due)
    if (status === 'past_due') return 'urgency-overdue';

    // Imminent (today, tomorrow, or due in 1 day)
    if (status === 'due_today' || status === 'due_tomorrow' || status === 'due_1') {
        return 'urgency-imminent';
    }

    // Soon (2-3 days out)
    if (status === 'due_2' || status === 'due_3') {
        return 'urgency-soon';
    }

    // Future (4+ days out)
    return 'urgency-future';
}

/**
 * Get date string in YYYY-MM-DD format using local timezone
 * @param {Date} date - Date object
 * @returns {string} - Date string in YYYY-MM-DD format
 */
function getLocalDateString(date) {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return `${year}-${month}-${day}`;
}

/**
 * Parse a YYYY-MM-DD date string as local time (not UTC)
 * @param {string} dateString - Date string in YYYY-MM-DD format
 * @returns {Date} - Date object in local timezone
 */
function parseLocalDate(dateString) {
    if (!dateString) return null;
    const [year, month, day] = dateString.split('-').map(Number);
    return new Date(year, month - 1, day);
}

/**
 * Format due date for display
 * @param {string} dueDateString - ISO date string
 * @param {boolean} isCompleted - If true, always show actual date (no relative strings)
 * @returns {string} - Formatted display string
 */
function formatDueDate(dueDateString, isCompleted = false) {
    if (!dueDateString) return '';

    const dueDate = parseLocalDate(dueDateString);

    // Completed items always show the actual date - never "X days overdue" or relative strings
    if (isCompleted) {
        return dueDate.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
    }

    const today = new Date();
    today.setHours(0, 0, 0, 0);
    dueDate.setHours(0, 0, 0, 0);

    const diffTime = dueDate.getTime() - today.getTime();
    const diffDays = Math.floor(diffTime / (1000 * 60 * 60 * 24));

    if (diffDays < -1) {
        const days = Math.abs(diffDays);
        return `${days} ${days === 1 ? 'day' : 'days'} overdue`;
    }
    if (diffDays === -1) return 'Yesterday';
    if (diffDays === 0) return 'Today';
    if (diffDays === 1) return 'Tomorrow';
    if (diffDays <= 7) return `${diffDays} days`;
    const weeks = Math.ceil(diffDays / 7);
    if (weeks <= 4) return `${weeks} week${weeks > 1 ? 's' : ''}`;

    // For dates beyond a month, show the date
    return dueDate.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
}

/**
 * Get the effective due date for an item, considering inheritance from subitems
 *
 * This function implements the "inherited due date" feature (XACA-0052):
 * - If the item has a direct dueDate property, that takes precedence
 * - If the item has no dueDate but has subitems with due dates, returns the EARLIEST subitem due date
 * - If neither the item nor any subitems have due dates, returns null
 *
 * @param {object} item - Kanban item (with optional subitems array)
 * @returns {object|null} - Object with { date: string, source: 'direct'|'inherited' } or null
 *
 * @example
 * // Item with direct due date
 * const result = getEffectiveDueDate({ dueDate: '2026-02-15' });
 * // Returns: { date: '2026-02-15', source: 'direct' }
 *
 * @example
 * // Item inheriting earliest subitem date
 * const result = getEffectiveDueDate({
 *   subitems: [
 *     { dueDate: '2026-02-20' },
 *     { dueDate: '2026-02-10' }, // earliest
 *     { dueDate: '2026-02-25' }
 *   ]
 * });
 * // Returns: { date: '2026-02-10', source: 'inherited' }
 *
 * @example
 * // Item with no due dates
 * const result = getEffectiveDueDate({ subitems: [] });
 * // Returns: null
 */
function getEffectiveDueDate(item) {
    // Validate input
    if (!item) return null;

    // Priority 1: Direct due date on the item itself
    if (item.dueDate) {
        return {
            date: item.dueDate,
            source: 'direct'
        };
    }

    // Priority 2: Inherit earliest due date from subitems
    if (item.subitems && item.subitems.length > 0) {
        // Filter subitems that have due dates AND are not completed
        // Completed subitems should not contribute to inherited due date
        const subitemsWithDates = item.subitems.filter(sub => sub.dueDate && sub.status !== 'completed');

        if (subitemsWithDates.length > 0) {
            // Find the earliest due date among subitems
            // Use parseLocalDate to properly compare dates
            let earliestDate = null;
            let earliestDateString = null;

            for (const sub of subitemsWithDates) {
                const subDate = parseLocalDate(sub.dueDate);

                if (!subDate) continue; // Skip invalid dates

                if (!earliestDate || subDate < earliestDate) {
                    earliestDate = subDate;
                    earliestDateString = sub.dueDate;
                }
            }

            if (earliestDateString) {
                return {
                    date: earliestDateString,
                    source: 'inherited'
                };
            }
        }
    }

    // Priority 3: No due date found
    return null;
}

/**
 * Check if a status matches a filter category
 * Maps granular statuses to filter categories
 * @param {string} status - Granular status from getDueDateStatus
 * @param {string} filter - Filter category from UI
 * @returns {boolean}
 */
function statusMatchesFilter(status, filter) {
    if (filter === status) return true;

    // "due_this_week" filter matches: tomorrow, due_2-7
    if (filter === 'due_this_week') {
        if (status === 'due_tomorrow') return true;
        if (/^due_[2-7]$/.test(status)) return true;
    }

    return false;
}

/**
 * Check if an item matches the text search filter
 * @param {object} item - Backlog item
 * @param {string} searchText - Search text (already lowercase)
 * @returns {boolean} - Whether the item matches the search
 */
function itemMatchesTextFilter(item, searchText) {
    if (!searchText) return true;

    // Handle special filter prefixes
    // worktree:<path> - filter by worktree path
    // branch:<name> - filter by git branch name
    // working - filter to show only items with activelyWorking=true
    if (searchText.startsWith('worktree:')) {
        const worktreeFilter = searchText.substring(9).toLowerCase();
        // Check item worktree
        if (item.worktree && item.worktree.toLowerCase().includes(worktreeFilter)) {
            return true;
        }
        // Check subitem worktrees
        if (item.subitems) {
            for (const sub of item.subitems) {
                if (sub.worktree && sub.worktree.toLowerCase().includes(worktreeFilter)) {
                    return true;
                }
            }
        }
        return false;
    }

    if (searchText.startsWith('branch:')) {
        const branchFilter = searchText.substring(7).toLowerCase();
        // Check item branch
        if (item.worktreeBranch && item.worktreeBranch.toLowerCase().includes(branchFilter)) {
            return true;
        }
        // Check subitem branches
        if (item.subitems) {
            for (const sub of item.subitems) {
                if (sub.worktreeBranch && sub.worktreeBranch.toLowerCase().includes(branchFilter)) {
                    return true;
                }
            }
        }
        return false;
    }

    if (searchText === 'working' || searchText === 'active') {
        // Show items that are actively being worked on
        if (item.activelyWorking) return true;
        if (item.subitems) {
            for (const sub of item.subitems) {
                if (sub.activelyWorking) return true;
            }
        }
        return false;
    }

    // Check item fields
    const itemText = [
        item.title || '',
        item.description || '',
        item.id || '',
        item.category || '',
        item.project || '',
        item.worktreeBranch || ''  // Include branch in general text search
    ].join(' ').toLowerCase();

    if (itemText.includes(searchText)) return true;

    // Check item tags
    if (item.tags && Array.isArray(item.tags)) {
        for (const tag of item.tags) {
            if (tag.toLowerCase().includes(searchText)) return true;
        }
    }

    // Check subitems
    if (item.subitems && item.subitems.length > 0) {
        for (const subitem of item.subitems) {
            const subText = [
                subitem.title || '',
                subitem.description || '',
                subitem.id || '',
                subitem.worktreeBranch || ''  // Include branch in subitem search
            ].join(' ').toLowerCase();
            if (subText.includes(searchText)) return true;

            // Check subitem tags
            if (subitem.tags && Array.isArray(subitem.tags)) {
                for (const tag of subitem.tags) {
                    if (tag.toLowerCase().includes(searchText)) return true;
                }
            }
        }
    }

    return false;
}

/**
 * Check if an item (or any of its subitems) matches the active filters
 * @param {object} item - Backlog item
 * @returns {boolean} - Whether the item should be displayed
 */
function itemMatchesFilter(item) {
    const filters = backlogFilterState.activeFilters;
    const searchText = (backlogFilterState.searchText || '').toLowerCase().trim();

    // First check text filter - must match if there's search text
    if (!itemMatchesTextFilter(item, searchText)) return false;

    // Check OS filter
    const osFilter = backlogFilterState.osFilter || 'all';
    if (osFilter !== 'all') {
        const itemOS = getOSFromTags(item.tags);
        if (osFilter === 'none') {
            // "None" means items with no OS tag
            if (itemOS !== null) return false;
        } else {
            // Specific OS selected
            if (itemOS !== osFilter) return false;
        }
    }

    // Check release filter (XACA-0023)
    const releaseFilter = backlogFilterState.releaseFilter || 'all';
    if (releaseFilter !== 'all') {
        const hasRelease = item.releaseAssignment && item.releaseAssignment.releaseId;
        if (releaseFilter === 'assigned') {
            if (!hasRelease) return false;
        } else if (releaseFilter === 'unassigned') {
            if (hasRelease) return false;
        } else {
            // Specific release ID
            if (!hasRelease || item.releaseAssignment.releaseId !== releaseFilter) return false;
        }
    }

    // Check epic filter (XACA-0040)
    const epicFilter = backlogFilterState.epicFilter || 'all';
    if (epicFilter !== 'all') {
        const hasEpic = item.epicId;
        if (epicFilter === 'assigned') {
            if (!hasEpic) return false;
        } else if (epicFilter === 'unassigned') {
            if (hasEpic) return false;
        } else {
            // Specific epic ID
            if (!hasEpic || item.epicId !== epicFilter) return false;
        }
    }

    // Check category filter
    const categoryFilter = backlogFilterState.categoryFilter || 'all';
    if (categoryFilter !== 'all') {
        const hasCategory = item.category;
        if (categoryFilter === 'none') {
            // Show only items without a category
            if (hasCategory) return false;
        } else {
            // Specific category
            if (!hasCategory || item.category.toLowerCase() !== categoryFilter) return false;
        }
    }

    // Check CR filter (XACA-0310-003)
    const crFilter = backlogFilterState.crFilter || 'all';
    if (crFilter !== 'all') {
        const itemCRId = (item.crAssignment && item.crAssignment.crId) || '';
        if (crFilter === 'none') {
            // UNASSIGNED: only items without a crAssignment
            if (itemCRId) return false;
        } else {
            // Specific CR ID
            if (itemCRId !== crFilter) return false;
        }
    }

    // Check for 'completed' filter - show completed AND cancelled items
    if (filters.includes('completed')) {
        return item.status === 'completed' || item.status === 'cancelled';
    }

    // Check for 'in_progress' filter - show items being actively worked on
    if (filters.includes('in_progress')) {
        // Item is in progress or has in_progress subitems
        if (item.status === 'in_progress' || item.activelyWorking) return true;
        if (item.subitems) {
            return item.subitems.some(sub => sub.status === 'in_progress');
        }
        return false;
    }

    // Check for 'paused' filter - show items that are paused
    if (filters.includes('paused')) {
        return itemIsPaused(item);
    }

    // Check for 'blocked' filter - show items that are dependency-blocked
    if (filters.includes('blocked')) {
        return item.status === 'blocked' || (item.blockedBy && item.blockedBy.length > 0);
    }

    // 'all' filter shows all ACTIVE (non-completed, non-cancelled) items
    if (filters.includes('all')) {
        return item.status !== 'completed' && item.status !== 'cancelled';
    }

    // For other filters, also exclude completed/cancelled items by default
    if (item.status === 'completed' || item.status === 'cancelled') return false;

    // Check for no_due_date filter - item has no effective due date (direct or inherited)
    if (filters.includes('no_due_date')) {
        const effectiveDueDate = getEffectiveDueDate(item);
        if (!effectiveDueDate) return true;
    }

    // Check item's effective due date (direct or inherited from subitems)
    const effectiveDueDate = getEffectiveDueDate(item);
    if (effectiveDueDate) {
        const status = getDueDateStatus(effectiveDueDate.date);
        for (const filter of filters) {
            if (statusMatchesFilter(status, filter)) return true;
        }
    }

    return false;
}

/**
 * Check if an item or any of its subitems has an overdue date
 * Uses effective due date (direct or inherited from subitems)
 * @param {object} item - Backlog item
 * @returns {boolean}
 */
function itemHasOverdue(item) {
    const effectiveDueDate = getEffectiveDueDate(item);
    return effectiveDueDate && getDueDateStatus(effectiveDueDate.date) === 'past_due';
}

/**
 * Check if an item or subitem is paused by looking at activeWindows AND backlog item
 * XACA-0019: Now also checks pausedReason on the backlog item itself for persistence
 * @param {string} itemId - The item or subitem ID to check
 * @returns {object|null} - { paused: true, reason: "...", previousStatus: "...", source: "window"|"item" } or null
 */
function getPausedStatus(itemId) {
    if (!boardData || !itemId) return null;

    // First check activeWindows (real-time paused status from active sessions)
    if (boardData.activeWindows) {
        for (const win of boardData.activeWindows) {
            if (win.workingOnId === itemId && win.status === 'paused') {
                return {
                    paused: true,
                    reason: win.pausedReason || 'Unknown reason',
                    previousStatus: win.previousStatus || 'unknown',
                    source: 'window'
                };
            }
        }
    }

    // XACA-0019: Also check the backlog item itself for persisted paused state
    // This allows paused status to display even when no active window exists
    if (boardData.backlog) {
        for (const item of boardData.backlog) {
            if (item.id === itemId && item.pausedReason) {
                return {
                    paused: true,
                    reason: item.pausedReason,
                    previousStatus: item.pausedPreviousStatus || 'unknown',
                    source: 'item'
                };
            }
            // Check subitems
            if (item.subitems) {
                for (const sub of item.subitems) {
                    if (sub.id === itemId && sub.pausedReason) {
                        return {
                            paused: true,
                            reason: sub.pausedReason,
                            previousStatus: sub.pausedPreviousStatus || 'unknown',
                            source: 'item'
                        };
                    }
                }
            }
        }
    }

    return null;
}

/**
 * Check if an item or any of its subitems is paused
 * Checks both activeWindows and persisted paused state on backlog items
 * @param {object} item - The backlog item
 * @returns {boolean}
 */
function itemIsPaused(item) {
    // Check if the item itself is paused (via window or persisted state)
    if (getPausedStatus(item.id)) return true;
    // Also check direct pausedReason on the item (fallback)
    if (item.pausedReason) return true;
    // Check subitems
    if (item.subitems) {
        return item.subitems.some(sub => getPausedStatus(sub.id) || sub.pausedReason);
    }
    return false;
}

/**
 * XACA-0020: Find which window is actively working on an item or subitem
 * Looks up activeWindows to find which terminal/window has this item as workingOnId
 * @param {string} itemId - The item or subitem ID to check
 * @returns {object|null} - { windowId, terminal, developer, status } or null
 */
function getWorkingWindow(itemId) {
    if (!boardData || !itemId || !boardData.activeWindows) return null;

    for (const win of boardData.activeWindows) {
        if (win.workingOnId === itemId) {
            return {
                windowId: win.id,
                terminal: win.terminal,
                windowName: win.windowName,
                developer: win.developer,
                status: win.status,
                color: win.color
            };
        }
    }
    return null;
}

/**
 * Look up an active window by its ID (e.g., "medical:medical-cmd")
 * Used as fallback when getWorkingWindow doesn't find a match by workingOnId
 * @param {string} windowId - The window ID to look up
 * @returns {object|null} - Window info or null
 */
function getWindowById(windowId) {
    if (!boardData || !windowId || !boardData.activeWindows) return null;

    for (const win of boardData.activeWindows) {
        if (win.id === windowId) {
            return {
                windowId: win.id,
                terminal: win.terminal,
                windowName: win.windowName,
                developer: win.developer,
                status: win.status,
                color: win.color
            };
        }
    }
    return null;
}

// ═══════════════════════════════════════════════════════════════════════════════
// CALENDAR RENDERING & NAVIGATION
// ═══════════════════════════════════════════════════════════════════════════════
//
// EXTERNAL CALENDAR EVENTS (XACA-0036-008):
// - Displays synced events from external calendars (Google, Outlook, etc.)
// - Gracefully handles missing XACA-0039 calendar integration
// - Toggle control only appears if calendar integration is enabled
// - External events displayed with sync icon (↻) and read-only styling
// - Uses localStorage to persist show/hide preference
//
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Check if calendar integration is enabled
 * Returns true if XACA-0039 calendar sync is configured
 */
async function checkCalendarIntegration() {
    try {
        const response = await fetch(apiUrl('/api/calendar/config'));
        if (!response.ok) return false;
        const config = await response.json();
        // Integration is enabled if either provider is connected
        return (config.apple && config.apple.connected) || (config.google && config.google.connected) || false;
    } catch {
        return false;  // Graceful fallback if API doesn't exist
    }
}

/**
 * Fetch external calendar events for a date range
 * Returns empty array if integration not available or error occurs
 */
async function fetchExternalEvents(startDate, endDate) {
    try {
        const start = startDate.toISOString().split('T')[0];
        const end = endDate.toISOString().split('T')[0];

        const response = await fetch(apiUrl(`/api/calendar/external?start=${start}&end=${end}`));
        if (!response.ok) {
            return [];
        }

        const data = await response.json();
        return data.events || [];
    } catch {
        return [];  // Graceful fallback
    }
}

/**
 * Load external events for current calendar view
 * Updates calendarState.externalEvents and sync status (XACA-0039-010)
 */
async function loadExternalEvents() {
    if (!calendarState.hasCalendarIntegration || !calendarState.showExternalEvents) {
        calendarState.externalEvents = [];
        calendarState.syncStatus = calendarState.hasCalendarIntegration ? 'synced' : 'not_connected';
        return;
    }

    // Set syncing state
    calendarState.isSyncing = true;
    calendarState.syncStatus = 'syncing';
    updateSyncStatusIndicator();  // Update UI immediately

    const { viewMode, currentDate } = calendarState;
    let startDate, endDate;

    if (viewMode === 'week') {
        startDate = getWeekStart(currentDate);
        endDate = new Date(startDate);
        endDate.setDate(endDate.getDate() + 6);
    } else {
        // Month view
        startDate = new Date(currentDate.getFullYear(), currentDate.getMonth(), 1);
        endDate = new Date(currentDate.getFullYear(), currentDate.getMonth() + 1, 0);
    }

    try {
        calendarState.externalEvents = await fetchExternalEvents(startDate, endDate);

        // Sync successful
        calendarState.syncStatus = 'synced';
        calendarState.lastSyncTime = new Date();
        calendarState.syncError = null;
    } catch (error) {
        // Sync failed
        calendarState.syncStatus = 'error';
        calendarState.syncError = error.message || 'Failed to sync external events';
        calendarState.externalEvents = [];
    } finally {
        calendarState.isSyncing = false;
        updateSyncStatusIndicator();  // Update UI with final state
    }
}

/**
 * Toggle external events display
 */
function toggleExternalEvents() {
    calendarState.showExternalEvents = !calendarState.showExternalEvents;
    localStorage.setItem(CALENDAR_EXTERNAL_KEY, calendarState.showExternalEvents.toString());
    renderCalendar();
}

/**
 * Update sync status indicator in calendar header (XACA-0039-010)
 * Updates the badge text, color, and timestamp without re-rendering entire calendar
 */
function updateSyncStatusIndicator() {
    const badge = document.getElementById('calendar-sync-badge');
    const timestamp = document.getElementById('calendar-sync-timestamp');
    const errorMsg = document.getElementById('calendar-sync-error');

    if (!badge) return;  // Not rendered yet

    // Update badge based on status
    switch (calendarState.syncStatus) {
        case 'synced':
            badge.textContent = '✓ SYNCED';
            badge.className = 'calendar-sync-badge synced';
            break;
        case 'syncing':
            badge.textContent = '↻ SYNCING...';
            badge.className = 'calendar-sync-badge syncing';
            break;
        case 'error':
            badge.textContent = '⚠ ERROR';
            badge.className = 'calendar-sync-badge error';
            break;
        case 'not_connected':
            badge.textContent = '○ NOT CONNECTED';
            badge.className = 'calendar-sync-badge not-connected';
            break;
    }

    // Update timestamp
    if (timestamp && calendarState.lastSyncTime) {
        const elapsed = getTimeElapsed(calendarState.lastSyncTime);
        timestamp.textContent = `Last sync: ${elapsed}`;
        timestamp.style.display = 'block';
    } else if (timestamp) {
        timestamp.style.display = 'none';
    }

    // Update error message
    if (errorMsg) {
        if (calendarState.syncError) {
            errorMsg.textContent = calendarState.syncError;
            errorMsg.style.display = 'block';
        } else {
            errorMsg.style.display = 'none';
        }
    }
}

/**
 * Manual sync trigger (XACA-0039-010)
 * Forces refresh of external events
 */
async function manualSyncCalendar() {
    if (!calendarState.hasCalendarIntegration || calendarState.isSyncing) {
        return;  // Can't sync or already syncing
    }

    calendarState.isSyncing = true;
    calendarState.syncStatus = 'syncing';
    updateSyncStatusIndicator();

    try {
        // Trigger server-side sync (push kanban items to calendar, pull external events)
        const response = await apiFetch(apiUrl('/api/calendar/sync/trigger'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ direction: 'both' })
        });

        const syncData = await response.json().catch(() => ({}));

        if (!response.ok) {
            // XACA-0395 [UX-16]: carry status onto the Error so the catch below can
            // defer to api-auth.js's central 401 notifier instead of double-toasting.
            const syncErr = new Error(syncData.error || 'Sync failed');
            syncErr.status = response.status;
            throw syncErr;
        }

        // Reload external events and re-render
        await loadExternalEvents();
        renderCalendarGrid();

        calendarState.syncStatus = 'synced';
        calendarState.lastSyncTime = new Date().toISOString();
        calendarState.syncError = null;

        // Show sync stats in toast
        const result = syncData.result || {};
        const outbound = result.outbound || {};
        const itemCount = result.itemsWithDueDates || 0;
        const created = outbound.created || 0;
        const updated = outbound.updated || 0;
        const errors = outbound.errors || 0;
        const statsMsg = `Synced ${created} created, ${updated} updated` + (errors > 0 ? `, ${errors} errors` : '') + ` (${itemCount} items)`;
        showToast(statsMsg, errors > 0 ? 'warning' : 'success');
    } catch (error) {
        console.error('Calendar sync failed:', error);
        calendarState.syncStatus = 'error';
        calendarState.syncError = error.message;
        // XACA-0395 [UX-16]: on 401, api-auth.js already surfaced the actionable
        // central auth-failure toast — skip the redundant local one.
        // XACA-0395-015: same skip on a network-level failure (isNetworkFailure).
        if (!error || (error.status !== 401 && !error.isNetworkFailure)) {
            showToast(`Calendar sync failed: ${error.message}`, 'error');
        }
    } finally {
        calendarState.isSyncing = false;
        updateSyncStatusIndicator();
    }
}

/**
 * Get time elapsed since a timestamp in human-readable format
 */
function getTimeElapsed(timestamp) {
    const now = new Date();
    const diffMs = now - timestamp;
    const diffSec = Math.floor(diffMs / 1000);
    const diffMin = Math.floor(diffSec / 60);
    const diffHr = Math.floor(diffMin / 60);

    if (diffSec < 60) return 'just now';
    if (diffMin < 60) return `${diffMin}m ago`;
    if (diffHr < 24) return `${diffHr}h ago`;

    const diffDays = Math.floor(diffHr / 24);
    return `${diffDays}d ago`;
}

/**
 * Fetch calendar items (kanban items and epics) for a date range
 * Implements caching to avoid repeated API calls for the same range
 * Only fetches items for the current team's kanban board
 */
async function fetchCalendarItems(startDate, endDate) {
    const start = startDate.toISOString().split('T')[0];
    const end = endDate.toISOString().split('T')[0];
    const team = CONFIG.team || 'academy';

    // Return cached data if available and covers the requested range and team
    if (calendarState.cachedItems &&
        calendarState.cacheStartDate === start &&
        calendarState.cacheEndDate === end &&
        calendarState.cacheTeam === team) {
        return {
            items: calendarState.cachedItems,
            epics: calendarState.cachedEpics
        };
    }

    try {
        const response = await fetch(apiUrl(`/api/calendar/items?start=${start}&end=${end}&team=${encodeURIComponent(team)}`));
        if (!response.ok) {
            console.error('Failed to fetch calendar items:', response.statusText);
            return { items: [], epics: [] };
        }

        const data = await response.json();

        // Cache the results
        calendarState.cachedItems = data.items || [];
        calendarState.cachedEpics = data.epics || [];
        calendarState.cacheStartDate = start;
        calendarState.cacheEndDate = end;
        calendarState.cacheTeam = team;

        return {
            items: data.items,
            epics: data.epics
        };
    } catch (error) {
        console.error('Error fetching calendar items:', error);
        return { items: [], epics: [] };
    }
}

/**
 * Load calendar items for current calendar view
 * Updates calendarState cache
 */
async function loadCalendarItems() {
    const { viewMode, currentDate } = calendarState;
    let startDate, endDate;

    if (viewMode === 'week') {
        startDate = getWeekStart(currentDate);
        endDate = new Date(startDate);
        endDate.setDate(endDate.getDate() + 6);
    } else {
        // Month view
        startDate = new Date(currentDate.getFullYear(), currentDate.getMonth(), 1);
        endDate = new Date(currentDate.getFullYear(), currentDate.getMonth() + 1, 0);
    }

    await fetchCalendarItems(startDate, endDate);
}

/**
 * Check for calendar sync conflicts and show modal if any exist
 */
async function checkForCalendarConflicts() {
    if (!calendarState.hasCalendarIntegration) {
        return;
    }

    try {
        const response = await fetch(apiUrl('/api/calendar/conflicts'));
        const data = await response.json();

        if (data.success && data.count > 0) {
            showConflictResolutionModal(data.conflicts);
        }
    } catch (error) {
        console.error('Error checking for conflicts:', error);
    }
}

/**
 * Show conflict resolution modal with side-by-side comparison
 */
function showConflictResolutionModal(conflicts) {
    const modal = document.createElement('div');
    modal.className = 'lcars-modal conflict-modal';
    modal.innerHTML = `
        <div class="lcars-modal-content conflict-modal-content">
            <div class="lcars-modal-header">
                <h2>CALENDAR SYNC CONFLICTS</h2>
                <button class="lcars-modal-close" onclick="closeConflictModal()">[X]</button>
            </div>
            <div class="conflict-warning">
                <div class="conflict-icon">⚠️</div>
                <p>${conflicts.length} item(s) have been modified both locally and in the calendar since last sync.</p>
            </div>
            <div class="conflicts-list">
                ${conflicts.map((conflict, index) => renderConflictItem(conflict, index)).join('')}
            </div>
        </div>
    `;

    document.body.appendChild(modal);
    setTimeout(() => modal.classList.add('active'), 10);
}

/**
 * Render a single conflict item with side-by-side comparison
 */
function renderConflictItem(conflict, index) {
    const { itemId, title, type, localVersion, externalVersion } = conflict;

    return `
        <div class="conflict-item" data-item-id="${itemId}" data-conflict-index="${index}">
            <div class="conflict-item-header">
                <span class="conflict-item-id">${itemId}</span>
                <span class="conflict-item-type">${type.toUpperCase()}</span>
            </div>
            <div class="conflict-comparison">
                <div class="conflict-version local-version">
                    <h3>LOCAL VERSION</h3>
                    <div class="version-field">
                        <label>Title:</label>
                        <div class="field-value">${escapeHtml(localVersion.title || '')}</div>
                    </div>
                    <div class="version-field">
                        <label>Due Date:</label>
                        <!-- XACA-1005-001 (6th round, PR #795 gate): formatDate()'s
                             CATCH-AND-RETURN-RAW pattern (its parseLocalDate() call
                             throws for ANY non-string dueDate -- .split('-') is
                             string-only -- and the catch returns the offending
                             value VERBATIM, unstringified) makes this an ELEMENT-
                             CONTENT injection sink, not merely a "malformed date
                             string" edge case: a dueDate of ["<img src=x
                             onerror=alert(1)>"] (array) or an object with a
                             hostile toString() reaches the template literal's
                             implicit ToString and renders as a live element.
                             XACA-1020 established handle_update_item applies
                             client JSON fields with no type validation, so a
                             non-string dueDate is directly reachable -- this is
                             NOT narrowed to malformed date STRINGS the way
                             "Invalid Date" is (a string always launders safely;
                             .split() never throws on one). Fixed:
                             escapeHtml(String(formatDate(x) ?? 'None')) --
                             String() first so a raw array/object is stringified
                             (invoking its toString(), which is exactly the value
                             that must be escaped) BEFORE escapeHtml() runs, and
                             ?? (not the original ||) preserves the exact
                             legitimate-input behavior: formatDate() only ever
                             returns null for a genuinely absent/falsy dueDate
                             (never 0/false/NaN/''), so ?? and || are equivalent
                             for every real return value -- verified against the
                             real function bodies, not assumed, both here and in
                             the regression suite below. Do NOT "fix" formatDate()
                             itself: its catch behavior is shared by every caller,
                             and formatDate has an exact ONE call site outside
                             this function (verified by grep) -- see the CHANGELOG
                             entry for the full site-by-site accounting. -->
                        <div class="field-value">${escapeHtml(String(formatDate(localVersion.dueDate) ?? 'None'))}</div>
                    </div>
                    <div class="version-field">
                        <label>Modified:</label>
                        <div class="field-value">${formatTimestamp(localVersion.modifiedAt)}</div>
                    </div>
                </div>
                <div class="conflict-version external-version">
                    <h3>CALENDAR VERSION</h3>
                    <div class="version-field">
                        <label>Title:</label>
                        <div class="field-value">${escapeHtml(externalVersion.title || '')}</div>
                    </div>
                    <div class="version-field">
                        <label>Due Date:</label>
                        <div class="field-value">${escapeHtml(String(formatDate(externalVersion.dueDate) ?? 'None'))}</div>
                    </div>
                    <div class="version-field">
                        <label>Modified:</label>
                        <div class="field-value">${formatTimestamp(externalVersion.modifiedAt)}</div>
                    </div>
                </div>
            </div>
            <div class="conflict-actions">
                <button class="conflict-btn keep-local" onclick="resolveConflict('${itemId}', 'keep_local')">
                    Keep Local
                </button>
                <button class="conflict-btn keep-external" onclick="resolveConflict('${itemId}', 'keep_external')">
                    Keep Calendar
                </button>
                <button class="conflict-btn merge" onclick="showMergeDialog('${itemId}', ${index})">
                    Manual Merge
                </button>
            </div>
        </div>
    `;
}

/**
 * Resolve a calendar sync conflict
 */
async function resolveConflict(itemId, resolution, mergeData = null) {
    try {
        const response = await apiFetch(apiUrl('/api/calendar/conflicts/resolve'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                team: CONFIG.team,
                itemId,
                resolution,
                mergeData
            })
        });

        const data = await response.json();

        if (data.success) {
            // Remove resolved conflict from modal
            const conflictItem = document.querySelector(`.conflict-item[data-item-id="${itemId}"]`);
            if (conflictItem) {
                conflictItem.style.opacity = '0.3';
                conflictItem.innerHTML = '<div class="conflict-resolved">✓ RESOLVED</div>';
                setTimeout(() => {
                    conflictItem.remove();
                    // Close modal if no more conflicts
                    const remainingConflicts = document.querySelectorAll('.conflict-item:not(:has(.conflict-resolved))');
                    if (remainingConflicts.length === 0) {
                        closeConflictModal();
                        refreshData(); // Reload board to show updated data
                    }
                }, 1000);
            }
        } else {
            alert('Error resolving conflict: ' + data.error);
        }
    } catch (error) {
        console.error('Error resolving conflict:', error);
        alert('Failed to resolve conflict. Please try again.');
    }
}

/**
 * Show manual merge dialog for a conflict
 */
function showMergeDialog(itemId, conflictIndex) {
    const conflictItem = document.querySelector(`.conflict-item[data-item-id="${itemId}"]`);
    if (!conflictItem) return;

    const localTitle = conflictItem.querySelector('.local-version .field-value:nth-of-type(1)').textContent;
    const localDueDate = conflictItem.querySelector('.local-version .field-value:nth-of-type(2)').textContent;
    const externalTitle = conflictItem.querySelector('.external-version .field-value:nth-of-type(1)').textContent;
    const externalDueDate = conflictItem.querySelector('.external-version .field-value:nth-of-type(2)').textContent;

    // XACA-1005-001 (folded-in scope expansion): localTitle/externalTitle are
    // read back via .textContent from renderConflictItem()'s already-rendered
    // markup (~line 8101/8116 above), which the browser DECODES on the way
    // out — so by the time these locals exist they are plain text again, not
    // pre-escaped for whatever sink they land in below. `conflict.localVersion`
    // is this client's own kanban item data; `conflict.externalVersion` comes
    // from GET /api/calendar/conflicts, i.e. the external calendar sync feed
    // — outside this app's trust boundary. Both get identical treatment below
    // because the SINK, not the source's trust level, determines the escaper,
    // and either field reaching either sink unescaped is exploitable.
    //
    // SIX sinks below, two escapers, verified against the actual escaper
    // bodies (escapeAttr ~line 11504, jsAttrEscape ~line 11558). (Corrected
    // 4th-round PR-gate finding, XACA-1005-021: this comment previously said
    // "three sinks", counting only the Title row -- it undercounted the
    // identically-shaped Due Date row below, which has the SAME three
    // interpolation positions for localDueDate/externalDueDate.)
    //   - `value="${...}"` (the two <input> elements below, Title and Due
    //     Date) is a plain QUOTED ATTRIBUTE -> escapeAttr. jsAttrEscape would
    //     be wrong there: it additionally escapes ' as \', so an apostrophe
    //     in a real title would render as a literal backslash-quote in the
    //     input's value instead of the apostrophe the user typed.
    //   - All four suggestion buttons' onclick (two Title, two Due Date)
    //     assign into a JS STRING LITERAL embedded in an HTML attribute
    //     (`...value = '${...}'`) -> jsAttrEscape, which escapes \ and ' in
    //     addition to the HTML metacharacters escapeHtml/escapeAttr cover.
    //     A title of `'); alert(1); //` closes the string literal and
    //     executes arbitrary JS with escapeHtml (which leaves ' untouched)
    //     — the same class of bug as the epic-selector fix above, and worse
    //     than a plain attribute breakout.
    //
    // localDueDate/externalDueDate REACHABILITY (XACA-1005-021): normally
    // laundered safe by formatDate() (lcars.js ~11853), whose only two
    // outcomes for a STRING dueDate are a formatted date ("Jan 1, 2026") or
    // the fixed literal "Invalid Date" -- neither is attacker-shaped.
    // formatDate() has a narrower path that is NOT laundered: its try/catch
    // returns the RAW, UNPARSED dateString verbatim if parseLocalDate()
    // throws, which only happens for a NON-STRING truthy value (a string's
    // .split('-') never throws, whatever its content). XACA-1020 established
    // handle_update_item applies client fields with no type validation at
    // all, so a dueDate of a non-string type is reachable in principle. That
    // said, THIS FUNCTION reads localDueDate/externalDueDate via .textContent
    // from renderConflictItem()'s already-rendered DOM -- the same mechanism
    // already established safe for localTitle/externalTitle above, since any
    // real element a raw tag produced there would have already become part
    // of the DOM tree, and .textContent on that subtree returns only text,
    // not tag markup. So these two sinks in showMergeDialog() are fixed here
    // for the same defense-in-depth reason as SITES 3/4/5 (the sink, not the
    // source's trust level, decides the escaper) -- not because a live
    // exploit was demonstrated reaching THIS function specifically.
    //
    // A DIFFERENT, EARLIER sink was found while tracing this: renderConflictItem()
    // (~8105/8120) interpolates `${formatDate(localVersion.dueDate) || 'None'}`
    // as ELEMENT CONTENT with NO escaper at all (unlike the adjacent Title
    // field on the same lines, which uses escapeHtml()) -- if formatDate()'s
    // catch-fallback ever returns attacker-shaped text (per the non-string
    // dueDate path above), THAT is where it would actually execute, before
    // showMergeDialog() is ever invoked. NOT fixed here: it is a different
    // function than the one named in this round's findings, and its
    // reachability has the SAME XACA-1020 mass-assignment gap as its
    // precondition -- reported to the coordinator, not touched.
    const mergeDialog = document.createElement('div');
    mergeDialog.className = 'merge-dialog';
    mergeDialog.innerHTML = `
        <h3>Manual Merge: ${itemId}</h3>
        <div class="merge-field">
            <label>Title:</label>
            <input type="text" id="merge-title" value="${escapeAttr(localTitle)}" />
            <div class="merge-suggestions">
                <button class="suggestion-btn" onclick="document.getElementById('merge-title').value = '${jsAttrEscape(localTitle)}'">Local</button>
                <button class="suggestion-btn" onclick="document.getElementById('merge-title').value = '${jsAttrEscape(externalTitle)}'">Calendar</button>
            </div>
        </div>
        <div class="merge-field">
            <label>Due Date:</label>
            <input type="date" id="merge-duedate" value="${escapeAttr(localDueDate !== 'None' ? localDueDate : '')}" />
            <div class="merge-suggestions">
                <button class="suggestion-btn" onclick="document.getElementById('merge-duedate').value = '${jsAttrEscape(localDueDate !== 'None' ? localDueDate : '')}'">Local</button>
                <button class="suggestion-btn" onclick="document.getElementById('merge-duedate').value = '${jsAttrEscape(externalDueDate !== 'None' ? externalDueDate : '')}'">Calendar</button>
            </div>
        </div>
        <div class="merge-actions">
            <button class="merge-btn save" onclick="saveMerge('${itemId}')">Save Merged Version</button>
            <button class="merge-btn cancel" onclick="closeMergeDialog()">Cancel</button>
        </div>
    `;

    conflictItem.querySelector('.conflict-actions').appendChild(mergeDialog);
}

/**
 * Save manually merged conflict data
 */
async function saveMerge(itemId) {
    const titleInput = document.getElementById('merge-title');
    const dueDateInput = document.getElementById('merge-duedate');

    const mergeData = {
        title: titleInput.value,
        dueDate: dueDateInput.value || null
    };

    closeMergeDialog();
    await resolveConflict(itemId, 'merge', mergeData);
}

/**
 * Close merge dialog
 */
function closeMergeDialog() {
    const dialog = document.querySelector('.merge-dialog');
    if (dialog) dialog.remove();
}

/**
 * Close conflict resolution modal
 */
function closeConflictModal() {
    const modal = document.querySelector('.conflict-modal');
    if (modal) {
        modal.classList.remove('active');
        setTimeout(() => modal.remove(), 300);
    }
}

/**
 * Render calendar controls (view toggle, navigation, date range display)
 */
function renderCalendarControls() {
    const controlsContainer = document.getElementById('calendar-controls');
    if (!controlsContainer) return;

    const dateRange = getDateRangeDisplay();

    // Build external events toggle HTML (only if integration enabled)
    const externalToggleHTML = calendarState.hasCalendarIntegration ? `
        <label class="calendar-external-toggle">
            <input type="checkbox" id="calendar-external-toggle" ${calendarState.showExternalEvents ? 'checked' : ''}>
            <span>Show External Events</span>
        </label>
    ` : '';

    // Build epic filter dropdown HTML
    const epicFilterHTML = `
        <div class="calendar-epic-filter-dropdown" id="calendar-epic-filter-dropdown">
            <span class="calendar-epic-filter-label">EPIC:</span>
            <select id="calendar-epic-filter-select" class="calendar-epic-filter-select">
                <option value="all">ALL</option>
                <option value="assigned">ASSIGNED</option>
                <option value="unassigned">UNASSIGNED</option>
            </select>
        </div>
    `;

    // Build sync status HTML (XACA-0039-010)
    const syncStatusHTML = calendarState.hasCalendarIntegration ? `
        <div class="calendar-sync-status">
            <div id="calendar-sync-badge" class="calendar-sync-badge"></div>
            <div id="calendar-sync-timestamp" class="calendar-sync-timestamp"></div>
            <div id="calendar-sync-error" class="calendar-sync-error"></div>
            <button class="calendar-btn calendar-sync-btn" id="calendar-manual-sync" title="Sync now">
                <span class="sync-icon">↻</span> SYNC
            </button>
        </div>
    ` : '';

    controlsContainer.innerHTML = `
        <div class="calendar-header">
            <div class="calendar-nav">
                <button class="calendar-btn" id="calendar-today">TODAY</button>
                <button class="calendar-btn" id="calendar-prev">◀</button>
                <div class="calendar-date-range">${dateRange}</div>
                <button class="calendar-btn" id="calendar-next">▶</button>
            </div>
            <div class="calendar-view-toggle">
                <button class="calendar-view-btn ${calendarState.viewMode === 'week' ? 'active' : ''}" data-view="week">WEEK</button>
                <button class="calendar-view-btn ${calendarState.viewMode === 'month' ? 'active' : ''}" data-view="month">MONTH</button>
            </div>
            ${syncStatusHTML}
            ${externalToggleHTML}
            ${epicFilterHTML}
            <button class="calendar-settings-btn" id="calendar-settings-btn" title="Calendar Settings">⚙ SETTINGS</button>
        </div>
    `;

    // Wire up event listeners
    document.getElementById('calendar-today')?.addEventListener('click', () => {
        calendarState.currentDate = new Date();
        renderCalendar();
    });

    document.getElementById('calendar-prev')?.addEventListener('click', () => {
        navigateCalendar(-1);
    });

    document.getElementById('calendar-next')?.addEventListener('click', () => {
        navigateCalendar(1);
    });

    document.querySelectorAll('.calendar-view-btn').forEach(btn => {
        btn.addEventListener('click', (e) => {
            const view = e.target.dataset.view;
            setCalendarView(view);
        });
    });

    // External events toggle (only exists if integration enabled)
    document.getElementById('calendar-external-toggle')?.addEventListener('change', () => {
        toggleExternalEvents();
    });

    // Manual sync button (XACA-0039-010)
    document.getElementById('calendar-manual-sync')?.addEventListener('click', () => {
        manualSyncCalendar();
    });

    // Epic filter dropdown
    const epicSelect = document.getElementById('calendar-epic-filter-select');
    if (epicSelect) {
        // Set initial value from saved state
        epicSelect.value = calendarState.epicFilter || 'all';
        updateCalendarEpicDropdownStyle();

        epicSelect.addEventListener('change', (e) => {
            calendarState.epicFilter = e.target.value;
            localStorage.setItem(CALENDAR_EPIC_FILTER_KEY, e.target.value);
            updateCalendarEpicDropdownStyle();
            renderCalendarGrid(); // Re-render grid to apply filter
        });

        // Populate epic options from cached data
        populateCalendarEpicFilterOptions();
    }

    // Settings button listener
    document.getElementById('calendar-settings-btn')?.addEventListener('click', () => {
        openCalendarSettingsModal();
    });

    // Initialize sync status indicator (XACA-0039-010)
    updateSyncStatusIndicator();
}

/**
 * Get display string for current date range
 */
function getDateRangeDisplay() {
    const { viewMode, currentDate } = calendarState;

    if (viewMode === 'week') {
        const weekStart = getWeekStart(currentDate);
        const weekEnd = new Date(weekStart);
        weekEnd.setDate(weekEnd.getDate() + 6);

        const monthStart = weekStart.toLocaleDateString('en-US', { month: 'long' });
        const monthEnd = weekEnd.toLocaleDateString('en-US', { month: 'long' });
        const year = weekStart.getFullYear();

        if (monthStart === monthEnd) {
            return `${monthStart} ${weekStart.getDate()}-${weekEnd.getDate()}, ${year}`;
        } else {
            return `${monthStart} ${weekStart.getDate()} - ${monthEnd} ${weekEnd.getDate()}, ${year}`;
        }
    } else {
        return currentDate.toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
    }
}

/**
 * Get the start of the week (Sunday) for a given date
 */
function getWeekStart(date) {
    const d = new Date(date);
    const day = d.getDay();
    const diff = d.getDate() - day;
    return new Date(d.setDate(diff));
}

/**
 * Navigate calendar forward or backward
 */
function navigateCalendar(direction) {
    const { viewMode, currentDate } = calendarState;
    const newDate = new Date(currentDate);

    if (viewMode === 'week') {
        newDate.setDate(newDate.getDate() + (direction * 7));
    } else {
        newDate.setMonth(newDate.getMonth() + direction);
    }

    calendarState.currentDate = newDate;
    renderCalendar();
}

/**
 * Set calendar view mode and persist to localStorage
 */
function setCalendarView(viewMode) {
    if (viewMode !== 'week' && viewMode !== 'month') return;

    calendarState.viewMode = viewMode;
    localStorage.setItem(CALENDAR_VIEW_KEY, viewMode);
    renderCalendar();
}

/**
 * Render the calendar grid based on current view mode
 */
function renderCalendarGrid() {
    const gridContainer = document.getElementById('calendar-grid');
    if (!gridContainer) return;

    const { viewMode } = calendarState;

    if (viewMode === 'week') {
        renderWeekView(gridContainer);
    } else {
        renderMonthView(gridContainer);
    }
}

/**
 * Render week view (7 columns, single row of days)
 */
function renderWeekView(container) {
    const weekStart = getWeekStart(calendarState.currentDate);
    const today = new Date();
    today.setHours(0, 0, 0, 0);

    const daysOfWeek = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];

    let html = '<div class="calendar-grid week-view">';

    // Day headers
    html += '<div class="calendar-row calendar-header-row">';
    daysOfWeek.forEach(day => {
        html += `<div class="calendar-day-header">${day}</div>`;
    });
    html += '</div>';

    // Day cells
    html += '<div class="calendar-row">';
    for (let i = 0; i < 7; i++) {
        const date = new Date(weekStart);
        date.setDate(date.getDate() + i);

        const isToday = date.getTime() === today.getTime();
        const dayClass = isToday ? 'calendar-day today' : 'calendar-day';

        html += `<div class="${dayClass}" data-date="${date.toISOString().split('T')[0]}">`;
        html += `<div class="calendar-day-number">${date.getDate()}</div>`;
        html += renderDayItems(date);
        html += '</div>';
    }
    html += '</div>';
    html += '</div>';

    container.innerHTML = html;
}

/**
 * Render month view (7 columns, 5-6 rows)
 */
function renderMonthView(container) {
    const { currentDate } = calendarState;
    const year = currentDate.getFullYear();
    const month = currentDate.getMonth();

    const firstDay = new Date(year, month, 1);
    const lastDay = new Date(year, month + 1, 0);
    const startDay = firstDay.getDay(); // 0 = Sunday
    const daysInMonth = lastDay.getDate();

    const today = new Date();
    today.setHours(0, 0, 0, 0);

    const daysOfWeek = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];

    let html = '<div class="calendar-grid month-view">';

    // Day headers
    html += '<div class="calendar-row calendar-header-row">';
    daysOfWeek.forEach(day => {
        html += `<div class="calendar-day-header">${day}</div>`;
    });
    html += '</div>';

    // Calculate grid
    let dayCounter = 1;
    const totalCells = Math.ceil((startDay + daysInMonth) / 7) * 7;

    for (let i = 0; i < totalCells; i++) {
        if (i % 7 === 0) {
            html += '<div class="calendar-row">';
        }

        if (i < startDay || dayCounter > daysInMonth) {
            // Empty cell or previous/next month
            html += '<div class="calendar-day other-month"></div>';
        } else {
            const date = new Date(year, month, dayCounter);
            const isToday = date.getTime() === today.getTime();
            const dayClass = isToday ? 'calendar-day today' : 'calendar-day';

            html += `<div class="${dayClass}" data-date="${date.toISOString().split('T')[0]}">`;
            html += `<div class="calendar-day-number">${dayCounter}</div>`;
            html += renderDayItems(date);
            html += '</div>';

            dayCounter++;
        }

        if (i % 7 === 6) {
            html += '</div>';
        }
    }

    html += '</div>';
    container.innerHTML = html;
}

/**
 * Render items for a specific day (epics, kanban items, and external events)
 * Now uses cached calendar data from API instead of filtering boardData
 */
function renderDayItems(date) {
    const dateStr = date.toISOString().split('T')[0];
    const items = [];

    // Get current epic filter
    const epicFilter = calendarState.epicFilter || 'all';

    // Get epics from cached calendar data
    if (calendarState.cachedEpics) {
        calendarState.cachedEpics.forEach(epic => {
            if (epic.dueDate === dateStr) {
                // Apply epic filter (only show this epic if filter matches)
                if (epicFilter !== 'all' && epicFilter !== epic.id) {
                    return; // Skip epics that don't match filter
                }

                items.push({
                    type: 'epic',
                    id: epic.id,
                    title: epic.title,
                    priority: epic.priority,
                    status: epic.status,
                    itemCount: epic.itemCount || 0,
                    completedCount: epic.completedCount || 0,
                    isExternal: false
                });
            }
        });
    }

    // Get kanban items from cached calendar data
    if (calendarState.cachedItems) {
        calendarState.cachedItems.forEach(item => {
            if (item.dueDate === dateStr && item.status !== 'completed') {
                // Apply epic filter
                if (epicFilter !== 'all') {
                    const hasEpic = item.epicId;
                    if (epicFilter === 'assigned') {
                        if (!hasEpic) return; // Skip unassigned items
                    } else if (epicFilter === 'unassigned') {
                        if (hasEpic) return; // Skip assigned items
                    } else {
                        // Specific epic ID
                        if (!hasEpic || item.epicId !== epicFilter) return; // Skip non-matching items
                    }
                }

                items.push({
                    type: 'item',
                    id: item.id,
                    title: item.title,
                    priority: item.priority,
                    status: item.status,
                    epicId: item.epicId,
                    epicName: item.epicName,
                    subitemCount: item.subitemCount || 0,
                    isExternal: false
                });
            }
        });
    }

    // Add external events if enabled and available
    if (calendarState.showExternalEvents && calendarState.externalEvents.length > 0) {
        calendarState.externalEvents.forEach(event => {
            // Check if event occurs on this date
            const eventDate = new Date(event.start || event.date);
            const eventDateStr = eventDate.toISOString().split('T')[0];

            if (eventDateStr === dateStr) {
                items.push({
                    type: 'external',
                    title: event.title || event.summary || 'Untitled Event',
                    source: event.source || 'External',  // e.g., "Google", "Outlook"
                    isExternal: true
                });
            }
        });
    }

    if (items.length === 0) return '';

    // Show max 3 items, then "+N more" indicator
    const MAX_VISIBLE = 3;
    const visibleItems = items.slice(0, MAX_VISIBLE);
    const overflow = items.length - MAX_VISIBLE;

    let html = '<div class="calendar-day-items">';

    visibleItems.forEach(item => {
        if (item.isExternal) {
            // External events - read-only with sync icon (XACA-0039-010)
            const sourceLabel = item.source ? ` (${item.source})` : '';
            // XACA-1005-001 (3rd folded-in scope expansion, FINDING B): both
            // item.title and item.source were interpolated RAW into quoted
            // title="..." attributes below -- no escaper at all. item.source
            // comes from the external calendar feed (outside this app's
            // trust boundary, same provenance as externalTitle in SITES
            // 3/4); item.title here is the external event's own title, same
            // untrusted-feed provenance. Fixed: escapeAttr() at each
            // interpolation site. sourceLabel is escaped as a whole at its
            // one usage (verified single-consumer via grep) rather than at
            // its `const sourceLabel = ...` construction two lines up --
            // escapeAttr() only touches &/</>/"/', so the surrounding
            // " (" / ")" literal parens pass through unaffected.
            //
            // 4th-round PR-gate fix (blocking reviewer finding): the
            // ${truncateTitle(item.title, 25)} below was left RAW as ELEMENT
            // CONTENT -- the same FINDING-A defect class, in the same
            // branch this round already hardened for forward-safety, so
            // leaving the worst sink in it unescaped was incoherent. This
            // sibling is dead code today for the SAME reason FINDING B is
            // (the branch is unreachable -- see the note above the div),
            // fixed for the same forward-safety reason.
            //
            // COMPOSITION ORDER IS LOAD-BEARING: escapeHtml(truncateTitle(x,
            // n)), NEVER truncateTitle(escapeHtml(x), n). Truncating AFTER
            // escaping can cut an entity in half (e.g. "&lt" with the ";"
            // sliced off), and HTML5's legacy no-semicolon character-
            // reference table decodes a severed "&lt" back to a raw "<" on
            // the next parse -- a truncation step that MANUFACTURES the
            // injection it was meant to prevent. Escaping after truncation
            // only ever produces MORE entity text, never less, so it cannot
            // create this failure mode.
            //
            // String(item.title ?? '') guards truncateTitle()'s unguarded
            // `title.length` (throws on null/undefined -- item.title here is
            // always a string per the item-building code above, but this
            // matches the identical guard added at the epic-branch sibling
            // and keeps the two call sites textually parallel) and ALSO
            // fixes escapeHtml's falsy-vs-escapeAttr's-nullish guard mismatch
            // for the numeric-0-title case (see the row2 fix below for the
            // full explanation) -- one change serves both purposes here.
            html += `<div class="calendar-item external-event" title="${escapeAttr(item.title)}${escapeAttr(sourceLabel)}">
                <span class="event-sync-badge" title="Synced from ${escapeAttr(item.source || 'external calendar')}">↻</span>
                ${escapeHtml(truncateTitle(String(item.title ?? ''), 25))}
            </div>`;
        } else if (item.type === 'epic') {
            // Epic items - distinct gold/amber styling with urgency
            const progress = item.itemCount > 0 ? `${item.completedCount}/${item.itemCount}` : '';
            const titleText = progress ? `${item.title} (${progress})` : item.title;
            // XACA-0050: Use shortTitle for display if available
            const displayTitle = item.shortTitle || item.title;

            // Add urgency class based on due date
            const dueDateStatus = getDueDateStatus(dateStr);
            const urgencyClass = getUrgencyClass(dueDateStatus);
            // XACA-1005-001 (2nd folded-in scope expansion, SITE 6): titleText
            // (built two lines above from item.title, user-supplied epic
            // title) was interpolated RAW into the QUOTED title="..." attribute
            // below -- no escaper at all, not merely the wrong one. Verified
            // titleText has exactly ONE consumer in this branch (this
            // attribute) via grep before choosing where to escape, so wrapping
            // it at the interpolation site (rather than reassigning it at its
            // `const titleText = ...` construction two lines up) cannot
            // double-escape a second use. escapeAttr() is correct: a plain
            // quoted HTML attribute, not a JS string literal.
            //
            // urgencyClass and item.id, interpolated in the SAME line, were
            // independently evaluated and left alone:
            //   - urgencyClass comes from getUrgencyClass(getDueDateStatus(...))
            //     above, which returns one of a small fixed set of literal
            //     strings ('urgency-future'/'urgency-overdue'/'urgency-imminent'/
            //     'urgency-soon') -- no external input reaches
            //     it, so escaping it would be purely defensive noise.
            //   - item.id is produced by kanban-helpers.sh's _kb_generate_id()
            //     as `PREFIX-NNNN` (team/series code + zero-padded counter) on
            //     the normal item-creation path, a constrained charset that
            //     cannot contain a quote. NOTE (reported, not fixed here --
            //     out of scope for this ticket): server.py's handle_update_item
            //     applies `updates.items()` as a fully generic field setter
            //     with no per-field allowlist or validation, so a client could
            //     in principle overwrite an item's `id` field to an arbitrary
            //     string via that endpoint, bypassing the generator entirely.
            //     That is a mass-assignment gap in a different class from the
            //     escaper-choice defects this ticket fixes, and would affect
            //     every sink that renders item.id, not just this one -- flagged
            //     for the coordinator/audit rather than fixed here.
            // 4th-round PR-gate fix (BLOCKING, reviewer-verified): the
            // ${truncateTitle(displayTitle, 20)} below is the exact
            // FINDING-A defect class -- displayTitle = item.shortTitle ||
            // item.title, and the epic-items push above (this same
            // function) sets only `title`, never `shortTitle`, so
            // displayTitle is always item.title here: raw, unescaped
            // ELEMENT CONTENT, one line below the title="..." attribute this
            // ticket already escaped on the SAME field. The 20-char cap is
            // not mitigation -- `<svg onload=alert()>` is 20 characters, and
            // truncateTitle() returns a string that short completely
            // untouched. Fixed: escapeHtml(truncateTitle(...)).
            //
            // COMPOSITION ORDER IS LOAD-BEARING: escapeHtml(truncateTitle(x,
            // n)), NEVER truncateTitle(escapeHtml(x), n). Truncating AFTER
            // escaping can cut an entity in half (e.g. "&lt" with its ";"
            // sliced off), and HTML5's legacy no-semicolon character-
            // reference table decodes a severed "&lt" back to a raw "<" on
            // the next parse -- a truncation step that MANUFACTURES the
            // injection it was meant to prevent. escapeHtml(truncateTitle())
            // only ever produces MORE entity text from an already-cut plain
            // string, never a cut entity, so it cannot create this failure
            // mode. See tests/... for a payload engineered so the cut lands
            // mid-entity, proving the ORDER, not just the presence, of the
            // escaper matters.
            //
            // String(displayTitle ?? '') guards truncateTitle()'s unguarded
            // `title.length` (throws on null/undefined; displayTitle can in
            // principle be null/undefined if a future change adds an epic
            // push without a `title` field, though today's push above always
            // sets one) and ALSO fixes a real behaviour regression this
            // ticket's row2 fix (below, kanban-item branch) introduced:
            // escapeHtml()'s guard is `if (!text) return ''` (FALSY), while
            // escapeAttr()'s is `value === null || value === undefined`
            // (NULLISH) -- so a numeric title of `0` renders as EMPTY via a
            // bare escapeHtml(x) but as "0" via escapeAttr(x), a visible
            // mismatch between two renderings of the SAME field on the same
            // card. XACA-1020 established that handle_update_item applies
            // client fields with no type/enum validation, so a numeric title
            // is reachable, however unlikely. Fixed at THIS call site, not
            // by changing escapeHtml()'s shared guard (which would alter
            // rendering at every escapeHtml() call across this 21,000-line
            // file for a defect that only exists at these three sites).
            html += `<div class="calendar-item epic-item ${urgencyClass}" data-epic-id="${item.id}" title="Epic: ${escapeAttr(titleText)} (click to navigate)">
                <span class="epic-badge">E</span> ${escapeHtml(truncateTitle(String(displayTitle ?? ''), 20))}
                ${progress ? `<span class="epic-progress">${progress}</span>` : ''}
            </div>`;
        } else {
            // Kanban items - show ID, priority, epic badge, subitem count with urgency
            const priorityClass = item.priority ? item.priority.toLowerCase() : 'medium';
            // XACA-1005-001 (3rd folded-in scope expansion, FINDING C): this
            // whole fallback chain was interpolated RAW into a quoted
            // title="..." attribute -- no escaper at all. The FIRST branch,
            // getEpicTitleById(item.epicId), resolves an epic TITLE --
            // user-supplied free text, same provenance as SITE 2's
            // epic.title (server.py's epic-creation handler assigns the POST
            // body's `name` straight through with no sanitization). Not a
            // system id, despite the local being named "Badge". Fixed:
            // escapeAttr() wraps the WHOLE ternary chain at this single
            // interpolation site -- item.epicName/item.epicId, the fallback
            // branches, pass through escapeAttr() unchanged when they hold
            // an ordinary id/name with no HTML metacharacters, so wrapping
            // the whole expression does not conflict with XACA-1013's
            // separate, already-ticketed judgment that item.id/epic.id are
            // safe on their normal creation path -- this is a DIFFERENT
            // interpolation site than the item.id/epic.id occurrences left
            // bare elsewhere in this function for XACA-1013.
            const epicBadge = item.epicId ? `<span class="epic-badge" title="Part of epic: ${escapeAttr(getEpicTitleById(item.epicId) || item.epicName || item.epicId)}">E</span>` : '';
            const subitemBadge = item.subitemCount > 0 ? `<span class="subitem-badge" title="${item.subitemCount} subitems with due dates">${item.subitemCount}</span>` : '';

            // Add urgency class based on due date
            const dueDateStatus = getDueDateStatus(dateStr);
            const urgencyClass = getUrgencyClass(dueDateStatus);

            // XACA-1005-001 (2nd folded-in scope expansion, SITE 7): item.title
            // was interpolated RAW into the QUOTED title="..." attribute below
            // -- same defect as SITE 6, same fix: escapeAttr(), a plain quoted
            // attribute, not a JS string literal.
            //
            // priorityClass, interpolated in the SAME line's class="..."
            // attribute, was independently evaluated (per the "do not
            // reflexively escape" note) and judged GENUINELY UNSAFE, unlike
            // urgencyClass/item.id below: `item.priority` reaches this render
            // via server.py's handle_update_item, which applies
            // `updates.items()` as a fully generic field setter with NO
            // enum/format validation on `priority` (the enum check at
            // TODO_PRIORITY_ORDER gates a DIFFERENT resource -- todos, not
            // backlog items). So a priority value of e.g. `x" onmouseover=
            // alert(1) y="` reaches `.toLowerCase()` untouched and breaks out
            // of this class="..." attribute exactly like SITE 1's crTitle did.
            // Fixed: escapeAttr(priorityClass) at the interpolation site --
            // verified it has exactly one consumer in this branch (this
            // attribute), so wrapping here cannot double-escape a second use.
            //
            // urgencyClass and item.id are unescaped for the same reasons
            // given at SITE 6 above (urgencyClass: fixed literal set, no
            // external input; item.id: constrained-charset generator on the
            // normal path, with the same out-of-scope mass-assignment caveat
            // reported there, not fixed here).
            //
            // XACA-1005-001 (3rd folded-in scope expansion, FINDING A --
            // HIGHEST SEVERITY of the three folded in this round): the
            // row2 div below interpolated item.title RAW as ELEMENT CONTENT,
            // with no escaper at all. Unlike SITES 1/6/7's attribute
            // breakouts, this is not an attribute-context injection -- it is
            // a full HTML-injection sink: a title containing an <img> tag
            // with an onerror handler renders as a live element and
            // executes, no attribute boundary needs breaking at all. Fixed:
            // escapeHtml(item.title). escapeAttr() would ALSO be safe here
            // (a strict superset in element content -- see SITE 1's
            // reasoning above), but escapeHtml() is the conventional choice
            // for a plain element-content sink and is what the rest of this
            // file uses for this shape (e.g. crIdEsc near the top of this
            // file). This same item.title also appears in the title="..."
            // attribute a few lines up (escaped there with escapeAttr()) --
            // two SEPARATE call sites on the SAME raw field, each escaping
            // independently for its own context, not one escaped value
            // reused across both (which would risk double-escaping).
            //
            // 4th-round PR-gate fix (BLOCKING [UX] regression, XACA-1005-020
            // -- introduced by the escapeHtml() fix above, caught by review):
            // escapeHtml()'s guard is `if (!text) return ''` (FALSY), while
            // escapeAttr()'s guard is `value === null || value === undefined`
            // (NULLISH). So for a numeric item.title of `0`, the bare
            // escapeHtml(item.title) below rendered EMPTY while the
            // escapeAttr(item.title) in the title="..." attribute a few
            // lines up rendered "0" -- two DIFFERENT renderings of the SAME
            // field on the SAME card, and a behaviour change from the
            // pre-fix code (which was raw and rendered `0` correctly, by
            // accident, alongside the actual XSS hole). XACA-1020
            // established handle_update_item applies client fields with no
            // type/enum validation at all, so a numeric title is reachable,
            // however unlikely. Fixed HERE, at the call site, with
            // String(item.title ?? '') -- matching escapeAttr()'s nullish
            // semantics locally so the two renderings of one field can never
            // disagree again. Deliberately NOT fixed by changing
            // escapeHtml()'s shared guard from falsy to nullish: that
            // function is called throughout this 21,000-line file, and
            // widening its blast radius for a defect that only exists at
            // these three call sites (this one, and the two truncateTitle()
            // sites in the same function) is exactly the kind of
            // "while I'm here" cleanup a security fix should not carry.
            //
            // NOTE: HTML comments (<!-- ... -->), not JS ones, are the only
            // safe way to annotate INSIDE this template literal below --
            // `//`/`/* */` are not comments in a template literal, they are
            // literal output text, and a naive `{/* ... */}` (JSX habit) is
            // actively wrong here: it both renders as visible junk in the
            // markup AND its own backtick-delimited code span would open a
            // nested template-literal expression, a syntax error this exact
            // mistake was caught and reverted while authoring this fix.
            html += `<div class="calendar-item priority-${escapeAttr(priorityClass)} ${urgencyClass}" data-item-id="${item.id}" title="${item.id}: ${escapeAttr(item.title)} (click to navigate)">
                <div class="calendar-item-row1"><span class="item-id">${item.id}</span>${epicBadge}${subitemBadge}</div>
                <div class="calendar-item-row2">${escapeHtml(String(item.title ?? ''))}</div>
            </div>`;
        }
    });

    if (overflow > 0) {
        html += `<div class="calendar-item-overflow" title="${overflow} more items">+${overflow} more</div>`;
    }

    html += '</div>';

    return html;
}

/**
 * Truncate title to max length with ellipsis
 */
function truncateTitle(title, maxLength) {
    if (title.length <= maxLength) return title;
    return title.substring(0, maxLength - 1) + '…';
}

/**
 * Navigate to a calendar item or epic and highlight it
 */
function navigateToCalendarItem(itemId, epicId) {
    if (epicId) {
        // Navigate to EPICS section
        switchSection('epics');
        
        // Wait for section to render, then scroll to and highlight the epic
        setTimeout(() => {
            const epicCard = document.querySelector(`.epic-card[data-epic-id="${epicId}"]`);
            if (epicCard) {
                epicCard.scrollIntoView({ behavior: 'smooth', block: 'center' });
                epicCard.classList.add('highlight-pulse');
                setTimeout(() => epicCard.classList.remove('highlight-pulse'), 2000);
            }
        }, 300);
    } else if (itemId) {
        // Navigate to BACKLOG section
        switchSection('backlog');
        
        // Wait for section to render, then scroll to and highlight the item
        setTimeout(() => {
            const backlogItem = document.querySelector(`.backlog-item[data-item-id="${itemId}"]`);
            if (backlogItem) {
                backlogItem.scrollIntoView({ behavior: 'smooth', block: 'center' });
                backlogItem.classList.add('highlight-pulse');
                setTimeout(() => backlogItem.classList.remove('highlight-pulse'), 2000);
            }
        }, 300);
    }
}

/**
 * Main calendar rendering function
 */
async function renderCalendar() {
    // Load calendar items from API
    await loadCalendarItems();

    // Load external events if enabled
    await loadExternalEvents();

    // Check for conflicts and show modal if needed
    await checkForCalendarConflicts();

    renderCalendarControls();
    renderCalendarGrid();
}

/**
 * Update calendar epic dropdown visual style based on current selection
 */
function updateCalendarEpicDropdownStyle() {
    const dropdown = document.getElementById('calendar-epic-filter-dropdown');
    const select = document.getElementById('calendar-epic-filter-select');
    if (dropdown && select) {
        if (select.value !== 'all') {
            dropdown.classList.add('active');
        } else {
            dropdown.classList.remove('active');
        }
    }
}

/**
 * Populate calendar epic filter dropdown with epics from cached calendar data
 */
function populateCalendarEpicFilterOptions() {
    const select = document.getElementById('calendar-epic-filter-select');
    if (!select) return;

    // Get epics from cached calendar data
    const epics = calendarState.cachedEpics || [];

    // Use state variable for restoration
    const targetValue = calendarState.epicFilter || select.value || 'all';

    // Clear existing epic-specific options (keep ALL, ASSIGNED, UNASSIGNED)
    while (select.options.length > 3) {
        select.remove(3);
    }

    // Add a separator if there are epics
    if (epics.length > 0) {
        const separator = document.createElement('option');
        separator.value = '---';
        separator.textContent = '───────────';
        separator.disabled = true;
        select.appendChild(separator);

        // Add each epic
        epics.forEach(epic => {
            const option = document.createElement('option');
            option.value = epic.id;
            // Display format: "ShortLabel - Title" or just title if no shortTitle
            let displayName;
            if (epic.shortTitle && (epic.title || epic.name)) {
                displayName = `${epic.shortTitle} - ${epic.title || epic.name}`;
            } else {
                displayName = epic.title || epic.name || epic.id;
            }
            option.textContent = displayName.length > 35 ? displayName.substring(0, 35) + '…' : displayName;
            option.title = `${epic.title || epic.name} (${epic.id})`;
            select.appendChild(option);
        });
    }

    // Restore previous value if still valid
    select.value = targetValue;
    if (select.value !== targetValue) {
        select.value = 'all';
        calendarState.epicFilter = 'all';
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// CALENDAR SETTINGS MODAL (XACA-0039-008)
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Open the calendar settings modal and load current configuration
 */
async function openCalendarSettingsModal() {
    const modal = document.getElementById('calendar-settings-modal');
    if (!modal) return;

    modal.style.display = 'flex';

    // Load current calendar configuration
    await loadCalendarConfig();
}

/**
 * Close the calendar settings modal
 */
function closeCalendarSettingsModal() {
    const modal = document.getElementById('calendar-settings-modal');
    if (modal) {
        modal.style.display = 'none';
    }
}

/**
 * Load calendar configuration from server for current team
 */
async function loadCalendarConfig() {
    const team = CONFIG.team || 'academy';

    try {
        const response = await fetch(apiUrl('/api/calendar/config'));

        if (response.ok) {
            const config = await response.json();
            updateCalendarSettingsUI(config);
        } else {
            // No config exists yet, show disconnected state
            updateCalendarSettingsUI({ apple: null, google: null });
        }
    } catch (error) {
        console.error('Failed to load calendar config:', error);
        updateCalendarSettingsUI({ apple: null, google: null });
    }
}

/**
 * Update calendar settings UI with current configuration
 */
function updateCalendarSettingsUI(config) {
    // Update Apple Calendar status
    const appleConnected = config.apple && config.apple.connected;
    const appleStatusValue = document.getElementById('apple-status-value');
    const appleCredentialForm = document.getElementById('apple-credential-form');
    const appleInfo = document.getElementById('apple-info');
    const appleConnectBtn = document.getElementById('apple-connect-btn');
    const appleDisconnectBtn = document.getElementById('apple-disconnect-btn');
    const appleSelectGroup = document.getElementById('apple-calendar-select-group');

    if (appleConnected) {
        appleStatusValue.textContent = 'CONNECTED';
        appleStatusValue.classList.add('connected');
        appleCredentialForm.style.display = 'none';
        appleInfo.style.display = 'block';
        appleConnectBtn.style.display = 'none';
        appleDisconnectBtn.style.display = 'inline-block';

        document.getElementById('apple-account-name').textContent = config.apple.accountName || '--';
        document.getElementById('apple-calendar-name').textContent = config.apple.calendarName || '--';

        // Show calendar selector if we have calendars
        if (config.apple.availableCalendars && config.apple.availableCalendars.length > 0) {
            appleSelectGroup.style.display = 'block';
            populateCalendarSelect('apple-calendar-select', config.apple.availableCalendars, config.apple.selectedCalendarId);
        }
    } else {
        appleStatusValue.textContent = 'NOT CONNECTED';
        appleStatusValue.classList.remove('connected');
        appleCredentialForm.style.display = 'block';
        appleInfo.style.display = 'none';
        appleConnectBtn.style.display = 'inline-block';
        appleDisconnectBtn.style.display = 'none';
        appleSelectGroup.style.display = 'none';
    }

    // Update Google Calendar status
    const googleConnected = config.google && config.google.connected;
    const googleStatusValue = document.getElementById('google-status-value');
    const googleCredentialForm = document.getElementById('google-credential-form');
    const googleInfo = document.getElementById('google-info');
    const googleConnectBtn = document.getElementById('google-connect-btn');
    const googleDisconnectBtn = document.getElementById('google-disconnect-btn');
    const googleSelectGroup = document.getElementById('google-calendar-select-group');

    if (googleConnected) {
        googleStatusValue.textContent = 'CONNECTED';
        googleStatusValue.classList.add('connected');
        googleCredentialForm.style.display = 'none';
        googleInfo.style.display = 'block';
        googleConnectBtn.style.display = 'none';
        googleDisconnectBtn.style.display = 'inline-block';

        document.getElementById('google-account-name').textContent = config.google.accountName || '--';
        document.getElementById('google-calendar-name').textContent = config.google.calendarName || '--';

        // Show calendar selector if we have calendars
        if (config.google.availableCalendars && config.google.availableCalendars.length > 0) {
            googleSelectGroup.style.display = 'block';
            populateCalendarSelect('google-calendar-select', config.google.availableCalendars, config.google.selectedCalendarId);
        }
    } else {
        googleStatusValue.textContent = 'NOT CONNECTED';
        googleStatusValue.classList.remove('connected');
        googleCredentialForm.style.display = 'block';
        googleInfo.style.display = 'none';
        googleConnectBtn.style.display = 'inline-block';
        googleDisconnectBtn.style.display = 'none';
        googleSelectGroup.style.display = 'none';
    }
}

/**
 * Populate a calendar select dropdown with available calendars
 */
function populateCalendarSelect(selectId, calendars, selectedId) {
    const select = document.getElementById(selectId);
    if (!select) return;

    select.innerHTML = '<option value="">Select a calendar...</option>';

    calendars.forEach(cal => {
        const option = document.createElement('option');
        option.value = cal.id;
        option.textContent = cal.name;
        if (cal.id === selectedId) {
            option.selected = true;
        }
        select.appendChild(option);
    });

    // Add change listener to save selection
    select.addEventListener('change', async (e) => {
        const provider = selectId.startsWith('apple') ? 'apple' : 'google';
        await saveCalendarSelection(provider, e.target.value);
    });
}

/**
 * Save calendar selection to server
 */
async function saveCalendarSelection(provider, calendarId) {
    const team = CONFIG.team || 'academy';

    // Find the calendar name from the select dropdown
    const selectEl = document.getElementById(`${provider}-calendar-select`);
    const calendarName = selectEl ? selectEl.options[selectEl.selectedIndex]?.text : null;

    try {
        const response = await apiFetch(apiUrl('/api/calendar/config'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ provider, calendarId, calendarName })
        });

        if (!response.ok) {
            // XACA-0395 [UX-16]: carry status onto the Error so the catch below can
            // defer to api-auth.js's central 401 notifier instead of double-toasting.
            const saveErr = new Error(`Failed to save calendar selection: ${response.statusText}`);
            saveErr.status = response.status;
            throw saveErr;
        }

        // Reload config to update UI
        await loadCalendarConfig();

        // Show success feedback
        showToast(`${provider === 'apple' ? 'Apple' : 'Google'} Calendar selection saved`, 'success');
    } catch (error) {
        console.error('Failed to save calendar selection:', error);
        // XACA-0395 [UX-16]: skip the redundant local toast on 401 — the central
        // auth-failure toast already told the user what happened.
        // XACA-0395-015: same skip on a network-level failure (isNetworkFailure).
        if (!error || (error.status !== 401 && !error.isNetworkFailure)) {
            showToast('Failed to save calendar selection', 'error');
        }
    }
}

/**
 * Connect Apple Calendar - send credentials to server
 */
async function connectAppleCalendar() {
    const team = CONFIG.team || 'academy';

    // Get credentials from input fields
    const username = document.getElementById('apple-email').value.trim();
    const appPassword = document.getElementById('apple-app-password').value.trim();

    // Validate inputs
    if (!username || !appPassword) {
        showToast('Please enter both iCloud email and app-specific password', 'error');
        return;
    }

    try {
        // Send credentials to server
        const response = await apiFetch(apiUrl('/api/calendar/connect/apple'), {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                username: username,
                appPassword: appPassword
            })
        });

        if (!response.ok) {
            const errorData = await response.json().catch(() => ({}));
            // XACA-0395 [UX-16]: carry status onto the Error so the catch below can
            // defer to api-auth.js's central 401 notifier instead of double-toasting.
            const connErr = new Error(errorData.error || `Failed to connect Apple Calendar: ${response.statusText}`);
            connErr.status = response.status;
            throw connErr;
        }

        // Clear input fields
        document.getElementById('apple-email').value = '';
        document.getElementById('apple-app-password').value = '';

        // Reload config to update UI
        await loadCalendarConfig();
        showToast('Apple Calendar connected successfully', 'success');
    } catch (error) {
        console.error('Failed to connect Apple Calendar:', error);
        // XACA-0395 [UX-16]: skip the redundant local toast on 401 — the central
        // auth-failure toast already told the user what happened.
        // XACA-0395-015: same skip on a network-level failure (isNetworkFailure).
        if (!error || (error.status !== 401 && !error.isNetworkFailure)) {
            showToast(error.message || 'Failed to connect Apple Calendar', 'error');
        }
    }
}

/**
 * Disconnect Apple Calendar
 */
async function disconnectAppleCalendar() {
    if (!confirm('Are you sure you want to disconnect Apple Calendar? This will remove all synced events.')) {
        return;
    }

    const team = CONFIG.team || 'academy';

    try {
        const response = await apiFetch(apiUrl('/api/calendar/disconnect/apple'), {
            method: 'POST'
        });

        if (!response.ok) {
            // XACA-0395 [UX-16]: carry status onto the Error so the catch below can
            // defer to api-auth.js's central 401 notifier instead of double-toasting.
            const discErr = new Error(`Failed to disconnect Apple Calendar: ${response.statusText}`);
            discErr.status = response.status;
            throw discErr;
        }

        await loadCalendarConfig();
        showToast('Apple Calendar disconnected', 'success');
    } catch (error) {
        console.error('Failed to disconnect Apple Calendar:', error);
        // XACA-0395 [UX-16]: skip the redundant local toast on 401 — the central
        // auth-failure toast already told the user what happened.
        // XACA-0395-015: same skip on a network-level failure (isNetworkFailure).
        if (!error || (error.status !== 401 && !error.isNetworkFailure)) {
            showToast('Failed to disconnect Apple Calendar', 'error');
        }
    }
}

/**
 * Connect Google Calendar - send credentials to server
 */
async function connectGoogleCalendar() {
    const team = CONFIG.team || 'academy';

    // Get credentials from input fields
    const clientId = document.getElementById('google-client-id').value.trim();
    const clientSecret = document.getElementById('google-client-secret').value.trim();
    const refreshToken = document.getElementById('google-refresh-token').value.trim();

    // Validate inputs
    if (!clientId || !clientSecret || !refreshToken) {
        showToast('Please enter all Google Calendar credentials', 'error');
        return;
    }

    try {
        // Send credentials to server
        const response = await apiFetch(apiUrl('/api/calendar/connect/google'), {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                clientId: clientId,
                clientSecret: clientSecret,
                refreshToken: refreshToken
            })
        });

        if (!response.ok) {
            const errorData = await response.json().catch(() => ({}));
            // XACA-0395 [UX-16]: carry status onto the Error so the catch below can
            // defer to api-auth.js's central 401 notifier instead of double-toasting.
            const connErr = new Error(errorData.error || `Failed to connect Google Calendar: ${response.statusText}`);
            connErr.status = response.status;
            throw connErr;
        }

        // Clear input fields
        document.getElementById('google-client-id').value = '';
        document.getElementById('google-client-secret').value = '';
        document.getElementById('google-refresh-token').value = '';

        // Reload config to update UI
        await loadCalendarConfig();
        showToast('Google Calendar connected successfully', 'success');
    } catch (error) {
        console.error('Failed to connect Google Calendar:', error);
        // XACA-0395 [UX-16]: skip the redundant local toast on 401 — the central
        // auth-failure toast already told the user what happened.
        // XACA-0395-015: same skip on a network-level failure (isNetworkFailure).
        if (!error || (error.status !== 401 && !error.isNetworkFailure)) {
            showToast(error.message || 'Failed to connect Google Calendar', 'error');
        }
    }
}

/**
 * Disconnect Google Calendar
 */
async function disconnectGoogleCalendar() {
    if (!confirm('Are you sure you want to disconnect Google Calendar? This will remove all synced events.')) {
        return;
    }

    const team = CONFIG.team || 'academy';

    try {
        const response = await apiFetch(apiUrl('/api/calendar/disconnect/google'), {
            method: 'POST'
        });

        if (!response.ok) {
            // XACA-0395 [UX-16]: carry status onto the Error so the catch below can
            // defer to api-auth.js's central 401 notifier instead of double-toasting.
            const discErr = new Error(`Failed to disconnect Google Calendar: ${response.statusText}`);
            discErr.status = response.status;
            throw discErr;
        }

        await loadCalendarConfig();
        showToast('Google Calendar disconnected', 'success');
    } catch (error) {
        console.error('Failed to disconnect Google Calendar:', error);
        // XACA-0395 [UX-16]: skip the redundant local toast on 401 — the central
        // auth-failure toast already told the user what happened.
        // XACA-0395-015: same skip on a network-level failure (isNetworkFailure).
        if (!error || (error.status !== 401 && !error.isNetworkFailure)) {
            showToast('Failed to disconnect Google Calendar', 'error');
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// BACKLOG FILTER STATE MANAGEMENT
// Powered by createFilterBar() from lcars-filter-bar.js (XACA-0292-005).
// backlogFilterState is a live reference into the component's internal state
// object — all existing callers (itemMatchesFilter, renderMissionBacklog, etc.)
// continue to read it directly, unchanged.
// ═══════════════════════════════════════════════════════════════════════════════

// Component instance; assigned in initQueueFilterBar() below.
let _backlogFilterBarInstance = null;

// ── Thin stubs kept for external callers outside the filter-bar block ──────────
// (populateReleaseFilterOptions at lines ~628, ~10653; populateEpicFilterOptions
//  at lines ~12757, ~12855, ~12883; updateReleaseDropdownStyle at line ~11027;
//  saveQueueFilterState at line ~11031)

/** @deprecated internal — use component instance; kept for external call sites */
function saveQueueFilterState() {
    if (_backlogFilterBarInstance) _backlogFilterBarInstance.save();
}

/** @deprecated internal — use component instance; kept for external call sites */
function updateReleaseDropdownStyle() {
    if (_backlogFilterBarInstance) _backlogFilterBarInstance.updateReleaseStyle();
}

/** @deprecated internal — use component instance; kept for external call sites */
function populateReleaseFilterOptions() {
    if (_backlogFilterBarInstance) _backlogFilterBarInstance.populateReleaseOptions();
}

/** @deprecated internal — use component instance; kept for external call sites */
function populateEpicFilterOptions() {
    if (_backlogFilterBarInstance) _backlogFilterBarInstance.populateEpicOptions();
}

/** Repopulate CR dropdown from live boardData.crs[]. Called after board refresh. */
function populateCRFilterOptions() {
    if (_backlogFilterBarInstance) _backlogFilterBarInstance.populateCROptions();
}

// ─── Release Tag Filter (XACA-0209) ──────────────────────────────────────────

// ─── Release / Epic search + item-tag helpers (XACA-0209 round 5) ─────────────

/** Shared: load a persisted search string from localStorage. */
function loadSearchText(storageKey) {
    try {
        const saved = localStorage.getItem(storageKey);
        return typeof saved === 'string' ? saved : '';
    } catch (e) {
        return '';
    }
}

/** Shared: persist a search string to localStorage. */
function saveSearchText(storageKey, text) {
    try {
        localStorage.setItem(storageKey, text);
    } catch (e) {
        /* noop — non-fatal */
    }
}

/** Substring matcher shared by release and epic search.
 *  Matches across id, title, shortTitle, description, and tags. Empty text → always true. */
function itemMatchesSearch(item, searchText) {
    if (!searchText) return true;
    const needle = searchText.toLowerCase().trim();
    if (!needle) return true;
    const hay = [
        item.id || '',
        item.title || '',
        item.name || '',
        item.shortTitle || '',
        item.description || '',
    ].join(' ').toLowerCase();
    if (hay.includes(needle)) return true;
    if (Array.isArray(item.tags)) {
        for (const tag of item.tags) {
            if (typeof tag === 'string' && tag.toLowerCase().includes(needle)) return true;
        }
    }
    return false;
}

/** Release search state mutator. Updates input value (if different), persists, and reloads. */
function setReleaseSearchFilter(text) {
    releaseSearchText = text || '';
    saveSearchText(RELEASE_SEARCH_KEY, releaseSearchText);
    const input = document.getElementById('release-filter-text');
    if (input && input.value !== releaseSearchText) input.value = releaseSearchText;
    const clearBtn = document.getElementById('release-filter-clear');
    if (clearBtn) clearBtn.style.display = releaseSearchText ? 'block' : 'none';
    loadReleases();
}

/** Epic search state mutator. Updates input value (if different), persists, and reloads. */
function setEpicSearchFilter(text) {
    epicSearchText = text || '';
    saveSearchText(EPIC_SEARCH_KEY, epicSearchText);
    const input = document.getElementById('epic-filter-text');
    if (input && input.value !== epicSearchText) input.value = epicSearchText;
    const clearBtn = document.getElementById('epic-filter-clear');
    if (clearBtn) clearBtn.style.display = epicSearchText ? 'block' : 'none';
    loadEpics();
}

/** Wire the search input + clear button for a section. Shared between Releases and Epics. */
function initSectionSearchBar(config) {
    const input = document.getElementById(config.inputId);
    const clearBtn = document.getElementById(config.clearId);
    if (!input || !clearBtn) return;

    // Restore persisted value before binding events (so the initial input event
    // we fire with setter below doesn't double-run).
    input.value = config.currentText();
    clearBtn.style.display = config.currentText() ? 'block' : 'none';

    let debounceTimer = null;
    input.addEventListener('input', (e) => {
        const v = e.target.value;
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(() => config.setFilter(v), 150);
    });

    clearBtn.addEventListener('click', () => {
        input.value = '';
        config.setFilter('');
        input.focus();
    });
}

/**
 * Build a Queue-style purple tag-pill row for a Release or Epic card.
 * Returns an HTML string (for inline injection into card template literals), but
 * the pill DOM is built via createElement/textContent/dataset (matching Queue's
 * createTagsElement) so no tag value ever reaches an attribute-context
 * interpolation — attribute-quote or HTML-delimiter characters in tag values
 * cannot escape their context regardless of escapeHtml's scope. Returns '' when
 * the tag list is empty.
 *
 * @param {string[]} tags
 * @param {string} searchScope   'release' | 'epic' — stored on dataset.searchScope
 */
function buildItemTagsHtml(tags, searchScope) {
    if (!Array.isArray(tags) || tags.length === 0) return '';
    const displayTags = tags.filter(t => typeof t === 'string' && t.trim());
    if (displayTags.length === 0) return '';

    const row = document.createElement('div');
    row.className = 'backlog-tags-row';
    const container = document.createElement('div');
    container.className = 'backlog-tags';
    row.appendChild(container);

    displayTags.forEach((tag, idx) => {
        if (idx > 0) {
            const sep = document.createElement('div');
            sep.className = 'backlog-tag-separator';
            container.appendChild(sep);
        }
        const trimmed = tag.trim();
        const pill = document.createElement('div');
        pill.className = 'backlog-tag';
        pill.textContent = trimmed;
        pill.title = `Filter by: ${trimmed}`;
        pill.dataset.tag = trimmed;
        pill.dataset.searchScope = searchScope;
        container.appendChild(pill);
    });

    return row.outerHTML;
}

/** Delegated click wiring for item tag pills inside a dashboard container.
 *  Called once per displayReleases / displayEpics so click handlers survive re-render. */
function bindItemTagClicks(dashboardEl) {
    if (!dashboardEl || dashboardEl.dataset.tagClicksWired === '1') return;
    dashboardEl.addEventListener('click', (e) => {
        const pill = e.target.closest('.backlog-tag[data-search-scope]');
        if (!pill) return;
        e.stopPropagation();
        const tag = pill.dataset.tag || '';
        const scope = pill.dataset.searchScope;
        if (scope === 'release') setReleaseSearchFilter(tag);
        else if (scope === 'epic') setEpicSearchFilter(tag);
    });
    dashboardEl.dataset.tagClicksWired = '1';
}

// ─────────────────────────────────────────────────────────────────────────────

/**
 * Initialize the BACKLOG filter bar using the reusable createFilterBar component.
 * XACA-0292-005: replaces the previous inline implementation.
 *
 * After init:
 *   - backlogFilterState points to the component's live state object
 *   - _backlogFilterBarInstance holds the full public API
 *   - External callers of saveQueueFilterState / populateReleaseFilterOptions /
 *     populateEpicFilterOptions / updateReleaseDropdownStyle forward to the instance
 *     via the stubs defined above.
 */
function initQueueFilterBar() {
    _backlogFilterBarInstance = createFilterBar({
        containerId:             'backlog-filter-bar',
        storageKey:              BACKLOG_FILTER_KEY,
        initialState:            Object.assign({}, backlogFilterState),
        osPlatforms:             OS_PLATFORMS,
        osConfig:                OS_CONFIG,
        releaseOptionsEndpoint:  '/api/releases',
        epicOptionsEndpoint:     '/api/epics',
        // XACA-0310-003: synchronous provider; reads live boardData.crs[] — no server route needed
        crsProvider:             () => (window.boardData && window.boardData.crs) || [],
        extraButtons: [
            {
                id:      'backlog-import-btn',
                onClick: () => showImportModal(),
            },
        ],
        viewToggle: {
            btnId:             'view-toggle-btn',
            valueId:           'view-toggle-value',
            sectionSelector:   '.backlog-section',
            storageKey:        'lcars-view-toggle',
            values:            ['TAGS', 'TRACKING'],
        },
        onChange: () => renderMissionBacklog(),
    });

    // Redirect the module-level backlogFilterState reference to the component's
    // live state object.  All existing callers (itemMatchesFilter, renderMissionBacklog,
    // viewReleaseItems, etc.) reference the module-level variable; this single
    // reassignment keeps them working with zero further changes.
    backlogFilterState = _backlogFilterBarInstance.getState();

    // XACA-0310-003: Gate CR dropdown visibility on crSupport.enabled.
    // Read initial state from already-loaded boardData (set by loadBoardData before
    // initQueueFilterBar is called).  Runtime toggles are handled by the
    // crsupport-changed listener below.
    _applyCRDropdownVisibility(
        !!(window.boardData &&
           window.boardData.teamConfig &&
           window.boardData.teamConfig.crSupport &&
           window.boardData.teamConfig.crSupport.enabled)
    );

    document.addEventListener('crsupport-changed', (e) => {
        const enabled = !!(e.detail && e.detail.enabled);
        _applyCRDropdownVisibility(enabled);
        if (!enabled && backlogFilterState.crFilter !== 'all') {
            // Reset CR filter so hidden state doesn't silently suppress items
            backlogFilterState.crFilter = 'all';
            const crSelect = document.getElementById('cr-filter-select');
            if (crSelect) crSelect.value = 'all';
            if (_backlogFilterBarInstance) _backlogFilterBarInstance.save();
            renderMissionBacklog();
        }
    });
}

/**
 * Show or hide the BACKLOG CR filter dropdown based on crSupport.enabled.
 * @param {boolean} enabled
 */
function _applyCRDropdownVisibility(enabled) {
    const crDropdown = document.getElementById('cr-filter-dropdown');
    if (!crDropdown) return;
    crDropdown.style.display = enabled ? '' : 'none';
}

// ═══════════════════════════════════════════════════════════════════════════════
// VIEW TOGGLE — now handled inside createFilterBar via the viewToggle option.
// XACA-0046 / XACA-0292-005: stub kept so any lingering call sites don't error.
// ═══════════════════════════════════════════════════════════════════════════════

function initViewToggle() {
    // No-op: view toggle wired by createFilterBar() in initQueueFilterBar() above.
}

// ═══════════════════════════════════════════════════════════════════════════════
// COMMAND SECTION BAR - Navigation between command categories
// ═══════════════════════════════════════════════════════════════════════════════

function initCommandSectionBar() {
    const sectionBar = document.getElementById('command-section-bar');
    if (!sectionBar) return;

    // Section pill click handlers
    sectionBar.querySelectorAll('.command-section-pill').forEach(pill => {
        pill.addEventListener('click', () => {
            const section = pill.dataset.commandSection;
            if (section && section !== activeCommandSection) {
                renderCommands(section);
            }
        });
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// SECTION NAVIGATION
// ═══════════════════════════════════════════════════════════════════════════════

function getSectionClass(section) {
    if (section === 'workflow') return 'kanban-section';
    return `${section}-section`;
}


// Mode state machine — XACA-0164-004
// Switches the active UI mode (team | kanban | data | settings).
// Routing and sidebar swapping are handled by later subitems (007, 005).
function switchMode(newMode) {
    if (!MODES.includes(newMode)) return;
    if (newMode === activeMode) return;

    const previousMode = activeMode;
    activeMode = newMode;

    // Apply data-mode attribute to .lcars-container (or <html> as fallback)
    const container = document.querySelector('.lcars-container') || document.documentElement;
    container.setAttribute('data-mode', newMode);

    // Update mode-pill active classes
    document.querySelectorAll('.mode-pill[data-mode-target]').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.modeTarget === newMode);
    });

    // Persist selection
    try {
        localStorage.setItem(MODE_KEY, newMode);
    } catch (e) {
        console.warn('lcars: Could not persist mode to localStorage', e);
    }

    // Notify listeners — routing wired up in XACA-0164-007
    document.dispatchEvent(new CustomEvent('modechange', {
        detail: { mode: newMode, previous: previousMode }
    }));
}

// ─── Mode Router Helpers — XACA-0164-007 ─────────────────────────────────────

/**
 * Show/hide content sections based on the active mode.
 * Each <section data-mode="..."> element lists the modes it belongs to
 * as a space-separated string (e.g. "team kanban"). Sections not in the
 * current mode are hidden with .hidden-by-mode.
 */
function filterSectionsByMode(mode) {
    document.querySelectorAll('section[data-mode]').forEach(section => {
        const allowedModes = section.dataset.mode.split(/\s+/);
        if (allowedModes.includes(mode)) {
            section.classList.remove('hidden-by-mode');
        } else {
            section.classList.add('hidden-by-mode');
        }
    });
}

/**
 * Returns the canonical default section name for a given mode.
 * Per spec A1.3:
 *   TEAM, KANBAN, DATA  → 'home' (first sidebar item is HOME)
 *   SETTINGS            → 'team-config' (no HOME in settings sidebar)
 */
function pickDefaultSectionForMode(mode) {
    switch (mode) {
        case 'kanban':
            return 'daily-overview'; // XACA-0334: kanban mode lands on Daily Overview
        case 'team':
        case 'data':
            return 'home';
        case 'settings':
            return 'team-config';
        default:
            return 'home';
    }
}

// ─── Per-mode section persistence helpers — XACA-0164-013 ────────────────────

/**
 * Load per-mode section map from localStorage.
 * Returns an object with defaults if nothing is stored yet.
 */
function loadModeSections() {
    const defaults = { team: 'home', kanban: 'daily-overview', data: 'home', settings: 'team-config' }; // XACA-0334: kanban default → daily-overview
    // Renames applied to any persisted section value before validation.
    // XACA-0292 renamed 'queue' → 'backlog'; pre-rename users still have 'queue'
    // in localStorage, which would fail the SECTIONS.indexOf check in switchSection
    // and leave them stranded on the startup splash.
    const RENAMES = { 'queue': 'backlog' };
    try {
        const raw = localStorage.getItem(MODE_SECTIONS_KEY);
        if (raw) {
            const parsed = JSON.parse(raw);
            const merged = Object.assign({}, defaults, parsed);
            let dirty = false;
            for (const mode of Object.keys(merged)) {
                const orig = merged[mode];
                if (RENAMES[orig]) { merged[mode] = RENAMES[orig]; dirty = true; }
                if (!SECTIONS.includes(merged[mode])) { merged[mode] = defaults[mode] || 'home'; dirty = true; }
            }
            if (dirty) saveModeSections(merged);
            return merged;
        }
    } catch (e) {
        console.warn('lcars: Could not read modeSections from localStorage', e);
    }
    return defaults;
}

/**
 * Persist the per-mode section map to localStorage.
 */
function saveModeSections(modeSectionsObj) {
    try {
        localStorage.setItem(MODE_SECTIONS_KEY, JSON.stringify(modeSectionsObj));
    } catch (e) {
        console.warn('lcars: Could not persist modeSections to localStorage', e);
    }
}

/**
 * Sync URL hash to reflect current mode and section.
 * Uses history.replaceState so every navigation doesn't pollute browser history.
 */
function updateURLHash(mode, section) {
    if (section === 'startup') return; // never expose startup in hash
    try {
        const newHash = `#mode=${encodeURIComponent(mode)}&section=${encodeURIComponent(section)}`;
        history.replaceState(null, '', newHash);
    } catch (e) {
        // replaceState can fail in file:// protocol; silently ignore
    }
}

/**
 * Parse mode and section from location.hash.
 * Returns null if hash is absent or invalid.
 */
function parseURLHash() {
    try {
        const hash = location.hash.slice(1); // remove leading '#'
        if (!hash) return null;
        const params = {};
        hash.split('&').forEach(part => {
            const [k, v] = part.split('=');
            if (k && v) params[decodeURIComponent(k)] = decodeURIComponent(v);
        });
        const mode = params.mode;
        const section = params.section;
        if (mode && MODES.includes(mode) && section && SECTIONS.includes(section)) {
            return { mode, section };
        }
    } catch (e) {
        // Malformed hash — ignore
    }
    return null;
}

// ─── Migration — XACA-0164-014 ───────────────────────────────────────────────

/**
 * One-time migration from the old single SECTION_KEY to the new per-mode map.
 * Safe to call on every boot: bails immediately if new schema already exists.
 */
function runMigration() {
    try {
        // Already migrated — nothing to do
        if (localStorage.getItem(MODE_SECTIONS_KEY) !== null) return;

        const OLD_SECTION_TO_MODE = {
            'home': { mode: 'kanban', section: 'home' },
            'workflow': { mode: 'kanban', section: 'workflow' },
            'kanban': { mode: 'kanban', section: 'workflow' },
            'backlog': { mode: 'kanban', section: 'backlog' },
            'details': { mode: 'kanban', section: 'details' },
            'epics': { mode: 'kanban', section: 'epics' },
            'releases': { mode: 'kanban', section: 'releases' },
            'todos': { mode: 'kanban', section: 'todos' },
            'calendar': { mode: 'kanban', section: 'calendar' },
            'commands': { mode: 'kanban', section: 'commands' },
            'knowledge-graph': { mode: 'data', section: 'knowledge-graph' },
            'rag-engines': { mode: 'data', section: 'rag-engines' },
            'team-config': { mode: 'settings', section: 'team-config' },
            'integrations': { mode: 'settings', section: 'integrations' },
            'backups': { mode: 'settings', section: 'backups' },
            'export-import': { mode: 'settings', section: 'export-import' },
            'startup': { mode: 'kanban', section: 'home' } // startup is not a restore target
        };

        const defaultModeSections = { team: 'home', kanban: 'home', data: 'home', settings: 'team-config' };

        const oldSection = localStorage.getItem(SECTION_KEY);
        if (oldSection) {
            const mapped = OLD_SECTION_TO_MODE[oldSection] || { mode: 'kanban', section: 'home' };
            defaultModeSections[mapped.mode] = mapped.section;
            // Seed MODE_KEY so the existing user lands on the right mode
            try { localStorage.setItem(MODE_KEY, mapped.mode); } catch (e) {}
        }

        saveModeSections(defaultModeSections);
        // Mark migration complete (belt-and-suspenders — modeSections presence is the real guard)
        try { localStorage.setItem('lcars.migration.v1', 'done'); } catch (e) {}
        // Keep SECTION_KEY in place for rollback safety — do not delete it
    } catch (e) {
        console.warn('lcars: Migration error', e);
    }

    // XACA-0209 round 5: one-shot cleanup of the round-3/4 pill-filter localStorage
    // keys. Shape is incompatible with the new search model, so stale values would
    // sit forever. removeItem is idempotent — safe to call on every session.
    try {
        localStorage.removeItem('lcars-release-tags-filter');
        localStorage.removeItem('lcars-epic-tags-filter');
    } catch (e) {
        /* noop — non-fatal */
    }
}

// ─────────────────────────────────────────────────────────────────────────────

function switchSection(sectionName, skipAnimation = false) {
    let newIndex = SECTIONS.indexOf(sectionName);
    if (newIndex === -1) {
        // Unknown section (often stale persisted name after a rename). Fall back
        // to the mode default so the user is never stranded on the splash.
        console.warn(`[router] unknown section "${sectionName}" — falling back to default`);
        sectionName = pickDefaultSectionForMode(activeMode);
        newIndex = SECTIONS.indexOf(sectionName);
        if (newIndex === -1) return;
    }

    const previousSection = activeSection;
    const previousEl = document.querySelector(`.${getSectionClass(previousSection)}`);

    // If same section, do nothing
    if (previousSection === sectionName) return;

    // Guard: section must be valid for current mode — XACA-0164-007
    // Startup is always allowed regardless of mode (boot sequence).
    const sectionEl = document.querySelector(`.${getSectionClass(sectionName)}`);
    if (sectionEl && sectionEl.dataset.mode && activeMode && sectionName !== 'startup') {
        const allowedModes = sectionEl.dataset.mode.split(/\s+/);
        if (!allowedModes.includes(activeMode)) {
            console.warn(`[router] section "${sectionName}" not available in mode "${activeMode}"`);
            return;
        }
    }

    // Update state
    activeSection = sectionName;
    activeSectionIndex = newIndex;

    // Persist to localStorage (but not startup)
    if (sectionName !== 'startup') {
        try {
            localStorage.setItem(SECTION_KEY, sectionName);
        } catch (e) {}
        // Per-mode section memory — XACA-0164-013
        const modeSections = loadModeSections();
        modeSections[activeMode] = sectionName;
        saveModeSections(modeSections);
        // Sync URL hash
        updateURLHash(activeMode, sectionName);
    }

    // Update sidebar buttons (startup has no button)
    document.querySelectorAll('.sidebar-button[data-section]').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.section === sectionName);
    });

    // Update mobile tab bar buttons (mirrors sidebar state)
    document.querySelectorAll('.tabbar-button[data-section]').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.section === sectionName);
    });

    // Update mode-bar utility pills that navigate to sections (e.g. USAGE — XACA-0243)
    document.querySelectorAll('.legend-pill[data-section]').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.section === sectionName);
    });

    // Stop carousel auto-advance when leaving HOME tab
    if (previousSection === 'home') {
        stopCarousel();
    }

    // Stop export/import polling when leaving EXPORT/IMPORT tab
    if (previousSection === 'export-import') {
        stopExportPolling();
        stopImportPolling();
    }

    // Stop RAG engines health polling when leaving RAG ENGINES tab
    if (previousSection === 'rag-engines') {
        stopRAGEnginesHealthPolling();
    }

    // Handle exit animation for previous section
    if (previousEl && !skipAnimation && previousSection !== 'startup') {
        // Add exiting class to trigger reverse cascade
        previousEl.classList.add('exiting');

        // After exit animation completes, remove classes
        setTimeout(() => {
            previousEl.classList.remove('active', 'exiting');
        }, 200); // Match exit transition duration
    } else if (previousEl) {
        // Skip animation - immediate hide
        previousEl.classList.remove('active', 'exiting');
    }

    // Show new section with entrance animation
    SECTIONS.forEach((section) => {
        const el = document.querySelector(`.${getSectionClass(section)}`);
        if (!el) return;

        if (section === sectionName) {
            // Remove any lingering animation classes
            el.classList.remove('exiting', 'refreshing');

            // Delay entrance if we're animating exit
            const entranceDelay = (!skipAnimation && previousSection !== 'startup') ? 100 : 0;

            const applyEntrance = () => {
                el.classList.add('active');
                // Render charts AFTER section is visible (Canvas needs dimensions)
                if (section === 'home') {
                    renderHomeAnalytics();
                    // Initialize carousel (idempotent) and start auto-advance
                    initCarousel();
                }
            };

            // When there's no delay, apply synchronously — using setTimeout(0) here
            // creates a race where a follow-up switchSection call can queue its own
            // .active toggle before this one fires, leaving two sections active
            // simultaneously (XACA-0164 debug: home content bleeding through splash).
            if (entranceDelay === 0) {
                applyEntrance();
            } else {
                setTimeout(applyEntrance, entranceDelay);
            }
        } else if (section !== previousSection) {
            // Other sections stay hidden
            el.classList.remove('active');
        }
    });

    // Toggle mode bar (show on all tabs except startup) — XACA-0164
    const modeBar = document.querySelector('.mode-bar');
    if (modeBar) {
        modeBar.classList.toggle('hidden', sectionName === 'startup');
    }

    // Note: renderHomeAnalytics() is called inside the entrance setTimeout above (line ~8759)
    // so canvases have real dimensions when Chart.js reads them.

    // Load backup status and files when switching to backups section
    if (sectionName === 'backups') {
        loadBackupStatus();
        loadBackupFiles();
    }

// Load releases when switching to releases section
    if (sectionName === 'releases') {
        loadReleases();
    }

    // Load epics when switching to epics section
    if (sectionName === 'epics') {
        loadEpics();
    }

    // Render roadmap when switching to roadmap section (XACA-0625)
    // renderRoadmap() is defined by the roadmap render module (XACA-0625-004).
    // Guard prevents crash until that module is loaded.
    if (sectionName === 'roadmap') {
        if (typeof renderRoadmap === 'function') renderRoadmap();
    }

    // Render calendar when switching to calendar section
    if (sectionName === 'calendar') {
        // Check for calendar integration (only needs to happen once)
        if (!calendarState.hasCalendarIntegration) {
            checkCalendarIntegration().then(enabled => {
                calendarState.hasCalendarIntegration = enabled;
                // Initialize sync status (XACA-0039-010)
                calendarState.syncStatus = enabled ? 'synced' : 'not_connected';
                renderCalendar();
            });
        } else {
            renderCalendar();
        }
    }

    // Load integrations when switching to integrations section
    if (sectionName === 'integrations') {
        loadIntegrations();
    }

    // Load RAG engines when switching to rag-engines section
    if (sectionName === 'rag-engines') {
        loadRAGEngines();
    }

    // Initialize knowledge graph when entering that section
    if (sectionName === 'knowledge-graph') {
        if (!cyGraph) {
            initKnowledgeGraph('knowledge-graph-container');
        }
        loadGraphEngines();
        if (cyGraph && cyGraph.elements().length === 0) {
            loadGraphData('demo');
        }
    }

    // Initialize Export/Import panel when switching to section
    if (sectionName === 'export-import') {
        initExportImportPanel();
    }

    // Load Daily Overview when switching to that section (XACA-0334)
    if (sectionName === 'daily-overview') {
        if (typeof loadDailyOverview === 'function') loadDailyOverview();
    }

    // Load todos when switching to todos section (XACA-0101)
    if (sectionName === 'todos') {
        loadTodos();
    }

    // Load team config when switching to team-config section (XACA-0292)
    if (sectionName === 'team-config') {
        loadTeamConfig();
    }

    // Render CR list when switching to change-req section (XACA-0292-007)
    if (sectionName === 'change-req') {
        if (typeof renderChangeReqList === 'function') renderChangeReqList();
    }

    // Refresh account selector when switching to usage section (XACA-0280-007)
    if (sectionName === 'usage') {
        const selFn = document.getElementById('usage-account-selector')
            ? window._populateUsageAccountSelector
            : null;
        if (typeof selFn === 'function') selFn();
    }
}

function loadSavedSection() {
    // Restore the last-active section for the current mode — XACA-0164-013
    const modeSections = loadModeSections();
    return modeSections[activeMode] || pickDefaultSectionForMode(activeMode);
}

/**
 * Refresh the current section's animations
 * Uses the .refreshing class to instantly reset, then replays entrance animations
 */
function refreshSection() {
    const sectionEl = document.querySelector(`.${getSectionClass(activeSection)}`);
    if (!sectionEl || activeSection === 'startup') return;

    // Add refreshing class to disable transitions
    sectionEl.classList.add('refreshing');
    sectionEl.classList.remove('active');

    // Force reflow to ensure state is applied
    void sectionEl.offsetWidth;

    // Remove refreshing and re-add active to trigger entrance animations
    requestAnimationFrame(() => {
        sectionEl.classList.remove('refreshing');
        sectionEl.classList.add('active');
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// STARTUP ANIMATION SEQUENCE
// ═══════════════════════════════════════════════════════════════════════════════

const STARTUP_MESSAGES = [
    'LCARS INTERFACE v24.7.1',
    'LOADING KERNEL MODULES...',
    'INITIALIZING DISPLAY MATRIX...',
    'CONNECTING TO STARFLEET DATABASE...',
    'LOADING TERMINAL CONFIGURATIONS...',
    'SYNCHRONIZING KANBAN PROTOCOLS...',
    'ESTABLISHING SECURE CHANNELS...',
    'LOADING DEVELOPER PROFILES...',
    'CALIBRATING WORKFLOW ENGINE...',
    'INITIALIZING MISSION BACKLOG...',
    'LOADING COMMAND INTERFACE...',
    'VERIFYING SECURITY CLEARANCE...',
    'SYSTEMS NOMINAL',
    'INTERFACE READY'
];

function generateRandomHex(length) {
    return Array.from({ length }, () =>
        Math.floor(Math.random() * 16).toString(16).toUpperCase()
    ).join('');
}

function generateDataLine() {
    const types = [
        () => `[${generateRandomHex(4)}] SECTOR ${Math.floor(Math.random() * 999)}.${Math.floor(Math.random() * 99)} ONLINE`,
        () => `[${generateRandomHex(4)}] BUFFER ${generateRandomHex(8)} ALLOCATED`,
        () => `[${generateRandomHex(4)}] NODE ${generateRandomHex(6)} SYNCHRONIZED`,
        () => `[${generateRandomHex(4)}] PROTOCOL ${Math.floor(Math.random() * 9999)} VERIFIED`,
        () => `[${generateRandomHex(4)}] CHANNEL ${generateRandomHex(4)}-${generateRandomHex(4)} ACTIVE`,
    ];
    return types[Math.floor(Math.random() * types.length)]();
}

// Startup state for tap-to-skip
let startupTimers = [];
let startupSkipped = false;

function skipStartup() {
    if (startupSkipped) return;
    startupSkipped = true;
    console.log('[LCARS] Startup skipped by user');

    // Clear all intervals and timeouts
    startupTimers.forEach(timer => {
        clearInterval(timer);
        clearTimeout(timer);
    });
    startupTimers = [];

    // Complete the startup immediately
    const progressBar = document.getElementById('startup-progress-bar');
    const initText = document.getElementById('startup-init-text');

    if (progressBar) progressBar.style.width = '100%';
    if (initText) initText.textContent = 'INTERFACE READY';

    // Transition to saved section
    setTimeout(() => {
        const targetSection = loadSavedSection();
        switchSection(targetSection);
    }, 100);
}

function initStartupScreen() {
    // Reset skip state
    startupSkipped = false;
    startupTimers = [];

    // Set the team logo (try PNG first, fall back to SVG)
    const logoImg = document.getElementById('startup-team-logo');
    const logoTeam = getLogoTeamName(CONFIG.team);
    console.log('initStartupScreen: CONFIG.team =', CONFIG.team, 'logoTeam =', logoTeam);
    console.log('initStartupScreen: logoImg found =', !!logoImg);

    if (logoImg && logoTeam) {
        const logoPath = `images/${logoTeam}_logo.png`;
        console.log('initStartupScreen: Setting logo src to', logoPath);
        logoImg.src = logoPath;
        logoImg.alt = `${CONFIG.team.toUpperCase()} Team`;
        // Fallback to SVG if PNG fails
        logoImg.onerror = function() {
            console.log('initStartupScreen: PNG failed, trying SVG');
            this.onerror = null; // Prevent infinite loop
            this.src = `images/${logoTeam}_logo.svg`;
        };
        logoImg.onload = function() {
            console.log('initStartupScreen: Logo loaded successfully');
        };
    } else {
        console.warn('initStartupScreen: Missing logoImg or logoTeam');
    }

    // Show startup section
    switchSection('startup', true);

    // Hide mode bar during startup — XACA-0164
    const modeBar = document.querySelector('.mode-bar');
    if (modeBar) modeBar.classList.add('hidden');

    // Add tap/click to skip functionality
    const startupSection = document.querySelector('.startup-section');
    if (startupSection) {
        startupSection.style.cursor = 'pointer';
        startupSection.addEventListener('click', skipStartup);
    }

    // Get elements
    const initText = document.getElementById('startup-init-text');
    const dataScroll = document.getElementById('startup-data-scroll');
    const progressBar = document.getElementById('startup-progress-bar');

    // Initialize data scroll with random lines
    // Calculate max lines based on viewport (roughly 20px per line)
    const scrollHeight = dataScroll?.offsetHeight || 300;
    const maxLines = Math.max(12, Math.floor(scrollHeight / 18));
    let messageIndex = 0;

    // Data scroll interval - adds new lines rapidly
    const dataInterval = setInterval(() => {
        if (startupSkipped) return;
        const line = document.createElement('div');
        line.className = 'data-line';

        // Mix random data with status messages
        if (messageIndex < STARTUP_MESSAGES.length && Math.random() > 0.6) {
            line.textContent = `[OK] ${STARTUP_MESSAGES[messageIndex]}`;
            line.style.color = 'var(--lcars-peach)';
            messageIndex++;
        } else {
            line.textContent = generateDataLine();
        }

        dataScroll.appendChild(line);

        // Keep only last N lines visible
        while (dataScroll.children.length > maxLines) {
            dataScroll.removeChild(dataScroll.firstChild);
        }

        // Auto-scroll to bottom
        dataScroll.scrollTop = dataScroll.scrollHeight;
    }, 80); // New line every 80ms
    startupTimers.push(dataInterval);

    // Progress bar animation
    let progress = 0;
    const progressInterval = setInterval(() => {
        if (startupSkipped) return;
        progress += Math.random() * 8 + 2; // Random increment 2-10%
        if (progress > 100) progress = 100;
        progressBar.style.width = `${progress}%`;
    }, 100);
    startupTimers.push(progressInterval);

    // Update init text periodically
    let textPhase = 0;
    const textMessages = [
        'INITIALIZING LCARS INTERFACE',
        'LOADING SUBSYSTEMS',
        'ESTABLISHING CONNECTIONS',
        'INTERFACE READY'
    ];
    const textInterval = setInterval(() => {
        if (startupSkipped) return;
        textPhase++;
        if (textPhase < textMessages.length) {
            initText.textContent = textMessages[textPhase];
        }
    }, 500);
    startupTimers.push(textInterval);

    // After delay, clean up and transition
    const completionTimeout = setTimeout(() => {
        if (startupSkipped) return;

        clearInterval(dataInterval);
        clearInterval(progressInterval);
        clearInterval(textInterval);

        progressBar.style.width = '100%';
        initText.textContent = 'INTERFACE READY';

        // Brief pause then transition
        setTimeout(() => {
            const targetSection = loadSavedSection();
            switchSection(targetSection);
        }, 300);
    }, STARTUP_DELAY - 300);
    startupTimers.push(completionTimeout);
}

// ═══════════════════════════════════════════════════════════════════════════════
// AUTO-REFRESH
// ═══════════════════════════════════════════════════════════════════════════════

// Track if refresh is paused (e.g., during modal editing)
let refreshPaused = false;

function startAutoRefresh() {
    if (refreshTimer) {
        clearInterval(refreshTimer);
    }

    if (CONFIG.autoRefresh) {
        refreshTimer = setInterval(() => {
            // Skip refresh if paused (modal is open)
            if (!refreshPaused) {
                loadBoardData();
            }
        }, CONFIG.refreshInterval);
    }
}

function stopAutoRefresh() {
    if (refreshTimer) {
        clearInterval(refreshTimer);
        refreshTimer = null;
    }
}

/**
 * Pause auto-refresh while a modal is open
 * Call this when opening any modal/popup
 */
function pauseAutoRefresh() {
    refreshPaused = true;
    console.log('[LCARS] Auto-refresh paused (modal open)');
}

/**
 * Resume auto-refresh after modal is closed
 * Call this when closing any modal/popup
 */
function resumeAutoRefresh() {
    refreshPaused = false;
    console.log('[LCARS] Auto-refresh resumed');
}

// Handle tab visibility changes - browsers throttle timers in background tabs
function handleVisibilityChange() {
    if (document.visibilityState === 'visible') {
        console.log('LCARS: Tab visible - refreshing data');
        loadBoardData();
        // Restart the timer to ensure consistent intervals
        startAutoRefresh();
    } else {
        console.log('LCARS: Tab hidden - timer may be throttled');
    }
}

// Register visibility change listener
document.addEventListener('visibilitychange', handleVisibilityChange);

// ═══════════════════════════════════════════════════════════════════════════════
// COMMAND INTERFACE
// ═══════════════════════════════════════════════════════════════════════════════

const COMMANDS = [
    // ═══════════════════════════════════════════════════════════════════════════════
    // WORKFLOW - Core progression: plan → code → test → commit → pr → done
    // ═══════════════════════════════════════════════════════════════════════════════
    { section: 'kanban', cmd: 'kb-plan', color: 'ready', cat: 'Workflow', short: 'Start planning',
      usage: 'kb-plan "task description"',
      desc: 'Begin planning a new task. This command initializes your workflow by setting your terminal window to PLANNING status and recording what you intend to work on. The task description appears on the kanban board and in the LCARS status display. Use descriptive text that helps others understand your current focus.',
      examples: [
        'kb-plan "Implement user authentication flow"',
        'kb-plan "Fix crash on app launch - issue #42"',
        'kb-plan "Refactor database connection pooling"'
      ]
    },
    { section: 'kanban', cmd: 'kb-code', color: 'coding', cat: 'Workflow', short: 'Move to coding',
      usage: 'kb-code',
      desc: 'Transition from planning to active coding. This moves your window to the CODING column on the kanban board, indicating you are actively writing code. Your task description is preserved. Use this when you have finished planning and are ready to implement. The status history tracks your progression through workflow stages.',
      examples: ['kb-code']
    },
    { section: 'kanban', cmd: 'kb-test', color: 'testing', cat: 'Workflow', short: 'Move to testing',
      usage: 'kb-test',
      desc: 'Move to testing phase. Sets your status to TESTING, indicating you are running tests, performing QA, or validating your implementation. Use this when code is written and you are verifying correctness. The kanban board updates to show your window in the testing column.',
      examples: ['kb-test']
    },
    { section: 'kanban', cmd: 'kb-commit', color: 'commit', cat: 'Workflow', short: 'Move to commit',
      usage: 'kb-commit',
      desc: 'Prepare to commit your changes. Sets status to COMMIT, indicating you are staging files, writing commit messages, or preparing a pull request. This is the final active stage before completing a task. Your git branch and modified file count are displayed in the status details.',
      examples: ['kb-commit']
    },
    { section: 'kanban', cmd: 'kb-pr', color: 'pr_review', cat: 'Workflow', short: 'Move to PR review',
      usage: 'kb-pr',
      desc: 'Move your task to PR Review status. Sets your window status to PR_REVIEW, indicating your code has been committed and a pull request is awaiting review. Use this after pushing your branch and creating a PR.',
      examples: ['kb-pr']
    },
    { section: 'kanban', cmd: 'kb-done', color: 'complete', cat: 'Workflow', short: 'Complete task',
      usage: 'kb-done [--force]',
      desc: 'Mark your current task as completed. For items with subitems, all subitems must be completed first (or use --force to bypass). The window returns to an untracked state. Use when work is finished and ready for review or merged.',
      examples: [
        'kb-done                    # Complete (validates subitems)',
        'kb-done --force            # Skip subitem validation',
        'kb-done XIOS-0001 --force  # Force complete specific item'
      ]
    },

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONTROLS - Pause, resume, stop, clear
    // ═══════════════════════════════════════════════════════════════════════════════
    { section: 'kanban', cmd: 'kb-pause', color: 'ready', cat: 'Controls', short: 'Pause with reason',
      usage: 'kb-pause "reason"',
      desc: 'Pause your current task with a specified reason. This moves the window to the PAUSED column on the kanban board. The pause reason is displayed in the status. Use when waiting on dependencies, reviews, or external resources.',
      examples: [
        'kb-pause "Waiting for API access"',
        'kb-pause "Pending design review"',
        'kb-pause "Dependency on ME-123"'
      ]
    },
    { section: 'kanban', cmd: 'kb-resume', color: 'coding', cat: 'Controls', short: 'Resume task',
      usage: 'kb-resume',
      desc: 'Resume a paused task. This clears the pause reason and returns the window to its previous workflow status. Use when the reason for pausing has been resolved and you can continue work.',
      examples: ['kb-resume']
    },
    { section: 'kanban', cmd: 'kb-stop-working', color: 'ready', cat: 'Controls', short: 'Stop working',
      usage: 'kb-stop-working',
      desc: 'Stop working on the current task but keep it in your workflow. Unlike kb-done (which completes) or kb-clear (which abandons), this pauses work while preserving your progress and task context. Useful when switching to higher-priority work.',
      examples: ['kb-stop-working']
    },
    { section: 'kanban', cmd: 'kb-clear', color: 'ready', cat: 'Controls', short: 'Clear window',
      usage: 'kb-clear',
      desc: 'Remove your window from the kanban board without marking work as complete. Use this to abandon a task, clear a stale entry, or reset your window state. Unlike kb-done, this does not imply successful completion. The window becomes untracked until you run kb-plan again.',
      examples: ['kb-clear']
    },
    { section: 'kanban', cmd: 'kb-block', color: 'ready', cat: 'Controls', short: '(deprecated)',
      usage: 'kb-block "reason"',
      desc: 'DEPRECATED: Use kb-pause instead. This command still works but displays a deprecation warning.',
      examples: ['kb-pause "reason" (use this instead)']
    },
    { section: 'kanban', cmd: 'kb-unblock', color: 'coding', cat: 'Controls', short: '(deprecated)',
      usage: 'kb-unblock',
      desc: 'DEPRECATED: Use kb-resume instead. This command still works but displays a deprecation warning.',
      examples: ['kb-resume (use this instead)']
    },

    // ═══════════════════════════════════════════════════════════════════════════════
    // BACKLOG - Mission backlog management
    // ═══════════════════════════════════════════════════════════════════════════════
    { section: 'kanban', cmd: 'kb-backlog', color: 'planning', cat: 'Backlog', short: 'Manage backlog',
      usage: 'kb-backlog <command> [args]',
      desc: 'Manage the mission backlog. The backlog holds tasks waiting to be worked on, sorted by priority. Use this to add upcoming work, review pending tasks, update priorities, manage subitems, or remove items that are no longer needed.',
      subcommands: [
        { sub: 'add "task" [priority] [desc] [jira] [os]', desc: 'Add new task. Priority: low/med/high/critical. OS: iOS/Android/Firebase.' },
        { sub: 'list', desc: 'Display all backlog items with index numbers and priorities.' },
        { sub: 'change <idx> ["title"] [priority]', desc: 'Modify title and/or priority of existing item.' },
        { sub: 'remove <idx>', desc: 'Delete item from backlog permanently.' },
        { sub: 'priority <idx> [priority]', desc: 'View or set priority for an item.' },
        { sub: 'jira <idx> [id]', desc: 'View, set, or clear (-) JIRA ID for an item.' },
        { sub: 'github <idx> [ref]', desc: 'View, set, or clear (-) GitHub issue (#123 or owner/repo#123).' },
        { sub: 'desc <idx> [text]', desc: 'View, set, or clear (-) description for an item.' },
        { sub: 'tag <idx> [add|rm|clear] [tags]', desc: 'Manage tags (clickable in LCARS UI).' },
        { sub: 'due <idx> [YYYY-MM-DD]', desc: 'View, set, or clear due date.' },
        { sub: 'toggle <idx>', desc: 'Toggle collapsed/expanded state for items with subitems.' }
      ],
      examples: [
        'kb-backlog add "Implement dark mode" high',
        'kb-backlog priority 0 critical',
        'kb-backlog tag 0 add iOS feature',
        'kb-backlog due 0 2026-01-25'
      ]
    },
    { section: 'kanban', cmd: 'kb-backlog sub', color: 'coding', cat: 'Backlog', short: 'Manage subitems',
      usage: 'kb-backlog sub <command> <parent-idx|subitem-id> [args]',
      desc: 'Manage hierarchical subitems within backlog items. Subitems break down complex tasks into smaller trackable pieces. Each subitem can have its own JIRA/GitHub links and tracks work time.',
      subcommands: [
        { sub: 'add <idx> "title" [jira] [os]', desc: 'Add subitem to parent. Optional JIRA ID and OS tag.' },
        { sub: 'list <idx>', desc: 'List all subitems for parent item.' },
        { sub: 'start <subitem-id>', desc: 'Start working on subitem (tracks time & worktree).' },
        { sub: 'done <subitem-id>', desc: 'Mark subitem completed (captures work time).' },
        { sub: 'stop <subitem-id>', desc: 'Stop working without completing (captures time).' },
        { sub: 'todo <idx> <sub-idx>', desc: 'Mark subitem as todo (○).' },
        { sub: 'remove <idx> <sub-idx>', desc: 'Remove subitem from parent.' },
        { sub: 'priority <idx> <sub-idx> [priority]', desc: 'Set subitem priority.' },
        { sub: 'jira <idx> <sub-idx> <id>', desc: 'Set JIRA ID for subitem.' },
        { sub: 'github <idx> <sub-idx> <ref>', desc: 'Set GitHub issue for subitem.' },
        { sub: 'tag <idx> <sub-idx> [add|rm|clear] [tags]', desc: 'Manage subitem tags.' },
        { sub: 'due <idx> <sub-idx> [YYYY-MM-DD]', desc: 'Set subitem due date.' }
      ],
      examples: [
        'kb-backlog sub add 0 "Design API schema"',
        'kb-backlog sub start XIOS-0001-001',
        'kb-backlog sub done XIOS-0001-001',
        'kb-backlog sub stop XIOS-0001-001'
      ]
    },
    { section: 'kanban', cmd: 'kb-pick', color: 'planning', cat: 'Backlog', short: 'Pick item',
      usage: 'kb-pick <item-id>',
      desc: 'Pick a task from the backlog and mark it as active. Sets your window to work on the selected item. Does not create a worktree or launch Claude. Use kb-run for full task launch with worktree.',
      examples: [
        'kb-backlog list   # View available tasks',
        'kb-pick XIOS-0001 # Pick and start working'
      ]
    },
    { section: 'kanban', cmd: 'kb-run', color: 'planning', cat: 'Backlog', short: 'Run with Claude',
      usage: 'kb-run <item-id>',
      desc: 'Launch Claude Code with full task context from a backlog item. Automatically creates a dedicated git worktree, sets up the working environment, and provides Claude with task details, subitems, and tracking instructions. This is the recommended way to start work on complex tasks.',
      examples: [
        'kb-backlog list   # View available tasks',
        'kb-run XIOS-0001  # Launch Claude with task context'
      ]
    },

    // ═══════════════════════════════════════════════════════════════════════════════
    // TASKS - Task description and status management
    // ═══════════════════════════════════════════════════════════════════════════════
    { section: 'kanban', cmd: 'kb-task', color: 'coding', cat: 'Tasks', short: 'Set task',
      usage: 'kb-task "description"',
      desc: 'Update your task description without changing workflow status. Use this to refine or clarify what you are working on, add detail as scope becomes clearer, or correct a typo in your original description. The kanban board and LCARS display update immediately.',
      examples: [
        'kb-task "Auth flow - adding OAuth2 support"',
        'kb-task "Issue #42 - root cause identified, implementing fix"'
      ]
    },
    { section: 'kanban', cmd: 'kb-status', color: 'planning', cat: 'Tasks', short: 'Set status',
      usage: 'kb-status <status>',
      desc: 'Set your workflow status directly to any valid state. Useful for jumping between stages or correcting status. Valid values: ready, planning, coding, testing, commit. The status history will record this transition.',
      examples: [
        'kb-status planning',
        'kb-status coding',
        'kb-status testing',
        'kb-status commit'
      ]
    },

    // ═══════════════════════════════════════════════════════════════════════════════
    // WORKTREE - Git worktree linking for backlog items
    // ═══════════════════════════════════════════════════════════════════════════════
    { section: 'kanban', cmd: 'kb-link-worktree', color: 'coding', cat: 'Worktree', short: 'Link worktree',
      usage: 'kb-link-worktree <item-id>',
      desc: 'Link the current git worktree to a backlog item without starting active work. This creates an association between the worktree and the task for tracking purposes. Useful when setting up worktrees in advance or for the git-worktree skill integration.',
      examples: [
        'kb-link-worktree XIOS-0001'
      ]
    },
    { section: 'kanban', cmd: 'kb-unlink-worktree', color: 'ready', cat: 'Worktree', short: 'Unlink worktree',
      usage: 'kb-unlink-worktree <item-id>',
      desc: 'Remove the worktree association from a backlog item. This clears the worktree path and branch information stored with the task. Use when cleaning up completed work or reassigning worktrees.',
      examples: [
        'kb-unlink-worktree XIOS-0001'
      ]
    },

    // ═══════════════════════════════════════════════════════════════════════════════
    // DISPLAY - View status and board information
    // ═══════════════════════════════════════════════════════════════════════════════
    { section: 'kanban', cmd: 'kb-my-status', color: 'ready', cat: 'Display', short: 'Window status',
      usage: 'kb-my-status',
      desc: 'Display detailed status information for your current terminal window. Shows: current workflow status, task description, worktree path, git branch, modified file count, lines added/deleted, time in current status, and full status history.',
      examples: ['kb-my-status']
    },
    { section: 'kanban', cmd: 'kb-show', color: 'coding', cat: 'Display', short: 'Show board',
      usage: 'kb-show',
      desc: 'Render the full kanban board in your terminal. Displays all active windows organized by workflow status (Ready, Planning, Coding, Testing, Commit, PR Review). Each entry shows the terminal name, developer, task description, and time in status.',
      examples: ['kb-show']
    },
    { section: 'kanban', cmd: 'kb-watch', color: 'testing', cat: 'Display', short: 'Watch board',
      usage: 'kb-watch [interval]',
      desc: 'Continuously watch the kanban board with auto-refresh. Displays the board in your terminal and refreshes at the specified interval (default 5 seconds). Press Ctrl+C to stop.',
      examples: [
        'kb-watch      # Watch with 5s refresh',
        'kb-watch 10   # Watch with 10s refresh'
      ]
    },
    { section: 'kanban', cmd: 'kb-help', color: 'complete', cat: 'Display', short: 'Show help',
      usage: 'kb-help [command]',
      desc: 'Display help information for kanban commands. Without arguments, shows a summary of all available commands. With a command name, shows detailed usage for that specific command.',
      examples: [
        'kb-help           # Show all commands',
        'kb-help kb-plan   # Detailed help for kb-plan'
      ]
    },

    // ═══════════════════════════════════════════════════════════════════════════════
    // SERVER - LCARS server management
    // ═══════════════════════════════════════════════════════════════════════════════
    { section: 'kanban', cmd: 'kb-restart', color: 'testing', cat: 'Server', short: 'Restart server',
      usage: 'kb-restart',
      desc: 'Restart the LCARS kanban server for the current team. Auto-detects team from tmux session, stops any existing server, starts a fresh instance, and verifies health. Use when the LCARS UI is unresponsive or showing stale data.',
      examples: ['kb-restart']
    },
    { section: 'kanban', cmd: 'lcars-status', color: 'ready', cat: 'Server', short: 'Check all servers',
      usage: 'lcars-status',
      desc: 'Check the health status of all LCARS servers without restarting. Shows which team servers are healthy, unhealthy, or inactive. Quick diagnostic to verify server availability.',
      examples: ['lcars-status']
    },
    { section: 'kanban', cmd: 'lcars-health', color: 'coding', cat: 'Server', short: 'Health & auto-restart',
      usage: 'lcars-health',
      desc: 'Check all LCARS servers and auto-restart any that are unhealthy. Only restarts servers for teams with active tmux sessions. Use for automated recovery of crashed servers.',
      examples: ['lcars-health']
    },
    { section: 'kanban', cmd: 'lcars-logs', color: 'planning', cat: 'Server', short: 'View logs',
      usage: 'lcars-logs [lines]',
      desc: 'View recent LCARS health check logs. Shows server start/stop events, health check results, and any errors. Default shows last 50 lines.',
      examples: [
        'lcars-logs       # Last 50 lines',
        'lcars-logs 100   # Last 100 lines'
      ]
    },
    { section: 'kanban', cmd: 'kb-ui', color: 'planning', cat: 'Server', short: 'Start UI server',
      usage: 'kb-ui [port]',
      desc: 'Launch the LCARS web interface server. Starts a local HTTP server serving the LCARS UI on the specified port (default 8080). The web interface provides a visual kanban board, team status, and real-time updates.',
      examples: [
        'kb-ui       # Start on port 8080',
        'kb-ui 3000  # Start on port 3000'
      ]
    },
    { section: 'kanban', cmd: 'kb-browser', color: 'coding', cat: 'Server', short: 'Open in browser',
      usage: 'kb-browser [port]',
      desc: 'Open the LCARS web interface in your default browser. If the server is not running, it will be started automatically on the specified port.',
      examples: [
        'kb-browser       # Open on default port',
        'kb-browser 3000  # Open on port 3000'
      ]
    },

    // ═══════════════════════════════════════════════════════════════════════════════
    // WORKTREE COMMANDS - Git worktree management for parallel development
    // ═══════════════════════════════════════════════════════════════════════════════

    // Project Selection
    { section: 'worktree', cmd: 'wt-project', color: 'planning', cat: 'Project', short: 'Switch project',
      usage: 'wt-project <project>',
      desc: 'Switch between different project worktree contexts. Sets up the environment variables for the selected project including base directory, worktree directory, and main branch. Required before using other wt-* commands.',
      examples: [
        'wt-project ios        # Switch to iOS project',
        'wt-project firebase   # Switch to Firebase project',
        'wt-project android    # Switch to Android project',
        'wt-project freelance  # Switch to Freelance project',
        'wt-project academy    # Switch to Academy project',
        'wt-project command    # Switch to Command project',
        'wt-project status     # Show current project details'
      ]
    },

    // Creating & Switching
    { section: 'worktree', cmd: 'wt-new', color: 'coding', cat: 'Create', short: 'Create worktree',
      usage: 'wt-new <name> [type]',
      desc: 'Create a new git worktree with an associated branch. Automatically generates a branch name based on the worktree name and optional type prefix (feature, bugfix, hotfix, refactor). The worktree is created in the project worktree directory.',
      examples: [
        'wt-new booking-flow           # Creates feature/booking-flow',
        'wt-new login-fix bugfix       # Creates bugfix/login-fix',
        'wt-new auth-refactor refactor # Creates refactor/auth-refactor'
      ]
    },
    { section: 'worktree', cmd: 'wt', color: 'ready', cat: 'Navigate', short: 'Switch worktree',
      usage: 'wt <name>',
      desc: 'Switch to an existing worktree by name. Changes directory to the worktree and updates the CURRENT_WORKTREE environment variable. Use wt-list to see available worktrees.',
      examples: [
        'wt booking-flow   # Switch to booking-flow worktree',
        'wt login-fix      # Switch to login-fix worktree'
      ]
    },
    { section: 'worktree', cmd: 'wt-dev', color: 'commit', cat: 'Navigate', short: 'Go to main repo',
      usage: 'wt-dev',
      desc: 'Switch to the main repository (DEV/main/develop branch). Exits any worktree and returns to the primary development directory. Useful for reviewing changes across branches or preparing releases.',
      examples: ['wt-dev']
    },

    // Information
    { section: 'worktree', cmd: 'wt-list', color: 'testing', cat: 'Info', short: 'List worktrees',
      usage: 'wt-list',
      desc: 'List all worktrees for the current project. Shows worktree names, associated branches, and paths. Use this to see available worktrees before switching.',
      examples: ['wt-list']
    },
    { section: 'worktree', cmd: 'wt-status', color: 'coding', cat: 'Info', short: 'Show status',
      usage: 'wt-status',
      desc: 'Show detailed status of all worktrees for the current project. Displays git status, uncommitted changes, branch tracking information, and sync state for each worktree.',
      examples: ['wt-status']
    },
    { section: 'worktree', cmd: 'wt-current', color: 'ready', cat: 'Info', short: 'Current info',
      usage: 'wt-current [mode]',
      desc: 'Show information about the current worktree. Displays worktree path, branch name, tracking status, and recent commits. Use with mode argument for specific output format.',
      examples: [
        'wt-current        # Full status',
        'wt-current short  # Brief output'
      ]
    },

    // Syncing
    { section: 'worktree', cmd: 'wt-sync', color: 'planning', cat: 'Sync', short: 'Sync current',
      usage: 'wt-sync',
      desc: 'Sync the current worktree with the main branch. Fetches latest changes from remote and merges or rebases the main branch into your current branch. Helps keep your feature branch up to date.',
      examples: ['wt-sync']
    },
    { section: 'worktree', cmd: 'wt-sync-all', color: 'testing', cat: 'Sync', short: 'Sync all',
      usage: 'wt-sync-all',
      desc: 'Sync all worktrees with the main branch. Iterates through all project worktrees and syncs each one with the latest main branch. Useful for keeping multiple feature branches current.',
      examples: ['wt-sync-all']
    },

    // Cleanup
    { section: 'worktree', cmd: 'wt-finish', color: 'commit', cat: 'Cleanup', short: 'Finish worktree',
      usage: 'wt-finish [name]',
      desc: 'Finish and clean up a worktree after work is complete. Removes the worktree directory and optionally deletes the associated branch. Use when you have manually merged or abandoned a branch.',
      examples: [
        'wt-finish                # Finish current worktree',
        'wt-finish booking-flow   # Finish specific worktree'
      ]
    },
    { section: 'worktree', cmd: 'wt-pr-merged', color: 'pr_review', cat: 'Cleanup', short: 'PR merged cleanup',
      usage: 'wt-pr-merged',
      desc: 'Clean up after a PR has been merged externally (via GitHub web or another tool). This is the recommended cleanup command when using Claude Code. Removes the worktree, deletes local and remote branches, and updates tracking.',
      examples: ['wt-pr-merged']
    },
    { section: 'worktree', cmd: 'wt-cleanup', color: 'ready', cat: 'Cleanup', short: 'Cleanup merged',
      usage: 'wt-cleanup',
      desc: 'Clean up all worktrees whose branches have been merged to main. Automatically detects merged branches and removes their associated worktrees. Run periodically to keep your worktree directory clean.',
      examples: ['wt-cleanup']
    },

    // Help
    { section: 'worktree', cmd: 'wt-help', color: 'complete', cat: 'Help', short: 'Show help',
      usage: 'wt-help',
      desc: 'Display comprehensive help for all worktree commands. Shows command syntax, examples, project main branches, and available aliases.',
      examples: ['wt-help']
    },

    // ═══════════════════════════════════════════════════════════════════════════════
    // MISCELLANEOUS COMMANDS - Claude Code launchers and utilities
    // ═══════════════════════════════════════════════════════════════════════════════

    { section: 'miscellaneous', cmd: 'cc', color: 'planning', cat: 'Claude', short: 'Launch Claude Code',
      usage: 'cc [args]',
      desc: 'Context-aware Claude Code launcher. Automatically detects your terminal context (SESSION_TYPE and SESSION_NAME) and loads the appropriate AI persona/prompt. If not in a configured terminal, launches basic Claude Code without a persona. Bypasses permission prompts for streamlined workflow.',
      examples: [
        'cc                    # Launch with auto-detected persona',
        'cc "Fix the bug"      # Launch with initial prompt'
      ]
    },
    { section: 'miscellaneous', cmd: 'cc-<team>-<location>', color: 'coding', cat: 'Claude', short: 'Team-specific Claude',
      usage: 'cc-<team>-<location>',
      desc: 'Launch Claude Code with a specific team persona. Each command loads a specialized system prompt tailored to that team and terminal role. Teams: ios, firebase, android, freelance, mainevent, dns, academy, command. Locations vary by team (bridge, engineering, sickbay, etc.).',
      subcommands: [
        { sub: 'cc-ios-bridge', desc: 'iOS Lead Feature Development (Captain Picard)' },
        { sub: 'cc-ios-engineering', desc: 'iOS Release Engineer (Geordi La Forge)' },
        { sub: 'cc-ios-sickbay', desc: 'iOS Bug Fix Developer (Doctor)' },
        { sub: 'cc-firebase-ops', desc: 'Firebase Release Engineer (Chief OBrien)' },
        { sub: 'cc-firebase-engineering', desc: 'Firebase Lead Feature Dev (Sisko)' },
        { sub: 'cc-android-bridge', desc: 'Android Lead Feature Dev (Kirk)' },
        { sub: 'cc-android-science', desc: 'Android Refactoring Lead (Spock)' },
        { sub: 'cc-freelance-command', desc: 'Freelance Lead Feature Dev (Archer)' },
        { sub: 'cc-academy-chancellor', desc: 'Academy Chancellor (Nahla)' },
        { sub: 'cc-command-admiral', desc: 'Command Strategic Leadership (Vance)' }
      ],
      examples: [
        'cc-ios-bridge         # Launch iOS lead developer persona',
        'cc-firebase-ops       # Launch Firebase operations persona',
        'cc-android-science    # Launch Android refactoring persona',
        'cc-academy-medical    # Launch Academy documentation (EMH)'
      ]
    },
    { section: 'miscellaneous', cmd: 'source kanban-helpers.sh', color: 'ready', cat: 'Setup', short: 'Load KB helpers',
      usage: 'source ~/dev-team/kanban-helpers.sh',
      desc: 'Load the kanban helper functions into your current shell session. This makes all kb-* commands available. Typically added to your shell profile (.zshrc) but can be sourced manually when needed.',
      examples: [
        'source ~/dev-team/kanban-helpers.sh'
      ]
    },
    { section: 'miscellaneous', cmd: 'source worktree-helpers.sh', color: 'testing', cat: 'Setup', short: 'Load WT helpers',
      usage: 'source ~/dev-team/worktree-helpers.sh',
      desc: 'Load the worktree helper functions into your current shell session. This makes all wt-* commands available. Typically added to your shell profile (.zshrc) but can be sourced manually when needed.',
      examples: [
        'source ~/dev-team/worktree-helpers.sh'
      ]
    }
];

// Track active command section (default to miscellaneous)
let activeCommandSection = 'miscellaneous';

function renderCommands(section = activeCommandSection) {
    const container = document.getElementById('commands-grid');
    if (!container) return;

    // Update active section state
    activeCommandSection = section;

    // Set data attribute for section-specific CSS styling
    container.dataset.section = section;

    // Update section pill active states
    document.querySelectorAll('.command-section-pill').forEach(pill => {
        pill.classList.toggle('active', pill.dataset.commandSection === section);
    });

    // Clear command detail when switching sections
    const detail = document.getElementById('command-detail');
    if (detail) {
        detail.innerHTML = '<div class="detail-placeholder">Select a command to see details</div>';
    }

    container.innerHTML = '';

    // Filter commands by active section
    const filteredCommands = COMMANDS.filter(cmd => cmd.section === section);

    filteredCommands.forEach((cmd) => {
        // Find the original index in COMMANDS array for showCommandDetail
        const originalIndex = COMMANDS.indexOf(cmd);

        const item = document.createElement('div');
        item.className = 'command-item';
        item.dataset.index = originalIndex;

        const btn = document.createElement('div');
        btn.className = `command-btn ${cmd.color}`;
        btn.textContent = cmd.cmd;

        const desc = document.createElement('span');
        desc.className = 'command-desc';
        desc.textContent = cmd.short;

        item.appendChild(btn);
        item.appendChild(desc);

        item.addEventListener('click', () => showCommandDetail(originalIndex));

        container.appendChild(item);
    });
}

function showCommandDetail(index) {
    const cmd = COMMANDS[index];
    const detail = document.getElementById('command-detail');
    if (!detail || !cmd) return;

    // Update active state
    document.querySelectorAll('.command-item').forEach(el => el.classList.remove('active'));
    document.querySelector(`.command-item[data-index="${index}"]`)?.classList.add('active');

    let html = `
        <div class="detail-cmd">${cmd.cmd}</div>
        <div class="detail-usage">${cmd.usage}</div>
        <div class="detail-desc">${cmd.desc}</div>
    `;

    // Render subcommands if present
    if (cmd.subcommands && cmd.subcommands.length > 0) {
        html += '<div class="detail-subcommands"><div class="detail-section-title">SUBCOMMANDS</div>';
        cmd.subcommands.forEach(sub => {
            html += `
                <div class="subcommand-row">
                    <span class="subcommand-usage">${cmd.cmd} ${sub.sub}</span>
                    <span class="subcommand-desc">${sub.desc}</span>
                </div>
            `;
        });
        html += '</div>';
    }

    // Render examples if present
    if (cmd.examples && cmd.examples.length > 0) {
        html += '<div class="detail-examples"><div class="detail-section-title">EXAMPLES</div>';
        cmd.examples.forEach(ex => {
            html += `<div class="example-row">${ex}</div>`;
        });
        html += '</div>';
    }

    html += `<div class="detail-category">Category: ${cmd.cat}</div>`;

    detail.innerHTML = html;
}

// ═══════════════════════════════════════════════════════════════════════════════
// RELEASES DASHBOARD
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * List the platforms holding a release back from completion.
 *
 * XACA-1000-011: used to explain WHY the ARCHIVE button is unavailable. Returns
 * `[{name, environment}]` for every declared platform not yet at PROD, in the
 * order the release declares them. An empty array means either "complete" or
 * "no platforms at all" — callers distinguish via isReleaseComplete().
 *
 * @param {Object} release - Release object with platforms dict
 * @returns {Array<{name: string, environment: string}>} blocking platforms
 */
function getIncompletePlatforms(release) {
    const platforms = (release && release.platforms) || {};
    if (typeof platforms !== 'object' || Array.isArray(platforms)) {
        return [];
    }
    return Object.keys(platforms).reduce((acc, name) => {
        const platform = platforms[name];
        const env = (platform && typeof platform === 'object' && platform.environment) || 'unknown';
        if (env !== 'PROD') {
            acc.push({ name: name, environment: env });
        }
        return acc;
    }, []);
}

/**
 * Render the ARCHIVE / UNARCHIVE control for a release card.
 *
 * XACA-1000-011 / -018: this branch previously emitted an EMPTY STRING when a
 * release was not complete — no button, no tooltip, nothing. That silence is
 * why the XACA-1000 platform-set defect went unnoticed: operators on six teams
 * could not tell "you may not archive this yet" apart from "this product has
 * no archive feature", and had nothing to search for or report. Every sibling
 * control on this card (PROMOTE / EDIT / DELETE) already renders as a DISABLED
 * button when unavailable, so the empty string was also the odd one out.
 *
 * An incomplete release now renders a disabled ARCHIVE button whose tooltip
 * names the platforms still holding it back and the environment each sits at.
 *
 * XACA-1000-013: all three states carry a `title`, matching `.release-cr-link`
 * on this same card, which has had one all along.
 *
 * @param {Object} release - Release object
 * @param {boolean} isArchived - Whether the release is currently archived
 * @returns {string} HTML for the archive/unarchive control
 */
function renderArchiveAction(release, isArchived) {
    // XACA-1000-021: jsAttrEscape, NOT escapeHtml. `id` lands inside a JS STRING
    // LITERAL within an HTML attribute -- toggleReleaseArchive('<id>') -- and
    // escapeHtml is textContent->innerHTML, which leaves ' and \ untouched. A
    // release id of  x'); alert(document.cookie); ('  therefore breaks straight
    // out of the string and executes. jsAttrEscape (XACA-0277) exists for this
    // exact sink and escapes \ and ' as well as the HTML metacharacters.
    // Three escapers, three contexts, and they are NOT interchangeable:
    //   escapeHtml    -> text content
    //   escapeAttr    -> a quoted HTML attribute value (the title= below)
    //   jsAttrEscape  -> a JS string literal inside an attribute (here)
    const id = jsAttrEscape(String((release && release.id) || ''));

    if (isArchived) {
        return '<button class="release-action-btn unarchive-btn"' +
            ' onclick="event.stopPropagation(); toggleReleaseArchive(\'' + id + '\')"' +
            ' title="Unarchive this release and return it to the active list">' +
            '<span class="action-icon">\uD83D\uDCE4</span> UNARCHIVE</button>';
    }

    if (isReleaseComplete(release)) {
        return '<button class="release-action-btn archive-btn"' +
            ' onclick="event.stopPropagation(); toggleReleaseArchive(\'' + id + '\')"' +
            ' title="Archive this release (every platform is at PROD)">' +
            '<span class="action-icon">\uD83D\uDCE6</span> ARCHIVE</button>';
    }

    // Not complete: explain what is missing rather than rendering nothing.
    const blocking = getIncompletePlatforms(release);
    const reason = blocking.length
        ? 'Archive unavailable \u2014 ' + blocking
            .map((p) => getPlatformName(p.name) + ' is at ' + p.environment + ', not PROD')
            .join('; ')
        : 'Archive unavailable \u2014 this release declares no platforms';

    // XACA-1001: escapeAttr (not jsAttrEscape) -- this id lands in a plain
    // HTML `id`/`aria-describedby` attribute value, not inside a JS string
    // literal, so the plain attribute escaper is the right one here.
    const reasonId = 'release-archive-reason-' + escapeAttr(String((release && release.id) || ''));

    // XACA-1001: guard added even though this branch is unconditionally
    // aria-disabled (there is no live call to gate here, unlike the other
    // three buttons) -- kept ONLY so the guard is uniformly present on all
    // four controls for a later test to assert against. Deliberately no
    // toggleReleaseArchive(...) call behind it: a pre-existing regression
    // test (XACA-1000-018, "incomplete state is NOT clickable") asserts this
    // markup contains no reference to that function at all.
    return '<button class="release-action-btn archive-btn" aria-disabled="true"' +
        ' onclick="event.stopPropagation(); if (this.getAttribute(\'aria-disabled\') === \'true\') return;"' +
        ' aria-describedby="' + reasonId + '"' +
        ' title="' + escapeAttr(reason) + '">' +
        '<span class="action-icon">\uD83D\uDCE6</span> ARCHIVE</button>' +
        '<span id="' + reasonId + '" class="sr-only">' + escapeHtml(reason) + '</span>';
}

/**
 * Check if a release is complete (every declared platform at PROD).
 *
 * A release is complete when it declares at least one platform and EVERY
 * platform it declares is at "PROD" - whatever those platform keys are.
 *
 * XACA-1000: this deliberately has no hardcoded platform list. It used to
 * require one of ios/android/firebase to be present, which made the predicate
 * return false for any release whose only platform key was something else
 * (Academy/Command/DNS/Finance/Legal/Medical all use "other"). Because the
 * ARCHIVE button below renders '' rather than a disabled control when this
 * returns false, those teams saw no button and no explanation. The same
 * hardcoded list caused the opposite error too - a platform outside the list
 * was skipped by the loop, so a release with ios at PROD and other at DEV
 * evaluated complete. Both directions are fixed by checking the platforms the
 * release actually has.
 *
 * Platforms at "PLANNED" are NOT complete - PLANNED !== PROD, so they block
 * completion just like DEV, QA, ALPHA, BETA, or GAMMA would (XACA-0238).
 *
 * Keep this in lockstep with is_release_complete() in lcars-ui/server.py, which
 * is the actual archive gate. The two are duplicated by necessity (no shared
 * module between the Python server and the browser bundle); if you change one,
 * change the other, or this will offer a button the API refuses - or hide one
 * it would have accepted.
 *
 * @param {Object} release - Release object with platforms dict
 * @returns {boolean} True if every declared platform is at PROD, false otherwise
 */
function isReleaseComplete(release) {
    const platforms = (release && release.platforms) || {};

    // XACA-1000-015: `platforms` must be a real object. A list or a string is
    // malformed data, not "zero platforms" — treat it as not-complete rather
    // than letting Object.keys() yield indices/characters that could never
    // match 'PROD'. The Python twin carries the same isinstance guard, so both
    // return false on the same inputs instead of one throwing and one not.
    if (typeof platforms !== 'object' || Array.isArray(platforms)) {
        return false;
    }

    // If no platforms exist at all, not complete
    const platformNames = Object.keys(platforms);
    if (platformNames.length === 0) {
        return false;
    }

    // Every declared platform must be at PROD - no platform is exempt.
    // A platform value that is not an object cannot be at PROD.
    return platformNames.every((name) => {
        const platform = platforms[name];
        return !!platform && typeof platform === 'object' && platform.environment === 'PROD';
    });
}

/**
 * Fetch and display releases
 */
async function loadReleases() {
    const dashboard = document.getElementById('releases-dashboard');
    if (!dashboard) return;

    dashboard.innerHTML = '<div class="releases-loading">Loading releases...</div>';

    // XACA-0056: Update toggle buttons to reflect current filter
    updateReleasesStatusToggle();

    try {
        // XACA-0056: Include status filter in API call
        // 'planned' and 'active' tabs both fetch non-archived releases from backend;
        // client-side filtering in displayReleases() splits them by platform state.
        const statusParam = releasesState.statusFilter === 'archived' ? 'archived' : 'active';
        // XACA-0209 round 5: tag filtering moved fully client-side — see displayReleases.
        // Fetch releases and flow config in parallel (include team for correct scoping)
        const [releasesResponse, configResponse] = await Promise.all([
            fetch(apiUrl('/api/releases?status=' + statusParam)),
            fetch(apiUrl(`/api/release-config?team=${encodeURIComponent(CONFIG.team)}`))
        ]);

        if (!releasesResponse.ok) throw new Error('Failed to fetch releases');
        const data = await releasesResponse.json();

        // Load flow config for progress calculation
        let flowConfig = null;
        let projectEnvironments = {};
        if (configResponse.ok) {
            const configData = await configResponse.json();
            flowConfig = configData.flowConfig || null;
            projectEnvironments = configData.projectEnvironments || {};
            // Update global flowConfigState
            if (flowConfig && flowConfig.stages) {
                flowConfigState.stages = flowConfig.stages;
            }
            flowConfigState.projectEnvironments = projectEnvironments;
        }

        // Update the current flow display in header
        updateCurrentFlowDisplay(flowConfig);

        displayReleases(data.releases || [], flowConfig, projectEnvironments);
    } catch (e) {
        console.log('Could not load releases:', e);
        dashboard.innerHTML = `
            <div class="releases-empty">
                <div class="releases-empty-icon">⚠</div>
                <div class="releases-empty-text">Error loading releases</div>
                <div class="releases-empty-hint">${e.message}</div>
            </div>
        `;
    }
}

/**
 * Display releases in the dashboard
 * @param {Array} releases - Array of release objects
 * @param {Object} flowConfig - Optional flow configuration (XACA-0027)
 * @param {Object} projectEnvironments - Optional per-project stage overrides (XACA-0163)
 */
function displayReleases(releases, flowConfig = null, projectEnvironments = {}) {
    const dashboard = document.getElementById('releases-dashboard');
    if (!dashboard) return;

    // XACA-0238: Client-side split for Planned vs Active tabs.
    // Backend returns all non-archived releases for both tabs; we filter here.
    // Planned: ALL platforms in PLANNED state.
    // Active:  ANY platform in DEV+ state (i.e. not ALL platforms PLANNED).
    if (releasesState.statusFilter === 'planned') {
        releases = releases.filter(r => {
            const platforms = Object.values(r.platforms || {});
            return platforms.length > 0 && platforms.every(p => (p.environment || '') === 'PLANNED');
        });
    } else if (releasesState.statusFilter === 'active') {
        releases = releases.filter(r => {
            const platforms = Object.values(r.platforms || {});
            return platforms.some(p => (p.environment || '') !== 'PLANNED');
        });
    }

    if (!releases || releases.length === 0) {
        // XACA-0056 / XACA-0238: Context-aware empty state message for all three tabs
        const filter = releasesState.statusFilter;
        const icon = filter === 'archived' ? '📁' : filter === 'planned' ? '🗓' : '📦';
        const title = filter === 'archived' ? 'No Archived Releases'
            : filter === 'planned' ? 'No Planned Releases'
            : 'No Active Releases';
        const hint = filter === 'archived' ? 'Completed releases will appear here when archived'
            : filter === 'planned' ? 'Create a release to see it here'
            : 'Promote a release platform to DEV to see it here';
        dashboard.innerHTML = `
            <div class="releases-empty">
                <div class="releases-empty-icon">${icon}</div>
                <div class="releases-empty-text">${title}</div>
                <div class="releases-empty-hint">${hint}</div>
            </div>
        `;
        return;
    }

    // XACA-0209 round 5: client-side search filter over id/title/shortTitle/description/tags.
    if (releaseSearchText) {
        releases = releases.filter(r => itemMatchesSearch(r, releaseSearchText));
        if (releases.length === 0) {
            dashboard.innerHTML = `
                <div class="releases-empty">
                    <div class="releases-empty-icon">🔍</div>
                    <div class="releases-empty-text">No releases match "${escapeHtml(releaseSearchText)}"</div>
                    <div class="releases-empty-hint">Try a different search term, or clear the filter.</div>
                </div>
            `;
            return;
        }
    }

    // XACA-0056: Sort releases
    // 1. Non-archived first, archived last
    // 2. Non-archived: sort by targetDate ascending (earliest first), fallback to shortTitle
    // 3. Archived: sort by targetDate descending (most recent first), fallback to shortTitle
    releases.sort((a, b) => {
        const aArchived = a.status === 'archived';
        const bArchived = b.status === 'archived';

        // Non-archived before archived
        if (aArchived !== bArchived) return aArchived ? 1 : -1;

        // Within same group, sort by targetDate (or shortTitle as fallback)
        const aDate = a.targetDate ? new Date(a.targetDate) : null;
        const bDate = b.targetDate ? new Date(b.targetDate) : null;

        // Both have dates - sort by date
        if (aDate && bDate) {
            // Non-archived: ascending (earliest first)
            // Archived: descending (most recent first)
            return aArchived ? (bDate - aDate) : (aDate - bDate);
        }

        // One or both missing dates - use shortTitle (or name as fallback)
        const aLabel = (a.shortTitle || a.name || '').toLowerCase();
        const bLabel = (b.shortTitle || b.name || '').toLowerCase();
        return aLabel.localeCompare(bLabel);
    });

    const html = releases.map(release => renderReleaseCard(release, flowConfig, projectEnvironments)).join('');
    dashboard.innerHTML = html;

    // XACA-0209 round 5: delegated click handler for item tag pills — set once per dashboard.
    bindItemTagClicks(dashboard);

    // XACA-0045: Check plan existence for DOCS buttons
    checkPlanDocsButtons(dashboard);

    // Update release filter dropdown with current releases
    populateReleaseFilterOptions();

    // Load items for any expanded releases (fixes perpetual "Loading items..." on tab switch)
    releasesState.expandedReleases.forEach(releaseId => {
        loadReleaseItems(releaseId);
    });
}

/**
 * Render a single release card
 * @param {Object} release - Release object
 * @param {Object} flowConfig - Optional flow configuration (XACA-0027)
 * @param {Object} projectEnvironments - Optional per-project stage overrides (XACA-0163)
 */
function renderReleaseCard(release, flowConfig = null, projectEnvironments = {}) {
    // XACA-1005-001 (8th round, PR #795 gate, BLOCKING, reviewer-verified):
    // release.type reaches TWO sinks raw -- this CLASS-ATTRIBUTE position and
    // typeBadge below (attribute AND element content). release.type is in
    // server.py handle_update_release's allowed_fields with
    // `release[field] = post_data[field]` and NO validation. Live PoC
    // produced a real onmouseover= event-handler attribute and a live
    // <IMG ... ONERROR=...> element; .toUpperCase() below is not a
    // mitigation, it just uppercases the payload before it executes. Fixed:
    // escapeAttr() here (class-attribute position), escapeAttr()+escapeHtml()
    // at typeBadge below (attribute vs content, not one escaper for both --
    // the point of this ticket).
    const typeClass = release.type ? `type-${escapeAttr(release.type)}` : '';
    // XACA-1005-001 (6th round, PR #795 gate): found while checking whether
    // formatDate()'s catch-and-return-raw pattern is a CLASS, not an
    // instance -- formatTargetDate() (lcars.js ~11756) has the IDENTICAL
    // shape: `catch (e) { return dateStr; }`, reached via the SAME
    // parseLocalDate()-throws-on-non-string mechanism. release.targetDate
    // is set via server.py's handle_update_release, whose `allowed_fields`
    // list DOES include 'targetDate' -- but that list only restricts which
    // KEYS may be set, not the VALUE TYPE of any of them (unlike XACA-1020's
    // handle_update_item, which restricts neither), so a non-string
    // targetDate (array / hostile-toString object) is reachable through
    // this different, allowlisted endpoint. Verified live against the real
    // formatTargetDate() body before fixing (see the regression suite).
    // Escaped at the interpolation site below (verified single consumer of
    // this local via grep) rather than here at construction, matching this
    // ticket's established pattern.
    const targetDate = release.targetDate ? formatTargetDate(release.targetDate) : 'No target';
    const isExpanded = releasesState.expandedReleases.has(release.id);
    const expandedClass = isExpanded ? 'expanded' : '';
    // XACA-0056-005: Detect archived status
    const isArchived = release.status === 'archived';
    const archivedClass = isArchived ? 'archived' : '';

    // XACA-1001: reason text for the inert PROMOTE/EDIT/DELETE controls when
    // archived, surfaced via both `title` (sighted hover) and
    // `aria-describedby` (screen reader) -- matching the voice of the
    // ARCHIVE-button reason composed in renderArchiveAction() below.
    const promoteReason = 'Promote unavailable — this release is archived. Unarchive it to promote.';
    const editReason = 'Edit unavailable — this release is archived. Unarchive it to edit.';
    const deleteReason = 'Delete unavailable — this release is archived. Unarchive it to delete.';
    const safeReleaseId = escapeAttr(release.id);

    // Get enabled environments based on flowConfig (XACA-0027, XACA-0163)
    const enabledEnvironments = getReleaseEnvironments(release, flowConfig, projectEnvironments);

    // Build platform progress rows with progress based on enabled stages
    let totalProgress = 0;
    let platformCount = 0;

    const platformsHtml = Object.entries(release.platforms || {}).map(([key, platform]) => {
        // XACA-1005-001 (8th round, PR #795 gate, BLOCKING, reviewer-verified):
        // this is a SIBLING KEY of platform.version, fixed one round ago six
        // lines below this -- same release.platforms provenance reasoning
        // applies. Reachable via POST /api/releases with an unvalidated list
        // that omits "PLANNED", so the initial value (server.py ~7551,
        // ~7577-7588) becomes whatever the client sent, with no enum check.
        // currentEnv reaches TWO sinks: envClass below (class-attribute
        // position, via .toLowerCase() on the RAW value first -- transform
        // before escape, matching the truncateTitle() composition-order
        // lesson from an earlier round, so case transforms never operate on
        // already-escaped entity text) and the platform-env span's element
        // content further down (escaped independently there, its own sink).
        const currentEnv = platform.environment || 'DEV';
        const envClass = `env-${escapeAttr(currentEnv.toLowerCase())}`;

        // Calculate progress based on position in enabled environments (XACA-0027)
        const currentIdx = enabledEnvironments.indexOf(currentEnv);
        const envProgress = currentIdx >= 0
            ? Math.round((currentIdx / (enabledEnvironments.length - 1)) * 100)
            : 0;

        totalProgress += envProgress;
        platformCount++;

        const progressComplete = envProgress >= 100 ? 'complete' : '';

        // XACA-0658-004: Render gateStatus badge (pass/fail/skip) + stale hint.
        const gs = platform.gateStatus;
        let gateHtml = '';
        if (gs && gs.result) {
            const gsResult    = gs.result;   // 'pass' | 'fail' | 'skip'
            const gsCheckedAt = gs.checkedAt || '';
            const gsCode      = gs.codeVersion   || '';
            const gsTarget    = gs.targetVersion || '';

            // Staleness: warn when last checked > 24 h ago
            let staleMarker = '';
            if (gsCheckedAt) {
                const ageMs = Date.now() - new Date(gsCheckedAt).getTime();
                if (ageMs > 24 * 60 * 60 * 1000) {
                    staleMarker = ' <span class="gate-stale" title="Gate result is over 24 hours old — re-run kb-release-version-gate to refresh">STALE</span>';
                }
            }

            // Build human-readable tooltip
            let tooltip = `Gate: ${gsResult.toUpperCase()}`;
            if (gsCode)    tooltip += `\nCode:   ${gsCode}`;
            if (gsTarget)  tooltip += `\nTarget: ${gsTarget}`;
            if (gsCheckedAt) tooltip += `\nChecked: ${gsCheckedAt}`;
            const tooltipAttr = tooltip.replace(/"/g, '&quot;');

            const gsClass = `gate-${gsResult}`;  // gate-pass | gate-fail | gate-skip
            gateHtml = `<span class="platform-gate-badge ${gsClass}" title="${tooltipAttr}">${gsResult.toUpperCase()}${staleMarker}</span>`;
        }

        // XACA-1005-001 (7th round, PR #795 gate, BLOCKING, reviewer-verified):
        // both spans below were RAW ELEMENT CONTENT, no escaper at all.
        // getPlatformName(key) (~11779) maps a small known set of platform
        // keys ('ios'/'android'/'firebase'/'web'/'other') to display labels,
        // but falls through for any UNMAPPED key to
        // `safeKey.charAt(0).toUpperCase() + safeKey.slice(1)` -- a
        // TITLE-CASED PASSTHROUGH of the raw key, not a safe default. `key`
        // and `platform.version` both come from `release.platforms`, reached
        // through the SAME unvalidated server.py handle_update_release path
        // the targetDate fix above already depends on: its allowed_fields
        // list is key-only (no value-type validation), 'tags' gets
        // isinstance filtering three lines below it in that handler, but
        // platforms gets nothing. Verified live: a hostile platform key or
        // version string renders `<img src=x onerror=alert(1)>` as a live
        // element. Fixed at the SINK (not inside getPlatformName(), which is
        // a shared helper -- consistent with every other fix in this
        // ticket): escapeHtml(getPlatformName(key)) and
        // escapeHtml(String(platform.version || '1.0.0')) -- the extra
        // String() guards platform.version being a non-string (same
        // no-type-validation reachability as release.targetDate above), and
        // is a no-op for the ordinary string case.
        //
        // gs.result (the gate-status badge a few lines above) is
        // deliberately NOT touched here: the reviewer confirmed the
        // producing endpoint validates it to the fixed enum pass|fail|skip,
        // so it carries no untrusted text and re-escaping it would be
        // decorative.
        return `
            <div class="release-platform">
                <div class="platform-info">
                    <span class="platform-name">${escapeHtml(getPlatformName(key))}</span>
                    <span class="platform-version">${escapeHtml(String(platform.version || '1.0.0'))}</span>
                    ${gateHtml}
                </div>
                <div class="platform-progress">
                    <div class="platform-progress-bar ${progressComplete}" style="width: ${envProgress}%"></div>
                </div>
                <span class="platform-env ${envClass}">${escapeHtml(currentEnv)}</span>
            </div>
        `;
    }).join('');

    // Calculate overall release progress
    const overallProgress = platformCount > 0 ? Math.round(totalProgress / platformCount) : 0;

    // Get item count from progress if available
    const itemCount = release.progress?.total || 0;
    const completedCount = release.progress?.completed || 0;
    const cancelledCount = release.progress?.cancelled || 0;
    // XACA-0948-014: server's _calculate_release_progress also emits
    // progress.unresolved (a row whose team/board couldn't be found) "so the
    // gap is visible instead of silently green" — but nothing here read it,
    // so a release's completed/total ratio could jump (e.g. 40%→80%) with no
    // on-screen explanation, reading as unexplained data loss.
    const unresolvedCount = release.progress?.unresolved || 0;
    // A release with zero items has nothing left to do — it's 100% complete
    const itemProgress = itemCount > 0 ? Math.round((completedCount / itemCount) * 100) : 100;
    // XACA-0206-001: Surface cancelled count so users see why denominator shrank.
    // "excluded" avoids the math-additive read of a leading + sign.
    const cancelledSuffix = cancelledCount > 0 ? ` <span class="release-item-cancelled-count">(${cancelledCount} cancelled, excluded)</span>` : '';
    // XACA-0948-014: mirrors cancelledSuffix's pattern/tone. "unresolved" here
    // matches the server's statusResolution vocabulary rather than inventing
    // new wording — deliberately does NOT say "excluded" since unresolved rows
    // stay IN the total per the server comment ("never less").
    const unresolvedSuffix = unresolvedCount > 0 ? ` <span class="release-item-unresolved-count" title="${unresolvedCount} item(s) could not be resolved against a team/board and are counted as incomplete">(${unresolvedCount} unresolved)</span>` : '';

    // XACA-0056-007: Add archived badge for archived releases
    const archivedBadge = isArchived ? '<span class="archived-badge">ARCHIVED</span>' : '';

    // XACA-0056: Add type badge
    // XACA-1005-001 (8th round, PR #795 gate, BLOCKING, reviewer-verified):
    // releaseType (from release.type, same defect as typeClass above) was
    // raw at BOTH the class-attribute position AND element content below.
    // Fixed with the context-appropriate escaper at each site, not one
    // escaper for both: escapeAttr() for the attribute, escapeHtml() for
    // the content. .toUpperCase() runs on the RAW value first, then the
    // result is escaped -- uppercasing an already-escaped string risks
    // mangling a named entity's case (escapeHtml() never needs this here
    // since it only ever produces &amp;/&lt;/&gt;, but transform-then-escape
    // is the safe default order regardless, matching the truncateTitle()
    // composition-order lesson from an earlier round).
    const releaseType = release.type || 'feature';
    const typeBadge = `<span class="release-type-badge type-${escapeAttr(releaseType)}">${escapeHtml(releaseType.toUpperCase())}</span>`;

    // XACA-0209 round 5: purple tag pills on each release card — clicking a pill
    // sets the release search input (handler wired via bindItemTagClicks).
    const tagsHtml = buildItemTagsHtml(release.tags, 'release');

    // XACA-0657-005: Linked CR chips — snapshot crTitle/crId; each chip navigates
    // to the CHANGE REQ section and highlights the target CR row.
    //
    // XACA-1005-001: crTitle is interpolated TWICE below — once inside
    // title="Navigate to CR: ${crTitle}" (a QUOTED ATTRIBUTE) and once as
    // element content (${crIdEsc} — ${crTitle}). It was escaped with
    // escapeHtml() for both, which is a FALSE FIX in the attribute slot:
    // escapeHtml is textContent -> innerHTML, which per the WHATWG
    // fragment-serialization spec escapes &, U+00A0, < and > and
    // DELIBERATELY LEAVES QUOTES ALONE (see the comment above escapeAttr()).
    // A CR title of `Fix " onmouseover=alert(1) x="` — CR titles are
    // user-supplied, verified against live board data — therefore closed the
    // title="..." attribute early and injected a new onmouseover= attribute
    // onto the <button>, a hand-verified breakout (XACA-0416 found this exact
    // shape across five other client apps).
    //
    // Fixed by switching crTitle to escapeAttr() for BOTH interpolations
    // rather than introducing a second variable, because escapeAttr is a
    // SAFE SUPERSET of escapeHtml in element content, not merely a different
    // escaper: escapeAttr additionally turns a raw `"`/`'` into `&quot;`/
    // `&#39;`, and the HTML parser decodes those entities in TEXT content
    // exactly the same way it does inside an attribute value, back to the
    // literal `"`/`'` character. `&`/`<`/`>` are escaped identically by both
    // functions. So a CR title containing `'`, `"`, `&` or `<` renders
    // IDENTICALLY on screen whichever escaper produced it — escapeAttr just
    // also closes the attribute-breakout hole that escapeHtml leaves open.
    // One variable, one escaper, no second failure mode to keep in sync.
    //
    // crIdEsc (below) was independently re-checked against this same
    // reasoning: it is interpolated exactly ONCE, as `${crIdEsc} — ${crTitle}`
    // element content, and never inside an attribute — so escapeHtml remains
    // the right, and sufficient, escaper for it. Left unchanged.
    const linkedCRs = Array.isArray(release.linkedCRs) ? release.linkedCRs : [];
    const linkedCRsHtml = linkedCRs.length > 0
        ? `<div class="release-linked-crs">
                <span class="release-linked-crs-label">CHANGE REQUESTS</span>
                ${linkedCRs.map(entry => {
                    const crId    = entry.crId    ? jsAttrEscape(entry.crId)    : '';
                    const crTitle = entry.crTitle ? escapeAttr(entry.crTitle)   : escapeAttr(entry.crId || '');
                    const crIdEsc = entry.crId    ? escapeHtml(entry.crId)      : '';
                    if (!crId) return '';
                    return `<button class="release-cr-link" onclick="event.stopPropagation(); navigateToReleaseCR('${crId}')" title="Navigate to CR: ${crTitle}">${crIdEsc} — ${crTitle}</button>`;
                }).join('')}
           </div>`
        : '';

    return `
        <div class="release-card ${typeClass} ${expandedClass} ${archivedClass}" data-release-id="${release.id}">
            <div class="release-card-header" onclick="toggleReleaseExpanded('${release.id}')">
                <div class="release-card-title">
                    <span class="release-card-id" role="button" tabindex="0" title="Click to copy Release ID to clipboard" aria-label="Release ID: ${escapeHtml(release.id)}. Click to copy." onclick="event.stopPropagation(); copyToClipboard('${jsAttrEscape(release.id)}')" onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();event.stopPropagation();copyToClipboard('${jsAttrEscape(release.id)}');}">${escapeHtml(release.id)}</span> ${typeBadge}
                    <span class="release-card-name">${release.shortTitle ? escapeHtml(release.shortTitle) + ' — ' + escapeHtml(release.name) : escapeHtml(release.name)}${archivedBadge}</span>
                </div>
                <div class="release-card-header-right">
                    ${tagsHtml}
                    <div class="release-card-meta">
                        <span class="release-card-date">${escapeHtml(targetDate)}</span>
                        <span class="release-item-count">${completedCount}/${itemCount} items${cancelledSuffix}${unresolvedSuffix}</span>
                        <span class="release-card-progress">${itemProgress}%</span>
                        <span class="release-expand-icon">${isExpanded ? '▼' : '▶'}</span>
                    </div>
                </div>
            </div>
            <div class="release-card-body">
                <div class="release-platforms">
                    ${platformsHtml}
                </div>
                ${linkedCRsHtml}
            </div>
            <div class="release-card-items" id="release-items-${release.id}">
                ${isExpanded ? '<div class="release-items-loading">Loading items...</div>' : ''}
            </div>
            <div class="release-card-actions">
                <button class="release-action-btn docs" data-item-id="${release.id}" onclick="event.stopPropagation(); showPlanDocModal('${release.id}', this.getAttribute('data-retro-exists') === 'true', this.getAttribute('data-cr-exists') === 'true')" style="display:none">DOCS</button>
                <button class="release-action-btn promote-btn" onclick="event.stopPropagation(); if (this.getAttribute('aria-disabled') === 'true') return; promoteRelease('${jsAttrEscape(release.id)}')" ${isArchived ? `aria-disabled="true" aria-describedby="release-promote-reason-${safeReleaseId}" title="${escapeAttr(promoteReason)}"` : ''}>PROMOTE</button>
                ${isArchived ? `<span id="release-promote-reason-${safeReleaseId}" class="sr-only">${escapeHtml(promoteReason)}</span>` : ''}
                <button class="release-action-btn" onclick="event.stopPropagation(); viewReleaseNotes('${release.id}')">RELNOTES</button>
                <button class="release-action-btn edit-btn" onclick="event.stopPropagation(); if (this.getAttribute('aria-disabled') === 'true') return; showEditReleaseModal('${jsAttrEscape(release.id)}')" ${isArchived ? `aria-disabled="true" aria-describedby="release-edit-reason-${safeReleaseId}" title="${escapeAttr(editReason)}"` : ''}>EDIT</button>
                ${isArchived ? `<span id="release-edit-reason-${safeReleaseId}" class="sr-only">${escapeHtml(editReason)}</span>` : ''}
                ${renderArchiveAction(release, isArchived)}
                <button class="release-action-btn danger delete-btn" onclick="event.stopPropagation(); if (this.getAttribute('aria-disabled') === 'true') return; deleteRelease('${jsAttrEscape(release.id)}', '${jsAttrEscape(release.name)}')" ${isArchived ? `aria-disabled="true" aria-describedby="release-delete-reason-${safeReleaseId}" title="${escapeAttr(deleteReason)}"` : ''}>DELETE</button>
                ${isArchived ? `<span id="release-delete-reason-${safeReleaseId}" class="sr-only">${escapeHtml(deleteReason)}</span>` : ''}
            </div>
        </div>
    `;
}

/**
 * Toggle release expanded state
 */
async function toggleReleaseExpanded(releaseId) {
    const isExpanded = releasesState.expandedReleases.has(releaseId);

    if (isExpanded) {
        releasesState.expandedReleases.delete(releaseId);
    } else {
        releasesState.expandedReleases.add(releaseId);
    }

    // Re-render the release card
    const card = document.querySelector(`.release-card[data-release-id="${releaseId}"]`);
    if (card) {
        card.classList.toggle('expanded', !isExpanded);
        const expandIcon = card.querySelector('.release-expand-icon');
        if (expandIcon) {
            expandIcon.textContent = !isExpanded ? '▼' : '▶';
        }
    }

    // Load items if expanding
    if (!isExpanded) {
        await loadReleaseItems(releaseId);
    } else {
        const itemsContainer = document.getElementById(`release-items-${releaseId}`);
        if (itemsContainer) {
            itemsContainer.innerHTML = '';
        }
    }
}

/**
 * XACA-0948: canonical release-item status tokens that get their own CSS
 * class name. Anything else — a non-canonical recorded token (contract
 * §1.4, e.g. 'backlog'/'pending') or no value at all — falls back to
 * 'unknown'/'unresolved' rather than being interpolated verbatim into
 * `class=` (an unescaped-attribute smell, XACA-0948-004 §4.3 R3).
 */
const RELEASE_ITEM_STATUS_CLASSES = new Set([
    'todo', 'in_progress', 'in_review', 'blocked', 'completed', 'cancelled', 'done'
]);

/**
 * Resolve the CSS class suffix + display label for a release item's status.
 *
 * XACA-0948: `item.status` is resolved live per ITEM_STATUS_CONTRACT.md
 * §1.5 and can legitimately be null/undefined (server reports
 * `statusResolution: "unresolved"` when a row's team/board can't be
 * resolved) or a non-canonical recorded token. Pulled out as a small, pure,
 * DOM-free function specifically so it's unit-testable in isolation — see
 * lcars-ui/tests/test-xaca-0948-release-item-status-guard.js. Before this
 * fix, the caller did `item.status.toUpperCase()` unguarded here; a missing
 * status threw inside the `.map()` over ALL release items and rendered
 * "Error loading items" for the whole panel.
 *
 * XACA-0948-017: the CSS class keeps the raw underscored token
 * (`status-in_review`) unchanged — that's what the stylesheet selectors in
 * lcars.css match against — but the human-facing label is normalized
 * underscore->space (`in_review` -> "IN REVIEW") to match the established
 * convention elsewhere in this file (see the `.replace(/_/g, ' ')` pattern
 * used for backlog-status chart labels). Only the label changes; statusClass
 * is untouched so styling is unaffected.
 *
 * XACA-0948-016: `statusTitle` is a tooltip for the 'unresolved' case only.
 * The server's `statusResolution` is a binary resolved/unresolved flag with
 * no reason code — a dangling item id, a missing team, and an unreadable
 * board are all indistinguishable from here — so the tooltip text is
 * deliberately generic rather than promising a specific cause the data
 * can't support. Non-unresolved statuses get an empty string (no tooltip).
 *
 * @param {{status: (string|null|undefined)}} item
 * @returns {{statusClass: string, statusLabel: string, statusTitle: string}}
 */
function resolveReleaseItemStatusDisplay(item) {
    const rawStatus = item.status;
    const hasStatus = rawStatus !== null && rawStatus !== undefined && String(rawStatus).trim() !== '';
    const statusClass = !hasStatus ? 'unresolved' : (RELEASE_ITEM_STATUS_CLASSES.has(rawStatus) ? rawStatus : 'unknown');
    const statusLabel = hasStatus ? String(rawStatus).toUpperCase().replace(/_/g, ' ') : 'UNRESOLVED';
    const statusTitle = !hasStatus
        ? 'Status could not be resolved from a team board (e.g. a dangling item ID, missing team, or unreadable board data). Counted as incomplete pending resolution.'
        : '';
    return { statusClass, statusLabel, statusTitle };
}

/**
 * Load items for a release
 */
async function loadReleaseItems(releaseId) {
    const itemsContainer = document.getElementById(`release-items-${releaseId}`);
    if (!itemsContainer) return;

    itemsContainer.innerHTML = '<div class="release-items-loading">Loading items...</div>';

    try {
        const response = await fetch(apiUrl(`/api/releases/${releaseId}/items`));
        if (!response.ok) throw new Error('Failed to fetch release items');
        const data = await response.json();

        if (!data.items || data.items.length === 0) {
            itemsContainer.innerHTML = '<div class="release-no-items">No items assigned to this release</div>';
            return;
        }

        const itemsHtml = data.items.map(item => {
            const isCompleted = item.status === 'done' || item.status === 'completed';
            const isCancelled = item.status === 'cancelled';
            const stateClass = isCompleted ? 'completed' : (isCancelled ? 'cancelled' : '');

            const { statusClass, statusLabel, statusTitle } = resolveReleaseItemStatusDisplay(item);
            // XACA-0948-016: only emit a title attribute when there's
            // explanatory text to show — canonical/non-canonical statuses
            // are self-explanatory from the label and get no tooltip.
            const statusTitleAttr = statusTitle ? ` title="${escapeHtml(statusTitle)}"` : '';

            return `
            <div class="release-item ${stateClass}" data-item-id="${escapeHtml(item.itemId)}" onclick="navigateToBacklogItemById('${jsAttrEscape(item.itemId)}')">
                <span class="release-item-id" role="button" tabindex="0" title="Click to copy item ID to clipboard" aria-label="Item ID: ${escapeHtml(item.itemId)}. Click to copy." onclick="event.stopPropagation(); copyToClipboard('${jsAttrEscape(item.itemId)}')" onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();event.stopPropagation();copyToClipboard('${jsAttrEscape(item.itemId)}');}">${escapeHtml(item.itemId)}</span>
                <span class="release-item-status status-${statusClass}"${statusTitleAttr}>${escapeHtml(statusLabel)}</span>
                <span class="release-item-title">${escapeHtml(item.title)}</span>
                <button class="release-item-docs" data-item-id="${item.itemId}" onclick="event.stopPropagation(); showPlanDocModal('${item.itemId}', this.getAttribute('data-retro-exists') === 'true', this.getAttribute('data-cr-exists') === 'true')" title="View Plan Document" style="display:none">DOCS</button>
                <button class="release-item-remove" onclick="event.stopPropagation(); removeItemFromRelease('${releaseId}', '${item.itemId}')" title="Remove from release">✕</button>
            </div>
        `}).join('');

        itemsContainer.innerHTML = itemsHtml;

        // Check for plan documents on each item
        checkReleaseItemsDocs(data.items);
    } catch (e) {
        itemsContainer.innerHTML = `<div class="release-items-error">Error loading items: ${escapeHtml(e.message)}</div>`;
    }
}

/**
 * Check plan existence for release item DOCS buttons
 */
function checkReleaseItemsDocs(items) {
    items.forEach(item => {
        const button = document.querySelector(`.release-item-docs[data-item-id="${item.itemId}"]`);
        if (button) {
            checkPlanExists(item.itemId, button);
        }
    });
}

/**
 * Remove item from release
 */
async function removeItemFromRelease(releaseId, itemId) {
    if (!confirm('Remove this item from the release?')) return;

    try {
        const response = await apiFetch(apiUrl(`/api/releases/${releaseId}/items/${itemId}`), {
            method: 'DELETE'
        });

        if (!response.ok) throw new Error('Failed to remove item');

        // Refresh release items
        await loadReleaseItems(releaseId);
        // Refresh releases list to update counts
        loadReleases();
    } catch (e) {
        alert('Error removing item from release: ' + e.message);
    }
}

/**
 * Get display name for platform
 */
function getPlatformName(key) {
    const names = {
        'ios': 'iOS',
        'android': 'Android',
        'firebase': 'Firebase',
        'web': 'Web',
        // XACA-1000-012: 'other' is the platform key every non-mobile team uses
        // (Academy, Command, DNS, Finance, Legal, Medical). Before XACA-1000 a
        // release on those teams could never reach PROD/ARCHIVE, so this label
        // was effectively dead code; it is now on the normal path for six teams
        // and was rendering as a bare lowercase 'other' beside 'iOS'/'Android'.
        'other': 'Other'
    };
    const safeKey = String(key == null ? '' : key);
    // Title-case the fallback so an unmapped key never renders lowercase next
    // to the Title-Case labels above.
    return names[safeKey.toLowerCase()] ||
        (safeKey ? safeKey.charAt(0).toUpperCase() + safeKey.slice(1) : safeKey);
}

/**
 * Format target date for display
 */
function formatTargetDate(dateStr) {
    if (!dateStr) return 'No target';
    try {
        const date = parseLocalDate(dateStr);
        const now = new Date();
        now.setHours(0, 0, 0, 0);
        const diffDays = Math.round((date - now) / (1000 * 60 * 60 * 24));

        const formatted = date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });

        if (diffDays < 0) {
            return `${formatted} (overdue)`;
        } else if (diffDays === 0) {
            return `${formatted} (today)`;
        } else if (diffDays <= 7) {
            return `${formatted} (${diffDays}d)`;
        }
        return formatted;
    } catch (e) {
        return dateStr;
    }
}

/**
 * Escape HTML for safe display
 */
function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

// XACA-1000-013: Escape a value for interpolation into a QUOTED HTML ATTRIBUTE
// (e.g. title="${escapeAttr(text)}").
//
// escapeHtml() above is textContent -> innerHTML, which per the WHATWG
// fragment-serialization spec escapes &, U+00A0, < and > and DELIBERATELY
// LEAVES QUOTES ALONE -- quotes are only special inside an attribute value.
// Using it in attribute context therefore looks correct, passes review, and
// still permits a `" onmouseover=... x="` breakout (XACA-0416 found exactly
// this shape across five client apps). Use escapeAttr in attribute context.
//
// Distinct from jsAttrEscape() below, which additionally applies JS-string
// escapes (\ and ') because its output lands inside a JS string literal within
// an attribute. Using that here would render an apostrophe as \' to the user.
function escapeAttr(value) {
    if (value === null || value === undefined) return '';
    return String(value)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

// XACA-1000-014: Announce a transient status change to assistive technology.
//
// Several LCARS actions signal success only by re-rendering the affected card
// (the archive/unarchive toggle is one -- its success alert() was deliberately
// removed to avoid popup fatigue). A sighted user sees the card move; a screen
// reader user gets nothing and must re-discover the new state unaided.
//
// Writes into a single shared visually-hidden role="status" region, following
// the established pattern (see #team-account-test-status and the export-missing
// -roots box). aria-live="polite" so it never interrupts, per WCAG 2.1 AA 4.1.3.
//
// The clear-then-set on a timer is deliberate: assistive tech does not re-announce
// a live region whose text is unchanged, so archiving two releases in a row would
// announce only once without it. Any pending set is cancelled first so rapid
// consecutive calls announce the LAST message rather than interleaving.
function announceToScreenReader(message) {
    if (!message || typeof document === 'undefined' || !document.body) return;
    var region = document.getElementById('lcars-sr-announcer');
    if (!region) {
        region = document.createElement('div');
        region.id = 'lcars-sr-announcer';
        region.setAttribute('role', 'status');
        region.setAttribute('aria-live', 'polite');
        region.setAttribute('aria-atomic', 'true');
        // Visually hidden but still exposed to assistive tech -- display:none
        // and visibility:hidden would remove it from the accessibility tree.
        region.style.cssText = 'position:absolute;width:1px;height:1px;margin:-1px;' +
            'padding:0;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0;';
        document.body.appendChild(region);
    }
    if (region._lcarsAnnounceTimer) {
        window.clearTimeout(region._lcarsAnnounceTimer);
    }
    region.textContent = '';
    region._lcarsAnnounceTimer = window.setTimeout(function () {
        region.textContent = String(message);
        region._lcarsAnnounceTimer = null;
    }, 50);
}

// XACA-0277: Escape a value for safe interpolation as a JS string literal
// inside an HTML attribute (e.g. onclick="copy('${jsAttrEscape(id)}')").
// Covers HTML metacharacters AND the JS-string-breaking ones escapeHtml
// leaves alone (\, '). Order matters: backslash MUST be escaped first.
function jsAttrEscape(value) {
    if (value === null || value === undefined) return '';
    return String(value)
        .replace(/\\/g, '\\\\')
        .replace(/'/g, "\\'")
        .replace(/&/g, '&amp;')
        .replace(/"/g, '&quot;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
}

/**
 * Format ISO timestamp for display
 */
function formatTimestamp(timestamp) {
    if (!timestamp) return 'Unknown';
    try {
        const date = new Date(timestamp);
        return date.toLocaleString('en-US', {
            month: 'short',
            day: 'numeric',
            year: 'numeric',
            hour: '2-digit',
            minute: '2-digit'
        });
    } catch {
        return timestamp;
    }
}

/**
 * Format date string for display
 */
function formatDate(dateString) {
    if (!dateString) return null;
    try {
        const date = parseLocalDate(dateString);
        return date.toLocaleDateString('en-US', {
            month: 'short',
            day: 'numeric',
            year: 'numeric'
        });
    } catch {
        return dateString;
    }
}

/**
 * XACA-0037: Item ID prefix to team mapping
 */
const ITEM_PREFIX_TO_TEAM = {
    'XIOS': 'ios',
    'XAND': 'android',
    'XFIR': 'firebase',
    'XACA': 'academy',
    'XCMD': 'command',
    'XDNS': 'dns',
    'XFRE': 'freelance',
    'XMEV': 'mainevent',
};

/**
 * XACA-0037: Extract team from item ID prefix
 * Item IDs follow the pattern: X<TEAM>-<NUMBER> (e.g., XIOS-0001, XFIR-0023)
 * @param {string} itemId - The item ID
 * @returns {string|null} The team name or null if prefix is not recognized
 */
function extractTeamFromItemId(itemId) {
    if (!itemId || itemId.length < 4) return null;
    const prefix = itemId.substring(0, 4).toUpperCase();
    return ITEM_PREFIX_TO_TEAM[prefix] || null;
}

/**
 * View items in a release - navigates to Queue tab with release filter applied (XACA-0026)
 * @param {string} releaseId - The release ID to filter by
 */
function viewReleaseItems(releaseId) {
    console.log('View items for release:', releaseId);

    // Set the release filter
    backlogFilterState.releaseFilter = releaseId;

    // Update the dropdown if it exists
    const releaseSelect = document.getElementById('release-filter-select');
    if (releaseSelect) {
        releaseSelect.value = releaseId;
        updateReleaseDropdownStyle();
    }

    // Save filter state
    saveQueueFilterState();

    // Switch to Queue tab
    switchSection('backlog');

    // Re-render the backlog with the filter applied (after tab switch animation)
    setTimeout(() => {
        renderMissionBacklog();
    }, 150);
}

// ═══════════════════════════════════════════════════════════════════════════════
// PROMOTE MODAL (XACA-0026)
// 3-step wizard for promoting release platforms to next environment
// ═══════════════════════════════════════════════════════════════════════════════

let promoteModalState = {
    releaseId: null,
    releaseData: null,
    currentStep: 1,
    selectedPlatforms: [],
    promotionResults: []
};

/**
 * Show the promote modal for a release (XACA-0026)
 * @param {string} releaseId - The release ID to promote
 */
async function promoteRelease(releaseId) {
    console.log('Opening promote modal for release:', releaseId);

    // Reset state
    promoteModalState = {
        releaseId: releaseId,
        releaseData: null,
        currentStep: 1,
        selectedPlatforms: [],
        promotionResults: [],
        flowConfig: null
    };

    // Fetch release data and flow config in parallel (include team for correct scoping)
    try {
        const [releaseResponse, configResponse] = await Promise.all([
            fetch(apiUrl(`/api/releases/${releaseId}`)),
            fetch(apiUrl(`/api/release-config?team=${encodeURIComponent(CONFIG.team)}`))
        ]);

        if (!releaseResponse.ok) {
            showToast(`Failed to load release: ${releaseId}`, 'error');
            return;
        }
        const releaseData = await releaseResponse.json();
        promoteModalState.releaseData = releaseData;

        // Load flow config
        if (configResponse.ok) {
            const configData = await configResponse.json();
            promoteModalState.flowConfig = configData.flowConfig || null;
            // XACA-0163: per-project stage overrides from the same response
            promoteModalState.projectEnvironments = configData.projectEnvironments || {};
        }
    } catch (error) {
        console.error('Error loading release for promotion:', error);
        showToast('Failed to load release data', 'error');
        return;
    }

    // Populate and show modal
    populatePromoteStep1();
    updatePromoteStepIndicator(1);
    showPromoteStep(1);

    // Show modal
    document.getElementById('promote-modal').style.display = 'flex';
}

/**
 * Hide the promote modal
 */
function hidePromoteModal() {
    document.getElementById('promote-modal').style.display = 'none';
    promoteModalState = {
        releaseId: null,
        releaseData: null,
        currentStep: 1,
        selectedPlatforms: [],
        promotionResults: []
    };
}

/**
 * Populate Step 1 - Platform selection (XACA-0026)
 */
function populatePromoteStep1() {
    const release = promoteModalState.releaseData;
    if (!release) return;

    // Update release info
    document.getElementById('promote-release-info').innerHTML = `
        <span class="release-name">${release.name || 'Unnamed Release'}</span>
        <span class="release-id">${release.id}</span>
    `;

    // Build platform checkboxes
    const platformsContainer = document.getElementById('promote-platforms');
    const platforms = release.platforms || {};

    // Filter environments based on flowConfig (XACA-0027, XACA-0163)
    const flowConfig = promoteModalState.flowConfig;
    const environments = getReleaseEnvironments(release, flowConfig, promoteModalState.projectEnvironments);

    let html = '';
    for (const [platform, data] of Object.entries(platforms)) {
        const currentEnv = data.environment || 'DEV';
        const currentIdx = environments.indexOf(currentEnv);
        const isAtFinal = currentIdx >= environments.length - 1;
        const nextEnv = isAtFinal ? null : environments[currentIdx + 1];

        const platformIcon = platform === 'ios' ? '🍎' : platform === 'android' ? '🤖' : '🔥';
        const platformLabel = platform.charAt(0).toUpperCase() + platform.slice(1);

        html += `
            <div class="platform-checkbox-item ${isAtFinal ? 'disabled' : ''}" data-platform="${platform}">
                <label class="platform-checkbox-label">
                    <input type="checkbox" class="platform-checkbox" value="${platform}"
                           ${isAtFinal ? 'disabled' : ''} onchange="updatePromoteSelection()">
                    <span class="platform-checkbox-custom"></span>
                    <span class="platform-icon">${platformIcon}</span>
                    <span class="platform-name">${platformLabel}</span>
                </label>
                <div class="platform-env-info">
                    <span class="env-current">${currentEnv}</span>
                    ${nextEnv ? `<span class="env-arrow">→</span><span class="env-next">${nextEnv}</span>` : '<span class="env-final">AT FINAL</span>'}
                </div>
            </div>
        `;
    }

    platformsContainer.innerHTML = html || '<p class="no-platforms">No platforms configured for this release.</p>';

    // Update button state
    updatePromoteNextButtonState();
}

/**
 * Update selection tracking when checkboxes change
 */
function updatePromoteSelection() {
    const checkboxes = document.querySelectorAll('#promote-platforms .platform-checkbox:checked');
    promoteModalState.selectedPlatforms = Array.from(checkboxes).map(cb => cb.value);
    updatePromoteNextButtonState();
}

/**
 * Update the Next button state based on current step
 */
function updatePromoteNextButtonState() {
    const nextBtn = document.getElementById('promote-next-btn');
    const step = promoteModalState.currentStep;

    if (step === 1) {
        nextBtn.disabled = promoteModalState.selectedPlatforms.length === 0;
        nextBtn.textContent = 'NEXT';
    } else if (step === 2) {
        nextBtn.disabled = false;
        nextBtn.textContent = 'PROMOTE';
    } else if (step === 3) {
        nextBtn.textContent = 'DONE';
        nextBtn.disabled = false;
    }
}

/**
 * Update the step indicator UI
 */
function updatePromoteStepIndicator(step) {
    document.querySelectorAll('.promote-step').forEach((el, idx) => {
        el.classList.remove('active', 'completed');
        if (idx + 1 < step) {
            el.classList.add('completed');
        } else if (idx + 1 === step) {
            el.classList.add('active');
        }
    });
}

/**
 * Show a specific step and hide others
 */
function showPromoteStep(step) {
    for (let i = 1; i <= 3; i++) {
        const stepEl = document.getElementById(`promote-step-${i}`);
        if (stepEl) {
            stepEl.style.display = i === step ? 'block' : 'none';
        }
    }

    // Update back button visibility
    const backBtn = document.getElementById('promote-back-btn');
    backBtn.style.display = step > 1 && step < 3 ? 'inline-block' : 'none';

    // Update cancel button text on final step
    const cancelBtn = document.getElementById('promote-cancel-btn');
    cancelBtn.style.display = step === 3 && promoteModalState.promotionResults.length > 0 ? 'none' : 'inline-block';
}

/**
 * Move to next step
 */
function promoteStepNext() {
    const step = promoteModalState.currentStep;

    if (step === 1) {
        if (promoteModalState.selectedPlatforms.length === 0) {
            showPromoteError(1, 'Please select at least one platform to promote.');
            return;
        }
        promoteModalState.currentStep = 2;
        populatePromoteStep2();
        updatePromoteStepIndicator(2);
        showPromoteStep(2);
        updatePromoteNextButtonState();
    } else if (step === 2) {
        promoteModalState.currentStep = 3;
        populatePromoteStep3();
        updatePromoteStepIndicator(3);
        showPromoteStep(3);
        executePromotion();
    } else if (step === 3) {
        hidePromoteModal();
        loadReleases(); // Refresh releases list
    }
}

/**
 * Move to previous step
 */
function promoteStepBack() {
    const step = promoteModalState.currentStep;

    if (step === 2) {
        promoteModalState.currentStep = 1;
        updatePromoteStepIndicator(1);
        showPromoteStep(1);
        updatePromoteNextButtonState();
    }
}

/**
 * Show error in a specific step
 */
function showPromoteError(step, message) {
    const errorEl = document.getElementById(`promote-error-${step}`);
    if (errorEl) {
        errorEl.textContent = message;
        errorEl.style.display = 'block';
    }
}

/**
 * Clear error in a specific step
 */
function clearPromoteError(step) {
    const errorEl = document.getElementById(`promote-error-${step}`);
    if (errorEl) {
        errorEl.style.display = 'none';
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PROMOTE MODAL STEP 2 - Validation & Review (XACA-0026)
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Populate Step 2 - Validation and preview
 */
function populatePromoteStep2() {
    const release = promoteModalState.releaseData;
    const platforms = release.platforms || {};
    // XACA-0163: honor flowConfig and projectEnvironments so Step 2
    // matches Step 1's filtered list.
    const environments = getReleaseEnvironments(
        release,
        promoteModalState.flowConfig,
        promoteModalState.projectEnvironments
    );
    const selected = promoteModalState.selectedPlatforms;

    // Build preview list
    const previewContainer = document.getElementById('promote-preview');
    let previewHtml = '';
    const warnings = [];

    selected.forEach(platform => {
        const data = platforms[platform];
        const currentEnv = data?.environment || 'DEV';
        const currentIdx = environments.indexOf(currentEnv);
        const nextEnv = environments[currentIdx + 1] || currentEnv;

        const platformIcon = platform === 'ios' ? '🍎' : platform === 'android' ? '🤖' : '🔥';
        const platformLabel = platform.charAt(0).toUpperCase() + platform.slice(1);

        previewHtml += `
            <div class="promote-preview-item">
                <div class="preview-platform">
                    <span class="platform-icon">${platformIcon}</span>
                    <span class="platform-name">${platformLabel}</span>
                </div>
                <div class="preview-transition">
                    <span class="env-badge env-${currentEnv.toLowerCase()}">${currentEnv}</span>
                    <span class="transition-arrow">→</span>
                    <span class="env-badge env-${nextEnv.toLowerCase()}">${nextEnv}</span>
                </div>
                <div class="preview-version">
                    v${data?.version || '?.?.?'} (${data?.buildNumber || '?'})
                </div>
            </div>
        `;

        // Check for warnings
        if (nextEnv === 'PROD') {
            warnings.push(`${platformLabel} will be promoted to PRODUCTION environment.`);
        }
        if (currentEnv === 'DEV' && nextEnv !== 'QA') {
            warnings.push(`${platformLabel} is jumping from DEV directly to ${nextEnv}.`);
        }
    });

    previewContainer.innerHTML = previewHtml;

    // Show warnings if any
    const warningsContainer = document.getElementById('promote-warnings');
    const warningsList = document.getElementById('warning-list');

    if (warnings.length > 0) {
        warningsList.innerHTML = warnings.map(w => `<li>${w}</li>`).join('');
        warningsContainer.style.display = 'block';
    } else {
        warningsContainer.style.display = 'none';
    }

    clearPromoteError(2);
}

// ═══════════════════════════════════════════════════════════════════════════════
// PROMOTE MODAL STEP 3 - Confirmation & Execute (XACA-0026)
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Populate Step 3 - Summary before execution
 */
function populatePromoteStep3() {
    const release = promoteModalState.releaseData;
    const summaryContainer = document.getElementById('promote-summary');

    summaryContainer.innerHTML = `
        <div class="summary-header">
            <span class="summary-release">${release.name}</span>
            <span class="summary-count">${promoteModalState.selectedPlatforms.length} platform(s)</span>
        </div>
        <p class="summary-message">Initiating promotion sequence...</p>
    `;

    // Show progress, hide results
    document.getElementById('promote-progress').style.display = 'block';
    document.getElementById('promote-results').style.display = 'none';
    document.getElementById('promote-next-btn').disabled = true;
}

/**
 * Execute the promotion for all selected platforms
 */
async function executePromotion() {
    const releaseId = promoteModalState.releaseId;
    const selected = promoteModalState.selectedPlatforms;
    const results = [];

    const progressBar = document.getElementById('promote-progress-bar');
    const progressMessage = document.getElementById('progress-message');

    for (let i = 0; i < selected.length; i++) {
        const platform = selected[i];
        progressMessage.textContent = `Promoting ${platform}...`;
        progressBar.style.width = `${((i + 0.5) / selected.length) * 100}%`;

        try {
            const response = await apiFetch(apiUrl(`/api/releases/${releaseId}/promote`), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ platform: platform })
            });

            if (!response.ok) {
                const errorData = await response.json().catch(() => ({}));
                results.push({
                    platform,
                    success: false,
                    error: errorData.error || `HTTP ${response.status}`
                });
            } else {
                const data = await response.json();
                results.push({
                    platform,
                    success: true,
                    previousEnvironment: data.previousEnvironment,
                    newEnvironment: data.newEnvironment
                });
            }
        } catch (error) {
            results.push({
                platform,
                success: false,
                error: error.message
            });
        }

        progressBar.style.width = `${((i + 1) / selected.length) * 100}%`;
    }

    promoteModalState.promotionResults = results;
    progressMessage.textContent = 'Complete!';

    // Short delay then show results
    setTimeout(() => {
        displayPromotionResults(results);
    }, 500);
}

/**
 * Display promotion results
 */
function displayPromotionResults(results) {
    const progressEl = document.getElementById('promote-progress');
    const resultsEl = document.getElementById('promote-results');
    const summaryEl = document.getElementById('promote-summary');

    progressEl.style.display = 'none';

    const successCount = results.filter(r => r.success).length;
    const failCount = results.filter(r => !r.success).length;

    let html = `<div class="results-summary">`;

    if (failCount === 0) {
        html += `<div class="results-status success">✓ All promotions successful!</div>`;
    } else if (successCount === 0) {
        html += `<div class="results-status error">✗ All promotions failed</div>`;
    } else {
        html += `<div class="results-status partial">⚠ ${successCount} succeeded, ${failCount} failed</div>`;
    }

    html += `<div class="results-list">`;

    results.forEach(r => {
        const platformIcon = r.platform === 'ios' ? '🍎' : r.platform === 'android' ? '🤖' : '🔥';

        if (r.success) {
            html += `
                <div class="result-item success">
                    <span class="result-icon">${platformIcon}</span>
                    <span class="result-platform">${r.platform}</span>
                    <span class="result-detail">${r.previousEnvironment} → ${r.newEnvironment}</span>
                </div>
            `;
        } else {
            html += `
                <div class="result-item error">
                    <span class="result-icon">${platformIcon}</span>
                    <span class="result-platform">${r.platform}</span>
                    <span class="result-error">${r.error}</span>
                </div>
            `;
        }
    });

    html += `</div></div>`;

    resultsEl.innerHTML = html;
    resultsEl.style.display = 'block';
    summaryEl.style.display = 'none';

    // Update buttons for final state
    document.getElementById('promote-next-btn').disabled = false;
    document.getElementById('promote-next-btn').textContent = 'DONE';
    document.getElementById('promote-cancel-btn').style.display = 'none';
    document.getElementById('promote-back-btn').style.display = 'none';

    // Show toast
    if (failCount === 0) {
        showToast(`Successfully promoted ${successCount} platform(s)`, 'success');
    } else {
        showToast(`Promotion completed with ${failCount} error(s)`, 'warning');
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// RELNOTES MODAL (XACA-0026)
// Auto-generates and displays release notes for a release
// ═══════════════════════════════════════════════════════════════════════════════

let relnotesModalState = {
    releaseId: null,
    releaseData: null,
    generatedContent: ''
};

/**
 * Show the release notes modal (XACA-0026)
 * @param {string} releaseId - The release ID
 */
async function viewReleaseNotes(releaseId) {
    console.log('Opening release notes modal for:', releaseId);

    // Reset state
    relnotesModalState = {
        releaseId: releaseId,
        releaseData: null,
        generatedContent: ''
    };

    // Show modal with loading state
    document.getElementById('relnotes-modal').style.display = 'flex';
    document.getElementById('relnotes-loading').style.display = 'block';
    document.getElementById('relnotes-output').style.display = 'none';
    switchRelnotesTab('generated');

    try {
        // Fetch release data
        const response = await fetch(apiUrl(`/api/releases/${releaseId}`));
        if (!response.ok) throw new Error(`Failed to load release: ${response.status}`);
        // API returns release directly, not wrapped in { release: ... }
        const release = await response.json();
        relnotesModalState.releaseData = release;

        // XACA-0056: Hide regenerate button and editor tab for archived releases
        const isArchived = release.status === 'archived';
        const regenerateBtn = document.getElementById('relnotes-regenerate-btn');
        const editorTab = document.getElementById('relnotes-editor-tab');
        if (regenerateBtn) {
            regenerateBtn.style.display = isArchived ? 'none' : 'inline-block';
        }
        if (editorTab) {
            editorTab.style.display = isArchived ? 'none' : 'inline-block';
        }

        // Update header (show archived badge if applicable)
        document.getElementById('relnotes-release-info').innerHTML = `
            <span class="release-name">${release.name || 'Unnamed Release'}</span>
            <span class="release-id">${release.id}</span>
            ${isArchived ? '<span class="release-archived-badge">ARCHIVED</span>' : ''}
        `;

        // Generate release notes
        await generateReleaseNotes();

    } catch (error) {
        console.error('Error loading release notes:', error);
        document.getElementById('relnotes-loading').style.display = 'none';
        showRelnotesError(error.message);
    }
}

/**
 * Hide the release notes modal
 */
function hideRelnotesModal() {
    document.getElementById('relnotes-modal').style.display = 'none';
    relnotesModalState = {
        releaseId: null,
        releaseData: null,
        generatedContent: ''
    };
}

/**
 * Generate release notes content (XACA-0026)
 * Fetches items assigned to this release and generates formatted notes
 */
async function generateReleaseNotes() {
    const release = relnotesModalState.releaseData;
    if (!release) return;

    try {
        // Fetch items assigned to this release
        const response = await fetch(apiUrl(`/api/releases/${release.id}/items`));
        if (!response.ok) throw new Error('Failed to fetch release items');
        const data = await response.json();
        const items = data.items || [];

        // Generate the release notes content
        let content = generateRelnotesContent(release, items);

        relnotesModalState.generatedContent = content;

        // Display in the modal
        document.getElementById('relnotes-loading').style.display = 'none';
        document.getElementById('relnotes-output').style.display = 'block';
        document.getElementById('relnotes-output').innerHTML = formatRelnotesAsHtml(content);

        // Also populate the editor
        document.getElementById('relnotes-textarea').value = content;

    } catch (error) {
        console.error('Error generating release notes:', error);
        document.getElementById('relnotes-loading').style.display = 'none';
        showRelnotesError('Failed to generate release notes: ' + error.message);
    }
}

/**
 * Generate formatted release notes content (XACA-0026)
 * @param {Object} release - The release data
 * @param {Array} items - Items assigned to the release
 * @returns {string} Formatted release notes markdown
 */
function generateRelnotesContent(release, items) {
    const platforms = release.platforms || {};
    // XACA-0163: honor current flowConfig and projectEnvironments (via
    // module-level flowConfigState) instead of the frozen stage snapshot.
    const environments = getReleaseEnvironments(
        release,
        flowConfigState,
        flowConfigState.projectEnvironments
    );

    // XACA-0037: Filter items by team as a safeguard against cross-team contamination
    // This catches any legacy cross-team assignments that predate validation
    const releaseTeam = release.team;
    const filteredItems = releaseTeam
        ? items.filter(item => !item.team || item.team === releaseTeam)
        : items;

    if (filteredItems.length !== items.length) {
        console.warn(`XACA-0037: Filtered ${items.length - filteredItems.length} cross-team items from release notes`);
    }

    // Determine the "lowest" environment across all platforms (the release stage)
    let lowestEnvIdx = environments.length - 1;
    for (const [platform, data] of Object.entries(platforms)) {
        const idx = environments.indexOf(data.environment || 'DEV');
        if (idx >= 0 && idx < lowestEnvIdx) {
            lowestEnvIdx = idx;
        }
    }
    const releaseStage = environments[lowestEnvIdx] || 'DEV';

    // Start building content
    let content = `## ${releaseStage} - ${release.name || release.id}\n\n`;

    // Release type
    const releaseType = release.type || 'MAINTENANCE';
    content += `**Release Type**\n-   ${releaseType.toUpperCase()}\n\n`;

    // Categorize items by type
    const features = [];
    const bugfixes = [];
    const improvements = [];
    const other = [];

    filteredItems.forEach(item => {
        const title = item.title || item.itemId;
        const id = item.itemId;
        const entry = `${title} (${id})`;

        // Categorize based on tags or title keywords
        const tags = (item.tags || []).map(t => t.toLowerCase());
        const titleLower = title.toLowerCase();

        if (tags.includes('feature') || tags.includes('enhancement') || titleLower.includes('add') || titleLower.includes('new')) {
            features.push(entry);
        } else if (tags.includes('bug') || tags.includes('fix') || titleLower.includes('fix') || titleLower.includes('bug')) {
            bugfixes.push(entry);
        } else if (tags.includes('refactor') || tags.includes('improvement') || titleLower.includes('improve') || titleLower.includes('update')) {
            improvements.push(entry);
        } else {
            other.push(entry);
        }
    });

    // Issues Resolved
    content += `**Issues Resolved**\n`;
    if (bugfixes.length > 0) {
        bugfixes.forEach(item => { content += `-   ${item}\n`; });
    } else {
        content += `-   NONE\n`;
    }
    content += `\n`;

    // New Features
    content += `**New Features**\n`;
    if (features.length > 0) {
        features.forEach(item => { content += `-   ${item}\n`; });
    } else {
        content += `-   NONE\n`;
    }
    content += `\n`;

    // Technical Improvements
    content += `**Technical Improvements**\n`;
    const techImprovements = [...improvements, ...other];
    if (techImprovements.length > 0) {
        techImprovements.forEach(item => { content += `-   ${item}\n`; });
    } else {
        content += `-   NONE\n`;
    }
    content += `\n`;

    // Known Problems
    content += `**Known Problems**\n-   None identified in this release\n\n`;

    // Platform Status
    content += `---\n\n**Platform Status**\n`;
    for (const [platform, data] of Object.entries(platforms)) {
        const platformLabel = platform.charAt(0).toUpperCase() + platform.slice(1);
        const env = data.environment || 'DEV';
        const version = data.version || '?.?.?';
        const build = data.buildNumber || '?';
        content += `-   ${platformLabel}: ${env} (v${version} build ${build})\n`;
    }

    return content;
}

/**
 * Format release notes markdown as HTML for display
 */
function formatRelnotesAsHtml(content) {
    // Simple markdown to HTML conversion
    let html = content
        .replace(/^## (.+)$/gm, '<h2>$1</h2>')
        .replace(/^\*\*(.+)\*\*$/gm, '<h4>$1</h4>')
        .replace(/^-   (.+)$/gm, '<li>$1</li>')
        .replace(/^---$/gm, '<hr>')
        .replace(/\n\n/g, '</ul><ul>')
        .replace(/<\/h4><\/ul><ul>/g, '</h4><ul>')
        .replace(/<\/h2><\/ul><ul>/g, '</h2><ul>');

    // Wrap in container
    html = `<div class="relnotes-formatted"><ul>${html}</ul></div>`;

    // Clean up empty uls
    html = html.replace(/<ul><\/ul>/g, '').replace(/<ul>(<h[24]>)/g, '$1').replace(/(<\/h[24]>)<\/ul>/g, '$1');

    return html;
}

/**
 * Switch between generated and editor tabs
 */
function switchRelnotesTab(tab) {
    // Update tab buttons
    document.querySelectorAll('.relnotes-tab').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.tab === tab);
    });

    // Show/hide content
    document.getElementById('relnotes-generated').style.display = tab === 'generated' ? 'block' : 'none';
    document.getElementById('relnotes-editor').style.display = tab === 'editor' ? 'block' : 'none';
}

/**
 * Copy release notes to clipboard
 *
 * XACA-0920-005: routed through the hardened copyToClipboard() two-tier
 * helper instead of calling navigator.clipboard.writeText() directly, so
 * this path can't retain the rejected-promise-dead-ends defect. Release
 * notes content is a large multi-line blob, so a custom successMessage is
 * supplied — the default `Copied: ${text}` behavior (which echoes the
 * copied text into the toast) would be terrible UX here.
 */
async function copyRelnotesToClipboard() {
    const activeTab = document.querySelector('.relnotes-tab.active')?.dataset.tab;
    let content;

    if (activeTab === 'editor') {
        content = document.getElementById('relnotes-textarea').value;
    } else {
        content = relnotesModalState.generatedContent;
    }

    await copyToClipboard(content, { successMessage: 'Release notes copied to clipboard' });
}

/**
 * Regenerate release notes
 */
async function regenerateRelnotes() {
    document.getElementById('relnotes-loading').style.display = 'block';
    document.getElementById('relnotes-output').style.display = 'none';
    clearRelnotesError();
    await generateReleaseNotes();
    showToast('Release notes regenerated', 'info');
}

/**
 * Show error in release notes modal
 */
function showRelnotesError(message) {
    const errorEl = document.getElementById('relnotes-error');
    if (errorEl) {
        errorEl.textContent = message;
        errorEl.style.display = 'block';
    }
}

/**
 * Clear error in release notes modal
 */
function clearRelnotesError() {
    const errorEl = document.getElementById('relnotes-error');
    if (errorEl) {
        errorEl.style.display = 'none';
    }
}

/**
 * Delete (archive) a release
 * @param {string} releaseId - The release ID to delete
 * @param {string} releaseName - The release name for confirmation
 */
async function deleteRelease(releaseId, releaseName) {
    // Confirm deletion
    const confirmed = confirm(`Are you sure you want to delete release "${releaseName}" (${releaseId})?\n\nThis will archive the release and remove it from the active list.`);
    if (!confirmed) {
        return;
    }

    try {
        const response = await apiFetch(apiUrl(`/api/releases/${releaseId}`), {
            method: 'DELETE',
            headers: {
                'Content-Type': 'application/json'
            }
        });

        if (!response.ok) {
            const errorData = await response.json().catch(() => ({}));
            throw new Error(errorData.error || `Failed to delete release: ${response.status}`);
        }

        const result = await response.json();
        console.log('Release deleted:', result);

        // Refresh the releases list
        loadReleases();

        // Show success message
        alert(`Release "${releaseName}" has been archived successfully.`);

    } catch (error) {
        console.error('Error deleting release:', error);
        alert(`Error deleting release: ${error.message}`);
    }
}

/**
 * Toggle release archive status (XACA-0056-004)
 * Archives a release if it's complete (all platforms at PROD)
 * Unarchives a release if it's currently archived
 */
async function toggleReleaseArchive(releaseId) {
    try {
        const team = CONFIG.team || '';
        const response = await apiFetch(apiUrl(`/api/releases/${releaseId}/archive?team=${encodeURIComponent(team)}`), {
            method: 'PATCH',
            headers: {
                'Content-Type': 'application/json'
            }
        });

        if (!response.ok) {
            const errorData = await response.json().catch(() => ({}));
            throw new Error(errorData.error || `Failed to toggle archive: ${response.status}`);
        }

        const result = await response.json();
        console.log('Release archive toggled:', result);

        // Refresh the releases list
        loadReleases();

        // XACA-1000-014: a success alert() was deliberately removed here to
        // avoid popup fatigue, leaving the re-rendered card as the ONLY signal
        // that anything happened. A sighted user sees the card move; a screen
        // reader user got nothing at all and had to re-discover the state.
        // announceToScreenReader() restores the confirmation without restoring
        // the popup — it is polite, so it will not interrupt.
        announceToScreenReader(
            result && result.archived === false
                ? 'Release unarchived and returned to the active list.'
                : 'Release archived.'
        );

    } catch (error) {
        console.error('Error toggling release archive:', error);
        alert(`Error toggling archive: ${error.message}`);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// RELEASE ASSIGNMENT MODAL
// ═══════════════════════════════════════════════════════════════════════════════

// State for the release assignment modal
let releaseAssignModalState = {
    itemId: null,
    itemTitle: null,
    team: null,
    releases: [],
    allPlatforms: {},
    currentAssignment: null
};

/**
 * Update platform dropdown based on selected release
 * Only shows platforms that are enabled for the selected release
 */
function updatePlatformDropdownForRelease() {
    const releaseSelect = document.getElementById('release-select');
    const platformSelect = document.getElementById('platform-select');
    if (!releaseSelect || !platformSelect) return;

    const selectedReleaseId = releaseSelect.value;
    const currentPlatformValue = platformSelect.value;

    // Find the selected release
    const selectedRelease = releaseAssignModalState.releases.find(r => r.id === selectedReleaseId);

    // Get available platforms for this release (or all platforms if no release selected)
    let availablePlatforms = {};
    if (selectedRelease && selectedRelease.platforms) {
        // Only show platforms that exist in the release
        Object.keys(selectedRelease.platforms).forEach(key => {
            if (releaseAssignModalState.allPlatforms[key]) {
                availablePlatforms[key] = releaseAssignModalState.allPlatforms[key];
            }
        });
    } else {
        // No release selected - show all platforms
        availablePlatforms = releaseAssignModalState.allPlatforms;
    }

    // Rebuild platform dropdown
    platformSelect.innerHTML = '<option value="">Select platform...</option>';
    Object.entries(availablePlatforms).forEach(([key, platform]) => {
        const option = document.createElement('option');
        option.value = key;
        option.textContent = platform.name || key;
        platformSelect.appendChild(option);
    });

    // Try to restore previous selection if it's still valid
    if (currentPlatformValue && availablePlatforms[currentPlatformValue]) {
        platformSelect.value = currentPlatformValue;
    }
}

/**
 * Show the release assignment modal for an item
 * @param {string} itemId - The kanban item ID
 * @param {string} itemTitle - The item title
 * @param {string} team - The team the item belongs to
 * @param {object} currentAssignment - Current release assignment (optional)
 */
async function showReleaseAssignModal(itemId, itemTitle, team, currentAssignment) {
    pauseAutoRefresh();

    const modal = document.getElementById('release-assign-modal');
    const itemInfo = document.getElementById('modal-item-info');
    const releaseSelect = document.getElementById('release-select');
    const platformSelect = document.getElementById('platform-select');
    const errorDiv = document.getElementById('release-assign-error');
    const unassignBtn = document.getElementById('release-unassign-btn');

    if (!modal) {
        console.error('Release assign modal not found');
        return;
    }

    // Store state
    releaseAssignModalState.itemId = itemId;
    releaseAssignModalState.itemTitle = itemTitle;
    releaseAssignModalState.team = team;
    releaseAssignModalState.currentAssignment = currentAssignment || null;

    // Update item info display
    itemInfo.innerHTML = `
        <span class="modal-item-id">${escapeHtml(itemId)}</span>
        <span class="modal-item-title">${escapeHtml(itemTitle)}</span>
    `;

    // Reset form
    releaseSelect.innerHTML = '<option value="">Loading releases...</option>';
    platformSelect.value = '';
    errorDiv.style.display = 'none';

    // Show/hide unassign button based on current assignment
    if (unassignBtn) {
        unassignBtn.style.display = currentAssignment ? 'block' : 'none';
    }

    // Show modal
    modal.style.display = 'flex';

    // Load releases and config in parallel
    // XACA-0037: Filter releases by team to prevent cross-team contamination
    try {
        const releaseUrl = team ? `/api/releases?team=${encodeURIComponent(team)}` : '/api/releases';
        const configTeam = team || CONFIG.team;
        const [releasesResponse, configResponse] = await Promise.all([
            fetch(apiUrl(releaseUrl)),
            fetch(apiUrl(`/api/release-config?team=${encodeURIComponent(configTeam)}`))
        ]);

        if (!releasesResponse.ok) throw new Error('Failed to fetch releases');

        const releasesData = await releasesResponse.json();
        const allReleases = releasesData.releases || [];

        // XACA-0056-006: Filter out archived releases from assignment modal
        releaseAssignModalState.releases = allReleases.filter(r => r.status !== 'archived');

        // XACA-0056: Sort by targetDate ascending, fallback to shortTitle
        releaseAssignModalState.releases.sort((a, b) => {
            const aDate = a.targetDate ? new Date(a.targetDate) : null;
            const bDate = b.targetDate ? new Date(b.targetDate) : null;
            if (aDate && bDate) return aDate - bDate;
            const aLabel = (a.shortTitle || a.name || '').toLowerCase();
            const bLabel = (b.shortTitle || b.name || '').toLowerCase();
            return aLabel.localeCompare(bLabel);
        });

        // Populate release dropdown
        if (releaseAssignModalState.releases.length === 0) {
            const teamLabel = team ? ` for ${team}` : '';
            releaseSelect.innerHTML = `<option value="">No active releases${teamLabel}</option>`;
        } else {
            releaseSelect.innerHTML = '<option value="">Select a release...</option>';
            releaseAssignModalState.releases.forEach(release => {
                const option = document.createElement('option');
                option.value = release.id;
                // Display format: "ShortName - LongName" or just name if no shortTitle
                let displayName;
                if (release.shortTitle && release.name) {
                    displayName = `${release.shortTitle} - ${release.name}`;
                } else {
                    displayName = release.name || release.id;
                }
                option.textContent = displayName;
                option.title = `${release.name} (${release.id})`;
                releaseSelect.appendChild(option);
            });
        }

        // Store all platforms from config for filtering
        if (configResponse.ok) {
            const configData = await configResponse.json();
            releaseAssignModalState.allPlatforms = configData.platforms || {};
        }

        // Add change handler for release selection to filter platforms
        releaseSelect.onchange = updatePlatformDropdownForRelease;

        // Pre-select current assignment if exists
        if (currentAssignment) {
            releaseSelect.value = currentAssignment.releaseId || '';
            // Update platform dropdown based on selected release
            updatePlatformDropdownForRelease();
            platformSelect.value = currentAssignment.platform || '';
        } else {
            // No current assignment - show all platforms initially
            updatePlatformDropdownForRelease();
            // Auto-detect platform from item ID prefix
            const platformPrefix = itemId.substring(0, 4).toUpperCase();
            if (platformPrefix === 'XIOS') {
                platformSelect.value = 'ios';
            } else if (platformPrefix === 'XAND') {
                platformSelect.value = 'android';
            } else if (platformPrefix === 'XFIR') {
                platformSelect.value = 'firebase';
            }
        }
    } catch (e) {
        console.error('Error loading releases:', e);
        releaseSelect.innerHTML = '<option value="">Error loading releases</option>';
    }
}

/**
 * Hide the release assignment modal
 */
function hideReleaseAssignModal() {
    resumeAutoRefresh();

    const modal = document.getElementById('release-assign-modal');
    if (modal) {
        modal.style.display = 'none';
    }

    // Clear state
    releaseAssignModalState = {
        itemId: null,
        itemTitle: null,
        team: null,
        releases: [],
        allPlatforms: {},
        currentAssignment: null
    };
}

/**
 * Submit the release assignment
 */
async function submitReleaseAssignment() {
    const releaseSelect = document.getElementById('release-select');
    const platformSelect = document.getElementById('platform-select');
    const errorDiv = document.getElementById('release-assign-error');
    const confirmBtn = document.querySelector('.modal-btn-confirm');

    const releaseId = releaseSelect.value;
    const platform = platformSelect.value;
    const currentAssignment = releaseAssignModalState.currentAssignment;

    // Validate
    if (!releaseId) {
        showReleaseAssignError('Please select a release');
        return;
    }
    if (!platform) {
        showReleaseAssignError('Please select a platform');
        return;
    }

    // Check if nothing changed
    if (currentAssignment &&
        currentAssignment.releaseId === releaseId &&
        currentAssignment.platform === platform) {
        // No changes - just close the modal
        hideReleaseAssignModal();
        return;
    }

    // Disable button during request
    confirmBtn.disabled = true;
    confirmBtn.textContent = 'ASSIGNING...';

    try {
        // If currently assigned to a different release, unassign first
        if (currentAssignment && currentAssignment.releaseId && currentAssignment.releaseId !== releaseId) {
            const unassignResponse = await apiFetch(apiUrl(`/api/releases/${currentAssignment.releaseId}/items/${releaseAssignModalState.itemId}`), {
                method: 'DELETE'
            });
            if (!unassignResponse.ok) {
                console.warn('Failed to unassign from previous release, continuing anyway');
            }
        }

        const response = await apiFetch(apiUrl(`/api/releases/${releaseId}/items`), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                itemId: releaseAssignModalState.itemId,
                platform: platform,
                team: releaseAssignModalState.team,
                title: releaseAssignModalState.itemTitle
            })
        });

        if (!response.ok) {
            const error = await response.text();
            throw new Error(error || 'Failed to assign item');
        }

        const result = await response.json();
        console.log('Item assigned to release:', result);

        // Close modal and refresh
        hideReleaseAssignModal();

        // Refresh releases view if visible
        const releasesSection = document.querySelector('.releases-section');
        if (releasesSection && releasesSection.classList.contains('active')) {
            loadReleases();
        }

        // Refresh kanban data to show release badge
        refreshData();

    } catch (e) {
        console.error('Error assigning item:', e);
        showReleaseAssignError(e.message);
    } finally {
        confirmBtn.disabled = false;
        confirmBtn.textContent = 'ASSIGN';
    }
}

/**
 * Show error in the release assignment modal
 * @param {string} message - Error message
 */
function showReleaseAssignError(message) {
    const errorDiv = document.getElementById('release-assign-error');
    if (errorDiv) {
        errorDiv.textContent = message;
        errorDiv.style.display = 'block';
    }
}

/**
 * Submit release unassignment
 */
async function submitReleaseUnassignment() {
    const unassignBtn = document.getElementById('release-unassign-btn');
    const currentAssignment = releaseAssignModalState.currentAssignment;

    if (!currentAssignment || !currentAssignment.releaseId) {
        showReleaseAssignError('No current assignment to remove');
        return;
    }

    // Show loading state
    if (unassignBtn) {
        unassignBtn.disabled = true;
        unassignBtn.textContent = 'REMOVING...';
    }

    try {
        const response = await apiFetch(apiUrl(`/api/releases/${currentAssignment.releaseId}/items/${releaseAssignModalState.itemId}`), {
            method: 'DELETE'
        });

        if (!response.ok) {
            const error = await response.text();
            throw new Error(error || 'Failed to unassign item');
        }

        console.log('Item unassigned from release');

        // Close modal and refresh
        hideReleaseAssignModal();

        // Refresh releases view if visible
        const releasesSection = document.querySelector('.releases-section');
        if (releasesSection && releasesSection.classList.contains('active')) {
            loadReleases();
        }

        // Refresh kanban data to update release badge
        refreshData();

    } catch (e) {
        console.error('Error unassigning item:', e);
        showReleaseAssignError(e.message);
    } finally {
        if (unassignBtn) {
            unassignBtn.disabled = false;
            unassignBtn.textContent = 'UNASSIGN';
        }
    }
}

/**
 * Close modal when clicking outside
 */
document.addEventListener('click', function(e) {
    const modal = document.getElementById('release-assign-modal');
    if (e.target === modal) {
        hideReleaseAssignModal();
    }
});

/**
 * Close modal on Escape key
 */
document.addEventListener('keydown', function(e) {
    if (e.key === 'Escape') {
        const modal = document.getElementById('release-assign-modal');
        if (modal && modal.style.display !== 'none') {
            hideReleaseAssignModal();
        }
        const createModal = document.getElementById('release-create-modal');
        if (createModal && createModal.style.display !== 'none') {
            hideCreateReleaseModal();
        }
        // XACA-0026: Close Promote modal on Escape
        const promoteModal = document.getElementById('promote-modal');
        if (promoteModal && promoteModal.style.display !== 'none') {
            hidePromoteModal();
        }
        // XACA-0026: Close Relnotes modal on Escape
        const relnotesModal = document.getElementById('relnotes-modal');
        if (relnotesModal && relnotesModal.style.display !== 'none') {
            hideRelnotesModal();
        }
        const editModal = document.getElementById('release-edit-modal');
        if (editModal && editModal.style.display !== 'none') {
            hideEditReleaseModal();
        }
    }
});

// ═══════════════════════════════════════════════════════════════════════════════
// CREATE RELEASE MODAL
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Show the Create Release modal
 */
function showCreateReleaseModal() {
    pauseAutoRefresh();

    const modal = document.getElementById('release-create-modal');
    if (!modal) return;

    // Reset form fields
    document.getElementById('new-release-title').value = '';
    document.getElementById('new-release-short-title').value = '';  // XACA-0050
    document.getElementById('new-release-type').value = 'feature';
    document.getElementById('new-release-target-date').value = '';
    document.getElementById('new-release-description').value = '';
    document.getElementById('new-release-tags').value = '';  // XACA-0209

    // Reset platform checkboxes to all checked
    const checkboxes = document.querySelectorAll('#new-release-platforms input[type="checkbox"]');
    checkboxes.forEach(cb => cb.checked = true);

    // Clear any previous errors
    const errorDiv = document.getElementById('release-create-error');
    if (errorDiv) {
        errorDiv.style.display = 'none';
        errorDiv.textContent = '';
    }

    // Show modal
    modal.style.display = 'flex';

    // Focus on name input
    setTimeout(() => {
        document.getElementById('new-release-title').focus();
    }, 100);
}

/**
 * Hide the Create Release modal
 */
function hideCreateReleaseModal() {
    resumeAutoRefresh();

    const modal = document.getElementById('release-create-modal');
    if (modal) {
        modal.style.display = 'none';
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// EPIC MANAGEMENT (XACA-0040)
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Release state management
 */
let releasesState = {
    expandedReleases: new Set(),
    statusFilter: 'active'  // XACA-0056: 'planned', 'active', or 'archived'
};

/**
 * XACA-0056: Toggle releases status filter between active and archived
 */
function toggleReleasesStatusFilter(status) {
    releasesState.statusFilter = status;
    loadReleases();
}

/**
 * XACA-0056: Update toggle button UI to reflect current filter
 */
function updateReleasesStatusToggle() {
    const plannedBtn = document.getElementById('releases-planned-btn');
    const activeBtn = document.getElementById('releases-active-btn');
    const archivedBtn = document.getElementById('releases-archived-btn');

    [plannedBtn, activeBtn, archivedBtn].forEach(btn => {
        if (btn) btn.classList.remove('active');
    });

    const filter = releasesState.statusFilter;
    if (filter === 'planned' && plannedBtn) {
        plannedBtn.classList.add('active');
    } else if (filter === 'archived' && archivedBtn) {
        archivedBtn.classList.add('active');
    } else if (activeBtn) {
        activeBtn.classList.add('active');
    }
}

/**
 * Epic state management
 */
let epicsState = {
    epics: [],
    colors: {},
    expandedEpics: new Set(),
    stateFilter: localStorage.getItem('lcars-epics-state-filter') || 'active'  // XACA-0474: 'planned' | 'active' | 'archived'
};

/**
 * XACA-0474: Toggle epics state filter (planned | active | archived)
 */
function toggleEpicsStateFilter(state) {
    epicsState.stateFilter = state;
    try {
        localStorage.setItem('lcars-epics-state-filter', state);
    } catch (e) {
        console.warn('lcars: Could not persist epics state filter to localStorage', e);
    }
    updateEpicsStateToggle();
    loadEpics();
}

/**
 * XACA-0474: Update toggle button UI to reflect current epics state filter
 */
function updateEpicsStateToggle() {
    const plannedBtn = document.getElementById('epics-planned-btn');
    const activeBtn = document.getElementById('epics-active-btn');
    const archivedBtn = document.getElementById('epics-archived-btn');

    [plannedBtn, activeBtn, archivedBtn].forEach(btn => {
        if (btn) btn.classList.remove('active');
    });

    const filter = epicsState.stateFilter;
    if (filter === 'planned' && plannedBtn) {
        plannedBtn.classList.add('active');
    } else if (filter === 'archived' && archivedBtn) {
        archivedBtn.classList.add('active');
    } else if (activeBtn) {
        activeBtn.classList.add('active');
    }
}

/**
 * Fetch and display epics
 */
async function loadEpics() {
    const dashboard = document.getElementById('epics-dashboard');
    if (!dashboard) return;

    dashboard.innerHTML = '<div class="epics-loading">Loading epics...</div>';

    // XACA-0474: Update toggle buttons to reflect current state filter
    updateEpicsStateToggle();

    try {
        // XACA-0209 round 5: tag filtering moved fully client-side — see displayEpics.
        // XACA-0474: state filter applied server-side via ?state= query param.
        const stateParam = epicsState.stateFilter ? `?state=${encodeURIComponent(epicsState.stateFilter)}` : '';
        const response = await fetch(apiUrl(`/api/epics${stateParam}`));
        if (!response.ok) {
            const errorText = await response.text();
            throw new Error(`Server returned ${response.status}: ${errorText || response.statusText}`);
        }
        const data = await response.json();

        epicsState.epics = data.epics || [];
        epicsState.colors = data.colors || {};

        displayEpics(epicsState.epics);
    } catch (e) {
        console.error('Could not load epics:', e);
        dashboard.innerHTML = `
            <div class="epics-empty">
                <div class="epics-empty-icon">⚠</div>
                <div class="epics-empty-text">Error loading epics</div>
                <div class="epics-empty-hint">${escapeHtml(e.message)}</div>
            </div>
        `;
    }
}

/**
 * Display epics in the dashboard
 * @param {Array} epics - Array of epic objects
 */
function displayEpics(epics) {
    const dashboard = document.getElementById('epics-dashboard');
    if (!dashboard) return;

    if (!epics || epics.length === 0) {
        // XACA-0474: filter-aware empty state messages
        let emptyIcon, emptyTitle, emptyHint;
        const filter = epicsState.stateFilter;
        if (filter === 'planned') {
            emptyIcon = '🗓';
            emptyTitle = 'No Planned Epics';
            emptyHint = 'Epics appear here when created but no items have been started.';
        } else if (filter === 'archived') {
            emptyIcon = '📁';
            emptyTitle = 'No Archived Epics';
            emptyHint = 'Epics appear here when all their items are completed, or all were cancelled.';
        } else {
            emptyIcon = '📚';
            emptyTitle = 'No Active Epics';
            emptyHint = 'Start work on an epic\'s items to see it here.';
        }
        dashboard.innerHTML = `
            <div class="epics-empty">
                <div class="epics-empty-icon">${emptyIcon}</div>
                <div class="epics-empty-text">${emptyTitle}</div>
                <div class="epics-empty-hint">${emptyHint}</div>
            </div>
        `;
        return;
    }

    // XACA-0209 round 5: client-side search filter over id/title/shortTitle/description/tags.
    if (epicSearchText) {
        epics = epics.filter(e => itemMatchesSearch(e, epicSearchText));
        if (epics.length === 0) {
            dashboard.innerHTML = `
                <div class="epics-empty">
                    <div class="epics-empty-icon">🔍</div>
                    <div class="epics-empty-text">No epics match "${escapeHtml(epicSearchText)}"</div>
                    <div class="epics-empty-hint">Try a different search term, or clear the filter.</div>
                </div>
            `;
            return;
        }
    }

    const html = epics.map(epic => renderEpicCard(epic)).join('');
    dashboard.innerHTML = html;

    // XACA-0209 round 5: delegated click handler for item tag pills.
    bindItemTagClicks(dashboard);

    // XACA-0045: Check plan existence for DOCS buttons
    checkPlanDocsButtons(dashboard);
}

/**
 * Render a single epic card
 * @param {Object} epic - Epic object
 */
function renderEpicCard(epic) {
    const colorHex = epicsState.colors[epic.color]?.hex || '#4a90d9';
    const isExpanded = epicsState.expandedEpics.has(epic.id);
    const expandedClass = isExpanded ? 'expanded' : '';
    const completedCount = epic.completedCount || 0;
    const itemCount = epic.itemCount || 0;
    const cancelledCount = epic.cancelledCount || 0;
    // Empty (or fully-cancelled) epic has nothing left to do — show 100%.
    const progressPercent = itemCount > 0 ? Math.round((completedCount / itemCount) * 100) : 100;
    // Mirror release-card behavior (XACA-0206-001): surface cancelled count so
    // users see why the denominator shrank.
    const cancelledSuffix = cancelledCount > 0 ? ` <span class="epic-item-cancelled-count">(${cancelledCount} cancelled, excluded)</span>` : '';

    // XACA-0209 round 5: purple tag pills on each epic card — clicking a pill
    // sets the epic search input (handler wired via bindItemTagClicks).
    const tagsHtml = buildItemTagsHtml(epic.tags, 'epic');

    // XACA-0474: derive state class from epic.state field (UPPERCASE from API, lowercase for CSS)
    const epicStateToken = (epic.state || 'active').toLowerCase();
    const epicStateAttr = (epic.state || 'ACTIVE').toUpperCase();

    return `
        <div class="epic-card ${expandedClass} epic-state-${epicStateToken}" data-epic-id="${epic.id}" data-epic-state="${epicStateAttr}" style="--epic-color: ${colorHex}">
            <div class="epic-card-header" onclick="toggleEpicExpanded('${epic.id}')">
                <div class="epic-color-indicator" style="background-color: ${colorHex}"></div>
                <div class="epic-card-info">
                    <div class="epic-card-title-row">
                        <span class="epic-card-id" role="button" tabindex="0" title="Click to copy Epic ID to clipboard" aria-label="Epic ID: ${escapeHtml(epic.id)}. Click to copy." onclick="event.stopPropagation(); copyToClipboard('${jsAttrEscape(epic.id)}')" onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();event.stopPropagation();copyToClipboard('${jsAttrEscape(epic.id)}');}">${escapeHtml(epic.id)}</span>
                        <span class="epic-card-name">${epic.shortTitle ? escapeHtml(epic.shortTitle) + ' — ' + escapeHtml(epic.title || epic.name) : escapeHtml(epic.title || epic.name)}</span>
                    </div>
                    <div class="epic-card-meta">
                        <span class="epic-item-count">${itemCount} items</span>
                        <span class="epic-progress-text">${completedCount}/${itemCount} complete${cancelledSuffix}</span>
                    </div>
                </div>
                <div class="epic-card-header-right">
                    ${tagsHtml}
                    <div class="epic-card-actions">
                        <button class="epic-action-btn docs" data-item-id="${epic.id}" onclick="event.stopPropagation(); showPlanDocModal('${epic.id}', this.getAttribute('data-retro-exists') === 'true', this.getAttribute('data-cr-exists') === 'true')" title="View Plan Document" style="display:none">DOCS</button>
                        <button class="epic-action-btn edit" onclick="event.stopPropagation(); showEditEpicModal('${epic.id}')" title="Edit Epic">✎</button>
                        <button class="epic-action-btn delete" onclick="event.stopPropagation(); confirmDeleteEpic('${epic.id}')" title="Delete Epic">✕</button>
                        <span class="epic-expand-icon">${isExpanded ? '▼' : '▶'}</span>
                    </div>
                </div>
            </div>
            <div class="epic-progress-bar">
                <div class="epic-progress-fill" style="width: ${progressPercent}%; background-color: ${colorHex}"></div>
            </div>
            <div class="epic-card-items" id="epic-items-${epic.id}">
                ${isExpanded ? '<div class="epic-items-loading">Loading items...</div>' : ''}
            </div>
        </div>
    `;
}

/**
 * Toggle epic expanded state
 */
async function toggleEpicExpanded(epicId) {
    const isExpanded = epicsState.expandedEpics.has(epicId);

    if (isExpanded) {
        epicsState.expandedEpics.delete(epicId);
    } else {
        epicsState.expandedEpics.add(epicId);
    }

    // Re-render the epic card
    const card = document.querySelector(`.epic-card[data-epic-id="${epicId}"]`);
    if (card) {
        card.classList.toggle('expanded', !isExpanded);
        const expandIcon = card.querySelector('.epic-expand-icon');
        if (expandIcon) {
            expandIcon.textContent = !isExpanded ? '▼' : '▶';
        }
    }

    // Load items if expanding
    if (!isExpanded) {
        await loadEpicItems(epicId);
    } else {
        const itemsContainer = document.getElementById(`epic-items-${epicId}`);
        if (itemsContainer) {
            itemsContainer.innerHTML = '';
        }
    }
}

/**
 * Load items for an epic
 */
async function loadEpicItems(epicId) {
    const itemsContainer = document.getElementById(`epic-items-${epicId}`);
    if (!itemsContainer) return;

    itemsContainer.innerHTML = '<div class="epic-items-loading">Loading items...</div>';

    try {
        const response = await fetch(apiUrl(`/api/epics/${epicId}/items`));
        if (!response.ok) throw new Error('Failed to fetch epic items');
        const data = await response.json();

        if (!data.items || data.items.length === 0) {
            itemsContainer.innerHTML = '<div class="epic-no-items">No items assigned to this epic</div>';
            return;
        }

        const itemsHtml = data.items.map(item => {
            const isCompleted = item.status === 'done' || item.status === 'completed';
            const isCancelled = item.status === 'cancelled';
            const stateClass = isCompleted ? 'completed' : (isCancelled ? 'cancelled' : '');
            return `
            <div class="epic-item ${stateClass}" data-item-id="${item.itemId}">
                <span class="epic-item-id" role="button" tabindex="0" title="Click to copy item ID to clipboard" aria-label="Item ID: ${escapeHtml(item.itemId)}. Click to copy." onclick="event.stopPropagation(); copyToClipboard('${jsAttrEscape(item.itemId)}')" onkeydown="if(event.key==='Enter'||event.key===' '){event.preventDefault();event.stopPropagation();copyToClipboard('${jsAttrEscape(item.itemId)}');}">${escapeHtml(item.itemId)}</span>
                <span class="epic-item-status status-${item.status}">${item.status.toUpperCase()}</span>
                <span class="epic-item-title">${escapeHtml(item.title)}</span>
                <span class="epic-item-team">${item.team}</span>
                <button class="epic-item-docs" data-item-id="${item.itemId}" onclick="event.stopPropagation(); showPlanDocModal('${item.itemId}', this.getAttribute('data-retro-exists') === 'true', this.getAttribute('data-cr-exists') === 'true')" title="View Plan Document" style="display:none">DOCS</button>
                <button class="epic-item-remove" onclick="removeItemFromEpic('${epicId}', '${item.itemId}')" title="Remove from epic">✕</button>
            </div>
        `;
        }).join('');

        itemsContainer.innerHTML = itemsHtml;

        // Check for plan documents on each item
        checkEpicItemsDocs(data.items);
    } catch (e) {
        itemsContainer.innerHTML = `<div class="epic-items-error">Error loading items: ${escapeHtml(e.message)}</div>`;
    }
}

/**
 * Remove item from epic
 */
async function removeItemFromEpic(epicId, itemId) {
    if (!confirm('Remove this item from the epic?')) return;

    try {
        const response = await apiFetch(apiUrl(`/api/epics/${epicId}/items/${itemId}`), {
            method: 'DELETE'
        });

        if (!response.ok) throw new Error('Failed to remove item');

        // Refresh epic items and main list
        await loadEpicItems(epicId);
        await loadEpics();
    } catch (e) {
        alert(`Error removing item: ${e.message}`);
    }
}

/**
 * Show create epic modal
 */
function showCreateEpicModal() {
    pauseAutoRefresh();

    const modal = document.getElementById('epic-create-modal');
    if (!modal) {
        // Create modal if it doesn't exist
        createEpicModals();
    }

    // Reset form
    const nameInput = document.getElementById('new-epic-name');
    const descInput = document.getElementById('new-epic-description');
    const colorSelect = document.getElementById('new-epic-color');
    const prioritySelect = document.getElementById('new-epic-priority');
    const statusSelect = document.getElementById('new-epic-status');

    if (nameInput) nameInput.value = '';
    if (descInput) descInput.value = '';
    if (colorSelect) colorSelect.value = 'blue';
    if (prioritySelect) prioritySelect.value = 'medium';
    if (statusSelect) statusSelect.value = 'planning';
    const tagsInput = document.getElementById('new-epic-tags');  // XACA-0209
    if (tagsInput) tagsInput.value = '';

    // Clear errors
    const errorDiv = document.getElementById('epic-create-error');
    if (errorDiv) {
        errorDiv.style.display = 'none';
        errorDiv.textContent = '';
    }

    // Show modal
    const modalEl = document.getElementById('epic-create-modal');
    if (modalEl) {
        modalEl.style.display = 'flex';
        setTimeout(() => {
            document.getElementById('new-epic-name')?.focus();
        }, 100);
    }
}

/**
 * Hide create epic modal
 */
function hideCreateEpicModal() {
    resumeAutoRefresh();

    const modal = document.getElementById('epic-create-modal');
    if (modal) {
        modal.style.display = 'none';
    }
}

/**
 * Create epic from modal form
 */
async function createEpic() {
    const name = document.getElementById('new-epic-name')?.value.trim();
    const shortTitle = document.getElementById('new-epic-short-title')?.value.trim();  // XACA-0050
    const description = document.getElementById('new-epic-description')?.value.trim();
    const color = document.getElementById('new-epic-color')?.value || 'blue';
    const priority = document.getElementById('new-epic-priority')?.value || 'medium';
    const status = document.getElementById('new-epic-status')?.value || 'planning';

    if (!name) {
        showEpicError('epic-create-error', 'Epic name is required');
        return;
    }

    try {
        // XACA-0050: Include shortTitle in epic creation
        const epicData = { name, description, color, priority, status };
        if (shortTitle) {
            epicData.shortTitle = shortTitle;
        }

        // XACA-0209: Parse comma-separated tags, trim whitespace, drop empty strings
        const tagsRaw = document.getElementById('new-epic-tags')?.value || '';
        epicData.tags = tagsRaw.split(',').map(t => t.trim()).filter(t => t.length > 0);

        const response = await apiFetch(apiUrl('/api/epics'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(epicData)
        });

        if (!response.ok) {
            const error = await response.text();
            throw new Error(error || 'Failed to create epic');
        }

        hideCreateEpicModal();
        await loadEpics();

        // Update Queue tab's epic filter dropdown
        populateEpicFilterOptions();
    } catch (e) {
        showEpicError('epic-create-error', e.message);
    }
}

/**
 * Show edit epic modal
 */
async function showEditEpicModal(epicId) {
    pauseAutoRefresh();

    const modal = document.getElementById('epic-edit-modal');
    if (!modal) {
        createEpicModals();
    }

    // Load epic data
    try {
        const response = await fetch(apiUrl(`/api/epics/${epicId}`));
        if (!response.ok) throw new Error('Failed to load epic');
        const epic = await response.json();

        document.getElementById('edit-epic-id').value = epicId;
        document.getElementById('edit-epic-name').value = epic.name || epic.title || '';
        document.getElementById('edit-epic-short-title').value = epic.shortTitle || '';  // XACA-0050
        document.getElementById('edit-epic-description').value = epic.description || '';
        document.getElementById('edit-epic-color').value = epic.color || 'blue';
        document.getElementById('edit-epic-priority').value = epic.priority || 'medium';
        document.getElementById('edit-epic-status').value = epic.status || 'planning';

        // XACA-0855-013: read-only derived-state indicator, refreshed on every open —
        // mirrors `kb-epic show`'s side-by-side Status/State display so an editor isn't
        // misled by the raw STATUS dropdown when the rollup-derived state differs
        // (e.g. all items cancelled → ARCHIVED while STATUS still reads "planning").
        const derivedStateEl = document.getElementById('edit-epic-derived-state');
        if (derivedStateEl) {
            const derivedState = (epic.state || 'ACTIVE').toUpperCase();
            derivedStateEl.textContent = `Derived state: ${derivedState} (auto-updates from item status)`;
        }

        // XACA-0209: Pre-populate tags as comma-separated string
        const existingTags = Array.isArray(epic.tags) ? epic.tags : [];
        document.getElementById('edit-epic-tags').value = existingTags.join(', ');

        const modalEl = document.getElementById('epic-edit-modal');
        if (modalEl) {
            modalEl.style.display = 'flex';
        }
    } catch (e) {
        alert(`Error loading epic: ${e.message}`);
    }
}

/**
 * Hide edit epic modal
 */
function hideEditEpicModal() {
    resumeAutoRefresh();

    const modal = document.getElementById('epic-edit-modal');
    if (modal) {
        modal.style.display = 'none';
    }
}

/**
 * Update epic from modal form
 */
async function updateEpic() {
    const epicId = document.getElementById('edit-epic-id')?.value;
    const name = document.getElementById('edit-epic-name')?.value.trim();
    const shortTitle = document.getElementById('edit-epic-short-title')?.value.trim();  // XACA-0050
    const description = document.getElementById('edit-epic-description')?.value.trim();
    const color = document.getElementById('edit-epic-color')?.value || 'blue';
    const priority = document.getElementById('edit-epic-priority')?.value || 'medium';
    const status = document.getElementById('edit-epic-status')?.value || 'planning';

    if (!name) {
        showEpicError('epic-edit-error', 'Epic name is required');
        return;
    }

    try {
        // XACA-0050: Include shortTitle in update (can be empty to clear it)
        const epicData = { name, description, color, priority, status };
        epicData.shortTitle = shortTitle || null;

        // XACA-0209: Parse comma-separated tags, trim whitespace, drop empty strings
        // Always send tags (even empty array) so users can clear all tags on edit
        const tagsRaw = document.getElementById('edit-epic-tags')?.value || '';
        epicData.tags = tagsRaw.split(',').map(t => t.trim()).filter(t => t.length > 0);

        const response = await apiFetch(apiUrl(`/api/epics/${epicId}`), {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(epicData)
        });

        if (!response.ok) {
            const error = await response.text();
            throw new Error(error || 'Failed to update epic');
        }

        hideEditEpicModal();
        await loadEpics();

        // Update Queue tab's epic filter dropdown with new name
        populateEpicFilterOptions();

        // Also reload the backlog to update epic names on assigned items
        refreshData();
    } catch (e) {
        showEpicError('epic-edit-error', e.message);
    }
}

/**
 * Confirm and delete epic
 */
async function confirmDeleteEpic(epicId) {
    const epic = epicsState.epics.find(e => e.id === epicId);
    const epicName = epic?.name || epicId;

    if (!confirm(`Delete epic "${epicName}"? All items will be unassigned from this epic.`)) return;

    try {
        const response = await apiFetch(apiUrl(`/api/epics/${epicId}`), {
            method: 'DELETE'
        });

        if (!response.ok) throw new Error('Failed to delete epic');

        await loadEpics();

        // Update Queue tab's epic filter dropdown
        populateEpicFilterOptions();

        // Reload backlog to remove deleted epic badges from items
        refreshData();
    } catch (e) {
        alert(`Error deleting epic: ${e.message}`);
    }
}

/**
 * Show epic error message
 */
function showEpicError(elementId, message) {
    const errorDiv = document.getElementById(elementId);
    if (errorDiv) {
        errorDiv.textContent = message;
        errorDiv.style.display = 'block';
    }
}

/**
 * Create epic modals if they don't exist
 */
function createEpicModals() {
    // Check if modals already exist
    if (document.getElementById('epic-create-modal')) return;

    const colorOptions = Object.entries(epicsState.colors).map(([key, color]) =>
        `<option value="${key}">${color.name}</option>`
    ).join('') || `
        <option value="purple">Purple</option>
        <option value="blue">Blue</option>
        <option value="teal">Teal</option>
        <option value="green">Green</option>
        <option value="yellow">Yellow</option>
        <option value="orange">Orange</option>
        <option value="red">Red</option>
        <option value="pink">Pink</option>
    `;

    const priorityOptions = `
        <option value="low">Low</option>
        <option value="medium" selected>Medium</option>
        <option value="high">High</option>
        <option value="critical">Critical</option>
    `;

    const statusOptions = `
        <option value="planning" selected>Planning</option>
        <option value="active">Active</option>
        <option value="on_hold">On Hold</option>
        <option value="completed">Completed</option>
        <option value="cancelled">Cancelled</option>
    `;

    const modalsHtml = `
        <!-- Create Epic Modal -->
        <div class="lcars-modal-overlay" id="epic-create-modal" style="display: none;">
            <div class="lcars-modal epic-modal">
                <div class="lcars-modal-header purple">
                    <span class="lcars-modal-title">CREATE NEW EPIC</span>
                    <button class="lcars-modal-close" onclick="hideCreateEpicModal()">&times;</button>
                </div>
                <div class="lcars-modal-body">
                    <div class="modal-field">
                        <label class="modal-label">LABEL (OPTIONAL) <span class="modal-label-hint">For compact display in BACKLOG tab</span></label>
                        <input type="text" id="new-epic-short-title" class="modal-input" placeholder="e.g., Q1 Infrastructure" maxlength="20">
                    </div>
                    <div class="modal-field">
                        <label class="modal-label">EPIC NAME</label>
                        <input type="text" id="new-epic-name" class="modal-input" placeholder="Enter epic name...">
                    </div>
                    <div class="modal-field">
                        <label class="modal-label">DESCRIPTION (OPTIONAL)</label>
                        <textarea id="new-epic-description" class="modal-textarea" placeholder="Describe this epic..." rows="3"></textarea>
                    </div>
                    <div class="modal-field-row">
                        <div class="modal-field">
                            <label class="modal-label">PRIORITY</label>
                            <select id="new-epic-priority" class="modal-select">
                                ${priorityOptions}
                            </select>
                        </div>
                        <div class="modal-field">
                            <label class="modal-label">STATUS</label>
                            <select id="new-epic-status" class="modal-select">
                                ${statusOptions}
                            </select>
                        </div>
                    </div>
                    <div class="modal-field">
                        <label class="modal-label">COLOR</label>
                        <select id="new-epic-color" class="modal-select">
                            ${colorOptions}
                        </select>
                    </div>
                    <div class="modal-field">
                        <label class="modal-label">TAGS (OPTIONAL) <span class="modal-label-hint">Comma-separated, e.g. main-event, admin, ios</span></label>
                        <input type="text" class="modal-input" id="new-epic-tags" placeholder="e.g. main-event, admin (comma-separated)" autocomplete="off" data-lpignore="true" data-form-type="other" data-1p-ignore="true">
                    </div>
                    <div class="modal-error" id="epic-create-error" style="display: none;"></div>
                </div>
                <div class="lcars-modal-footer">
                    <button class="modal-btn modal-btn-cancel" onclick="hideCreateEpicModal()">CANCEL</button>
                    <button class="modal-btn modal-btn-confirm" onclick="createEpic()">CREATE</button>
                </div>
            </div>
        </div>

        <!-- Edit Epic Modal -->
        <div class="lcars-modal-overlay" id="epic-edit-modal" style="display: none;">
            <div class="lcars-modal epic-modal">
                <div class="lcars-modal-header purple">
                    <span class="lcars-modal-title">EDIT EPIC</span>
                    <button class="lcars-modal-close" onclick="hideEditEpicModal()">&times;</button>
                </div>
                <div class="lcars-modal-body">
                    <input type="hidden" id="edit-epic-id">
                    <div class="modal-field">
                        <label class="modal-label">LABEL (OPTIONAL) <span class="modal-label-hint">For compact display in BACKLOG tab</span></label>
                        <input type="text" id="edit-epic-short-title" class="modal-input" placeholder="e.g., Q1 Infrastructure" maxlength="20">
                    </div>
                    <div class="modal-field">
                        <label class="modal-label">EPIC NAME</label>
                        <input type="text" id="edit-epic-name" class="modal-input" placeholder="Enter epic name...">
                    </div>
                    <div class="modal-field">
                        <label class="modal-label">DESCRIPTION (OPTIONAL)</label>
                        <textarea id="edit-epic-description" class="modal-textarea" placeholder="Describe this epic..." rows="3"></textarea>
                    </div>
                    <div class="modal-field-row">
                        <div class="modal-field">
                            <label class="modal-label">PRIORITY</label>
                            <select id="edit-epic-priority" class="modal-select">
                                ${priorityOptions}
                            </select>
                        </div>
                        <div class="modal-field">
                            <label class="modal-label">STATUS</label>
                            <select id="edit-epic-status" class="modal-select">
                                ${statusOptions}
                            </select>
                            <div class="modal-derived-state" id="edit-epic-derived-state"></div>
                        </div>
                    </div>
                    <div class="modal-field">
                        <label class="modal-label">COLOR</label>
                        <select id="edit-epic-color" class="modal-select">
                            ${colorOptions}
                        </select>
                    </div>
                    <div class="modal-field">
                        <label class="modal-label">TAGS (OPTIONAL) <span class="modal-label-hint">Comma-separated, e.g. main-event, admin, ios</span></label>
                        <input type="text" class="modal-input" id="edit-epic-tags" placeholder="e.g. main-event, admin (comma-separated)" autocomplete="off" data-lpignore="true" data-form-type="other" data-1p-ignore="true">
                    </div>
                    <div class="modal-error" id="epic-edit-error" style="display: none;"></div>
                </div>
                <div class="lcars-modal-footer">
                    <button class="modal-btn modal-btn-cancel" onclick="hideEditEpicModal()">CANCEL</button>
                    <button class="modal-btn modal-btn-confirm" onclick="updateEpic()">SAVE</button>
                </div>
            </div>
        </div>
    `;

    // Append to body
    document.body.insertAdjacentHTML('beforeend', modalsHtml);
}

/**
 * Show epic assignment modal for backlog items
 */
async function showEpicAssignModal(itemId, itemTitle, team, currentEpicId) {
    pauseAutoRefresh();

    // Create modal if it doesn't exist
    let modal = document.getElementById('epic-assign-modal');
    if (!modal) {
        const modalHtml = `
            <div class="lcars-modal-overlay" id="epic-assign-modal" style="display: none;">
                <div class="lcars-modal epic-modal">
                    <div class="lcars-modal-header purple">
                        <span class="lcars-modal-title">ASSIGN TO EPIC</span>
                        <button class="lcars-modal-close" onclick="hideEpicAssignModal()">&times;</button>
                    </div>
                    <div class="lcars-modal-body">
                        <div class="assign-item-info">
                            <span class="assign-item-id"></span>
                            <span class="assign-item-title"></span>
                        </div>
                        <div class="epic-select-list" id="epic-select-list">
                            <div class="epics-loading">Loading epics...</div>
                        </div>
                        <div class="modal-error" id="epic-assign-error" style="display: none;"></div>
                    </div>
                    <div class="lcars-modal-footer">
                        <button class="modal-btn modal-btn-cancel" onclick="hideEpicAssignModal()">CANCEL</button>
                    </div>
                </div>
            </div>
        `;
        document.body.insertAdjacentHTML('beforeend', modalHtml);
        modal = document.getElementById('epic-assign-modal');
    }

    // Store current assignment context
    modal.dataset.itemId = itemId;
    modal.dataset.team = team;
    modal.dataset.currentEpicId = currentEpicId || '';

    // Update item info display
    modal.querySelector('.assign-item-id').textContent = `[${itemId}]`;
    modal.querySelector('.assign-item-title').textContent = itemTitle;

    // Load epics list
    const listEl = document.getElementById('epic-select-list');
    listEl.innerHTML = '<div class="epics-loading">Loading epics...</div>';

    try {
        const response = await fetch(apiUrl('/api/epics'));
        if (!response.ok) throw new Error('Failed to load epics');
        const data = await response.json();
        const epics = data.epics || [];

        if (epics.length === 0) {
            listEl.innerHTML = `
                <div class="epic-select-empty">
                    No epics available. Create an epic first.
                </div>
            `;
        } else {
            const html = epics.map(epic => {
                const isSelected = epic.id === currentEpicId;
                const colorHex = data.colors?.[epic.color]?.hex || '#4a90d9';
                // Display format: "ShortLabel — Title" or just title if no shortTitle
                const epicDisplayName = epic.shortTitle
                    ? `${epic.shortTitle} — ${epic.title || epic.name}`
                    : (epic.title || epic.name);
                // XACA-1005-001 (folded-in scope expansion): epic.id and
                // epic.title/epic.name land inside a JS STRING LITERAL within
                // an HTML attribute — selectEpicForItem('${...}', '${...}') —
                // not element content and not a plain quoted attribute. They
                // were escapeHtml()'d, which leaves BOTH ' and \ untouched.
                // epic.title is user-supplied (server.py's epic-creation POST
                // handler assigns the request body's `name` straight to the
                // "title" field with no escaping), so an epic titled
                // `'); alert(1); //` terminated the string literal and
                // executed arbitrary JS — a strictly worse outcome than an
                // attribute-only breakout. jsAttrEscape (XACA-0277) is the
                // escaper built for exactly this context: it escapes \ and '
                // in addition to the HTML metacharacters escapeHtml covers.
                // epic.id sits in the identical JS-string-literal slot one
                // argument over and gets the same escaper for consistency,
                // even though it is a server-assigned id rather than
                // free-text — the context, not the field's provenance, is
                // what determines the escaper.
                // 4th-round PR-gate fix, XACA-1005-023: data-epic-id below was
                // bare/unescaped and no ticket enumerated it (distinct from
                // the item.id/epic.id occurrences in renderDayItems(), which
                // ARE already tracked under XACA-1013 and are deliberately
                // left bare there to avoid colliding with that ticket).
                // Fixed here rather than deferred: it is one line, in a
                // function this ticket already touches, and escapeAttr() on
                // a compliant epic.id is a no-op (no HTML metacharacters to
                // escape), so there is no reason not to close it now.
                return `
                    <div class="epic-select-option ${isSelected ? 'selected' : ''}"
                         data-epic-id="${escapeAttr(epic.id)}"
                         onclick="selectEpicForItem('${jsAttrEscape(epic.id)}', '${jsAttrEscape(epic.title || epic.name)}')"
                         style="--epic-color: ${colorHex}">
                        <div class="epic-select-color" style="background-color: ${colorHex}"></div>
                        <div class="epic-select-info">
                            <div class="epic-select-name">${escapeHtml(epicDisplayName)}</div>
                            <div class="epic-select-meta">${epic.itemCount || 0} items</div>
                        </div>
                        ${isSelected ? '<span class="epic-select-check">✓</span>' : ''}
                    </div>
                `;
            }).join('');

            // Add "No Epic" option if currently assigned
            const noEpicHtml = currentEpicId ? `
                <div class="epic-select-option remove-epic"
                     onclick="removeEpicFromItem()">
                    <div class="epic-select-info">
                        <div class="epic-select-name">Remove from Epic</div>
                        <div class="epic-select-meta">Clear epic assignment</div>
                    </div>
                </div>
            ` : '';

            listEl.innerHTML = html + noEpicHtml;
        }
    } catch (e) {
        listEl.innerHTML = `<div class="epic-select-error">Error: ${escapeHtml(e.message)}</div>`;
    }

    // Show modal
    modal.style.display = 'flex';
}

/**
 * Hide epic assignment modal
 */
function hideEpicAssignModal() {
    resumeAutoRefresh();

    const modal = document.getElementById('epic-assign-modal');
    if (modal) {
        modal.style.display = 'none';
    }
}

/**
 * Select an epic for the current item
 */
async function selectEpicForItem(epicId, epicName) {
    const modal = document.getElementById('epic-assign-modal');
    if (!modal) return;

    const itemId = modal.dataset.itemId;
    const team = modal.dataset.team;

    try {
        const response = await apiFetch(apiUrl(`/api/epics/${epicId}/items`), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ itemId, team })
        });

        if (!response.ok) throw new Error('Failed to assign epic');

        hideEpicAssignModal();

        // Refresh the backlog to show new badge
        refreshData();

        // Refresh epics if on that section
        const epicsSection = document.querySelector('.epics-section');
        if (epicsSection && epicsSection.classList.contains('active')) {
            await loadEpics();
        }
    } catch (e) {
        const errorDiv = document.getElementById('epic-assign-error');
        if (errorDiv) {
            errorDiv.textContent = e.message;
            errorDiv.style.display = 'block';
        }
    }
}

/**
 * Remove epic from the current item
 */
async function removeEpicFromItem() {
    const modal = document.getElementById('epic-assign-modal');
    if (!modal) return;

    const itemId = modal.dataset.itemId;
    const currentEpicId = modal.dataset.currentEpicId;

    if (!currentEpicId) {
        hideEpicAssignModal();
        return;
    }

    try {
        const response = await apiFetch(apiUrl(`/api/epics/${currentEpicId}/items/${itemId}`), {
            method: 'DELETE'
        });

        if (!response.ok) throw new Error('Failed to remove from epic');

        hideEpicAssignModal();

        // Refresh the backlog
        refreshData();

        // Refresh epics if on that section
        const epicsSection = document.querySelector('.epics-section');
        if (epicsSection && epicsSection.classList.contains('active')) {
            await loadEpics();
        }
    } catch (e) {
        const errorDiv = document.getElementById('epic-assign-error');
        if (errorDiv) {
            errorDiv.textContent = e.message;
            errorDiv.style.display = 'block';
        }
    }
}

// =========================================================================
// PLAN DOCUMENT MODAL (XACA-0045)
// =========================================================================

/**
 * Render markdown content to HTML
 * Supports headers, lists, bold, italic, code blocks, links
 */
/**
 * Validate that a URL href uses an allowed scheme.
 * Permits http:, https:, mailto:, and relative paths (/, ./, ../, #, or no scheme).
 * Rejects javascript:, data:, vbscript:, and any other dangerous schemes.
 * XACA-0292-013: XSS hardening for CR doc rendering.
 * @param {string} href - The URL to validate (may already be HTML-entity-escaped)
 * @returns {string|null} The href if safe, or null if dangerous
 */
function validateUrlScheme(href) {
    if (!href) return null;
    // Decode HTML entities that escapeHtml may have introduced before scheme check
    const decoded = href
        .replace(/&amp;/g, '&')
        .replace(/&lt;/g, '<')
        .replace(/&gt;/g, '>')
        .replace(/&quot;/g, '"')
        .replace(/&#39;/g, "'");
    const trimmed = decoded.trim().toLowerCase();
    // Allowed absolute schemes
    if (trimmed.startsWith('http:') || trimmed.startsWith('https:') || trimmed.startsWith('mailto:')) {
        return href;
    }
    // Allowed relative paths
    if (trimmed.startsWith('/') || trimmed.startsWith('./') || trimmed.startsWith('../') || trimmed.startsWith('#')) {
        return href;
    }
    // No scheme at all (bare relative path like "foo/bar") — allowed if colon appears
    // after the first slash (query param), or there is no colon at all
    const colonPos = trimmed.indexOf(':');
    const slashPos = trimmed.indexOf('/');
    if (colonPos === -1 || (slashPos !== -1 && slashPos < colonPos)) {
        return href;
    }
    // Anything else (javascript:, data:, vbscript:, etc.) — reject
    return null;
}

function renderMarkdown(content) {
    if (!content) return '<div class="plan-doc-empty">No plan document available</div>';

    // XACA-0478: Strip HTML comments before any further processing so that
    // '<!-- plan_doc: canonical -->' and similar markers are invisible in the
    // rendered output. This matches CommonMark spec behavior (HTML comments are
    // not rendered). Must run before escapeHtml() to avoid encoding '<' as
    // '&lt;' which would make the comment visible as literal text in the UI.
    // Non-greedy [\s\S]*? handles multi-line comments correctly.
    content = content.replace(/<!--[\s\S]*?-->/g, '');

    // XACA-0292-013: XSS hardening — escape all raw HTML in the content FIRST so
    // that embedded <script> tags or HTML attributes become inert entities.
    // Code blocks are extracted before escaping so their content is preserved
    // verbatim (we escape them separately inside the replacement function).
    const codeBlockPlaceholders = [];
    let html = content.replace(/```(\w+)?\n([\s\S]*?)```/g, function(match, lang, code) {
        const idx = codeBlockPlaceholders.length;
        codeBlockPlaceholders.push(`<pre><code class="language-${lang || 'text'}">${escapeHtml(code.trim())}</code></pre>`);
        return `\x00CODEBLOCK${idx}\x00`;
    });

    // Escape all remaining content before any HTML injection via regex capture groups
    html = escapeHtml(html);

    // Restore pre-rendered code blocks. escapeHtml uses div.textContent which
    // browsers encode NUL as empty string (dropping the placeholder delimiters);
    // use a visible ASCII sentinel that won't appear in normal markdown instead.
    // NOTE: the NUL bytes above survive escapeHtml in V8/browser (they pass through
    // textContent unchanged), so this straightforward replacement works.
    html = html.replace(/\x00CODEBLOCK(\d+)\x00/g, function(match, idx) {
        return codeBlockPlaceholders[parseInt(idx, 10)] || '';
    });

    // Headers (must be at start of line)
    html = html.replace(/^### (.+)$/gm, '<h3>$1</h3>');
    html = html.replace(/^## (.+)$/gm, '<h2>$1</h2>');
    html = html.replace(/^# (.+)$/gm, '<h1>$1</h1>');

    // Horizontal rules
    html = html.replace(/^---$/gm, '<hr>');
    html = html.replace(/^\*\*\*$/gm, '<hr>');

    // Lists (unordered)
    html = html.replace(/^[\*\-] (.+)$/gm, '<li>$1</li>');

    // Lists (ordered)
    html = html.replace(/^\d+\. (.+)$/gm, '<li>$1</li>');

    // Bold
    html = html.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
    html = html.replace(/__(.+?)__/g, '<strong>$1</strong>');

    // Italic
    html = html.replace(/\*(.+?)\*/g, '<em>$1</em>');
    html = html.replace(/_(.+?)_/g, '<em>$1</em>');

    // Inline code
    html = html.replace(/`(.+?)`/g, '<code>$1</code>');

    // Links — validate href scheme; render as plain text if dangerous
    html = html.replace(/\[(.+?)\]\((.+?)\)/g, function(match, text, href) {
        const safeHref = validateUrlScheme(href);
        if (safeHref) {
            return `<a href="${safeHref}" target="_blank">${text}</a>`;
        }
        // Dangerous scheme — render link text only, no anchor element
        return text;
    });

    // Wrap consecutive <li> tags in <ul>
    html = html.replace(/(<li>.*<\/li>\n?)+/g, function(match) {
        return '<ul>' + match + '</ul>';
    });

    // Paragraphs (double line breaks)
    html = html.replace(/\n\n/g, '</p><p>');
    html = '<p>' + html + '</p>';

    // Clean up empty paragraphs
    html = html.replace(/<p><\/p>/g, '');
    html = html.replace(/<p>(<h[1-3]>)/g, '$1');
    html = html.replace(/(<\/h[1-3]>)<\/p>/g, '$1');
    html = html.replace(/<p>(<hr>)<\/p>/g, '$1');
    html = html.replace(/<p>(<ul>)/g, '$1');
    html = html.replace(/(<\/ul>)<\/p>/g, '$1');
    html = html.replace(/<p>(<pre>)/g, '$1');
    html = html.replace(/(<\/pre>)<\/p>/g, '$1');

    // Single line breaks to <br>
    html = html.replace(/\n/g, '<br>');

    return html;
}

/**
 * Show plan document modal for an item
 * @param {string} itemId - The kanban item ID
 * @param {boolean} retroExists - Whether a retrospective document exists
 * @param {boolean} [crExists=false] - Whether a CR document is available (XACA-0292)
 */
function showPlanDocModal(itemId, retroExists, crExists) {
    crExists = !!crExists; // normalise — callers may pass undefined when only 2 args given
    pauseAutoRefresh();

    // Create overlay
    const overlay = document.createElement('div');
    overlay.className = 'lcars-modal-overlay';
    overlay.id = 'plan-doc-modal-overlay';

    // Create modal
    const modal = document.createElement('div');
    modal.className = 'lcars-modal plan-doc-modal';
    modal.setAttribute('data-active-tab', 'plan');
    modal.setAttribute('data-item-id', itemId);

    // Create header
    const header = document.createElement('div');
    header.className = 'lcars-modal-header';
    header.innerHTML = `
        <span class="lcars-modal-title">PLAN DOCUMENT: ${escapeHtml(itemId)}</span>
        <button class="lcars-modal-close" onclick="hidePlanDocModal()">&times;</button>
    `;

    // Create tab bar when any secondary tab is present (retro and/or CR)
    let tabBar = null;
    if (retroExists || crExists) {
        tabBar = document.createElement('div');
        tabBar.className = 'plan-doc-tabs';

        const planTab = document.createElement('button');
        planTab.className = 'plan-doc-tab active';
        planTab.setAttribute('data-tab', 'plan');
        planTab.textContent = 'PLAN';
        planTab.onclick = function() { switchDocTab(itemId, 'plan'); };
        tabBar.appendChild(planTab);

        if (retroExists) {
            const retroTab = document.createElement('button');
            retroTab.className = 'plan-doc-tab';
            retroTab.setAttribute('data-tab', 'retro');
            retroTab.textContent = 'RETRO';
            retroTab.onclick = function() { switchDocTab(itemId, 'retro'); };
            tabBar.appendChild(retroTab);
        }

        if (crExists) {
            const crTab = document.createElement('button');
            crTab.className = 'plan-doc-tab';
            crTab.setAttribute('data-tab', 'cr');
            crTab.textContent = 'CR';
            crTab.onclick = function() { switchDocTab(itemId, 'cr'); };
            tabBar.appendChild(crTab);
        }
    }

    // Create body (for markdown content)
    const body = document.createElement('div');
    body.className = 'lcars-modal-body plan-doc-content';
    body.innerHTML = '<div class="plan-doc-loading">Loading plan document...</div>';

    // Assemble modal
    modal.appendChild(header);
    if (tabBar) modal.appendChild(tabBar);
    modal.appendChild(body);
    overlay.appendChild(modal);

    // Close on overlay click (but not modal click)
    overlay.addEventListener('click', function(e) {
        if (e.target === overlay) {
            hidePlanDocModal();
        }
    });

    // Add to page
    document.body.appendChild(overlay);

    // Animate in
    setTimeout(() => overlay.classList.add('active'), 10);

    // Fetch plan document content
    fetch(apiUrl('/api/kanban/' + itemId + '/plan-content'))
        .then(response => {
            if (!response.ok) {
                throw new Error('Plan document not found');
            }
            return response.json();
        })
        .then(data => {
            // Update title with filename if available
            if (data.filename) {
                header.querySelector('.lcars-modal-title').textContent =
                    `PLAN DOCUMENT: ${data.filename}`;
            }

            // Render markdown content
            body.innerHTML = renderMarkdown(data.content);
        })
        .catch(error => {
            console.error('Error loading plan document:', error);
            body.innerHTML = `
                <div class="plan-doc-error">
                    <strong>Error loading plan document</strong><br>
                    ${error.message}
                </div>
            `;
        });
}

/**
 * Hide plan document modal
 */
function hidePlanDocModal() {
    resumeAutoRefresh();

    const overlay = document.getElementById('plan-doc-modal-overlay');
    if (overlay) {
        overlay.classList.remove('active');
        setTimeout(() => overlay.remove(), 300);
    }
}

/**
 * Switch between plan and retro tabs in the doc modal
 */
function switchDocTab(itemId, tabType) {
    const overlay = document.getElementById('plan-doc-modal-overlay');
    if (!overlay) return;

    const modal = overlay.querySelector('.plan-doc-modal');
    if (!modal) return;

    // Update active tab styling
    const tabs = modal.querySelectorAll('.plan-doc-tab');
    tabs.forEach(tab => {
        tab.classList.toggle('active', tab.getAttribute('data-tab') === tabType);
    });

    // Update modal state
    modal.setAttribute('data-active-tab', tabType);

    // Update title
    const title = modal.querySelector('.lcars-modal-title');
    if (title) {
        if (tabType === 'retro') {
            title.textContent = `RETROSPECTIVE: ${itemId}`;
        } else if (tabType === 'cr') {
            title.textContent = `CR DOCUMENT: ${itemId}`;
        } else {
            title.textContent = `PLAN DOCUMENT: ${itemId}`;
        }
    }

    // Fetch and display content
    const body = modal.querySelector('.plan-doc-content');
    if (!body) return;

    let endpoint, loadingLabel, errorLabel;
    if (tabType === 'retro') {
        endpoint = 'retro-content';
        loadingLabel = 'retrospective';
        errorLabel = 'Retrospective not found';
    } else if (tabType === 'cr') {
        endpoint = 'cr-content';
        loadingLabel = 'CR document';
        errorLabel = 'CR document not found';
    } else {
        endpoint = 'plan-content';
        loadingLabel = 'plan document';
        errorLabel = 'Plan document not found';
    }

    body.innerHTML = '<div class="plan-doc-loading">Loading ' + loadingLabel + '...</div>';

    fetch(apiUrl('/api/kanban/' + itemId + '/' + endpoint))
        .then(response => {
            if (!response.ok) throw new Error(errorLabel);
            return response.json();
        })
        .then(data => {
            if (data.filename && title) {
                const prefix = tabType === 'retro' ? 'RETROSPECTIVE: '
                    : tabType === 'cr' ? 'CR DOCUMENT: '
                    : 'PLAN DOCUMENT: ';
                title.textContent = prefix + data.filename;
            }
            // New CR schema: cr-content may return { url, isExternal: true } when
            // the CR doc lives in Confluence (no markdown to render). Show a
            // launch button instead of attempting to render undefined content.
            if (tabType === 'cr' && data.isExternal && data.url) {
                body.innerHTML =
                    '<div class="cr-doc-launch-row" style="padding:24px;text-align:center;">' +
                    '<a class="cr-doc-launch" href="' + escapeHtml(data.url) + '" target="_blank" rel="noopener noreferrer">OPEN CR DOC →</a>' +
                    '</div>';
            } else {
                const mainContent = renderMarkdown(data.content || '');
                const cfUrl = (tabType === 'cr' && data.confluenceUrl && String(data.confluenceUrl).trim())
                    ? String(data.confluenceUrl).trim() : '';
                const footerHtml = cfUrl
                    ? '<div class="cr-confluence-footer">' +
                      '<a href="' + escapeHtml(cfUrl) + '" target="_blank" rel="noopener noreferrer">' +
                      '<span class="cr-confluence-icon">&#128196;</span>Published to Confluence' +
                      '</a></div>'
                    : '';
                body.innerHTML = mainContent + footerHtml;
            }
        })
        .catch(error => {
            console.error('Error loading ' + tabType + ':', error);
            body.innerHTML = '<div class="plan-doc-error"><strong>Error loading ' +
                loadingLabel + '</strong><br>' + error.message + '</div>';
        });
}

// =========================================================================
// FLOW CONFIG MODAL (XACA-0027)
// =========================================================================

/**
 * Current flow config state
 */
let flowConfigState = {
    stages: {
        DEV: { enabled: true, required: true },
        QA: { enabled: true, required: false },
        ALPHA: { enabled: true, required: false },
        BETA: { enabled: true, required: false },
        GAMMA: { enabled: true, required: false },
        PROD: { enabled: true, required: true }
    },
    // XACA-0163: per-project stage overrides from /api/release-config.
    // Keyed by project name; value is an ordered list of stages valid
    // for that project. Empty when no project overrides are configured.
    projectEnvironments: {}
};

/**
 * Show the Flow Config modal
 */
async function showFlowConfigModal() {
    pauseAutoRefresh();

    const modal = document.getElementById('flow-config-modal');
    if (!modal) return;

    // Load current flow config from server (include team for correct scoping)
    try {
        const response = await fetch(apiUrl(`/api/release-config?team=${encodeURIComponent(CONFIG.team)}`));
        if (response.ok) {
            const config = await response.json();
            if (config.flowConfig && config.flowConfig.stages) {
                flowConfigState.stages = config.flowConfig.stages;
            }
            // XACA-0163: keep per-project stage overrides in sync
            flowConfigState.projectEnvironments = config.projectEnvironments || {};
        }
    } catch (error) {
        console.error('Error loading flow config:', error);
    }

    // Set checkbox states based on loaded config
    const stages = ['qa', 'alpha', 'beta', 'gamma'];
    stages.forEach(stage => {
        const checkbox = document.getElementById(`flow-stage-${stage}`);
        if (checkbox) {
            const stageKey = stage.toUpperCase();
            checkbox.checked = flowConfigState.stages[stageKey]?.enabled !== false;
        }
    });

    // Update flow preview
    updateFlowPreview();

    // Clear any previous errors
    const errorDiv = document.getElementById('flow-config-error');
    if (errorDiv) {
        errorDiv.style.display = 'none';
        errorDiv.textContent = '';
    }

    // Show modal
    modal.style.display = 'flex';
}

/**
 * Hide the Flow Config modal
 */
function hideFlowConfigModal() {
    resumeAutoRefresh();

    const modal = document.getElementById('flow-config-modal');
    if (modal) {
        modal.style.display = 'none';
    }
}

/**
 * Update the flow preview based on current toggle states
 */
function updateFlowPreview() {
    const preview = document.getElementById('flow-preview');
    if (!preview) return;

    const allStages = ['DEV', 'QA', 'ALPHA', 'BETA', 'GAMMA', 'PROD'];
    const enabledStages = [];

    allStages.forEach(stage => {
        if (stage === 'DEV' || stage === 'PROD') {
            enabledStages.push(stage);
        } else {
            const checkbox = document.getElementById(`flow-stage-${stage.toLowerCase()}`);
            if (checkbox && checkbox.checked) {
                enabledStages.push(stage);
            }
        }
    });

    // Build preview HTML
    let html = '';
    enabledStages.forEach((stage, index) => {
        html += `<span class="flow-stage-badge">${stage}</span>`;
        if (index < enabledStages.length - 1) {
            html += '<span class="flow-arrow">→</span>';
        }
    });

    preview.innerHTML = html;
}

/**
 * Save the flow configuration
 */
async function saveFlowConfig() {
    const errorDiv = document.getElementById('flow-config-error');

    // Build stages config from checkboxes
    const stages = {
        DEV: { enabled: true, required: true },
        QA: { enabled: document.getElementById('flow-stage-qa')?.checked ?? true, required: false },
        ALPHA: { enabled: document.getElementById('flow-stage-alpha')?.checked ?? true, required: false },
        BETA: { enabled: document.getElementById('flow-stage-beta')?.checked ?? true, required: false },
        GAMMA: { enabled: document.getElementById('flow-stage-gamma')?.checked ?? true, required: false },
        PROD: { enabled: true, required: true }
    };

    try {
        const response = await apiFetch(apiUrl('/api/releases/flow-config'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ stages, team: CONFIG.team })
        });

        if (!response.ok) {
            const errorText = await response.text();
            throw new Error(errorText || 'Failed to save flow config');
        }

        // Update local state
        flowConfigState.stages = stages;

        // Show success toast
        showToast('Flow configuration saved', 'success');

        // Close modal
        hideFlowConfigModal();

        // Refresh releases display to reflect new flow
        if (typeof loadReleases === 'function') {
            loadReleases();
        }

    } catch (error) {
        console.error('Error saving flow config:', error);
        if (errorDiv) {
            errorDiv.textContent = error.message || 'Failed to save configuration';
            errorDiv.style.display = 'block';
        }
    }
}

// XACA-0163: canonical stage list. Used as the source of truth for any
// rendering that needs to honor the current flowConfig, so that toggling
// a stage in Configure Flow re-introduces it even for releases that were
// created when that stage was not in defaultEnvironments.
const CANONICAL_STAGES = ['DEV', 'QA', 'ALPHA', 'BETA', 'GAMMA', 'PROD'];

/**
 * Get enabled environments based on flow config
 */
function getEnabledEnvironments() {
    return CANONICAL_STAGES.filter(stage => {
        if (stage === 'DEV' || stage === 'PROD') return true;
        return flowConfigState.stages[stage]?.enabled !== false;
    });
}

/**
 * Get the stage list for a release, honoring the current flowConfig.
 * XACA-0163: release.environments is a frozen snapshot captured at
 * creation time, so filtering it would prevent flowConfig toggles from
 * re-adding previously disabled stages. Seed from CANONICAL_STAGES
 * (or projectEnvironments[release.project] if the board defines a
 * per-project override) and filter by flowConfig, so Configure Flow
 * is always authoritative for display and projectEnvironments is
 * honored as the hard per-project constraint.
 */
function getReleaseEnvironments(release, flowConfig, projectEnvironments) {
    const stages = flowConfig?.stages || {};
    const projectOverride =
        projectEnvironments && release && release.project
            ? projectEnvironments[release.project]
            : null;
    const baseStages =
        Array.isArray(projectOverride) && projectOverride.length > 0
            ? projectOverride
            : CANONICAL_STAGES;
    return baseStages.filter(stage => {
        if (stage === 'DEV' || stage === 'PROD') return true;
        return stages[stage]?.enabled !== false;
    });
}

/**
 * Update the current flow display in the releases header
 */
function updateCurrentFlowDisplay(flowConfig) {
    const display = document.getElementById('current-flow-display');
    if (!display) return;

    const allStages = ['DEV', 'QA', 'ALPHA', 'BETA', 'GAMMA', 'PROD'];
    const stages = flowConfig?.stages || {};
    const enabledStages = allStages.filter(stage => {
        if (stage === 'DEV' || stage === 'PROD') return true;
        return stages[stage]?.enabled !== false;
    });

    // Build compact flow display
    let html = '';
    enabledStages.forEach((stage, index) => {
        html += `<span class="flow-stage">${stage}</span>`;
        if (index < enabledStages.length - 1) {
            html += '<span class="flow-arrow">→</span>';
        }
    });

    display.innerHTML = html;
}

/**
 * Show error in Create Release modal
 */
function showCreateReleaseError(message) {
    const errorDiv = document.getElementById('release-create-error');
    if (errorDiv) {
        errorDiv.textContent = message;
        errorDiv.style.display = 'block';
    }
}

/**
 * Submit new release creation
 */
async function submitCreateRelease() {
    const nameInput = document.getElementById('new-release-title');
    const shortTitleInput = document.getElementById('new-release-short-title');  // XACA-0050
    const typeSelect = document.getElementById('new-release-type');
    const targetDateInput = document.getElementById('new-release-target-date');
    const descriptionInput = document.getElementById('new-release-description');
    const tagsInput = document.getElementById('new-release-tags');  // XACA-0209
    const platformCheckboxes = document.querySelectorAll('#new-release-platforms input[type="checkbox"]:checked');
    const errorDiv = document.getElementById('release-create-error');

    // Clear previous errors
    if (errorDiv) {
        errorDiv.style.display = 'none';
        errorDiv.textContent = '';
    }

    // Validate name
    const name = nameInput.value.trim();
    if (!name) {
        showCreateReleaseError('Release name is required');
        nameInput.focus();
        return;
    }

    // Validate platforms
    const platforms = Array.from(platformCheckboxes).map(cb => cb.value);
    if (platforms.length === 0) {
        showCreateReleaseError('Select at least one platform');
        return;
    }

    // Build release data
    const releaseData = {
        name: name,
        type: typeSelect.value,
        platforms: platforms
    };

    // Add optional fields
    const shortTitle = shortTitleInput.value.trim();  // XACA-0050
    if (shortTitle) {
        releaseData.shortTitle = shortTitle;
    }
    if (targetDateInput.value) {
        releaseData.targetDate = targetDateInput.value;
    }
    if (descriptionInput.value.trim()) {
        releaseData.description = descriptionInput.value.trim();
    }

    // XACA-0209: Parse comma-separated tags, trim whitespace, drop empty strings
    const tags = tagsInput.value.split(',').map(t => t.trim()).filter(t => t.length > 0);
    if (tags.length > 0) {
        releaseData.tags = tags;
    }

    try {
        const response = await apiFetch(apiUrl('/api/releases'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(releaseData)
        });

        if (!response.ok) {
            const error = await response.json();
            throw new Error(error.error || 'Failed to create release');
        }

        const result = await response.json();
        console.log('Release created:', result);

        // Close modal
        hideCreateReleaseModal();

        // Refresh releases dashboard
        loadReleases();

    } catch (error) {
        console.error('Error creating release:', error);
        showCreateReleaseError(error.message || 'Failed to create release');
    }
}

/**
 * Close Create Release modal when clicking outside
 */
document.addEventListener('click', function(e) {
    const modal = document.getElementById('release-create-modal');
    if (e.target === modal) {
        hideCreateReleaseModal();
    }
});

// ═══════════════════════════════════════════════════════════════════════════════
// EDIT RELEASE MODAL
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Show the Edit Release modal
 * @param {string} releaseId - The ID of the release to edit
 */
async function showEditReleaseModal(releaseId) {
    pauseAutoRefresh();

    const modal = document.getElementById('release-edit-modal');
    if (!modal) return;

    // Clear any previous errors
    const errorDiv = document.getElementById('release-edit-error');
    if (errorDiv) {
        errorDiv.style.display = 'none';
        errorDiv.textContent = '';
    }

    try {
        // Fetch releases to find the one we're editing
        const response = await fetch(apiUrl('/api/releases'));
        if (!response.ok) throw new Error('Failed to fetch releases');
        const data = await response.json();
        const release = (data.releases || []).find(r => r.id === releaseId);

        if (!release) {
            alert(`Release not found: ${releaseId}`);
            return;
        }

        // Populate form fields
        document.getElementById('edit-release-id').value = release.id;
        document.getElementById('edit-release-title').value = release.name || '';
        document.getElementById('edit-release-short-title').value = release.shortTitle || '';  // XACA-0050
        document.getElementById('edit-release-type').value = release.type || 'feature';
        document.getElementById('edit-release-target-date').value = release.targetDate || '';

        // XACA-0209: Pre-populate tags as comma-separated string
        const existingTags = Array.isArray(release.tags) ? release.tags : [];
        document.getElementById('edit-release-tags').value = existingTags.join(', ');

        // Set platform checkboxes - platforms is an object with keys like {ios: {...}, android: {...}}
        // Existing platforms: checked AND disabled (cannot remove)
        // New platforms: unchecked AND enabled (can add)
        const platformCheckboxes = document.querySelectorAll('#edit-release-platforms input[type="checkbox"]');
        const releasePlatforms = release.platforms || {};
        platformCheckboxes.forEach(cb => {
            const platformExists = cb.value in releasePlatforms;
            cb.checked = platformExists;
            cb.disabled = platformExists; // Lock existing platforms, allow adding new ones
            // Add visual indicator for locked platforms
            const label = cb.closest('.modal-checkbox-label');
            if (label) {
                label.classList.toggle('platform-locked', platformExists);
            }
        });

        // Show modal
        modal.style.display = 'flex';

        // Focus on name input
        setTimeout(() => {
            document.getElementById('edit-release-title').focus();
        }, 100);

    } catch (error) {
        console.error('Error loading release for edit:', error);
        alert('Failed to load release data: ' + error.message);
    }
}

/**
 * Hide the Edit Release modal
 */
function hideEditReleaseModal() {
    resumeAutoRefresh();

    const modal = document.getElementById('release-edit-modal');
    if (modal) {
        modal.style.display = 'none';
    }
}

/**
 * Show error in Edit Release modal
 */
function showEditReleaseError(message) {
    const errorDiv = document.getElementById('release-edit-error');
    if (errorDiv) {
        errorDiv.textContent = message;
        errorDiv.style.display = 'block';
    }
}

/**
 * Submit release edit
 */
async function submitEditRelease() {
    const releaseId = document.getElementById('edit-release-id').value;
    const nameInput = document.getElementById('edit-release-title');
    const shortTitleInput = document.getElementById('edit-release-short-title');  // XACA-0050
    const typeSelect = document.getElementById('edit-release-type');
    const targetDateInput = document.getElementById('edit-release-target-date');
    const tagsInput = document.getElementById('edit-release-tags');  // XACA-0209
    const errorDiv = document.getElementById('release-edit-error');

    // Clear previous errors
    if (errorDiv) {
        errorDiv.style.display = 'none';
        errorDiv.textContent = '';
    }

    // Validate name
    const name = nameInput.value.trim();
    if (!name) {
        showEditReleaseError('Release name is required');
        nameInput.focus();
        return;
    }

    // Collect newly added platforms (checked but not disabled)
    const platformCheckboxes = document.querySelectorAll('#edit-release-platforms input[type="checkbox"]');
    const newPlatforms = [];
    platformCheckboxes.forEach(cb => {
        if (cb.checked && !cb.disabled) {
            newPlatforms.push(cb.value);
        }
    });

    // Build update data
    const updateData = {
        name: name,
        type: typeSelect.value,
        targetDate: targetDateInput.value || null
    };

    // XACA-0050: Include shortTitle (can be empty to clear it)
    const shortTitle = shortTitleInput.value.trim();
    updateData.shortTitle = shortTitle || null;

    // XACA-0209: Parse comma-separated tags, trim whitespace, drop empty strings
    // Always send tags (even empty array) so users can clear all tags on edit
    updateData.tags = tagsInput.value.split(',').map(t => t.trim()).filter(t => t.length > 0);

    // Include new platforms if any were added
    if (newPlatforms.length > 0) {
        updateData.addPlatforms = newPlatforms;
    }

    try {
        const response = await apiFetch(apiUrl(`/api/releases/${releaseId}`), {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(updateData)
        });

        if (!response.ok) {
            const error = await response.json();
            throw new Error(error.error || 'Failed to update release');
        }

        const result = await response.json();
        console.log('Release updated:', result);

        // Close modal
        hideEditReleaseModal();

        // Refresh releases dashboard
        loadReleases();

        // Refresh board data to update release names on BACKLOG items
        loadBoardData();

    } catch (error) {
        console.error('Error updating release:', error);
        showEditReleaseError(error.message || 'Failed to update release');
    }
}

/**
 * Close Edit Release modal when clicking outside
 */
document.addEventListener('click', function(e) {
    const modal = document.getElementById('release-edit-modal');
    if (e.target === modal) {
        hideEditReleaseModal();
    }
});

// ═══════════════════════════════════════════════════════════════════════════════
// BACKUP STATUS
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Fetch and display backup system status
 */
async function loadBackupStatus() {
    try {
        const response = await fetch(apiUrl('/api/backup-status'));
        if (!response.ok) throw new Error('Failed to fetch backup status');
        const data = await response.json();
        displayBackupStatus(data);
    } catch (e) {
        console.log('Could not load backup status:', e);
        displayBackupStatus({
            status: 'error',
            error: e.message
        });
    }
}

/**
 * Display backup status in the UI
 */
function displayBackupStatus(data) {
    // Update status indicator
    const statusEl = document.getElementById('backup-system-status');
    if (statusEl) {
        const statusMap = {
            'configured': { text: 'OPERATIONAL', class: 'status-good' },
            'stale': { text: 'STALE', class: 'status-warning' },
            'not_configured': { text: 'NOT CONFIGURED', class: 'status-inactive' },
            'error': { text: 'ERROR', class: 'status-error' }
        };
        const status = statusMap[data.status] || { text: 'UNKNOWN', class: 'status-inactive' };
        statusEl.textContent = status.text;
        statusEl.className = 'stat-value ' + status.class;
    }

    // Update last run
    const lastRunEl = document.getElementById('backup-last-run');
    if (lastRunEl) {
        lastRunEl.textContent = data.lastRunAgo || 'NEVER';
    }

    // Update total count
    const totalEl = document.getElementById('backup-total-count');
    if (totalEl) {
        totalEl.textContent = data.totalBackups || '0';
    }

    // Update storage
    const storageEl = document.getElementById('backup-storage');
    if (storageEl) {
        storageEl.textContent = data.storageUsed || '0 B';
    }

    // Update boards list
    const boardsEl = document.getElementById('backup-boards');
    if (boardsEl && data.boards) {
        let html = '<div class="backup-boards-header">BOARD STATUS</div>';
        html += '<div class="backup-boards-grid">';

        const sortedBoards = Object.entries(data.boards).sort((a, b) => a[0].localeCompare(b[0]));

        for (const [board, info] of sortedBoards) {
            const actionClass = info.lastAction === 'backed_up' ? 'action-backup' :
                              info.lastAction === 'skipped' ? 'action-skip' :
                              info.lastAction === 'auto-restore' ? 'action-restore' :
                              info.lastAction === 'error' ? 'action-error' : 'action-unknown';

            // Parse last check time
            let checkTime = '--';
            if (info.lastCheck) {
                try {
                    const date = new Date(info.lastCheck);
                    checkTime = date.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' });
                } catch (e) {}
            }

            // Parse last actual backup time
            let backupTime = '--';
            let backupTimeDisplay = '--';
            if (info.lastBackup) {
                try {
                    const date = new Date(info.lastBackup);
                    const now = new Date();
                    const isToday = date.toDateString() === now.toDateString();
                    const isSameYear = date.getFullYear() === now.getFullYear();

                    if (isToday) {
                        // Same day: show time only
                        backupTime = date.toLocaleTimeString('en-US', {
                            hour: '2-digit',
                            minute: '2-digit'
                        });
                    } else if (isSameYear) {
                        // Same year, different day: show month/day + time
                        backupTime = date.toLocaleDateString('en-US', {
                            month: 'short',
                            day: 'numeric',
                            hour: '2-digit',
                            minute: '2-digit'
                        });
                    } else {
                        // Different year: include year for clarity
                        backupTime = date.toLocaleDateString('en-US', {
                            month: 'short',
                            day: 'numeric',
                            year: 'numeric',
                            hour: '2-digit',
                            minute: '2-digit'
                        });
                    }
                    backupTimeDisplay = `(backed up: ${backupTime})`;
                } catch (e) {}
            }

            html += `
                <div class="backup-board-item ${actionClass}">
                    <span class="board-name">${board.toUpperCase()}</span>
                    <span class="board-backup-time" title="Last actual backup">${backupTimeDisplay}</span>
                    <span class="board-action">${info.lastAction || '--'}</span>
                    <span class="board-time">${checkTime}</span>
                </div>
            `;
        }

        html += '</div>';

        // Add last run stats if available
        if (data.lastRunStats) {
            const stats = data.lastRunStats;
            html += `
                <div class="backup-stats-summary">
                    <span class="stats-item">Backed: ${stats.backedUp || 0}</span>
                    <span class="stats-item">Skipped: ${stats.skipped || 0}</span>
                    <span class="stats-item">Restored: ${stats.restored || 0}</span>
                    <span class="stats-item">Errors: ${stats.errors || 0}</span>
                </div>
            `;
        }

        boardsEl.innerHTML = html;
    }
}

// Store backup files data for filtering/sorting
let backupFilesData = null;
let backupSortOrder = 'desc'; // 'desc' = newest first, 'asc' = oldest first

/**
 * Fetch and display backup files list
 */
async function loadBackupFiles() {
    try {
        const response = await fetch(apiUrl('/api/backup-files'));
        if (!response.ok) throw new Error('Failed to fetch backup files');
        const data = await response.json();
        backupFilesData = data;
        populateTeamFilter(data);
        renderRetentionSummary(data);
        displayBackupFiles(data);
        setupBackupControls();
    } catch (e) {
        console.log('Could not load backup files:', e);
        backupFilesData = null;
        displayBackupFiles({
            teams: {},
            error: e.message
        });
    }
}

/**
 * Populate team filter dropdown
 */
function populateTeamFilter(data) {
    const filterEl = document.getElementById('backup-team-filter');
    if (!filterEl) return;

    const teams = Object.keys(data.teams || {}).sort();
    let html = '<option value="">ALL TEAMS</option>';
    for (const team of teams) {
        html += `<option value="${team}">${team.toUpperCase()}</option>`;
    }
    filterEl.innerHTML = html;
}

/**
 * Setup event listeners for filter and sort controls
 */
function setupBackupControls() {
    const filterEl = document.getElementById('backup-team-filter');
    const sortBtn = document.getElementById('backup-sort-toggle');

    if (filterEl && !filterEl.hasAttribute('data-initialized')) {
        filterEl.setAttribute('data-initialized', 'true');
        filterEl.addEventListener('change', () => {
            renderBackupFilesFiltered();
        });
    }

    if (sortBtn && !sortBtn.hasAttribute('data-initialized')) {
        sortBtn.setAttribute('data-initialized', 'true');
        sortBtn.addEventListener('click', () => {
            backupSortOrder = backupSortOrder === 'desc' ? 'asc' : 'desc';
            sortBtn.textContent = backupSortOrder === 'desc' ? 'NEWEST FIRST' : 'OLDEST FIRST';
            sortBtn.setAttribute('data-sort', backupSortOrder);
            renderBackupFilesFiltered();
        });
    }
}

/**
 * Render backup files with current filter/sort settings
 */
function renderBackupFilesFiltered() {
    if (!backupFilesData) return;

    const filterEl = document.getElementById('backup-team-filter');
    const selectedTeam = filterEl ? filterEl.value : '';

    // Filter data by selected team
    let filteredData;
    if (selectedTeam) {
        filteredData = {
            teams: { [selectedTeam]: backupFilesData.teams[selectedTeam] || [] },
            totalFiles: (backupFilesData.teams[selectedTeam] || []).length,
            totalSize: (backupFilesData.teams[selectedTeam] || []).reduce((sum, f) => sum + (f.size || 0), 0),
            totalSizeFormatted: formatBytes((backupFilesData.teams[selectedTeam] || []).reduce((sum, f) => sum + (f.size || 0), 0))
        };
    } else {
        filteredData = backupFilesData;
    }

    displayBackupFiles(filteredData, backupSortOrder);
}

/**
 * Display backup files in the UI
 */
function displayBackupFiles(data, sortOrder = 'desc') {
    const container = document.getElementById('backup-files-list');
    if (!container) return;

    if (data.error) {
        container.innerHTML = `<div class="backup-error">Error: ${escapeHtml(data.error)}</div>`;
        return;
    }

    const teams = data.teams || {};
    const teamNames = Object.keys(teams).sort();

    if (teamNames.length === 0) {
        container.innerHTML = '<div class="backup-empty">No backup files found</div>';
        return;
    }

    let html = '';

    // Summary header
    html += `
        <div class="backup-files-summary">
            <span class="summary-stat">Total Files: <strong>${data.totalFiles || 0}</strong></span>
            <span class="summary-stat">Total Size: <strong>${data.totalSizeFormatted || '0 B'}</strong></span>
        </div>
    `;

    // Team sections
    for (const teamName of teamNames) {
        let files = [...(teams[teamName] || [])];
        const teamSize = files.reduce((sum, f) => sum + (f.size || 0), 0);
        const teamSizeFormatted = formatBytes(teamSize);

        // Sort files by timestamp
        files.sort((a, b) => {
            const timeA = a.timestamp || '';
            const timeB = b.timestamp || '';
            return sortOrder === 'desc' ? timeB.localeCompare(timeA) : timeA.localeCompare(timeB);
        });

        html += `
            <div class="backup-team-section" data-team="${teamName}">
                <div class="backup-team-header">
                    <span class="team-name">${teamName.toUpperCase()}</span>
                    <span class="team-stats">${files.length} files • ${teamSizeFormatted}</span>
                </div>
                <div class="backup-files-grid">
        `;

        // Show files (limit to 10 per team for performance)
        const displayFiles = files.slice(0, 10);
        for (const file of displayFiles) {
            const timestamp = file.timestamp ? new Date(file.timestamp) : null;
            const dateStr = timestamp ? timestamp.toLocaleDateString('en-US', {
                month: 'short',
                day: 'numeric'
            }) : '--';
            const timeStr = timestamp ? timestamp.toLocaleTimeString('en-US', {
                hour: '2-digit',
                minute: '2-digit'
            }) : '--';

            html += `
                <div class="backup-file-item">
                    <span class="file-name">${file.filename || '--'}</span>
                    <span class="file-date">${dateStr}</span>
                    <span class="file-time">${timeStr}</span>
                    <span class="file-size">${file.sizeFormatted || '--'}</span>
                </div>
            `;
        }

        // Show "and X more" if there are additional files
        if (files.length > 10) {
            html += `
                <div class="backup-file-more">
                    +${files.length - 10} more files
                </div>
            `;
        }

        html += `
                </div>
            </div>
        `;
    }

    container.innerHTML = html;
}

/**
 * Format bytes to human-readable string (client-side helper)
 */
function formatBytes(bytes) {
    if (bytes === 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(1024));
    return (bytes / Math.pow(1024, i)).toFixed(1) + ' ' + units[i];
}

/**
 * Calculate retention summary from backup files
 * Based on retention policy: hourly (24h), daily (7d), weekly (4w), monthly (6m)
 */
function calculateRetentionSummary(data) {
    const now = new Date();
    const hourMs = 60 * 60 * 1000;
    const dayMs = 24 * hourMs;
    const weekMs = 7 * dayMs;
    const monthMs = 30 * dayMs;

    const summary = {
        hourly: { count: 0, oldest: null, newest: null, limit: 24 },
        daily: { count: 0, oldest: null, newest: null, limit: 7 },
        weekly: { count: 0, oldest: null, newest: null, limit: 4 },
        monthly: { count: 0, oldest: null, newest: null, limit: 6 },
        older: { count: 0, oldest: null, newest: null }
    };

    const teams = data.teams || {};
    for (const teamName of Object.keys(teams)) {
        const files = teams[teamName] || [];
        for (const file of files) {
            if (!file.timestamp) continue;
            const fileDate = new Date(file.timestamp);
            const age = now - fileDate;

            let bucket;
            if (age < dayMs) {
                bucket = 'hourly';
            } else if (age < weekMs) {
                bucket = 'daily';
            } else if (age < 4 * weekMs) {
                bucket = 'weekly';
            } else if (age < 6 * monthMs) {
                bucket = 'monthly';
            } else {
                bucket = 'older';
            }

            summary[bucket].count++;
            if (!summary[bucket].newest || fileDate > summary[bucket].newest) {
                summary[bucket].newest = fileDate;
            }
            if (!summary[bucket].oldest || fileDate < summary[bucket].oldest) {
                summary[bucket].oldest = fileDate;
            }
        }
    }

    return summary;
}

/**
 * Render retention summary visualization
 */
function renderRetentionSummary(data) {
    const summary = calculateRetentionSummary(data);
    const container = document.getElementById('backup-retention-summary');
    if (!container) return;

    const buckets = [
        { key: 'hourly', label: 'LAST 24H', color: '#00ff88' },
        { key: 'daily', label: 'LAST 7D', color: '#00ccff' },
        { key: 'weekly', label: 'LAST 4W', color: '#ffaa00' },
        { key: 'monthly', label: 'LAST 6M', color: '#ff6699' },
        { key: 'older', label: 'OLDER', color: '#888888' }
    ];

    const total = Object.values(summary).reduce((sum, b) => sum + b.count, 0);

    let html = '<div class="retention-bars">';
    for (const bucket of buckets) {
        const info = summary[bucket.key];
        const pct = total > 0 ? Math.round((info.count / total) * 100) : 0;
        const width = total > 0 ? Math.max(2, (info.count / total) * 100) : 0;

        html += `
            <div class="retention-bucket">
                <div class="retention-label">${bucket.label}</div>
                <div class="retention-bar-container">
                    <div class="retention-bar" style="width: ${width}%; background: ${bucket.color};"></div>
                </div>
                <div class="retention-count">${info.count}</div>
            </div>
        `;
    }
    html += '</div>';

    container.innerHTML = html;
}

// ═══════════════════════════════════════════════════════════════════════════════
// INTEGRATIONS SECTION
// External ticket tracking integration management
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Cached integrations data
 */
let integrationsData = null;

/**
 * Load and display integrations
 */
async function loadIntegrations() {
    const statusEl = document.getElementById('integration-system-status');
    const activeCountEl = document.getElementById('integration-active-count');
    const availableCountEl = document.getElementById('integration-available-count');
    const listEl = document.getElementById('integrations-list');

    try {
        const response = await fetch(apiUrl('/api/integrations'));
        if (!response.ok) throw new Error('Failed to fetch integrations');

        const data = await response.json();
        integrationsData = data.integrations || [];

        // Update status
        if (statusEl) {
            statusEl.textContent = 'ONLINE';
            statusEl.className = 'stat-value online';
        }

        // Count active integrations (those with credentials)
        const activeCount = integrationsData.filter(i => i.hasCredentials && i.enabled).length;
        const availableCount = integrationsData.filter(i => i.enabled).length;

        if (activeCountEl) activeCountEl.textContent = activeCount;
        if (availableCountEl) availableCountEl.textContent = availableCount;

        // Render integration cards
        renderIntegrationsList(integrationsData);

        // Enable add button to open modal
        const addBtn = document.getElementById('add-integration-btn');
        if (addBtn) {
            addBtn.disabled = false;
            addBtn.onclick = openIntegrationModal;
        }

    } catch (error) {
        console.error('Failed to load integrations:', error);

        if (statusEl) {
            statusEl.textContent = 'ERROR';
            statusEl.className = 'stat-value offline';
        }

        if (listEl) {
            listEl.innerHTML = `<div class="integrations-error">Failed to load integrations: ${escapeHtml(error.message)}</div>`;
        }
    }
}

/**
 * Render the integrations list
 */
function renderIntegrationsList(integrations) {
    const container = document.getElementById('integrations-list');
    if (!container) return;

    if (!integrations || integrations.length === 0) {
        container.innerHTML = '<div class="integrations-empty">No integrations configured</div>';
        return;
    }

    let html = '';

    for (const integration of integrations) {
        const iconClass = integration.icon || integration.type || 'default';
        const iconSymbol = getIntegrationIcon(integration.type);
        const statusClass = integration.hasCredentials ? 'connected' : 'no-creds';
        const statusText = integration.hasCredentials ? 'Connected' : 'No Credentials';
        const cardClass = integration.enabled ? '' : 'disabled';

        html += `
            <div class="integration-card ${cardClass}" data-integration-id="${integration.id}">
                <div class="integration-icon ${iconClass}">${iconSymbol}</div>
                <div class="integration-info">
                    <div class="integration-name">${escapeHtml(integration.name)}</div>
                    <div class="integration-type">${escapeHtml(integration.type.toUpperCase())}</div>
                    <div class="integration-url">${escapeHtml(integration.baseUrl || '--')}</div>
                </div>
                <div class="integration-status">
                    <span class="integration-status-badge ${statusClass}">${statusText}</span>
                    <div class="integration-actions">
                        <button class="integration-btn edit" onclick="editIntegration('${integration.id}')">Edit</button>
                        <button class="integration-btn test" onclick="testIntegration('${integration.id}')" ${!integration.hasCredentials ? 'disabled' : ''}>Test</button>
                    </div>
                </div>
            </div>
        `;
    }

    container.innerHTML = html;
}

/**
 * Get icon symbol for integration type
 */
function getIntegrationIcon(type) {
    const icons = {
        'jira': '🔷',
        'monday': '📅',
        'github': '🐙',
        'linear': '📐',
        'asana': '🎯',
        'trello': '📋',
        'custom': '🔌'
    };
    return icons[type] || '🔗';
}

/**
 * Test an integration connection
 */
async function testIntegration(integrationId) {
    const card = document.querySelector(`[data-integration-id="${integrationId}"]`);
    const testBtn = card?.querySelector('.integration-btn.test');

    if (testBtn) {
        testBtn.disabled = true;
        testBtn.textContent = 'Testing...';
    }

    try {
        const response = await apiFetch(apiUrl('/api/integrations/test'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ integrationId })
        });

        const result = await response.json();

        if (result.success) {
            showIntegrationTestResult(card, true, result.message);
        } else {
            showIntegrationTestResult(card, false, result.message);
        }
    } catch (error) {
        showIntegrationTestResult(card, false, error.message);
    } finally {
        if (testBtn) {
            testBtn.disabled = false;
            testBtn.textContent = 'Test';
        }
    }
}

/**
 * Show integration test result
 */
function showIntegrationTestResult(card, success, message) {
    if (!card) return;

    // Update status badge temporarily
    const badge = card.querySelector('.integration-status-badge');
    if (badge) {
        const originalClass = badge.className;
        const originalText = badge.textContent;

        badge.className = `integration-status-badge ${success ? 'connected' : 'disconnected'}`;
        badge.textContent = success ? 'OK' : 'FAILED';
        badge.title = message;

        // Show message below the card info
        let msgEl = card.querySelector('.integration-test-message');
        if (!msgEl) {
            msgEl = document.createElement('div');
            msgEl.className = 'integration-test-message';
            const info = card.querySelector('.integration-info');
            if (info) {
                info.appendChild(msgEl);
            } else {
                card.appendChild(msgEl);
            }
        }
        msgEl.textContent = message;
        msgEl.style.color = success ? 'var(--lcars-gold)' : 'var(--lcars-red)';
        msgEl.style.padding = '8px 12px';
        msgEl.style.fontSize = '0.85em';
        msgEl.style.borderTop = '1px solid var(--lcars-blue-dark)';

        // Restore after 5 seconds
        setTimeout(() => {
            badge.className = originalClass;
            badge.textContent = originalText;
            badge.title = '';
            if (msgEl) msgEl.remove();
        }, 5000);
    }
}

// escapeHtml() defined earlier (line ~10041) — single definition used globally

// ═══════════════════════════════════════════════════════════════════════════════
// RAG ENGINES - Load, Render, and Actions
// ═══════════════════════════════════════════════════════════════════════════════

async function loadRAGEngines() {
    const statusEl = document.getElementById('rag-system-status');
    const installedCountEl = document.getElementById('rag-installed-count');
    const runningCountEl = document.getElementById('rag-running-count');
    const listEl = document.getElementById('rag-engines-list');

    try {
        const response = await fetch(apiUrl('/api/rag-engines'));
        if (!response.ok) throw new Error('Failed to fetch RAG engines');

        const data = await response.json();
        const engines = data.engines || [];

        // Update overview stats
        const installedCount = engines.filter(e => e.status !== 'not_installed').length;
        const runningCount = engines.filter(e => e.status === 'running').length;
        const errorCount = engines.filter(e => e.status === 'error').length;

        if (installedCountEl) installedCountEl.textContent = installedCount;
        if (runningCountEl) runningCountEl.textContent = runningCount;

        // Derive system status from engine states
        if (statusEl) {
            let systemStatus, systemClass;
            if (engines.length === 0 || installedCount === 0) {
                systemStatus = 'NO ENGINES';
                systemClass = 'stat-value offline';
            } else if (errorCount > 0) {
                systemStatus = 'DEGRADED';
                systemClass = 'stat-value error';
            } else if (runningCount > 0) {
                systemStatus = 'ACTIVE';
                systemClass = 'stat-value online';
            } else {
                systemStatus = 'IDLE';
                systemClass = 'stat-value';
            }
            statusEl.textContent = systemStatus;
            statusEl.className = systemClass;
        }

        // Render engine cards
        renderRAGEnginesList(engines);

        // Auto-health-check any running engines in the background
        const runningEngines = engines.filter(e => e.status === 'running');
        if (runningEngines.length > 0) {
            setTimeout(() => {
                runningEngines.forEach(e => healthCheckRAGEngineSilent(e.id));
            }, 500);
        }

        // Start periodic health polling if engines are running
        startRAGEnginesHealthPolling(runningEngines.length > 0);

    } catch (error) {
        console.error('Failed to load RAG engines:', error);

        if (statusEl) {
            statusEl.textContent = 'ERROR';
            statusEl.className = 'stat-value offline';
        }

        if (listEl) {
            listEl.textContent = '';
            const errDiv = document.createElement('div');
            errDiv.className = 'rag-engines-error';
            errDiv.textContent = 'Failed to load RAG engines: ' + error.message;
            listEl.appendChild(errDiv);
        }
    }
}

function renderRAGEnginesList(engines) {
    const container = document.getElementById('rag-engines-list');
    if (!container) return;

    if (!engines || engines.length === 0) {
        container.innerHTML = '<div class="rag-engines-empty">No RAG engines configured. Use the engine presets to get started.</div>';
        return;
    }

    let html = '';

    for (const engine of engines) {
        // Python backend uses underscores (not_installed); CSS classes use hyphens (not-installed)
        const statusClass = (engine.status || 'not_installed').replace(/_/g, '-');
        const statusText = formatRAGStatus(engine.status);
        const icon = getRAGEngineIcon(engine.type);

        // Build version display and update badge strings
        const versionStr = engine.version ? `v${escapeHtml(engine.version)}` : '';
        const latestStr = engine.latestVersion ? `v${escapeHtml(engine.latestVersion)}` : '';
        const showUpdateBadge = engine.updateAvailable && engine.version && engine.latestVersion;
        const versionHtml = versionStr
            ? `<div class="rag-engine-version">${versionStr}</div>`
            : '';
        const updateBadgeHtml = showUpdateBadge
            ? `<div class="rag-engine-update-badge" data-current-version="${escapeHtml(engine.version)}" data-latest-version="${escapeHtml(engine.latestVersion)}">${versionStr} &rarr; ${latestStr}</div>`
            : '';

        html += `
            <div class="rag-engine-card ${statusClass}" data-engine-id="${escapeHtml(engine.id)}" data-update-available="${showUpdateBadge ? 'true' : 'false'}" data-current-version="${escapeHtml(engine.version || '')}" data-latest-version="${escapeHtml(engine.latestVersion || '')}">
                <div class="rag-engine-icon">${icon}</div>
                <div class="rag-engine-info">
                    <div class="rag-engine-name">${escapeHtml(engine.name)}</div>
                    <div class="rag-engine-type">${escapeHtml(engine.type)} · Port ${engine.port || '--'}</div>
                    <div class="rag-engine-desc">${escapeHtml(engine.dataDir || '--')}</div>
                    ${engine.contentStats ? renderRAGContentStats(engine.contentStats) : ''}
                    ${versionHtml}
                    ${updateBadgeHtml}
                </div>
                <div class="rag-engine-status">
                    <span class="rag-engine-status-badge ${statusClass}">${statusText}</span>
                    <div class="rag-engine-actions-row">
                        ${renderRAGEngineActions(engine)}
                    </div>
                </div>
                <div class="rag-engine-progress" id="rag-progress-${escapeHtml(engine.id)}">
                    <div class="rag-engine-progress-bar">
                        <div class="rag-engine-progress-fill" id="rag-progress-fill-${escapeHtml(engine.id)}"></div>
                    </div>
                    <div class="rag-engine-progress-text" id="rag-progress-text-${escapeHtml(engine.id)}"></div>
                </div>
                <div class="rag-engine-log" id="rag-log-${escapeHtml(engine.id)}">
                    <div class="rag-engine-log-header">
                        <span class="rag-engine-log-title" id="rag-log-title-${escapeHtml(engine.id)}"></span>
                        <button class="rag-engine-log-dismiss" onclick="dismissRAGEngineLog('${escapeHtml(engine.id)}')">&times;</button>
                    </div>
                    <pre class="rag-engine-log-body" id="rag-log-body-${escapeHtml(engine.id)}"></pre>
                </div>
            </div>
        `;
    }

    container.innerHTML = html;
}

function renderRAGContentStats(stats) {
    const total = stats.total || {};
    const processed = stats.processed || {};
    const failed = stats.failed || {};

    let parts = [];
    if (total.documents !== undefined) parts.push(`${total.documents} docs`);
    if (total.chunks !== undefined) parts.push(`${total.chunks} chunks`);
    if (processed.documents !== undefined) parts.push(`${processed.documents} processed`);
    if (failed.documents) parts.push(`${failed.documents} failed`);

    if (parts.length === 0) return '';
    return `<div class="rag-engine-content-stats">${escapeHtml(parts.join(' · '))}</div>`;
}

function getRAGEngineIcon(type) {
    const icons = {
        'lightrag': '🔮',
        'code-graph-rag': '🧬',
        'rag-anything': '📦'
    };
    return icons[type] || '🔧';
}

function formatRAGStatus(status) {
    const labels = {
        'not_installed': 'Not Installed',
        'installed': 'Installed',
        'running': 'Running',
        'error': 'Error'
    };
    return labels[status] || status || 'Unknown';
}

function renderRAGEngineActions(engine) {
    const actions = [];

    switch (engine.status) {
        case 'not_installed':
            actions.push(`<button class="rag-engine-btn install" onclick="installRAGEngine('${escapeHtml(engine.id)}')">Install</button>`);
            break;
        case 'installed':
            actions.push(`<button class="rag-engine-btn" onclick="startRAGEngine('${escapeHtml(engine.id)}')">Start</button>`);
            actions.push(`<button class="rag-engine-btn uninstall" onclick="uninstallRAGEngine('${escapeHtml(engine.id)}')">Uninstall</button>`);
            break;
        case 'running':
            actions.push(`<button class="rag-engine-btn" onclick="stopRAGEngine('${escapeHtml(engine.id)}')">Stop</button>`);
            actions.push(`<button class="rag-engine-btn" onclick="healthCheckRAGEngine('${escapeHtml(engine.id)}')">Health</button>`);
            break;
        case 'error':
            actions.push(`<button class="rag-engine-btn" onclick="startRAGEngine('${escapeHtml(engine.id)}')">Retry</button>`);
            actions.push(`<button class="rag-engine-btn uninstall" onclick="uninstallRAGEngine('${escapeHtml(engine.id)}')">Uninstall</button>`);
            break;
    }

    // Show Update button when an update is available (installed or running state)
    if (engine.updateAvailable && (engine.status === 'installed' || engine.status === 'running')) {
        actions.push(`<button class="rag-engine-btn update" id="rag-update-btn-${escapeHtml(engine.id)}" onclick="updateRAGEngine('${escapeHtml(engine.id)}')">Update</button>`);
    }

    // Always show configure and log buttons
    actions.push(`<button class="rag-engine-btn" onclick="editRAGEngine('${escapeHtml(engine.id)}')">Config</button>`);
    actions.push(`<button class="rag-engine-btn" onclick="viewRAGEngineLog('${escapeHtml(engine.id)}')">Log</button>`);

    return actions.join('');
}

function showRAGEngineLog(engineId, title, body, isError) {
    const logEl = document.getElementById(`rag-log-${engineId}`);
    const titleEl = document.getElementById(`rag-log-title-${engineId}`);
    const bodyEl = document.getElementById(`rag-log-body-${engineId}`);
    if (!logEl) return;

    if (titleEl) {
        titleEl.textContent = title;
        titleEl.className = 'rag-engine-log-title ' + (isError ? 'error' : 'success');
    }
    if (bodyEl) bodyEl.textContent = body || '(no details)';
    logEl.classList.add('active');
}

function dismissRAGEngineLog(engineId) {
    const logEl = document.getElementById(`rag-log-${engineId}`);
    if (logEl) logEl.classList.remove('active');
}

/**
 * Check all RAG engines for available updates and re-render cards with update badges.
 * Called by the "Check for Updates" toolbar button.
 */
async function checkAllRAGEngineUpdates() {
    const btn = document.getElementById('rag-check-updates-btn');
    if (btn) {
        btn.disabled = true;
        btn.textContent = 'CHECKING...';
    }

    try {
        const response = await apiFetch(apiUrl('/api/rag-engines/check-updates'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({})
        });
        const data = await response.json();

        if (data.error) {
            console.error('RAG update check error:', data.error);
            if (btn) btn.textContent = 'CHECK FAILED';
        } else if (data.results) {
            // Patch update info into currently rendered engine cards without full re-render
            let updatesFound = 0;
            for (const [engineId, updateInfo] of Object.entries(data.results)) {
                applyUpdateInfoToCard(engineId, updateInfo);
                if (updateInfo.update_available) updatesFound++;
            }
            if (btn) {
                btn.textContent = updatesFound > 0
                    ? `${updatesFound} UPDATE${updatesFound > 1 ? 'S' : ''} AVAILABLE`
                    : 'ALL UP TO DATE';
            }
        }
    } catch (err) {
        console.error('Failed to check RAG engine updates:', err);
        if (btn) btn.textContent = 'CHECK FAILED';
    } finally {
        if (btn) {
            btn.disabled = false;
            // Reset button text after a few seconds
            setTimeout(() => {
                if (btn) btn.textContent = 'CHECK FOR UPDATES';
            }, 4000);
        }
    }
}

/**
 * Apply update check results to an existing engine card without a full re-render.
 * Updates version badge visibility and update button presence.
 * @param {string} engineId
 * @param {{current_version: string|null, latest_version: string|null, update_available: boolean}} updateInfo
 */
function applyUpdateInfoToCard(engineId, updateInfo) {
    const card = document.querySelector(`.rag-engine-card[data-engine-id="${CSS.escape(engineId)}"]`);
    if (!card) return;

    const { current_version: currentVersion, latest_version: latestVersion, update_available: updateAvailable } = updateInfo;

    // Update card data attributes
    card.dataset.updateAvailable = updateAvailable ? 'true' : 'false';
    card.dataset.currentVersion = currentVersion || '';
    card.dataset.latestVersion = latestVersion || '';

    const infoDiv = card.querySelector('.rag-engine-info');
    if (!infoDiv) return;

    // Remove existing version/badge elements
    infoDiv.querySelectorAll('.rag-engine-version, .rag-engine-update-badge').forEach(el => el.remove());

    // Add version display
    if (currentVersion) {
        const versionEl = document.createElement('div');
        versionEl.className = 'rag-engine-version';
        versionEl.textContent = `v${currentVersion}`;
        infoDiv.appendChild(versionEl);
    }

    // Add update badge if applicable
    if (updateAvailable && currentVersion && latestVersion) {
        const badgeEl = document.createElement('div');
        badgeEl.className = 'rag-engine-update-badge';
        badgeEl.dataset.currentVersion = currentVersion;
        badgeEl.dataset.latestVersion = latestVersion;
        // Use textContent with unicode arrow to avoid XSS — no HTML injection
        badgeEl.textContent = `v${currentVersion} \u2192 v${latestVersion}`;
        infoDiv.appendChild(badgeEl);

        // Add update button to actions row if not already present
        const actionsRow = card.querySelector('.rag-engine-actions-row');
        if (actionsRow && !actionsRow.querySelector(`#rag-update-btn-${CSS.escape(engineId)}`)) {
            const updateBtn = document.createElement('button');
            updateBtn.className = 'rag-engine-btn update';
            updateBtn.id = `rag-update-btn-${engineId}`;
            updateBtn.textContent = 'Update';
            updateBtn.onclick = () => updateRAGEngine(engineId);
            // Insert before Config button
            const buttons = actionsRow.querySelectorAll('button');
            const configBtn = Array.from(buttons).find(b => b.textContent.trim() === 'Config');
            if (configBtn) {
                actionsRow.insertBefore(updateBtn, configBtn);
            } else {
                actionsRow.appendChild(updateBtn);
            }
        }
    } else {
        // Remove update button if no longer needed
        const existingUpdateBtn = card.querySelector(`#rag-update-btn-${CSS.escape(engineId)}`);
        if (existingUpdateBtn) existingUpdateBtn.remove();
    }
}

/**
 * Update a RAG engine package to the latest PyPI version.
 * Shows progress feedback on the card during the upgrade process.
 * @param {string} engineId
 */
async function updateRAGEngine(engineId) {
    const btn = document.getElementById(`rag-update-btn-${engineId}`);
    const progressEl = document.getElementById(`rag-progress-${engineId}`);
    const progressFillEl = document.getElementById(`rag-progress-fill-${engineId}`);
    const progressTextEl = document.getElementById(`rag-progress-text-${engineId}`);

    // Disable button and show progress
    if (btn) {
        btn.disabled = true;
        btn.textContent = 'Updating...';
    }

    if (progressEl) progressEl.classList.add('active');
    if (progressFillEl) {
        progressFillEl.classList.add('indeterminate');
        progressFillEl.style.width = '';
    }

    const steps = ['Stopping engine...', 'Upgrading package...', 'Restarting engine...'];
    let stepIdx = 0;

    const stepInterval = setInterval(() => {
        if (stepIdx < steps.length && progressTextEl) {
            progressTextEl.textContent = steps[stepIdx++];
        }
    }, 2000);

    try {
        const response = await apiFetch(apiUrl('/api/rag-engines/update'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ engineId })
        });
        const data = await response.json();

        clearInterval(stepInterval);

        if (progressFillEl) {
            progressFillEl.classList.remove('indeterminate');
            progressFillEl.style.width = '100%';
        }

        const success = data.status !== 'error' && !data.error;
        const message = data.message || (success ? 'Update complete' : 'Update failed');

        if (progressTextEl) {
            progressTextEl.textContent = message;
            progressTextEl.className = 'rag-engine-progress-text ' + (success ? 'success' : 'error');
        }

        // Refresh engine list after a brief delay to show the new version
        setTimeout(() => {
            if (progressEl) progressEl.classList.remove('active');
            if (progressFillEl) progressFillEl.style.width = '0%';
            loadRAGEngines();
        }, 2500);

    } catch (err) {
        clearInterval(stepInterval);

        if (progressFillEl) progressFillEl.classList.remove('indeterminate');
        if (progressTextEl) {
            progressTextEl.textContent = `Update failed: ${err.message}`;
            progressTextEl.className = 'rag-engine-progress-text error';
        }

        // Re-enable button on error
        if (btn) {
            btn.disabled = false;
            btn.textContent = 'Update';
        }

        setTimeout(() => {
            if (progressEl) progressEl.classList.remove('active');
        }, 4000);
    }
}

async function viewRAGEngineLog(engineId) {
    try {
        const response = await fetch(apiUrl(`/api/rag-engines/log?engineId=${encodeURIComponent(engineId)}`));
        const data = await response.json();
        if (data.error) {
            showRAGEngineLog(engineId, 'Log Error', data.error, true);
        } else {
            showRAGEngineLog(engineId, `Stderr Log: ${engineId}`, data.content || '(empty log)', false);
        }
    } catch (err) {
        showRAGEngineLog(engineId, 'Log Error', err.message, true);
    }
}

async function installRAGEngine(engineId) {
    if (!confirm(`Install RAG engine: ${engineId}?`)) return;

    const progressEl = document.getElementById(`rag-progress-${engineId}`);
    const fillEl = document.getElementById(`rag-progress-fill-${engineId}`);
    const textEl = document.getElementById(`rag-progress-text-${engineId}`);

    if (progressEl) progressEl.classList.add('active');

    // Show indeterminate progress — we don't know how long the backend will take
    if (fillEl) {
        fillEl.style.width = '';
        fillEl.classList.add('indeterminate');
    }
    if (textEl) {
        textEl.textContent = 'Installing... this may take a few minutes';
        textEl.className = 'rag-engine-progress-text';
    }

    try {
        const response = await apiFetch(apiUrl('/api/rag-engines/install'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ engineId })
        });

        const result = await response.json();

        // Stop indeterminate animation
        if (fillEl) fillEl.classList.remove('indeterminate');

        if (result.error) {
            if (fillEl) fillEl.style.width = '0%';
            if (textEl) {
                textEl.textContent = 'Installation failed (see log below)';
                textEl.className = 'rag-engine-progress-text error';
            }
            if (progressEl) progressEl.classList.remove('active');
            showRAGEngineLog(engineId, 'Installation Failed', result.error, true);
            return;
        }

        // Show success state, then refresh the full engine list
        if (fillEl) fillEl.style.width = '100%';
        if (textEl) {
            textEl.textContent = result.message || 'Installation complete';
            textEl.className = 'rag-engine-progress-text success';
        }
        setTimeout(() => {
            if (progressEl) progressEl.classList.remove('active');
            loadRAGEngines();
        }, 1500);

    } catch (error) {
        if (fillEl) {
            fillEl.classList.remove('indeterminate');
            fillEl.style.width = '0%';
        }
        if (textEl) {
            textEl.textContent = 'Installation error (see log below)';
            textEl.className = 'rag-engine-progress-text error';
        }
        if (progressEl) progressEl.classList.remove('active');
        showRAGEngineLog(engineId, 'Installation Error', error.message, true);
    }
}

async function uninstallRAGEngine(engineId) {
    if (!confirm(`Uninstall RAG engine: ${engineId}? This will remove all engine data.`)) return;

    const progressEl = document.getElementById(`rag-progress-${engineId}`);
    const fillEl = document.getElementById(`rag-progress-fill-${engineId}`);
    const textEl = document.getElementById(`rag-progress-text-${engineId}`);

    if (progressEl) progressEl.classList.add('active');
    if (fillEl) {
        fillEl.style.width = '';
        fillEl.classList.add('indeterminate');
    }
    if (textEl) {
        textEl.textContent = 'Uninstalling...';
        textEl.className = 'rag-engine-progress-text';
    }

    try {
        const response = await apiFetch(apiUrl('/api/rag-engines/uninstall'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ engineId })
        });

        const result = await response.json();
        if (fillEl) fillEl.classList.remove('indeterminate');

        if (result.status === 'error' || result.error) {
            if (fillEl) fillEl.style.width = '0%';
            if (textEl) {
                textEl.textContent = 'Uninstall failed (see log below)';
                textEl.className = 'rag-engine-progress-text error';
            }
            if (progressEl) progressEl.classList.remove('active');
            showRAGEngineLog(engineId, 'Uninstall Failed', result.message || result.error || 'Unknown error', true);
            return;
        }

        if (fillEl) fillEl.style.width = '100%';
        if (textEl) {
            textEl.textContent = result.message || 'Uninstalled successfully';
            textEl.className = 'rag-engine-progress-text success';
        }
        setTimeout(() => {
            if (progressEl) progressEl.classList.remove('active');
            loadRAGEngines();
        }, 1500);

    } catch (error) {
        if (fillEl) fillEl.classList.remove('indeterminate');
        if (textEl) {
            textEl.textContent = 'Uninstall error (see log below)';
            textEl.className = 'rag-engine-progress-text error';
        }
        if (progressEl) progressEl.classList.remove('active');
        showRAGEngineLog(engineId, 'Uninstall Error', error.message, true);
    }
}

async function startRAGEngine(engineId) {
    const progressEl = document.getElementById(`rag-progress-${engineId}`);
    const fillEl = document.getElementById(`rag-progress-fill-${engineId}`);
    const textEl = document.getElementById(`rag-progress-text-${engineId}`);

    if (progressEl) progressEl.classList.add('active');
    if (fillEl) {
        fillEl.style.width = '';
        fillEl.classList.add('indeterminate');
    }
    if (textEl) {
        textEl.textContent = 'Starting...';
        textEl.className = 'rag-engine-progress-text';
    }

    try {
        const response = await apiFetch(apiUrl('/api/rag-engines/start'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ engineId })
        });

        const result = await response.json();
        if (fillEl) fillEl.classList.remove('indeterminate');

        if (result.status === 'error' || result.error) {
            if (fillEl) fillEl.style.width = '0%';
            if (textEl) {
                textEl.textContent = 'Start failed (see log below)';
                textEl.className = 'rag-engine-progress-text error';
            }
            if (progressEl) progressEl.classList.remove('active');
            showRAGEngineLog(engineId, 'Start Failed', result.message || result.error || 'Unknown error', true);
            return;
        }

        if (fillEl) fillEl.style.width = '100%';
        if (textEl) {
            textEl.textContent = result.message || 'Engine started successfully';
            textEl.className = 'rag-engine-progress-text success';
        }
        setTimeout(() => {
            if (progressEl) progressEl.classList.remove('active');
            loadRAGEngines();
        }, 1500);

    } catch (error) {
        if (fillEl) fillEl.classList.remove('indeterminate');
        if (textEl) {
            textEl.textContent = 'Start error (see log below)';
            textEl.className = 'rag-engine-progress-text error';
        }
        if (progressEl) progressEl.classList.remove('active');
        showRAGEngineLog(engineId, 'Start Error', error.message, true);
    }
}

async function stopRAGEngine(engineId) {
    const progressEl = document.getElementById(`rag-progress-${engineId}`);
    const fillEl = document.getElementById(`rag-progress-fill-${engineId}`);
    const textEl = document.getElementById(`rag-progress-text-${engineId}`);

    if (progressEl) progressEl.classList.add('active');
    if (fillEl) {
        fillEl.style.width = '';
        fillEl.classList.add('indeterminate');
    }
    if (textEl) {
        textEl.textContent = 'Stopping...';
        textEl.className = 'rag-engine-progress-text';
    }

    try {
        const response = await apiFetch(apiUrl('/api/rag-engines/stop'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ engineId })
        });

        const result = await response.json();
        if (fillEl) fillEl.classList.remove('indeterminate');

        if (result.status === 'error' || result.error) {
            if (fillEl) fillEl.style.width = '0%';
            if (textEl) {
                textEl.textContent = 'Stop failed (see log below)';
                textEl.className = 'rag-engine-progress-text error';
            }
            if (progressEl) progressEl.classList.remove('active');
            showRAGEngineLog(engineId, 'Stop Failed', result.message || result.error || 'Unknown error', true);
            return;
        }

        if (fillEl) fillEl.style.width = '100%';
        if (textEl) {
            textEl.textContent = result.message || 'Engine stopped successfully';
            textEl.className = 'rag-engine-progress-text success';
        }
        setTimeout(() => {
            if (progressEl) progressEl.classList.remove('active');
            loadRAGEngines();
        }, 1500);

    } catch (error) {
        if (fillEl) fillEl.classList.remove('indeterminate');
        if (textEl) {
            textEl.textContent = 'Stop error (see log below)';
            textEl.className = 'rag-engine-progress-text error';
        }
        if (progressEl) progressEl.classList.remove('active');
        showRAGEngineLog(engineId, 'Stop Error', error.message, true);
    }
}

async function healthCheckRAGEngine(engineId) {
    const card = document.querySelector(`[data-engine-id="${engineId}"]`);
    const badge = card?.querySelector('.rag-engine-status-badge');

    if (badge) {
        badge.textContent = 'Checking...';
    }

    try {
        const response = await apiFetch(apiUrl('/api/rag-engines/health'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ engineId })
        });

        const result = await response.json();
        const status = result.results?.[engineId];

        if (status && badge) {
            badge.textContent = status.health || formatRAGStatus(status.status);
            const statusCssClass = (status.status || 'not_installed').replace(/_/g, '-');
            badge.className = `rag-engine-status-badge ${statusCssClass}`;

            // Show message temporarily
            if (status.message) {
                let msgEl = card.querySelector('.rag-engine-health-message');
                if (!msgEl) {
                    msgEl = document.createElement('div');
                    msgEl.className = 'rag-engine-health-message';
                    msgEl.style.cssText = 'font-size: 0.8em; padding: 6px 12px; color: var(--lcars-cyan); grid-column: 1 / -1;';
                    card.appendChild(msgEl);
                }
                msgEl.textContent = status.message;
                setTimeout(() => msgEl.remove(), 5000);
            }
        }

        // Full refresh after delay
        setTimeout(() => loadRAGEngines(), 3000);

    } catch (error) {
        if (badge) badge.textContent = 'Error';
        alert('Health check error: ' + error.message);
    }
}

function editRAGEngine(engineId) {
    // Find engine data from last load — re-fetch to be sure
    fetch(apiUrl('/api/rag-engines'))
        .then(r => r.json())
        .then(data => {
            const engine = (data.engines || []).find(e => e.id === engineId);
            if (engine) {
                openRAGEngineModal(engineId, engine);
            } else {
                alert('Engine not found: ' + engineId);
            }
        })
        .catch(err => alert('Failed to load engine data: ' + err.message));
}

/**
 * Silent health check — updates badge and card class without showing alerts.
 * Used for background auto-checks on load and periodic polling.
 */
async function healthCheckRAGEngineSilent(engineId) {
    try {
        const response = await apiFetch(apiUrl('/api/rag-engines/health'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ engineId })
        });

        const result = await response.json();
        const status = result.results?.[engineId];
        if (!status) return;

        const card = document.querySelector(`[data-engine-id="${engineId}"]`);
        if (!card) return;

        const badge = card.querySelector('.rag-engine-status-badge');
        const statusCssClass = (status.status || 'not_installed').replace(/_/g, '-');

        if (badge) {
            badge.textContent = formatRAGStatus(status.status);
            badge.className = `rag-engine-status-badge ${statusCssClass}`;
        }

        // Update card class to match new status
        card.className = card.className.replace(/\b(running|installed|not-installed|error)\b/g, '').trim();
        card.classList.add(statusCssClass);

    } catch (_err) {
        // Silent — don't surface errors from background health checks
    }
}

/**
 * Start/stop periodic health polling for running RAG engines.
 * @param {boolean} hasRunning - true if any engines are currently running
 */
function startRAGEnginesHealthPolling(hasRunning) {
    // Clear any existing poll
    if (ragEnginesHealthInterval) {
        clearInterval(ragEnginesHealthInterval);
        ragEnginesHealthInterval = null;
    }

    if (!hasRunning) return;

    // Counter to trigger update checks every 10th health poll (~5 minutes at 30s intervals)
    let healthPollCount = 0;
    const UPDATE_CHECK_EVERY_N_POLLS = 10;

    // Poll every 30 seconds while the section is active
    ragEnginesHealthInterval = setInterval(() => {
        // Only poll if rag-engines section is visible
        const section = document.querySelector('.rag-engines-section');
        if (!section || !section.classList.contains('active')) {
            clearInterval(ragEnginesHealthInterval);
            ragEnginesHealthInterval = null;
            return;
        }

        healthPollCount++;

        // Fetch current engine list and health-check running ones
        fetch(apiUrl('/api/rag-engines'))
            .then(r => r.json())
            .then(data => {
                const engines = data.engines || [];
                const running = engines.filter(e => e.status === 'running');
                if (running.length === 0) {
                    clearInterval(ragEnginesHealthInterval);
                    ragEnginesHealthInterval = null;
                    return;
                }
                running.forEach(e => healthCheckRAGEngineSilent(e.id));
            })
            .catch(() => {}); // Silent on network errors

        // Every Nth poll, also check PyPI for available updates and patch cards in place
        if (healthPollCount % UPDATE_CHECK_EVERY_N_POLLS === 0) {
            apiFetch(apiUrl('/api/rag-engines/check-updates'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({})
            })
                .then(r => r.json())
                .then(data => {
                    if (data.results) {
                        for (const [engineId, updateInfo] of Object.entries(data.results)) {
                            applyUpdateInfoToCard(engineId, updateInfo);
                        }
                    }
                })
                .catch(() => {}); // Silent on network errors
        }
    }, 30000);
}

/**
 * Stop RAG engines health polling (called on section leave).
 */
function stopRAGEnginesHealthPolling() {
    if (ragEnginesHealthInterval) {
        clearInterval(ragEnginesHealthInterval);
        ragEnginesHealthInterval = null;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// RAG ENGINE CONFIGURATION MODAL
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Engine type presets with default settings and descriptions
 */
const RAG_ENGINE_PRESETS = {
    'lightrag': {
        name: 'LightRAG',
        icon: '🔮',
        description: 'Cross-team text knowledge graphs for semantic search across documents and notes',
        defaultPort: 9621,
        defaultDataDir: '~/rag-data/lightrag',
        settings: [
            { key: 'graphType', label: 'Graph Type', type: 'select', options: ['knowledge', 'semantic', 'hybrid'], default: 'hybrid' },
            { key: 'chunkSize', label: 'Chunk Size', type: 'number', default: 512, min: 128, max: 4096 },
            { key: 'overlapSize', label: 'Chunk Overlap', type: 'number', default: 64, min: 0, max: 512 },
            { key: 'embeddingModel', label: 'Embedding Model', type: 'text', default: 'text-embedding-3-small' },
            { key: 'maxNodes', label: 'Max Graph Nodes', type: 'number', default: 10000, min: 1000, max: 1000000 }
        ]
    },
    'code-graph-rag': {
        name: 'Code-Graph-RAG',
        icon: '🧬',
        description: 'Source code intelligence — AST parsing, dependency graphs, and semantic code search',
        defaultPort: 9622,
        defaultDataDir: '~/rag-data/code-graph',
        settings: [
            { key: 'languages', label: 'Languages', type: 'text', default: 'swift,python,typescript', placeholder: 'Comma-separated' },
            { key: 'indexDepth', label: 'Index Depth', type: 'select', options: ['shallow', 'standard', 'deep'], default: 'standard' },
            { key: 'includeTests', label: 'Index Test Files', type: 'checkbox', default: false },
            { key: 'maxFileSize', label: 'Max File Size (KB)', type: 'number', default: 500, min: 50, max: 5000 },
            { key: 'excludePatterns', label: 'Exclude Patterns', type: 'text', default: 'node_modules,build,.git', placeholder: 'Comma-separated globs' }
        ]
    },
    'rag-anything': {
        name: 'RAG-Anything',
        icon: '📦',
        description: 'Multimodal asset archives — index PDFs, images, audio, and mixed-media documents',
        defaultPort: 9623,
        defaultDataDir: '~/rag-data/rag-anything',
        settings: [
            { key: 'mediaTypes', label: 'Media Types', type: 'text', default: 'pdf,png,jpg,mp3,docx', placeholder: 'Comma-separated' },
            { key: 'ocrEnabled', label: 'Enable OCR', type: 'checkbox', default: true },
            { key: 'audioTranscription', label: 'Audio Transcription', type: 'checkbox', default: false },
            { key: 'maxAssetSize', label: 'Max Asset Size (MB)', type: 'number', default: 50, min: 1, max: 500 },
            { key: 'thumbnailGeneration', label: 'Generate Thumbnails', type: 'checkbox', default: true }
        ]
    }
};

/**
 * Open the RAG engine configuration modal
 * @param {string|null} engineId - Engine ID to edit, or null for new engine
 * @param {object|null} engineData - Existing engine data (for edit mode)
 */
function openRAGEngineModal(engineId = null, engineData = null) {
    const modal = document.getElementById('rag-engine-modal');
    const titleEl = document.getElementById('rag-engine-modal-title');
    const bodyEl = document.getElementById('rag-engine-modal-body');

    if (!modal || !bodyEl) return;

    const isEdit = !!engineId && !!engineData;
    titleEl.textContent = isEdit ? `CONFIGURE: ${engineData.name}` : 'ADD RAG ENGINE';

    let html = '';

    if (!isEdit) {
        // Engine type selector (only for new engines)
        html += `
            <div class="rag-engine-form-group">
                <label>ENGINE TYPE</label>
                <select id="rag-engine-type-select" onchange="updateRAGEngineModalFields()">
                    <option value="">-- Select Engine Type --</option>
                    ${Object.entries(RAG_ENGINE_PRESETS).map(([type, preset]) =>
                        `<option value="${type}">${preset.icon} ${preset.name}</option>`
                    ).join('')}
                </select>
            </div>
            <div id="rag-engine-type-description" class="rag-engine-desc" style="margin-bottom: 16px; color: var(--lcars-text-dim, #667788);"></div>
        `;
    }

    // Common fields container
    html += `<div id="rag-engine-fields-container">`;

    if (isEdit) {
        const preset = RAG_ENGINE_PRESETS[engineData.type] || {};
        html += renderRAGEngineFields(engineData.type, engineData, preset);
    }

    html += `</div>`;

    bodyEl.innerHTML = html;

    // Store edit state
    modal.dataset.editId = engineId || '';
    modal.dataset.engineType = engineData?.type || '';

    modal.style.display = 'flex';
}

/**
 * Update modal fields when engine type is selected (new engine mode)
 */
function updateRAGEngineModalFields() {
    const typeSelect = document.getElementById('rag-engine-type-select');
    const descEl = document.getElementById('rag-engine-type-description');
    const fieldsContainer = document.getElementById('rag-engine-fields-container');
    const modal = document.getElementById('rag-engine-modal');

    if (!typeSelect || !fieldsContainer) return;

    const selectedType = typeSelect.value;
    const preset = RAG_ENGINE_PRESETS[selectedType];

    if (!preset) {
        fieldsContainer.innerHTML = '';
        if (descEl) descEl.textContent = '';
        return;
    }

    if (descEl) descEl.textContent = preset.description;
    modal.dataset.engineType = selectedType;

    // Create default engine data from preset
    const defaultData = {
        id: selectedType,
        type: selectedType,
        name: preset.name,
        port: preset.defaultPort,
        dataDir: preset.defaultDataDir,
        settings: {}
    };
    preset.settings.forEach(s => { defaultData.settings[s.key] = s.default; });

    fieldsContainer.innerHTML = renderRAGEngineFields(selectedType, defaultData, preset);
}

/**
 * Render the configuration fields for a specific engine type
 */
function renderRAGEngineFields(engineType, data, preset) {
    if (!preset) return '<div class="rag-engines-empty">Unknown engine type</div>';

    let html = `
        <div class="rag-engine-form-group">
            <label>ENGINE NAME</label>
            <input type="text" id="rag-engine-name" value="${escapeHtml(data.name || preset.name)}" />
        </div>
        <div class="rag-engine-form-row">
            <div class="rag-engine-form-group">
                <label>PORT</label>
                <input type="number" id="rag-engine-port" value="${data.port || preset.defaultPort}" min="1024" max="65535" />
            </div>
            <div class="rag-engine-form-group">
                <label>ENABLED</label>
                <select id="rag-engine-enabled">
                    <option value="true" ${data.enabled !== false ? 'selected' : ''}>Yes</option>
                    <option value="false" ${data.enabled === false ? 'selected' : ''}>No</option>
                </select>
            </div>
        </div>
        <div class="rag-engine-form-group">
            <label>DATA DIRECTORY</label>
            <input type="text" id="rag-engine-data-dir" value="${escapeHtml(data.dataDir || preset.defaultDataDir)}" />
        </div>
        <div class="rag-engine-form-group">
            <label>INSTALL PATH (optional)</label>
            <input type="text" id="rag-engine-install-path" value="${escapeHtml(data.installPath || '')}" placeholder="Auto-detected if blank" />
        </div>
    `;

    // Engine-specific settings
    if (preset.settings && preset.settings.length > 0) {
        html += `
            <div class="rag-engine-settings-section">
                <div class="rag-engine-settings-title">${preset.icon} ${preset.name} SETTINGS</div>
        `;

        for (const setting of preset.settings) {
            const currentVal = data.settings?.[setting.key] ?? setting.default;

            html += `<div class="rag-engine-form-group">`;
            html += `<label>${escapeHtml(setting.label.toUpperCase())}</label>`;

            if (setting.type === 'select') {
                html += `<select id="rag-setting-${setting.key}">`;
                for (const opt of setting.options) {
                    html += `<option value="${opt}" ${currentVal === opt ? 'selected' : ''}>${opt}</option>`;
                }
                html += `</select>`;
            } else if (setting.type === 'checkbox') {
                html += `
                    <select id="rag-setting-${setting.key}">
                        <option value="true" ${currentVal ? 'selected' : ''}>Yes</option>
                        <option value="false" ${!currentVal ? 'selected' : ''}>No</option>
                    </select>
                `;
            } else if (setting.type === 'number') {
                html += `<input type="number" id="rag-setting-${setting.key}" value="${currentVal}"
                    ${setting.min !== undefined ? `min="${setting.min}"` : ''}
                    ${setting.max !== undefined ? `max="${setting.max}"` : ''} />`;
            } else {
                html += `<input type="text" id="rag-setting-${setting.key}" value="${escapeHtml(String(currentVal || ''))}"
                    ${setting.placeholder ? `placeholder="${escapeHtml(setting.placeholder)}"` : ''} />`;
            }

            html += `</div>`;
        }

        html += `</div>`;
    }

    return html;
}

/**
 * Close the RAG engine modal
 */
function closeRAGEngineModal() {
    const modal = document.getElementById('rag-engine-modal');
    if (modal) {
        modal.style.display = 'none';
        modal.dataset.editId = '';
        modal.dataset.engineType = '';
    }
}

/**
 * Save the RAG engine configuration from the modal
 */
async function saveRAGEngineConfig() {
    const modal = document.getElementById('rag-engine-modal');
    const engineType = modal?.dataset.engineType;
    const editId = modal?.dataset.editId;

    if (!engineType) {
        alert('Please select an engine type');
        return;
    }

    const preset = RAG_ENGINE_PRESETS[engineType];
    if (!preset) return;

    // Gather common fields
    const engineData = {
        id: editId || engineType,
        type: engineType,
        name: document.getElementById('rag-engine-name')?.value || preset.name,
        enabled: document.getElementById('rag-engine-enabled')?.value !== 'false',
        port: parseInt(document.getElementById('rag-engine-port')?.value) || preset.defaultPort,
        dataDir: document.getElementById('rag-engine-data-dir')?.value || preset.defaultDataDir,
        installPath: document.getElementById('rag-engine-install-path')?.value || '',
        settings: {}
    };

    // Gather engine-specific settings
    for (const setting of (preset.settings || [])) {
        const el = document.getElementById(`rag-setting-${setting.key}`);
        if (!el) continue;

        if (setting.type === 'checkbox') {
            engineData.settings[setting.key] = el.value === 'true';
        } else if (setting.type === 'number') {
            engineData.settings[setting.key] = parseInt(el.value) || setting.default;
        } else {
            engineData.settings[setting.key] = el.value;
        }
    }

    // Save via API
    const saveBtn = document.getElementById('rag-engine-save-btn');
    if (saveBtn) {
        saveBtn.disabled = true;
        saveBtn.textContent = 'SAVING...';
    }

    try {
        const response = await apiFetch(apiUrl('/api/rag-engines/save'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ engine: engineData })
        });

        const result = await response.json();

        if (result.success) {
            closeRAGEngineModal();
            loadRAGEngines(); // Refresh the list
        } else {
            alert('Failed to save: ' + (result.error || 'Unknown error'));
        }
    } catch (error) {
        alert('Error saving engine config: ' + error.message);
    } finally {
        if (saveBtn) {
            saveBtn.disabled = false;
            saveBtn.textContent = 'SAVE';
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// INTEGRATION MODAL
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Integration type presets for auto-fill
 */
const INTEGRATION_PRESETS = {
    jira: {
        name: 'JIRA',
        baseUrl: 'https://company.atlassian.net',
        browseUrl: 'https://company.atlassian.net/browse/{ticketId}',
        pattern: '^[A-Z]{1,10}-[0-9]+$',
        userEnv: 'JIRA_USER',
        tokenEnv: 'JIRA_API_TOKEN'
    },
    monday: {
        name: 'Monday.com',
        baseUrl: 'https://api.monday.com/v2',
        browseUrl: 'https://view.monday.com/pulse/{ticketId}',
        pattern: '^(MON-)?[0-9]+$',
        userEnv: '',
        tokenEnv: 'MONDAY_API_TOKEN'
    },
    github: {
        name: 'GitHub',
        baseUrl: 'https://api.github.com',
        browseUrl: 'https://github.com/{owner}/{repo}/issues/{ticketId}',
        pattern: '^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+#[0-9]+$',
        userEnv: '',
        tokenEnv: 'GITHUB_TOKEN'
    },
    linear: {
        name: 'Linear',
        baseUrl: 'https://api.linear.app',
        browseUrl: 'https://linear.app/team/issue/{ticketId}',
        pattern: '^[A-Z]+-[0-9]+$',
        userEnv: '',
        tokenEnv: 'LINEAR_API_KEY'
    },
    monday: {
        name: 'Monday.com',
        baseUrl: 'https://api.monday.com/v2',
        browseUrl: 'https://{account}.monday.com/boards/{boardId}/pulses/{ticketId}',
        pattern: '^[0-9]+$',
        userEnv: '',
        tokenEnv: 'MONDAY_API_TOKEN'
    },
    custom: {
        name: '',
        baseUrl: '',
        browseUrl: '',
        pattern: '',
        userEnv: '',
        tokenEnv: ''
    }
};

/**
 * Open integration modal for adding new integration
 */
function openIntegrationModal() {
    const modal = document.getElementById('integration-modal');
    const title = document.getElementById('integration-modal-title');
    const deleteBtn = document.getElementById('integration-delete-btn');
    const form = document.getElementById('integration-form');

    if (!modal) return;

    // Reset form
    form.reset();
    document.getElementById('integration-id').value = '';
    document.getElementById('integration-enabled').checked = true;

    // Set title and hide delete button
    title.textContent = 'ADD INTEGRATION';
    deleteBtn.style.display = 'none';

    // Show modal
    modal.style.display = 'flex';
}

/**
 * Open integration modal for editing existing integration
 */
function editIntegration(integrationId) {
    const modal = document.getElementById('integration-modal');
    const title = document.getElementById('integration-modal-title');
    const deleteBtn = document.getElementById('integration-delete-btn');

    if (!modal) return;

    // Fetch integration data
    fetch(apiUrl('/api/integrations'))
        .then(r => r.json())
        .then(data => {
            const integration = data.integrations.find(i => i.id === integrationId);
            if (!integration) {
                alert('Integration not found');
                return;
            }

            // Populate form
            document.getElementById('integration-id').value = integration.id;
            document.getElementById('integration-type').value = integration.type || 'custom';
            document.getElementById('integration-name').value = integration.name || '';
            document.getElementById('integration-base-url').value = integration.baseUrl || '';
            document.getElementById('integration-browse-url').value = integration.browseUrl || '';
            document.getElementById('integration-projects').value = (integration.defaultProjects || []).join(', ');
            document.getElementById('integration-pattern').value = integration.ticketPattern || '';
            document.getElementById('integration-enabled').checked = integration.enabled !== false;
            document.getElementById('integration-user-env').value = integration.auth?.userEnvVar || '';
            document.getElementById('integration-token-env').value = integration.auth?.tokenEnvVar || '';

            // Set title and show delete button
            title.textContent = 'EDIT INTEGRATION';
            deleteBtn.style.display = 'block';

            // Show modal
            modal.style.display = 'flex';
        })
        .catch(err => {
            alert('Failed to load integration: ' + err.message);
        });
}

/**
 * Close integration modal
 */
function closeIntegrationModal() {
    const modal = document.getElementById('integration-modal');
    if (modal) {
        modal.style.display = 'none';
    }
}

/**
 * Handle integration type change - auto-fill fields
 */
function onIntegrationTypeChange() {
    const type = document.getElementById('integration-type').value;
    const preset = INTEGRATION_PRESETS[type];

    if (!preset) return;

    // Only auto-fill if fields are empty (don't overwrite user input)
    const nameField = document.getElementById('integration-name');
    const baseUrlField = document.getElementById('integration-base-url');
    const browseUrlField = document.getElementById('integration-browse-url');
    const patternField = document.getElementById('integration-pattern');
    const userEnvField = document.getElementById('integration-user-env');
    const tokenEnvField = document.getElementById('integration-token-env');

    if (!nameField.value) nameField.value = preset.name;
    if (!baseUrlField.value) baseUrlField.value = preset.baseUrl;
    if (!browseUrlField.value) browseUrlField.value = preset.browseUrl;
    if (!patternField.value) patternField.value = preset.pattern;
    if (!userEnvField.value) userEnvField.value = preset.userEnv;
    if (!tokenEnvField.value) tokenEnvField.value = preset.tokenEnv;
}

/**
 * Save integration (add or update)
 */
async function saveIntegration(event) {
    event.preventDefault();

    const id = document.getElementById('integration-id').value;
    const type = document.getElementById('integration-type').value;
    const name = document.getElementById('integration-name').value;
    const baseUrl = document.getElementById('integration-base-url').value;
    const browseUrl = document.getElementById('integration-browse-url').value;
    const projects = document.getElementById('integration-projects').value;
    const pattern = document.getElementById('integration-pattern').value;
    const enabled = document.getElementById('integration-enabled').checked;
    const userEnv = document.getElementById('integration-user-env').value;
    const tokenEnv = document.getElementById('integration-token-env').value;

    // Generate ID for new integrations
    const integrationId = id || `${type}-${name.toLowerCase().replace(/[^a-z0-9]/g, '-')}`;

    const integration = {
        id: integrationId,
        type: type,
        name: name,
        enabled: enabled,
        baseUrl: baseUrl,
        browseUrl: browseUrl,
        ticketPattern: pattern || undefined,
        defaultProjects: projects ? projects.split(',').map(p => p.trim()).filter(Boolean) : undefined,
        auth: (userEnv || tokenEnv) ? {
            type: 'basic',
            userEnvVar: userEnv || undefined,
            tokenEnvVar: tokenEnv || undefined
        } : undefined,
        icon: type
    };

    try {
        const response = await apiFetch(apiUrl('/api/integrations/save'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ integration, isNew: !id })
        });

        const result = await response.json();

        if (result.success) {
            closeIntegrationModal();
            loadIntegrations(); // Refresh the list
            alert(id ? 'Integration updated!' : 'Integration added! Remember to set the environment variables and restart the server.');
        } else {
            alert('Failed to save: ' + (result.error || 'Unknown error'));
        }
    } catch (error) {
        alert('Failed to save integration: ' + error.message);
    }
}

/**
 * Delete integration
 */
async function deleteIntegration() {
    const id = document.getElementById('integration-id').value;

    if (!id) return;

    if (!confirm(`Are you sure you want to delete this integration?`)) {
        return;
    }

    try {
        const response = await apiFetch(apiUrl('/api/integrations/delete'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ integrationId: id })
        });

        const result = await response.json();

        if (result.success) {
            closeIntegrationModal();
            loadIntegrations(); // Refresh the list
        } else {
            alert('Failed to delete: ' + (result.error || 'Unknown error'));
        }
    } catch (error) {
        alert('Failed to delete integration: ' + error.message);
    }
}

/**
 * Test connection from within the modal
 */
async function testIntegrationFromModal() {
    const id = document.getElementById('integration-id').value;

    if (!id) {
        alert('Please save the integration first before testing.');
        return;
    }

    try {
        const response = await apiFetch(apiUrl('/api/integrations/test'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ integrationId: id })
        });

        const result = await response.json();

        if (result.success) {
            alert('Connection successful!\n\n' + result.message);
        } else {
            alert('Connection failed:\n\n' + (result.message || result.error || 'Unknown error'));
        }
    } catch (error) {
        alert('Test failed: ' + error.message);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// IMPORT MODAL (XACA-0031)
// External issue import with preview and approval workflow
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Import state - holds fetched issue data for approval
 */
let importState = {
    issue: null,
    provider: null,
    ticketId: null
};

/**
 * Fetch and populate the integration provider dropdown
 */
async function loadImportProviders() {
    const providerSelect = document.getElementById('import-provider');
    if (!providerSelect) return;

    try {
        const response = await fetch(apiUrl('/api/integrations'));
        const data = await response.json();

        // Clear existing options
        providerSelect.innerHTML = '';

        if (!data.integrations || data.integrations.length === 0) {
            providerSelect.innerHTML = '<option value="">No integrations configured</option>';
            providerSelect.disabled = true;
            return;
        }

        // Add options for each enabled integration
        data.integrations.forEach(integration => {
            const option = document.createElement('option');
            option.value = integration.type;
            option.textContent = integration.name;
            option.dataset.integrationId = integration.id;
            providerSelect.appendChild(option);
        });

        providerSelect.disabled = false;
        updateImportPlaceholder();

    } catch (error) {
        console.error('Failed to load integrations:', error);
        providerSelect.innerHTML = '<option value="">Error loading integrations</option>';
        providerSelect.disabled = true;
    }
}

/**
 * Update the ticket ID placeholder based on selected provider
 */
function updateImportPlaceholder() {
    const providerSelect = document.getElementById('import-provider');
    const ticketInput = document.getElementById('import-ticket-id');
    if (!providerSelect || !ticketInput) return;

    const placeholders = {
        'jira': 'e.g., ME-123 or MEM-456',
        'github': 'e.g., owner/repo#123',
        'monday': 'e.g., 1234567890'
    };
    ticketInput.placeholder = placeholders[providerSelect.value] || 'Enter ticket ID';
}

/**
 * Build the full ticket ID string from provider + input
 */
function buildImportTicketId() {
    const providerSelect = document.getElementById('import-provider');
    const ticketInput = document.getElementById('import-ticket-id');
    if (!providerSelect || !ticketInput) return '';

    const provider = providerSelect.value;
    const ticketId = ticketInput.value.trim();
    if (!ticketId) return '';

    // Format based on provider
    switch (provider) {
        case 'jira':
            // JIRA tickets are passed as-is (ME-123)
            return ticketId;
        case 'github':
            // GitHub needs gh: prefix if not already present
            if (ticketId.startsWith('gh:') || ticketId.startsWith('github:')) {
                return ticketId;
            }
            return `gh:${ticketId}`;
        case 'monday':
            // Monday needs mon: prefix if not already present
            if (ticketId.startsWith('mon:') || ticketId.startsWith('MON-')) {
                return ticketId;
            }
            return `mon:${ticketId}`;
        default:
            return ticketId;
    }
}

/**
 * Show the import modal
 */
function showImportModal() {
    pauseAutoRefresh();

    const modal = document.getElementById('import-modal');
    if (modal) {
        modal.style.display = 'flex';
        // Reset state
        importState = { issue: null, provider: null, ticketId: null };

        // Load available integrations into dropdown
        loadImportProviders();

        // Clear input
        const ticketInput = document.getElementById('import-ticket-id');
        if (ticketInput) ticketInput.value = '';

        // Hide preview, loading, and error
        const preview = document.getElementById('import-preview');
        const loading = document.getElementById('import-loading');
        const errorEl = document.getElementById('import-error');
        if (preview) preview.style.display = 'none';
        if (loading) loading.style.display = 'none';
        if (errorEl) errorEl.style.display = 'none';

        // Disable import button
        const confirmBtn = document.getElementById('import-execute-btn');
        if (confirmBtn) confirmBtn.disabled = true;

        // Set team to current team
        const teamSelect = document.getElementById('import-target-team');
        if (teamSelect && CONFIG.team) {
            teamSelect.value = CONFIG.team;
        }

        // Focus input
        if (ticketInput) {
            setTimeout(() => ticketInput.focus(), 100);
        }
    }
}

/**
 * Hide the import modal
 */
function hideImportModal() {
    resumeAutoRefresh();

    const modal = document.getElementById('import-modal');
    if (modal) {
        modal.style.display = 'none';
    }
    importState = { issue: null, provider: null, ticketId: null };
}

/**
 * Show confirmation dialog for changing item/subitem status
 * XACA-0053: Extended to support changing TO completed as well as reverting FROM completed
 * @param {Object} item - The item or subitem to change
 * @param {string} targetStatus - The target status
 * @param {boolean} isSubitem - Whether this is a subitem
 * @param {Function} onConfirm - Callback when user confirms
 * @param {Function} onCancel - Callback when user cancels
 */
function showStatusChangeConfirmDialog(item, targetStatus, isSubitem, onConfirm, onCancel) {
    // Remove any existing confirm dialog
    const existing = document.querySelector('.status-change-confirm-dialog');
    if (existing) {
        existing.remove();
    }

    // Create overlay
    const overlay = document.createElement('div');
    overlay.className = 'lcars-modal-overlay';

    // Determine if this is completing or reverting
    const isCompleting = targetStatus === 'completed';
    const currentStatus = item.status || 'todo';
    const wasCompleted = currentStatus === 'completed';

    // Format status display text
    const statusDisplayText = targetStatus === 'in_progress' ? 'IN PROGRESS' : targetStatus.toUpperCase();
    const currentStatusDisplay = currentStatus === 'in_progress' ? 'IN PROGRESS' : currentStatus.toUpperCase();

    // Build different content based on action type
    let dateFieldHtml = '';
    let warningHtml = '';
    let titleText = 'CONFIRM STATUS CHANGE';
    let confirmBtnText = 'CONFIRM';

    if (wasCompleted && !isCompleting) {
        // Reverting from completed
        titleText = 'CONFIRM REVERT STATUS';
        confirmBtnText = 'CONFIRM REVERT';

        // Show completed date
        let completedDateText = 'Unknown';
        if (item.completedAt) {
            try {
                const date = new Date(item.completedAt);
                completedDateText = date.toLocaleString();
            } catch (e) {
                completedDateText = item.completedAt;
            }
        }
        dateFieldHtml = `
            <div class="modal-field">
                <div class="modal-label">COMPLETED AT</div>
                <div>${completedDateText}</div>
            </div>
        `;

        // Check if item is part of a release
        if (item.release) {
            warningHtml = `
                <div class="status-change-warning">
                    ⚠️ This ${isSubitem ? 'subitem' : 'item'} is part of release "${item.release}". Reverting will decrease the release completion percentage.
                </div>
            `;
        }
    } else if (isCompleting) {
        // Completing
        titleText = 'CONFIRM COMPLETION';
        confirmBtnText = 'MARK COMPLETE';
    }

    // Create modal HTML
    overlay.innerHTML = `
        <div class="lcars-modal status-change-confirm-dialog">
            <div class="lcars-modal-header">
                <div class="lcars-modal-title">${titleText}</div>
            </div>
            <div class="lcars-modal-body">
                <div class="status-change-confirm-details">
                    <div class="modal-item-info">
                        <div class="modal-item-id">${item.id || 'Unknown ID'}</div>
                        <div class="modal-item-title">${escapeHtml(item.title || 'Untitled')}</div>
                    </div>
                    <div class="modal-field">
                        <div class="modal-label">TYPE</div>
                        <div>${isSubitem ? 'Subitem' : 'Item'}</div>
                    </div>
                    <div class="modal-field">
                        <div class="modal-label">CURRENT STATUS</div>
                        <div>${currentStatusDisplay}</div>
                    </div>
                    ${dateFieldHtml}
                    <div class="modal-field">
                        <div class="modal-label">NEW STATUS</div>
                        <div class="status-change-target-status">${statusDisplayText}</div>
                    </div>
                </div>
                ${warningHtml}
            </div>
            <div class="lcars-modal-footer">
                <button class="modal-btn modal-btn-cancel status-change-confirm-cancel">CANCEL</button>
                <button class="modal-btn modal-btn-confirm status-change-confirm-btn">${confirmBtnText}</button>
            </div>
        </div>
    `;

    // Add to document
    document.body.appendChild(overlay);

    // Wire up event handlers
    const confirmBtn = overlay.querySelector('.status-change-confirm-btn');
    const cancelBtn = overlay.querySelector('.status-change-confirm-cancel');

    confirmBtn.addEventListener('click', () => {
        overlay.remove();
        if (onConfirm) {
            onConfirm();
        }
    });

    cancelBtn.addEventListener('click', () => {
        overlay.remove();
        if (onCancel) {
            onCancel();
        }
    });

    // Allow clicking overlay background to cancel
    overlay.addEventListener('click', (e) => {
        if (e.target === overlay) {
            overlay.remove();
            if (onCancel) {
                onCancel();
            }
        }
    });

    // Allow ESC key to cancel
    const escHandler = (e) => {
        if (e.key === 'Escape') {
            overlay.remove();
            if (onCancel) {
                onCancel();
            }
            document.removeEventListener('keydown', escHandler);
        }
    };
    document.addEventListener('keydown', escHandler);
}

// Legacy alias for backwards compatibility
function showRevertConfirmDialog(item, targetStatus, isSubitem, onConfirm, onCancel) {
    showStatusChangeConfirmDialog(item, targetStatus, isSubitem, onConfirm, onCancel);
}

// ═══════════════════════════════════════════════════════════════════════════════
// STATUS CHANGE HELPERS (XACA-0049, XACA-0053)
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Show LCARS-styled error modal when item completion is blocked by incomplete subitems
 * @param {Object} item - The item that cannot be completed
 * @param {Array} incomplete - Array of incomplete subitems [{id, title, status}]
 */
function showIncompleteSubitemsError(item, incomplete) {
    // Remove any existing error dialog
    const existing = document.querySelector('.incomplete-subitems-error-dialog');
    if (existing) existing.remove();

    const overlay = document.createElement('div');
    overlay.className = 'lcars-modal-overlay';

    const subitemRows = incomplete.map(s => {
        const statusDisplay = (s.status || 'todo') === 'in_progress' ? 'IN PROGRESS' : (s.status || 'todo').toUpperCase();
        return `<div class="modal-field" style="display:flex; justify-content:space-between; align-items:center; padding:4px 0;">
            <span>${escapeHtml(s.id || '')} — ${escapeHtml(s.title || 'Untitled')}</span>
            <span style="color:var(--lcars-orange); font-size:0.85em; margin-left:12px;">${statusDisplay}</span>
        </div>`;
    }).join('');

    overlay.innerHTML = `
        <div class="lcars-modal incomplete-subitems-error-dialog">
            <div class="lcars-modal-header">
                <div class="lcars-modal-title">CANNOT COMPLETE ITEM</div>
            </div>
            <div class="lcars-modal-body">
                <div class="status-change-confirm-details">
                    <div class="modal-item-info">
                        <div class="modal-item-id">${item.id || 'Unknown ID'}</div>
                        <div class="modal-item-title">${escapeHtml(item.title || 'Untitled')}</div>
                    </div>
                    <div class="status-change-warning">
                        This item has ${incomplete.length} incomplete subitem${incomplete.length !== 1 ? 's' : ''}. Complete or cancel all subitems before marking the parent item as completed.
                    </div>
                    <div class="modal-field">
                        <div class="modal-label">INCOMPLETE SUBITEMS</div>
                    </div>
                    ${subitemRows}
                </div>
            </div>
            <div class="lcars-modal-footer">
                <button class="modal-btn modal-btn-cancel incomplete-subitems-dismiss">UNDERSTOOD</button>
            </div>
        </div>
    `;

    document.body.appendChild(overlay);

    const dismissBtn = overlay.querySelector('.incomplete-subitems-dismiss');
    dismissBtn.addEventListener('click', () => overlay.remove());
    overlay.addEventListener('click', (e) => { if (e.target === overlay) overlay.remove(); });

    const escHandler = (e) => {
        if (e.key === 'Escape') {
            overlay.remove();
            document.removeEventListener('keydown', escHandler);
        }
    };
    document.addEventListener('keydown', escHandler);
}

/**
 * Change an item's status - supports changing TO or FROM completed
 * XACA-0053: Extended to handle completing items as well as reverting
 * @param {Object} item - The item to change
 * @param {string} newStatus - The target status
 * @returns {Promise<boolean>} - Success status
 */
async function changeItemStatus(item, newStatus) {
    try {
        const isCompleting = newStatus === 'completed';

        // Block completion if subitems are incomplete (client-side check)
        if (isCompleting && item.subitems && item.subitems.length > 0) {
            const incomplete = item.subitems.filter(s => s.status !== 'completed' && s.status !== 'cancelled');
            if (incomplete.length > 0) {
                showIncompleteSubitemsError(item, incomplete);
                return false;
            }
        }

        const timestamp = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');

        // Build updates object
        const updates = {
            status: newStatus,
            updatedAt: timestamp
        };

        // If completing, set completedAt; otherwise we'll clear it
        if (isCompleting) {
            updates.completedAt = timestamp;
        }

        // Build request body
        const requestBody = {
            team: CONFIG.team,
            id: item.id,
            updates: updates
        };

        // Only clear completedAt if NOT completing
        if (!isCompleting) {
            requestBody.clearFields = ['completedAt'];
        }

        const response = await apiFetch(apiUrl('/api/update-item'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(requestBody)
        });

        if (!response.ok) {
            const errorText = await response.text();
            console.error('Failed to change item status:', response.status, errorText);
            // Parse structured error from server (defense in depth)
            try {
                const errorData = JSON.parse(errorText);
                if (errorData.incompleteSubitems) {
                    showIncompleteSubitemsError(item, errorData.incompleteSubitems);
                }
            } catch (_) {
                // Non-JSON error — already logged above
            }
            return false;
        }

        // API call succeeded. UI refresh errors shouldn't fail the operation.
        try {
            // Trigger release progress recalculation if item is part of a release
            if (item.release) {
                await refreshReleaseProgress(item.release);
            }

            // Refresh the board display
            await loadBoardData();
        } catch (refreshError) {
            console.warn('Status change succeeded but UI refresh failed:', refreshError);
        }

        return true;
    } catch (error) {
        console.error('Error changing item status:', error);
        return false;
    }
}

/**
 * Change a subitem's status - supports changing TO or FROM completed
 * XACA-0053: Extended to handle completing subitems as well as reverting
 * @param {Object} subitem - The subitem to change
 * @param {string} newStatus - The target status
 * @param {Object} parentItem - The parent item (for release tracking)
 * @param {number} parentIndex - The parent item's index in the backlog
 * @param {number} subIndex - The subitem's index in the parent's subitems array
 * @returns {Promise<boolean>} - Success status
 */
async function changeSubitemStatus(subitem, newStatus, parentItem, parentIndex, subIndex) {
    try {
        const isCompleting = newStatus === 'completed';
        const timestamp = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');

        // Build updates object
        const updates = {
            status: newStatus,
            updatedAt: timestamp
        };

        // If completing, set completedAt
        if (isCompleting) {
            updates.completedAt = timestamp;
        }

        // Build request body - API expects parentIndex and subIndex (numeric indices)
        const requestBody = {
            team: CONFIG.team,
            parentIndex: parentIndex,
            subIndex: subIndex,
            updates: updates
        };

        // Only clear completedAt if NOT completing
        if (!isCompleting) {
            requestBody.clearFields = ['completedAt'];
        }

        const response = await apiFetch(apiUrl('/api/update-subitem'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(requestBody)
        });

        if (!response.ok) {
            const errorText = await response.text();
            console.error('Failed to change subitem status:', response.status, errorText);
            return false;
        }

        // API call succeeded. UI refresh errors shouldn't fail the operation.
        try {
            // Trigger release progress recalculation if parent item is part of a release
            if (parentItem.release) {
                await refreshReleaseProgress(parentItem.release);
            }

            // Refresh the board display
            await loadBoardData();
        } catch (refreshError) {
            console.warn('Subitem status change succeeded but UI refresh failed:', refreshError);
        }

        return true;
    } catch (error) {
        console.error('Error changing subitem status:', error);
        return false;
    }
}

// Legacy aliases for backwards compatibility
async function revertItemStatus(item, newStatus) {
    return changeItemStatus(item, newStatus);
}

async function revertSubitemStatus(subitem, newStatus, parentItem, parentIndex, subIndex) {
    return changeSubitemStatus(subitem, newStatus, parentItem, parentIndex, subIndex);
}

/**
 * Refresh the release progress percentage after status changes
 * Triggers a reload of the releases view if it's currently visible
 * @param {string} releaseName - The name of the release to refresh
 */
async function refreshReleaseProgress(releaseName) {
    // Check if releases section is currently visible
    const releasesSection = document.querySelector('.releases-section');
    if (releasesSection && releasesSection.classList.contains('active')) {
        // Releases view is visible, reload it to show updated percentages
        await loadReleases();
    }

    // Note: The backend automatically recalculates release progress when items/subitems change
    // We just need to refresh the UI to show the updated values
    console.log(`Release progress refreshed for: ${releaseName}`);
}

/**
 * Fetch and preview an issue for import
 */
async function fetchImportPreview() {
    const ticketInput = document.getElementById('import-ticket-id');
    const loading = document.getElementById('import-loading');
    const errorEl = document.getElementById('import-error');
    const preview = document.getElementById('import-preview');
    const confirmBtn = document.getElementById('import-execute-btn');

    if (!ticketInput) return;

    // Build the full ticket ID from provider + input
    const ticketId = buildImportTicketId();
    if (!ticketId) {
        showImportError('Please enter a ticket ID');
        return;
    }

    // Show loading, hide error and preview
    if (loading) loading.style.display = 'flex';
    if (errorEl) errorEl.style.display = 'none';
    if (preview) preview.style.display = 'none';
    if (confirmBtn) confirmBtn.disabled = true;

    try {
        const response = await apiFetch(apiUrl('/api/import/fetch'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ticketId: ticketId })
        });

        const result = await readJsonResponse(response);
        if (!result.ok || result.parseError) {
            showImportError(_httpErrorMessage('Failed to fetch issue', result));
            return;
        }
        if (result.data.success && result.data.issue) {
            importState.issue = result.data.issue;
            importState.provider = result.data.provider;
            importState.ticketId = ticketId;
            displayImportPreview(result.data.issue, result.data.provider);
            if (confirmBtn) confirmBtn.disabled = false;
        } else {
            showImportError(result.data.error || 'Failed to fetch issue');
        }
    } catch (error) {
        showImportError('Fetch issue failed: LCARS server not responding on this port — verify the tab URL/port and that the team server is running.');
    } finally {
        if (loading) loading.style.display = 'none';
    }
}

/**
 * Display fetched issue preview using the existing HTML structure
 */
function displayImportPreview(issue, provider) {
    const preview = document.getElementById('import-preview');
    const errorEl = document.getElementById('import-error');

    if (errorEl) errorEl.style.display = 'none';
    if (!preview) return;

    // Update source info
    const sourceName = document.getElementById('import-source-name');
    const sourceTicket = document.getElementById('import-source-ticket');
    if (sourceName) sourceName.textContent = provider || 'External';
    if (sourceTicket) sourceTicket.textContent = issue.ticketId || '';

    // Update issue details
    const issueTitle = document.getElementById('import-issue-title');
    const issueType = document.getElementById('import-issue-type');
    const issueStatus = document.getElementById('import-issue-status');
    const issuePriority = document.getElementById('import-issue-priority');
    const issueDescription = document.getElementById('import-issue-description');

    if (issueTitle) issueTitle.textContent = issue.title || '';
    if (issueType) {
        issueType.textContent = issue.issueType || 'Issue';
        issueType.className = 'issue-type';
    }
    if (issueStatus) {
        const statusText = issue.status || 'Unknown';
        issueStatus.textContent = statusText;
        issueStatus.className = 'issue-status ' + getStatusClass(statusText);
    }
    if (issuePriority) {
        const priorityText = issue.priority || 'None';
        issuePriority.textContent = priorityText;
        issuePriority.className = 'issue-priority ' + getPriorityClass(priorityText);
    }
    if (issueDescription) {
        const desc = issue.description || '';
        issueDescription.textContent = desc.length > 300 ? desc.substring(0, 300) + '...' : desc;
        issueDescription.style.display = desc ? 'block' : 'none';
    }

    // Update children/subtasks section
    const childrenSection = document.getElementById('import-children');
    const childrenCount = document.getElementById('import-children-count');
    const childrenList = document.getElementById('import-children-list');

    if (issue.children && issue.children.length > 0) {
        if (childrenCount) childrenCount.textContent = issue.children.length;
        if (childrenList) {
            let childHtml = '';
            for (const child of issue.children) {
                const childStatusClass = getStatusClass(child.status);
                childHtml += `
                    <div class="child-item">
                        <span class="child-status ${childStatusClass}">●</span>
                        <span class="child-title">${escapeHtml(child.title)}</span>
                        <span class="child-ticket">${escapeHtml(child.ticketId || '')}</span>
                    </div>
                `;
            }
            childrenList.innerHTML = childHtml;
        }
        if (childrenSection) childrenSection.style.display = 'block';
    } else {
        if (childrenSection) childrenSection.style.display = 'none';
    }

    // Set team to current team
    const teamSelect = document.getElementById('import-target-team');
    if (teamSelect && CONFIG.team) {
        teamSelect.value = CONFIG.team;
    }

    // Show the preview section
    preview.style.display = 'block';
}

/**
 * Show error in import modal
 */
function showImportError(message) {
    const errorEl = document.getElementById('import-error');
    const preview = document.getElementById('import-preview');
    const loading = document.getElementById('import-loading');

    if (loading) loading.style.display = 'none';
    if (preview) preview.style.display = 'none';
    if (errorEl) {
        errorEl.textContent = message;
        errorEl.style.display = 'block';
    }
}

/**
 * Get CSS class for status
 */
function getStatusClass(status) {
    if (!status) return '';
    const s = status.toLowerCase();
    if (['done', 'closed', 'complete', 'completed', 'resolved'].includes(s)) return 'status-done';
    if (['in progress', 'in_progress', 'active', 'working'].includes(s)) return 'status-in-progress';
    if (['blocked', 'on hold', 'waiting'].includes(s)) return 'status-blocked';
    return 'status-todo';
}

// ═══════════════════════════════════════════════════════════════════════════════
// XACA-0045: Plan Document Functions
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Check if a plan document exists for an item and show/hide the DOCS button accordingly
 * @param {string} itemId - The item ID to check
 * @param {HTMLElement} docsButton - The DOCS button element to show/hide
 */
async function checkPlanExists(itemId, docsButton) {
    console.log('[DOCS] Checking plan for:', itemId);
    try {
        const url = apiUrl(`/api/kanban/${itemId}/plan-exists`);
        console.log('[DOCS] Fetching:', url);
        const response = await fetch(url);
        console.log('[DOCS] Response status:', response.status);
        if (!response.ok) {
            // On error, keep button hidden
            console.log('[DOCS] Response not OK, hiding button');
            return;
        }
        const data = await response.json();
        console.log('[DOCS] Data:', data);
        if (data.exists) {
            console.log('[DOCS] Plan exists! Showing button for', itemId);
            docsButton.style.display = ''; // Show the button
            // Store retroExists for the modal
            if (data.retroExists) {
                docsButton.setAttribute('data-retro-exists', 'true');
            }
            // Store crExists for the modal (XACA-0292)
            if (data.crExists) {
                docsButton.setAttribute('data-cr-exists', 'true');
            }
        } else {
            console.log('[DOCS] No plan for', itemId);
        }
    } catch (error) {
        console.error('[DOCS] Error checking plan existence:', error);
        // On error, keep button hidden
    }
}

/**
 * Check plan existence for all DOCS buttons in a container
 * Used for epic and release cards that use template strings
 * @param {HTMLElement} container - The container to search for DOCS buttons
 */
function checkPlanDocsButtons(container) {
    const docsButtons = container.querySelectorAll('[data-item-id].docs, .docs[data-item-id]');
    docsButtons.forEach(button => {
        const itemId = button.dataset.itemId;
        if (itemId) {
            checkPlanExists(itemId, button);
        }
    });
}

/**
 * Check plan existence for epic item DOCS buttons
 * Called after epic items are loaded
 * @param {Array} items - Array of item objects with itemId property
 */
function checkEpicItemsDocs(items) {
    items.forEach(item => {
        const button = document.querySelector(`.epic-item-docs[data-item-id="${item.itemId}"]`);
        if (button) {
            checkPlanExists(item.itemId, button);
        }
    });
}

/**
 * Get CSS class for priority
 */
function getPriorityClass(priority) {
    if (!priority) return '';
    const p = priority.toLowerCase();
    if (['critical', 'highest', 'urgent'].includes(p)) return 'priority-critical';
    if (['high'].includes(p)) return 'priority-high';
    if (['medium', 'normal'].includes(p)) return 'priority-medium';
    return 'priority-low';
}

/**
 * Execute the import - create kanban item from fetched issue
 */
async function executeImport() {
    if (!importState.issue) {
        showImportError('No issue to import. Please fetch first.');
        return;
    }

    const includeChildren = document.getElementById('import-include-children')?.checked ?? true;
    const targetTeam = document.getElementById('import-target-team')?.value || CONFIG.team;
    const confirmBtn = document.getElementById('import-execute-btn');

    if (confirmBtn) {
        confirmBtn.disabled = true;
        confirmBtn.textContent = 'IMPORTING...';
    }

    try {
        const response = await apiFetch(apiUrl('/api/import/execute'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                issue: importState.issue,
                provider: importState.provider,
                ticketId: importState.ticketId,
                team: targetTeam,
                includeChildren: includeChildren
            })
        });

        const result = await readJsonResponse(response);
        if (!result.ok || result.parseError) {
            showImportError(_httpErrorMessage('Import failed', result));
            return;
        }
        if (result.data.success) {
            hideImportModal();
            // Refresh the board to show new item
            loadBoardData();
            // Show success notification
            const msg = result.data.createdId
                ? `Imported as ${result.data.createdId}`
                : 'Import successful!';
            alert(msg);
        } else {
            showImportError(result.data.error || 'Import failed');
        }
    } catch (error) {
        showImportError('Import failed: LCARS server not responding on this port — verify the tab URL/port and that the team server is running.');
    } finally {
        if (confirmBtn) {
            confirmBtn.disabled = false;
            confirmBtn.textContent = 'IMPORT';
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// XACA-0049: Status Change Functions (formerly Revert Completed Status)
// XACA-0053: Extended to support changing TO any status (including completed)
// ═══════════════════════════════════════════════════════════════════════════════

/**
 * Show status change selection modal - allows changing to ANY status
 * @param {Object} itemOrSubitem - The item or subitem to change
 * @param {boolean} isSubitem - Whether this is a subitem (true) or item (false)
 * @param {Function} callback - Callback function that receives the selected status
 */
function showStatusChangeModal(itemOrSubitem, isSubitem, callback) {
    // Create modal overlay
    const overlay = document.createElement('div');
    overlay.className = 'lcars-modal-overlay status-change-modal-overlay';

    // Get the title - handle both items and subitems
    const title = isSubitem
        ? (itemOrSubitem.title || itemOrSubitem.description || 'Subitem')
        : (itemOrSubitem.title || 'Item');

    // Get the ID and current status
    const id = itemOrSubitem.id || 'Unknown';
    const currentStatus = itemOrSubitem.status || 'todo';

    // Define all available statuses with icons and descriptions
    const allStatuses = [
        { status: 'todo', icon: '📋', label: 'TODO', desc: 'Item needs to be worked on' },
        { status: 'in_progress', icon: '⚙️', label: 'IN PROGRESS', desc: 'Currently being worked on' },
        { status: 'completed', icon: '✅', label: 'COMPLETED', desc: 'Mark as done' },
        { status: 'cancelled', icon: '🚫', label: 'CANCELLED', desc: 'No longer needed' }
    ];

    // Filter out the current status - no point selecting what it already is
    const availableStatuses = allStatuses.filter(s => s.status !== currentStatus);

    // Build status options HTML (horizontal row layout for compact height)
    const optionsHtml = availableStatuses.map(s => `
        <button class="status-change-option" data-status="${s.status}">
            <div class="status-change-option-icon">${s.icon}</div>
            <div class="status-change-option-text">
                <div class="status-change-option-label">${s.label}</div>
                <div class="status-change-option-desc">${s.desc}</div>
            </div>
        </button>
    `).join('');

    // Format current status for display
    const currentStatusDisplay = currentStatus === 'in_progress' ? 'IN PROGRESS' : currentStatus.toUpperCase();

    overlay.innerHTML = `
        <div class="lcars-modal status-change-modal">
            <div class="lcars-modal-header">
                <div class="lcars-modal-title">CHANGE STATUS</div>
                <button class="lcars-modal-close" onclick="closeStatusChangeModal()">×</button>
            </div>
            <div class="lcars-modal-body">
                <div class="modal-item-info">
                    <div class="modal-item-id">${id}</div>
                    <div class="modal-item-title">${escapeHtml(title)}</div>
                </div>
                <div class="status-change-current">
                    Current status: <span class="current-status-value">${currentStatusDisplay}</span>
                </div>
                <div class="status-change-instructions">
                    Select the new status for this ${isSubitem ? 'subitem' : 'item'}:
                </div>
                <div class="status-change-options">
                    ${optionsHtml}
                </div>
            </div>
            <div class="lcars-modal-footer">
                <button class="modal-btn modal-btn-cancel" onclick="closeStatusChangeModal()">CANCEL</button>
            </div>
        </div>
    `;

    // Add click handlers to status options
    const statusButtons = overlay.querySelectorAll('.status-change-option');
    statusButtons.forEach(btn => {
        btn.addEventListener('click', () => {
            const selectedStatus = btn.dataset.status;
            closeStatusChangeModal();
            callback(selectedStatus);
        });
    });

    // Add to DOM and show
    document.body.appendChild(overlay);
    setTimeout(() => overlay.classList.add('active'), 10);
}

/**
 * Close the status change modal
 */
function closeStatusChangeModal() {
    const overlay = document.querySelector('.status-change-modal-overlay');
    if (overlay) {
        overlay.classList.remove('active');
        setTimeout(() => overlay.remove(), 300);
    }
}

// Legacy alias for backwards compatibility
function showRevertStatusModal(itemOrSubitem, isSubitem, callback) {
    showStatusChangeModal(itemOrSubitem, isSubitem, callback);
}

function closeRevertStatusModal() {
    closeStatusChangeModal();
}

// ═══════════════════════════════════════════════════════════════════════════════
// PUBLIC API
// ═══════════════════════════════════════════════════════════════════════════════

window.refreshData = function() {
    loadBoardData();
};

window.setRefreshInterval = function(seconds) {
    CONFIG.refreshInterval = seconds * 1000;
    startAutoRefresh();
};

// ═══════════════════════════════════════════════════════════════════════════════
// INITIALIZATION
// ═══════════════════════════════════════════════════════════════════════════════

async function loadServerConfig() {
    try {
        const response = await fetch(apiUrl('/api/status'));
        if (response.ok) {
            const data = await response.json();
            if (data.session_name) {
                document.title = data.session_name;
                CONFIG.sessionName = data.session_name;
            }
            if (data.team) {
                CONFIG.team = data.team;
                CONFIG.dataPath = `data/${data.team}-board.json`;
                console.log(`LCARS configured for team: ${data.team}`);
            }
            if (data.hostname) {
                const hostnameEl = document.getElementById('server-hostname');
                if (hostnameEl) {
                    // Use as-is — Tailscale machine names are already in
                    // canonical kebab-case (e.g. "darren-m4-mini") and
                    // read better without forced uppercasing. Fallback
                    // hostnames (`hostname -s` output) also display more
                    // naturally without case mangling.
                    hostnameEl.textContent = data.hostname;
                }
            }
        }
    } catch (e) {
        console.log('Could not load server config, using defaults');
    }

    // XACA-0249: If /api/status did not populate CONFIG.team (network error,
    // server restart race, etc.), fall back to the dedicated /api/team endpoint
    // which is a cheaper, focused call.  This ensures CONFIG.team is always
    // authoritative before any team-scoped fetch fires.
    if (!CONFIG.team) {
        try {
            const teamResp = await fetch(apiUrl('/api/team'));
            if (teamResp.ok) {
                const teamData = await teamResp.json();
                if (teamData.team) {
                    CONFIG.team = teamData.team;
                    CONFIG.dataPath = `data/${teamData.team}-board.json`;
                    console.log(`LCARS team (fallback /api/team): ${teamData.team}`);
                    if (teamData.default_used) {
                        console.warn('LCARS: server is using hardcoded "freelance" team default — LCARS_TEAM env is unset. See XACA-0249.');
                    }
                }
            }
        } catch (e) {
            console.log('Could not load team from /api/team fallback');
        }
    }

    // Fetch AITeamForge tap version — best-effort, non-blocking.
    try {
        const resp = await fetch('/api/tap-version');
        if (resp.ok) {
            const { version, source } = await resp.json();
            const el = document.getElementById('tap-version');
            if (el && version) {
                el.textContent = `AITF ${version}`;
                el.title = `AITeamForge tap version (${source})`;
            }
        }
    } catch (e) {
        // Non-fatal — header just shows "AITF --"
    }
}

/**
 * Apply team-specific theme to container for org/div color theming
 * Directly sets CSS custom properties on the container element for reliability
 * This bypasses all CSS specificity issues from multiple stylesheets
 */
function applyTeamTheme() {
    const container = document.querySelector('.lcars-container');
    if (!container) {
        console.warn('Could not find .lcars-container for team theming');
        return;
    }

    // Team color mapping - org and div colors for each team
    // Matches the color definitions in lcars-fleet-theme.css
    const TEAM_COLORS = {
        // Main Event Organization (crimson) teams
        'ios':      { org: '#ff4466', div: '#9999ff' },  // crimson / blue
        'android':  { org: '#ff4466', div: '#99ff99' },  // crimson / green
        'firebase': { org: '#ff4466', div: '#ffcc00' },  // crimson / amber
        'command':  { org: '#ff4466', div: '#ff6688' },  // crimson / rose

        // DoubleNode Organization (blue) teams
        'dns':                            { org: '#9999ff', div: '#ccccff' },  // blue / lavender
        'freelance':                      { org: '#9999ff', div: '#cc99ff' },  // blue / purple
        'freelance-doublenode-starwords': { org: '#9999ff', div: '#aa77dd' },  // blue / violet
        'freelance-doublenode-workstats': { org: '#9999ff', div: '#cc99cc' },  // blue / mauve
        'freelance-doublenode-appplanning': { org: '#9999ff', div: '#bb88ee' },  // blue / light violet

        // DevTeam Organization (cyan) teams
        'academy':  { org: '#99ccff', div: '#ffcc99' }   // cyan / peach
    };

    const team = CONFIG.team || 'ios';
    const colors = TEAM_COLORS[team] || TEAM_COLORS['ios'];

    // Directly set CSS custom properties on the container
    // This overrides any stylesheet definitions
    container.style.setProperty('--current-org-color', colors.org);
    container.style.setProperty('--current-div-color', colors.div);

    // Also add team class for any other styling
    container.classList.remove(
        'team-ios', 'team-android', 'team-firebase', 'team-command',
        'team-dns', 'team-freelance', 'team-freelance-doublenode-starwords',
        'team-freelance-doublenode-workstats', 'team-freelance-doublenode-appplanning', 'team-academy'
    );
    const teamClass = `team-${team}`;
    container.classList.add(teamClass);

    console.log(`Applied team theme: ${teamClass} (org: ${colors.org}, div: ${colors.div})`);
}

// ═══════════════════════════════════════════════════════════════════════════════
// AVATAR TOOLTIP SYSTEM
// ═══════════════════════════════════════════════════════════════════════════════

const avatarTooltip = {
    element: null,
    visible: false,
    hideTimer: null,

    init: function() {
        // Create tooltip element
        const tooltip = document.createElement('div');
        tooltip.className = 'lcars-avatar-tooltip';
        tooltip.style.display = 'none';
        tooltip.innerHTML =
            '<div class="tooltip-arrow"></div>' +
            '<div class="tooltip-content">' +
                '<div class="tooltip-name"></div>' +
                '<div class="tooltip-divider"></div>' +
                '<div class="tooltip-role"></div>' +
                '<div class="tooltip-terminal"></div>' +
            '</div>';
        document.body.appendChild(tooltip);
        this.element = tooltip;

        // Event delegation on document for all .lcars-avatar elements
        const self = this;
        document.addEventListener('mouseenter', function(e) {
            const avatar = e.target.closest('.lcars-avatar');
            if (avatar) self.show(avatar);
        }, true);
        document.addEventListener('mouseleave', function(e) {
            const avatar = e.target.closest('.lcars-avatar');
            if (avatar) self.scheduleHide();
        }, true);
    },

    show: function(avatar) {
        if (!this.element) return;
        const developer = avatar.dataset.developer;
        if (!developer) return;

        this.cancelHide();

        // Update content
        this.element.querySelector('.tooltip-name').textContent = developer;
        this.element.querySelector('.tooltip-role').textContent = avatar.dataset.role || '';
        this.element.querySelector('.tooltip-terminal').textContent =
            avatar.dataset.terminal ? avatar.dataset.terminal.toUpperCase() : '';

        // Position and show
        this.element.style.display = 'block';
        this.position(avatar);
        const el = this.element;
        setTimeout(function() { el.classList.add('visible'); }, 10);
        this.visible = true;
    },

    position: function(avatar) {
        const rect = avatar.getBoundingClientRect();
        const tooltip = this.element;
        // Temporarily make visible for measurement
        tooltip.style.visibility = 'hidden';
        tooltip.style.display = 'block';
        const tooltipRect = tooltip.getBoundingClientRect();
        tooltip.style.visibility = '';

        const spaceBelow = window.innerHeight - rect.bottom;
        let top, showAbove = false;

        if (spaceBelow < tooltipRect.height + 20 && rect.top > spaceBelow) {
            top = rect.top - tooltipRect.height - 8;
            showAbove = true;
        } else {
            top = rect.bottom + 8;
        }

        let left = rect.left + (rect.width / 2) - (tooltipRect.width / 2);
        left = Math.max(10, Math.min(left, window.innerWidth - tooltipRect.width - 10));

        tooltip.style.top = top + 'px';
        tooltip.style.left = left + 'px';

        if (showAbove) {
            tooltip.classList.add('arrow-bottom');
            tooltip.classList.remove('arrow-top');
        } else {
            tooltip.classList.add('arrow-top');
            tooltip.classList.remove('arrow-bottom');
        }
    },

    scheduleHide: function() {
        const self = this;
        this.hideTimer = setTimeout(function() { self.hide(); }, 150);
    },

    cancelHide: function() {
        if (this.hideTimer) {
            clearTimeout(this.hideTimer);
            this.hideTimer = null;
        }
    },

    hide: function() {
        if (!this.visible) return;
        const el = this.element;
        el.classList.remove('visible');
        setTimeout(function() { el.style.display = 'none'; }, 200);
        this.visible = false;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// ARCHIVE / TRANSFER (XACA-0128)
// ═══════════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════
// Team EXPORT / IMPORT — per-team archive with merge-aware restore
// ═══════════════════════════════════════════════════════════════════

let currentExportJobId = null;
let exportPollingInterval = null;
let currentImportJobId = null;
let importPollingInterval = null;
// XACA-0602-012: paired-secrets extraction poll handle, tracked at module scope so
// stopImportPolling()/resetImportState() can cancel an in-flight secrets poll when a
// new import starts (previously a function-local handle that survived a reset).
let pairedSecretsPollingInterval = null;
let stagedImportFile = null;
// XACA-0554: tracks inline secrets file + discovered count for main import flow
let stagedImportSecretsFile = null;
let currentImportSecretsDiscovered = 0;
let currentSecretsExportJobId = null;
let secretsExportPollingInterval = null;

function initExportImportPanel() {
    const teamEl = document.getElementById('export-team-label');
    if (teamEl && CONFIG.team) {
        teamEl.textContent = CONFIG.team;
    }
}

// ───── EXPORT / IMPORT shared helpers ─────

// Reads a fetch Response, classifying the outcome. Never throws on a bad body.
// Returns { ok, status, statusText, data, parseError }.
// Use this instead of bare `await response.json()` so a non-JSON body (HTML error
// page, empty body, reverse-proxy error) does not masquerade as a true network reject.
async function readJsonResponse(response) {
    let data = null, parseError = null;
    try { data = await response.json(); }
    catch (e) { parseError = e; }
    return { ok: response.ok, status: response.status, statusText: response.statusText, data, parseError };
}

// Builds a human-readable error string from a readJsonResponse result.
// mode: 'http'  → HTTP <status> + server reason (for non-OK status)
//       'parse' → unreadable response (for ok-but-parse-failed)
function _httpErrorMessage(prefix, result) {
    if (!result.ok) {
        const reason = (result.data && (result.data.error || result.data.message)) || result.statusText || 'unknown error';
        return `${prefix}: HTTP ${result.status} ${reason}`;
    }
    // ok=true but parseError set
    return `${prefix}: server returned an unreadable response`;
}

// ───── EXPORT ─────

async function startTeamExport() {
    if (exportPollingInterval) return;

    const btn = document.getElementById('export-btn');
    const progressSection = document.getElementById('export-progress');
    const downloadSection = document.getElementById('export-download');
    const statusEl = document.getElementById('export-status-label');

    if (btn) btn.disabled = true;
    if (progressSection) progressSection.style.display = 'block';
    if (downloadSection) downloadSection.style.display = 'none';
    // XACA-0954-023: the warning is a sibling of the panel, so hiding the panel
    // does not hide it. Clear it explicitly or it describes the previous run.
    clearExportMissingRoots();
    if (statusEl) statusEl.textContent = 'EXPORTING';

    updateExportProgress(0, 'EXPORTING...', 'Initializing...');

    try {
        const response = await apiFetch('/api/export/create', { method: 'POST' });
        const result = await readJsonResponse(response);
        if (!result.ok || result.parseError) {
            if (statusEl) statusEl.textContent = 'ERROR';
            if (btn) btn.disabled = false;
            alert(_httpErrorMessage('Export failed', result));
            return;
        }
        currentExportJobId = result.data.jobId;
        exportPollingInterval = setInterval(() => pollExportStatus(result.data.jobId), 1000);
    } catch (error) {
        console.error('Export request failed:', error);
        if (statusEl) statusEl.textContent = 'ERROR';
        if (btn) btn.disabled = false;
        alert('Export failed: LCARS server not responding on this port — verify the tab URL/port and that the team server is running.');
    }
}

async function pollExportStatus(jobId) {
    try {
        const response = await fetch(`/api/export/status/${jobId}`);
        const data = await response.json();
        if (!response.ok) {
            stopExportPolling();
            const btn = document.getElementById('export-btn');
            if (btn) btn.disabled = false;
            return;
        }
        updateExportProgress(data.progress, 'EXPORTING...', data.message);
        if (data.status === 'completed') {
            stopExportPolling();
            onExportComplete(data);
        } else if (data.status === 'failed') {
            stopExportPolling();
            onExportFailed(data);
        }
    } catch (error) {
        console.error('Export poll error:', error);
    }
}

function stopExportPolling() {
    if (exportPollingInterval) {
        clearInterval(exportPollingInterval);
        exportPollingInterval = null;
    }
}

function updateExportProgress(percent, label, message) {
    const bar = document.getElementById('export-progress-bar');
    const pctEl = document.getElementById('export-progress-percent');
    const labelEl = document.getElementById('export-progress-label');
    const msgEl = document.getElementById('export-progress-message');
    if (bar) bar.style.width = `${percent}%`;
    if (pctEl) pctEl.textContent = `${percent}%`;
    if (labelEl) labelEl.textContent = label;
    if (msgEl) msgEl.textContent = message;
}

// XACA-0954-018/019: render unscanned domain roots in the export panel.
//
// The backend computes missingRootsSummary correctly, but nothing in the
// frontend read it: onExportComplete() set the status label to 'READY'
// unconditionally, and the only trace of incompleteness that reached the DOM
// was data.message, appended after the phrase "Export ready for download" in a
// secondary progress line. Correct data that nothing renders is not a fixed
// interface.
//
// XACA-0954-019 (round 4): the box is inserted as a SIBLING BEFORE
// #export-download, not appended inside it. `.export-download` is
// `display:flex; justify-content:space-between` with NO flex-wrap, so a third
// child could never drop below the file metadata the way the first attempt
// assumed -- it was squeezed into the same row and, at ~520px, the DOWNLOAD
// button overlapped the filename. That was found by rendering the real CSS in a
// browser; the stub-DOM test asserted structure and is blind to layout.
// `.export-download` is also shared with #secrets-export-download, so adding
// flex-wrap to it would have reached a second panel. A preceding sibling needs
// no CSS change at all, and puts the warning before the thing it qualifies.
function renderExportMissingRoots(downloadSection, summary) {
    const existing = document.getElementById('export-missing-roots');
    if (existing) existing.remove();
    if (!downloadSection || !summary || !summary.count) return null;

    const box = document.createElement('div');
    box.id = 'export-missing-roots';
    box.className = 'export-missing-roots';
    // role/aria-live per the established pattern (see #team-account-test-status):
    // a screen-reader user must be told the export just came back incomplete,
    // not only see a colour change. WCAG 2.1 AA 4.1.3.
    box.setAttribute('role', 'status');
    box.setAttribute('aria-live', 'polite');
    // Inline styles so the warning renders even if the stylesheet has not caught
    // up -- a warning that depends on CSS is one that can silently vanish -- but
    // colours come from the LCARS alert tokens rather than ad-hoc hex.
    box.style.cssText = 'width:100%;box-sizing:border-box;margin-top:10px;padding:12px 14px;' +
        'border:1px solid var(--lcars-alert-red, #ff6666);' +
        'border-left:6px solid var(--lcars-alert-red, #ff6666);' +
        'border-radius:8px;background:var(--lcars-alert-glow, rgba(255,102,102,0.4));' +
        'color:var(--lcars-text, #ffcc99);font-size:12px;line-height:1.5;';

    const heading = document.createElement('div');
    heading.style.cssText = 'font-weight:bold;letter-spacing:0.05em;margin-bottom:4px;';
    heading.textContent = `\u26A0 INCOMPLETE EXPORT \u2014 ${summary.count} configured ` +
        `domain root${summary.count === 1 ? '' : 's'} never scanned`;
    box.appendChild(heading);

    const blurb = document.createElement('div');
    blurb.style.cssText = 'margin-bottom:6px;';
    blurb.textContent = 'These paths are configured for this team but do not exist on this ' +
        'machine. Their files are ABSENT from the archive below \u2014 a domain showing few ' +
        'files may never have been looked at, rather than having been checked and found empty.';
    box.appendChild(blurb);

    const list = document.createElement('ul');
    list.style.cssText = 'margin:0;padding-left:18px;';
    (summary.roots || []).forEach((r) => {
        const li = document.createElement('li');
        // textContent throughout: these strings are filesystem paths from config.
        li.textContent = `[${r.domain || '?'}] ${r.path || '?'}` +
            (r.configKey ? `  (config key: ${r.configKey})` : '');
        list.appendChild(li);
    });
    box.appendChild(list);

    // Sibling BEFORE the panel -- see the note above.
    if (downloadSection.parentNode) {
        downloadSection.parentNode.insertBefore(box, downloadSection);
    }
    return box;
}

// XACA-0954-023: tear down the incomplete-export warning.
//
// Moving the box OUT of #export-download (to escape the no-wrap flex row) also
// moved it out of the panel's lifecycle: startTeamExport() hides the panel with
// `downloadSection.style.display = 'none'`, which no longer reaches a sibling,
// and onExportFailed() never removed it at all. A stale INCOMPLETE banner from
// one run therefore survived into the next -- describing a run it was not about.
// That is this ticket's own defect class (false state shown to the operator),
// relocated by the fix for it. Every path that starts, fails, or restarts an
// export must call this.
function clearExportMissingRoots() {
    const existing = document.getElementById('export-missing-roots');
    if (existing) existing.remove();
    applyExportPanelState(document.getElementById('export-download'), false);
}

// XACA-0954-019: the download panel's chrome is success-green
// (rgba(68,204,68,...)) and stayed green over an incomplete export, contradicting
// the warning directly above it. Toned to the alert palette when incomplete and
// restored when not, inline so the shared `.export-download` class -- which
// #secrets-export-download also uses -- is left alone.
function applyExportPanelState(downloadSection, isIncomplete) {
    if (!downloadSection) return;
    // XACA-0954-024: the container shell alone is not the panel an operator
    // looks at. `.download-filename` and `.export-download-btn` carry hardcoded
    // success-green, so toning only the border left a green filename and a green
    // DOWNLOAD button sitting inside a red-bordered panel under a red warning.
    // Not a contrast failure, but it half-answers the complaint that the panel
    // "stayed green over an incomplete export".
    const filenameEl = document.getElementById('export-download-filename');
    const dlBtn = document.getElementById('export-download-btn');
    if (isIncomplete) {
        downloadSection.style.background = 'var(--lcars-alert-glow, rgba(255,102,102,0.4))';
        downloadSection.style.borderColor = 'var(--lcars-alert-red, #ff6666)';
        // XACA-0954-023: NOT alert-red — red text on the alert-tinted panel measures
        // 3.84:1, under the 4.5:1 AA floor for this size/weight. Same-hue on same-hue
        // is what tanks it. This is the body-text token the warning banner above
        // already uses (7.5:1 on the same background).
        if (filenameEl) filenameEl.style.color = 'var(--lcars-text, #ffcc99)';
        if (dlBtn) dlBtn.style.background = 'var(--lcars-alert-red, #ff6666)';
    } else {
        downloadSection.style.background = '';
        downloadSection.style.borderColor = '';
        if (filenameEl) filenameEl.style.color = '';
        if (dlBtn) dlBtn.style.background = '';
    }
}

function onExportComplete(data) {
    const btn = document.getElementById('export-btn');
    const downloadSection = document.getElementById('export-download');
    const statusEl = document.getElementById('export-status-label');

    // XACA-0954-018: an export that skipped a configured root is not READY.
    const missingSummary = data.missingRootsSummary;
    const isIncomplete = !!(missingSummary && missingSummary.count > 0);

    updateExportProgress(
        100,
        isIncomplete ? 'INCOMPLETE' : 'COMPLETE',
        data.message || (isIncomplete ? 'Export incomplete' : 'Export ready'),
    );

    if (downloadSection) {
        downloadSection.style.display = 'flex';
        document.getElementById('export-download-filename').textContent = data.filename || '--';
        document.getElementById('export-download-size').textContent = data.fileSize || '--';
        document.getElementById('export-download-files').textContent = `${data.totalFiles || 0} files`;
        renderExportMissingRoots(downloadSection, missingSummary);
        applyExportPanelState(downloadSection, isIncomplete);
    }
    // The archive is still offered for download -- a partial export can be a
    // deliberate choice -- but the status must never read READY over one.
    if (statusEl) statusEl.textContent = isIncomplete ? 'INCOMPLETE' : 'READY';
    if (btn) btn.disabled = false;
}

function onExportFailed(data) {
    const btn = document.getElementById('export-btn');
    const statusEl = document.getElementById('export-status-label');
    // XACA-0954-023: a failed run must not leave the previous run's INCOMPLETE
    // banner on screen, where it reads as a description of this failure.
    clearExportMissingRoots();
    updateExportProgress(0, 'FAILED', data.message || 'Export failed');
    if (statusEl) statusEl.textContent = 'ERROR';
    if (btn) btn.disabled = false;
    alert(`Export failed: ${data.error || data.message || 'unknown error'}`);
}

function downloadTeamExport() {
    if (!currentExportJobId) return;
    const link = document.createElement('a');
    link.href = `/api/export/download/${currentExportJobId}`;
    link.download = '';
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
}

// ───── SECRETS EXPORT ─────

function toggleSecretsExportPanel() {
    const toggle = document.getElementById('secrets-export-toggle');
    const panel  = document.getElementById('secrets-export-panel');
    if (!toggle || !panel) return;
    panel.style.display = toggle.checked ? 'block' : 'none';
    if (!toggle.checked) {
        resetSecretsExportUI();
    }
}

function validateSecretsPasswords() {
    const pw1 = document.getElementById('secrets-export-password');
    const pw2 = document.getElementById('secrets-export-password-confirm');
    const btn = document.getElementById('secrets-export-btn');
    if (!pw1 || !pw2 || !btn) return;
    const valid = pw1.value.length > 0 && pw1.value === pw2.value;
    btn.disabled = !valid;
}

async function startSecretsExport() {
    if (secretsExportPollingInterval) return;

    const btn           = document.getElementById('secrets-export-btn');
    const pw1El         = document.getElementById('secrets-export-password');
    const pw2El         = document.getElementById('secrets-export-password-confirm');
    const progressEl    = document.getElementById('secrets-export-progress');
    const downloadEl    = document.getElementById('secrets-export-download');
    const statusMsgEl   = document.getElementById('secrets-export-status-msg');

    const password = pw1El ? pw1El.value : '';

    if (!password) return;

    if (btn) btn.disabled = true;
    if (progressEl) progressEl.style.display = 'block';
    if (downloadEl) downloadEl.style.display = 'none';
    if (statusMsgEl) statusMsgEl.style.display = 'none';

    updateSecretsExportProgress(0, 'ENCRYPTING...', 'Initializing...');

    const body = {
        team: CONFIG.team,
        password: password
    };
    if (currentExportJobId) {
        body.pairedExportId = currentExportJobId;
    }

    // Zero password from DOM immediately — before any await
    if (pw1El) pw1El.value = '';
    if (pw2El) pw2El.value = '';
    let pw = password;

    try {
        const response = await apiFetch('/api/export/secrets/create', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        // Zero the local variable regardless of outcome
        pw = '';
        body.password = '';

        const result = await readJsonResponse(response);
        if (!result.ok) {
            // non-OK HTTP status: show code + server reason
            const msg = _httpErrorMessage('Secrets export failed', result);
            updateSecretsExportProgress(0, 'FAILED', (result.data && result.data.error) || `HTTP ${result.status}`);
            if (statusMsgEl) { statusMsgEl.textContent = msg; statusMsgEl.style.display = 'block'; }
            if (btn) btn.disabled = false;
            return;
        }
        if (result.parseError) {
            // OK status but body was not valid JSON
            updateSecretsExportProgress(0, 'FAILED', 'Unreadable response');
            if (statusMsgEl) {
                statusMsgEl.textContent = 'Secrets export failed: server returned an unreadable response';
                statusMsgEl.style.display = 'block';
            }
            if (btn) btn.disabled = false;
            return;
        }
        currentSecretsExportJobId = result.data.jobId;
        secretsExportPollingInterval = setInterval(
            () => pollSecretsExportStatus(result.data.jobId),
            1500
        );
    } catch (error) {
        // True fetch reject — server unreachable (TypeError from fetch itself)
        pw = '';
        body.password = '';
        console.error('Secrets export request failed:', error);
        updateSecretsExportProgress(0, 'FAILED', 'Server unreachable');
        if (statusMsgEl) {
            statusMsgEl.textContent = 'Secrets export failed: LCARS server not responding on this port — verify the tab URL/port and that the team server is running.';
            statusMsgEl.style.display = 'block';
        }
        if (btn) btn.disabled = false;
    }
}

async function pollSecretsExportStatus(jobId) {
    try {
        const response = await fetch(`/api/export/secrets/status/${jobId}`);
        const data = await response.json();

        if (!response.ok) {
            stopSecretsExportPolling();
            const btn = document.getElementById('secrets-export-btn');
            if (btn) btn.disabled = false;
            return;
        }

        updateSecretsExportProgress(data.progress || 0, 'ENCRYPTING...', data.message || '');

        if (data.status === 'completed') {
            stopSecretsExportPolling();
            const downloadEl  = document.getElementById('secrets-export-download');
            const filenameEl  = document.getElementById('secrets-export-download-filename');
            const sizeEl      = document.getElementById('secrets-export-download-size');
            const statusMsgEl = document.getElementById('secrets-export-status-msg');
            const panel       = document.getElementById('secrets-export-panel');
            const toggle      = document.getElementById('secrets-export-toggle');

            updateSecretsExportProgress(100, 'COMPLETE', data.message || 'Secrets zip ready');

            if (filenameEl) filenameEl.textContent = data.filename || '--';
            if (sizeEl)     sizeEl.textContent = data.fileSize || '--';
            if (downloadEl) downloadEl.style.display = 'flex';

            // Hide opt-in and password fields now that download is ready
            const fieldsEl = panel ? panel.querySelector('.secrets-export-fields') : null;
            if (fieldsEl) fieldsEl.style.display = 'none';
            const generateActionsEl = panel ? panel.querySelector('.export-actions') : null;
            if (generateActionsEl) generateActionsEl.style.display = 'none';

            if (statusMsgEl) {
                statusMsgEl.textContent = 'Encrypted secrets zip ready. Store separately from the main export and share the password through a secure channel.';
                statusMsgEl.style.display = 'block';
                statusMsgEl.className = 'secrets-export-status-msg secrets-info';
            }

        } else if (data.status === 'skipped') {
            stopSecretsExportPolling();
            const progressEl  = document.getElementById('secrets-export-progress');
            const statusMsgEl = document.getElementById('secrets-export-status-msg');
            const btn         = document.getElementById('secrets-export-btn');

            if (progressEl) progressEl.style.display = 'none';
            if (statusMsgEl) {
                statusMsgEl.textContent = 'No secrets directory found for this team — secrets export skipped.';
                statusMsgEl.style.display = 'block';
                statusMsgEl.className = 'secrets-export-status-msg secrets-info';
            }
            if (btn) btn.disabled = false;

        } else if (data.status === 'failed') {
            stopSecretsExportPolling();
            const btn         = document.getElementById('secrets-export-btn');
            const statusMsgEl = document.getElementById('secrets-export-status-msg');

            updateSecretsExportProgress(0, 'FAILED', data.message || 'Secrets export failed');
            if (statusMsgEl) {
                statusMsgEl.textContent = `Secrets export failed: ${data.error || data.message || 'unknown error'}`;
                statusMsgEl.style.display = 'block';
                statusMsgEl.className = 'secrets-export-status-msg secrets-error';
            }
            if (btn) btn.disabled = false;
        }
    } catch (error) {
        console.error('Secrets export poll error:', error);
    }
}

function stopSecretsExportPolling() {
    if (secretsExportPollingInterval) {
        clearInterval(secretsExportPollingInterval);
        secretsExportPollingInterval = null;
    }
}

function updateSecretsExportProgress(percent, label, message) {
    const bar     = document.getElementById('secrets-export-progress-bar');
    const pctEl   = document.getElementById('secrets-export-progress-percent');
    const labelEl = document.getElementById('secrets-export-progress-label');
    const msgEl   = document.getElementById('secrets-export-progress-message');
    if (bar)     { bar.style.width = `${percent}%`; }
    if (pctEl)   pctEl.textContent = `${percent}%`;
    if (labelEl) labelEl.textContent = label;
    if (msgEl)   msgEl.textContent = message;
    const container = bar ? bar.closest('.progress-bar-container') : null;
    if (container) container.setAttribute('aria-valuenow', percent);
}

function downloadSecretsExport() {
    if (!currentSecretsExportJobId) return;
    window.location.href = `/api/export/secrets/download/${currentSecretsExportJobId}`;
}

function resetSecretsExportUI() {
    stopSecretsExportPolling();
    currentSecretsExportJobId = null;

    const pw1El       = document.getElementById('secrets-export-password');
    const pw2El       = document.getElementById('secrets-export-password-confirm');
    const btn         = document.getElementById('secrets-export-btn');
    const progressEl  = document.getElementById('secrets-export-progress');
    const downloadEl  = document.getElementById('secrets-export-download');
    const statusMsgEl = document.getElementById('secrets-export-status-msg');
    const panel       = document.getElementById('secrets-export-panel');

    if (pw1El) pw1El.value = '';
    if (pw2El) pw2El.value = '';
    if (btn)   btn.disabled = true;
    if (progressEl)  progressEl.style.display = 'none';
    if (downloadEl)  downloadEl.style.display = 'none';
    if (statusMsgEl) statusMsgEl.style.display = 'none';

    // Restore fields visibility in case they were hidden after complete
    if (panel) {
        const fieldsEl = panel.querySelector('.secrets-export-fields');
        if (fieldsEl) fieldsEl.style.display = '';
        const generateActionsEl = panel.querySelector('.export-actions');
        if (generateActionsEl) generateActionsEl.style.display = '';
    }

    updateSecretsExportProgress(0, 'ENCRYPTING...', 'Initializing...');
}

// ───── IMPORT ─────

function handleImportFileSelected(event) {
    const file = event.target.files[0];
    if (!file) return;
    // XACA-0602 (re-import fix): wipe any prior completed/failed import's panel +
    // session state the moment a new file is picked. This is the chosen "reset on
    // new file-select" UX — the previous result stays visible until exactly this point.
    resetImportState();
    stagedImportFile = file;
    uploadImportFile(file);
}

async function uploadImportFile(file) {
    const btn = document.getElementById('import-btn');
    if (btn) btn.disabled = true;

    // XACA-0602: the /api/import/upload POST does iCloud-materialize + upload +
    // manifest verify server-side — previously dead air. Reuse the #import-progress
    // panel as an immediate "PREPARING IMPORT…" indicator covering that whole window.
    // renderImportPreflight() hides it on success; both error paths below hide it too;
    // resetImportState() (top of handleImportFileSelected) hides it on the next select.
    const progressEl = document.getElementById('import-progress');
    if (progressEl) progressEl.style.display = 'block';
    updateImportProgress(0, 'PREPARING IMPORT…', 'Materializing, uploading and verifying archive…');

    const formData = new FormData();
    formData.append('file', file);

    try {
        const response = await apiFetch('/api/import/upload', {
            method: 'POST',
            body: formData,
        });
        const result = await readJsonResponse(response);
        if (!result.ok || result.parseError) {
            if (progressEl) progressEl.style.display = 'none';
            alert(_httpErrorMessage('Import upload failed', result));
            if (btn) btn.disabled = false;
            return;
        }
        currentImportJobId = result.data.jobId;
        renderImportPreflight(result.data);
        // Re-enable the file picker so the operator can start over if a downstream
        // apply or secrets-import step fails. cancelImport() is wired to the CANCEL
        // button in the preflight panel and provides the full reset path.
        if (btn) btn.disabled = false;
    } catch (error) {
        if (progressEl) progressEl.style.display = 'none';
        console.error('Import upload failed:', error);
        alert('Import upload failed: LCARS server not responding on this port — verify the tab URL/port and that the team server is running.');
        if (btn) btn.disabled = false;
    }
}

function renderImportPreflight(data) {
    const preflightEl = document.getElementById('import-preflight');
    if (!preflightEl) return;

    // v2 manifest: no .team, .sourceHost, .baseTeam, or .fileCount — read from top-level data.
    const sourceHostEl = document.getElementById('preflight-source-host');
    if (sourceHostEl) {
        sourceHostEl.textContent = (data.sourceIdentity && data.sourceIdentity.hostname) || '--';
        sourceHostEl.setAttribute('data-test-id', 'preflight-source-host');
    }

    // v2 manifests carry no source team field; display explicit N/A so users know it's intentional.
    const sourceTeamEl = document.getElementById('preflight-source-team');
    if (sourceTeamEl) sourceTeamEl.textContent = '(N/A in v2 manifest)';

    document.getElementById('preflight-target-team').textContent = data.targetTeam || '--';

    // Verifier pill: replace old MATCH/MISMATCH with PASS/WARN/FAIL semantic.
    // DOM row label stays "Base Match" in HTML (avoid churn) but we set the pill text to verifierState.
    const baseMatchEl = document.getElementById('preflight-base-match');
    if (baseMatchEl) {
        const verifierState = data.verifierState || 'FAIL';
        baseMatchEl.textContent = verifierState;
        baseMatchEl.setAttribute('data-state', verifierState);
        baseMatchEl.setAttribute('data-test-id', 'preflight-verifier-state');
        if (verifierState === 'PASS') {
            baseMatchEl.style.color = '#9f9';
        } else if (verifierState === 'WARN') {
            baseMatchEl.style.color = '#fa0';
        } else {
            baseMatchEl.style.color = '#f99';
        }

        // For WARN or FAIL: render a collapsible details block with verifier tail output.
        const existingDetails = document.getElementById('preflight-verifier-details');
        if (existingDetails) existingDetails.remove();
        if ((verifierState === 'WARN' || verifierState === 'FAIL') &&
                data.verifierSummary && data.verifierSummary.tail) {
            const detailsEl = document.createElement('details');
            detailsEl.id = 'preflight-verifier-details';
            detailsEl.style.cssText = 'margin-top: 6px; font-size: 0.85em; color: #9cf;';
            const summaryEl = document.createElement('summary');
            summaryEl.style.cssText = 'cursor: pointer; color: #fa0;';
            summaryEl.textContent = 'Verifier output (' + verifierState + ')';
            const preEl = document.createElement('pre');
            preEl.style.cssText = 'margin: 6px 0 0; padding: 8px; background: #0a0a1a; border: 1px solid #336; overflow-x: auto; white-space: pre-wrap; word-break: break-all; color: #9cf;';
            preEl.textContent = data.verifierSummary.tail;
            detailsEl.appendChild(summaryEl);
            detailsEl.appendChild(preEl);
            // Insert after the preflight-row containing the base-match value
            const parentRow = baseMatchEl.closest('.preflight-row');
            if (parentRow && parentRow.parentNode) {
                parentRow.parentNode.insertBefore(detailsEl, parentRow.nextSibling);
            } else {
                baseMatchEl.parentNode.appendChild(detailsEl);
            }
        }
    }

    // v2 manifests carry no source team; idRenameRequired is always false for v2.
    document.getElementById('preflight-id-rename').textContent = data.idRenameRequired
        ? `Required: ${data.targetTeam}`
        : 'Not required (same team ID)';

    // v2: single totalFileCount instead of in-tree/out-of-tree split.
    const fileCountEl = document.getElementById('preflight-file-counts');
    if (fileCountEl) {
        fileCountEl.textContent = String(data.totalFileCount ?? 0);
        fileCountEl.setAttribute('data-test-id', 'preflight-file-counts');
    }

    // Store gate data on apply button for updateImportApplyEnabled() to read.
    // baseMatch is verifier-derived (verifierState !== 'FAIL') per server 002+003.
    const applyBtnRef = document.getElementById('import-apply-btn');
    if (applyBtnRef) {
        applyBtnRef.setAttribute('data-base-match', data.baseMatch ? 'true' : 'false');
        applyBtnRef.setAttribute('data-verifier-state', data.verifierState || '');
        applyBtnRef.setAttribute('data-total-file-count', String(data.totalFileCount ?? 0));
        applyBtnRef.setAttribute('data-test-id', 'import-apply-btn');
    }

    // XACA-0554 / XACA-0566 (BUG B): gate Apply on secrets when export declares secrets.
    // Three cases show the inline picker:
    //   (F0) discovered > 0 — normal path: export ran fine, found sources on disk.
    //   (F1) detection_failed — secrets_export_lib was missing on source host; discovery
    //        returned zeros but may have missed real secrets.  Show picker with warning.
    //   (F2) expected > 0 && discovered === 0 — lib ran but found no files at pack time;
    //        export declared sources that weren't present.  Show picker with warning.
    // (F3) secrets_summary absent entirely (pre-XACA-0520-005): leave picker hidden;
    //        the file-exists guard catches it downstream.  No false-positive here.
    const secretsSummary = (data.manifest && data.manifest.secrets_summary) || {};
    const discovered = typeof secretsSummary.discovered === 'number' ? secretsSummary.discovered : 0;
    const expected   = typeof secretsSummary.expected   === 'number' ? secretsSummary.expected   : 0;
    const detectionFailed = secretsSummary.detection_failed === true;

    // showSecretsSection: true for F0, F1, F2.
    const showSecretsSection = (discovered > 0) || detectionFailed || (expected > 0 && discovered === 0);

    // currentImportSecretsDiscovered drives apply-gating and the upload path in
    // applyTeamImport().  Set it to 1 (non-zero) for F1/F2 so those paths engage.
    currentImportSecretsDiscovered = showSecretsSection ? Math.max(discovered, 1) : 0;

    const secretsSection = document.getElementById('import-secrets-required');
    const explainerEl = document.getElementById('import-secrets-explainer');
    if (secretsSection) {
        if (showSecretsSection) {
            secretsSection.style.display = 'block';
            if (explainerEl) {
                let explainerText;
                if (detectionFailed) {
                    // F1: lib missing — discovery may have been incomplete
                    explainerText =
                        'WARNING: Secret source detection was unavailable on the source host. ' +
                        'This export may contain secrets — provide the secrets zip + password ' +
                        'to continue, or re-export from a fully configured host.';
                } else if (expected > 0 && discovered === 0) {
                    // F2: lib ran but no files found at pack time
                    explainerText =
                        `This export declared ${expected} secret source${expected !== 1 ? 's' : ''} ` +
                        'but none were present on disk at export time. ' +
                        'If the secrets files were missing intentionally, proceed; ' +
                        'otherwise re-export with secrets in place. ' +
                        'Provide the secrets zip + password to continue.';
                } else {
                    // F0: normal path
                    explainerText =
                        `This export declares ${discovered} secret source${discovered !== 1 ? 's' : ''} — provide the secrets zip + password to continue.`;
                }
                explainerEl.textContent = explainerText;
            }
        } else {
            secretsSection.style.display = 'none';
        }
    }

    // XACA-0582: show the preflight-delta acknowledge checkbox only when verifier FAILed.
    const preflightDeltaAckEl = document.getElementById('import-preflight-delta-ack');
    const preflightDeltaCheckbox = document.getElementById('import-acknowledge-preflight-deltas');
    if (preflightDeltaAckEl) {
        // XACA-0582-009: default to '' (not 'FAIL') so the override checkbox only
        // appears when the verifier EXPLICITLY reports FAIL — matching data-verifier-state
        // (line ~17710) which the apply-button gate reads. A missing verifierState means
        // there is nothing to override, so the checkbox stays hidden.
        const verifierStateForAck = data.verifierState || '';
        preflightDeltaAckEl.style.display = (verifierStateForAck === 'FAIL') ? 'block' : 'none';
    }
    // Reset acknowledge checkbox on each new preflight
    if (preflightDeltaCheckbox) preflightDeltaCheckbox.checked = false;

    // Reset staged secrets file on each new preflight
    stagedImportSecretsFile = null;
    const fnLabel = document.getElementById('import-secrets-filename');
    if (fnLabel) fnLabel.textContent = '';
    const secretsPwInput = document.getElementById('import-secrets-password-input');
    if (secretsPwInput) secretsPwInput.value = '';
    const secretsErrEl = document.getElementById('import-secrets-error');
    if (secretsErrEl) secretsErrEl.style.display = 'none';
    const secretsFileInput = document.getElementById('import-secrets-file-input');
    if (secretsFileInput) secretsFileInput.value = '';

    updateImportApplyEnabled();

    // XACA-0602: clear the "PREPARING IMPORT…" indicator now that preflight is painted.
    const progressEl = document.getElementById('import-progress');
    if (progressEl) progressEl.style.display = 'none';

    preflightEl.style.display = 'block';
}

// XACA-0602: single source of truth for returning the import session to a clean
// baseline. Called from cancelImport() (CANCEL button) AND from the top of
// handleImportFileSelected() (new-file-select) — the latter is the actual re-import
// fix: a prior completed/failed import's stale state + result panel are wiped the
// moment the operator picks the next file. NOTE: onImportComplete()/onImportFailed()
// deliberately do NOT call this — the chosen UX keeps the result panel visible until
// the next file-select; they only clear the BLOCKING session bits (jobId + polling).
function resetImportState() {
    // ── Session state ──
    currentImportJobId = null;
    stagedImportFile = null;
    // XACA-0554: reset inline secrets state
    stagedImportSecretsFile = null;
    currentImportSecretsDiscovered = 0;
    stopImportPolling();

    // ── Panels ──
    const preflightEl = document.getElementById('import-preflight');
    if (preflightEl) preflightEl.style.display = 'none';
    const resultEl = document.getElementById('import-result');
    if (resultEl) resultEl.style.display = 'none';
    const progressEl = document.getElementById('import-progress');
    if (progressEl) progressEl.style.display = 'none';

    // ── Re-arm picker + button ──
    const btn = document.getElementById('import-btn');
    if (btn) btn.disabled = false;
    const input = document.getElementById('import-file-input');
    if (input) input.value = '';

    // ── Inline secrets section ──
    const secretsSection = document.getElementById('import-secrets-required');
    if (secretsSection) secretsSection.style.display = 'none';
    const secretsPwInput = document.getElementById('import-secrets-password-input');
    if (secretsPwInput) secretsPwInput.value = '';
    const secretsFileInput = document.getElementById('import-secrets-file-input');
    if (secretsFileInput) secretsFileInput.value = '';
    const fnLabel = document.getElementById('import-secrets-filename');
    if (fnLabel) fnLabel.textContent = '';
    const secretsErrEl = document.getElementById('import-secrets-error');
    if (secretsErrEl) secretsErrEl.style.display = 'none';
}

function cancelImport() {
    // XACA-0602: thin wrapper — resetImportState() is the single reset path.
    // Keep this function (the CANCEL button's onclick is wired to cancelImport()).
    resetImportState();
}

// XACA-0554: file-picker handler for the inline secrets zip in main import preflight
function handleInlineSecretsFileSelected(input) {
    const file = input && input.files && input.files[0];
    if (!file) return;
    if (!file.name.toLowerCase().endsWith('.zip')) {
        alert('Please select a .zip file.');
        input.value = '';
        return;
    }
    stagedImportSecretsFile = file;
    const fnLabel = document.getElementById('import-secrets-filename');
    if (fnLabel) fnLabel.textContent = file.name;
    updateImportApplyEnabled();
}

// XACA-0554 / XACA-0568: re-evaluates whether Apply button should be enabled.
// Floor 1: verifier must not have FAILed (data-verifier-state != 'FAIL' AND data-base-match == 'true').
// Floor 2: archive must contain at least one file (data-total-file-count > 0).
// Floor 3 (existing): when secrets are present, secrets file and password must both be provided.
function updateImportApplyEnabled() {
    const applyBtn = document.getElementById('import-apply-btn');
    if (!applyBtn) return;

    const verifierState = applyBtn.getAttribute('data-verifier-state') || '';
    const totalFiles = parseInt(applyBtn.getAttribute('data-total-file-count') || '0', 10);
    const baseMatch = applyBtn.getAttribute('data-base-match') === 'true';

    // Floor 1: verifier must not have FAILed — unless operator has acknowledged the deltas.
    // XACA-0582: acknowledgePreflightDeltas checkbox lets the apply proceed when verifier FAILed.
    if (verifierState === 'FAIL' || !baseMatch) {
        const ackCheckbox = document.getElementById('import-acknowledge-preflight-deltas');
        const ackChecked = ackCheckbox ? ackCheckbox.checked : false;
        if (!ackChecked) {
            applyBtn.disabled = true;
            applyBtn.title = 'Verifier reported FAIL — check "I acknowledge expected migration deltas" to proceed';
            return;
        }
        // Acknowledged: fall through to remaining floor checks.
    }

    // Floor 2: archive must contain files
    if (!Number.isFinite(totalFiles) || totalFiles <= 0) {
        applyBtn.disabled = true;
        applyBtn.title = 'Empty archive — nothing to import';
        return;
    }

    // Floor 3 (existing): secrets gating
    if (currentImportSecretsDiscovered > 0) {
        const secretsPwInput = document.getElementById('import-secrets-password-input');
        const password = secretsPwInput ? secretsPwInput.value : '';
        const ok = !!(stagedImportSecretsFile && password.length > 0);
        applyBtn.disabled = !ok;
        applyBtn.title = ok ? '' : 'Secrets detected — provide secrets file and password';
        return;
    }

    applyBtn.disabled = false;
    applyBtn.title = '';
}

async function applyTeamImport() {
    // XACA-0554: orchestrate secrets upload + verify before main apply when secrets required.
    if (!currentImportJobId) return;

    // XACA-0568: belt-and-suspenders guard against double-click or stale onclick firing
    // before updateImportApplyEnabled() has disabled the button. The button's disabled
    // state is the canonical gate; re-checking here closes the brief enable window race.
    const _applyBtnGuard = document.getElementById('import-apply-btn');
    if (_applyBtnGuard && _applyBtnGuard.disabled) return;

    const preflightEl = document.getElementById('import-preflight');
    const progressEl = document.getElementById('import-progress');
    const resultEl = document.getElementById('import-result');
    const secretsErrEl = document.getElementById('import-secrets-error');

    // Helper: restore preflight panel on inline error so operator can retry
    function _showInlineSecretsError(msg) {
        if (progressEl) progressEl.style.display = 'none';
        if (preflightEl) preflightEl.style.display = 'block';
        if (secretsErrEl) { secretsErrEl.textContent = msg; secretsErrEl.style.display = 'block'; }
        const applyBtn = document.getElementById('import-apply-btn');
        if (applyBtn) applyBtn.disabled = false;
        const secretsSelectBtn = document.getElementById('import-secrets-select-btn');
        if (secretsSelectBtn) secretsSelectBtn.disabled = false;
    }

    if (preflightEl) preflightEl.style.display = 'none';
    if (progressEl) progressEl.style.display = 'block';
    if (resultEl) resultEl.style.display = 'none';
    updateImportProgress(0, 'IMPORTING...', 'Starting...');

    // XACA-0582: read acknowledgePreflightDeltas before branching — used in both paths.
    const _ackDeltaCheckbox = document.getElementById('import-acknowledge-preflight-deltas');
    const _acknowledgePreflightDeltas = _ackDeltaCheckbox ? _ackDeltaCheckbox.checked : false;

    // ── SECRETS PATH (discovered > 0) ──
    if (currentImportSecretsDiscovered > 0) {
        // Step 1: upload secrets zip
        updateImportProgress(5, 'IMPORTING...', 'Uploading secrets zip...');
        const team = (window.serverConfig && window.serverConfig.team) || '';
        const secretsFormData = new FormData();
        secretsFormData.append('file', stagedImportSecretsFile);
        secretsFormData.append('team', team);

        let secretsJobId;
        try {
            const uploadResp = await apiFetch('/api/import/secrets/upload', {
                method: 'POST',
                body: secretsFormData,
            });
            const uploadResult = await readJsonResponse(uploadResp);
            if (!uploadResult.ok || uploadResult.parseError) {
                _showInlineSecretsError(_httpErrorMessage('Secrets upload failed', uploadResult));
                return;
            }
            secretsJobId = uploadResult.data.jobId;
        } catch (err) {
            console.error('Secrets upload error:', err);
            _showInlineSecretsError('Secrets upload failed: LCARS server not responding on this port — verify the tab URL/port and that the team server is running.');
            return;
        }

        // Step 2: verify password — read from DOM, zero immediately after use
        updateImportProgress(15, 'IMPORTING...', 'Verifying secrets password...');
        const secretsPwInput = document.getElementById('import-secrets-password-input');
        const password = secretsPwInput ? secretsPwInput.value : '';
        try {
            const preflightResp = await apiFetch(`/api/import/secrets/preflight/${secretsJobId}`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ password }),
            });
            // Zero password from input now — we hold it in the local `password` var only
            // through the remaining fetches in this call stack, then it falls out of scope.
            if (secretsPwInput) secretsPwInput.value = '';

            const preflightResult = await readJsonResponse(preflightResp);
            if (!preflightResult.ok || preflightResult.parseError) {
                let msg;
                if (preflightResult.parseError) {
                    msg = _httpErrorMessage('Secrets password verification failed', preflightResult);
                } else {
                    msg = (preflightResult.data && preflightResult.data.error) || 'Wrong password — please try again.';
                    if (preflightResult.data && typeof preflightResult.data.attemptsRemaining === 'number') {
                        msg += ` (${preflightResult.data.attemptsRemaining} attempt${preflightResult.data.attemptsRemaining !== 1 ? 's' : ''} remaining)`;
                    }
                }
                _showInlineSecretsError(msg);
                return;
            }
        } catch (err) {
            if (secretsPwInput) secretsPwInput.value = '';
            console.error('Secrets preflight error:', err);
            _showInlineSecretsError('Secrets password verification failed: LCARS server not responding on this port — verify the tab URL/port and that the team server is running.');
            return;
        }

        // Step 3: POST main apply with paired secrets job ID
        updateImportProgress(25, 'IMPORTING...', 'Applying import...');
        try {
            const applyResp = await apiFetch(`/api/import/apply/${currentImportJobId}`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    pairedSecretsJobId: secretsJobId,
                    acknowledgePreflightDeltas: _acknowledgePreflightDeltas,
                }),
            });
            const applyResult = await readJsonResponse(applyResp);
            if (!applyResult.ok || applyResult.parseError) {
                alert(_httpErrorMessage('Import failed', applyResult));
                if (progressEl) progressEl.style.display = 'none';
                return;
            }
        } catch (err) {
            console.error('Apply import failed:', err);
            alert('Import failed: LCARS server not responding on this port — verify the tab URL/port and that the team server is running.');
            if (progressEl) progressEl.style.display = 'none';
            return;
        }

        // Step 4: poll main import to completion; on success, apply the paired secrets.
        // XACA-0554 (PR #469 review): the password lives ONLY in this call's closure —
        // never a module-scope var — so it cannot outlive the operation or leak into a
        // later import session. Once the interval is cleared the closure is released.
        const mainJobId = currentImportJobId;
        importPollingInterval = setInterval(async () => {
            try {
                const statusResp = await fetch(`/api/import/status/${mainJobId}`);
                const statusData = await statusResp.json();
                if (!statusResp.ok) { stopImportPolling(); return; }
                updateImportProgress(statusData.progress, 'IMPORTING...', statusData.message);
                if (statusData.status === 'completed') {
                    stopImportPolling();
                    _applyPairedSecretsImport(secretsJobId, password, statusData);
                } else if (statusData.status === 'failed') {
                    stopImportPolling();
                    onImportFailed(statusData);
                }
            } catch (pollErr) {
                console.error('Import poll error:', pollErr);
            }
        }, 1000);
        return;
    }

    // ── NO SECRETS PATH (original behavior) ──
    try {
        const response = await apiFetch(`/api/import/apply/${currentImportJobId}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ acknowledgePreflightDeltas: _acknowledgePreflightDeltas }),
        });
        const result = await readJsonResponse(response);
        if (!result.ok || result.parseError) {
            alert(_httpErrorMessage('Import failed', result));
            if (progressEl) progressEl.style.display = 'none';
            return;
        }
        importPollingInterval = setInterval(() => pollImportStatus(currentImportJobId), 1000);
    } catch (error) {
        console.error('Apply import failed:', error);
        alert('Import failed: LCARS server not responding on this port — verify the tab URL/port and that the team server is running.');
        if (progressEl) progressEl.style.display = 'none';
    }
}

async function pollImportStatus(jobId) {
    try {
        const response = await fetch(`/api/import/status/${jobId}`);
        const data = await response.json();
        if (!response.ok) {
            stopImportPolling();
            return;
        }
        updateImportProgress(data.progress, 'IMPORTING...', data.message);
        if (data.status === 'completed') {
            stopImportPolling();
            onImportComplete(data);
        } else if (data.status === 'failed') {
            stopImportPolling();
            onImportFailed(data);
        }
    } catch (error) {
        console.error('Import poll error:', error);
    }
}

function stopImportPolling() {
    if (importPollingInterval) {
        clearInterval(importPollingInterval);
        importPollingInterval = null;
    }
    // XACA-0602-012: also cancel an in-flight paired-secrets poll so a new import
    // (via resetImportState) cannot leave an orphaned interval re-showing the result panel.
    if (pairedSecretsPollingInterval) {
        clearInterval(pairedSecretsPollingInterval);
        pairedSecretsPollingInterval = null;
    }
}

function updateImportProgress(percent, label, message) {
    const bar = document.getElementById('import-progress-bar');
    const pctEl = document.getElementById('import-progress-percent');
    const labelEl = document.getElementById('import-progress-label');
    const msgEl = document.getElementById('import-progress-message');
    if (bar) bar.style.width = `${percent}%`;
    if (pctEl) pctEl.textContent = `${percent}%`;
    if (labelEl) labelEl.textContent = label;
    if (msgEl) msgEl.textContent = message;
}

function renderImportStatsDOM(statsEl, stats) {
    while (statsEl.firstChild) statsEl.removeChild(statsEl.firstChild);
    const rows = [
        'Project kanban tree: overwritten',
        `Team ID rewrites: ${stats.inTreeRenames || 0}`,
        `Out-of-tree knowledge merged: ${stats.outOfTreeMerged || 0} new files`,
        `Out-of-tree conflicts (renamed): ${stats.outOfTreeConflicts || 0}`,
    ];
    for (const text of rows) {
        const div = document.createElement('div');
        div.textContent = text;
        statsEl.appendChild(div);
    }
}

function onImportComplete(data) {
    const progressEl = document.getElementById('import-progress');
    const resultEl = document.getElementById('import-result');
    const titleEl = document.getElementById('import-result-title');
    const statsEl = document.getElementById('import-result-stats');

    updateImportProgress(100, 'COMPLETE', 'Import applied successfully');
    if (progressEl) progressEl.style.display = 'none';
    if (resultEl) resultEl.style.display = 'block';
    if (titleEl) titleEl.textContent = '✓ IMPORT COMPLETE';

    if (statsEl) renderImportStatsDOM(statsEl, data.stats || {});

    setTimeout(() => {
        if (typeof loadBoardData === 'function') loadBoardData();
    }, 500);

    const btn = document.getElementById('import-btn');
    if (btn) btn.disabled = false;
    const input = document.getElementById('import-file-input');
    if (input) input.value = '';

    // XACA-0602: clear ONLY the blocking session bits so a second import can start.
    // We intentionally do NOT call resetImportState() here — the chosen UX keeps the
    // result panel (rendered just above) visible until the operator selects the next
    // file. handleImportFileSelected() runs the full teardown at that point.
    currentImportJobId = null;
    stopImportPolling();
}

// XACA-0554: step 5 — apply secrets extraction after main import succeeds.
// `password` is the decrypted value passed by value from applyTeamImport's closure;
// it is already zeroed from the DOM at this point. We zero the local var after the fetch.
async function _applyPairedSecretsImport(secretsJobId, password, mainImportData) {
    const progressEl = document.getElementById('import-progress');
    const resultEl = document.getElementById('import-result');
    const titleEl = document.getElementById('import-result-title');
    const statsEl = document.getElementById('import-result-stats');

    if (progressEl) progressEl.style.display = 'block';
    if (resultEl) resultEl.style.display = 'none';
    updateImportProgress(50, 'EXTRACTING SECRETS...', 'Applying paired secrets...');

    try {
        const applyResp = await apiFetch(`/api/import/secrets/apply/${secretsJobId}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ password }),
        });
        // Zero password from local var by overwriting (GC will handle cleanup; this limits window)
        password = '';

        const pairedApplyResult = await readJsonResponse(applyResp);
        if (!pairedApplyResult.ok || pairedApplyResult.parseError) {
            updateImportProgress(100, 'COMPLETE', 'Main import done');
            if (progressEl) progressEl.style.display = 'none';
            if (resultEl) resultEl.style.display = 'block';
            if (titleEl) titleEl.textContent = '✓ IMPORT COMPLETE — ✗ SECRETS FAILED';
            if (statsEl) {
                while (statsEl.firstChild) statsEl.removeChild(statsEl.firstChild);
                renderImportStatsDOM(statsEl, mainImportData.stats || {});
                const errDiv = document.createElement('div');
                errDiv.style.color = '#f66';
                errDiv.textContent = _httpErrorMessage('Secrets extraction failed', pairedApplyResult);
                statsEl.appendChild(errDiv);
            }
            const btn = document.getElementById('import-btn');
            if (btn) btn.disabled = false;
            return;
        }

        // Poll secrets status to completion. Tracked at module scope (XACA-0602-012)
        // so a new import's resetImportState()/stopImportPolling() can cancel it.
        stopImportPolling();
        pairedSecretsPollingInterval = setInterval(async () => {
            try {
                const statusResp = await fetch(`/api/import/secrets/status/${secretsJobId}`);
                const statusData = await statusResp.json();
                const pct = Math.round(50 + (statusData.progress || 0) * 0.5);
                updateImportProgress(pct, 'EXTRACTING SECRETS...', statusData.message || '');

                if (statusData.status === 'completed') {
                    clearInterval(pairedSecretsPollingInterval);
                    pairedSecretsPollingInterval = null;
                    updateImportProgress(100, 'COMPLETE', 'Import and secrets applied successfully');
                    if (progressEl) progressEl.style.display = 'none';
                    if (resultEl) resultEl.style.display = 'block';
                    if (titleEl) titleEl.textContent = '✓ IMPORT COMPLETE + SECRETS EXTRACTED';
                    if (statsEl) {
                        while (statsEl.firstChild) statsEl.removeChild(statsEl.firstChild);
                        renderImportStatsDOM(statsEl, mainImportData.stats || {});
                        const secDiv = document.createElement('div');
                        secDiv.textContent = `Secrets extracted: ${statusData.fileCount != null ? statusData.fileCount + ' file(s)' : 'complete'}`;
                        statsEl.appendChild(secDiv);
                    }
                    setTimeout(() => {
                        if (typeof loadBoardData === 'function') loadBoardData();
                    }, 500);
                    const btn = document.getElementById('import-btn');
                    if (btn) btn.disabled = false;
                    const input = document.getElementById('import-file-input');
                    if (input) input.value = '';
                } else if (statusData.status === 'failed') {
                    clearInterval(pairedSecretsPollingInterval);
                    pairedSecretsPollingInterval = null;
                    if (progressEl) progressEl.style.display = 'none';
                    if (resultEl) resultEl.style.display = 'block';
                    if (titleEl) titleEl.textContent = '✓ IMPORT COMPLETE — ✗ SECRETS FAILED';
                    if (statsEl) {
                        while (statsEl.firstChild) statsEl.removeChild(statsEl.firstChild);
                        renderImportStatsDOM(statsEl, mainImportData.stats || {});
                        const errDiv = document.createElement('div');
                        errDiv.style.color = '#f66';
                        errDiv.textContent = `Secrets extraction failed: ${statusData.error || statusData.message || 'unknown error'}`;
                        statsEl.appendChild(errDiv);
                    }
                    const btn = document.getElementById('import-btn');
                    if (btn) btn.disabled = false;
                }
            } catch (pollErr) {
                console.error('Secrets apply poll error:', pollErr);
            }
        }, 1500);
    } catch (err) {
        password = '';
        console.error('Paired secrets apply error:', err);
        if (progressEl) progressEl.style.display = 'none';
        if (resultEl) resultEl.style.display = 'block';
        if (titleEl) titleEl.textContent = '✓ IMPORT COMPLETE — ✗ SECRETS FAILED';
        if (statsEl) {
            while (statsEl.firstChild) statsEl.removeChild(statsEl.firstChild);
            renderImportStatsDOM(statsEl, mainImportData.stats || {});
            const errDiv = document.createElement('div');
            errDiv.style.color = '#f66';
            errDiv.textContent = 'Secrets extraction request failed — see console';
            statsEl.appendChild(errDiv);
        }
        const btn = document.getElementById('import-btn');
        if (btn) btn.disabled = false;
    }
}

function onImportFailed(data) {
    const progressEl = document.getElementById('import-progress');
    const resultEl = document.getElementById('import-result');
    const titleEl = document.getElementById('import-result-title');
    const statsEl = document.getElementById('import-result-stats');

    if (progressEl) progressEl.style.display = 'none';
    if (resultEl) resultEl.style.display = 'block';
    if (titleEl) titleEl.textContent = '✗ IMPORT FAILED';
    if (statsEl) {
        while (statsEl.firstChild) statsEl.removeChild(statsEl.firstChild);
        const div = document.createElement('div');
        div.textContent = data.error || data.message || 'unknown error';
        statsEl.appendChild(div);
    }

    const btn = document.getElementById('import-btn');
    if (btn) btn.disabled = false;

    // XACA-0602: clear ONLY the blocking session bits so the operator can retry.
    // Do NOT call resetImportState() — the failure result panel must stay visible
    // until the next file-select (handleImportFileSelected runs the full teardown).
    currentImportJobId = null;
    stopImportPolling();
}

// ═══════════════════════════════════════════════════════════════════
// SECRETS IMPORT — encrypted zip with password (XACA-0172-005)
// ═══════════════════════════════════════════════════════════════════

let currentSecretsImportJobId = null;
let secretsImportPollingInterval = null;
// NOTE: password is kept in the DOM input only; never stored in a JS variable
//       beyond the brief window of the fetch call.

function handleSecretsImportFileSelected(input) {
    const file = input && input.files && input.files[0];
    if (!file) return;
    if (!file.name.toLowerCase().endsWith('.zip')) {
        alert('Please select a .zip file.');
        input.value = '';
        return;
    }
    uploadSecretsImportFile(file);
}

async function uploadSecretsImportFile(file) {
    const selectBtn = document.getElementById('secretsImport-select-btn');
    if (selectBtn) selectBtn.disabled = true;

    // Resolve team from the server config (same source as the main import handler)
    const team = (window.serverConfig && window.serverConfig.team) || '';

    const formData = new FormData();
    formData.append('file', file);
    formData.append('team', team);

    try {
        const response = await apiFetch('/api/import/secrets/upload', {
            method: 'POST',
            body: formData,
        });
        const result = await readJsonResponse(response);
        if (!result.ok || result.parseError) {
            alert(_httpErrorMessage('Secrets upload failed', result));
            if (selectBtn) selectBtn.disabled = false;
            return;
        }
        // Backend returns { jobId, status: "awaiting-password" }
        currentSecretsImportJobId = result.data.jobId;

        // Hide file picker, show password panel
        const fileArea = document.getElementById('secretsImport-file-area');
        const pwPanel  = document.getElementById('secretsImport-password-panel');
        if (fileArea) fileArea.style.display = 'none';
        if (pwPanel)  pwPanel.style.display  = 'block';

        const pwInput = document.getElementById('secretsImport-password-input');
        if (pwInput) { pwInput.value = ''; pwInput.focus(); }

        const errEl = document.getElementById('secretsImport-password-error');
        if (errEl) errEl.style.display = 'none';
    } catch (err) {
        console.error('Secrets upload error:', err);
        alert('Secrets upload failed: LCARS server not responding on this port — verify the tab URL/port and that the team server is running.');
        if (selectBtn) selectBtn.disabled = false;
    }
}

async function verifySecretsImportPassword() {
    if (!currentSecretsImportJobId) return;

    const pwInput  = document.getElementById('secretsImport-password-input');
    const errEl    = document.getElementById('secretsImport-password-error');
    const verifyBtn = document.getElementById('secretsImport-verify-btn');

    const password = pwInput ? pwInput.value : '';
    if (!password) {
        if (errEl) { errEl.textContent = 'Password is required.'; errEl.style.display = 'block'; }
        if (pwInput) pwInput.focus();
        return;
    }

    if (verifyBtn) verifyBtn.disabled = true;
    if (errEl) errEl.style.display = 'none';

    try {
        const response = await apiFetch(`/api/import/secrets/preflight/${currentSecretsImportJobId}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ password }),
        });
        const prefResult = await readJsonResponse(response);

        if (!prefResult.ok || prefResult.parseError) {
            if (prefResult.parseError) {
                if (errEl) { errEl.textContent = _httpErrorMessage('Password verification failed', prefResult); errEl.style.display = 'block'; }
                if (verifyBtn) verifyBtn.disabled = false;
                return;
            }
            // Wrong password (HTTP 400) — show inline error, keep panel open for retry.
            // If budget exhausted the server returns a different error string and the
            // job transitions to 'failed', so _resetSecretsImportToFileArea() is called.
            const data = prefResult.data || {};
            let msg = data.error || 'Wrong password — please try again.';
            if (
                data.error === 'Too many failed password attempts. Re-upload the secrets zip to try again.' ||
                (typeof data.error === 'string' && data.error.startsWith('Too many failed password attempts'))
            ) {
                if (errEl) { errEl.textContent = msg; errEl.style.display = 'block'; }
                // Budget exhausted — return to file picker so user can re-upload.
                setTimeout(() => _resetSecretsImportToFileArea(), 3000);
                return;
            }
            if (typeof data.attemptsRemaining === 'number') {
                msg += ` (${data.attemptsRemaining} attempt${data.attemptsRemaining !== 1 ? 's' : ''} remaining)`;
            }
            if (errEl) { errEl.textContent = msg; errEl.style.display = 'block'; }
            // Clear the input so user knows to re-type
            if (pwInput) { pwInput.value = ''; pwInput.focus(); }
            if (verifyBtn) verifyBtn.disabled = false;
            return;
        }

        // Success — password stays populated so apply can reuse it
        // Show preflight panel
        const pwPanel       = document.getElementById('secretsImport-password-panel');
        const preflightPanel = document.getElementById('secretsImport-preflight-panel');
        if (pwPanel)        pwPanel.style.display        = 'none';
        if (preflightPanel) preflightPanel.style.display = 'block';

        const data = prefResult.data || {};
        renderSecretsImportPreflight(data.manifest || {}, data.fileCount, data.targetTeam, data.warning);
    } catch (err) {
        console.error('Secrets preflight error:', err);
        if (errEl) { errEl.textContent = 'Password verification failed: LCARS server not responding on this port — verify the tab URL/port and that the team server is running.'; errEl.style.display = 'block'; }
        if (pwInput) { pwInput.value = ''; pwInput.focus(); }
        if (verifyBtn) verifyBtn.disabled = false;
    }
}

function renderSecretsImportPreflight(manifest, fileCount, targetTeam, teamWarning) {
    const grid = document.getElementById('secretsImport-preflight-grid');
    if (!grid) return;

    while (grid.firstChild) grid.removeChild(grid.firstChild);

    function addRow(key, value, cls) {
        const row   = document.createElement('div'); row.className = 'preflight-row' + (cls ? ' ' + cls : '');
        const kEl   = document.createElement('span'); kEl.className = 'preflight-key';   kEl.textContent = key;
        const vEl   = document.createElement('span'); vEl.className = 'preflight-value'; vEl.textContent = value || '--';
        row.appendChild(kEl); row.appendChild(vEl);
        grid.appendChild(row);
    }

    addRow('Source Team',   manifest.team        || '--');
    addRow('Target Team',   targetTeam           || manifest.team || '--');
    addRow('Source Host',   manifest.sourceHost  || '--');
    addRow('File Count',    fileCount != null ? String(fileCount) : '--');
    addRow('Target Root',   manifest.targetRoot  || '--');

    // Team mismatch warning — warn-only, cross-team transfer is allowed
    if (teamWarning) {
        addRow('WARNING', teamWarning, 'preflight-row-warning');
    }

    // Per-source target paths
    const sources = Array.isArray(manifest.sources) ? manifest.sources : [];
    sources.forEach((src, i) => {
        const label = `Source ${i + 1} Path`;
        const files = src.fileCount != null ? ` (${src.fileCount} file${src.fileCount !== 1 ? 's' : ''})` : '';
        addRow(label, (src.target || '--') + files);
    });
}

async function applySecretsImport() {
    if (!currentSecretsImportJobId) return;

    // Re-read password from input (it was kept populated after verify)
    const pwInput  = document.getElementById('secretsImport-password-input');
    const password = pwInput ? pwInput.value : '';
    if (!password) {
        // Shouldn't normally reach here, but guard anyway
        const preflightPanel = document.getElementById('secretsImport-preflight-panel');
        const pwPanel        = document.getElementById('secretsImport-password-panel');
        const errEl          = document.getElementById('secretsImport-password-error');
        if (preflightPanel) preflightPanel.style.display = 'none';
        if (pwPanel) pwPanel.style.display = 'block';
        if (errEl) { errEl.textContent = 'Session expired — please re-enter password.'; errEl.style.display = 'block'; }
        if (pwInput) { pwInput.value = ''; pwInput.focus(); }
        return;
    }

    const preflightPanel = document.getElementById('secretsImport-preflight-panel');
    const progressEl     = document.getElementById('secretsImport-progress');
    const resultEl       = document.getElementById('secretsImport-result');
    if (preflightPanel) preflightPanel.style.display = 'none';
    if (progressEl)     progressEl.style.display     = 'block';
    if (resultEl)       resultEl.style.display       = 'none';

    updateSecretsImportProgress(0, 'EXTRACTING...', 'Starting...');

    try {
        const response = await apiFetch(`/api/import/secrets/apply/${currentSecretsImportJobId}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ password }),
        });

        // Zero the password from the input immediately after the POST
        if (pwInput) pwInput.value = '';

        const applyResult = await readJsonResponse(response);
        if (!applyResult.ok || applyResult.parseError) {
            if (progressEl) progressEl.style.display = 'none';
            alert(_httpErrorMessage('Secrets extraction failed', applyResult));
            _resetSecretsImportToFileArea();
            return;
        }
        // applyResult.data.status === "applying" — start polling
        secretsImportPollingInterval = setInterval(
            () => pollSecretsImportStatus(currentSecretsImportJobId), 1500
        );
    } catch (err) {
        console.error('Secrets apply error:', err);
        if (pwInput) pwInput.value = '';
        if (progressEl) progressEl.style.display = 'none';
        alert('Secrets extraction failed: LCARS server not responding on this port — verify the tab URL/port and that the team server is running.');
        _resetSecretsImportToFileArea();
    }
}

async function pollSecretsImportStatus(jobId) {
    try {
        const response = await fetch(`/api/import/secrets/status/${jobId}`);
        const data = await response.json();
        if (!response.ok) {
            stopSecretsImportPolling();
            return;
        }
        updateSecretsImportProgress(data.progress || 0, 'EXTRACTING...', data.message || '');

        if (data.status === 'completed') {
            stopSecretsImportPolling();
            _onSecretsImportComplete(data);
        } else if (data.status === 'failed') {
            stopSecretsImportPolling();
            _onSecretsImportFailed(data);
        }
    } catch (err) {
        console.error('Secrets import poll error:', err);
    }
}

function stopSecretsImportPolling() {
    if (secretsImportPollingInterval) {
        clearInterval(secretsImportPollingInterval);
        secretsImportPollingInterval = null;
    }
}

function updateSecretsImportProgress(percent, label, message) {
    const bar    = document.getElementById('secretsImport-progress-bar');
    const pctEl  = document.getElementById('secretsImport-progress-percent');
    const lblEl  = document.getElementById('secretsImport-progress-label');
    const msgEl  = document.getElementById('secretsImport-progress-message');
    const prog   = document.getElementById('secretsImport-progress');
    if (bar)    bar.style.width     = `${percent}%`;
    if (pctEl)  pctEl.textContent   = `${percent}%`;
    if (lblEl)  lblEl.textContent   = label;
    if (msgEl)  msgEl.textContent   = message;
    if (prog)   prog.setAttribute('aria-valuenow', String(percent));
}

function _onSecretsImportComplete(data) {
    const progressEl = document.getElementById('secretsImport-progress');
    const resultEl   = document.getElementById('secretsImport-result');
    const titleEl    = document.getElementById('secretsImport-result-title');
    const statsEl    = document.getElementById('secretsImport-result-stats');

    updateSecretsImportProgress(100, 'COMPLETE', 'Extraction complete');
    if (progressEl) progressEl.style.display = 'none';
    if (resultEl)   resultEl.style.display   = 'block';
    if (titleEl)    titleEl.textContent       = '✓ EXTRACTION COMPLETE';

    if (statsEl) {
        while (statsEl.firstChild) statsEl.removeChild(statsEl.firstChild);
        const targetRoot  = (data.manifest && data.manifest.targetRoot) || '';
        const fileCount   = data.fileCount != null ? data.fileCount : (data.manifest && data.manifest.fileCount);
        const countStr    = fileCount != null ? `${fileCount} file${fileCount !== 1 ? 's' : ''}` : 'files';
        const msg = targetRoot
            ? `Extracted ${countStr} to ${targetRoot}. Files placed in their original locations.`
            : `Extracted ${countStr}. Files placed in their original locations.`;
        const div = document.createElement('div'); div.textContent = msg;
        statsEl.appendChild(div);
    }

    // Re-enable the file picker for another import
    _resetSecretsImportToFileArea();
}

function _onSecretsImportFailed(data) {
    const progressEl = document.getElementById('secretsImport-progress');
    const resultEl   = document.getElementById('secretsImport-result');
    const titleEl    = document.getElementById('secretsImport-result-title');
    const statsEl    = document.getElementById('secretsImport-result-stats');

    if (progressEl) progressEl.style.display = 'none';
    if (resultEl)   resultEl.style.display   = 'block';
    if (titleEl)    titleEl.textContent       = '✗ EXTRACTION FAILED';

    if (statsEl) {
        while (statsEl.firstChild) statsEl.removeChild(statsEl.firstChild);
        const div = document.createElement('div'); div.textContent = data.error || data.message || 'Unknown error';
        statsEl.appendChild(div);
    }

    // If the error indicates wrong password, drop back to password panel for retry
    const errMsg = data.error || '';
    if (errMsg === 'Wrong password — please try again.' || data.status === 'awaiting-password') {
        if (resultEl) resultEl.style.display = 'none';
        const pwPanel = document.getElementById('secretsImport-password-panel');
        const errEl   = document.getElementById('secretsImport-password-error');
        if (pwPanel) pwPanel.style.display = 'block';
        if (errEl)   { errEl.textContent = errMsg || 'Wrong password — please try again.'; errEl.style.display = 'block'; }
        const pwInput = document.getElementById('secretsImport-password-input');
        if (pwInput) { pwInput.value = ''; pwInput.focus(); }
    } else {
        _resetSecretsImportToFileArea();
    }
}

function cancelSecretsImport() {
    stopSecretsImportPolling();
    currentSecretsImportJobId = null;
    _resetSecretsImportToFileArea();
}

function _resetSecretsImportToFileArea() {
    const fileArea      = document.getElementById('secretsImport-file-area');
    const pwPanel       = document.getElementById('secretsImport-password-panel');
    const preflightPanel = document.getElementById('secretsImport-preflight-panel');
    const progressEl    = document.getElementById('secretsImport-progress');
    const fileInput     = document.getElementById('secretsImport-file-input');
    const selectBtn     = document.getElementById('secretsImport-select-btn');
    const pwInput       = document.getElementById('secretsImport-password-input');
    const errEl         = document.getElementById('secretsImport-password-error');
    const verifyBtn     = document.getElementById('secretsImport-verify-btn');

    if (fileArea)       fileArea.style.display       = 'block';
    if (pwPanel)        pwPanel.style.display        = 'none';
    if (preflightPanel) preflightPanel.style.display = 'none';
    if (progressEl)     progressEl.style.display     = 'none';
    if (fileInput)      fileInput.value              = '';
    if (selectBtn)      selectBtn.disabled           = false;
    if (pwInput)        pwInput.value                = '';
    if (errEl)          errEl.style.display          = 'none';
    if (verifyBtn)      verifyBtn.disabled           = false;
}

document.addEventListener('DOMContentLoaded', async () => {
    console.log('LCARS Kanban Monitor Initializing...');
    await loadServerConfig();

    // Initialize LCARS Chart.js theming (must run after Chart.js loads)
    LCARSCharts.init();

    // Apply team class to container for org/div color theming
    applyTeamTheme();

    loadBoardData();
    startAutoRefresh();
    updateStardate();
    renderCommands();
    avatarTooltip.init();
    initQueueFilterBar();
    // XACA-0209 round 5: restore persisted search strings and wire each section's
    // search input/clear button (debounced input → set filter → re-render).
    releaseSearchText = loadSearchText(RELEASE_SEARCH_KEY);
    epicSearchText = loadSearchText(EPIC_SEARCH_KEY);
    initSectionSearchBar({
        inputId: 'release-filter-text',
        clearId: 'release-filter-clear',
        currentText: () => releaseSearchText,
        setFilter: setReleaseSearchFilter,
    });
    initSectionSearchBar({
        inputId: 'epic-filter-text',
        clearId: 'epic-filter-clear',
        currentText: () => epicSearchText,
        setFilter: setEpicSearchFilter,
    });
    // XACA-0474: hydrate epics state filter toggle from persisted value
    updateEpicsStateToggle();
    initViewToggle();
    initCommandSectionBar();

    // Sidebar button interactions - TAB SWITCHING
    document.querySelectorAll('.sidebar-button[data-section]').forEach(btn => {
        btn.addEventListener('click', () => {
            // Don't allow clicks during startup
            if (activeSection === 'startup') return;
            switchSection(btn.dataset.section);
        });
    });

    // Mode bar button interactions — XACA-0164-004
    document.querySelectorAll('.mode-pill[data-mode-target]').forEach(btn => {
        btn.addEventListener('click', () => {
            // Don't allow clicks during startup — mirrors sidebar-button guard above
            if (activeSection === 'startup') return;
            switchMode(btn.dataset.modeTarget);
        });
    });

    // Mobile tab bar button interactions - TAB SWITCHING
    document.querySelectorAll('.tabbar-button[data-section]').forEach(btn => {
        btn.addEventListener('click', () => {
            // Don't allow clicks during startup
            if (activeSection === 'startup') return;
            switchSection(btn.dataset.section);
        });
    });

    // NEW Release button click handler
    const newReleaseBtn = document.getElementById('release-new-btn');
    if (newReleaseBtn) {
        newReleaseBtn.addEventListener('click', () => {
            showCreateReleaseModal();
        });
    }

    // Configure Flow button click handler
    const configureFlowBtn = document.getElementById('release-configure-flow-btn');
    if (configureFlowBtn) {
        configureFlowBtn.addEventListener('click', () => {
            showFlowConfigModal();
        });
    }

    // NEW Epic button click handler
    const newEpicBtn = document.getElementById('epic-new-btn');
    if (newEpicBtn) {
        newEpicBtn.addEventListener('click', () => {
            showCreateEpicModal();
        });
    }

    // Calendar item click navigation - EVENT DELEGATION
    document.addEventListener('click', (e) => {
        const calendarItem = e.target.closest('.calendar-item');
        if (!calendarItem) return;
        
        // Don't navigate for external events (they're not in our system)
        if (calendarItem.classList.contains('external-event')) return;
        
        // Get item ID or epic ID from data attributes
        const itemId = calendarItem.dataset.itemId;
        const epicId = calendarItem.dataset.epicId;
        
        // Navigate to the appropriate section
        navigateToCalendarItem(itemId, epicId);
    });

    // Keyboard navigation - Alt+1 through Alt+8
    document.addEventListener('keydown', (e) => {
        // Don't allow keyboard nav during startup
        if (activeSection === 'startup') return;

        if (e.altKey && !e.ctrlKey && !e.metaKey) {
            const key = parseInt(e.key);
            if (key >= 1 && key <= 8) {
                e.preventDefault();
                // Alt+1 = home, Alt+2 = todos, Alt+3 = calendar, Alt+4 = workflow,
                // Alt+5 = details, Alt+6 = backlog, Alt+7 = epics, Alt+8 = releases
                switchSection(SECTIONS[key]);
            }
        }

        // Escape exits fullscreen mode
        if (e.key === 'Escape' && homeFullscreen) {
            e.preventDefault();
            _exitHomeFullscreen();
        }

        // Left/Right arrow keys navigate carousel panels when HOME tab is active
        // Only fires if no modifier key and no focused input element
        // Skip when fullscreen — the dedicated fullscreen keydown handler (line ~840) handles it
        if (activeSection === 'home' && !homeFullscreen && !e.altKey && !e.ctrlKey && !e.metaKey && !e.shiftKey) {
            const tag = document.activeElement ? document.activeElement.tagName : '';
            const isInput = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
            if (!isInput) {
                if (e.key === 'ArrowLeft') {
                    e.preventDefault();
                    navigateToPanel(currentLogicalPanel - 1);
                } else if (e.key === 'ArrowRight') {
                    e.preventDefault();
                    navigateToPanel(currentLogicalPanel + 1);
                }
            }
        }
    });

    // Mode-change routing — XACA-0164-007 / XACA-0164-013
    // Wired here (inside DOMContentLoaded) so all section elements exist.
    document.addEventListener('modechange', (e) => {
        const newMode = e.detail.mode;
        filterSectionsByMode(newMode);
        // Restore the last-active section for this mode, falling back to the canonical default
        const modeSections = loadModeSections();
        const targetSection = modeSections[newMode] || pickDefaultSectionForMode(newMode);
        if (targetSection) {
            switchSection(targetSection, true); // skipAnimation=true on mode switch
        }
        // Re-filter carousel panels to match the new mode — XACA-0164-008
        // showAll only in fullscreen/VIEWSCREEN; mode switch always exits fullscreen context
        applyCarouselModeFilter(newMode, homeFullscreen);
    });

    // Migration must run before any restore logic — XACA-0164-014
    runMigration();

    // Resolve initial mode + section: URL hash > localStorage > defaults — XACA-0164-013
    const hashParams = parseURLHash();
    let initialMode, _hashSection;
    if (hashParams) {
        initialMode = hashParams.mode;
        _hashSection = hashParams.section;
    } else {
        const storedMode = (() => { try { return localStorage.getItem(MODE_KEY); } catch (e) { return null; } })();
        initialMode = (storedMode && MODES.includes(storedMode)) ? storedMode : 'kanban';
        _hashSection = null;
    }

    // If the hash specified a section, pre-seed modeSections so the modechange
    // listener restores it when switchMode fires.
    if (_hashSection) {
        const modeSections = loadModeSections();
        modeSections[initialMode] = _hashSection;
        saveModeSections(modeSections);
    }

    switchMode(initialMode);
    // filterSectionsByMode runs via the modechange listener that switchMode dispatches.

    // Wire hashchange listener so back/forward and direct URL edits work — XACA-0164-013
    window.addEventListener('hashchange', () => {
        const parsed = parseURLHash();
        if (!parsed) return;
        const { mode, section } = parsed;
        // Avoid double-work if already in correct state
        if (mode !== activeMode) {
            switchMode(mode);
        }
        if (section !== activeSection) {
            switchSection(section, true);
        }
    });

    // Initialize startup screen with boot animation
    initStartupScreen();

    // CHANGE REQ — XACA-0292-006: bootstrap visibility and wire crsupport-changed listener
    initChangeReqSection();

    // CHANGE REQ — XACA-0292-007: mount CR list view filter bar
    if (typeof initChangeReqTab === 'function') initChangeReqTab();

    // XACA-0332: wire up the copyright Save button
    initCopyrightSaveButton();

    // XACA-0334-006: wire Daily Overview delegated interactions + refresh button
    if (typeof initDailyOverviewInteractions === 'function') initDailyOverviewInteractions();

    console.log('LCARS Kanban Monitor Ready');
});

// ═══════════════════════════════════════════════════════════════════════════════
// TODO LIST (XACA-0101)
// ═══════════════════════════════════════════════════════════════════════════════

// State
let currentTodoFilter = 'todo';
let todosCache = [];

/**
 * Load todos from API for the current team and render them.
 * GET /api/todos?team={team}
 */
async function loadTodos() {
    // Show loading, hide list and empty state
    const loadingEl = document.getElementById('todo-loading');
    const listEl = document.getElementById('todo-list');
    const emptyEl = document.getElementById('todo-empty');
    if (loadingEl) loadingEl.style.display = '';
    if (listEl) listEl.style.display = 'none';
    if (emptyEl) emptyEl.style.display = 'none';

    try {
        const team = CONFIG.team || 'freelance';
        const response = await fetch(apiUrl(`/api/todos?team=${encodeURIComponent(team)}`));
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }
        const data = await response.json();
        todosCache = data.todos || [];
    } catch (err) {
        console.error('Failed to load todos:', err);
        todosCache = [];
    }

    if (loadingEl) loadingEl.style.display = 'none';
    if (listEl) listEl.style.display = '';
    renderTodos();
}

/**
 * Render the todo list based on the current filter.
 * Filters todosCache by currentTodoFilter and generates list HTML.
 */
function renderTodos() {
    const listEl = document.getElementById('todo-list');
    const emptyEl = document.getElementById('todo-empty');
    if (!listEl) return;

    // Filter by status — 'todo' = active, 'completed' = done
    const filtered = todosCache.filter(t => t.status === currentTodoFilter);

    if (filtered.length === 0) {
        listEl.innerHTML = '';
        if (emptyEl) emptyEl.style.display = '';
        return;
    }

    if (emptyEl) emptyEl.style.display = 'none';

    // Sort: critical/high first for active; newest first for completed
    const sorted = [...filtered].sort((a, b) => {
        if (currentTodoFilter === 'todo') {
            const priorityOrder = { critical: 0, high: 1, medium: 2, low: 3 };
            const pa = priorityOrder[a.priority] ?? 2;
            const pb = priorityOrder[b.priority] ?? 2;
            if (pa !== pb) return pa - pb;
        }
        // Secondary sort: newest created first
        return new Date(b.createdAt || 0) - new Date(a.createdAt || 0);
    });

    listEl.innerHTML = sorted.map(todo => renderTodoItem(todo)).join('');
}

/**
 * Build the HTML string for a single todo item row.
 * Includes checkbox, text, priority badge, optional due date, and edit button.
 */
function renderTodoItem(todo) {
    const isCompleted = todo.status === 'completed';
    const completedClass = isCompleted ? ' todo-completed' : '';
    const checkboxChecked = isCompleted ? 'checked' : '';
    const safeId = String(todo.id).replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    const safeText = (todo.text || '').replace(/</g, '&lt;').replace(/>/g, '&gt;');

    // Priority badge
    const priority = todo.priority || 'medium';
    const priorityLabel = priority.toUpperCase();
    const priorityBadge = `<span class="todo-priority-badge todo-priority-${priority}">${priorityLabel}</span>`;

    // Due date display + overdue detection (single computation)
    let dueDateHtml = '';
    let overdueItemClass = '';
    if (todo.requiredBy) {
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        const dueDate = new Date(todo.requiredBy + 'T00:00:00');
        const isOverdue = !isCompleted && dueDate < today;
        if (isOverdue) overdueItemClass = ' todo-overdue';
        const overdueClass = isOverdue ? ' todo-due-overdue' : '';
        const overdueLabel = isOverdue ? ' (OVERDUE)' : '';
        const formattedDate = String(todo.requiredBy).replace(/</g, '&lt;').replace(/>/g, '&gt;');
        dueDateHtml = `<span class="todo-due-date${overdueClass}">BY ${formattedDate}${overdueLabel}</span>`;
    }

    return `
        <div class="todo-item${completedClass}${overdueItemClass}" data-todo-id="${safeId}">
            <input type="checkbox" class="todo-checkbox" ${checkboxChecked}
                   onchange="toggleTodo('${safeId}')" title="Mark ${isCompleted ? 'active' : 'complete'}">
            <div class="todo-content">
                <div class="todo-text">${safeText}</div>
                <div class="todo-meta">
                    ${priorityBadge}
                    ${dueDateHtml}
                </div>
            </div>
            <button class="todo-edit-btn" onclick="openTodoModal('${safeId}')">EDIT</button>
        </div>
    `;
}

/**
 * Update the active tab and re-render with the new filter.
 */
function filterTodos(filter) {
    currentTodoFilter = filter;

    // Update tab button active state
    document.querySelectorAll('.todo-tab').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.filter === filter);
    });

    renderTodos();
}

/**
 * Open the todo modal for add (todoId = null) or edit (todoId provided).
 * Pre-fills form fields when editing.
 */
function openTodoModal(todoId = null) {
    const modal = document.getElementById('todo-modal');
    const titleEl = document.getElementById('todo-modal-title');
    const editIdEl = document.getElementById('todo-edit-id');
    const textEl = document.getElementById('todo-text');
    const priorityEl = document.getElementById('todo-priority');
    const requiredByEl = document.getElementById('todo-required-by');
    const deleteBtn = document.getElementById('todo-delete-btn');

    if (!modal) return;

    // Clear the form first
    editIdEl.value = '';
    textEl.value = '';
    priorityEl.value = 'medium';
    requiredByEl.value = '';
    if (deleteBtn) deleteBtn.style.display = 'none';

    if (todoId !== null) {
        // Edit mode — find existing todo in cache
        const todo = todosCache.find(t => String(t.id) === String(todoId));
        if (todo) {
            editIdEl.value = todo.id;
            textEl.value = todo.text || '';
            priorityEl.value = todo.priority || 'medium';
            requiredByEl.value = todo.requiredBy || '';
            if (titleEl) titleEl.textContent = 'EDIT TODO';
            if (deleteBtn) deleteBtn.style.display = '';
        } else {
            if (titleEl) titleEl.textContent = 'EDIT TODO';
        }
    } else {
        // Add mode
        if (titleEl) titleEl.textContent = 'ADD TODO';
    }

    modal.style.display = 'flex';
    // Focus the text area after display
    setTimeout(() => textEl.focus(), 50);
}

/**
 * Close the todo modal and clear the form.
 */
function closeTodoModal() {
    const modal = document.getElementById('todo-modal');
    if (modal) modal.style.display = 'none';
}

/**
 * Save a todo — creates new (POST) or updates existing (PUT) based on edit-id field.
 * Reloads todos and closes the modal on success.
 */
async function saveTodo() {
    const editId = document.getElementById('todo-edit-id').value;
    const text = (document.getElementById('todo-text').value || '').trim();
    const priority = document.getElementById('todo-priority').value;
    const requiredBy = document.getElementById('todo-required-by').value || null;

    if (!text) {
        alert('Item text is required.');
        document.getElementById('todo-text').focus();
        return;
    }

    const team = CONFIG.team || 'freelance';
    const payload = { team, text, priority, requiredBy };

    try {
        let response;
        if (editId) {
            // Update existing — server expects { team, id, updates: {...} }
            response = await apiFetch(apiUrl('/api/todos'), {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ team, id: editId, updates: { text, priority, requiredBy } })
            });
        } else {
            // Create new
            response = await apiFetch(apiUrl('/api/todos'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });
        }

        if (!response.ok) {
            const err = await response.json().catch(() => ({}));
            throw new Error(err.error || `HTTP ${response.status}`);
        }

        closeTodoModal();
        await loadTodos();
    } catch (err) {
        console.error('Failed to save todo:', err);
        alert(`Failed to save todo: ${err.message}`);
    }
}

/**
 * Delete the currently open todo after user confirmation.
 * Sends DELETE /api/todos, then reloads and closes modal.
 */
async function deleteTodo() {
    const editId = document.getElementById('todo-edit-id').value;
    if (!editId) return;

    if (!confirm('Delete this todo item? This cannot be undone.')) return;

    const team = CONFIG.team || 'freelance';

    try {
        const response = await apiFetch(apiUrl('/api/todos'), {
            method: 'DELETE',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ team, id: editId })
        });

        if (!response.ok) {
            const err = await response.json().catch(() => ({}));
            throw new Error(err.error || `HTTP ${response.status}`);
        }

        closeTodoModal();
        await loadTodos();
    } catch (err) {
        console.error('Failed to delete todo:', err);
        alert(`Failed to delete todo: ${err.message}`);
    }
}

/**
 * Toggle a todo item between active ('todo') and completed status.
 * Sends PUT /api/todos with the toggled status, then reloads.
 */
async function toggleTodo(todoId) {
    const todo = todosCache.find(t => String(t.id) === String(todoId));
    if (!todo) return;

    const newStatus = todo.status === 'completed' ? 'todo' : 'completed';
    const team = CONFIG.team || 'freelance';

    try {
        const response = await apiFetch(apiUrl('/api/todos'), {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ team, id: todoId, updates: { status: newStatus } })
        });

        if (!response.ok) {
            const err = await response.json().catch(() => ({}));
            throw new Error(err.error || `HTTP ${response.status}`);
        }

        await loadTodos();
    } catch (err) {
        console.error('Failed to toggle todo:', err);
        alert(`Failed to update todo: ${err.message}`);
        // Re-render to restore checkbox visual state
        renderTodos();
    }
}


// =============================================================================
// TEAM CONFIG — XACA-0292 + XACA-0332
// Loads and persists per-board settings: crSupport.enabled + copyright fields.
// Dispatches 'crsupport-changed' on toggle so other agents can react.
// =============================================================================

// XACA-0333-003: TBD detection now uses server-supplied teamConfig.copyright.is_placeholder
// (server is the single source of truth for placeholder strings; previous _COPYRIGHT_TBD_VALUES removed).

/**
 * Fetch the current teamConfig from the server and wire up the CR checkbox
 * and all copyright fields.
 * Safe to call multiple times (re-reads server state each visit).
 */
async function loadTeamConfig() {
    const checkbox = document.getElementById('team-config-cr-checkbox');
    const statusEl = document.getElementById('team-config-cr-status');
    if (!checkbox) return;

    try {
        const response = await fetch(apiUrl('/api/team-config'));
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const data = await response.json();

        const enabled = !!(data.teamConfig && data.teamConfig.crSupport && data.teamConfig.crSupport.enabled);
        checkbox.checked = enabled;

        // Wire change handler (replace any existing to avoid duplicate listeners)
        checkbox.onchange = () => saveTeamConfigCRSupport(checkbox, statusEl);

        if (statusEl) {
            statusEl.textContent = '';
            statusEl.className = 'team-config-status';
        }

        // XACA-0332: populate copyright fields if present
        if (data.teamConfig && data.teamConfig.copyright) {
            _populateCopyrightFields(data.teamConfig.copyright);
        } else {
            _populateCopyrightFields(null);
        }
    } catch (err) {
        console.error('[team-config] Failed to load:', err);
        if (statusEl) {
            statusEl.textContent = 'Load error';
            statusEl.className = 'team-config-status error';
        }
    }
}

/**
 * Populate the five copyright input elements from a copyright block.
 * If block is null/undefined, marks all inputs as unset.
 * Applies TBD warning styling for placeholder values.
 */
function _populateCopyrightFields(copyright) {
    // XACA-0333-003: use server-supplied is_placeholder map; empty map = safe fallback (no TBD badges shown).
    const isPlaceholderMap = (copyright && copyright.is_placeholder) || {};
    const fields = [
        { id: 'team-config-copyright-owner', key: 'copyright_owner', tbdId: 'team-config-copyright-owner-tbd' },
        { id: 'team-config-component-label', key: 'component_label', tbdId: 'team-config-component-label-tbd' },
    ];
    const selects = [
        { id: 'team-config-license-type', key: 'license_type' },
        { id: 'team-config-notice-template', key: 'notice_template' },
    ];
    const numericFields = [
        { id: 'team-config-year-start', key: 'year_start' },
    ];

    fields.forEach(({ id, key, tbdId }) => {
        const el = document.getElementById(id);
        const tbdEl = tbdId ? document.getElementById(tbdId) : null;
        if (!el) return;
        const val = copyright ? copyright[key] : null;
        if (val == null) {
            el.value = '';
            el.classList.add('unset');
            el.classList.remove('tbd-warning');
            if (tbdEl) tbdEl.style.display = 'none';
        } else {
            el.value = val;
            el.classList.remove('unset');
            const isTbd = !!isPlaceholderMap[key];
            el.classList.toggle('tbd-warning', isTbd);
            if (tbdEl) tbdEl.style.display = isTbd ? 'inline-block' : 'none';
        }
    });

    selects.forEach(({ id, key }) => {
        const el = document.getElementById(id);
        if (!el) return;
        const val = copyright ? copyright[key] : null;
        if (val == null) {
            el.value = '';
            el.classList.add('unset');
        } else {
            el.value = val;
            el.classList.remove('unset');
        }
    });

    numericFields.forEach(({ id, key }) => {
        const el = document.getElementById(id);
        if (!el) return;
        const val = copyright ? copyright[key] : null;
        if (val == null) {
            el.value = '';
            el.classList.add('unset');
        } else {
            el.value = String(val);
            el.classList.remove('unset');
        }
    });
}

/**
 * Wire up the "Save Copyright" button on DOM ready.
 * Called once from DOMContentLoaded init (below).
 */
function initCopyrightSaveButton() {
    const btn = document.getElementById('team-config-copyright-save-btn');
    if (!btn) return;
    btn.onclick = saveTeamConfigCopyright;
}

/**
 * Collect current copyright field values and POST to /api/team-config.
 * Shows inline saving/saved/error status next to the Save button.
 */
async function saveTeamConfigCopyright() {
    const statusEl = document.getElementById('team-config-copyright-status');

    const copyrightOwner = (document.getElementById('team-config-copyright-owner') || {}).value || '';
    const licenseType = (document.getElementById('team-config-license-type') || {}).value || '';
    const componentLabel = (document.getElementById('team-config-component-label') || {}).value || '';
    const yearStartRaw = (document.getElementById('team-config-year-start') || {}).value || '';
    const noticeTemplate = (document.getElementById('team-config-notice-template') || {}).value || '';

    // Client-side validation (mirrors server rules)
    if (!copyrightOwner || copyrightOwner.length > 200) {
        _setCopyrightStatus(statusEl, 'error', 'Copyright owner is required (1-200 chars)');
        return;
    }
    if (!licenseType) {
        _setCopyrightStatus(statusEl, 'error', 'License type is required');
        return;
    }
    if (!componentLabel || componentLabel.length > 200) {
        _setCopyrightStatus(statusEl, 'error', 'Component label is required (1-200 chars)');
        return;
    }
    const yearStart = parseInt(yearStartRaw, 10);
    if (isNaN(yearStart) || yearStart < 1990 || yearStart > 2100) {
        _setCopyrightStatus(statusEl, 'error', 'Year start must be 1990-2100');
        return;
    }
    if (!noticeTemplate) {
        _setCopyrightStatus(statusEl, 'error', 'Notice template is required');
        return;
    }

    _setCopyrightStatus(statusEl, 'saving', 'Saving...');

    try {
        const response = await apiFetch(apiUrl('/api/team-config'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                team: CONFIG.team,
                teamConfig: {
                    copyright: {
                        copyright_owner: copyrightOwner,
                        license_type: licenseType,
                        component_label: componentLabel,
                        year_start: yearStart,
                        notice_template: noticeTemplate,
                    }
                }
            })
        });

        const result = await response.json().catch(() => ({}));

        if (!response.ok) {
            throw new Error(result.error || `HTTP ${response.status}`);
        }

        // Re-apply TBD styling after save (values may have changed)
        // XACA-0333-005: server response now always includes saved copyright block (with is_placeholder)
        _populateCopyrightFields(result.teamConfig && result.teamConfig.copyright);

        if (result.warning) {
            // Partial save: the fields were validated and applied in-memory, but the
            // underlying write did not fully succeed (e.g. lock contention on
            // team-paths.json — XACA-1059). Surface this as a distinct amber warning
            // state rather than green "saved", and lead with the failure text instead
            // of burying it in a parenthetical.
            _setCopyrightStatus(statusEl, 'warning', `${result.warning} — changes may not be fully saved`);
            setTimeout(() => _setCopyrightStatus(statusEl, '', ''), 6000);
        } else {
            _setCopyrightStatus(statusEl, 'saved', 'Saved');
            setTimeout(() => _setCopyrightStatus(statusEl, '', ''), 3000);
        }

    } catch (err) {
        console.error('[team-config] Copyright save failed:', err);
        _setCopyrightStatus(statusEl, 'error', `Save failed: ${err.message}`);
    }
}

function _setCopyrightStatus(el, type, text) {
    if (!el) return;
    el.textContent = text;
    el.className = 'team-config-status' + (type ? ' ' + type : '');
    // XACA-1059: no `.team-config-status.warning` rule exists in lcars.css yet, so the
    // 'warning' type is colored inline (amber, matching the LCARS warning convention
    // used for e.g. `.backup-stat .stat-value.status-warning`) rather than silently
    // rendering with no distinguishing color. Cleared for every other type so it never
    // leaks into a subsequent 'saved'/'error' state, which already have CSS-defined colors.
    el.style.color = (type === 'warning') ? 'var(--lcars-amber, #ffcc00)' : '';
}

/**
 * Persist crSupport.enabled to the server.
 * On success: dispatch 'crsupport-changed' DOM event with { enabled } detail.
 * On failure: revert checkbox state and show error message.
 */
async function saveTeamConfigCRSupport(checkbox, statusEl) {
    const enabled = checkbox.checked;

    // Warn before turning CR support OFF if any CRs already exist on this board.
    // Disabling does not delete CRs, but it hides the CHANGE REQ tab + per-item
    // CR doc tab, which is surprising if the user has live CRs in flight.
    if (!enabled) {
        const crCount = (window.boardData?.backlog || []).filter(item =>
            item.cr_id && String(item.cr_id).trim().length > 0
        ).length;
        if (crCount > 0) {
            const proceed = confirm(
                `${crCount} change request${crCount === 1 ? '' : 's'} ` +
                `currently exist${crCount === 1 ? 's' : ''} on this board.\n\n` +
                `Disabling CR support will hide the CHANGE REQ tab and the CR ` +
                `document tab on each item. Existing CR data is preserved and ` +
                `will reappear if you re-enable CR support.\n\n` +
                `Disable CR support anyway?`
            );
            if (!proceed) {
                checkbox.checked = true; // revert visual state
                return;
            }
        }
    }

    if (statusEl) {
        statusEl.textContent = 'Saving...';
        statusEl.className = 'team-config-status saving';
    }

    try {
        const response = await apiFetch(apiUrl('/api/team-config'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                team: CONFIG.team,
                teamConfig: { crSupport: { enabled } }
            })
        });

        if (!response.ok) {
            const err = await response.json().catch(() => ({}));
            throw new Error(err.error || `HTTP ${response.status}`);
        }

        if (statusEl) {
            statusEl.textContent = 'Saved';
            statusEl.className = 'team-config-status saved';
            // Fade out after 2 s
            setTimeout(() => {
                if (statusEl.className === 'team-config-status saved') {
                    statusEl.textContent = '';
                    statusEl.className = 'team-config-status';
                }
            }, 2000);
        }

        // Notify other agents/components — no page reload
        document.dispatchEvent(new CustomEvent('crsupport-changed', { detail: { enabled } }));
        console.log('[team-config] crsupport-changed dispatched: enabled=' + enabled);

    } catch (err) {
        console.error('[team-config] Save failed:', err);
        // Revert checkbox visual state
        checkbox.checked = !enabled;
        if (statusEl) {
            statusEl.textContent = 'Save failed';
            statusEl.className = 'team-config-status error';
        }
    }
}

// =============================================================================
// CHANGE REQ SECTION — XACA-0292-006
// Conditional mount/unmount based on crSupport.enabled flag.
// =============================================================================

/**
 * Apply visibility state for the CHANGE REQ tab and section.
 * When enabled=false (default Academy state), sidebar/tabbar buttons and the
 * section element are hidden with style="display:none" — no DOM removal.
 * When enabled=true they are unhidden, making the section reachable via routing.
 * If the user is currently viewing CHANGE REQ when the flag turns false, they
 * are navigated back to BACKLOG without a page reload.
 *
 * @param {boolean} enabled
 */
function applyChangeReqVisibility(enabled) {
    const sidebarBtn = document.getElementById('sidebar-btn-change-req');
    const tabbarBtn  = document.getElementById('tabbar-btn-change-req');
    const section    = document.getElementById('section-change-req');

    const display = enabled ? '' : 'none';
    if (sidebarBtn) sidebarBtn.style.display = display;
    if (tabbarBtn)  tabbarBtn.style.display  = display;
    if (section)    section.style.display    = display;

    // If the user is currently on CHANGE REQ and the flag just turned off,
    // navigate them to BACKLOG immediately (no page reload).
    if (!enabled && activeSection === 'change-req') {
        switchSection('backlog');
    }

    console.log('[change-req] visibility set to ' + (enabled ? 'visible' : 'hidden'));
}

/**
 * Bootstrap CHANGE REQ visibility on page load.
 * Fetches /api/team-config once and applies the initial state.
 * On error (e.g. server not yet running) defaults to hidden — safe.
 */
async function initChangeReqSection() {
    try {
        const response = await fetch(apiUrl('/api/team-config'));
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const data = await response.json();
        const enabled = !!(data.teamConfig && data.teamConfig.crSupport && data.teamConfig.crSupport.enabled);
        applyChangeReqVisibility(enabled);
    } catch (err) {
        console.warn('[change-req] Could not load team-config on init; defaulting to hidden:', err);
        applyChangeReqVisibility(false);
    }

    // Listen for runtime toggles (dispatched by saveTeamConfigCRSupport)
    document.addEventListener('crsupport-changed', (e) => {
        applyChangeReqVisibility(!!(e.detail && e.detail.enabled));
    });
}

// =============================================================================
// ROADMAP SECTION — XACA-0625-004
// =============================================================================
// =============================================================================
// ROADMAP EXPORT (XACA-0625-006)
// =============================================================================

/**
 * Export the roadmap as a PDF using client-side html2canvas + jsPDF.
 *
 * Strategy (XACA-0633 — replaces window.print() approach):
 *   window.print() is a no-op in iTerm2's WKWebView cockpit, producing a
 *   stuck full-window takeover and no PDF.  This implementation captures
 *   #roadmap-content with html2canvas, builds a landscape jsPDF document
 *   sized to the content, and downloads it directly via doc.save().
 *
 *   Requires: window.html2canvas (html2canvas 1.4.1) and window.jspdf.jsPDF
 *   (jsPDF 2.5.1), both vendored as UMD scripts loaded before lcars.js.
 *
 * buildRoadmapPdf() — pure builder, exposed as window.__buildRoadmapPdf for
 *   headless verification.  Returns { doc, filename }.
 * exportRoadmapPdf() — save wrapper; handles button state and error toast.
 *
 * Does NOT touch body classes, does NOT call window.print(), does NOT register
 * afterprint listeners, does NOT need a janitor timeout.
 */
async function buildRoadmapPdf() {
    const el = document.getElementById('roadmap-content');
    if (!el) throw new Error('roadmap-content not found');

    if (typeof window.html2canvas !== 'function') {
        throw new Error('html2canvas not loaded — vendor script missing');
    }
    if (!window.jspdf || typeof window.jspdf.jsPDF !== 'function') {
        throw new Error('jsPDF not loaded — vendor script missing');
    }

    // OFF-SCREEN CLONE CAPTURE (XACA-0636). The live roadmap lives in a
    // position:absolute; overflow-y:auto scroll container which, in WKWebView, does
    // NOT lay out / paint its lower off-screen rows — so el.scrollHeight is short and
    // capturing the live element truncates the PDF (the bottom epics go missing, same
    // root cause as "scrolling doesn't render more content"). We instead capture a
    // deep clone appended off-screen to <body> with NO clipping/scrolling ancestor and
    // an explicit width, so the ENTIRE content lays out and renders. The clone carries
    // the live stacker's inline styles; at the same width they resolve identically.
    const liveWidth = el.clientWidth || el.scrollWidth;
    const clone = el.cloneNode(true);
    clone.id = 'roadmap-pdf-clone';
    clone.classList.add('roadmap-pdf-light');   // white-bg light theme for export
    Object.assign(clone.style, {
        position: 'absolute', left: '-100000px', top: '0',
        width: liveWidth + 'px', height: 'auto', minHeight: '0',
        overflow: 'visible', margin: '0', zIndex: '-1',
    });

    // Title header for the export (XACA-0641). The on-screen cockpit already carries
    // a "ROADMAP" section title (outside #roadmap-content, so not captured), but the
    // PDF opened straight into the timeline with nothing identifying it. Prepend a
    // header — team name + "Roadmap" + generation date — to the clone only.
    const hdr = document.createElement('div');
    hdr.className = 'roadmap-pdf-header';
    const teamName = roadmapTeamName();
    const hdrTitle = (teamName ? teamName + ' — ' : '') + 'Roadmap';
    const gen = new Date().toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' });
    hdr.innerHTML =
        `<div class="roadmap-pdf-title">${escapeHtml(hdrTitle)}</div>` +
        `<div class="roadmap-pdf-subtitle">Generated ${escapeHtml(gen)}</div>`;
    clone.insertBefore(hdr, clone.firstChild);

    document.body.appendChild(clone);

    const { jsPDF } = window.jspdf;
    const PAGE_W = 1122;   // ~A4 landscape width in pt
    const PAGE_H = 793;    // ~A4 landscape height in pt
    const doc = new jsPDF({ orientation: 'landscape', unit: 'pt', format: [PAGE_W, PAGE_H] });

    try {
        void clone.offsetHeight;  // force a layout flush
        // Re-run the lane stacker on the clone (XACA-0641). The clone is laid out at
        // the live width with overflow:visible and no scroll ancestor — the ideal
        // context to (re)compute row-packing, the title-priority fit, and external
        // bar labels, so the PDF reflects them even if the live view's stacker state
        // was stale or had measured a pre-layout (zero-width) track.
        try { stackRoadmapLanes(clone); void clone.offsetHeight; } catch (e) { /* layout race */ }
        const fullW = clone.scrollWidth;
        const fullH = clone.scrollHeight;

        // CHUNKED CAPTURE: render the content ONE page-region at a time. Even with the
        // fully-laid-out clone, a single tall canvas can hit WKWebView's canvas-size
        // limit; per-page chunks never do.

        // Gap-aware page breaks in DOM coordinates: never cut through a card. Collect
        // every content block's vertical span; a break y is "safe" if it lands in a gap
        // (inside no block).
        const elTop = clone.getBoundingClientRect().top;
        const blockSel = '.roadmap-pdf-header, .roadmap-chip, .roadmap-bar, .roadmap-milestone, .roadmap-axis,' +
            ' .roadmap-unscheduled-heading, .roadmap-unscheduled-subheading,' +
            ' .roadmap-unscheduled-status-label, .roadmap-lane-label,' +
            ' .roadmap-details-heading, .roadmap-details-subheading, .roadmap-details-substate, .roadmap-details-entry';
        const blocks = Array.from(clone.querySelectorAll(blockSel)).map(b => {
            const r = b.getBoundingClientRect();
            return [r.top - elTop, r.bottom - elTop];
        });
        const insideBlock = (yy) => blocks.some(([t, b]) => yy > t + 0.5 && yy < b - 0.5);

        // Paginate only down to the last real content, not the element's trailing
        // bottom padding — otherwise that padding becomes a blank final page.
        const contentBottom = blocks.length ? Math.max(...blocks.map(b => b[1])) : fullH;
        const effH = Math.min(fullH, contentBottom + 14);

        // OUTER MARGINS (XACA-0636): the document perimeter (left/right on every page,
        // top of the first page, bottom of the last page) gets a white margin so the
        // content doesn't bleed to the paper edge. INTERNAL page joins stay flush so
        // the content reads continuously across a break. Content is scaled to the
        // margined width, consistent across all pages.
        const M = 16;                       // outer margin, pt
        const contentW = PAGE_W - 2 * M;    // drawn content width, pt
        const pxPerPt  = fullW / contentW;  // CSS px per pt at the horizontal scale
        const ptToPx   = (pt) => pt * pxPerPt;

        // Find a card-gap break at/above `target` (px), never below `minY`.
        const gapCut = (yStart, target) => {
            const win = (target - yStart) * 0.30;
            const minY = yStart + (target - yStart) * 0.5;
            let cut = target;
            for (let yy = target; yy > target - win && yy > minY; yy -= 2) {
                if (!insideBlock(yy)) { cut = yy; break; }
            }
            if (cut <= yStart) cut = target;
            return Math.min(cut, effH);
        };

        // Greedy pages: interior pages fill flush to the page bottom (seamless join);
        // the last page keeps a bottom margin. First page has a top margin.
        const pages = [];
        let y = 0, idx = 0, guard = 0;
        while (y < effH - 1 && guard++ < 500) {
            const topInset = (idx === 0) ? M : 0;
            const flushCapPx = ptToPx(PAGE_H - topInset);        // content flush to bottom
            const lastCapPx  = ptToPx(PAGE_H - topInset - M);    // content with bottom margin
            if (y + lastCapPx >= effH) {                         // remainder is the last page
                pages.push({ top: y, bottom: effH, topInset });
                break;
            }
            const cut = gapCut(y, y + flushCapPx);
            pages.push({ top: y, bottom: cut, topInset });
            y = cut; idx++;
        }

        let rendered = 0;
        for (const pg of pages) {
            const chunkTop = pg.top, chunkH = pg.bottom - pg.top;
            if (chunkH <= 1) continue;
            const hasContent = blocks.some(([t, b]) => b > chunkTop + 1 && t < chunkTop + chunkH - 1);
            if (!hasContent) continue;

            const c = await window.html2canvas(clone, {
                backgroundColor: '#ffffff',
                scale: 2,
                useCORS: true,
                x: 0, y: chunkTop,
                width: fullW, height: chunkH,
                windowWidth: fullW, windowHeight: fullH,
                scrollX: 0, scrollY: 0
            });

            if (rendered > 0) doc.addPage([PAGE_W, PAGE_H], 'landscape');
            // JPEG (not PNG): jsPDF 2.5.1's PNG parser chokes on some canvas output.
            const img = c.toDataURL('image/jpeg', 0.92);
            const drawH = chunkH / pxPerPt;  // chunk height in pt at the margined scale
            doc.addImage(img, 'JPEG', M, pg.topInset, contentW, drawH);
            rendered++;
        }
    } finally {
        clone.remove();
    }

    const filename = buildRoadmapPdfFilename();
    doc.setProperties({ title: filename.replace(/\.pdf$/i, '') });

    return { doc, filename };
}

/**
 * Build the export filename: "<Team Name> - Roadmap - YYYYMMDD.pdf"
 * e.g. "Academy Team - Roadmap - 20260605.pdf".
 *
 * Derived deterministically from the team slug (CONFIG.team → title-cased + "Team")
 * rather than document.title, which is unstable — it gets overwritten with the
 * session name / org banner depending on load timing. (XACA-0636)
 */
function roadmapTeamName() {
    const slug = (typeof CONFIG !== 'undefined' && CONFIG && CONFIG.team) ? String(CONFIG.team) : '';
    if (slug) {
        const titled = slug.replace(/[-_]+/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
        return `${titled} Team`;
    }
    return '';
}

function buildRoadmapPdfFilename() {
    const name = roadmapTeamName() || 'Roadmap';
    const d = new Date();
    const ymd = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`;
    // Sanitize characters illegal in filenames.
    const safe = name.replace(/[\\/:*?"<>|]+/g, '').trim();
    return `${safe} - Roadmap - ${ymd}.pdf`;
}

// Headless verification hook — allows test harnesses to call the builder
// without triggering a file-save dialog.
window.__buildRoadmapPdf = buildRoadmapPdf;

async function exportRoadmapPdf() {
    const btn = document.querySelector('.roadmap-pdf-btn');
    const prevText = btn ? btn.textContent : null;

    try {
        if (btn) { btn.setAttribute('disabled', 'true'); btn.textContent = 'GENERATING…'; }
        const { doc, filename } = await buildRoadmapPdf();

        // Primary path (XACA-0636): stash the PDF on the server and download it from
        // /api/roadmap-pdf/<token>, which streams it with a Content-Disposition
        // filename. This is the ONLY thing the iTerm2 WKWebView cockpit honors for
        // the saved name — it ignores <a download> and document.title (it names blob
        // downloads "<random>-Unknown.pdf"). Mirrors the working Team Export download.
        let served = false;
        try {
            const dataUri = doc.output('datauristring');  // "data:application/pdf;base64,…"
            const resp = await apiFetch(apiUrl('/api/roadmap-pdf'), {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ pdf: dataUri, filename })
            });
            if (resp.ok) {
                const { token } = await resp.json();
                if (token) {
                    const a = document.createElement('a');
                    a.href = apiUrl('/api/roadmap-pdf/' + token);
                    a.download = '';  // let the server's Content-Disposition set the name
                    document.body.appendChild(a);
                    a.click();
                    a.remove();
                    served = true;
                }
            }
        } catch (stashErr) {
            served = false;  // fall through to client-side blob fallback
        }

        // Fallback (server unreachable): client-side blob. <a download> works in real
        // browsers; the new-tab open is the last resort for WebViews.
        if (!served) {
            const url = URL.createObjectURL(doc.output('blob'));
            let downloaded = false;
            try {
                const a = document.createElement('a');
                if ('download' in a) {
                    a.href = url; a.download = filename; a.rel = 'noopener';
                    document.body.appendChild(a); a.click(); a.remove();
                    downloaded = true;
                }
            } catch (dlErr) { downloaded = false; }
            if (!downloaded) {
                const w = window.open(url, '_blank');
                if (!w && typeof showToast === 'function') {
                    showToast('PDF generated but the browser blocked the download/open. Try a real browser tab.', 'error');
                }
            }
            setTimeout(() => URL.revokeObjectURL(url), 20000);
        }
    } catch (e) {
        // showToast renders via textContent (XACA-0217), so do NOT escapeHtml
        // here — that would display literal &lt; entities. Pass the raw message.
        const msg = (e && e.message) ? e.message : 'unknown error';
        if (typeof showToast === 'function') {
            showToast('PDF export failed: ' + msg, 'error');
        } else {
            console.error('Roadmap PDF export failed', e);
        }
    } finally {
        if (btn) {
            btn.removeAttribute('disabled');
            if (prevText !== null) btn.textContent = prevText;
        }
    }
}

// Renders the /api/roadmap response into #roadmap-content.
// CSS class contract (all styling belongs to XACA-0625-005):
//
//   .roadmap-loading          — shown while fetch is in flight
//   .roadmap-error            — shown when fetch fails
//   .roadmap-empty            — shown when no epics, releases, or unscheduled items
//   .roadmap-timeline         — outer wrapper for the dated-axis + lanes block
//   .roadmap-axis             — date ruler row at the top of the timeline
//   .roadmap-axis-label       — individual tick label inside the axis
//   .roadmap-lanes            — scrollable container holding all lane rows
//   .roadmap-lane             — one horizontal lane row (epics | releases)
//   .roadmap-lane-label       — the left-gutter label for a lane
//   .roadmap-lane-track       — the right portion of the lane where bars are placed
//   .roadmap-bar              — a ranged epic/release bar (has start != end)
//   .roadmap-milestone        — a point-event marker (start == end)
//   .roadmap-item-label       — the text label inside a bar or beside a milestone
//   .roadmap-item-sublabel    — secondary info inside a bar (priority, itemCounts)
//   .roadmap-unscheduled      — wrapper for the unscheduled lane below the timeline
//   .roadmap-unscheduled-heading — section header text
//   .roadmap-unscheduled-group — per-kind subsection (data-kind="epics"|"releases")
//   .roadmap-unscheduled-subheading — "Epics"/"Releases" label for a group
//   .roadmap-unscheduled-status — per-state sub-row (data-state="planned"|"active"|"archived")
//   .roadmap-unscheduled-status-label — "Planned"/"Active"/"Archived" label for a sub-row
//   .roadmap-unscheduled-list — flex container of chips
//   .roadmap-chip             — individual unscheduled item chip
//   .roadmap-chip-label       — chip title text
//   .roadmap-chip-meta        — chip secondary info (status, priority, itemCounts)
//
// Data-attributes for CSS color hooks:
//   [data-color]              — epic color string, e.g. data-color="blue"
//   [data-type]               — release type string, e.g. data-type="feature"
//   [data-status]             — item status, e.g. data-status="active"
//   [data-priority]           — epic priority, e.g. data-priority="high"
//   [data-kind]               — "epic" or "release" on bar/milestone/chip elements
// =============================================================================

/**
 * Render the roadmap section. Called by switchSection('roadmap').
 * Fetches /api/roadmap and renders a timeline with three conceptual lanes:
 *   - Epics lane (scheduled epics as bars or milestone markers)
 *   - Releases lane (scheduled releases as milestone markers)
 *   - Unscheduled lane (chips for epics + releases with no dates)
 */
async function renderRoadmap() {
    const container = document.getElementById('roadmap-content');
    if (!container) return;

    // Show loading state immediately
    container.innerHTML = '<div class="roadmap-loading">Loading roadmap...</div>';

    let data;
    try {
        const response = await fetch(apiUrl('/api/roadmap'));
        if (!response.ok) {
            const errText = await response.text();
            throw new Error(`Server returned ${response.status}: ${errText || response.statusText}`);
        }
        data = await response.json();
    } catch (e) {
        console.error('[roadmap] Could not load roadmap:', e);
        container.innerHTML = `
            <div class="roadmap-error">
                <div class="roadmap-error-icon">&#9888;</div>
                <div class="roadmap-error-text">Error loading roadmap</div>
                <div class="roadmap-error-hint">${escapeHtml(e.message)}</div>
            </div>
        `;
        return;
    }

    const scheduledEpics    = data.epics    || [];
    const scheduledReleases = data.releases || [];
    const unschEpics        = (data.unscheduled && data.unscheduled.epics)    || [];
    const unschReleases     = (data.unscheduled && data.unscheduled.releases) || [];
    const dateRange         = data.dateRange || null;

    const hasScheduled   = dateRange && (scheduledEpics.length > 0 || scheduledReleases.length > 0);
    const hasUnscheduled = unschEpics.length > 0 || unschReleases.length > 0;

    // Fully empty state
    if (!hasScheduled && !hasUnscheduled) {
        container.innerHTML = `
            <div class="roadmap-empty">
                <div class="roadmap-empty-icon">&#x1F5FA;</div>
                <div class="roadmap-empty-text">No roadmap data yet</div>
                <div class="roadmap-empty-hint">Add due dates to epic items or target dates to releases to populate the timeline.</div>
            </div>
        `;
        return;
    }

    // Build HTML into a buffer
    const parts = [];

    // -----------------------------------------------------------------------
    // Timeline block (only when dateRange is non-null)
    // -----------------------------------------------------------------------
    if (hasScheduled) {
        const rangeStart = new Date(dateRange.start + 'T00:00:00Z');
        const rangeEnd   = new Date(dateRange.end   + 'T00:00:00Z');
        const rangeSpanMs = rangeEnd.getTime() - rangeStart.getTime();

        // Edge gutter (XACA-0641): markers/labels are centered on their date via
        // translateX(-50%), so an item at 0% or 100% has half its width outside the
        // lane-track and is clipped by its overflow:hidden. Rather than rely solely
        // on the post-layout px-nudge in stackRoadmapLanes() (which needs a settled
        // layout to measure and silently no-ops when the track isn't laid out yet),
        // project the time domain [0,100]% into [GUTTER, 100-GUTTER]% so every edge
        // item carries a built-in safe margin. The axis ticks share this projection
        // (projectPct), so a marker and its month tick stay aligned. The runtime
        // nudge remains as a residual correction for unusually wide labels on narrow
        // viewports. Deterministic + measurement-free = html2canvas-safe.
        const EDGE_GUTTER_PCT = 4;
        const DOMAIN_SCALE = (100 - 2 * EDGE_GUTTER_PCT) / 100;
        const projectPct = (pct) => EDGE_GUTTER_PCT + pct * DOMAIN_SCALE;

        /**
         * Convert a YYYY-MM-DD date string to a left-offset percentage within
         * the range. Raw position is clamped to [0, 100] to keep out-of-range
         * events visible, then projected into the gutter-inset domain.
         */
        function dateToPct(dateStr) {
            const d = new Date(dateStr + 'T00:00:00Z');
            if (rangeSpanMs === 0) return projectPct(0);
            const pct = (d.getTime() - rangeStart.getTime()) / rangeSpanMs * 100;
            return projectPct(Math.max(0, Math.min(100, pct)));
        }

        /**
         * Width percentage for a bar from startStr to endStr.
         * Point events (start == end) get a minimum 0.5% so they remain
         * clickable; the render layer should switch to .roadmap-milestone class
         * for visual distinction. Width is scaled by DOMAIN_SCALE so a bar's
         * right edge lands at projectPct(end) — consistent with dateToPct.
         */
        function dateRangeWidthPct(startStr, endStr) {
            const s = new Date(startStr + 'T00:00:00Z');
            const e = new Date(endStr   + 'T00:00:00Z');
            if (rangeSpanMs === 0) return 0;
            const w = (e.getTime() - s.getTime()) / rangeSpanMs * 100;
            // Clamp to [0, 100]: the contract guarantees end <= dateRange.end so
            // this is defensive, but it keeps a bar from ever overflowing the track.
            return Math.max(0, Math.min(100, w)) * DOMAIN_SCALE;
        }

        // Build month-boundary tick labels for the date axis
        function buildAxisTicks() {
            const ticks = [];
            const cursor = new Date(rangeStart);
            // Advance to the first day of the next month
            cursor.setUTCDate(1);
            cursor.setUTCMonth(cursor.getUTCMonth() + 1);

            const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
            while (cursor.getTime() <= rangeEnd.getTime()) {
                // Share the gutter-inset projection (XACA-0641) so each month tick
                // stays aligned with the markers dated within that month.
                const pct = projectPct((cursor.getTime() - rangeStart.getTime()) / rangeSpanMs * 100);
                const label = MONTHS[cursor.getUTCMonth()] + ' ' + cursor.getUTCFullYear();
                ticks.push({ pct, label });
                cursor.setUTCMonth(cursor.getUTCMonth() + 1);
            }
            // Edge-aware anchoring so the first/last month labels are never clipped
            // by the axis's overflow:hidden. Labels are absolutely positioned at
            // their tick pct; centering (translateX(-50%)) pushes an edge label half
            // its width outside the axis. So: anchor the leftmost label's LEFT edge to
            // the tick (align 'start') and the rightmost label's RIGHT edge to the tick
            // (align 'end'); everything in between stays centered.
            for (let i = 0; i < ticks.length; i++) {
                if (ticks[i].pct <= 6)        ticks[i].align = 'start';
                else if (ticks[i].pct >= 94)  ticks[i].align = 'end';
                else                          ticks[i].align = 'center';
            }
            return ticks;
        }

        const ticks = buildAxisTicks();

        // Map an anchor mode to the transform that keeps the label inside the axis.
        const axisAlignTransform = {
            start:  'translate(0, -50%)',
            center: 'translate(-50%, -50%)',
            end:    'translate(-100%, -50%)',
        };

        parts.push('<div class="roadmap-timeline">');

        // Date axis
        parts.push('<div class="roadmap-axis">');
        for (const tick of ticks) {
            const tf = axisAlignTransform[tick.align] || axisAlignTransform.center;
            parts.push(
                `<span class="roadmap-axis-label" data-align="${tick.align}"` +
                ` style="left:${tick.pct.toFixed(2)}%;transform:${tf}">${escapeHtml(tick.label)}</span>`
            );
        }
        parts.push('</div>'); // .roadmap-axis

        parts.push('<div class="roadmap-lanes">');

        // -- Epics lane --
        if (scheduledEpics.length > 0) {
            parts.push('<div class="roadmap-lane" data-kind="epics">');
            parts.push('<div class="roadmap-lane-label">Epics</div>');
            parts.push('<div class="roadmap-lane-track">');

            for (const epic of scheduledEpics) {
                const isPoint = epic.start === epic.end;
                const leftPct  = dateToPct(epic.start);
                const widthPct = isPoint ? 0 : dateRangeWidthPct(epic.start, epic.end);

                const label     = epic.shortTitle || epic.title || epic.id;
                const fullTitle = epic.title || epic.id;
                const priority  = epic.priority || '';
                const status    = epic.status || '';
                const color     = epic.color || '';
                const counts    = epic.itemCounts || {};

                // Phase 2 scheduling fields (XACA-0627-003)
                const scheduleSource = epic.scheduleSource || '';   // "explicit" | "derived" | "rollup" | "activity"
                const timeEstimate   = epic.timeEstimate   || '';   // e.g. "40h", "3w" or ""
                const startDate      = epic.startDate      || '';
                const targetDate     = epic.targetDate     || '';

                // Build a tooltip string with key info
                const inProgress = counts.inProgress || 0;
                const completed  = counts.completed  || 0;
                const total      = counts.total      || 0;
                const tooltipText = [
                    fullTitle,
                    epic.start + ' → ' + epic.end,
                    scheduleSource ? 'Schedule: ' + scheduleSource : '',
                    (startDate || targetDate) ? (startDate || epic.start) + ' → ' + (targetDate || epic.end) : '',
                    timeEstimate ? 'Estimate: ' + timeEstimate : '',
                    priority ? 'Priority: ' + priority : '',
                    total ? (completed + '/' + total + ' done') : '',
                    epic.description || '',
                ].filter(Boolean).join(' | ');

                // Schedule-source badge HTML — short pill label per source type.
                // "rollup" is intentionally subdued (dimmer); "explicit" and "derived"
                // are visually distinct to signal intent vs. inference.
                // "activity" is muted green — actual/historical span (real work timestamps).
                let scheduleBadgeHtml = '';
                if (scheduleSource) {
                    const badgeLabel = scheduleSource === 'explicit' ? 'EXPLICIT'
                                     : scheduleSource === 'derived'  ? 'EST'
                                     : scheduleSource === 'rollup'   ? 'ROLLUP'
                                     : scheduleSource === 'activity' ? 'ACTUAL'
                                     : escapeHtml(scheduleSource.toUpperCase());
                    scheduleBadgeHtml =
                        `<span class="roadmap-schedule-badge roadmap-schedule-badge--${escapeHtml(scheduleSource)}"` +
                        ` title="${escapeHtml('Schedule source: ' + scheduleSource)}">${badgeLabel}</span>`;
                }

                // Estimate label HTML — shown when timeEstimate is present.
                let estimateLabelHtml = '';
                if (timeEstimate) {
                    const estimateTooltip = [
                        timeEstimate,
                        startDate  ? 'Start: '  + startDate  : '',
                        targetDate ? 'Target: ' + targetDate : '',
                    ].filter(Boolean).join(' | ');
                    estimateLabelHtml =
                        `<span class="roadmap-estimate-label"` +
                        ` title="${escapeHtml(estimateTooltip)}">~${escapeHtml(timeEstimate)}</span>`;
                }

                if (isPoint) {
                    parts.push(
                        `<div class="roadmap-milestone"` +
                        ` data-kind="epic"` +
                        ` data-color="${escapeHtml(color)}"` +
                        ` data-status="${escapeHtml(status)}"` +
                        ` data-priority="${escapeHtml(priority)}"` +
                        (scheduleSource ? ` data-schedule-source="${escapeHtml(scheduleSource)}"` : '') +
                        ` style="left:${leftPct.toFixed(2)}%"` +
                        ` title="${escapeHtml(tooltipText)}">` +
                        `<span class="roadmap-item-label">${escapeHtml(label)}</span>` +
                        scheduleBadgeHtml +
                        estimateLabelHtml +
                        `</div>`
                    );
                } else {
                    parts.push(
                        `<div class="roadmap-bar"` +
                        ` data-kind="epic"` +
                        ` data-color="${escapeHtml(color)}"` +
                        ` data-status="${escapeHtml(status)}"` +
                        ` data-priority="${escapeHtml(priority)}"` +
                        (scheduleSource ? ` data-schedule-source="${escapeHtml(scheduleSource)}"` : '') +
                        ` style="left:${leftPct.toFixed(2)}%;width:${widthPct.toFixed(2)}%"` +
                        ` title="${escapeHtml(tooltipText)}">` +
                        `<span class="roadmap-item-label">${escapeHtml(label)}</span>` +
                        (priority ? `<span class="roadmap-item-sublabel">${escapeHtml(priority)}` +
                            (total ? ` &bull; ${escapeHtml(String(completed))}/${escapeHtml(String(total))}` : '') +
                            `</span>` : '') +
                        scheduleBadgeHtml +
                        estimateLabelHtml +
                        `</div>`
                    );
                }
            }

            parts.push('</div>'); // .roadmap-lane-track
            parts.push('</div>'); // .roadmap-lane[epics]
        }

        // -- Releases lane --
        if (scheduledReleases.length > 0) {
            parts.push('<div class="roadmap-lane" data-kind="releases">');
            parts.push('<div class="roadmap-lane-label">Releases</div>');
            parts.push('<div class="roadmap-lane-track">');

            for (const rel of scheduledReleases) {
                // Non-archived releases are point events (start == end == targetDate);
                // archived releases (XACA-0639) carry a derived start..end span and
                // render as a ranged bar so their historical extent is visible.
                const isPoint  = rel.start === rel.end;
                const leftPct  = dateToPct(rel.start);
                const widthPct = isPoint ? 0 : dateRangeWidthPct(rel.start, rel.end);
                const label    = rel.shortTitle || rel.name || rel.id;
                const fullName = rel.name || rel.id;
                const relType  = rel.type || '';
                const status   = rel.status || '';

                // XACA-0639: archived releases may carry scheduleSource='activity'
                // (set by server when the span is derived from real item timestamps).
                // Render the same schedule-source badge pill as the epic lane does.
                const scheduleSource = rel.scheduleSource || '';
                let scheduleBadgeHtml = '';
                if (scheduleSource) {
                    const badgeLabel = scheduleSource === 'explicit' ? 'EXPLICIT'
                                     : scheduleSource === 'derived'  ? 'EST'
                                     : scheduleSource === 'rollup'   ? 'ROLLUP'
                                     : scheduleSource === 'activity' ? 'ACTUAL'
                                     : escapeHtml(scheduleSource.toUpperCase());
                    scheduleBadgeHtml =
                        `<span class="roadmap-schedule-badge roadmap-schedule-badge--${escapeHtml(scheduleSource)}"` +
                        ` title="${escapeHtml('Schedule source: ' + scheduleSource)}">${badgeLabel}</span>`;
                }

                const tooltipText = [
                    fullName,
                    isPoint ? (rel.targetDate || rel.start) : (rel.start + ' → ' + rel.end),
                    scheduleSource ? 'Schedule: ' + scheduleSource : '',
                    relType ? 'Type: ' + relType : '',
                    status ? 'Status: ' + status : '',
                ].filter(Boolean).join(' | ');

                if (isPoint) {
                    parts.push(
                        `<div class="roadmap-milestone"` +
                        ` data-kind="release"` +
                        ` data-type="${escapeHtml(relType)}"` +
                        ` data-status="${escapeHtml(status)}"` +
                        (scheduleSource ? ` data-schedule-source="${escapeHtml(scheduleSource)}"` : '') +
                        ` style="left:${leftPct.toFixed(2)}%"` +
                        ` title="${escapeHtml(tooltipText)}">` +
                        `<span class="roadmap-item-label">${escapeHtml(label)}</span>` +
                        scheduleBadgeHtml +
                        `</div>`
                    );
                } else {
                    parts.push(
                        `<div class="roadmap-bar"` +
                        ` data-kind="release"` +
                        ` data-type="${escapeHtml(relType)}"` +
                        ` data-status="${escapeHtml(status)}"` +
                        (scheduleSource ? ` data-schedule-source="${escapeHtml(scheduleSource)}"` : '') +
                        ` style="left:${leftPct.toFixed(2)}%;width:${widthPct.toFixed(2)}%"` +
                        ` title="${escapeHtml(tooltipText)}">` +
                        `<span class="roadmap-item-label">${escapeHtml(label)}</span>` +
                        scheduleBadgeHtml +
                        `</div>`
                    );
                }
            }

            parts.push('</div>'); // .roadmap-lane-track
            parts.push('</div>'); // .roadmap-lane[releases]
        }

        parts.push('</div>'); // .roadmap-lanes
        parts.push('</div>'); // .roadmap-timeline
    }

    // -----------------------------------------------------------------------
    // Unscheduled lane (chip list; rendered whether or not timeline exists)
    // -----------------------------------------------------------------------
    if (hasUnscheduled) {
        parts.push('<div class="roadmap-unscheduled">');
        parts.push('<div class="roadmap-unscheduled-heading">Unscheduled</div>');

        // Epics and Releases are kept in separately-labeled kind groups (chip
        // color encodes the epic color / release type, NOT the kind, so an epic
        // and a release can otherwise look identical). Within each kind group the
        // chips are further split by canonical state — Planned / Active / Archived
        // (epic state per STATE_CONTRACT §1.5; release state per the Releases-tab
        // split, XACA-0238). The server provides `item.state` as one of
        // 'PLANNED' | 'ACTIVE' | 'ARCHIVED'. (XACA-0635)
        const STATE_ORDER = [
            { key: 'PLANNED',  label: 'Planned'  },
            { key: 'ACTIVE',   label: 'Active'   },
            { key: 'ARCHIVED', label: 'Archived' },
        ];

        // Normalize to a known bucket; unknown/missing falls back to ACTIVE so a
        // chip is never silently dropped from the lane.
        const stateKey = (it) => {
            const s = (it.state || '').toUpperCase();
            return (s === 'PLANNED' || s === 'ACTIVE' || s === 'ARCHIVED') ? s : 'ACTIVE';
        };

        const releaseChipHtml = (rel) => {
            const label   = rel.shortTitle || rel.name || rel.id;
            const relType = rel.type || '';
            const status  = rel.status || '';
            return (
                `<div class="roadmap-chip"` +
                ` data-kind="release"` +
                ` data-type="${escapeHtml(relType)}"` +
                ` data-status="${escapeHtml(status)}"` +
                ` title="${escapeHtml(rel.name || rel.id)}">` +
                `<span class="roadmap-chip-label">${escapeHtml(label)}</span>` +
                (relType || status ? `<span class="roadmap-chip-meta">${escapeHtml(relType)}` +
                    (status ? ` &bull; ${escapeHtml(status)}` : '') +
                    `</span>` : '') +
                `</div>`
            );
        };

        const epicChipHtml = (epic) => {
            const label    = epic.shortTitle || epic.title || epic.id;
            const color    = epic.color || '';
            const priority = epic.priority || '';
            const status   = epic.status || '';
            const counts   = epic.itemCounts || {};
            const total    = counts.total || 0;
            const completed = counts.completed || 0;
            return (
                `<div class="roadmap-chip"` +
                ` data-kind="epic"` +
                ` data-color="${escapeHtml(color)}"` +
                ` data-status="${escapeHtml(status)}"` +
                ` data-priority="${escapeHtml(priority)}"` +
                ` title="${escapeHtml(epic.title || epic.id)}">` +
                `<span class="roadmap-chip-label">${escapeHtml(label)}</span>` +
                (priority || total ? `<span class="roadmap-chip-meta">${escapeHtml(priority)}` +
                    (total ? ` &bull; ${escapeHtml(String(completed))}/${escapeHtml(String(total))}` : '') +
                    `</span>` : '') +
                `</div>`
            );
        };

        // Natural (numeric-aware) compare so version-named items order correctly —
        // e.g. V2.9.0 < V2.10.0 (a plain string sort would put "10" before "9").
        const naturalCompare = (a, b) =>
            String(a).localeCompare(String(b), undefined, { numeric: true, sensitivity: 'base' });

        // Render one kind group (Releases or Epics) with up to three state sub-rows.
        // When sortKey is supplied, the chips within each state bucket are sorted by
        // natural compare on that key (XACA-0636).
        const renderKindGroup = (kind, kindLabel, items, chipHtml, sortKey) => {
            if (items.length === 0) return;
            parts.push(`<div class="roadmap-unscheduled-group" data-kind="${kind}">`);
            parts.push(`<div class="roadmap-unscheduled-subheading">${kindLabel}</div>`);
            for (const st of STATE_ORDER) {
                let bucket = items.filter(it => stateKey(it) === st.key);
                if (bucket.length === 0) continue;  // empty status buckets are not rendered
                if (sortKey) {
                    bucket = bucket.slice().sort((a, b) => naturalCompare(sortKey(a), sortKey(b)));
                }
                parts.push(`<div class="roadmap-unscheduled-status" data-state="${st.key.toLowerCase()}">`);
                parts.push(`<div class="roadmap-unscheduled-status-label">${st.label}</div>`);
                parts.push('<div class="roadmap-unscheduled-list">');
                for (const it of bucket) parts.push(chipHtml(it));
                parts.push('</div>'); // .roadmap-unscheduled-list
                parts.push('</div>'); // .roadmap-unscheduled-status
            }
            parts.push('</div>'); // .roadmap-unscheduled-group
        };

        // Releases first, then Epics (kind order set in XACA-0634). Releases are
        // sorted within each bucket by their display label so semantic versions
        // (V1.0.0, V2.10.0, V3.0.0…) order correctly.
        renderKindGroup('releases', 'Releases', unschReleases, releaseChipHtml,
            r => r.shortTitle || r.name || r.id);
        renderKindGroup('epics', 'Epics', unschEpics, epicChipHtml);

        parts.push('</div>'); // .roadmap-unscheduled
    }

    // -----------------------------------------------------------------------
    // Details & Reference section (XACA-0642, enriched XACA-0644, grouped XACA-0645)
    // Epics group: ALL epics (description line omitted when blank). Each entry
    //   renders a meta line: ID · resolved start→target dates · X/Y progress.
    // Releases group: all releases, meta line with REL-id; detail text in body.
    // XACA-0645: within each group, entries are bucketed by lifecycle state
    //   (Active → Upcoming → Archived) via the server-derived `state` enum
    //   (ACTIVE | PLANNED | ARCHIVED), with a sub-section separator per non-empty
    //   bucket. Active/Upcoming sort by date ascending (soonest first); Archived
    //   descending (most recently finished first); date-less entries sort last.
    // Dedup note: scheduled vs unscheduled lists never contain the same item twice,
    // so [...scheduled, ...unscheduled] concat is safe.
    // -----------------------------------------------------------------------
    {
        const allEpics    = [...scheduledEpics, ...unschEpics];
        const allReleases = [...scheduledReleases, ...unschReleases];

        const hasEpicsGroup    = allEpics.length > 0;    // XACA-0644: show ALL epics
        const hasReleasesGroup = allReleases.length > 0;

        // --- XACA-0645 lifecycle bucketing helpers ---
        // Ordered buckets: label = on-screen separator text, token = data-attr value.
        const STATE_BUCKETS = [
            { key: 'ACTIVE',   label: 'Active',   token: 'active'   },
            { key: 'PLANNED',  label: 'Upcoming', token: 'upcoming' },
            { key: 'ARCHIVED', label: 'Archived', token: 'archived' },
        ];
        // Normalize an entry's server-derived state to a known bucket; unknown/blank
        // falls to PLANNED (Upcoming) so no entry is ever silently dropped.
        const bucketKey = (item) => {
            const s = String(item.state || '').trim().toUpperCase();
            return (s === 'ACTIVE' || s === 'ARCHIVED') ? s : 'PLANNED';
        };
        // Sortable date key (YYYY-MM-DD strings compare lexically). First present of:
        // epics → targetDate|end|startDate|start; releases also fall back to createdAt.
        const dateKey = (item) => {
            const cands = [item.targetDate, item.end, item.startDate, item.start, item.createdAt];
            for (const c of cands) {
                if (c && String(c).trim()) return String(c).trim();
            }
            return '';
        };
        // Comparator: ascending for active/upcoming, descending for archived.
        // Date-less entries ('') always sort last regardless of direction.
        const byDate = (descending) => (a, b) => {
            const da = dateKey(a), db = dateKey(b);
            if (!da && !db) return 0;
            if (!da) return 1;
            if (!db) return -1;
            if (da === db) return 0;
            return descending ? (da < db ? 1 : -1) : (da < db ? -1 : 1);
        };

        // Per-entry HTML builder for an epic (one .roadmap-details-entry div).
        const epicEntryHtml = (epic) => {
            const color  = escapeHtml(epic.color  || '');
            const status = escapeHtml(epic.status || '');
            const out = [];
            out.push(
                `<div class="roadmap-details-entry" data-kind="epic"` +
                ` data-color="${color}"` +
                ` data-status="${status}">`
            );
            out.push(`<div class="roadmap-details-entry-title">${escapeHtml(epic.shortTitle || epic.title || epic.id)}</div>`);

            // Meta line: ID · resolved dates · progress (XACA-0644)
            // Date resolution mirrors the bar-tooltip logic (~line 20330):
            //   startResolved  = explicit startDate (if set) else rollup start
            //   targetResolved = explicit targetDate (if set) else rollup end
            const metaParts = [];
            metaParts.push(escapeHtml(epic.id || ''));
            const startResolved  = (epic.startDate  && epic.startDate.trim())  ? epic.startDate.trim()  : (epic.start  || '');
            const targetResolved = (epic.targetDate && epic.targetDate.trim()) ? epic.targetDate.trim() : (epic.end    || '');
            if (startResolved || targetResolved) {
                if (startResolved && targetResolved && startResolved === targetResolved) {
                    metaParts.push(escapeHtml(startResolved));
                } else if (startResolved && targetResolved) {
                    metaParts.push(escapeHtml(startResolved) + ' → ' + escapeHtml(targetResolved));
                } else {
                    metaParts.push(escapeHtml(startResolved || targetResolved));
                }
            }
            const c = epic.itemCounts || {};
            if (c.total) {
                metaParts.push(escapeHtml(String(c.completed || 0)) + '/' + escapeHtml(String(c.total)));
            }
            out.push(`<div class="roadmap-details-entry-meta">${metaParts.filter(Boolean).join(' · ')}</div>`);

            // Description body: only when non-empty
            if (epic.description && epic.description.trim()) {
                out.push(`<div class="roadmap-details-entry-body">${escapeHtml(epic.description.trim())}</div>`);
            }
            out.push('</div>'); // .roadmap-details-entry
            return out.join('\n');
        };

        // Per-entry HTML builder for a release (one .roadmap-details-entry div).
        const releaseEntryHtml = (rel) => {
            const relType   = escapeHtml(rel.type   || '');
            const relStatus = escapeHtml(rel.status || '');
            const out = [];

            // Derive detail text: type (capitalized) · status · date.
            // (Lifecycle state is now the sub-section header, so it is no longer
            //  repeated inline here — XACA-0645.)
            const detailParts = [];
            if (rel.type && rel.type.trim()) {
                const t = rel.type.trim();
                detailParts.push(t.charAt(0).toUpperCase() + t.slice(1));
            }
            if (rel.status && rel.status.trim()) detailParts.push(rel.status.trim());
            // Date: prefer targetDate; fall back to start→end range
            if (rel.targetDate && rel.targetDate.trim()) {
                detailParts.push(rel.targetDate.trim());
            } else if (rel.start && rel.end) {
                const relStart = rel.start.trim();
                const relEnd   = rel.end.trim();
                if (relStart === relEnd) {
                    detailParts.push(relStart);
                } else {
                    detailParts.push(`${relStart} – ${relEnd}`);
                }
            }
            const detailText = detailParts.length > 0
                ? detailParts.join(' · ')
                : '(no detail)';

            out.push(
                `<div class="roadmap-details-entry" data-kind="release"` +
                ` data-type="${relType}"` +
                ` data-status="${relStatus}">`
            );
            out.push(`<div class="roadmap-details-entry-title">${escapeHtml(rel.shortTitle || rel.name || rel.id)}</div>`);
            // REL-id on meta line, consistent with epic treatment (XACA-0644).
            // Omit the line entirely when no id (no empty meta div / stray gap).
            if (rel.id && String(rel.id).trim()) {
                out.push(`<div class="roadmap-details-entry-meta">${escapeHtml(String(rel.id).trim())}</div>`);
            }
            out.push(`<div class="roadmap-details-entry-body">${escapeHtml(detailText)}</div>`);
            out.push('</div>'); // .roadmap-details-entry
            return out.join('\n');
        };

        // Render one group (epics or releases) bucketed by lifecycle state, with a
        // sub-section separator per NON-empty bucket in Active→Upcoming→Archived
        // order; entries within a bucket sorted by date (XACA-0645).
        const renderStateGroups = (items, entryHtml) => {
            const buckets = { ACTIVE: [], PLANNED: [], ARCHIVED: [] };
            for (const it of items) buckets[bucketKey(it)].push(it);
            for (const b of STATE_BUCKETS) {
                const list = buckets[b.key];
                if (!list.length) continue;   // skip empty buckets — no orphan separator
                list.sort(byDate(b.key === 'ARCHIVED'));
                parts.push(`<div class="roadmap-details-substate" data-state="${b.token}">${b.label}</div>`);
                for (const it of list) parts.push(entryHtml(it));
            }
        };

        if (hasEpicsGroup || hasReleasesGroup) {
            parts.push('<div class="roadmap-details">');
            parts.push('<div class="roadmap-details-heading">Details &amp; Reference</div>');

            // --- Epics group (XACA-0644 meta line, XACA-0645 lifecycle buckets) ---
            if (hasEpicsGroup) {
                parts.push('<div class="roadmap-details-group" data-kind="epics">');
                parts.push('<div class="roadmap-details-subheading">Epics</div>');
                renderStateGroups(allEpics, epicEntryHtml);
                parts.push('</div>'); // .roadmap-details-group[data-kind="epics"]
            }

            // --- Releases group (XACA-0644 REL-id, XACA-0645 lifecycle buckets) ---
            if (hasReleasesGroup) {
                parts.push('<div class="roadmap-details-group" data-kind="releases">');
                parts.push('<div class="roadmap-details-subheading">Releases</div>');
                renderStateGroups(allReleases, releaseEntryHtml);
                parts.push('</div>'); // .roadmap-details-group[data-kind="releases"]
            }

            parts.push('</div>'); // .roadmap-details
        }
    }

    container.innerHTML = parts.join('\n');

    // Reflow scheduled-lane items into non-overlapping rows (XACA-0636). Bars/
    // milestones are absolutely positioned by time, so items overlapping in time
    // would stack on top of each other; stackRoadmapLanes() packs them into rows
    // and grows the lane. Scheduled robustly because a single rAF can fire before
    // the fresh nodes are laid out, and webfont load changes label widths.
    scheduleRoadmapStack(container);
}

/**
 * Robustly (re)run the lane stacker: after layout settles (double rAF) and again
 * once webfonts load (label widths shift when 'Antonio' arrives), plus on viewport
 * resize. Idempotent — stackRoadmapLanes resets prior inline layout first. (XACA-0636)
 */
function scheduleRoadmapStack(container) {
    if (!container) return;
    const run = () => { try { stackRoadmapLanes(container); } catch (e) { /* layout race */ } };
    requestAnimationFrame(() => requestAnimationFrame(run));
    if (document.fonts && document.fonts.ready && typeof document.fonts.ready.then === 'function') {
        document.fonts.ready.then(run).catch(() => {});
    }
    if (!window.__roadmapStackResizeBound) {
        window.__roadmapStackResizeBound = true;
        let t = null;
        window.addEventListener('resize', () => {
            clearTimeout(t);
            t = setTimeout(() => {
                const c = document.getElementById('roadmap-content');
                if (c) { try { stackRoadmapLanes(c); } catch (e) {} }
            }, 150);
        });
    }
}

/**
 * Pack each scheduled lane's bars/milestones into non-overlapping horizontal rows,
 * growing the lane so nothing overlaps. Measures real pixel geometry after layout.
 * IDEMPOTENT: clears any prior inline layout first, so it can run repeatedly (font
 * load, resize). Defensive: if a track has no measurable width (hidden/not laid
 * out) it leaves that lane untouched.
 *
 * Positioning is html2canvas-safe: stacked items are placed by an explicit pixel
 * `top` with NO vertical transform (a translateY(-50%) center is mis-rendered by
 * html2canvas and clips bar labels in the PDF export). (XACA-0636)
 */
function stackRoadmapLanes(root) {
    if (!root) return;
    const ROW_GAP = 8;   // vertical gap between stacked rows (px)
    const COL_GAP = 10;  // min horizontal gap between two items in the same row (px)
    const PAD = 6;       // top/bottom padding inside a lane track (px)

    root.querySelectorAll('.roadmap-lane-track').forEach(track => {
        const items = Array.from(track.children).filter(c =>
            c.classList.contains('roadmap-bar') || c.classList.contains('roadmap-milestone'));
        if (items.length === 0) return;

        // --- Reset any prior stacking so this run measures the natural layout ---
        track.style.minHeight = '';
        const lane = track.closest('.roadmap-lane');
        if (lane) lane.style.minHeight = '';
        // External bar labels (XACA-0641) from a prior run are removed wholesale —
        // they are re-created below only for bars that still need them this run.
        track.querySelectorAll('.roadmap-bar-extlabel').forEach(n => n.remove());
        for (const el of items) {
            // Stash the original left (the % set at render) once, so edge nudges
            // below are reapplied from scratch each run rather than accumulating.
            if (el.dataset.roadmapLeft0 === undefined) el.dataset.roadmapLeft0 = el.style.left || '';
            el.style.left = el.dataset.roadmapLeft0;
            el.style.top = '';
            el.style.transform = '';
            el.classList.remove('roadmap-stacked');
            const sub = el.querySelector('.roadmap-item-sublabel');
            if (sub) sub.style.display = '';
            // Restore the schedule badge AND the in-bar title — the narrow-bar fit
            // below may hide either, and this run must start from natural layout.
            const bdg = el.querySelector('.roadmap-schedule-badge');
            if (bdg) bdg.style.display = '';
            const ttl = el.querySelector('.roadmap-item-label');
            if (ttl) ttl.style.visibility = '';
        }

        const trackRect = track.getBoundingClientRect();
        if (trackRect.width <= 0) {
            // Not laid out yet (e.g. measured before the roadmap section became
            // visible). Silently giving up here left the edge nudges and narrow-bar
            // trims unapplied — a prime suspect for edge clipping persisting
            // on-screen (XACA-0641). Retry on the next frame, bounded so a genuinely
            // zero-width track can't spin forever.
            const tries = (track.__roadmapStackTries || 0) + 1;
            track.__roadmapStackTries = tries;
            if (tries <= 30) requestAnimationFrame(() => { try { stackRoadmapLanes(root); } catch (e) {} });
            return;
        }
        track.__roadmapStackTries = 0;

        // Measure each item's horizontal footprint relative to the track.
        const measured = items.map(el => {
            const r = el.getBoundingClientRect();
            return {
                el,
                left:  r.left  - trackRect.left,
                right: r.right - trackRect.left,
                height: r.height,
                isBar: el.classList.contains('roadmap-bar'),
            };
        }).sort((a, b) => a.left - b.left);

        // Greedy row packing: first row whose last item ends (with gap) before this
        // item's left edge; else open a new row.
        const rowRightEdge = [];
        let maxItemH = 0;
        for (const m of measured) {
            let row = 0;
            while (row < rowRightEdge.length && rowRightEdge[row] + COL_GAP > m.left) row++;
            rowRightEdge[row] = m.right;
            m.row = row;
            if (m.height > maxItemH) maxItemH = m.height;
        }

        const rowH   = maxItemH + ROW_GAP;
        const nRows  = rowRightEdge.length;
        const totalH = nRows * rowH - ROW_GAP + PAD * 2;

        track.style.minHeight = totalH + 'px';
        if (lane) lane.style.minHeight = totalH + 'px';

        for (const m of measured) {
            const rowTop = PAD + m.row * rowH;
            m.el.classList.add('roadmap-stacked');
            if (m.isBar) {
                // Center the (shorter) bar within the row band; explicit pixel top,
                // no transform (html2canvas-safe — see fn header).
                const barH = m.el.getBoundingClientRect().height || 26;
                m.el.style.top = (rowTop + (maxItemH - barH) / 2) + 'px';
                // Title-priority fit (XACA-0641). The title (.roadmap-item-label)
                // shares the bar with a sublabel + schedule badge that consume width
                // first. The old scroll-width truncation test proved unreliable (a
                // flex:1 item with min-width:auto never reports as shrunk), so trim
                // deterministically instead:
                //   - drop the sublabel from the bar face ALWAYS (least-important info,
                //     priority • counts; it stays in the tooltip),
                //   - drop the schedule badge on a narrow bar (reliable px width),
                //   - then, only if the title STILL can't fit the bar alone, render it
                //     OUTSIDE the bar (beside it) like a milestone label so it reads.
                const barW = m.right - m.left;
                const sub = m.el.querySelector('.roadmap-item-sublabel');
                if (sub) sub.style.display = 'none';
                if (barW < 96) {
                    const bdg = m.el.querySelector('.roadmap-schedule-badge');
                    if (bdg) bdg.style.display = 'none';
                }
                const title = m.el.querySelector('.roadmap-item-label');
                if (title) {
                    void m.el.offsetWidth;  // settle layout after the trims
                    if (title.scrollWidth > title.clientWidth + 1) {
                        // Bar too short for the title even alone → externalize it. Hide
                        // the clipped in-bar title; place a sibling label beside the bar,
                        // preferring the right, falling back left when the right would
                        // overflow the track's overflow:hidden edge.
                        const ext = document.createElement('span');
                        ext.className = 'roadmap-bar-extlabel';
                        ext.textContent = title.textContent;
                        track.appendChild(ext);
                        const er = ext.getBoundingClientRect();
                        const lw = er.width, lh = er.height || 14;
                        const rowCenterY = rowTop + maxItemH / 2;
                        let exLeft = m.right + 6;
                        if (exLeft + lw > trackRect.width - 2) {
                            const leftPlace = m.left - 6 - lw;
                            if (leftPlace >= 2) exLeft = leftPlace;
                        }
                        ext.style.left = exLeft + 'px';
                        ext.style.top = (rowCenterY - lh / 2) + 'px';
                        title.style.visibility = 'hidden';
                    }
                }
            } else {
                m.el.style.top = rowTop + 'px';
                // Center the milestone with an explicit pixel left instead of relying
                // on translateX(-50%): html2canvas mis-renders transforms, which shifted
                // markers off their x in the PDF only (overlapping the last two and
                // flipping their order). With .roadmap-stacked now carrying no transform,
                // left:% would put the box's LEFT edge on the date — so subtract half the
                // width to re-center. Rendered identically on-screen and in the PDF. The
                // gutter (projectPct) keeps the centered box clear of the track edges.
                const w = m.el.getBoundingClientRect().width;
                m.el.style.left = (m.el.offsetLeft - w / 2) + 'px';
            }
        }

        // NOTE (XACA-0641): the former edge-label *nudge* (shifting an edge milestone
        // horizontally so its centered label cleared the track's overflow:hidden) has
        // been removed. The gutter-inset time domain (projectPct → [4,96]%) already
        // guarantees that clearance declaratively, and the nudge actively caused a
        // regression: the rightmost milestone (at the range end) was shoved left into
        // its neighbour AFTER row-packing had run, so the last two markers (e.g.
        // v1.1.0 / v1.2.0) collided on the same row. Relying on the gutter keeps edge
        // labels readable without disturbing the packed layout.
    });
}
