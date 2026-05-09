//
//  lcars-dashboards-ui.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * LCARS Dashboards Admin UI Module
 * Handles dashboard configuration management in the ADMIN section.
 *
 * Features:
 * - List all dashboards with system/custom distinction
 * - Create new dashboards
 * - Edit existing dashboards
 * - Delete dashboards (with system protection)
 * - Division multi-select assignment
 * - Toast notifications for feedback
 */

const DASHBOARDS_UI = {
    // API endpoints
    apiBase: '/api/dashboards',
    divisionsApi: '/api/active-divisions',
    machinesApi: '/api/machines/list',

    // State
    dashboards: [],
    divisions: [],
    machines: [],
    selectedDashboard: null,
    isEditing: false,
    isNewDashboard: false,
    draggedItem: null,
    draggedOverItem: null,

    // Available org colors
    orgColors: [
        { id: 'lavender', label: 'Lavender' },
        { id: 'blue', label: 'Blue' },
        { id: 'cyan', label: 'Cyan' },
        { id: 'purple', label: 'Purple' },
        { id: 'orange', label: 'Orange' },
        { id: 'red', label: 'Red' },
        { id: 'crimson', label: 'Crimson' },
        { id: 'tan', label: 'Tan' },
        { id: 'peach', label: 'Peach' },
        { id: 'green', label: 'Green' }
    ],

    /**
     * Initialize the dashboards UI
     * Called when the ADMIN section is loaded
     */
    async init() {
        console.log('[DASHBOARDS] Initializing dashboards admin UI...');

        // Create toast container if it doesn't exist
        if (!document.querySelector('.toast-container')) {
            const toastContainer = document.createElement('div');
            toastContainer.className = 'toast-container';
            document.body.appendChild(toastContainer);
        }

        // Load data
        await Promise.all([
            this.loadDashboards(),
            this.loadDivisions(),
            this.loadMachines()
        ]);

        // Render the UI
        this.render();
    },

    /**
     * Load all dashboards from API
     */
    async loadDashboards() {
        try {
            const response = await fetch(this.apiBase);
            const data = await response.json();
            this.dashboards = data.dashboards || [];
            console.log(`[DASHBOARDS] Loaded ${this.dashboards.length} dashboards`);
        } catch (error) {
            console.error('[DASHBOARDS] Error loading dashboards:', error);
            this.showToast('Failed to load dashboards', 'error');
        }
    },

    /**
     * Load all divisions from API (active divisions from fleet data)
     */
    async loadDivisions() {
        try {
            const response = await fetch(this.divisionsApi);
            const data = await response.json();
            this.divisions = data.divisions || [];
            console.log(`[DASHBOARDS] Loaded ${this.divisions.length} active divisions`);
        } catch (error) {
            console.error('[DASHBOARDS] Error loading divisions:', error);
            this.showToast('Failed to load divisions', 'error');
        }
    },

    /**
     * Load all machines from API
     */
    async loadMachines() {
        try {
            const response = await fetch(this.machinesApi);
            const data = await response.json();
            this.machines = data.machines || [];
            console.log(`[DASHBOARDS] Loaded ${this.machines.length} machines (${data.online} online)`);
        } catch (error) {
            console.error('[DASHBOARDS] Error loading machines:', error);
            this.showToast('Failed to load machines', 'error');
        }
    },

    /**
     * Render the complete admin UI
     */
    render() {
        console.log('[DASHBOARDS] render() called, order:', this.dashboards.map(d => d.id).join(', '));

        const container = document.getElementById('admin-content');
        if (!container) {
            console.error('[DASHBOARDS] Admin content container not found');
            return;
        }

        const listHtml = this.renderListPanel();
        const editorHtml = this.renderEditorPanel();
        const modalHtml = this.renderDeleteModal();

        console.log('[DASHBOARDS] Setting innerHTML...');

        container.innerHTML = `
            <div class="admin-container">
                ${listHtml}
                ${editorHtml}
            </div>
            ${modalHtml}
        `;

        console.log('[DASHBOARDS] innerHTML set, binding events...');

        // Bind events
        this.bindEvents();

        console.log('[DASHBOARDS] render() complete');
    },

    /**
     * Render the dashboard list panel
     */
    renderListPanel() {
        console.log('[DASHBOARDS] renderListPanel, dashboards:', this.dashboards.map(d => d.id));
        const listItems = this.dashboards.map((d, i) => this.renderDashboardCard(d, i)).join('');

        return `
            <div class="dashboard-list-panel">
                <div class="panel-header">
                    <span class="panel-title">DASHBOARDS</span>
                    <button class="btn-lcars btn-lcars-new" onclick="DASHBOARDS_UI.createNew()">+ NEW</button>
                </div>
                <div class="dashboard-list" id="dashboard-list">
                    ${listItems || this.renderEmptyState()}
                </div>
            </div>
        `;
    },

    /**
     * Render a single dashboard card
     */
    renderDashboardCard(dashboard, index) {
        const isSelected = this.selectedDashboard?.id === dashboard.id;
        const divisionCount = (dashboard.divisions || []).length;
        const divisionLabel = divisionCount === 0 ? 'ALL' : `${divisionCount} DIV`;
        const orgColor = dashboard.org_color || 'lavender';

        return `
            <div class="dashboard-card ${isSelected ? 'selected' : ''} ${dashboard.system ? 'system' : ''}"
                 data-id="${dashboard.id}"
                 data-index="${index}"
                 draggable="true"
                 style="border-left: 4px solid var(--lcars-${orgColor});"
                 onclick="DASHBOARDS_UI.selectDashboard('${dashboard.id}')">
                <div class="drag-handle" title="Drag to reorder">&#x2630;</div>
                <div class="dashboard-card-info">
                    <span class="dashboard-card-name" style="color: var(--lcars-${orgColor});">${this.escapeHtml(dashboard.name)}</span>
                    <span class="dashboard-card-path">${dashboard.url_path}</span>
                </div>
                <div class="dashboard-card-badges">
                    <span class="color-swatch ${orgColor}" style="width: 14px; height: 14px; border-radius: 2px;"></span>
                    ${dashboard.system ? '<span class="badge-system">SYSTEM</span>' : ''}
                    <span class="badge-divisions">${divisionLabel}</span>
                </div>
            </div>
        `;
    },

    /**
     * Render empty state for list
     */
    renderEmptyState() {
        return `
            <div class="empty-state">
                <div class="empty-state-icon">&#x1F4CA;</div>
                <div class="empty-state-title">NO DASHBOARDS</div>
                <div class="empty-state-text">Click "+ NEW" to create a dashboard</div>
            </div>
        `;
    },

    /**
     * Render the editor panel
     */
    renderEditorPanel() {
        if (!this.selectedDashboard && !this.isNewDashboard) {
            return `
                <div class="dashboard-editor-panel">
                    <div class="panel-header">
                        <span class="panel-title">EDITOR</span>
                    </div>
                    <div class="editor-content">
                        <div class="editor-placeholder">
                            <div class="editor-placeholder-icon">&#x270F;</div>
                            <div class="editor-placeholder-text">Select a dashboard to edit<br>or create a new one</div>
                        </div>
                    </div>
                </div>
            `;
        }

        const d = this.selectedDashboard || {
            name: '',
            title: '',
            subtitle: 'OPERATIONS MONITOR',
            description: '',
            divisions: [],
            machines: [],
            org_color: 'lavender',
            system: false
        };

        const isSystem = d.system;
        const headerTitle = this.isNewDashboard ? 'NEW DASHBOARD' : 'EDIT DASHBOARD';

        return `
            <div class="dashboard-editor-panel">
                <div class="panel-header">
                    <span class="panel-title">${headerTitle}</span>
                </div>
                <div class="editor-content">
                    <form id="dashboard-form" onsubmit="DASHBOARDS_UI.saveDashboard(event)">
                        <div class="form-group">
                            <label class="form-label">Name *</label>
                            <input type="text" class="form-input" id="dash-name"
                                   value="${this.escapeHtml(d.name)}"
                                   placeholder="My Dashboard"
                                   ${isSystem ? 'disabled' : ''}
                                   required>
                        </div>

                        <div class="form-group">
                            <label class="form-label">Title</label>
                            <input type="text" class="form-input" id="dash-title"
                                   value="${this.escapeHtml(d.title || '')}"
                                   placeholder="DASHBOARD TITLE"
                                   ${isSystem ? 'disabled' : ''}>
                        </div>

                        <div class="form-group">
                            <label class="form-label">Subtitle</label>
                            <input type="text" class="form-input" id="dash-subtitle"
                                   value="${this.escapeHtml(d.subtitle || '')}"
                                   placeholder="OPERATIONS MONITOR"
                                   ${isSystem ? 'disabled' : ''}>
                        </div>

                        <div class="form-group">
                            <label class="form-label">Description</label>
                            <textarea class="form-textarea" id="dash-description"
                                      placeholder="Dashboard description..."
                                      ${isSystem ? 'disabled' : ''}>${this.escapeHtml(d.description || '')}</textarea>
                        </div>

                        <div class="form-group">
                            <label class="form-label">Organization Color</label>
                            ${this.renderColorPicker(d.org_color, false)}
                        </div>

                        ${d.id === 'all' ? `
                            <div class="form-group">
                                <label class="form-label">Divisions Filter</label>
                                <p style="color: var(--lcars-cyan); font-size: 12px;">
                                    &#x1F310; The ALL FLEET dashboard always shows all divisions.<br>
                                    Division filtering is not available for this dashboard.
                                </p>
                            </div>
                            <div class="form-group">
                                <label class="form-label">Machines Filter</label>
                                <p style="color: var(--lcars-cyan); font-size: 12px;">
                                    &#x1F310; The ALL FLEET dashboard always shows all machines.<br>
                                    Machine filtering is not available for this dashboard.
                                </p>
                            </div>
                            <div class="form-group">
                                <label class="form-label">ALL FLEET Link Visibility</label>
                                <p style="color: var(--lcars-tan); font-size: 11px; margin-bottom: 10px;">
                                    Select which dashboards show the ALL FLEET button in their sidebar:
                                </p>
                                ${this.renderAllFleetLinkCheckboxes(d.show_all_fleet_on || [])}
                            </div>
                        ` : `
                            <div class="form-group">
                                <label class="form-label">Divisions Filter</label>
                                ${this.renderDivisionCheckboxes(d.divisions || [], isSystem)}
                                <p class="division-note">Leave all unchecked to show ALL divisions</p>
                            </div>
                            <div class="form-group">
                                <label class="form-label">Machines Filter</label>
                                ${this.renderMachineCheckboxes(d.machines || [], isSystem)}
                                <p class="division-note">Leave all unchecked to show ALL machines</p>
                            </div>
                            <div class="form-group">
                                <label class="form-label">Dashboard Visibility</label>
                                <p style="color: var(--lcars-tan); font-size: 11px; margin-bottom: 10px;">
                                    Select which dashboards appear in this dashboard's sidebar and settings:
                                </p>
                                ${this.renderVisibilityCheckboxes(d.visible_dashboards)}
                                <p class="division-note">Leave all checked to show ALL dashboards</p>
                            </div>
                        `}

                        ${isSystem ? `
                            <div class="form-group">
                                <p style="color: var(--lcars-purple); font-size: 12px;">
                                    &#x1F512; System dashboards cannot be modified or deleted.
                                </p>
                            </div>
                        ` : ''}

                        <div class="button-group button-group-spread">
                            ${!isSystem && !this.isNewDashboard ? `
                                <button type="button" class="btn-lcars btn-lcars-danger"
                                        onclick="DASHBOARDS_UI.confirmDelete()">DELETE</button>
                            ` : '<div></div>'}
                            <div style="display: flex; gap: 10px;">
                                <button type="button" class="btn-lcars btn-lcars-secondary"
                                        onclick="DASHBOARDS_UI.cancelEdit()">CANCEL</button>
                                ${(!isSystem || d.id === 'all') ? `
                                    <button type="submit" class="btn-lcars btn-lcars-primary">SAVE</button>
                                ` : ''}
                            </div>
                        </div>
                    </form>
                </div>
            </div>
        `;
    },

    /**
     * Render color picker
     */
    renderColorPicker(selectedColor, disabled) {
        const colorOptions = this.orgColors.map(c => `
            <div class="color-option ${c.id === selectedColor ? 'selected' : ''}"
                 data-color="${c.id}"
                 ${disabled ? '' : `onclick="DASHBOARDS_UI.selectColor('${c.id}')"`}>
                <div class="color-swatch ${c.id}"></div>
                <span class="color-label">${c.label}</span>
            </div>
        `).join('');

        return `
            <input type="hidden" id="dash-org-color" value="${selectedColor}">
            <div class="color-preview-grid ${disabled ? 'disabled' : ''}">${colorOptions}</div>
        `;
    },

    /**
     * Render division checkboxes
     */
    renderDivisionCheckboxes(selectedDivisions, disabled) {
        if (this.divisions.length === 0) {
            return '<p style="color: var(--lcars-tan);">No active divisions in fleet</p>';
        }

        const checkboxes = this.divisions.map(div => {
            const isChecked = selectedDivisions.includes(div.id);
            const sessionCount = div.total_sessions || 0;
            return `
                <label class="division-checkbox ${isChecked ? 'checked' : ''}"
                       data-division="${div.id}"
                       ${disabled ? '' : `onclick="DASHBOARDS_UI.toggleDivision('${div.id}', event)"`}>
                    <input type="checkbox" name="divisions" value="${div.id}"
                           ${isChecked ? 'checked' : ''} ${disabled ? 'disabled' : ''}>
                    <span class="division-checkbox-mark"></span>
                    <span class="division-checkbox-label">${this.escapeHtml(div.name)}</span>
                    <span class="division-checkbox-count">${sessionCount}</span>
                </label>
            `;
        }).join('');

        return `<div class="division-checkboxes">${checkboxes}</div>`;
    },

    /**
     * Render ALL FLEET link visibility checkboxes (for ALL FLEET dashboard editor only)
     */
    renderAllFleetLinkCheckboxes(selectedDashboards) {
        // Get all dashboards except 'all' itself
        const otherDashboards = this.dashboards.filter(d => d.id !== 'all');

        if (otherDashboards.length === 0) {
            return '<p style="color: var(--lcars-tan);">No other dashboards available</p>';
        }

        const checkboxes = otherDashboards.map(dashboard => {
            const isChecked = selectedDashboards.includes(dashboard.id);
            const orgColor = dashboard.org_color || 'lavender';
            return `
                <label class="division-checkbox ${isChecked ? 'checked' : ''}"
                       data-all-fleet-link="${dashboard.id}"
                       onclick="DASHBOARDS_UI.toggleAllFleetLink('${dashboard.id}', event)">
                    <input type="checkbox" name="show_all_fleet_on" value="${dashboard.id}"
                           ${isChecked ? 'checked' : ''}>
                    <span class="division-checkbox-mark"></span>
                    <span class="color-swatch ${orgColor}" style="width: 12px; height: 12px; border-radius: 2px; margin-right: 6px;"></span>
                    <span class="division-checkbox-label">${this.escapeHtml(dashboard.name)}</span>
                </label>
            `;
        }).join('');

        return `<div class="division-checkboxes">${checkboxes}</div>`;
    },

    /**
     * Toggle ALL FLEET link visibility selection
     */
    toggleAllFleetLink(dashboardId, event) {
        event.preventDefault();
        const label = event.currentTarget;
        const checkbox = label.querySelector('input[type="checkbox"]');

        checkbox.checked = !checkbox.checked;
        label.classList.toggle('checked', checkbox.checked);
    },

    /**
     * Get selected dashboards for ALL FLEET link visibility
     */
    getSelectedAllFleetLinks() {
        const checkboxes = document.querySelectorAll('input[name="show_all_fleet_on"]:checked');
        return Array.from(checkboxes).map(cb => cb.value);
    },

    /**
     * Render Dashboard Visibility checkboxes (for controlling which dashboards show in sidebar/settings)
     */
    renderVisibilityCheckboxes(selectedDashboards) {
        // Get all dashboards except current one being edited
        const currentId = this.selectedDashboard?.id;
        const otherDashboards = this.dashboards.filter(d => d.id !== currentId);

        if (otherDashboards.length === 0) {
            return '<p style="color: var(--lcars-tan);">No other dashboards available</p>';
        }

        // If no selection (null/undefined), all are visible by default
        const showAll = !selectedDashboards || !Array.isArray(selectedDashboards);

        const checkboxes = otherDashboards.map(dashboard => {
            const isChecked = showAll || selectedDashboards.includes(dashboard.id);
            const orgColor = dashboard.org_color || 'lavender';
            return `
                <label class="division-checkbox ${isChecked ? 'checked' : ''}"
                       data-visible-dashboard="${dashboard.id}"
                       onclick="DASHBOARDS_UI.toggleVisibility('${dashboard.id}', event)">
                    <input type="checkbox" name="visible_dashboards" value="${dashboard.id}"
                           ${isChecked ? 'checked' : ''}>
                    <span class="division-checkbox-mark"></span>
                    <span class="color-swatch ${orgColor}" style="width: 12px; height: 12px; border-radius: 2px; margin-right: 6px;"></span>
                    <span class="division-checkbox-label">${this.escapeHtml(dashboard.name)}</span>
                </label>
            `;
        }).join('');

        return `
            <div class="visibility-quick-actions" style="margin-bottom: 8px; display: flex; gap: 8px;">
                <button type="button" class="btn-lcars-mini" onclick="DASHBOARDS_UI.selectAllVisibility()"
                        style="padding: 4px 10px; font-size: 11px; background: var(--lcars-cyan); color: var(--lcars-black); border: none; border-radius: 3px; cursor: pointer;">
                    ALL
                </button>
                <button type="button" class="btn-lcars-mini" onclick="DASHBOARDS_UI.selectNoneVisibility()"
                        style="padding: 4px 10px; font-size: 11px; background: var(--lcars-orange); color: var(--lcars-black); border: none; border-radius: 3px; cursor: pointer;">
                    NONE
                </button>
            </div>
            <div class="division-checkboxes">${checkboxes}</div>
        `;
    },

    /**
     * Select all visibility checkboxes
     */
    selectAllVisibility() {
        const checkboxes = document.querySelectorAll('input[name="visible_dashboards"]');
        checkboxes.forEach(cb => {
            cb.checked = true;
            cb.closest('label').classList.add('checked');
        });
    },

    /**
     * Select none visibility checkboxes (hide all other dashboards)
     */
    selectNoneVisibility() {
        const checkboxes = document.querySelectorAll('input[name="visible_dashboards"]');
        checkboxes.forEach(cb => {
            cb.checked = false;
            cb.closest('label').classList.remove('checked');
        });
    },

    /**
     * Toggle dashboard visibility selection
     */
    toggleVisibility(dashboardId, event) {
        event.preventDefault();
        const label = event.currentTarget;
        const checkbox = label.querySelector('input[type="checkbox"]');

        checkbox.checked = !checkbox.checked;
        label.classList.toggle('checked', checkbox.checked);
    },

    /**
     * Get selected visible dashboards
     * Returns null if all are checked (meaning "show all"), otherwise returns array of IDs
     */
    getSelectedVisibleDashboards() {
        const allCheckboxes = document.querySelectorAll('input[name="visible_dashboards"]');
        const checkedCheckboxes = document.querySelectorAll('input[name="visible_dashboards"]:checked');

        // If all are checked, return null (show all - default behavior)
        if (allCheckboxes.length === checkedCheckboxes.length) {
            return null;
        }

        // Return array of checked IDs
        return Array.from(checkedCheckboxes).map(cb => cb.value);
    },

    /**
     * Render machine checkboxes
     */
    renderMachineCheckboxes(selectedMachines, disabled) {
        if (this.machines.length === 0) {
            return '<p style="color: var(--lcars-tan);">No machines available</p>';
        }

        const checkboxes = this.machines.map(machine => {
            const isChecked = selectedMachines.includes(machine.machine_id);
            const statusClass = machine.status === 'online' ? 'online' : 'offline';
            const displayName = machine.nickname || machine.hostname;
            return `
                <label class="division-checkbox machine-checkbox ${isChecked ? 'checked' : ''} ${statusClass}"
                       data-machine="${machine.machine_id}"
                       ${disabled ? '' : `onclick="DASHBOARDS_UI.toggleMachine('${machine.machine_id}', event)"`}>
                    <input type="checkbox" name="machines" value="${machine.machine_id}"
                           ${isChecked ? 'checked' : ''} ${disabled ? 'disabled' : ''}>
                    <span class="division-checkbox-mark"></span>
                    <span class="machine-status-dot ${statusClass}"></span>
                    <span class="division-checkbox-label">${this.escapeHtml(displayName)}</span>
                    <span class="division-checkbox-count">${machine.session_count}</span>
                </label>
            `;
        }).join('');

        return `<div class="division-checkboxes machine-checkboxes">${checkboxes}</div>`;
    },

    /**
     * Render delete confirmation modal
     */
    renderDeleteModal() {
        return `
            <div class="modal-overlay" id="delete-modal">
                <div class="modal-content">
                    <div class="modal-header">
                        <span class="modal-title">CONFIRM DELETE</span>
                    </div>
                    <div class="modal-body">
                        <p class="modal-message" id="delete-message">
                            Are you sure you want to delete this dashboard?
                        </p>
                        <p class="modal-warning">This action cannot be undone.</p>
                    </div>
                    <div class="modal-footer">
                        <button class="btn-lcars btn-lcars-secondary" onclick="DASHBOARDS_UI.hideDeleteModal()">CANCEL</button>
                        <button class="btn-lcars btn-lcars-danger" onclick="DASHBOARDS_UI.executeDelete()">DELETE</button>
                    </div>
                </div>
            </div>
        `;
    },

    /**
     * Bind events
     */
    bindEvents() {
        // Bind drag-and-drop events to dashboard cards
        const cards = document.querySelectorAll('.dashboard-card[draggable="true"]');
        cards.forEach(card => {
            card.addEventListener('dragstart', (e) => this.handleDragStart(e));
            card.addEventListener('dragend', (e) => this.handleDragEnd(e));
            card.addEventListener('dragover', (e) => this.handleDragOver(e));
            card.addEventListener('dragenter', (e) => this.handleDragEnter(e));
            card.addEventListener('dragleave', (e) => this.handleDragLeave(e));
            card.addEventListener('drop', (e) => this.handleDrop(e));
        });
    },

    /**
     * Handle drag start
     */
    handleDragStart(e) {
        this.draggedItem = e.currentTarget;
        this.draggedItem.classList.add('dragging');
        e.dataTransfer.effectAllowed = 'move';
        e.dataTransfer.setData('text/plain', e.currentTarget.dataset.id);

        // Add slight delay for visual feedback
        setTimeout(() => {
            this.draggedItem.style.opacity = '0.5';
        }, 0);
    },

    /**
     * Handle drag end
     */
    handleDragEnd(e) {
        e.currentTarget.classList.remove('dragging');
        e.currentTarget.style.opacity = '1';

        // Remove all drag-over states
        document.querySelectorAll('.dashboard-card').forEach(card => {
            card.classList.remove('drag-over', 'drag-over-top', 'drag-over-bottom');
        });

        this.draggedItem = null;
        this.draggedOverItem = null;
    },

    /**
     * Handle drag over
     */
    handleDragOver(e) {
        e.preventDefault();
        e.dataTransfer.dropEffect = 'move';
    },

    /**
     * Handle drag enter
     */
    handleDragEnter(e) {
        e.preventDefault();
        const card = e.currentTarget;
        if (card !== this.draggedItem) {
            // Determine if we're in the top or bottom half
            const rect = card.getBoundingClientRect();
            const midY = rect.top + rect.height / 2;

            card.classList.remove('drag-over-top', 'drag-over-bottom');
            if (e.clientY < midY) {
                card.classList.add('drag-over-top');
            } else {
                card.classList.add('drag-over-bottom');
            }
            card.classList.add('drag-over');
        }
    },

    /**
     * Handle drag leave
     */
    handleDragLeave(e) {
        e.currentTarget.classList.remove('drag-over', 'drag-over-top', 'drag-over-bottom');
    },

    /**
     * Handle drop
     */
    handleDrop(e) {
        e.preventDefault();
        e.stopPropagation();

        console.log('[DASHBOARDS] handleDrop called');

        const dropTarget = e.currentTarget;

        if (!this.draggedItem) {
            console.log('[DASHBOARDS] No dragged item');
            return;
        }

        if (dropTarget === this.draggedItem) {
            console.log('[DASHBOARDS] Dropped on self, ignoring');
            return;
        }

        const draggedId = this.draggedItem.dataset.id;
        const targetId = dropTarget.dataset.id;

        console.log('[DASHBOARDS] Dragged:', draggedId, 'Target:', targetId);

        // Find indices
        const draggedIndex = this.dashboards.findIndex(d => d.id === draggedId);
        const targetIndex = this.dashboards.findIndex(d => d.id === targetId);

        console.log('[DASHBOARDS] Indices - dragged:', draggedIndex, 'target:', targetIndex);

        if (draggedIndex === -1 || targetIndex === -1) {
            console.log('[DASHBOARDS] Invalid indices, returning');
            return;
        }

        // Determine insert position based on drop location
        const rect = dropTarget.getBoundingClientRect();
        const midY = rect.top + rect.height / 2;
        let newIndex = targetIndex;
        if (e.clientY > midY && draggedIndex < targetIndex) {
            // Dropping below and moving down - stay at target
        } else if (e.clientY <= midY && draggedIndex > targetIndex) {
            // Dropping above and moving up - stay at target
        } else if (e.clientY > midY) {
            newIndex = targetIndex + 1;
        }

        console.log('[DASHBOARDS] New index:', newIndex);

        // Reorder array
        const [removed] = this.dashboards.splice(draggedIndex, 1);
        const adjustedIndex = newIndex > draggedIndex ? newIndex - 1 : newIndex;
        this.dashboards.splice(adjustedIndex, 0, removed);

        // Update sort_order values
        this.dashboards.forEach((d, i) => {
            d.sort_order = i + 1;
        });

        console.log('[DASHBOARDS] New order:', this.dashboards.map(d => d.id));

        // Re-render immediately with new order, then save to server
        console.log('[DASHBOARDS] Calling render...');
        this.render();
        console.log('[DASHBOARDS] Calling saveOrder...');
        this.saveOrder();
    },

    /**
     * Save dashboard order to server
     */
    async saveOrder() {
        const order = this.dashboards.map(d => d.id);

        try {
            const response = await fetch(`${this.apiBase}/reorder`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ order })
            });

            const result = await response.json();

            if (response.ok) {
                this.showToast('Dashboard order saved', 'success');
                console.log('[DASHBOARDS] Order saved:', order);

                // Dispatch event to refresh sidebar links
                document.dispatchEvent(new CustomEvent('lcars:dashboardsChanged'));
            } else {
                this.showToast(result.error || 'Failed to save order', 'error');
                // Reload to restore original order
                await this.loadDashboards();
                this.render();
            }
        } catch (error) {
            console.error('[DASHBOARDS] Save order error:', error);
            this.showToast('Error saving order', 'error');
        }
    },

    /**
     * Select a dashboard for editing
     */
    selectDashboard(id) {
        this.selectedDashboard = this.dashboards.find(d => d.id === id) || null;
        this.isNewDashboard = false;
        this.render();
    },

    /**
     * Create a new dashboard
     */
    createNew() {
        this.selectedDashboard = null;
        this.isNewDashboard = true;
        this.render();
    },

    /**
     * Cancel editing
     */
    cancelEdit() {
        this.selectedDashboard = null;
        this.isNewDashboard = false;
        this.render();
    },

    /**
     * Select an org color
     */
    selectColor(colorId) {
        document.getElementById('dash-org-color').value = colorId;
        document.querySelectorAll('.color-option').forEach(el => {
            el.classList.toggle('selected', el.dataset.color === colorId);
        });
    },

    /**
     * Toggle division selection
     */
    toggleDivision(divisionId, event) {
        event.preventDefault();
        const label = event.currentTarget;
        const checkbox = label.querySelector('input[type="checkbox"]');

        checkbox.checked = !checkbox.checked;
        label.classList.toggle('checked', checkbox.checked);
    },

    /**
     * Toggle machine selection
     */
    toggleMachine(machineId, event) {
        event.preventDefault();
        const label = event.currentTarget;
        const checkbox = label.querySelector('input[type="checkbox"]');

        checkbox.checked = !checkbox.checked;
        label.classList.toggle('checked', checkbox.checked);
    },

    /**
     * Get selected divisions from form
     */
    getSelectedDivisions() {
        const checkboxes = document.querySelectorAll('input[name="divisions"]:checked');
        return Array.from(checkboxes).map(cb => cb.value);
    },

    /**
     * Get selected machines from form
     */
    getSelectedMachines() {
        const checkboxes = document.querySelectorAll('input[name="machines"]:checked');
        return Array.from(checkboxes).map(cb => cb.value);
    },

    /**
     * Save dashboard (create or update)
     */
    async saveDashboard(event) {
        event.preventDefault();

        const name = document.getElementById('dash-name').value.trim();
        const title = document.getElementById('dash-title').value.trim();
        const subtitle = document.getElementById('dash-subtitle').value.trim();
        const description = document.getElementById('dash-description').value.trim();
        const org_color = document.getElementById('dash-org-color').value;
        const divisions = this.getSelectedDivisions();
        const machines = this.getSelectedMachines();

        // Validation
        if (!name) {
            this.showToast('Dashboard name is required', 'error');
            document.getElementById('dash-name').classList.add('error');
            return;
        }

        const dashboardData = {
            name,
            title: title || name.toUpperCase(),
            subtitle: subtitle || 'OPERATIONS MONITOR',
            description,
            org_color,
            divisions,
            machines
        };

        // For ALL FLEET dashboard, include the link visibility settings
        if (this.selectedDashboard && this.selectedDashboard.id === 'all') {
            dashboardData.show_all_fleet_on = this.getSelectedAllFleetLinks();
        } else {
            // For other dashboards, include visibility settings
            dashboardData.visible_dashboards = this.getSelectedVisibleDashboards();
        }

        try {
            let response;
            if (this.isNewDashboard) {
                // Create new
                response = await fetch(this.apiBase, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(dashboardData)
                });
            } else {
                // Update existing
                response = await fetch(`${this.apiBase}/${this.selectedDashboard.id}`, {
                    method: 'PUT',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(dashboardData)
                });
            }

            const result = await response.json();

            if (response.ok) {
                const action = this.isNewDashboard ? 'created' : 'updated';
                this.showToast(`Dashboard ${action} successfully`, 'success');
                console.log(`[DASHBOARDS] Dashboard ${action}:`, result);

                // Reload data and update UI
                await this.loadDashboards();
                this.selectedDashboard = result;
                this.isNewDashboard = false;
                this.render();

                // Update sidebar links if available
                this.updateSidebarLinks();
            } else {
                this.showToast(result.error || 'Failed to save dashboard', 'error');
            }
        } catch (error) {
            console.error('[DASHBOARDS] Save error:', error);
            this.showToast('Error saving dashboard', 'error');
        }
    },

    /**
     * Show delete confirmation modal
     */
    confirmDelete() {
        if (!this.selectedDashboard) return;

        const message = document.getElementById('delete-message');
        message.textContent = `Are you sure you want to delete "${this.selectedDashboard.name}"?`;

        const modal = document.getElementById('delete-modal');
        modal.classList.add('active');
    },

    /**
     * Hide delete modal
     */
    hideDeleteModal() {
        const modal = document.getElementById('delete-modal');
        modal.classList.remove('active');
    },

    /**
     * Execute delete
     */
    async executeDelete() {
        if (!this.selectedDashboard) return;

        try {
            const response = await fetch(`${this.apiBase}/${this.selectedDashboard.id}`, {
                method: 'DELETE'
            });

            const result = await response.json();

            if (response.ok && result.success) {
                this.showToast(`Dashboard "${this.selectedDashboard.name}" deleted`, 'success');
                console.log('[DASHBOARDS] Dashboard deleted:', result);

                this.hideDeleteModal();

                // Reload and reset UI
                await this.loadDashboards();
                this.selectedDashboard = null;
                this.isNewDashboard = false;
                this.render();

                // Update sidebar links if available
                this.updateSidebarLinks();
            } else {
                this.showToast(result.error || 'Failed to delete dashboard', 'error');
            }
        } catch (error) {
            console.error('[DASHBOARDS] Delete error:', error);
            this.showToast('Error deleting dashboard', 'error');
        }
    },

    /**
     * Update sidebar dashboard links dynamically
     */
    updateSidebarLinks() {
        const sidebarLinksContainer = document.querySelector('.sidebar-dashboard-links');
        if (!sidebarLinksContainer) return;

        const currentPath = window.location.pathname;
        const currentSearch = window.location.search;
        const currentUrl = currentPath.split('/').pop() + currentSearch;
        const links = this.dashboards.map(d => {
            const linkUrl = 'lcars-dashboard.html?dashboard=' + d.id;
            const isActive = (currentUrl === d.html_file) ||
                             (currentUrl === linkUrl) ||
                             (currentPath === d.url_path) ||
                             (currentPath === d.url_path + '/');
            const orgColor = d.org_color || 'lavender';
            // Invert colors when active: black background, org color text
            const colorStyle = isActive
                ? `background: var(--lcars-black); color: var(--lcars-${orgColor});`
                : `background: var(--lcars-${orgColor}); color: var(--lcars-black);`;
            return `<a href="${linkUrl}" class="sidebar-link ${isActive ? 'active' : ''}" style="${colorStyle}">${d.name.toUpperCase()}</a>`;
        }).join('');

        sidebarLinksContainer.innerHTML = links;
    },

    /**
     * Show toast notification
     */
    showToast(message, type = 'info') {
        const container = document.querySelector('.toast-container');
        if (!container) return;

        const icons = {
            success: '&#x2714;',
            error: '&#x2716;',
            info: '&#x2139;',
            warning: '&#x26A0;'
        };

        const toast = document.createElement('div');
        toast.className = `toast toast-${type}`;
        toast.innerHTML = `
            <span class="toast-icon">${icons[type]}</span>
            <span class="toast-message">${this.escapeHtml(message)}</span>
            <button class="toast-close" onclick="this.parentElement.remove()">&times;</button>
        `;

        container.appendChild(toast);

        // Auto-remove after 5 seconds
        setTimeout(() => {
            toast.classList.add('toast-exit');
            setTimeout(() => toast.remove(), 300);
        }, 5000);
    },

    /**
     * Escape HTML to prevent XSS
     */
    escapeHtml(text) {
        if (!text) return '';
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    },

    /**
     * Refresh the dashboard list
     */
    async refresh() {
        await Promise.all([
            this.loadDashboards(),
            this.loadDivisions(),
            this.loadMachines()
        ]);
        this.render();
    }
};

// Expose globally
window.DASHBOARDS_UI = DASHBOARDS_UI;
