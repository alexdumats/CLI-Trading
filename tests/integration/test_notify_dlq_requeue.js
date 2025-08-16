import axios from 'axios';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function getDlqEntries(base, stream, token) {
  const url = `${base}/admin/streams/dlq`;
  const res = await axios.get(url, { params: { stream }, headers: { 'X-Admin-Token': token } });
  return res.data?.entries || [];
}

async function main() {
  const base = process.env.ORCH_URL || 'http://orchestrator:7001';
  const token = process.env.ADMIN_TOKEN;
  if (!token) throw new Error('ADMIN_TOKEN not set for test');

  console.log('Triggering manual halt to generate notify.events');
  await axios.post(`${base}/admin/orchestrate/halt`, { reason: 'dlq-requeue-test' }, { headers: { 'X-Admin-Token': token } });

  // Wait for DLQ entries to appear (due to failing Slack webhook in CI)
  let entries = [];
  for (let i = 0; i < 30; i++) {
    try { entries = await getDlqEntries(base, 'notify.events.dlq', token); } catch {}
    if ((entries?.length || 0) > 0) break;
    await sleep(1000);
  }
  console.log('DLQ entries found:', entries.length);
  if (entries.length === 0) {
    throw new Error('Expected DLQ entries for notify.events but found none');
  }

  // Requeue the first entry
  const id = entries[0].id;
  console.log('Requeuing DLQ id:', id);
  const rq = await axios.post(`${base}/admin/streams/dlq/requeue`, { dlqStream: 'notify.events.dlq', id }, { headers: { 'X-Admin-Token': token } });
  console.log('Requeue response:', rq.data);
}

main().catch((e) => { console.error(e); process.exit(1); });
