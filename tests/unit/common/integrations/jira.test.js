/**
 * Unit tests for the Jira integration
 */
import { jest } from '@jest/globals';
import { createJiraIssue } from '../../../../common/integrations/jira.js';

describe('Jira Integration', () => {
  let originalEnv;
  let originalFetch;

  beforeEach(() => {
    originalEnv = { ...process.env };
    originalFetch = global.fetch;
    global.fetch = jest.fn();
    jest.clearAllMocks();
  });

  afterEach(() => {
    process.env = originalEnv;
    global.fetch = originalFetch;
  });

  test('returns skipped when env is missing', async () => {
    delete process.env.JIRA_BASE_URL;
    delete process.env.JIRA_EMAIL;
    delete process.env.JIRA_API_TOKEN;

    const res = await createJiraIssue({ summary: 'x' });
    expect(res).toEqual({ ok: false, skipped: true, reason: 'missing_jira_env' });
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test('creates issue when env is present and API returns ok', async () => {
    process.env.JIRA_BASE_URL = 'https://jira.example.com';
    process.env.JIRA_EMAIL = 'user@example.com';
    process.env.JIRA_API_TOKEN = 'apitoken';

    const mockResp = {
      ok: true,
      json: async () => ({ key: 'OPS-123', id: '1001' }),
    };
    global.fetch.mockResolvedValue(mockResp);

    const res = await createJiraIssue({
      summary: 'Investigate latency spike',
      description: 'p95 > 2s',
      labels: ['latency', 'incident'],
      fields: { priority: { name: 'High' } },
    });

    expect(res).toEqual({ ok: true, key: 'OPS-123', id: '1001' });

    // Verify request
    expect(global.fetch).toHaveBeenCalledTimes(1);
    const [url, init] = global.fetch.mock.calls[0];
    expect(url).toBe('https://jira.example.com/rest/api/3/issue');
    expect(init.method).toBe('POST');
    expect(init.headers['Content-Type']).toBe('application/json');
    expect(init.headers['Accept']).toBe('application/json');
    // Authorization header should be Basic base64(email:token)
    const expectedAuth = 'Basic ' + Buffer.from('user@example.com:apitoken').toString('base64');
    expect(init.headers['Authorization']).toBe(expectedAuth);

    const body = JSON.parse(init.body);
    expect(body.fields.project).toEqual({ key: process.env.JIRA_PROJECT_KEY || 'OPS' });
    expect(body.fields.issuetype).toEqual({ name: process.env.JIRA_ISSUE_TYPE || 'Task' });
    expect(typeof body.fields.summary).toBe('string');
  });

  test('returns error details when API responds with non-OK', async () => {
    process.env.JIRA_BASE_URL = 'https://jira.example.com';
    process.env.JIRA_EMAIL = 'user@example.com';
    process.env.JIRA_API_TOKEN = 'apitoken';

    const mockResp = {
      ok: false,
      status: 400,
      text: async () => 'Bad issue fields',
    };
    global.fetch.mockResolvedValue(mockResp);

    const res = await createJiraIssue({ summary: 'Broken' });
    expect(res).toEqual({ ok: false, status: 400, error: 'Bad issue fields' });
  });
});
