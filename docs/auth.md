# Team Works — authentication

_Authentication spec for v1. Companion to [team-works-concept-brief.md](./team-works-concept-brief.md), [permissions.md](./permissions.md) and [data-model.md](./data-model.md). Status: approved 2026-07-31._

This document is the source of truth for how a person proves who they are, how that proof reaches `zero-cache`, and the three tables that make it work. [permissions.md](./permissions.md) takes over the moment identity is established: this document answers *who is this*, that one answers *what may they do*.

**Authentication is hand-written.** There is no Auth.js, NextAuth, Lucia or Better Auth in this system. That reverses the concept brief, which named Auth.js; §14 records the reconciliation.

---

## 1. Why hand-written, and what that obliges

The surface an auth library exists to cover is mostly absent here. There are no passwords to hash, no OAuth callbacks to validate, no provider tokens to refresh, no account linking, no multi-tenant boundaries. One workspace, one identity per email, one credential type — an emailed link.

What remains is a session cookie, a token table and a signed JWT, and those are worth owning outright: the sync layer needs a token in a shape we control, and the deployment is a single box where a dependency that changes its session format between majors is a liability, not a service.

The obligation is that the things a library did silently now have to be written down and tested. This document names each one rather than leaving it implied:

| Concern | Section |
| --- | --- |
| Token entropy and storage at rest | §2 |
| Single-use redemption, and resistance to mail scanners | §4.3 |
| Rotation, and the concurrent-refresh race | §4.4 |
| Cookie flags and CSRF | §7 |
| Session fixation | §4.3 |
| Revocation, and the stale-claim window | §6, §8 |
| Throttling the one unauthenticated endpoint | §9 |
| Secret validation at boot | §10 |

---

## 2. Three tokens, one secret

| Artifact | Form | Lifetime | Stored as |
| --- | --- | --- | --- |
| Magic-link token | 32 bytes from `crypto.randomBytes`, base64url | 15 minutes, single-use | SHA-256 digest in `login_token` |
| Refresh token | 32 bytes from `crypto.randomBytes`, base64url | 30 days, sliding | SHA-256 digest in `session` |
| Access token | HS256 JWT | 15 minutes | not stored — cookie and response body |

**Raw tokens are never persisted.** Both opaque tokens are stored as their SHA-256 digest in a `bytea` column with a unique index, and verification is a lookup *by digest*. There is consequently no secret-dependent comparison anywhere in application code — nothing calls `timingSafeEqual`, because nothing compares two secrets. A database that leaks does not yield a working credential.

SHA-256 rather than a password hash is deliberate and correct here: these are 256-bit random values, not user-chosen secrets, so there is no dictionary to defend against and no reason to pay Argon2's cost on every request.

### The access token

```json
{ "sub": "<user uuid>", "role": "admin" | "member", "iat": …, "exp": … }
```

Nothing else. This is exactly the claim set permissions.md §4 promises — id and workspace role — and in particular **project membership is not a claim**, so adding or removing a member takes effect on the next mutation rather than at the next token issuance.

The token is signed HS256 with `AUTH_SECRET`, using `jose` (which runs on both the Node and edge runtimes, and so is usable in middleware).

### One secret under two names

`zero-cache` is a separate process and reads its own environment variable. Its `ZERO_AUTH_SECRET` **must be set to the same value as `AUTH_SECRET`** — they are one secret with two names, because the app signs and `zero-cache` verifies. Generating two different values is the most likely way to misconfigure this deployment, and §10 makes the boot check catch it.

The consequence, stated plainly: the `zero-cache` container holds the secret that signs HTTP session tokens, so a compromise of that container is a full authentication compromise. This was weighed and accepted. That container already holds a complete SQLite replica of the workspace, so it is already a total read compromise; and because Zero routes custom mutators *through* `zero-cache` to the app's push endpoint carrying that same token, a forged sync token authorizes writes regardless of which secret signed it. Splitting the secret would have protected the attachment and admin routes and nothing else.

---

## 3. Tables

Three tables, all **outside the `zero_data` publication** (data-model.md §3). They cannot reach a client: the publication names ten tables and these are not among them, so no Zero schema declaration can pull them in.

They follow data-model.md §1's conventions — UUIDv7 primary keys, `snake_case`, singular names, `timestamptz` for instants — with one deviation noted below.

### `invite`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | PK |
| `email` | `text NOT NULL` | `UNIQUE (lower(email))`, stored lowercased |
| `name` | `text` | nullable; seeds `user.name` on acceptance |
| `role` | `text NOT NULL DEFAULT 'member'` | `CHECK (role IN ('admin','member'))` |
| `invited_by` | `uuid NOT NULL` | → `user(id)` `ON DELETE RESTRICT` |
| `expires_at` | `timestamptz NOT NULL` | `DEFAULT now() + interval '14 days'` |
| `accepted_at` | `timestamptz` | null means pending |
| `created_at` | `timestamptz NOT NULL` | |
| `updated_at` | `timestamptz NOT NULL` | |

The invite carries no token. Sign-in has exactly one mechanism (§4.2), so the link in an invitation email is an ordinary `login_token` — an invitee and a returning colleague walk the identical path.

**Invitations expire.** A standing invitation to a workspace is a credential; leaving one open indefinitely means a mailbox compromised two years from now still grants access. Fourteen days, extended by resending. The `ON DELETE RESTRICT` on `invited_by` matches data-model.md §4: every foreign key to `user` restricts, because users are never deleted.

### `login_token`

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | PK |
| `token_hash` | `bytea NOT NULL` | `UNIQUE` — SHA-256 of the raw token |
| `email` | `text NOT NULL` | lowercased |
| `expires_at` | `timestamptz NOT NULL` | issuance + 15 minutes |
| `consumed_at` | `timestamptz` | null means live |
| `created_at` | `timestamptz NOT NULL` | |

Keyed by `email`, not `user_id`, because an invitee has no `user` row yet — that row is created *by* redemption (§4.3).

No `updated_at`: `consumed_at` is the only mutation these rows ever see, and it is itself a timestamp. This is the deviation from data-model.md §1 mentioned above, and it means `touched()` is not used here.

Indexes: `(email) WHERE consumed_at IS NULL` serves the throttle count in §9, and `(expires_at)` serves the purge in §11.

### `session`

One row per browser that has signed in.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | `uuid` | PK |
| `user_id` | `uuid NOT NULL` | → `user(id)` `ON DELETE RESTRICT` |
| `token_hash` | `bytea NOT NULL` | `UNIQUE` — current refresh token |
| `prev_token_hash` | `bytea` | `UNIQUE`, nullable — the token this one replaced |
| `rotated_at` | `timestamptz` | null until first rotation |
| `expires_at` | `timestamptz NOT NULL` | reset to `now() + 30 days` on every rotation |
| `user_agent` | `text` | nullable; labels the row in "your sessions" |
| `created_at` | `timestamptz NOT NULL` | |
| `last_used_at` | `timestamptz NOT NULL` | |

Indexes: the two unique indexes above, plus `(user_id)` for revoke-all and `(expires_at)` for the purge. Postgres permits multiple NULLs in a unique index, so `prev_token_hash` needs no partial predicate.

**Lookup is two point queries, never an `OR`.** `WHERE token_hash = $1 OR prev_token_hash = $1` cannot use either index. Match `token_hash` first; only on a miss, try `prev_token_hash`. The second query is rare — it runs only during the race in §4.4.

---

## 4. Flows

### 4.1 Inviting

Admin-only (permissions.md §5 lists `inviteUser` among the admin mutators). Given an email, an optional name and a role:

1. Normalize the email — trim, lowercase.
2. If a `user` already exists at that address, fail — *already a member* if active, *reactivate this person instead* if deactivated. No invite row is written in either case; an invite for a deactivated user would otherwise create a link that §4.3 refuses to redeem.
3. Upsert the `invite` row on `lower(email)`, setting `expires_at = now() + 14 days`. Re-inviting an existing pending invitee is therefore how you resend.
4. Insert a `login_token` for that address by the same mechanism as §4.2, and send the invitation email carrying its link. The §9 throttle applies here too, so repeatedly resending an invitation cannot be used to bury an inbox.

Revoking a pending invitation deletes the `invite` row and every live `login_token` for that address in one transaction. Pending invitations are listed on a server-rendered admin page — `invite` is outside the publication, so this is the app's first screen that is not a Zero query.

### 4.2 Requesting a sign-in link

`POST /api/auth/signin`, body `{ email }`. The only endpoint an unauthenticated stranger can reach.

1. Normalize the email.
2. Resolve it to either an **active user** or an **unaccepted, unexpired invite**. A deactivated user resolves to neither.
3. Apply the throttle (§9).
4. Insert a `login_token` — 32 random bytes, digest stored, `expires_at = now() + 15 minutes`.
5. Send `${APP_URL}/auth/verify?token=<raw>` by email (§10 covers the transport).

**Responses.** The endpoint returns the same generic acknowledgement whether or not the address resolved. The two exceptions are cases where the operation genuinely failed and silence would be a lie: the throttle returns a message saying a link is already waiting, and an SMTP error returns a visible failure.

Both of those confirm the address exists, and that is fine. **Email enumeration is explicitly out of scope**: this is an invite-only workspace of under twenty colleagues who know each other's addresses, and the generic response is a default courtesy rather than a security control. Swallowing a real delivery failure into a cheerful "check your inbox" would trade a non-secret for a support ticket nobody can diagnose.

### 4.3 Redeeming the link

Two steps, and the split is the point.

**`GET /auth/verify?token=…` consumes nothing.** It looks the digest up, renders *"Sign in as alice@example.com"* with a button, and is otherwise a read-only page. Expired, consumed and unknown tokens render their own explanatory states with a link back to sign-in.

**`POST /api/auth/verify` redeems**, in one transaction:

1. `SELECT … FROM login_token WHERE token_hash = $1 FOR UPDATE`.
2. Reject if `consumed_at IS NOT NULL` or `expires_at <= now()`.
3. `UPDATE login_token SET consumed_at = now()`.
4. Resolve the identity:
   - active user at that email → use it;
   - deactivated user → reject;
   - no user, but a pending unexpired invite → create the `user` row (`id` UUIDv7, `role` from the invite, `name` from `invite.name` or else the email's local part, since `user.name` is `NOT NULL`), and stamp `invite.accepted_at`;
   - neither → reject.
5. Insert a `session` row with a fresh refresh token.
6. Set both cookies (§7) and redirect.

**Why the split.** Links in email are fetched by things that are not the recipient — Outlook Safe Links, corporate antivirus proxies, mail-client prefetchers, chat unfurlers. Every one of them issues a `GET`. Consuming on `GET` means a scanner burns a single-use token seconds after delivery and the actual person is told the link is already used: an intermittent failure that reproduces only inside the corporate mail environments where you cannot debug it. None of them issue the `POST`.

The token appears in a URL, which is unavoidable for emailed links. Two mitigations: the verify page sets `Referrer-Policy: no-referrer`, and deployment.md is asked to configure nginx not to log query strings on `/auth/verify`. Exposure is bounded anyway — fifteen minutes, single use.

A new `session` row is created on every redemption and no pre-existing session is ever upgraded in place, so there is no session-fixation path.

### 4.4 Refreshing, and the rotation race

`POST /api/auth/refresh` — no body; the refresh cookie is the credential. Returns `{ token, expiresAt }` and sets both cookies.

Two independent callers hit it per tab: the browser on navigation when the access cookie has lapsed, and Zero's `auth` callback when `zero-cache` rejects an expired token. Simultaneous calls are ordinary, not exceptional.

They are simultaneous but not *divergent*, and that is what makes this tractable: the refresh token lives in a cookie, and cookies are shared across every tab in a browser. There is no per-tab token to drift out of phase. The only concurrency is two requests that both read the jar before either `Set-Cookie` lands.

So the endpoint has three outcomes:

| Match | Action |
| --- | --- |
| `token_hash` | **Rotate.** `prev_token_hash := token_hash`, `token_hash := H(new)`, `rotated_at := now()`, `expires_at := now() + 30 days`, `last_used_at := now()`. Set the refresh cookie to the new token. Return a fresh access JWT. |
| `prev_token_hash`, and `rotated_at > now() - 30 seconds` | **Do not rotate, and do not touch the refresh cookie.** Return a fresh access JWT only; the `session` row is left entirely unmodified, `last_used_at` included. |
| anything else | 401, clear both cookies. |

The grace branch deliberately issues no refresh token. It cannot return the successor — only the successor's digest was stored — and rotating *again* would be worse: two responses would then race to set different refresh cookies, and whichever landed last could leave the browser holding a token already demoted to `prev`, which would fail its next refresh fifteen minutes later when the grace window has long closed. Returning an access token and staying silent about the refresh cookie leaves the jar holding exactly what the winning request set.

Every refresh also re-checks that the user is still active; a deactivated user's refresh fails even before §8 deletes their rows.

**Sliding, uncapped.** Each rotation pushes `expires_at` out 30 days. Someone who opens the tool weekly never signs in again; someone who leaves for a month does. There is no absolute cap — a forced quarterly re-authentication buys little on a workspace where an admin can revoke by hand in seconds.

**Reuse detection is deliberately absent.** A refresh token replayed hours after rotation matches nothing and gets a 401 — indistinguishable from a stale tab, and no session family is killed. Real replay detection needs a chain of consumed-token rows, which costs a row per refresh per tab, a pruning job, and a class of spurious sign-outs when a laptop lid closes mid-rotation. On an invite-only team of this size, with manual revocation available, that trade did not pay.

### 4.5 Signing out

`POST /api/auth/signout` deletes the current `session` row and clears both cookies. `POST /api/auth/signout-all` deletes every `session` row for the user. The access token remains valid for up to fifteen more minutes in both cases — see §8 for what that does and does not mean.

### 4.6 Bootstrap and break-glass

```bash
npm run admin:grant -- --email=alice@example.com --name="Alice"
```

A Node script run over SSH against `DATABASE_URL`. It creates the `user` row if absent, sets `role = 'admin'`, and clears `deactivated_at`. It sends no email; the person then signs in through the ordinary flow.

This is both the first-admin bootstrap that permissions.md §7 refers to only as "during setup" and the recovery procedure for total lockout. Lockout is reachable: last-admin protection (§8) prevents you from *demoting* your way out, but not from losing access to the last admin's mailbox.

Two alternatives were rejected. Seeding an admin from an environment variable on an empty database adds a startup path whose precondition is true exactly once and does nothing for recovery. Letting the first sign-in claim the workspace leaves a window between `docker compose up` and your own first visit in which anyone who resolves the hostname owns the installation — a real race on a box whose DNS record already points at it.

deployment.md picks this command up in the provisioning runbook.

---

## 5. The sync connection

Zero's client is constructed with an `auth` callback:

```ts
const z = new Zero({
  auth: async () => {
    const res = await fetch('/api/auth/refresh', { method: 'POST' })
    if (!res.ok) { window.location.href = '/signin'; throw new Error('unauthenticated') }
    return (await res.json()).token
  },
  // …schema, server URL
})
```

Zero calls it once at construction and again whenever `zero-cache` rejects the token. That re-invocation is the refresh mechanism permissions.md §9 already assumes when it says the sync connection "drops and the client behaves as disconnected until the token refreshes" — this is the machinery behind that sentence.

### Verify during Foundation

**Confirm the pinned Zero version re-invokes `auth` on token rejection**, rather than only reading it once at construction. Everything above depends on it: if the callback is one-shot, an expiring token means a dead connection until the page reloads.

The fallback is decided, so this blocks nothing. If Zero does not re-invoke, the client owns the schedule instead — a timer refreshes at 80% of the token's life (12 minutes) and recreates the Zero instance with the new token, and `zero-cache` never sees an expired one under normal operation. Slightly more client code, same tables, same endpoints, no schema consequence.

This joins the two verifications data-model.md already assigned to build step 1.

`zero-cache` verifies the JWT with `ZERO_AUTH_SECRET` and exposes its claims to the read rule. permissions.md §4's single read rule reads the `sub` claim.

**Mutations arrive over the same token.** Zero routes custom mutators through `zero-cache` to the app's push endpoint, carrying the JWT in an `Authorization: Bearer` header and no cookie. `requireUser()` (§6) therefore accepts the token from either carrier.

Because the running app refreshes every fifteen minutes on its own through this callback, the access cookie is kept fresh as a side effect. The middleware refresh hop in §6 fires only on a cold navigation to a tab that has been closed longer than the access token's life.

---

## 6. `requireUser()` and `loadActor()`

Two functions, and confusing them is the most likely way to get authorization wrong.

```ts
// src/lib/auth/require-user.ts
type Claims = { userId: string; role: 'admin' | 'member' }

// Verifies the JWT from the cookie or the Authorization header. Throws 401.
// Cheap: signature and expiry only, no database.
export async function requireUser(req: Request): Promise<Claims>

// src/lib/auth/load-actor.ts
// Re-reads role and deactivated_at from Postgres. Throws 403 if deactivated.
// This is what permissions.ts consumes on the server.
export async function loadActor(userId: string): Promise<Actor>
```

`requireUser()` establishes *identity*. Its `role` claim may be up to fifteen minutes stale, so it drives nothing but cheap rendering.

`loadActor()` establishes *authority*. **Every server mutator calls it**, and the `Actor` it returns — not the token — is what `isAdmin` and `isMember` receive. Its query is folded into the membership load that permissions.md §8 already requires on every mutation, so it costs nothing extra.

This extends permissions.md §8's rule from membership to role: the server derives its own and never trusts the client's. It is also what closes the stale-claim window. A demoted admin's *writes* fail on the next mutation; only their UI keeps offering buttons, and only until the token turns over.

### Route protection

Two layers, and only one of them is trusted.

**Middleware** verifies the access cookie statelessly with `jose` — no database, which the edge runtime could not reach anyway on Next 14. Valid, or the route is public → through. Expired or absent, but a refresh cookie is present → rewrite to `GET /api/auth/refresh?next=…`, which runs in the Node runtime, rotates, sets cookies and redirects back. Neither → `/signin`.

**`requireUser()`** runs independently in every route handler, server action and data-reading server component. Nothing anywhere assumes middleware ran.

The separation is not stylistic. Next.js middleware has a history of header-based bypasses — CVE-2025-29927 is the loud one — and a middleware-only gate turns any such bug into a full authorization bypass. Middleware here manages *experience*: it decides whether you get redirected. It never decides whether you get data.

**The one state-changing `GET`.** `/api/auth/refresh?next=…` rotates on a `GET`, which contradicts the rule §7 otherwise holds to. It exists because middleware cannot reach Postgres and so cannot refresh in place. It is safe by consequence rather than by protection: a cross-site `GET` rotates the victim's own token in the victim's own browser, and the attacker can read neither the response nor the cookies. `next` is validated as a same-origin absolute path — it must begin with a single `/`, and `//` and `/\` are rejected — or the endpoint becomes an open redirect.

---

## 7. Cookies, CSRF, and hygiene

| Cookie | Contents | `Max-Age` | Flags |
| --- | --- | --- | --- |
| `tw_access` | the access JWT | 900 | `HttpOnly`, `SameSite=Lax`, `Path=/`, `Secure`* |
| `tw_refresh` | the raw refresh token | 2592000 | `HttpOnly`, `SameSite=Lax`, `Path=/`, `Secure`* |

\* `Secure` is set when `APP_URL` is `https://` and omitted otherwise, because local development runs over plain HTTP and a `Secure` cookie would never be stored. local-dev.md inherits this.

`Path=/` on the refresh cookie rather than scoping it to `/api/auth`: middleware has to see whether a refresh cookie exists in order to choose between the refresh hop and `/signin`.

**CSRF** is covered twice. `SameSite=Lax` withholds both cookies from cross-site `POST`s, and every mutating handler additionally verifies that the `Origin` header matches `APP_URL`. No state-changing `GET` exists other than the refresh hop discussed above.

The access token is returned in the refresh response body as well as set as a cookie, because Zero's `auth` callback is JavaScript and cannot read an `HttpOnly` cookie. This is a real cost, and worth naming: it puts a portable fifteen-minute credential within reach of an XSS, which could exfiltrate something that keeps working after the tab closes rather than merely forging requests while it is open. It was accepted in exchange for a single token, a single expiry and a single refresh path — and because the alternative, a separately-minted sync token, would have shrunk that blast radius without closing it, given that a sync token already authorizes both reading everything and writing through mutators.

---

## 8. Deactivation, revocation, and the last admin

### What `deactivateUser` does

In one transaction: set `user.deactivated_at`, delete every `session` row for that user, delete every live `login_token` for their address.

Revocation is therefore not uniform, and the doc says so rather than implying an instantaneous kill:

| Capability | Stops |
| --- | --- |
| Signing in | immediately — §4.2 and §4.3 both refuse a deactivated user |
| Refreshing | immediately — the session rows are gone |
| Writing | immediately — `loadActor()` throws on `deactivated_at` (§6) |
| Receiving new synced rows | within 15 minutes, when the access token expires |

The last line is the only lag, and it is smaller than it looks. Someone with the tab already open holds a complete local replica of the workspace; dropping their sync connection does not un-see any of it. The window bounds how long they keep receiving *new* rows, not what they can read.

permissions.md §7's promise that reactivation restores prior access holds: `project_member` rows are untouched, and the person signs in again through the ordinary flow.

### The last admin

permissions.md §7 states that the last active admin cannot be demoted or deactivated. That check races — two concurrent demotions can each observe two admins and each conclude it is safe. So it runs inside the mutator's own transaction:

```sql
SELECT id FROM "user"
 WHERE role = 'admin' AND deactivated_at IS NULL AND id <> $target
 FOR UPDATE;
```

An empty result fails the mutation. `FOR UPDATE` serializes concurrent attempts, so exactly one of two simultaneous demotions succeeds. This applies to both `setUserRole` and `deactivateUser`.

### Promotion

permissions.md §7 says promotion "takes effect on the next JWT issuance" and that the token is refreshed so the user need not sign out. Concretely: the *authoritative* effect is immediate, because `loadActor()` reads the database (§6), and the promoted user can write as an admin on their very next mutation. What lags by up to fifteen minutes is the token claim, and therefore only the UI's decision about which controls to render.

---

## 9. Throttling

`POST /api/auth/signin` is the sole unauthenticated endpoint. Unthrottled it is a mail bomb aimed at whichever colleague's address the sender guesses, and the SMTP reputation it burns is yours.

The limit is derived from data already stored:

```sql
SELECT count(*) FROM login_token
 WHERE email = $1 AND consumed_at IS NULL AND expires_at > now();
```

Three or more live tokens refuses the request. No rate-limit table, no in-memory counter, correct across restarts and across multiple app processes — the `login_token` rows *are* the counter. It also degrades in the right direction: the only person it can inconvenience is someone who already has three working links sitting in their inbox.

Per-IP coverage comes from nginx `limit_req` on `/api/auth/*`, which deployment.md configures. It is crude and IP-scoped, and it is a complement rather than the mechanism.

Guessing a token is not in the threat model: 256 bits of entropy, fifteen minutes, single use.

---

## 10. Environment contract

This replaces the scaffold's placeholder `SECRET_KEY`, which data-model.md §12 flagged and which does not survive.

| Variable | Required | Notes |
| --- | --- | --- |
| `DATABASE_URL` | yes | Postgres connection string |
| `ATTACHMENTS_DIR` | yes | absolute path; must exist and be writable at boot — [attachments.md](./attachments.md) §3 |
| `AUTH_SECRET` | yes | ≥ 32 bytes; signs and verifies the access JWT |
| `ZERO_AUTH_SECRET` | yes | **the same value as `AUTH_SECRET`**, read by the `zero-cache` container |
| `APP_URL` | yes | absolute origin; builds magic links, sets the `Origin` check, decides the `Secure` cookie flag |
| `SMTP_HOST` | yes | |
| `SMTP_PORT` | yes | |
| `SMTP_SECURE` | yes | `true` for implicit TLS on 465, `false` for STARTTLS on 587 |
| `SMTP_USER` | yes | |
| `SMTP_PASS` | yes | |
| `SMTP_FROM` | yes | e.g. `Team Works <noreply@example.com>` |

**Validated at boot.** A single module parses this contract at startup and the process refuses to start if anything is missing or if `AUTH_SECRET` is shorter than 32 bytes. Signing a token with `undefined` must not be a reachable state.

### Mail

`nodemailer` over SMTP, in a small `sendMail()` module that this document owns. The operator supplies credentials for whatever they already use — Fastmail, SES, Postmark's SMTP endpoint, a Gmail app password, or a relay on the box itself. No vendor API and no required outbound HTTPS, which keeps the self-hosting story honest.

Auth mail is sent **inline, during the request**. It is a handful of messages a day, and a failed send should surface to the person waiting rather than disappear into a queue they cannot see.

notifications.md later builds its outbox table and retry worker on top of this same `sendMail()`. Notification mail is bulk and genuinely needs retries; auth mail does not. This also moves SMTP configuration into build step 1 — the brief had placed the email path in step 4, which was written when only notifications needed it (§14).

---

## 11. Purging expired rows

Both token tables accumulate dead rows.

- **Opportunistically**, `POST /api/auth/signin` deletes expired and consumed `login_token` rows for that email before inserting a new one.
- **On a schedule**, `npm run auth:purge` deletes `login_token` rows past `expires_at` and `session` rows past `expires_at`. deployment.md wires it to a daily systemd timer.

Neither is load-bearing for correctness — expiry is checked on every read — so a missed run degrades disk use and nothing else.

---

## 12. Testing

Beyond the predicate and mutator tests permissions.md §10 already specifies. See [testing.md](./testing.md) for the runner and database strategy — everything below is integration-tier against a real Postgres, except the boot-failure case, which spawns the process itself.

**Storage and redemption**

- No raw token is ever persisted: after a full sign-in, assert no column in `login_token` or `session` contains the raw value.
- A `GET` on `/auth/verify` leaves `consumed_at` null. This is the scanner-safety guarantee and it is the single most important test in this document.
- A second `POST` with the same token fails.
- A token past `expires_at` fails.
- Redeeming an invite creates the `user` row with the invite's role, stamps `accepted_at`, and derives `name` from the invite or the email's local part.

**Rotation**

- Sequential refreshes each rotate, and each pushes `expires_at` out.
- Two concurrent refreshes with the same token both return a usable access token, exactly one rotates, and the refresh cookie ends on the rotated value.
- A `prev_token_hash` match more than 30 seconds after `rotated_at` returns 401.

**Revocation**

- After `deactivateUser`, refresh returns 401 and `loadActor()` throws — the second asserted independently, since it is what stops writes before the token expires.
- Two concurrent demotions of the two remaining admins: exactly one succeeds and one admin remains.
- `signout-all` invalidates a second browser's session.

**Boundaries**

- `requireUser()` rejects a request whose only credential is a middleware-bypass header.
- `next=//evil.example` and `next=/\evil.example` are both rejected by the refresh hop.
- A cross-origin `POST` with a valid cookie is rejected by the `Origin` check.
- Boot fails with a missing or short `AUTH_SECRET`.
- **The auth tables are not in the publication.** Query `pg_publication_tables` and assert `invite`, `login_token` and `session` are absent. This is the test that keeps permissions.md §4's guarantee honest as the schema grows.

---

## 13. Out of scope for v1

Stated so none of it reads as an oversight.

- **Passwords.** There is no password anywhere in this system.
- **OAuth / SSO**, and therefore no `account` table. Provider bookkeeping an email-only app would never write.
- **Two-factor, TOTP, WebAuthn, passkeys.** The magic link is already a possession factor.
- **A "remember me" toggle.** One session lifetime for everyone.
- **Device management beyond `signout-all`.** `session.user_agent` exists so a future screen can label rows; there is no such screen in v1.
- **Refresh-token reuse detection** (§4.4).
- **Email enumeration protection** (§4.2).
- **An auth audit log.** permissions.md §11 already excludes an audit log for permission changes; this is the same decision.
- **Changing a user's email address.** `user.email` is the login identity and v1 has no mutator for it. The workaround is a direct database update, which deployment.md should note alongside the `admin:grant` command.
- **Multiple workspaces or tenants**, per permissions.md §11.

---

## 14. Changes this spec requires elsewhere

### To [team-works-concept-brief.md](./team-works-concept-brief.md) — applied 2026-07-31, the documents now agree

- **§5, "Auth & per-project access"** — Auth.js replaced by the hand-written scheme, with a pointer here. The role, membership and read-model bullets are unchanged.
- **§5, "Deployment (VPS)"** — the email path is required from build step 1 for magic links, not added in step 4 for notifications.
- **§6, build step 1** — "Auth.js issuing JWTs" becomes the hand-written session and JWT scheme, with SMTP configured; the step's assigned verifications go from two to three.
- **§7, Settled** — five decisions added from this document (15–19).
- **§7, Open** — a third verification added: whether Zero re-invokes its `auth` callback on token rejection (§5 here). Still no open decisions.
- **§8, future chat** — the backbone line named Auth.js/JWT; it now names this scheme.
- **§9** — auth.md added to the companion documents.

### To [data-model.md](./data-model.md) — applied 2026-07-31

- **§2** — the non-synced table list changes from `account`, `session`, `verification_token` (described as "Auth.js's own schema") to `invite`, `login_token`, `session`. `account` disappears entirely; §13 above explains why.
- **§12** — `next-auth` removed from the scaffold's dependency list; the `SECRET_KEY` item is discharged by §10 here.

### To [permissions.md](./permissions.md) — applied 2026-07-31

- **§8** — the server's `Actor` is loaded from the database by `loadActor()`, never built from the token's claims. The existing rule ("the server derives its own and never trusts the client's") extends from membership to `role`.
- **§7** — the last-admin check is specified as a `SELECT … FOR UPDATE` inside the mutator's transaction; promotion's "next JWT issuance" is clarified as affecting UI only, since authority comes from the database.

### To `CLAUDE.md` and `README.md` — applied 2026-07-31

Both were written by a concurrent session while this document was being drafted, and both named Auth.js.

- `CLAUDE.md` — the planned-architecture bullet and the build-step-1 dependency list drop `next-auth`; auth.md joins the source-of-truth list; the `requireUser()`/`loadActor()` distinction and the digest-only token storage rule are called out as things easy to get wrong; the third build-step-1 verification is recorded.
- `README.md` — the stack line and the document index.

### To the repository scaffold — not yet applied

- `.env.example` is replaced wholesale by §10's contract. The placeholder `SECRET_KEY` is deleted, not renamed.
- `package.json` gains `jose` and `nodemailer` (and `@types/nodemailer`), and does **not** gain `next-auth`.

### Deferred, with owners named

| Question | Owner |
| --- | --- |
| nginx `limit_req` on `/api/auth/*`, and suppressing query strings in the `/auth/verify` access log | deployment.md |
| The daily `auth:purge` timer, and `admin:grant` in the provisioning runbook | deployment.md |
| Running SMTP locally — MailHog, Mailpit or a real relay | local-dev.md |
| The sign-in, verify-confirmation and expired-link screens, and the pending-invite admin page | ui-spec.md |
| Reusing `sendMail()` behind an outbox with retries | notifications.md |

---

_Decisions here are settled. Revise deliberately, and reconcile the concept brief, permissions.md and data-model.md in the same change._
