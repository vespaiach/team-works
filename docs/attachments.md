# Team Works — attachments

_Attachment spec for v1. Companion to [data-model.md](./data-model.md), [permissions.md](./permissions.md), [auth.md](./auth.md) and [ui-spec.md](./ui-spec.md). Status: approved 2026-07-31._

Files live on local disk on the VPS ([team-works-concept-brief.md](./team-works-concept-brief.md) §5); only metadata syncs through Zero. This document fixes the two HTTP routes that metadata sync can't cover — upload and authorized download — plus path layout, size/MIME limits, orphan reclamation, and what backups must include. data-model.md §7 owns the `attachment` table itself and defers exactly these questions here.

---

## 1. Upload

**`POST /api/issues/:issueId/attachments`**, `multipart/form-data`, one file per request. This is a plain Next.js route, not a Zero custom mutator — Zero's mutator protocol carries JSON, and a multipart file body doesn't fit it. It is the one place in the app where a write reaches Postgres by a direct `Drizzle` insert rather than through `zero-cache`'s push endpoint; the row still reaches every client normally, because logical replication doesn't care how a row was written, only that it committed.

permissions.md §5 already lists `createAttachment` as requiring `isMember` of the affected project, but exports no dedicated `canCreateAttachment` predicate — only `canDeleteAttachment`, because delete also needs authorship. Upload authorization is nothing more than the bare `isMember(actor, membership, issue.project_id)` check every other project-scoped mutator reduces to, called directly by this route with the project id read from the target issue's own row (never from the client), per permissions.md §5's rule for id-bearing mutators. No new exported predicate is needed; see §8.

Request handling, in order:

1. `requireUser()` then `loadActor()` — the same fresh-from-Postgres check every mutator uses (auth.md §6), so a just-deactivated or just-demoted user can't slip a file in in the token's last few minutes.
2. Load the target issue, derive `project_id`, check `isMember`. Reject with the same 403 shape other mutators use if it fails.
3. Stream the multipart body with a size cap enforced *during* the read (§4) — a request whose body exceeds the cap is aborted mid-stream, never buffered in full first.
4. Validate the declared content type against the allowlist (§4). Reject before writing anything to disk if it doesn't match.
5. Generate `storage_path` server-side (§3) and write the file.
6. Insert the `attachment` row (id, `issue_id`, `comment_id` if the upload arrived attached to an in-progress comment, `filename`, `storage_path`, `content_type`, `size_bytes`, `uploaded_by`) in the same request, after the file write succeeds.
7. Respond with the created row. The client already has this shape from data-model.md §7 and can render it immediately; Zero's own sync of the same row over the next moment is a duplicate, not a race, since ids are client-supplied UUIDv7 wherever else that pattern is used — but not here. **This is the one row-creating write in the whole system whose id is server-generated, not client-generated**, since the id can't be minted until the multipart body has actually been validated and written; ui-spec.md's optimistic-mutator conventions don't apply to it. The upload UI (ui-spec.md §4.4) shows its own local "uploading…" placeholder keyed by a client-side temp id, swapped for the real row when this response (or the Zero sync of the same row) arrives — whichever comes first.

`deleteAttachment` is the reverse case: no binary payload, so it *is* an ordinary Zero custom mutator like `deleteComment`, deleting only the Postgres row. The file is reclaimed later (§5), not deleted synchronously — consistent with data-model.md §7's "the file on disk is not [deleted]."

---

## 2. Authorized download

**`GET /api/attachments/:id`**. Files are never served statically by nginx — nginx proxies this route like any other, so every download passes through the same check as everything else.

1. `requireUser()` then `loadActor()`. Reject a deactivated user immediately, the same as any other route — don't wait for their access token to expire, even though zero-cache itself would (permissions.md §7).
2. Load the `attachment` row by id. Missing row → 404.
3. **No membership check beyond that.** Reading any attachment is workspace-wide, exactly like reading the issue it's on (permissions.md §3's matrix: "Read any project, milestone, issue, comment, attachment ✓ ✓ ✓" — all three columns). Membership gates uploading and deleting, never reading.
4. Stream the file from `storage_path` under `ATTACHMENTS_DIR` (§3). A row with no corresponding file on disk — a backup/restore gap, or manual disk tampering — is a 404, not a 500: the row said the file should exist, the filesystem disagrees, and the honest answer is "not found," not a crash.
5. Response headers: `Content-Type` is the **stored** `content_type` from upload time, never re-sniffed from the file at download time. `Content-Disposition: attachment` is set unconditionally — never `inline` — with the original `filename` (RFC 5987-encoded for non-ASCII names, with a sanitized ASCII fallback for older clients). This is the load-bearing security line in this document: an uploaded HTML or SVG file can never be rendered inline by a teammate's browser through this route, regardless of what content type it claims, closing the stored-XSS path that "just serve the file" would otherwise open in a fully transparent, workspace-wide-readable system.

No `Range` support in v1 — whole-file downloads only. Nothing in the brief calls for scrubbing through large video attachments, and partial-content handling is real complexity for a need nobody has yet.

---

## 3. Storage layout

```
{ATTACHMENTS_DIR}/{project_key}/{issue_number}/{attachment_id}.{ext}
```

e.g. `/var/lib/team-works/attachments/WEB/142/018f3b2e-....pdf`. `project_key` and `issue_number` are both immutable once assigned (data-model.md §6), so this path never needs to move for the life of the row — an issue can't change project, and a project's key can't change (permissions.md §5's `updateProject` guard). Grouping by project and issue keeps any one directory small and makes the tree human-navigable during a manual backup or restore drill, without needing a database lookup to find "everything on `WEB-142`."

`{ext}` is taken from the uploaded filename — lowercased, stripped to `[a-z0-9]`, capped at 10 characters, empty if the original had none. It is cosmetic only: nothing depends on it matching `content_type`, and it plays no role in the MIME validation in §4, which checks the declared content type exclusively.

`ATTACHMENTS_DIR` is a new required variable in the environment contract auth.md §10 already owns and validates at boot (§8 below) — an absolute path, expected to exist and be writable before the app starts; the app does not create it.

---

## 4. Size and MIME limits

**25 MB per file.** Enforced by aborting the multipart read once the byte count crosses the limit (§1 step 3), returning `413`. No per-issue or per-workspace total is enforced here; disk usage at this scale is an operational concern for deployment.md, not a per-request check.

**Allowlist, not a blocklist**, checked against the client-declared content type:

| Category | Types |
| --- | --- |
| Images | `image/png`, `image/jpeg`, `image/gif`, `image/webp` |
| Documents | `application/pdf`, `text/plain`, `text/csv`, `text/markdown` |
| Office | `application/msword`, `application/vnd.openxmlformats-officedocument.wordprocessingml.document`, `application/vnd.ms-excel`, `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`, `application/vnd.ms-powerpoint`, `application/vnd.openxmlformats-officedocument.presentationml.presentation` |
| Archives | `application/zip` |

**`image/svg+xml` is deliberately excluded** — an SVG can carry a `<script>`. §2's forced `Content-Disposition: attachment` already prevents it from executing if someone uploaded one anyway, but there's no reason to allow it through the front door too.

Anything outside this list is rejected with `415` before the file touches disk. The list is a plain constant in code, not environment-configurable — nobody has asked for a different set, and a fixed list is one thing fewer for deployment.md's contract to validate.

---

## 5. Orphan reclamation

Deleting an `attachment` row — directly, or by cascade from a deleted comment, issue, or project (data-model.md §4) — never deletes the file. Reclaiming it is a separate, periodic job: `npm run attachments:reclaim`.

1. Read every `storage_path` currently in the `attachment` table into a set.
2. Walk `ATTACHMENTS_DIR` recursively. For each file whose relative path is **not** in that set **and** whose mtime is older than one hour, delete it.
3. For each `storage_path` in the table with **no** corresponding file on disk, log a warning and continue — this is a backup/restore skew or manual tampering (§6), not something this job repairs.

The one-hour mtime grace period exists because a file is written to disk (§1 step 5) *before* its row commits (§1 step 6); without it, a reclaim run racing an in-flight upload could delete a file whose row insert hasn't landed yet. An hour is generously longer than any upload in this system takes.

Wired to a weekly systemd timer by deployment.md — the same pattern as auth.md §11's `auth:purge` and notifications.md §5's `notify:send-outbox`, just less frequent, since an orphaned file is wasted disk space, not a correctness or security problem, and doesn't warrant a daily or per-minute cadence.

---

## 6. Backup implications

Attachment metadata lives in Postgres and is covered by an ordinary `pg_dump`. The files themselves are not, and a Postgres-only backup silently produces a restore where every `attachment` row exists but every download 404s (§2 step 4). deployment.md's backup and restore-drill sections (HANDOFF's own scope for that document) must:

- Back up `ATTACHMENTS_DIR` on the same schedule as the Postgres backup, not a separate one — the two are only meaningful together.
- Treat "row exists, file missing" after a restore as the expected result of restoring the two from *different points in time*, not a bug in this document's design — §2 already degrades that case to a clean 404 rather than a crash.

This document doesn't specify the backup mechanism (rsync, tar snapshot, etc.) — that's deployment.md's runbook, not a storage-layer decision.

---

## 7. Testing

Beyond the predicate and mutator tests permissions.md §10, auth.md §12 and notifications.md §8 already specify:

- **Upload authorization.** A non-member of the issue's project is rejected before any file write; a deactivated user is rejected even with a still-valid access token.
- **Size and MIME enforcement.** A file over 25 MB is aborted mid-stream, not buffered then rejected. A disallowed content type, including `image/svg+xml`, is rejected before disk write.
- **Download.** `Content-Disposition` is always `attachment`, never `inline`, including for an uploaded file whose stored `content_type` is `text/plain` or `application/pdf`. A row with a missing file returns 404, not 500.
- **Reclamation.** A file with no matching row is deleted only once its mtime exceeds the one-hour grace period; a file uploaded seconds ago is left alone even with no row yet.

---

## 8. Changes this spec requires elsewhere

- **auth.md §10:** the environment contract gains `ATTACHMENTS_DIR` (required, absolute path, validated at boot alongside the existing variables).
- **local-dev.md §3:** gains a local value for `ATTACHMENTS_DIR`, e.g. `./.data/attachments`, and a note that this path must be gitignored.
- **data-model.md's deferred-items table:** this discharges "On-disk path layout, size and MIME limits, authorized download, orphan reclamation."
- **permissions.md:** no changes required. `createAttachment`'s authorization is the existing bare `isMember` check with no new predicate; `deleteAttachment` already has its own (`canDeleteAttachment`, §8 there) and this document doesn't touch it.
- **ui-spec.md:** no changes required. §4.4's upload/list UI and §3's RAC mapping already anticipated the authorized-download endpoint this document now defines; the "uploading…" placeholder behavior in §1 above is an implementation detail of that same screen, not a new state.
- **team-works-concept-brief.md:** no changes required.
- **package.json** (build step 1's dependency list, data-model.md §12 and auth.md §12): gains a streaming multipart parser (e.g. `busboy`) for §1's route — Next.js route handlers don't parse `multipart/form-data` on their own, and the size cap in §4 depends on aborting the read mid-stream rather than buffering the body first.
