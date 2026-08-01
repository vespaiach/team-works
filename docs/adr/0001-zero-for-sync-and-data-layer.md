# ADR-0001: Zero for sync and the data layer

Status: Accepted — 2026-07-31

## Context

Both v1 views — the Kanban board and the roadmap — are live queries over the same local data (CLAUDE.md, brief §4). The team wanted optimistic writes and cross-client live updates without hand-building websocket plumbing, cache invalidation per mutation, and a separate realtime layer on top of a REST API.

## Decision

Zero (Rocicorp) is the data layer, not a realtime add-on. `zero-cache` replicates the syncable subset of Postgres into a SQLite replica via logical replication and bridges it to clients. Every component reads with `useQuery`/ZQL against a local store holding the whole workspace. Writes go through custom mutators — optimistic on the client, authoritative on the server via Drizzle. There are no per-screen API endpoints and no TanStack Query.

## Consequences

- Sync is foundational, not a later phase — there is no separate "add realtime" step in the build order (brief §6).
- `zero-cache` runs as a Docker container on the same VPS, which requires `wal_level=logical` and sets the Postgres 15+ floor (data-model.md §3, §12).
- Postgres cascades (e.g. deleting a project) can't be reproduced by the client's optimistic run, so a delete settles in two phases — target gone at once, cascaded rows a moment later (data-model.md §4).
- No offline writes: reads of synced data work offline, writes are rejected when disconnected (brief §5, §7 decision 8).
- `zero-cache` holds the secret that verifies session JWTs and a full replica of the workspace, so compromising that container is both a total read compromise and a full auth compromise — weighed and accepted (auth.md §2).
- The team's dataset sits far inside Zero's ~100GB comfort range; this pairing wouldn't scale unmodified to a much larger deployment.

## Alternatives considered

- **REST API + TanStack Query with polling or manual WebSockets.** Well-understood, but requires hand-building optimistic-update reconciliation and cache invalidation per mutation, plus a bespoke realtime layer for the board and roadmap — exactly what Zero provides natively.
- **A realtime BaaS (Supabase Realtime, Firebase).** Would mean adopting their hosting and auth model, in tension with the single self-hosted VPS and the hand-written-auth decision ([ADR-0009](./0009-hand-written-auth.md)).
