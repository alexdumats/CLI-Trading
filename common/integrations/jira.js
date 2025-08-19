import fs from 'node:fs';

function readSecret(path) {
  try {
    return fs.readFileSync(path, 'utf8').trim();
  } catch {
    return '';
  }
}

function getAuth() {
  const baseUrl = process.env.JIRA_BASE_URL || '';
  const email = process.env.JIRA_EMAIL || '';
  let token = process.env.JIRA_API_TOKEN || '';
  if (!token && process.env.JIRA_API_TOKEN_FILE)
    token = readSecret(process.env.JIRA_API_TOKEN_FILE);
  if (!baseUrl || !email || !token) return null;
  return { baseUrl, email, token };
}

export async function createJiraIssue({ summary, description, labels = [], fields = {} }) {
  const auth = getAuth();
  if (!auth) return { ok: false, skipped: true, reason: 'missing_jira_env' };
  const projectKey = process.env.JIRA_PROJECT_KEY || 'OPS';
  const issueType = process.env.JIRA_ISSUE_TYPE || 'Task';
  const body = {
    fields: {
      project: { key: projectKey },
      issuetype: { name: issueType },
      summary: summary?.slice(0, 255) || 'Auto-generated issue',
      description: description || '',
      labels,
      ...fields,
    },
  };
  const resp = await fetch(`${auth.baseUrl}/rest/api/3/issue`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: 'Basic ' + Buffer.from(`${auth.email}:${auth.token}`).toString('base64'),
      Accept: 'application/json',
    },
    body: JSON.stringify(body),
  });
  if (!resp.ok) return { ok: false, status: resp.status, error: await safeText(resp) };
  const data = await resp.json().catch(() => ({}));
  return { ok: true, key: data.key, id: data.id };
}

async function safeText(resp) {
  try {
    return await resp.text();
  } catch {
    return '';
  }
}
