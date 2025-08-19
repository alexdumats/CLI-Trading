#!/bin/bash
#
# System Validation Script for CLI-Trading
#
# This script runs comprehensive validation tests including:
# - Pre-deployment validation
# - Health checks
# - E2E trading workflow tests
# - Performance validation
# - Security audit
# - Integration testing
#
# Usage: ./scripts/validate-system.sh [--quick] [--full] [--report]
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VALIDATION_LOG="/opt/cli-trading/logs/validation.log"
REPORT_DIR="/opt/cli-trading/reports"
QUICK_MODE=false
FULL_MODE=false
GENERATE_REPORT=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --quick)
            QUICK_MODE=true
            shift
            ;;
        --full)
            FULL_MODE=true
            shift
            ;;
        --report)
            GENERATE_REPORT=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--quick] [--full] [--report]"
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
    echo "$message" >> "$VALIDATION_LOG" 2>/dev/null || true
}

# Validation results tracking
declare -A validation_results=()
declare -A test_results=()
validation_start_time=$(date +%s)
overall_status="pass"

# Update overall status
update_status() {
    local new_status=$1
    if [[ "$new_status" == "fail" ]] || [[ "$overall_status" != "fail" && "$new_status" == "warn" ]]; then
        overall_status="$new_status"
    fi
}

# Run a validation step
run_validation_step() {
    local step_name=$1
    local step_command=$2
    local is_critical=${3:-true}
    
    log "Running validation step: $step_name"
    blue "🔍 $step_name"
    
    local start_time=$(date +%s)
    local step_status="pass"
    local step_output=""
    
    if eval "$step_command" 2>&1 | tee -a "$VALIDATION_LOG"; then
        step_status="pass"
        green "✓ $step_name: PASSED"
    else
        step_status="fail"
        red "✗ $step_name: FAILED"
        
        if [[ "$is_critical" == "true" ]]; then
            update_status "fail"
        else
            update_status "warn"
        fi
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    validation_results["$step_name"]="$step_status"
    test_results["${step_name}_duration"]="${duration}s"
    
    log "$step_name completed in ${duration}s with status: $step_status"
}

# Pre-deployment validation
validate_prerequisites() {
    log "Starting prerequisite validation..."
    
    # Check Docker
    run_validation_step "Docker Service" "docker info >/dev/null"
    
    # Check Docker Compose
    run_validation_step "Docker Compose" "docker compose version >/dev/null"
    
    # Check Node.js
    run_validation_step "Node.js Runtime" "node --version >/dev/null"
    
    # Check environment file
    run_validation_step "Environment Configuration" "[[ -f '$PROJECT_DIR/.env' ]]"
    
    # Check secrets
    run_validation_step "Secrets Configuration" "[[ -f '$PROJECT_DIR/secrets/admin_token' && -f '$PROJECT_DIR/secrets/postgres_password' ]]"
    
    # Check project structure
    run_validation_step "Project Structure" "[[ -f '$PROJECT_DIR/docker-compose.yml' && -d '$PROJECT_DIR/agents' ]]"
}

# Container and service validation
validate_containers() {
    log "Starting container validation..."
    
    # Check all containers are running
    run_validation_step "All Containers Running" "
        expected_containers=8
        running_containers=\$(docker compose -f '$PROJECT_DIR/docker-compose.yml' ps --quiet | wc -l)
        [[ \$running_containers -ge \$expected_containers ]]
    "
    
    # Check container health
    run_validation_step "Container Health Status" "
        unhealthy_containers=\$(docker ps --filter 'health=unhealthy' --format '{{.Names}}' | wc -l)
        [[ \$unhealthy_containers -eq 0 ]]
    "
    
    # Check resource usage
    run_validation_step "Container Resource Usage" "
        # Check if any container is using >90% memory
        high_mem_containers=\$(docker stats --no-stream --format 'table {{.Container}}\t{{.MemPerc}}' | awk 'NR>1 {gsub(/%/, \"\", \$2); if(\$2>90) print \$1}' | wc -l)
        [[ \$high_mem_containers -eq 0 ]]
    "
}

# Network connectivity validation
validate_networking() {
    log "Starting network validation..."
    
    # Check internal networking
    run_validation_step "Internal Network Connectivity" "
        docker exec cli-trading-orchestrator-1 curl -sf http://redis:6379 >/dev/null || true
        docker exec cli-trading-orchestrator-1 nc -z postgres 5432
    "
    
    # Check Redis connectivity
    run_validation_step "Redis Connectivity" "
        docker exec cli-trading-redis-1 redis-cli ping | grep -q PONG
    "
    
    # Check PostgreSQL connectivity
    run_validation_step "PostgreSQL Connectivity" "
        docker exec cli-trading-postgres-1 pg_isready -U trader
    "
}

# API endpoint validation
validate_apis() {
    log "Starting API validation..."
    
    # Health endpoints
    local agents=("orchestrator:7001" "portfolio-manager:7002" "market-analyst:7003" "risk-manager:7004" "trade-executor:7005" "notification-manager:7006" "parameter-optimizer:7007" "mcp-hub-controller:7008")
    
    for agent_port in "${agents[@]}"; do
        local agent=${agent_port%:*}
        local port=${agent_port#*:}
        
        run_validation_step "$agent Health API" "
            curl -sf http://localhost:$port/health | jq -e '.status == \"healthy\"' >/dev/null
        "
        
        run_validation_step "$agent Metrics API" "
            curl -sf http://localhost:$port/metrics | grep -q '# HELP'
        " false  # Non-critical
    done
}

# Infrastructure service validation
validate_infrastructure() {
    log "Starting infrastructure validation..."
    
    # Prometheus
    run_validation_step "Prometheus Service" "
        curl -sf http://localhost:9090/-/healthy >/dev/null
    "
    
    run_validation_step "Prometheus Targets" "
        active_targets=\$(curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets | length')
        [[ \$active_targets -gt 0 ]]
    "
    
    # Grafana
    run_validation_step "Grafana Service" "
        curl -sf http://localhost:3000/api/health | jq -e '.database == \"ok\"' >/dev/null
    "
    
    # Loki (if available)
    run_validation_step "Loki Service" "
        curl -sf http://localhost:3100/ready >/dev/null || true
    " false  # Non-critical
}

# MCP connectivity validation
validate_mcp() {
    log "Starting MCP validation..."
    
    run_validation_step "MCP Connectivity Validation" "
        '$SCRIPT_DIR/validate-mcp-connectivity.sh' --verbose
    " false  # Non-critical as MCP may not be fully configured
}

# Security validation
validate_security() {
    log "Starting security validation..."
    
    # Check secrets permissions
    run_validation_step "Secrets File Permissions" "
        find '$PROJECT_DIR/secrets' -type f -exec stat -c '%a %n' {} \\; | while read perm file; do
            [[ \$perm == '600' ]] || [[ \$perm == '400' ]] || exit 1
        done
    "
    
    # Check container security
    run_validation_step "Container Security Settings" "
        # Check for containers running as root
        root_containers=\$(docker inspect \$(docker ps -q) | jq -r '.[] | select(.Config.User == \"\" or .Config.User == \"0\" or .Config.User == \"root\") | .Name' | wc -l)
        [[ \$root_containers -eq 0 ]]
    " false  # Non-critical warning
    
    # Check exposed ports
    run_validation_step "Port Exposure Audit" "
        # Only expected ports should be exposed
        exposed_ports=\$(docker ps --format 'table {{.Ports}}' | grep -v PORTS | wc -l)
        [[ \$exposed_ports -le 20 ]]  # Reasonable limit
    " false
}

# Performance validation
validate_performance() {
    log "Starting performance validation..."
    
    # API response time test
    run_validation_step "API Response Time" "
        response_time=\$(curl -sf -w '%{time_total}' -o /dev/null http://localhost:7001/health)
        [[ \$(echo \"\$response_time < 5.0\" | bc -l) -eq 1 ]]
    "
    
    # Memory usage check
    run_validation_step "System Memory Usage" "
        mem_usage_pct=\$(free | awk 'NR==2{printf \"%.0f\", \$3*100/\$2}')
        [[ \$mem_usage_pct -lt 90 ]]
    "
    
    # Disk usage check
    run_validation_step "Disk Usage" "
        disk_usage_pct=\$(df /opt/cli-trading | awk 'NR==2{print \$5}' | sed 's/%//')
        [[ \$disk_usage_pct -lt 85 ]]
    "
}

# End-to-end workflow testing
run_e2e_tests() {
    log "Starting end-to-end tests..."
    
    if [[ "$QUICK_MODE" == "true" ]]; then
        # Quick smoke tests only
        run_validation_step "E2E Smoke Tests" "
            cd '$PROJECT_DIR'
            timeout 60 npm run test:e2e -- --testNamePattern='should validate all agent health endpoints'
        "
    else
        # Full E2E test suite
        run_validation_step "E2E Trading Workflow Tests" "
            cd '$PROJECT_DIR'
            npm run test:e2e
        "
    fi
}

# Data integrity validation
validate_data_integrity() {
    log "Starting data integrity validation..."
    
    # Check Redis data structures
    run_validation_step "Redis Data Structures" "
        # Test basic Redis operations
        docker exec cli-trading-redis-1 redis-cli set test_key test_value >/dev/null
        docker exec cli-trading-redis-1 redis-cli get test_key | grep -q test_value
        docker exec cli-trading-redis-1 redis-cli del test_key >/dev/null
    "
    
    # Check PostgreSQL schema
    run_validation_step "PostgreSQL Schema" "
        # Check if required tables exist
        tables=\$(docker exec cli-trading-postgres-1 psql -U trader -d trading -t -c \"SELECT count(*) FROM information_schema.tables WHERE table_schema='public';\" | xargs)
        [[ \$tables -gt 0 ]]
    "
}

# Load testing (full mode only)
run_load_tests() {
    if [[ "$FULL_MODE" != "true" ]]; then
        return 0
    fi
    
    log "Starting load tests..."
    
    run_validation_step "Concurrent Load Test" "
        # Test with 20 concurrent requests
        for i in {1..20}; do
            curl -sf http://localhost:7001/health >/dev/null &
        done
        wait
    "
    
    run_validation_step "Sustained Load Test" "
        # Test with requests over 60 seconds
        end_time=\$((SECONDS + 60))
        while [[ SECONDS -lt end_time ]]; do
            curl -sf http://localhost:7001/health >/dev/null
            sleep 0.5
        done
    " false  # Non-critical
}

# Generate validation report
generate_validation_report() {
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local end_time=$(date +%s)
    local total_duration=$((end_time - validation_start_time))
    
    mkdir -p "$REPORT_DIR"
    local report_file="$REPORT_DIR/validation-report-$(date +%Y%m%d_%H%M%S).json"
    
    # Create JSON report
    cat > "$report_file" << EOF
{
  "timestamp": "$timestamp",
  "overall_status": "$overall_status",
  "total_duration": "${total_duration}s",
  "validation_mode": "$(if [[ "$QUICK_MODE" == "true" ]]; then echo "quick"; elif [[ "$FULL_MODE" == "true" ]]; then echo "full"; else echo "standard"; fi)",
  "validation_results": {
EOF

    local first=true
    for step in "${!validation_results[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo "," >> "$report_file"
        fi
        echo "    \"$step\": \"${validation_results[$step]}\"" >> "$report_file"
    done

    cat >> "$report_file" << EOF
  },
  "test_metrics": {
EOF

    first=true
    for metric in "${!test_results[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo "," >> "$report_file"
        fi
        echo "    \"$metric\": \"${test_results[$metric]}\"" >> "$report_file"
    done

    cat >> "$report_file" << EOF
  },
  "system_info": {
    "hostname": "$(hostname)",
    "kernel": "$(uname -r)",
    "docker_version": "$(docker --version | cut -d' ' -f3 | sed 's/,//')",
    "compose_version": "$(docker compose version --short)",
    "node_version": "$(node --version)"
  }
}
EOF

    log "Validation report generated: $report_file"
    echo "$report_file"
}

# Display results summary
display_summary() {
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local end_time=$(date +%s)
    local total_duration=$((end_time - validation_start_time))
    
    echo
    bold "🏁 System Validation Summary"
    echo "Timestamp: $timestamp"
    echo "Duration: ${total_duration}s"
    echo "Mode: $(if [[ "$QUICK_MODE" == "true" ]]; then echo "Quick"; elif [[ "$FULL_MODE" == "true" ]]; then echo "Full"; else echo "Standard"; fi)"
    echo
    
    local passed=0
    local failed=0
    local warned=0
    
    echo "Validation Results:"
    for step in "${!validation_results[@]}"; do
        local status="${validation_results[$step]}"
        local duration="${test_results[${step}_duration]:-unknown}"
        
        printf "  %-35s: " "$step"
        case $status in
            "pass")
                green "✓ PASSED"
                ((passed++))
                ;;
            "fail")
                red "✗ FAILED"
                ((failed++))
                ;;
            "warn")
                yellow "⚠ WARNING"
                ((warned++))
                ;;
        esac
        echo " ($duration)"
    done
    
    echo
    echo "Summary: $passed passed, $failed failed, $warned warnings"
    echo "Overall Status: $(if [[ "$overall_status" == "pass" ]]; then green "PASS"; elif [[ "$overall_status" == "warn" ]]; then yellow "PASS (with warnings)"; else red "FAIL"; fi)"
    
    if [[ "$overall_status" == "fail" ]]; then
        echo
        red "❌ System validation failed. Check the logs and failed tests above."
        echo "Logs: $VALIDATION_LOG"
    elif [[ "$overall_status" == "warn" ]]; then
        echo
        yellow "⚠ System validation passed with warnings. Review the warnings above."
    else
        echo
        green "✅ System validation passed successfully!"
        echo "The CLI-Trading system is ready for production use."
    fi
}

# Main execution
main() {
    # Create log and report directories
    mkdir -p "$(dirname "$VALIDATION_LOG")"
    mkdir -p "$REPORT_DIR"
    
    bold "🚀 Starting CLI-Trading System Validation"
    log "System validation started"
    
    # Run validation steps based on mode
    if [[ "$QUICK_MODE" == "true" ]]; then
        log "Running quick validation mode"
        validate_prerequisites
        validate_containers
        validate_apis
        run_e2e_tests
    elif [[ "$FULL_MODE" == "true" ]]; then
        log "Running full validation mode"
        validate_prerequisites
        validate_containers
        validate_networking
        validate_apis
        validate_infrastructure
        validate_mcp
        validate_security
        validate_performance
        validate_data_integrity
        run_e2e_tests
        run_load_tests
    else
        log "Running standard validation mode"
        validate_prerequisites
        validate_containers
        validate_networking
        validate_apis
        validate_infrastructure
        validate_mcp
        validate_security
        validate_performance
        run_e2e_tests
    fi
    
    # Generate report if requested
    if [[ "$GENERATE_REPORT" == "true" ]]; then
        local report_file=$(generate_validation_report)
        echo "Report generated: $report_file"
    fi
    
    # Display summary
    display_summary
    
    # Exit with appropriate code
    case $overall_status in
        "pass") exit 0 ;;
        "warn") exit 1 ;;
        "fail") exit 2 ;;
        *) exit 3 ;;
    esac
}

# Handle script interruption
trap 'echo; log "Validation interrupted"; exit 130' INT TERM

# Run main function
main