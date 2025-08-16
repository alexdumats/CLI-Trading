# mTLS Runbook for Orchestrator Admin

This enables mutual TLS for the /admin/* routes on the Orchestrator via Traefik.

Prerequisites:
- Traefik is configured with providers.file and tls options (already in repo).
- Admin route uses `tls.options=mtls@file`.

Steps
1) Create a private CA
```
mkdir -p secrets/mtls_ca
openssl genrsa -out secrets/mtls_ca/ca.key 4096
openssl req -x509 -new -nodes -key secrets/mtls_ca/ca.key -sha256 -days 3650 -subj "/CN=Trading Ops CA" -out secrets/mtls_ca/ca.pem
```

2) Mount CA into Traefik
- Copy `docker-compose.override.example.yml` to `docker-compose.override.yml`.
- Ensure it mounts `secrets/mtls_ca/ca.pem` to `/etc/traefik/dynamic/mtls/ca.pem`.
- `docker compose up -d traefik`.

3) Issue a client certificate for an operator
```
# Generate key and CSR
openssl genrsa -out operator.key 2048
openssl req -new -key operator.key -subj "/CN=alice@example.com" -out operator.csr

# Sign CSR with CA
openssl x509 -req -in operator.csr -CA secrets/mtls_ca/ca.pem -CAkey secrets/mtls_ca/ca.key -CAcreateserial -out operator.crt -days 730 -sha256

# Create a PFX for browser import (optional)
openssl pkcs12 -export -out operator.p12 -inkey operator.key -in operator.crt -name "Trading Ops"
```

4) Use the client certificate
- curl: `curl https://orch.example.com/admin/pnl/status --cert operator.crt --key operator.key`
- Browser: import `operator.p12` into your user keychain and access admin pages.

5) Rotating CA or clients
- To rotate CA, generate a new CA and update `ca.pem`, then issue new client certs.
- Revoke old clients by removing their certs from distribution and optionally switching to a new CA.

Security notes
- Protect `secrets/mtls_ca/ca.key` carefully. Do NOT commit it.
- Combine mTLS with OAuth and admin token for defense-in-depth (already configured).
