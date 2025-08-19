# 🚀 CLI Trading Deployment Guide

Your Ansible deployment is ready! Follow these steps to deploy your trading application to your Hetzner server.

## 📋 Configuration Summary

✅ **Server**: 91.99.103.119  
✅ **User**: root  
✅ **Slack Bot Token**: Configured  
✅ **Slack Signing Secret**: Configured  
✅ **Slack Webhook**: Configured  
⚠️ **Repository URL**: Please update if different from placeholder

## 🔧 Before You Deploy

### 1. Update Repository URL (if needed)

Edit `ansible/vars.yml` and update the `repo_url` field with your actual GitHub repository URL:

```yaml
repo_url: 'https://github.com/YOUR_ACTUAL_USERNAME/CLI-Trading.git'
```

### 2. Set up SSH Key Authentication

Run the SSH setup script (you'll need the server password: `CQGT8hcWLZCV8G`):

```bash
./setup-ssh.sh
```

## 🚀 Deploy Your Application

Once SSH keys are set up, deploy with:

```bash
./deploy.sh
```

The deployment script will:

- ✅ Install Docker on your server
- ✅ Clone your repository to `/opt/cli-trading`
- ✅ Create secure secrets files
- ✅ Build and start all containers
- ✅ Configure Traefik reverse proxy
- ✅ Set up monitoring with Grafana and Prometheus

## 🔍 Verify Deployment

After deployment, verify everything is working:

### Check Services

```bash
ssh root@91.99.103.119 "cd /opt/cli-trading && docker compose ps"
```

### Test Health Endpoint

```bash
curl -s http://91.99.103.119:7001/health | jq .
```

### View Logs

```bash
ssh root@91.99.103.119 "cd /opt/cli-trading && docker compose logs -f orchestrator"
```

## 🌐 Access Your Services

After successful deployment, access your services at:

- **📊 Trading Orchestrator**: http://91.99.103.119:7001
- **📈 Grafana Dashboard**: http://91.99.103.119:3000
  - Username: `admin`
  - Password: `SecureGrafana2025!`
- **🔍 Prometheus**: http://91.99.103.119:9090
- **🔧 Traefik Dashboard**: http://91.99.103.119:8080

## 🔧 Configuration Details

### Secrets Location

All sensitive data is stored in `/opt/cli-trading/secrets/` on the server:

- `admin_token`
- `postgres_password`
- `slack_bot_token`
- `slack_signing_secret`
- `slack_webhook_url`

### Environment Variables

The deployment creates a production `.env` file with:

- Database: PostgreSQL with secure password
- Redis: For caching and pub/sub
- Slack: Full integration configured
- Monitoring: Grafana + Prometheus

## 🔄 Updates and Maintenance

### Deploy Updates

To deploy code updates, simply re-run:

```bash
./deploy.sh
```

### View Running Services

```bash
ssh root@91.99.103.119 "cd /opt/cli-trading && docker compose ps"
```

### Restart Services

```bash
ssh root@91.99.103.119 "cd /opt/cli-trading && docker compose restart"
```

### View All Logs

```bash
ssh root@91.99.103.119 "cd /opt/cli-trading && docker compose logs"
```

## 🛡️ Security Notes

- SSH key authentication is configured (more secure than passwords)
- Secrets are stored as Docker secrets, not environment variables
- Database and admin tokens use strong passwords
- Services are accessible via specific ports only

## 🚨 Troubleshooting

### SSH Issues

If SSH key setup fails:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@91.99.103.119
```

### Deployment Fails

Check Ansible output for specific errors. Common issues:

- SSH connectivity problems
- Docker installation issues
- Git repository access problems

### Services Not Starting

Check logs for specific services:

```bash
ssh root@91.99.103.119 "cd /opt/cli-trading && docker compose logs SERVICE_NAME"
```

### Slack Not Working

Verify tokens in `/opt/cli-trading/secrets/` on the server and check application logs.

---

**Ready to deploy? Run: `./setup-ssh.sh` then `./deploy.sh`**
