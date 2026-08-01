# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

Team Works is a self-hosted, Linear-inspired work tracker for a single team of under 20 people. **The design is well advanced; the implementation has not started.** Everything under `src/` is untouched scaffolder output (a placeholder homepage, three generic UI components, a stub `db.ts`, a health route). None of the architecture below exists in code yet, and `README.md` still describes the project as generator output.

The documents in `docs/` are the real content of this repo and the source of truth for the build:

- [docs/team-works-concept-brief.md](docs/team-works-concept-brief.md) — scope, stack, deployment, build order. Sketches the entities; the other two are the authority on their details.
- [docs/permissions.md](docs/permissions.md) — authorization: roles, the permission matrix, sync scope, per-mutator write rules.
- [docs/data-model.md](docs/data-model.md) — schema: the authority on the Drizzle schema, the Postgres publication defining Zero's sync set, and the Zero client schema. Requires **PostgreSQL 15+** (column lists in publications and column-scoped `ON DELETE SET NULL` are both load-bearing).
- [docs/auth.md](docs/auth.md) — authentication: invites, magic links, sessions and refresh rotation, the token `zero-cache` verifies, deactivation and revocation, and the environment contract. Owns `invite`, `login_token` and `session`, all outside the publication.
- [docs/HANDOFF.md](docs/HANDOFF.md) — the remaining doc backlog in priority order (local-dev, ui-spec, notifications, attachments, roadmap-view, deployment, ADRs, state-machines, testing, non-functional). Several specs above defer open questions to docs that do not exist yet; HANDOFF names the owner for each. It is meant to be deleted once that backlog is done.

All four approved docs are dated 2026-07-31 and have been reconciled with each other — each ends with a "changes this spec requires elsewhere" section that was applied. They record decisions with their reasoning, so a change that contradicts one should be raised rather than made silently, and reconciled across all four in the same change.

## Commands

```bash
npm run dev      # Next.js dev server on :3000 (prefer preview_start with the "team-works-dev" config in .claude/launch.json)
npm run build
npm run lint     # next lint
```

There is no test runner configured yet — adding it is part of build step 1. [docs/testing.md](docs/testing.md) is the authority: Vitest for unit predicate tests and integration tests against a real `team_works_test` Postgres database, Playwright for a narrow E2E layer that runs against a real `zero-cache`. Will be `npm test` / `npm run test:unit` / `test:integration` / `test:e2e`.

Three verifications are assigned to build step 1 and each already has its fallback decided: how Zero maps Postgres `date` (data-model.md §11), whether the self-referential composite FK survives a cascading project delete (§8 there), and whether Zero re-invokes its `auth` callback on token rejection (auth.md §5).

## Planned architecture

None of this is installed — `package.json` has only Next 14, React and Tailwind. Adding it is part of build step 1: `drizzle-orm`, `drizzle-kit`, `pg`, `@rocicorp/zero`, `uuidv7`, `fractional-indexing`, plus `react-aria-components`, `@dnd-kit/core`, `frappe-gantt`, `jose` + `nodemailer` for auth, and `vitest` + `@playwright/test` for testing (docs/testing.md). **Not `next-auth`** — authentication is hand-written.

- **Next.js App Router + React**, UI on **Adobe React Aria Components**, responsive from one codebase. `dnd-kit` for the board; `frappe-gantt` (core package, wrapped in a thin React component) for the roadmap.
- **Zero (Rocicorp)** is the data layer, not a realtime add-on. Components read with `useQuery`/ZQL against a local store holding the whole workspace; writes go through custom mutators that run optimistically on the client and authoritatively on the server. There are no per-screen API endpoints and no TanStack Query. `zero-cache` runs as a Docker container on the same VPS, replicating from Postgres via logical replication.
- **PostgreSQL + Drizzle** (`wal_level=logical`). Drizzle is server-side only, in the mutators.
- **Hand-written auth** (no Auth.js), invite-only email magic links. A 15-minute HS256 JWT carrying `sub` and `role` is both the browser's session credential and the token `zero-cache` verifies; a rotating refresh token in a `session` row renews it. Membership is *not* in the token — it resolves server-side per mutation. See [docs/auth.md](docs/auth.md).
- Attachments go to **local disk on the VPS** via a normal API route; only metadata lives in Postgres.

Hierarchy: Issue (+ one level of sub-issues) → Project (+ milestones) → Roadmap. Two views only — Kanban board (working) and timeline (planning) — both live queries over the same local data.

`src/lib/db.ts` and `src/types/index.ts` are generator output whose `User` shape is unrelated to the real schema; data-model.md §12 says to delete rather than adapt them. `.env.example` is replaced wholesale by auth.md §10's contract — the placeholder `SECRET_KEY` is deleted, not renamed.

## The permission model

The part most likely to be got wrong, so worth holding in mind on any feature:

- **Reads are workspace-wide; writes are per-project.** Every authenticated client syncs the entire workspace. `ProjectMember` is a write boundary, not a visibility one. The single exception is `Notification`, scoped to its owner — the only read rule in the system.
- Two predicates cover everything: `isAdmin(actor)` and `isMember(actor, membership, projectId)` — and `isMember` returns true for admins, so no downstream rule needs its own admin branch. Authorship is the only other check, and it applies to comments and attachments and nothing else.
- All of it lives in `src/lib/permissions.ts` (not yet written) as **pure functions over already-loaded data** — no queries, no framework imports — so the same code runs in the server mutators (enforcement) and in the client (disabling controls, and keeping optimistic mutations from flashing a state the server will reject). The server is authoritative; never the reverse.
- Zero's read rules deliberately do **not** consume that module. Sync scope and the permission matrix are independent.
- A mutator taking an issue or comment id derives the project for its `isMember` check from the stored row, **never** from a client-supplied `project_id`.
- **The token establishes identity; the database establishes authority.** `requireUser()` verifies the JWT and returns claims that may be 15 minutes stale — good enough for rendering, never for a decision. Every server mutator calls `loadActor()`, which re-reads `role` and `deactivated_at` from Postgres, and *that* is what the predicates receive (auth.md §6). This is why a demotion or deactivation stops writes at once while the UI catches up later.
- Because losing access hides nothing, controls the user cannot use must render disabled with a reason, not as dead buttons or a "no access" empty state. An assigned non-member is a reachable, real state (permissions.md §7).
- Members cancel (`status = 'canceled'`); admins hard-delete. Deleting a project is rejected unless it is already canceled.

data-model.md §9 lists all eight invariants with their enforcement point. Beyond "every issue belongs to a project" and "an issue cannot change project", note that same-project parentage and milestones are enforced by **composite foreign keys**, not mutator checks, and that nesting is capped at one level — a sub-issue cannot have sub-issues.

## Schema mechanics worth knowing before writing any of it

These are decided, non-obvious, and easy to violate by accident:

- **Ids are client-generated UUIDv7** (`uuidv7` package). Optimistic mutators need the id before any round-trip, and time-ordering makes `ORDER BY id` mean creation order — which is the tie-break below.
- **`sort_order` is a base-62 fractional index** (`fractional-indexing`), `text COLLATE "C"`, one key per issue **project-wide** rather than per board column, so every re-grouping has a defined order. A drop writes exactly one row. Keys can tie; that is not an error, so **every ordered query sorts by `(sort_order, id)`**.
- **Issues are addressed `WEB-142`** — immutable `project.key` plus per-project `issue.number` from an `issue_counter` table that sits *outside* the publication. Numbers are monotonic and never reused, so the client's optimistic `max(number) + 1` guess is sometimes wrong and gets corrected on sync.
- **Deletes are hard.** There is no `deleted_at` anywhere; the reversible path is `status = 'canceled'`. Users are never deleted, only deactivated — every FK to `user` is `ON DELETE RESTRICT`.
- **The publication is the sync boundary, physically.** `user` is replicated with a six-column list, so a column added later cannot leak to clients without editing the publication. Changing the publication is a migration that may force a `zero-cache` replica reset.
- **`updated_at` is maintained by mutators, not a trigger.** Compose the `touched(fields)` helper rather than writing the column by hand; omitting it fails silently.
- Enums are `text` + `CHECK`, not `pgEnum` (cheaper migrations). Calendar dates are `date`, not `timestamptz` — though how the pinned Zero version maps `date` is an open item to resolve in build step 1, with the fallback already decided (data-model.md §11).
- **Auth tokens are stored as SHA-256 digests, never raw**, and verification is a lookup by digest — so nothing in the codebase compares two secrets and nothing needs `timingSafeEqual`. `AUTH_SECRET` and `ZERO_AUTH_SECRET` are one secret under two names, because two processes read it.

## Conventions

- `@/*` maps to `./src/*`; TypeScript is strict. Tables and columns are `snake_case` and singular.
- GitHub issues use the templates in `.github/ISSUE_TEMPLATE/` — feature, bug, UI design, DevOps, and sub-task, each with its own title prefix and label.
- Commit messages are conventional-ish and lowercase (`docs: add permissions spec`). Work happens on branches off `main`.
