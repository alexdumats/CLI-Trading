#!/usr/bin/env node
/**
 * Ops CLI for Streams and Notifications
 *
 * Usage examples:
 *  node scripts/ops_cli.js streams:pending --stream notify.events --group notify
 *  node scripts/ops_cli.js streams:dlq:list --stream notify.events.dlq
 *  node scripts/ops_cli.js streams:dlq:requeue --stream notify.events.dlq --id 1700000-0
 *  node scripts/ops_cli.js notify:ack --traceId 12345
 *  node scripts/ops_cli.js notify:recent
 *  node scripts/ops_cli.js orch:halt --reason manual
 *  node scripts/ops_cli.js orch:unhalt
 *
 * Env:
 *  ORCH_URL (default http://localhost:7001)
 *  NOTIF_URL (default http://localhost:7006)
 *  ADMIN_TOKEN or ADMIN_TOKEN_FILE
 */

import fs from 'node:fs';

const args = process.argv.slice(2);
const cmd = args[0];
const opts = parseArgs(args.slice(1));

const ORCH_URL = process.env.ORCH_URL || 'http://localhost:7001';
const NOTIF_URL = process.env.NOTIF_URL || 'http://localhost:7006';
let ADMIN_TOKEN = process.env.ADMIN_TOKEN || '';
if (!ADMIN_TOKEN && process.env.ADMIN_TOKEN_FILE) {
  try { ADMIN_TOKEN = fs.readFileSync(process.env.ADMIN_TOKEN_FILE, 'utf8').trim(); } catch {}
}

function parseArgs(list) {
  const res = {};
  for (let i = 0; i < list.length; i++) {
    const t = list[i];
    if (t.startsWith('--')) {
      const key = t.slice(2);
      const val = list[i + 1] && !list[i + 1].startsWith('--') ? list[++i] : 'true';
      res[key] = val;
    }
  }
  return res;
}

async function main() {
  try {
    switch (cmd) {
      case 'help':
      case undefined:
        printHelp();
        return;
      case 'streams:pending':
        requireAdmin();
        await streamsPending(opts);
        return;
      case 'streams:dlq:list':
        requireAdmin();
        await streamsDlqList(opts);
        return;
      case 'streams:dlq:requeue':
        requireAdmin();
        await streamsDlqRequeue(opts);
        return;
      case 'notify:ack':
        requireAdmin();
        await notifyAck(opts);
        return;
      case 'notify:recent':
        await notifyRecent();
        return;
      case 'orch:halt':
        requireAdmin();
        await orchHalt(opts);
        return;
      case 'orch:unhalt':
        requireAdmin();
        await orchUnhalt();
        return;
      default:
        console.error('Unknown command:', cmd);
        printHelp();
        process.exit(1);
    }
  } catch (e) {
    console.error('Error:', e?.response?.data || e?.message || e);
    process.exit(1);
  }
}

function requireAdmin() {
  if (!ADMIN_TOKEN) {
    console.error('ADMIN_TOKEN not set. Provide ADMIN_TOKEN or ADMIN_TOKEN_FILE.');
    process.exit(2);
  }
}

async function streamsPending({ stream, group }) {
  if (!stream || !group) throw new Error('Usage: streams:pending --stream <name> --group <name>');
  const url = `${ORCH_URL}/admin/streams/pending?stream=${encodeURIComponent(stream)}&group=${encodeURIComponent(group)}`;
  const res = await fetch(url, { headers: { 'X-Admin-Token': ADMIN_TOKEN } });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  console.log(JSON.stringify(await res.json(), null, 2));
}

async function streamsDlqList({ stream }) {
  if (!stream) throw new Error('Usage: streams:dlq:list --stream <dlq-stream>');
  const url = `${ORCH_URL}/admin/streams/dlq?stream=${encodeURIComponent(stream)}`;
  const res = await fetch(url, { headers: { 'X-Admin-Token': ADMIN_TOKEN } });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  console.log(JSON.stringify(await res.json(), null, 2));
}

async function streamsDlqRequeue({ stream, id }) {
  if (!stream || !id) throw new Error('Usage: streams:dlq:requeue --stream <dlq-stream> --id <id>');
  const url = `${ORCH_URL}/admin/streams/dlq/requeue`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Admin-Token': ADMIN_TOKEN },
    body: JSON.stringify({ dlqStream: stream, id })
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  console.log(JSON.stringify(await res.json(), null, 2));
}

async function notifyAck({ traceId, requestId }) {
  const id = traceId || requestId;
  if (!id) throw new Error('Usage: notify:ack --traceId <id> | --requestId <id>');
  const url = `${NOTIF_URL}/admin/notify/ack`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Admin-Token': ADMIN_TOKEN },
    body: JSON.stringify(traceId ? { traceId } : { requestId })
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  console.log(JSON.stringify(await res.json(), null, 2));
}

async function notifyRecent() {
  const url = `${NOTIF_URL}/notify/recent`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  console.log(JSON.stringify(await res.json(), null, 2));
}

async function orchHalt({ reason = 'manual' }) {
  const url = `${ORCH_URL}/admin/orchestrate/halt`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Admin-Token': ADMIN_TOKEN },
    body: JSON.stringify({ reason })
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  console.log(JSON.stringify(await res.json(), null, 2));
}

async function orchUnhalt() {
  const url = `${ORCH_URL}/admin/orchestrate/unhalt`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Admin-Token': ADMIN_TOKEN }
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  console.log(JSON.stringify(await res.json(), null, 2));
}

function printHelp() {
  console.log(`Ops CLI

Usage:
  streams:pending --stream <name> --group <name>
  streams:dlq:list --stream <dlq-stream>
  streams:dlq:requeue --stream <dlq-stream> --id <id>
  notify:ack --traceId <id> | --requestId <id>
  notify:recent
  orch:halt [--reason text]
  orch:unhalt

Env:
  ORCH_URL (default http://localhost:7001)
  NOTIF_URL (default http://localhost:7006)
  ADMIN_TOKEN or ADMIN_TOKEN_FILE
`);
}

main();
