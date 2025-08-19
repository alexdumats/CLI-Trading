# Slack Integration Setup Guide

This guide helps you set up Slack integration for your CLI Trading application.

## Prerequisites

- Slack workspace where you have admin permissions
- Ability to create Slack apps

## Step 1: Create a Slack App

1. Go to https://api.slack.com/apps
2. Click "Create New App"
3. Choose "From scratch"
4. Enter app name: "CLI Trading Bot"
5. Select your workspace
6. Click "Create App"

## Step 2: Configure Bot Permissions

1. In your app settings, go to "OAuth & Permissions" in the sidebar
2. Scroll down to "Scopes" section
3. Under "Bot Token Scopes", add these permissions:
   - `chat:write` - Send messages
   - `chat:write.public` - Send messages to channels the app isn't in
   - `channels:read` - View basic information about public channels
   - `groups:read` - View basic information about private channels
   - `im:read` - View basic information about direct messages
   - `mpim:read` - View basic information about group direct messages

## Step 3: Install App to Workspace

1. Scroll up to "OAuth Tokens for Your Workspace"
2. Click "Install to Workspace"
3. Review permissions and click "Allow"
4. Copy the "Bot User OAuth Token" (starts with `xoxb-`)
   - This is your `slack_bot_token` for the vars.yml file

## Step 4: Get Signing Secret

1. Go to "Basic Information" in the sidebar
2. Scroll down to "App Credentials"
3. Copy the "Signing Secret"
   - This is your `slack_signing_secret` for the vars.yml file

## Step 5: Create Incoming Webhook (Optional but Recommended)

1. Go to "Incoming Webhooks" in the sidebar
2. Toggle "Activate Incoming Webhooks" to On
3. Click "Add New Webhook to Workspace"
4. Choose the channel where you want notifications
5. Click "Allow"
6. Copy the webhook URL
   - This is your `slack_webhook_url` for the vars.yml file

## Step 6: Update Your vars.yml File

Update the following values in `ansible/vars.yml`:

```yaml
# Slack configuration
slack_bot_token: 'xoxb-your-actual-bot-token-here'
slack_signing_secret: 'your-actual-signing-secret-here'
slack_webhook_url: 'https://hooks.slack.com/services/T.../B.../...'

# Optional: Additional webhooks for different log levels
slack_webhook_url_info: ''
slack_webhook_url_warning: ''
slack_webhook_url_critical: ''
```

## Step 7: Test Your Configuration

After deployment, you can test Slack integration by:

1. Checking the application logs for Slack connection status
2. Triggering a test notification through the application
3. Verifying messages appear in your designated Slack channel

## Troubleshooting

### Common Issues:

1. **"invalid_auth" error**: Check that your bot token is correct and starts with `xoxb-`
2. **"channel_not_found" error**: Ensure the bot is added to the target channel
3. **Webhook not working**: Verify the webhook URL is complete and correct

### Adding Bot to Channels:

To receive notifications in specific channels:

1. Go to the channel in Slack
2. Type `/invite @CLI Trading Bot`
3. The bot will now be able to send messages to that channel

## Security Notes

- Keep your tokens secure and never commit them to version control
- The Ansible playbook stores tokens in `/opt/cli-trading/secrets/` on the server
- Tokens are mounted into Docker containers as secrets, not environment variables
- Regularly rotate your tokens if security is compromised
