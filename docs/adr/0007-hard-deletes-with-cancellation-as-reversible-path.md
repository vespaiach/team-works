# ADR-0007: Hard deletes, with cancellation as the reversible path

Status: Accepted — 2026-07-31

## Context

`DELETE` in Postgres, propagated through the WAL, is the path Zero is built for. A `deleted_at` soft-delete column would create a second, competing meaning of "gone" alongside a reversible state that could exist at the domain level instead (data-model.md §4).

## Decision

Deletes are hard everywhere; there is no `deleted_at` column anywhere. The reversible path exists at the domain level instead: issues and projects get `status = 'canceled'` (the members' path); users are never deleted, only deactivated (`deactivated_at`). Admins hard-delete; `deleteProject` is rejected unless the project is already canceled.

## Consequences

- Recovery from an unintended hard delete is a database restore — an accepted cost, which is why the two destructive paths (issue, project) are gated behind role and, for projects, a prior cancellation step (data-model.md §4).
- Every foreign key to `user` is `ON DELETE RESTRICT`, so an attempted user delete fails loudly rather than cascading through the workspace.
- Sub-issues are **promoted**, not cascade-deleted, when a parent issue is deleted (`SET NULL` on `parent_issue_id`) — deleting a parent is a statement about the parent, not a license to destroy the work nested beneath it.
- The client's optimistic run can't reproduce Postgres cascades, so a delete settles in two phases — the target vanishes immediately, cascaded rows follow once replication catches up — handled per-case in the UI rather than treated as a bug (data-model.md §4).

## Alternatives considered

- **`deleted_at` soft-delete column.** Rejected — duplicates the meaning of "gone" that `status = 'canceled'` / `deactivated_at` already cover, and every read path would need a filter Zero's sync model has no clean equivalent for.
- **Single confirmation dialog before permanent project delete.** Rejected — makes the largest irreversible action in the system one click deep with recovery only from backup; the two-step cancel-then-delete gives the UI a natural moment to state what's about to be destroyed.
