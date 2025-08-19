// Pure handler for integrations-broker to enable unit testing without Redis
// Usage: await handleEvent({ event, enableJira, enableNotion, jiraIssue, notionPage, inc, logger })

export async function handleEvent({
  event,
  enableJira,
  enableNotion,
  jiraIssue,
  notionPage,
  inc,
  logger,
}) {
  const sev = (event?.severity || 'info').toLowerCase();
  const isCritical = sev === 'critical';
  const out = { acted: false, jira: null, notion: null };
  if (!isCritical) return out; // only act on critical by default
  out.acted = true;

  // Jira
  if (enableJira && typeof jiraIssue === 'function') {
    try {
      const res = await jiraIssue({
        summary: `[${event.type}] ${event.message || 'Critical event'}`,
        description: `Trace: ${event.traceId || 'n/a'}\n\n${'```'}${JSON.stringify(event.context || {}, null, 2)}${'```'}`,
        labels: ['system:trader', `type:${event.type || 'event'}`],
      });
      out.jira = res;
      inc?.('jira', res?.ok ? 'ok' : 'fail');
    } catch (e) {
      inc?.('jira', 'error');
      logger?.error?.('jira_error', { error: String(e?.message || e) });
    }
  }

  // Notion
  if (enableNotion && typeof notionPage === 'function') {
    try {
      const res = await notionPage({
        title: `Event: ${event.type}`,
        properties: {
          Severity: { select: { name: sev.toUpperCase() } },
          TraceId: { rich_text: [{ text: { content: event.traceId || '' } }] },
          RequestId: { rich_text: [{ text: { content: event.requestId || '' } }] },
        },
        content: `Context: ${'```'}${JSON.stringify(event.context || {}, null, 2)}${'```'}`,
      });
      out.notion = res;
      inc?.('notion', res?.ok ? 'ok' : 'fail');
    } catch (e) {
      inc?.('notion', 'error');
      logger?.error?.('notion_error', { error: String(e?.message || e) });
    }
  }

  return out;
}
