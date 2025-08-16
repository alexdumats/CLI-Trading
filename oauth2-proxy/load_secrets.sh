#!/bin/sh
# Load secrets from Docker secrets if present and export envs expected by oauth2-proxy
set -e

if [ -f "/run/secrets/oauth2_client_id" ]; then
  export OAUTH2_PROXY_CLIENT_ID="$(cat /run/secrets/oauth2_client_id | tr -d '\r\n')"
fi
if [ -f "/run/secrets/oauth2_client_secret" ]; then
  export OAUTH2_PROXY_CLIENT_SECRET="$(cat /run/secrets/oauth2_client_secret | tr -d '\r\n')"
fi
if [ -f "/run/secrets/oauth2_cookie_secret" ]; then
  export OAUTH2_PROXY_COOKIE_SECRET="$(cat /run/secrets/oauth2_cookie_secret | tr -d '\r\n')"
fi

exec oauth2-proxy
