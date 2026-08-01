# ADR-0003: Workspace-wide reads, per-project writes

Status: Accepted — 2026-07-31

## Context

The original concept brief made project membership a visibility wall: you'd only see projects you belonged to. During design of [permissions.md](../permissions.md), this was reversed.

## Decision

Reads are workspace-wide — every user reads every project. `ProjectMember` is a **write** boundary only. The single exception is `Notification`, scoped to its owner (permissions.md §1, §4).

## Consequences

- No confidential projects in v1 — every user can read every project, including one about a reorganization, a departure, or a legal matter. Accepted as a limitation for a team under twenty, not an oversight (permissions.md §1).
- Avoids three problems a visibility wall creates and each would need solving separately: a member removed from a project would otherwise lose sight of their own assigned issues; an @mention would need to be restricted to co-members; and rows would need to disappear from a client mid-session on removal (permissions.md §1).
- Zero's read rules become near-trivial: the whole syncable dataset goes to every client, with the one `Notification` exception. Sync scope for everything else is fixed one layer lower, by the Postgres publication (data-model.md §3), not by a Zero read rule (permissions.md §4).
- If confidential projects are ever needed, `isMember` is already the right hook, but the sync scope in permissions.md §4 would need revisiting.

## Alternatives considered

- **Visibility wall (original brief).** Reads scoped by membership. Rejected: reintroduces the three problems above and needs cleanup logic (hiding rows on removal, restricting mentions) that the flat model avoids entirely.
- **Per-project confidentiality flag from day one.** Deferred as unneeded scope for a team this size; the `isMember` hook is preserved so it can be added later without a redesign.
