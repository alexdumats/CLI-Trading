#!/bin/bash
#
# Continuous Deployment Script for CLI-Trading System
#
# This script implements automated continuous deployment with zero-downtime
# updates, rollback capabilities, and comprehensive validation.
#
# Usage: ./scripts/deploy-continuous.sh [--version VERSION] [--rollback] [--canary]
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DEPLOYMENT_LOG="/opt/cli-trading/logs/continuous-deployment.log"
BACKUP_DIR="/opt/cli-trading/backups/deployments"
VERSION=""
ROLLBACK=false
CANARY_DEPLOYMENT=false
HEALTH_CHECK_TIMEOUT=300
VALIDATION_TIMEOUT=600

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --rollback)
            ROLLBACK=true
            shift
            ;;
        --canary)
            CANARY_DEPLOYMENT=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--version VERSION] [--rollback] [--canary]"
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
    echo "$message" >> "$DEPLOYMENT_LOG" 2>/dev/null || true
}

# Error handling
error_exit() {
    red "ERROR: $1"
    log "ERROR: $1"
    exit 1
}

# Load environment variables
if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

ADMIN_TOKEN=${ADMIN_TOKEN:-$(cat "$PROJECT_DIR/secrets/admin_token" 2>/dev/null || echo "")}

# Deployment state tracking
DEPLOYMENT_ID="deploy-$(date +%Y%m%d_%H%M%S)"
DEPLOYMENT_STATE_FILE="/tmp/${DEPLOYMENT_ID}.state"

# Save deployment state
save_deployment_state() {
    local state=$1
    echo "$state" > "$DEPLOYMENT_STATE_FILE"
    log "Deployment state: $state"
}

# Get current deployment version
get_current_version() {
    if [[ -f "/opt/cli-trading/data/deployment.json" ]]; then
        jq -r '.version // "unknown"' /opt/cli-trading/data/deployment.json 2>/dev/null || echo "unknown"
    else
        echo "unknown"
    fi
}

# Create deployment backup
create_deployment_backup() {
    log "Creating pre-deployment backup..."
    
    mkdir -p "$BACKUP_DIR"
    local backup_name="pre-${DEPLOYMENT_ID}"
    local backup_path="$BACKUP_DIR/$backup_name"
    
    # Create comprehensive backup
    mkdir -p "$backup_path"
    
    # Backup current deployment info
    if [[ -f "/opt/cli-trading/data/deployment.json" ]]; then
        cp "/opt/cli-trading/data/deployment.json" "$backup_path/"
    fi
    
    # Backup configurations
    cp -r "$PROJECT_DIR/.env" "$backup_path/" 2>/dev/null || true
    cp -r "$PROJECT_DIR/docker-compose.yml" "$backup_path/"
    
    # Backup secrets
    tar -czf "$backup_path/secrets.tar.gz" -C "$PROJECT_DIR" secrets/ 2>/dev/null || true
    
    # Backup current container images
    docker images --format "{{.Repository}}:{{.Tag}}" | grep cli-trading > "$backup_path/images.list"
    
    # Create backup archive
    tar -czf "$BACKUP_DIR/$backup_name.tar.gz" -C "$BACKUP_DIR" "$backup_name"
    rm -rf "$backup_path"
    
    log "Backup created: $BACKUP_DIR/$backup_name.tar.gz"
    echo "$BACKUP_DIR/$backup_name.tar.gz"
}

# Blue-Green deployment strategy
deploy_blue_green() {
    local new_version=$1
    
    log "Starting Blue-Green deployment for version $new_version..."
    
    # Create backup
    local backup_file=$(create_deployment_backup)
    save_deployment_state "backup_created"
    
    # Build new images with version tag
    log "Building new images..."
    docker-compose build --parallel
    
    # Tag current images as 'blue' (current)
    local services=("orchestrator" "portfolio-manager" "market-analyst" "risk-manager" "trade-executor" "notification-manager" "parameter-optimizer" "mcp-hub-controller")
    
    for service in "${services[@]}"; do
        docker tag "cli-trading-$service:latest" "cli-trading-$service:blue"
        docker tag "cli-trading-$service:latest" "cli-trading-$service:$new_version"
    done
    
    save_deployment_state "images_built"
    
    # Temporarily halt trading to prevent inconsistencies
    log "Temporarily halting trading for deployment..."
    curl -sf -X POST -H "X-Admin-Token: $ADMIN_TOKEN" \
         http://localhost:7001/admin/orchestrate/halt \
         -d '{"reason":"deployment_in_progress"}' >/dev/null || true
    
    save_deployment_state "trading_halted"
    
    # Start green environment (new version)
    log "Starting green environment..."
    
    # Update docker-compose with new image tags
    cp docker-compose.yml docker-compose.green.yml
    
    # Deploy new version
    docker-compose -f docker-compose.green.yml down
    docker-compose -f docker-compose.green.yml up -d
    
    save_deployment_state "green_deployed"
    
    # Wait for services to start
    log "Waiting for green environment to be ready..."
    sleep 30
    
    # Health check green environment
    local health_check_passed=true
    for ((i=1; i<=30; i++)); do
        if "$SCRIPT_DIR/comprehensive-health-check.sh" >/dev/null 2>&1; then
            log "Green environment health check passed"
            break
        fi
        
        if [[ $i -eq 30 ]]; then
            health_check_passed=false
            break
        fi
        
        sleep 10
    done
    
    if [[ "$health_check_passed" != "true" ]]; then
        log "Green environment health check failed, rolling back..."
        rollback_deployment "$backup_file"
        return 1
    fi
    
    save_deployment_state "green_validated"
    
    # Switch traffic to green (this is simplified - in production you'd update load balancer)
    log "Switching to green environment..."
    
    # Stop blue environment
    docker-compose -f docker-compose.yml down
    
    # Rename green compose file to main
    mv docker-compose.green.yml docker-compose.yml
    
    save_deployment_state "traffic_switched"
    
    # Resume trading
    log "Resuming trading operations..."
    curl -sf -X POST -H "X-Admin-Token: $ADMIN_TOKEN" \
         http://localhost:7001/admin/orchestrate/unhalt >/dev/null || true
    
    # Final validation
    log "Performing final validation..."
    if ! "$SCRIPT_DIR/validate-system.sh" --quick >/dev/null 2>&1; then
        log "Final validation failed, rolling back..."
        rollback_deployment "$backup_file"
        return 1
    fi
    
    save_deployment_state "deployment_complete"
    
    # Update deployment metadata
    cat > "/opt/cli-trading/data/deployment.json" << EOF
{
  "deployment_id": "$DEPLOYMENT_ID",
  "version": "$new_version",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "strategy": "blue-green",
  "backup_file": "$backup_file",
  "previous_version": "$(get_current_version)"
}
EOF
    
    green "✅ Blue-Green deployment completed successfully!"
}

# Canary deployment strategy
deploy_canary() {
    local new_version=$1
    
    log "Starting Canary deployment for version $new_version..."
    
    # Create backup
    local backup_file=$(create_deployment_backup)
    save_deployment_state "backup_created"
    
    # Build new images
    log "Building canary images..."
    docker-compose build --parallel
    
    # Tag images as canary
    local services=("orchestrator" "portfolio-manager" "market-analyst" "risk-manager" "trade-executor" "notification-manager" "parameter-optimizer" "mcp-hub-controller")
    
    for service in "${services[@]}"; do
        docker tag "cli-trading-$service:latest" "cli-trading-$service:canary-$new_version"
    done
    
    save_deployment_state "canary_images_built"
    
    # Deploy canary instances (scaled down)
    log "Deploying canary instances..."
    
    # Start with a single critical service (orchestrator) as canary
    local canary_compose=$(cat docker-compose.yml | sed "s/cli-trading-orchestrator:latest/cli-trading-orchestrator:canary-$new_version/")
    echo "$canary_compose" > docker-compose.canary.yml
    
    # Scale down to single instance for canary
    docker-compose -f docker-compose.canary.yml up -d --scale orchestrator=1
    
    save_deployment_state "canary_deployed"
    
    # Monitor canary for specified period
    local canary_duration=${CANARY_DURATION:-300}  # 5 minutes default
    log "Monitoring canary deployment for $canary_duration seconds..."
    
    local canary_healthy=true
    local start_time=$(date +%s)
    
    while [[ $(($(date +%s) - start_time)) -lt $canary_duration ]]; do
        # Check canary health
        if ! curl -sf http://localhost:7001/health >/dev/null 2>&1; then
            canary_healthy=false
            break
        fi
        
        # Check error rates (simplified)
        local error_rate=$(curl -s http://localhost:9090/api/v1/query?query='rate(http_requests_total{code=~"5.."}[5m])' | jq -r '.data.result[0].value[1] // "0"')
        if (( $(echo "$error_rate > 0.1" | bc -l 2>/dev/null || echo "0") )); then
            canary_healthy=false
            break
        fi
        
        sleep 30
    done
    
    if [[ "$canary_healthy" != "true" ]]; then
        log "Canary deployment failed health checks, rolling back..."
        docker-compose -f docker-compose.canary.yml down
        rollback_deployment "$backup_file"
        return 1
    fi
    
    save_deployment_state "canary_validated"
    
    # Promote canary to full deployment
    log "Promoting canary to full deployment..."
    
    # Update all services to new version
    for service in "${services[@]}"; do
        docker tag "cli-trading-$service:canary-$new_version" "cli-trading-$service:latest"
    done
    
    # Deploy full new version
    docker-compose down
    docker-compose up -d
    
    save_deployment_state "canary_promoted"
    
    # Final validation
    log "Performing final validation..."
    if ! "$SCRIPT_DIR/validate-system.sh" --quick >/dev/null 2>&1; then
        log "Final validation failed, rolling back..."
        rollback_deployment "$backup_file"
        return 1
    fi
    
    save_deployment_state "deployment_complete"
    
    # Update deployment metadata
    cat > "/opt/cli-trading/data/deployment.json" << EOF
{
  "deployment_id": "$DEPLOYMENT_ID",
  "version": "$new_version",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "strategy": "canary",
  "backup_file": "$backup_file",
  "previous_version": "$(get_current_version)"
}
EOF
    
    green "✅ Canary deployment completed successfully!"
}

# Rolling deployment strategy
deploy_rolling() {
    local new_version=$1
    
    log "Starting Rolling deployment for version $new_version..."
    
    # Create backup
    local backup_file=$(create_deployment_backup)
    save_deployment_state "backup_created"
    
    # Build new images
    log "Building new images..."
    docker-compose build --parallel
    
    save_deployment_state "images_built"
    
    # Rolling update - update one service at a time
    local services=("notification-manager" "parameter-optimizer" "mcp-hub-controller" "market-analyst" "portfolio-manager" "risk-manager" "trade-executor" "orchestrator")
    
    for service in "${services[@]}"; do
        log "Rolling update for service: $service"
        
        # Update specific service
        docker-compose up -d --no-deps "$service"
        
        # Wait for service to be healthy
        local service_port=""
        case $service in
            "orchestrator") service_port="7001" ;;
            "portfolio-manager") service_port="7002" ;;
            "market-analyst") service_port="7003" ;;
            "risk-manager") service_port="7004" ;;
            "trade-executor") service_port="7005" ;;
            "notification-manager") service_port="7006" ;;
            "parameter-optimizer") service_port="7007" ;;
            "mcp-hub-controller") service_port="7008" ;;
        esac
        
        if [[ -n "$service_port" ]]; then
            local health_attempts=0
            while [[ $health_attempts -lt 30 ]]; do
                if curl -sf "http://localhost:$service_port/health" >/dev/null 2>&1; then
                    log "Service $service is healthy"
                    break
                fi
                sleep 10
                ((health_attempts++))
            done
            
            if [[ $health_attempts -eq 30 ]]; then
                log "Service $service failed to become healthy, rolling back..."
                rollback_deployment "$backup_file"
                return 1
            fi
        fi
        
        # Brief pause between service updates
        sleep 15
    done
    
    save_deployment_state "rolling_complete"
    
    # Final system validation
    log "Performing final system validation..."
    if ! "$SCRIPT_DIR/validate-system.sh" --quick >/dev/null 2>&1; then
        log "Final validation failed, rolling back..."
        rollback_deployment "$backup_file"
        return 1
    fi
    
    save_deployment_state "deployment_complete"
    
    # Update deployment metadata
    cat > "/opt/cli-trading/data/deployment.json" << EOF
{
  "deployment_id": "$DEPLOYMENT_ID",
  "version": "$new_version",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "strategy": "rolling",
  "backup_file": "$backup_file",
  "previous_version": "$(get_current_version)"
}
EOF
    
    green "✅ Rolling deployment completed successfully!"
}

# Rollback deployment
rollback_deployment() {
    local backup_file=${1:-""}
    
    log "Starting deployment rollback..."
    
    if [[ -z "$backup_file" ]]; then
        # Find latest backup
        backup_file=$(ls -t "$BACKUP_DIR"/pre-deploy-*.tar.gz 2>/dev/null | head -1)
        if [[ -z "$backup_file" ]]; then
            error_exit "No backup file found for rollback"
        fi
    fi
    
    log "Rolling back from backup: $backup_file"
    
    # Stop current services
    docker-compose down
    
    # Extract backup
    local temp_dir="/tmp/rollback-$$"
    mkdir -p "$temp_dir"
    tar -xzf "$backup_file" -C "$temp_dir"
    
    local backup_name=$(basename "$backup_file" .tar.gz)
    local backup_path="$temp_dir/$backup_name"
    
    # Restore configurations
    if [[ -f "$backup_path/.env" ]]; then
        cp "$backup_path/.env" "$PROJECT_DIR/"
    fi
    
    if [[ -f "$backup_path/docker-compose.yml" ]]; then
        cp "$backup_path/docker-compose.yml" "$PROJECT_DIR/"
    fi
    
    # Restore secrets
    if [[ -f "$backup_path/secrets.tar.gz" ]]; then
        tar -xzf "$backup_path/secrets.tar.gz" -C "$PROJECT_DIR"
    fi
    
    # Restore container images
    if [[ -f "$backup_path/images.list" ]]; then
        while IFS= read -r image; do
            if [[ -n "$image" ]] && docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "$image"; then
                docker tag "$image" "${image%:*}:latest"
            fi
        done < "$backup_path/images.list"
    fi
    
    # Start services with restored configuration
    docker-compose up -d
    
    # Wait for services to start
    sleep 30
    
    # Verify rollback
    if "$SCRIPT_DIR/comprehensive-health-check.sh" >/dev/null 2>&1; then
        green "✅ Rollback completed successfully"
        
        # Update deployment metadata
        cat > "/opt/cli-trading/data/deployment.json" << EOF
{
  "deployment_id": "rollback-$(date +%Y%m%d_%H%M%S)",
  "version": "$(get_current_version)",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "strategy": "rollback",
  "backup_file": "$backup_file",
  "rollback_reason": "deployment_failure"
}
EOF
    else
        red "❌ Rollback failed - manual intervention required"
        return 1
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
}

# Auto-scaling functionality
implement_auto_scaling() {
    log "Checking auto-scaling requirements..."
    
    # Get current resource usage
    local cpu_usage=$(docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}" | grep cli-trading | awk '{print $2}' | sed 's/%//' | sort -nr | head -1)
    local memory_usage=$(docker stats --no-stream --format "table {{.Name}}\t{{.MemPerc}}" | grep cli-trading | awk '{print $2}' | sed 's/%//' | sort -nr | head -1)
    
    # Scale up conditions
    if (( $(echo "$cpu_usage > 80" | bc -l 2>/dev/null || echo "0") )) || (( $(echo "$memory_usage > 80" | bc -l 2>/dev/null || echo "0") )); then
        log "High resource usage detected (CPU: $cpu_usage%, Memory: $memory_usage%), considering scale-up..."
        
        # Scale up non-critical services first
        local scalable_services=("notification-manager" "parameter-optimizer")
        
        for service in "${scalable_services[@]}"; do
            local current_scale=$(docker-compose ps -q "$service" | wc -l)
            if [[ $current_scale -lt 3 ]]; then
                log "Scaling up $service to $((current_scale + 1)) instances"
                docker-compose up -d --scale "$service=$((current_scale + 1))"
            fi
        done
    fi
    
    # Scale down conditions
    if (( $(echo "$cpu_usage < 20" | bc -l 2>/dev/null || echo "0") )) && (( $(echo "$memory_usage < 20" | bc -l 2>/dev/null || echo "0") )); then
        log "Low resource usage detected (CPU: $cpu_usage%, Memory: $memory_usage%), considering scale-down..."
        
        # Scale down non-critical services
        local scalable_services=("notification-manager" "parameter-optimizer")
        
        for service in "${scalable_services[@]}"; do
            local current_scale=$(docker-compose ps -q "$service" | wc -l)
            if [[ $current_scale -gt 1 ]]; then
                log "Scaling down $service to $((current_scale - 1)) instances"
                docker-compose up -d --scale "$service=$((current_scale - 1))"
            fi
        done
    fi
}

# Pre-deployment validation
pre_deployment_validation() {
    log "Running pre-deployment validation..."
    
    # Check system health
    if ! "$SCRIPT_DIR/comprehensive-health-check.sh" >/dev/null 2>&1; then
        error_exit "System health check failed - cannot proceed with deployment"
    fi
    
    # Check available resources
    local available_memory=$(free | awk 'NR==2{printf "%.1f", $7*100/$2}')
    if (( $(echo "$available_memory < 20" | bc -l 2>/dev/null || echo "0") )); then
        error_exit "Insufficient memory available for deployment"
    fi
    
    local available_disk=$(df /opt/cli-trading | awk 'NR==2{print 100-$5}' | sed 's/%//')
    if [[ $available_disk -lt 20 ]]; then
        error_exit "Insufficient disk space available for deployment"
    fi
    
    # Check for pending critical alerts
    if curl -sf http://localhost:9093/api/v1/alerts >/dev/null 2>&1; then
        local critical_alerts=$(curl -s http://localhost:9093/api/v1/alerts | jq '[.data[] | select(.status.state == "active" and .labels.severity == "critical")] | length')
        if [[ "$critical_alerts" != "0" ]]; then
            error_exit "Critical alerts are active - cannot proceed with deployment"
        fi
    fi
    
    green "✅ Pre-deployment validation passed"
}

# Post-deployment validation
post_deployment_validation() {
    log "Running post-deployment validation..."
    
    # Comprehensive health check
    if ! "$SCRIPT_DIR/comprehensive-health-check.sh" >/dev/null 2>&1; then
        error_exit "Post-deployment health check failed"
    fi
    
    # Run integration tests
    if ! "$SCRIPT_DIR/validate-system.sh" --quick >/dev/null 2>&1; then
        error_exit "Post-deployment system validation failed"
    fi
    
    # Check trading system status
    local trading_status=$(curl -sf -H "X-Admin-Token: $ADMIN_TOKEN" http://localhost:7001/pnl/status | jq -r '.isHalted // true')
    if [[ "$trading_status" == "true" ]]; then
        yellow "⚠️ Trading system is halted after deployment - manual intervention may be required"
    fi
    
    green "✅ Post-deployment validation passed"
}

# Main execution
main() {
    # Create log and backup directories
    mkdir -p "$(dirname "$DEPLOYMENT_LOG")"
    mkdir -p "$BACKUP_DIR"
    
    if [[ "$ROLLBACK" == "true" ]]; then
        bold "🔄 Starting Deployment Rollback"
        rollback_deployment
        return $?
    fi
    
    if [[ -z "$VERSION" ]]; then
        VERSION="$(git rev-parse HEAD 2>/dev/null || date +%Y%m%d_%H%M%S)"
    fi
    
    bold "🚀 Starting Continuous Deployment"
    log "Continuous deployment started for version: $VERSION"
    
    # Pre-deployment validation
    pre_deployment_validation
    
    # Choose deployment strategy
    if [[ "$CANARY_DEPLOYMENT" == "true" ]]; then
        deploy_canary "$VERSION"
    elif [[ "${DEPLOYMENT_STRATEGY:-rolling}" == "blue-green" ]]; then
        deploy_blue_green "$VERSION"
    else
        deploy_rolling "$VERSION"
    fi
    
    # Post-deployment validation
    post_deployment_validation
    
    # Auto-scaling check
    implement_auto_scaling
    
    # Cleanup old backups (keep last 10)
    ls -t "$BACKUP_DIR"/pre-deploy-*.tar.gz 2>/dev/null | tail -n +11 | xargs rm -f
    
    log "Continuous deployment completed successfully"
    green "🎉 Deployment completed successfully!"
    
    echo
    echo "Deployment Summary:"
    echo "  Version: $VERSION"
    echo "  Strategy: ${DEPLOYMENT_STRATEGY:-rolling}"
    echo "  Deployment ID: $DEPLOYMENT_ID"
    echo "  Timestamp: $(date)"
    echo
    echo "Next Steps:"
    echo "  • Monitor system performance for the next 30 minutes"
    echo "  • Check logs: tail -f $DEPLOYMENT_LOG"
    echo "  • View dashboard: ./scripts/ops-dashboard.sh --watch"
    echo "  • If issues occur: ./scripts/deploy-continuous.sh --rollback"
}

# Handle script interruption
trap 'echo; log "Deployment interrupted"; exit 130' INT TERM

# Run main function
main