# Foundation B: Database Schema & Zero Sync Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the full Drizzle schema for all fifteen tables, the `zero_data` publication that defines Zero's sync boundary, and the migration/seed/admin tooling around them — so Plan C (auth) has `user`/`invite`/`login_token`/`session` to write against and Plan D (Zero + permissions + shell) has a real publication to sync from.

**Architecture:** Schema lives in `src/lib/db/schema/*.ts`, one file per entity group, re-exported from an `index.ts` barrel. Everything expressible in Drizzle's `pgTable` API (columns, simple FKs, single-table `CHECK`s, ordinary and partial indexes) is declared there and captured by `drizzle-kit generate`. The handful of things Drizzle cannot express — `COLLATE "C"`, the two self-referential/cross-table composite foreign keys with column-scoped `ON DELETE SET NULL`, the two partial unique indexes on `notification`, and `CREATE PUBLICATION` itself — go in one hand-written custom SQL migration applied immediately after the generated one. This plan assumes **Foundation A is complete** (dependencies installed, `env.ts` exists, `team_works_dev` and `team_works_test` databases exist natively with `wal_level=logical`).

**Tech Stack:** `drizzle-orm`, `drizzle-kit`, `pg`, `uuidv7`, `fractional-indexing` (all installed in Plan A).

## Global Constraints

- PostgreSQL 15+ (column-list publications, column-scoped `ON DELETE SET NULL` — both load-bearing, data-model.md §0/§8).
- `snake_case`, singular table names (data-model.md §1).
- Primary keys are client-generated UUIDv7 via the `uuidv7` package — never `gen_random_uuid()` or `bigserial` (data-model.md §1).
- Enums are `text` + `CHECK`, never `pgEnum` (data-model.md §1).
- `sort_order` is `text COLLATE "C" NOT NULL`, a base-62 fractional index (data-model.md §5).
- `updated_at` is set by mutators via a `touched()` helper, never by a trigger (data-model.md §1) — this plan defines the helper; nothing calls it yet since no mutators exist until build step 2+.
- **Deletes are hard.** No `deleted_at` column anywhere (data-model.md §4).
- Migrations are versioned SQL files applied explicitly (`drizzle-kit generate` + a migrate script) — never `drizzle-kit push` (local-dev.md §5).
- Every FK to `user` is `ON DELETE RESTRICT` (data-model.md §4) — users are never deleted, only deactivated.

---

## File Structure

```
drizzle.config.ts                              # new
src/lib/db/client.ts                            # new — drizzle(pool, {schema})
src/lib/db/touched.ts                           # new
src/lib/db/schema/types.ts                      # new — bytea customType
src/lib/db/schema/user.ts                       # new
src/lib/db/schema/project.ts                    # new — project, project_member, milestone
src/lib/db/schema/issue.ts                      # new — issue, issue_counter
src/lib/db/schema/collab.ts                     # new — label, issue_label, comment, attachment, notification, notification_email
src/lib/db/schema/auth.ts                       # new — invite, login_token, session
src/lib/db/schema/index.ts                      # new — barrel re-export
drizzle/                                        # generated migrations (drizzle-kit output)
scripts/migrate.ts                              # new
scripts/admin-grant.ts                          # new
scripts/db-seed.ts                              # new
tests/db.ts                                     # new — withTx harness
tests/factories.ts                              # new
tests/integration/schema-roundtrip.test.ts      # new
tests/integration/composite-fk-cascade.test.ts  # new
tests/integration/publication.test.ts           # new
package.json                                    # modified — scripts
```

---

### Task 1: Drizzle config, db client, `touched()` helper

**Files:**
- Create: `drizzle.config.ts`, `src/lib/db/client.ts`, `src/lib/db/touched.ts`

**Interfaces:**
- Consumes: `process.env.DATABASE_URL` directly (not `src/lib/env.ts` — `drizzle-kit` runs as a standalone CLI process and shouldn't require the full 11-variable contract just to generate a migration).
- Produces: `db` (Drizzle instance, exported from `src/lib/db/client.ts`) and `touched<T>(fields: T)` — both imported by every later task in this plan and by Plans C/D.

- [ ] **Step 1: Write `drizzle.config.ts`**

```ts
import { defineConfig } from 'drizzle-kit'

export default defineConfig({
  dialect: 'postgresql',
  schema: './src/lib/db/schema/index.ts',
  out: './drizzle',
  dbCredentials: { url: process.env.DATABASE_URL! },
})
```

- [ ] **Step 2: Write `src/lib/db/touched.ts`**

data-model.md §1: "Mutators never write `updated_at` by hand; they compose a `touched(fields)` helper that adds it."

```ts
export function touched<T extends object>(fields: T): T & { updatedAt: Date } {
  return { ...fields, updatedAt: new Date() }
}
```

- [ ] **Step 3: Write `src/lib/db/client.ts`**

This imports `./schema`, which does not exist until Task 2 — leave the import in place; it resolves once Task 2 lands, and nothing in this task runs the file standalone.

```ts
import { drizzle } from 'drizzle-orm/node-postgres'
import { Pool } from 'pg'
import * as schema from './schema'

const pool = new Pool({ connectionString: process.env.DATABASE_URL })
export const db = drizzle(pool, { schema })
export type Db = typeof db
// The transaction handle drizzle's db.transaction() callback receives. Exported
// from production code (not just the test harness) because every DB-touching
// function in Plans B/C/D accepts an optional trailing `handle: Db | Tx = db`
// parameter — testing.md §3's constraint that a mutator must take its db handle
// as a parameter rather than importing the module-level singleton, so tests can
// inject a rolled-back transaction. `tests/db.ts` (Task 3) imports this type
// rather than redeclaring it.
export type Tx = Parameters<Parameters<typeof db.transaction>[0]>[0]
```

- [ ] **Step 4: Commit**

```bash
git add drizzle.config.ts src/lib/db/client.ts src/lib/db/touched.ts
git commit -m "chore: add drizzle config, db client, touched() helper"
```

---

### Task 2: Full schema — all fifteen tables

**Files:**
- Create: `src/lib/db/schema/types.ts`, `src/lib/db/schema/user.ts`, `src/lib/db/schema/project.ts`, `src/lib/db/schema/issue.ts`, `src/lib/db/schema/collab.ts`, `src/lib/db/schema/auth.ts`, `src/lib/db/schema/index.ts`

**Interfaces:**
- Produces: every table export later tasks, Plan C and Plan D import by name — `user`, `project`, `projectMember`, `milestone`, `issue`, `issueCounter`, `label`, `issueLabel`, `comment`, `attachment`, `notification`, `notificationEmail`, `invite`, `loginToken`, `session`.
- Note on partial indexes: this task uses Drizzle's `.on(...).where(sql\`...\`)` index builder for the six partial indexes named in data-model.md §10 (`issue.assignee_id`, `issue.milestone_id`, `issue.parent_issue_id`, `issue.due_date`, `attachment.comment_id`, `notification` unread) and the two `lower(email)`/`lower(name)` functional unique indexes. Confirm during Step 8 (generated-SQL review) that the installed `drizzle-kit` version actually emits the `WHERE` clause and the `lower(...)` expression — if it silently drops either, move the affected index into Task 4's custom migration instead (same SQL, just hand-written) rather than leaving it missing.

- [ ] **Step 1: `bytea` custom type**

Drizzle's `pgTable` API has no built-in `bytea` column; `login_token.token_hash` and `session.token_hash`/`prev_token_hash` (auth.md §3) need one for the SHA-256 digest storage.

```ts
// src/lib/db/schema/types.ts
import { customType } from 'drizzle-orm/pg-core'

export const bytea = customType<{ data: Buffer }>({
  dataType() {
    return 'bytea'
  },
})
```

- [ ] **Step 2: `user`**

```ts
// src/lib/db/schema/user.ts
import { pgTable, uuid, text, timestamp, check, uniqueIndex } from 'drizzle-orm/pg-core'
import { sql } from 'drizzle-orm'

export const user = pgTable('user', {
  id: uuid('id').primaryKey(),
  name: text('name').notNull(),
  email: text('email').notNull(),
  avatarUrl: text('avatar_url'),
  role: text('role').notNull().default('member'),
  deactivatedAt: timestamp('deactivated_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
}, (table) => ({
  emailUq: uniqueIndex('user_email_uq').on(sql`lower(${table.email})`),
  roleCheck: check('user_role_check', sql`${table.role} IN ('admin','member')`),
}))
```

Note the rename from the brief: `avatar` → `avatar_url` (data-model.md §7). Synced columns are `id, name, email, avatar_url, role, deactivated_at` — `created_at`/`updated_at` stay server-side; that narrowing is enforced by the publication in Task 4, not by this file.

- [ ] **Step 3: `project`, `project_member`, `milestone`**

```ts
// src/lib/db/schema/project.ts
import { pgTable, uuid, text, date, timestamp, primaryKey, unique, index, check } from 'drizzle-orm/pg-core'
import { sql } from 'drizzle-orm'
import { user } from './user'

export const project = pgTable('project', {
  id: uuid('id').primaryKey(),
  key: text('key').notNull().unique(),
  name: text('name').notNull(),
  description: text('description'),
  status: text('status').notNull().default('planned'),
  leadId: uuid('lead_id').references(() => user.id, { onDelete: 'restrict' }),
  startDate: date('start_date'),
  targetDate: date('target_date'),
  color: text('color').notNull(),
  sortOrder: text('sort_order').notNull(), // COLLATE "C" applied in Task 4's custom migration
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
}, (table) => ({
  keyCheck: check('project_key_check', sql`${table.key} ~ '^[A-Z][A-Z0-9]{1,5}$'`),
  nameCheck: check('project_name_check', sql`length(btrim(${table.name})) > 0`),
  statusCheck: check('project_status_check', sql`${table.status} IN ('planned','active','paused','completed','canceled')`),
  colorCheck: check('project_color_check', sql`${table.color} ~ '^#[0-9a-f]{6}$'`),
  dateOrderCheck: check('project_date_order_check', sql`${table.startDate} IS NULL OR ${table.targetDate} IS NULL OR ${table.startDate} <= ${table.targetDate}`),
  sortOrderIdx: index('project_sort_order_idx').on(table.sortOrder),
  leadIdx: index('project_lead_id_idx').on(table.leadId),
}))

export const projectMember = pgTable('project_member', {
  projectId: uuid('project_id').notNull().references(() => project.id, { onDelete: 'cascade' }),
  userId: uuid('user_id').notNull().references(() => user.id, { onDelete: 'restrict' }),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
}, (table) => ({
  pk: primaryKey({ columns: [table.projectId, table.userId] }),
  userIdx: index('project_member_user_id_idx').on(table.userId),
}))

export const milestone = pgTable('milestone', {
  id: uuid('id').primaryKey(),
  projectId: uuid('project_id').notNull().references(() => project.id, { onDelete: 'cascade' }),
  name: text('name').notNull(),
  targetDate: date('target_date'),
  sortOrder: text('sort_order').notNull(), // COLLATE "C" applied in Task 4
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
}, (table) => ({
  nameCheck: check('milestone_name_check', sql`length(btrim(${table.name})) > 0`),
  idProjectUq: unique('milestone_id_project_id_uq').on(table.id, table.projectId),
  projectSortIdx: index('milestone_project_id_sort_order_idx').on(table.projectId, table.sortOrder),
}))
```

`milestone_id_project_id_uq` exists only as the target of `issue`'s composite FK (data-model.md §7, §8) — it looks redundant in isolation and is not.

- [ ] **Step 4: `issue`, `issue_counter`**

```ts
// src/lib/db/schema/issue.ts
import { pgTable, uuid, text, integer, date, timestamp, unique, index, check } from 'drizzle-orm/pg-core'
import { sql } from 'drizzle-orm'
import { user } from './user'
import { project } from './project'

export const issue = pgTable('issue', {
  id: uuid('id').primaryKey(),
  projectId: uuid('project_id').notNull().references(() => project.id, { onDelete: 'cascade' }),
  number: integer('number').notNull(),
  // milestoneId / parentIssueId: plain columns here, composite FKs added in Task 4's
  // custom migration (data-model.md §8) — a single-column .references() here would
  // conflict with the composite constraint that supersedes it.
  milestoneId: uuid('milestone_id'),
  parentIssueId: uuid('parent_issue_id'),
  title: text('title').notNull(),
  description: text('description'),
  status: text('status').notNull().default('backlog'),
  priority: text('priority').notNull().default('none'),
  assigneeId: uuid('assignee_id').references(() => user.id, { onDelete: 'restrict' }),
  dueDate: date('due_date'),
  createdBy: uuid('created_by').notNull().references(() => user.id, { onDelete: 'restrict' }),
  sortOrder: text('sort_order').notNull(), // COLLATE "C" applied in Task 4
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
}, (table) => ({
  numberUq: unique('issue_project_id_number_uq').on(table.projectId, table.number),
  idProjectUq: unique('issue_id_project_id_uq').on(table.id, table.projectId),
  titleCheck: check('issue_title_check', sql`length(btrim(${table.title})) > 0`),
  statusCheck: check('issue_status_check', sql`${table.status} IN ('backlog','todo','in_progress','done','canceled')`),
  priorityCheck: check('issue_priority_check', sql`${table.priority} IN ('none','low','medium','high','urgent')`),
  noSelfParentCheck: check('issue_no_self_parent_check', sql`${table.parentIssueId} IS NULL OR ${table.parentIssueId} <> ${table.id}`),
  projectSortIdx: index('issue_project_id_sort_order_idx').on(table.projectId, table.sortOrder),
  projectStatusIdx: index('issue_project_id_status_idx').on(table.projectId, table.status),
  assigneeIdx: index('issue_assignee_id_idx').on(table.assigneeId).where(sql`${table.assigneeId} IS NOT NULL`),
  milestoneIdx: index('issue_milestone_id_idx').on(table.milestoneId).where(sql`${table.milestoneId} IS NOT NULL`),
  parentIdx: index('issue_parent_issue_id_idx').on(table.parentIssueId).where(sql`${table.parentIssueId} IS NOT NULL`),
  dueDateIdx: index('issue_due_date_idx').on(table.dueDate).where(sql`${table.dueDate} IS NOT NULL`),
}))

export const issueCounter = pgTable('issue_counter', {
  projectId: uuid('project_id').primaryKey().references(() => project.id, { onDelete: 'cascade' }),
  nextNumber: integer('next_number').notNull().default(1),
}, (table) => ({
  nextNumberCheck: check('issue_counter_next_number_check', sql`${table.nextNumber} >= 1`),
}))
```

`issue_counter` is deliberately outside the publication (Task 4) — data-model.md §6: placing the counter on `project` would replicate a project update to every client on every issue creation.

- [ ] **Step 5: `label`, `issue_label`, `comment`, `attachment`, `notification`**

```ts
// src/lib/db/schema/collab.ts
import { pgTable, uuid, text, integer, bigint, timestamp, primaryKey, unique, uniqueIndex, index, check } from 'drizzle-orm/pg-core'
import { sql } from 'drizzle-orm'
import { user } from './user'
import { issue } from './issue'

export const label = pgTable('label', {
  id: uuid('id').primaryKey(),
  name: text('name').notNull(),
  color: text('color').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
}, (table) => ({
  nameUq: uniqueIndex('label_name_uq').on(sql`lower(${table.name})`),
  colorCheck: check('label_color_check', sql`${table.color} ~ '^#[0-9a-f]{6}$'`),
}))

export const issueLabel = pgTable('issue_label', {
  issueId: uuid('issue_id').notNull().references(() => issue.id, { onDelete: 'cascade' }),
  labelId: uuid('label_id').notNull().references(() => label.id, { onDelete: 'cascade' }),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
}, (table) => ({
  pk: primaryKey({ columns: [table.issueId, table.labelId] }),
  labelIdx: index('issue_label_label_id_idx').on(table.labelId),
}))

export const comment = pgTable('comment', {
  id: uuid('id').primaryKey(),
  issueId: uuid('issue_id').notNull().references(() => issue.id, { onDelete: 'cascade' }),
  authorId: uuid('author_id').notNull().references(() => user.id, { onDelete: 'restrict' }),
  body: text('body').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
}, (table) => ({
  bodyCheck: check('comment_body_check', sql`length(btrim(${table.body})) > 0`),
  idIssueUq: unique('comment_id_issue_id_uq').on(table.id, table.issueId),
  issueCreatedIdx: index('comment_issue_id_created_at_idx').on(table.issueId, table.createdAt),
  authorIdx: index('comment_author_id_idx').on(table.authorId),
}))

export const attachment = pgTable('attachment', {
  id: uuid('id').primaryKey(),
  issueId: uuid('issue_id').notNull().references(() => issue.id, { onDelete: 'cascade' }),
  // commentId: composite FK added in Task 4 (must match issue_id on the target comment)
  commentId: uuid('comment_id'),
  filename: text('filename').notNull(),
  storagePath: text('storage_path').notNull().unique(),
  contentType: text('content_type').notNull(),
  sizeBytes: bigint('size_bytes', { mode: 'number' }).notNull(),
  uploadedBy: uuid('uploaded_by').notNull().references(() => user.id, { onDelete: 'restrict' }),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
}, (table) => ({
  sizeCheck: check('attachment_size_check', sql`${table.sizeBytes} > 0`),
  issueIdx: index('attachment_issue_id_idx').on(table.issueId),
  commentIdx: index('attachment_comment_id_idx').on(table.commentId).where(sql`${table.commentId} IS NOT NULL`),
}))

export const notification = pgTable('notification', {
  id: uuid('id').primaryKey(),
  userId: uuid('user_id').notNull().references(() => user.id, { onDelete: 'restrict' }),
  actorId: uuid('actor_id').notNull().references(() => user.id, { onDelete: 'restrict' }),
  type: text('type').notNull(),
  issueId: uuid('issue_id').notNull().references(() => issue.id, { onDelete: 'cascade' }),
  // commentId: composite FK added in Task 4
  commentId: uuid('comment_id'),
  readAt: timestamp('read_at', { withTimezone: true }),
  emailedAt: timestamp('emailed_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
}, (table) => ({
  typeCheck: check('notification_type_check', sql`${table.type} IN ('mention','assignment','comment')`),
  notSelfCheck: check('notification_not_self_check', sql`${table.userId} <> ${table.actorId}`),
  typeCommentCheck: check(
    'notification_type_comment_check',
    sql`(${table.type} = 'assignment' AND ${table.commentId} IS NULL) OR (${table.type} = 'comment' AND ${table.commentId} IS NOT NULL) OR (${table.type} = 'mention')`
  ),
  userCreatedIdx: index('notification_user_id_created_at_idx').on(table.userId, table.createdAt),
  unreadIdx: index('notification_user_id_unread_idx').on(table.userId).where(sql`${table.readAt} IS NULL`),
  // the two partial UNIQUE indexes (dedup) are added in Task 4 — Drizzle's index()
  // builder here is not declared unique because the WHERE-scoped uniqueness
  // combination is safer to hand-verify against the spec's literal SQL.
}))

// notifications.md §5 — the email outbox. NOT synced: it is absent from the
// publication (Task 4), and Task 7 asserts that. One row per notification,
// inserted in the same transaction as the notification itself.
export const notificationEmail = pgTable('notification_email', {
  id: uuid('id').primaryKey(),
  notificationId: uuid('notification_id').notNull().references(() => notification.id, { onDelete: 'cascade' }),
  status: text('status').notNull().default('pending'),
  attempts: integer('attempts').notNull().default(0),
  nextAttemptAt: timestamp('next_attempt_at', { withTimezone: true }).notNull().defaultNow(),
  lastError: text('last_error'),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  // deliberately no updated_at — status/attempts/next_attempt_at are worker
  // bookkeeping, and notifications.md §5 defines no updated_at for this table.
}, (table) => ({
  statusCheck: check('notification_email_status_check', sql`${table.status} IN ('pending','sent','failed')`),
  // Derived from notifications.md §5's worker query ("status = 'pending' AND
  // next_attempt_at <= now(), oldest first"), not stated as an index in that
  // document. Drop it if the generated SQL review in Step 8 shows it is redundant.
  pendingIdx: index('notification_email_pending_idx').on(table.nextAttemptAt).where(sql`${table.status} = 'pending'`),
}))
```

`integer` joins the `drizzle-orm/pg-core` import list at the top of this file for `attempts`.

- [ ] **Step 6: `invite`, `login_token`, `session`**

```ts
// src/lib/db/schema/auth.ts
import { pgTable, uuid, text, timestamp, unique, uniqueIndex, index, check } from 'drizzle-orm/pg-core'
import { sql } from 'drizzle-orm'
import { user } from './user'
import { bytea } from './types'

export const invite = pgTable('invite', {
  id: uuid('id').primaryKey(),
  email: text('email').notNull(),
  name: text('name'),
  role: text('role').notNull().default('member'),
  invitedBy: uuid('invited_by').notNull().references(() => user.id, { onDelete: 'restrict' }),
  expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  acceptedAt: timestamp('accepted_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
}, (table) => ({
  emailUq: uniqueIndex('invite_email_uq').on(sql`lower(${table.email})`),
  roleCheck: check('invite_role_check', sql`${table.role} IN ('admin','member')`),
}))

export const loginToken = pgTable('login_token', {
  id: uuid('id').primaryKey(),
  tokenHash: bytea('token_hash').notNull().unique(),
  email: text('email').notNull(),
  expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  consumedAt: timestamp('consumed_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  // deliberately no updated_at (data-model.md §12) — consumed_at is the only mutation
}, (table) => ({
  emailLiveIdx: index('login_token_email_live_idx').on(table.email).where(sql`${table.consumedAt} IS NULL`),
  expiresIdx: index('login_token_expires_at_idx').on(table.expiresAt),
}))

export const session = pgTable('session', {
  id: uuid('id').primaryKey(),
  userId: uuid('user_id').notNull().references(() => user.id, { onDelete: 'restrict' }),
  tokenHash: bytea('token_hash').notNull().unique(),
  prevTokenHash: bytea('prev_token_hash').unique(),
  rotatedAt: timestamp('rotated_at', { withTimezone: true }),
  expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  userAgent: text('user_agent'),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  lastUsedAt: timestamp('last_used_at', { withTimezone: true }).notNull().defaultNow(),
}, (table) => ({
  userIdx: index('session_user_id_idx').on(table.userId),
  expiresIdx: index('session_expires_at_idx').on(table.expiresAt),
}))
```

These three are **outside the publication** — fixed in Task 4, owned in detail by Plan C.

- [ ] **Step 7: Barrel export**

```ts
// src/lib/db/schema/index.ts
export * from './user'
export * from './project'
export * from './issue'
export * from './collab'
export * from './auth'
```

- [ ] **Step 8: Generate the migration and review it before applying anything**

```bash
npm run db:generate
```

(This script doesn't exist until Task 3 adds it — for this step, run the underlying command directly: `npx drizzle-kit generate`.)

Open the generated file under `drizzle/0000_*.sql` and check, against data-model.md §7/§10:
- All fifteen tables are present with `snake_case` names.
- Every `CHECK` constraint from Step 2–6 appears.
- Partial indexes (`WHERE ... IS NOT NULL`) and the two `lower(...)` functional indexes render correctly — **if any silently dropped their predicate or expression**, note it here and move that specific index into Task 4's custom migration by hand instead.

Do not apply this migration yet — Task 3 does that as part of its own test cycle.

- [ ] **Step 9: Commit**

```bash
git add src/lib/db/schema drizzle
git commit -m "feat: add full drizzle schema for all fifteen tables"
```

---

### Task 3: Migration tooling, transaction-rollback test harness, and the first round-trip test

**Files:**
- Create: `scripts/migrate.ts`, `tests/db.ts`, `tests/factories.ts`, `tests/integration/schema-roundtrip.test.ts`
- Modify: `package.json` (scripts)

**Interfaces:**
- Consumes: `db` (Task 1), the schema barrel (Task 2).
- Produces: `withTx(fn)` and `Tx` (used by every integration test in this plan and Plans C/D), `makeUser`/`makeProject`/`makeIssue` factories (extended by Plans C/D, not replaced), `npm run db:migrate`.

- [ ] **Step 1: Write the migration runner**

local-dev.md §5: "`drizzle-kit generate` + a migrate script — versioned SQL files, applied explicitly, rather than `drizzle-kit push`."

```ts
// scripts/migrate.ts
import { drizzle } from 'drizzle-orm/node-postgres'
import { migrate } from 'drizzle-orm/node-postgres/migrator'
import { Pool } from 'pg'

async function main() {
  const pool = new Pool({ connectionString: process.env.DATABASE_URL })
  const db = drizzle(pool)
  await migrate(db, { migrationsFolder: './drizzle' })
  await pool.end()
  console.log('Migrations applied.')
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
```

Add to `package.json`:

```json
"db:generate": "drizzle-kit generate",
"db:migrate": "tsx scripts/migrate.ts"
```

- [ ] **Step 2: Write the transaction-rollback test harness**

testing.md §3, code sample adapted to this project's `db` export.

```ts
// tests/db.ts
import { db, type Tx } from '@/lib/db/client'

export type { Tx }

// drizzle-orm's node-postgres driver throws a specific error when tx.rollback()
// is called deliberately inside a transaction callback — confirm the exact
// error shape against the installed drizzle-orm version (record it in Task 1
// of foundation-a-tooling.md alongside the other pinned-version notes) and
// adjust this check if it differs.
function isRollback(e: unknown): boolean {
  return e instanceof Error && e.message === 'Rollback'
}

export async function withTx<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
  let result!: T
  await db
    .transaction(async (tx) => {
      result = await fn(tx)
      tx.rollback()
    })
    .catch((e) => {
      if (!isRollback(e)) throw e
    })
  return result
}
```

- [ ] **Step 3: Write the fixture factories**

```ts
// tests/factories.ts
import { uuidv7 } from 'uuidv7'
import { generateKeyBetween } from 'fractional-indexing'
import type { Tx } from './db'
import { user, project, issueCounter, issue } from '@/lib/db/schema'

export function randomEmail() {
  return `test-${uuidv7()}@example.com`
}

export function randomProjectKey() {
  return 'T' + Math.random().toString(36).slice(2, 6).toUpperCase()
}

export async function makeUser(tx: Tx, overrides: Partial<typeof user.$inferInsert> = {}) {
  const [row] = await tx
    .insert(user)
    .values({ id: uuidv7(), name: 'Test User', email: randomEmail(), role: 'member', ...overrides })
    .returning()
  return row
}

export async function makeProject(tx: Tx, overrides: Partial<typeof project.$inferInsert> = {}) {
  const [row] = await tx
    .insert(project)
    .values({
      id: uuidv7(),
      key: randomProjectKey(),
      name: 'Test Project',
      status: 'planned',
      color: '#3366ff',
      sortOrder: generateKeyBetween(null, null),
      ...overrides,
    })
    .returning()
  await tx.insert(issueCounter).values({ projectId: row.id, nextNumber: 1 })
  return row
}

export async function makeIssue(
  tx: Tx,
  overrides: Partial<typeof issue.$inferInsert> & { projectId: string; createdBy: string }
) {
  const [row] = await tx
    .insert(issue)
    .values({
      id: uuidv7(),
      number: Math.floor(Math.random() * 1_000_000),
      title: 'Test issue',
      status: 'backlog',
      priority: 'none',
      sortOrder: generateKeyBetween(null, null),
      ...overrides,
    })
    .returning()
  return row
}
```

- [ ] **Step 4: Write the failing round-trip test**

```ts
// tests/integration/schema-roundtrip.test.ts
import { describe, it, expect } from 'vitest'
import { withTx } from '../db'
import { makeUser, makeProject, makeIssue } from '../factories'

describe('schema round-trip', () => {
  it('inserts and reads back a user, a project, and an issue', async () => {
    await withTx(async (tx) => {
      const u = await makeUser(tx, { name: 'Ada' })
      expect(u.role).toBe('member')

      const p = await makeProject(tx, { name: 'Launch' })
      expect(p.status).toBe('planned')

      const i = await makeIssue(tx, { projectId: p.id, createdBy: u.id, title: 'First issue' })
      expect(i.status).toBe('backlog')
      expect(i.projectId).toBe(p.id)
    })
  })
})
```

- [ ] **Step 5: Run it, verify it fails**

```bash
DATABASE_URL=postgresql://team_works@localhost:5432/team_works_test npm run test:integration
```

Expected: FAIL — `relation "user" does not exist` (no migration applied yet).

- [ ] **Step 6: Apply the migration to `team_works_test`**

```bash
DATABASE_URL=postgresql://team_works@localhost:5432/team_works_test npm run db:migrate
```

- [ ] **Step 7: Run the test again, verify it passes**

```bash
DATABASE_URL=postgresql://team_works@localhost:5432/team_works_test npm run test:integration
```

Expected: PASS.

- [ ] **Step 8: Apply the same migration to `team_works_dev`**

```bash
npm run db:migrate
```

(Uses `DATABASE_URL` from `.env.local`, per local-dev.md §5 — run it once after cloning and after every pull that touches the schema.)

- [ ] **Step 9: Commit**

```bash
git add scripts/migrate.ts tests/db.ts tests/factories.ts tests/integration/schema-roundtrip.test.ts package.json
git commit -m "feat: add migration runner and transaction-rollback test harness"
```

---

### Task 4: Custom SQL migration — collation, composite FKs, dedup indexes, publication

**Files:**
- Create: one custom migration file under `drizzle/` (exact name assigned by `drizzle-kit generate --custom`)

**Interfaces:**
- Produces: the `zero_data` publication Plan D's Zero client schema mirrors, and the composite FKs Task 5's cascade test exercises.

- [ ] **Step 1: Scaffold an empty custom migration**

```bash
npx drizzle-kit generate --custom --name=composite_fks_and_publication
```

- [ ] **Step 2: Fill it in**

Copied from data-model.md §5 (collation), §8 (composite FKs, verbatim), §7 (notification dedup indexes, verbatim), and §3 (publication, verbatim):

```sql
-- Collation: fractional-indexing keys must compare by byte value (data-model.md §5)
ALTER TABLE project   ALTER COLUMN sort_order TYPE text COLLATE "C";
ALTER TABLE milestone ALTER COLUMN sort_order TYPE text COLLATE "C";
ALTER TABLE issue     ALTER COLUMN sort_order TYPE text COLLATE "C";

-- Composite foreign keys (data-model.md §8)
ALTER TABLE issue ADD CONSTRAINT issue_milestone_project_fk
  FOREIGN KEY (milestone_id, project_id)
  REFERENCES milestone (id, project_id)
  ON DELETE SET NULL (milestone_id);

ALTER TABLE issue ADD CONSTRAINT issue_parent_project_fk
  FOREIGN KEY (parent_issue_id, project_id)
  REFERENCES issue (id, project_id)
  ON DELETE SET NULL (parent_issue_id);

ALTER TABLE attachment ADD CONSTRAINT attachment_comment_issue_fk
  FOREIGN KEY (comment_id, issue_id)
  REFERENCES comment (id, issue_id)
  ON DELETE CASCADE;

ALTER TABLE notification ADD CONSTRAINT notification_comment_issue_fk
  FOREIGN KEY (comment_id, issue_id)
  REFERENCES comment (id, issue_id)
  ON DELETE CASCADE;

-- Notification dedup: at most one notification per user per comment,
-- and at most one mention notification per user per issue description (data-model.md §7)
CREATE UNIQUE INDEX notification_user_comment_uq
  ON notification (user_id, comment_id)
  WHERE comment_id IS NOT NULL;

CREATE UNIQUE INDEX notification_user_issue_mention_uq
  ON notification (user_id, issue_id)
  WHERE type = 'mention' AND comment_id IS NULL;

-- Zero sync boundary (data-model.md §3)
CREATE PUBLICATION zero_data FOR TABLE
  "user" (id, name, email, avatar_url, role, deactivated_at),
  project,
  project_member,
  milestone,
  issue,
  label,
  issue_label,
  comment,
  attachment,
  notification;
```

- [ ] **Step 3: Apply to both databases**

```bash
DATABASE_URL=postgresql://team_works@localhost:5432/team_works_test npm run db:migrate
npm run db:migrate
```

- [ ] **Step 4: Commit**

```bash
git add drizzle
git commit -m "feat: add composite FKs, dedup indexes, and zero_data publication"
```

---

### Task 5: The composite-FK cascade verification (data-model.md §8 — "the one thing to verify")

**Files:**
- Test: `tests/integration/composite-fk-cascade.test.ts`

**Interfaces:**
- Consumes: `withTx`, `makeUser`, `makeProject`, `makeIssue` (Task 3).

data-model.md §8: "**Test:** create a project with a parent issue and two sub-issues, cancel it, delete it, assert the delete succeeds and all three issues are gone." This is one of the three verifications concept-brief §6 names as blocking for build step 1.

- [ ] **Step 1: Write the test**

```ts
// tests/integration/composite-fk-cascade.test.ts
import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { withTx } from '../db'
import { project, issue } from '@/lib/db/schema'
import { makeUser, makeProject, makeIssue } from '../factories'

describe('composite FK cascade on project delete (data-model.md §8)', () => {
  it('deletes a canceled project and all of its issues, including sub-issues, in one statement', async () => {
    await withTx(async (tx) => {
      const author = await makeUser(tx)
      const proj = await makeProject(tx)
      const parent = await makeIssue(tx, { projectId: proj.id, createdBy: author.id })
      const childA = await makeIssue(tx, { projectId: proj.id, createdBy: author.id, parentIssueId: parent.id })
      const childB = await makeIssue(tx, { projectId: proj.id, createdBy: author.id, parentIssueId: parent.id })

      await tx.update(project).set({ status: 'canceled' }).where(eq(project.id, proj.id))
      await tx.delete(project).where(eq(project.id, proj.id))

      const remainingInProject = await tx.select().from(issue).where(eq(issue.projectId, proj.id))
      expect(remainingInProject).toHaveLength(0)

      for (const id of [parent.id, childA.id, childB.id]) {
        const row = await tx.select().from(issue).where(eq(issue.id, id))
        expect(row).toHaveLength(0)
      }
    })
  })
})
```

- [ ] **Step 2: Run it**

```bash
DATABASE_URL=postgresql://team_works@localhost:5432/team_works_test npm run test:integration
```

- [ ] **Step 3a: If it passes** — commit as-is. This is now a permanent regression test (testing.md §5), not a one-off spike.

- [ ] **Step 3b: If it fails** — apply data-model.md §8's named fallback rather than debugging the interaction further:

1. Drop the two `issue` composite FKs from Task 4's migration (`issue_milestone_project_fk` stays; only `issue_parent_project_fk` is implicated by the self-reference — data-model.md §8 says drop it specifically) via a new migration.
2. Replace it with a plain self-referential FK: `ALTER TABLE issue ADD CONSTRAINT issue_parent_fk FOREIGN KEY (parent_issue_id) REFERENCES issue(id) ON DELETE SET NULL;`
3. Enforce "a sub-issue lives in the same project as its parent" (permissions.md §6.2) as a mutator check instead, in whichever module build step 2 puts `createIssue`/`updateIssue` — leave a comment there pointing at this decision.
4. Rewrite this test to assert the same end state through the plain FK, and keep it green.

Either branch, nothing else in this plan changes.

- [ ] **Step 4: Commit**

```bash
git add tests/integration/composite-fk-cascade.test.ts
git commit -m "test: verify composite FK cascade on project delete (data-model.md §8)"
```

---

### Task 6: `admin:grant` and `db:seed` scripts

**Files:**
- Create: `scripts/admin-grant.ts`, `scripts/db-seed.ts`
- Modify: `package.json` (scripts)

**Interfaces:**
- Consumes: `db` (Task 1), schema (Task 2).
- Produces: `npm run admin:grant -- --email=... --name=...`, `npm run db:seed` — both referenced by local-dev.md §6–7 and by auth.md §4.6 (break-glass recovery).

- [ ] **Step 1: `admin:grant`**

auth.md §4.6: "creates the `user` row if absent, sets `role = 'admin'`, and clears `deactivated_at`. It sends no email."

```ts
// scripts/admin-grant.ts
import { uuidv7 } from 'uuidv7'
import { eq } from 'drizzle-orm'
import { db } from '../src/lib/db/client'
import { user } from '../src/lib/db/schema'

function parseArgs(argv: string[]): Record<string, string> {
  const out: Record<string, string> = {}
  for (const arg of argv) {
    const m = arg.match(/^--([^=]+)=(.*)$/)
    if (m) out[m[1]] = m[2]
  }
  return out
}

async function main() {
  const { email, name } = parseArgs(process.argv.slice(2))
  if (!email) {
    throw new Error('Usage: npm run admin:grant -- --email=you@example.com --name="Your Name"')
  }

  const normalized = email.trim().toLowerCase()
  const [existing] = await db.select().from(user).where(eq(user.email, normalized))

  if (existing) {
    await db
      .update(user)
      .set({ role: 'admin', deactivatedAt: null, updatedAt: new Date() })
      .where(eq(user.id, existing.id))
    console.log(`Granted admin to existing user ${normalized}`)
  } else {
    await db.insert(user).values({
      id: uuidv7(),
      name: name ?? normalized.split('@')[0],
      email: normalized,
      role: 'admin',
    })
    console.log(`Created admin user ${normalized}`)
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err)
    process.exit(1)
  })
```

- [ ] **Step 2: `db:seed`**

local-dev.md §7's fixture shape, inserted directly (not through the invite flow).

```ts
// scripts/db-seed.ts
import { uuidv7 } from 'uuidv7'
import { eq } from 'drizzle-orm'
import { generateKeyBetween } from 'fractional-indexing'
import { db } from '../src/lib/db/client'
import { user, project, issueCounter, issue, milestone, label, issueLabel } from '../src/lib/db/schema'

async function main() {
  const [admin] = await db.select().from(user).limit(1)
  if (!admin) {
    throw new Error('Run `npm run admin:grant` first — db:seed adds a second user, not the first.')
  }

  const [member] = await db
    .insert(user)
    .values({ id: uuidv7(), name: 'Sam Member', email: 'sam@example.com', role: 'member' })
    .returning()

  const [projA] = await db
    .insert(project)
    .values({ id: uuidv7(), key: 'WEB', name: 'Website Redesign', status: 'active', color: '#3366ff', sortOrder: generateKeyBetween(null, null) })
    .returning()
  await db.insert(issueCounter).values({ projectId: projA.id, nextNumber: 1 })

  const [projB] = await db
    .insert(project)
    .values({ id: uuidv7(), key: 'OPS', name: 'Internal Ops', status: 'planned', color: '#22aa66', sortOrder: generateKeyBetween(null, null) })
    .returning()
  await db.insert(issueCounter).values({ projectId: projB.id, nextNumber: 1 })

  const [ms] = await db
    .insert(milestone)
    .values({ id: uuidv7(), projectId: projA.id, name: 'Launch', sortOrder: generateKeyBetween(null, null) })
    .returning()

  const [bug, feature] = await db
    .insert(label)
    .values([
      { id: uuidv7(), name: 'bug', color: '#dd3333' },
      { id: uuidv7(), name: 'feature', color: '#3333dd' },
    ])
    .returning()

  const seedIssues = [
    { projectId: projA.id, title: 'Set up design tokens', status: 'done', priority: 'medium', assigneeId: admin.id, milestoneId: ms.id },
    { projectId: projA.id, title: 'Build the board view', status: 'in_progress', priority: 'high', assigneeId: member.id, milestoneId: ms.id },
    { projectId: projA.id, title: 'Fix header overflow on mobile', status: 'todo', priority: 'low', assigneeId: member.id, milestoneId: null },
    { projectId: projB.id, title: 'Rotate SMTP credentials', status: 'backlog', priority: 'urgent', assigneeId: admin.id, milestoneId: null },
    { projectId: projB.id, title: 'Document the deploy runbook', status: 'todo', priority: 'none', assigneeId: admin.id, milestoneId: null },
    { projectId: projB.id, title: 'Old ticketing import cleanup', status: 'canceled', priority: 'none', assigneeId: member.id, milestoneId: null },
  ] as const

  const nextNumber: Record<string, number> = { [projA.id]: 1, [projB.id]: 1 }
  const lastKey: Record<string, string | null> = { [projA.id]: null, [projB.id]: null }
  const inserted: { id: string }[] = []

  for (const s of seedIssues) {
    const number = nextNumber[s.projectId]++
    const sortOrder = generateKeyBetween(lastKey[s.projectId], null)
    lastKey[s.projectId] = sortOrder

    const [row] = await db
      .insert(issue)
      .values({
        id: uuidv7(),
        number,
        title: s.title,
        status: s.status,
        priority: s.priority,
        assigneeId: s.assigneeId,
        projectId: s.projectId,
        milestoneId: s.milestoneId ?? undefined,
        createdBy: admin.id,
        sortOrder,
      })
      .returning()
    inserted.push(row)
  }

  for (const [projectId, next] of Object.entries(nextNumber)) {
    await db.update(issueCounter).set({ nextNumber: next }).where(eq(issueCounter.projectId, projectId))
  }

  await db.insert(issueLabel).values([
    { issueId: inserted[0].id, labelId: bug.id },
    { issueId: inserted[1].id, labelId: feature.id },
  ])

  console.log('Seed complete: 1 admin (pre-existing), 1 member, 2 projects, 1 milestone, 6 issues, 2 labels.')
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err)
    process.exit(1)
  })
```

- [ ] **Step 3: Add npm scripts**

```json
"admin:grant": "tsx scripts/admin-grant.ts",
"db:seed": "tsx scripts/db-seed.ts"
```

- [ ] **Step 4: Run both against `team_works_dev` and verify manually**

```bash
npm run admin:grant -- --email=you@example.com --name="Your Name"
npm run db:seed
```

Verify with `psql team_works_dev -c "select key, name, status from project;"` — expect `WEB` and `OPS`, and `select count(*) from issue;` — expect `6`.

- [ ] **Step 5: Commit**

```bash
git add scripts/admin-grant.ts scripts/db-seed.ts package.json
git commit -m "feat: add admin:grant and db:seed scripts"
```

---

### Task 7: Sync-scope test — publication membership (testing.md §6)

**Files:**
- Test: `tests/integration/publication.test.ts`

**Interfaces:**
- Consumes: `db` (Task 1). Runs against committed DDL state (the publication itself), not inside `withTx` — `CREATE PUBLICATION` already happened in Task 4's migration, so this test only reads catalog views.

- [ ] **Step 1: Write the test**

testing.md §6: "Query `pg_publication_tables` and `pg_publication_columns` for `zero_data`; assert exactly the ten tables in data-model.md §3 and, for `user`, exactly the six listed columns. Assert `invite`, `login_token`, `session` and `issue_counter` are absent."

`notification_email` (notifications.md §5) joins that exclusion list — it postdates testing.md §6's wording, but it is a non-synced server table under exactly the same rule.

```ts
// tests/integration/publication.test.ts
import { describe, it, expect } from 'vitest'
import { sql } from 'drizzle-orm'
import { db } from '@/lib/db/client'

const SYNCED_TABLES = [
  'user', 'project', 'project_member', 'milestone', 'issue',
  'label', 'issue_label', 'comment', 'attachment', 'notification',
].sort()

const USER_SYNCED_COLUMNS = ['id', 'name', 'email', 'avatar_url', 'role', 'deactivated_at'].sort()

describe('zero_data publication (data-model.md §3)', () => {
  it('publishes exactly the ten synced tables', async () => {
    const result = await db.execute<{ tablename: string }>(
      sql`SELECT tablename FROM pg_publication_tables WHERE pubname = 'zero_data'`
    )
    const tables = result.rows.map((r) => r.tablename).sort()
    expect(tables).toEqual(SYNCED_TABLES)
  })

  it('publishes only the six documented columns for "user"', async () => {
    // pg_publication_tables.attnames (PG15+) lists the published column list per table.
    // Confirm the exact result shape (array vs. brace-string) against the pg driver in
    // use — node-postgres parses text[] natively, so this should already be a string[].
    const result = await db.execute<{ attnames: string[] }>(
      sql`SELECT attnames FROM pg_publication_tables WHERE pubname = 'zero_data' AND tablename = 'user'`
    )
    const cols = [...result.rows[0].attnames].sort()
    expect(cols).toEqual(USER_SYNCED_COLUMNS)
  })

  it('never publishes the non-synced server tables', async () => {
    const result = await db.execute<{ tablename: string }>(
      sql`SELECT tablename FROM pg_publication_tables WHERE pubname = 'zero_data'`
    )
    const tables = result.rows.map((r) => r.tablename)
    for (const excluded of ['issue_counter', 'invite', 'login_token', 'session', 'notification_email']) {
      expect(tables).not.toContain(excluded)
    }
  })
})
```

- [ ] **Step 2: Run it**

```bash
DATABASE_URL=postgresql://team_works@localhost:5432/team_works_test npm run test:integration
```

Expected: PASS — the publication was created in Task 4.

- [ ] **Step 3: Commit**

```bash
git add tests/integration/publication.test.ts
git commit -m "test: verify zero_data publication membership and column list"
```

---

## Self-Review

**Spec coverage.** data-model.md §1 (conventions) → Task 2 throughout. §3 (publication) → Task 4, verified in Task 7. §4 (cascades) → Task 4's composite FKs, verified in Task 5. §5 (ordering, collation) → Task 4 Step 2. §6 (issue identifiers, counter) → Task 2 Step 4, exercised by Task 6's seed. §7 (full schema) → Task 2 Steps 2–6. §8 (composite FKs + the one verification) → Task 4 + Task 5. §9 (invariants 1, 4, 5, 6, 8) → schema-level (`NOT NULL`, composite FK, checks); invariants 2/3/7 are mutator-enforced and belong to build step 2+, out of scope here. §10 (indexes) → Task 2. §11 (Zero client schema, `date` mapping) → explicitly **not** in this plan; it belongs to Plan D, which owns the Zero client and can actually run the verification against a live `zero-cache`. local-dev.md §5–7 (migrations, admin bootstrap, seed) → Task 3, Task 6. testing.md §3 (transaction harness), §5 (cascade regression test), §6 (sync-scope tests) → Task 3, Task 5, Task 7.

**Placeholder scan.** No TODOs. The one open branch (Task 5's fallback) is a named, fully-specified alternative from data-model.md §8 itself, not a placeholder — the plan states both outcomes concretely rather than assuming the happy path.

**Type consistency.** `Tx` (Task 3) is the type every later integration test in this plan and in Plans C/D imports from `tests/db.ts`. Table export names (`user`, `project`, `projectMember`, `milestone`, `issue`, `issueCounter`, `label`, `issueLabel`, `comment`, `attachment`, `notification`, `notificationEmail`, `invite`, `loginToken`, `session`) are fixed in Task 2 and used identically in Tasks 3, 5, 6, 7 — Plan C and Plan D should import these same names rather than re-declaring them.

---

**Plan complete and saved to `docs/superpowers/plans/2026-07-31-foundation-b-schema-sync-boundary.md`.**
