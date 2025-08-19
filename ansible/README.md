# Ansible deployment for CLI-Trading on a Hetzner server

This playbook provisions Docker and deploys the stack on a fresh Debian/Ubuntu box. It keeps secrets out of git and writes them to `secrets/` on the server.

Prerequisites

- Control machine with Ansible >= 2.12
- SSH access to the server (prefer SSH keys, avoid password auth)
- A domain (optional but recommended) pointing A-records to the server IP for Traefik TLS

Files

- `inventory.ini.example` — sample inventory
- `vars_example.yml` — sample variables file (fill in and pass via `-e @vars.yml`)
- `site.yml` — main play
- `roles/docker` — installs Docker CE and compose plugin
- `roles/cli_trading_deploy` — clones repo, renders .env and secrets, runs `docker compose up -d`

Quick start

1. Copy and edit inventory and vars
   - cp ansible/inventory.ini.example ansible/inventory.ini
   - cp ansible/vars_example.yml ansible/vars.yml
   - Edit `ansible/inventory.ini` and `ansible/vars.yml` with your host and secrets

2. Run the playbook
   - ansible-playbook -i ansible/inventory.ini ansible/site.yml -e @ansible/vars.yml --ask-become-pass

3. Verify
   - ssh <host> "cd /opt/cli-trading && docker compose ps"
   - If using domains: curl -s https://orch.yourdomain.com/health | jq .

Notes

- Secrets are written under `/opt/cli-trading/secrets/` and mounted via Docker secrets. They are not committed to git.
- If you don’t want OAuth locally/now, set `enable_oauth: false` — the play will scale `oauth2-proxy=0`.
- To update to a new version, re-run the play. It will `git pull` the repo and `docker compose up -d` again.
