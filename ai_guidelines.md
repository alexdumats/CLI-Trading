# AI Collaboration Guidelines

These rules are for any AI assistant working in this repository.

1) Always inspect before you edit
- Open files to understand current state. Don’t assume.
- Propose a plan with the exact files and changes.
- Apply changes as precise diffs. Avoid bulk search-and-replace across the repo.

2) Keep changes minimal and reversible
- Limit edits to the files necessary for the task.
- Do not modify lockfiles, secrets, or CI unless explicitly requested.
- Never remove configuration comments or docs without approval.

3) Validate locally
- After changes, run: `npm run format:check`, `docker compose build`, `docker compose up -d`.
- Verify `/health` for touched services and `/metrics` integrity.
- If tests exist for the area, run them.

4) Be explicit about risky operations
- Schema changes, public exposure via Traefik, or security-sensitive changes must be called out in the plan.
- Don’t change `.env.example` defaults without explicit instruction.

5) Logging and observability
- Maintain structured logging (JSON) and keep tracing headers.
- Avoid adding noisy logs; prefer contextual logs with requestId/traceId.

6) Documentation
- Update README/Docs for new endpoints, env vars, or ops flows.

7) Safety net
- If detected regressions or broken builds, revert your edits and propose an alternative.
