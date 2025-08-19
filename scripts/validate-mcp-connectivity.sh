#!/bin/bash
#
# MCP Connectivity Validator for CLI-Trading System
#
# This script validates connectivity and authentication with all configured
# MCP (Model Context Protocol) servers and external integrations.
#
# Usage: ./scripts/validate-mcp-connectivity.sh [--verbose] [--fix-auth]
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MCP_LOG="/opt/cli-trading/logs/mcp-validation.log"
VERBOSE=false
FIX_AUTH=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose)
            VERBOSE=true
            shift
            ;;
        --fix-auth)
            FIX_AUTH=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--verbose] [--fix-auth]"
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
    if [[ "$VERBOSE" == "true" ]]; then
        echo "$message"
    fi
    echo "$message" >> "$MCP_LOG" 2>/dev/null || true
}

# Load environment variables
if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

# MCP validation results
declare -A mcp_results=()
overall_mcp_status="healthy"

# Validate Slack MCP Server
validate_slack_mcp() {
    log "Validating Slack MCP server connectivity..."
    
    # Check if Slack MCP is enabled
    if [[ -z "${SLACK_BOT_TOKEN:-}" ]] && [[ ! -f "$PROJECT_DIR/secrets/slack_bot_token" ]]; then
        mcp_results["slack_mcp"]="disabled"
        log "Slack MCP: Not configured (missing bot token)"
        return 0
    fi
    
    # Check if Slack MCP container is running
    if ! docker ps --format "{{.Names}}" | grep -q "cli-trading-slack-mcp"; then
        mcp_results["slack_mcp"]="container_missing"
        log "Slack MCP: Container not running"
        overall_mcp_status="degraded"
        return 1
    fi
    
    # Test Slack API connectivity
    local slack_token=""
    if [[ -f "$PROJECT_DIR/secrets/slack_bot_token" ]]; then
        slack_token=$(cat "$PROJECT_DIR/secrets/slack_bot_token")
    elif [[ -n "${SLACK_BOT_TOKEN:-}" ]]; then
        slack_token="$SLACK_BOT_TOKEN"
    fi
    
    if [[ -n "$slack_token" ]]; then
        log "Testing Slack API connectivity..."
        
        local response
        if response=$(curl -s -H "Authorization: Bearer $slack_token" \
                         "https://slack.com/api/auth.test" 2>/dev/null); then
            
            if echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
                local team_name
                team_name=$(echo "$response" | jq -r '.team // "unknown"')
                mcp_results["slack_mcp"]="healthy"
                log "Slack MCP: Connected to workspace '$team_name'"
                
                # Test posting capability (test message)
                local test_response
                if test_response=$(curl -s -X POST \
                    -H "Authorization: Bearer $slack_token" \
                    -H "Content-Type: application/json" \
                    -d '{"channel":"#general","text":"Health check test (ignore)","dry_run":true}' \
                    "https://slack.com/api/chat.postMessage" 2>/dev/null); then
                    
                    if echo "$test_response" | jq -e '.ok == true or .error == "channel_not_found"' >/dev/null 2>&1; then
                        log "Slack MCP: Posting capability verified"
                    else
                        local error
                        error=$(echo "$test_response" | jq -r '.error // "unknown"')
                        log "Slack MCP: Posting test failed - $error"
                        mcp_results["slack_mcp"]="limited"
                        overall_mcp_status="degraded"
                    fi
                fi
                
                return 0
            else
                local error
                error=$(echo "$response" | jq -r '.error // "unknown"')
                mcp_results["slack_mcp"]="auth_failed"
                log "Slack MCP: Authentication failed - $error"
                overall_mcp_status="unhealthy"
                return 1
            fi
        else
            mcp_results["slack_mcp"]="api_unreachable"
            log "Slack MCP: Slack API unreachable"
            overall_mcp_status="unhealthy"
            return 1
        fi
    else
        mcp_results["slack_mcp"]="no_token"
        log "Slack MCP: No valid token found"
        overall_mcp_status="degraded"
        return 1
    fi
}

# Validate Jira integration
validate_jira_integration() {
    log "Validating Jira integration..."
    
    # Check if Jira is enabled
    if [[ "${ENABLE_JIRA:-false}" != "true" ]]; then
        mcp_results["jira"]="disabled"
        log "Jira: Integration disabled"
        return 0
    fi
    
    # Check required configuration
    if [[ -z "${JIRA_BASE_URL:-}" ]] || [[ -z "${JIRA_EMAIL:-}" ]]; then
        mcp_results["jira"]="misconfigured"
        log "Jira: Missing base URL or email configuration"
        overall_mcp_status="degraded"
        return 1
    fi
    
    # Get API token
    local jira_token=""
    if [[ -f "$PROJECT_DIR/secrets/jira_api_token" ]]; then
        jira_token=$(cat "$PROJECT_DIR/secrets/jira_api_token")
    fi
    
    if [[ -z "$jira_token" ]]; then
        mcp_results["jira"]="no_token"
        log "Jira: No API token found"
        overall_mcp_status="degraded"
        return 1
    fi
    
    # Test Jira API connectivity
    log "Testing Jira API connectivity to $JIRA_BASE_URL..."
    
    local auth_header
    auth_header=$(echo -n "$JIRA_EMAIL:$jira_token" | base64 -w 0)
    
    local response
    if response=$(curl -s -H "Authorization: Basic $auth_header" \
                     -H "Accept: application/json" \
                     "$JIRA_BASE_URL/rest/api/3/myself" 2>/dev/null); then
        
        if echo "$response" | jq -e '.accountId' >/dev/null 2>&1; then
            local display_name
            display_name=$(echo "$response" | jq -r '.displayName // "unknown"')
            mcp_results["jira"]="healthy"
            log "Jira: Connected as '$display_name'"
            
            # Test project access if project key is configured
            if [[ -n "${JIRA_PROJECT_KEY:-}" ]]; then
                log "Testing access to project $JIRA_PROJECT_KEY..."
                
                local project_response
                if project_response=$(curl -s -H "Authorization: Basic $auth_header" \
                                         -H "Accept: application/json" \
                                         "$JIRA_BASE_URL/rest/api/3/project/$JIRA_PROJECT_KEY" 2>/dev/null); then
                    
                    if echo "$project_response" | jq -e '.key' >/dev/null 2>&1; then
                        log "Jira: Project access verified"
                    else
                        log "Jira: Project access failed"
                        mcp_results["jira"]="limited"
                        overall_mcp_status="degraded"
                    fi
                fi
            fi
            
            return 0
        else
            mcp_results["jira"]="auth_failed"
            log "Jira: Authentication failed"
            overall_mcp_status="unhealthy"
            return 1
        fi
    else
        mcp_results["jira"]="api_unreachable"
        log "Jira: API unreachable at $JIRA_BASE_URL"
        overall_mcp_status="unhealthy"
        return 1
    fi
}

# Validate Notion integration
validate_notion_integration() {
    log "Validating Notion integration..."
    
    # Check if Notion is enabled
    if [[ "${ENABLE_NOTION:-false}" != "true" ]]; then
        mcp_results["notion"]="disabled"
        log "Notion: Integration disabled"
        return 0
    fi
    
    # Get API token
    local notion_token=""
    if [[ -f "$PROJECT_DIR/secrets/notion_api_token" ]]; then
        notion_token=$(cat "$PROJECT_DIR/secrets/notion_api_token")
    fi
    
    if [[ -z "$notion_token" ]]; then
        mcp_results["notion"]="no_token"
        log "Notion: No API token found"
        overall_mcp_status="degraded"
        return 1
    fi
    
    # Test Notion API connectivity
    log "Testing Notion API connectivity..."
    
    local response
    if response=$(curl -s -H "Authorization: Bearer $notion_token" \
                     -H "Content-Type: application/json" \
                     -H "Notion-Version: 2022-06-28" \
                     "https://api.notion.com/v1/users/me" 2>/dev/null); then
        
        if echo "$response" | jq -e '.id' >/dev/null 2>&1; then
            local user_name
            user_name=$(echo "$response" | jq -r '.name // "unknown"')
            mcp_results["notion"]="healthy"
            log "Notion: Connected as '$user_name'"
            
            # Test database access if database ID is configured
            if [[ -n "${NOTION_DATABASE_ID:-}" ]]; then
                log "Testing access to database $NOTION_DATABASE_ID..."
                
                local db_response
                if db_response=$(curl -s -H "Authorization: Bearer $notion_token" \
                                   -H "Content-Type: application/json" \
                                   -H "Notion-Version: 2022-06-28" \
                                   "https://api.notion.com/v1/databases/$NOTION_DATABASE_ID" 2>/dev/null); then
                    
                    if echo "$db_response" | jq -e '.id' >/dev/null 2>&1; then
                        local db_title
                        db_title=$(echo "$db_response" | jq -r '.title[0].plain_text // "unknown"')
                        log "Notion: Database access verified ('$db_title')"
                    else
                        log "Notion: Database access failed"
                        mcp_results["notion"]="limited"
                        overall_mcp_status="degraded"
                    fi
                fi
            fi
            
            return 0
        else
            mcp_results["notion"]="auth_failed"
            log "Notion: Authentication failed"
            overall_mcp_status="unhealthy"
            return 1
        fi
    else
        mcp_results["notion"]="api_unreachable"
        log "Notion: API unreachable"
        overall_mcp_status="unhealthy"
        return 1
    fi
}

# Validate agent MCP endpoints
validate_agent_mcp_endpoints() {
    log "Validating agent MCP endpoints..."
    
    # Check MCP Hub Controller
    if docker ps --format "{{.Names}}" | grep -q "cli-trading-mcp-hub-controller"; then
        local response
        if response=$(curl -s "http://localhost:7008/mcp/status" 2>/dev/null); then
            if echo "$response" | jq -e '.status' >/dev/null 2>&1; then
                local status
                status=$(echo "$response" | jq -r '.status')
                mcp_results["mcp_hub_controller"]="$status"
                log "MCP Hub Controller: Status $status"
                
                if [[ "$status" != "healthy" ]]; then
                    overall_mcp_status="degraded"
                fi
            else
                mcp_results["mcp_hub_controller"]="invalid_response"
                log "MCP Hub Controller: Invalid response format"
                overall_mcp_status="degraded"
            fi
        else
            mcp_results["mcp_hub_controller"]="unreachable"
            log "MCP Hub Controller: Endpoint unreachable"
            overall_mcp_status="degraded"
        fi
    else
        mcp_results["mcp_hub_controller"]="container_missing"
        log "MCP Hub Controller: Container not running"
        overall_mcp_status="degraded"
    fi
    
    # Check if other agents report MCP connectivity
    local agents=("orchestrator")
    for agent in "${agents[@]}"; do
        local port=""
        case $agent in
            "orchestrator") port="7001" ;;
        esac
        
        if [[ -n "$port" ]]; then
            local response
            if response=$(curl -s "http://localhost:$port/mcp/status" 2>/dev/null); then
                if echo "$response" | jq -e '.mcp_connections' >/dev/null 2>&1; then
                    local connections
                    connections=$(echo "$response" | jq -r '.mcp_connections | length')
                    mcp_results["${agent}_mcp_connections"]="$connections"
                    log "$agent: $connections MCP connections"
                fi
            fi
        fi
    done
}

# Attempt to fix authentication issues
fix_authentication_issues() {
    log "Attempting to fix authentication issues..."
    
    for service in "${!mcp_results[@]}"; do
        local status="${mcp_results[$service]}"
        
        case $status in
            "auth_failed"|"no_token")
                case $service in
                    "slack_mcp")
                        yellow "Slack MCP authentication issue detected."
                        echo "Please verify:"
                        echo "1. Slack bot token is valid and not expired"
                        echo "2. Bot has necessary permissions in workspace"
                        echo "3. secrets/slack_bot_token file exists and is readable"
                        ;;
                    "jira")
                        yellow "Jira authentication issue detected."
                        echo "Please verify:"
                        echo "1. Jira API token is valid"
                        echo "2. Email address matches token owner"
                        echo "3. User has access to configured project"
                        echo "4. secrets/jira_api_token file exists and is readable"
                        ;;
                    "notion")
                        yellow "Notion authentication issue detected."
                        echo "Please verify:"
                        echo "1. Notion API token is valid"
                        echo "2. Integration has access to workspace"
                        echo "3. Database permissions are correct"
                        echo "4. secrets/notion_api_token file exists and is readable"
                        ;;
                esac
                echo
                ;;
        esac
    done
}

# Generate MCP connectivity report
generate_report() {
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    bold "🔗 MCP Connectivity Validation Report"
    echo "Timestamp: $timestamp"
    echo "Overall MCP Status: $(if [[ "$overall_mcp_status" == "healthy" ]]; then green "$overall_mcp_status"; elif [[ "$overall_mcp_status" == "degraded" ]]; then yellow "$overall_mcp_status"; else red "$overall_mcp_status"; fi)"
    echo
    
    echo "Integration Status:"
    
    # Slack MCP
    printf "  %-20s: " "Slack MCP"
    case "${mcp_results[slack_mcp]:-unknown}" in
        "healthy") green "✓ Connected and functional" ;;
        "limited") yellow "⚠ Connected but limited functionality" ;;
        "auth_failed") red "✗ Authentication failed" ;;
        "api_unreachable") red "✗ API unreachable" ;;
        "no_token") yellow "⚠ No token configured" ;;
        "container_missing") red "✗ Container not running" ;;
        "disabled") blue "- Disabled" ;;
        *) yellow "? Unknown status" ;;
    esac
    
    # Jira
    printf "  %-20s: " "Jira Integration"
    case "${mcp_results[jira]:-unknown}" in
        "healthy") green "✓ Connected and functional" ;;
        "limited") yellow "⚠ Connected but limited access" ;;
        "auth_failed") red "✗ Authentication failed" ;;
        "api_unreachable") red "✗ API unreachable" ;;
        "no_token") yellow "⚠ No token configured" ;;
        "misconfigured") red "✗ Configuration incomplete" ;;
        "disabled") blue "- Disabled" ;;
        *) yellow "? Unknown status" ;;
    esac
    
    # Notion
    printf "  %-20s: " "Notion Integration"
    case "${mcp_results[notion]:-unknown}" in
        "healthy") green "✓ Connected and functional" ;;
        "limited") yellow "⚠ Connected but limited access" ;;
        "auth_failed") red "✗ Authentication failed" ;;
        "api_unreachable") red "✗ API unreachable" ;;
        "no_token") yellow "⚠ No token configured" ;;
        "disabled") blue "- Disabled" ;;
        *) yellow "? Unknown status" ;;
    esac
    
    # MCP Hub Controller
    printf "  %-20s: " "MCP Hub Controller"
    case "${mcp_results[mcp_hub_controller]:-unknown}" in
        "healthy") green "✓ Running and healthy" ;;
        "degraded") yellow "⚠ Running but degraded" ;;
        "unreachable") red "✗ Endpoint unreachable" ;;
        "container_missing") red "✗ Container not running" ;;
        "invalid_response") yellow "⚠ Invalid response format" ;;
        *) yellow "? Unknown status" ;;
    esac
    
    echo
    
    # Show connection counts if available
    for key in "${!mcp_results[@]}"; do
        if [[ "$key" == *"_mcp_connections" ]]; then
            local agent="${key%_mcp_connections}"
            local count="${mcp_results[$key]}"
            echo "  $agent: $count active MCP connections"
        fi
    done
    
    # Summary and recommendations
    echo
    local healthy_count=0
    local total_count=0
    
    for status in "${mcp_results[@]}"; do
        case $status in
            "healthy") ((healthy_count++)) ;;
            "disabled") ;; # Don't count disabled services
            *) ((total_count++)) ;;
        esac
        case $status in
            "disabled") ;; # Don't count disabled services in total
            *) ((total_count++)) ;;
        esac
    done
    
    echo "Summary: $healthy_count/$total_count MCP integrations healthy"
    
    if [[ "$overall_mcp_status" != "healthy" ]]; then
        echo
        yellow "⚠ MCP connectivity issues detected."
        if [[ "$FIX_AUTH" == "true" ]]; then
            fix_authentication_issues
        else
            echo "Run with --fix-auth for troubleshooting assistance."
        fi
    else
        echo
        green "✓ All enabled MCP integrations are healthy"
    fi
}

# Main execution
main() {
    # Create log directory
    mkdir -p "$(dirname "$MCP_LOG")"
    
    log "Starting MCP connectivity validation"
    
    # Validate all MCP integrations
    validate_slack_mcp
    validate_jira_integration
    validate_notion_integration
    validate_agent_mcp_endpoints
    
    # Generate report
    generate_report
    
    # Exit with appropriate code
    case $overall_mcp_status in
        "healthy") exit 0 ;;
        "degraded") exit 1 ;;
        "unhealthy") exit 2 ;;
        *) exit 3 ;;
    esac
}

# Run main function
main