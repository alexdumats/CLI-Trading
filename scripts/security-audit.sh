#!/bin/bash
#
# Comprehensive Security Audit Script for CLI-Trading System
#
# This script performs thorough security validation including:
# - Secrets management and permissions
# - Container security configuration
# - Network security analysis
# - Authentication and authorization checks
# - Compliance verification
#
# Usage: ./scripts/security-audit.sh [--fix] [--report] [--compliance]
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SECURITY_LOG="/opt/cli-trading/logs/security-audit.log"
REPORT_DIR="/opt/cli-trading/security"
FIX_ISSUES=false
GENERATE_REPORT=false
COMPLIANCE_CHECK=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --fix)
            FIX_ISSUES=true
            shift
            ;;
        --report)
            GENERATE_REPORT=true
            shift
            ;;
        --compliance)
            COMPLIANCE_CHECK=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--fix] [--report] [--compliance]"
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
    echo "$message" >> "$SECURITY_LOG" 2>/dev/null || true
}

# Security issue tracking
declare -A security_issues=()
declare -A security_scores=()
declare -A findings=()
overall_security_score=100
critical_issues=0
high_issues=0
medium_issues=0
low_issues=0

# Report security issue
report_issue() {
    local severity=$1
    local category=$2
    local issue=$3
    local fix_command=${4:-""}
    
    local key="${category}_${issue// /_}"
    security_issues["$key"]="$severity"
    findings["$key"]="$issue"
    
    case $severity in
        "CRITICAL")
            ((critical_issues++))
            overall_security_score=$((overall_security_score - 25))
            ;;
        "HIGH")
            ((high_issues++))
            overall_security_score=$((overall_security_score - 15))
            ;;
        "MEDIUM")
            ((medium_issues++))
            overall_security_score=$((overall_security_score - 8))
            ;;
        "LOW")
            ((low_issues++))
            overall_security_score=$((overall_security_score - 3))
            ;;
    esac
    
    # Auto-fix if requested and fix command provided
    if [[ "$FIX_ISSUES" == "true" && -n "$fix_command" ]]; then
        log "Auto-fixing: $issue"
        if eval "$fix_command" 2>/dev/null; then
            log "Fixed: $issue"
        else
            log "Failed to fix: $issue"
        fi
    fi
    
    log "[$severity] $category: $issue"
}

# Audit secrets management
audit_secrets() {
    log "Starting secrets management audit..."
    
    # Check if secrets directory exists
    if [[ ! -d "$PROJECT_DIR/secrets" ]]; then
        report_issue "CRITICAL" "SECRETS" "Secrets directory does not exist" \
            "mkdir -p '$PROJECT_DIR/secrets' && chmod 700 '$PROJECT_DIR/secrets'"
        return
    fi
    
    # Check secrets directory permissions
    local secrets_dir_perms=$(stat -c "%a" "$PROJECT_DIR/secrets")
    if [[ "$secrets_dir_perms" != "700" ]]; then
        report_issue "HIGH" "SECRETS" "Secrets directory has insecure permissions: $secrets_dir_perms" \
            "chmod 700 '$PROJECT_DIR/secrets'"
    fi
    
    # Check individual secret files
    local required_secrets=(
        "admin_token"
        "postgres_password"
    )
    
    for secret in "${required_secrets[@]}"; do
        local secret_file="$PROJECT_DIR/secrets/$secret"
        
        if [[ ! -f "$secret_file" ]]; then
            report_issue "HIGH" "SECRETS" "Required secret file missing: $secret"
            continue
        fi
        
        # Check file permissions
        local file_perms=$(stat -c "%a" "$secret_file")
        if [[ "$file_perms" != "600" ]] && [[ "$file_perms" != "400" ]]; then
            report_issue "HIGH" "SECRETS" "Secret file $secret has insecure permissions: $file_perms" \
                "chmod 600 '$secret_file'"
        fi
        
        # Check file ownership
        local file_owner=$(stat -c "%U" "$secret_file")
        if [[ "$file_owner" != "trader" ]] && [[ "$file_owner" != "root" ]]; then
            report_issue "MEDIUM" "SECRETS" "Secret file $secret has unexpected owner: $file_owner" \
                "chown trader:trader '$secret_file'"
        fi
        
        # Check for empty secrets
        if [[ ! -s "$secret_file" ]]; then
            report_issue "HIGH" "SECRETS" "Secret file $secret is empty"
        fi
        
        # Check for weak secrets (if readable)
        if [[ -r "$secret_file" ]]; then
            local secret_content=$(cat "$secret_file")
            local secret_length=${#secret_content}
            
            if [[ $secret_length -lt 12 ]]; then
                report_issue "MEDIUM" "SECRETS" "Secret $secret is too short (${secret_length} chars, minimum 12)"
            fi
            
            # Check for common weak passwords
            local weak_patterns=("password" "admin" "changeme" "123456" "qwerty")
            for pattern in "${weak_patterns[@]}"; do
                if [[ "$secret_content" == *"$pattern"* ]]; then
                    report_issue "HIGH" "SECRETS" "Secret $secret contains weak pattern: $pattern"
                fi
            done
        fi
    done
    
    # Check for secrets in environment files
    if [[ -f "$PROJECT_DIR/.env" ]]; then
        local secrets_in_env=$(grep -E "(PASSWORD|TOKEN|SECRET|KEY)=" "$PROJECT_DIR/.env" | grep -v "_FILE=" || true)
        if [[ -n "$secrets_in_env" ]]; then
            report_issue "HIGH" "SECRETS" "Secrets found in .env file instead of secrets/"
        fi
    fi
    
    # Check for secrets in git repository
    local secrets_in_git=$(git -C "$PROJECT_DIR" ls-files | grep -E "(secret|password|token|key)" | grep -v "example" || true)
    if [[ -n "$secrets_in_git" ]]; then
        report_issue "CRITICAL" "SECRETS" "Secret files tracked in git repository"
    fi
    
    log "Secrets management audit completed"
}

# Audit container security
audit_container_security() {
    log "Starting container security audit..."
    
    # Get list of trading containers
    local containers=($(docker ps --format "{{.Names}}" | grep "cli-trading" || true))
    
    if [[ ${#containers[@]} -eq 0 ]]; then
        report_issue "HIGH" "CONTAINER" "No trading containers found running"
        return
    fi
    
    for container in "${containers[@]}"; do
        log "Auditing container: $container"
        
        # Check if running as root
        local user_info=$(docker exec "$container" id 2>/dev/null || echo "uid=0(root)")
        if [[ "$user_info" == *"uid=0(root)"* ]]; then
            report_issue "HIGH" "CONTAINER" "Container $container running as root user"
        fi
        
        # Check privileged mode
        local privileged=$(docker inspect "$container" --format='{{.HostConfig.Privileged}}' 2>/dev/null || echo "false")
        if [[ "$privileged" == "true" ]]; then
            report_issue "CRITICAL" "CONTAINER" "Container $container running in privileged mode"
        fi
        
        # Check capabilities
        local cap_add=$(docker inspect "$container" --format='{{.HostConfig.CapAdd}}' 2>/dev/null || echo "[]")
        if [[ "$cap_add" != "[]" ]] && [[ "$cap_add" != "<no value>" ]]; then
            report_issue "MEDIUM" "CONTAINER" "Container $container has additional capabilities: $cap_add"
        fi
        
        # Check if read-only root filesystem
        local readonly_rootfs=$(docker inspect "$container" --format='{{.HostConfig.ReadonlyRootfs}}' 2>/dev/null || echo "false")
        if [[ "$readonly_rootfs" != "true" ]]; then
            report_issue "LOW" "CONTAINER" "Container $container does not have read-only root filesystem"
        fi
        
        # Check security options
        local security_opt=$(docker inspect "$container" --format='{{.HostConfig.SecurityOpt}}' 2>/dev/null || echo "[]")
        if [[ "$security_opt" != *"no-new-privileges"* ]]; then
            report_issue "MEDIUM" "CONTAINER" "Container $container missing no-new-privileges security option"
        fi
        
        # Check exposed ports
        local ports=$(docker inspect "$container" --format='{{.NetworkSettings.Ports}}' 2>/dev/null || echo "{}")
        if [[ "$ports" != "{}" ]] && [[ "$ports" != "map[]" ]]; then
            # Only report if container exposes ports to host
            local host_ports=$(echo "$ports" | grep -o "0.0.0.0" || true)
            if [[ -n "$host_ports" ]]; then
                report_issue "LOW" "CONTAINER" "Container $container exposes ports to host"
            fi
        fi
        
        # Check resource limits
        local memory_limit=$(docker inspect "$container" --format='{{.HostConfig.Memory}}' 2>/dev/null || echo "0")
        if [[ "$memory_limit" == "0" ]]; then
            report_issue "LOW" "CONTAINER" "Container $container has no memory limit"
        fi
        
        local cpu_limit=$(docker inspect "$container" --format='{{.HostConfig.CpuShares}}' 2>/dev/null || echo "0")
        if [[ "$cpu_limit" == "0" ]]; then
            report_issue "LOW" "CONTAINER" "Container $container has no CPU limit"
        fi
    done
    
    log "Container security audit completed"
}

# Audit network security
audit_network_security() {
    log "Starting network security audit..."
    
    # Check Docker networks
    local networks=$(docker network ls --format "{{.Name}}" | grep -E "(cli-trading|backend|public)" || true)
    
    for network in $networks; do
        # Check network configuration
        local network_info=$(docker network inspect "$network" 2>/dev/null || echo "[]")
        
        # Check if network is using default bridge
        local driver=$(echo "$network_info" | jq -r '.[0].Driver // "unknown"')
        if [[ "$driver" == "bridge" ]] && [[ "$network" == "bridge" ]]; then
            report_issue "MEDIUM" "NETWORK" "Using default Docker bridge network"
        fi
        
        # Check for overly permissive networks
        local internal=$(echo "$network_info" | jq -r '.[0].Internal // false')
        if [[ "$network" == *"backend"* ]] && [[ "$internal" != "true" ]]; then
            report_issue "LOW" "NETWORK" "Backend network $network is not marked as internal"
        fi
    done
    
    # Check exposed ports on host
    local exposed_ports=$(netstat -tlnp 2>/dev/null | grep ":70[0-9][0-9]" || true)
    if [[ -n "$exposed_ports" ]]; then
        while IFS= read -r line; do
            local port=$(echo "$line" | awk '{print $4}' | cut -d: -f2)
            if [[ "$port" =~ ^70[0-9][0-9]$ ]]; then
                report_issue "MEDIUM" "NETWORK" "Trading service port $port exposed on host"
            fi
        done <<< "$exposed_ports"
    fi
    
    # Check firewall status
    if command -v ufw >/dev/null 2>&1; then
        local ufw_status=$(ufw status | head -1)
        if [[ "$ufw_status" == *"inactive"* ]]; then
            report_issue "HIGH" "NETWORK" "UFW firewall is inactive" \
                "ufw --force enable"
        fi
        
        # Check for overly permissive rules
        local ufw_rules=$(ufw status numbered 2>/dev/null | grep "ALLOW" || true)
        if echo "$ufw_rules" | grep -q "Anywhere"; then
            report_issue "LOW" "NETWORK" "UFW has rules allowing from anywhere"
        fi
    else
        report_issue "MEDIUM" "NETWORK" "No firewall (UFW) detected"
    fi
    
    # Check for SSH hardening
    if [[ -f "/etc/ssh/sshd_config" ]]; then
        # Check SSH root login
        local root_login=$(grep -E "^PermitRootLogin" /etc/ssh/sshd_config || echo "PermitRootLogin yes")
        if [[ "$root_login" == *"yes"* ]]; then
            report_issue "HIGH" "NETWORK" "SSH root login is enabled" \
                "sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && systemctl reload ssh"
        fi
        
        # Check SSH password authentication
        local password_auth=$(grep -E "^PasswordAuthentication" /etc/ssh/sshd_config || echo "PasswordAuthentication yes")
        if [[ "$password_auth" == *"yes"* ]]; then
            report_issue "MEDIUM" "NETWORK" "SSH password authentication is enabled"
        fi
    fi
    
    log "Network security audit completed"
}

# Audit authentication and authorization
audit_auth() {
    log "Starting authentication and authorization audit..."
    
    # Check admin token security
    if [[ -f "$PROJECT_DIR/secrets/admin_token" ]]; then
        local admin_token=$(cat "$PROJECT_DIR/secrets/admin_token" 2>/dev/null || echo "")
        if [[ -n "$admin_token" ]]; then
            # Check token entropy/strength
            local token_length=${#admin_token}
            if [[ $token_length -lt 32 ]]; then
                report_issue "HIGH" "AUTH" "Admin token is too short (${token_length} chars, minimum 32)"
            fi
            
            # Check for simple patterns
            if [[ "$admin_token" =~ ^[a-zA-Z0-9]{8,}$ ]] && [[ $token_length -lt 24 ]]; then
                report_issue "MEDIUM" "AUTH" "Admin token may be too simple"
            fi
        fi
    fi
    
    # Check for hardcoded credentials in code
    local hardcoded_creds=$(find "$PROJECT_DIR" -name "*.js" -o -name "*.json" -o -name "*.yml" -o -name "*.yaml" | \
        xargs grep -l -E "(password|token|secret|key).*[:=].*['\"][^'\"]{8,}['\"]" 2>/dev/null || true)
    
    if [[ -n "$hardcoded_creds" ]]; then
        report_issue "CRITICAL" "AUTH" "Potential hardcoded credentials found in: $hardcoded_creds"
    fi
    
    # Check OAuth2 configuration if present
    if [[ -f "$PROJECT_DIR/secrets/oauth2_client_secret" ]]; then
        local oauth_secret=$(cat "$PROJECT_DIR/secrets/oauth2_client_secret" 2>/dev/null || echo "")
        if [[ ${#oauth_secret} -lt 20 ]]; then
            report_issue "HIGH" "AUTH" "OAuth2 client secret is too short"
        fi
    fi
    
    # Check for default passwords in docker-compose
    local default_passwords=$(grep -E "(POSTGRES_PASSWORD|REDIS_PASSWORD)" "$PROJECT_DIR/docker-compose.yml" | grep -v "_FILE" || true)
    if [[ -n "$default_passwords" ]]; then
        report_issue "HIGH" "AUTH" "Passwords configured directly in docker-compose.yml"
    fi
    
    # Check session security
    if [[ -f "$PROJECT_DIR/.env" ]]; then
        # Check if secure cookies are enabled
        local secure_cookies=$(grep -E "SECURE_COOKIES|COOKIE_SECURE" "$PROJECT_DIR/.env" || true)
        if [[ -z "$secure_cookies" ]]; then
            report_issue "LOW" "AUTH" "Secure cookie configuration not found"
        fi
    fi
    
    log "Authentication and authorization audit completed"
}

# Audit file system security
audit_filesystem() {
    log "Starting filesystem security audit..."
    
    # Check project directory permissions
    local project_perms=$(stat -c "%a" "$PROJECT_DIR")
    local project_owner=$(stat -c "%U:%G" "$PROJECT_DIR")
    
    if [[ "$project_owner" != "trader:trader" ]] && [[ "$project_owner" != "root:root" ]]; then
        report_issue "MEDIUM" "FILESYSTEM" "Project directory has unexpected ownership: $project_owner"
    fi
    
    # Check for world-writable files
    local world_writable=$(find "$PROJECT_DIR" -type f -perm -002 2>/dev/null || true)
    if [[ -n "$world_writable" ]]; then
        report_issue "HIGH" "FILESYSTEM" "World-writable files found: $world_writable" \
            "find '$PROJECT_DIR' -type f -perm -002 -exec chmod 644 {} +"
    fi
    
    # Check for SUID/SGID files
    local suid_files=$(find "$PROJECT_DIR" -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null || true)
    if [[ -n "$suid_files" ]]; then
        report_issue "MEDIUM" "FILESYSTEM" "SUID/SGID files found: $suid_files"
    fi
    
    # Check log file permissions
    if [[ -d "/opt/cli-trading/logs" ]]; then
        local log_perms=$(find /opt/cli-trading/logs -type f -exec stat -c "%a %n" {} \; 2>/dev/null || true)
        while IFS= read -r line; do
            if [[ -n "$line" ]]; then
                local perms=$(echo "$line" | cut -d' ' -f1)
                local file=$(echo "$line" | cut -d' ' -f2-)
                if [[ "${perms:2:1}" -gt "4" ]]; then
                    report_issue "LOW" "FILESYSTEM" "Log file $file has overly permissive permissions: $perms"
                fi
            fi
        done <<< "$log_perms"
    fi
    
    # Check for sensitive files in accessible locations
    local sensitive_files=$(find /tmp /var/tmp -name "*password*" -o -name "*secret*" -o -name "*key*" 2>/dev/null || true)
    if [[ -n "$sensitive_files" ]]; then
        report_issue "HIGH" "FILESYSTEM" "Sensitive files found in temporary directories: $sensitive_files"
    fi
    
    log "Filesystem security audit completed"
}

# Audit logging and monitoring security
audit_logging() {
    log "Starting logging security audit..."
    
    # Check for secrets in logs
    if [[ -d "/opt/cli-trading/logs" ]]; then
        local secrets_in_logs=$(grep -r -i -E "(password|token|secret|key).*[:=]" /opt/cli-trading/logs/ 2>/dev/null | head -5 || true)
        if [[ -n "$secrets_in_logs" ]]; then
            report_issue "HIGH" "LOGGING" "Potential secrets found in log files"
        fi
    fi
    
    # Check log retention
    if [[ -f "/etc/logrotate.d/cli-trading" ]]; then
        local retention=$(grep "rotate" /etc/logrotate.d/cli-trading | head -1 || echo "rotate 7")
        local days=$(echo "$retention" | grep -o "[0-9]\+" || echo "7")
        if [[ $days -gt 90 ]]; then
            report_issue "LOW" "LOGGING" "Log retention period too long: $days days"
        fi
    fi
    
    # Check if audit logging is enabled
    if ! command -v auditctl >/dev/null 2>&1; then
        report_issue "LOW" "LOGGING" "Audit logging (auditd) not installed"
    fi
    
    # Check centralized logging configuration
    if [[ ! -f "$PROJECT_DIR/loki/loki-config.yml" ]] && [[ ! -f "$PROJECT_DIR/promtail/promtail-config.yml" ]]; then
        report_issue "LOW" "LOGGING" "Centralized logging not configured"
    fi
    
    log "Logging security audit completed"
}

# Compliance checks
audit_compliance() {
    if [[ "$COMPLIANCE_CHECK" != "true" ]]; then
        return 0
    fi
    
    log "Starting compliance audit..."
    
    # Data encryption at rest
    local encryption_check=$(docker exec cli-trading-postgres-1 psql -U trader -d trading -c "SELECT name, setting FROM pg_settings WHERE name LIKE '%ssl%';" 2>/dev/null || true)
    if [[ -z "$encryption_check" ]] || [[ "$encryption_check" != *"ssl = on"* ]]; then
        report_issue "MEDIUM" "COMPLIANCE" "Database encryption not verified"
    fi
    
    # Backup encryption
    if [[ ! -f "/opt/cli-trading/scripts/backup-system.sh" ]] || ! grep -q "gpg" "/opt/cli-trading/scripts/backup-system.sh"; then
        report_issue "MEDIUM" "COMPLIANCE" "Backup encryption not configured"
    fi
    
    # Access logging
    if [[ ! -f "/var/log/auth.log" ]]; then
        report_issue "MEDIUM" "COMPLIANCE" "Authentication logging not available"
    fi
    
    # Data retention policy
    if [[ ! -f "/opt/cli-trading/docs/data-retention-policy.md" ]]; then
        report_issue "LOW" "COMPLIANCE" "Data retention policy not documented"
    fi
    
    log "Compliance audit completed"
}

# Generate security report
generate_security_report() {
    if [[ "$GENERATE_REPORT" != "true" ]]; then
        return 0
    fi
    
    log "Generating security report..."
    
    mkdir -p "$REPORT_DIR"
    local report_file="$REPORT_DIR/security-audit-$(date +%Y%m%d_%H%M%S).json"
    local html_report="${report_file%.json}.html"
    
    # Generate JSON report
    cat > "$report_file" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "overall_score": $overall_security_score,
  "risk_level": "$(if [[ $overall_security_score -gt 80 ]]; then echo "LOW"; elif [[ $overall_security_score -gt 60 ]]; then echo "MEDIUM"; elif [[ $overall_security_score -gt 40 ]]; then echo "HIGH"; else echo "CRITICAL"; fi)",
  "summary": {
    "total_issues": $((critical_issues + high_issues + medium_issues + low_issues)),
    "critical": $critical_issues,
    "high": $high_issues,
    "medium": $medium_issues,
    "low": $low_issues
  },
  "findings": {
EOF
    
    local first=true
    for key in "${!security_issues[@]}"; do
        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo "," >> "$report_file"
        fi
        echo "    \"$key\": {" >> "$report_file"
        echo "      \"severity\": \"${security_issues[$key]}\"," >> "$report_file"
        echo "      \"description\": \"${findings[$key]}\"" >> "$report_file"
        echo "    }" >> "$report_file"
    done
    
    cat >> "$report_file" << EOF
  }
}
EOF
    
    # Generate HTML report
    cat > "$html_report" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Security Audit Report - CLI Trading</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background: #f4f4f4; padding: 20px; border-radius: 5px; }
        .score { font-size: 24px; font-weight: bold; }
        .critical { color: #d32f2f; }
        .high { color: #f57c00; }
        .medium { color: #fbc02d; }
        .low { color: #388e3c; }
        .issue { margin: 10px 0; padding: 10px; border-left: 4px solid; }
        .issue.critical { border-color: #d32f2f; background: #ffebee; }
        .issue.high { border-color: #f57c00; background: #fff3e0; }
        .issue.medium { border-color: #fbc02d; background: #fffde7; }
        .issue.low { border-color: #388e3c; background: #e8f5e8; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Security Audit Report</h1>
        <p>Generated: $(date)</p>
        <p>Security Score: <span class="score">$overall_security_score/100</span></p>
        <p>Risk Level: $(if [[ $overall_security_score -gt 80 ]]; then echo "LOW"; elif [[ $overall_security_score -gt 60 ]]; then echo "MEDIUM"; elif [[ $overall_security_score -gt 40 ]]; then echo "HIGH"; else echo "CRITICAL"; fi)</p>
    </div>
    
    <h2>Summary</h2>
    <ul>
        <li>Total Issues: $((critical_issues + high_issues + medium_issues + low_issues))</li>
        <li class="critical">Critical: $critical_issues</li>
        <li class="high">High: $high_issues</li>
        <li class="medium">Medium: $medium_issues</li>
        <li class="low">Low: $low_issues</li>
    </ul>
    
    <h2>Findings</h2>
EOF
    
    for key in "${!security_issues[@]}"; do
        local severity="${security_issues[$key]}"
        local description="${findings[$key]}"
        local class_name=$(echo "$severity" | tr '[:upper:]' '[:lower:]')
        
        cat >> "$html_report" << EOF
    <div class="issue $class_name">
        <strong>[$severity]</strong> $description
    </div>
EOF
    done
    
    cat >> "$html_report" << EOF
</body>
</html>
EOF
    
    log "Security report generated: $report_file"
    log "HTML report generated: $html_report"
}

# Display audit summary
display_summary() {
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    echo
    bold "🛡️ Security Audit Summary"
    echo "Timestamp: $timestamp"
    echo "Overall Security Score: $overall_security_score/100"
    
    local risk_level
    if [[ $overall_security_score -gt 80 ]]; then
        risk_level="LOW"
        green "Risk Level: $risk_level"
    elif [[ $overall_security_score -gt 60 ]]; then
        risk_level="MEDIUM"
        yellow "Risk Level: $risk_level"
    elif [[ $overall_security_score -gt 40 ]]; then
        risk_level="HIGH"
        red "Risk Level: $risk_level"
    else
        risk_level="CRITICAL"
        red "Risk Level: $risk_level"
    fi
    
    echo
    echo "Issue Summary:"
    if [[ $critical_issues -gt 0 ]]; then
        red "  Critical Issues: $critical_issues"
    fi
    if [[ $high_issues -gt 0 ]]; then
        red "  High Issues: $high_issues"
    fi
    if [[ $medium_issues -gt 0 ]]; then
        yellow "  Medium Issues: $medium_issues"
    fi
    if [[ $low_issues -gt 0 ]]; then
        blue "  Low Issues: $low_issues"
    fi
    
    local total_issues=$((critical_issues + high_issues + medium_issues + low_issues))
    echo "  Total Issues: $total_issues"
    
    if [[ $total_issues -eq 0 ]]; then
        green "✅ No security issues found!"
    elif [[ $critical_issues -gt 0 ]] || [[ $high_issues -gt 0 ]]; then
        red "❌ Critical or high-severity security issues require immediate attention"
    else
        yellow "⚠️ Security issues found but none are critical"
    fi
    
    echo
    echo "Audit Log: $SECURITY_LOG"
    if [[ "$GENERATE_REPORT" == "true" ]]; then
        echo "Security Reports: $REPORT_DIR/"
    fi
}

# Main execution
main() {
    # Create log and report directories
    mkdir -p "$(dirname "$SECURITY_LOG")"
    mkdir -p "$REPORT_DIR"
    
    bold "🔒 Starting Comprehensive Security Audit"
    log "Security audit started"
    
    # Run all audit functions
    audit_secrets
    audit_container_security
    audit_network_security
    audit_auth
    audit_filesystem
    audit_logging
    audit_compliance
    
    # Generate report if requested
    generate_security_report
    
    # Display summary
    display_summary
    
    # Exit with appropriate code based on findings
    if [[ $critical_issues -gt 0 ]]; then
        exit 2  # Critical issues
    elif [[ $high_issues -gt 0 ]]; then
        exit 1  # High issues
    else
        exit 0  # No critical/high issues
    fi
}

# Run main function
main