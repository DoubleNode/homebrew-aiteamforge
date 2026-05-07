//
//  lcars-graph.js
//  DoubleNode Dev-Team Infrastructure (AITeamForge)
//
//  Copyright © 2026 - 2025 DoubleNode.com. All rights reserved.
//

/**
 * LCARS - Library Computer Access/Retrieval System
 * Knowledge Graph Visualizer - Cytoscape.js Theme and Controller
 *
 * Provides LCARS-themed graph visualization using Cytoscape.js.
 * All functions are global scope to match lcars.js patterns.
 *
 * Dependencies: cytoscape.min.js (vendor)
 * Background container color: #1a1a2e (set via CSS, not here)
 */

// ============================================================================
// COLOR DEFINITIONS
// ============================================================================

const GRAPH_NODE_COLORS = {
    concept:    '#FF9900',  // LCARS orange
    entity:     '#CC99CC',  // LCARS lavender
    engine:     '#99CCFF',  // LCARS blue
    source:     '#FFCC66',  // LCARS gold
    function:   '#FF9966',  // LCARS peach
    class:      '#CC6699',  // LCARS magenta
    module:     '#99CC99',  // LCARS green
    document:   '#FFCC99',  // LCARS cream
    person:     '#CC99FF',  // LCARS violet
    event:      '#66CCCC',  // LCARS teal
    default:    '#FF9900',  // Fallback orange
};

const GRAPH_EDGE_COLORS = {
    default:    '#7799BB',  // Muted blue-gray
    strong:     '#FF9900',  // Orange for important relationships
    weak:       '#556677',  // Dim for weak connections
};

// ============================================================================
// STYLESHEET
// ============================================================================

/**
 * Returns the Cytoscape.js stylesheet array with LCARS theming.
 * Uses Antonio font (LCARS standard) throughout.
 * Text outlines use #1a1a2e to ensure readability on dark background.
 */
function getLCARSGraphStyle() {
    return [
        // Node base style
        {
            selector: 'node',
            style: {
                'label': 'data(label)',
                'background-color': function(ele) {
                    return GRAPH_NODE_COLORS[ele.data('type')] || GRAPH_NODE_COLORS.default;
                },
                'color': '#FF9900',
                'text-valign': 'bottom',
                'text-halign': 'center',
                'font-family': 'Antonio, sans-serif',
                'font-size': '11px',
                'text-margin-y': 8,
                'width': 30,
                'height': 30,
                'border-width': 2,
                'border-color': '#556677',
                'text-outline-width': 2,
                'text-outline-color': '#1a1a2e',
            }
        },
        // Selected node
        {
            selector: 'node:selected',
            style: {
                'border-width': 3,
                'border-color': '#FF9900',
                'background-color': '#FFCC66',
                'color': '#FFCC66',
                'text-outline-color': '#1a1a2e',
                'z-index': 999,
            }
        },
        // Hovered node
        {
            selector: 'node:active',
            style: {
                'overlay-color': '#FF9900',
                'overlay-opacity': 0.2,
            }
        },
        // Edge base style
        {
            selector: 'edge',
            style: {
                'label': 'data(label)',
                'curve-style': 'bezier',
                'target-arrow-shape': 'triangle',
                'target-arrow-color': '#7799BB',
                'line-color': '#7799BB',
                'width': 1.5,
                'opacity': 0.7,
                'font-family': 'Antonio, sans-serif',
                'font-size': '9px',
                'color': '#7799BB',
                'text-rotation': 'autorotate',
                'text-outline-width': 2,
                'text-outline-color': '#1a1a2e',
                'text-margin-y': -10,
            }
        },
        // Selected edge
        {
            selector: 'edge:selected',
            style: {
                'line-color': '#FF9900',
                'target-arrow-color': '#FF9900',
                'color': '#FF9900',
                'width': 3,
                'opacity': 1,
                'z-index': 999,
            }
        },
        // Highlighted neighbors
        {
            selector: '.highlighted',
            style: {
                'border-color': '#FFCC66',
                'border-width': 3,
                'opacity': 1,
            }
        },
        // Dimmed (non-highlighted) elements
        {
            selector: '.dimmed',
            style: {
                'opacity': 0.15,
            }
        },
    ];
}

// ============================================================================
// LAYOUT PRESETS
// ============================================================================

const GRAPH_LAYOUTS = {
    cose: {
        name: 'cose',
        animate: true,
        animationDuration: 500,
        nodeRepulsion: 8000,
        idealEdgeLength: 80,
        edgeElasticity: 100,
        gravity: 0.25,
        numIter: 1000,
        padding: 30,
    },
    circle: {
        name: 'circle',
        animate: true,
        animationDuration: 500,
        padding: 30,
    },
    grid: {
        name: 'grid',
        animate: true,
        animationDuration: 500,
        padding: 30,
        rows: undefined, // auto
    },
    breadthfirst: {
        name: 'breadthfirst',
        animate: true,
        animationDuration: 500,
        padding: 30,
        directed: true,
        spacingFactor: 1.2,
    },
    concentric: {
        name: 'concentric',
        animate: true,
        animationDuration: 500,
        padding: 30,
        minNodeSpacing: 50,
        concentric: function(node) {
            return node.degree();
        },
        levelWidth: function() {
            return 2;
        },
    },
    random: {
        name: 'random',
        animate: true,
        animationDuration: 500,
        padding: 30,
    },
};

// ============================================================================
// GLOBAL GRAPH STATE
// ============================================================================

let cyGraph = null;
let currentGraphEngine = null;
let currentLayout = 'cose';

// ============================================================================
// INITIALIZATION
// ============================================================================

/**
 * Initialize the Cytoscape.js instance in the given container element.
 * Wires up tap handlers for nodes, edges, and background.
 *
 * @param {string} containerId - DOM element ID for the graph container
 * @returns {object|null} Cytoscape instance, or null if container not found
 */
function initKnowledgeGraph(containerId) {
    const container = document.getElementById(containerId);
    if (!container) return null;

    cyGraph = cytoscape({
        container: container,
        style: getLCARSGraphStyle(),
        layout: { name: 'preset' },  // No layout until data loads
        elements: [],
        minZoom: 0.1,
        maxZoom: 5,
        wheelSensitivity: 0.3,
        boxSelectionEnabled: true,
        selectionType: 'single',
    });

    // Node click: show details and highlight neighbors
    cyGraph.on('tap', 'node', function(evt) {
        const node = evt.target;
        showGraphNodeDetails(node.data());
        highlightNeighbors(node);
    });

    // Edge click: show relationship details
    cyGraph.on('tap', 'edge', function(evt) {
        const edge = evt.target;
        showGraphEdgeDetails(edge.data());
    });

    // Background click: clear selection and hide detail panel
    cyGraph.on('tap', function(evt) {
        if (evt.target === cyGraph) {
            clearGraphHighlights();
            hideGraphDetails();
        }
    });

    return cyGraph;
}

// ============================================================================
// HIGHLIGHT HELPERS
// ============================================================================

/**
 * Dim all elements, then highlight the given node and its immediate neighbors.
 *
 * @param {object} node - Cytoscape node element
 */
function highlightNeighbors(node) {
    // Dim everything first
    cyGraph.elements().addClass('dimmed');
    // Highlight selected node and its direct neighbors
    const neighborhood = node.neighborhood().add(node);
    neighborhood.removeClass('dimmed').addClass('highlighted');
}

/**
 * Remove all highlight/dim classes from graph elements.
 */
function clearGraphHighlights() {
    if (!cyGraph) return;
    cyGraph.elements().removeClass('dimmed highlighted');
}

// ============================================================================
// DATA LOADING
// ============================================================================

/**
 * Fetch graph data from the API and render it.
 * Expects the API to return { nodes: [...], edges: [...], engine: '...' }.
 *
 * @param {string} engineId - RAG engine ID to query
 * @param {string|null} query - Optional search query to filter the graph
 * @param {number|null} limit - Optional max nodes to return
 * @returns {object|null} API response data, or null on failure
 */
async function loadGraphData(engineId, query, limit) {
    const body = { engineId: engineId || 'demo' };
    if (query) body.query = query;
    if (limit) body.limit = limit;

    // Clear stale graph data immediately so a different engine's data never lingers
    if (cyGraph) cyGraph.elements().remove();

    const engineLabel = document.getElementById('graph-engine-label');
    if (engineLabel) engineLabel.textContent = (engineId || 'demo') + ' (loading...)';

    try {
        const url = apiUrl('/api/graph/data');
        const resp = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
        });
        if (!resp.ok) {
            console.warn('[Graph] API returned HTTP', resp.status);
            if (engineLabel) engineLabel.textContent = 'HTTP ' + resp.status;
            return null;
        }
        const data = await resp.json();

        if (data.error) {
            console.warn('[Graph] API error:', data.error);
            if (engineLabel) engineLabel.textContent = 'error: ' + data.error;
            return null;
        }

        renderGraphData(data);
        return data;
    } catch (err) {
        console.error('[Graph] Failed to load graph data:', err);
        if (engineLabel) engineLabel.textContent = 'fetch failed';
        return null;
    }
}

/**
 * Convert API response into Cytoscape elements and render with the current layout.
 * Clears existing graph elements before rendering.
 *
 * Expected data shape:
 *   nodes: [{ id, label, type, group, properties }]
 *   edges: [{ id, source, target, label, properties }]
 *
 * @param {object} data - API response containing nodes and edges arrays
 */
function renderGraphData(data) {
    if (!cyGraph) return;

    // Clear existing elements
    cyGraph.elements().remove();

    // Convert API data to Cytoscape element format
    const elements = [];
    const nodeIds = new Set();

    (data.nodes || []).forEach(n => {
        nodeIds.add(n.id);
        elements.push({
            group: 'nodes',
            data: {
                id: n.id,
                label: n.label || n.id,
                type: n.type || 'default',
                nodeGroup: n.group || 'default',
                properties: n.properties || {},
            }
        });
    });

    // Filter edges to only those whose source and target exist in the node set
    // (API may return capped nodes but edges referencing nodes outside the cap)
    (data.edges || []).forEach(e => {
        if (!nodeIds.has(e.source) || !nodeIds.has(e.target)) return;
        elements.push({
            group: 'edges',
            data: {
                id: e.id || `${e.source}-${e.target}`,
                source: e.source,
                target: e.target,
                label: e.label || '',
                properties: e.properties || {},
            }
        });
    });

    cyGraph.add(elements);

    // Apply current layout
    applyGraphLayout(currentLayout);

    // Update node/edge count display
    updateGraphStats(data);
}

// ============================================================================
// LAYOUT CONTROL
// ============================================================================

/**
 * Apply a named layout to the graph and update layout button active states.
 *
 * @param {string} layoutName - Key from GRAPH_LAYOUTS (cose, circle, grid, etc.)
 */
function applyGraphLayout(layoutName) {
    if (!cyGraph || cyGraph.elements().length === 0) return;

    currentLayout = layoutName;
    const layoutConfig = GRAPH_LAYOUTS[layoutName] || GRAPH_LAYOUTS.cose;
    cyGraph.layout(layoutConfig).run();

    // Sync active state on layout buttons
    document.querySelectorAll('.graph-layout-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.layout === layoutName);
    });
}

// ============================================================================
// STATS DISPLAY
// ============================================================================

/**
 * Update graph statistics display elements (node count, edge count, engine name).
 *
 * @param {object} data - API response containing nodes, edges arrays and engine name
 */
function updateGraphStats(data) {
    const nodeCount = document.getElementById('graph-node-count');
    const edgeCount = document.getElementById('graph-edge-count');
    const engineLabel = document.getElementById('graph-engine-label');

    if (nodeCount) nodeCount.textContent = (data.nodes || []).length;
    if (edgeCount) edgeCount.textContent = (data.edges || []).length;
    if (engineLabel) engineLabel.textContent = data.engine || 'unknown';
}

// ============================================================================
// DETAIL PANELS — helper to build a detail row using safe DOM methods
// Note: Placeholder implementation — will be enhanced in subitem XACA-0141-005
// ============================================================================

/**
 * Create a detail row element using safe DOM methods (no innerHTML).
 *
 * @param {string} labelText - The label string (e.g. "TYPE")
 * @param {string} valueText - The value string (e.g. "concept")
 * @returns {HTMLElement} A .detail-row div
 */
function buildDetailRow(labelText, valueText) {
    const row = document.createElement('div');
    row.className = 'detail-row';
    row.style.opacity = '1';
    row.style.transform = 'none';

    const label = document.createElement('span');
    label.className = 'detail-label';
    label.textContent = labelText;

    const value = document.createElement('span');
    value.className = 'detail-value';
    value.textContent = valueText;

    row.appendChild(label);
    row.appendChild(value);
    return row;
}

/**
 * Show the node detail panel with full node information, type badge, and relationships.
 *
 * @param {object} nodeData - Cytoscape node data object
 */
function showGraphNodeDetails(nodeData) {
    const panel = document.getElementById('graph-detail-panel');
    if (!panel) return;
    panel.classList.add('visible');

    const title = panel.querySelector('.graph-detail-title');
    const content = panel.querySelector('.graph-detail-content');
    const relSection = document.getElementById('graph-detail-relationships');

    if (title) title.textContent = nodeData.label || nodeData.id;

    if (content) {
        // Clear content safely using DOM removal
        while (content.firstChild) content.removeChild(content.firstChild);

        // Type badge with color from GRAPH_NODE_COLORS
        const typeColor = GRAPH_NODE_COLORS[nodeData.type] || GRAPH_NODE_COLORS.default;
        const badgeRow = document.createElement('div');
        badgeRow.className = 'detail-row';
        badgeRow.style.opacity = '1';
        badgeRow.style.transform = 'none';
        const badgeLabel = document.createElement('span');
        badgeLabel.className = 'detail-label';
        badgeLabel.textContent = 'TYPE';
        const badgeValue = document.createElement('span');
        badgeValue.className = 'detail-value';
        badgeValue.style.color = typeColor;
        badgeValue.style.fontWeight = '600';
        badgeValue.textContent = (nodeData.type || 'unknown').toUpperCase();
        badgeRow.appendChild(badgeLabel);
        badgeRow.appendChild(badgeValue);
        content.appendChild(badgeRow);

        // ID
        content.appendChild(buildDetailRow('ID', nodeData.id));

        // Group (if not default)
        if (nodeData.nodeGroup && nodeData.nodeGroup !== 'default') {
            content.appendChild(buildDetailRow('GROUP', nodeData.nodeGroup));
        }

        // Render local properties immediately (fast feedback)
        _renderNodeProperties(content, nodeData.properties);

        // Fetch enriched details from the server API
        _fetchAndEnrichNodeDetails(nodeData.id, content, relSection);
    }

    // Show relationships from connected edges (local graph data)
    _renderNodeRelationships(relSection, nodeData);
}

/**
 * Render node properties into the detail content panel.
 * Skips keys already shown (id, label, type, group) and empty values.
 * Long values get a scrollable, wrapped style for readability.
 *
 * @param {HTMLElement} container - The content div to append rows to
 * @param {object} props - Key/value properties to display
 */
function _renderNodeProperties(container, props) {
    // Priority order: show description first, then other props alphabetically
    const items = props || {};
    const sortedKeys = Object.keys(items).sort((a, b) => {
        if (a === 'description') return -1;
        if (b === 'description') return 1;
        return a.localeCompare(b);
    });
    sortedKeys.forEach(key => {
        const val = items[key];
        if (val === null || val === undefined || val === '' || val === 0) return;
        // Skip internal/noisy LightRAG metadata
        if (['source_id', 'file_path', 'truncate', 'entity_id'].indexOf(key) !== -1) return;
        // Format epoch timestamps as readable dates
        if (key === 'created_at' && typeof val === 'number' && val > 1000000000) {
            items[key] = new Date(val * 1000).toLocaleDateString('en-US', {
                year: 'numeric', month: 'short', day: 'numeric'
            });
        }
        let displayVal = typeof val === 'object' ? JSON.stringify(val, null, 2) : String(val);
        // Clean LightRAG <SEP> delimiters into readable line breaks
        if (typeof displayVal === 'string' && displayVal.includes('<SEP>')) {
            displayVal = displayVal.split('<SEP>').map(s => s.trim()).filter(Boolean).join('\n');
        }
        const row = buildDetailRow(key.toUpperCase(), displayVal);
        // Description and long values get block layout via CSS class
        if (key === 'description' || displayVal.length > 100) {
            row.classList.add('detail-description');
            const valSpan = row.querySelector('.detail-value');
            if (valSpan) {
                valSpan.style.whiteSpace = 'pre-wrap';
                valSpan.style.wordBreak = 'break-word';
                valSpan.style.lineHeight = '1.4';
            }
        }
        container.appendChild(row);
    });
}

/**
 * Fetch enriched node details from /api/graph/node and update the panel.
 * Merges server properties with what's already shown, avoiding duplicates.
 *
 * @param {string} nodeId - The node ID to look up
 * @param {HTMLElement} content - The detail content div
 * @param {HTMLElement} relSection - The relationships section div
 */
async function _fetchAndEnrichNodeDetails(nodeId, content, relSection) {
    const engineId = currentGraphEngine || 'demo';
    try {
        const resp = await fetch(apiUrl('/api/graph/node'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ engineId, nodeId }),
        });
        if (!resp.ok) return;
        const data = await resp.json();
        if (!data.node) return;

        // Check that this node is still selected (user may have clicked another)
        const panel = document.getElementById('graph-detail-panel');
        const titleEl = panel ? panel.querySelector('.graph-detail-title') : null;
        const currentLabel = titleEl ? titleEl.textContent : '';
        const nodeLabel = data.node.label || nodeId;
        if (currentLabel !== nodeLabel && currentLabel !== nodeId) return;

        // Determine which property keys are already rendered in the panel
        const existingLabels = new Set();
        content.querySelectorAll('.detail-label').forEach(el => {
            existingLabels.add(el.textContent.trim());
        });

        // Skip meta keys that are already shown as dedicated rows
        const metaKeys = new Set(['id', 'label', 'name', 'type', 'entity_type', 'group', 'cluster']);

        // Collect only new properties not already displayed
        const newProps = {};
        const enrichedProps = data.node.properties || {};
        Object.keys(enrichedProps).forEach(key => {
            if (metaKeys.has(key)) return;
            if (existingLabels.has(key.toUpperCase())) return;
            newProps[key] = enrichedProps[key];
        });
        if (Object.keys(newProps).length > 0) {
            _renderNodeProperties(content, newProps);
        }

        // Enrich relationships from server if the local graph had none
        if (data.node.relationships && data.node.relationships.length > 0 && relSection) {
            const existingRelCount = relSection.querySelectorAll('.detail-row').length;
            // Only add server relationships if local graph had none (header row = 1)
            if (existingRelCount <= 1) {
                while (relSection.firstChild) relSection.removeChild(relSection.firstChild);

                const relHeader = document.createElement('div');
                relHeader.className = 'detail-row';
                relHeader.style.opacity = '1';
                relHeader.style.transform = 'none';
                const relLabel = document.createElement('span');
                relLabel.className = 'detail-label';
                relLabel.style.color = '#99CCFF';
                relLabel.textContent = 'RELATIONSHIPS (' + data.node.relationships.length + ')';
                relHeader.appendChild(relLabel);
                relSection.appendChild(relHeader);

                data.node.relationships.forEach(rel => {
                    const relRow = document.createElement('div');
                    relRow.className = 'detail-row';
                    relRow.style.opacity = '1';
                    relRow.style.transform = 'none';
                    relRow.style.cursor = 'pointer';
                    relRow.style.fontSize = '12px';
                    const relValue = document.createElement('span');
                    relValue.className = 'detail-value';
                    relValue.style.color = '#CC99CC';
                    relValue.style.fontSize = '12px';
                    const targetLabel = rel.targetLabel || rel.target;
                    relValue.textContent = '\u2192 ' + (rel.type || 'RELATED') + ' \u2192 ' + targetLabel;
                    relRow.appendChild(relValue);

                    // Click to navigate if node exists in graph
                    relRow.addEventListener('click', function() {
                        if (!cyGraph) return;
                        const targetNode = cyGraph.getElementById(rel.target);
                        if (targetNode.length > 0) {
                            cyGraph.animate({
                                center: { eles: targetNode },
                                zoom: cyGraph.zoom(),
                            }, { duration: 300 });
                            targetNode.select();
                            showGraphNodeDetails(targetNode.data());
                            highlightNeighbors(targetNode);
                        }
                    });
                    relSection.appendChild(relRow);
                });
            }
        }
    } catch (err) {
        console.warn('[Graph] Node detail fetch failed:', err);
    }
}

/**
 * Render relationships from the local Cytoscape graph edges into the panel.
 *
 * @param {HTMLElement} relSection - The relationships container div
 * @param {object} nodeData - The Cytoscape node data
 */
function _renderNodeRelationships(relSection, nodeData) {
    if (!relSection || !cyGraph) return;
    while (relSection.firstChild) relSection.removeChild(relSection.firstChild);
    const node = cyGraph.getElementById(nodeData.id);
    if (!node || node.length === 0) return;

    const edges = node.connectedEdges();
    if (edges.length === 0) return;

    const relHeader = document.createElement('div');
    relHeader.className = 'detail-row';
    relHeader.style.opacity = '1';
    relHeader.style.transform = 'none';
    const relLabel = document.createElement('span');
    relLabel.className = 'detail-label';
    relLabel.style.color = '#99CCFF';
    relLabel.textContent = 'RELATIONSHIPS (' + edges.length + ')';
    relHeader.appendChild(relLabel);
    relSection.appendChild(relHeader);

    edges.forEach(edge => {
        const edgeData = edge.data();
        const isOutgoing = edgeData.source === nodeData.id;
        const otherNodeId = isOutgoing ? edgeData.target : edgeData.source;
        const otherNode = cyGraph.getElementById(otherNodeId);
        const otherLabel = otherNode.length > 0 ? (otherNode.data('label') || otherNodeId) : otherNodeId;
        const arrow = isOutgoing ? '\u2192' : '\u2190';
        const relText = arrow + ' ' + (edgeData.label || 'RELATED') + ' ' + arrow + ' ' + otherLabel;

        const relRow = document.createElement('div');
        relRow.className = 'detail-row';
        relRow.style.opacity = '1';
        relRow.style.transform = 'none';
        relRow.style.cursor = 'pointer';
        relRow.style.fontSize = '12px';

        const relValue = document.createElement('span');
        relValue.className = 'detail-value';
        relValue.style.color = '#CC99CC';
        relValue.style.fontSize = '12px';
        relValue.textContent = relText;

        relRow.appendChild(relValue);

        // Click to navigate to the connected node
        relRow.addEventListener('click', function() {
            const targetNode = cyGraph.getElementById(otherNodeId);
            if (targetNode.length > 0) {
                cyGraph.animate({
                    center: { eles: targetNode },
                    zoom: cyGraph.zoom(),
                }, { duration: 300 });
                targetNode.select();
                showGraphNodeDetails(targetNode.data());
                highlightNeighbors(targetNode);
            }
        });

        relSection.appendChild(relRow);
    });
}

/**
 * Show the detail panel with full edge relationship information and node labels.
 *
 * @param {object} edgeData - Cytoscape edge data object
 */
function showGraphEdgeDetails(edgeData) {
    const panel = document.getElementById('graph-detail-panel');
    if (!panel) return;
    panel.classList.add('visible');

    const title = panel.querySelector('.graph-detail-title');
    const content = panel.querySelector('.graph-detail-content');
    const relSection = document.getElementById('graph-detail-relationships');

    if (title) title.textContent = edgeData.label || 'RELATIONSHIP';

    if (content) {
        content.innerHTML = '';

        // Resolve source/target node labels from the graph
        const sourceNode = cyGraph ? cyGraph.getElementById(edgeData.source) : null;
        const targetNode = cyGraph ? cyGraph.getElementById(edgeData.target) : null;
        const sourceLabel = (sourceNode && sourceNode.length > 0) ? (sourceNode.data('label') || edgeData.source) : edgeData.source;
        const targetLabel = (targetNode && targetNode.length > 0) ? (targetNode.data('label') || edgeData.target) : edgeData.target;

        content.appendChild(buildDetailRow('TYPE', (edgeData.label || 'RELATED').toUpperCase()));
        content.appendChild(buildDetailRow('FROM', sourceLabel));
        content.appendChild(buildDetailRow('TO', targetLabel));

        // All properties
        const props = edgeData.properties || {};
        Object.keys(props).forEach(key => {
            const val = props[key];
            if (val !== null && val !== undefined && val !== '') {
                const displayVal = typeof val === 'object' ? JSON.stringify(val) : String(val);
                content.appendChild(buildDetailRow(key.toUpperCase(), displayVal));
            }
        });
    }

    // Clear relationships section for edges (not applicable)
    if (relSection) relSection.innerHTML = '';
}

/**
 * Hide the graph detail panel.
 */
function hideGraphDetails() {
    const panel = document.getElementById('graph-detail-panel');
    if (panel) panel.classList.remove('visible');
}

// ============================================================================
// SEARCH
// ============================================================================

/**
 * Search the knowledge graph using the selected mode and re-render results.
 * Reads the search mode from #graph-search-mode selector.
 * Displays RAG answer or message in #graph-rag-answer if provided.
 *
 * @param {string} query - Search query string
 */
async function searchGraph(query) {
    if (!query) return;

    const engineId = currentGraphEngine || 'demo';
    const modeSelect = document.getElementById('graph-search-mode');
    const mode = modeSelect ? modeSelect.value : 'hybrid';

    // Show loading state on the search button
    const searchBtn = document.querySelector('.graph-search-btn');
    if (searchBtn) {
        searchBtn.textContent = 'QUERYING...';
        searchBtn.disabled = true;
    }

    try {
        const resp = await fetch(apiUrl('/api/graph/query'), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                engineId: engineId,
                query: query,
                mode: mode,
            }),
        });
        if (!resp.ok) {
            throw new Error('Server returned HTTP ' + resp.status);
        }
        const data = await resp.json();

        if (data.nodes && data.nodes.length > 0) {
            renderGraphData(data);
        }

        // Display RAG answer, message, or hide the answer area
        const answerEl = document.getElementById('graph-rag-answer');
        if (answerEl) {
            if (data.answer) {
                answerEl.textContent = data.answer;
                answerEl.style.display = 'block';
            } else if (data.message) {
                answerEl.textContent = data.message;
                answerEl.style.display = 'block';
            } else {
                answerEl.style.display = 'none';
            }
        }
    } catch (err) {
        console.error('[Graph] Search failed:', err);
        const answerEl = document.getElementById('graph-rag-answer');
        if (answerEl) {
            answerEl.textContent = 'Search failed: ' + err.message;
            answerEl.style.display = 'block';
        }
    } finally {
        if (searchBtn) {
            searchBtn.textContent = 'QUERY';
            searchBtn.disabled = false;
        }
    }
}

/**
 * Clear the search input and RAG answer, then reload the full graph
 * from the currently selected engine.
 */
function clearGraphSearch() {
    const searchInput = document.getElementById('graph-search-input');
    if (searchInput) searchInput.value = '';

    const answerEl = document.getElementById('graph-rag-answer');
    if (answerEl) answerEl.style.display = 'none';

    // Reload full graph from current engine
    loadGraphData(currentGraphEngine || 'demo');
}

// ============================================================================
// ENGINE SELECTOR
// ============================================================================

/**
 * Handle engine selector change — update currentGraphEngine and reload graph data.
 *
 * @param {HTMLSelectElement} selectEl - The engine selector element
 */
function onGraphEngineChange(selectEl) {
    const engineId = selectEl.value;
    console.log('[Graph] Engine changed to:', engineId);
    currentGraphEngine = engineId;
    // Show loading state in stats bar
    const engineLabel = document.getElementById('graph-engine-label');
    if (engineLabel) engineLabel.textContent = engineId + ' (loading...)';
    loadGraphData(engineId);
}

/**
 * Fetch available RAG engines and populate the engine selector dropdown.
 * Disables options for engines that are not in 'running' status.
 * Adds a 'Demo Graph' option as the first entry.
 */
async function loadGraphEngines() {
    try {
        const resp = await fetch(apiUrl('/api/graph/engines'));
        const data = await resp.json();

        const selector = document.getElementById('graph-engine-selector');
        if (!selector) return;

        // Reset to just the demo option
        selector.textContent = '';
        const demoOpt = document.createElement('option');
        demoOpt.value = 'demo';
        demoOpt.textContent = 'Demo Graph';
        selector.appendChild(demoOpt);

        (data.engines || []).forEach(engine => {
            const opt = document.createElement('option');
            opt.value = engine.id;
            const statusTag = engine.status === 'running' ? '● LIVE' : engine.status.toUpperCase();
            opt.textContent = `${engine.name} (${statusTag})`;
            selector.appendChild(opt);
        });

        // Restore previously selected engine so dropdown stays in sync with displayed graph
        if (currentGraphEngine && selector.querySelector(`option[value="${currentGraphEngine}"]`)) {
            selector.value = currentGraphEngine;
        }
    } catch (err) {
        console.error('[Graph] Failed to load engines:', err);
    }
}

// ============================================================================
// ZOOM CONTROLS
// ============================================================================

/**
 * Zoom the graph in by 30% from the current zoom level.
 */
function graphZoomIn() {
    if (!cyGraph) return;
    cyGraph.zoom(cyGraph.zoom() * 1.3);
    cyGraph.center();
}

/**
 * Zoom the graph out by 30% from the current zoom level.
 */
function graphZoomOut() {
    if (!cyGraph) return;
    cyGraph.zoom(cyGraph.zoom() / 1.3);
    cyGraph.center();
}

/**
 * Fit all graph elements into the viewport with 30px padding.
 */
function graphFitAll() {
    if (!cyGraph) return;
    cyGraph.fit(undefined, 30);
}

/**
 * Center the graph in the viewport without changing zoom level.
 */
function graphCenter() {
    if (!cyGraph) return;
    cyGraph.center();
}
