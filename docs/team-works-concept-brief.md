# Team Works — concept & architecture brief

_A small, self-hosted, Linear-inspired tracker for a team under 20. Real-time layer: Zero (Rocicorp)._

---

## 1. What it is

**Team Works** is a lightweight, self-hosted work tracker for a single team of fewer than 20 people. It borrows Linear's clarity and speed but deliberately strips away the dev-centric machinery (sprints, velocity, command-palette power-user layer). The result is a more general-purpose **project-and-roadmap tracker**: work lives as issues, issues roll up into projects, projects carry milestones, and everything is visible on a timeline.

Like Linear, it's **local-first**: the UI reads and writes a local copy of the data and syncs in the background, so interactions feel instant.

**Positioning vs Linear**

|             | Linear                         | Team Works                                |
| ----------- | ------------------------------ | ----------------------------------------- |
| Audience    | Software teams                 | Any small team, mixed work                |
| Cadence     | Sprint/cycle-driven            | Milestone/roadmap-driven                  |
| Power layer | Keyboard-first command palette | Simple, direct UI                         |
| Hosting     | SaaS, per-seat                 | Self-hosted on your VPS, you own the data |
| Scope       | Broad, deep                    | Small, bespoke, focused                   |

**Why build it:** custom workflow, data ownership, no per-seat cost, and a worthwhile learning project — all four reasons apply.

---

## 2. Scope for v1

**In**

- Issues with status, assignee, **priority, labels, due dates, sub-issues, attachments**
- Projects with milestones
- Two views: a **Kanban board** (working) and a **timeline / roadmap** (planning)
- Comments with @mentions
- **Notifications: in-app (synced) and email**
- Invite-only auth, with **per-project write access** (membership-based); all projects are readable workspace-wide
- **Responsive on mobile** (one responsive web app, not a separate native build)
- Live, real-time updates across clients (via the sync engine, by default)

**Out (deliberately, for now)**

- Cycles / sprints
- Estimates / story points
- List view and calendar view
- Keyboard command palette
- External integrations (GitHub, Slack), SLAs, time tracking
- Offline _writes_ — read-only-when-offline is acceptable (confirmed)

---

## 3. Core concepts & data model

The hierarchy is: **Issue (+ sub-issues) → Project (+ milestones) → Roadmap.**

Primary entities and their key fields:

- **User** — id, name, email, avatar_url, role (`admin` | `member`) _(workspace-level)_, deactivated_at
- **Project** — id, **key** (`WEB`, immutable), name, description, status (`planned` | `active` | `paused` | `completed` | `canceled`), lead (user), start_date, target_date, color, sort_order
- **ProjectMember** — project_id, user_id _(no role column; this is what gates writes per-project)_
- **Milestone** — id, project_id, name, target_date, sort_order
- **Issue** — id, project_id (**required**), **number** (per-project, permanent — together with the project key this is `WEB-142`), milestone_id (nullable), parent_issue_id (nullable, for sub-issues), title, description, status (`backlog` | `todo` | `in_progress` | `done` | `canceled`), priority (`none` | `low` | `medium` | `high` | `urgent`), assignee_id (nullable), due_date, created_by, sort_order, timestamps
- **Label** — id, name, color
- **IssueLabel** — issue_id, label_id (join table, many-to-many)
- **Comment** — id, issue_id, author_id, body, timestamps
- **Attachment** — id, issue_id (**required**), comment_id (nullable — set when the file arrived in a comment), filename, storage_path, content_type, size_bytes, uploaded_by
- **Notification** — id, user_id (recipient), actor_id (who caused it), type (`mention` | `assignment` | `comment`), issue_id (**required**), comment_id (nullable), read_at, emailed_at

Relationships at a glance: a project has many milestones, many issues, and many members (via ProjectMember); a milestone has many issues; an issue can have many sub-issues (self-referencing via `parent_issue_id`, **one level deep** — a sub-issue cannot itself have children), many labels, many comments, and many attachments; a user authors comments, is assigned issues, and belongs to projects.

`sort_order` is a fractional index — a string key, not an integer — so a drag on the board writes exactly one row and needs no server round-trip.

This schema lives in Postgres (defined with Drizzle). Zero syncs the same shape to clients with one narrowing: only the six `User` columns listed above reach a client, enforced by the replication publication.

The exact column types, nullability, indexes, cascade rules and invariants are in [data-model.md](./data-model.md), which is the authority where it and this section differ.

---

## 4. The two views

**Kanban board (working).** Columns are issue statuses; cards are issues. Drag a card between columns to change its status. Cards show priority, assignee avatar, labels, and due date at a glance. Optionally re-group by assignee or priority — every grouping is the same single project-wide order, filtered, so reordering in one grouping also shifts relative position in the others ([data-model.md](./data-model.md) §5).

**Timeline / roadmap (planning).** Projects and milestones plotted across time as bars. This is where you see the shape of the quarter — what's planned, what overlaps, what's slipping. Rendered with **Frappe Gantt** (lightweight, SVG-based; integration note in section 5).

Both views are live queries over the same local data — no separate API endpoints per screen.

---

## 5. Architecture

### Stack

- **Frontend:** Next.js (App Router) + React, built on **Adobe React Aria Components**, styled for a **responsive** layout (mobile + desktop from one codebase). `dnd-kit` for board drag-and-drop. **Roadmap: Frappe Gantt** — the maintained core `frappe-gantt`, wrapped in a thin React component (see note below).
- **Data layer:** **Zero (Rocicorp)** — reactive queries + optimistic mutations; no separate TanStack Query needed.
- **Database:** PostgreSQL **15 or later** (logical replication enabled, for Zero). The version floor is set by [data-model.md](./data-model.md): column lists in publications, and column-scoped `ON DELETE SET NULL`.
- **ORM:** Drizzle — used on the server-side mutators.
- **Supporting libraries:** `uuidv7` (client-generatable, time-ordered primary keys) and `fractional-indexing` (the `sort_order` keys) — both load-bearing for the data model rather than incidental.

### Roadmap rendering — Frappe Gantt

Use the maintained core package (`frappe-gantt`, currently v1.2.2 — MIT, SVG) rather than the old community React wrappers, which are years stale and target outdated versions. Wrap it yourself in a small React component: a container `ref` plus a `useEffect` that runs `new Gantt(el, tasks, options)`, calls `.refresh(tasks)` when data changes, and cleans up on unmount. Map your data to its task shape `{ id, name, start, end, progress, custom_class }` — projects become bars (`start_date` → `target_date`), milestones become marker bars (`custom_class: 'bar-milestone'`); leave `dependencies` empty since the roadmap isn't dependency-scheduled. Use the Month / Quarter / Year view modes for zoom, override its CSS to match the app's styling, and wire its `onDateChange` callback to a Zero mutator so dragging a bar reschedules the project. The one wrinkle: it's an imperative SVG chart, so you bridge Zero's reactive live-query data to it by calling `.refresh()` whenever the underlying data updates.

Three constraints the mapping above does not resolve on its own, all owned by `roadmap-view.md` when written:

- **Dragging a bar is an admin-only action.** `onDateChange` calls `updateProject` or `updateMilestone`, and [permissions.md](./permissions.md) §5 restricts both to admins. For everyone else the chart is read-only, and the drag handles must be disabled rather than left to fail on write.
- **Not every project has a bar.** `start_date` and `target_date` are independently nullable ([data-model.md](./data-model.md) §7), as is `milestone.target_date`. Frappe Gantt needs a start and an end, so undated and half-dated records need a defined treatment — omitted from the chart, listed beside it, or given an inferred range.
- **`progress` has no backing column.** Nothing in the schema stores it. It has to be derived — the obvious candidate being the share of a project's or milestone's issues at `status = 'done'` — and that derivation is a decision, not a lookup.

### Real-time / sync layer — Zero

`zero-cache` keeps a SQLite replica of the syncable subset of Postgres (via logical replication) and bridges Postgres to clients. `zero-client` runs in the browser with a local store; components read with `useQuery` in ZQL (instant, query-driven sync). Writes go through custom mutators — instant on the client, authoritative on the server (via Drizzle). Conflicts resolve by server reconciliation. One exception to "instant": deletes cascade in Postgres, which the client's optimistic run cannot reproduce, so a delete settles in two phases — the target vanishes at once, its dependent rows a moment later ([data-model.md](./data-model.md) §4). **No offline writes** — reads of synced data work offline; writes are rejected when disconnected (acceptable, confirmed — design a clear disconnected-input state). Dataset is far inside Zero's ~100GB comfort range.

### Auth & per-project access

**Hand-written**, invite-only, email magic-links — no Auth.js or other auth library. [auth.md](./auth.md) is the full spec and the authority here; [permissions.md](./permissions.md) takes over once identity is established. The shape is:

- **Workspace role** on User (`admin` | `member`) — admins manage invites/settings, create projects, own project and milestone structure, and can write anywhere.
- **Per-project membership** via **ProjectMember** — a **write** boundary. Members create and edit issues, comments, and attachments in the projects they belong to.
- **Reads are workspace-wide.** Every user reads every project. Membership does not hide anything.

Zero authenticates its sync connection with a signed JWT carrying the user's id and workspace role — a short-lived access token that doubles as the browser's session credential ([auth.md](./auth.md) §2). Its **read rules** are near-trivial as a result — the whole syncable dataset goes to every client, with one exception scoping Notification rows to their owner. Authorization lives in the server-side mutators, which check membership before writing.

What counts as "the syncable dataset" is fixed one layer lower, by the publication in [data-model.md](./data-model.md) §3: ten tables, and for `User` only the six columns in §3 above. So there are two narrowings in total, and only one of them is a Zero read rule — the other is a property of what `zero-cache` replicates at all.

The trade-off is deliberate: there are no confidential projects in v1. Transparency is what keeps the model simple — nothing vanishes from a client mid-session, an @mention can name anyone, and removing someone from a project needs no cleanup. Design the membership layer generically anyway — it's the same shape the future team chat's channel access will reuse, and chat is where a genuine read boundary first becomes necessary.

### Attachments / storage

**Local disk on the VPS** (decided). File uploads go through a normal API route; only the file metadata lives in Postgres (and syncs via Zero). Can migrate to S3-compatible storage later if needed.

### Deployment (VPS)

**Single VPS** runs: the Next.js app (**systemd**, decided — see [deployment.md](./deployment.md)), **`zero-cache` as a Docker container on the same box** (decided), PostgreSQL with `wal_level=logical`, and nginx as the reverse proxy with Certbot SSL. Give `zero-cache` fast local storage for its replica. An SMTP path is required from **build step 1**, not step 4 — magic links are how anyone signs in at all ([auth.md](./auth.md) §10). Notification email later reuses the same transport behind an outbox.

---

## 6. Suggested build order

1. **Foundation** — Postgres schema (Drizzle) with logical replication, the `zero_data` publication that defines the sync set ([data-model.md](./data-model.md) §3), `zero-cache` running, Zero client schema, the hand-written auth scheme issuing JWTs ([auth.md](./auth.md)) with SMTP configured, the ProjectMember-based policy module gating mutators, the responsive app shell with React Aria. Get one synced query rendering end-to-end.

   Three items are assigned to this step and should not slip past it: **confirm how Zero maps Postgres `date`** and apply the specified fallback if it does not ([data-model.md](./data-model.md) §11), **test the self-referential composite foreign key against a cascading project delete** (§8 there), and **confirm Zero re-invokes its `auth` callback when `zero-cache` rejects an expired token** ([auth.md](./auth.md) §5). All three have decided answers on either branch; all three are cheapest to settle before anything is built on top.
2. **Issues + board** — ZQL queries, custom mutators for create/update/status, the Kanban board with `dnd-kit`. Live by default.
3. **Projects + milestones + roadmap** — the planning side and the timeline view (rendering per section 5).
4. **Collaboration & notifications** — comments, @mentions, in-app notifications, and the email path.
5. **Issue depth** — labels, sub-issues, attachments (local disk), priority/due-date polish.
6. **Mobile polish** — tighten the responsive layout for phones across both views.

(With Zero, sync is foundational — there's no separate "add realtime" phase.)

---

## 7. Decisions

**Settled**

1. **Name:** Team Works
2. **Notifications:** in-app and email
3. **Mobile:** responsive web (one codebase)
4. **Access:** reads are workspace-wide; writes are per-project (membership-based, via ProjectMember). See [permissions.md](./permissions.md).
5. **Roadmap rendering:** Frappe Gantt (lightweight, SVG)
6. **Object storage:** local disk on the VPS
7. **`zero-cache` placement:** same VPS as the app
8. **Offline UX:** read-only-when-offline is acceptable

From [data-model.md](./data-model.md):

9. **Ordering:** fractional index (base-62 strings), one project-wide key per issue, ties broken by id
10. **Issue identifiers:** `WEB-142` — immutable per-project key plus a monotonic per-project number
11. **Deletion:** hard delete throughout; `status = 'canceled'` is the reversible path, and users are deactivated rather than deleted
12. **Primary keys:** UUIDv7, generated client-side
13. **Sync scope:** enforced by a Postgres publication with a per-table column list, not by application code
14. **Postgres floor:** version 15, set by the two features decision 13 and the cascade rules depend on

From [auth.md](./auth.md):

15. **No auth library:** authentication is hand-written — no Auth.js, Lucia or Better Auth. With no passwords, no OAuth and one tenant, what a library would cover is a cookie, a token table and a JWT
16. **Sessions:** short-lived access JWT (15 min) plus a rotating refresh token in a `session` row (30-day sliding, uncapped). The access JWT is also the token `zero-cache` verifies — one artifact, one secret, delivered as both a cookie and a response body
17. **Magic links:** `GET` renders a confirmation page and consumes nothing; a `POST` redeems. Mail scanners cannot burn a single-use token
18. **Invites:** an `invite` row only; the `user` row is created when the link is first redeemed, which leaves the publication's six synced `user` columns untouched
19. **First admin:** a one-off `admin:grant` CLI over SSH, which doubles as the break-glass recovery from total lockout

From [deployment.md](./deployment.md):

20. **Process manager: systemd**, not PM2. One supervision system for the app, the background timers, and (indirectly) the `zero-cache` container, rather than two.

**Open**

- No open **decisions**. Three open **verifications**, each with the outcome decided on either branch, all assigned to build step 1: how Zero maps Postgres `date` ([data-model.md](./data-model.md) §11), whether the self-referential composite foreign key survives a cascading project delete (§8 there), and whether Zero re-invokes its `auth` callback on token rejection ([auth.md](./auth.md) §5).

---

## 8. Future: team chat

Planned later, on the **same backbone** — same Postgres, `zero-cache`, session-and-JWT scheme ([auth.md](./auth.md)), and React Aria UI. Chat becomes additive: new tables (channels, messages, reactions, read pointers) synced by the existing Zero setup, plus two genuinely new pieces — an **ephemeral presence/typing side-channel** (don't put high-frequency presence in synced Postgres) and **out-of-app push** (the email/notification path generalizes here). The per-project membership model designed now is what lets chat's channel permissions drop in cleanly.

---

## 9. Companion documents

- [permissions.md](./permissions.md) — authorization spec: roles, permission matrix, read model, per-mutator write rules.
- [data-model.md](./data-model.md) — schema spec: column types, ordering, issue identifiers, cascades, indexes, invariants, and the publication that defines Zero's sync set.
- [auth.md](./auth.md) — authentication spec: invites, magic links, sessions and rotation, the token `zero-cache` verifies, deactivation and revocation, and the environment contract.

---

_Built from a multi-round scoping interview. Sync layer: Zero (Rocicorp). Living document — revise as decisions firm up._
