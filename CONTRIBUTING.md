# Contributing

Thanks for contributing to the Claude Multi-Agent Trading System.

## Workflow
- Work on feature branches and open PRs to `main`.
- Keep commits small and scoped; use conventional commits if possible (feat:, fix:, chore:).
- Always start from a clean working tree (no uncommitted changes) before large edits.

## Local checks
- Use Node 20.
- Install dev tools at repo root: `npm ci`.
- Pre-commit hooks will run Prettier on staged files.
- Run `docker compose build` and `docker compose up -d` to validate containers.
- Run integration test: `docker compose run --rm tests` (or in CI).

## Code style
- Formatting: Prettier (configured in `.prettierrc.json`).
- Keep `/health` and `/metrics` endpoints stable.
- Prefer small, targeted changes and submit diffs for review.

## Security & secrets
- Never commit secrets. Use `.env` and secret stores.
- Do not expose new ports or services publicly without review.

## PR checklist
- [ ] Unit/integration tests updated if applicable
- [ ] `docker compose build` succeeds
- [ ] `/health` for affected services is green
- [ ] Docs/README updated if needed
