/**
 * Credential routes
 *
 * Delegates all actual secret storage to the credential_cli.py helper.
 * Never returns credential values — only metadata and existence flags.
 *
 * POST   /api/credentials/:integration          - store credential
 * DELETE /api/credentials/:integration          - delete credential
 * GET    /api/credentials/:integration/verify   - check existence
 * GET    /api/credentials/:integration/info     - non-sensitive metadata
 * GET    /api/credentials                       - list integration IDs
 */

'use strict';

const express = require('express');
const path    = require('path');
const { spawn } = require('child_process');
const router  = express.Router();

// ============================================================================
// CREDENTIAL CLI PATH
// ============================================================================

// Resolves via environment or config: AITEAMFORGE_DIR defaults to $HOME/aiteamforge
// When installed via AITeamForge homebrew, kanban-hooks land at $AITEAMFORGE_DIR/kanban-hooks/
const AITEAMFORGE_DIR  = process.env.AITEAMFORGE_DIR || path.join(process.env.HOME || '/Users/darrenehlers', 'aiteamforge');
const CREDENTIAL_CLI   = process.env.CREDENTIAL_CLI_PATH ||
    path.join(AITEAMFORGE_DIR, 'kanban-hooks', 'integrations', 'credential_cli.py');

// ============================================================================
// CLI HELPER
// ============================================================================

/**
 * Execute credential CLI command.
 * @param {string}      command      - Command to execute (set|delete|verify|info|list)
 * @param {string|null} integrationId
 * @param {object|null} inputData    - Data to pass via stdin (for set command)
 * @returns {Promise<object>}        - Parsed JSON response from CLI
 */
function execCredentialCli(command, integrationId = null, inputData = null) {
    return new Promise((resolve, reject) => {
        const args = [CREDENTIAL_CLI, command];
        if (integrationId) args.push(integrationId);

        const proc = spawn('python3', args, { stdio: ['pipe', 'pipe', 'pipe'] });
        let stdout = '';
        let stderr = '';

        proc.stdout.on('data', (data) => { stdout += data.toString(); });
        proc.stderr.on('data', (data) => { stderr += data.toString(); });

        proc.on('close', (code) => {
            try {
                resolve(JSON.parse(stdout));
            } catch (e) {
                reject(new Error(stderr || stdout || `Process exited with code ${code}`));
            }
        });

        proc.on('error', (err) => { reject(err); });

        if (inputData) proc.stdin.write(JSON.stringify(inputData));
        proc.stdin.end();
    });
}

// Shared integration ID validator
function validateIntegrationId(integration) {
    return /^[A-Za-z0-9_-]{2,20}$/.test(integration);
}

// ============================================================================
// ROUTES
// ============================================================================

/**
 * POST /api/credentials/:integration
 * Store credential for an integration.
 * Body: { type: "jira", endpoint: "...", user: "...", token: "..." }
 * NEVER returns credential values.
 */
router.post('/:integration', async (req, res) => {
    try {
        const { integration } = req.params;
        const credData        = req.body;

        if (!credData.type) {
            return res.status(400).json({ error: 'Missing required field: type' });
        }
        if (!validateIntegrationId(integration)) {
            return res.status(400).json({ error: 'Invalid integration ID format' });
        }

        const result = await execCredentialCli('set', integration, credData);
        if (result.success) {
            console.log(`\u2713 Credential stored for integration: ${integration}`);
            res.status(201).json({ success: true, message: `Credential stored for ${integration}` });
        } else {
            res.status(500).json({ error: result.error || 'Failed to store credential' });
        }
    } catch (error) {
        console.error('Error storing credential:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * DELETE /api/credentials/:integration
 * Delete credential for an integration.
 */
router.delete('/:integration', async (req, res) => {
    try {
        const { integration } = req.params;
        if (!validateIntegrationId(integration)) {
            return res.status(400).json({ error: 'Invalid integration ID format' });
        }

        const result = await execCredentialCli('delete', integration);
        if (result.success) {
            console.log(`\u2713 Credential deleted for integration: ${integration}`);
            res.json({ success: true, message: `Credential deleted for ${integration}` });
        } else {
            if (result.error && result.error.includes('not found')) {
                res.status(404).json({ error: result.error });
            } else {
                res.status(500).json({ error: result.error || 'Failed to delete credential' });
            }
        }
    } catch (error) {
        console.error('Error deleting credential:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/credentials/:integration/verify
 * Verify credential exists (NEVER returns actual values).
 */
router.get('/:integration/verify', async (req, res) => {
    try {
        const { integration } = req.params;
        if (!validateIntegrationId(integration)) {
            return res.status(400).json({ error: 'Invalid integration ID format' });
        }

        const result = await execCredentialCli('verify', integration);
        if (result.success) {
            res.json({ integration_id: integration, exists: result.data.exists });
        } else {
            res.status(500).json({ error: result.error || 'Failed to verify credential' });
        }
    } catch (error) {
        console.error('Error verifying credential:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/credentials/:integration/info
 * Get non-sensitive info about credential (type, dates, field presence).
 */
router.get('/:integration/info', async (req, res) => {
    try {
        const { integration } = req.params;
        if (!validateIntegrationId(integration)) {
            return res.status(400).json({ error: 'Invalid integration ID format' });
        }

        const result = await execCredentialCli('info', integration);
        if (result.success) {
            res.json({ integration_id: integration, ...result.data });
        } else {
            if (result.error && result.error.includes('not found')) {
                res.status(404).json({ error: result.error });
            } else {
                res.status(500).json({ error: result.error || 'Failed to get credential info' });
            }
        }
    } catch (error) {
        console.error('Error getting credential info:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

/**
 * GET /api/credentials
 * List all integration IDs (no values).
 */
router.get('/', async (req, res) => {
    try {
        const result = await execCredentialCli('list');
        if (result.success) {
            res.json({ integrations: result.data.integrations });
        } else {
            res.status(500).json({ error: result.error || 'Failed to list credentials' });
        }
    } catch (error) {
        console.error('Error listing credentials:', error);
        res.status(500).json({ error: 'Internal server error' });
    }
});

module.exports = router;
