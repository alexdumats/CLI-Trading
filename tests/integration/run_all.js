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
  await run('node', ['tests/integration/test_integrations_helpers.js']);
  await run('node', ['tests/integration/test_integrations_broker_handler.js']);
  await run('node', ['tests/integration/test_opt_loss_to_risk.js']);
  await run('node', ['tests/integration/test_risk_rules.js']);
  await run('node', ['tests/integration/test_e2e_risk_params_http.js']);
  await run('node', ['tests/integration/test_streams_e2e.js']);
  await run('node', ['tests/integration/test_streams_rejection_e2e.js']);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
