/**
 * LCARS Credentials UI Module
 * Handles secure credential input and management in the INTEGRATIONS section.
 *
 * Security Notes:
 * - Credentials are NEVER stored in browser localStorage/sessionStorage
 * - Passwords are immediately sent to server and cleared from memory
 * - API never returns credential values, only metadata
 */

const CREDENTIALS_UI = {
    // API base URL
    apiBase: '/api/credentials',

    /**
     * Initialize the credentials UI
     * Called when the INTEGRATIONS section is loaded
     */
    async init() {
        console.log('[CREDENTIALS] Initializing credentials UI...');
        await this.refreshAllCredentialStatus();
    },

    /**
     * Refresh status for all known integrations
     */
    async refreshAllCredentialStatus() {
        const integrations = ['ME', 'MON'];
        for (const id of integrations) {
            await this.refreshCredentialStatus(id);
        }
    },

    /**
     * Refresh status for a single integration
     */
    async refreshCredentialStatus(integrationId) {
        const statusEl = document.getElementById(`cred-status-${integrationId}`);
        const infoEl = document.getElementById(`cred-info-${integrationId}`);
        const deleteBtn = document.getElementById(`delete-btn-${integrationId}`);

        if (!statusEl) return;

        try {
            const response = await fetch(`${this.apiBase}/${integrationId}/verify`);
            const data = await response.json();

            if (data.exists) {
                // Get additional info
                const infoResponse = await fetch(`${this.apiBase}/${integrationId}/info`);
                const info = await infoResponse.json();

                statusEl.textContent = 'CONFIGURED';
                statusEl.style.background = 'var(--lcars-cyan)';
                statusEl.style.color = '#000';

                // Format last used
                let lastUsed = 'Never';
                if (info.lastUsed) {
                    const date = new Date(info.lastUsed);
                    const now = new Date();
                    const diffMs = now - date;
                    const diffMins = Math.floor(diffMs / 60000);
                    const diffHours = Math.floor(diffMins / 60);
                    const diffDays = Math.floor(diffHours / 24);

                    if (diffMins < 60) {
                        lastUsed = `${diffMins}m ago`;
                    } else if (diffHours < 24) {
                        lastUsed = `${diffHours}h ago`;
                    } else {
                        lastUsed = `${diffDays}d ago`;
                    }
                }

                infoEl.innerHTML = `
                    <div>Type: ${info.type || 'unknown'}</div>
                    <div>Last used: ${lastUsed}</div>
                    ${info.hasEndpoint ? '<div>Endpoint: Configured</div>' : ''}
                    ${info.hasUser ? '<div>User: Configured</div>' : ''}
                `;

                if (deleteBtn) deleteBtn.style.display = 'inline-block';
            } else {
                statusEl.textContent = 'NOT CONFIGURED';
                statusEl.style.background = 'var(--lcars-orange)';
                statusEl.style.color = '#000';
                infoEl.innerHTML = '<div>No credentials stored</div>';
                if (deleteBtn) deleteBtn.style.display = 'none';
            }
        } catch (error) {
            console.error(`[CREDENTIALS] Error checking ${integrationId}:`, error);
            statusEl.textContent = 'ERROR';
            statusEl.style.background = 'var(--lcars-red)';
            statusEl.style.color = '#fff';
            infoEl.innerHTML = '<div>Failed to check status</div>';
        }
    },

    /**
     * Show the credential input modal
     */
    showCredentialModal(integrationId, credType) {
        const modal = document.getElementById('credential-modal');
        const titleEl = document.getElementById('modal-title');
        const integrationIdInput = document.getElementById('cred-integration-id');
        const typeInput = document.getElementById('cred-type');

        // Set hidden fields
        integrationIdInput.value = integrationId;
        typeInput.value = credType;

        // Set title
        const titles = {
            'jira': 'CONFIGURE JIRA',
            'monday': 'CONFIGURE MONDAY.COM'
        };
        titleEl.textContent = titles[credType] || 'CONFIGURE INTEGRATION';

        // Show appropriate fields
        document.querySelectorAll('.cred-fields').forEach(el => el.style.display = 'none');
        const fieldsEl = document.getElementById(`${credType}-fields`);
        if (fieldsEl) fieldsEl.style.display = 'block';

        // Clear form fields
        document.getElementById('cred-endpoint')?.value && (document.getElementById('cred-endpoint').value = '');
        document.getElementById('cred-user')?.value && (document.getElementById('cred-user').value = '');
        document.getElementById('cred-token-jira')?.value && (document.getElementById('cred-token-jira').value = '');
        document.getElementById('cred-token-monday')?.value && (document.getElementById('cred-token-monday').value = '');

        // Show modal
        modal.style.display = 'flex';
    },

    /**
     * Hide the credential input modal
     */
    hideCredentialModal() {
        const modal = document.getElementById('credential-modal');
        modal.style.display = 'none';

        // Clear sensitive fields immediately
        const tokenFields = ['cred-token-jira', 'cred-token-monday'];
        tokenFields.forEach(id => {
            const el = document.getElementById(id);
            if (el) el.value = '';
        });
    },

    /**
     * Toggle password visibility
     */
    togglePassword(inputId) {
        const input = document.getElementById(inputId);
        if (input) {
            input.type = input.type === 'password' ? 'text' : 'password';
        }
    },

    /**
     * Save credential from form
     */
    async saveCredential(event) {
        event.preventDefault();

        const integrationId = document.getElementById('cred-integration-id').value;
        const credType = document.getElementById('cred-type').value;

        // Build credential data based on type
        let credData = { type: credType };

        if (credType === 'jira') {
            const endpoint = document.getElementById('cred-endpoint').value.trim();
            const user = document.getElementById('cred-user').value.trim();
            const token = document.getElementById('cred-token-jira').value;

            if (!endpoint || !user || !token) {
                alert('Please fill in all fields');
                return;
            }

            credData.endpoint = endpoint;
            credData.user = user;
            credData.token = token;
        } else if (credType === 'monday') {
            const token = document.getElementById('cred-token-monday').value;

            if (!token) {
                alert('Please enter your API token');
                return;
            }

            credData.token = token;
        }

        try {
            const response = await fetch(`${this.apiBase}/${integrationId}`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(credData)
            });

            const result = await response.json();

            if (response.ok && result.success) {
                console.log(`[CREDENTIALS] Saved credentials for ${integrationId}`);
                this.hideCredentialModal();
                await this.refreshCredentialStatus(integrationId);

                // Show success feedback
                const statusEl = document.getElementById(`cred-status-${integrationId}`);
                if (statusEl) {
                    statusEl.textContent = 'SAVED!';
                    setTimeout(() => this.refreshCredentialStatus(integrationId), 1500);
                }
            } else {
                alert(result.error || 'Failed to save credentials');
            }
        } catch (error) {
            console.error('[CREDENTIALS] Save error:', error);
            alert('Error saving credentials. Check console for details.');
        } finally {
            // Clear sensitive data from memory
            credData.token = null;
            credData = null;
        }
    },

    /**
     * Delete credential
     */
    async deleteCredential(integrationId) {
        if (!confirm(`Delete credentials for ${integrationId}? This cannot be undone.`)) {
            return;
        }

        try {
            const response = await fetch(`${this.apiBase}/${integrationId}`, {
                method: 'DELETE'
            });

            const result = await response.json();

            if (response.ok && result.success) {
                console.log(`[CREDENTIALS] Deleted credentials for ${integrationId}`);
                await this.refreshCredentialStatus(integrationId);
            } else {
                alert(result.error || 'Failed to delete credentials');
            }
        } catch (error) {
            console.error('[CREDENTIALS] Delete error:', error);
            alert('Error deleting credentials. Check console for details.');
        }
    },

    /**
     * Test connection for an integration
     */
    async testConnection(integrationId) {
        const testBtn = document.getElementById(`test-btn-${integrationId}`);
        const originalText = testBtn?.textContent;

        if (testBtn) {
            testBtn.textContent = 'TESTING...';
            testBtn.disabled = true;
        }

        try {
            // For now, just verify the credential exists
            // Future: Add actual connection test endpoints
            const response = await fetch(`${this.apiBase}/${integrationId}/verify`);
            const data = await response.json();

            if (data.exists) {
                if (testBtn) {
                    testBtn.textContent = 'OK!';
                    testBtn.style.background = 'var(--lcars-cyan)';
                }
                console.log(`[CREDENTIALS] Test passed for ${integrationId}`);
            } else {
                if (testBtn) {
                    testBtn.textContent = 'NO CREDS';
                    testBtn.style.background = 'var(--lcars-red)';
                }
            }
        } catch (error) {
            console.error('[CREDENTIALS] Test error:', error);
            if (testBtn) {
                testBtn.textContent = 'ERROR';
                testBtn.style.background = 'var(--lcars-red)';
            }
        } finally {
            // Reset button after delay
            setTimeout(() => {
                if (testBtn) {
                    testBtn.textContent = originalText;
                    testBtn.disabled = false;
                    testBtn.style.background = '';
                }
            }, 2000);
        }
    }
};

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    // Initialize credentials UI when integrations section is shown
    // This is triggered by the LCARS core when switching sections
    CREDENTIALS_UI.init();
});

// Also expose for manual refresh
window.CREDENTIALS_UI = CREDENTIALS_UI;
