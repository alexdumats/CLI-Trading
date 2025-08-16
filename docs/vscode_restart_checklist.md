# VS Code Restart Checklist

1) Ensure a clean working tree
- `git status` should be clean. Stash or commit any local changes.
- `git fetch --all` and update your branch.

2) Rehydrate environment
- `npm ci` at repo root (sets up Prettier, husky, lint-staged).
- `docker compose build` then `docker compose up -d`.
- Verify `/health` on orchestrator and others.

3) Provide context to assistants
- Share `docker-compose.yml`, `.env.example`, and any files you want changed.
- Ask for a plan + diffs before changes are made.

4) Run checks after changes
- `npm run format:check`
- `docker compose build` (target changed services if possible)
- `docker compose up -d`
- `docker compose run --rm tests`

5) Rollback if needed
- `git restore .` and `git clean -fd` to discard unintended edits.
- Re-run the above steps and request a smaller, safer change plan.
