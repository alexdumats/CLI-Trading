#!/bin/bash
#
# Master Deployment Pipeline for CLI-Trading System
#
# This script orchestrates the complete deployment pipeline including
# validation, testing, deployment, and post-deployment verification.
#
# Usage: ./scripts/deployment-pipeline.sh [--environment ENV] [--strategy STRATEGY]
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PIPELINE_LOG="/opt/cli-trading/logs/deployment-pipeline.log"
ENVIRONMENT="production"
DEPLOYMENT_STRATEGY="rolling"
VERSION=""
SKIP_TESTS=false
SKIP_SECURITY=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --strategy)
            DEPLOYMENT_STRATEGY="$2"
            shift 2
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --skip-tests)
            SKIP_TESTS=true
            shift
            ;;
        --skip-security)
            SKIP_SECURITY=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--environment ENV] [--strategy STRATEGY] [--version VERSION] [--skip-tests] [--skip-security]"
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
    echo "$message" >> "$PIPELINE_LOG" 2>/dev/null || true
}

# Error handling
error_exit() {
    red "PIPELINE FAILED: $1"
    log "PIPELINE FAILED: $1"
    
    # Send failure notification
    send_notification "FAILURE" "Deployment pipeline failed: $1"
    exit 1
}

# Pipeline stage tracking
declare -A pipeline_stages
pipeline_stages["pre_validation"]="pending"
pipeline_stages["security_audit"]="pending"
pipeline_stages["build"]="pending"
pipeline_stages["unit_tests"]="pending"
pipeline_stages["integration_tests"]="pending"
pipeline_stages["deployment"]="pending"
pipeline_stages["post_validation"]="pending"
pipeline_stages["monitoring_setup"]="pending"
pipeline_stages["cleanup"]="pending"

# Update pipeline stage status
update_stage_status() {
    local stage=$1
    local status=$2
    pipeline_stages["$stage"]="$status"
    log "Stage $stage: $status"
}

# Send notification (placeholder - integrate with your notification system)
send_notification() {
    local type=$1
    local message=$2
    
    # Log notification
    log "NOTIFICATION [$type]: $message"
    
    # Send to Slack if webhook is configured
    if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
        local color="good"
        case $type in
            "FAILURE") color="danger" ;;
            "WARNING") color="warning" ;;
            "SUCCESS") color="good" ;;
        esac
        
        curl -sf -X POST "$SLACK_WEBHOOK_URL" \
             -H 'Content-Type: application/json' \
             -d "{
                 \"attachments\": [{
                     \"color\": \"$color\",
                     \"title\": \"CLI-Trading Deployment Pipeline\",
                     \"text\": \"$message\",
                     \"fields\": [
                         {\"title\": \"Environment\", \"value\": \"$ENVIRONMENT\", \"short\": true},
                         {\"title\": \"Strategy\", \"value\": \"$DEPLOYMENT_STRATEGY\", \"short\": true},
                         {\"title\": \"Version\", \"value\": \"${VERSION:-'auto'}\", \"short\": true},
                         {\"title\": \"Timestamp\", \"value\": \"$(date)\", \"short\": true}
                     ]
                 }]
             }" >/dev/null 2>&1 || true
    fi
}

# Stage 1: Pre-deployment validation
stage_pre_validation() {
    update_stage_status "pre_validation" "running"
    log "Starting pre-deployment validation..."
    
    # Check system health
    if ! "$SCRIPT_DIR/comprehensive-health-check.sh" >/dev/null 2>&1; then
        update_stage_status "pre_validation" "failed"
        error_exit "System health check failed"
    fi
    
    # Check available resources
    local available_memory=$(free | awk 'NR==2{printf "%.1f", $7*100/$2}')
    if (( $(echo "$available_memory < 20" | bc -l 2>/dev/null || echo "0") )); then
        update_stage_status "pre_validation" "failed"
        error_exit "Insufficient memory available (${available_memory}%)"
    fi
    
    local available_disk=$(df /opt/cli-trading | awk 'NR==2{print 100-$5}' | sed 's/%//')
    if [[ $available_disk -lt 20 ]]; then
        update_stage_status "pre_validation" "failed"
        error_exit "Insufficient disk space available (${available_disk}%)"
    fi
    
    # Check for critical alerts
    if curl -sf http://localhost:9093/api/v1/alerts >/dev/null 2>&1; then
        local critical_alerts=$(curl -s http://localhost:9093/api/v1/alerts | jq '[.data[] | select(.status.state == "active" and .labels.severity == "critical")] | length' 2>/dev/null || echo "0")
        if [[ "$critical_alerts" != "0" ]]; then
            update_stage_status "pre_validation" "failed"
            error_exit "Critical alerts are active ($critical_alerts alerts)"
        fi
    fi
    
    # Validate environment configuration
    if [[ ! -f "$PROJECT_DIR/.env" ]]; then
        update_stage_status "pre_validation" "failed"
        error_exit "Environment configuration file (.env) not found"
    fi
    
    # Check secrets
    if ! "$SCRIPT_DIR/manage-secrets.sh" validate >/dev/null 2>&1; then
        update_stage_status "pre_validation" "failed"
        error_exit "Secrets validation failed"
    fi
    
    # Check Git repository status
    if [[ -d "$PROJECT_DIR/.git" ]]; then
        if [[ -n "$(git status --porcelain)" ]]; then
            yellow "Warning: Repository has uncommitted changes"
        fi
        
        if [[ -z "$VERSION" ]]; then
            VERSION=$(git rev-parse HEAD)
            log "Auto-detected version from Git: $VERSION"
        fi
    fi
    
    update_stage_status "pre_validation" "completed"
    log "Pre-deployment validation completed successfully"
}

# Stage 2: Security audit
stage_security_audit() {
    if [[ "$SKIP_SECURITY" == "true" ]]; then
        update_stage_status "security_audit" "skipped"
        yellow "Security audit skipped (--skip-security)"
        return 0
    fi
    
    update_stage_status "security_audit" "running"
    log "Running security audit..."
    
    # Run comprehensive security audit
    if ! "$SCRIPT_DIR/security-audit.sh" --report >/dev/null 2>&1; then
        # Check if it's a critical failure or just warnings
        local exit_code=$?
        if [[ $exit_code -eq 2 ]]; then
            update_stage_status "security_audit" "failed"
            error_exit "Critical security issues found"
        else
            update_stage_status "security_audit" "warning"
            yellow "Security warnings found, but proceeding with deployment"
        fi
    else
        update_stage_status "security_audit" "completed"
        log "Security audit completed successfully"
    fi
}

# Stage 3: Build
stage_build() {
    update_stage_status "build" "running"
    log "Building application images..."
    
    # Clean previous builds
    docker system prune -f >/dev/null 2>&1
    
    # Build all services
    if ! docker-compose build --parallel --no-cache; then
        update_stage_status "build" "failed"
        error_exit "Build failed"
    fi
    
    # Tag images with version
    if [[ -n "$VERSION" ]]; then
        local services=("orchestrator" "portfolio-manager" "market-analyst" "risk-manager" "trade-executor" "notification-manager" "parameter-optimizer" "mcp-hub-controller")
        
        for service in "${services[@]}"; do
            docker tag "cli-trading-$service:latest" "cli-trading-$service:$VERSION"
        done
        
        log "Images tagged with version: $VERSION"
    fi
    
    update_stage_status "build" "completed"
    log "Build completed successfully"
}

# Stage 4: Unit tests
stage_unit_tests() {
    if [[ "$SKIP_TESTS" == "true" ]]; then
        update_stage_status "unit_tests" "skipped"
        yellow "Unit tests skipped (--skip-tests)"
        return 0
    fi
    
    update_stage_status "unit_tests" "running"
    log "Running unit tests..."
    
    # Run unit tests
    if ! npm run test:unit >/dev/null 2>&1; then
        update_stage_status "unit_tests" "failed"
        error_exit "Unit tests failed"
    fi
    
    update_stage_status "unit_tests" "completed"
    log "Unit tests completed successfully"
}

# Stage 5: Integration tests
stage_integration_tests() {
    if [[ "$SKIP_TESTS" == "true" ]]; then
        update_stage_status "integration_tests" "skipped"
        yellow "Integration tests skipped (--skip-tests)"
        return 0
    fi
    
    update_stage_status "integration_tests" "running"
    log "Running integration tests..."
    
    # Ensure system is running for integration tests
    if ! docker-compose ps | grep -q "Up"; then
        log "Starting system for integration tests..."
        docker-compose up -d
        sleep 30
    fi
    
    # Run integration tests
    if ! "$SCRIPT_DIR/validate-system.sh" --quick >/dev/null 2>&1; then
        update_stage_status "integration_tests" "failed"
        error_exit "Integration tests failed"
    fi
    
    update_stage_status "integration_tests" "completed"
    log "Integration tests completed successfully"
}

# Stage 6: Deployment
stage_deployment() {
    update_stage_status "deployment" "running"
    log "Starting deployment with strategy: $DEPLOYMENT_STRATEGY"
    
    # Create pre-deployment backup
    local backup_file=$("$SCRIPT_DIR/backup-system.sh" 2>/dev/null | tail -1)
    log "Pre-deployment backup created: $backup_file"
    
    # Execute deployment based on strategy
    case $DEPLOYMENT_STRATEGY in
        "blue-green")
            if ! "$SCRIPT_DIR/deploy-continuous.sh" --version "$VERSION"; then
                update_stage_status "deployment" "failed"
                error_exit "Blue-green deployment failed"
            fi
            ;;
        "canary")
            if ! "$SCRIPT_DIR/deploy-continuous.sh" --version "$VERSION" --canary; then
                update_stage_status "deployment" "failed"
                error_exit "Canary deployment failed"
            fi
            ;;
        "rolling")
            if ! "$SCRIPT_DIR/deploy-continuous.sh" --version "$VERSION"; then
                update_stage_status "deployment" "failed"
                error_exit "Rolling deployment failed"
            fi
            ;;
        *)
            update_stage_status "deployment" "failed"
            error_exit "Unknown deployment strategy: $DEPLOYMENT_STRATEGY"
            ;;
    esac
    
    update_stage_status "deployment" "completed"
    log "Deployment completed successfully"
}

# Stage 7: Post-deployment validation
stage_post_validation() {
    update_stage_status "post_validation" "running"
    log "Running post-deployment validation..."
    
    # Wait for system to stabilize
    sleep 30
    
    # Comprehensive health check
    if ! "$SCRIPT_DIR/comprehensive-health-check.sh" >/dev/null 2>&1; then
        update_stage_status "post_validation" "failed"
        error_exit "Post-deployment health check failed"
    fi
    
    # System validation
    if ! "$SCRIPT_DIR/validate-system.sh" --quick >/dev/null 2>&1; then
        update_stage_status "post_validation" "failed"
        error_exit "Post-deployment system validation failed"
    fi
    
    # MCP connectivity validation
    if ! "$SCRIPT_DIR/validate-mcp-connectivity.sh" >/dev/null 2>&1; then
        update_stage_status "post_validation" "warning"
        yellow "MCP connectivity validation failed (non-critical)"
    fi
    
    # Trading system verification
    local trading_status=$(curl -sf -H "X-Admin-Token: ${ADMIN_TOKEN:-}" http://localhost:7001/pnl/status 2>/dev/null | jq -r '.isHalted // true' 2>/dev/null || echo "true")
    if [[ "$trading_status" == "true" ]]; then
        yellow "Trading system is halted - this may be expected"
    else
        log "Trading system is active and operational"
    fi
    
    update_stage_status "post_validation" "completed"
    log "Post-deployment validation completed successfully"
}

# Stage 8: Monitoring setup
stage_monitoring_setup() {
    update_stage_status "monitoring_setup" "running"
    log "Setting up enhanced monitoring..."
    
    # Update monitoring configurations
    if ! "$SCRIPT_DIR/setup-monitoring.sh" >/dev/null 2>&1; then
        update_stage_status "monitoring_setup" "warning"
        yellow "Monitoring setup completed with warnings"
    else
        update_stage_status "monitoring_setup" "completed"
        log "Monitoring setup completed successfully"
    fi
    
    # Generate deployment dashboard
    local dashboard_data=$("$SCRIPT_DIR/ops-dashboard.sh" --json 2>/dev/null || echo "{}")
    echo "$dashboard_data" > "/opt/cli-trading/data/post-deployment-status.json"
}

# Stage 9: Cleanup
stage_cleanup() {
    update_stage_status "cleanup" "running"
    log "Performing cleanup tasks..."
    
    # Clean up old Docker images
    docker image prune -f >/dev/null 2>&1
    
    # Clean up old build artifacts
    find "$PROJECT_DIR" -name "*.tmp" -type f -mtime +1 -delete 2>/dev/null || true
    
    # Archive old logs
    find /opt/cli-trading/logs -name "*.log" -mtime +7 -exec gzip {} \; 2>/dev/null || true
    
    # Clean up old backups (keep last 10)
    ls -t /opt/cli-trading/backups/*.tar.gz 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
    
    update_stage_status "cleanup" "completed"
    log "Cleanup completed successfully"
}

# Generate deployment report
generate_deployment_report() {
    local report_file="/opt/cli-trading/reports/deployment-pipeline-$(date +%Y%m%d_%H%M%S).md"
    
    mkdir -p "$(dirname "$report_file")"
    
    cat > "$report_file" << EOF
# Deployment Pipeline Report

**Environment:** $ENVIRONMENT
**Strategy:** $DEPLOYMENT_STRATEGY
**Version:** ${VERSION:-'auto'}
**Timestamp:** $(date)

## Pipeline Stages

EOF
    
    for stage in "${!pipeline_stages[@]}"; do
        local status="${pipeline_stages[$stage]}"
        local status_icon
        
        case $status in
            "completed") status_icon="✅" ;;
            "warning") status_icon="⚠️" ;;
            "failed") status_icon="❌" ;;
            "skipped") status_icon="⏭️" ;;
            "running") status_icon="🔄" ;;
            *) status_icon="⏸️" ;;
        esac
        
        echo "- **$stage**: $status_icon $status" >> "$report_file"
    done
    
    cat >> "$report_file" << EOF

## System Status

\`\`\`json
$(cat /opt/cli-trading/data/post-deployment-status.json 2>/dev/null || echo "{}")
\`\`\`

## Deployment Metadata

- **Pipeline Log:** $PIPELINE_LOG
- **Report Generated:** $(date)
- **Total Duration:** $(($(date +%s) - pipeline_start_time)) seconds

## Next Steps

1. Monitor system performance for the next 30 minutes
2. Review logs for any warnings or errors
3. Verify trading operations are functioning correctly
4. Update documentation if necessary

EOF
    
    log "Deployment report generated: $report_file"
    echo "$report_file"
}

# Main execution
main() {
    # Create log directory
    mkdir -p "$(dirname "$PIPELINE_LOG")"
    
    # Record pipeline start time
    pipeline_start_time=$(date +%s)
    
    bold "🚀 CLI-Trading Deployment Pipeline"
    log "Deployment pipeline started"
    log "Environment: $ENVIRONMENT"
    log "Strategy: $DEPLOYMENT_STRATEGY"
    log "Version: ${VERSION:-'auto'}"
    
    # Send start notification
    send_notification "INFO" "Deployment pipeline started for $ENVIRONMENT environment"
    
    # Execute pipeline stages
    stage_pre_validation
    stage_security_audit
    stage_build
    stage_unit_tests
    stage_integration_tests
    stage_deployment
    stage_post_validation
    stage_monitoring_setup
    stage_cleanup
    
    # Generate final report
    local report_file=$(generate_deployment_report)
    
    # Calculate total duration
    local pipeline_end_time=$(date +%s)
    local total_duration=$((pipeline_end_time - pipeline_start_time))
    
    log "Deployment pipeline completed successfully in ${total_duration} seconds"
    
    # Send success notification
    send_notification "SUCCESS" "Deployment pipeline completed successfully in ${total_duration} seconds"
    
    green "🎉 Deployment Pipeline Completed Successfully!"
    echo
    echo "Summary:"
    echo "  Environment: $ENVIRONMENT"
    echo "  Strategy: $DEPLOYMENT_STRATEGY"
    echo "  Version: ${VERSION:-'auto'}"
    echo "  Duration: ${total_duration} seconds"
    echo "  Report: $report_file"
    echo
    echo "Next Steps:"
    echo "  • Monitor system: ./scripts/ops-dashboard.sh --watch"
    echo "  • View logs: tail -f $PIPELINE_LOG"
    echo "  • Check trading: curl http://localhost:7001/pnl/status"
    echo "  • View report: cat $report_file"
}

# Handle script interruption
trap 'echo; log "Pipeline interrupted"; send_notification "FAILURE" "Pipeline interrupted by user"; exit 130' INT TERM

# Run main function
main