//
//  daily-overview-popup.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//  (Year order is intentional: current year first per COPYRIGHT_POLICY.md § 4.8 range convention.)
//

/**
 * daily-overview-popup.js — detail popup for Daily Overview cards
 *
 * XACA-0351: Tap any card on the Daily Overview to surface full item details
 * in a modal popup.  Renders a category-specific layout for each of the 7
 * sources (kanban_todos, kanban_items_due, change_requests, backup_failures,
 * calendar_items, releases, alert).  Kanban IDs inside the popup body render
 * as deep-link anchors that close the popup and route via switchSection().
 *
 * Public API (globals called by daily-overview.js):
 *   openDailyOverviewPopup(item, categoryKey)  — open with the item from the API payload.
 *   closeDailyOverviewPopup()                  — programmatic close.
 *
 * Dependencies (defined in lcars.js, which loads before this file):
 *   escapeHtml(), switchSection()
 */

/* global escapeHtml, switchSection */

'use strict';

// ─── Module state ──────────────────────────────────────────────────────────────

/** Currently mounted backdrop element, or null when no popup is open. */
let _activeBackdrop = null;

/** Element that had focus before the popup opened — restored on close. */
let _previouslyFocused = null;

/** Whether the document-level keydown listener has been attached. */
let _keydownWired = false;

// ─── Public entry points ───────────────────────────────────────────────────────

/**
 * Open the detail popup for an item.
 *
 * @param {Object} item         The item object from /api/daily-overview (must
 *                              include a `details` sub-object; if missing the
 *                              popup falls back to the top-level fields).
 * @param {string} categoryKey  The category key (e.g. "kanban_todos") used to
 *                              choose the renderer.  Falls back to
 *                              item.details.kind if categoryKey is missing.
 */
function openDailyOverviewPopup(item, categoryKey) {
    if (!item) return;

    // If a popup is already open, replace its contents rather than stacking.
    closeDailyOverviewPopup();

    _previouslyFocused = document.activeElement;

    const details = item.details || {};
    const kind = categoryKey || details.kind || 'generic';

    const backdrop = document.createElement('div');
    backdrop.className = 'do-popup-backdrop';
    backdrop.setAttribute('role', 'dialog');
    backdrop.setAttribute('aria-modal', 'true');
    backdrop.setAttribute('aria-label', _popupAriaLabel(kind, item));

    backdrop.innerHTML = _renderPopupShell(item, details, kind);

    backdrop.addEventListener('click', _onBackdropClick);

    document.body.appendChild(backdrop);
    _activeBackdrop = backdrop;

    if (!_keydownWired) {
        document.addEventListener('keydown', _onDocumentKeydown);
        _keydownWired = true;
    }

    // Focus the close button so ESC and screen-readers work immediately.
    const closeBtn = backdrop.querySelector('.do-popup-close');
    if (closeBtn) {
        closeBtn.focus();
    }
}

/** Close the active popup if one is open. */
function closeDailyOverviewPopup() {
    if (!_activeBackdrop) return;
    if (_activeBackdrop.parentNode) {
        _activeBackdrop.parentNode.removeChild(_activeBackdrop);
    }
    _activeBackdrop = null;
    if (_previouslyFocused && typeof _previouslyFocused.focus === 'function') {
        try { _previouslyFocused.focus(); } catch (e) { /* element may be detached */ }
    }
    _previouslyFocused = null;
}

// ─── Event handlers ────────────────────────────────────────────────────────────

function _onBackdropClick(e) {
    // Click on the backdrop itself (not the popup body) → close.
    if (e.target === _activeBackdrop) {
        closeDailyOverviewPopup();
        return;
    }
    // Close button.
    const closeBtn = e.target.closest('.do-popup-close');
    if (closeBtn) {
        closeDailyOverviewPopup();
        return;
    }
    // Deep-link anchor inside the popup body.
    const link = e.target.closest('.do-popup-deeplink');
    if (link) {
        e.preventDefault();
        const section = link.dataset.section;
        const targetId = link.dataset.targetId;
        closeDailyOverviewPopup();
        if (section) {
            switchSection(section);
            if (targetId) {
                console.debug('[do-popup] deep-link to', section, 'item:', targetId);
            }
        }
    }
}

function _onDocumentKeydown(e) {
    if (!_activeBackdrop) return;
    if (e.key === 'Escape') {
        e.preventDefault();
        closeDailyOverviewPopup();
    }
}

// ─── Shell + dispatcher ────────────────────────────────────────────────────────

function _popupAriaLabel(kind, item) {
    const title = item.details && item.details.title
        ? item.details.title
        : (item.title || 'Detail');
    return _kindLabel(kind) + ': ' + title;
}

function _kindLabel(kind) {
    switch (kind) {
        case 'kanban_todos':     return 'TODO';
        case 'kanban_items_due': return 'KANBAN ITEM';
        case 'change_requests':  return 'CHANGE REQUEST';
        case 'backup_failures':  return 'BACKUP STATUS';
        case 'calendar_items':   return 'CALENDAR ITEM';
        case 'releases':         return 'RELEASE';
        case 'alert':            return 'ALERT';
        default:                 return 'DETAIL';
    }
}

function _renderPopupShell(item, details, kind) {
    const heading = escapeHtml(_kindLabel(kind));
    const fullTitle = escapeHtml(String(details.title || item.title || ''));
    const bodyHtml = _renderPopupBody(item, details, kind);

    return (
        '<div class="do-popup" role="document">' +
            '<div class="do-popup-header">' +
                '<span class="do-popup-kind">' + heading + '</span>' +
                '<button class="do-popup-close" type="button" aria-label="Close">✕</button>' +
            '</div>' +
            '<h2 class="do-popup-title">' + fullTitle + '</h2>' +
            '<div class="do-popup-body">' + bodyHtml + '</div>' +
        '</div>'
    );
}

function _renderPopupBody(item, details, kind) {
    switch (kind) {
        case 'kanban_todos':     return _renderKanbanTodo(details, item);
        case 'kanban_items_due': return _renderKanbanItem(details, item);
        case 'change_requests':  return _renderChangeRequest(details, item);
        case 'backup_failures':  return _renderBackupFailure(details, item);
        case 'calendar_items':   return _renderCalendarItem(details, item);
        case 'releases':         return _renderRelease(details, item);
        case 'alert':            return _renderAlert(details, item);
        default:                 return _renderGeneric(details, item);
    }
}

// ─── Per-category renderers ────────────────────────────────────────────────────

function _renderKanbanTodo(d, item) {
    const rows = [
        _kvRow('ID', _kanbanLink(d.todo_id || item.id, 'todos')),
        _kvRow('Status', _statusPill(d.status || 'todo')),
        _kvRow('Priority', _priorityPill(d.priority)),
        _kvRow('Required by', _formatDate(d.required_by) || '—'),
        _kvRow('Created', _formatDateTime(d.created_at)),
    ];
    const text = d.text || item.title || '';
    return (
        _section('Description', '<p class="do-popup-text">' + _bodyHtml(text) + '</p>') +
        _section('Properties', _kvTable(rows))
    );
}

function _renderKanbanItem(d, item) {
    const rows = [
        _kvRow('ID', _kanbanLink(d.item_id || item.id, 'workflow')),
        _kvRow('Status', _statusPill(d.status)),
        _kvRow('Priority', _priorityPill(d.priority)),
        _kvRow('Platform', d.platform ? escapeHtml(String(d.platform)) : '—'),
        _kvRow('Due date', _formatDate(d.due_date) || '—'),
        _kvRow('Subitems', _subitemRatio(d.subitems_completed, d.subitems_total)),
        _kvRow('JIRA', d.jira_id ? escapeHtml(String(d.jira_id)) : '—'),
        _kvRow('GitHub', d.github_id ? escapeHtml(String(d.github_id)) : '—'),
    ];
    const desc = d.description || '';
    return (
        (desc
            ? _section('Description', '<p class="do-popup-text">' + _bodyHtml(desc) + '</p>')
            : '') +
        _section('Properties', _kvTable(rows))
    );
}

function _renderChangeRequest(d, item) {
    const rows = [
        _kvRow('CR ID', _kanbanLink(d.cr_id || item.id, 'change-req')),
        _kvRow('State', _statusPill(d.cr_state)),
        _kvRow('Type', d.cr_type ? escapeHtml(String(d.cr_type)) : '—'),
        _kvRow('Severity', _priorityPill(d.severity)),
        _kvRow('Customer', d.customer ? escapeHtml(String(d.customer)) : '—'),
        _kvRow('Target date', _formatDate(d.target_date) || '—'),
        _kvRow('Created', _formatDateTime(d.created_at)),
        _kvRow(
            'Linked item',
            d.linked_kanban_id
                ? _kanbanLink(d.linked_kanban_id, 'workflow')
                : '—'
        ),
    ];
    const summary = d.summary || '';
    return (
        (summary
            ? _section('Summary', '<p class="do-popup-text">' + _bodyHtml(summary) + '</p>')
            : '') +
        _section('Properties', _kvTable(rows))
    );
}

function _renderBackupFailure(d, item) {
    const rows = [
        _kvRow('Team', d.team ? escapeHtml(String(d.team)) : '—'),
        _kvRow('Status', _statusPill(d.overall_status || '—')),
        _kvRow('Severity', _priorityPill(d.severity)),
        _kvRow('Last run', _formatDateTime(d.last_run)),
        _kvRow('Stale', d.is_stale ? 'Yes (> 30m)' : 'No'),
    ];
    const errBlock = d.last_error
        ? _section('Error',
            '<pre class="do-popup-pre">' + escapeHtml(String(d.last_error)) + '</pre>')
        : '';
    return _section('Properties', _kvTable(rows)) + errBlock;
}

function _renderCalendarItem(d, item) {
    const sourceLabel = ({
        kanban_backlog: 'Kanban backlog item',
        kanban_epic:    'Kanban epic',
        team_calendar:  'Team calendar event',
    })[d.source] || (d.source || 'Calendar item');

    const targetSection = (d.source === 'kanban_backlog' || d.source === 'kanban_epic')
        ? 'workflow'
        : 'calendar';

    const eventOrItemId = d.event_id || d.item_id || item.id;
    const idCell = (d.source === 'kanban_backlog' || d.source === 'kanban_epic')
        ? _kanbanLink(eventOrItemId, targetSection)
        : escapeHtml(String(eventOrItemId || ''));

    const rows = [
        _kvRow('ID', idCell),
        _kvRow('Source', escapeHtml(sourceLabel)),
        _kvRow('Start', _formatDateTime(d.start) || _formatDate(d.due_date) || '—'),
        _kvRow('End', _formatDateTime(d.end) || '—'),
        _kvRow('All-day', d.all_day === false ? 'No' : (d.all_day === true ? 'Yes' : '—')),
        _kvRow('Priority', _priorityPill(d.priority)),
        _kvRow('Status', _statusPill(d.status)),
    ];
    return _section('Properties', _kvTable(rows));
}

function _renderRelease(d, item) {
    const envChips = _envChips(d.environments);
    const rows = [
        _kvRow('Release ID', _kanbanLink(d.release_id || item.id, 'releases')),
        _kvRow('Status', _statusPill(d.status)),
        _kvRow('Severity', _priorityPill(d.severity)),
        _kvRow('Target date', _formatDate(d.target_date) || '—'),
        _kvRow('Short title', d.short_title ? escapeHtml(String(d.short_title)) : '—'),
    ];
    return (
        _section('Properties', _kvTable(rows)) +
        (envChips ? _section('Environments', envChips) : '')
    );
}

function _renderAlert(d, item) {
    const metaText = (d.metadata && Object.keys(d.metadata).length)
        ? JSON.stringify(d.metadata, null, 2)
        : '';
    const rows = [
        _kvRow('Alert ID', escapeHtml(String(d.alert_id || item.id || ''))),
        _kvRow('Source', d.source ? escapeHtml(String(d.source)) : '—'),
        _kvRow('Severity', _priorityPill(d.severity || item.severity_or_priority)),
        _kvRow('Category', d.category ? escapeHtml(String(d.category)) : '—'),
        _kvRow('Accepted', _formatDateTime(d.accepted_at)),
        _kvRow('Expires', _formatDateTime(d.expires_at)),
        _kvRow('Dedupe key', d.dedupe_key ? escapeHtml(String(d.dedupe_key)) : '—'),
        _kvRow(
            'Link',
            d.link
                ? '<code class="do-popup-mono">' + escapeHtml(String(d.link)) + '</code>'
                : '—'
        ),
    ];
    const bodyBlock = d.body
        ? _section('Body', '<p class="do-popup-text">' + _bodyHtml(d.body) + '</p>')
        : '';
    const metaBlock = metaText
        ? _section('Metadata',
            '<pre class="do-popup-pre">' + escapeHtml(metaText) + '</pre>')
        : '';
    return bodyBlock + _section('Properties', _kvTable(rows)) + metaBlock;
}

function _renderGeneric(d, item) {
    // Fallback: dump non-trivial details as a key/value table.
    const rows = Object.keys(d || {})
        .filter(function (k) { return k !== 'kind'; })
        .map(function (k) {
            const v = d[k];
            const display = (v === null || v === undefined || v === '')
                ? '—'
                : (typeof v === 'object' ? JSON.stringify(v) : String(v));
            return _kvRow(k, escapeHtml(display));
        });
    if (!rows.length) {
        return '<p class="do-popup-text">' +
            escapeHtml(String(item.title || '(no detail provided)')) +
            '</p>';
    }
    return _section('Properties', _kvTable(rows));
}

// ─── Cell / fragment helpers ───────────────────────────────────────────────────

function _section(label, innerHtml) {
    return (
        '<section class="do-popup-section">' +
            '<h3 class="do-popup-section-label">' + escapeHtml(label) + '</h3>' +
            innerHtml +
        '</section>'
    );
}

function _kvTable(rows) {
    return '<dl class="do-popup-kv">' + rows.join('') + '</dl>';
}

function _kvRow(key, valueHtml) {
    return (
        '<dt>' + escapeHtml(key) + '</dt>' +
        '<dd>' + (valueHtml === undefined || valueHtml === null || valueHtml === '' ? '—' : valueHtml) + '</dd>'
    );
}

function _statusPill(status) {
    if (!status) return '—';
    const s = String(status);
    const cls = 'do-popup-pill do-popup-status-' + escapeHtml(s.toLowerCase().replace(/[^a-z0-9_-]/g, '-'));
    return '<span class="' + cls + '">' + escapeHtml(s.toUpperCase()) + '</span>';
}

function _priorityPill(priority) {
    if (!priority) return '—';
    const p = String(priority).toLowerCase();
    const cls = 'do-popup-pill do-popup-prio-' + escapeHtml(p);
    return '<span class="' + cls + '">' + escapeHtml(p.toUpperCase()) + '</span>';
}

function _subitemRatio(done, total) {
    if (typeof total !== 'number' || total <= 0) return '—';
    const d = (typeof done === 'number') ? done : 0;
    return escapeHtml(d + ' / ' + total);
}

function _envChips(environments) {
    if (!environments || typeof environments !== 'object') return '';
    const keys = Object.keys(environments);
    if (!keys.length) return '';
    return '<div class="do-popup-env-chips">' + keys.map(function (envKey) {
        const env = environments[envKey] || {};
        const status = env.status || (env.completed ? 'completed' : (env.enabled ? 'pending' : 'off'));
        const cls = 'do-popup-env-chip do-popup-env-' + escapeHtml(String(status).toLowerCase());
        return '<span class="' + cls + '">' +
            escapeHtml(envKey) + ' · ' + escapeHtml(String(status)) +
        '</span>';
    }).join('') + '</div>';
}

// ─── Body / link helpers ───────────────────────────────────────────────────────

/**
 * Linkify kanban-style IDs (XACA-NNNN, MEAPP-NNNN, EPIC-NNNN, REL-NNNN, etc.)
 * inside a body string.  IDs become `<a class="do-popup-deeplink">` so the
 * delegated handler intercepts them.  All other text is escaped.
 *
 * Defaults to `workflow` section for matched IDs; alert/CR rendering can
 * override by linking the primary ID separately above the body.
 */
function _bodyHtml(text) {
    if (!text) return '';
    const str = String(text);
    const out = [];
    const re = /[A-Z][A-Z0-9]+-\d{1,6}/g;
    let last = 0;
    let m;
    while ((m = re.exec(str)) !== null) {
        out.push(escapeHtml(str.slice(last, m.index)));
        out.push(_kanbanLink(m[0], _sectionForId(m[0])));
        last = m.index + m[0].length;
    }
    out.push(escapeHtml(str.slice(last)));
    // Preserve newlines from raw bodies (alert.body, descriptions).
    return out.join('').replace(/\n/g, '<br>');
}

function _sectionForId(id) {
    const upper = String(id || '').toUpperCase();
    if (upper.startsWith('REL-'))   return 'releases';
    if (upper.startsWith('EPIC-'))  return 'workflow';
    if (upper.startsWith('CR-'))    return 'change-req';
    return 'workflow';
}

function _kanbanLink(id, section) {
    if (!id) return '—';
    const safeId = escapeHtml(String(id));
    const safeSection = escapeHtml(String(section || 'workflow'));
    return (
        '<a href="#" class="do-popup-deeplink"' +
            ' data-section="' + safeSection + '"' +
            ' data-target-id="' + safeId + '">' +
            safeId +
        '</a>'
    );
}

// ─── Date formatting ───────────────────────────────────────────────────────────

/**
 * Format an ISO timestamp as "YYYY-MM-DD HH:MM UTC".  Returns "" on falsy.
 */
function _formatDateTime(iso) {
    if (!iso) return '';
    const s = String(iso);
    // Compact: take "YYYY-MM-DDTHH:MM:SS..." → "YYYY-MM-DD HH:MM"
    const date = s.slice(0, 10);
    const time = s.slice(11, 16);
    if (!time) return escapeHtml(date);
    return escapeHtml(date + ' ' + time + ' UTC');
}

function _formatDate(s) {
    if (!s) return '';
    return escapeHtml(String(s).slice(0, 10));
}
