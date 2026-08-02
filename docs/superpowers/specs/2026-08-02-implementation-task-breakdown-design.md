# Team Works — implementation task breakdown

_Design spec, 2026-08-02. How the build is sliced into tasks, why it is sliced that way, which tasks exist,
and what order they go in._

**In a hurry?** §8 is the numbered backlog — 59 tasks in execution order, each mapped to its GitHub issue.
Start at order 1.

This document does not re-plan build step 1. Four detailed implementation plans for it already exist
(`docs/superpowers/plans/2026-07-31-foundation-{a,b,c,d}-*.md`, ~4,350 lines). This document fixes the
**slicing rules**, reconciles those plans against them, names two gaps they leave, and supplies the task
list for build steps 2–6, which have no plans yet.

---

## 1. The constraint being designed against

Five criteria, given as requirements:

1. Tasks are small.
2. Tasks are independent.
3. Tasks are easy to test separately.
4. A finished task can be merged to `main` immediately and deployed to prod daily.
5. One full-stack developer can implement a task without waiting on anyone.

**Team size: one developer.** This collapses criteria 2 and 5 from "parallel tracks must not block each
other" to the weaker "no task requires half-finished work sitting in another branch." Criterion 4 becomes
the dominant constraint.

**Criterion 4 is literal, not aspirational.** [deployment.md](../../deployment.md) §7 auto-deploys every
merge to `main` — fast CI, then E2E, then SSH deploy, health check, auto-rollback. Merging *is* deploying.
Every rule below follows from that.

---

## 2. Slicing rules

Each rule is derived from a spec, not from taste.

| # | Rule | Source |
| --- | --- | --- |
| **R1** | **A task is a deploy.** "Done" means `main` is green *and* safe to auto-ship to the VPS. | [deployment.md](../../deployment.md) §7 |
| **R2** | **Schema ships ahead of the code that uses it.** Auto-rollback reverts code but not migrations, so a schema-only PR that ships nothing user-visible is the prescribed pattern, not a smell. | [deployment.md](../../deployment.md) §7 |
| **R3** | **Exactly one task touches the `zero_data` publication.** It is the only replica-reset hazard. Land every table and the publication once; every task afterwards is pure app code. | [deployment.md](../../deployment.md) §8 |
| **R4** | **A verification runs before anything depends on it.** The `date` verification can retype three *synced* columns — itself a reset-forcing migration — so it cannot come after features are built on those columns. | [data-model.md](../../data-model.md) §11 |
| **R5** | **After the foundation, one task = one user-visible capability** — mutator + UI + tests in one PR, no migration, no deploy hazard. | R3 makes this free |

### The invariant R3 buys

All fifteen tables land during the foundation. **No task in build steps 2–6 carries a migration.** That
makes criterion 4 hold trivially for every one of the ~28 feature tasks: no schema change means no
replica reset, no un-rollbackable migration, and nothing for a reviewer to check beyond the code itself.

This is the single highest-value property of the whole breakdown, and §5.2 records the one place the
existing plans currently break it.

---

## 3. The spine

```
Phase 0   Pipeline is real       1 task    NEW — no existing plan covers this
Phase 1   Tooling                6 tasks   = Plan A
Phase 2   Schema + sync boundary 7 tasks   = Plan B
Phase 3   Auth                   8 tasks   = Plan C
Phase 4   Zero client + shell    9 tasks   = Plan D
─────────────────────────────────────────  build step 1 ends here
Phase 5   Issues + board         7 tasks   NEW
Phase 6   Projects + roadmap     6 tasks   NEW
Phase 7   Collaboration          5 tasks   NEW
Phase 8   Issue depth            6 tasks   NEW
Phase 9   Mobile polish          3 tasks   NEW
Phase 10  Backups                1 task    NEW
```

**59 tasks.** 30 already have written plans (Phases 1–4); 29 are new (Phase 0, and Phases 5–10) and are
specified in §6 below.

### Why Phase 0 comes first

Provisioning is a manual runbook ([deployment.md](../../deployment.md) §2, §10) and nothing in the repo
automates it. Until it is done, criterion 4 is theoretical — there is no prod to deploy to and no CI to
gate a merge. Doing it first means:

- every subsequent PR genuinely auto-deploys, so the criterion is enforced by the pipeline rather than by
  discipline;
- the riskiest infrastructure (logical replication, the `zero-cache` container, nginx, Certbot,
  auto-rollback) is proven while the app is empty and a broken deploy costs nothing;
- [deployment.md](../../deployment.md) §11's operational checklist — deploy round-trip, auto-rollback,
  manual rollback — can be exercised for real on day one.

### Why auth is a feature phase, not plumbing

The entire magic-link system is Next.js + Drizzle + `nodemailer`. It touches Zero nowhere;
[auth.md](../../auth.md) §4.1 even notes the pending-invite admin page is "the app's first screen that is
not a Zero query." "You can sign in" is therefore the first genuinely user-visible increment, and it ships
before `zero-cache` is load-bearing. Plan C already sequences it this way.

---

## 4. Where the criteria are knowingly violated

Stated plainly rather than papered over.

**Phases 0–4 are a serial chain, and most of them ship nothing a user can see.** Criteria 2 and 5 do not
hold there. This is inherent to Zero: it replaces the entire data-fetch and mutation path, so there is no
walking skeleton smaller than "schema + publication + `zero-cache` + client schema + a signed JWT + shell."
There is no vertical slice to cut until that exists.

What the design does instead is make every one of those tasks **green, tested, and independently
deployable** (R1, R2). The violation costs review size and rework risk, not delivery cadence. Roughly
1.5–3 weeks solo.

**From Phase 5 onward all five criteria hold.** No migrations (R3), each task is one capability (R5), and
the remaining dependencies are shallow — most Phase 5–8 tasks can be done in any order.

---

## 5. Reconciliation with the existing foundation plans

Plans A–D already decompose build step 1 into 30 tasks, at a granularity *finer* than this document would
have chosen. They satisfy criteria 1 and 3 well. **They are adopted as-is**; Phases 1–4 above are exactly
their task lists. Two gaps follow.

### 5.1 Gap: no plan covers the deploy pipeline

No plan mentions nginx, systemd, `deploy.sh`, Certbot, `/api/health`, or a GitHub Actions workflow. The
sole match in Plan C is a line stating it is out of scope. Everything in
[deployment.md](../../deployment.md) §2–§7 and §10 is unimplemented and unplanned.

Without it, criterion 4 cannot be satisfied by any task. **Phase 0 (§6.1) closes this gap and must come
before Plan A.**

### 5.2 Gap: `notification_email` is missing from Plan B

Plan B builds "all fourteen tables" and declares exactly fourteen. [notifications.md](../../notifications.md)
§5 defines a fifteenth — `notification_email`, the delivery outbox — which post-dates the plan.

Left unfixed, Phase 7's outbox task (§6.4, P7.5) would carry a migration, breaking §2's invariant that no
build-step-2-onward task ships schema. The impact is mild — the table is non-synced and additive, so
[deployment.md](../../deployment.md) §8's decision rule means **no replica reset** — but the invariant is
worth more than the convenience.

**Fix:** add `notification_email` to Plan B Task 2, and to the Task 7 sync-scope assertion that it is
absent from the publication. One table, one index, no interactions with anything else in that plan.

---

## 6. Task list

Notation per task: **`[template]`** is the GitHub issue template — `feat` = feature_request,
`infra` = devops_infrastructure, `ui` = ui_design. **Depends** names the task or tasks that must land
first.

### 6.1 Phase 0 — Pipeline is real (new)

**P0.1 — Provision the VPS and wire the deploy pipeline** `[infra]` · Depends: nothing

Everything in [deployment.md](../../deployment.md) §2–§7: Ubuntu with Node 20, PostgreSQL 15+ with
`wal_level=logical`, Docker, nginx, Certbot, `ufw` limited to 22/80/443, the `deploy` system user with
narrowly-scoped `sudo`, the `releases/`–`shared/`–`current` layout, `team-works.service`, the nginx server
block including `limit_req` on `/api/auth/` and `access_log off` on `/auth/verify`, `/opt/team-works/shared/.env`,
`deploy.sh`, and `.github/workflows/ci.yml` with the `fast` and `deploy` jobs. Plus an `/api/health` route
in the app — `deploy.sh`'s health check depends on it.

The `e2e` job is defined but skipped until Phase 4 has tests for it to run.

**Done when** ([deployment.md](../../deployment.md) §11): a push to `main` produces a new release
directory, repoints `current`, and serves `https://<domain>/api/health` with 200; and a deliberately
broken build leaves `current` untouched with the site still up.

### 6.2 Phases 1–4 — Build step 1

Adopted verbatim from the existing plans. Listed here only so the issue set is complete.

| Task | Plan | Template |
| --- | --- | --- |
| Install the planned dependencies | A-1 | infra |
| Delete scaffold cruft, add `.nvmrc`, rewrite `.env.example` | A-2 | infra |
| Environment contract module | A-3 | feat |
| Vitest configuration | A-4 | infra |
| Playwright configuration | A-5 | infra |
| `zero-cache` Docker Compose + native Postgres checklist | A-6 | infra |
| Drizzle config, db client, `touched()` helper | B-1 | feat |
| Full schema — all **fifteen** tables (§5.2) | B-2 | feat |
| Migration tooling, rollback test harness, first round-trip test | B-3 | infra |
| Custom SQL migration — collation, composite FKs, dedup indexes, publication | B-4 | feat |
| Composite-FK cascade verification ([data-model.md](../../data-model.md) §8) | B-5 | feat |
| `admin:grant` and `db:seed` scripts | B-6 | infra |
| Sync-scope test — publication membership | B-7 | feat |
| `permissions.ts` — the pure predicate module | C-1 | feat |
| Token primitives, JWT, `requireUser()`, `loadActor()` | C-2 | feat |
| Supporting infra — mail, cookies, origin check, next-path validation | C-3 | feat |
| Sign-in and redemption | C-4 | feat |
| Refresh and rotation | C-5 | feat |
| Sign-out, invites, deactivation, last-admin guard | C-6 | feat |
| Route protection — `middleware.ts` | C-7 | feat |
| Boot-failure test and `auth:purge` | C-8 | infra |
| Zero client schema + schema-parity test | D-1 | feat |
| Verify `zero-cache` env vars and image tag | D-2 | infra |
| Zero client construction | D-3 | feat |
| App shell — responsive layout, React Aria, sign-in page | D-4 | ui |
| The one synced query | D-5 | feat |
| E2E infrastructure — dockerized stack, fixtures | D-6 | infra |
| E2E scenario — sign-in | D-7 | feat |
| E2E verification — Postgres `date` mapping | D-8 | feat |
| E2E verification — Zero re-invokes `auth` on rejection | D-9 | feat |

B-4 is the **publication migration** — the one task flagged under
[deployment.md](../../deployment.md) §8. Its PR description must say so, and the §8 reset procedure runs
after it deploys. It is the only such task in the project.

D-8 and D-9 resolve two of the three build-step-1 verifications; B-5 resolves the third. Each has a
decided fallback, applied in the same PR if the verification fails, with the outcome recorded in the
owning spec.

### 6.3 Phase 5 — Issues + board (new)

**P5.1 — `createIssue`** `[feat]` · Depends: D-5
Server mutator allocating `number` via `UPDATE issue_counter … RETURNING` in the issue's own transaction;
client mutator guessing `max(number)+1` from the local replica ([data-model.md](../../data-model.md) §6).
`sort_order = generateKeyBetween(lastKey, null)`. Guards: `isMember`; reject a `parent_issue_id` whose
target itself has a parent (invariant 5). Uses `touched()`. Create form UI.
**Tests:** allowed/denied; nesting precondition; numbers stay monotonic after a delete; concurrent creates
in one project get distinct numbers; `updated_at` set.

**P5.2 — `updateIssue`** `[feat]` · Depends: P5.1
All editable fields. Guards: `isMember`; reject any project change (invariant 3); nesting check
(invariant 5). Issue detail view with inline edit.
**Tests:** allowed/denied; project change rejected; nesting rejected; `updated_at` advances.

**P5.3 — Kanban board, read-only** `[ui]` · Depends: P5.2
Columns are statuses; cards show priority, assignee avatar, labels, due date (brief §4). Query sorted by
`(sort_order, id)` ([data-model.md](../../data-model.md) §5).

**P5.4 — Board drag-and-drop** `[feat]` · Depends: P5.3
`dnd-kit` wired to a `moveIssue` mutator writing status + `sort_order`. Key from
`generateKeyBetween(prev, next)` read off the local replica — exactly one row written, no round trip. Ties
are legal and need no repair.
**Tests:** E2E scenario 2 — two browser contexts, one drags, the other updates with no reload
([testing.md](../../testing.md) §8).

**P5.5 — Board re-grouping** `[ui]` · Depends: P5.4
Group by assignee or priority over the same single project-wide order, filtered. The UI states the honest
cost: reordering in one grouping shifts relative position in the others
([data-model.md](../../data-model.md) §5).

**P5.6 — Delete and cancel an issue** `[feat]` · Depends: P5.2
`deleteIssue` is admin-only; the member path is `status = 'canceled'`. The client mutator performs child
promotion locally to match the server's `SET NULL`, so the visible result is correct at once
([data-model.md](../../data-model.md) §4). The mutator reports how many children will be promoted.
**Tests:** member denied delete but allowed cancel; children promoted, not cascaded.

**P5.7 — Disabled-control convention and the assigned-non-member state** `[ui]` · Depends: P5.2
Controls the user cannot use render disabled with a reason, never hidden. Issue detail explains why and
names the project they would need to join ([permissions.md](../../permissions.md) §7, §12).
**Tests:** E2E scenario 3 — a non-member's optimistic write is rejected server-side, the local store
rebases, and a toast names why.

### 6.4 Phase 6 — Projects, milestones, roadmap (new)

**P6.1 — Project mutators and settings UI** `[feat]` · Depends: D-5
`createProject` (inserting the `issue_counter` row in the same transaction), `updateProject` (rejects any
`key` change — invariant 6), `deleteProject` (refuses unless `status = 'canceled'` — invariant 7). The UI
navigates away immediately on delete, per the two-phase settle.
**Tests:** key change rejected; delete before cancel rejected; cascade removes milestones, issues, members
and the counter.

**P6.2 — Project membership** `[feat]` · Depends: P6.1
`addProjectMember` / `removeProjectMember`, admin-only, plus membership UI.
**Tests:** the removal test ([permissions.md](../../permissions.md) §7) — remove a member with an issue
assigned to them; the issue is unchanged, still visible to them, no longer editable by them.

**P6.3 — Milestones** `[feat]` · Depends: P6.1
`createMilestone` / `updateMilestone` / `deleteMilestone`, admin-only, plus milestone UI. Issues outlive
milestones via `ON DELETE SET NULL (milestone_id)`.
**Tests:** invariant 4 — a milestone from another project is refused by the composite FK.

**P6.4 — Frappe Gantt React wrapper** `[feat]` · Depends: P6.3
Container `ref` plus a `useEffect` running `new Gantt(el, tasks, options)`, calling `.refresh(tasks)` when
data changes and cleaning up on unmount (brief §5). App CSS overrides its stylesheet.

**P6.5 — Roadmap view** `[ui]` · Depends: P6.4
Projects become bars (`start_date` → `target_date`), milestones marker bars
(`custom_class: 'bar-milestone'`), `dependencies` left empty. Undated and half-dated records, and the
derived `progress` value, follow [roadmap-view.md](../../roadmap-view.md). Month / Quarter / Year zoom.

**P6.6 — Roadmap drag-to-reschedule** `[feat]` · Depends: P6.5
`onDateChange` calls `updateProject` / `updateMilestone`, both admin-only. For everyone else the drag
handles render disabled rather than being left to fail on write (brief §5).

### 6.5 Phase 7 — Collaboration and notifications (new)

**P7.1 — Comments** `[feat]` · Depends: P5.2
`createComment` (`isMember`); `updateComment` / `deleteComment` (`isMember` + authorship). An admin may
delete anyone's comment; **nobody may edit another user's**, admins included. Thread UI ordered by
`(issue_id, created_at)`.
**Tests:** author edits own; admin cannot edit another's; admin can delete another's; member cannot.

**P7.2 — Mentions** `[feat]` · Depends: P7.1
The autocomplete writes the stored token `@[Display Name](user:<uuid>)` directly, so there is no free-text
name for the server to fuzzy-match ([notifications.md](../../notifications.md) §2). The picker lists
project members first and excludes deactivated users. Server-side extraction drops unresolvable ids
silently rather than failing the mutator.

**P7.3 — Notification creation** `[feat]` · Depends: P7.2
The three triggers of [notifications.md](../../notifications.md) §1 — `assignment` on a change to a
different non-null assignee; `mention` by diffing mentioned ids against the previous value; `comment` to
the issue's participants minus the author and minus anyone already receiving a mention from that same
comment. Rows insert in the same transaction as the triggering write. Deactivated candidates are filtered
at creation.
**Tests:** exact recipient set per trigger; no row for the actor or a deactivated candidate; the two
partial unique indexes hold.

**P7.4 — In-app notification feed** `[ui]` · Depends: P7.3
The feed, driven by the system's one Zero read rule; unread badge; `markNotificationRead` (self only);
deep link `/WEB-142#comment-<id>`.

**P7.5 — Email outbox and worker** `[feat]` · Depends: P7.3
One `notification_email` row per notification, in the same transaction. `npm run notify:send-outbox`
processes 20 rows a run, re-reads the recipient's `deactivated_at`, calls `sendMail()`, and sets
`emailed_at`. Backoff 1/5/15/60/180 minutes, `failed` at attempt 5. Wired to
`team-works-notify-outbox.timer`, every minute.
**Tests:** exactly one outbox row per notification, same transaction; a mocked send failure drives the
backoff schedule including the terminal `failed` state.
**Note:** assumes §5.2's fix has landed. Otherwise this task carries a migration.

### 6.6 Phase 8 — Issue depth (new)

**P8.1 — Labels** `[feat]` · Depends: D-5
`createLabel` / `updateLabel` / `deleteLabel`, admin-only, with case-insensitive uniqueness. Label
management UI.

**P8.2 — Applying labels** `[feat]` · Depends: P8.1, P5.3
`addIssueLabel` / `removeIssueLabel` (`isMember`) — curated by admins, applied by any member. Picker on
issue detail, chips on board cards.

**P8.3 — Sub-issues** `[feat]` · Depends: P5.6
Create and list sub-issues on issue detail. One level deep (invariant 5); same-project is already
guaranteed structurally by the composite FK (invariant 2). Promote-on-delete already landed in P5.6.

**P8.4 — Attachment upload** `[feat]` · Depends: P5.2
`POST /api/issues/:issueId/attachments` — a plain route, not a Zero mutator, since the mutator protocol
carries JSON ([attachments.md](../../attachments.md) §1). `requireUser()` → `loadActor()` → load the issue
→ derive `project_id` from the stored row → `isMember`. 25 MB cap enforced *during* the stream (413);
content-type allowlist checked before any disk write (415), `image/svg+xml` excluded. Server-generated
`storage_path`. Adds `busboy`. This is the one row-creating write in the system whose id is
server-generated.
**Tests:** non-member rejected before any file write; deactivated user rejected despite a valid token;
oversize aborted mid-stream rather than buffered; SVG rejected.

**P8.5 — Attachment download, delete, reclamation** `[feat]` · Depends: P8.4
`GET /api/attachments/:id` — never served statically by nginx. Reads are workspace-wide, so there is no
membership check beyond authentication. **`Content-Disposition: attachment` unconditionally**, with the
*stored* `content_type` never re-sniffed — the load-bearing security line
([attachments.md](../../attachments.md) §2). A row whose file is missing returns 404, not 500.
`deleteAttachment` is an ordinary Zero mutator deleting only the row; `npm run attachments:reclaim` on a
weekly timer collects orphans past a one-hour mtime grace.
**Tests:** disposition is always `attachment`, including for `text/plain` and `application/pdf`; missing
file returns 404; a file uploaded seconds ago is left alone by reclamation.

**P8.6 — Priority and due-date polish** `[ui]` · Depends: P5.5
Filters and overdue indicators across board and issue detail.

### 6.7 Phase 9 — Mobile polish (new)

**P9.1 — Responsive board** `[ui]` · Depends: P5.5
**P9.2 — Responsive roadmap** `[ui]` · Depends: P6.6
**P9.3 — Responsive issue detail and navigation** `[ui]` · Depends: P8.6

### 6.8 Phase 10 — Backups (new)

**P10.1 — Backups and restore drill** `[infra]` · Depends: P8.5
Nightly `pg_dump` and an `ATTACHMENTS_DIR` tarball produced and pushed **in the same run** — the two are
only meaningful together ([attachments.md](../../attachments.md) §6). `team-works-backup.timer`,
credentials in `/etc/team-works/backup.env`, 14 daily copies retained by a bucket lifecycle rule. Plus
[deployment.md](../../deployment.md) §9's restore-drill checklist.

Deliberately last: it protects data, and until Phase 8 there is no attachment data to protect. It should
not slip past Phase 10.

---

## 7. Dependency shape

Phases 0–4 are a single chain. From Phase 5 onward the graph is shallow and wide — four independent roots
hang off `D-5` (the one synced query):

```
D-5 ─┬─ P5.1 → P5.2 ─┬─ P5.3 → P5.4 → P5.5 ─┬─ P8.6 → P9.3
     │               │                      └─ P9.1
     │               ├─ P5.6 → P8.3
     │               ├─ P5.7
     │               ├─ P7.1 → P7.2 → P7.3 ─┬─ P7.4
     │               │                      └─ P7.5
     │               └─ P8.4 → P8.5 → P10.1
     ├─ P6.1 ─┬─ P6.2
     │        └─ P6.3 → P6.4 → P6.5 → P6.6 → P9.2
     └─ P8.1 → P8.2
```

The tree above shows each task's primary parent only; P8.2 additionally depends on P5.3.

Longest post-foundation path: 7 tasks (P5.1 → P5.2 → P5.3 → P5.4 → P5.5 → P8.6 → P9.3). Everything else
can be picked up in any order that respects an arrow, which is what criteria 2 and 5 reduce to for a
single developer.

---

## 8. Execution order

Every issue carries its position three ways, so the next thing to pick up is unambiguous from any view:

- **Title prefix** — `01 · [INFRA/DEVOPS]: P0.1 — …`, zero-padded so a title sort is an order sort.
- **Milestone** — `Phase 00` … `Phase 10`, giving per-phase progress and a filter
  (`gh issue list --milestone "Phase 05 — Issues + board"`).
- **Body banner** — the first line of every issue states its order, its phase, the issue to do before it,
  and — where the two differ — its actual hard dependency.

**The order column is a recommended sequence; the dependency column is the real constraint.** They are
deliberately different. Phases 0–4 are a chain, so there the two coincide. From Phase 5 on the graph is
wide (§7) and the sequence is one valid topological sort of many — a task whose hard dependency sits well
above its predecessor can be pulled forward freely. With one developer the sequence is what matters; the
dependency column is what makes reordering safe when priorities change.

`B-4` (order 11, [#14](https://github.com/vespaiach/team-works/issues/14)) is the publication migration
and the only task in the project that triggers [deployment.md](../../deployment.md) §8's replica reset.
Nothing after it carries a migration.

| # | Phase | Task | Issue | Deliverable | Hard dependency |
| --- | --- | --- | --- | --- | --- |
| 1 | 00 | `P0.1` | [#4](https://github.com/vespaiach/team-works/issues/4) | Provision the VPS and wire the deploy pipeline | — |
| 2 | 01 | `A-1` | [#5](https://github.com/vespaiach/team-works/issues/5) | Install the planned dependencies | #4 |
| 3 | 01 | `A-2` | [#6](https://github.com/vespaiach/team-works/issues/6) | Delete scaffold cruft, add `.nvmrc`, rewrite `.env.example` | #5 |
| 4 | 01 | `A-3` | [#7](https://github.com/vespaiach/team-works/issues/7) | Environment contract module | #6 |
| 5 | 01 | `A-4` | [#8](https://github.com/vespaiach/team-works/issues/8) | Vitest configuration | #7 |
| 6 | 01 | `A-5` | [#9](https://github.com/vespaiach/team-works/issues/9) | Playwright configuration | #8 |
| 7 | 01 | `A-6` | [#10](https://github.com/vespaiach/team-works/issues/10) | `zero-cache` Docker Compose + native Postgres checklist | #9 |
| 8 | 02 | `B-1` | [#11](https://github.com/vespaiach/team-works/issues/11) | Drizzle config, db client, `touched()` helper | #10 |
| 9 | 02 | `B-2` | [#12](https://github.com/vespaiach/team-works/issues/12) | Full schema — all fifteen tables | #11 |
| 10 | 02 | `B-3` | [#13](https://github.com/vespaiach/team-works/issues/13) | Migration tooling, rollback test harness, first round-trip test | #12 |
| 11 | 02 | `B-4` | [#14](https://github.com/vespaiach/team-works/issues/14) | Custom SQL migration — collation, composite FKs, dedup indexes, publication | #13 |
| 12 | 02 | `B-5` | [#15](https://github.com/vespaiach/team-works/issues/15) | Composite-FK cascade verification (data-model.md §8) | #14 |
| 13 | 02 | `B-6` | [#16](https://github.com/vespaiach/team-works/issues/16) | `admin:grant` and `db:seed` scripts | #15 |
| 14 | 02 | `B-7` | [#17](https://github.com/vespaiach/team-works/issues/17) | Sync-scope test — publication membership | #16 |
| 15 | 03 | `C-1` | [#18](https://github.com/vespaiach/team-works/issues/18) | `permissions.ts` — the pure predicate module | #17 |
| 16 | 03 | `C-2` | [#19](https://github.com/vespaiach/team-works/issues/19) | Token primitives, JWT, `requireUser()`, `loadActor()` | #18 |
| 17 | 03 | `C-3` | [#20](https://github.com/vespaiach/team-works/issues/20) | Supporting infra — mail, cookies, origin check, next-path validation | #19 |
| 18 | 03 | `C-4` | [#21](https://github.com/vespaiach/team-works/issues/21) | Sign-in and redemption | #20 |
| 19 | 03 | `C-5` | [#22](https://github.com/vespaiach/team-works/issues/22) | Refresh and rotation | #21 |
| 20 | 03 | `C-6` | [#23](https://github.com/vespaiach/team-works/issues/23) | Sign-out, invites, deactivation, and the last-admin guard | #22 |
| 21 | 03 | `C-7` | [#24](https://github.com/vespaiach/team-works/issues/24) | Route protection — `middleware.ts` | #23 |
| 22 | 03 | `C-8` | [#25](https://github.com/vespaiach/team-works/issues/25) | Boot-failure test and `auth:purge` | #24 |
| 23 | 04 | `D-1` | [#26](https://github.com/vespaiach/team-works/issues/26) | Zero client schema + schema-parity test | #25 |
| 24 | 04 | `D-2` | [#27](https://github.com/vespaiach/team-works/issues/27) | Verify `zero-cache` environment variables and image tag | #26 |
| 25 | 04 | `D-3` | [#28](https://github.com/vespaiach/team-works/issues/28) | Zero client construction | #27 |
| 26 | 04 | `D-4` | [#29](https://github.com/vespaiach/team-works/issues/29) | App shell — responsive layout, React Aria, sign-in page | #28 |
| 27 | 04 | `D-5` | [#30](https://github.com/vespaiach/team-works/issues/30) | The one synced query | #29 |
| 28 | 04 | `D-6` | [#31](https://github.com/vespaiach/team-works/issues/31) | E2E infrastructure — dockerized stack, fixtures | #30 |
| 29 | 04 | `D-7` | [#32](https://github.com/vespaiach/team-works/issues/32) | E2E scenario — sign-in | #31 |
| 30 | 04 | `D-8` | [#33](https://github.com/vespaiach/team-works/issues/33) | E2E verification — Postgres `date` mapping | #32 |
| 31 | 04 | `D-9` | [#34](https://github.com/vespaiach/team-works/issues/34) | E2E verification — Zero re-invokes `auth` on token rejection | #33 |
| 32 | 05 | `P5.1` | [#35](https://github.com/vespaiach/team-works/issues/35) | `createIssue` mutator and create form | #30 |
| 33 | 05 | `P5.2` | [#36](https://github.com/vespaiach/team-works/issues/36) | `updateIssue` mutator and issue detail view | #35 |
| 34 | 05 | `P5.3` | [#37](https://github.com/vespaiach/team-works/issues/37) | Kanban board, read-only | #36 |
| 35 | 05 | `P5.4` | [#38](https://github.com/vespaiach/team-works/issues/38) | Board drag-and-drop | #37 |
| 36 | 05 | `P5.5` | [#39](https://github.com/vespaiach/team-works/issues/39) | Board re-grouping by assignee and priority | #38 |
| 37 | 05 | `P5.6` | [#40](https://github.com/vespaiach/team-works/issues/40) | Delete and cancel an issue | #36 |
| 38 | 05 | `P5.7` | [#41](https://github.com/vespaiach/team-works/issues/41) | Disabled-control convention and the assigned-non-member state | #36 |
| 39 | 06 | `P6.1` | [#42](https://github.com/vespaiach/team-works/issues/42) | Project mutators and settings UI | #30 |
| 40 | 06 | `P6.2` | [#43](https://github.com/vespaiach/team-works/issues/43) | Project membership | #42 |
| 41 | 06 | `P6.3` | [#44](https://github.com/vespaiach/team-works/issues/44) | Milestones | #42 |
| 42 | 06 | `P6.4` | [#45](https://github.com/vespaiach/team-works/issues/45) | Frappe Gantt React wrapper | #44 |
| 43 | 06 | `P6.5` | [#46](https://github.com/vespaiach/team-works/issues/46) | Roadmap view | #45 |
| 44 | 06 | `P6.6` | [#47](https://github.com/vespaiach/team-works/issues/47) | Roadmap drag-to-reschedule | #46 |
| 45 | 07 | `P7.1` | [#48](https://github.com/vespaiach/team-works/issues/48) | Comments | #36 |
| 46 | 07 | `P7.2` | [#49](https://github.com/vespaiach/team-works/issues/49) | Mentions | #48 |
| 47 | 07 | `P7.3` | [#50](https://github.com/vespaiach/team-works/issues/50) | Notification creation | #49 |
| 48 | 07 | `P7.4` | [#51](https://github.com/vespaiach/team-works/issues/51) | In-app notification feed | #50 |
| 49 | 07 | `P7.5` | [#52](https://github.com/vespaiach/team-works/issues/52) | Email outbox and worker | #50 |
| 50 | 08 | `P8.1` | [#53](https://github.com/vespaiach/team-works/issues/53) | Label mutators and management UI | #30 |
| 51 | 08 | `P8.2` | [#54](https://github.com/vespaiach/team-works/issues/54) | Applying labels to issues | #53, #37 |
| 52 | 08 | `P8.3` | [#55](https://github.com/vespaiach/team-works/issues/55) | Sub-issues | #40 |
| 53 | 08 | `P8.4` | [#56](https://github.com/vespaiach/team-works/issues/56) | Attachment upload | #36 |
| 54 | 08 | `P8.5` | [#57](https://github.com/vespaiach/team-works/issues/57) | Attachment download, delete, and orphan reclamation | #56 |
| 55 | 08 | `P8.6` | [#58](https://github.com/vespaiach/team-works/issues/58) | Priority and due-date polish | #39 |
| 56 | 09 | `P9.1` | [#59](https://github.com/vespaiach/team-works/issues/59) | Responsive board on phones | #39 |
| 57 | 09 | `P9.2` | [#60](https://github.com/vespaiach/team-works/issues/60) | Responsive roadmap on phones | #47 |
| 58 | 09 | `P9.3` | [#61](https://github.com/vespaiach/team-works/issues/61) | Responsive issue detail and navigation | #58 |
| 59 | 10 | `P10.1` | [#62](https://github.com/vespaiach/team-works/issues/62) | Nightly backups and the restore drill | #57 |

---

## 9. Changes this spec requires elsewhere

- **`docs/superpowers/plans/2026-07-31-foundation-b-schema-sync-boundary.md`** — Task 2 gains
  `notification_email` ([notifications.md](../../notifications.md) §5), making it fifteen tables; Task 7's
  sync-scope assertion gains it to the list of tables required to be absent from the publication (§5.2
  above).
- **No spec changes.** This document reads the eight specs and contradicts none of them. The two gaps in
  §5 are plan gaps, not spec gaps.
- **`docs/HANDOFF.md`** — unaffected; its one remaining item (`non-functional.md`) is documentation work
  outside this breakdown.
