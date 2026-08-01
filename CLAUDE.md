# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

Team Works is a self-hosted, Linear-inspired work tracker for a single team of under 20 people. **Design is done; implementation hasn't started.** `src/` is untouched scaffolder output — treat it as empty. `docs/` is the source of truth:

- [docs/team-works-concept-brief.md](docs/team-works-concept-brief.md) — scope, stack, deployment, build order
- [docs/permissions.md](docs/permissions.md) — roles, permission matrix, sync scope, write rules
- [docs/data-model.md](docs/data-model.md) — Drizzle schema, Postgres publication, Zero client schema (requires **PostgreSQL 15+**)
- [docs/auth.md](docs/auth.md) — invites, magic links, sessions, tokens, deactivation
- [docs/HANDOFF.md](docs/HANDOFF.md) — remaining doc backlog and owners; delete once done

All four are dated 2026-07-31 and reconciled with each other. A change that contradicts one should be raised, not made silently, and reconciled across all four.

## Commands

```bash
npm run dev      # Next.js dev server on :3000 (prefer preview_start with "team-works-dev" in .claude/launch.json)
npm run build
npm run lint     # Biome lint (biome.json), recommended rules; docs/prototype/ is excluded
npm run format   # Biome format --write
npm run check    # Biome check --write (format + lint + organize imports, all auto-fixed)
```

No test runner yet — adding one (Vitest + Playwright, per [docs/testing.md](docs/testing.md)) is part of build step 1.

Build step 1 also resolves three open verifications, each with a decided fallback: Zero's mapping of Postgres `date` (data-model.md §11), whether a self-referential composite FK survives cascading project delete (§8), and whether Zero re-invokes `auth` on token rejection (auth.md §5).

## Architecture

Next.js App Router + React, UI on React Aria Components (`dnd-kit` for the board, `frappe-gantt` for the roadmap). **Zero (Rocicorp)** is the data layer — `useQuery`/ZQL against a local full-workspace store, writes through optimistic client mutators backed by authoritative server mutators; no per-screen API routes. Postgres + Drizzle (server-side only, `wal_level=logical`), synced to `zero-cache` via logical replication. **Hand-written auth** (not next-auth/Auth.js) — see [docs/auth.md](docs/auth.md). Attachments go to local disk via an API route; only metadata lives in Postgres.

Hierarchy: Issue (+ one level of sub-issues) → Project (+ milestones) → Roadmap. Two views: Kanban board and timeline.

None of this is installed yet (`package.json` has only Next 14, React, Tailwind) — installing it is build step 1. `src/lib/db.ts` and `src/types/index.ts` should be deleted, not adapted (data-model.md §12).

## Permission model

Easy to get wrong — worth holding in mind on any feature. Full detail in [docs/permissions.md](docs/permissions.md); the essentials:

- **Reads are workspace-wide; writes are per-project.** `ProjectMember` is a write boundary, not a visibility one. `Notification` (scoped to its owner) is the only read rule in the system.
- Two predicates cover everything: `isAdmin(actor)` and `isMember(actor, membership, projectId)` (true for admins too) — pure functions in `src/lib/permissions.ts` (not yet written), used by both server mutators and client UI.
- **The token establishes identity; the database establishes authority.** `requireUser()` gives possibly-stale JWT claims; every mutator calls `loadActor()` to re-read `role`/`deactivated_at` from Postgres before checking permissions (auth.md §6).
- A mutator derives the project from the stored row, never from a client-supplied `project_id`.
- Controls the user can't use render disabled with a reason, never hidden — an assigned non-member is a real, reachable state.
- Members cancel projects (`status = 'canceled'`); only admins hard-delete, and only once canceled.

## Schema mechanics

Decided, non-obvious, easy to violate — full detail in [docs/data-model.md](docs/data-model.md):

- Ids are **client-generated UUIDv7**; `ORDER BY id` means creation order.
- `sort_order` is a **base-62 fractional index**, project-wide (not per column); ties are expected, so sort by `(sort_order, id)`.
- Issues are addressed `WEB-142` via `project.key` + `issue.number` (a counter outside the publication) — optimistic client numbering can be wrong and gets corrected on sync.
- **Deletes are hard**, no `deleted_at`; the reversible path is `status = 'canceled'`. Users are deactivated, never deleted (`ON DELETE RESTRICT` everywhere).
- `updated_at` is set by mutators via the `touched(fields)` helper, not a trigger or by hand.
- Enums are `text` + `CHECK`, not `pgEnum`. Dates are `date`, not `timestamptz`.
- Auth tokens are stored as **SHA-256 digests**, never raw. `AUTH_SECRET`/`ZERO_AUTH_SECRET` are the same secret under two names.

## Development

**Never commit directly to `main`.** Create a feature branch for every change, including docs — `git checkout -b <branch> main` before touching files.

**Open a pull request when a change is done.** Don't merge to `main` yourself — push the branch and open a PR for review.

## Conventions

- `@/*` maps to `./src/*`; TypeScript strict. Tables/columns are `snake_case`, singular.
- GitHub issues use `.github/ISSUE_TEMPLATE/` templates (feature, bug, UI design, DevOps, sub-task).
- Commit messages are conventional-ish, lowercase (`docs: add permissions spec`).
