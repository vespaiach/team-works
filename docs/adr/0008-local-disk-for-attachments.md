# ADR-0008: Local disk for attachments

Status: Accepted — 2026-07-31

## Context

Attachments need file storage. The deployment target is a single VPS, and the brief needed a v1 storage decision without pulling in cloud object-storage infrastructure the rest of the stack doesn't otherwise require.

## Decision

Attachments are stored on local disk on the VPS. Uploads go through a normal Next.js API route, not a Zero mutator; only file metadata lives in Postgres and syncs via Zero.

## Consequences

- No S3/object-storage dependency, credentials, or egress cost for a single-VPS, sub-20-person deployment.
- Attachments are the one write path in the app that isn't a Zero mutator — file bytes don't belong in a Postgres-replicated sync set, so this goes through a normal HTTP upload instead.
- Deleting an attachment row does not delete the file on disk — [attachments.md](../attachments.md) owns orphan reclamation.
- Backups must cover the attachment disk in addition to Postgres — [deployment.md](../deployment.md), when written, owns that runbook.
- Ties storage capacity to the VPS's own disk, with no built-in redundancy or CDN.

## Alternatives considered

- **S3-compatible object storage (S3, R2, MinIO) from v1.** More resilient and offloadable, but adds a second infrastructure dependency and credential surface that a single-VPS, sub-20-person deployment doesn't need yet. Left as an explicit later migration path rather than a v1 requirement.
