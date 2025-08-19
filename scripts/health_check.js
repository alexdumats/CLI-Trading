#!/usr/bin/env node
/**
 * Simple health checker for all services.
 * Usage:
 *   node scripts/health_check.js
 *   OR with npm script: npm run health:check
 *
 * Env overrides (defaults assume docker-compose.override.yml exposing ports):
 *   ORCH_URL, ANALYST_URL, RISK_URL, EXEC_URL, NOTIF_URL, PORTF_URL,
 *   OPT_URL, MCP_URL, INTEGR_URL
 */

const DEFAULTS = {
  ORCH_URL: process.env.ORCH_URL || 'http://localhost:7001',
  ANALYST_URL: process.env.ANALYST_URL || 'http://localhost:7003',
  RISK_URL: process.env.RISK_URL || 'http://localhost:7004',
  EXEC_URL: process.env.EXEC_URL || 'http://localhost:7005',
  NOTIF_URL: process.env.NOTIF_URL || 'http://localhost:7006',
  PORTF_URL: process.env.PORTF_URL || 'http://localhost:7002',
  OPT_URL: process.env.OPT_URL || 'http://localhost:7007',
  MCP_URL: process.env.MCP_URL || 'http://localhost:7008',
  INTEGR_URL: process.env.INTEGR_URL || 'http://localhost:7010',
};

const targets = [
  ['orchestrator', DEFAULTS.ORCH_URL],
  ['portfolio-manager', DEFAULTS.PORTF_URL],
  ['market-analyst', DEFAULTS.ANALYST_URL],
  ['risk-manager', DEFAULTS.RISK_URL],
  ['trade-executor', DEFAULTS.EXEC_URL],
  ['notification-manager', DEFAULTS.NOTIF_URL],
  ['parameter-optimizer', DEFAULTS.OPT_URL],
  ['mcp-hub-controller', DEFAULTS.MCP_URL],
  ['integrations-broker', DEFAULTS.INTEGR_URL],
];

async function pingHealth(name, base, timeoutMs = 3000) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(`${base}/health`, { signal: ctrl.signal });
    const ok = res.ok;
    let body = {};
    try {
      body = await res.json();
    } catch {}
    return { name, base, ok, status: res.status, body };
  } catch (e) {
    return { name, base, ok: false, error: String(e?.message || e) };
  } finally {
    clearTimeout(t);
  }
}

async function main() {
  const results = await Promise.all(targets.map(([n, u]) => pingHealth(n, u)));
  let allOk = true;
  for (const r of results) {
    if (r.ok && r.status === 200) {
      console.log(`[OK] ${r.name} -> ${r.base} ::`, r.body);
    } else {
      allOk = false;
      console.error(`[FAIL] ${r.name} -> ${r.base} ::`, r.error || r.status, r.body || '');
    }
  }
  if (!allOk) process.exit(1);
}

main().catch((e) => {
  console.error('health_check_error:', e?.message || e);
  process.exit(2);
});
