import axios from 'axios';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitForPending(base, stream, group, token, timeoutMs = 15000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const url = `${base}/admin/streams/pending`;
      const res = await axios.get(url, { params: { stream, group }, headers: { 'X-Admin-Token': token } });
      const summary = res.data?.summary;
      const count = Array.isArray(summary) ? parseInt(summary[0] || 0, 10) : 0;
      if (count > 0) return count;
    } catch (e) {}
    await sleep(500);
  }
  return 0;
}

async function main() {
  const base = process.env.ORCH_URL || 'http://orchestrator:7001';
  const token = process.env.ADMIN_TOKEN;
  if (!token) throw new Error('ADMIN_TOKEN not set for test');

  // Trigger a notification that will fail Slack webhook (CI sets SLACK_WEBHOOK_URL to invalid URL)
  console.log('Triggering manual halt to generate notify.events');
  await axios.post(`${base}/admin/orchestrate/halt`, { reason: 'test' }, { headers: { 'X-Admin-Token': token } });

  console.log('Waiting for notify.events pending count');
  const pending = await waitForPending(base, 'notify.events', 'notify', token, 15000);
  console.log('notify.events pending =', pending);
  if (pending <= 0) {
    throw new Error('Expected pending messages on notify.events but found none');
  }

  // Optionally check DLQ is empty (due to retries not being implemented for pending re-reads)
  try {
    const dlqRes = await axios.get(`${base}/admin/streams/dlq`, { params: { stream: 'notify.events.dlq' }, headers: { 'X-Admin-Token': token } });
    console.log('DLQ entries (notify.events.dlq):', dlqRes.data?.entries?.length || 0);
  } catch (e) {
    console.log('DLQ check skipped or failed:', e.message);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
