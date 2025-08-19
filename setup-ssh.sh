#!/bin/bash

echo "🔑 Setting up SSH key authentication for your Hetzner server"
echo "============================================================"
echo ""
echo "This script will copy your SSH public key to the server."
echo "You'll need to enter the server password: CQGT8hcWLZCV8G"
echo ""
echo "Server: root@91.99.103.119"
echo "Key: ~/.ssh/id_ed25519.pub"
echo ""

# Copy SSH key to server
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@91.99.103.119

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ SSH key successfully installed!"
    echo ""
    echo "Testing SSH connection without password..."
    if ssh -o ConnectTimeout=10 -o BatchMode=yes root@91.99.103.119 "echo 'SSH key authentication working!'" 2>/dev/null; then
        echo "✅ SSH key authentication is working!"
        echo ""
        echo "🚀 You can now run the deployment:"
        echo "   ./deploy.sh"
    else
        echo "❌ SSH key authentication test failed"
        echo "   You may need to try again or check server configuration"
    fi
else
    echo "❌ Failed to copy SSH key"
    echo "   Please check the password and try again"
fi
