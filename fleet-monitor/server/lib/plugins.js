'use strict';

/**
 * Plugin loader for fleet-monitor.
 *
 * Reads ~/.aiteamforge/organization.yaml to determine which plugins are
 * enabled, then resolves their plugin.yaml manifests from
 *   <repo-root>/homebrew-tap/fleet-monitor/plugins/<slug>/plugin.yaml
 *
 * No plugin is loaded by default — the default fleet-monitor install is
 * org-agnostic. Client-specific dashboards (e.g. Main Event, DoubleNode)
 * live in opt-in plugins.
 *
 * Exposes:
 *   loadEnabledPlugins()        -> [{ slug, manifest, pluginDir, publicDir, dashboardsDir, pageRoutes }]
 *   mountPlugins(app, plugins)  -> registers static dirs + page routes on Express app
 *   loadPluginDashboards(plugins) -> merges per-plugin dashboards/divisions JSON (see routes/dashboards.js)
 */

const fs   = require('fs');
const path = require('path');
const os   = require('os');

// js-yaml is an optional runtime dep. If it's not installed we still boot, but
// plugin config / manifests will not be parseable. In that case we log once
// and skip plugin loading entirely.
let yaml = null;
try {
    yaml = require('js-yaml');
} catch (_err) {
    yaml = null;
}

const ORG_CONFIG_PATH = path.join(os.homedir(), '.aiteamforge', 'organization.yaml');
const PLUGINS_ROOT    = path.join(__dirname, '..', '..', 'plugins');

function _log(msg) { console.log(`[plugins] ${msg}`); }
function _warn(msg) { console.warn(`[plugins] ${msg}`); }

/**
 * Read ~/.aiteamforge/organization.yaml and return the list of enabled plugin slugs.
 * Returns [] for all non-fatal failures (no file, no yaml parser, malformed, etc.).
 */
function readEnabledPluginSlugs() {
    if (!yaml) {
        _warn('js-yaml not installed — plugin layer disabled. `npm install js-yaml` in the fleet-monitor server to enable plugins.');
        return [];
    }
    if (!fs.existsSync(ORG_CONFIG_PATH)) {
        return []; // default install — no org config, no plugins
    }
    try {
        const raw = fs.readFileSync(ORG_CONFIG_PATH, 'utf8');
        const doc = yaml.load(raw);
        const enabled = (doc && doc.plugins && doc.plugins.enabled) || [];
        if (!Array.isArray(enabled)) {
            _warn(`organization.yaml: plugins.enabled is not a list, ignoring`);
            return [];
        }
        return enabled.filter(s => typeof s === 'string' && s.length > 0);
    } catch (err) {
        _warn(`failed to read ${ORG_CONFIG_PATH}: ${err.message}`);
        return [];
    }
}

/**
 * Resolve a single plugin slug to a loaded plugin descriptor. Returns null on failure.
 */
function _loadPlugin(slug) {
    // Reject any slug containing path separators or traversal segments before joining.
    // organization.yaml is user-writable, so treat slug as untrusted input.
    if (typeof slug !== 'string' || !/^[a-z0-9][a-z0-9-]*$/.test(slug)) {
        _warn(`plugin slug "${slug}" rejected — must match [a-z0-9][a-z0-9-]*`);
        return null;
    }

    const pluginDir    = path.resolve(PLUGINS_ROOT, slug);
    // Defense-in-depth: confirm the resolved directory stays under PLUGINS_ROOT
    // even if the slug regex is later loosened.
    const rootWithSep  = PLUGINS_ROOT.endsWith(path.sep) ? PLUGINS_ROOT : PLUGINS_ROOT + path.sep;
    if (!pluginDir.startsWith(rootWithSep)) {
        _warn(`plugin "${slug}" resolved outside PLUGINS_ROOT — refusing to load`);
        return null;
    }
    const manifestPath = path.join(pluginDir, 'plugin.yaml');

    if (!fs.existsSync(manifestPath)) {
        _warn(`plugin "${slug}" enabled but plugin.yaml not found at ${manifestPath}`);
        return null;
    }

    let manifest;
    try {
        manifest = yaml.load(fs.readFileSync(manifestPath, 'utf8')) || {};
    } catch (err) {
        _warn(`failed to parse plugin.yaml for "${slug}": ${err.message}`);
        return null;
    }

    const mounts         = manifest.mounts || [];
    const dashboardsDir  = _resolveFromManifest(pluginDir, manifest, 'dashboards_dir');
    const publicMount    = Array.isArray(mounts) ? mounts.find(m => m && m.dir) : null;
    const publicDir      = publicMount ? path.resolve(pluginDir, publicMount.dir.replace(/^\.\//, '')) : null;
    const publicHttpPath = publicMount ? publicMount.path : null;
    const pageRoutes     = Array.isArray(manifest.page_routes) ? manifest.page_routes : [];

    return {
        slug,
        manifest,
        pluginDir,
        publicDir,
        publicHttpPath,
        dashboardsDir,
        pageRoutes,
    };
}

function _resolveFromManifest(pluginDir, manifest, key) {
    // dashboards_dir lives either at top level or inside mounts object.
    // Support both shapes in plugin.yaml.
    if (typeof manifest[key] === 'string') {
        return path.resolve(pluginDir, manifest[key].replace(/^\.\//, ''));
    }
    if (manifest.mounts && typeof manifest.mounts === 'object' && !Array.isArray(manifest.mounts)) {
        if (typeof manifest.mounts[key] === 'string') {
            return path.resolve(pluginDir, manifest.mounts[key].replace(/^\.\//, ''));
        }
    }
    // Scan mounts array for a mount whose key name matches (e.g. dashboards_dir as its own field)
    if (Array.isArray(manifest.mounts)) {
        for (const m of manifest.mounts) {
            if (m && typeof m[key] === 'string') {
                return path.resolve(pluginDir, m[key].replace(/^\.\//, ''));
            }
        }
    }
    return null;
}

/**
 * Load all enabled plugins (empty array if none enabled or js-yaml missing).
 */
function loadEnabledPlugins() {
    const slugs = readEnabledPluginSlugs();
    if (slugs.length === 0) return [];

    const loaded = [];
    for (const slug of slugs) {
        const p = _loadPlugin(slug);
        if (p) {
            loaded.push(p);
            _log(`loaded plugin "${slug}" v${(p.manifest.plugin && p.manifest.plugin.version) || '?'}`);
        }
    }
    return loaded;
}

/**
 * Mount plugin static assets and page routes on the given Express app.
 */
function mountPlugins(app, plugins, express) {
    for (const p of plugins) {
        if (p.publicDir && p.publicHttpPath && fs.existsSync(p.publicDir)) {
            app.use(p.publicHttpPath, express.static(p.publicDir));
            _log(`mounted ${p.publicHttpPath} -> ${p.publicDir}`);
        }
        for (const pr of p.pageRoutes) {
            if (!pr || !pr.route) continue;
            if (pr.redirect) {
                app.get(pr.route, (req, res) => res.redirect(302, pr.redirect));
                _log(`route ${pr.route} -> redirect ${pr.redirect}`);
            } else if (pr.file && p.publicDir) {
                const filePath = path.resolve(p.publicDir, pr.file);
                app.get(pr.route, (req, res) => res.sendFile(filePath));
                _log(`route ${pr.route} -> ${filePath}`);
            }
        }
    }
}

/**
 * Merge per-plugin dashboards/divisions JSON files. Returns
 *   { dashboards: [...], divisions: [...], all_fleet_dashboard_ids: [...] }
 * where each dashboard is tagged with `plugin_slug` so routes/dashboards.js
 * knows not to persist writes to it.
 */
function loadPluginDashboards(plugins) {
    const merged = { dashboards: [], divisions: [], all_fleet_dashboard_ids: [] };
    for (const p of plugins) {
        if (!p.dashboardsDir || !fs.existsSync(p.dashboardsDir)) continue;
        let entries;
        try {
            entries = fs.readdirSync(p.dashboardsDir).filter(f => f.endsWith('.json'));
        } catch (err) {
            _warn(`failed to list ${p.dashboardsDir}: ${err.message}`);
            continue;
        }
        for (const fname of entries) {
            const fpath = path.join(p.dashboardsDir, fname);
            try {
                const doc = JSON.parse(fs.readFileSync(fpath, 'utf8'));
                (doc.dashboards || []).forEach(d => {
                    merged.dashboards.push({ ...d, plugin_slug: p.slug });
                });
                (doc.divisions || []).forEach(d => {
                    merged.divisions.push({ ...d, plugin_slug: p.slug });
                });
                if (Array.isArray(doc.all_fleet_dashboard_ids)) {
                    merged.all_fleet_dashboard_ids.push(...doc.all_fleet_dashboard_ids);
                }
            } catch (err) {
                _warn(`failed to parse ${fpath}: ${err.message}`);
            }
        }
    }
    return merged;
}

module.exports = {
    loadEnabledPlugins,
    mountPlugins,
    loadPluginDashboards,
    ORG_CONFIG_PATH,
    PLUGINS_ROOT,
};
