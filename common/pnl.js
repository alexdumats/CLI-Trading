import Redis from 'ioredis';

const dateKey = () => new Date().toISOString().slice(0, 10); // YYYY-MM-DD (UTC)
const keyFor = (date = dateKey()) => `pnl:${date}`;

export async function initDayIfNeeded(redis, { startEquity = 1000, dailyTargetPct = 1 } = {}) {
  const date = dateKey();
  const key = keyFor(date);
  const exists = await redis.exists(key);
  if (!exists) {
    await redis.hset(key, {
      date,
      startEquity: String(startEquity),
      realized: '0',
      percent: '0',
      dailyTargetPct: String(dailyTargetPct),
      halted: '0'
    });
  }
  return key;
}

export async function getStatus(redis) {
  const key = keyFor();
  const data = await redis.hgetall(key);
  return normalize(data);
}

export async function resetDay(redis, { startEquity = 1000, dailyTargetPct = 1 } = {}) {
  const key = keyFor();
  await redis.hset(key, {
    date: key.split(':')[1],
    startEquity: String(startEquity),
    realized: '0',
    percent: '0',
    dailyTargetPct: String(dailyTargetPct),
    halted: '0'
  });
  return getStatus(redis);
}

export async function incrementPnl(redis, amount) {
  const key = await initDayIfNeeded(redis, {});
  const realized = await redis.hincrbyfloat(key, 'realized', amount);
  const startEquity = parseFloat(await redis.hget(key, 'startEquity')) || 1;
  const percent = (parseFloat(realized) / startEquity) * 100;
  await redis.hset(key, { percent: String(percent) });
  const status = await getStatus(redis);
  return status;
}

export async function setHalted(redis, halted) {
  const key = keyFor();
  await redis.hset(key, { halted: halted ? '1' : '0' });
}

export async function isHalted(redis) {
  const key = keyFor();
  const v = await redis.hget(key, 'halted');
  return v === '1';
}

function normalize(data) {
  if (!data || Object.keys(data).length === 0) return {
    date: dateKey(), startEquity: 0, realized: 0, percent: 0, dailyTargetPct: 1, halted: false
  };
  return {
    date: data.date,
    startEquity: parseFloat(data.startEquity || '0'),
    realized: parseFloat(data.realized || '0'),
    percent: parseFloat(data.percent || '0'),
    dailyTargetPct: parseFloat(data.dailyTargetPct || '1'),
    halted: data.halted === '1'
  };
}
