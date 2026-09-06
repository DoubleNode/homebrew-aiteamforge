//
//  lcars-academy-config.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * XACA-1110: per-org config for the unified lcars2 fleet dashboard module
 * (lcars-fleet-dashboard-app.js) -- Academy filtered view.
 *
 * MUST be loaded via <script> BEFORE lcars-fleet-dashboard-app.js (script
 * tag order matters -- see the design decision doc, D5/D6). Sets
 * window.LCARS_DASHBOARD_CONFIG, a consumer-side input the unified module
 * reads; this file carries no logic of its own and defines no exports.
 *
 * D5 hard constraint: the unified module contains NO org registry -- every
 * dashboard's identity lives in its own config file like this one, never in
 * the shared module. Do not add doublenode/mainevent data here.
 */

window.LCARS_DASHBOARD_CONFIG = {
    divisions: ['academy'],
    dashboardName: 'ACADEMY',
    emptyMessage: 'No active Academy sessions detected',
    machinesEmptyMessage: 'No machines detected',
    candySection: 'overview',
    unmappedOrgColor: 'org-academy'
};
