# Team Works

A small, self-hosted work tracker for a single team of under 20 people. Linear-inspired, but milestone- and roadmap-driven rather than sprint-driven, and local-first — the UI reads and writes a local copy of the data and syncs in the background.

Work lives as issues; issues roll up into projects; projects carry milestones. Two views: a Kanban board for working, a timeline for planning.

## Status

**Design stage — not yet implemented.** Everything under `src/` is placeholder scaffolder output. The specs in `docs/` are the substance of this repo.

- [docs/team-works-concept-brief.md](docs/team-works-concept-brief.md) — scope, stack, deployment, build order
- [docs/permissions.md](docs/permissions.md) — authorization model
- [docs/data-model.md](docs/data-model.md) — schema, sync boundary, invariants
- [docs/auth.md](docs/auth.md) — invites, magic links, sessions, environment contract
- [docs/local-dev.md](docs/local-dev.md) — local setup: Postgres, `zero-cache`, migrations, seed data
- [docs/ui-spec.md](docs/ui-spec.md) — screens, React Aria components, design tokens, board semantics
- [docs/notifications.md](docs/notifications.md) — triggers, mention parsing, dedup, email outbox and retries
- [docs/HANDOFF.md](docs/HANDOFF.md) — remaining documentation backlog

## Planned stack

Next.js (App Router) + React Aria Components · [Zero](https://zero.rocicorp.dev/) for sync and optimistic mutations · PostgreSQL 15+ with logical replication · Drizzle · hand-written magic-link invite auth · dnd-kit for the board · Frappe Gantt for the roadmap. Self-hosted on a single VPS.

None of it is installed yet; adding it is the first build step.

## Development

```bash
npm install
npm run dev
```

Runs on http://localhost:3000. Also available: `npm run build`, `npm run lint`. There is no test runner configured yet.
