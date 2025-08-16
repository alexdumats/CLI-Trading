import axios from 'axios';

async function main() {
  const base = process.env.ORCH_URL || 'http://localhost:7001';
  const adminToken = process.env.ADMIN_TOKEN;
  if (adminToken) {
    console.log('Resetting PnL...');
    try { await axios.post(`${base}/admin/pnl/reset`, {}, { headers: { 'X-Admin-Token': adminToken } }); } catch {}
  }
  console.log('Checking PnL status');
  let status = await axios.get(`${base}/pnl/status`).then(r => r.data).catch(e => ({ error: e.message }));
  console.log('Initial status:', status);

  console.log('Triggering run 1');
  let r1 = await axios.post(`${base}/orchestrate/run`, { mode: 'http', symbol: 'BTC-USD' }).then(r => r.data).catch(e => ({ error: e.message }));
  console.log('Run1 resp:', r1);

  // Wait briefly to allow async fill to publish
  await new Promise(res => setTimeout(res, 250));

  status = await axios.get(`${base}/pnl/status`).then(r => r.data).catch(e => ({ error: e.message }));
  console.log('After 1 fill:', status);

  console.log('Triggering run 2 (may be halted)');
  let r2;
  try {
    const resp = await axios.post(`${base}/orchestrate/run`, { mode: 'http', symbol: 'BTC-USD' });
    r2 = { status: resp.status, data: resp.data };
  } catch (e) {
    if (e.response) r2 = { status: e.response.status, data: e.response.data };
    else r2 = { error: e.message };
  }
  console.log('Run2 resp:', r2);
}

main().catch(e => { console.error(e); process.exit(1); });
