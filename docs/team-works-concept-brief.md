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
- Invite-only auth, with **per-project access** (membership-based)
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

- **User** — id, name, email, avatar, role (`admin` | `member`) _(workspace-level)_
- **Project** — id, name, description, status (`planned` | `active` | `paused` | `completed` | `canceled`), lead (user), start_date, target_date, color
- **ProjectMember** — project_id, user_id, role (`lead` | `member`) _(this is what makes access per-project)_
- **Milestone** — id, project_id, name, target_date, sort_order
- **Issue** — id, project_id (nullable), milestone_id (nullable), parent_issue_id (nullable, for sub-issues), title, description, status (`backlog` | `todo` | `in_progress` | `done` | `canceled`), priority (`none` | `low` | `medium` | `high` | `urgent`), assignee_id (nullable), due_date, created_by, sort_order, timestamps
- **Label** — id, name, color
- **IssueLabel** — issue_id, label_id (join table, many-to-many)
- **Comment** — id, issue_id, author_id, body, timestamps
- **Attachment** — id, issue_id (nullable), comment_id (nullable), filename, path, content_type, size, uploaded_by
- **Notification** — id, user_id, type (`mention` | `assignment` | `comment`), source_id, read_at, emailed_at

Relationships at a glance: a project has many milestones, many issues, and many members (via ProjectMember); a milestone has many issues; an issue can have many sub-issues (self-referencing via `parent_issue_id`), many labels, many comments, and many attachments; a user authors comments, is assigned issues, and belongs to projects.

This schema lives in Postgres (defined with Drizzle) and is the same shape Zero syncs to clients.

---

## 4. The two views

**Kanban board (working).** Columns are issue statuses; cards are issues. Drag a card between columns to change its status. Cards show priority, assignee avatar, labels, and due date at a glance. Optionally re-group by assignee or priority.

**Timeline / roadmap (planning).** Projects and milestones plotted across time as bars. This is where you see the shape of the quarter — what's planned, what overlaps, what's slipping. Rendered with **Frappe Gantt** (lightweight, SVG-based; integration note in section 5).

Both views are live queries over the same local data — no separate API endpoints per screen.

---

## 5. Architecture

### Stack

- **Frontend:** Next.js (App Router) + React, built on **Adobe React Aria Components**, styled for a **responsive** layout (mobile + desktop from one codebase). `dnd-kit` for board drag-and-drop. **Roadmap: Frappe Gantt** — the maintained core `frappe-gantt`, wrapped in a thin React component (see note below).
- **Data layer:** **Zero (Rocicorp)** — reactive queries + optimistic mutations; no separate TanStack Query needed.
- **Database:** PostgreSQL (logical replication enabled, for Zero).
- **ORM:** Drizzle — used on the server-side mutators.

### Roadmap rendering — Frappe Gantt

Use the maintained core package (`frappe-gantt`, currently v1.2.2 — MIT, SVG) rather than the old community React wrappers, which are years stale and target outdated versions. Wrap it yourself in a small React component: a container `ref` plus a `useEffect` that runs `new Gantt(el, tasks, options)`, calls `.refresh(tasks)` when data changes, and cleans up on unmount. Map your data to its task shape `{ id, name, start, end, progress, custom_class }` — projects become bars (`start_date` → `target_date`), milestones become marker bars (`custom_class: 'bar-milestone'`); leave `dependencies` empty since the roadmap isn't dependency-scheduled. Use the Month / Quarter / Year view modes for zoom, override its CSS to match the app's styling, and wire its `onDateChange` callback to a Zero mutator so dragging a bar reschedules the project. The one wrinkle: it's an imperative SVG chart, so you bridge Zero's reactive live-query data to it by calling `.refresh()` whenever the underlying data updates.

### Real-time / sync layer — Zero

`zero-cache` keeps a SQLite replica of the syncable subset of Postgres (via logical replication) and bridges Postgres to clients. `zero-client` runs in the browser with a local store; components read with `useQuery` in ZQL (instant, query-driven sync). Writes go through custom mutators — instant on the client, authoritative on the server (via Drizzle). Conflicts resolve by server reconciliation. **No offline writes** — reads of synced data work offline; writes are rejected when disconnected (acceptable, confirmed — design a clear disconnected-input state). Dataset is far inside Zero's ~100GB comfort range.

### Auth & per-project access

**Auth.js (NextAuth)**, invite-only, email magic-links. Two layers of role:

- **Workspace role** on User (`admin` | `member`) — admins manage invites/settings and can see all projects.
- **Per-project membership** via **ProjectMember** — regular members see and act on only the projects they belong to.

Zero authenticates its sync connection with a signed JWT, and its **read rules** key off ProjectMembership: a client only syncs projects the user is a member of (or all, if workspace admin). Design this membership/permission layer generically — it's the same shape the future team chat's channel access will reuse.

### Attachments / storage

**Local disk on the VPS** (decided). File uploads go through a normal API route; only the file metadata lives in Postgres (and syncs via Zero). Can migrate to S3-compatible storage later if needed.

### Deployment (VPS)

**Single VPS** runs: the Next.js app (PM2 or systemd), **`zero-cache` as a Docker container on the same box** (decided), PostgreSQL with `wal_level=logical`, and nginx as the reverse proxy with Certbot SSL. Give `zero-cache` fast local storage for its replica. An email-sending path (transactional email) is added for the email side of notifications.

---

## 6. Suggested build order

1. **Foundation** — Postgres schema (Drizzle) with logical replication, `zero-cache` running, Zero client schema, Auth.js issuing JWTs, ProjectMember-based read rules, the responsive app shell with React Aria. Get one synced query rendering end-to-end.
2. **Issues + board** — ZQL queries, custom mutators for create/update/status, the Kanban board with `dnd-kit`. Live by default.
3. **Projects + milestones + roadmap** — the planning side and the timeline view (rendering per section 7).
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
4. **Access:** per-project (membership-based; new ProjectMember entity, drives Zero read rules)
5. **Roadmap rendering:** Frappe Gantt (lightweight, SVG)
6. **Object storage:** local disk on the VPS
7. **`zero-cache` placement:** same VPS as the app
8. **Offline UX:** read-only-when-offline is acceptable

**Open**

- None — all v1 decisions are settled.

---

## 8. Future: team chat

Planned later, on the **same backbone** — same Postgres, `zero-cache`, Auth.js/JWT, and React Aria UI. Chat becomes additive: new tables (channels, messages, reactions, read pointers) synced by the existing Zero setup, plus two genuinely new pieces — an **ephemeral presence/typing side-channel** (don't put high-frequency presence in synced Postgres) and **out-of-app push** (the email/notification path generalizes here). The per-project membership model designed now is what lets chat's channel permissions drop in cleanly.

---

_Built from a multi-round scoping interview. Sync layer: Zero (Rocicorp). Living document — revise as decisions firm up._
