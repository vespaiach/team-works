# Foundation C: Hand-Written Authentication Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the full hand-written auth system — invites, magic-link sign-in, JWT issuance, refresh rotation, sessions, route protection, deactivation and the last-admin guard — so a person can actually sign into the app, and so Plan D's Zero client has a working `/api/auth/refresh` to call from its `auth` callback.

**Architecture:** Thin Next.js route handlers (`src/app/api/auth/**/route.ts`) wrap small, independently-testable service functions in `src/lib/auth/*.ts`. Every function that touches Postgres accepts an optional trailing `handle: Db | Tx = db` parameter, and every function that sends mail accepts an optional trailing `mailer` parameter — both default to the real implementation in production and let tests inject a rolled-back transaction / a no-op stub. This plan assumes **Foundation A and Foundation B are complete** (`env.ts`, the full schema including `invite`/`login_token`/`session`, `tests/db.ts`'s `withTx`, `tests/factories.ts`).

**Tech Stack:** `jose` (JWT), Node's built-in `crypto` (token generation, SHA-256 digest), `nodemailer` (SMTP).

## Global Constraints

- **Raw tokens are never persisted** — only SHA-256 digests, in `bytea` columns, looked up by digest (auth.md §2). No code anywhere calls `timingSafeEqual`, because nothing compares two secrets.
- `AUTH_SECRET` and `ZERO_AUTH_SECRET` are one secret under two names (auth.md §2) — already enforced by `env.ts` (Foundation A).
- **`requireUser()` establishes identity** (cheap, no DB, may be stale); **`loadActor()` establishes authority** (re-reads `role`/`deactivated_at` from Postgres). Every server mutator calls `loadActor()`, never trusts the JWT's claims for an authorization decision (auth.md §6).
- **DB-touching functions take an optional trailing `handle: Db | Tx = db` parameter** (testing.md §3's constraint, which postdates and overrides auth.md's plain code samples) — production omits it, tests inject `tx` from `withTx`.
- **Mail-sending functions take an optional trailing `mailer` parameter** defaulting to the real `sendMail` — so the integration tier (and the Fast CI stage, testing.md §9) never needs a live SMTP server. Only the E2E tier (Plan D) exercises real delivery through Mailpit.
- Cookies: `tw_access` (900s) and `tw_refresh` (2592000s), both `HttpOnly`, `SameSite=Lax`, `Path=/`, `Secure` only when `APP_URL` starts with `https://` (auth.md §7).
- CSRF: `SameSite=Lax` plus an `Origin` check on every mutating handler (auth.md §7) — no state-changing `GET` except the one named exception below.
- The one state-changing `GET` is `/api/auth/refresh?next=…`, because middleware cannot reach Postgres (auth.md §6). `next` must be validated as a same-origin absolute path.
- Not `next-auth`, `next-auth`-adjacent, or any other auth library (CLAUDE.md).

---

## File Structure

```
src/lib/permissions.ts                          # new
src/lib/auth/tokens.ts                          # new
src/lib/auth/jwt.ts                             # new
src/lib/auth/require-user.ts                    # new
src/lib/auth/load-actor.ts                      # new
src/lib/auth/mail.ts                            # new
src/lib/auth/cookies.ts                         # new
src/lib/auth/origin-check.ts                    # new
src/lib/auth/next-path.ts                       # new
src/lib/auth/signin.ts                          # new
src/lib/auth/verify.ts                          # new
src/lib/auth/refresh.ts                         # new
src/lib/auth/signout.ts                         # new
src/lib/auth/admin-mutators.ts                  # new — inviteUser, deactivateUser, setUserRole
src/app/api/auth/signin/route.ts                # new
src/app/auth/verify/page.tsx                    # new
src/app/api/auth/verify/route.ts                # new
src/app/api/auth/refresh/route.ts               # new
src/app/api/auth/signout/route.ts               # new
src/app/api/auth/signout-all/route.ts           # new
src/middleware.ts                               # new
scripts/auth-purge.ts                           # new
tests/fixtures/boot-check.ts                    # new
tests/unit/permissions.test.ts                  # new
tests/unit/require-user.test.ts                 # new
tests/unit/origin-check.test.ts                 # new
tests/unit/next-path.test.ts                    # new
tests/unit/middleware.test.ts                   # new
tests/integration/load-actor.test.ts            # new
tests/integration/signin-verify.test.ts         # new
tests/integration/refresh.test.ts               # new
tests/integration/revocation.test.ts            # new
tests/integration/boot-failure.test.ts          # new
package.json                                    # modified — auth:purge script
```

---

### Task 1: `permissions.ts` — the pure predicate module

**Files:**
- Create: `src/lib/permissions.ts`
- Test: `tests/unit/permissions.test.ts`

**Interfaces:**
- Produces: `isAdmin`, `isMember`, `canCreateIssue`, `canEditIssue`, `canDeleteIssue`, `canComment`, `canEditComment`, `canDeleteComment`, `canDeleteAttachment`, `canManageProject`, `canManageMilestones`, `canManageLabels`, `canManageUsers`, and the types `Actor`, `Membership`, `IssueRow`, `CommentRow`, `AttachmentRow` — consumed by Task 6 (`inviteUser`/`deactivateUser`/`setUserRole` use `canManageUsers`) and, unchanged, by Plan D's client-side control-disabling.
- Consumes: nothing — permissions.md §8: "pure, no I/O, no framework imports."

Built here rather than deferred to the app-shell plan because it has zero dependencies and its first real consumer (`inviteUser`) is in this plan (Task 6).

- [ ] **Step 1: Write the failing tests**

testing.md §4: table-driven, one case per cell of the permissions matrix (permissions.md §3).

```ts
// tests/unit/permissions.test.ts
import { describe, it, expect } from 'vitest'
import {
  isAdmin, isMember, canCreateIssue, canEditIssue, canDeleteIssue,
  canComment, canEditComment, canDeleteComment, canDeleteAttachment,
  canManageProject, canManageMilestones, canManageLabels, canManageUsers,
  type Actor, type Membership,
} from '@/lib/permissions'

const PROJECT = 'project-1'
const admin: Actor = { id: 'admin-1', role: 'admin' }
const member: Actor = { id: 'member-1', role: 'member' }
const memberOf = (...projectIds: string[]): Membership => new Set(projectIds)

describe('permissions matrix (permissions.md §3)', () => {
  it('isMember returns true for admins regardless of ProjectMember rows', () => {
    expect(isMember(admin, memberOf(), PROJECT)).toBe(true)
    expect(isMember(member, memberOf(), PROJECT)).toBe(false)
    expect(isMember(member, memberOf(PROJECT), PROJECT)).toBe(true)
  })

  it('create issue / edit any issue / post comment: admin always, member only within their project, never a non-member', () => {
    for (const check of [canCreateIssue, canComment]) {
      expect(check(admin, memberOf(), PROJECT)).toBe(true)
      expect(check(member, memberOf(PROJECT), PROJECT)).toBe(true)
      expect(check(member, memberOf(), PROJECT)).toBe(false)
    }
    const anyIssue = { projectId: PROJECT }
    expect(canEditIssue(admin, memberOf(), anyIssue)).toBe(true)
    expect(canEditIssue(member, memberOf(PROJECT), anyIssue)).toBe(true)
    expect(canEditIssue(member, memberOf(), anyIssue)).toBe(false)
  })

  it('delete issue: admin only — membership does not grant it (permissions.md §3: members cancel, admins delete)', () => {
    expect(canDeleteIssue(admin)).toBe(true)
    expect(canDeleteIssue(member)).toBe(false)
  })

  it("edit comment: author only — no one, admins included, may edit another user's comment", () => {
    const ownComment = { projectId: PROJECT, authorId: member.id }
    const othersComment = { projectId: PROJECT, authorId: 'someone-else' }
    expect(canEditComment(member, memberOf(PROJECT), ownComment)).toBe(true)
    expect(canEditComment(member, memberOf(PROJECT), othersComment)).toBe(false)
    expect(canEditComment(admin, memberOf(), othersComment)).toBe(false)
  })

  it('delete comment: author or admin, never a different member', () => {
    const othersComment = { projectId: PROJECT, authorId: 'someone-else' }
    expect(canDeleteComment(admin, memberOf(), othersComment)).toBe(true)
    expect(canDeleteComment(member, memberOf(PROJECT), othersComment)).toBe(false)
    const ownComment = { projectId: PROJECT, authorId: member.id }
    expect(canDeleteComment(member, memberOf(PROJECT), ownComment)).toBe(true)
  })

  it('delete attachment: uploader or admin', () => {
    const ownAttachment = { projectId: PROJECT, uploadedBy: member.id }
    const othersAttachment = { projectId: PROJECT, uploadedBy: 'someone-else' }
    expect(canDeleteAttachment(member, memberOf(PROJECT), ownAttachment)).toBe(true)
    expect(canDeleteAttachment(member, memberOf(PROJECT), othersAttachment)).toBe(false)
    expect(canDeleteAttachment(admin, memberOf(), othersAttachment)).toBe(true)
  })

  it.each([
    ['project', canManageProject],
    ['milestones', canManageMilestones],
    ['labels', canManageLabels],
    ['users', canManageUsers],
  ] as const)('manage %s: admin only', (_name, predicate) => {
    expect(predicate(admin)).toBe(true)
    expect(predicate(member)).toBe(false)
  })
})
```

- [ ] **Step 2: Run it, verify it fails**

```bash
npm run test:unit
```

Expected: FAIL — `Cannot find module '@/lib/permissions'`.

- [ ] **Step 3: Implement `src/lib/permissions.ts`**

```ts
// src/lib/permissions.ts — pure, no I/O, no framework imports (permissions.md §8)

export type Role = 'admin' | 'member'
export type Actor = { id: string; role: Role }
export type Membership = ReadonlySet<string>

export type IssueRow = { projectId: string }
export type CommentRow = { projectId: string; authorId: string }
export type AttachmentRow = { projectId: string; uploadedBy: string }

export function isAdmin(actor: Actor): boolean {
  return actor.role === 'admin'
}

export function isMember(actor: Actor, membership: Membership, projectId: string): boolean {
  return isAdmin(actor) || membership.has(projectId)
}

export function canCreateIssue(actor: Actor, membership: Membership, projectId: string): boolean {
  return isMember(actor, membership, projectId)
}

export function canEditIssue(actor: Actor, membership: Membership, issue: IssueRow): boolean {
  return isMember(actor, membership, issue.projectId)
}

export function canDeleteIssue(actor: Actor): boolean {
  return isAdmin(actor)
}

export function canComment(actor: Actor, membership: Membership, projectId: string): boolean {
  return isMember(actor, membership, projectId)
}

export function canEditComment(actor: Actor, membership: Membership, comment: CommentRow): boolean {
  if (!isMember(actor, membership, comment.projectId)) return false
  return comment.authorId === actor.id
}

export function canDeleteComment(actor: Actor, membership: Membership, comment: CommentRow): boolean {
  if (!isMember(actor, membership, comment.projectId)) return false
  return comment.authorId === actor.id || isAdmin(actor)
}

export function canDeleteAttachment(actor: Actor, membership: Membership, attachment: AttachmentRow): boolean {
  if (!isMember(actor, membership, attachment.projectId)) return false
  return attachment.uploadedBy === actor.id || isAdmin(actor)
}

export function canManageProject(actor: Actor): boolean {
  return isAdmin(actor)
}

export function canManageMilestones(actor: Actor): boolean {
  return isAdmin(actor)
}

export function canManageLabels(actor: Actor): boolean {
  return isAdmin(actor)
}

export function canManageUsers(actor: Actor): boolean {
  return isAdmin(actor)
}
```

- [ ] **Step 4: Run it, verify it passes**

```bash
npm run test:unit
```

- [ ] **Step 5: Commit**

```bash
git add src/lib/permissions.ts tests/unit/permissions.test.ts
git commit -m "feat: add permissions predicate module"
```

---

### Task 2: Token primitives, JWT, `requireUser()`, `loadActor()`

**Files:**
- Create: `src/lib/auth/tokens.ts`, `src/lib/auth/jwt.ts`, `src/lib/auth/require-user.ts`, `src/lib/auth/load-actor.ts`
- Test: `tests/unit/require-user.test.ts`, `tests/integration/load-actor.test.ts`

**Interfaces:**
- Produces: `generateToken()`, `signAccessToken(claims)`, `verifyAccessToken(token)`, `requireUser(req)`, `AuthError`, `loadActor(userId, handle?)`. Consumed by every route handler in Tasks 4–7 and by Plan D's Zero `auth` callback wiring.

- [ ] **Step 1: Token generation and digest**

auth.md §2: "32 bytes from `crypto.randomBytes`, base64url... Both opaque tokens are stored as their SHA-256 digest."

```ts
// src/lib/auth/tokens.ts
import { randomBytes, createHash } from 'node:crypto'

export function generateToken(): { raw: string; hash: Buffer } {
  const raw = randomBytes(32).toString('base64url')
  return { raw, hash: digest(raw) }
}

export function digest(raw: string): Buffer {
  return createHash('sha256').update(raw).digest()
}
```

- [ ] **Step 2: JWT sign/verify**

auth.md §2: `{ sub, role, iat, exp }`, HS256, `jose`, 15-minute expiry.

```ts
// src/lib/auth/jwt.ts
import { SignJWT, jwtVerify } from 'jose'
import { env } from '@/lib/env'

export type Claims = { sub: string; role: 'admin' | 'member' }

const secret = new TextEncoder().encode(env.AUTH_SECRET)

// 900s (15m) in production, per auth.md §2. Overridable via an optional,
// non-secret env var — not part of auth.md §10's required 11-variable
// contract, so parseEnv does not require it — so Plan D's E2E verification
// of Zero's auth-callback re-invocation (auth.md §5) can force a real token
// expiry within a test's timeout instead of waiting 15 real minutes.
const ACCESS_TOKEN_TTL_SECONDS = Number(process.env.ACCESS_TOKEN_TTL_SECONDS ?? 900)

export async function signAccessToken(claims: Claims): Promise<string> {
  return new SignJWT({ role: claims.role })
    .setProtectedHeader({ alg: 'HS256' })
    .setSubject(claims.sub)
    .setIssuedAt()
    .setExpirationTime(Math.floor(Date.now() / 1000) + ACCESS_TOKEN_TTL_SECONDS)
    .sign(secret)
}

export async function verifyAccessToken(token: string): Promise<Claims> {
  const { payload } = await jwtVerify(token, secret)
  if (typeof payload.sub !== 'string' || (payload.role !== 'admin' && payload.role !== 'member')) {
    throw new Error('Malformed token claims')
  }
  return { sub: payload.sub, role: payload.role }
}
```

- [ ] **Step 3: `requireUser()`**

auth.md §5: accepts the token from either the cookie or an `Authorization: Bearer` header, since Zero's mutator push carries the header and no cookie.

```ts
// src/lib/auth/require-user.ts
import { verifyAccessToken } from './jwt'

export class AuthError extends Error {
  constructor(public status: number, message: string) {
    super(message)
  }
}

export async function requireUser(req: Request): Promise<{ userId: string; role: 'admin' | 'member' }> {
  const token = extractToken(req)
  if (!token) throw new AuthError(401, 'Missing credentials')
  try {
    const claims = await verifyAccessToken(token)
    return { userId: claims.sub, role: claims.role }
  } catch {
    throw new AuthError(401, 'Invalid or expired token')
  }
}

function extractToken(req: Request): string | null {
  const authHeader = req.headers.get('authorization')
  if (authHeader?.startsWith('Bearer ')) return authHeader.slice('Bearer '.length)

  const cookieHeader = req.headers.get('cookie') ?? ''
  const match = cookieHeader.match(/(?:^|;\s*)tw_access=([^;]+)/)
  return match ? decodeURIComponent(match[1]) : null
}
```

- [ ] **Step 4: Write and run `requireUser()`'s unit tests**

```ts
// tests/unit/require-user.test.ts
import { describe, it, expect } from 'vitest'
import { requireUser, AuthError } from '@/lib/auth/require-user'
import { signAccessToken } from '@/lib/auth/jwt'

describe('requireUser (auth.md §6, §12)', () => {
  it('accepts a valid token from the Authorization header', async () => {
    const token = await signAccessToken({ sub: 'user-1', role: 'member' })
    const req = new Request('http://localhost/api/x', { headers: { authorization: `Bearer ${token}` } })
    expect(await requireUser(req)).toEqual({ userId: 'user-1', role: 'member' })
  })

  it('accepts a valid token from the tw_access cookie', async () => {
    const token = await signAccessToken({ sub: 'user-1', role: 'admin' })
    const req = new Request('http://localhost/api/x', { headers: { cookie: `tw_access=${token}` } })
    expect((await requireUser(req)).role).toBe('admin')
  })

  it('rejects a request with no credentials', async () => {
    const req = new Request('http://localhost/api/x')
    await expect(requireUser(req)).rejects.toBeInstanceOf(AuthError)
  })

  it('rejects a request whose only credential is a spoofed middleware-bypass header', async () => {
    const req = new Request('http://localhost/api/x', { headers: { 'x-middleware-subrequest': 'true' } })
    await expect(requireUser(req)).rejects.toBeInstanceOf(AuthError)
  })
})
```

```bash
npm run test:unit
```

Expected: PASS.

- [ ] **Step 5: `loadActor()`**

auth.md §6: re-reads `role`/`deactivated_at` from Postgres. Takes the optional trailing `handle` per this plan's Global Constraints, even though auth.md's own code sample omits it — testing.md §3 requires it for `withTx` to work, and testing.md postdates auth.md.

```ts
// src/lib/auth/load-actor.ts
import { eq } from 'drizzle-orm'
import { db, type Db, type Tx } from '@/lib/db/client'
import { user } from '@/lib/db/schema'
import { AuthError } from './require-user'
import type { Actor } from '@/lib/permissions'

export async function loadActor(userId: string, handle: Db | Tx = db): Promise<Actor> {
  const [row] = await handle.select().from(user).where(eq(user.id, userId))
  if (!row) throw new AuthError(401, 'User not found')
  if (row.deactivatedAt) throw new AuthError(403, 'User is deactivated')
  return { id: row.id, role: row.role as 'admin' | 'member' }
}
```

- [ ] **Step 6: Write and run `loadActor()`'s integration test**

```ts
// tests/integration/load-actor.test.ts
import { describe, it, expect } from 'vitest'
import { withTx } from '../db'
import { makeUser } from '../factories'
import { loadActor } from '@/lib/auth/load-actor'
import { AuthError } from '@/lib/auth/require-user'

describe('loadActor (auth.md §6)', () => {
  it('returns the actor for an active user', async () => {
    await withTx(async (tx) => {
      const u = await makeUser(tx, { role: 'admin' })
      expect(await loadActor(u.id, tx)).toEqual({ id: u.id, role: 'admin' })
    })
  })

  it('throws for a deactivated user', async () => {
    await withTx(async (tx) => {
      const u = await makeUser(tx, { deactivatedAt: new Date() })
      await expect(loadActor(u.id, tx)).rejects.toBeInstanceOf(AuthError)
    })
  })

  it('throws for an id that does not exist', async () => {
    await withTx(async (tx) => {
      await expect(loadActor(crypto.randomUUID(), tx)).rejects.toBeInstanceOf(AuthError)
    })
  })
})
```

```bash
DATABASE_URL=postgresql://team_works@localhost:5432/team_works_test npm run test:integration
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/lib/auth/tokens.ts src/lib/auth/jwt.ts src/lib/auth/require-user.ts src/lib/auth/load-actor.ts tests/unit/require-user.test.ts tests/integration/load-actor.test.ts
git commit -m "feat: add token generation, JWT, requireUser, loadActor"
```

---

### Task 3: Supporting infra — mail, cookies, origin check, next-path validation

**Files:**
- Create: `src/lib/auth/mail.ts`, `src/lib/auth/cookies.ts`, `src/lib/auth/origin-check.ts`, `src/lib/auth/next-path.ts`
- Test: `tests/unit/origin-check.test.ts`, `tests/unit/next-path.test.ts`

**Interfaces:**
- Produces: `sendMail(opts)`, `setAuthCookies(res, tokens)`, `clearAuthCookies(res)`, `checkOrigin(req)`, `isSafeNextPath(next)` — used by every route in Tasks 4–7.

- [ ] **Step 1: `mail.ts`**

auth.md §10: `nodemailer` over SMTP, a small `sendMail()` module.

```ts
// src/lib/auth/mail.ts
import nodemailer from 'nodemailer'
import { env } from '@/lib/env'

const transport = nodemailer.createTransport({
  host: env.SMTP_HOST,
  port: env.SMTP_PORT,
  secure: env.SMTP_SECURE,
  auth: { user: env.SMTP_USER, pass: env.SMTP_PASS },
})

export async function sendMail(opts: { to: string; subject: string; text: string }): Promise<void> {
  await transport.sendMail({ from: env.SMTP_FROM, to: opts.to, subject: opts.subject, text: opts.text })
}
```

- [ ] **Step 2: `cookies.ts`**

auth.md §7's exact table.

```ts
// src/lib/auth/cookies.ts
import type { NextResponse } from 'next/server'
import { env } from '@/lib/env'

const secure = env.APP_URL.startsWith('https://')

export function setAuthCookies(res: NextResponse, tokens: { accessToken: string; refreshToken?: string }): void {
  res.cookies.set('tw_access', tokens.accessToken, { httpOnly: true, sameSite: 'lax', path: '/', secure, maxAge: 900 })
  if (tokens.refreshToken) {
    res.cookies.set('tw_refresh', tokens.refreshToken, { httpOnly: true, sameSite: 'lax', path: '/', secure, maxAge: 2_592_000 })
  }
}

export function clearAuthCookies(res: NextResponse): void {
  res.cookies.delete('tw_access')
  res.cookies.delete('tw_refresh')
}
```

- [ ] **Step 3: `origin-check.ts`, with its test**

```ts
// src/lib/auth/origin-check.ts
import { env } from '@/lib/env'

export function checkOrigin(req: Request): boolean {
  return req.headers.get('origin') === env.APP_URL
}
```

```ts
// tests/unit/origin-check.test.ts
import { describe, it, expect } from 'vitest'
import { checkOrigin } from '@/lib/auth/origin-check'

describe('checkOrigin (auth.md §7, §12)', () => {
  it('accepts a request whose Origin matches APP_URL', () => {
    expect(checkOrigin(new Request('http://x/y', { headers: { origin: 'http://localhost:3000' } }))).toBe(true)
  })
  it('rejects a cross-origin Origin header', () => {
    expect(checkOrigin(new Request('http://x/y', { headers: { origin: 'https://evil.example' } }))).toBe(false)
  })
  it('rejects a request with no Origin header', () => {
    expect(checkOrigin(new Request('http://x/y'))).toBe(false)
  })
})
```

- [ ] **Step 4: `next-path.ts`, with its test**

auth.md §6: `next` must begin with a single `/`; `//` and `/\` are rejected.

```ts
// src/lib/auth/next-path.ts
export function isSafeNextPath(next: string): boolean {
  return /^\/(?!\/|\\)/.test(next)
}
```

```ts
// tests/unit/next-path.test.ts
import { describe, it, expect } from 'vitest'
import { isSafeNextPath } from '@/lib/auth/next-path'

describe('isSafeNextPath (auth.md §6, §12)', () => {
  it('accepts a same-origin absolute path', () => expect(isSafeNextPath('/dashboard')).toBe(true))
  it('rejects a protocol-relative URL', () => expect(isSafeNextPath('//evil.example')).toBe(false))
  it('rejects a backslash-based bypass', () => expect(isSafeNextPath('/\\evil.example')).toBe(false))
})
```

- [ ] **Step 5: Run the unit tests, verify they pass**

```bash
npm run test:unit
```

- [ ] **Step 6: Commit**

```bash
git add src/lib/auth/mail.ts src/lib/auth/cookies.ts src/lib/auth/origin-check.ts src/lib/auth/next-path.ts tests/unit/origin-check.test.ts tests/unit/next-path.test.ts
git commit -m "feat: add mail, cookie, origin-check, and next-path helpers"
```

---

### Task 4: Sign-in and redemption

**Files:**
- Create: `src/lib/auth/signin.ts`, `src/lib/auth/verify.ts`, `src/app/api/auth/signin/route.ts`, `src/app/auth/verify/page.tsx`, `src/app/api/auth/verify/route.ts`
- Test: `tests/integration/signin-verify.test.ts`

**Interfaces:**
- Consumes: `db`/`Tx` (Plan B), `generateToken`/`digest` (Task 2), `sendMail` (Task 3), `checkOrigin` (Task 3).
- Produces: `requestSignInLink(email, handle?, mailer?)`, `ThrottledError`, `redeemLoginToken(rawToken, handle?)`, `RedeemError`, `RedeemResult`.

- [ ] **Step 1: `requestSignInLink`**

auth.md §4.2, with the §11 opportunistic purge and the §9 throttle folded in.

```ts
// src/lib/auth/signin.ts
import { and, eq, isNull, isNotNull, or, lt, gt, count } from 'drizzle-orm'
import { uuidv7 } from 'uuidv7'
import { db, type Db, type Tx } from '@/lib/db/client'
import { user, invite, loginToken } from '@/lib/db/schema'
import { generateToken } from './tokens'
import { sendMail } from './mail'
import { env } from '@/lib/env'

export class ThrottledError extends Error {}

export async function requestSignInLink(
  rawEmail: string,
  handle: Db | Tx = db,
  mailer: typeof sendMail = sendMail
): Promise<void> {
  const email = rawEmail.trim().toLowerCase()

  const [activeUser] = await handle.select().from(user).where(and(eq(user.email, email), isNull(user.deactivatedAt)))
  const [pendingInvite] = await handle
    .select()
    .from(invite)
    .where(and(eq(invite.email, email), isNull(invite.acceptedAt), gt(invite.expiresAt, new Date())))

  if (!activeUser && !pendingInvite) {
    return // generic ack either way (auth.md §4.2) — nothing to do
  }

  await handle
    .delete(loginToken)
    .where(and(eq(loginToken.email, email), or(lt(loginToken.expiresAt, new Date()), isNotNull(loginToken.consumedAt))))

  const [{ liveCount }] = await handle
    .select({ liveCount: count() })
    .from(loginToken)
    .where(and(eq(loginToken.email, email), isNull(loginToken.consumedAt), gt(loginToken.expiresAt, new Date())))

  if (liveCount >= 3) {
    throw new ThrottledError('A sign-in link is already waiting in your inbox.')
  }

  const { raw, hash } = generateToken()
  await handle.insert(loginToken).values({
    id: uuidv7(),
    tokenHash: hash,
    email,
    expiresAt: new Date(Date.now() + 15 * 60 * 1000),
  })

  await mailer({ to: email, subject: 'Sign in to Team Works', text: `${env.APP_URL}/auth/verify?token=${raw}` })
}
```

- [ ] **Step 2: `redeemLoginToken`**

auth.md §4.3, the two-step split — this function is the `POST` half only; the `GET` confirmation page (Step 3) reads without calling it.

```ts
// src/lib/auth/verify.ts
import { createHash } from 'node:crypto'
import { eq, and } from 'drizzle-orm'
import { uuidv7 } from 'uuidv7'
import { db, type Db, type Tx } from '@/lib/db/client'
import { user, invite, loginToken, session } from '@/lib/db/schema'
import { generateToken } from './tokens'

export class RedeemError extends Error {}

export type RedeemResult = { userId: string; role: 'admin' | 'member'; refreshToken: string }

export async function redeemLoginToken(rawToken: string, handle: Db | Tx = db): Promise<RedeemResult> {
  const hash = createHash('sha256').update(rawToken).digest()

  return handle.transaction(async (tx) => {
    const [row] = await tx.select().from(loginToken).where(eq(loginToken.tokenHash, hash)).for('update')

    if (!row) throw new RedeemError('Invalid token')
    if (row.consumedAt) throw new RedeemError('Token already used')
    if (row.expiresAt <= new Date()) throw new RedeemError('Token expired')

    await tx.update(loginToken).set({ consumedAt: new Date() }).where(eq(loginToken.id, row.id))

    const [existingUser] = await tx.select().from(user).where(eq(user.email, row.email))

    let resolvedUserId: string
    let resolvedRole: 'admin' | 'member'

    if (existingUser && !existingUser.deactivatedAt) {
      resolvedUserId = existingUser.id
      resolvedRole = existingUser.role as 'admin' | 'member'
    } else if (existingUser && existingUser.deactivatedAt) {
      throw new RedeemError('This account has been deactivated')
    } else {
      const [pendingInvite] = await tx.select().from(invite).where(eq(invite.email, row.email))
      if (!pendingInvite || pendingInvite.acceptedAt || pendingInvite.expiresAt <= new Date()) {
        throw new RedeemError('No account or pending invite for this address')
      }

      const [created] = await tx
        .insert(user)
        .values({
          id: uuidv7(),
          name: pendingInvite.name ?? row.email.split('@')[0],
          email: row.email,
          role: pendingInvite.role as 'admin' | 'member',
        })
        .returning()

      await tx.update(invite).set({ acceptedAt: new Date() }).where(eq(invite.id, pendingInvite.id))

      resolvedUserId = created.id
      resolvedRole = created.role as 'admin' | 'member'
    }

    const { raw: refreshRaw, hash: refreshHash } = generateToken()
    await tx.insert(session).values({
      id: uuidv7(),
      userId: resolvedUserId,
      tokenHash: refreshHash,
      expiresAt: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
    })

    return { userId: resolvedUserId, role: resolvedRole, refreshToken: refreshRaw }
  })
}
```

Note: `handle.transaction(...)` works whether `handle` is the real `db` or an already-open `tx` from `withTx` — Drizzle nests the latter as a savepoint. Verify this against the installed `drizzle-orm` version during Step 6 below; if nested transactions aren't supported the way expected, drop the inner `.transaction()` wrapper and require callers to already be inside one (production routes would then open the transaction themselves before calling `redeemLoginToken`).

`.for('update')` row-locking syntax: confirm against the installed `drizzle-orm` version's query-builder docs — this is the same kind of pinned-version fact Foundation A's Task 1 asks to record.

- [ ] **Step 3: The `GET /auth/verify` confirmation page — consumes nothing**

auth.md §4.3: "`GET /auth/verify?token=…` consumes nothing... Expired, consumed and unknown tokens render their own explanatory states."

```tsx
// src/app/auth/verify/page.tsx
import { createHash } from 'node:crypto'
import { eq } from 'drizzle-orm'
import type { Metadata } from 'next'
import { db } from '@/lib/db/client'
import { loginToken } from '@/lib/db/schema'

export const metadata: Metadata = { referrer: 'no-referrer' }

export default async function VerifyPage({ searchParams }: { searchParams: Promise<{ token?: string }> }) {
  const { token } = await searchParams
  if (!token) return <State title="This link isn't valid." />

  const hash = createHash('sha256').update(token).digest()
  const [row] = await db.select().from(loginToken).where(eq(loginToken.tokenHash, hash))

  if (!row) return <State title="This link isn't valid." />
  if (row.consumedAt) return <State title="This link has already been used." />
  if (row.expiresAt <= new Date()) return <State title="This link has expired." />

  return (
    <main>
      <h1>Sign in as {row.email}</h1>
      <form method="post" action="/api/auth/verify">
        <input type="hidden" name="token" value={token} />
        <button type="submit">Sign in</button>
      </form>
    </main>
  )
}

function State({ title }: { title: string }) {
  return (
    <main>
      <h1>{title}</h1>
      <a href="/signin">Request a new one</a>
    </main>
  )
}
```

- [ ] **Step 4: The `POST /api/auth/verify` redeem route**

```ts
// src/app/api/auth/verify/route.ts
import { NextResponse } from 'next/server'
import { redeemLoginToken, RedeemError } from '@/lib/auth/verify'
import { signAccessToken } from '@/lib/auth/jwt'
import { setAuthCookies } from '@/lib/auth/cookies'
import { checkOrigin } from '@/lib/auth/origin-check'
import { env } from '@/lib/env'

export async function POST(req: Request) {
  if (!checkOrigin(req)) return NextResponse.json({ error: 'Invalid origin' }, { status: 403 })

  const form = await req.formData()
  const token = form.get('token')
  if (typeof token !== 'string') return NextResponse.json({ error: 'token is required' }, { status: 400 })

  let result
  try {
    result = await redeemLoginToken(token)
  } catch (err) {
    if (err instanceof RedeemError) {
      return NextResponse.redirect(new URL(`/signin?error=${encodeURIComponent(err.message)}`, env.APP_URL))
    }
    throw err
  }

  const accessToken = await signAccessToken({ sub: result.userId, role: result.role })
  const response = NextResponse.redirect(new URL('/', env.APP_URL))
  setAuthCookies(response, { accessToken, refreshToken: result.refreshToken })
  return response
}
```

- [ ] **Step 5: The `POST /api/auth/signin` route**

```ts
// src/app/api/auth/signin/route.ts
import { NextResponse } from 'next/server'
import { requestSignInLink, ThrottledError } from '@/lib/auth/signin'
import { checkOrigin } from '@/lib/auth/origin-check'

export async function POST(req: Request) {
  if (!checkOrigin(req)) return NextResponse.json({ error: 'Invalid origin' }, { status: 403 })

  const body = await req.json().catch(() => null)
  if (!body?.email || typeof body.email !== 'string') {
    return NextResponse.json({ error: 'email is required' }, { status: 400 })
  }

  try {
    await requestSignInLink(body.email)
  } catch (err) {
    if (err instanceof ThrottledError) return NextResponse.json({ error: err.message }, { status: 429 })
    console.error('signin send failed', err)
    return NextResponse.json({ error: 'Could not send the email — try again shortly.' }, { status: 502 })
  }

  return NextResponse.json({ ok: true })
}
```

- [ ] **Step 6: Write the failing integration tests**

auth.md §12 "Storage and redemption."

```ts
// tests/integration/signin-verify.test.ts
import { describe, it, expect } from 'vitest'
import { createHash } from 'node:crypto'
import { eq } from 'drizzle-orm'
import { withTx } from '../db'
import { makeUser } from '../factories'
import { requestSignInLink, ThrottledError } from '@/lib/auth/signin'
import { redeemLoginToken, RedeemError } from '@/lib/auth/verify'
import { loginToken, session, invite } from '@/lib/db/schema'

const noopMailer = async () => {}

async function seedLoginToken(tx: any, email: string, raw: string, overrides: Partial<{ expiresAt: Date; consumedAt: Date | null }> = {}) {
  await tx.insert(loginToken).values({
    id: crypto.randomUUID(),
    tokenHash: createHash('sha256').update(raw).digest(),
    email,
    expiresAt: overrides.expiresAt ?? new Date(Date.now() + 60_000),
    consumedAt: overrides.consumedAt ?? null,
  })
}

describe('sign-in and redemption (auth.md §4.2-4.3, §12)', () => {
  it('stores only the digest, never the raw token', async () => {
    await withTx(async (tx) => {
      await makeUser(tx, { email: 'ada@example.com' })
      await requestSignInLink('ada@example.com', tx, noopMailer)
      const [row] = await tx.select().from(loginToken).where(eq(loginToken.email, 'ada@example.com'))
      expect(row.tokenHash).toBeInstanceOf(Buffer)
      expect(row.tokenHash.length).toBe(32) // SHA-256 digest length; no raw-token column exists
    })
  })

  it('issuing a link leaves consumed_at null — the scanner-safety guarantee', async () => {
    await withTx(async (tx) => {
      await makeUser(tx, { email: 'bo@example.com' })
      await requestSignInLink('bo@example.com', tx, noopMailer)
      const [row] = await tx.select().from(loginToken).where(eq(loginToken.email, 'bo@example.com'))
      expect(row.consumedAt).toBeNull()
    })
  })

  it('redeeming as an existing active user creates a session and returns their role', async () => {
    await withTx(async (tx) => {
      const u = await makeUser(tx, { email: 'cy@example.com', role: 'admin' })
      await seedLoginToken(tx, 'cy@example.com', 'raw-cy')

      const result = await redeemLoginToken('raw-cy', tx)
      expect(result.userId).toBe(u.id)
      expect(result.role).toBe('admin')

      const [sessionRow] = await tx.select().from(session).where(eq(session.userId, u.id))
      expect(sessionRow).toBeDefined()
    })
  })

  it('a second redemption of the same token fails', async () => {
    await withTx(async (tx) => {
      await makeUser(tx, { email: 'dee@example.com' })
      await seedLoginToken(tx, 'dee@example.com', 'raw-dee')
      await redeemLoginToken('raw-dee', tx)
      await expect(redeemLoginToken('raw-dee', tx)).rejects.toBeInstanceOf(RedeemError)
    })
  })

  it('a token past expires_at fails', async () => {
    await withTx(async (tx) => {
      await makeUser(tx, { email: 'eli@example.com' })
      await seedLoginToken(tx, 'eli@example.com', 'raw-eli', { expiresAt: new Date(Date.now() - 1000) })
      await expect(redeemLoginToken('raw-eli', tx)).rejects.toBeInstanceOf(RedeemError)
    })
  })

  it('redeeming an invite creates the user row with the invite role and stamps accepted_at', async () => {
    await withTx(async (tx) => {
      const admin = await makeUser(tx, { role: 'admin' })
      const [inv] = await tx
        .insert(invite)
        .values({
          id: crypto.randomUUID(),
          email: 'newperson@example.com',
          name: 'New Person',
          role: 'member',
          invitedBy: admin.id,
          expiresAt: new Date(Date.now() + 60_000),
        })
        .returning()

      await seedLoginToken(tx, 'newperson@example.com', 'raw-invite')
      const result = await redeemLoginToken('raw-invite', tx)
      expect(result.role).toBe('member')

      const [updatedInvite] = await tx.select().from(invite).where(eq(invite.id, inv.id))
      expect(updatedInvite.acceptedAt).not.toBeNull()
    })
  })

  it('throttles at three or more live tokens for the same address', async () => {
    await withTx(async (tx) => {
      await makeUser(tx, { email: 'flo@example.com' })
      await requestSignInLink('flo@example.com', tx, noopMailer)
      await requestSignInLink('flo@example.com', tx, noopMailer)
      await requestSignInLink('flo@example.com', tx, noopMailer)
      await expect(requestSignInLink('flo@example.com', tx, noopMailer)).rejects.toBeInstanceOf(ThrottledError)
    })
  })
})
```

- [ ] **Step 7: Run, verify pass**

```bash
DATABASE_URL=postgresql://team_works@localhost:5432/team_works_test npm run test:integration
```

- [ ] **Step 8: Commit**

```bash
git add src/lib/auth/signin.ts src/lib/auth/verify.ts src/app/api/auth/signin src/app/auth/verify src/app/api/auth/verify tests/integration/signin-verify.test.ts
git commit -m "feat: add sign-in request and magic-link redemption"
```

---

### Task 5: Refresh and rotation

**Files:**
- Create: `src/lib/auth/refresh.ts`, `src/app/api/auth/refresh/route.ts`
- Test: `tests/integration/refresh.test.ts`

**Interfaces:**
- Consumes: `generateToken` (Task 2), `signAccessToken` (Task 2), `setAuthCookies`/`clearAuthCookies` (Task 3), `isSafeNextPath` (Task 3).
- Produces: `refresh(rawRefreshToken, handle?)`, `RefreshError` — this is what Plan D's Zero `auth` callback calls.

- [ ] **Step 1: `refresh()` — the three-outcome table from auth.md §4.4**

```ts
// src/lib/auth/refresh.ts
import { createHash } from 'node:crypto'
import { eq } from 'drizzle-orm'
import { db, type Db, type Tx } from '@/lib/db/client'
import { session, user } from '@/lib/db/schema'
import { generateToken } from './tokens'
import { signAccessToken } from './jwt'

export class RefreshError extends Error {}

export type RefreshResult = { accessToken: string; refreshToken?: string; expiresAt?: Date }

const THIRTY_DAYS_MS = 30 * 24 * 60 * 60 * 1000
const GRACE_WINDOW_MS = 30_000

export async function refresh(rawRefreshToken: string, handle: Db | Tx = db): Promise<RefreshResult> {
  const hash = createHash('sha256').update(rawRefreshToken).digest()

  return handle.transaction(async (tx) => {
    const [byCurrent] = await tx.select().from(session).where(eq(session.tokenHash, hash)).for('update')

    if (byCurrent) {
      const actor = await loadActiveUser(tx, byCurrent.userId)
      const { raw, hash: newHash } = generateToken()
      const newExpiresAt = new Date(Date.now() + THIRTY_DAYS_MS)

      await tx
        .update(session)
        .set({ prevTokenHash: byCurrent.tokenHash, tokenHash: newHash, rotatedAt: new Date(), expiresAt: newExpiresAt, lastUsedAt: new Date() })
        .where(eq(session.id, byCurrent.id))

      const accessToken = await signAccessToken({ sub: actor.id, role: actor.role })
      return { accessToken, refreshToken: raw, expiresAt: newExpiresAt }
    }

    const [byPrev] = await tx.select().from(session).where(eq(session.prevTokenHash, hash)).for('update')

    if (byPrev && byPrev.rotatedAt && byPrev.rotatedAt.getTime() > Date.now() - GRACE_WINDOW_MS) {
      const actor = await loadActiveUser(tx, byPrev.userId)
      // Grace branch: return an access token only, touch nothing else (auth.md §4.4).
      const accessToken = await signAccessToken({ sub: actor.id, role: actor.role })
      return { accessToken }
    }

    throw new RefreshError('Invalid or expired refresh token')
  })
}

async function loadActiveUser(tx: Tx, userId: string): Promise<{ id: string; role: 'admin' | 'member' }> {
  const [row] = await tx.select().from(user).where(eq(user.id, userId))
  if (!row || row.deactivatedAt) throw new RefreshError('Account is deactivated')
  return { id: row.id, role: row.role as 'admin' | 'member' }
}
```

- [ ] **Step 2: The refresh routes — `POST` (Zero's `auth` callback and the browser) and `GET` (the middleware hop)**

```ts
// src/app/api/auth/refresh/route.ts
import { NextResponse } from 'next/server'
import { refresh, RefreshError } from '@/lib/auth/refresh'
import { setAuthCookies, clearAuthCookies } from '@/lib/auth/cookies'
import { isSafeNextPath } from '@/lib/auth/next-path'
import { env } from '@/lib/env'

function getRefreshCookie(req: Request): string | null {
  const cookieHeader = req.headers.get('cookie') ?? ''
  const match = cookieHeader.match(/(?:^|;\s*)tw_refresh=([^;]+)/)
  return match ? decodeURIComponent(match[1]) : null
}

export async function POST(req: Request) {
  const raw = getRefreshCookie(req)
  if (!raw) return NextResponse.json({ error: 'No refresh token' }, { status: 401 })

  try {
    const result = await refresh(raw)
    const response = NextResponse.json({ token: result.accessToken, expiresAt: result.expiresAt ?? null })
    setAuthCookies(response, { accessToken: result.accessToken, refreshToken: result.refreshToken })
    return response
  } catch (err) {
    if (err instanceof RefreshError) {
      const response = NextResponse.json({ error: err.message }, { status: 401 })
      clearAuthCookies(response)
      return response
    }
    throw err
  }
}

// The one state-changing GET (auth.md §6) — middleware rewrites here because it
// cannot reach Postgres to refresh in place.
export async function GET(req: Request) {
  const url = new URL(req.url)
  const next = url.searchParams.get('next') ?? '/'
  if (!isSafeNextPath(next)) return NextResponse.json({ error: 'Invalid next parameter' }, { status: 400 })

  const raw = getRefreshCookie(req)
  if (!raw) return NextResponse.redirect(new URL('/signin', env.APP_URL))

  try {
    const result = await refresh(raw)
    const response = NextResponse.redirect(new URL(next, env.APP_URL))
    setAuthCookies(response, { accessToken: result.accessToken, refreshToken: result.refreshToken })
    return response
  } catch {
    const response = NextResponse.redirect(new URL('/signin', env.APP_URL))
    clearAuthCookies(response)
    return response
  }
}
```

- [ ] **Step 3: Write the failing integration tests**

auth.md §12 "Rotation." The sequential and grace-window cases run inside `withTx`; the true concurrent race needs two genuinely overlapping transactions, which the single shared rollback transaction cannot produce, so that one case runs against the real `db` handle with explicit cleanup.

```ts
// tests/integration/refresh.test.ts
import { describe, it, expect } from 'vitest'
import { eq, and, isNull, inArray } from 'drizzle-orm'
import { createHash, randomBytes } from 'node:crypto'
import { uuidv7 } from 'uuidv7'
import { withTx, type Tx } from '../db'
import { makeUser } from '../factories'
import { db } from '@/lib/db/client'
import { refresh, RefreshError } from '@/lib/auth/refresh'
import { session, user } from '@/lib/db/schema'

async function seedSession(handle: Tx | typeof db, userId: string) {
  const raw = randomBytes(32).toString('base64url')
  await handle.insert(session).values({
    id: uuidv7(),
    userId,
    tokenHash: createHash('sha256').update(raw).digest(),
    expiresAt: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
  })
  return raw
}

describe('refresh rotation (auth.md §4.4, §12)', () => {
  it('sequential refreshes each rotate and push expires_at out', async () => {
    await withTx(async (tx) => {
      const u = await makeUser(tx)
      const raw1 = await seedSession(tx, u.id)

      const r1 = await refresh(raw1, tx)
      expect(r1.refreshToken).toBeDefined()
      expect(r1.refreshToken).not.toBe(raw1)

      const r2 = await refresh(r1.refreshToken!, tx)
      expect(r2.refreshToken).toBeDefined()
      expect(r2.refreshToken).not.toBe(r1.refreshToken)
    })
  })

  it('a prev_token_hash match inside the 30s grace window returns an access token and rotates nothing', async () => {
    await withTx(async (tx) => {
      const u = await makeUser(tx)
      const raw1 = await seedSession(tx, u.id)
      await refresh(raw1, tx) // raw1 becomes prev

      const grace = await refresh(raw1, tx)
      expect(grace.accessToken).toBeDefined()
      expect(grace.refreshToken).toBeUndefined()
    })
  })

  it('a prev_token_hash match after the grace window fails', async () => {
    await withTx(async (tx) => {
      const u = await makeUser(tx)
      const raw1 = await seedSession(tx, u.id)
      await refresh(raw1, tx)
      await tx.update(session).set({ rotatedAt: new Date(Date.now() - 31_000) }).where(eq(session.userId, u.id))
      await expect(refresh(raw1, tx)).rejects.toBeInstanceOf(RefreshError)
    })
  })

  it('refresh fails immediately for a deactivated user', async () => {
    await withTx(async (tx) => {
      const u = await makeUser(tx, { deactivatedAt: new Date() })
      const raw = await seedSession(tx, u.id)
      await expect(refresh(raw, tx)).rejects.toBeInstanceOf(RefreshError)
    })
  })

  it('two concurrent refreshes with the same token: both succeed, exactly one rotates', async () => {
    const [u] = await db.insert(user).values({ id: uuidv7(), name: 'Race', email: `race-${uuidv7()}@example.com`, role: 'member' }).returning()
    const raw = await seedSession(db, u.id)

    const [a, b] = await Promise.all([refresh(raw, db), refresh(raw, db)])
    expect(a.accessToken).toBeDefined()
    expect(b.accessToken).toBeDefined()

    const rotated = [a.refreshToken, b.refreshToken].filter(Boolean)
    expect(rotated).toHaveLength(1)

    await db.delete(session).where(eq(session.userId, u.id))
    await db.delete(user).where(eq(user.id, u.id))
  })
})
```

- [ ] **Step 4: Run, verify pass**

```bash
DATABASE_URL=postgresql://team_works@localhost:5432/team_works_test npm run test:integration
```

- [ ] **Step 5: Commit**

```bash
git add src/lib/auth/refresh.ts src/app/api/auth/refresh tests/integration/refresh.test.ts
git commit -m "feat: add refresh rotation with the concurrent-refresh grace window"
```

---

### Task 6: Sign-out, invites, deactivation, and the last-admin guard

**Files:**
- Create: `src/lib/auth/signout.ts`, `src/lib/auth/admin-mutators.ts`, `src/app/api/auth/signout/route.ts`, `src/app/api/auth/signout-all/route.ts`
- Test: `tests/integration/revocation.test.ts`

**Interfaces:**
- Consumes: `loadActor` (Task 2), `canManageUsers` (Task 1), `checkOrigin`/`clearAuthCookies` (Task 3).
- Produces: `signOut`, `signOutAll`, `inviteUser`, `deactivateUser`, `setUserRole`, `ForbiddenError`, `ConflictError`, `LastAdminError`.

- [ ] **Step 1: `signout.ts`**

```ts
// src/lib/auth/signout.ts
import { eq } from 'drizzle-orm'
import { createHash } from 'node:crypto'
import { db, type Db, type Tx } from '@/lib/db/client'
import { session } from '@/lib/db/schema'

export async function signOut(rawRefreshToken: string, handle: Db | Tx = db): Promise<void> {
  const hash = createHash('sha256').update(rawRefreshToken).digest()
  await handle.delete(session).where(eq(session.tokenHash, hash))
}

export async function signOutAll(userId: string, handle: Db | Tx = db): Promise<void> {
  await handle.delete(session).where(eq(session.userId, userId))
}
```

- [ ] **Step 2: `admin-mutators.ts`**

auth.md §4.1 (invite), §8 (deactivation, last-admin `SELECT … FOR UPDATE`).

```ts
// src/lib/auth/admin-mutators.ts
import { and, eq, isNull, ne } from 'drizzle-orm'
import { uuidv7 } from 'uuidv7'
import { db, type Db, type Tx } from '@/lib/db/client'
import { user, invite, session, loginToken } from '@/lib/db/schema'
import { loadActor } from './load-actor'
import { canManageUsers } from '@/lib/permissions'

export class ForbiddenError extends Error {}
export class ConflictError extends Error {}
export class LastAdminError extends Error {}

export async function inviteUser(
  actorId: string,
  input: { email: string; name?: string; role: 'admin' | 'member' },
  handle: Db | Tx = db
): Promise<void> {
  const actor = await loadActor(actorId, handle)
  if (!canManageUsers(actor)) throw new ForbiddenError('Only admins can invite users')

  const email = input.email.trim().toLowerCase()

  await handle.transaction(async (tx) => {
    const [existingUser] = await tx.select().from(user).where(eq(user.email, email))
    if (existingUser && !existingUser.deactivatedAt) throw new ConflictError('Already a member')
    if (existingUser && existingUser.deactivatedAt) throw new ConflictError('Reactivate this person instead')

    const expiresAt = new Date(Date.now() + 14 * 24 * 60 * 60 * 1000)
    const [existingInvite] = await tx.select().from(invite).where(eq(invite.email, email))

    if (existingInvite) {
      await tx.update(invite).set({ name: input.name, role: input.role, expiresAt, updatedAt: new Date() }).where(eq(invite.id, existingInvite.id))
    } else {
      await tx.insert(invite).values({ id: uuidv7(), email, name: input.name, role: input.role, invitedBy: actorId, expiresAt })
    }
  })

  // §4.1 step 4 (issue a login_token and send the invite email, reusing
  // requestSignInLink's internals) is wired up once the admin console page
  // exists to call this (ui-spec.md owns that screen) — nothing renders it
  // within Foundation's scope, so this function stops at the invite row.
}

async function assertNotLastAdmin(tx: Tx, excludingUserId: string): Promise<void> {
  const [otherAdmin] = await tx
    .select({ id: user.id })
    .from(user)
    .where(and(eq(user.role, 'admin'), isNull(user.deactivatedAt), ne(user.id, excludingUserId)))
    .for('update')
  if (!otherAdmin) throw new LastAdminError('Cannot remove the last admin')
}

export async function setUserRole(actorId: string, targetId: string, role: 'admin' | 'member', handle: Db | Tx = db): Promise<void> {
  const actor = await loadActor(actorId, handle)
  if (!canManageUsers(actor)) throw new ForbiddenError('Only admins can change roles')

  await handle.transaction(async (tx) => {
    if (role === 'member') await assertNotLastAdmin(tx, targetId)
    await tx.update(user).set({ role, updatedAt: new Date() }).where(eq(user.id, targetId))
  })
}

export async function deactivateUser(actorId: string, targetId: string, handle: Db | Tx = db): Promise<void> {
  const actor = await loadActor(actorId, handle)
  if (!canManageUsers(actor)) throw new ForbiddenError('Only admins can deactivate users')

  await handle.transaction(async (tx) => {
    const [target] = await tx.select().from(user).where(eq(user.id, targetId))
    if (!target) throw new ForbiddenError('User not found')
    if (target.role === 'admin') await assertNotLastAdmin(tx, targetId)

    await tx.update(user).set({ deactivatedAt: new Date(), updatedAt: new Date() }).where(eq(user.id, targetId))
    await tx.delete(session).where(eq(session.userId, targetId))
    await tx.delete(loginToken).where(eq(loginToken.email, target.email))
  })
}
```

- [ ] **Step 3: Sign-out routes**

```ts
// src/app/api/auth/signout/route.ts
import { NextResponse } from 'next/server'
import { signOut } from '@/lib/auth/signout'
import { clearAuthCookies } from '@/lib/auth/cookies'
import { checkOrigin } from '@/lib/auth/origin-check'

export async function POST(req: Request) {
  if (!checkOrigin(req)) return NextResponse.json({ error: 'Invalid origin' }, { status: 403 })

  const cookieHeader = req.headers.get('cookie') ?? ''
  const match = cookieHeader.match(/(?:^|;\s*)tw_refresh=([^;]+)/)
  if (match) await signOut(decodeURIComponent(match[1]))

  const response = NextResponse.json({ ok: true })
  clearAuthCookies(response)
  return response
}
```

```ts
// src/app/api/auth/signout-all/route.ts
import { NextResponse } from 'next/server'
import { requireUser } from '@/lib/auth/require-user'
import { signOutAll } from '@/lib/auth/signout'
import { clearAuthCookies } from '@/lib/auth/cookies'
import { checkOrigin } from '@/lib/auth/origin-check'

export async function POST(req: Request) {
  if (!checkOrigin(req)) return NextResponse.json({ error: 'Invalid origin' }, { status: 403 })
  const claims = await requireUser(req)
  await signOutAll(claims.userId)
  const response = NextResponse.json({ ok: true })
  clearAuthCookies(response)
  return response
}
```

- [ ] **Step 4: Write the failing integration tests**

auth.md §12 "Revocation."

```ts
// tests/integration/revocation.test.ts
import { describe, it, expect } from 'vitest'
import { eq, and, isNull, inArray } from 'drizzle-orm'
import { createHash, randomBytes } from 'node:crypto'
import { uuidv7 } from 'uuidv7'
import { withTx, type Tx } from '../db'
import { makeUser } from '../factories'
import { db } from '@/lib/db/client'
import { user, session } from '@/lib/db/schema'
import { deactivateUser, setUserRole, LastAdminError, ForbiddenError } from '@/lib/auth/admin-mutators'
import { signOut, signOutAll } from '@/lib/auth/signout'
import { refresh, RefreshError } from '@/lib/auth/refresh'
import { loadActor } from '@/lib/auth/load-actor'
import { AuthError } from '@/lib/auth/require-user'

async function seedSession(handle: Tx | typeof db, userId: string) {
  const raw = randomBytes(32).toString('base64url')
  await handle.insert(session).values({
    id: uuidv7(),
    userId,
    tokenHash: createHash('sha256').update(raw).digest(),
    expiresAt: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000),
  })
  return raw
}

describe('revocation (auth.md §8, §12)', () => {
  it('deactivateUser stops refresh and loadActor immediately', async () => {
    await withTx(async (tx) => {
      const admin = await makeUser(tx, { role: 'admin' })
      const target = await makeUser(tx, { role: 'member' })
      const raw = await seedSession(tx, target.id)

      await deactivateUser(admin.id, target.id, tx)

      await expect(refresh(raw, tx)).rejects.toBeInstanceOf(RefreshError)
      await expect(loadActor(target.id, tx)).rejects.toBeInstanceOf(AuthError)
    })
  })

  it('cannot deactivate or demote the last admin', async () => {
    await withTx(async (tx) => {
      const onlyAdmin = await makeUser(tx, { role: 'admin' })
      await expect(deactivateUser(onlyAdmin.id, onlyAdmin.id, tx)).rejects.toBeInstanceOf(LastAdminError)
      await expect(setUserRole(onlyAdmin.id, onlyAdmin.id, 'member', tx)).rejects.toBeInstanceOf(LastAdminError)
    })
  })

  it('a non-admin cannot deactivate anyone', async () => {
    await withTx(async (tx) => {
      const member = await makeUser(tx, { role: 'member' })
      const other = await makeUser(tx, { role: 'member' })
      await expect(deactivateUser(member.id, other.id, tx)).rejects.toBeInstanceOf(ForbiddenError)
    })
  })

  it('signout-all invalidates every session for the user', async () => {
    await withTx(async (tx) => {
      const u = await makeUser(tx)
      const rawA = await seedSession(tx, u.id)
      const rawB = await seedSession(tx, u.id)
      await signOutAll(u.id, tx)
      await expect(refresh(rawA, tx)).rejects.toBeInstanceOf(RefreshError)
      await expect(refresh(rawB, tx)).rejects.toBeInstanceOf(RefreshError)
    })
  })

  it('signout removes only the current session, not a second browser\'s', async () => {
    await withTx(async (tx) => {
      const u = await makeUser(tx)
      const rawA = await seedSession(tx, u.id)
      const rawB = await seedSession(tx, u.id)
      await signOut(rawA, tx)
      await expect(refresh(rawA, tx)).rejects.toBeInstanceOf(RefreshError)
      await expect(refresh(rawB, tx)).resolves.toBeDefined()
    })
  })

  it('two concurrent demotions of the two remaining admins: exactly one succeeds', async () => {
    const [a] = await db.insert(user).values({ id: uuidv7(), name: 'A', email: `a-${uuidv7()}@example.com`, role: 'admin' }).returning()
    const [b] = await db.insert(user).values({ id: uuidv7(), name: 'B', email: `b-${uuidv7()}@example.com`, role: 'admin' }).returning()

    const results = await Promise.allSettled([setUserRole(a.id, a.id, 'member', db), setUserRole(a.id, b.id, 'member', db)])
    expect(results.filter((r) => r.status === 'fulfilled')).toHaveLength(1)

    const remaining = await db.select().from(user).where(and(eq(user.role, 'admin'), isNull(user.deactivatedAt)))
    expect(remaining.length).toBeGreaterThanOrEqual(1)

    await db.delete(user).where(inArray(user.id, [a.id, b.id]))
  })
})
```

- [ ] **Step 5: Run, verify pass**

```bash
DATABASE_URL=postgresql://team_works@localhost:5432/team_works_test npm run test:integration
```

- [ ] **Step 6: Commit**

```bash
git add src/lib/auth/signout.ts src/lib/auth/admin-mutators.ts src/app/api/auth/signout src/app/api/auth/signout-all tests/integration/revocation.test.ts
git commit -m "feat: add signout, invites, deactivation, and last-admin guard"
```

---

### Task 7: Route protection — `middleware.ts`

**Files:**
- Create: `src/middleware.ts`
- Test: `tests/unit/middleware.test.ts`

**Interfaces:**
- Consumes: `env` (Foundation A), `jose`'s `jwtVerify` directly (not `verifyAccessToken` from Task 2 — middleware runs on the Edge runtime and this plan keeps the DB-touching modules out of that bundle by not importing anything that transitively pulls in `pg`).

auth.md §6: middleware "manages experience," never authorizes — `requireUser()` (already wired into every route above) is what actually gates data access.

- [ ] **Step 1: Write the middleware**

```ts
// src/middleware.ts
import { NextResponse, type NextRequest } from 'next/server'
import { jwtVerify } from 'jose'
import { env } from '@/lib/env'

const PUBLIC_PATHS = ['/signin', '/auth/verify', '/api/auth/signin', '/api/auth/verify', '/api/auth/refresh']

const secret = new TextEncoder().encode(env.AUTH_SECRET)

export async function middleware(req: NextRequest) {
  const { pathname } = req.nextUrl

  if (PUBLIC_PATHS.some((p) => pathname === p || pathname.startsWith(p + '/'))) {
    return NextResponse.next()
  }

  const access = req.cookies.get('tw_access')?.value
  if (access) {
    try {
      await jwtVerify(access, secret)
      return NextResponse.next()
    } catch {
      // fall through
    }
  }

  const refreshCookie = req.cookies.get('tw_refresh')?.value
  if (refreshCookie) {
    const url = req.nextUrl.clone()
    url.pathname = '/api/auth/refresh'
    url.searchParams.set('next', pathname)
    return NextResponse.rewrite(url)
  }

  const signinUrl = req.nextUrl.clone()
  signinUrl.pathname = '/signin'
  return NextResponse.redirect(signinUrl)
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
}
```

- [ ] **Step 2: Write the failing tests**

auth.md §12 "Boundaries" (the bypass-header and `Origin`/`next` cases are covered by Tasks 2–3's unit tests; this covers middleware's own three branches).

```ts
// tests/unit/middleware.test.ts
import { describe, it, expect } from 'vitest'
import { NextRequest } from 'next/server'
import { middleware } from '@/middleware'
import { signAccessToken } from '@/lib/auth/jwt'

describe('middleware (auth.md §6, §12)', () => {
  it('lets a request with a valid access cookie through', async () => {
    const token = await signAccessToken({ sub: 'user-1', role: 'member' })
    const req = new NextRequest('http://localhost/dashboard', { headers: { cookie: `tw_access=${token}` } })
    const res = await middleware(req)
    expect(res.headers.get('x-middleware-next')).toBeTruthy()
  })

  it('rewrites to the refresh hop when only a refresh cookie is present', async () => {
    const req = new NextRequest('http://localhost/dashboard', { headers: { cookie: 'tw_refresh=some-raw-token' } })
    const res = await middleware(req)
    const rewriteUrl = res.headers.get('x-middleware-rewrite')
    expect(rewriteUrl).toContain('/api/auth/refresh')
    expect(rewriteUrl).toContain('next=%2Fdashboard')
  })

  it('redirects to /signin with neither cookie', async () => {
    const req = new NextRequest('http://localhost/dashboard')
    const res = await middleware(req)
    expect(res.headers.get('location')).toContain('/signin')
  })

  it('redirects to /signin when the access cookie is garbage and there is no refresh cookie', async () => {
    const req = new NextRequest('http://localhost/dashboard', { headers: { cookie: 'tw_access=not-a-jwt' } })
    const res = await middleware(req)
    expect(res.headers.get('location')).toContain('/signin')
  })

  it('lets a public path through with no credentials at all', async () => {
    const req = new NextRequest('http://localhost/signin')
    const res = await middleware(req)
    expect(res.headers.get('location')).toBeNull()
  })
})
```

- [ ] **Step 3: Run, verify pass**

```bash
npm run test:unit
```

`NextRequest`/`NextResponse` header names for `next()`/`rewrite()` (`x-middleware-next`, `x-middleware-rewrite`) are internal to the Next.js test/runtime shim — confirm they match the installed `next` version's behavior when this test is first run; if the assertion needs adjusting, the *behavior* being tested (pass-through vs. rewrite vs. redirect) does not change, only how the test observes it.

- [ ] **Step 4: Commit**

```bash
git add src/middleware.ts tests/unit/middleware.test.ts
git commit -m "feat: add route-protection middleware"
```

---

### Task 8: Boot-failure test and `auth:purge`

**Files:**
- Create: `tests/fixtures/boot-check.ts`, `tests/integration/boot-failure.test.ts`, `scripts/auth-purge.ts`
- Modify: `package.json` (scripts)

**Interfaces:**
- Consumes: `env.ts` (Foundation A), `loginToken`/`session` schema (Plan B).

- [ ] **Step 1: A minimal fixture that imports the env module**

```ts
// tests/fixtures/boot-check.ts
import '../../src/lib/env'
console.log('booted ok')
```

- [ ] **Step 2: Write the boot-failure test**

testing.md §3: "Auth.md §12's 'boot fails with a missing or short `AUTH_SECRET`' test exercises process startup, not a query — it spawns the app as a subprocess with a bad environment and asserts it exits, outside the transaction harness entirely."

```ts
// tests/integration/boot-failure.test.ts
import { describe, it, expect } from 'vitest'
import { spawnSync } from 'node:child_process'

function run(env: Record<string, string | undefined>) {
  return spawnSync('npx', ['tsx', 'tests/fixtures/boot-check.ts'], { env: { ...process.env, ...env }, encoding: 'utf-8' })
}

describe('boot fails on an invalid AUTH_SECRET (auth.md §10, §12)', () => {
  it('exits non-zero when AUTH_SECRET is missing', () => {
    const result = run({ AUTH_SECRET: '' })
    expect(result.status).not.toBe(0)
  })

  it('exits non-zero when AUTH_SECRET is shorter than 32 bytes', () => {
    const result = run({ AUTH_SECRET: 'short', ZERO_AUTH_SECRET: 'short' })
    expect(result.status).not.toBe(0)
  })

  it('exits 0 with a valid environment', () => {
    const valid = {
      DATABASE_URL: 'postgresql://team_works@localhost:5432/team_works_test',
      ATTACHMENTS_DIR: '/tmp/team-works-test-attachments',
      AUTH_SECRET: 'a'.repeat(32),
      ZERO_AUTH_SECRET: 'a'.repeat(32),
      APP_URL: 'http://localhost:3000',
      SMTP_HOST: 'localhost',
      SMTP_PORT: '1025',
      SMTP_SECURE: 'false',
      SMTP_USER: 'test',
      SMTP_PASS: 'test',
      SMTP_FROM: 'Team Works <test@localhost>',
    }
    const result = run(valid)
    expect(result.status).toBe(0)
    expect(result.stdout).toContain('booted ok')
  })
})
```

- [ ] **Step 3: Run, verify pass**

```bash
npm run test:integration
```

- [ ] **Step 4: `auth:purge`**

auth.md §11.

```ts
// scripts/auth-purge.ts
import { lt } from 'drizzle-orm'
import { db } from '../src/lib/db/client'
import { loginToken, session } from '../src/lib/db/schema'

async function main() {
  const now = new Date()
  const tokens = await db.delete(loginToken).where(lt(loginToken.expiresAt, now)).returning({ id: loginToken.id })
  const sessions = await db.delete(session).where(lt(session.expiresAt, now)).returning({ id: session.id })
  console.log(`Purged ${tokens.length} login_token rows and ${sessions.length} session rows.`)
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err)
    process.exit(1)
  })
```

```json
"auth:purge": "tsx scripts/auth-purge.ts"
```

deployment.md, when written, wires this to a daily systemd timer (auth.md §11) — out of scope here.

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/boot-check.ts tests/integration/boot-failure.test.ts scripts/auth-purge.ts package.json
git commit -m "test: add boot-failure test; add auth:purge script"
```

---

## Self-Review

**Spec coverage.** auth.md §1 (obligations table) → spread across Tasks 2–7, each cell in a task. §2 (three tokens, one secret) → Task 2. §3 (tables) → Plan B, consumed here. §4.1 (inviting) → Task 6. §4.2 (sign-in request) → Task 4. §4.3 (redemption, the two-step split) → Task 4. §4.4 (refresh, rotation race) → Task 5. §4.5 (sign-out) → Task 6. §4.6 (bootstrap) → Plan B Task 6 (`admin:grant`), not duplicated here. §5 (sync connection contract) → Task 2's `requireUser` accepting both carriers; the Zero-side `auth` callback itself is Plan D's. §6 (`requireUser`/`loadActor`, middleware) → Task 2, Task 7. §7 (cookies, CSRF) → Task 3. §8 (deactivation, last admin) → Task 6. §9 (throttling) → Task 4. §10 (env contract, mail) → Foundation A (`env.ts`), Task 3 (`mail.ts`). §11 (purging) → Task 8. §12 (testing) → distributed across every task's test step; cross-checked line by line above.

**Placeholder scan.** No TODOs. `inviteUser`'s stop-short note (Task 6, Step 2) names exactly what's deferred (the email-sending half) and why (no admin console page exists yet to call it) rather than leaving a vague gap.

**Type consistency.** `Actor` is defined once, in `src/lib/permissions.ts` (Task 1), and `loadActor` (Task 2) returns that exact type rather than redeclaring it. `Db`/`Tx` come from `src/lib/db/client.ts` (Plan B) everywhere. Every service function's `handle` parameter is `Db | Tx = db`, applied uniformly from Task 2 onward — checked against each task above.

**Cross-plan dependency note.** Plan D's Zero client `auth` callback (auth.md §5's code sample) calls `POST /api/auth/refresh` — built in Task 5 here. Plan D does not need to re-implement or re-test refresh; it only needs this route running.

---

**Plan complete and saved to `docs/superpowers/plans/2026-07-31-foundation-c-auth.md`.**
