#!/bin/bash
#
# Operations Dashboard Script for CLI-Trading System
#
# This script provides a comprehensive command-line dashboard for monitoring
# and managing the CLI-Trading system operations.
#
# Usage: ./scripts/ops-dashboard.sh [--watch] [--json] [--summary]
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WATCH_MODE=false
JSON_OUTPUT=false
SUMMARY_ONLY=false
REFRESH_INTERVAL=5

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --watch)
            WATCH_MODE=true
            shift
            ;;
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --summary)
            SUMMARY_ONLY=true
            shift
            ;;
        --interval)
            REFRESH_INTERVAL="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--watch] [--json] [--summary] [--interval SECONDS]"
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
    dim() { echo -e "\033[2m$1\033[0m"; }
    clear_screen() { clear; }
else
    red() { echo "$1"; }
    green() { echo "$1"; }
    yellow() { echo "$1"; }
    blue() { echo "$1"; }
    bold() { echo "$1"; }
    dim() { echo "$1"; }
    clear_screen() { :; }
fi

# Load environment variables
if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

# Admin token for API calls
ADMIN_TOKEN=${ADMIN_TOKEN:-$(cat "$PROJECT_DIR/secrets/admin_token" 2>/dev/null || echo "")}

# Dashboard data structure
declare -A dashboard_data=()
dashboard_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# API helper function
call_api() {
    local url=$1
    local method=${2:-GET}
    local data=${3:-""}
    
    local curl_args=("-s" "-w" "%{http_code}")
    
    if [[ -n "$ADMIN_TOKEN" ]]; then
        curl_args+=("-H" "X-Admin-Token: $ADMIN_TOKEN")
    fi
    
    if [[ "$method" != "GET" ]]; then
        curl_args+=("-X" "$method")
    fi
    
    if [[ -n "$data" ]]; then
        curl_args+=("-H" "Content-Type: application/json" "-d" "$data")
    fi
    
    curl_args+=("$url")
    
    curl "${curl_args[@]}" 2>/dev/null
}

# Collect system overview data
collect_system_overview() {
    dashboard_data["system_load"]=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    dashboard_data["system_memory"]=$(free | awk 'NR==2{printf "%.1f%%", $3*100/$2}')
    dashboard_data["system_disk"]=$(df -h /opt/cli-trading | awk 'NR==2{print $5}' | sed 's/%//')
    dashboard_data["system_uptime"]=$(uptime -p)
}

# Collect trading system status
collect_trading_status() {
    local pnl_response=$(call_api "http://localhost:7001/pnl/status")
    local status_code="${pnl_response: -3}"
    pnl_response="${pnl_response%???}"
    
    if [[ "$status_code" == "200" ]] && command -v jq >/dev/null 2>&1; then
        dashboard_data["trading_halted"]=$(echo "$pnl_response" | jq -r '.isHalted // false')
        dashboard_data["daily_pnl_usd"]=$(echo "$pnl_response" | jq -r '.dailyPnl // 0')
        dashboard_data["daily_pnl_pct"]=$(echo "$pnl_response" | jq -r '.dailyPnlPct // 0')
        dashboard_data["target_reached"]=$(echo "$pnl_response" | jq -r '.targetReached // false')
        dashboard_data["halt_reason"]=$(echo "$pnl_response" | jq -r '.haltReason // "none"')
    else
        dashboard_data["trading_halted"]="unknown"
        dashboard_data["daily_pnl_usd"]="unknown"
        dashboard_data["daily_pnl_pct"]="unknown"
        dashboard_data["target_reached"]="unknown"
        dashboard_data["halt_reason"]="unknown"
    fi
}

# Collect agent health status
collect_agent_health() {
    local agents=("orchestrator:7001" "portfolio-manager:7002" "market-analyst:7003" "risk-manager:7004" "trade-executor:7005" "notification-manager:7006" "parameter-optimizer:7007" "mcp-hub-controller:7008")
    
    for agent_port in "${agents[@]}"; do
        local agent=${agent_port%:*}
        local port=${agent_port#*:}
        
        local health_response=$(call_api "http://localhost:$port/health")
        local status_code="${health_response: -3}"
        health_response="${health_response%???}"
        
        if [[ "$status_code" == "200" ]] && command -v jq >/dev/null 2>&1; then
            local health_status=$(echo "$health_response" | jq -r '.status // "unknown"')
            local uptime=$(echo "$health_response" | jq -r '.uptime // "unknown"')
            dashboard_data["agent_${agent}_status"]="$health_status"
            dashboard_data["agent_${agent}_uptime"]="$uptime"
        else
            dashboard_data["agent_${agent}_status"]="down"
            dashboard_data["agent_${agent}_uptime"]="unknown"
        fi
    done
}

# Collect container status
collect_container_status() {
    local containers=$(docker ps --format "{{.Names}}\t{{.Status}}\t{{.RunningFor}}" | grep "cli-trading" || true)
    
    dashboard_data["total_containers"]=$(echo "$containers" | wc -l)
    dashboard_data["running_containers"]=$(echo "$containers" | grep -c "Up" || echo "0")
    
    # Collect individual container status
    while IFS=$'\t' read -r name status running_for; do
        if [[ -n "$name" ]]; then
            local short_name=$(echo "$name" | sed 's/cli-trading-//' | sed 's/-1$//')
            if [[ "$status" == Up* ]]; then
                dashboard_data["container_${short_name}_status"]="running"
                dashboard_data["container_${short_name}_uptime"]="$running_for"
            else
                dashboard_data["container_${short_name}_status"]="stopped"
                dashboard_data["container_${short_name}_uptime"]="0"
            fi
        fi
    done <<< "$containers"
}

# Collect infrastructure status
collect_infrastructure_status() {
    # Redis status
    if docker exec cli-trading-redis-1 redis-cli ping >/dev/null 2>&1; then
        dashboard_data["redis_status"]="healthy"
        dashboard_data["redis_memory"]=$(docker exec cli-trading-redis-1 redis-cli info memory | grep "used_memory_human:" | cut -d: -f2 | tr -d '\r')
        dashboard_data["redis_clients"]=$(docker exec cli-trading-redis-1 redis-cli info clients | grep "connected_clients:" | cut -d: -f2 | tr -d '\r')
    else
        dashboard_data["redis_status"]="down"
        dashboard_data["redis_memory"]="unknown"
        dashboard_data["redis_clients"]="unknown"
    fi
    
    # PostgreSQL status
    if docker exec cli-trading-postgres-1 pg_isready -U trader >/dev/null 2>&1; then
        dashboard_data["postgres_status"]="healthy"
        dashboard_data["postgres_connections"]=$(docker exec cli-trading-postgres-1 psql -U trader -d trading -t -c "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | xargs || echo "unknown")
        dashboard_data["postgres_size"]=$(docker exec cli-trading-postgres-1 psql -U trader -d trading -t -c "SELECT pg_size_pretty(pg_database_size('trading'));" 2>/dev/null | xargs || echo "unknown")
    else
        dashboard_data["postgres_status"]="down"
        dashboard_data["postgres_connections"]="unknown"
        dashboard_data["postgres_size"]="unknown"
    fi
    
    # Monitoring status
    if curl -sf http://localhost:9090/-/healthy >/dev/null 2>&1; then
        dashboard_data["prometheus_status"]="healthy"
    else
        dashboard_data["prometheus_status"]="down"
    fi
    
    if curl -sf http://localhost:3000/api/health >/dev/null 2>&1; then
        dashboard_data["grafana_status"]="healthy"
    else
        dashboard_data["grafana_status"]="down"
    fi
}

# Collect stream status
collect_stream_status() {
    local streams=("orchestrator.commands" "analysis.signals" "risk.requests" "risk.responses" "exec.orders" "exec.status" "notify.events")
    
    for stream in "${streams[@]}"; do
        local pending_response=$(call_api "http://localhost:7001/admin/streams/pending?stream=$stream&group=${stream%.*}")
        local status_code="${pending_response: -3}"
        pending_response="${pending_response%???}"
        
        if [[ "$status_code" == "200" ]] && command -v jq >/dev/null 2>&1; then
            local pending_count=$(echo "$pending_response" | jq -r '.pending // 0')
            dashboard_data["stream_${stream//\./_}_pending"]="$pending_count"
        else
            dashboard_data["stream_${stream//\./_}_pending"]="unknown"
        fi
        
        # Check DLQ
        local dlq_response=$(call_api "http://localhost:7001/admin/streams/dlq?stream=${stream}.dlq")
        local dlq_status_code="${dlq_response: -3}"
        dlq_response="${dlq_response%???}"
        
        if [[ "$dlq_status_code" == "200" ]] && command -v jq >/dev/null 2>&1; then
            local dlq_count=$(echo "$dlq_response" | jq -r '.entries | length')
            dashboard_data["stream_${stream//\./_}_dlq"]="$dlq_count"
        else
            dashboard_data["stream_${stream//\./_}_dlq"]="unknown"
        fi
    done
}

# Collect alert status
collect_alert_status() {
    if curl -sf http://localhost:9093/api/v1/alerts >/dev/null 2>&1; then
        local alerts_response=$(curl -s http://localhost:9093/api/v1/alerts)
        if command -v jq >/dev/null 2>&1; then
            dashboard_data["alerts_firing"]=$(echo "$alerts_response" | jq '[.data[] | select(.status.state == "active")] | length')
            dashboard_data["alerts_critical"]=$(echo "$alerts_response" | jq '[.data[] | select(.status.state == "active" and .labels.severity == "critical")] | length')
            dashboard_data["alerts_warning"]=$(echo "$alerts_response" | jq '[.data[] | select(.status.state == "active" and .labels.severity == "warning")] | length')
        else
            dashboard_data["alerts_firing"]="unknown"
            dashboard_data["alerts_critical"]="unknown"
            dashboard_data["alerts_warning"]="unknown"
        fi
    else
        dashboard_data["alerts_firing"]="unknown"
        dashboard_data["alerts_critical"]="unknown"
        dashboard_data["alerts_warning"]="unknown"
    fi
}

# Collect all dashboard data
collect_dashboard_data() {
    dashboard_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    if [[ "$SUMMARY_ONLY" != "true" ]]; then
        collect_system_overview
        collect_agent_health
        collect_container_status
        collect_infrastructure_status
        collect_stream_status
        collect_alert_status
    fi
    
    collect_trading_status
}

# Display JSON output
display_json() {
    cat << EOF
{
  "timestamp": "$dashboard_timestamp",
  "data": {
EOF
    
    local first=true
    for key in "${!dashboard_data[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi
        echo "    \"$key\": \"${dashboard_data[$key]}\""
    done
    
    cat << EOF
  }
}
EOF
}

# Display formatted dashboard
display_dashboard() {
    clear_screen
    
    # Header
    bold "🎯 CLI-Trading Operations Dashboard"
    echo "Last Updated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Refresh Interval: ${REFRESH_INTERVAL}s"
    echo

    # Trading System Status
    bold "📈 Trading System"
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    
    local halt_status="${dashboard_data[trading_halted]}"
    if [[ "$halt_status" == "true" ]]; then
        printf "│ Status: %s                     │\n" "$(red "HALTED (${dashboard_data[halt_reason]})")"
    elif [[ "$halt_status" == "false" ]]; then
        printf "│ Status: %s                           │\n" "$(green "ACTIVE")"
    else
        printf "│ Status: %s                          │\n" "$(yellow "UNKNOWN")"
    fi
    
    local pnl_usd="${dashboard_data[daily_pnl_usd]}"
    local pnl_pct="${dashboard_data[daily_pnl_pct]}"
    if [[ "$pnl_usd" != "unknown" ]] && [[ "$pnl_pct" != "unknown" ]]; then
        if (( $(echo "$pnl_usd >= 0" | bc -l 2>/dev/null || echo "0") )); then
            printf "│ Daily PnL: %s                   │\n" "$(green "$pnl_usd USD ($pnl_pct%)")"
        else
            printf "│ Daily PnL: %s                   │\n" "$(red "$pnl_usd USD ($pnl_pct%)")"
        fi
    else
        printf "│ Daily PnL: %s                              │\n" "$(yellow "Unknown")"
    fi
    
    local target_reached="${dashboard_data[target_reached]}"
    if [[ "$target_reached" == "true" ]]; then
        printf "│ Target: %s                            │\n" "$(green "REACHED")"
    elif [[ "$target_reached" == "false" ]]; then
        printf "│ Target: %s                        │\n" "$(yellow "In Progress")"
    else
        printf "│ Target: %s                             │\n" "$(yellow "Unknown")"
    fi
    
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo

    if [[ "$SUMMARY_ONLY" == "true" ]]; then
        return 0
    fi

    # System Overview
    bold "🖥️  System Overview"
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    printf "│ Load: %-15s Memory: %-15s Disk: %-10s │\n" \
           "${dashboard_data[system_load]}" \
           "${dashboard_data[system_memory]}" \
           "${dashboard_data[system_disk]}%"
    printf "│ Uptime: %-57s │\n" "${dashboard_data[system_uptime]}"
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo

    # Agents Status
    bold "🤖 Trading Agents"
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    
    local agents=("orchestrator" "portfolio-manager" "market-analyst" "risk-manager" "trade-executor" "notification-manager" "parameter-optimizer" "mcp-hub-controller")
    
    for agent in "${agents[@]}"; do
        local status="${dashboard_data[agent_${agent}_status]}"
        local uptime="${dashboard_data[agent_${agent}_uptime]}"
        
        printf "│ %-20s: " "$agent"
        if [[ "$status" == "healthy" ]]; then
            printf "%s" "$(green "●")"
        elif [[ "$status" == "down" ]]; then
            printf "%s" "$(red "●")"
        else
            printf "%s" "$(yellow "●")"
        fi
        printf " %-8s %s" "$status" "$(dim "$uptime")"
        printf "%*s│\n" $((35 - ${#uptime})) ""
    done
    
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo

    # Infrastructure Status
    bold "🏗️  Infrastructure"
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    
    # Database row
    printf "│ Redis: "
    local redis_status="${dashboard_data[redis_status]}"
    if [[ "$redis_status" == "healthy" ]]; then
        printf "%s" "$(green "●")"
    else
        printf "%s" "$(red "●")"
    fi
    printf " %-8s Mem: %-10s Clients: %-6s │\n" \
           "$redis_status" \
           "${dashboard_data[redis_memory]}" \
           "${dashboard_data[redis_clients]}"
    
    printf "│ PostgreSQL: "
    local postgres_status="${dashboard_data[postgres_status]}"
    if [[ "$postgres_status" == "healthy" ]]; then
        printf "%s" "$(green "●")"
    else
        printf "%s" "$(red "●")"
    fi
    printf " %-8s Size: %-10s Conns: %-6s │\n" \
           "$postgres_status" \
           "${dashboard_data[postgres_size]}" \
           "${dashboard_data[postgres_connections]}"
    
    # Monitoring row
    printf "│ Prometheus: "
    local prom_status="${dashboard_data[prometheus_status]}"
    if [[ "$prom_status" == "healthy" ]]; then
        printf "%s" "$(green "●")"
    else
        printf "%s" "$(red "●")"
    fi
    printf " %-8s " "$prom_status"
    
    printf "Grafana: "
    local grafana_status="${dashboard_data[grafana_status]}"
    if [[ "$grafana_status" == "healthy" ]]; then
        printf "%s" "$(green "●")"
    else
        printf "%s" "$(red "●")"
    fi
    printf " %-8s │\n" "$grafana_status"
    
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo

    # Stream Status
    bold "🌊 Message Streams"
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    
    local stream_names=("orchestrator.commands" "analysis.signals" "risk.requests" "risk.responses" "exec.orders" "exec.status" "notify.events")
    
    for stream in "${stream_names[@]}"; do
        local pending="${dashboard_data[stream_${stream//\./_}_pending]}"
        local dlq="${dashboard_data[stream_${stream//\./_}_dlq]}"
        
        printf "│ %-20s: Pending: " "${stream##*.}"
        
        if [[ "$pending" != "unknown" ]] && [[ "$pending" -gt 100 ]]; then
            printf "%s" "$(red "$pending")"
        elif [[ "$pending" != "unknown" ]] && [[ "$pending" -gt 10 ]]; then
            printf "%s" "$(yellow "$pending")"
        else
            printf "%s" "$(green "$pending")"
        fi
        
        printf " DLQ: "
        if [[ "$dlq" != "unknown" ]] && [[ "$dlq" -gt 0 ]]; then
            printf "%s" "$(red "$dlq")"
        else
            printf "%s" "$(green "$dlq")"
        fi
        printf "%*s│\n" $((25 - ${#pending} - ${#dlq})) ""
    done
    
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo

    # Alerts Status
    bold "🚨 Alerts"
    echo "┌─────────────────────────────────────────────────────────────────────┐"
    
    local firing="${dashboard_data[alerts_firing]}"
    local critical="${dashboard_data[alerts_critical]}"
    local warning="${dashboard_data[alerts_warning]}"
    
    printf "│ Total Firing: "
    if [[ "$firing" != "unknown" ]] && [[ "$firing" -gt 0 ]]; then
        printf "%s" "$(red "$firing")"
    else
        printf "%s" "$(green "$firing")"
    fi
    
    printf " Critical: "
    if [[ "$critical" != "unknown" ]] && [[ "$critical" -gt 0 ]]; then
        printf "%s" "$(red "$critical")"
    else
        printf "%s" "$(green "$critical")"
    fi
    
    printf " Warning: "
    if [[ "$warning" != "unknown" ]] && [[ "$warning" -gt 0 ]]; then
        printf "%s" "$(yellow "$warning")"
    else
        printf "%s" "$(green "$warning")"
    fi
    printf "%*s│\n" $((25 - ${#firing} - ${#critical} - ${#warning})) ""
    
    echo "└─────────────────────────────────────────────────────────────────────┘"
    echo

    # Footer
    if [[ "$WATCH_MODE" == "true" ]]; then
        dim "Press Ctrl+C to exit watch mode"
    else
        dim "Use --watch for continuous monitoring"
    fi
}

# Main execution function
main() {
    if [[ "$WATCH_MODE" == "true" ]]; then
        # Watch mode - continuous updates
        while true; do
            collect_dashboard_data
            
            if [[ "$JSON_OUTPUT" == "true" ]]; then
                display_json
            else
                display_dashboard
            fi
            
            sleep "$REFRESH_INTERVAL"
        done
    else
        # Single execution
        collect_dashboard_data
        
        if [[ "$JSON_OUTPUT" == "true" ]]; then
            display_json
        else
            display_dashboard
        fi
    fi
}

# Handle script interruption
trap 'echo; exit 0' INT TERM

# Check dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "Warning: jq not found. JSON parsing will be limited."
fi

if ! command -v bc >/dev/null 2>&1; then
    echo "Warning: bc not found. Numeric comparisons will be limited."
fi

# Run main function
main