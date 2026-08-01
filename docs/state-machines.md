# Team Works — state machines

_State machine spec for v1. Companion to [data-model.md](./data-model.md), [permissions.md](./permissions.md) and [ui-spec.md](./ui-spec.md). Status: approved 2026-07-31._

data-model.md §12 parked two questions for this document: what issue and project status transitions are legal, and two side effects — does closing a parent issue close its sub-issues, and do all-done issues complete a milestone. Both resolve the same way: **nothing is automatic.** This document fixes the transition rules (there aren't any — every status is reachable from every other), who may make each change and through which mutator, and states plainly what does *not* cascade, so a future reader doesn't have to reconstruct the absence of a rule from silence.

---

## 1. Issue status

```
backlog · todo · in_progress · done · canceled
```

`CHECK (status IN (...))`, default `'backlog'` (data-model.md §7).

All 5 × 5 transitions are legal, including a no-op write back to the same value and moving out of `done` or `canceled` to any earlier state. There is no terminal state and no forbidden move. This matches the board, which always shows all five columns and lets any card drop into any of them (ui-spec.md §5) — the state machine is exactly as permissive as the UI already implies.

Guardrails were considered and rejected: blocking a `backlog → done` jump, or requiring confirmation to cancel, would restrict a single-team internal tool for a benefit nobody has asked for, in exchange for a new mutator-level check that today's `CHECK` constraint doesn't need.

Two mutators write it, both gated by `isMember` of the issue's project (permissions.md §5) and neither carrying any transition-specific check beyond that:

- **`updateIssue`** — the general edit path. The issue detail page's status quick-change menu (ui-spec.md §4.4) calls this with just the new `status`.
- **`moveIssue`** — the board's drag-and-drop path (ui-spec.md §5). Dropping a card in a new column sets `status` *and* recomputes `sort_order` in the same call; under Assignee or Priority grouping the identical mutator instead sets `assignee_id` or `priority` to match the target column, per the board's grouping rule. Status only changes here when the board is grouped by status (the default).

Both paths write through the `touched({ status })` helper (data-model.md §1), so `updated_at` always advances with a status change. There is no separate history table or "moved at" timestamp in v1 — an issue's current status is all that's stored.

---

## 2. Project status

```
planned · active · paused · completed · canceled
```

`CHECK (status IN (...))`, default `'planned'` (data-model.md §7).

Same rule as issues: every transition is legal, no terminal state. `updateProject` is `isAdmin`-only (permissions.md §5) — there is no member path to change a project's status, matching the split in ui-spec.md between the (member-writable) board and the (admin-only) project settings screen (ui-spec.md §4.5).

One precondition already exists elsewhere and isn't restated here beyond a pointer: `deleteProject` refuses unless `status = 'canceled'` (data-model.md §5, permissions.md §5). That remains the only place a project's status gates a different mutator.

---

## 3. Cross-entity effects: nothing cascades

**Closing a parent issue does not touch its sub-issues.** Setting a parent's `status` to `done` or `canceled` neither requires nor changes the status of its sub-issues — `updateIssue` and `moveIssue` write exactly the row they were called on. A parent can sit at `done` while a sub-issue is still `backlog`; that is a reachable, real state, not something the UI should hide, in the same spirit as an assigned non-member being a real state rather than an error (permissions.md §7). A team that wants "all children done before closing the parent" as a habit enforces it socially, not structurally.

This is a status question, distinct from **deletion**, which already has its own, different rule: deleting a parent issue *promotes* its sub-issues to top-level rather than cascading the delete to them (data-model.md §4). The two mechanisms don't interact — a status change never deletes anything, and a delete never changes a sub-issue's status, only its `parent_issue_id`.

**Milestone completion is derived, not stored, and triggers nothing.** `milestone` has no `status` column (data-model.md §7) — there is nothing to transition. "All done" is a read-time computation over already-synced data (every issue with that `milestone_id` has `status IN ('done', 'canceled')`), not a mutator concern. It produces no write, no notification, and no automatic project-status change. [roadmap-view.md](./roadmap-view.md), when written, owns whether and how that computed fact renders (a progress bar, a checkmark, or nothing) — this document only fixes that the fact is derived at read time and has no side effect of its own.

**Canceling a project does not cascade-cancel its issues or milestones.** They keep whatever status they had. This keeps `status = 'canceled'` on a project cheap and reversible — consistent with data-model.md §5's reasoning for why cancellation is a separate, deliberate step before deletion — rather than becoming a bulk write over every issue in the project.

**Status changes trigger no notification.** notifications.md §1 fixes the trigger list at `mention`, `assignment`, and `comment`; status is not one of them, deliberately, and this document doesn't reopen that list.

---

[testing.md](./testing.md) §5 turns the "nothing cascades" claims in §3 above into permanent regression tests — the mechanism this document otherwise only asks a future reader to trust from silence.

## 4. Enforcement summary

| Rule | Enforced by |
| --- | --- |
| Issue status is one of five values | `CHECK` constraint (data-model.md §7) |
| Project status is one of five values | `CHECK` constraint (data-model.md §7) |
| Who may change issue status | `isMember` (permissions.md §5), in `updateIssue` / `moveIssue` |
| Who may change project status | `isAdmin` (permissions.md §5), in `updateProject` |
| Which transitions are legal | none rejected — every value pair is legal for both entities |
| Parent status ↔ sub-issue status | no enforcement point — no rule exists |
| Milestone completion | not stored — computed at read time from issue statuses |
| Project cancel → issue/milestone cascade | no enforcement point — no rule exists |
| `deleteProject` precondition | `status = 'canceled'`, checked in `deleteProject` (data-model.md §5) |

---

## 5. Changes this spec requires elsewhere

- **README.md** — add a link to this document in the doc list.
- **HANDOFF.md** — strike item 10; leave "Start with `docs/attachments.md`" as-is, since that remains the lowest-numbered undone item.
- **data-model.md, permissions.md, ui-spec.md, notifications.md** — no changes required. Every decision here (unrestricted transitions, no cascades, no new notification trigger) confirms behavior those documents already implied rather than contradicting any of them.

---

_Decisions here are settled. Revise deliberately, and reconcile data-model.md, permissions.md and ui-spec.md in the same change._
