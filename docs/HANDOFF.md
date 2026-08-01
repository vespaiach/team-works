# Team Works — documentation continuation

_Handoff prompt. Paste the whole file into a fresh session to continue the documentation work. Delete it once the doc backlog is done._

Repo: `/Users/toannguyen/team-works` (branch: `main`)

## What this is

Team Works: a self-hosted, Linear-inspired work tracker for one team of <20 people. Milestone/roadmap-driven rather than sprint-driven. Local-first.

Stack (all decided, do not re-litigate): Next.js App Router + React, Adobe React Aria Components, Zero (Rocicorp) for sync + optimistic mutations, PostgreSQL 15+ with logical replication, Drizzle on server-side mutators, hand-written magic-link invite-only auth (no Auth.js), dnd-kit for the board, frappe-gantt for the roadmap, attachments on local disk, single VPS running app + zero-cache container + Postgres + nginx.

## Docs that already exist — READ ALL FOUR FIRST

- `docs/team-works-concept-brief.md` — architecture brief, all v1 decisions settled
- `docs/permissions.md` — authorization spec, approved and final
- `docs/data-model.md` — schema spec: columns, cascades, ordering, identifiers, indexes, invariants, the publication
- `docs/auth.md` — authentication spec: invites, magic links, sessions and rotation, revocation, env contract

## Decisions from permissions.md that constrain everything downstream

Treat these as settled. Do not reopen them.

- Two roles only: `User.role` = `admin` | `member` (workspace-level)
- `ProjectMember(project_id, user_id)`. **No role column.** `Project.lead` is informational only.
- **Reads are workspace-wide.** Every user reads every project. Membership gates **writes** only.
- Zero read rules are near-trivial: the entire syncable dataset syncs to every client, except `Notification` rows, which scope to their owner. That is the only read rule.
- Accepted limitation: no confidential projects in v1.
- `Issue.project_id` is `NOT NULL` (changed from the brief).
- A sub-issue must live in the same project as its parent.
- An issue cannot change project in v1.
- Issues may be assigned to non-members; @mentions may name anyone. Pickers list project members first, everyone else below — UI preference, not an enforced rule.
- Members set `status = 'canceled'`; only admins hard-delete.
- Admins curate the global label set; any member applies labels.
- Comments and attachments carry an authorship check: edit your own only. Admins may delete anyone's, but nobody may edit another user's comment.
- Admins own project settings, milestones, membership, invites, roles.
- Authorization lives in `src/lib/permissions.ts`: pure predicates, no I/O, consumed by (1) server mutators — authoritative — and (2) the client, for disabling controls and for Zero's optimistic client-side mutator run. Zero read rules do **not** consume it.
- The JWT carries user id + workspace role only. Membership is resolved server-side.

## Repo scaffold does not match the brief

Flag this; don't silently code around it. `package.json` has only Next 14 / React / Tailwind. Missing: Drizzle, Zero, React Aria, dnd-kit, frappe-gantt, `jose`, `nodemailer` — and explicitly **not** `next-auth`. `src/types/index.ts` has an unrelated `User` shape. `.env.example` still has a placeholder `SECRET_KEY`, superseded by auth.md §10. (`README.md` and `CLAUDE.md` have since been rewritten.)

## Remaining docs, in priority order

### ~~1. `docs/data-model.md`~~ — done

### ~~2. `docs/auth.md`~~ — done

### ~~3. `docs/local-dev.md`~~ — done

### ~~4. `docs/ui-spec.md`~~ — done

### ~~5. `docs/notifications.md`~~ — done

### ~~6. `docs/attachments.md`~~ — done

### ~~7. `docs/roadmap-view.md`~~ — done

### 8. `docs/deployment.md`

Runbook. Provisioning, nginx, Certbot, PM2/systemd, backups (Postgres + attachment disk), restore drill. Critically: the **schema migration procedure including how the `zero-cache` replica is handled** — a migration can require a replica reset.

### 9. `docs/adr/`

One short ADR per settled decision in brief §7. Zero and frappe-gantt matter most; they're the ones you'd revisit.

### 10. `docs/state-machines.md`

Issue and project status transitions, legal moves, side effects (does closing a parent close sub-issues? do all-done issues complete a milestone?).

### 11. `docs/testing.md`

Testing a Zero app: mutator unit tests, permission predicate tests, sync-scope tests, whether E2E runs against a real `zero-cache`.

### 12. `docs/non-functional.md`

Browser support, perf budgets, data volume, retention.

### ~~13. `README.md` rewrite and `CLAUDE.md`~~ — done

## How to work

Use the brainstorming skill. Ask **one question at a time**, multiple-choice where possible. Present the design and get approval **before** writing the file. Then write, self-review for placeholders, contradictions, and ambiguity, and commit.

Every doc ends with a "changes this spec requires elsewhere" section, and any contradiction it creates with `team-works-concept-brief.md` or the other docs gets reconciled immediately in the same session — grep for the affected terms rather than trusting the list, since that is how a fifth contradiction turned up last time. `README.md` and `CLAUDE.md` now count as reconciliation targets too.

Start with `docs/deployment.md`.
