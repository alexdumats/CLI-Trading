/**
 * Unit tests for the Notion integration
 */
import { jest } from '@jest/globals';
import { createOrUpdateNotionPage } from '../../../../common/integrations/notion.js';

describe('Notion Integration', () => {
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
    delete process.env.NOTION_API_TOKEN;
    delete process.env.NOTION_DATABASE_ID;

    const res = await createOrUpdateNotionPage({ title: 'x' });
    expect(res).toEqual({ ok: false, skipped: true, reason: 'missing_notion_env' });
    expect(global.fetch).not.toHaveBeenCalled();
  });

  test('creates page when env is present and API returns ok', async () => {
    process.env.NOTION_API_TOKEN = 'test-token';
    process.env.NOTION_DATABASE_ID = 'db-123';

    const mockResp = {
      ok: true,
      json: async () => ({ id: 'page-abc' }),
    };
    global.fetch.mockResolvedValue(mockResp);

    const res = await createOrUpdateNotionPage({
      title: 'Daily Ops Record',
      properties: { Priority: { select: { name: 'High' } } },
      content: 'Hello Notion',
    });

    expect(res).toEqual({ ok: true, id: 'page-abc' });

    // Verify fetch call
    expect(global.fetch).toHaveBeenCalledTimes(1);
    const [url, init] = global.fetch.mock.calls[0];
    expect(url).toBe('https://api.notion.com/v1/pages');
    expect(init.method).toBe('POST');
    expect(init.headers['Content-Type']).toBe('application/json');
    expect(init.headers['Authorization']).toBe(`Bearer ${process.env.NOTION_API_TOKEN}`);
    expect(init.headers['Notion-Version']).toBe('2022-06-28');

    const body = JSON.parse(init.body);
    expect(body.parent).toEqual({ database_id: 'db-123' });
    expect(Array.isArray(body.children)).toBe(true);
    expect(body.properties.Title.title[0].text.content).toContain('Daily Ops Record');
  });

  test('returns error details when API responds with non-OK', async () => {
    process.env.NOTION_API_TOKEN = 'test-token';
    process.env.NOTION_DATABASE_ID = 'db-123';

    const mockResp = {
      ok: false,
      status: 400,
      text: async () => 'Invalid request',
    };
    global.fetch.mockResolvedValue(mockResp);

    const res = await createOrUpdateNotionPage({ title: 'Bad' });
    expect(res).toEqual({ ok: false, status: 400, error: 'Invalid request' });
  });
});
