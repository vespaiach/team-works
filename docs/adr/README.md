# Team Works — architecture decision records

_Index of ADRs. Companion to [team-works-concept-brief.md](../team-works-concept-brief.md) §7, which lists every settled decision; these records cover the ones with real trade-offs and alternatives worth writing down — the ones a future reader would actually revisit. Status: approved 2026-07-31._

These are retrospective records: each decision below is already reflected in the approved spec it cites, and none of them changes anything in `team-works-concept-brief.md`, `permissions.md`, `data-model.md`, or `auth.md`. When one of these decisions is revisited, add a new ADR that supersedes it rather than editing the old one — the point of the record is what was known and chosen at the time.

| ADR | Decision |
| --- | --- |
| [0001](./0001-zero-for-sync-and-data-layer.md) | Zero for sync and the data layer |
| [0002](./0002-frappe-gantt-for-roadmap.md) | Frappe Gantt for the roadmap view |
| [0003](./0003-workspace-wide-reads-per-project-writes.md) | Workspace-wide reads, per-project writes |
| [0004](./0004-fractional-indexing-for-issue-ordering.md) | Fractional indexing for issue ordering |
| [0005](./0005-client-generated-uuidv7-primary-keys.md) | Client-generated UUIDv7 primary keys |
| [0006](./0006-human-readable-issue-identifiers.md) | Human-readable issue identifiers (`WEB-142`) |
| [0007](./0007-hard-deletes-with-cancellation-as-reversible-path.md) | Hard deletes, with cancellation as the reversible path |
| [0008](./0008-local-disk-for-attachments.md) | Local disk for attachments |
| [0009](./0009-hand-written-auth.md) | Hand-written authentication |
| [0010](./0010-short-lived-jwt-with-rotating-refresh-token.md) | Short-lived JWT plus a rotating refresh token |

Decisions from brief §7 not given their own ADR here (name, notification channels, mobile strategy, `zero-cache`'s VPS placement, the Postgres 15 floor, invite/first-admin mechanics, etc.) are settled but don't carry alternatives worth recording separately — see brief §7 for the full list.

## Changes this requires elsewhere

None. These records document decisions already made and reconciled across `team-works-concept-brief.md`, `permissions.md`, `data-model.md`, and `auth.md`; nothing here contradicts or amends them.
