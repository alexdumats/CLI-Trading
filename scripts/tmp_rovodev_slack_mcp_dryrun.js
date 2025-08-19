#!/usr/bin/env node
/**
 * Dry-run validator for Slack MCP -> Orchestrator/Notification Manager admin actions.
 * It prints the HTTP requests that Slack MCP should perform (method, URL, headers, body),
 * without sending any traffic unless --smoke is passed.
 *
 * Env:
 *  ORCH_URL (default http://orchestrator:7001)
 *  NOTIF_URL (default http://notification-manager:7006)
 *  ADMIN_TOKEN or ADMIN_TOKEN_FILE
 *
 * Usage:
 *  node scripts/tmp_rovodev_slack_mcp_dryrun.js --dry-run   # print only (default)
 *  node scripts/tmp_rovodev_slack_mcp_dryrun.js --smoke     # attempt /health and simple GETs
 */

import fs from 'node:fs';

const args = new Set(process.argv.slice(2));
const DRY_RUN = args.has('--dry-run') || !args.has('--smoke');
const SMOKE = args.has('--smoke');

const ORCH_URL = process.env.ORCH_URL || 'http://orchestrator:7001';
const NOTIF_URL = process.env.NOTIF_URL || 'http://notification-manager:7006';

let ADMIN_TOKEN = process.env.ADMIN_TOKEN || '';
if (!ADMIN_TOKEN && process.env.ADMIN_TOKEN_FILE) {
  try {
    ADMIN_TOKEN = fs.readFileSync(process.env.ADMIN_TOKEN_FILE, 'utf8').trim();
  } catch {}
}

function maskToken(tok) {
  if (!tok) return '(unset)';
  if (tok.length <= 8) return '*'.repeat(tok.length);
  return tok.slice(0, 2) + '***' + tok.slice(-4);
}

function printAction({ title, method, url, headers, body }) {
  console.log(`\n=== ${title} ===`);
  console.log(method, url);
  const safeHeaders = { ...headers };
  if (safeHeaders['X-Admin-Token'])
    safeHeaders['X-Admin-Token'] = maskToken(safeHeaders['X-Admin-Token']);
  console.log('Headers:', JSON.stringify(safeHeaders, null, 2));
  if (body) console.log('Body:', JSON.stringify(body, null, 2));
}

async function tryFetch(url, init) {
  try {
    const res = await fetch(url, init);
    const txt = await res.text();
    console.log(`[smoke] ${init?.method || 'GET'} ${url} -> ${res.status}`);
    console.log(txt.slice(0, 300));
  } catch (e) {
    console.log(`[smoke] ${init?.method || 'GET'} ${url} -> error: ${e?.message || e}`);
  }
}

async function main() {
  const commonHeaders = {
    'Content-Type': 'application/json',
    'X-Admin-Token': ADMIN_TOKEN || '(missing)',
  };

  // 1) Halt orchestration
  printAction({
    title: 'Halt Orchestration',
    method: 'POST',
    url: `${ORCH_URL}/admin/orchestrate/halt`,
    headers: commonHeaders,
    body: { reason: 'manual' },
  });

  // 2) Unhalt orchestration
  printAction({
    title: 'Unhalt Orchestration',
    method: 'POST',
    url: `${ORCH_URL}/admin/orchestrate/unhalt`,
    headers: commonHeaders,
    body: {},
  });

  // 3) Ack notification (example)
  printAction({
    title: 'Acknowledge Notification',
    method: 'POST',
    url: `${NOTIF_URL}/admin/notify/ack`,
    headers: commonHeaders,
    body: { traceId: 'example-trace-123' },
  });

  // 4) Streams pending
  printAction({
    title: 'Streams Pending (notify.events, group=notify)',
    method: 'GET',
    url: `${ORCH_URL}/admin/streams/pending?stream=notify.events&group=notify`,
    headers: commonHeaders,
  });

  // 5) Streams DLQ list & requeue
  printAction({
    title: 'Streams DLQ List (notify.events.dlq)',
    method: 'GET',
    url: `${ORCH_URL}/admin/streams/dlq?stream=notify.events.dlq`,
    headers: commonHeaders,
  });
  printAction({
    title: 'Streams DLQ Requeue (example id) ',
    method: 'POST',
    url: `${ORCH_URL}/admin/streams/dlq/requeue`,
    headers: commonHeaders,
    body: { dlqStream: 'notify.events.dlq', id: '1700000-0' },
  });

  if (SMOKE) {
    console.log('\n--- SMOKE MODE: attempting /health and GET endpoints ---');
    await tryFetch(`${ORCH_URL}/health`);
    await tryFetch(`${NOTIF_URL}/health`);
    await tryFetch(`${ORCH_URL}/admin/streams/pending?stream=notify.events&group=notify`, {
      headers: commonHeaders,
    });
    await tryFetch(`${ORCH_URL}/admin/streams/dlq?stream=notify.events.dlq`, {
      headers: commonHeaders,
    });
  } else {
    console.log('\n(dry-run) No network calls performed. Use --smoke to attempt basic checks.');
  }
}

main().catch((e) => {
  console.error('dryrun_error:', e?.message || e);
  process.exit(1);
});
