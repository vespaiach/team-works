# Team Works — data model

_Schema spec for v1. Companion to [team-works-concept-brief.md](./team-works-concept-brief.md) and [permissions.md](./permissions.md). Status: approved 2026-07-31._

This document is the source of truth for the Drizzle schema, the Postgres publication that defines Zero's sync set, and the Zero client schema. Section 3 of the concept brief sketches the entities; this document is the authority on their exact shape.

**Requires PostgreSQL 15 or later.** Two PG 15 features are load-bearing: column lists in publications (§3) and column-scoped `ON DELETE SET NULL` (§8).

---

## 1. Conventions

| Concern | Decision |
| --- | --- |
| Primary keys | `uuid`, UUIDv7, generated client-side via the `uuidv7` package |
| Enumerations | `text` + `CHECK (col IN (…))` |
| Calendar dates | `date` — `due_date`, `start_date`, `target_date` |
| Instants | `timestamptz` — `created_at`, `updated_at`, `read_at`, `emailed_at`, `deactivated_at` |
| Colors | `text CHECK (col ~ '^#[0-9a-f]{6}$')` — lowercase hex, six digits |
| Ordering | `sort_order text COLLATE "C" NOT NULL` — base-62 fractional index (§5) |
| Naming | `snake_case` tables and columns, singular table names |

### Why UUIDv7

Zero runs custom mutators optimistically on the client before the server sees them, so a row's id must exist before any server round-trip. That rules out `bigserial` and anything else server-assigned.

Among client-generatable options, UUIDv7 is time-ordered: sequential inserts land at the right edge of the B-tree rather than scattering across it. That matters twice — once in Postgres, and again in `zero-cache`'s SQLite replica, which indexes the same keys. It also makes `ORDER BY id` mean creation order, which §5 uses as the tie-break for equal sort keys.

The cost is one small dependency; `crypto.randomUUID()` produces v4, which is unordered.

### Why `text` + `CHECK` rather than `pgEnum`

Drizzle's `text('status', { enum: [...] })` produces exactly the same TypeScript literal union that `pgEnum` does, so nothing is lost on the type side. The difference is migration cost. Widening a `CHECK` is an ordinary `ALTER TABLE` that runs in a transaction and can be rolled back. `ALTER TYPE … ADD VALUE` has historically carried transaction restrictions, and removing an enum value is not supported at all — it requires creating a new type and rewriting every dependent column. Given that every migration here also has to be reasoned about against the `zero-cache` replica (§11), the cheaper primitive wins.

### Why `date` and not `timestamptz` for the three date fields

`due_date`, `start_date` and `target_date` are calendar dates, not instants. A target date of "September 30" is September 30 for everyone. Storing them as `timestamptz` would attach a time and a zone, and a Gantt bar rendered for a user in a different offset would land on the wrong day. `date` has no such failure mode.

### `updated_at` maintenance

Every server mutator sets `updated_at` explicitly. There is no database trigger.

The known hazard is that this is one line which must appear in every write path, and omitting it fails silently — a stale timestamp is not something a test naturally catches. Two mitigations, both required:

1. **A single helper.** Mutators never write `updated_at` by hand; they compose a `touched(fields)` helper that adds it. One call site to get right.

   ```ts
   const touched = <T extends object>(fields: T) => ({ ...fields, updated_at: new Date() })

   await db.update(issue).set(touched({ status })).where(eq(issue.id, id))
   ```

2. **A test that drives every mutator.** For each mutator that updates a row, read `updated_at`, invoke the mutator, assert the value advanced. This is the test that would otherwise not exist, so it is not optional.

The client's optimistic run sets its own `updated_at` so the UI has something to render immediately; the server's authoritative value arrives via replication a few milliseconds later and the client rebases. That correction is invisible and is the same reconciliation Zero performs for every other server-assigned value.

`DEFAULT now()` remains on the column as a backstop for seeds and direct SQL.

---

## 2. Table inventory

**Synced** — replicated to every client (§3):

`user`, `project`, `project_member`, `milestone`, `issue`, `label`, `issue_label`, `comment`, `attachment`, `notification`

**Not synced** — server-side only:

| Table | Owner |
| --- | --- |
| `issue_counter` | this document (§6) |
| `account`, `session`, `verification_token` | [auth.md](./auth.md), when written — Auth.js's own schema |
| `invite` | [auth.md](./auth.md), when written |

The auth tables are named here only to fix the publication boundary. Their columns are not this document's concern; what matters is that they are outside the sync set, as [permissions.md](./permissions.md) §4 requires.

---

## 3. The sync boundary

`zero-cache` replicates from a Postgres publication. PostgreSQL 15 allows a publication to specify a **column list** per table, which means the sync scope defined in permissions.md §4 is enforced at the replication boundary rather than in application code:

```sql
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

Three consequences worth stating:

- **The `user` restriction is physical.** A column added to `user` later — a password hash, a preferences blob, a last-seen timestamp — does not reach any client unless someone edits this publication. There is no code path that can leak it by accident.
- **`issue_counter` and the auth tables cannot be synced by mistake.** They are absent from the publication, so no Zero schema definition can pull them in.
- **Changing this publication is a migration.** It is one of the cases that may require a `zero-cache` replica reset; [deployment.md](./deployment.md), when written, owns that procedure.

The one per-user read rule — `notification.user_id === user.id` — is not expressed here. Publications replicate whole tables to `zero-cache`; the per-user filter lives in the Zero schema's read rule, applied when `zero-cache` serves a client. Every other table syncs in full, per permissions.md §4.

`ALTER TABLE … REPLICA IDENTITY FULL` is not required; every synced table has a primary key, which is what logical replication needs to identify rows for `UPDATE` and `DELETE`.

---

## 4. Deletion and cascades

**Deletes are hard.** `DELETE` in Postgres, propagated through the WAL to `zero-cache`, which drops the row from its replica and from every client's local store. This is the path Zero is built for.

There is no `deleted_at` column anywhere, because the reversible path already exists at the domain level and duplicating it would create two competing meanings of "gone":

- An **issue** that should go away but stay recoverable gets `status = 'canceled'`. permissions.md §3 makes this the members' path and reserves hard deletion for admins.
- A **project** likewise has `status = 'canceled'`.
- A **user** is never deleted at all. `deactivated_at` is set; the row, the `ProjectMember` rows, and all authored content survive (permissions.md §7).

Recovery from an unintended hard delete is a database restore. That is the accepted cost, and it is why the two destructive cases below are gated.

### Cascade matrix

| Deleting | Effect |
| --- | --- |
| `project` | **Rejected unless `status = 'canceled'`.** Then cascades to `milestone`, `issue` (and transitively `comment`, `attachment`, `issue_label`, `notification`), `project_member`, `issue_counter` |
| `issue` | Cascades to `comment`, `attachment`, `issue_label`, `notification`. Sub-issues are **promoted** to top-level — `ON DELETE SET NULL (parent_issue_id)` |
| `milestone` | `ON DELETE SET NULL (milestone_id)` on its issues. Issues outlive milestones |
| `comment` | Cascades to its `attachment` and `notification` rows |
| `label` | Cascades to `issue_label` |
| `attachment` | Row deleted. **The file on disk is not.** [attachments.md](./attachments.md), when written, owns orphan reclamation |
| `user` | Never deleted. Every FK referencing `user` is `ON DELETE RESTRICT`, so an attempted delete fails loudly rather than cascading through half the workspace |

### Why project deletion requires cancellation first

`deleteProject` throws unless the project's status is already `canceled`. Two deliberate steps, the first of which is reversible and already exists in the status enum. This extends the "members cancel, admins delete" grammar of permissions.md §3 one level up, and it gives the UI a natural moment to state the size of what is about to be destroyed.

The alternative — a single confirmation dialog — makes the largest irreversible action in the system one click deep, with recovery available only from backup.

### Why sub-issues are promoted, not cascaded

A sub-issue here is a full issue: its own permanent number, assignee, due date, priority, comments and attachments. Deleting a parent is a statement about the parent, not a licence to destroy the work nested beneath it. Promotion preserves everything; the children become ordinary top-level issues in the same project.

Invariant §9.2 (a sub-issue shares its parent's project) is trivially satisfied once there is no parent.

The mutator reports how many children will be promoted so the UI can say so before the fact.

### The optimistic-cascade gap

Cascades execute in Postgres. A client's optimistic mutator run cannot reproduce them — it deletes the row it was told about and nothing else. So a delete settles in two phases: the target disappears immediately, and the cascaded rows follow milliseconds later when replication catches up. In between, the client briefly holds orphans.

This is inherent to running referential actions in the database, and the fix is per-case rather than general:

- **Project delete** — the UI navigates away from the project immediately. Nothing that would flicker is still on screen.
- **Issue delete** — the client-side mutator performs the child promotion locally, matching what the server's `SET NULL` will do. The visible result is correct at once.
- **Comment and label delete** — the cascaded rows (attachments, notifications, join rows) are small in number and mostly not rendered next to the thing being deleted. Left to settle.

`ui-spec.md`, when written, should treat the two-phase settle as a known state rather than a bug report.

---

## 5. Ordering

`sort_order` is a **base-62 fractional index** — a string key, generated with the `fractional-indexing` package, ordered by plain byte comparison.

```
before:  "a0"        "a1"   "a2"
drop between a0 and a1  →  generateKeyBetween("a0", "a1") = "a0V"
after:   "a0" "a0V"  "a1"   "a2"

rows written: 1
```

### Why not integers or floats

The board is `dnd-kit` over Zero. A drop must compute its new position on the client, immediately, with no server round-trip. It must also touch exactly one row, because every row change travels through logical replication to `zero-cache` and out to every connected client — an integer scheme that renumbers a column on drop turns one gesture into N replicated updates, and races with other users' in-flight optimistic drags.

Floats update one row too, but a `double` exhausts its precision after roughly fifty successive halvings of the same gap, after which two issues collide silently and the column needs renumbering anyway.

Fractional indices have no such limit; keys simply grow longer.

### Scope: one key per issue, project-wide

An issue's `sort_order` places it in a **single ordered sequence across its whole project**. Every view is that one sequence, filtered:

```
project order:  A  B  C  D  E  F

grouped by status:          grouped by assignee:
  todo:         A  C  E       ana:  A  B  E
  in_progress:  B  D  F       bo:   C  D  F
```

The brief (§4) allows the board to re-group by assignee or priority. A per-column key would leave those groupings with no defined order and would force drag-to-reorder to be disabled in them. One project-wide key is always defined, in every grouping.

The consequence, which the UI should not hide: **reordering within the status board also changes relative position in the assignee grouping**, because there is only one order. This is the honest cost of the choice.

Milestones and projects order the same way — `milestone.sort_order` within its project, `project.sort_order` across the workspace for the roadmap's row order.

### Generating keys

| Situation | Call |
| --- | --- |
| New issue, appended | `generateKeyBetween(lastKey, null)` |
| Dropped between two rows | `generateKeyBetween(prevKey, nextKey)` |
| Dropped at the top | `generateKeyBetween(null, firstKey)` |
| First row in an empty project | `generateKeyBetween(null, null)` |
| Bulk insert (seeds, import) | `generateNKeysBetween(null, null, n)` |

`prevKey` and `nextKey` are read from the client's local replica — it holds the whole workspace, so the neighbours are always available without a query.

### Ties

Two clients dragging into the same slot simultaneously can generate the identical key. This is not an error and needs no repair: both rows exist, both are ordered correctly relative to everything else, and only their order *relative to each other* is unspecified.

**Every ordered query therefore sorts by `(sort_order, id)`.** Because ids are UUIDv7, the tie-break resolves to creation order, which is a defensible answer rather than an arbitrary one. There is no unique constraint on `sort_order`.

### `COLLATE "C"` is required

`fractional-indexing` assumes its keys compare by byte value. Base-62 keys contain digits, uppercase and lowercase letters, and under a locale collation such as `en_US.UTF-8` Postgres does **not** order those by byte value — case is folded into the comparison, so `"a0"` and `"A0"` sort adjacently instead of far apart. Ordering in Postgres would then disagree with ordering in the client.

Declaring the column `COLLATE "C"` pins byte ordering:

```sql
sort_order text COLLATE "C" NOT NULL
```

The other two engines already agree: `zero-cache`'s SQLite uses `BINARY` collation by default, and JavaScript's `<` on strings compares UTF-16 code units, which for the base-62 alphabet is byte order. Postgres is the only one that needs telling.

### Rebalancing

None in v1. Keys grow by roughly one character per repeated insertion into the same gap; reaching a length that matters requires thousands of drops into an identical position, which will not happen for a team under twenty. If it ever does, the repair is a one-off `generateNKeysBetween` pass over the affected project, run as a maintenance script. No scheduled job, no background process.

---

## 6. Issue identifiers

Issues are addressed as `WEB-142`: a per-project key and a per-project number.

```
project.key      text NOT NULL UNIQUE CHECK (key ~ '^[A-Z][A-Z0-9]{1,5}$')
issue.number     integer NOT NULL,  UNIQUE (project_id, number)
```

Both parts are permanent. `project.key` is set at creation and never editable, and permissions.md §6.3 already forbids an issue from changing project — so `WEB-142` identifies the same issue forever, and any link, bookmark or pasted reference stays valid. Making the key editable would break every existing `/WEB-142` URL at once, and a redirect table of retired keys is scope the brief does not have.

### The counter

```sql
CREATE TABLE issue_counter (
  project_id  uuid PRIMARY KEY REFERENCES project(id) ON DELETE CASCADE,
  next_number integer NOT NULL DEFAULT 1 CHECK (next_number >= 1)
);
```

Outside the publication, so it never syncs. Placing this counter as a column on `project` instead would mean every issue creation dirties the project row, replicating a project update to every connected client on every create — noise proportional to the busiest activity in the app.

`createProject` inserts the matching `issue_counter` row in the same transaction.

**Server**, in the same transaction as the issue insert:

```sql
UPDATE issue_counter
   SET next_number = next_number + 1
 WHERE project_id = $1
RETURNING next_number - 1 AS number;
```

The `UPDATE … RETURNING` takes a row lock, so concurrent creates in the same project serialize on it and cannot receive the same number.

**Client**, for the optimistic run: `max(number) + 1` over the issues it already holds for that project. The client has the entire workspace in its replica, so this needs no query and is usually correct.

It is a guess, and two cases make it wrong: two people creating an issue at the same moment, and creation after a deletion. **Numbers are monotonic and never reused** — the counter only moves forward — so after `WEB-9` is deleted the next issue is still `WEB-10`, while a client guessing from `max(number)` would say `WEB-9`. The server's value overwrites the guess on sync. The UI should therefore not treat a freshly created issue's number as stable until the write is confirmed; in practice the correction lands within the same interaction.

`UNIQUE (project_id, number)` is the backstop that turns any bug in the above into a loud failure rather than two issues sharing an identifier.

---

## 7. Schema

Common to every table: `id uuid PRIMARY KEY`, `created_at timestamptz NOT NULL DEFAULT now()`, and — where rows are mutable — `updated_at timestamptz NOT NULL DEFAULT now()`. Join tables and immutable rows carry `created_at` only, noted per table.

### `user`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | PK |
| `name` | `text NOT NULL` | display name |
| `email` | `text NOT NULL` | `UNIQUE (lower(email))` |
| `avatar_url` | `text` | nullable |
| `role` | `text NOT NULL DEFAULT 'member'` | `CHECK (role IN ('admin','member'))` |
| `deactivated_at` | `timestamptz` | null means active |
| `created_at` | `timestamptz NOT NULL` | |
| `updated_at` | `timestamptz NOT NULL` | |

Renamed from the brief: `avatar` → `avatar_url`, to say what it holds.

**Synced columns:** `id`, `name`, `email`, `avatar_url`, `role`, `deactivated_at`. `created_at` and `updated_at` stay server-side; nothing in the UI needs them.

`deactivated_at` is a change to permissions.md §4, which listed only the first five. Without it the client cannot distinguish an active user from a deactivated one, so the assignee picker would offer people who cannot act and old comments would render with no indication that their author has left. The column exposes nothing sensitive: who still works here is roster state, in a workspace that is already fully transparent by design.

The last admin cannot be deactivated (permissions.md §7). That is a mutator check in `deactivateUser` and `setUserRole`, not a constraint — Postgres cannot express "at least one row with `role = 'admin'` and `deactivated_at IS NULL`" without a trigger, and a trigger here would fire on ordinary profile edits.

### `project`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | PK |
| `key` | `text NOT NULL UNIQUE` | `CHECK (key ~ '^[A-Z][A-Z0-9]{1,5}$')`, immutable (§6) |
| `name` | `text NOT NULL` | `CHECK (length(btrim(name)) > 0)` |
| `description` | `text` | Markdown, nullable |
| `status` | `text NOT NULL DEFAULT 'planned'` | `CHECK (status IN ('planned','active','paused','completed','canceled'))` |
| `lead_id` | `uuid` | → `user(id)` `RESTRICT`, nullable. Informational only; grants nothing (permissions.md §2) |
| `start_date` | `date` | nullable |
| `target_date` | `date` | nullable |
| `color` | `text NOT NULL` | hex |
| `sort_order` | `text COLLATE "C" NOT NULL` | roadmap row order |
| `created_at`, `updated_at` | `timestamptz NOT NULL` | |

```sql
CHECK (start_date IS NULL OR target_date IS NULL OR start_date <= target_date)
```

Either date may be absent. A project with no dates has no bar on the roadmap; [roadmap-view.md](./roadmap-view.md), when written, owns how that renders.

### `project_member`

| Column | Type | Notes |
| --- | --- | --- |
| `project_id` | `uuid NOT NULL` | → `project(id)` `CASCADE` |
| `user_id` | `uuid NOT NULL` | → `user(id)` `RESTRICT` |
| `created_at` | `timestamptz NOT NULL` | |

`PRIMARY KEY (project_id, user_id)`. No role column, per permissions.md §2. No `updated_at` — the row has no mutable field; membership is added or removed, never edited.

### `milestone`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | PK |
| `project_id` | `uuid NOT NULL` | → `project(id)` `CASCADE` |
| `name` | `text NOT NULL` | `CHECK (length(btrim(name)) > 0)` |
| `target_date` | `date` | nullable |
| `sort_order` | `text COLLATE "C" NOT NULL` | within the project |
| `created_at`, `updated_at` | `timestamptz NOT NULL` | |

`UNIQUE (id, project_id)` — redundant on its own, but required as the target of `issue`'s composite foreign key (§8).

### `issue`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | PK |
| `project_id` | `uuid NOT NULL` | → `project(id)` `CASCADE`. Required, per permissions.md §6.1 |
| `number` | `integer NOT NULL` | `UNIQUE (project_id, number)` (§6) |
| `milestone_id` | `uuid` | nullable, composite FK (§8) |
| `parent_issue_id` | `uuid` | nullable, composite FK (§8) |
| `title` | `text NOT NULL` | `CHECK (length(btrim(title)) > 0)` |
| `description` | `text` | Markdown, nullable |
| `status` | `text NOT NULL DEFAULT 'backlog'` | `CHECK (status IN ('backlog','todo','in_progress','done','canceled'))` |
| `priority` | `text NOT NULL DEFAULT 'none'` | `CHECK (priority IN ('none','low','medium','high','urgent'))` |
| `assignee_id` | `uuid` | → `user(id)` `RESTRICT`, nullable |
| `due_date` | `date` | nullable |
| `created_by` | `uuid NOT NULL` | → `user(id)` `RESTRICT` |
| `sort_order` | `text COLLATE "C" NOT NULL` | project-wide (§5) |
| `created_at`, `updated_at` | `timestamptz NOT NULL` | |

`UNIQUE (id, project_id)` — target of the self-referential composite FK.
`CHECK (parent_issue_id IS NULL OR parent_issue_id <> id)` — an issue cannot parent itself.

An issue may be assigned to a non-member and to a user of any status; permissions.md §6 makes that explicit, and the assignee picker's ordering is a UI preference rather than a constraint. Assignment to a deactivated user is discouraged by hiding them in the picker, not forbidden by the schema — historical assignments must survive deactivation.

### `label`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | PK |
| `name` | `text NOT NULL` | `UNIQUE (lower(name))` |
| `color` | `text NOT NULL` | hex |
| `created_at`, `updated_at` | `timestamptz NOT NULL` | |

Workspace-wide set, curated by admins, applied by any member (permissions.md §3). Case-insensitive uniqueness prevents `Bug` and `bug` coexisting.

### `issue_label`

| Column | Type | Notes |
| --- | --- | --- |
| `issue_id` | `uuid NOT NULL` | → `issue(id)` `CASCADE` |
| `label_id` | `uuid NOT NULL` | → `label(id)` `CASCADE` |
| `created_at` | `timestamptz NOT NULL` | |

`PRIMARY KEY (issue_id, label_id)`. No `updated_at`.

### `comment`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | PK |
| `issue_id` | `uuid NOT NULL` | → `issue(id)` `CASCADE` |
| `author_id` | `uuid NOT NULL` | → `user(id)` `RESTRICT` |
| `body` | `text NOT NULL` | Markdown, `CHECK (length(btrim(body)) > 0)` |
| `created_at`, `updated_at` | `timestamptz NOT NULL` | |

`UNIQUE (id, issue_id)` — target of the composite FKs on `attachment` and `notification`.

Only the author may edit, and no one — admins included — may edit another user's comment (permissions.md §3). There is no tombstone: a deleted comment is gone, and the thread closes over it.

### `attachment`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | PK |
| `issue_id` | `uuid NOT NULL` | → `issue(id)` `CASCADE` |
| `comment_id` | `uuid` | nullable, composite FK (§8) `CASCADE` |
| `filename` | `text NOT NULL` | as uploaded, for display and download |
| `storage_path` | `text NOT NULL UNIQUE` | server-generated, relative to the attachments root |
| `content_type` | `text NOT NULL` | |
| `size_bytes` | `bigint NOT NULL` | `CHECK (size_bytes > 0)` |
| `uploaded_by` | `uuid NOT NULL` | → `user(id)` `RESTRICT` |
| `created_at` | `timestamptz NOT NULL` | |

No `updated_at` — an attachment row is immutable once written. Replacing a file means deleting the row and uploading again.

Renamed from the brief: `path` → `storage_path`, `size` → `size_bytes`.

**`issue_id` is `NOT NULL`; `comment_id` is the optional refinement.** The brief made both nullable, which admits a row belonging to neither. Here, an attachment always hangs off an issue, and `comment_id` names the comment it arrived in, when it arrived in one. "All attachments on this issue" is then a single indexed query with no union, and both cascade paths work: deleting the comment removes it, and so does deleting the issue.

`storage_path` is generated server-side and never derived from `filename`, which is user-supplied. `UNIQUE` on it prevents two rows claiming the same file, which would make orphan reclamation unsound. Path layout, size and MIME limits, the authorized-download route, and reclamation of files whose rows have been deleted are all owned by [attachments.md](./attachments.md).

### `notification`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | PK |
| `user_id` | `uuid NOT NULL` | recipient → `user(id)` `RESTRICT` |
| `actor_id` | `uuid NOT NULL` | who caused it → `user(id)` `RESTRICT` |
| `type` | `text NOT NULL` | `CHECK (type IN ('mention','assignment','comment'))` |
| `issue_id` | `uuid NOT NULL` | → `issue(id)` `CASCADE` |
| `comment_id` | `uuid` | nullable, composite FK (§8) `CASCADE` |
| `read_at` | `timestamptz` | null means unread |
| `emailed_at` | `timestamptz` | null means not yet emailed |
| `created_at` | `timestamptz NOT NULL` | |

```sql
CHECK (user_id <> actor_id)
CHECK (
  (type = 'assignment' AND comment_id IS NULL) OR
  (type = 'comment'    AND comment_id IS NOT NULL) OR
  (type = 'mention')
)
```

No `updated_at`; `read_at` and `emailed_at` are the only mutable fields and each is its own timestamp.

**`source_id` is gone.** The brief's single untyped pointer had no discriminator and could not be a foreign key. With hard deletes in force (§4) that is a live hazard: every delete mutator would have to remember to clean up matching notifications, and a single omission renders as a notification linking to nothing. Real foreign keys make the cleanup automatic.

**`actor_id` is new.** The brief has no way to say who caused a notification, which "Ana mentioned you" requires.

**`issue_id` is `NOT NULL`** because every notification type in v1 resolves to an issue, so the deep link `/WEB-142#comment-<id>` is always constructible without a join. `comment_id` refines it: an `assignment` has none, a `comment` notification always has one, and a `mention` has one when the mention was in a comment and none when it was in an issue description.

`CHECK (user_id <> actor_id)` encodes "you are not notified about your own actions" — assigning yourself or mentioning yourself produces nothing. It is written as a constraint rather than mutator logic because it is cheap and total. [notifications.md](./notifications.md) inherits this rule and may argue with it; if it does, the constraint is one migration to drop.

**Dedup and batching are not modelled here.** notifications.md owns that policy. When it settles one, the natural enforcement point is a partial unique index on this table — something in the shape of `UNIQUE (user_id, type, comment_id) WHERE comment_id IS NOT NULL` — and that document should specify it rather than leaving it to the mutator.

### `issue_counter`

Defined in §6. Not synced.

---

## 8. Composite foreign keys

Two of permissions.md's invariants, plus two of this document's, are enforced by the database rather than by mutator code. The technique is a composite foreign key against a redundant `UNIQUE (id, parent_key)`.

```sql
-- targets
ALTER TABLE milestone ADD UNIQUE (id, project_id);
ALTER TABLE issue     ADD UNIQUE (id, project_id);
ALTER TABLE comment   ADD UNIQUE (id, issue_id);

-- an issue's milestone must belong to the issue's project
ALTER TABLE issue ADD FOREIGN KEY (milestone_id, project_id)
  REFERENCES milestone (id, project_id)
  ON DELETE SET NULL (milestone_id);

-- a sub-issue must live in its parent's project  [permissions.md §6.2]
ALTER TABLE issue ADD FOREIGN KEY (parent_issue_id, project_id)
  REFERENCES issue (id, project_id)
  ON DELETE SET NULL (parent_issue_id);

-- an attachment's comment must be on the attachment's issue
ALTER TABLE attachment ADD FOREIGN KEY (comment_id, issue_id)
  REFERENCES comment (id, issue_id)
  ON DELETE CASCADE;

-- a notification's comment must be on the notification's issue
ALTER TABLE notification ADD FOREIGN KEY (comment_id, issue_id)
  REFERENCES comment (id, issue_id)
  ON DELETE CASCADE;
```

Each of these would otherwise be a mutator check that can be forgotten in a new write path, bypassed by a seed script, or violated by a manual `UPDATE` during an incident. As constraints they hold unconditionally.

The column-scoped `ON DELETE SET NULL (milestone_id)` is the PG 15 feature. Plain `SET NULL` nulls *every* column in the constraint, including `project_id`, which is `NOT NULL` — the delete would fail. Naming the column confines the effect to the one that is nullable, which is exactly the promote-on-delete behaviour §4 requires.

### The one thing to verify

The self-referential composite FK on `issue` interacts with the project-level `CASCADE`: deleting a project deletes parent and child issues in the same statement, while the parent FK simultaneously wants to null the child's `parent_issue_id`. Postgres is expected to handle this — self-referential referential actions are well-trodden — but it is the kind of interaction worth one explicit test rather than an assumption.

**Test:** create a project with a parent issue and two sub-issues, cancel it, delete it, assert the delete succeeds and all three issues are gone.

**If it fails:** drop the `parent_issue_id` composite FK, keep a plain self-FK with `ON DELETE SET NULL`, and enforce the same-project rule in `createIssue` and `updateIssue` as permissions.md §6.2 originally specified. Nothing else in this document changes.

---

## 9. Invariants

permissions.md §6 defines three. This document keeps all three and adds five, with the enforcement point named for each.

| # | Invariant | Enforced by |
| --- | --- | --- |
| 1 | Every issue belongs to a project | `issue.project_id NOT NULL` |
| 2 | A sub-issue lives in the same project as its parent | composite FK (§8) — *was* a mutator check in permissions.md §6.2 |
| 3 | An issue cannot change project | `updateIssue` |
| 4 | An issue's milestone belongs to the issue's project | composite FK (§8) |
| 5 | Nesting is one level: a parent has `parent_issue_id IS NULL` | `createIssue`, `updateIssue` |
| 6 | `project.key` is immutable after creation | `updateProject` |
| 7 | A project cannot be deleted unless `status = 'canceled'` | `deleteProject` |
| 8 | Issue numbers are monotonic per project and never reused | `issue_counter` (§6) |

### On #5

A sub-issue cannot itself have sub-issues. The board card, the issue detail page and any progress rollup then have a single, known shape, and none of the machinery arbitrary nesting requires — cycle detection on every reparent, a depth cap, a recursive rollup, a rule for how far promote-on-delete reaches — needs to exist.

Combined with #2, cycles are structurally impossible: a cycle needs a parent that is itself a child, and #5 forbids exactly that. The `parent_issue_id <> id` check covers the degenerate one-row case.

This is easy to relax later and hard to tighten once people have built deep trees.

---

## 10. Indexes

Beyond the primary keys and unique constraints already stated.

| Table | Index | For |
| --- | --- | --- |
| `user` | `UNIQUE (lower(email))` | login lookup, invite collision |
| `project` | `(sort_order)` | roadmap row order |
| `project` | `(lead_id)` | "projects I lead" |
| `project_member` | `(user_id)` | the actor's membership set, read on every mutation |
| `milestone` | `(project_id, sort_order)` | milestone list |
| `issue` | `(project_id, sort_order)` | the board's primary read |
| `issue` | `(project_id, status)` | column counts, filters |
| `issue` | `(assignee_id) WHERE assignee_id IS NOT NULL` | "my issues" |
| `issue` | `(milestone_id) WHERE milestone_id IS NOT NULL` | milestone rollup |
| `issue` | `(parent_issue_id) WHERE parent_issue_id IS NOT NULL` | sub-issue list |
| `issue` | `(due_date) WHERE due_date IS NOT NULL` | overdue queries |
| `issue_label` | `(label_id)` | "issues with this label"; the PK covers the other direction |
| `comment` | `(issue_id, created_at)` | thread render |
| `comment` | `(author_id)` | authorship checks, user activity |
| `attachment` | `(issue_id)` | issue attachment list |
| `attachment` | `(comment_id) WHERE comment_id IS NOT NULL` | comment attachment list |
| `notification` | `(user_id, created_at DESC)` | the notification feed |
| `notification` | `(user_id) WHERE read_at IS NULL` | unread badge count |

`project_member (user_id)` is the hottest of these: permissions.md §8 has the server derive the actor's membership set on every mutation, so it is read on every write in the system.

**These indexes serve the server.** They support the Drizzle mutators and `zero-cache`'s initial snapshot. Client queries do not use them — ZQL runs against the client's own local store, and `zero-cache` maintains its own SQLite indexes over the replica. Adding an index here does not speed up a client query, and a slow client query is not fixed by touching this table.

---

## 11. Zero client schema

The Zero schema mirrors the publication (§3) — the same ten tables, and for `user` the same six columns. It is a separate declaration from the Drizzle schema and must be kept in step; a mismatch surfaces as a sync error rather than a type error, so a test that asserts the two agree earns its keep.

Type mapping:

| Postgres | Zero client |
| --- | --- |
| `uuid` | `string` |
| `text` | `string` |
| `integer`, `bigint` | `number` |
| `timestamptz` | `number` (epoch ms) |
| `boolean` | `boolean` |

`size_bytes` is `bigint` in Postgres and arrives as a JavaScript `number`. File sizes are far below 2^53, so no precision is lost.

### The `date` mapping — verify during Foundation

I have not confirmed how the pinned version of Zero maps Postgres `date`. Both branches are decided in advance so this cannot become a blocking question:

- **If Zero maps `date`** — use `date`, as §1 and §7 specify. Nothing changes.
- **If it does not** — the three columns (`issue.due_date`, `project.start_date`, `project.target_date`) become `text` holding ISO `YYYY-MM-DD`, with `CHECK (col ~ '^\d{4}-\d{2}-\d{2}$')`. Lexical ordering matches chronological ordering for that format, so range queries and `ORDER BY` still work. The reason for avoiding `timestamptz` (§1) applies to this fallback too and is why the fallback is `text` rather than an instant.

Resolve this in build step 1 and record the outcome here.

### The one read rule

```
notification: user_id === auth.userId
```

Everything else syncs in full. permissions.md §4 and §8 are the authority; the permission predicates in `src/lib/permissions.ts` are deliberately not consumed by the read rules.

### Migrations and the replica

`zero-cache` holds a replica built from the publication. Some schema changes require it to be reset and re-seeded rather than picked up incrementally — changing the publication itself is the clearest case. [deployment.md](./deployment.md), when written, owns the procedure and the decision rule for which migrations need it. This document only flags that the question exists and that the publication in §3 is where it bites.

---

## 12. Changes this spec requires elsewhere

### To [permissions.md](./permissions.md) — applied 2026-07-31, the documents now agree

- **§4** — `deactivated_at` added to the synced `User` columns, with the reasoning from §7 of this document.
- **§5** — `deleteProject` gains the precondition `status = 'canceled'`; `createIssue` and `updateIssue` gain the one-level nesting check.
- **§6** — invariant 2's enforcement moves from mutator to schema; five invariants added (§9 here is the full list).

### To [team-works-concept-brief.md](./team-works-concept-brief.md) — applied 2026-07-31

- **§3** — entity field lists reconciled with §7 here: `Project.key`, `Issue.number`, `User.deactivated_at`, `avatar` → `avatar_url`, the attachment and notification reshapes, `sort_order` described as a fractional index.

### To the repository scaffold — not yet applied

The current scaffold is unmodified output from a generic project generator and does not match the brief. Nothing in this document can be implemented against it as it stands.

- `package.json` has only `next`, `react`, `react-dom` and Tailwind. It needs `drizzle-orm`, `drizzle-kit`, `pg`, `@rocicorp/zero`, `uuidv7` and `fractional-indexing` before any of this schema exists — and, per the brief's stack, `next-auth`, `react-aria-components`, `@dnd-kit/core` and `frappe-gantt` for the rest.
- `src/lib/db.ts` and `src/types/index.ts` are generator output. `src/types/index.ts` defines a `User` shape unrelated to §7. Both should be deleted rather than adapted.
- `.env.example` carries a placeholder `SECRET_KEY`. auth.md owns the real environment contract; the placeholder should not survive into it.
- `README.md` still describes the project as scaffolder output.

### Deferred, with owners named

| Question | Owner |
| --- | --- |
| Notification dedup and batching, and the partial unique index that enforces it | notifications.md |
| Whether `CHECK (user_id <> actor_id)` survives | notifications.md |
| Mention parsing and dispatch — this document fixes only the stored form, `@[Display Name](user:<uuid>)` | notifications.md |
| On-disk path layout, size and MIME limits, authorized download, orphan reclamation | attachments.md |
| Which migrations force a `zero-cache` replica reset | deployment.md |
| Rendering of projects and milestones with absent dates | roadmap-view.md |
| The two-phase settle after a cascading delete, as a UI state | ui-spec.md |
| Whether closing a parent closes its sub-issues; whether all-done issues complete a milestone | state-machines.md |

---

_Decisions here are settled. Revise deliberately, and reconcile permissions.md and the concept brief in the same change._
