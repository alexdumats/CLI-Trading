#!/usr/bin/env bash
# setup.sh - Prepare a fresh Hetzner Ubuntu server for a multi-agent trading system deployment
#
# This script is idempotent and safe to re-run. It handles:
# - System updates and baseline tooling
# - Node.js 20.x + npm, Git, ripgrep
# - Docker CE + Docker Compose plugin (docker compose)
# - Redis (local-only)
# - Non-root deploy user with sudo, SSH key-based auth, and Docker group
# - SSH hardening (disable root + password auth)
# - UFW firewall + Fail2ban
# - Optional Anthropic API key setup for Claude/CLI tooling
# - Project directory scaffolding (empty placeholder)
#
# Usage examples:
#   sudo bash setup.sh --user trader --ssh-pubkey "ssh-ed25519 AAAA... user@host" --anthropic-key "sk-ant-..."
#   sudo bash setup.sh --user trader --ssh-pubkey-file /tmp/id_ed25519.pub
#
# Notes:
# - Must be run as root (or with sudo).
# - If you pass --disable-root-ssh yes (default), ensure you provide a working SSH public key.
# - After adding a user to the docker group, a new login session is required for it to take effect.

set -euo pipefail

# Defaults
DEPLOY_USER="trader"
SSH_PUBKEY=""
SSH_PUBKEY_FILE=""
ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"
DISABLE_ROOT_SSH="yes"
TIMEZONE="Etc/UTC"
PROJECT_DIR="/opt/claude-multi-agent-trader"
CLAUDE_CODE_NPM_PACKAGE="claude-code"  # If this fails, script will guide you to alternatives
# Traefik basic auth helpers
GENERATE_HTPASSWD="no"
BASIC_AUTH_USER="admin"
BASIC_AUTH_PASS=""
ENV_FILE_PATH=""

log() { echo -e "[setup] $*"; }
err() { echo -e "[setup:ERROR] $*" 1>&2; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "This script must be run as root (try: sudo bash setup.sh ...)"
    exit 1
  fi
}

usage() {
  cat <<EOF
Usage: sudo bash setup.sh [options]

Options:
  --user <name>                Deploy username to create/use (default: ${DEPLOY_USER})
  --ssh-pubkey <key>           SSH public key string to authorize for the deploy user
  --ssh-pubkey-file <path>     Path to file containing a single-line SSH public key
  --anthropic-key <key>        Anthropic API key to store system-wide (optional)
  --disable-root-ssh <yes|no>  Disable root SSH login and password auth (default: ${DISABLE_ROOT_SSH})
  --timezone <tz>              System timezone (default: ${TIMEZONE})
  --generate-htpasswd <yes|no> Generate Traefik Basic Auth and write to .env (default: ${GENERATE_HTPASSWD})
  --basic-auth-user <user>     Username for Traefik Basic Auth (default: ${BASIC_AUTH_USER})
  --basic-auth-pass <pass>     Password for Traefik Basic Auth (auto-generate if empty)
  --env-file <path>            .env file path (default: ${PROJECT_DIR}/.env)
  -h, --help                   Show this help

Examples:
  sudo bash setup.sh --user trader --ssh-pubkey "ssh-ed25519 AAA.." --anthropic-key "sk-ant-..."
  sudo bash setup.sh --user ops --ssh-pubkey-file /root/.ssh/id_ed25519.pub --disable-root-ssh yes
  sudo bash setup.sh --generate-htpasswd yes --basic-auth-user admin --basic-auth-pass 'S3cureP@ss!'
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user)
        DEPLOY_USER="$2"; shift 2;;
      --ssh-pubkey)
        SSH_PUBKEY="$2"; shift 2;;
      --ssh-pubkey-file)
        SSH_PUBKEY_FILE="$2"; shift 2;;
      --anthropic-key)
        ANTHROPIC_KEY="$2"; shift 2;;
      --disable-root-ssh)
        DISABLE_ROOT_SSH="$2"; shift 2;;
      --timezone)
        TIMEZONE="$2"; shift 2;;
      --generate-htpasswd)
        GENERATE_HTPASSWD="$2"; shift 2;;
      --basic-auth-user)
        BASIC_AUTH_USER="$2"; shift 2;;
      --basic-auth-pass)
        BASIC_AUTH_PASS="$2"; shift 2;;
      --env-file)
        ENV_FILE_PATH="$2"; shift 2;;
      -h|--help)
        usage; exit 0;;
      *)
        err "Unknown option: $1"; usage; exit 1;;
    esac
  done
}

set_timezone() {
  if command -v timedatectl >/dev/null 2>&1; then
    log "Setting timezone to ${TIMEZONE}"
    timedatectl set-timezone "$TIMEZONE" || true
  fi
}

apt_baseline() {
  log "Updating system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get upgrade -y
  apt-get install -y \
    ca-certificates curl gnupg lsb-release \
    git ripgrep jq unzip \
    ufw fail2ban \
    build-essential pkg-config \
    software-properties-common \
    apache2-utils openssl wget
}

install_node() {
  if command -v node >/dev/null 2>&1; then
    local ver; ver=$(node -v || true)
    log "Node already installed: ${ver}"
  else
    log "Installing Node.js 20.x"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
  fi
  log "Node version: $(node -v)"
  log "npm version: $(npm -v)"
}

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker CE and Docker Compose plugin"
    # Remove old versions
    apt-get remove -y docker docker-engine docker.io containerd runc || true

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    . /etc/os-release
    echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update -y
    apt-get install -y \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker
  else
    log "Docker already installed: $(docker --version)"
  fi
  log "Docker Compose plugin: $(docker compose version || echo 'compose plugin not available')"
}

create_deploy_user() {
  if id -u "$DEPLOY_USER" >/dev/null 2>&1; then
    log "User '$DEPLOY_USER' already exists"
  else
    log "Creating user '$DEPLOY_USER' with sudo and docker group"
    adduser --disabled-password --gecos "" "$DEPLOY_USER"
  fi
  usermod -aG sudo "$DEPLOY_USER" || true
  usermod -aG docker "$DEPLOY_USER" || true

  # SSH setup
  local ssh_dir="/home/$DEPLOY_USER/.ssh"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  touch "$ssh_dir/authorized_keys"
  chmod 600 "$ssh_dir/authorized_keys"
  chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$ssh_dir"

  if [[ -n "$SSH_PUBKEY_FILE" ]]; then
    if [[ -f "$SSH_PUBKEY_FILE" ]]; then
      if ! grep -qf "$SSH_PUBKEY_FILE" "$ssh_dir/authorized_keys"; then
        cat "$SSH_PUBKEY_FILE" >> "$ssh_dir/authorized_keys"
        log "Added SSH key from file to authorized_keys"
      else
        log "SSH key from file already present in authorized_keys"
      fi
    else
      err "SSH public key file not found: $SSH_PUBKEY_FILE"
    fi
  fi

  if [[ -n "$SSH_PUBKEY" ]]; then
    if ! grep -qF "$SSH_PUBKEY" "$ssh_dir/authorized_keys"; then
      echo "$SSH_PUBKEY" >> "$ssh_dir/authorized_keys"
      log "Added provided SSH public key to authorized_keys"
    else
      log "Provided SSH public key already present in authorized_keys"
    fi
  fi
}

harden_ssh() {
  log "Hardening SSH configuration"
  local cfg="/etc/ssh/sshd_config"
  cp "$cfg" "${cfg}.bak.$(date +%s)" || true

  # Ensure directives exist or are updated
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/g' "$cfg"
  sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/g' "$cfg"
  sed -i 's/^#\?UsePAM.*/UsePAM yes/g' "$cfg"
  sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/g' "$cfg"
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/g' "$cfg"

  # Allow only the deploy user (optional but recommended)
  if grep -q '^AllowUsers' "$cfg"; then
    sed -i "s/^AllowUsers.*/AllowUsers $DEPLOY_USER/g" "$cfg"
  else
    echo "AllowUsers $DEPLOY_USER" >> "$cfg"
  fi

  systemctl reload ssh || systemctl reload sshd || true

  if [[ "$DISABLE_ROOT_SSH" == "yes" ]]; then
    log "Root SSH login disabled and password auth disabled"
  else
    log "Root SSH login/password auth settings preserved per flag"
  fi
}

configure_firewall() {
  log "Configuring UFW firewall"
  ufw --force reset || true
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow OpenSSH
  ufw allow 80/tcp  # HTTP (reverse proxy / ACME)
  ufw allow 443/tcp # HTTPS
  # Note: Prometheus/Grafana ports can be opened later if exposed publicly
  ufw --force enable
}

configure_fail2ban() {
  log "Configuring Fail2ban"
  systemctl enable fail2ban
  systemctl start fail2ban
}

install_redis() {
  if command -v redis-server >/dev/null 2>&1; then
    log "Redis already installed: $(redis-server --version | awk '{print $3}')"
  else
    log "Installing Redis Server"
    apt-get install -y redis-server
  fi

  # Bind to localhost only for security
  local conf="/etc/redis/redis.conf"
  if [[ -f "$conf" ]]; then
    sed -i 's/^#\?bind .*/bind 127.0.0.1 ::1/g' "$conf" || true
    sed -i 's/^#\?protected-mode .*/protected-mode yes/g' "$conf" || true
    # Optional: set a password if you intend to expose Redis beyond localhost
    # if [[ -n "$REDIS_PASSWORD" ]]; then
    #   if grep -q '^#\?requirepass' "$conf"; then
    #     sed -i "s/^#\?requirepass.*/requirepass $REDIS_PASSWORD/g" "$conf"
    #   else
    #     echo "requirepass $REDIS_PASSWORD" >> "$conf"
    #   fi
    # fi
    systemctl enable redis-server
    systemctl restart redis-server
  fi
}

install_claude_code() {
  log "Attempting to install '${CLAUDE_CODE_NPM_PACKAGE}' globally via npm"
  if npm install -g "${CLAUDE_CODE_NPM_PACKAGE}" >/dev/null 2>&1; then
    log "Installed ${CLAUDE_CODE_NPM_PACKAGE} via npm"
  else
    err "Failed to install ${CLAUDE_CODE_NPM_PACKAGE}. This package name may differ or be unavailable."
    err "If there is a specific CLI, provide its npm package name. As a fallback, you can use the official 'anthropic' npm package or other tooling."
    # Try anthropic as a fallback helper library/CLI
    if npm install -g anthropic >/dev/null 2>&1; then
      log "Installed 'anthropic' npm package globally as a fallback."
    fi
  fi

  # Persist Anthropic key if provided
  if [[ -n "$ANTHROPIC_KEY" ]]; then
    log "Storing Anthropic API key system-wide in /etc/environment (and masking in logs)"
    if grep -q '^ANTHROPIC_API_KEY=' /etc/environment; then
      sed -i "s/^ANTHROPIC_API_KEY=.*/ANTHROPIC_API_KEY=$ANTHROPIC_KEY/g" /etc/environment
    else
      echo "ANTHROPIC_API_KEY=$ANTHROPIC_KEY" >> /etc/environment
    fi
    # Also export for deploy user shell sessions
    local profile_d="/etc/profile.d/anthropic.sh"
    echo 'export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"' > "$profile_d"
    chmod 0644 "$profile_d"
  else
    log "No --anthropic-key provided. You can set it later: echo ANTHROPIC_API_KEY=sk-ant-... >> /etc/environment"
  fi
}

prepare_project_dir() {
  log "Preparing project directory at ${PROJECT_DIR}"
  mkdir -p "$PROJECT_DIR"
  chown -R "$DEPLOY_USER":"$DEPLOY_USER" "$PROJECT_DIR"
  if [[ -z "$ENV_FILE_PATH" ]]; then
    ENV_FILE_PATH="${PROJECT_DIR}/.env"
  fi

  # Drop a placeholder README to indicate next steps
  if [[ ! -f "$PROJECT_DIR/README.md" ]]; then
    cat > "$PROJECT_DIR/README.md" <<'RMD'
# Claude Multi-Agent Trader (Server Prepared)

This directory has been prepared by setup.sh. Next steps:

1. Log in as the deploy user:
   - ssh <deploy-user>@<server-ip>
2. Export ANTHROPIC_API_KEY if not already set in /etc/environment.
3. Proceed with project scaffolding and Docker Compose generation.
RMD
    chown "$DEPLOY_USER":"$DEPLOY_USER" "$PROJECT_DIR/README.md"
  fi
}

print_summary() {
  cat <<SUM

=== Setup Summary ===
- Deploy user:           $DEPLOY_USER
- SSH hardened:          $DISABLE_ROOT_SSH (root login disabled, password auth disabled)
- Node:                  $(node -v 2>/dev/null || echo 'not found')
- npm:                   $(npm -v 2>/dev/null || echo 'not found')
- Docker:                $(docker --version 2>/dev/null || echo 'not found')
- Docker Compose:        $(docker compose version 2>/dev/null || echo 'not found')
- Redis:                 $(redis-server --version 2>/dev/null | awk '{print $3}')
- Firewall (ufw):        $(ufw status | head -n1)
- Fail2ban:              $(systemctl is-active fail2ban || echo 'inactive')
- Project directory:     $PROJECT_DIR
- .env path:             $ENV_FILE_PATH
- Anthropic key set:     $( [[ -n "$ANTHROPIC_KEY" ]] && echo 'yes' || echo 'no' )
- Traefik htpasswd:      $( [[ "$GENERATE_HTPASSWD" == "yes" ]] && echo "generated for user '$BASIC_AUTH_USER'" || echo 'skipped' )

Next steps:
1) Reconnect via SSH as $DEPLOY_USER to ensure Docker group membership is active.
2) Confirm ANTHROPIC_API_KEY is present (source /etc/environment if needed):
     printenv ANTHROPIC_API_KEY
3) Review $ENV_FILE_PATH and set domain/TLS values before docker compose up -d.

Security notes:
- SSH root login disabled. Password auth disabled. Only key-based login is allowed.
- UFW allows SSH (22), HTTP (80), HTTPS (443) by default.

SUM
}

escape_dollars() {
  sed 's/\$/$$/g'
}

generate_htpasswd_if_requested() {
  if [[ "$GENERATE_HTPASSWD" != "yes" ]]; then
    return
  fi
  if ! command -v htpasswd >/dev/null 2>&1; then
    apt-get install -y apache2-utils >/dev/null 2>&1 || true
  fi
  local user="$BASIC_AUTH_USER"
  local pass="$BASIC_AUTH_PASS"
  if [[ -z "$pass" ]]; then
    pass=$(openssl rand -base64 18)
    log "Generated random password for user '$user'"
  fi
  local entry
  entry=$(htpasswd -nbB "$user" "$pass")
  local escaped
  escaped=$(echo "$entry" | escape_dollars)

  # Write/update TRAEFIK_BASIC_AUTH in .env
  touch "$ENV_FILE_PATH"
  if grep -q '^TRAEFIK_BASIC_AUTH=' "$ENV_FILE_PATH"; then
    sed -i "s/^TRAEFIK_BASIC_AUTH=.*/TRAEFIK_BASIC_AUTH=${escaped//\//\\/}/" "$ENV_FILE_PATH"
  else
    echo "TRAEFIK_BASIC_AUTH=$escaped" >> "$ENV_FILE_PATH"
  fi

  log "Traefik basic auth written to $ENV_FILE_PATH (user '$user'). Keep the password secure."
  # Optionally print the password once for the operator
  echo "[setup] Basic auth credentials -> user: $user   password: $pass"
}

main() {
  require_root
  parse_args "$@"
  set_timezone
  apt_baseline
  install_node
  install_docker
  create_deploy_user
  harden_ssh
  configure_firewall
  configure_fail2ban
  install_redis
  install_claude_code
  prepare_project_dir
  generate_htpasswd_if_requested
  print_summary
}

main "$@"
