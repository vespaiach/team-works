# ADR-0009: Hand-written authentication

Status: Accepted — 2026-07-31

## Context

The app needs invite-only, magic-link authentication for one workspace and one tenant: no passwords, no OAuth, no account linking (auth.md §1).

## Decision

Authenticate by hand — no Auth.js, Lucia, Better Auth, or any other auth library. The surface a library exists to cover (password hashing, OAuth callbacks, provider token refresh, account linking, multi-tenant boundaries) is mostly absent here; what remains is a session cookie, a token table, and a signed JWT.

## Consequences

- Every concern a library would handle silently now has to be written down and tested explicitly. auth.md §1 names each one — token entropy, single-use redemption, the rotation race, cookie flags and CSRF, session fixation, revocation, throttling, secret validation at boot — so nothing is left implied.
- The access JWT is exactly the shape Zero's sync connection needs. The app signs it and `zero-cache` verifies it — one artifact, instead of bridging two separate auth systems together.
- All tokens are stored as SHA-256 digests, never raw, so nothing in the codebase does a secret-dependent comparison and nothing needs `timingSafeEqual`.
- Single-box, single-secret deployment where a dependency that changes its session format between majors would be a liability, not a convenience.

## Alternatives considered

- **Auth.js / NextAuth.** Covers OAuth providers and session adapters this app doesn't use, and would still need custom work to produce the exact JWT shape `zero-cache` verifies — without removing much of the code this decision writes anyway.
- **Lucia / Better Auth.** Lighter than Auth.js, but still a dependency to track through major versions, for a surface (magic links, one JWT, one secret) explicitly small enough to own directly.
