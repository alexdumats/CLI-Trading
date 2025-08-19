#!/bin/bash
#
# Secrets Management Script for CLI-Trading System
#
# This script provides secure management of secrets including generation,
# rotation, validation, and backup of sensitive configuration data.
#
# Usage: ./scripts/manage-secrets.sh [command] [options]
#
# Commands:
#   generate    - Generate new secrets
#   rotate      - Rotate existing secrets
#   validate    - Validate current secrets
#   backup      - Create encrypted backup
#   restore     - Restore from backup
#   list        - List configured secrets
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SECRETS_DIR="$PROJECT_DIR/secrets"
BACKUP_DIR="/opt/cli-trading/backups/secrets"
SECRETS_LOG="/opt/cli-trading/logs/secrets-management.log"

# Default values
COMMAND=""
FORCE=false
BACKUP_ENCRYPTION_KEY=""

# Parse command line arguments
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 [command] [options]"
    echo "Commands: generate, rotate, validate, backup, restore, list"
    exit 1
fi

COMMAND=$1
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE=true
            shift
            ;;
        --backup-key)
            BACKUP_ENCRYPTION_KEY="$2"
            shift 2
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
    echo "$message" >> "$SECRETS_LOG" 2>/dev/null || true
}

# Error handling
error_exit() {
    red "ERROR: $1"
    log "ERROR: $1"
    exit 1
}

# Generate secure random string
generate_random_string() {
    local length=${1:-32}
    local charset=${2:-"A-Za-z0-9"}
    
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 $((length * 3 / 4)) | tr -d "=+/" | cut -c1-$length
    elif [[ -c /dev/urandom ]]; then
        tr -dc "$charset" < /dev/urandom | head -c $length
    else
        error_exit "No secure random source available"
    fi
}

# Generate strong password
generate_strong_password() {
    local length=${1:-24}
    
    # Generate password with mixed character sets
    local lowercase=$(tr -dc 'a-z' < /dev/urandom | head -c $((length / 4)))
    local uppercase=$(tr -dc 'A-Z' < /dev/urandom | head -c $((length / 4)))
    local numbers=$(tr -dc '0-9' < /dev/urandom | head -c $((length / 4)))
    local special=$(tr -dc '!@#$%^&*()_+-=' < /dev/urandom | head -c $((length / 4)))
    
    # Combine and shuffle
    echo "$lowercase$uppercase$numbers$special" | fold -w1 | shuf | tr -d '\n'
}

# Generate JWT-style token
generate_jwt_token() {
    local header='{"alg":"HS256","typ":"JWT"}'
    local payload="{\"iss\":\"cli-trading\",\"iat\":$(date +%s),\"exp\":$(($(date +%s) + 31536000))}"
    local secret=$(generate_random_string 64)
    
    # Base64 encode header and payload
    local encoded_header=$(echo -n "$header" | base64 | tr -d '=' | tr '/+' '_-')
    local encoded_payload=$(echo -n "$payload" | base64 | tr -d '=' | tr '/+' '_-')
    
    # Generate signature (simplified for demo)
    local signature=$(echo -n "${encoded_header}.${encoded_payload}" | openssl dgst -sha256 -hmac "$secret" -binary | base64 | tr -d '=' | tr '/+' '_-')
    
    echo "${encoded_header}.${encoded_payload}.${signature}"
}

# Setup secrets directory
setup_secrets_directory() {
    if [[ ! -d "$SECRETS_DIR" ]]; then
        log "Creating secrets directory..."
        mkdir -p "$SECRETS_DIR"
    fi
    
    # Set secure permissions
    chmod 700 "$SECRETS_DIR"
    chown trader:trader "$SECRETS_DIR" 2>/dev/null || true
    
    log "Secrets directory secured"
}

# Generate all required secrets
generate_secrets() {
    log "Starting secrets generation..."
    
    setup_secrets_directory
    
    declare -A secrets_config=(
        # Required secrets
        ["admin_token"]="jwt"
        ["postgres_password"]="password:32"
        
        # Optional secrets (only generate if enabled)
        ["slack_bot_token"]="string:64"
        ["slack_signing_secret"]="string:32"
        ["jira_api_token"]="string:40"
        ["notion_api_token"]="string:50"
        
        # OAuth2 secrets
        ["oauth2_client_id"]="string:32"
        ["oauth2_client_secret"]="password:48"
        ["oauth2_cookie_secret"]="random:32"
        
        # Webhook URLs (placeholders)
        ["slack_webhook_url"]="webhook"
        ["slack_webhook_url_info"]="webhook"
        ["slack_webhook_url_warning"]="webhook"
        ["slack_webhook_url_critical"]="webhook"
    )
    
    for secret_name in "${!secrets_config[@]}"; do
        local secret_file="$SECRETS_DIR/$secret_name"
        local secret_type="${secrets_config[$secret_name]}"
        
        # Skip if file exists and not forcing
        if [[ -f "$secret_file" ]] && [[ "$FORCE" != "true" ]]; then
            yellow "Secret $secret_name already exists, skipping (use --force to regenerate)"
            continue
        fi
        
        log "Generating secret: $secret_name"
        
        local secret_value=""
        case $secret_type in
            "jwt")
                secret_value=$(generate_jwt_token)
                ;;
            "password:"*)
                local length=${secret_type#password:}
                secret_value=$(generate_strong_password "$length")
                ;;
            "string:"*)
                local length=${secret_type#string:}
                secret_value=$(generate_random_string "$length")
                ;;
            "random:"*)
                local length=${secret_type#random:}
                secret_value=$(openssl rand -base64 "$length")
                ;;
            "webhook")
                secret_value="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
                ;;
            *)
                error_exit "Unknown secret type: $secret_type"
                ;;
        esac
        
        # Write secret to file
        echo -n "$secret_value" > "$secret_file"
        chmod 600 "$secret_file"
        chown trader:trader "$secret_file" 2>/dev/null || true
        
        green "✓ Generated $secret_name"
    done
    
    # Generate .env.example with secret file references
    generate_env_example
    
    log "Secrets generation completed"
}

# Generate .env.example file
generate_env_example() {
    local env_example="$PROJECT_DIR/.env.example"
    
    log "Generating .env.example file..."
    
    cat > "$env_example" << 'EOF'
# CLI-Trading System Environment Configuration
# Copy this file to .env and configure for your environment

# Node Environment
NODE_ENV=production

# Redis Configuration
REDIS_URL=redis://redis:6379/0

# PostgreSQL Configuration
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_USER=trader
POSTGRES_DB=trading
# POSTGRES_PASSWORD is loaded from secrets/postgres_password file

# Trading Configuration
START_EQUITY=1000
DAILY_TARGET_PCT=1.0
PROFIT_PER_TRADE=10

# Communication Mode
COMM_MODE=hybrid

# Stream Configuration
STREAM_IDEMP_TTL_SECONDS=86400
STREAM_MAX_FAILURES=5

# Admin Token (loaded from secrets/admin_token file)
# ADMIN_TOKEN is loaded from secrets/admin_token file

# Monitoring URLs
GRAFANA_URL=http://grafana:3000
PROM_URL=http://prometheus:9090

# SSL/TLS Configuration (for production)
LETSENCRYPT_EMAIL=admin@yourdomain.com
TRAEFIK_DOMAIN=trading.yourdomain.com
ORCH_DOMAIN=orchestrator.yourdomain.com
GRAFANA_DOMAIN=grafana.yourdomain.com
PROM_DOMAIN=prometheus.yourdomain.com

# Traefik Authentication
TRAEFIK_BASIC_AUTH=admin:$2y$10$... # Generate with: htpasswd -n admin
TRAEFIK_ALLOWED_CIDRS=192.168.1.0/24,10.0.0.0/8

# Rate Limiting
ORCH_RL_AVG=100
ORCH_RL_BURST=200

# OAuth2 Configuration (optional)
OAUTH2_PROXY_PROVIDER=github
OAUTH2_PROXY_EMAIL_DOMAINS=*
OAUTH2_PROXY_ALLOWED_EMAILS=your-email@domain.com
OAUTH2_PROXY_REDIRECT_URL=https://your-domain.com/oauth2/callback

# Grafana Configuration
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=admin

# Alert Configuration
ALERT_SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
ALERT_SLACK_CHANNEL=#trading-alerts

# Integration Flags
ENABLE_JIRA=false
ENABLE_NOTION=false

# Jira Configuration (if enabled)
JIRA_BASE_URL=https://your-company.atlassian.net
JIRA_EMAIL=your-email@company.com
JIRA_PROJECT_KEY=TRADING
JIRA_ISSUE_TYPE=Task

# Notion Configuration (if enabled)
NOTION_DATABASE_ID=your-notion-database-id

# Backup Configuration
BACKUP_RETENTION_DAYS=30
BACKUP_ENCRYPTION_ENABLED=true
EOF

    log ".env.example file generated"
}

# Rotate secrets
rotate_secrets() {
    log "Starting secrets rotation..."
    
    if [[ ! -d "$SECRETS_DIR" ]]; then
        error_exit "Secrets directory does not exist. Run 'generate' first."
    fi
    
    # Create backup before rotation
    backup_secrets "pre-rotation-$(date +%Y%m%d_%H%M%S)"
    
    # Get list of secrets to rotate
    local secrets_to_rotate=()
    while IFS= read -r -d '' file; do
        secrets_to_rotate+=("$(basename "$file")")
    done < <(find "$SECRETS_DIR" -type f -print0)
    
    if [[ ${#secrets_to_rotate[@]} -eq 0 ]]; then
        error_exit "No secrets found to rotate"
    fi
    
    echo "Secrets to rotate: ${secrets_to_rotate[*]}"
    
    if [[ "$FORCE" != "true" ]]; then
        read -p "Proceed with rotation? This will require system restart. (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Rotation cancelled by user"
            exit 0
        fi
    fi
    
    # Rotate each secret
    for secret_name in "${secrets_to_rotate[@]}"; do
        case $secret_name in
            "admin_token")
                rotate_admin_token
                ;;
            "postgres_password")
                rotate_postgres_password
                ;;
            "oauth2_"*)
                rotate_oauth_secret "$secret_name"
                ;;
            *)
                rotate_generic_secret "$secret_name"
                ;;
        esac
    done
    
    log "Secrets rotation completed. System restart required!"
    yellow "⚠️ IMPORTANT: Restart the trading system to apply new secrets"
}

# Rotate admin token
rotate_admin_token() {
    log "Rotating admin token..."
    
    local old_token_file="$SECRETS_DIR/admin_token"
    local new_token=$(generate_jwt_token)
    
    # Backup old token
    if [[ -f "$old_token_file" ]]; then
        cp "$old_token_file" "${old_token_file}.backup"
    fi
    
    # Write new token
    echo -n "$new_token" > "$old_token_file"
    chmod 600 "$old_token_file"
    
    green "✓ Admin token rotated"
}

# Rotate PostgreSQL password
rotate_postgres_password() {
    log "Rotating PostgreSQL password..."
    
    local password_file="$SECRETS_DIR/postgres_password"
    local new_password=$(generate_strong_password 32)
    
    # Update password in database first
    if docker ps --format "{{.Names}}" | grep -q "cli-trading-postgres"; then
        log "Updating password in PostgreSQL..."
        docker exec cli-trading-postgres-1 psql -U trader -c "ALTER USER trader PASSWORD '$new_password';" 2>/dev/null || {
            error_exit "Failed to update PostgreSQL password"
        }
    fi
    
    # Update secret file
    echo -n "$new_password" > "$password_file"
    chmod 600 "$password_file"
    
    green "✓ PostgreSQL password rotated"
}

# Rotate OAuth2 secret
rotate_oauth_secret() {
    local secret_name=$1
    log "Rotating OAuth2 secret: $secret_name"
    
    local secret_file="$SECRETS_DIR/$secret_name"
    local new_secret
    
    case $secret_name in
        "oauth2_client_secret")
            new_secret=$(generate_strong_password 48)
            ;;
        "oauth2_cookie_secret")
            new_secret=$(openssl rand -base64 32)
            ;;
        *)
            new_secret=$(generate_random_string 32)
            ;;
    esac
    
    echo -n "$new_secret" > "$secret_file"
    chmod 600 "$secret_file"
    
    green "✓ OAuth2 secret $secret_name rotated"
    yellow "⚠️ Update your OAuth2 provider with the new client secret"
}

# Rotate generic secret
rotate_generic_secret() {
    local secret_name=$1
    log "Rotating generic secret: $secret_name"
    
    local secret_file="$SECRETS_DIR/$secret_name"
    
    # Generate appropriate replacement based on current content
    local new_secret
    if [[ -f "$secret_file" ]]; then
        local current_length=$(wc -c < "$secret_file")
        if [[ $current_length -gt 40 ]]; then
            new_secret=$(generate_random_string "$current_length")
        else
            new_secret=$(generate_strong_password 24)
        fi
    else
        new_secret=$(generate_strong_password 24)
    fi
    
    echo -n "$new_secret" > "$secret_file"
    chmod 600 "$secret_file"
    
    green "✓ Secret $secret_name rotated"
}

# Validate secrets
validate_secrets() {
    log "Starting secrets validation..."
    
    local validation_errors=0
    local secrets_found=0
    
    # Required secrets
    local required_secrets=("admin_token" "postgres_password")
    
    for secret_name in "${required_secrets[@]}"; do
        local secret_file="$SECRETS_DIR/$secret_name"
        
        if [[ ! -f "$secret_file" ]]; then
            red "✗ Required secret missing: $secret_name"
            ((validation_errors++))
            continue
        fi
        
        ((secrets_found++))
        
        # Check file permissions
        local perms=$(stat -c "%a" "$secret_file")
        if [[ "$perms" != "600" ]] && [[ "$perms" != "400" ]]; then
            red "✗ Secret $secret_name has insecure permissions: $perms"
            ((validation_errors++))
        fi
        
        # Check file size
        if [[ ! -s "$secret_file" ]]; then
            red "✗ Secret $secret_name is empty"
            ((validation_errors++))
            continue
        fi
        
        # Check secret strength
        local secret_content=$(cat "$secret_file")
        local secret_length=${#secret_content}
        
        case $secret_name in
            "admin_token")
                if [[ $secret_length -lt 32 ]]; then
                    red "✗ Admin token too short: $secret_length chars (minimum 32)"
                    ((validation_errors++))
                fi
                ;;
            "postgres_password")
                if [[ $secret_length -lt 12 ]]; then
                    red "✗ PostgreSQL password too short: $secret_length chars (minimum 12)"
                    ((validation_errors++))
                fi
                # Check for weak patterns
                if [[ "$secret_content" =~ ^[a-z]+$ ]] || [[ "$secret_content" =~ ^[0-9]+$ ]]; then
                    red "✗ PostgreSQL password too simple"
                    ((validation_errors++))
                fi
                ;;
        esac
        
        green "✓ Secret $secret_name validated"
    done
    
    # Check optional secrets
    local optional_secrets=("slack_bot_token" "slack_signing_secret" "jira_api_token" "notion_api_token")
    
    for secret_name in "${optional_secrets[@]}"; do
        local secret_file="$SECRETS_DIR/$secret_name"
        
        if [[ -f "$secret_file" ]]; then
            ((secrets_found++))
            
            if [[ ! -s "$secret_file" ]]; then
                yellow "⚠ Optional secret $secret_name exists but is empty"
            else
                green "✓ Optional secret $secret_name found"
            fi
        fi
    done
    
    echo
    echo "Validation Summary:"
    echo "  Secrets found: $secrets_found"
    echo "  Validation errors: $validation_errors"
    
    if [[ $validation_errors -eq 0 ]]; then
        green "✅ All secrets validation passed"
        return 0
    else
        red "❌ Secrets validation failed with $validation_errors errors"
        return 1
    fi
}

# Backup secrets
backup_secrets() {
    local backup_name=${1:-"secrets-$(date +%Y%m%d_%H%M%S)"}
    
    log "Creating secrets backup: $backup_name"
    
    if [[ ! -d "$SECRETS_DIR" ]] || [[ -z "$(ls -A "$SECRETS_DIR" 2>/dev/null)" ]]; then
        error_exit "No secrets found to backup"
    fi
    
    mkdir -p "$BACKUP_DIR"
    
    # Create tar archive
    local backup_file="$BACKUP_DIR/${backup_name}.tar.gz"
    tar -czf "$backup_file" -C "$PROJECT_DIR" secrets/
    
    # Encrypt backup if encryption key provided
    if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
        log "Encrypting backup..."
        gpg --symmetric --cipher-algo AES256 --compress-algo 1 --s2k-digest-algo sha512 \
            --passphrase "$BACKUP_ENCRYPTION_KEY" --batch --yes \
            --output "${backup_file}.gpg" "$backup_file"
        
        # Remove unencrypted backup
        rm "$backup_file"
        backup_file="${backup_file}.gpg"
    fi
    
    # Set secure permissions
    chmod 600 "$backup_file"
    
    green "✓ Secrets backup created: $backup_file"
    
    # Clean up old backups (keep last 10)
    log "Cleaning up old backups..."
    ls -t "$BACKUP_DIR"/secrets-*.tar.gz* 2>/dev/null | tail -n +11 | xargs rm -f
}

# Restore secrets
restore_secrets() {
    log "Starting secrets restore..."
    
    if [[ ! -d "$BACKUP_DIR" ]]; then
        error_exit "Backup directory does not exist: $BACKUP_DIR"
    fi
    
    # List available backups
    echo "Available backups:"
    local backups=($(ls -t "$BACKUP_DIR"/secrets-*.tar.gz* 2>/dev/null || true))
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        error_exit "No backup files found"
    fi
    
    for i in "${!backups[@]}"; do
        echo "  $((i+1)). $(basename "${backups[$i]}")"
    done
    
    # Get user selection
    if [[ "$FORCE" != "true" ]]; then
        read -p "Select backup to restore (1-${#backups[@]}): " -r selection
        
        if ! [[ "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt ${#backups[@]} ]]; then
            error_exit "Invalid selection"
        fi
    else
        selection=1  # Use most recent backup
    fi
    
    local backup_file="${backups[$((selection-1))]}"
    log "Restoring from backup: $(basename "$backup_file")"
    
    # Backup current secrets first
    if [[ -d "$SECRETS_DIR" ]] && [[ -n "$(ls -A "$SECRETS_DIR" 2>/dev/null)" ]]; then
        log "Backing up current secrets before restore..."
        backup_secrets "pre-restore-$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Decrypt if necessary
    local temp_file="$backup_file"
    if [[ "$backup_file" == *.gpg ]]; then
        if [[ -z "$BACKUP_ENCRYPTION_KEY" ]]; then
            read -s -p "Enter backup encryption passphrase: " BACKUP_ENCRYPTION_KEY
            echo
        fi
        
        temp_file="/tmp/secrets-restore-$$.tar.gz"
        gpg --decrypt --passphrase "$BACKUP_ENCRYPTION_KEY" --batch --yes \
            --output "$temp_file" "$backup_file" || error_exit "Failed to decrypt backup"
    fi
    
    # Remove existing secrets directory
    if [[ -d "$SECRETS_DIR" ]]; then
        rm -rf "$SECRETS_DIR"
    fi
    
    # Extract backup
    tar -xzf "$temp_file" -C "$PROJECT_DIR"
    
    # Clean up temporary file
    if [[ "$temp_file" != "$backup_file" ]]; then
        rm -f "$temp_file"
    fi
    
    # Fix permissions
    chmod 700 "$SECRETS_DIR"
    find "$SECRETS_DIR" -type f -exec chmod 600 {} \;
    chown -R trader:trader "$SECRETS_DIR" 2>/dev/null || true
    
    green "✓ Secrets restored from backup"
    yellow "⚠️ System restart required to apply restored secrets"
}

# List secrets
list_secrets() {
    log "Listing configured secrets..."
    
    if [[ ! -d "$SECRETS_DIR" ]]; then
        yellow "Secrets directory does not exist"
        return 0
    fi
    
    echo "Configured secrets:"
    echo "├── Directory: $SECRETS_DIR"
    echo "├── Permissions: $(stat -c "%a" "$SECRETS_DIR")"
    echo "└── Contents:"
    
    local secrets=($(find "$SECRETS_DIR" -type f | sort))
    
    if [[ ${#secrets[@]} -eq 0 ]]; then
        echo "    (no secrets found)"
        return 0
    fi
    
    for secret_file in "${secrets[@]}"; do
        local secret_name=$(basename "$secret_file")
        local perms=$(stat -c "%a" "$secret_file")
        local size=$(stat -c "%s" "$secret_file")
        local modified=$(stat -c "%Y" "$secret_file" | xargs -I {} date -d @{} '+%Y-%m-%d %H:%M:%S')
        
        echo "    ├── $secret_name"
        echo "    │   ├── Permissions: $perms"
        echo "    │   ├── Size: $size bytes"
        echo "    │   └── Modified: $modified"
    done
}

# Main execution
main() {
    # Create log directory
    mkdir -p "$(dirname "$SECRETS_LOG")"
    
    case $COMMAND in
        "generate")
            bold "🔐 Generating Secrets"
            generate_secrets
            ;;
        "rotate")
            bold "🔄 Rotating Secrets"
            rotate_secrets
            ;;
        "validate")
            bold "✅ Validating Secrets"
            validate_secrets
            ;;
        "backup")
            bold "💾 Backing up Secrets"
            backup_secrets
            ;;
        "restore")
            bold "📥 Restoring Secrets"
            restore_secrets
            ;;
        "list")
            bold "📋 Listing Secrets"
            list_secrets
            ;;
        *)
            error_exit "Unknown command: $COMMAND"
            ;;
    esac
}

# Run main function
main