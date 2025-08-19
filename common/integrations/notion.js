import fs from 'node:fs';

function readSecret(path) {
  try {
    return fs.readFileSync(path, 'utf8').trim();
  } catch {
    return '';
  }
}

function getAuth() {
  let token = process.env.NOTION_API_TOKEN || '';
  if (!token && process.env.NOTION_API_TOKEN_FILE)
    token = readSecret(process.env.NOTION_API_TOKEN_FILE);
  const databaseId = process.env.NOTION_DATABASE_ID || '';
  if (!token || !databaseId) return null;
  return { token, databaseId };
}

export async function createOrUpdateNotionPage({ title, properties = {}, content = '' }) {
  const auth = getAuth();
  if (!auth) return { ok: false, skipped: true, reason: 'missing_notion_env' };
  const body = {
    parent: { database_id: auth.databaseId },
    properties: {
      Title: { title: [{ text: { content: title?.slice(0, 200) || 'Auto entry' } }] },
      ...properties,
    },
    children: content
      ? [
          {
            object: 'block',
            type: 'paragraph',
            paragraph: { rich_text: [{ type: 'text', text: { content } }] },
          },
        ]
      : [],
  };
  const resp = await fetch('https://api.notion.com/v1/pages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${auth.token}`,
      'Notion-Version': '2022-06-28',
    },
    body: JSON.stringify(body),
  });
  if (!resp.ok) return { ok: false, status: resp.status, error: await safeText(resp) };
  const data = await resp.json().catch(() => ({}));
  return { ok: true, id: data.id };
}

async function safeText(resp) {
  try {
    return await resp.text();
  } catch {
    return '';
  }
}
