# ADR-0010: Short-lived JWT plus a rotating refresh token

Status: Accepted — 2026-07-31

## Context

The browser's session credential is also the token `zero-cache` verifies for the sync connection, so its lifetime and revocation behavior have to satisfy both a web session and a sync auth token at once (auth.md §2).

## Decision

A 15-minute HS256 JWT — carrying only `sub` (user id) and `role`, never project membership — is the access token and doubles as the sync credential. A 30-day sliding refresh token, stored as a SHA-256 digest in a `session` row, renews it. `AUTH_SECRET` and `ZERO_AUTH_SECRET` are one secret under two names, since the app and `zero-cache` verify the same token independently.

## Consequences

- Membership is deliberately excluded from the claim set, so adding or removing a `ProjectMember` row takes effect on the next mutation rather than waiting for the next token issuance — the token establishes identity, the database establishes authority (permissions.md §4, auth.md §2).
- A demotion or deactivation stops writes at once, because `loadActor()` re-reads `role`/`deactivated_at` from Postgres on every server mutator call, even though the 15-minute-stale JWT claim hasn't caught up in the UI yet.
- `zero-cache` holds the same secret that signs HTTP session tokens — accepted, because that container already holds a full SQLite replica of the workspace (a total read compromise on its own) and already relays mutator writes through the app's push endpoint carrying that same token, so splitting the secret would only have protected the attachment and admin routes.
- The rotation race (concurrent refresh requests) and revocation's stale-claim window are named, explicit concerns with their own handling, not left implicit (auth.md §4.4, §6, §8).

## Alternatives considered

- **Long-lived single JWT, no refresh token.** Simpler, but a compromised token stays valid for its full lifetime with no revocation path short of rotating the shared secret for every user.
- **Server-side session lookup on every request, no JWT.** Gives instant revocation, but reintroduces a per-request database round-trip that Zero's token-based sync connection is specifically designed to avoid, and loses the "one artifact both processes verify" property.
