# LCARS UI Changelog

All notable changes to the LCARS Kanban Workflow Monitor will be documented in this file.

## [Unreleased]

### Changed
- **LCARS Tab Order Reorder** (XACA-0115) - Reordered all tab navigation for improved workflow
  - New order: HOME → TODOS → CALENDAR → WORKFLOW → DETAILS → QUEUE → EPICS → RELEASES → SETTINGS
  - TODOS and CALENDAR moved to positions 2-3 for faster access to daily-use tabs
  - Updated SECTIONS array, sidebar buttons, mobile tabbar, and Alt+1-8 keyboard shortcuts

### Fixed
- **Terminal Activation tmux Socket Fix** (XACA-0102) - Terminal click-to-activate was
  non-functional because the tmux command used the default socket (which doesn't exist) and
  bare terminal names (which don't match). Fix adds `-L {team}` for per-team sockets and
  constructs `{team}-{terminal}` session names using the `LCARS_TEAM` environment variable.
- **Knowledge Panel Orphaned Chart Guard** (XACA-0098-016) - Debounce and AbortController
  pattern added to `_renderHomeKnowledgeStats` to prevent orphaned chart injection on rapid
  carousel navigation.
  - Added module-level `_knowledgeAbortController` and `_knowledgeDebounceTimer` state variables
  - `_renderHomeKnowledgeStats` now coalesces rapid calls with a 150ms debounce before firing
    the `/api/knowledge-stats` fetch
  - In-flight fetch is aborted immediately via `AbortController.signal` when a new call arrives
  - Two `currentHomePanel !== 4` guards after each `await` prevent stale continuations from
    injecting DOM content or charts when a different panel is active
  - `navigateToPanel` cancels debounce timer and aborts fetch when leaving panel 4
  - `stopCarousel` cancels debounce timer and aborts fetch when leaving the HOME tab entirely
  - `AbortError` exceptions are silently suppressed (they are intentional, not failures)

### Added
- **Team Todo List UI** (XACA-0101) - Lightweight per-team todo feature for quick one-shot items
  - New TODOS sidebar button and section in LCARS Kanban UI (`lcars-ui/index.html`)
  - Toggle tabs to switch between ACTIVE and COMPLETED views
  - Checkbox-based completion toggle with immediate API update
  - Priority badges (low/medium/high/critical) with LCARS color coding; critical items pulse
  - Optional required-by date with overdue highlighting (red border + date label)
  - Add/Edit modal with text, priority, and date fields; delete with confirmation
  - Empty state and loading state indicators
  - Reusable `lcars-modal` pattern for todo add/edit form
  - `todos-section` integrated into section switching, hide/show, and entrance animation system
  - All JavaScript functions: `loadTodos`, `renderTodos`, `filterTodos`, `openTodoModal`,
    `closeTodoModal`, `saveTodo`, `deleteTodo`, `toggleTodo`, `renderTodoItem`
  - API endpoints: `GET /api/todos`, `POST /api/todos`, `PUT /api/todos`, `DELETE /api/todos`
    (server implementation in `server.py` via XACA-0101-002)
  - Server handlers: `serve_todos_list`, `handle_create_todo`, `handle_update_todo`, `handle_delete_todo`
  - File locking + atomic writes; auto-sets completedAt on status transitions; sorts active by priority/date
- **AMB Badge Display** (XACA-0080) - Optional Agent Merit Badges display in agent panels
  - `@handle` text and up to 5 earned badge emojis shown between role and location/divider
  - Only visible for agents registered on the AMB platform (file-based detection)
  - `agent-panel.html`: `.amb-section` with handle + badge row, hidden by default
  - `agent-panel-display.sh`: `get_amb_badges()` with 5-min file cache, centered emoji display
  - `server.py`: `_fetch_amb_badges()` with in-memory cache (5-min TTL), badge enrichment in API response
  - `display-agent-avatar.sh`: `amb_handle` field in JSON output with config file validation
  - Graceful degradation at every layer (API down, no handle, no badges = invisible)

## [2026-02-12] - Agent Panel Split Panes & VESSEL/UPDATED Alignment

### Added
- **Terminal-Based Agent Panels** - Split pane in each terminal tab showing agent avatar and info
  - Uses `imgcat` for inline avatar display + ANSI formatting for agent details
  - Polls `/tmp/lcars-agent-{session}.json` for data changes (3s interval)
  - Auto-refreshes when agent data updates (file mtime detection)
  - Narrow 30-column pane on right side of each terminal tab
- **`agent-panel-display.sh`** - New script for terminal-based agent panel rendering
- **`agent-panel.html`** / **`agent-panel-router.html`** - Browser-based panel pages (available as fallback)
- **Per-session agent JSON** - `display-agent-avatar.sh` writes per-session JSON files for panel consumption

### Changed
- **VESSEL/UPDATED positioning** - Moved up 4px and tightened gap between lines by 8px across all LCARS UIs
  - `lcars-ui/css/lcars.css`
  - `fleet-monitor/lcars/css/lcars-fleet.css`
  - `fleet-monitor/lcars2/css/lcars-fleet.css`
- **`iterm2_window_manager.py`** - `split-agent-panel` action now uses Default profile + command (not Browser WebView)
  - Resizes pane to 30 cols after split for narrow sidebar layout
- **`server.py`** - Fixed `tempfile.gettempdir()` mismatch; hardcoded `/tmp` for agent JSON reads
- **All 10 startup scripts** - Updated to use `--command` with `agent-panel-display.sh` instead of `--url`
- **All banner scripts** - Updated to write per-session JSON via `display-agent-avatar.sh`

---

## [2026-01-28] - XACA-0050: Add shortTitle to Epics and Releases

### Added
- **Epic shortTitle Field** - Optional short display name for Epics
  - CLI: `kb-epic create --short-title "text"` or `-s "text"`
  - CLI: `kb-epic update <id> shortTitle "value"`
  - UI: shortTitle input in Epic create/edit modals
- **Release shortTitle Field** - Optional short display name for Releases
  - API: Create/update releases with optional shortTitle
  - UI: shortTitle input in Release create/edit modals
- **QUEUE Badge Display** - Epic and Release badges show shortTitle when available
  - Falls back to full title if shortTitle not set
  - Full title shown in tooltip for accessibility

### Changed
- **Badge Rendering** - Epic/Release badges now use `shortTitle || title` pattern
- **Modal Forms** - Added shortTitle input fields with helpful hints

---

## [2026-01-27] - XACA-0046: Queue Item UI Redesign

### Added
- **Zone-Based Layout** - Reorganized queue item header into 4 distinct zones:
  - **Identity Zone** - Expander, Priority, Category, Due Date, Item ID (always visible)
  - **Title Zone** - Item title with flex-grow (always visible)
  - **Tracking Zone** - Epic, Release, JIRA, GitHub, DOCS (toggle-controlled)
  - **Workflow Zone** - Window badge, Worktree badge, Tags (toggle-controlled)
- **View Toggle Button** - New "VIEW: TAGS/TRACKING" toggle in filter bar
  - Switches between showing Tags or Tracking metadata
  - Touch-friendly (replaces hover-to-reveal for iPad/iPhone support)
  - Persists preference to localStorage
- **Visual Hierarchy** - CSS-based hierarchy for scanability:
  - PRIMARY (14px, opacity 1.0): Title, Priority, Item ID
  - SECONDARY (12px, opacity 0.85): Category, Window/Worktree badges
  - TERTIARY (11px, opacity 0.7): Tracking zone elements
- **Progressive Disclosure** - Smooth CSS transitions for subitem expand/collapse
- **Accessibility Improvements** - ARIA attributes, keyboard navigation, focus indicators
- **Wireframe Documentation** - Design spec at `docs/kanban/XACA-0046_queue_redesign_wireframes.md`

### Changed
- **Due Date Position** - Moved from tracking zone to identity zone (always visible)
- **createQueueItem()** - Refactored to build elements into zone wrapper divs
- **Subitem Visibility** - Now uses CSS transitions instead of inline style.display

### Removed
- **Hover-to-Reveal** - Replaced with toggle button for better touch device support

---

## [2026-01-26] - XACA-0045: Plan Document Popup Reader

### Added
- **DOCS Button** - Conditional button on kanban items that appears when a plan document exists
  - Async existence check via new API endpoint
  - Blue LCARS styling with hover state
  - Positioned in queue item header
- **Plan Document Modal** - Popup reader for viewing markdown plan documents
  - Full markdown rendering (headers, lists, code blocks, links, bold/italic)
  - LCARS-themed styling with teal/cyan/purple color scheme
  - Loading and error state handling
  - Close via X button or clicking outside modal
  - Custom scrollbar for long documents
- **Server API Endpoints** - Two new endpoints for plan document access
  - `GET /api/kanban/<item-id>/plan-exists` - Check if plan document exists
  - `GET /api/kanban/<item-id>/plan-content` - Retrieve markdown content
  - Team-aware path resolution (iOS, Android, Firebase, Academy, Freelance, etc.)
  - Glob pattern matching for `<ITEM-ID>_*.md` files
- **Plan Document Cache** - Client-side caching infrastructure
  - 60-second TTL for existence checks
  - Cache clearing on board refresh

### Changed
- **createQueueItem()** - Added DOCS button rendering with async existence check

---

## [2026-01-25] - XACA-0042: LCARS Style Guide Alignment & Animation Library Sync

### Added
- **Animation Library** - Ported Fleet Monitor animations to Kanban LCARS
  - `lcars-glow` (with slow/fast variants) - Pulsing glow effect
  - `lcars-breathe` (with slow variant) - Opacity pulsing
  - `lcars-scan` (with slow variant) - Horizontal scanning beam
  - `lcars-warp` (in/out variants) - Warp speed stretch effect
  - `lcars-transport` (in/out) - Star Trek transporter dissolve
- **Slide Animations** - `slideInLeft` / `slideInRight` keyframes and utility classes
- **Candy-Pill Animations** - `candy-pulse` and `candy-invert` for interaction feedback
- **Accessibility** - `prefers-reduced-motion` media query covering all 19+ animation types
- **Missing Color Variables** - Added `--lcars-error`, `--lcars-violet`, `--lcars-yellow-glow`, `--lcars-alert-glow`
- **Organization Colors** - Added `--org-personal`, `--org-legal`
- **Division Colors** - Added `--div-legal`, `--div-legal-coparenting`
- **Firefox Scrollbar Support** - Added `scrollbar-width` and `scrollbar-color` to all scrollbar definitions

### Fixed
- **Critical Color Bug** - Line 29 incorrectly defined `--lcars-orange: #aa77dd` (violet value)
  - Now correctly defines `--lcars-violet: #aa77dd`
  - StarWords freelance division now displays correct violet color
- **Green-Dark Value** - Synced `--lcars-green-dark` to Fleet Monitor value (`#66cc66`)

### Changed
- **Easing Functions** - Standardized `--lcars-ease-smooth` and `--lcars-ease-elastic` across both interfaces
- **Fleet Monitor CSS** - Added Firefox scrollbar support to `lcars-fleet.css` and `lcars-fleet-theme.css`

---

## [2026-01-24] - XACA-0041: Animated Settings Sub-Menu

### Added
- **SETTINGS Button with Sub-Menu** - Consolidated INTEGRATIONS, BACKUPS, and COMMANDS into a single SETTINGS button with animated sub-menu
- **CSS Animation** - Smooth horizontal slide-out animation using `transform: scaleX()` (250ms ease-out)
  - Sub-menu positioned to the right of sidebar
  - High z-index (1000) for proper layering
  - Hover states with color inversion (tan ↔ black)
  - Active state tracking for selected sub-menu items
- **JavaScript Toggle Logic** - Complete sub-menu interaction handling
  - Toggle on SETTINGS button click
  - Close on outside click (document-level listener)
  - Close after item selection with navigation
  - Integrates with existing `switchSection()` function
  - Active state sync for sub-menu items

### Changed
- **Sidebar Structure** - Replaced three separate buttons (INTEGRATIONS, BACKUPS, COMMANDS) with nested SETTINGS sub-menu

---

## [2026-01-21] - XACA-0037: Team Validation for Release Item Assignment

### Added
- **Team Field in Release Schema** - Added `team` field to releases.json config and individual releases for ownership tracking
- **Server-Side Validation** - `handle_assign_item_to_release()` now validates item team matches release team, returns 403 on mismatch
- **Team Filter API** - `/api/releases?team=<team>` query parameter to filter releases by team
- **UI Team Filtering** - `showReleaseAssignModal()` now only shows releases for current team
- **RELNOTES Safeguard** - `generateRelnotesContent()` filters out cross-team items as defensive measure
- **Item ID Prefix Utilities** - `extractTeamFromItemId()` functions in both Python and JavaScript
  - Supports: XIOS→ios, XAND→android, XFIR→firebase, XACA→academy, XCMD→command, XDNS→dns, XFRE→freelance, XMEV→mainevent

### Fixed
- **Cross-Team Contamination Bug** - Items from one team can no longer be assigned to another team's releases

### Changed
- **Existing releases.json Files** - Updated with team ownership field for backward compatibility

---

## [2026-01-20] - XACA-0018: Monday.com Integration Support

### Added
- **MondayProvider Class** - Full Monday.com GraphQL API integration
  - Bearer token authentication via `MONDAY_API_TOKEN` environment variable
  - Connection testing using Monday.com `me` query
  - Item search across accessible boards
  - Item verification and URL generation
- **Status Column Detection** - Intelligent status column handling
  - `get_board_columns()` - Fetch all columns for a board
  - `detect_status_columns()` - Find status columns with their labels
  - `get_status_column_for_item()` - Get item's current status info
- **Status Synchronization** - `sync_status()` method with mapping support
  - Maps kanban statuses to Monday.com status labels
  - Case-insensitive label matching
  - Skip-on-unchanged optimization
- **Board Fetching API** - `POST /api/integrations/boards` endpoint for Monday.com
- **Frontend Integration**
  - Monday.com preset in INTEGRATION_PRESETS (auto-fill configuration)
  - Monday.com option in integration type dropdown
  - Monday icon (📅) in integration cards
  - Ticket pill styling with coral red (#ff6b6b) theme
- **Manual Integration Test** - `test_monday_integration.py` for real board testing
- **Unit Tests** - Extended test suite with `TestMondayProviderStatusMethods` class

### Documentation
- Updated `integrations/README.md` with Monday.com configuration examples
- Added API token setup instructions
- Documented status column detection and synchronization features
- Added Monday.com specific features section

---

## [2026-01-19] - XACA-0027: LCARS Configure Flow Feature

### Added
- **Configure Flow Button** - New "⚙ FLOW" button in releases tab header
- **Current Flow Display** - Shows enabled stages in header (e.g., `DEV → QA → PROD`), updates after config changes
- **Flow Config Modal** - Visual configuration modal with:
  - Dynamic flow diagram preview showing active stages
  - Toggle switches for QA, ALPHA, BETA, GAMMA stages
  - DEV and PROD locked as required stages
- **`flowConfig` Schema** - Added to all team `releases.json` files with stage enable/disable state
- **API Endpoint** - `POST /api/releases/flow-config` for saving flow configuration
- **`getEnabledEnvironments()`** - Helper function to get list of enabled stages
- **`updateCurrentFlowDisplay()`** - Updates header flow display when config changes

### Changed
- **Promote Logic** - Now skips disabled stages when auto-promoting to next environment
- **Promotion Modal** - Only displays enabled target environments
- **Release Cards** - Progress bars calculate percentage based on enabled stages only
- **`loadReleases()`** - Now fetches flow config in parallel for accurate progress display
- **`renderReleaseCard()`** - Accepts flowConfig parameter for stage-aware rendering
- **`/api/release-config`** - Now includes `flowConfig` in response

### Features
- **Team-Scoped** - Each team has independent flow configuration
- **Backward Compatible** - Defaults to all stages enabled if no flowConfig exists
- **Real-time Preview** - Flow diagram updates instantly as toggles change

---

## [2026-01-19] - XACA-0029: Work Time Tracking for Kanban Items

### Added
- **`formatWorkTime(ms)`** - Formats milliseconds as human-readable duration (e.g., "2h 15m", "3d 4h")
- **`calculateParentWorkTime(item)`** - Sums `timeWorkedMs` from all completed subitems for rollup display
- **Subitem Time Display** - Completed subitems show work time after timestamp (e.g., "✓ 2026-01-19 12:00 (2h 15m)")
- **Parent Rollup Display** - Parent items show total accumulated time from completed subitems
- **Partial Progress Display** - In-progress parent items show "(Xh Ym worked)" from completed subitems
- **CSS Classes**:
  - `.item-time-worked` - Styling for time display on parent items
  - `.subitem-time-worked` - Styling for time display on subitems
  - `.item-time-worked.partial` - Styling for in-progress rollup display

### Features
- Time accumulates across multiple work sessions (start/stop cycles)
- Only shows time on completed items (not in-progress)
- Blue color for time worked, mauve for partial progress

---

## [2026-01-19] - Window Badge Text Contrast Fix

### Fixed
- **Window badge readability** - Changed text color from black to white for all window badge states
  - Default (orange background): now uses white text
  - Coding (blue background): now uses white text
  - Planning (gold background): now uses white text
  - Paused (red background): already used white text (unchanged)
- Resolves "black on black" visibility issue where window badges were hard to read against the dark LCARS interface

---

## [2026-01-19] - Smart Team Code Generation for Kanban IDs

### Added
- **FAP Team Code** - New mapping for `freelance-doublenode-appplanning` → `XFAP-####`
- **Smart Compound Word Extraction** - `_kb_extract_compound_code()` function that intelligently parses compound words to generate 2-letter codes:
  - Detects camelCase (e.g., `CodeReview` → `CR`)
  - Finds consonant clusters at word boundaries (e.g., `starwords` → `SW`, `workstats` → `WS`, `appplanning` → `AP`)
  - Falls back to first two letters when no pattern detected
- **Intelligent Fallback** - Multi-segment team names now auto-generate codes using first letter of first segment + smart 2-letter code from last segment

### Changed
- `_kb_get_team_code()` fallback logic upgraded from simple "first 3 chars" to intelligent compound word parsing
- Existing AppPlanning items migrated from `XFRE-*` to `XFAP-*` prefix

### Fixed
- AppPlanning kanban items no longer incorrectly use `XFRE` prefix (which belongs to main `freelance` team)

---

## [2026-01-19] - XACA-0021: Hover-to-Filter Blocked Items (Enhanced)

### Added
- **Dependency Filter Mode** - Hover over "Blocked by" row to filter queue
- **`activateDependencyFilter()`** - Shows only blocked item and its blockers
- **`deactivateDependencyFilter()`** - Restores normal queue view
- **`checkAndClearStuckDependencyFilter()`** - Safety fallback on document click
- **Subitem-Level Filtering** - Hover over subitem blockers to filter:
  - Source subitem highlighted with `.dependency-source` class
  - Only blocking subitems remain visible
  - Non-blocking subitems fade to 15% opacity
  - Auto-expands parent items to reveal blocking subitems
- **CSS Classes**:
  - `.dependency-filter-active` - Queue container in filter mode
  - `.dependency-visible` - Items/subitems visible during filtering
  - `.dependency-source` - The blocked item/subitem (stronger highlight)
  - `.filter-hover` - Visual feedback on blocked row or subitem blocker container
  - `.subitem-blocker-container.filter-hover` - Hover styling for subitem blockers

### Features
- Fades non-related items to 15% opacity
- Fades non-blocking subitems within visible parent items
- Orange glow on visible items and subitems during filter
- Auto-expands parent items when subitem is a blocker
- Smooth 0.2s transitions for all effects
- Supports single and multiple blockers
- Works for both parent item and subitem blocked-by indicators

### Fixed
- Filter no longer gets stuck when queue re-renders during hover
- Pointer-events preserved on hover elements to ensure mouseleave fires

---

## [2026-01-19] - XACA-0025: Extend Blocked-By System to Subitems

### Added
- **Subitem Blocker Pills** - Blocked subitems now display inline blocker pills in their header
- **Subitem Navigation** - Clicking blocker pills navigates to the blocking item/subitem:
  - Parent items scroll and highlight
  - Subitems auto-expand parent first, then scroll and highlight
- **`navigateToBlocker()` Helper** - Unified navigation for both parent and subitem blockers
- **`data-subitem-id` Attribute** - Enables DOM targeting for subitem navigation
- **`is-blocked` Class for Subitems** - Visual styling for blocked subitems
- **CLI Subitem Blocking Commands**:
  - `kb-backlog block XACA-0016-001 XACA-0016-002` - Block subitem by subitem
  - `kb-backlog block XACA-0016-003 XACA-0017` - Block subitem by parent item
  - `kb-backlog unblock XACA-0016-001` - Remove all blockers from subitem
  - `kb-backlog unblock XACA-0016-001 XACA-0016-002` - Remove specific blocker
- **Auto-Unblock Cascade** - Completing a subitem auto-unblocks dependent items/subitems
- **Backend Helper Functions**:
  - `_kb_is_subitem_id()` - Detect subitem ID format
  - `_kb_add_subitem_blocker()` - Add blocker to subitem
  - `_kb_remove_subitem_blocker()` - Remove blocker from subitem

### Changed
- `_kb_check_unblock_dependents()` now processes both items and subitems
- Parent item blocker pill click handler refactored to use shared `navigateToBlocker()`

---

## [2026-01-19] - Delete Release Feature

### Added
- **Delete Release Button** - Red "DELETE" button on release cards
- **`deleteRelease()` Function** - Archives release with confirmation prompt
- **Danger Button Styling** - Red theme for destructive actions

---

## [2026-01-19] - XACA-0016: Multi-Platform Integration System

### Added
- **INTEGRATIONS Tab** - New orange-colored tab for managing external integrations
- **Integration Provider Architecture** - Flexible system supporting multiple platforms:
  - Abstract `IntegrationProvider` base class
  - JIRA Cloud implementation with REST API v3
  - Extensible for GitHub, Linear, and custom providers
- **Integration Modal** - Full add/edit/delete functionality:
  - Type selector (JIRA/GitHub/Linear/Custom)
  - Auto-fill presets based on type selection
  - URL configuration (base URL, browse URL pattern)
  - Project filtering and ticket ID regex patterns
  - Environment variable credential configuration
  - Test Connection button with user info display
- **ticketLinks Data Model** - Replaces legacy single `jiraId` field:
  - Supports multiple ticket links per kanban item
  - Caches ticket summary and status
  - Tracks link creation metadata
- **Integration API Endpoints**:
  - `/api/integrations` - List all configured integrations
  - `/api/integrations/test` - Test connection and show user info
  - `/api/integrations/verify` - Verify ticket exists
  - `/api/integrations/search` - Search for tickets by JQL
  - `/api/integrations/save` - Create or update integration
  - `/api/integrations/delete` - Remove integration
- **Migration Script** - Migrates legacy `jiraId` to `ticketLinks` format
- **22 Unit Tests** - Full test coverage for integration system

### Changed
- Tab order: RELEASES now appears before INTEGRATIONS
- INTEGRATIONS button uses unique orange color (`--lcars-orange`)
- JIRA API updated to use `/search/jql` endpoint (v3 compatibility)
- Default JIRA projects updated to: MEM, MEW, MEAPP, MEKIOSK, MEWEB

### Fixed
- JIRA 410 Gone error by updating deprecated search endpoint
- Test button now displays authenticated user info prominently

---

## [2026-01-19] - XACA-0023: Release Tracking System

### Added
- **Release Management Dashboard** - New RELEASES tab with green color theme
- **Create Release Modal** - Form to create new releases with:
  - Release name (required)
  - Type selector (feature/bugfix/hotfix/maintenance)
  - Platform checkboxes (iOS/Android/Firebase)
  - Target date (optional)
  - Description (optional)
- **Release Assignment Modal** - Assign kanban items to releases:
  - Pre-populates current assignment when editing
  - UNASSIGN button (red) for removing assignments
  - Auto-detects platform from item ID prefix (XIOS/XAND/XFIR)
  - Handles reassignment (unassigns from old release first)
- **Release Filter Dropdown** - Filter queue by release assignment:
  - ALL - Show all items
  - ASSIGNED - Show only items assigned to a release
  - UNASSIGNED - Show items not yet assigned
- **Release Badge on Queue Items** - Shows assigned release ID or "+REL" to assign
- **Release Manager Skill** - CLI commands for release management:
  - `/release list` - List all active releases
  - `/release show <id>` - Show detailed release info
  - `/release create "name"` - Create a new release
  - `/release assign <item-id> <release-id>` - Assign item to release
  - `/release unassign <item-id> <release-id>` - Remove item from release
  - `/release promote <release-id> <platform>` - Promote platform to next environment
  - `/release status <release-id>` - Show release progress by platform
  - `/release archive <release-id>` - Archive a completed release

### Changed
- RELEASES sidebar/tabbar button now uses green color
- Modal system extended with input fields, textareas, and checkboxes
- Queue items now display release assignment badge

### Fixed
- Release dashboard auto-refreshes after creating new release
- Browser autofill disabled on release name input
- Assign modal handles already-assigned items gracefully

---

## [2026-01-17] - Foundation

### Added
- Initial RELEASES tab structure
- releases.json configuration file
- API endpoints for release management
- Basic release card display in dashboard
