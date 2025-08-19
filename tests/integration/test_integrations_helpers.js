// Integration tests for Jira and Notion helper modules
// These tests mock global.fetch to avoid real network calls

import { createJiraIssue } from '../../common/integrations/jira.js';
import { createOrUpdateNotionPage } from '../../common/integrations/notion.js';

function assert(cond, msg) {
  if (!cond) throw new Error(msg || 'assertion failed');
}

async function withMockedFetch(mock, fn) {
  const orig = global.fetch;
  try {
    global.fetch = mock;
    await fn();
  } finally {
    global.fetch = orig;
  }
}

async function testJiraSuccess() {
  process.env.JIRA_BASE_URL = 'https://example.atlassian.net';
  process.env.JIRA_EMAIL = 'ops@example.com';
  process.env.JIRA_API_TOKEN = 'x-token';
  process.env.JIRA_PROJECT_KEY = 'OPS';
  process.env.JIRA_ISSUE_TYPE = 'Incident';

  await withMockedFetch(
    async (url, init) => {
      // Basic shape checks
      assert(String(url).endsWith('/rest/api/3/issue'), 'jira url mismatch');
      assert(init && init.method === 'POST', 'jira method');
      assert(init.headers && init.headers['Authorization'], 'jira auth header');
      const body = JSON.parse(init.body || '{}');
      assert(body.fields && body.fields.project && body.fields.issuetype, 'jira body fields');
      // Return a successful response
      return new Response(JSON.stringify({ id: '10001', key: 'OPS-123' }), {
        status: 201,
        headers: { 'content-type': 'application/json' },
      });
    },
    async () => {
      const res = await createJiraIssue({
        summary: 'Test',
        description: 'Body',
        labels: ['system:trader'],
      });
      assert(res.ok === true, 'jira ok');
      assert(res.key === 'OPS-123', 'jira key');
    }
  );
}

async function testJiraFailure() {
  process.env.JIRA_BASE_URL = 'https://example.atlassian.net';
  process.env.JIRA_EMAIL = 'ops@example.com';
  process.env.JIRA_API_TOKEN = 'x-token';

  await withMockedFetch(
    async (url, init) => {
      return new Response('unauthorized', { status: 401 });
    },
    async () => {
      const res = await createJiraIssue({ summary: 'Test fail' });
      assert(res.ok === false && res.status === 401, 'jira failure status');
    }
  );
}

async function testJiraMissingEnv() {
  delete process.env.JIRA_BASE_URL;
  delete process.env.JIRA_EMAIL;
  delete process.env.JIRA_API_TOKEN;
  const res = await createJiraIssue({ summary: 'No env' });
  assert(res.ok === false && res.skipped === true, 'jira skipped on missing env');
}

async function testNotionSuccess() {
  process.env.NOTION_API_TOKEN = 'x-token';
  process.env.NOTION_DATABASE_ID = 'db123';

  await withMockedFetch(
    async (url, init) => {
      assert(String(url).includes('https://api.notion.com/v1/pages'), 'notion url');
      assert(init && init.method === 'POST', 'notion method');
      const body = JSON.parse(init.body || '{}');
      assert(body.parent && body.properties, 'notion body basics');
      return new Response(JSON.stringify({ id: 'pg_abc' }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    },
    async () => {
      const res = await createOrUpdateNotionPage({ title: 'Event', content: 'Hello' });
      assert(res.ok === true && res.id === 'pg_abc', 'notion ok');
    }
  );
}

async function testNotionMissingEnv() {
  delete process.env.NOTION_API_TOKEN;
  delete process.env.NOTION_DATABASE_ID;
  const res = await createOrUpdateNotionPage({ title: 'No env' });
  assert(res.ok === false && res.skipped === true, 'notion skipped on missing env');
}

async function main() {
  await testJiraSuccess();
  await testJiraFailure();
  await testJiraMissingEnv();
  await testNotionSuccess();
  await testNotionMissingEnv();
  console.log('integration helpers tests: OK');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
