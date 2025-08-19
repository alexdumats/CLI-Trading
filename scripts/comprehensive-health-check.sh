#!/bin/bash
#
# Comprehensive Health Check for CLI-Trading Multi-Agent System
#
# This script performs deep health validation of all components including
# agent connectivity, MCP server validation, and system performance checks.
#
# Usage: ./scripts/comprehensive-health-check.sh [--verbose] [--json] [--continuous]
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
HEALTH_LOG="/opt/cli-trading/logs/health-check.log"
TIMEOUT=30
VERBOSE=false
JSON_OUTPUT=false
CONTINUOUS=false
CONTINUOUS_INTERVAL=60

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose)
            VERBOSE=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --continuous)
            CONTINUOUS=true
            shift
            ;;
        --interval)
            CONTINUOUS_INTERVAL="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--verbose] [--json] [--continuous] [--interval SECONDS]"
            exit 1
            ;;
    esac
done

# Color output functions (disabled in JSON mode)
if [[ "$JSON_OUTPUT" == "false" ]]; then
    red() { echo -e "\033[31m$1\033[0m"; }
    green() { echo -e "\033[32m$1\033[0m"; }
    yellow() { echo -e "\033[33m$1\033[0m"; }
    blue() { echo -e "\033[34m$1\033[0m"; }
    bold() { echo -e "\033[1m$1\033[0m"; }
else
    red() { echo "$1"; }
    green() { echo "$1"; }
    yellow() { echo "$1"; }
    blue() { echo "$1"; }
    bold() { echo "$1"; }
fi

# Logging function
log() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$HEALTH_LOG" 2>/dev/null || true
}

# Health check results
declare -A health_results
declare -A performance_metrics
declare -A agent_details

# Initialize results
overall_status="healthy"
start_time=$(date +%s)

# Agent configuration
declare -A agents=(
    ["orchestrator"]="7001"
    ["portfolio-manager"]="7002"
    ["market-analyst"]="7003"
    ["risk-manager"]="7004"
    ["trade-executor"]="7005"
    ["notification-manager"]="7006"
    ["parameter-optimizer"]="7007"
    ["mcp-hub-controller"]="7008"
)

# Infrastructure services
declare -A infrastructure=(
    ["redis"]="6379"
    ["postgres"]="5432"
    ["prometheus"]="9090"
    ["grafana"]="3000"
    ["loki"]="3100"
)

# Check if a service is responding
check_http_endpoint() {
    local service=$1
    local url=$2
    local timeout=${3:-$TIMEOUT}
    
    log "Checking HTTP endpoint: $service at $url"
    
    if timeout "$timeout" curl -sf "$url" >/dev/null 2>&1; then
        health_results["$service"]="healthy"
        log "$service: HTTP endpoint healthy"
        return 0
    else
        health_results["$service"]="unhealthy"
        log "$service: HTTP endpoint failed"
        overall_status="unhealthy"
        return 1
    fi
}

# Check service health with detailed response
check_agent_health() {
    local agent=$1
    local port=$2
    local url="http://localhost:$port/health"
    
    log "Checking agent health: $agent"
    
    local response
    local status_code
    
    if response=$(timeout "$TIMEOUT" curl -s -w "%{http_code}" "$url" 2>/dev/null); then
        status_code="${response: -3}"
        response="${response%???}"
        
        if [[ "$status_code" == "200" ]]; then
            # Parse health response
            if command -v jq >/dev/null 2>&1 && echo "$response" | jq -e . >/dev/null 2>&1; then
                local health_status
                health_status=$(echo "$response" | jq -r '.status // "unknown"')
                
                if [[ "$health_status" == "healthy" ]]; then
                    health_results["$agent"]="healthy"
                    agent_details["$agent"]="$response"
                    log "$agent: Health check passed"
                    
                    # Extract additional metrics if available
                    if echo "$response" | jq -e '.uptime' >/dev/null 2>&1; then
                        local uptime
                        uptime=$(echo "$response" | jq -r '.uptime // "unknown"')
                        performance_metrics["${agent}_uptime"]="$uptime"
                    fi
                    
                    return 0
                else
                    health_results["$agent"]="degraded"
                    log "$agent: Health status reported as $health_status"
                    overall_status="degraded"
                    return 1
                fi
            else
                health_results["$agent"]="unhealthy"
                log "$agent: Invalid health response format"
                overall_status="unhealthy"
                return 1
            fi
        else
            health_results["$agent"]="unhealthy"
            log "$agent: HTTP error $status_code"
            overall_status="unhealthy"
            return 1
        fi
    else
        health_results["$agent"]="unreachable"
        log "$agent: Connection failed"
        overall_status="unhealthy"
        return 1
    fi
}

# Check metrics endpoint
check_agent_metrics() {
    local agent=$1
    local port=$2
    local url="http://localhost:$port/metrics"
    
    log "Checking metrics endpoint: $agent"
    
    if timeout "$TIMEOUT" curl -sf "$url" >/dev/null 2>&1; then
        log "$agent: Metrics endpoint accessible"
        
        # Get basic metrics
        local metrics_response
        if metrics_response=$(timeout "$TIMEOUT" curl -s "$url" 2>/dev/null); then
            # Count available metrics
            local metric_count
            metric_count=$(echo "$metrics_response" | grep -c "^[a-zA-Z]" || echo "0")
            performance_metrics["${agent}_metrics_count"]="$metric_count"
            log "$agent: $metric_count metrics available"
        fi
        
        return 0
    else
        log "$agent: Metrics endpoint failed"
        return 1
    fi
}

# Check Docker container status
check_container_status() {
    local service=$1
    local container_name="cli-trading-${service}-1"
    
    log "Checking container status: $service"
    
    if docker ps --format "{{.Names}}" | grep -q "^$container_name$"; then
        local status
        status=$(docker inspect "$container_name" --format='{{.State.Status}}')
        
        if [[ "$status" == "running" ]]; then
            # Get additional container info
            local health_status
            health_status=$(docker inspect "$container_name" --format='{{.State.Health.Status}}' 2>/dev/null || echo "none")
            
            if [[ "$health_status" == "healthy" ]] || [[ "$health_status" == "none" ]]; then
                health_results["${service}_container"]="healthy"
                log "$service: Container running and healthy"
                
                # Get resource usage
                local mem_usage cpu_usage
                mem_usage=$(docker stats --no-stream --format "{{.MemUsage}}" "$container_name" 2>/dev/null || echo "unknown")
                cpu_usage=$(docker stats --no-stream --format "{{.CPUPerc}}" "$container_name" 2>/dev/null || echo "unknown")
                
                performance_metrics["${service}_memory"]="$mem_usage"
                performance_metrics["${service}_cpu"]="$cpu_usage"
                
                return 0
            else
                health_results["${service}_container"]="unhealthy"
                log "$service: Container unhealthy ($health_status)"
                overall_status="unhealthy"
                return 1
            fi
        else
            health_results["${service}_container"]="stopped"
            log "$service: Container not running ($status)"
            overall_status="unhealthy"
            return 1
        fi
    else
        health_results["${service}_container"]="missing"
        log "$service: Container not found"
        overall_status="unhealthy"
        return 1
    fi
}

# Check Redis connectivity and performance
check_redis() {
    log "Checking Redis connectivity and performance"
    
    # Basic connectivity
    if docker exec cli-trading-redis-1 redis-cli ping 2>/dev/null | grep -q "PONG"; then
        health_results["redis_connectivity"]="healthy"
        log "Redis: Basic connectivity OK"
        
        # Get Redis info
        local redis_info
        if redis_info=$(docker exec cli-trading-redis-1 redis-cli info 2>/dev/null); then
            # Extract key metrics
            local connected_clients memory_usage uptime
            connected_clients=$(echo "$redis_info" | grep "connected_clients:" | cut -d: -f2 | tr -d '\r')
            memory_usage=$(echo "$redis_info" | grep "used_memory_human:" | cut -d: -f2 | tr -d '\r')
            uptime=$(echo "$redis_info" | grep "uptime_in_seconds:" | cut -d: -f2 | tr -d '\r')
            
            performance_metrics["redis_clients"]="$connected_clients"
            performance_metrics["redis_memory"]="$memory_usage"
            performance_metrics["redis_uptime"]="${uptime}s"
            
            log "Redis: $connected_clients clients, $memory_usage memory, ${uptime}s uptime"
        fi
        
        # Test key operations
        if docker exec cli-trading-redis-1 redis-cli set health_check_test "ok" >/dev/null 2>&1 && \
           docker exec cli-trading-redis-1 redis-cli get health_check_test 2>/dev/null | grep -q "ok" && \
           docker exec cli-trading-redis-1 redis-cli del health_check_test >/dev/null 2>&1; then
            health_results["redis_operations"]="healthy"
            log "Redis: Key operations test passed"
        else
            health_results["redis_operations"]="failed"
            log "Redis: Key operations test failed"
            overall_status="degraded"
        fi
        
        return 0
    else
        health_results["redis_connectivity"]="failed"
        log "Redis: Connectivity failed"
        overall_status="unhealthy"
        return 1
    fi
}

# Check PostgreSQL connectivity and performance
check_postgres() {
    log "Checking PostgreSQL connectivity and performance"
    
    # Basic connectivity
    if docker exec cli-trading-postgres-1 pg_isready -U trader >/dev/null 2>&1; then
        health_results["postgres_connectivity"]="healthy"
        log "PostgreSQL: Basic connectivity OK"
        
        # Test database operations
        if docker exec cli-trading-postgres-1 psql -U trader -d trading -c "SELECT 1;" >/dev/null 2>&1; then
            health_results["postgres_operations"]="healthy"
            log "PostgreSQL: Database operations test passed"
            
            # Get database size and connection count
            local db_size connections
            db_size=$(docker exec cli-trading-postgres-1 psql -U trader -d trading -t -c "SELECT pg_size_pretty(pg_database_size('trading'));" 2>/dev/null | xargs || echo "unknown")
            connections=$(docker exec cli-trading-postgres-1 psql -U trader -d trading -t -c "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | xargs || echo "unknown")
            
            performance_metrics["postgres_size"]="$db_size"
            performance_metrics["postgres_connections"]="$connections"
            
            log "PostgreSQL: Database size $db_size, $connections connections"
        else
            health_results["postgres_operations"]="failed"
            log "PostgreSQL: Database operations test failed"
            overall_status="degraded"
        fi
        
        return 0
    else
        health_results["postgres_connectivity"]="failed"
        log "PostgreSQL: Connectivity failed"
        overall_status="unhealthy"
        return 1
    fi
}

# Check MCP server connectivity (if configured)
check_mcp_connectivity() {
    local agent=$1
    local port=$2
    
    log "Checking MCP connectivity for $agent"
    
    # Try to get MCP status from agent if it exposes this info
    local mcp_status_url="http://localhost:$port/mcp/status"
    
    if timeout "$TIMEOUT" curl -sf "$mcp_status_url" >/dev/null 2>&1; then
        local response
        if response=$(timeout "$TIMEOUT" curl -s "$mcp_status_url" 2>/dev/null); then
            if command -v jq >/dev/null 2>&1 && echo "$response" | jq -e . >/dev/null 2>&1; then
                local mcp_status
                mcp_status=$(echo "$response" | jq -r '.status // "unknown"')
                
                if [[ "$mcp_status" == "connected" ]]; then
                    health_results["${agent}_mcp"]="healthy"
                    log "$agent: MCP connectivity healthy"
                    return 0
                else
                    health_results["${agent}_mcp"]="disconnected"
                    log "$agent: MCP status: $mcp_status"
                    overall_status="degraded"
                    return 1
                fi
            fi
        fi
    fi
    
    # If no MCP endpoint, mark as not applicable
    health_results["${agent}_mcp"]="n/a"
    log "$agent: MCP status endpoint not available"
    return 0
}

# Check system resources
check_system_resources() {
    log "Checking system resources"
    
    # Memory usage
    local mem_info
    if mem_info=$(free -m 2>/dev/null); then
        local total_mem used_mem free_mem
        total_mem=$(echo "$mem_info" | awk 'NR==2{print $2}')
        used_mem=$(echo "$mem_info" | awk 'NR==2{print $3}')
        free_mem=$(echo "$mem_info" | awk 'NR==2{print $4}')
        
        performance_metrics["system_memory_total"]="${total_mem}MB"
        performance_metrics["system_memory_used"]="${used_mem}MB"
        performance_metrics["system_memory_free"]="${free_mem}MB"
        
        local mem_usage_pct=$((used_mem * 100 / total_mem))
        performance_metrics["system_memory_usage_pct"]="${mem_usage_pct}%"
        
        if [[ $mem_usage_pct -gt 90 ]]; then
            health_results["system_memory"]="critical"
            log "System: Memory usage critical ($mem_usage_pct%)"
            overall_status="degraded"
        elif [[ $mem_usage_pct -gt 80 ]]; then
            health_results["system_memory"]="warning"
            log "System: Memory usage high ($mem_usage_pct%)"
        else
            health_results["system_memory"]="healthy"
            log "System: Memory usage normal ($mem_usage_pct%)"
        fi
    fi
    
    # Disk usage
    local disk_info
    if disk_info=$(df -h /opt/cli-trading 2>/dev/null); then
        local disk_usage_pct
        disk_usage_pct=$(echo "$disk_info" | awk 'NR==2{print $5}' | sed 's/%//')
        
        performance_metrics["system_disk_usage_pct"]="${disk_usage_pct}%"
        
        if [[ $disk_usage_pct -gt 90 ]]; then
            health_results["system_disk"]="critical"
            log "System: Disk usage critical ($disk_usage_pct%)"
            overall_status="degraded"
        elif [[ $disk_usage_pct -gt 80 ]]; then
            health_results["system_disk"]="warning"
            log "System: Disk usage high ($disk_usage_pct%)"
        else
            health_results["system_disk"]="healthy"
            log "System: Disk usage normal ($disk_usage_pct%)"
        fi
    fi
    
    # Load average
    local load_avg
    if load_avg=$(uptime | awk -F'load average:' '{ print $2 }' | awk '{print $1}' | sed 's/,//'); then
        performance_metrics["system_load_avg"]="$load_avg"
        log "System: Load average $load_avg"
    fi
}

# Perform single health check
perform_health_check() {
    local check_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "Starting comprehensive health check at $check_timestamp"
    
    # Reset status for this check
    overall_status="healthy"
    health_results=()
    performance_metrics=()
    agent_details=()
    
    # Check system resources
    check_system_resources
    
    # Check infrastructure services
    log "Checking infrastructure services..."
    check_redis
    check_postgres
    
    # Check infrastructure containers
    for service in "${!infrastructure[@]}"; do
        check_container_status "$service"
        
        # Basic HTTP checks for services with web interfaces
        case $service in
            "prometheus")
                check_http_endpoint "$service" "http://localhost:9090/-/healthy"
                ;;
            "grafana")
                check_http_endpoint "$service" "http://localhost:3000/api/health"
                ;;
            "loki")
                check_http_endpoint "$service" "http://localhost:3100/ready" || true  # Optional
                ;;
        esac
    done
    
    # Check all agents
    log "Checking trading agents..."
    for agent in "${!agents[@]}"; do
        local port="${agents[$agent]}"
        
        # Container status
        check_container_status "$agent"
        
        # Health endpoint
        check_agent_health "$agent" "$port"
        
        # Metrics endpoint
        check_agent_metrics "$agent" "$port"
        
        # MCP connectivity (where applicable)
        if [[ "$agent" == "mcp-hub-controller" ]] || [[ "$agent" == "orchestrator" ]]; then
            check_mcp_connectivity "$agent" "$port"
        fi
    done
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    performance_metrics["check_duration"]="${duration}s"
    
    log "Health check completed in ${duration}s with overall status: $overall_status"
}

# Output results in JSON format
output_json() {
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    cat << EOF
{
  "timestamp": "$timestamp",
  "overall_status": "$overall_status",
  "health_results": {
EOF
    
    local first=true
    for key in "${!health_results[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi
        echo "    \"$key\": \"${health_results[$key]}\""
    done
    
    cat << EOF
  },
  "performance_metrics": {
EOF
    
    first=true
    for key in "${!performance_metrics[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi
        echo "    \"$key\": \"${performance_metrics[$key]}\""
    done
    
    cat << EOF
  },
  "agent_details": {
EOF
    
    first=true
    for key in "${!agent_details[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi
        echo "    \"$key\": ${agent_details[$key]}"
    done
    
    cat << EOF
  }
}
EOF
}

# Output results in human-readable format
output_human() {
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    bold "🏥 CLI-Trading System Health Check Report"
    echo "Timestamp: $timestamp"
    echo "Overall Status: $(if [[ "$overall_status" == "healthy" ]]; then green "$overall_status"; elif [[ "$overall_status" == "degraded" ]]; then yellow "$overall_status"; else red "$overall_status"; fi)"
    echo
    
    # System Resources
    echo "System Resources:"
    for key in "${!health_results[@]}"; do
        if [[ "$key" == system_* ]]; then
            local status="${health_results[$key]}"
            local display_name="${key#system_}"
            printf "  %-20s: " "$display_name"
            case $status in
                "healthy") green "✓ $status" ;;
                "warning") yellow "⚠ $status" ;;
                "critical") red "✗ $status" ;;
                *) red "✗ $status" ;;
            esac
        fi
    done
    echo
    
    # Infrastructure Services
    echo "Infrastructure Services:"
    for service in redis postgres prometheus grafana loki; do
        for suffix in "" "_connectivity" "_operations" "_container"; do
            key="${service}${suffix}"
            if [[ -n "${health_results[$key]:-}" ]]; then
                local status="${health_results[$key]}"
                printf "  %-20s: " "$key"
                case $status in
                    "healthy") green "✓ $status" ;;
                    "degraded") yellow "⚠ $status" ;;
                    "unhealthy"|"failed"|"stopped"|"missing") red "✗ $status" ;;
                    *) yellow "? $status" ;;
                esac
            fi
        done
    done
    echo
    
    # Trading Agents
    echo "Trading Agents:"
    for agent in "${!agents[@]}"; do
        local port="${agents[$agent]}"
        printf "  %-25s (:%s): " "$agent" "$port"
        
        local agent_status="${health_results[$agent]:-unknown}"
        local container_status="${health_results[${agent}_container]:-unknown}"
        local mcp_status="${health_results[${agent}_mcp]:-n/a}"
        
        case $agent_status in
            "healthy")
                if [[ "$container_status" == "healthy" ]]; then
                    green "✓ healthy"
                else
                    yellow "⚠ app healthy, container $container_status"
                fi
                ;;
            "degraded") yellow "⚠ $agent_status" ;;
            "unhealthy"|"unreachable") red "✗ $agent_status" ;;
            *) yellow "? $agent_status" ;;
        esac
        
        # Show MCP status if applicable
        if [[ "$mcp_status" != "n/a" ]]; then
            echo -n " | MCP: "
            case $mcp_status in
                "healthy") green "$mcp_status" ;;
                "disconnected") yellow "$mcp_status" ;;
                *) red "$mcp_status" ;;
            esac
        fi
        echo
    done
    echo
    
    # Performance Metrics
    if [[ "$VERBOSE" == "true" ]]; then
        echo "Performance Metrics:"
        for key in "${!performance_metrics[@]}"; do
            printf "  %-30s: %s\n" "$key" "${performance_metrics[$key]}"
        done
        echo
    fi
    
    # Summary
    local healthy_count=0
    local total_count=0
    
    for status in "${health_results[@]}"; do
        case $status in
            "healthy") ((healthy_count++)) ;;
        esac
        ((total_count++))
    done
    
    echo "Summary: $healthy_count/$total_count components healthy"
    
    if [[ "$overall_status" != "healthy" ]]; then
        echo
        yellow "⚠ Issues detected. Check logs and individual component status above."
        echo "For detailed information, run with --verbose flag."
    fi
}

# Main execution
main() {
    # Create log directory
    mkdir -p "$(dirname "$HEALTH_LOG")"
    
    if [[ "$CONTINUOUS" == "true" ]]; then
        log "Starting continuous health monitoring (interval: ${CONTINUOUS_INTERVAL}s)"
        
        while true; do
            perform_health_check
            
            if [[ "$JSON_OUTPUT" == "true" ]]; then
                output_json
            else
                output_human
                echo
                echo "Next check in ${CONTINUOUS_INTERVAL} seconds..."
                echo "Press Ctrl+C to stop continuous monitoring"
            fi
            
            sleep "$CONTINUOUS_INTERVAL"
        done
    else
        perform_health_check
        
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            output_json
        else
            output_human
        fi
        
        # Exit with appropriate code
        case $overall_status in
            "healthy") exit 0 ;;
            "degraded") exit 1 ;;
            "unhealthy") exit 2 ;;
            *) exit 3 ;;
        esac
    fi
}

# Handle signals for continuous mode
if [[ "$CONTINUOUS" == "true" ]]; then
    trap 'echo; log "Health monitoring stopped"; exit 0' INT TERM
fi

# Run main function
main