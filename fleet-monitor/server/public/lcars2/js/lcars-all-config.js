//
//  lcars-all-config.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1110: per-org config for the unified lcars2 fleet dashboard module
 * (lcars-fleet-dashboard-app.js) -- All Fleet unfiltered view.
 *
 * MUST be loaded via <script> BEFORE lcars-fleet-dashboard-app.js (script
 * tag order matters -- see the design decision doc, D5/D6). Sets
 * window.LCARS_DASHBOARD_CONFIG, a consumer-side input the unified module
 * reads; this file carries no logic of its own and defines no exports.
 *
 * `divisions: null` is the D1 signal for "unbounded" -- the unified module
 * derives `isUnbounded` from this and renders every division the API
 * returns (sourcing division ordering from a live /api/team-config fetch)
 * instead of filtering to a fixed set.
 */

window.LCARS_DASHBOARD_CONFIG = {
    divisions: null, // null = no filtering, show all (D1: isUnbounded)
    dashboardName: 'ALL FLEET',
    emptyMessage: 'No active divisions detected',
    machinesEmptyMessage: 'No machines detected',
    candySection: 'overview',
    unmappedOrgColor: 'org-academy'
};
