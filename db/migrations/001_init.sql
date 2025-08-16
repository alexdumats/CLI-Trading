create table if not exists migrations (
  id serial primary key,
  name text unique not null,
  applied_at timestamptz not null default now()
);

create table if not exists audit_events (
  id bigserial primary key,
  ts timestamptz not null,
  type text not null,
  severity text not null,
  payload jsonb not null default '{}'::jsonb,
  request_id text,
  trace_id text
);

create table if not exists pnl_days (
  date date primary key,
  start_equity numeric not null,
  realized numeric not null,
  percent numeric not null,
  daily_target_pct numeric not null,
  halted boolean not null default false,
  updated_at timestamptz not null default now()
);
