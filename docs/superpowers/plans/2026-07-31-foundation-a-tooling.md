# Foundation A: Repo & Tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the untouched scaffolder output into a working toolchain — real dependencies, a validated environment contract, and a configured Vitest + Playwright test runner — so Plans B (schema), C (auth) and D (Zero + permissions + shell) have something to build on.

**Architecture:** No application/domain logic in this plan. It only touches `package.json`, config files, and the two scaffold files `data-model.md` §12 marks for deletion. It ends with `npm run lint`, `npm run test:unit`, and `docker compose up -d` all succeeding, and `.env.local` populated from a rewritten `.env.example`.

**Tech Stack:** Next.js 14 (existing), TypeScript strict (existing), Vitest, `@playwright/test`, `tsx` (for running `.ts` scripts), Drizzle Kit (config only — no schema in this plan), Docker.

## Global Constraints

- `@/*` maps to `./src/*` (tsconfig, already set).
- Node.js 20.x LTS, pinned via `.nvmrc` (local-dev.md §1).
- PostgreSQL 15+ required later by Plan B — not installed by this plan, but its native (non-Docker) install is a prerequisite documented here (local-dev.md §1–2).
- Never add `next-auth` (CLAUDE.md, auth.md §14).
- `AUTH_SECRET` must be ≥ 32 bytes; boot must fail if missing or short (auth.md §10). This plan builds the pure validator; Plan C wires the subprocess boot-failure test (auth.md §12) once the secret is actually used to sign something.
- Tables/columns are `snake_case`, singular (data-model.md §1) — relevant starting in Plan B, noted here so schema code in later plans doesn't drift.
- Commit messages: conventional-ish, lowercase (`docs: add permissions spec` style, per CLAUDE.md).

---

## File Structure

```
.nvmrc                          # new — Node version pin
.env.example                    # rewritten — real contract, no placeholder SECRET_KEY
docker-compose.yml              # new — zero-cache only (Postgres/Mailpit are native, not Docker)
drizzle.config.ts               # new — stub pointing at a schema path Plan B will create
vitest.config.ts                # new
playwright.config.ts            # new
package.json                    # modified — deps + scripts
src/lib/env.ts                  # new — pure env-contract parser
tests/unit/env.test.ts          # new
tests/unit/smoke.test.ts        # new — proves the runner is wired
src/lib/db.ts                   # deleted (scaffold cruft, data-model.md §12)
src/types/index.ts               # deleted (scaffold cruft, data-model.md §12)
```

---

### Task 1: Install the planned dependencies

**Files:**
- Modify: `package.json`

**Interfaces:**
- Produces: every package later tasks and later plans import — `drizzle-orm`, `pg`, `@rocicorp/zero`, `uuidv7`, `fractional-indexing`, `react-aria-components`, `@dnd-kit/core`, `frappe-gantt`, `jose`, `nodemailer`, `drizzle-kit`, `vitest`, `@playwright/test`, `tsx`.

- [ ] **Step 1: Install production dependencies**

```bash
npm install drizzle-orm pg @rocicorp/zero uuidv7 fractional-indexing react-aria-components @dnd-kit/core frappe-gantt jose nodemailer
```

- [ ] **Step 2: Install dev dependencies**

```bash
npm install -D drizzle-kit vitest @playwright/test tsx @types/pg @types/nodemailer
```

- [ ] **Step 3: Record resolved versions**

The docs deliberately leave exact versions unpinned pending this step (local-dev.md §4 flags this explicitly for `zero-cache`; the same uncertainty applies to `@rocicorp/zero`'s client package). Run:

```bash
npm ls @rocicorp/zero drizzle-orm drizzle-kit frappe-gantt --depth=0
```

Paste the resolved versions into a short note at the top of this plan file's Task 1 (edit this file) so Plan D's zero-cache image-tag task and the `date`-mapping verification know which version they're actually testing against.

- [ ] **Step 4: Verify nothing else broke**

```bash
npm run lint
```

Expected: passes — no source files reference the new packages yet.

- [ ] **Step 5: Commit**

```bash
git add package.json package-lock.json
git commit -m "chore: install planned dependencies"
```

---

### Task 2: Delete scaffold cruft, add `.nvmrc`, rewrite `.env.example`

**Files:**
- Delete: `src/lib/db.ts`, `src/types/index.ts`
- Create: `.nvmrc`
- Modify: `.env.example`

**Interfaces:**
- Produces: `.env.example` — the shape every later `.env.local` (local-dev.md §3) and the `env.ts` parser in Task 3 are built against. Eleven variables, all required: `DATABASE_URL`, `ATTACHMENTS_DIR`, `AUTH_SECRET`, `ZERO_AUTH_SECRET`, `APP_URL`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `SMTP_USER`, `SMTP_PASS`, `SMTP_FROM`.

- [ ] **Step 1: Delete the scaffold files**

```bash
git rm src/lib/db.ts src/types/index.ts
```

data-model.md §12: "`src/lib/db.ts` and `src/types/index.ts` are generator output... Both should be deleted rather than adapted." Nothing in `src/` imports them yet (the scaffold's `page.tsx`/components don't reference `db` or the placeholder `User` type) — confirm with:

```bash
grep -rn "lib/db\|types/index" src/app src/components
```

Expected: no matches. If there are matches, remove those imports first (they'd be scaffold-only usage, e.g. an unused import).

- [ ] **Step 2: Add `.nvmrc`**

```
20
```

- [ ] **Step 3: Rewrite `.env.example`**

```bash
DATABASE_URL=
ATTACHMENTS_DIR=
AUTH_SECRET=
ZERO_AUTH_SECRET=
APP_URL=
SMTP_HOST=
SMTP_PORT=
SMTP_SECURE=
SMTP_USER=
SMTP_PASS=
SMTP_FROM=
```

Write this as the actual file content (via the file-editing tool, not the bash heredoc above — the heredoc above is illustrative of the eleven names only). No comments needed beyond what auth.md §10 and local-dev.md §3 already document; this file is the contract, not the explanation. The placeholder `SECRET_KEY` line is gone, not renamed (data-model.md §12, auth.md §14 both require this explicitly).

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: delete scaffold cruft, rewrite env contract"
```

---

### Task 3: Environment contract module (pure parser + boot-time load)

**Files:**
- Create: `src/lib/env.ts`
- Test: `tests/unit/env.test.ts`

**Interfaces:**
- Produces: `parseEnv(raw: Record<string, string | undefined>): Env` — pure, throws `Error` with a message naming the missing/invalid field. `export const env: Env = parseEnv(process.env)` — the eagerly-evaluated singleton every later module (`db/client.ts` in Plan B, `auth/jwt.ts` in Plan C, `zero/client.ts` in Plan D) imports instead of touching `process.env` directly.
- Consumes: nothing (first module in the dependency graph).

```ts
export type Env = {
  DATABASE_URL: string
  ATTACHMENTS_DIR: string
  AUTH_SECRET: string
  ZERO_AUTH_SECRET: string
  APP_URL: string
  SMTP_HOST: string
  SMTP_PORT: number
  SMTP_SECURE: boolean
  SMTP_USER: string
  SMTP_PASS: string
  SMTP_FROM: string
}
```

- [ ] **Step 1: Write the failing tests**

```ts
// tests/unit/env.test.ts
import { describe, it, expect } from 'vitest'
import { parseEnv } from '@/lib/env'

const valid = {
  DATABASE_URL: 'postgresql://team_works@localhost:5432/team_works_dev',
  ATTACHMENTS_DIR: '/tmp/attachments',
  AUTH_SECRET: 'a'.repeat(32),
  ZERO_AUTH_SECRET: 'a'.repeat(32),
  APP_URL: 'http://localhost:3000',
  SMTP_HOST: 'localhost',
  SMTP_PORT: '1025',
  SMTP_SECURE: 'false',
  SMTP_USER: 'x',
  SMTP_PASS: 'x',
  SMTP_FROM: 'Team Works <dev@localhost>',
}

describe('parseEnv', () => {
  it('returns a typed Env on valid input', () => {
    const env = parseEnv(valid)
    expect(env.SMTP_PORT).toBe(1025)
    expect(env.SMTP_SECURE).toBe(false)
  })

  it('throws when a required var is missing', () => {
    const { DATABASE_URL, ...rest } = valid
    expect(() => parseEnv(rest)).toThrow(/DATABASE_URL/)
  })

  it('throws when AUTH_SECRET is shorter than 32 bytes', () => {
    expect(() => parseEnv({ ...valid, AUTH_SECRET: 'short' })).toThrow(/AUTH_SECRET/)
  })

  it('throws when ZERO_AUTH_SECRET does not match AUTH_SECRET', () => {
    expect(() => parseEnv({ ...valid, ZERO_AUTH_SECRET: 'b'.repeat(32) })).toThrow(/ZERO_AUTH_SECRET/)
  })

  it('throws when SMTP_PORT is not numeric', () => {
    expect(() => parseEnv({ ...valid, SMTP_PORT: 'not-a-number' })).toThrow(/SMTP_PORT/)
  })
})
```

- [ ] **Step 2: Run the tests, verify they fail**

```bash
npx vitest run tests/unit/env.test.ts
```

Expected: FAIL — `Cannot find module '@/lib/env'`.

- [ ] **Step 3: Implement `src/lib/env.ts`**

```ts
export type Env = {
  DATABASE_URL: string
  ATTACHMENTS_DIR: string
  AUTH_SECRET: string
  ZERO_AUTH_SECRET: string
  APP_URL: string
  SMTP_HOST: string
  SMTP_PORT: number
  SMTP_SECURE: boolean
  SMTP_USER: string
  SMTP_PASS: string
  SMTP_FROM: string
}

const REQUIRED = [
  'DATABASE_URL',
  'ATTACHMENTS_DIR',
  'AUTH_SECRET',
  'ZERO_AUTH_SECRET',
  'APP_URL',
  'SMTP_HOST',
  'SMTP_PORT',
  'SMTP_SECURE',
  'SMTP_USER',
  'SMTP_PASS',
  'SMTP_FROM',
] as const

export function parseEnv(raw: Record<string, string | undefined>): Env {
  for (const key of REQUIRED) {
    if (!raw[key]) throw new Error(`Missing required environment variable: ${key}`)
  }

  if (raw.AUTH_SECRET!.length < 32) {
    throw new Error('AUTH_SECRET must be at least 32 bytes')
  }

  if (raw.ZERO_AUTH_SECRET !== raw.AUTH_SECRET) {
    throw new Error('ZERO_AUTH_SECRET must equal AUTH_SECRET — one secret, two names (auth.md §2)')
  }

  const port = Number(raw.SMTP_PORT)
  if (!Number.isInteger(port)) {
    throw new Error('SMTP_PORT must be an integer')
  }

  if (raw.SMTP_SECURE !== 'true' && raw.SMTP_SECURE !== 'false') {
    throw new Error("SMTP_SECURE must be 'true' or 'false'")
  }

  return {
    DATABASE_URL: raw.DATABASE_URL!,
    ATTACHMENTS_DIR: raw.ATTACHMENTS_DIR!,
    AUTH_SECRET: raw.AUTH_SECRET!,
    ZERO_AUTH_SECRET: raw.ZERO_AUTH_SECRET!,
    APP_URL: raw.APP_URL!,
    SMTP_HOST: raw.SMTP_HOST!,
    SMTP_PORT: port,
    SMTP_SECURE: raw.SMTP_SECURE === 'true',
    SMTP_USER: raw.SMTP_USER!,
    SMTP_PASS: raw.SMTP_PASS!,
    SMTP_FROM: raw.SMTP_FROM!,
  }
}

export const env: Env = parseEnv(process.env)
```

- [ ] **Step 4: Run the tests, verify they pass**

```bash
npx vitest run tests/unit/env.test.ts
```

Expected: PASS, all five cases.

Note: importing this file at module load time in a Vitest run will execute `parseEnv(process.env)` against the *real* `process.env` of the test process (not the `valid` fixture) — Vitest's test process needs a minimally-valid `.env.test` or equivalent loaded, or the `export const env` line will throw on import and fail every test in the file. Add a `tests/setup.ts` that stubs `process.env` with the `valid` shape before any import, and wire it into `vitest.config.ts` in Task 4 (`test.setupFiles`). Simplest concrete setup:

```ts
// tests/setup.ts
process.env.DATABASE_URL ??= 'postgresql://team_works@localhost:5432/team_works_test'
process.env.ATTACHMENTS_DIR ??= '/tmp/team-works-test-attachments'
process.env.AUTH_SECRET ??= 'a'.repeat(32)
process.env.ZERO_AUTH_SECRET ??= process.env.AUTH_SECRET
process.env.APP_URL ??= 'http://localhost:3000'
process.env.SMTP_HOST ??= 'localhost'
process.env.SMTP_PORT ??= '1025'
process.env.SMTP_SECURE ??= 'false'
process.env.SMTP_USER ??= 'test'
process.env.SMTP_PASS ??= 'test'
process.env.SMTP_FROM ??= 'Team Works <test@localhost>'
```

- [ ] **Step 5: Commit**

```bash
git add src/lib/env.ts tests/unit/env.test.ts tests/setup.ts
git commit -m "feat: add environment contract parser"
```

---

### Task 4: Vitest configuration

**Files:**
- Create: `vitest.config.ts`
- Create: `tests/unit/smoke.test.ts`
- Modify: `package.json` (scripts)

**Interfaces:**
- Consumes: `tests/setup.ts` (Task 3, Step 4).
- Produces: `npm run test:unit`, `npm run test:integration` — the two commands every later plan's tests run under. Plan B introduces `tests/integration/**` and a real `DATABASE_URL=team_works_test` requirement for that script; this task only wires the split, it does not need a database yet.

- [ ] **Step 1: Write `vitest.config.ts`**

```ts
import { defineConfig } from 'vitest/config'
import path from 'node:path'

export default defineConfig({
  test: {
    environment: 'node',
    setupFiles: ['./tests/setup.ts'],
    globals: false,
  },
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
})
```

- [ ] **Step 2: Add npm scripts**

In `package.json` `"scripts"`:

```json
"test": "npm run test:unit && npm run test:integration",
"test:unit": "vitest run tests/unit",
"test:integration": "vitest run tests/integration"
```

(`tests/integration` does not exist yet — Plan B creates it. `vitest run` on a nonexistent directory exits non-zero with "no tests found," which is expected and fine until Plan B lands; do not add a workaround for it.)

- [ ] **Step 3: Write a smoke test**

```ts
// tests/unit/smoke.test.ts
import { describe, it, expect } from 'vitest'
import { env } from '@/lib/env'

describe('toolchain smoke test', () => {
  it('resolves the @ alias and loads env', () => {
    expect(env.APP_URL).toBe('http://localhost:3000')
  })
})
```

- [ ] **Step 4: Run it, verify it passes**

```bash
npm run test:unit
```

Expected: PASS (env.test.ts and smoke.test.ts both green).

- [ ] **Step 5: Commit**

```bash
git add vitest.config.ts tests/unit/smoke.test.ts package.json
git commit -m "chore: configure vitest"
```

---

### Task 5: Playwright configuration

**Files:**
- Create: `playwright.config.ts`
- Modify: `package.json` (scripts)

**Interfaces:**
- Produces: `npm run test:e2e`. No E2E tests exist until Plan D — this task only proves the config is valid and the browser binary is installed, per local-dev.md §5 ("One additional one-time step for the E2E layer: `npx playwright install`").

- [ ] **Step 1: Write `playwright.config.ts`**

testing.md §2: "No cross-browser or cross-device matrix beyond Playwright's default Chromium config" (§10, out of scope for v1).

```ts
import { defineConfig } from '@playwright/test'

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: false,
  use: {
    baseURL: process.env.APP_URL ?? 'http://localhost:3000',
    trace: 'retain-on-failure',
  },
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }],
})
```

`fullyParallel: false` because testing.md §8's E2E scenarios include a two-context live-sync test against one shared `team_works_e2e` database seeded fresh per run (§8) — parallel test files would race on that shared fixture data. This is a judgment call inside what the docs leave open; revisit if the E2E suite grows large enough that serial execution becomes the bottleneck.

- [ ] **Step 2: Add the npm script**

```json
"test:e2e": "playwright test"
```

- [ ] **Step 3: Install the browser binary**

```bash
npx playwright install chromium
```

- [ ] **Step 4: Verify the config is valid**

```bash
npx playwright test --list
```

Expected: exits 0, reports "Total: 0 tests in 0 files" (or equivalent) — proves the config parses and the browser is installed, with no fabricated test needed to check that.

- [ ] **Step 5: Commit**

```bash
git add playwright.config.ts package.json
git commit -m "chore: configure playwright"
```

---

### Task 6: `zero-cache` Docker Compose + native Postgres checklist

**Files:**
- Create: `docker-compose.yml`

**Interfaces:**
- Produces: the `zero-cache` container Plan D's Zero client connects to. Depends on `ZERO_AUTH_SECRET` (Task 3) and, once running, on Postgres actually existing with `wal_level=logical` and the schema/publication from Plan B — so `docker compose up -d` in this task will start successfully but `zero-cache` will not do anything useful until Plan B's publication exists. That's expected; this task only proves the compose file and image are correct.

- [ ] **Step 1: Write `docker-compose.yml`**

Exactly per local-dev.md §4:

```yaml
services:
  zero-cache:
    image: rocicorp/zero-cache
    ports:
      - "4848:4848"
    environment:
      ZERO_UPSTREAM_DB: postgresql://team_works@host.docker.internal:5432/team_works_dev
      ZERO_REPLICA_FILE: /data/zero-replica.sqlite
      ZERO_AUTH_SECRET: ${ZERO_AUTH_SECRET}
      ZERO_PORT: "4848"
    volumes:
      - zero-replica:/data
volumes:
  zero-replica:
```

- [ ] **Step 2: Native Postgres checklist (manual — not automatable from this repo)**

This is environment setup on the developer's machine, not code; record it as a checklist rather than a fabricated test:

- [ ] `brew install postgresql@15` (macOS) or `sudo apt install postgresql-15` (Linux), service started
- [ ] `createuser -s team_works`
- [ ] `createdb -O team_works team_works_dev`
- [ ] `createdb -O team_works team_works_test` (testing.md §3 — Plan B's integration tests need this)
- [ ] `wal_level = logical` set in `postgresql.conf`, Postgres restarted, confirmed with `SHOW wal_level;` → `logical`

- [ ] **Step 3: Verify the compose file is syntactically valid and pulls**

```bash
docker compose config
docker compose up -d
docker compose ps
```

Expected: `zero-cache` shows as running. It will likely log connection errors until Postgres has the `team_works_dev` database reachable at that connection string and (later) the publication — that's expected at this point in the plan. Confirm the container itself starts rather than crash-looping on a config error:

```bash
docker compose logs zero-cache --tail 20
```

- [ ] **Step 4: Tear down (leave it stopped until Plan B's schema exists)**

```bash
docker compose down
```

- [ ] **Step 5: Commit**

```bash
git add docker-compose.yml
git commit -m "chore: add zero-cache docker compose"
```

---

## Self-Review

**Spec coverage.** local-dev.md §1 (prerequisites, `.nvmrc`) → Task 2/6. §2 (native Postgres) → Task 6. §3 (env contract) → Task 2/3. §4 (`zero-cache` compose) → Task 6. auth.md §10 (env contract, boot validation) → Task 3. data-model.md §12 scaffold cleanup → Task 2. testing.md §2 (Vitest + Playwright) → Task 4/5. concept-brief dependency list → Task 1.

**Placeholder scan.** No TODOs; every step has real code or a real command. The one deliberately-manual item (Task 6 Step 2, native Postgres install) is manual because it's a machine-level prerequisite the repo cannot script safely, not a deferred implementation detail — it's called out as such rather than disguised as an automated step.

**Type consistency.** `Env` type defined once in Task 3, imported by name (`env`) in Task 4's smoke test; no other plan file redefines it — Plans B/C/D import `{ env } from '@/lib/env'`.

---

**Plan complete and saved to `docs/superpowers/plans/2026-07-31-foundation-a-tooling.md`.**
