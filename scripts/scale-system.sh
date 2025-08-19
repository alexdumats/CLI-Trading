#!/bin/bash
#
# System Scaling Management Script for CLI-Trading
#
# This script manages horizontal and vertical scaling of the trading system
# components based on performance metrics and load patterns.
#
# Usage: ./scripts/scale-system.sh [command] [options]
#
# Commands:
#   status      - Show current scaling status
#   scale-up    - Scale up services
#   scale-down  - Scale down services
#   auto        - Enable auto-scaling
#   analyze     - Analyze scaling requirements
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCALING_LOG="/opt/cli-trading/logs/scaling.log"
METRICS_HISTORY="/opt/cli-trading/data/scaling-metrics.json"

# Default values
COMMAND=""
SERVICE=""
REPLICAS=""
AUTO_SCALING=false
DRY_RUN=false

# Parse command line arguments
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 [command] [options]"
    echo "Commands: status, scale-up, scale-down, auto, analyze"
    exit 1
fi

COMMAND=$1
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --service)
            SERVICE="$2"
            shift 2
            ;;
        --replicas)
            REPLICAS="$2"
            shift 2
            ;;
        --auto)
            AUTO_SCALING=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
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
    echo "$message" >> "$SCALING_LOG" 2>/dev/null || true
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

# Service scaling configurations
declare -A service_config=(
    # Service: min_replicas:max_replicas:scalable
    ["orchestrator"]="1:1:false"           # Critical, single instance
    ["portfolio-manager"]="1:3:true"       # Can scale
    ["market-analyst"]="1:3:true"          # Can scale  
    ["risk-manager"]="1:2:true"            # Limited scaling
    ["trade-executor"]="1:2:true"          # Limited scaling
    ["notification-manager"]="1:5:true"    # Highly scalable
    ["parameter-optimizer"]="1:2:true"     # Limited scaling
    ["mcp-hub-controller"]="1:2:true"      # Limited scaling
)

# Get current service scaling status
get_service_status() {
    local service=$1
    
    # Get current replica count
    local current_replicas=$(docker-compose ps -q "$service" 2>/dev/null | wc -l)
    
    # Get service configuration
    local config="${service_config[$service]:-1:1:false}"
    local min_replicas=$(echo "$config" | cut -d: -f1)
    local max_replicas=$(echo "$config" | cut -d: -f2)
    local scalable=$(echo "$config" | cut -d: -f3)
    
    echo "$current_replicas:$min_replicas:$max_replicas:$scalable"
}

# Get service resource usage
get_service_metrics() {
    local service=$1
    
    # Get container metrics
    local containers=$(docker ps --format "{{.Names}}" | grep "cli-trading-$service" || true)
    
    if [[ -z "$containers" ]]; then
        echo "0:0:0:0"
        return
    fi
    
    local total_cpu=0
    local total_memory=0
    local container_count=0
    
    while IFS= read -r container; do
        if [[ -n "$container" ]]; then
            local stats=$(docker stats --no-stream --format "{{.CPUPerc}} {{.MemPerc}}" "$container" 2>/dev/null || echo "0.00% 0.00%")
            local cpu_pct=$(echo "$stats" | awk '{print $1}' | sed 's/%//')
            local mem_pct=$(echo "$stats" | awk '{print $2}' | sed 's/%//')
            
            total_cpu=$(echo "$total_cpu + $cpu_pct" | bc -l 2>/dev/null || echo "$total_cpu")
            total_memory=$(echo "$total_memory + $mem_pct" | bc -l 2>/dev/null || echo "$total_memory")
            ((container_count++))
        fi
    done <<< "$containers"
    
    if [[ $container_count -gt 0 ]]; then
        local avg_cpu=$(echo "scale=2; $total_cpu / $container_count" | bc -l 2>/dev/null || echo "0")
        local avg_memory=$(echo "scale=2; $total_memory / $container_count" | bc -l 2>/dev/null || echo "0")
        echo "$avg_cpu:$avg_memory:$total_cpu:$total_memory"
    else
        echo "0:0:0:0"
    fi
}

# Get system-wide metrics
get_system_metrics() {
    # System CPU and memory
    local system_cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | sed 's/%us,//')
    local system_memory=$(free | awk 'NR==2{printf "%.1f", $3*100/$2}')
    
    # Load average
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    
    # Container count
    local total_containers=$(docker ps | grep cli-trading | wc -l)
    
    echo "$system_cpu:$system_memory:$load_avg:$total_containers"
}

# Store metrics history
store_metrics() {
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local system_metrics=$(get_system_metrics)
    
    mkdir -p "$(dirname "$METRICS_HISTORY")"
    
    # Create metrics entry
    local metrics_entry=$(cat << EOF
{
  "timestamp": "$timestamp",
  "system": {
    "cpu_percent": "$(echo "$system_metrics" | cut -d: -f1)",
    "memory_percent": "$(echo "$system_metrics" | cut -d: -f2)", 
    "load_average": "$(echo "$system_metrics" | cut -d: -f3)",
    "total_containers": "$(echo "$system_metrics" | cut -d: -f4)"
  },
  "services": {
EOF
    )
    
    local first_service=true
    for service in "${!service_config[@]}"; do
        local service_metrics=$(get_service_metrics "$service")
        local service_status=$(get_service_status "$service")
        
        if [[ "$first_service" == "true" ]]; then
            first_service=false
        else
            metrics_entry+=","
        fi
        
        metrics_entry+=$(cat << EOF

    "$service": {
      "avg_cpu": "$(echo "$service_metrics" | cut -d: -f1)",
      "avg_memory": "$(echo "$service_metrics" | cut -d: -f2)",
      "total_cpu": "$(echo "$service_metrics" | cut -d: -f3)",
      "total_memory": "$(echo "$service_metrics" | cut -d: -f4)",
      "current_replicas": "$(echo "$service_status" | cut -d: -f1)"
    }
EOF
        )
    done
    
    metrics_entry+=$(cat << EOF

  }
}
EOF
    )
    
    # Append to history file (keep last 100 entries)
    if [[ -f "$METRICS_HISTORY" ]]; then
        # Read existing data and add new entry
        local existing_data=$(cat "$METRICS_HISTORY" 2>/dev/null || echo "[]")
        echo "$existing_data" | jq ". + [$metrics_entry] | .[-100:]" > "$METRICS_HISTORY.tmp"
        mv "$METRICS_HISTORY.tmp" "$METRICS_HISTORY"
    else
        echo "[$metrics_entry]" > "$METRICS_HISTORY"
    fi
}

# Show current scaling status
show_status() {
    bold "📊 Current Scaling Status"
    echo
    
    # System overview
    local system_metrics=$(get_system_metrics)
    echo "System Overview:"
    echo "  CPU Usage: $(echo "$system_metrics" | cut -d: -f1)%"
    echo "  Memory Usage: $(echo "$system_metrics" | cut -d: -f2)%"
    echo "  Load Average: $(echo "$system_metrics" | cut -d: -f3)"
    echo "  Total Containers: $(echo "$system_metrics" | cut -d: -f4)"
    echo
    
    # Service details
    echo "Service Scaling Status:"
    printf "%-20s %-10s %-15s %-10s %-10s %-10s\n" "Service" "Replicas" "Range" "Scalable" "CPU%" "Memory%"
    printf "%-20s %-10s %-15s %-10s %-10s %-10s\n" "--------" "--------" "-----" "--------" "----" "-------"
    
    for service in "${!service_config[@]}"; do
        local status=$(get_service_status "$service")
        local metrics=$(get_service_metrics "$service")
        
        local current=$(echo "$status" | cut -d: -f1)
        local min=$(echo "$status" | cut -d: -f2)
        local max=$(echo "$status" | cut -d: -f3)
        local scalable=$(echo "$status" | cut -d: -f4)
        local cpu=$(echo "$metrics" | cut -d: -f1)
        local memory=$(echo "$metrics" | cut -d: -f2)
        
        printf "%-20s %-10s %-15s %-10s %-10s %-10s\n" \
               "$service" \
               "$current" \
               "$min-$max" \
               "$scalable" \
               "${cpu}%" \
               "${memory}%"
    done
    
    echo
    
    # Scaling recommendations
    echo "Scaling Recommendations:"
    analyze_scaling_needs
}

# Analyze scaling needs
analyze_scaling_needs() {
    local recommendations=()
    
    for service in "${!service_config[@]}"; do
        local status=$(get_service_status "$service")
        local metrics=$(get_service_metrics "$service")
        
        local current=$(echo "$status" | cut -d: -f1)
        local min=$(echo "$status" | cut -d: -f2)
        local max=$(echo "$status" | cut -d: -f3)
        local scalable=$(echo "$status" | cut -d: -f4)
        local cpu=$(echo "$metrics" | cut -d: -f1)
        local memory=$(echo "$metrics" | cut -d: -f2)
        
        if [[ "$scalable" == "true" ]] && [[ "$current" -gt 0 ]]; then
            # Scale up conditions
            if (( $(echo "$cpu > 80" | bc -l 2>/dev/null || echo "0") )) || (( $(echo "$memory > 80" | bc -l 2>/dev/null || echo "0") )); then
                if [[ $current -lt $max ]]; then
                    recommendations+=("SCALE UP: $service (CPU: ${cpu}%, Memory: ${memory}%) - suggest $((current + 1)) replicas")
                else
                    recommendations+=("AT LIMIT: $service (CPU: ${cpu}%, Memory: ${memory}%) - at maximum replicas")
                fi
            # Scale down conditions
            elif (( $(echo "$cpu < 20" | bc -l 2>/dev/null || echo "0") )) && (( $(echo "$memory < 30" | bc -l 2>/dev/null || echo "0") )); then
                if [[ $current -gt $min ]]; then
                    recommendations+=("SCALE DOWN: $service (CPU: ${cpu}%, Memory: ${memory}%) - suggest $((current - 1)) replicas")
                fi
            else
                recommendations+=("OPTIMAL: $service (CPU: ${cpu}%, Memory: ${memory}%)")
            fi
        elif [[ "$current" -eq 0 ]]; then
            recommendations+=("DOWN: $service - service not running")
        else
            recommendations+=("FIXED: $service - not scalable")
        fi
    done
    
    if [[ ${#recommendations[@]} -eq 0 ]]; then
        green "  No scaling recommendations at this time"
    else
        for rec in "${recommendations[@]}"; do
            if [[ "$rec" == SCALE\ UP:* ]]; then
                yellow "  $rec"
            elif [[ "$rec" == SCALE\ DOWN:* ]]; then
                blue "  $rec"
            elif [[ "$rec" == DOWN:* ]]; then
                red "  $rec"
            elif [[ "$rec" == AT\ LIMIT:* ]]; then
                red "  $rec"
            else
                green "  $rec"
            fi
        done
    fi
}

# Scale service up
scale_up() {
    local service=${SERVICE:-""}
    local target_replicas=${REPLICAS:-""}
    
    if [[ -z "$service" ]]; then
        error_exit "Service name required for scale-up (use --service)"
    fi
    
    # Validate service
    if [[ -z "${service_config[$service]:-}" ]]; then
        error_exit "Unknown service: $service"
    fi
    
    local status=$(get_service_status "$service")
    local current=$(echo "$status" | cut -d: -f1)
    local min=$(echo "$status" | cut -d: -f2)
    local max=$(echo "$status" | cut -d: -f3)
    local scalable=$(echo "$status" | cut -d: -f4)
    
    if [[ "$scalable" != "true" ]]; then
        error_exit "Service $service is not scalable"
    fi
    
    if [[ -z "$target_replicas" ]]; then
        target_replicas=$((current + 1))
    fi
    
    if [[ $target_replicas -gt $max ]]; then
        error_exit "Target replicas ($target_replicas) exceeds maximum ($max) for service $service"
    fi
    
    if [[ $target_replicas -le $current ]]; then
        error_exit "Target replicas ($target_replicas) must be greater than current ($current)"
    fi
    
    log "Scaling up $service from $current to $target_replicas replicas"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        yellow "DRY RUN: Would scale $service to $target_replicas replicas"
        return 0
    fi
    
    # Perform scaling
    if docker-compose up -d --scale "$service=$target_replicas"; then
        green "✅ Successfully scaled $service to $target_replicas replicas"
        
        # Wait for new instances to be healthy
        sleep 30
        
        # Verify scaling
        local new_count=$(docker-compose ps -q "$service" | wc -l)
        if [[ $new_count -eq $target_replicas ]]; then
            log "Scaling verification successful: $service now has $new_count replicas"
        else
            yellow "⚠️ Scaling verification warning: Expected $target_replicas, got $new_count replicas"
        fi
    else
        error_exit "Failed to scale $service"
    fi
}

# Scale service down
scale_down() {
    local service=${SERVICE:-""}
    local target_replicas=${REPLICAS:-""}
    
    if [[ -z "$service" ]]; then
        error_exit "Service name required for scale-down (use --service)"
    fi
    
    # Validate service
    if [[ -z "${service_config[$service]:-}" ]]; then
        error_exit "Unknown service: $service"
    fi
    
    local status=$(get_service_status "$service")
    local current=$(echo "$status" | cut -d: -f1)
    local min=$(echo "$status" | cut -d: -f2)
    local max=$(echo "$status" | cut -d: -f3)
    local scalable=$(echo "$status" | cut -d: -f4)
    
    if [[ "$scalable" != "true" ]]; then
        error_exit "Service $service is not scalable"
    fi
    
    if [[ -z "$target_replicas" ]]; then
        target_replicas=$((current - 1))
    fi
    
    if [[ $target_replicas -lt $min ]]; then
        error_exit "Target replicas ($target_replicas) below minimum ($min) for service $service"
    fi
    
    if [[ $target_replicas -ge $current ]]; then
        error_exit "Target replicas ($target_replicas) must be less than current ($current)"
    fi
    
    log "Scaling down $service from $current to $target_replicas replicas"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        yellow "DRY RUN: Would scale $service to $target_replicas replicas"
        return 0
    fi
    
    # Perform scaling
    if docker-compose up -d --scale "$service=$target_replicas"; then
        green "✅ Successfully scaled $service to $target_replicas replicas"
        
        # Verify scaling
        sleep 10
        local new_count=$(docker-compose ps -q "$service" | wc -l)
        if [[ $new_count -eq $target_replicas ]]; then
            log "Scaling verification successful: $service now has $new_count replicas"
        else
            yellow "⚠️ Scaling verification warning: Expected $target_replicas, got $new_count replicas"
        fi
    else
        error_exit "Failed to scale $service"
    fi
}

# Auto-scaling implementation
auto_scale() {
    log "Running auto-scaling analysis..."
    
    # Store current metrics
    store_metrics
    
    # Auto-scale based on metrics
    for service in "${!service_config[@]}"; do
        local status=$(get_service_status "$service")
        local metrics=$(get_service_metrics "$service")
        
        local current=$(echo "$status" | cut -d: -f1)
        local min=$(echo "$status" | cut -d: -f2)
        local max=$(echo "$status" | cut -d: -f3)
        local scalable=$(echo "$status" | cut -d: -f4)
        local cpu=$(echo "$metrics" | cut -d: -f1)
        local memory=$(echo "$metrics" | cut -d: -f2)
        
        if [[ "$scalable" == "true" ]] && [[ "$current" -gt 0 ]]; then
            # Scale up conditions
            if (( $(echo "$cpu > 80" | bc -l 2>/dev/null || echo "0") )) || (( $(echo "$memory > 85" | bc -l 2>/dev/null || echo "0") )); then
                if [[ $current -lt $max ]]; then
                    log "Auto-scaling up $service due to high resource usage (CPU: ${cpu}%, Memory: ${memory}%)"
                    
                    if [[ "$DRY_RUN" == "true" ]]; then
                        yellow "DRY RUN: Would auto-scale $service from $current to $((current + 1)) replicas"
                    else
                        SERVICE="$service"
                        REPLICAS="$((current + 1))"
                        scale_up
                    fi
                fi
            # Scale down conditions (more conservative)
            elif (( $(echo "$cpu < 15" | bc -l 2>/dev/null || echo "0") )) && (( $(echo "$memory < 25" | bc -l 2>/dev/null || echo "0") )); then
                if [[ $current -gt $min ]]; then
                    # Additional check: look at historical data to avoid thrashing
                    local should_scale_down=true
                    
                    # Check if metrics have been consistently low
                    if [[ -f "$METRICS_HISTORY" ]]; then
                        local recent_high_usage=$(jq -r ".[].services.$service | select(.avg_cpu > 50 or .avg_memory > 50)" "$METRICS_HISTORY" 2>/dev/null | tail -3)
                        if [[ -n "$recent_high_usage" ]]; then
                            should_scale_down=false
                            log "Skipping scale-down for $service due to recent high usage"
                        fi
                    fi
                    
                    if [[ "$should_scale_down" == "true" ]]; then
                        log "Auto-scaling down $service due to low resource usage (CPU: ${cpu}%, Memory: ${memory}%)"
                        
                        if [[ "$DRY_RUN" == "true" ]]; then
                            yellow "DRY RUN: Would auto-scale $service from $current to $((current - 1)) replicas"
                        else
                            SERVICE="$service"
                            REPLICAS="$((current - 1))"
                            scale_down
                        fi
                    fi
                fi
            fi
        fi
    done
}

# Generate scaling report
generate_scaling_report() {
    local report_file="/opt/cli-trading/reports/scaling-report-$(date +%Y%m%d_%H%M%S).md"
    
    mkdir -p "$(dirname "$report_file")"
    
    cat > "$report_file" << EOF
# Scaling Analysis Report

Generated: $(date)

## Current System Status

$(show_status)

## Historical Metrics Analysis

EOF
    
    if [[ -f "$METRICS_HISTORY" ]]; then
        echo "### Resource Usage Trends (Last 24 Hours)" >> "$report_file"
        echo "" >> "$report_file"
        
        # Analyze historical data
        for service in "${!service_config[@]}"; do
            local avg_cpu=$(jq -r ".[].services.$service.avg_cpu" "$METRICS_HISTORY" 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print 0}')
            local avg_memory=$(jq -r ".[].services.$service.avg_memory" "$METRICS_HISTORY" 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print 0}')
            
            echo "- **$service**: Avg CPU ${avg_cpu}%, Avg Memory ${avg_memory}%" >> "$report_file"
        done
        
        echo "" >> "$report_file"
    fi
    
    cat >> "$report_file" << EOF

## Scaling Recommendations

EOF
    
    # Add detailed recommendations
    analyze_scaling_needs >> "$report_file"
    
    cat >> "$report_file" << EOF

## Capacity Planning

Based on current trends and usage patterns:

1. **Short-term** (next 7 days): Monitor current scaling levels
2. **Medium-term** (next 30 days): Consider infrastructure scaling if consistently high usage
3. **Long-term** (next 90 days): Evaluate architecture optimizations

## Actions Taken

- Report generated at $(date)
- Current metrics stored in $METRICS_HISTORY
- No automatic scaling actions taken (use --auto for auto-scaling)

EOF
    
    log "Scaling report generated: $report_file"
    echo "$report_file"
}

# Main execution
main() {
    # Create log directory
    mkdir -p "$(dirname "$SCALING_LOG")"
    
    case $COMMAND in
        "status")
            show_status
            ;;
        "scale-up")
            bold "📈 Scaling Up Service"
            scale_up
            ;;
        "scale-down")
            bold "📉 Scaling Down Service" 
            scale_down
            ;;
        "auto")
            bold "🤖 Auto-Scaling Analysis"
            auto_scale
            ;;
        "analyze")
            bold "📊 Scaling Analysis"
            local report_file=$(generate_scaling_report)
            echo "Report generated: $report_file"
            ;;
        *)
            error_exit "Unknown command: $COMMAND"
            ;;
    esac
}

# Run main function
main