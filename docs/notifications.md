# Team Works — notifications

_Notification spec for v1. Companion to [data-model.md](./data-model.md), [permissions.md](./permissions.md), [auth.md](./auth.md) and [ui-spec.md](./ui-spec.md). Status: approved 2026-07-31._

HANDOFF called this "the least-specified feature." This document fixes: which events create a `notification` row and who receives it, how the fixed mention-token format gets parsed into recipients, how duplicate notifications are prevented, how email delivery works on top of [auth.md](./auth.md)'s `sendMail()`, and the deliberate decision to ship no unsubscribe mechanism in v1.

---

## 1. Trigger events and audience

The three notification types are fixed by [data-model.md](./data-model.md) §7: `mention`, `assignment`, `comment`. Each fires from the mutator that performs the triggering write, computes its own recipient set from already-loaded data, and inserts the `notification` row(s) in the *same transaction* as that write. No background job decides who gets notified — only whether and when the resulting email goes out (§5).

**`assignment`.** Fires when a mutator changes `issue.assignee_id` from one value (including null) to a different non-null value. Notifies the new assignee only. Clearing an assignee, or "reassigning" to the same person, changes nothing and fires nothing. Self-assignment fires nothing, enforced by the `CHECK (user_id <> actor_id)` constraint data-model.md §7 already has.

**`mention`.** Fires wherever a mention token (§2) appears in `issue.description` or `comment.body`. The rule is the same for both fields and for both create and update: diff the set of mentioned user ids in the new value against the set in the previous value (empty, for a newly created row), and notify only the ids that are newly present. Removing a mention, or re-saving a field with the same mentions already in it, notifies nobody. This single diff rule covers comment creation (previous state is always empty) without a separate case.

**`comment`.** Fires once, when a comment is created (not on edit — comment edits are covered by the mention diff rule above and nothing else, since edits are authorship-restricted typo fixes in practice, not new content worth re-announcing). The audience is the issue's participants: `issue.created_by`, `issue.assignee_id` (if set), and every distinct `author_id` of the issue's existing comments — minus the new comment's own author, and minus anyone who already receives a `mention` notification from this same comment. A participant who is mentioned gets the more specific `mention` notification, never both.

---

## 2. Mention tokens

The stored form is fixed by data-model.md §7: `@[Display Name](user:<uuid>)`. The client writes this token directly when a name is chosen from the mention autocomplete (ui-spec.md §3) — there is no free-text `@name` for the server to fuzzy-match, so a display-name change or a duplicate name can never misroute a mention.

Server-side extraction, run inside the mutator on the field's new value:

```
/@\[[^\]]*\]\(user:([0-9a-f-]{36})\)/g
```

Extracted ids are deduplicated within a single write, and any id that doesn't resolve to a real `user` row is silently dropped (a malformed or stale token should degrade to inert text, not fail the mutator). What remains is the newly-mentioned set used by §1's diff rule.

This depends on `issue.description` and `comment.body` being predictable plain text with exactly one piece of structured markup — the mention token — and nothing else. That is now explicit: see §9.

---

## 3. Recipient filtering

Before inserting any notification row, the mutator checks the candidate recipient's `deactivated_at IS NULL`, read fresh in the same query used to build the recipient set — not from a stale token claim, the same principle [auth.md](./auth.md) §6 applies to `loadActor()`. Deactivated users receive no notifications (permissions.md §7); this is enforced at creation, not by hiding existing rows, since a deactivated user cannot sign in to see them anyway.

A recipient who is a non-member of the issue's project still receives the notification — membership gates writes, not this. An assigned or mentioned non-member is a reachable state ui-spec.md §4.4 already renders.

---

## 4. Dedup

Two partial unique indexes on `notification`, closing the item data-model.md §7 left open for this document:

```sql
-- at most one notification per user per comment, regardless of type
-- (a mention within a comment supersedes the comment's own audience — §1)
CREATE UNIQUE INDEX notification_user_comment_uq
  ON notification (user_id, comment_id)
  WHERE comment_id IS NOT NULL;

-- at most one mention notification per user per issue description
CREATE UNIQUE INDEX notification_user_issue_mention_uq
  ON notification (user_id, issue_id)
  WHERE type = 'mention' AND comment_id IS NULL;
```

These are a safety net under the diff rule in §1 (which already avoids most duplicates), not a replacement for it — a mutator race that computed the same insert twice fails on the index instead of double-notifying.

**Batching:** none in v1. Each event that produces a notification row produces exactly one email (§5), sent as soon as the outbox worker's next cycle reaches it — no digesting multiple notifications into one message. The two indexes above are the only place duplicate *events* collapse; genuinely distinct events (two separate comments, two separate reassignments) each get their own row and their own email, on purpose.

---

## 5. Email delivery: outbox and worker

A new table, owned by this document and kept outside the publication — the same shape convention [auth.md](./auth.md) uses for `invite`, `login_token` and `session`.

### `notification_email`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | PK |
| `notification_id` | `uuid NOT NULL` | → `notification(id)` `ON DELETE CASCADE` |
| `status` | `text NOT NULL DEFAULT 'pending'` | `CHECK (status IN ('pending','sent','failed'))` |
| `attempts` | `integer NOT NULL DEFAULT 0` | |
| `next_attempt_at` | `timestamptz NOT NULL DEFAULT now()` | |
| `last_error` | `text` | nullable |
| `created_at` | `timestamptz NOT NULL` | |

One row per notification, inserted in the *same transaction* as the `notification` row itself, so the two can never diverge — a crash between them is not a reachable state. Not synced: delivery is a server-only concern with no UI beyond `notification.emailed_at`, which is already in the publication.

**Worker:** `npm run notify:send-outbox`, invoked on a short interval — mirrors [auth.md](./auth.md) §11's `auth:purge` exactly: a script wired to a systemd timer by deployment.md, not a long-lived process. Every run:

1. Selects up to 20 rows with `status = 'pending' AND next_attempt_at <= now()`, oldest first.
2. For each: re-reads the recipient's `deactivated_at`. If deactivated since the notification was created, marks the row `failed` with `last_error = 'recipient deactivated'` and sends nothing.
3. Otherwise calls the `sendMail()` module auth.md §10 already owns, with a per-type subject/body built from the notification's `type`, `actor_id` and `issue_id`.
4. On success: sets `notification.emailed_at = now()` and `notification_email.status = 'sent'`.
5. On failure: increments `attempts`. Below the retry ceiling (§6), sets `next_attempt_at` per the backoff schedule and leaves `status = 'pending'`; at the ceiling, sets `status = 'failed'`.

A one-minute timer with a 20-row batch keeps each run fast even after a period of downtime lets rows queue up, and stays well within what SMTP relays used by a <20-person team's mail provider tolerate.

---

## 6. Retry policy

Exponential backoff, capped at 5 attempts: 1, 5, 15, 60, 180 minutes after each failure. A row that exhausts all 5 is marked `failed` and left in the table — nothing purges it automatically, since failure volume at this scale is small enough to be an operational signal, not a cleanup problem. deployment.md may add a health check on `count(*) where status = 'failed'`; this document doesn't require one.

---

## 7. Unsubscribe: none in v1

Explicit decision, not an oversight. v1 ships no per-user notification preferences and no unsubscribe link. Every `mention`, `assignment`, and `comment` notification a user is eligible for (§1, §3) produces exactly one email, unconditionally.

Reasoning: this is a single trusted internal team under 20 people, not a product with strangers on a mailing list — email volume scales with real collaboration events, never with anything resembling spam. A preference column lives on `user`, and `user` is the one table whose synced columns are a physically closed list (data-model.md §3) — adding one means editing the publication, a migration that can force a `zero-cache` replica reset, for a feature nobody has asked to be protected from yet. If real usage shows it's needed, the change is one boolean column and one publication edit away, not a redesign.

---

## 8. Testing

Beyond the predicate and mutator tests permissions.md §10 and auth.md §12 already specify:

- **Notification creation.** For each trigger in §1 — assignee change, comment create, mention appearing in a description or comment — assert the exact recipient set, and assert no row is created for the actor or for a deactivated candidate recipient.
- **Dedup.** Assert the two partial unique indexes in §4 hold: mentioning the same person twice in one comment, or re-saving a description that already mentions someone, produces no duplicate row.
- **Outbox.** Assert a notification insert produces exactly one `notification_email` row in the same transaction, and that a mocked `sendMail()` failure drives the backoff schedule in §6 correctly, including the failure state at attempt 5.

---

## 9. Changes this spec requires elsewhere

- **data-model.md §7, `notification` table:** add the two partial unique indexes from §4.
- **data-model.md §7, `project.description`, `issue.description` and `comment.body`:** these are noted "Markdown," but ui-spec.md §8 rules out markdown rendering in v1 ("no markdown dependency is in the current stack"). This document depends on those fields being plain text carrying exactly one piece of structured markup — the mention token (§2) — so the two specs are reconciled here: the column notes change from "Markdown" to "Plain text." A user can still type `**bold**` and it renders as the literal characters, which is what ui-spec.md already describes; only the column's documented type changes, not its content or behavior.
- **data-model.md's deferred-items table:** this discharges "Notification dedup and batching, and the partial unique index that enforces it" (§4), "Whether `CHECK (user_id <> actor_id)` survives" (yes, unchanged), and "Mention parsing and dispatch" (§1, §2).
- **auth.md §10:** no edit needed — `sendMail()` is reused exactly as that document already anticipated (§10, §14).
- **permissions.md, team-works-concept-brief.md, ui-spec.md:** no changes required. This document's boundary with ui-spec.md — screen content and states versus trigger, delivery and retry mechanics — already held without adjustment.
