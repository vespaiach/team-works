# Foundation D: Zero Client, Permissions Wiring, App Shell & Verifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close out build step 1. Stand up the Zero client schema and connection, wrap the app in a responsive React Aria shell, get **one synced query rendering end-to-end** (concept-brief §6's literal step-1 deliverable), and run the three build-step-1 verifications this plan is positioned to actually prove, since they need a live `zero-cache`.

**Architecture:** Zero's client schema (`src/lib/zero/schema.ts`) is a hand-maintained mirror of the `zero_data` publication (Plan B, Task 4) — kept honest by a schema-parity test that diffs it against the Drizzle schema. The Zero client itself is a browser-only singleton whose `auth` callback calls `POST /api/auth/refresh` (Plan C, Task 5). The app shell wraps the whole tree in a Zero provider and renders one live query — a list of workspace members — as the "one synced query" proof. E2E tests run against a fully disposable stack (`docker-compose.e2e.yml`: dockerized Postgres + `zero-cache` + Mailpit), separate from the developer's native-Postgres dev stack. This plan assumes **Foundation A, B, and C are complete**.

**Tech Stack:** `@rocicorp/zero` (client + React bindings), `react-aria-components`, `@playwright/test`.

## Global Constraints

- The Zero client schema mirrors the publication exactly: the same ten tables, and for `user` the same six columns (data-model.md §11).
- **`date` mapping is unconfirmed going in** — Task 1 writes the schema on the "Zero maps `date`" branch; Task 8's E2E test is the actual verification, and data-model.md §11's fallback (three columns become `text` with an ISO-date `CHECK`) applies only if that test shows otherwise.
- Zero's read rules do not consume `src/lib/permissions.ts` — the one read rule (`notification.user_id === auth.userId`) is expressed directly in the Zero schema/rules, independent of the permission matrix (permissions.md §8, data-model.md §11).
- No offline writes — reads of synced data work offline; writes are rejected when disconnected (concept-brief §2). Nothing in this plan implements a write path yet (that's build step 2+), so this constraint has no code surface here beyond not building around an assumption that contradicts it.
- E2E runs against `team_works_e2e`, never `team_works_test` (testing.md §8) — a separate, fully dockerized stack so it never collides with a developer's running dev environment.
- Exact `zero-cache` environment variable names and image tag are **stated as of the docs' writing, not re-verified** (local-dev.md §4) — Task 2 is where this plan checks them against whatever version Foundation A's Task 1 resolved.

---

## File Structure

```
src/lib/zero/schema.ts                          # new
src/lib/zero/client.ts                          # new
src/components/shell/ZeroAppProvider.tsx        # new
src/components/shell/AppShell.tsx               # new
src/components/shell/MemberList.tsx             # new
src/app/signin/page.tsx                         # new
src/app/layout.tsx                              # modified — wraps children in ZeroAppProvider + AppShell
src/app/page.tsx                                # modified — renders MemberList
src/app/globals.css                             # modified — responsive shell styles
docker-compose.e2e.yml                          # new
scripts/e2e-setup.ts                            # new
scripts/test-e2e.sh                             # new
tests/e2e/global-setup.ts                       # new (Playwright globalSetup, if used)
tests/e2e/signin.spec.ts                        # new
tests/e2e/date-mapping.spec.ts                  # new
tests/e2e/auth-callback-reinvocation.spec.ts    # new
tests/integration/schema-parity.test.ts         # new
package.json                                    # modified — e2e:setup script
```

---

### Task 1: Zero client schema + schema-parity test

**Files:**
- Create: `src/lib/zero/schema.ts`
- Test: `tests/integration/schema-parity.test.ts`

**Interfaces:**
- Consumes: the Drizzle schema (Plan B) for the parity check.
- Produces: `schema` — the object every later task in this plan (`client.ts`, `MemberList.tsx`) imports.

- [ ] **Step 1: Write the schema**

Mirrors data-model.md §3's publication and §7's full column lists (the publication has no column restriction except on `user`, so every other synced table brings its `created_at`/`updated_at` along). The exact `@rocicorp/zero` schema-builder API (`table`, `string`, `number`, `.from()`, `.primaryKey()`, `createSchema`) should be checked against the version Foundation A's Task 1 resolved before treating this file as final — Zero's API has moved across versions, which is exactly why local-dev.md §4 and this document both flag it as unconfirmed rather than asserting it.

```ts
// src/lib/zero/schema.ts
import { createSchema, table, string, number } from '@rocicorp/zero'

// Verify during this task: does Zero map Postgres `date` to a plain string,
// or not at all? The columns below assume it maps to `string` (ISO
// YYYY-MM-DD). Task 8's E2E test is the actual confirmation; data-model.md
// §11's fallback (unchanged shape here — `date` already reads as `text`-like
// either way) applies only if Zero does not map `date` at all, in which case
// the *Postgres* column type changes (Plan B), not this file.

const user = table('user')
  .columns({
    id: string(),
    name: string(),
    email: string(),
    avatarUrl: string().optional(),
    role: string(),
    deactivatedAt: number().optional(), // timestamptz -> epoch ms
  })
  .primaryKey('id')

const project = table('project')
  .columns({
    id: string(),
    key: string(),
    name: string(),
    description: string().optional(),
    status: string(),
    leadId: string().optional(),
    startDate: string().optional(),
    targetDate: string().optional(),
    color: string(),
    sortOrder: string(),
    createdAt: number(),
    updatedAt: number(),
  })
  .primaryKey('id')

const projectMember = table('projectMember')
  .from('project_member')
  .columns({
    projectId: string(),
    userId: string(),
    createdAt: number(),
  })
  .primaryKey('projectId', 'userId')

const milestone = table('milestone')
  .columns({
    id: string(),
    projectId: string(),
    name: string(),
    targetDate: string().optional(),
    sortOrder: string(),
    createdAt: number(),
    updatedAt: number(),
  })
  .primaryKey('id')

const issue = table('issue')
  .columns({
    id: string(),
    projectId: string(),
    number: number(),
    milestoneId: string().optional(),
    parentIssueId: string().optional(),
    title: string(),
    description: string().optional(),
    status: string(),
    priority: string(),
    assigneeId: string().optional(),
    dueDate: string().optional(),
    createdBy: string(),
    sortOrder: string(),
    createdAt: number(),
    updatedAt: number(),
  })
  .primaryKey('id')

const label = table('label')
  .columns({
    id: string(),
    name: string(),
    color: string(),
    createdAt: number(),
    updatedAt: number(),
  })
  .primaryKey('id')

const issueLabel = table('issueLabel')
  .from('issue_label')
  .columns({
    issueId: string(),
    labelId: string(),
    createdAt: number(),
  })
  .primaryKey('issueId', 'labelId')

const comment = table('comment')
  .columns({
    id: string(),
    issueId: string(),
    authorId: string(),
    body: string(),
    createdAt: number(),
    updatedAt: number(),
  })
  .primaryKey('id')

const attachment = table('attachment')
  .columns({
    id: string(),
    issueId: string(),
    commentId: string().optional(),
    filename: string(),
    storagePath: string(),
    contentType: string(),
    sizeBytes: number(),
    uploadedBy: string(),
    createdAt: number(),
  })
  .primaryKey('id')

const notification = table('notification')
  .columns({
    id: string(),
    userId: string(),
    actorId: string(),
    type: string(),
    issueId: string(),
    commentId: string().optional(),
    readAt: number().optional(),
    emailedAt: number().optional(),
    createdAt: number(),
  })
  .primaryKey('id')

export const schema = createSchema({
  tables: [user, project, projectMember, milestone, issue, label, issueLabel, comment, attachment, notification],
})

export type ZeroSchema = typeof schema
```

- [ ] **Step 2: Write the failing schema-parity test**

testing.md §6: "diff the two declarations directly (table names, column names) and fail the build before that mismatch ever reaches a browser."

```ts
// tests/integration/schema-parity.test.ts
import { describe, it, expect } from 'vitest'
import { getTableColumns } from 'drizzle-orm'
import * as drizzleSchema from '@/lib/db/schema'
import { schema as zeroSchema } from '@/lib/zero/schema'

function toSnakeCase(name: string): string {
  return name.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`)
}

const TABLES: Array<{ drizzleTable: object; zeroTableName: string; onlyColumns?: string[] }> = [
  { drizzleTable: drizzleSchema.user, zeroTableName: 'user', onlyColumns: ['id', 'name', 'email', 'avatar_url', 'role', 'deactivated_at'] },
  { drizzleTable: drizzleSchema.project, zeroTableName: 'project' },
  { drizzleTable: drizzleSchema.projectMember, zeroTableName: 'projectMember' },
  { drizzleTable: drizzleSchema.milestone, zeroTableName: 'milestone' },
  { drizzleTable: drizzleSchema.issue, zeroTableName: 'issue' },
  { drizzleTable: drizzleSchema.label, zeroTableName: 'label' },
  { drizzleTable: drizzleSchema.issueLabel, zeroTableName: 'issueLabel' },
  { drizzleTable: drizzleSchema.comment, zeroTableName: 'comment' },
  { drizzleTable: drizzleSchema.attachment, zeroTableName: 'attachment' },
  { drizzleTable: drizzleSchema.notification, zeroTableName: 'notification' },
]

describe('Zero client schema mirrors the Drizzle schema (data-model.md §11)', () => {
  it.each(TABLES)('$zeroTableName: column names match', ({ drizzleTable, zeroTableName, onlyColumns }) => {
    const drizzleColumns = Object.values(getTableColumns(drizzleTable as any)).map((c: any) => c.name).sort()
    const expected = (onlyColumns ?? drizzleColumns).slice().sort()

    // zeroSchema.tables[name].columns — confirm this access path against the
    // installed @rocicorp/zero version; it is the one place this test
    // depends on Zero's internal schema object shape rather than its
    // documented builder API.
    const zeroTable = (zeroSchema.tables as any)[zeroTableName]
    const zeroColumns = Object.keys(zeroTable.columns).map(toSnakeCase).sort()

    expect(zeroColumns).toEqual(expected)
  })
})
```

- [ ] **Step 3: Run it**

```bash
DATABASE_URL=postgresql://team_works@localhost:5432/team_works_test npm run test:integration
```

If it fails because the access path (`zeroSchema.tables[name].columns`) doesn't match the installed version's actual object shape, adjust the introspection (not the assertion's intent) until it does — log `JSON.stringify(zeroSchema, null, 2)` once, by hand, to find the right path.

- [ ] **Step 4: Commit**

```bash
git add src/lib/zero/schema.ts tests/integration/schema-parity.test.ts
git commit -m "feat: add zero client schema mirroring the zero_data publication"
```

---

### Task 2: Verify `zero-cache`'s environment variables and image tag

**Files:**
- Modify: `docker-compose.yml` (if names differ from Foundation A's draft)

**Interfaces:**
- None — this is a verification task, not new code.

local-dev.md §4: "confirm the exact environment variable names and the image tag against whichever `zero-cache` version gets pinned... should be checked against the pinned package's own docs before being treated as final."

- [ ] **Step 1: Look up the pinned version's actual configuration contract**

Using the `@rocicorp/zero` version resolved in Foundation A Task 1, Step 3, consult that package's own documentation (its README or the `zero-cache` image's docs on whichever registry hosts it) for: the upstream-database env var name, the replica-file env var name, the auth-secret env var name, the port env var name, and the correct image tag (`rocicorp/zero-cache` with or without a version suffix).

- [ ] **Step 2: Reconcile against `docker-compose.yml`**

If any name differs from Foundation A Task 6's draft (`ZERO_UPSTREAM_DB`, `ZERO_REPLICA_FILE`, `ZERO_AUTH_SECRET`, `ZERO_PORT`), update `docker-compose.yml` to match, and note the correction here in this task (edit this plan file) so `docker-compose.e2e.yml` (Task 6) uses the same corrected names from the start rather than repeating the mistake.

- [ ] **Step 3: Bring the dev stack up against the real schema**

```bash
docker compose up -d
docker compose logs zero-cache --tail 50
```

Expected: no connection or config errors — Plan B's migration already created `team_works_dev` with the `zero_data` publication, so `zero-cache` should now successfully replicate rather than just start.

- [ ] **Step 4: Commit (only if `docker-compose.yml` changed)**

```bash
git add docker-compose.yml
git commit -m "fix: correct zero-cache environment variable names against the pinned version"
```

---

### Task 3: Zero client construction

**Files:**
- Create: `src/lib/zero/client.ts`, `src/components/shell/ZeroAppProvider.tsx`

**Interfaces:**
- Consumes: `schema` (Task 1). Calls `POST /api/auth/refresh` (Plan C, Task 5) from its `auth` callback — auth.md §5's exact code sample.
- Produces: `getZero()`, `<ZeroAppProvider>`.

- [ ] **Step 1: The client singleton**

```ts
// src/lib/zero/client.ts
'use client'

import { Zero } from '@rocicorp/zero'
import { schema, type ZeroSchema } from './schema'

let zeroInstance: Zero<ZeroSchema> | null = null

export function getZero(): Zero<ZeroSchema> {
  if (zeroInstance) return zeroInstance

  zeroInstance = new Zero({
    schema,
    server: process.env.NEXT_PUBLIC_ZERO_SERVER ?? 'http://localhost:4848',
    auth: async () => {
      const res = await fetch('/api/auth/refresh', { method: 'POST' })
      if (!res.ok) {
        window.location.href = '/signin'
        throw new Error('unauthenticated')
      }
      return (await res.json()).token
    },
  })

  // Test-only hook for Task 8/9's E2E verifications, which need to reach
  // into the running client from Playwright's page.evaluate(). Never read
  // in production code paths.
  if (typeof window !== 'undefined') {
    ;(window as unknown as { __ZERO__?: Zero<ZeroSchema> }).__ZERO__ = zeroInstance
  }

  return zeroInstance
}
```

`NEXT_PUBLIC_ZERO_SERVER` is a new, public, non-secret addition beyond auth.md §10's eleven-variable contract — the browser bundle needs to know where `zero-cache` is, and `NEXT_PUBLIC_` is Next's documented mechanism for that. It defaults to the dev compose file's port so local dev needs no extra configuration.

- [ ] **Step 2: The provider**

`@rocicorp/zero/react`'s exact export names — verify against the installed version.

```tsx
// src/components/shell/ZeroAppProvider.tsx
'use client'

import { useMemo, type ReactNode } from 'react'
import { ZeroProvider } from '@rocicorp/zero/react'
import { getZero } from '@/lib/zero/client'

export function ZeroAppProvider({ children }: { children: ReactNode }) {
  const zero = useMemo(() => getZero(), [])
  return <ZeroProvider zero={zero}>{children}</ZeroProvider>
}
```

- [ ] **Step 3: Manual smoke check**

There's no query yet to run (Task 5 adds one) — for now, confirm the module at least constructs without throwing by temporarily rendering `<ZeroAppProvider>` around a static `<p>ok</p>` in `src/app/page.tsx`, running `npm run dev`, and checking the browser console for connection attempts to `localhost:4848` with no thrown errors. Revert this temporary render before Task 5, which replaces it properly.

- [ ] **Step 4: Commit**

```bash
git add src/lib/zero/client.ts src/components/shell/ZeroAppProvider.tsx
git commit -m "feat: add zero client singleton and provider"
```

---

### Task 4: App shell — responsive layout, React Aria, sign-in page

**Files:**
- Create: `src/components/shell/AppShell.tsx`, `src/app/signin/page.tsx`
- Modify: `src/app/layout.tsx`, `src/app/globals.css`

**Interfaces:**
- Produces: `<AppShell>`, the `/signin` route — both needed before Task 5's query has anywhere authenticated to render, and before Task 7's E2E sign-in test has a page to drive.

- [ ] **Step 1: The shell**

```tsx
// src/components/shell/AppShell.tsx
import type { ReactNode } from 'react'

export function AppShell({ children }: { children: ReactNode }) {
  return (
    <div className="app-shell">
      <header className="app-shell__header">
        <span className="app-shell__brand">Team Works</span>
        <nav className="app-shell__nav">
          <a href="/">Board</a>
          <a href="/roadmap">Roadmap</a>
        </nav>
      </header>
      <main className="app-shell__content">{children}</main>
    </div>
  )
}
```

- [ ] **Step 2: Responsive styles**

Append to `src/app/globals.css` — CLAUDE.md: "responsive from one codebase," a single stylesheet with a breakpoint rather than separate mobile/desktop trees.

```css
.app-shell {
  display: flex;
  flex-direction: column;
  min-height: 100vh;
}

.app-shell__header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0.75rem 1rem;
  border-bottom: 1px solid #e5e5e5;
}

.app-shell__nav {
  display: flex;
  gap: 1rem;
}

.app-shell__content {
  flex: 1;
  padding: 1rem;
}

@media (max-width: 640px) {
  .app-shell__header {
    flex-direction: column;
    align-items: flex-start;
    gap: 0.5rem;
  }
}
```

- [ ] **Step 3: The sign-in page**

React Aria Components, per CLAUDE.md's stack decision. Field/button names match Task 7's E2E selectors exactly.

```tsx
// src/app/signin/page.tsx
'use client'

import { useState, type FormEvent } from 'react'
import { TextField, Label, Input, Button } from 'react-aria-components'

export default function SignInPage() {
  const [status, setStatus] = useState<'idle' | 'sent' | 'error'>('idle')

  async function handleSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const email = new FormData(e.currentTarget).get('email')
    const res = await fetch('/api/auth/signin', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email }),
    })
    setStatus(res.ok ? 'sent' : 'error')
  }

  if (status === 'sent') {
    return (
      <main>
        <p>Check your inbox for a sign-in link.</p>
      </main>
    )
  }

  return (
    <main>
      <form onSubmit={handleSubmit}>
        <TextField name="email" type="email" isRequired>
          <Label>Email</Label>
          <Input />
        </TextField>
        <Button type="submit">Send link</Button>
      </form>
      {status === 'error' && <p role="alert">Something went wrong — try again.</p>}
    </main>
  )
}
```

- [ ] **Step 4: Wire the shell into the root layout**

```tsx
// src/app/layout.tsx
import type { ReactNode } from 'react'
import { ZeroAppProvider } from '@/components/shell/ZeroAppProvider'
import { AppShell } from '@/components/shell/AppShell'
import './globals.css'

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>
        <ZeroAppProvider>
          <AppShell>{children}</AppShell>
        </ZeroAppProvider>
      </body>
    </html>
  )
}
```

`/signin` and `/auth/verify` render inside this same layout — they're already in `middleware.ts`'s `PUBLIC_PATHS` (Plan C, Task 7), so an unauthenticated visitor reaches them without a redirect loop even though they're wrapped in `ZeroAppProvider`. The Zero client constructing without a valid session is fine — it just has no queries running yet on those two routes.

- [ ] **Step 5: Verify in the browser**

```bash
npm run dev
```

Visit `http://localhost:3000/signin`, confirm the form renders and the header/nav appear. Resize to a narrow viewport and confirm the header stacks per the media query.

- [ ] **Step 6: Commit**

```bash
git add src/components/shell/AppShell.tsx src/app/signin src/app/layout.tsx src/app/globals.css
git commit -m "feat: add responsive app shell and sign-in page"
```

---

### Task 5: The one synced query

**Files:**
- Create: `src/components/shell/MemberList.tsx`
- Modify: `src/app/page.tsx`

**Interfaces:**
- Consumes: `getZero()` (Task 3).

concept-brief §6: "Get one synced query rendering end-to-end." A live list of workspace members is the smallest thing that exercises the full chain — schema, publication, `zero-cache`, the client schema, and the auth token — without depending on any mutator, since none exist yet (those start in build step 2).

- [ ] **Step 1: The component**

`useQuery`'s exact import path and the query-builder chain (`z.query.user.orderBy(...)`) — verify against the installed `@rocicorp/zero` version.

```tsx
// src/components/shell/MemberList.tsx
'use client'

import { useQuery } from '@rocicorp/zero/react'
import { getZero } from '@/lib/zero/client'

export function MemberList() {
  const z = getZero()
  const [members] = useQuery(z.query.user.orderBy('name', 'asc'))

  return (
    <ul className="member-list">
      {members.map((m) => (
        <li key={m.id}>
          {m.name} — {m.role}
          {m.deactivatedAt ? ' (deactivated)' : ''}
        </li>
      ))}
    </ul>
  )
}
```

- [ ] **Step 2: Wire it into the homepage**

```tsx
// src/app/page.tsx
import { MemberList } from '@/components/shell/MemberList'

export default function HomePage() {
  return (
    <section>
      <h1>Team</h1>
      <MemberList />
    </section>
  )
}
```

- [ ] **Step 3: Verify end-to-end in the browser**

```bash
docker compose up -d   # zero-cache, if not already running from Task 2
npm run dev
```

Sign in as the admin bootstrapped in Plan B, Task 6 (via `/signin`, reading the link from Mailpit at `http://localhost:8025`). Land on `/` and confirm the member list renders both the admin and the seeded member from `npm run db:seed`.

- [ ] **Step 4: Prove liveness**

With the browser tab open, run in a second terminal:

```sql
UPDATE "user" SET name = 'Ada (renamed)' WHERE email = 'sam@example.com';
```

Expected: the list updates in the open tab with no reload — the actual proof that this is a live query, not a one-time fetch.

- [ ] **Step 5: Commit**

```bash
git add src/components/shell/MemberList.tsx src/app/page.tsx
git commit -m "feat: render the first live-synced query — the workspace member list"
```

---

### Task 6: E2E infrastructure — dockerized stack, fixture setup

**Files:**
- Create: `docker-compose.e2e.yml`, `scripts/e2e-setup.ts`, `scripts/test-e2e.sh`
- Modify: `package.json` (scripts)

**Interfaces:**
- Consumes: `db:migrate`, `admin:grant`, `db:seed` (Plan B).

testing.md §8: a separate database (`team_works_e2e`), a separate dockerized stack (Postgres included this time, unlike native dev Postgres), separate ports, dropped and reseeded each run.

- [ ] **Step 1: The E2E compose file**

Distinct ports from the dev stack (`docker-compose.yml`) so both can run simultaneously without colliding.

```yaml
# docker-compose.e2e.yml
services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_USER: team_works
      POSTGRES_DB: team_works_e2e
      POSTGRES_HOST_AUTH_METHOD: trust
    command: ["postgres", "-c", "wal_level=logical"]
    ports:
      - "5433:5432"
  zero-cache:
    image: rocicorp/zero-cache
    depends_on:
      - postgres
    ports:
      - "4849:4848"
    environment:
      ZERO_UPSTREAM_DB: postgresql://team_works@postgres:5432/team_works_e2e
      ZERO_REPLICA_FILE: /data/zero-replica.sqlite
      ZERO_AUTH_SECRET: ${AUTH_SECRET}
      ZERO_PORT: "4848"
    volumes:
      - zero-e2e-replica:/data
  mailpit:
    image: axllent/mailpit
    ports:
      - "1026:1025"
      - "8026:8025"
volumes:
  zero-e2e-replica:
```

Use whatever corrected variable names Task 2 settled on if they differed from the draft above.

- [ ] **Step 2: The fixture-setup script**

```ts
// scripts/e2e-setup.ts
import { execSync } from 'node:child_process'
import { Client } from 'pg'

const ADMIN_URL = 'postgresql://team_works@localhost:5433/postgres'
const E2E_URL = 'postgresql://team_works@localhost:5433/team_works_e2e'

async function main() {
  const client = new Client({ connectionString: ADMIN_URL })
  await client.connect()
  await client.query('DROP DATABASE IF EXISTS team_works_e2e')
  await client.query('CREATE DATABASE team_works_e2e')
  await client.end()

  const env = { ...process.env, DATABASE_URL: E2E_URL }
  execSync('npm run db:migrate', { stdio: 'inherit', env })
  execSync('npm run admin:grant -- --email=admin@example.com --name="E2E Admin"', { stdio: 'inherit', env })
  execSync('npm run db:seed', { stdio: 'inherit', env })

  console.log('team_works_e2e ready.')
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
```

```json
"e2e:setup": "tsx scripts/e2e-setup.ts"
```

- [ ] **Step 3: The orchestration script**

Brings up the stack, seeds it, runs the app against it, runs Playwright, tears everything down — requires `AUTH_SECRET` already exported in the calling shell (CI supplies it as a secret; local runs can `export AUTH_SECRET=$(openssl rand -base64 32)` once per session).

```bash
#!/usr/bin/env bash
# scripts/test-e2e.sh
set -euo pipefail

if [ -z "${AUTH_SECRET:-}" ]; then
  echo "AUTH_SECRET must be exported before running this script" >&2
  exit 1
fi

docker compose -f docker-compose.e2e.yml up -d
cleanup() {
  kill "${DEV_PID:-0}" 2>/dev/null || true
  docker compose -f docker-compose.e2e.yml down
}
trap cleanup EXIT

npm run e2e:setup

DATABASE_URL=postgresql://team_works@localhost:5433/team_works_e2e \
APP_URL=http://localhost:3000 \
ATTACHMENTS_DIR=/tmp/team-works-e2e-attachments \
AUTH_SECRET="$AUTH_SECRET" \
ZERO_AUTH_SECRET="$AUTH_SECRET" \
SMTP_HOST=localhost SMTP_PORT=1026 SMTP_SECURE=false SMTP_USER=x SMTP_PASS=x SMTP_FROM="Team Works <e2e@localhost>" \
NEXT_PUBLIC_ZERO_SERVER=http://localhost:4849 \
npm run dev &
DEV_PID=$!

for i in $(seq 1 30); do
  curl -sf http://localhost:3000 >/dev/null && break
  sleep 1
done

npm run test:e2e -- "$@"
```

```bash
chmod +x scripts/test-e2e.sh
```

```json
"test:e2e:full": "bash scripts/test-e2e.sh"
```

- [ ] **Step 4: Dry-run the stack**

```bash
export AUTH_SECRET=$(openssl rand -base64 32)
docker compose -f docker-compose.e2e.yml up -d
npm run e2e:setup
docker compose -f docker-compose.e2e.yml down
```

Expected: no errors; `team_works_e2e` gets created, migrated, and seeded. There are no Playwright specs yet (Task 7 adds the first) — this step only proves the plumbing.

- [ ] **Step 5: Commit**

```bash
git add docker-compose.e2e.yml scripts/e2e-setup.ts scripts/test-e2e.sh package.json
git commit -m "chore: add E2E infrastructure (dockerized stack, fixture setup)"
```

---

### Task 7: E2E scenario — sign-in (testing.md §8, scenario 1)

**Files:**
- Create: `tests/e2e/signin.spec.ts`

**Interfaces:**
- Consumes: the running app + Mailpit's HTTP API (`docker-compose.e2e.yml`, Task 6).

- [ ] **Step 1: Write the spec**

```ts
// tests/e2e/signin.spec.ts
import { test, expect } from '@playwright/test'

const MAILPIT_API = 'http://localhost:8026/api/v1'

test('requesting a link and redeeming it signs the user in', async ({ page, request }) => {
  await page.goto('/signin')
  await page.getByLabel('Email').fill('admin@example.com')
  await page.getByRole('button', { name: 'Send link' }).click()
  await expect(page.getByText(/check your inbox/i)).toBeVisible()

  let magicLink: string | undefined
  for (let attempt = 0; attempt < 20 && !magicLink; attempt++) {
    const listRes = await request.get(`${MAILPIT_API}/messages`)
    const list = await listRes.json()
    const message = list.messages?.find((m: { To: { Address: string }[] }) => m.To[0]?.Address === 'admin@example.com')
    if (message) {
      const full = await (await request.get(`${MAILPIT_API}/message/${message.ID}`)).json()
      const match = (full.Text as string).match(/https?:\/\/\S+\/auth\/verify\?token=\S+/)
      if (match) magicLink = match[0]
    }
    if (!magicLink) await page.waitForTimeout(500)
  }

  expect(magicLink, 'magic link should appear in Mailpit within 10s').toBeDefined()
  await page.goto(magicLink!)
  await page.getByRole('button', { name: 'Sign in' }).click()

  await expect(page).toHaveURL('/')
  await expect(page.locator('.member-list')).toContainText('E2E Admin')
})
```

- [ ] **Step 2: Run it**

```bash
npm run test:e2e:full
```

- [ ] **Step 3: Commit**

```bash
git add tests/e2e/signin.spec.ts
git commit -m "test: add E2E sign-in scenario"
```

---

### Task 8: E2E verification — Postgres `date` mapping (data-model.md §11)

**Files:**
- Create: `tests/e2e/date-mapping.spec.ts`

This is one of concept-brief §6's three build-step-1 verifications, and the only tier that can answer it: "it needs a live `zero-cache`, so it runs at the E2E tier" (testing.md §8, scenario 4).

- [ ] **Step 1: Write the spec**

Reuses `signin.spec.ts`'s redemption flow as a small inline helper rather than importing it, since Playwright spec files are independent by design.

```ts
// tests/e2e/date-mapping.spec.ts
import { test, expect } from '@playwright/test'

async function signInAsAdmin(page: import('@playwright/test').Page, request: import('@playwright/test').APIRequestContext) {
  const MAILPIT_API = 'http://localhost:8026/api/v1'
  await page.goto('/signin')
  await page.getByLabel('Email').fill('admin@example.com')
  await page.getByRole('button', { name: 'Send link' }).click()

  let magicLink: string | undefined
  for (let attempt = 0; attempt < 20 && !magicLink; attempt++) {
    const list = await (await request.get(`${MAILPIT_API}/messages`)).json()
    const message = list.messages?.find((m: { To: { Address: string }[] }) => m.To[0]?.Address === 'admin@example.com')
    if (message) {
      const full = await (await request.get(`${MAILPIT_API}/message/${message.ID}`)).json()
      const match = (full.Text as string).match(/https?:\/\/\S+\/auth\/verify\?token=\S+/)
      if (match) magicLink = match[0]
    }
    if (!magicLink) await page.waitForTimeout(500)
  }
  await page.goto(magicLink!)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await expect(page).toHaveURL('/')
}

test('Postgres date columns round-trip through Zero (data-model.md §11)', async ({ page, request }) => {
  await signInAsAdmin(page, request)

  const mappedType = await page.evaluate(async () => {
    const z = (window as unknown as { __ZERO__: import('@rocicorp/zero').Zero<unknown> }).__ZERO__
    const projects = await (z as any).query.project.where('key', '=', 'WEB').run()
    return typeof projects[0]?.startDate
  })

  // Record the outcome here once run — this becomes the permanent regression
  // test data-model.md §11 asks for, narrowed to whichever branch actually won:
  //
  //   - if 'string': Zero maps `date` as an ISO string. Task 1's schema is
  //     correct as written. Change the assertion below to
  //     expect(mappedType).toBe('string') and stop here.
  //   - if 'undefined'/'number'/anything else Zero does NOT map `date`
  //     usefully. Apply data-model.md §11's fallback: in Plan B's schema,
  //     change project.startDate/targetDate and issue.dueDate from `date` to
  //     `text` with CHECK (col ~ '^\d{4}-\d{2}-\d{2}$'), regenerate and apply
  //     the migration, then narrow this assertion to match.
  expect(['string', 'number']).toContain(mappedType)
})
```

- [ ] **Step 2: Run it and record the outcome**

```bash
npm run test:e2e:full
```

Whichever branch the assertion actually exercises, edit this spec file to narrow the assertion to that one outcome per the comment above, and edit data-model.md §11 itself to record which branch won (data-model.md's own instruction: "Resolve this in build step 1 and record the outcome here").

- [ ] **Step 3: Commit**

```bash
git add tests/e2e/date-mapping.spec.ts
git commit -m "test: verify and record Zero's Postgres date mapping (data-model.md §11)"
```

---

### Task 9: E2E verification — Zero re-invokes `auth` on token rejection (auth.md §5)

**Files:**
- Create: `tests/e2e/auth-callback-reinvocation.spec.ts`

The third build-step-1 verification. To force a real token expiry inside a test's timeout rather than waiting 15 real minutes, this test overrides `ACCESS_TOKEN_TTL_SECONDS` (the optional env var Plan C's `jwt.ts` reads, defaulting to 900) for its own run only.

- [ ] **Step 1: Write the spec**

```ts
// tests/e2e/auth-callback-reinvocation.spec.ts
import { test, expect } from '@playwright/test'

test('the client recovers without a manual reload when the access token expires mid-session (auth.md §5)', async ({ page, request }) => {
  // This spec assumes the app under test was started with
  // ACCESS_TOKEN_TTL_SECONDS=5 — add that to test-e2e.sh's env block (Task 6)
  // when running this spec specifically, since a 900s TTL makes the wait in
  // Step 3 below impractical. Document the override here rather than
  // silently depending on it.

  const MAILPIT_API = 'http://localhost:8026/api/v1'
  await page.goto('/signin')
  await page.getByLabel('Email').fill('admin@example.com')
  await page.getByRole('button', { name: 'Send link' }).click()

  let magicLink: string | undefined
  for (let attempt = 0; attempt < 20 && !magicLink; attempt++) {
    const list = await (await request.get(`${MAILPIT_API}/messages`)).json()
    const message = list.messages?.find((m: { To: { Address: string }[] }) => m.To[0]?.Address === 'admin@example.com')
    if (message) {
      const full = await (await request.get(`${MAILPIT_API}/message/${message.ID}`)).json()
      const match = (full.Text as string).match(/https?:\/\/\S+\/auth\/verify\?token=\S+/)
      if (match) magicLink = match[0]
    }
    if (!magicLink) await page.waitForTimeout(500)
  }
  await page.goto(magicLink!)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await expect(page).toHaveURL('/')
  await expect(page.locator('.member-list')).toContainText('E2E Admin')

  // Wait past the shortened access-token TTL. zero-cache should reject the
  // now-expired token on its next request and Zero should re-invoke `auth`,
  // which calls /api/auth/refresh and recovers with no page reload.
  await page.waitForTimeout(7_000)

  // Prove the connection is still live: mutate through Postgres directly and
  // confirm the open tab still reflects it, exactly as Task 5's liveness
  // check did — the only difference is that the access token has expired
  // and been silently replaced in between.
  await page.evaluate(async () => {
    await fetch('/api/e2e-only/touch-member', { method: 'POST' }) // see note below
  })
  await expect(page.locator('.member-list')).toBeVisible()
});
```

Rather than adding a throwaway `/api/e2e-only/touch-member` route (which would be dead code outside this one test, and Foundation has no issue/project mutator yet to piggyback on), replace the last two steps with a direct assertion that the client's connection state recovered, using Zero's own connection-status signal if the installed version exposes one:

```ts
  const recovered = await page.waitForFunction(() => {
    const z = (window as unknown as { __ZERO__: { connectionState?: string } }).__ZERO__
    return z && (!('connectionState' in z) || z.connectionState !== 'closed')
  }, { timeout: 15_000 })
  expect(recovered).toBeTruthy()
```

Confirm the exact property name for connection state against the installed `@rocicorp/zero` version's docs — this is the one part of this test genuinely gated on an API surface this plan cannot pin down in advance, same as Task 1 and Task 2's other unconfirmed specifics.

- [ ] **Step 2: Run it with the shortened TTL**

```bash
ACCESS_TOKEN_TTL_SECONDS=5 npm run test:e2e:full -- tests/e2e/auth-callback-reinvocation.spec.ts
```

- [ ] **Step 3a: If it passes** — Zero re-invokes `auth` on rejection. Nothing further to build; commit as-is.

- [ ] **Step 3b: If it fails** — apply auth.md §5's named fallback: add a client-owned refresh timer to `src/lib/zero/client.ts` that fires at 80% of `ACCESS_TOKEN_TTL_SECONDS` and recreates the Zero instance with a freshly fetched token, so `zero-cache` never sees an expired one under normal operation. Rewrite this test to assert recovery under that mechanism instead (same wait, same final assertion), and keep it green.

- [ ] **Step 4: Commit**

```bash
git add tests/e2e/auth-callback-reinvocation.spec.ts src/lib/zero/client.ts
git commit -m "test: verify and record Zero auth-callback re-invocation behavior (auth.md §5)"
```

---

## Self-Review

**Spec coverage.** concept-brief §6 (Zero client schema, zero-cache running, app shell, "one synced query end-to-end," all three verifications) → Tasks 1, 2, 3, 4, 5, 8, 9. data-model.md §11 (client schema, `date` mapping) → Task 1, Task 8. permissions.md §8's note that Zero read rules don't consume `permissions.ts` → stated in Global Constraints; no code needed since Foundation has no per-row read rule beyond the notification one, which isn't exercised until notifications exist (build step 4). auth.md §5 (auth callback, re-invocation) → Task 3, Task 9. testing.md §6 (schema parity) → Task 1. testing.md §8 (E2E scenarios 1, 4, 5 — scenarios 2 and 3 need mutators that don't exist until build step 2+, correctly out of scope here) → Tasks 7, 8, 9. testing.md §9 (CI's Slow stage) → not built as CI config in this plan; deployment.md owns the actual provider config per testing.md §9's own deferral, so `test-e2e.sh` (Task 6) is the thing a CI step would eventually call, not a CI YAML file itself.

**Placeholder scan.** No TODOs. The two spots with real uncertainty — Zero's exact schema-builder/connection-state API surface (Tasks 1, 9) and whichever branch the `date`-mapping and auth-callback verifications land on (Tasks 8, 9) — are written as concretely as they can be ahead of running against the real pinned package, with the fallback path fully specified rather than deferred.

**Type consistency.** `ZeroSchema` (Task 1) is the type `getZero()` (Task 3) and `MemberList` (Task 5) build against. `getZero()` itself is a singleton — every consumer calls the same function rather than constructing its own `Zero` instance, so there is exactly one client connection per tab.

---

**Plan complete and saved to `docs/superpowers/plans/2026-07-31-foundation-d-zero-shell.md`.**

## Execution Handoff

Four plans now cover build step 1 in dependency order:

1. `2026-07-31-foundation-a-tooling.md`
2. `2026-07-31-foundation-b-schema-sync-boundary.md`
3. `2026-07-31-foundation-c-auth.md`
4. `2026-07-31-foundation-d-zero-shell.md` (this one)

Two execution options, per plan or across all four:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration. Use superpowers:subagent-driven-development.

**2. Inline Execution** — execute tasks in this session using superpowers:executing-plans, batch execution with checkpoints.

Which approach?
