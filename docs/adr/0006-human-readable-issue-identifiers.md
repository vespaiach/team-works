# ADR-0006: Human-readable issue identifiers (`WEB-142`)

Status: Accepted — 2026-07-31

## Context

Issues need a stable, shareable reference for URLs, links, and conversation — distinct from the opaque UUIDv7 primary key ([ADR-0005](./0005-client-generated-uuidv7-primary-keys.md)).

## Decision

Issues are addressed as `WEB-142`: an immutable per-project `key` plus a monotonic per-project `number`, drawn from an `issue_counter` table kept outside the sync publication (data-model.md §6). `project.key` is set at creation and never editable, and an issue can never change project (permissions.md §6.3), so `WEB-142` identifies the same issue forever.

## Consequences

- The counter lives on its own table, not as a column on `project` — a column on `project` would dirty (and replicate) the project row on every issue creation, noise proportional to the busiest activity in the app.
- The server increments it via `UPDATE ... RETURNING` inside the same transaction as the issue insert, taking a row lock so concurrent creates in one project can't collide.
- The client's optimistic guess (`max(number) + 1` over its local replica) is sometimes wrong — after a deletion, or under concurrent creates — and is corrected on sync; the UI must not treat a freshly created issue's number as stable until the write is confirmed.
- `UNIQUE (project_id, number)` is the backstop that turns any bug in the above into a loud failure instead of two issues silently sharing an identifier.

## Alternatives considered

- **UUID-only addressing.** Simpler schema, but unusable in conversation, URLs, or search the way `WEB-142` is.
- **Global auto-increment issue number, no per-project key.** Loses the per-project semantics teams expect from a Linear-style tracker, and turns a single counter into a write hotspot across every project.
- **Editable `project.key`.** Rejected — would break every existing `WEB-142` reference, and a redirect table for retired keys is scope the brief doesn't have.
