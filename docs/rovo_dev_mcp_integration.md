# Rovo-dev MCP Integration Plan

This document specifies how to connect each agent to the correct external MCP servers using rovo-dev, with clear configuration, security practices, and initial validation steps.

## Agent → MCP Server Assignment

Market Analyst

- coingecko-mcp-server (crypto market/DEX data)
- financial-datasets-mcp (global equities, macro)
- mcp_polygon (equities/FX/options)

Notification Manager

- atlassian-mcp-server (Jira/Confluence via OAuth)
- mcp (WayStation; Notion/Slack/Monday/Airtable)
- mcp-atlassian (advanced Atlassian workflows)

Orchestrator

- mcpx (central gateway for MCP management)
- magg (meta-hub discovery and orchestration)
- mcgravity (compose/multiplex multiple MCP servers)

Parameter Optimizer

- mcp-hydrolix (time-series datalake)
- mcp-grafana (dashboards, queries)
- netdata (metrics/logs monitoring)

Portfolio Manager

- trade-agent-mcp (brokerage/portfolio)
- alpaca-mcp (stocks/crypto)
- monarch-mcp-server (read-only personal finance)

Risk Manager

- mcp_polygon (risk/options analytics)
- ccxt-mcp (liquidity/counterparty risk)
- yahoofinance-mcp (beta/correlation)

Trade Executor

- ccxt-mcp (real-time trading & market data)
- binance-mcp (Binance futures/execution)
- ib-mcp (Interactive Brokers)

## Configuration Model

Keep agent containers immutable and configure MCP connections via environment variables (or Docker/Rovo secrets). For each agent we define MCP endpoints and credentials using agent-specific prefixes.

Examples (per agent):

Market Analyst

- ANALYST_MCP_COINGECKO_URL=
- ANALYST_MCP_COINGECKO_API_KEY_FILE=/run/secrets/coingecko_api_key (optional)
- ANALYST_MCP_FIN_DATASETS_URL=
- ANALYST_MCP_POLYGON_URL=
- ANALYST_MCP_POLYGON_API_KEY_FILE=/run/secrets/polygon_api_key

Notification Manager

- NOTIF_MCP_ATLASSIAN_URL=
- NOTIF_MCP_ATLASSIAN_CLIENT_ID_FILE=/run/secrets/atlassian_client_id
- NOTIF_MCP_ATLASSIAN_CLIENT_SECRET_FILE=/run/secrets/atlassian_client_secret
- NOTIF_MCP_WAYSTATION_URL=
- NOTIF_MCP_ATLASSIAN_ADV_URL=

Orchestrator

- ORCH_MCP_MCPX_URL=
- ORCH_MCP_MAGG_URL=
- ORCH_MCP_MCGRAVITY_URL=

Parameter Optimizer

- OPT_MCP_HYDROLIX_URL=
- OPT_MCP_GRAFANA_URL=
- OPT_MCP_NETDATA_URL=

Portfolio Manager

- PM_MCP_TRADE_AGENT_URL=
- PM_MCP_ALPACA_URL=
- PM_MCP_ALPACA_KEY_FILE=/run/secrets/alpaca_api_key
- PM_MCP_ALPACA_SECRET_FILE=/run/secrets/alpaca_api_secret
- PM_MCP_MONARCH_URL=

Risk Manager

- RISK_MCP_POLYGON_URL=
- RISK_MCP_CCXT_URL=
- RISK_MCP_YF_URL=

Trade Executor

- EXEC_MCP_CCXT_URL=
- EXEC_MCP_BINANCE_URL=
- EXEC_MCP_BINANCE_KEY_FILE=/run/secrets/binance_api_key
- EXEC_MCP_BINANCE_SECRET_FILE=/run/secrets/binance_api_secret
- EXEC_MCP_IB_URL=

Notes

- Prefer \*\_FILE envs referencing Docker/rovo secrets; do not put raw secrets in .env or logs.
- If a given MCP server supports OAuth, store client id/secret in secrets and use rovo-dev to handle the auth flow and token refresh.

## Health and Status

Each agent already exposes `/health` and standardized `/status`.

- Extend `/status` to include `mcp` section if endpoints are configured (planned in next step), e.g.:
  {
  status: 'ok',
  service: 'Claude Market Analyst',
  role: 'market-analyst',
  deps: { redis: 'ok' },
  mcp: {
  coingecko: 'configured',
  polygon: 'configured',
  financial_datasets: 'configured'
  }
  }
- Optional: implement `/status?deep=1` to actively ping each MCP `/health` when available (timeouts and error-safe).

## Logging & Monitoring

- Log MCP auth failures (never include secrets), connection errors, and usage counters to Prometheus metrics (e.g., mcp_requests_total{agent,server,result}).
- Forward errors to notify.events to route to Notification Manager as needed.

## Rovo-dev Instructions (pasteable)

> Task: For each agent in the modular trading system, connect to the designated external MCP servers. Configure each agent to use only the relevant MCP endpoints, APIs, and authentication flows according to its core responsibilities.
>
> Agent–MCP Assignment:
>
> - Market Analyst: coingecko-mcp-server, financial-datasets-mcp, mcp_polygon
> - Notification Manager: atlassian-mcp-server, mcp (WayStation), mcp-atlassian
> - Orchestrator: mcpx, magg, mcgravity
> - Parameter Optimizer: mcp-hydrolix, mcp-grafana, netdata
> - Portfolio Manager: trade-agent-mcp, alpaca-mcp, monarch-mcp-server
> - Risk Manager: mcp_polygon, ccxt-mcp, yahoofinance-mcp
> - Trade Executor: ccxt-mcp, binance-mcp, ib-mcp
>
> Configuration Requirements:
>
> - Inject endpoints as environment variables listed in `docs/rovo_dev_mcp_integration.md` or `mcp.env.example`.
> - Use \*\_FILE envs for credentials; rovo-dev secrets should mount files at runtime.
> - Expose per-MCP connectivity in `/status` (and optionally `/status?deep=1`).
> - Emit logs/metrics for MCP connectivity and usage.
>
> Deliverables:
>
> - Updated agent configs, environment template (mcp.env.example), and documentation.
> - Connection/usage smoke scripts.

## Validation Scripts (initial)

- Run: `make health` to check agents.
- After endpoints configured and MCPs reachable, call `/status?deep=1` for Market Analyst and Trade Executor.

## Security

- Never log or commit secrets. Only reference \*\_FILE envs.
- Keep MCP credentials restricted to the agents that need them.
