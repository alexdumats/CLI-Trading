#!/bin/bash

echo "🔑 Installing SSH public key on server..."

# Read the public key
PUBLIC_KEY=$(cat ~/.ssh/id_ed25519.pub)

# Create expect script on the fly
cat > /tmp/install_key.exp << EOF
#!/usr/bin/expect -f

set timeout 30
set host "91.99.103.119"
set user "root"
set password "CQGT8hcWLZCV8G"

spawn ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no \$user@\$host "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$PUBLIC_KEY' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo 'SSH key installed successfully'"

expect {
    "*password*:" {
        send "\$password\r"
        expect {
            "SSH key installed successfully" {
                puts "✅ SSH key successfully installed!"
                exit 0
            }
            timeout {
                puts "❌ Timeout during key installation"
                exit 1
            }
        }
    }
    "Permission denied" {
        puts "❌ Permission denied"
        exit 1
    }
    timeout {
        puts "❌ Connection timeout"
        exit 1
    }
}
EOF

chmod +x /tmp/install_key.exp
/tmp/install_key.exp

if [ $? -eq 0 ]; then
    echo ""
    echo "🧪 Testing SSH key authentication..."
    if ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no root@91.99.103.119 "echo 'SSH key authentication successful!'" 2>/dev/null; then
        echo "✅ SSH key authentication is working!"
        echo ""
        echo "🚀 Ready for deployment! You can now run:"
        echo "   ./deploy.sh"
    else
        echo "❌ SSH key authentication test failed"
    fi
else
    echo "❌ Failed to install SSH key"
fi

# Clean up
rm -f /tmp/install_key.exp
