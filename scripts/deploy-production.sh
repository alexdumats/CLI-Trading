#!/bin/bash
#
# Production Deployment Script for CLI-Trading Multi-Agent System
#
# This script orchestrates the complete deployment of the trading system
# with comprehensive validation, health checks, and rollback capabilities.
#
# Usage: ./scripts/deploy-production.sh [--force] [--skip-tests] [--rollback]
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_PROJECT_NAME="cli-trading"
DEPLOYMENT_LOG="/opt/cli-trading/logs/deployment.log"
HEALTH_CHECK_TIMEOUT=300
VALIDATION_TIMEOUT=600

# Command line arguments
FORCE_DEPLOY=false
SKIP_TESTS=false
ROLLBACK=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_DEPLOY=true
            shift
            ;;
        --skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        --rollback)
            ROLLBACK=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--force] [--skip-tests] [--rollback]"
            exit 1
            ;;
    esac
done

# Color output functions
red() { echo -e "\033[31m$1\033[0m"; }
green() { echo -e "\033[32m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
blue() { echo -e "\033[34m$1\033[0m"; }
bold() { echo -e "\033[1m$1\033[0m"; }

# Logging function
log() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$message"
    echo "$message" >> "$DEPLOYMENT_LOG"
}

# Error handling
error_exit() {
    red "ERROR: $1"
    log "ERROR: $1"
    if [[ "$ROLLBACK" == "false" ]]; then
        echo
        yellow "To rollback deployment, run: $0 --rollback"
    fi
    exit 1
}

# Progress tracking
DEPLOYMENT_STEPS=(
    "Pre-flight checks"
    "Environment validation"
    "Secrets verification"
    "Image building"
    "Infrastructure startup"
    "Agent deployment"
    "Health validation"
    "Integration testing"
    "Security audit"
    "Performance validation"
    "Monitoring setup"
    "Final verification"
)

current_step=0
total_steps=${#DEPLOYMENT_STEPS[@]}

show_progress() {
    current_step=$((current_step + 1))
    local step_name="${DEPLOYMENT_STEPS[$((current_step - 1))]}"
    blue "[$current_step/$total_steps] $step_name"
    log "Starting step $current_step/$total_steps: $step_name"
}

# Rollback function
perform_rollback() {
    log "Starting rollback procedure..."
    
    # Stop all services
    docker compose -f "$PROJECT_DIR/docker-compose.yml" down || true
    
    # Restore from latest backup if available
    local latest_backup=$(find /opt/cli-trading/backups -type d -name "20*" | sort -r | head -1)
    if [[ -n "$latest_backup" ]]; then
        log "Restoring from backup: $latest_backup"
        
        # Restore secrets
        if [[ -f "$latest_backup/secrets_*.tar.gz.gpg" ]]; then
            echo "Please provide GPG passphrase to restore secrets:"
            gpg --decrypt "$latest_backup"/secrets_*.tar.gz.gpg | tar -xzf - -C /opt/cli-trading/
        fi
        
        # Restore configuration
        tar -xzf "$latest_backup"/config_*.tar.gz -C /opt/cli-trading/
        
        # Restore databases
        if [[ -f "$latest_backup"/postgres_*.sql.gz ]]; then
            log "Restoring PostgreSQL database..."
            gunzip -c "$latest_backup"/postgres_*.sql.gz | docker exec -i cli-trading-postgres-1 psql -U trader
        fi
        
        if [[ -f "$latest_backup"/redis_*.rdb ]]; then
            log "Restoring Redis database..."
            docker cp "$latest_backup"/redis_*.rdb cli-trading-redis-1:/data/dump.rdb
            docker restart cli-trading-redis-1
        fi
        
        green "✓ Rollback completed from backup: $latest_backup"
    else
        yellow "No backup found for rollback"
    fi
    
    exit 0
}

# Handle rollback request
if [[ "$ROLLBACK" == "true" ]]; then
    perform_rollback
fi

# Create log directory
mkdir -p "$(dirname "$DEPLOYMENT_LOG")"

# Start deployment
bold "🚀 Starting CLI-Trading Production Deployment"
log "Deployment started with parameters: force=$FORCE_DEPLOY, skip_tests=$SKIP_TESTS"

# Step 1: Pre-flight checks
show_progress
log "Checking prerequisites..."

# Check if running as trader user
if [[ "$USER" != "trader" ]]; then
    error_exit "Deployment must run as 'trader' user. Run: sudo su - trader"
fi

# Check Docker access
if ! docker info >/dev/null 2>&1; then
    error_exit "Cannot access Docker. Ensure Docker is running and user has permissions"
fi

# Check project directory
if [[ ! -f "$PROJECT_DIR/docker-compose.yml" ]]; then
    error_exit "docker-compose.yml not found in $PROJECT_DIR"
fi

# Check for existing deployment
if docker compose -f "$PROJECT_DIR/docker-compose.yml" ps --quiet | grep -q .; then
    if [[ "$FORCE_DEPLOY" == "false" ]]; then
        error_exit "Existing deployment detected. Use --force to override or --rollback to restore"
    else
        log "Force deployment requested, stopping existing services..."
        docker compose -f "$PROJECT_DIR/docker-compose.yml" down
    fi
fi

green "✓ Pre-flight checks passed"

# Step 2: Environment validation
show_progress
log "Validating environment configuration..."

if [[ ! -f "$PROJECT_DIR/.env" ]]; then
    error_exit ".env file not found. Copy from .env.example and configure"
fi

# Load environment variables
set -a
source "$PROJECT_DIR/.env"
set +a

# Validate required environment variables
required_vars=(
    "REDIS_URL"
    "POSTGRES_HOST"
    "POSTGRES_USER"
    "POSTGRES_DB"
    "NODE_ENV"
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        error_exit "Required environment variable $var is not set"
    fi
done

green "✓ Environment validation passed"

# Step 3: Secrets verification
show_progress
log "Verifying secrets configuration..."

required_secrets=(
    "admin_token"
    "postgres_password"
)

for secret in "${required_secrets[@]}"; do
    if [[ ! -f "$PROJECT_DIR/secrets/$secret" ]]; then
        error_exit "Required secret file missing: secrets/$secret"
    fi
    
    # Check file permissions
    perms=$(stat -c "%a" "$PROJECT_DIR/secrets/$secret")
    if [[ "$perms" != "600" ]] && [[ "$perms" != "400" ]]; then
        log "Fixing permissions for secrets/$secret"
        chmod 600 "$PROJECT_DIR/secrets/$secret"
    fi
done

green "✓ Secrets verification passed"

# Step 4: Image building
show_progress
log "Building Docker images..."

cd "$PROJECT_DIR"

# Build images with progress output
if ! docker compose build --parallel; then
    error_exit "Docker image build failed"
fi

# Verify images were created
agents=("orchestrator" "portfolio-manager" "market-analyst" "risk-manager" "trade-executor" "notification-manager" "parameter-optimizer" "mcp-hub-controller")
for agent in "${agents[@]}"; do
    if ! docker images | grep -q "cli-trading-$agent"; then
        error_exit "Image for $agent was not built successfully"
    fi
done

green "✓ Docker images built successfully"

# Step 5: Infrastructure startup
show_progress
log "Starting infrastructure services..."

# Start infrastructure services first (Redis, Postgres, etc.)
infrastructure_services=("redis" "postgres" "prometheus" "grafana" "loki" "promtail")

for service in "${infrastructure_services[@]}"; do
    log "Starting $service..."
    docker compose up -d "$service"
    
    # Wait for service to be healthy
    timeout=60
    while [[ $timeout -gt 0 ]]; do
        if docker compose ps "$service" | grep -q "healthy\|running"; then
            break
        fi
        sleep 2
        timeout=$((timeout - 2))
    done
    
    if [[ $timeout -le 0 ]]; then
        error_exit "Service $service failed to start within timeout"
    fi
done

green "✓ Infrastructure services started"

# Step 6: Agent deployment
show_progress
log "Deploying trading agents..."

# Start agents in dependency order
agent_order=("orchestrator" "portfolio-manager" "market-analyst" "risk-manager" "trade-executor" "notification-manager" "parameter-optimizer" "mcp-hub-controller")

for agent in "${agent_order[@]}"; do
    log "Starting $agent..."
    docker compose up -d "$agent"
    
    # Wait for agent to be healthy
    timeout=120
    port=""
    case $agent in
        "orchestrator") port="7001" ;;
        "portfolio-manager") port="7002" ;;
        "market-analyst") port="7003" ;;
        "risk-manager") port="7004" ;;
        "trade-executor") port="7005" ;;
        "notification-manager") port="7006" ;;
        "parameter-optimizer") port="7007" ;;
        "mcp-hub-controller") port="7008" ;;
    esac
    
    if [[ -n "$port" ]]; then
        while [[ $timeout -gt 0 ]]; do
            if curl -sf "http://localhost:$port/health" >/dev/null 2>&1; then
                log "$agent health check passed"
                break
            fi
            sleep 5
            timeout=$((timeout - 5))
        done
        
        if [[ $timeout -le 0 ]]; then
            error_exit "Agent $agent failed health check within timeout"
        fi
    fi
done

green "✓ All agents deployed successfully"

# Step 7: Health validation
show_progress
log "Performing comprehensive health validation..."

# Run detailed health checks
if ! "$SCRIPT_DIR/health-check.sh"; then
    error_exit "Health validation failed"
fi

# Check Redis connectivity
if ! docker exec cli-trading-redis-1 redis-cli ping | grep -q "PONG"; then
    error_exit "Redis connectivity check failed"
fi

# Check PostgreSQL connectivity
if ! docker exec cli-trading-postgres-1 pg_isready -U trader; then
    error_exit "PostgreSQL connectivity check failed"
fi

# Verify all agent APIs are responding
api_endpoints=(
    "http://localhost:7001/health"
    "http://localhost:7002/health"
    "http://localhost:7003/health"
    "http://localhost:7004/health"
    "http://localhost:7005/health"
    "http://localhost:7006/health"
    "http://localhost:7007/health"
    "http://localhost:7008/health"
)

for endpoint in "${api_endpoints[@]}"; do
    if ! curl -sf "$endpoint" | jq -e '.status == "healthy"' >/dev/null; then
        error_exit "API health check failed for $endpoint"
    fi
done

green "✓ Health validation passed"

# Step 8: Integration testing
show_progress
if [[ "$SKIP_TESTS" == "false" ]]; then
    log "Running integration tests..."
    
    # Run test suite
    if ! docker compose run --rm tests; then
        error_exit "Integration tests failed"
    fi
    
    green "✓ Integration tests passed"
else
    yellow "⚠ Integration tests skipped"
fi

# Step 9: Security audit
show_progress
log "Performing security audit..."

# Check container security
log "Auditing container security..."
insecure_containers=()

for container in $(docker ps --format "{{.Names}}" | grep "cli-trading"); do
    # Check if running as root
    if docker exec "$container" id 2>/dev/null | grep -q "uid=0"; then
        insecure_containers+=("$container: running as root")
    fi
    
    # Check for privileged mode
    if docker inspect "$container" | jq -e '.[0].HostConfig.Privileged == true' >/dev/null 2>&1; then
        insecure_containers+=("$container: running in privileged mode")
    fi
done

if [[ ${#insecure_containers[@]} -gt 0 ]]; then
    yellow "Security warnings found:"
    for warning in "${insecure_containers[@]}"; do
        yellow "  - $warning"
    done
fi

# Check secrets permissions
log "Auditing secrets permissions..."
for secret_file in "$PROJECT_DIR"/secrets/*; do
    if [[ -f "$secret_file" ]]; then
        perms=$(stat -c "%a" "$secret_file")
        if [[ "$perms" != "600" ]] && [[ "$perms" != "400" ]]; then
            error_exit "Insecure permissions on $(basename "$secret_file"): $perms (should be 600 or 400)"
        fi
    fi
done

green "✓ Security audit completed"

# Step 10: Performance validation
show_progress
log "Validating system performance..."

# Check resource usage
for service in $(docker compose ps --services); do
    container_name="cli-trading-${service}-1"
    if docker ps --format "{{.Names}}" | grep -q "$container_name"; then
        # Get memory usage
        mem_usage=$(docker stats --no-stream --format "{{.MemUsage}}" "$container_name" | cut -d'/' -f1)
        log "$service memory usage: $mem_usage"
        
        # Check if container is responsive
        if ! docker exec "$container_name" echo "ok" >/dev/null 2>&1; then
            error_exit "Container $container_name is not responsive"
        fi
    fi
done

green "✓ Performance validation passed"

# Step 11: Monitoring setup
show_progress
log "Verifying monitoring and alerting setup..."

# Check Prometheus targets
if ! curl -sf "http://localhost:9090/api/v1/targets" | jq -e '.data.activeTargets | length > 0' >/dev/null; then
    error_exit "Prometheus has no active targets"
fi

# Check Grafana health
if ! curl -sf "http://localhost:3000/api/health" | jq -e '.database == "ok"' >/dev/null; then
    error_exit "Grafana health check failed"
fi

# Verify log aggregation
if docker ps --format "{{.Names}}" | grep -q "cli-trading-loki"; then
    if ! curl -sf "http://localhost:3100/ready" >/dev/null; then
        yellow "⚠ Loki health check failed"
    fi
fi

green "✓ Monitoring setup verified"

# Step 12: Final verification
show_progress
log "Performing final deployment verification..."

# Create deployment success marker
deployment_info="{
  \"deployment_time\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",
  \"version\": \"$(git rev-parse HEAD 2>/dev/null || echo 'unknown')\",
  \"services\": $(docker compose ps --format json | jq -s '.'),
  \"health_status\": \"verified\"
}"

echo "$deployment_info" > /opt/cli-trading/data/deployment.json

# Final health check
log "Running final health check..."
if ! "$SCRIPT_DIR/health-check.sh" >/dev/null 2>&1; then
    error_exit "Final health check failed"
fi

# Create deployment completion timestamp
date -u +%Y-%m-%dT%H:%M:%SZ > /opt/cli-trading/data/last_deployment

green "✓ Final verification completed"

# Deployment summary
bold "🎉 Deployment Completed Successfully!"
log "Deployment completed successfully"

echo
blue "=== Deployment Summary ==="
echo "Deployment time: $(date)"
echo "Project: $COMPOSE_PROJECT_NAME"
echo "Services deployed: $(docker compose ps --services | wc -l)"
echo "Containers running: $(docker compose ps --quiet | wc -l)"
echo
blue "=== Service URLs ==="
echo "Orchestrator: http://localhost:7001"
echo "Portfolio Manager: http://localhost:7002"
echo "Market Analyst: http://localhost:7003"
echo "Risk Manager: http://localhost:7004"
echo "Trade Executor: http://localhost:7005"
echo "Notification Manager: http://localhost:7006"
echo "Parameter Optimizer: http://localhost:7007"
echo "MCP Hub Controller: http://localhost:7008"
echo
echo "Grafana: http://localhost:3000"
echo "Prometheus: http://localhost:9090"
echo
blue "=== Next Steps ==="
echo "1. Configure monitoring dashboards in Grafana"
echo "2. Set up alerting rules in Prometheus"
echo "3. Test trading workflows with small amounts"
echo "4. Monitor logs: docker compose logs -f"
echo "5. Schedule regular backups with: crontab -e"
echo
yellow "=== Important ==="
echo "• Monitor system closely for the first 24 hours"
echo "• Keep deployment logs: $DEPLOYMENT_LOG"
echo "• Health check script: $SCRIPT_DIR/health-check.sh"
echo "• Backup script: /opt/cli-trading/scripts/backup-system.sh"
echo
log "Deployment documentation and logs available at: $DEPLOYMENT_LOG"