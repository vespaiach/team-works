# Team Works — roadmap view

_Roadmap view spec for v1. Companion to [team-works-concept-brief.md](./team-works-concept-brief.md) §5, [data-model.md](./data-model.md), [permissions.md](./permissions.md) and [ui-spec.md](./ui-spec.md) §4.3/§6. Status: approved 2026-07-31._

ui-spec.md fixed where the roadmap lives (`/roadmap`), that it offers Month/Quarter/Year zoom, and that it's read-only for non-admins. The concept brief fixed the rendering library (Frappe Gantt) and the task-shape mapping (§5). Three things were left open there, plus a fourth this document adds: what happens to a project or milestone with an absent date, what `progress` derives from, whether dragging a project also reschedules its milestones, and mobile behavior. This document settles all four.

---

## 1. Task mapping

Every project with both `start_date` and `target_date` set becomes one Gantt bar; every milestone with `target_date` set becomes one marker bar (`custom_class: 'bar-milestone'`), nested immediately beneath its project's row. Row order is `project.sort_order` workspace-wide, then `milestone.sort_order` within each project — the same ordering data-model.md §5 already defines for exactly this purpose. `dependencies` stays empty; the roadmap isn't dependency-scheduled (concept-brief.md §5).

Bar fill is `project.color` — the same hex value already shown as the project's swatch in the sidebar project list (ui-spec.md §1) — not the status five-color mapping issues and project status share elsewhere. The roadmap's job is to show *which* project a bar belongs to across a chart that can hold many bars at once; the status color language already does its job in the sidebar and on cards, and reusing it here would make every canceled project's bar visually identical regardless of which project it was. Milestones have no `color` column and get a single fixed marker style, not colored per project.

A canceled project or milestone is not hidden — the workspace stays "nothing hidden" the same way the board does (ui-spec.md §5) — but renders at reduced opacity so it doesn't visually compete with active work. This is a CSS treatment on the existing `custom_class` hook, not a new data field.

---

## 2. Undated and half-dated records

One rule: **a bar requires every date it needs.** A project needs both `start_date` and `target_date`; a milestone needs `target_date`. Short of that — no dates, or only one of the two a project needs — nothing is invented. No inferred range, no default duration, no "today" placeholder.

Everything that doesn't clear that bar appears instead in an **Undated** panel rendered below the chart (not beside it, so the layout doesn't change shape between mobile and desktop). It's grouped by project: an undated project heads its own group; a dated project with undated milestones lists those milestones under it even though the project itself has a bar above. Each row names what's missing and shows whatever date the record does have as plain text (e.g. "Launch milestone — no target date" or "Redesign — target date only, needs a start date to appear on the chart"). Nothing in this panel is a dead end: an admin can act on a row via the same Project Settings / milestone management surfaces ui-spec.md §4.5 already defines.

---

## 3. Progress derivation

Nothing in the schema stores `progress` (concept-brief.md §5); it's computed at render time from the issue set the bar represents:

```
progress = done_count / (total_count - canceled_count)
```

- **Project bar** — every issue with that `project_id`, top-level and sub-issues alike. Sub-issues are full issues with their own status (data-model.md §8), so they count the same as any other row; nothing about nesting changes the arithmetic.
- **Milestone bar** — every issue with that `milestone_id`, regardless of which project-level bar it also belongs to (it's the same project by the composite-FK invariant, data-model.md §8).
- **Canceled issues are excluded from both sides of the fraction.** A canceled issue is scope that was dropped, not scope that's still outstanding — counting it against progress would make an actively-managed project look permanently incomplete for work nobody intends to finish.
- **`total_count - canceled_count == 0`** (no issues, or every issue canceled) → `progress = 0`, never `NaN`. A project with no real work yet reads as "not started," not as an error.

---

## 4. Reschedule semantics

Dragging is admin-only; every other user sees the chart with drag handles disabled, per the permission-disabled convention (ui-spec.md §7). For an admin:

- **Dragging or resizing a project bar** calls `updateProject(id, { start_date, target_date })` with whatever pair Frappe Gantt's `onDateChange` computes for that interaction (move or single-edge resize — the library reports both as a new start/end pair). It writes only that project's row.
- **Dragging a milestone marker** calls `updateMilestone(id, { target_date })`. It writes only that milestone's row.
- **A project drag never cascades to its milestones.** This matches the board's own rule that a drop writes exactly one row (data-model.md §5); a roadmap drag keeps the same guarantee. If a project slips, its milestones stay where they were until someone moves them, which keeps a single gesture from silently rewriting rows the admin didn't drag and can't see changing.

Both mutators already exist and already require `isAdmin` (permissions.md §5) — no new mutator, no new predicate.

---

## 5. Zoom and default view

Default view mode is **Quarter**. The concept brief frames the roadmap as "where you see the shape of the quarter" (§5); Quarter is the zoom level that shows that shape without requiring a zoom action on load. Month and Year remain available via the zoom controls ui-spec.md §4.3 already fixes, at every breakpoint.

---

## 6. Mobile behavior

Below the `md` breakpoint (768px, ui-spec.md §2), the roadmap is **read-only for every role, including admins.** A Gantt bar's move/resize handles are a precision pointer interaction; touch doesn't give an admin reliable control over which edge they're grabbing or how far a drag will move a bar at Quarter zoom, so the chart drops drag entirely rather than offering a degraded version of it. Admins reschedule from Project Settings' existing start/target date fields (ui-spec.md §4.5) or milestone management instead — both already exist and already work at any viewport width. This is a device-capability limitation, not a permission mismatch, so it does not use the permission-disabled banner's copy or styling; a lighter inline note is sufficient, its exact wording left to implementation.

The chart itself keeps its full width and pans via horizontal scroll, the same interaction the board already uses on mobile (ui-spec.md §5). Zoom controls remain available and behave identically to desktop.

---

## 7. Out of scope for v1

- Filtering the roadmap by project status, label, or member — the concept brief names only Month/Quarter/Year zoom as a control (§5); a project or milestone that shouldn't be tracked yet is canceled or left undated, not filtered.
- Dependency lines between bars — `dependencies` stays empty (§1); the roadmap isn't dependency-scheduled.
- Per-bar tooltip or popup content beyond Frappe Gantt's own default (name, dates, progress) — no custom popup HTML in v1.
- Editing a project's or milestone's name from the roadmap itself — the chart is a scheduling surface, not an alternate editor; renames happen in Project Settings.

---

## 8. Testing

Beyond the mutator and predicate tests permissions.md §10 and data-model.md already specify. See [testing.md](./testing.md) for the runner and database strategy — all integration-tier, against a real Postgres, no `zero-cache` needed for any of the below:

- **Bucketing.** A project with both dates renders a bar; missing either one routes it to the Undated panel with the correct "what's missing" label. A milestone with no `target_date` is grouped under its project in the same panel even when the project itself has a bar.
- **Progress arithmetic.** A project with 2 done, 1 canceled, 1 open issues reports `2/3`, not `2/4`. A project with issues that are all canceled, or none at all, reports `0`, not `NaN`.
- **Reschedule scope.** Dragging a project bar writes only that project's row — a project with milestones scheduled inside its old range keeps their original `target_date` after the drag.
- **Authorization.** A non-admin's chart renders with drag handles disabled and no working `onDateChange`, regardless of project membership — this is a workspace-role check, not a per-project one (permissions.md §5).
- **Mobile.** Below the `md` breakpoint, drag is unavailable for an admin session too, even though the same session can drag at desktop width.

---

## 9. Changes this spec requires elsewhere

- **data-model.md's deferred-items table:** discharges "Rendering of projects and milestones with absent dates" (§10 there), now owned by §2 of this document.
- **ui-spec.md:** no changes required. §4.3 and §6 already deferred mobile behavior, date-gap handling, and progress derivation to this document by name; this document fills those in without contradicting anything §4.3/§6 fixed (route, zoom controls, read-only-for-non-admins).
- **permissions.md:** no changes required. `updateProject` and `updateMilestone` already require `isAdmin` (§5) and already carry the preconditions this document's drag semantics rely on.
- **team-works-concept-brief.md:** no changes required. §5's three open items (undated/half-dated handling, `progress` derivation, whether a project drag moves its milestones) are now resolved by §§2–4 of this document, as §5 anticipated.
- **package.json:** no changes required. `frappe-gantt` is already in the planned dependency list (concept-brief.md §5, CLAUDE.md).
