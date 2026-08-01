# ADR-0005: Client-generated UUIDv7 primary keys

Status: Accepted — 2026-07-31

## Context

Zero mutators run optimistically on the client before any server round-trip, so a row's id must exist before the server ever sees it. That rules out server-assigned ids such as `bigserial` (data-model.md §1).

## Decision

Every table's primary key is a `uuid`, generated client-side with the `uuidv7` package.

## Consequences

- `ORDER BY id` means creation order, which is used as the ordering tie-break in [ADR-0004](./0004-fractional-indexing-for-issue-ordering.md) and anywhere else a deterministic secondary sort is needed.
- Sequential inserts land at the right edge of the B-tree — in both Postgres and `zero-cache`'s SQLite replica — rather than scattering across it, unlike random (v4) UUIDs.
- One small added dependency, since `crypto.randomUUID()` only produces v4, which is unordered.

## Alternatives considered

- **Server-assigned `bigserial`/identity columns.** Incompatible with optimistic client-side writes — the id wouldn't exist yet when the client needs to render the row.
- **`crypto.randomUUID()` (UUIDv4).** Client-generatable, but unordered, which would scatter index writes and remove the free `ORDER BY id` creation-order tie-break.
