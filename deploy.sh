#!/bin/bash

# CLI Trading Ansible Deployment Script
# This script helps you deploy the CLI trading application to your Hetzner server

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"

echo "🚀 CLI Trading Deployment Script"
echo "================================"

# Check if Ansible is installed
if ! command -v ansible-playbook &> /dev/null; then
    echo "❌ Ansible is not installed. Please install it first:"
    echo "   brew install ansible"
    exit 1
fi

# Check if inventory file exists
if [ ! -f "$ANSIBLE_DIR/inventory.ini" ]; then
    echo "❌ Inventory file not found at $ANSIBLE_DIR/inventory.ini"
    echo "   Please copy and edit ansible/inventory.ini.example"
    exit 1
fi

# Check if vars file exists
if [ ! -f "$ANSIBLE_DIR/vars.yml" ]; then
    echo "❌ Variables file not found at $ANSIBLE_DIR/vars.yml"
    echo "   Please copy and edit ansible/vars_example.yml"
    exit 1
fi

echo "📋 Configuration Summary"
echo "----------------------"
echo "Inventory file: $ANSIBLE_DIR/inventory.ini"
echo "Variables file: $ANSIBLE_DIR/vars.yml"
echo ""

# Show which server will be targeted
echo "🎯 Target server:"
grep "ansible_host" "$ANSIBLE_DIR/inventory.ini" | head -1
echo ""

# Test connectivity with password
echo "🔍 Testing server connectivity..."
SERVER_IP=$(grep "ansible_host" "$ANSIBLE_DIR/inventory.ini" | head -1 | sed 's/.*ansible_host=\([^ ]*\).*/\1/')

if timeout 10 bash -c "</dev/tcp/$SERVER_IP/22" 2>/dev/null; then
    echo "✅ Server is reachable on port 22"
else
    echo "❌ Cannot reach server on port 22"
    echo "   Please check server IP and ensure SSH service is running"
    exit 1
fi

echo ""
echo "🚀 Starting deployment..."
echo "========================"

# Run the Ansible playbook with password authentication
cd "$SCRIPT_DIR"
ansible-playbook \
    -i ansible/inventory.ini \
    ansible/site.yml \
    -e @ansible/vars.yml \
    --ask-become-pass \
    -c paramiko \
    "$@"

if [ $? -eq 0 ]; then
    echo ""
    echo "🎉 Deployment completed successfully!"
    echo "======================================"
    echo ""
    echo "🔍 Verification steps:"
    echo "1. Check services: ssh root@$SERVER_IP 'cd /opt/cli-trading && docker compose ps'"
    echo "2. Check logs: ssh root@$SERVER_IP 'cd /opt/cli-trading && docker compose logs -f orchestrator'"
    echo "3. Test health: curl -s http://$SERVER_IP:7001/health | jq ."
    echo ""
    echo "📊 Access your services:"
    echo "- Orchestrator: http://$SERVER_IP:7001"
    echo "- Grafana: http://$SERVER_IP:3000 (admin/SecureGrafana2025!)"
    echo "- Prometheus: http://$SERVER_IP:9090"
    echo ""
    echo "🔔 Slack Integration:"
    echo "- Bot Token: Configured"
    echo "- Webhook: Configured"  
    echo "- Test notifications should appear in your Slack channel"
else
    echo ""
    echo "❌ Deployment failed. Check the output above for errors."
    echo "💡 Common issues:"
    echo "   - Incorrect server password"
    echo "   - Network connectivity issues"
    echo "   - Invalid configuration in vars.yml"
    echo "   - Server resource constraints"
fi
