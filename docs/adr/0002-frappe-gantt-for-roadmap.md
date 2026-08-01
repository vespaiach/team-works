# ADR-0002: Frappe Gantt for the roadmap view

Status: Accepted — 2026-07-31

## Context

The roadmap view (brief §4) is a planning-oriented timeline over projects and milestones, distinct from the working Kanban board. It needs a JS Gantt renderer usable inside a React/Next.js app at reasonable integration cost.

## Decision

Use the maintained core `frappe-gantt` package (SVG, MIT-licensed, not React-specific — currently v1.2.2), wrapped in a thin React component: a container `ref` plus a `useEffect` that instantiates `new Gantt(el, tasks, options)`, calls `.refresh(tasks)` when the underlying data changes, and cleans up on unmount (brief §5).

## Consequences

- It's an imperative SVG chart, not a reactive component — bridging Zero's reactive `useQuery` data into it means manually calling `.refresh()` whenever the live query result changes (brief §5).
- Its task shape (`{ id, name, start, end, progress, custom_class }`) doesn't match the schema directly and needs a mapping layer: projects become bars, milestones become marker bars, and `dependencies` is left empty since the roadmap isn't dependency-scheduled.
- `progress` has no backing column and must be derived at render time — owned by [roadmap-view.md](../roadmap-view.md) §3.
- `start_date`/`target_date` are independently nullable, so undated and half-dated projects need explicit handling, not left to the library — owned by [roadmap-view.md](../roadmap-view.md) §2.
- Dragging a bar (`onDateChange`) must be gated admin-only to match [permissions.md](../permissions.md) §5, with drag handles disabled for everyone else rather than left to fail server-side — owned by [roadmap-view.md](../roadmap-view.md) §4.

## Alternatives considered

- **Community React wrappers for Frappe Gantt.** Rejected outright — years stale, targeting outdated versions of the underlying library (brief §5).
- **A full scheduling library (dhtmlxGantt, Bryntum).** Heavier, commercially licensed, and built around dependency-scheduling the brief explicitly doesn't need.
- **Hand-rolled SVG/Canvas timeline.** Full control, but reimplements zoom levels, drag-to-reschedule, and rendering that `frappe-gantt` already provides.
