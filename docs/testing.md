# Testing Strategy and Documentation

This document outlines the comprehensive testing approach for the CLI Trading System. It covers the different types of tests, how to run them, and best practices for writing new tests.

## Table of Contents

- [Testing Strategy](#testing-strategy)
- [Test Structure](#test-structure)
- [Running Tests](#running-tests)
- [Writing Tests](#writing-tests)
- [Mocking](#mocking)
- [CI/CD Integration](#cicd-integration)
- [Performance Testing](#performance-testing)
- [Test Coverage](#test-coverage)

## Testing Strategy

Our testing strategy follows a multi-level approach:

### Unit Tests

Unit tests verify individual functions, classes, and modules in isolation. They use mocks to replace external dependencies and focus on testing the logic of a single unit of code.

**Key characteristics:**

- Fast execution
- No external dependencies
- High coverage
- Isolated test cases

### Integration Tests

Integration tests verify that different components work together correctly. They test the interactions between modules, services, and external dependencies.

**Key characteristics:**

- Test real interactions between components
- May use real or mocked external dependencies
- Focus on interfaces and communication
- Verify correct data flow

### End-to-End Tests

E2E tests verify the entire system works together correctly from end to end. They simulate real user scenarios and test the complete flow through the system.

**Key characteristics:**

- Test the entire system
- Use real external dependencies
- Simulate real user scenarios
- Verify business requirements

### Performance Tests

Performance tests verify the system's performance characteristics under load. They measure response times, throughput, and resource utilization.

**Key characteristics:**

- Measure performance metrics
- Test system under load
- Identify bottlenecks
- Establish performance baselines

## Test Structure

The test code is organized as follows:

```
tests/
├── helpers/            # Test helpers and utilities
│   ├── http-mock.js    # HTTP request mocking
│   ├── pg-mock.js      # PostgreSQL mocking
│   ├── redis-mock.js   # Redis mocking
│   └── test-utils.js   # General test utilities
├── unit/               # Unit tests
│   ├── common/         # Tests for common modules
│   └── agents/         # Tests for agent services
├── integration/        # Integration tests
├── e2e/                # End-to-end tests
└── performance/        # Performance tests
```

## Running Tests

### Prerequisites

- Node.js 18 or later
- npm
- Docker and Docker Compose (for integration and E2E tests)

### Installing Dependencies

```bash
npm install
```

### Running Unit Tests

```bash
# Run all unit tests
npm run test:unit

# Run tests with coverage
npm run test:coverage

# Run tests in watch mode
npm run test:watch

# Run specific test file
npm run test -- tests/unit/common/logger.test.js
```

Unit coverage includes:

- Common modules: logger, db, streams, pnl, trace
- Exchange adapters: paper, binance (stub), coinbase (stub)
- Adapter contract conformance: tests/unit/common/exchanges/adapter.contract.test.js
- Agent startup smoke tests: tests/unit/agents/orchestrator/startup.test.js and tests/unit/agents/all-startup.test.js (mock Redis/PG/metrics, assert express.listen and core routes)

### Running Integration Tests

There are two styles of integration tests in this repo:

1. Jest-based integration tests (under tests/integration-jest/, gated by RUN_DOCKER_TESTS)

```bash
# Ensure services are up
docker-compose -f docker-compose.dev.yml up -d

# Run Jest-based integration smoke tests (gated)
RUN_DOCKER_TESTS=true ORCH_URL=http://localhost:7001 npm run test:integration:docker
```

2. Node-runner scripts under tests/integration/ (current coverage)

```bash
# Start required services
docker-compose -f docker-compose.dev.yml up -d redis postgres

# Run all node-based integration tests sequentially
node tests/integration/run_all.js

# Or run a specific integration script
node tests/integration/test_streams_e2e.js
```

The CI workflow runs both the Jest target (if present) and the node-runner scripts to validate full flows.

### Running E2E Tests

```bash
# Start the full system
docker-compose -f docker-compose.dev.yml up -d

# Run all E2E tests (Jest-based if present under tests/e2e/)
npm run test:e2e

# Alternatively run the enhanced end-to-end node test directly:
ORCH_URL=http://localhost:7001 REDIS_URL=redis://localhost:6379/0 \
node tests/integration/test_streams_e2e_enhanced.js
```

### Running Performance Tests

```bash
# Start the full system
docker-compose -f docker-compose.dev.yml up -d

# Run performance tests
node tests/performance/load-test.js
```

## Writing Tests

### Unit Test Example

```javascript
import { jest } from '@jest/globals';
import { createLogger } from '../../../common/logger.js';

describe('Logger Module', () => {
  let originalStdout;
  let stdoutMock;

  beforeEach(() => {
    // Setup mocks
    originalStdout = process.stdout.write;
    stdoutMock = jest.fn();
    process.stdout.write = stdoutMock;
  });

  afterEach(() => {
    // Cleanup
    process.stdout.write = originalStdout;
  });

  test('creates a logger with the specified service name', () => {
    const logger = createLogger('test-service');
    expect(logger).toBeDefined();
    expect(logger.info).toBeInstanceOf(Function);
  });
});
```

### Integration Test Example

```javascript
import axios from 'axios';
import Redis from 'ioredis';

async function main() {
  const ORCH_URL = process.env.ORCH_URL || 'http://orchestrator:7001';

  // Test the orchestrator API
  const run = await axios.post(`${ORCH_URL}/orchestrate/run`, {
    symbol: 'BTC-USD',
    mode: 'pubsub',
  });

  const requestId = run.data?.requestId;

  // Verify the result
  // ...
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
```

## Mocking

We provide several mock utilities to simplify testing:

### Redis Mock

Use `tests/helpers/redis-mock.js` to mock Redis operations:

```javascript
import { RedisMock } from '../../helpers/redis-mock.js';

const redisMock = new RedisMock();
// Use redisMock in your tests
```

### PostgreSQL Mock

Use `tests/helpers/pg-mock.js` to mock PostgreSQL operations:

```javascript
import createPgPoolMock from '../../helpers/pg-mock.js';

const pgPoolMock = createPgPoolMock();
// Use pgPoolMock in your tests
```

### HTTP Mock

Use `tests/helpers/http-mock.js` to mock HTTP requests:

```javascript
import { createAxiosMock } from '../../helpers/http-mock.js';

const axiosMock = createAxiosMock({
  responses: {
    'api/endpoint': { data: { result: 'success' } },
  },
});
// Use axiosMock in your tests
```

### Test Environment

Use `tests/helpers/test-utils.js` to create a complete test environment:

```javascript
import { createTestEnvironment } from '../../helpers/test-utils.js';

const testEnv = createTestEnvironment();
// Use testEnv.redisMock, testEnv.pgPoolMock, etc.
```

## CI/CD Integration

Tests are automatically run as part of our CI/CD pipeline using GitHub Actions. The workflow is defined in `.github/workflows/test.yml`.

The pipeline runs:

1. Linting
2. Unit tests
3. Integration tests
4. E2E tests (on main branch only)
5. Performance tests (on main branch only)

## Performance Testing

Performance tests are implemented using a custom load testing script in `tests/performance/load-test.js`. This script simulates multiple concurrent users sending requests to the system and measures response times, throughput, and error rates. It also monitors Redis streams to compute risk approval and execution success rates.

To configure the performance test, use the following environment variables:

- `TEST_DURATION_SEC`: Test duration in seconds (default: 60)
- `REQUESTS_PER_SEC`: Target requests per second (default: 5)
- `CONCURRENT_USERS`: Number of concurrent users (default: 10)
- `ORCH_URL`: Orchestrator base URL (default: http://localhost:7001)
- `REDIS_URL`: Redis URL (default: redis://localhost:6379/0)

SLO suggestions:

- HTTP p95 latency under 500ms for orchestrator endpoints at baseline RPS
- Error rate under 1%
- Execution success rate > 95% (paper adapter)

The CI workflow runs a shortened performance test on main with conservative parameters.

## Test Coverage

We use Jest's built-in coverage reporting to track test coverage. The coverage report is generated when running:

```bash
npm run test:coverage
```

The coverage report is available in the `coverage/` directory.

### Coverage Thresholds

We aim for the following coverage thresholds:

- Statements: 70%
- Branches: 60%
- Functions: 70%
- Lines: 70%

These thresholds are enforced in the CI pipeline.
