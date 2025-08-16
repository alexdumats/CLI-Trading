import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import pg from 'pg';
const { Client } = pg;

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function run() {
  const client = new Client({
    host: process.env.POSTGRES_HOST || 'localhost',
    port: parseInt(process.env.POSTGRES_PORT || '5432', 10),
    user: process.env.POSTGRES_USER || 'postgres',
    password: process.env.POSTGRES_PASSWORD || '',
    database: process.env.POSTGRES_DB || 'postgres',
  });
  await client.connect();
  await client.query('begin');
  try {
    await client.query('create table if not exists migrations (id serial primary key, name text unique not null, applied_at timestamptz not null default now())');
    const dir = path.join(__dirname, '..', 'db', 'migrations');
    const files = fs.readdirSync(dir).filter(f => f.endsWith('.sql')).sort();
    for (const f of files) {
      const { rows } = await client.query('select 1 from migrations where name=$1', [f]);
      if (rows.length) continue;
      const sql = fs.readFileSync(path.join(dir, f), 'utf8');
      await client.query(sql);
      await client.query('insert into migrations(name) values($1)', [f]);
      console.log(`[migrate] applied ${f}`);
    }
    await client.query('commit');
  } catch (e) {
    await client.query('rollback');
    console.error('[migrate] failed:', e);
    process.exit(1);
  } finally {
    await client.end();
  }
}

run();
