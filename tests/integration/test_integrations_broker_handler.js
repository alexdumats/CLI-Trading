import { handleEvent } from '../../agents/integrations-broker/src/handler.js';

function assert(cond, msg) {
  if (!cond) throw new Error(msg || 'assert failed');
}

async function testNoopOnInfo() {
  const res = await handleEvent({ event: { severity: 'info', type: 'x' } });
  assert(res.acted === false, 'should not act on non-critical');
}

async function testCriticalJiraNotionOk() {
  const incCalls = [];
  const res = await handleEvent({
    event: { severity: 'critical', type: 'daily_target_reached', traceId: 't1', context: { a: 1 } },
    enableJira: true,
    enableNotion: true,
    jiraIssue: async () => ({ ok: true, key: 'OPS-1' }),
    notionPage: async () => ({ ok: true, id: 'pg1' }),
    inc: (t, r) => incCalls.push([t, r]),
    logger: { error: () => {} },
  });
  assert(res.acted === true, 'acted on critical');
  assert(res.jira?.ok === true, 'jira ok');
  assert(res.notion?.ok === true, 'notion ok');
  assert(
    incCalls.some(([t, r]) => t === 'jira' && r === 'ok'),
    'jira inc ok'
  );
  assert(
    incCalls.some(([t, r]) => t === 'notion' && r === 'ok'),
    'notion inc ok'
  );
}

async function testCriticalJiraError() {
  const incCalls = [];
  const res = await handleEvent({
    event: { severity: 'critical', type: 'x' },
    enableJira: true,
    jiraIssue: async () => {
      throw new Error('boom');
    },
    inc: (t, r) => incCalls.push([t, r]),
    logger: { error: () => {} },
  });
  assert(res.acted === true, 'acted');
  assert(
    incCalls.some(([t, r]) => t === 'jira' && r === 'error'),
    'jira inc error'
  );
}

async function main() {
  await testNoopOnInfo();
  await testCriticalJiraNotionOk();
  await testCriticalJiraError();
  console.log('integrations broker handler tests: OK');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
