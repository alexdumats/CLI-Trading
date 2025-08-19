import express from 'express';
import Redis from 'ioredis';
import client from 'prom-client';
import axios from 'axios';
import { WebSocketServer } from 'ws';
import { createLogger } from '../../../common/logger.js';
import { traceMiddleware, requestLoggerMiddleware } from '../../../common/trace.js';
import { xaddJSON, startConsumer } from '../../../common/streams.js';

const SERVICE_NAME = process.env.SERVICE_NAME || 'Rovo Dev Hub';
const PORT = parseInt(process.env.PORT || '7010', 10);
const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379/0';

// AI Model Configuration
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY || '';
const OPENAI_API_KEY = process.env.OPENAI_API_KEY || '';

// Trading Agent URLs
const AGENT_URLS = {
  orchestrator: process.env.ORCHESTRATOR_URL || 'http://orchestrator:7001',
  'market-analyst': process.env.MARKET_ANALYST_URL || 'http://market-analyst:7003',
  'risk-manager': process.env.RISK_MANAGER_URL || 'http://risk-manager:7004',
  'trade-executor': process.env.TRADE_EXECUTOR_URL || 'http://trade-executor:7005',
  'notification-manager':
    process.env.NOTIFICATION_MANAGER_URL || 'http://notification-manager:7006',
  'parameter-optimizer': process.env.PARAMETER_OPTIMIZER_URL || 'http://parameter-optimizer:7007',
  'mcp-hub-controller': process.env.MCP_HUB_CONTROLLER_URL || 'http://mcp-hub-controller:7008',
  'portfolio-manager': process.env.PORTFOLIO_MANAGER_URL || 'http://portfolio-manager:7002',
  'integrations-broker': process.env.INTEGRATIONS_BROKER_URL || 'http://integrations-broker:7009',
};

const app = express();
const logger = createLogger(SERVICE_NAME);
const redis = new Redis(REDIS_URL);
const http = axios.create({ timeout: 10000, validateStatus: () => true });

app.use(express.json());
app.use(traceMiddleware(SERVICE_NAME));
app.use(requestLoggerMiddleware(logger));

// Metrics
const register = new client.Registry();
client.collectDefaultMetrics({ register });
const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'path', 'status'],
  buckets: [0.05, 0.1, 0.3, 0.5, 1, 2, 5],
});
register.registerMetric(httpRequestDuration);

const aiRequestsTotal = new client.Counter({
  name: 'ai_requests_total',
  help: 'Total AI model requests',
  labelNames: ['model', 'agent', 'type'],
});
register.registerMetric(aiRequestsTotal);

const agentCommunicationTotal = new client.Counter({
  name: 'agent_communication_total',
  help: 'Total inter-agent communications',
  labelNames: ['from_agent', 'to_agent', 'type'],
});
register.registerMetric(agentCommunicationTotal);

// Timing middleware
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer({ method: req.method, path: req.path });
  res.on('finish', () => end({ status: String(res.statusCode) }));
  next();
});

// Health endpoint
app.get('/health', async (req, res) => {
  let redisStatus = 'unknown';
  try {
    await redis.ping();
    redisStatus = 'ok';
  } catch {
    redisStatus = 'error';
  }

  // Check agent connectivity
  const agentHealth = {};
  const healthChecks = Object.entries(AGENT_URLS).map(async ([name, url]) => {
    try {
      const response = await http.get(`${url}/health`, { timeout: 2000 });
      agentHealth[name] = response.status === 200 ? 'ok' : 'degraded';
    } catch {
      agentHealth[name] = 'error';
    }
  });

  await Promise.allSettled(healthChecks);

  res.json({
    status: 'ok',
    service: SERVICE_NAME,
    redis: redisStatus,
    agents: agentHealth,
    uptime: process.uptime(),
    ts: new Date().toISOString(),
  });
});

// Status endpoint
app.get('/status', async (req, res) => {
  let redisStatus = 'unknown';
  try {
    await redis.ping();
    redisStatus = 'ok';
  } catch {
    redisStatus = 'error';
  }

  res.json({
    status: 'ok',
    service: SERVICE_NAME,
    role: 'rovo-dev-hub',
    version: process.env.npm_package_version || '0.0.0',
    uptime: process.uptime(),
    deps: { redis: redisStatus },
    ai_models: {
      anthropic: ANTHROPIC_API_KEY ? 'configured' : 'not_configured',
      openai: OPENAI_API_KEY ? 'configured' : 'not_configured',
    },
    connected_agents: Object.keys(AGENT_URLS).length,
  });
});

// Metrics endpoint
app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// AI Chat Interface - Main endpoint for Rovo Dev communication
app.post('/chat', async (req, res) => {
  try {
    const { message, context = {}, model = 'claude', agent_scope = 'all' } = req.body;

    if (!message) {
      return res.status(400).json({ error: 'message_required' });
    }

    // Log the communication
    logger.info('rovo_dev_chat', { message: message.substring(0, 100), model, agent_scope });

    // Get current system state
    const systemState = await getSystemState(agent_scope);

    // Prepare context for AI model
    const aiContext = {
      role: 'You are Rovo Dev, an AI assistant managing a multi-agent cryptocurrency trading system.',
      system_state: systemState,
      user_context: context,
      available_actions: getAvailableActions(),
      trading_agents: Object.keys(AGENT_URLS),
    };

    let aiResponse;

    if (model === 'claude' && ANTHROPIC_API_KEY) {
      aiResponse = await callClaude(message, aiContext);
      aiRequestsTotal.inc({ model: 'claude', agent: 'rovo-dev', type: 'chat' });
    } else if (model === 'gpt' && OPENAI_API_KEY) {
      aiResponse = await callOpenAI(message, aiContext);
      aiRequestsTotal.inc({ model: 'gpt', agent: 'rovo-dev', type: 'chat' });
    } else {
      // Fallback to rule-based response
      aiResponse = await handleRuleBasedResponse(message, systemState);
      aiRequestsTotal.inc({ model: 'fallback', agent: 'rovo-dev', type: 'chat' });
    }

    // Execute any actions suggested by AI
    const actions = await executeAIActions(aiResponse.actions || []);

    // Broadcast to relevant agents if needed
    if (aiResponse.broadcast_to) {
      await broadcastToAgents(aiResponse.broadcast_to, {
        type: 'rovo_dev_message',
        message: aiResponse.message,
        actions: actions,
        timestamp: new Date().toISOString(),
      });
    }

    res.json({
      response: aiResponse.message,
      actions_taken: actions,
      system_state: systemState,
      model_used: model,
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    logger.error('rovo_dev_chat_error', { error: String(error.message || error) });
    res.status(500).json({ error: 'chat_failed', detail: String(error.message || error) });
  }
});

// Inter-agent communication endpoint
app.post('/agent-communication', async (req, res) => {
  try {
    const { from_agent, to_agent, message, type = 'communication', data = {} } = req.body;

    if (!from_agent || !to_agent || !message) {
      return res.status(400).json({ error: 'missing_required_fields' });
    }

    // Log the communication
    agentCommunicationTotal.inc({ from_agent, to_agent, type });
    logger.info('agent_communication', {
      from_agent,
      to_agent,
      type,
      message: message.substring(0, 100),
    });

    // Send to target agent if it exists
    if (AGENT_URLS[to_agent]) {
      try {
        const response = await http.post(`${AGENT_URLS[to_agent]}/message`, {
          from: from_agent,
          message,
          type,
          data,
          timestamp: new Date().toISOString(),
        });

        // Broadcast to Redis streams for other interested agents
        await xaddJSON(redis, 'agent.communications', {
          from_agent,
          to_agent,
          message,
          type,
          data,
          response_status: response.status,
          timestamp: new Date().toISOString(),
        });

        res.json({
          status: 'sent',
          target_agent: to_agent,
          response_status: response.status,
          timestamp: new Date().toISOString(),
        });
      } catch (error) {
        logger.error('agent_communication_error', {
          from_agent,
          to_agent,
          error: String(error.message),
        });
        res.status(502).json({ error: 'communication_failed', target_agent: to_agent });
      }
    } else {
      res.status(404).json({ error: 'agent_not_found', target_agent: to_agent });
    }
  } catch (error) {
    logger.error('agent_communication_endpoint_error', { error: String(error.message || error) });
    res.status(500).json({ error: 'communication_endpoint_failed' });
  }
});

// System command execution
app.post('/execute', async (req, res) => {
  try {
    const { command, target_agent = 'orchestrator', parameters = {} } = req.body;

    if (!command) {
      return res.status(400).json({ error: 'command_required' });
    }

    logger.info('rovo_dev_execute', { command, target_agent, parameters });

    let result;

    switch (command) {
      case 'halt_trading':
        result = await executeOnAgent('orchestrator', 'POST', '/admin/orchestrate/halt', {
          reason: 'rovo_dev_request',
        });
        break;

      case 'resume_trading':
        result = await executeOnAgent('orchestrator', 'POST', '/admin/orchestrate/unhalt', {});
        break;

      case 'get_pnl':
        result = await executeOnAgent('orchestrator', 'GET', '/pnl/status');
        break;

      case 'run_trade':
        result = await executeOnAgent('orchestrator', 'POST', '/orchestrate/run', {
          symbol: parameters.symbol || 'BTC-USD',
          mode: parameters.mode || 'http',
        });
        break;

      case 'check_risk':
        result = await executeOnAgent('risk-manager', 'POST', '/risk/evaluate', parameters);
        break;

      case 'get_analysis':
        result = await executeOnAgent('market-analyst', 'POST', '/analysis/analyze', parameters);
        break;

      default:
        return res.status(400).json({ error: 'unknown_command', command });
    }

    res.json({
      command,
      target_agent,
      result,
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    logger.error('rovo_dev_execute_error', { error: String(error.message || error) });
    res.status(500).json({ error: 'execute_failed', detail: String(error.message || error) });
  }
});

// Helper functions
async function getSystemState(agent_scope = 'all') {
  const state = {
    timestamp: new Date().toISOString(),
    agents: {},
  };

  const agents = agent_scope === 'all' ? Object.keys(AGENT_URLS) : [agent_scope];

  const stateChecks = agents.map(async (agentName) => {
    try {
      const response = await http.get(`${AGENT_URLS[agentName]}/status`, { timeout: 2000 });
      state.agents[agentName] = response.data || { status: 'unreachable' };
    } catch {
      state.agents[agentName] = { status: 'error' };
    }
  });

  await Promise.allSettled(stateChecks);
  return state;
}

function getAvailableActions() {
  return [
    'halt_trading',
    'resume_trading',
    'get_pnl',
    'run_trade',
    'check_risk',
    'get_analysis',
    'broadcast_message',
    'get_system_status',
  ];
}

async function callClaude(message, context) {
  // Placeholder for Anthropic Claude integration
  // In production, you would use @anthropic-ai/sdk
  return {
    message: `[Claude Response] Based on your trading system state, I understand you want: ${message}. Current system status shows all agents operational.`,
    actions: [],
    broadcast_to: null,
  };
}

async function callOpenAI(message, context) {
  // Placeholder for OpenAI integration
  // In production, you would use the openai npm package
  return {
    message: `[GPT Response] Analyzing trading system request: ${message}. System appears healthy with ${Object.keys(context.system_state.agents).length} agents active.`,
    actions: [],
    broadcast_to: null,
  };
}

async function handleRuleBasedResponse(message, systemState) {
  const lowerMessage = message.toLowerCase();

  if (lowerMessage.includes('halt') || lowerMessage.includes('stop')) {
    return {
      message: 'I can help you halt trading. Would you like me to execute a trading halt?',
      actions: ['suggest_halt_trading'],
      broadcast_to: ['orchestrator'],
    };
  }

  if (lowerMessage.includes('status') || lowerMessage.includes('health')) {
    const healthyAgents = Object.values(systemState.agents).filter((a) => a.status === 'ok').length;
    return {
      message: `System status: ${healthyAgents}/${Object.keys(systemState.agents).length} agents healthy. Trading system operational.`,
      actions: [],
      broadcast_to: null,
    };
  }

  if (lowerMessage.includes('pnl') || lowerMessage.includes('profit')) {
    return {
      message: 'I can fetch the current PnL status for you.',
      actions: ['get_pnl'],
      broadcast_to: null,
    };
  }

  return {
    message: `I understand you're asking about: "${message}". I'm here to help manage your trading system. Available commands: halt trading, resume trading, check status, get PnL, run analysis.`,
    actions: [],
    broadcast_to: null,
  };
}

async function executeAIActions(actions) {
  const results = [];

  for (const action of actions) {
    try {
      let result;

      switch (action) {
        case 'get_pnl':
          result = await executeOnAgent('orchestrator', 'GET', '/pnl/status');
          break;
        case 'suggest_halt_trading':
          result = { suggestion: 'Trading halt recommended', action_required: 'user_confirmation' };
          break;
        default:
          result = { action, status: 'unknown_action' };
      }

      results.push({ action, result, status: 'completed' });
    } catch (error) {
      results.push({ action, error: String(error.message), status: 'failed' });
    }
  }

  return results;
}

async function broadcastToAgents(agents, message) {
  const broadcasts = agents.map(async (agentName) => {
    if (AGENT_URLS[agentName]) {
      try {
        await http.post(`${AGENT_URLS[agentName]}/message`, message);
        agentCommunicationTotal.inc({
          from_agent: 'rovo-dev',
          to_agent: agentName,
          type: 'broadcast',
        });
      } catch (error) {
        logger.error('broadcast_error', { agent: agentName, error: String(error.message) });
      }
    }
  });

  await Promise.allSettled(broadcasts);
}

async function executeOnAgent(agentName, method, path, data = null) {
  const url = AGENT_URLS[agentName];
  if (!url) throw new Error(`Agent ${agentName} not found`);

  const config = {
    method,
    url: `${url}${path}`,
    timeout: 10000,
  };

  if (data && (method === 'POST' || method === 'PUT')) {
    config.data = data;
    config.headers = { 'Content-Type': 'application/json' };
  }

  const response = await http(config);
  return {
    status: response.status,
    data: response.data,
  };
}

// WebSocket server for real-time communication
const server = app.listen(PORT, () => {
  logger.info('rovo_dev_hub_listening', { port: PORT });
});

const wss = new WebSocketServer({ server });

wss.on('connection', (ws, req) => {
  logger.info('websocket_connection', { ip: req.socket.remoteAddress });

  ws.on('message', async (data) => {
    try {
      const message = JSON.parse(data);

      if (message.type === 'chat') {
        // Handle real-time chat
        const response = await handleRuleBasedResponse(message.message, await getSystemState());
        ws.send(
          JSON.stringify({
            type: 'chat_response',
            response: response.message,
            timestamp: new Date().toISOString(),
          })
        );
      }
    } catch (error) {
      ws.send(
        JSON.stringify({
          type: 'error',
          message: 'Invalid message format',
          timestamp: new Date().toISOString(),
        })
      );
    }
  });

  ws.on('close', () => {
    logger.info('websocket_disconnection');
  });
});

// Redis stream consumer for agent messages
startConsumer({
  redis,
  stream: 'agent.communications',
  group: 'rovo-dev',
  logger,
  handler: async ({ payload }) => {
    // Process inter-agent communications
    logger.info('agent_communication_received', payload);

    // Forward to WebSocket clients if needed
    wss.clients.forEach((client) => {
      if (client.readyState === 1) {
        // WebSocket.OPEN
        client.send(
          JSON.stringify({
            type: 'agent_communication',
            data: payload,
            timestamp: new Date().toISOString(),
          })
        );
      }
    });
  },
});

// Graceful shutdown
const shutdown = async () => {
  logger.info('rovo_dev_hub_shutting_down');
  server.close(() => logger.info('rovo_dev_hub_server_closed'));
  try {
    await redis.quit();
  } catch {}
  process.exit(0);
};

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
