/**
 * LCARS Activity Timeline Module
 * Displays item activity history in a modal panel
 *
 * Follows LCARS UI patterns from lcars.js — vanilla JS, no frameworks.
 * Depends on: escapeHtml(), apiUrl(), pauseAutoRefresh(), resumeAutoRefresh()
 * from lcars.js (loaded before this file).
 */

// ═══════════════════════════════════════════════════════════════════════════════
// ACTION TYPE CONFIGURATION
// ═══════════════════════════════════════════════════════════════════════════════

const ACTIVITY_ICONS = {
    item_created:           '\u2726',   // ✦
    status_change:          '\u25C9',   // ◉
    field_update:           '\u270E',   // ✎
    tag_added:              '+',
    tag_removed:            '\u2212',   // −
    subitem_added:          '\u25C8',   // ◈
    subitem_status_change:  '\u25C9',   // ◉
    subitem_cancelled:      '\u2715',   // ✕
    blocked:                '\u2298',   // ⊘
    unblocked:              '\u2299',   // ⊙
    paused:                 '\u23F8',   // ⏸
    resumed:                '\u25B6',   // ▶
    jira_linked:            '\uD83D\uDD17',  // 🔗
    github_linked:          '\uD83D\uDD17',  // 🔗
    window_claimed:         '\u25B8',   // ▸
    window_released:        '\u25C2',   // ◂
    collapsed_toggled:      '\u25BC'    // ▼
};

// Color bar category — CSS class suffix maps to var in lcars-activity.css
const ACTIVITY_CATEGORY = {
    item_created:           'creation',
    subitem_added:          'creation',
    field_update:           'update',
    tag_added:              'update',
    tag_removed:            'update',
    status_change:          'status',
    subitem_status_change:  'status',
    subitem_cancelled:      'cancel',
    paused:                 'cancel',
    blocked:                'cancel',
    window_claimed:         'workflow',
    window_released:        'workflow',
    resumed:                'workflow',
    unblocked:              'workflow',
    jira_linked:            'workflow',
    github_linked:          'workflow',
    collapsed_toggled:      'workflow'
};

// ═══════════════════════════════════════════════════════════════════════════════
// STATUS BADGE COLORS (mirrors LCARS status palette)
// ═══════════════════════════════════════════════════════════════════════════════

const STATUS_COLORS = {
    backlog:      '#9999ff',
    planning:     '#ccccff',
    ready:        '#99ccff',
    in_progress:  '#ffcc00',
    review:       '#ff9900',
    testing:      '#cc99ff',
    done:         '#99ff99',
    completed:    '#99ff99',
    cancelled:    '#ff6666',
    blocked:      '#ff4444',
    paused:       '#cc9966',
    archived:     '#666688'
};

// ═══════════════════════════════════════════════════════════════════════════════
// MODULE STATE
// ═══════════════════════════════════════════════════════════════════════════════

const ActivityTimeline = (function () {
    // Private state
    let _currentItemId = null;
    let _currentPage = 1;
    let _hasMore = false;
    let _allEntries = [];
    let _filterState = {
        actionType: 'all',
        agent: 'all',
        subitemId: ''
    };

    // ─────────────────────────────────────────────────────────────────────────
    // PUBLIC: open(itemId)
    // Fetches activity log and opens the modal panel.
    // ─────────────────────────────────────────────────────────────────────────
    function open(itemId) {
        _currentItemId = itemId;
        _currentPage = 1;
        _hasMore = false;
        _allEntries = [];
        _filterState = { actionType: 'all', agent: 'all', subitemId: '' };

        _createModal(itemId);
        _showLoading();

        if (typeof pauseAutoRefresh === 'function') {
            pauseAutoRefresh();
        }

        _fetchActivity(itemId, 1).then(function (data) {
            _allEntries = data.entries || [];
            _hasMore = data.hasMore || false;
            _populateFilters(_allEntries);
            render(_allEntries);
        }).catch(function (err) {
            _showError('Failed to load activity: ' + err.message);
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PUBLIC: render(entries)
    // Renders the filtered timeline entries into the panel body.
    // ─────────────────────────────────────────────────────────────────────────
    function render(entries) {
        const body = document.getElementById('activity-timeline-body');
        if (!body) return;

        const filtered = _applyFilters(entries);

        if (filtered.length === 0) {
            body.innerHTML = '<div class="activity-empty">NO ACTIVITY RECORDED</div>';
        } else {
            body.innerHTML = filtered.map(_renderEntry).join('');
        }

        _updateLoadMoreButton();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PUBLIC: close()
    // Removes the modal from the DOM and resumes auto-refresh.
    // ─────────────────────────────────────────────────────────────────────────
    function close() {
        const modal = document.getElementById('activity-timeline-modal');
        if (modal) {
            if (modal._keyHandler) {
                document.removeEventListener('keydown', modal._keyHandler);
            }
            modal.classList.remove('active');
            setTimeout(function () {
                if (modal.parentNode) {
                    modal.parentNode.removeChild(modal);
                }
            }, 300);
        }

        if (typeof resumeAutoRefresh === 'function') {
            resumeAutoRefresh();
        }

        _currentItemId = null;
        _allEntries = [];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PUBLIC: formatTimestamp(isoString)
    // Returns a human-readable relative time string.
    // ─────────────────────────────────────────────────────────────────────────
    function formatTimestamp(isoString) {
        if (!isoString) return 'Unknown';

        var date;
        try {
            date = new Date(isoString);
            if (isNaN(date.getTime())) return isoString;
        } catch (e) {
            return isoString;
        }

        var now = new Date();
        var diffMs = now - date;
        var diffSec = Math.floor(diffMs / 1000);
        var diffMin = Math.floor(diffSec / 60);
        var diffHr  = Math.floor(diffMin / 60);
        var diffDay = Math.floor(diffHr / 24);

        if (diffSec < 60)  return 'just now';
        if (diffMin < 60)  return diffMin + (diffMin === 1 ? ' minute ago' : ' minutes ago');
        if (diffHr < 24)   return diffHr + (diffHr === 1 ? ' hour ago' : ' hours ago');
        if (diffDay === 1) return 'yesterday';
        if (diffDay < 7)   return diffDay + ' days ago';
        if (diffDay < 14)  return 'last week';
        if (diffDay < 30)  return Math.floor(diffDay / 7) + ' weeks ago';
        if (diffDay < 365) return Math.floor(diffDay / 30) + (Math.floor(diffDay / 30) === 1 ? ' month ago' : ' months ago');
        return Math.floor(diffDay / 365) + (Math.floor(diffDay / 365) === 1 ? ' year ago' : ' years ago');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: _fetchActivity(itemId, page)
    // Calls the API and returns a promise resolving to {entries, hasMore}.
    // ─────────────────────────────────────────────────────────────────────────
    function _fetchActivity(itemId, page) {
        var url = typeof apiUrl === 'function'
            ? apiUrl('/api/kanban/' + itemId + '/activity?page=' + page)
            : '/api/kanban/' + itemId + '/activity?page=' + page;

        return fetch(url).then(function (resp) {
            if (!resp.ok) {
                throw new Error('HTTP ' + resp.status);
            }
            return resp.json();
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: _createModal(itemId)
    // Builds and inserts the modal DOM structure.
    // ─────────────────────────────────────────────────────────────────────────
    function _createModal(itemId) {
        // Remove any existing instance
        var existing = document.getElementById('activity-timeline-modal');
        if (existing) existing.parentNode.removeChild(existing);

        var modal = document.createElement('div');
        modal.id = 'activity-timeline-modal';
        modal.className = 'activity-timeline-modal';
        modal.setAttribute('role', 'dialog');
        modal.setAttribute('aria-label', 'Activity Timeline');

        modal.innerHTML =
            '<div class="activity-backdrop"></div>' +
            '<div class="activity-panel">' +
                '<div class="activity-header">' +
                    '<div class="activity-header-left">' +
                        '<span class="activity-header-icon">\u25C9</span>' +
                        '<span class="activity-header-title">ACTIVITY LOG</span>' +
                        '<span class="activity-header-id">' + _escapeHtml(itemId) + '</span>' +
                    '</div>' +
                    '<button class="activity-close-btn" onclick="ActivityTimeline.close()" title="Close (Esc)">[X]</button>' +
                '</div>' +
                '<div class="activity-filter-bar">' +
                    '<div class="activity-filter-group">' +
                        '<label class="activity-filter-label">ACTION</label>' +
                        '<select class="activity-filter-select" id="activity-filter-action" onchange="ActivityTimeline._onFilterChange()">' +
                            '<option value="all">ALL</option>' +
                        '</select>' +
                    '</div>' +
                    '<div class="activity-filter-group">' +
                        '<label class="activity-filter-label">AGENT</label>' +
                        '<select class="activity-filter-select" id="activity-filter-agent" onchange="ActivityTimeline._onFilterChange()">' +
                            '<option value="all">ALL</option>' +
                        '</select>' +
                    '</div>' +
                    '<div class="activity-filter-group">' +
                        '<label class="activity-filter-label">SUBITEM</label>' +
                        '<input class="activity-filter-input" id="activity-filter-subitem" type="text" placeholder="filter..." oninput="ActivityTimeline._onFilterChange()">' +
                    '</div>' +
                    '<button class="activity-filter-clear" onclick="ActivityTimeline._clearFilters()">CLEAR</button>' +
                '</div>' +
                '<div class="activity-timeline-body" id="activity-timeline-body">' +
                    '<div class="activity-loading">LOADING ACTIVITY DATA...</div>' +
                '</div>' +
                '<div class="activity-footer" id="activity-footer">' +
                    '<button class="activity-load-more" id="activity-load-more" onclick="ActivityTimeline._loadMore()" style="display:none">LOAD MORE</button>' +
                '</div>' +
            '</div>';

        document.body.appendChild(modal);

        // Activate with a slight delay so CSS transition fires
        setTimeout(function () { modal.classList.add('active'); }, 10);

        // ESC key handler
        modal._keyHandler = function (e) {
            if (e.key === 'Escape') ActivityTimeline.close();
        };
        document.addEventListener('keydown', modal._keyHandler);

        // Backdrop click closes
        modal.querySelector('.activity-backdrop').addEventListener('click', function () {
            ActivityTimeline.close();
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: _showLoading()
    // ─────────────────────────────────────────────────────────────────────────
    function _showLoading() {
        var body = document.getElementById('activity-timeline-body');
        if (body) {
            body.innerHTML = '<div class="activity-loading">LOADING ACTIVITY DATA...</div>';
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: _showError(msg)
    // ─────────────────────────────────────────────────────────────────────────
    function _showError(msg) {
        var body = document.getElementById('activity-timeline-body');
        if (body) {
            body.innerHTML = '<div class="activity-error">' + _escapeHtml(msg) + '</div>';
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: _populateFilters(entries)
    // Fills action-type and agent dropdowns from the loaded data.
    // ─────────────────────────────────────────────────────────────────────────
    function _populateFilters(entries) {
        var actionTypes = {};
        var agents = {};

        entries.forEach(function (e) {
            if (e.action) actionTypes[e.action] = true;
            if (e.agent) agents[e.agent] = true;
        });

        var actionSel = document.getElementById('activity-filter-action');
        var agentSel  = document.getElementById('activity-filter-agent');

        if (actionSel) {
            actionSel.innerHTML = '<option value="all">ALL</option>';
            Object.keys(actionTypes).sort().forEach(function (a) {
                var opt = document.createElement('option');
                opt.value = a;
                opt.textContent = a.toUpperCase().replace(/_/g, ' ');
                actionSel.appendChild(opt);
            });
        }

        if (agentSel) {
            agentSel.innerHTML = '<option value="all">ALL</option>';
            Object.keys(agents).sort().forEach(function (a) {
                var opt = document.createElement('option');
                opt.value = a;
                opt.textContent = a.toUpperCase();
                agentSel.appendChild(opt);
            });
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: _applyFilters(entries)
    // Returns entries matching current filter state.
    // ─────────────────────────────────────────────────────────────────────────
    function _applyFilters(entries) {
        return entries.filter(function (e) {
            if (_filterState.actionType !== 'all' && e.action !== _filterState.actionType) {
                return false;
            }
            if (_filterState.agent !== 'all' && e.agent !== _filterState.agent) {
                return false;
            }
            if (_filterState.subitemId) {
                var filter = _filterState.subitemId.toLowerCase();
                var target = (e.target || '').toLowerCase();
                var context = (e.context || '').toLowerCase();
                if (target.indexOf(filter) === -1 && context.indexOf(filter) === -1) {
                    return false;
                }
            }
            return true;
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: _renderEntry(entry)
    // Returns the HTML string for a single timeline entry.
    // entry shape: { action, agent, timestamp, oldValue, newValue, context, subitemId }
    // ─────────────────────────────────────────────────────────────────────────
    function _renderEntry(entry) {
        var action   = entry.action || 'unknown';
        var agent    = entry.agent || 'unknown';
        var ts       = entry.timestamp || '';
        var icon     = ACTIVITY_ICONS[action] || '?';
        var category = ACTIVITY_CATEGORY[action] || 'workflow';
        var relTime  = ActivityTimeline.formatTimestamp(ts);
        var fullTime = ts ? new Date(ts).toLocaleString('en-US', {
            year: 'numeric', month: 'short', day: 'numeric',
            hour: '2-digit', minute: '2-digit', second: '2-digit'
        }) : '';

        // Build change display
        var changeHtml = _renderChange(entry);

        // Context line
        var contextHtml = '';
        if (entry.context) {
            contextHtml = '<div class="activity-context">' + _escapeHtml(entry.context) + '</div>';
        }

        // Subitem reference
        var subitemHtml = '';
        if (entry.targetType === 'subitem' && entry.target) {
            subitemHtml = '<span class="activity-subitem-ref">' + _escapeHtml(entry.target) + '</span>';
        }

        return '<div class="activity-entry activity-cat-' + category + '">' +
                    '<div class="activity-entry-bar"></div>' +
                    '<div class="activity-entry-content">' +
                        '<div class="activity-entry-header">' +
                            '<span class="activity-icon">' + icon + '</span>' +
                            '<span class="activity-action-label">' +
                                action.toUpperCase().replace(/_/g, ' ') +
                            '</span>' +
                            subitemHtml +
                            '<span class="activity-spacer"></span>' +
                            '<span class="activity-agent-badge">' + _escapeHtml(agent) + '</span>' +
                            '<span class="activity-timestamp" title="' + _escapeHtml(fullTime) + '">' +
                                _escapeHtml(relTime) +
                            '</span>' +
                        '</div>' +
                        changeHtml +
                        contextHtml +
                    '</div>' +
               '</div>';
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: _renderChange(entry)
    // Returns HTML for field change and status badge display.
    // ─────────────────────────────────────────────────────────────────────────
    function _renderChange(entry) {
        var action = entry.action || '';
        var oldVal = entry.oldValue;
        var newVal = entry.newValue;

        // Status changes — render colored badges
        if (action === 'status_change' || action === 'subitem_status_change') {
            var oldBadge = oldVal ? _statusBadge(oldVal) : '<span class="activity-status-badge" style="opacity:0.4">none</span>';
            var newBadge = newVal ? _statusBadge(newVal) : '';
            return '<div class="activity-change">' +
                        oldBadge +
                        '<span class="activity-change-arrow">\u2192</span>' +
                        newBadge +
                   '</div>';
        }

        // Field updates — old → new in monospace
        if ((oldVal !== undefined && oldVal !== null) || (newVal !== undefined && newVal !== null)) {
            var oldDisplay = (oldVal !== null && oldVal !== undefined) ? String(oldVal) : '(empty)';
            var newDisplay = (newVal !== null && newVal !== undefined) ? String(newVal) : '(empty)';

            // Truncate long values
            if (oldDisplay.length > 80) oldDisplay = oldDisplay.substring(0, 80) + '...';
            if (newDisplay.length > 80) newDisplay = newDisplay.substring(0, 80) + '...';

            return '<div class="activity-change">' +
                        '<span class="activity-field-value old">' + _escapeHtml(oldDisplay) + '</span>' +
                        '<span class="activity-change-arrow">\u2192</span>' +
                        '<span class="activity-field-value new">' + _escapeHtml(newDisplay) + '</span>' +
                   '</div>';
        }

        return '';
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: _statusBadge(status)
    // Returns a colored badge span for a status string.
    // ─────────────────────────────────────────────────────────────────────────
    function _statusBadge(status) {
        var color = STATUS_COLORS[status] || '#888899';
        return '<span class="activity-status-badge" style="background:' + color + ';color:#000">' +
                    _escapeHtml(status.toUpperCase().replace(/_/g, ' ')) +
               '</span>';
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: _updateLoadMoreButton()
    // Shows or hides the "load more" footer button.
    // ─────────────────────────────────────────────────────────────────────────
    function _updateLoadMoreButton() {
        var btn = document.getElementById('activity-load-more');
        if (btn) {
            btn.style.display = _hasMore ? 'inline-block' : 'none';
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PRIVATE: _escapeHtml(text)
    // Uses the global escapeHtml from lcars.js when available, falls back
    // to a local implementation so this module is standalone-safe.
    // ─────────────────────────────────────────────────────────────────────────
    function _escapeHtml(text) {
        if (typeof escapeHtml === 'function') {
            return escapeHtml(text);
        }
        if (!text) return '';
        var div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PUBLIC (called from inline event handlers): _onFilterChange()
    // ─────────────────────────────────────────────────────────────────────────
    function _onFilterChange() {
        var actionSel  = document.getElementById('activity-filter-action');
        var agentSel   = document.getElementById('activity-filter-agent');
        var subitemInp = document.getElementById('activity-filter-subitem');

        _filterState.actionType = actionSel  ? actionSel.value  : 'all';
        _filterState.agent      = agentSel   ? agentSel.value   : 'all';
        _filterState.subitemId  = subitemInp ? subitemInp.value : '';

        render(_allEntries);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PUBLIC (called from inline event handler): _clearFilters()
    // ─────────────────────────────────────────────────────────────────────────
    function _clearFilters() {
        _filterState = { actionType: 'all', agent: 'all', subitemId: '' };

        var actionSel  = document.getElementById('activity-filter-action');
        var agentSel   = document.getElementById('activity-filter-agent');
        var subitemInp = document.getElementById('activity-filter-subitem');

        if (actionSel)  actionSel.value  = 'all';
        if (agentSel)   agentSel.value   = 'all';
        if (subitemInp) subitemInp.value = '';

        render(_allEntries);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PUBLIC (called from inline event handler): _loadMore()
    // Fetches the next page and appends entries.
    // ─────────────────────────────────────────────────────────────────────────
    function _loadMore() {
        if (!_currentItemId || !_hasMore) return;

        var btn = document.getElementById('activity-load-more');
        if (btn) btn.textContent = 'LOADING...';

        _currentPage += 1;
        _fetchActivity(_currentItemId, _currentPage).then(function (data) {
            var newEntries = data.entries || [];
            _hasMore = data.hasMore || false;
            _allEntries = _allEntries.concat(newEntries);
            _populateFilters(_allEntries);
            render(_allEntries);
            if (btn) btn.textContent = 'LOAD MORE';
        }).catch(function (err) {
            console.error('[ActivityTimeline] Load more failed:', err);
            if (btn) btn.textContent = 'LOAD MORE';
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PUBLIC API
    // ─────────────────────────────────────────────────────────────────────────
    return {
        open:             open,
        render:           render,
        close:            close,
        formatTimestamp:  formatTimestamp,
        _onFilterChange:  _onFilterChange,
        _clearFilters:    _clearFilters,
        _loadMore:        _loadMore
    };
}());
