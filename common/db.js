import pg from 'pg';
import fs from 'node:fs';
const { Pool } = pg;

export function createPgPool() {
  let password = process.env.POSTGRES_PASSWORD || '';
  if (process.env.POSTGRES_PASSWORD_FILE && !password) {
    try {
      password = fs.readFileSync(process.env.POSTGRES_PASSWORD_FILE, 'utf8').trim();
    } catch {}
  }
  const config = {
    host: process.env.POSTGRES_HOST || 'localhost',
    port: parseInt(process.env.POSTGRES_PORT || '5432', 10),
    user: process.env.POSTGRES_USER || 'postgres',
    password,
    database: process.env.POSTGRES_DB || 'postgres',
    max: 10,
    idleTimeoutMillis: 30000,
  };
  return new Pool(config);
}

export async function insertAudit(
  pool,
  { type, severity = 'info', payload = {}, requestId = null, traceId = null }
) {
  const sql = `insert into audit_events (ts, type, severity, payload, request_id, trace_id)
               values (now(), $1, $2, $3::jsonb, $4, $5)`;
  await pool.query(sql, [type, severity, JSON.stringify(payload), requestId, traceId]);
}

export async function upsertPnl(
  pool,
  { date, startEquity, realized, percent, dailyTargetPct, halted }
) {
  const sql = `insert into pnl_days (date, start_equity, realized, percent, daily_target_pct, halted, updated_at)
               values ($1, $2, $3, $4, $5, $6, now())
               on conflict (date) do update set start_equity=excluded.start_equity, realized=excluded.realized,
                 percent=excluded.percent, daily_target_pct=excluded.daily_target_pct, halted=excluded.halted, updated_at=now()`;
  await pool.query(sql, [date, startEquity, realized, percent, dailyTargetPct, halted]);
}
