//
//  lcars-division-collapse.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * LCARS Fleet Monitor — collapsible divisions + compact session chips.
 *
 * XACA-0989. THE SINGLE implementation of the collapsed/expanded division
 * renderer, following the XACA-0970 (lcars-org-resolution.js) precedent:
 * before that ticket, division→organization resolution was copy-pasted into
 * every dashboard and drifted. This module exists so the NEW collapse/chip
 * behavior is never implemented five times either.
 *
 * Design contract (XACA-0989-001, UX-gate ratified, locked):
 *   Q1 persistence — localStorage key 'lcars-orgs-expanded', EXCEPTIONS only
 *     (stores the array of EXPANDED division ids; absent = collapsed). A
 *     stale/corrupt value fails safe to "all collapsed", and a newly
 *     provisioned division needs no migration.
 *   Q2 toggle scope — per-division header click AND a global Expand All /
 *     Collapse All control, both funnelled through this module's single
 *     source of truth. Divisions only — organization panels never collapse.
 *   Q3 chip sizing — fixed width (172px), column count emergent via
 *     flex-wrap. Deliberately NOT pinned breakpoints (that produced the
 *     "which iPad you own" cliff XACA-0973/XACA-0976 had to patch).
 *   Q4 terminal icon — new, decorative, conveys "is a terminal" (shown on
 *     every chip). "Which type" (LCARS vs not) stays on the EXISTING
 *     .lcars-badge mechanism, gated by isLcarsTerminal() same as the
 *     expanded card — one type-signal mechanism, not two.
 *   Q5 overflow — ellipsis + title tooltip, min-width:0 declared explicitly
 *     on every flex child in the chip chain from the first commit.
 *
 * 600px collapse floor (user-ratified scope addition, post-lock):
 *   Below 600px viewport width, divisions always render expanded (the
 *   existing .team-card grid) and the chip/collapse mechanism does not
 *   exist. This is a PRESENTATION override only — it never reads from or
 *   writes to the persisted 'lcars-orgs-expanded' array, so state set on a
 *   wide viewport survives a visit from a narrow one. The floor is reactive
 *   via matchMedia + a change listener (not a one-shot width read), so a
 *   resize/rotation crosses it live without a reload. The toggle affordance
 *   (per-division header cursor/role/chevron, and the global button) is
 *   hidden below the floor rather than left visible-but-inert.
 *
 * The expanded view itself (.team-card / createTeamCard) is NOT owned here
 * and is NOT flattened across skins — the lcars skin's version is richer
 * (avatar stack) than the lcars2 skin's. Callers inject their own
 * createTeamCard; this module only owns the NEW chip + collapse mechanism.
 */
(function (global) {
    'use strict';

    var STORAGE_KEY = 'lcars-orgs-expanded';
    var FLOOR_QUERY = '(min-width: 600px)';

    // ------------------------------------------------------------------
    // Persistence (Q1) — store EXPANDED exceptions only.
    // ------------------------------------------------------------------

    function readExpanded() {
        try {
            var v = JSON.parse(localStorage.getItem(STORAGE_KEY));
            return Array.isArray(v) ? v : [];
        } catch (e) {
            return [];
        }
    }

    function writeExpanded(arr) {
        try {
            localStorage.setItem(STORAGE_KEY, JSON.stringify(arr));
        } catch (e) {
            /* non-fatal, silent */
        }
    }

    function isExpanded(divisionId) {
        return readExpanded().indexOf(divisionId) !== -1;
    }

    function setExpanded(divisionId, expanded) {
        var arr = readExpanded();
        var idx = arr.indexOf(divisionId);
        if (expanded && idx === -1) {
            arr.push(divisionId);
            writeExpanded(arr);
            notifyStateChange();
        } else if (!expanded && idx !== -1) {
            arr.splice(idx, 1);
            writeExpanded(arr);
            notifyStateChange();
        }
    }

    function expandAll(divisionIds) {
        writeExpanded((divisionIds || []).slice());
        notifyStateChange();
    }

    function collapseAll() {
        writeExpanded([]);
        notifyStateChange();
    }

    // ------------------------------------------------------------------
    // 600px collapse floor — presentation-only, reactive.
    // ------------------------------------------------------------------

    var mql = (typeof window !== 'undefined' && typeof window.matchMedia === 'function')
        ? window.matchMedia(FLOOR_QUERY)
        : null;
    var aboveFloor = mql ? mql.matches : true; // fail open: no matchMedia => no floor imposed

    function handleFloorChange(e) {
        aboveFloor = e.matches;
        notifyStateChange();
    }

    if (mql) {
        if (typeof mql.addEventListener === 'function') {
            mql.addEventListener('change', handleFloorChange);
        } else if (typeof mql.addListener === 'function') {
            // Safari <14 fallback
            mql.addListener(handleFloorChange);
        }
    }

    function isAboveFloor() {
        return aboveFloor;
    }

    // ------------------------------------------------------------------
    // Render-pass bookkeeping. Divisions rebuild from scratch on every
    // fleet poll (container.innerHTML = ''), so `controllers` is reset at
    // the start of each pass and repopulated as panels are wired.
    // `sectionRefreshers` (the Expand All / Collapse All button's refresh
    // fn) is wired ONCE per page load and persists across passes.
    // ------------------------------------------------------------------

    var controllers = [];
    var sectionRefreshers = [];

    function notifyStateChange() {
        controllers.forEach(function (c) {
            try { c.applyState(); } catch (e) { /* ignore a detached/broken panel */ }
        });
        sectionRefreshers.forEach(function (fn) {
            try { fn(); } catch (e) { /* ignore */ }
        });
    }

    function beginRenderPass() {
        controllers = [];
    }

    function endRenderPass() {
        sectionRefreshers.forEach(function (fn) {
            try { fn(); } catch (e) { /* ignore */ }
        });
    }

    // ------------------------------------------------------------------
    // Compact session chip (Q3/Q4/Q5).
    // ------------------------------------------------------------------

    // 14x14, decorative, conveys "is a terminal" -- not which type (that's
    // the existing .lcars-badge, gated separately below).
    var TERMINAL_ICON_SVG =
        '<svg class="chip-icon" width="14" height="14" viewBox="0 0 14 14" fill="none" ' +
        'stroke="currentColor" stroke-width="1.3" aria-hidden="true">' +
        '<rect x="1" y="1.5" width="12" height="9" rx="1.2"></rect>' +
        '<path d="M3.2 4.4 L5.2 6.1 L3.2 7.8 M6.6 7.8 L9 7.8" stroke-linecap="round" stroke-linejoin="round"></path>' +
        '</svg>';

    /**
     * helpers: { isLcarsTerminal: fn(data)->bool, getLcarsUrl: fn(data)->string|null }
     * injected per-caller so this module doesn't re-implement per-skin
     * terminal detection (both skins already define these identically).
     */
    function createSessionChip(name, data, helpers) {
        var isLcarsFn = helpers && helpers.isLcarsTerminal;
        var getUrlFn = helpers && helpers.getLcarsUrl;

        var chip = document.createElement('div');
        var isLcars = isLcarsFn ? !!isLcarsFn(data) : false;
        chip.className = isLcars ? 'session-chip lcars-terminal' : 'session-chip';

        var session = data && data.sessions && data.sessions[0];
        var svc = data && data.lcars_service;
        var status;
        if (session) {
            status = session.machine_status || 'offline';
        } else if (svc) {
            // XACA-0983 parity (fix (b)): a team can be a healthy LCARS
            // terminal with NO live tmux session -- e.g. a health-check
            // self-heal killed the session while the service kept serving.
            // Before this branch existed the chip hardcoded 'offline' here
            // and told the operator a running service was down, while the
            // expanded card (createServiceOnlyLcarsCard) correctly reported
            // REACHABLE. Two views of one team disagreeing, in the view this
            // ticket makes the DEFAULT.
            //
            // `=== true` deliberately, matching createServiceOnlyLcarsCard:
            // reachable false AND null both render unreachable, because null
            // means the probe was skipped or curl was unavailable. This UI
            // never claims health it did not actually observe.
            status = (svc.reachable === true) ? 'online' : 'offline';
        } else {
            status = 'offline';
        }
        var isOnline = status === 'online';

        chip.title = name;

        // XACA-0989 / XACA-0416: build the chip with DOM APIs, NOT innerHTML
        // concatenation. `name` and `status` both originate from POST
        // /api/team-register, which server.js validates for PRESENCE only, and
        // fleet-monitor sets no CSP. The expanded card's createTeamCard() still
        // concatenates these into innerHTML -- that is the open high-priority
        // defect XACA-0416 owns across all 5 app files. Do NOT copy that shape
        // here: textContent cannot be escaped out of, so this chip stays safe
        // regardless of what escaper XACA-0416 settles on.
        // Parse the static icon via <template> and append the real <svg
        // class="chip-icon"> node, so the chip's direct flex children are
        // EXACTLY as before this hardening: icon / name / badge / dot. A
        // wrapper span here would become an undeclared flex child
        // (flex-shrink defaulting to 1) and silently break the shrink
        // discipline the .chip-icon rule establishes.
        var iconTpl = document.createElement('template');
        iconTpl.innerHTML = TERMINAL_ICON_SVG;    // static module constant, no interpolation
        if (iconTpl.content.firstElementChild) {
            chip.appendChild(iconTpl.content.firstElementChild);
        }

        var nameSpan = document.createElement('span');
        nameSpan.className = 'chip-name';
        nameSpan.textContent = name;              // untrusted -- never innerHTML
        chip.appendChild(nameSpan);

        if (isLcars) {
            var badgeSpan = document.createElement('span');
            badgeSpan.className = 'lcars-badge';
            badgeSpan.textContent = 'LCARS';
            chip.appendChild(badgeSpan);
        }

        var statusSpan = document.createElement('span');
        // className is a DOM property assignment, not markup -- an attacker
        // cannot break out of it the way they could out of an innerHTML string.
        statusSpan.className = 'status-indicator ' + status;
        chip.appendChild(statusSpan);

        if (session && session.theme_color && !isLcars) {
            chip.style.borderLeft = '3px solid ' + session.theme_color;
        }

        if (isLcars && getUrlFn) {
            var lcarsUrl = getUrlFn(data);
            if (lcarsUrl && isOnline) {
                chip.classList.add('lcars-clickable');
                chip.title = 'Click to open LCARS terminal: ' + lcarsUrl;
                chip.addEventListener('click', function () {
                    window.open(lcarsUrl, '_blank');
                });
                // XACA-0983-014 parity: a clickable div is mouse-only unless
                // it is also focusable and keyboard-activatable. The chip had
                // the same gap the expanded card had before XACA-0983 fixed
                // it -- inherited by copying the pre-fix shape. Only this
                // branch is actionable; the non-clickable branches below
                // deliberately get NO tabindex and NO role, because an element
                // that is not actionable must not claim to be. XACA-0983's
                // tests assert exactly that for the card; same rule here.
                chip.setAttribute('tabindex', '0');
                chip.setAttribute('role', 'button');
                chip.addEventListener('keydown', function (evt) {
                    if (evt.key === 'Enter' || evt.key === ' ' ||
                        evt.key === 'Spacebar' ||
                        evt.keyCode === 13 || evt.keyCode === 32) {
                        evt.preventDefault();
                        window.open(lcarsUrl, '_blank');
                    }
                });
            } else if (lcarsUrl && !isOnline && !session && svc) {
                // Service-only AND unreachable: say what is actually known.
                // "machine is offline" is wrong here -- there is no machine
                // session to be offline; a service was reported and did not
                // answer. Wording matches createServiceOnlyLcarsCard.
                chip.classList.add('lcars-offline');
                chip.title = 'LCARS terminal service is reported but not reachable';
            } else if (lcarsUrl && !isOnline) {
                // XACA-0979 parity: match the expanded card's offline treatment.
                chip.classList.add('lcars-offline');
                chip.title = 'LCARS terminal unavailable - machine is ' + status;
            } else if (!lcarsUrl) {
                chip.classList.add('lcars-offline');
                chip.title = 'LCARS terminal misconfigured - no hostname reported for this session';
            }
        }

        return chip;
    }

    function buildChipRow(teamEntries, helpers) {
        var row = document.createElement('div');
        row.className = 'chip-row';
        (teamEntries || []).forEach(function (entry) {
            row.appendChild(createSessionChip(entry[0], entry[1], helpers));
        });
        return row;
    }

    // ------------------------------------------------------------------
    // Per-division toggle wiring (Q2).
    // ------------------------------------------------------------------

    /**
     * panel:    the .division-container element (panel.id is the existing
     *           'div-' + slug scheme -- reused as the persistence key).
     * header:   the .division-header element; must already contain a
     *           '.division-toggle-icon' span in its innerHTML (empty text,
     *           filled in here) for the chevron affordance.
     * chipRow:  the collapsed-view element from buildChipRow(), or null.
     * cardsGrid: the existing (unchanged) .teams-grid expanded-view element.
     */
    function wireDivisionToggle(panel, header, chipRow, cardsGrid) {
        var divisionId = panel.id;

        function applyState() {
            var interactive = aboveFloor; // below the 600px floor, always expanded, no affordance
            var expanded = interactive ? isExpanded(divisionId) : true;

            panel.classList.toggle('division-expanded', expanded);
            panel.classList.toggle('division-collapsed', !expanded);
            header.classList.toggle('division-header-toggle', interactive);

            if (interactive) {
                header.setAttribute('role', 'button');
                header.setAttribute('tabindex', '0');
                header.setAttribute('aria-expanded', expanded ? 'true' : 'false');
            } else {
                header.removeAttribute('role');
                header.removeAttribute('tabindex');
                header.removeAttribute('aria-expanded');
            }

            var icon = header.querySelector('.division-toggle-icon');
            if (icon) {
                icon.style.display = interactive ? '' : 'none';
                icon.textContent = expanded ? '▾' : '▸';
            }

            if (chipRow) {
                chipRow.style.display = (interactive && !expanded) ? '' : 'none';
            }
            if (cardsGrid) {
                cardsGrid.style.display = expanded ? '' : 'none';
            }
        }

        function toggle() {
            if (!aboveFloor) return; // no affordance shown below the floor; defensive no-op
            setExpanded(divisionId, !isExpanded(divisionId));
        }

        header.addEventListener('click', toggle);
        header.addEventListener('keydown', function (e) {
            if (e.key === 'Enter' || e.key === ' ' || e.key === 'Spacebar') {
                e.preventDefault();
                toggle();
            }
        });

        applyState(); // initial paint for this render pass

        var controller = { applyState: applyState, divisionId: divisionId };
        controllers.push(controller);
        return controller;
    }

    // ------------------------------------------------------------------
    // Global Expand All / Collapse All control (Q2).
    // ------------------------------------------------------------------

    /**
     * Wires the control ONCE per page (idempotent — repeat calls no-op).
     * sectionHeader: the .section-header element to append the button into
     *   (e.g. the ORGANIZATIONS section's header, sibling of
     *   #divisions-container).
     */
    function wireExpandCollapseAll(sectionHeader) {
        if (!sectionHeader || sectionHeader.__lcarsExpandAllWired) return null;
        sectionHeader.__lcarsExpandAllWired = true;

        var btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'division-expand-all-toggle';

        function currentIds() {
            return controllers.map(function (c) { return c.divisionId; });
        }

        function refresh() {
            btn.style.display = aboveFloor ? '' : 'none'; // hidden below the 600px floor
            if (!aboveFloor) return;
            var ids = currentIds();
            var allExpanded = ids.length > 0 && ids.every(isExpanded);
            btn.textContent = allExpanded ? 'COLLAPSE ALL' : 'EXPAND ALL';
        }

        btn.addEventListener('click', function () {
            if (!aboveFloor) return; // hidden anyway; defensive no-op
            var ids = currentIds();
            var allExpanded = ids.length > 0 && ids.every(isExpanded);
            if (allExpanded) {
                collapseAll();
            } else {
                expandAll(ids);
            }
        });

        sectionHeader.appendChild(btn);
        sectionRefreshers.push(refresh);
        refresh();

        return { refresh: refresh };
    }

    var API = {
        STORAGE_KEY: STORAGE_KEY,
        isExpanded: isExpanded,
        setExpanded: setExpanded,
        expandAll: expandAll,
        collapseAll: collapseAll,
        isAboveFloor: isAboveFloor,
        createSessionChip: createSessionChip,
        buildChipRow: buildChipRow,
        beginRenderPass: beginRenderPass,
        endRenderPass: endRenderPass,
        wireDivisionToggle: wireDivisionToggle,
        wireExpandCollapseAll: wireExpandCollapseAll
    };

    global.LCARS_DIVISIONS = API;
})(typeof window !== 'undefined' ? window : this);
