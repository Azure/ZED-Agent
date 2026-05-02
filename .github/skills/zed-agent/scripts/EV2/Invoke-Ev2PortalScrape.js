#!/usr/bin/env node
/**
 * Invoke-Ev2PortalScrape.js
 *
 * Queries the EV2 portal's proxy API for gov-cloud (Fairfax/Mooncake) rollout data.
 * Uses Edge CDP to extract the portal auth token from sessionStorage, then calls
 * the portal's backend API directly via page.evaluate(fetch(...)).
 *
 * This is much simpler and more reliable than the old approach of intercepting
 * XHR responses or parsing DOM — the API returns the same JSON as the Prod REST API.
 *
 * Usage:
 *   node Invoke-Ev2PortalScrape.js --cloud Fairfax --serviceTreeId <guid> --serviceGroup <sg> --rolloutId <guid>
 *
 * Output: JSON to stdout. Always valid JSON, even on error.
 *   { "status": "ok", "data": { ... } }                           — success
 *   { "status": "error", "code": "AUTH_REQUIRED", "message": ... } — no portal token
 *   { "status": "error", "code": "CDP_CONNECT_FAILED", ... }       — Edge not available
 */

const { chromium } = require('playwright-core');

// ── Arg parsing ──
const args = process.argv.slice(2);
function getArg(name) {
    const idx = args.indexOf(`--${name}`);
    return idx !== -1 && idx + 1 < args.length ? args[idx + 1] : null;
}

const cloud         = getArg('cloud')         || 'Fairfax';
const serviceTreeId = getArg('serviceTreeId') || 'fb10185a-465d-42cd-b339-7d0d9331c340';
const serviceGroup  = getArg('serviceGroup')  || '';
const rolloutId     = getArg('rolloutId')     || '';
const cdpUrl        = getArg('cdpUrl')        || 'http://localhost:9223';
const maxRetries    = parseInt(getArg('retries') || '2', 10);

if (!serviceGroup || !rolloutId) {
    outputJson({ status: 'error', code: 'INVALID_ARGS', message: '--serviceGroup and --rolloutId are required.' });
    process.exit(1);
}

function outputJson(obj) {
    process.stdout.write(JSON.stringify(obj) + '\n');
}

// ── Main ──
(async () => {
    let browser = null;

    try {
        browser = await chromium.connectOverCDP(cdpUrl, { timeout: 10000 });
    } catch (err) {
        outputJson({ status: 'error', code: 'CDP_CONNECT_FAILED', message: `Cannot connect to Edge CDP at ${cdpUrl}: ${err.message}` });
        process.exit(1);
    }

    try {
        const context = browser.contexts()[0];
        if (!context) {
            outputJson({ status: 'error', code: 'NO_CONTEXT', message: 'No browser context found. Is Edge running?' });
            process.exit(1);
        }

        // Find an existing ev2portal tab to extract the auth token from
        const pages = context.pages();
        let portalPage = pages.find(p => p.url().includes('ev2portal.azure.net'));

        if (!portalPage) {
            // No portal tab open — open one and wait for auth
            portalPage = pages.find(p =>
                p.url() === 'about:blank' || p.url().startsWith('edge://newtab')
            ) || await context.newPage();

            await portalPage.goto('https://ra.ev2portal.azure.net', {
                waitUntil: 'domcontentloaded', timeout: 30000
            }).catch(() => {});

            // Wait for MSAL to complete auth flow
            await new Promise(r => setTimeout(r, 5000));

            if (portalPage.url().includes('login.microsoftonline')) {
                outputJson({
                    status: 'error',
                    code: 'AUTH_REQUIRED',
                    message: 'EV2 portal requires authentication. Open https://ra.ev2portal.azure.net in Edge and sign in manually.',
                    portalUrl: 'https://ra.ev2portal.azure.net'
                });
                process.exit(1);
            }
        }

        // Extract portal self-token from sessionStorage
        // Key pattern: contains "accesstoken", ".default", and the portal client ID "4a49310a"
        const token = await portalPage.evaluate(() => {
            for (let i = 0; i < sessionStorage.length; i++) {
                const key = sessionStorage.key(i);
                if (key.includes('accesstoken') && key.includes('.default') && key.includes('4a49310a')) {
                    try {
                        const val = JSON.parse(sessionStorage.getItem(key));
                        return val.secret || null;
                    } catch { return null; }
                }
            }
            return null;
        });

        if (!token) {
            outputJson({
                status: 'error',
                code: 'AUTH_REQUIRED',
                message: 'No EV2 portal token found in sessionStorage. Open https://ra.ev2portal.azure.net in Edge and sign in.',
                portalUrl: 'https://ra.ev2portal.azure.net'
            });
            process.exit(1);
        }

        // Call the portal proxy API
        const apiUrl = `https://ra.ev2portal.azure.net/api/rollout/${serviceTreeId}/${encodeURIComponent(serviceGroup)}/${rolloutId}?rolloutInfra=${cloud}`;

        let lastError = null;
        for (let attempt = 1; attempt <= maxRetries; attempt++) {
            try {
                const result = await portalPage.evaluate(async ({ url, bearerToken }) => {
                    const resp = await fetch(url, {
                        headers: { 'Authorization': `Bearer ${bearerToken}` }
                    });
                    if (!resp.ok) {
                        return { _httpError: true, status: resp.status, statusText: resp.statusText };
                    }
                    return await resp.json();
                }, { url: apiUrl, bearerToken: token });

                if (result._httpError) {
                    if (result.status === 401 || result.status === 403) {
                        outputJson({
                            status: 'error',
                            code: 'AUTH_EXPIRED',
                            message: `Portal token expired (HTTP ${result.status}). Re-authenticate at https://ra.ev2portal.azure.net`,
                            portalUrl: 'https://ra.ev2portal.azure.net'
                        });
                        process.exit(1);
                    }
                    lastError = `HTTP ${result.status} ${result.statusText}`;
                    if (attempt < maxRetries) await new Promise(r => setTimeout(r, 3000));
                    continue;
                }

                // Success
                outputJson({ status: 'ok', source: 'portalApi', cloud, rolloutId, data: result });
                process.exit(0);

            } catch (err) {
                lastError = err.message;
                if (attempt < maxRetries) await new Promise(r => setTimeout(r, 3000));
            }
        }

        outputJson({
            status: 'error',
            code: 'API_FAILED',
            message: `Portal API failed after ${maxRetries} attempts: ${lastError}`,
            apiUrl
        });

    } finally {
        if (browser) {
            try { browser.close(); } catch (_) { /* disconnect only */ }
        }
    }
})();
