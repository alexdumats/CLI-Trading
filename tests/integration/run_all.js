import { spawn } from 'node:child_process';

function run(cmd, args = []) {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args, { stdio: 'inherit' });
    p.on('exit', (code) => (code === 0 ? resolve() : reject(new Error(`${cmd} exited ${code}`))));
  });
}

async function main() {
  await run('node', ['tests/integration/test_daily_target.js']);
  await run('node', ['tests/integration/test_streams_reliability.js']);
  await run('node', ['tests/integration/test_notify_dlq_requeue.js']);
}

main().catch((e) => { console.error(e); process.exit(1); });
