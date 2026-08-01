# Team Works — testing

_Testing spec for v1. Companion to [permissions.md](./permissions.md), [data-model.md](./data-model.md), [auth.md](./auth.md), [local-dev.md](./local-dev.md), [notifications.md](./notifications.md) and [attachments.md](./attachments.md). Status: approved 2026-07-31._

Five of those documents already carry their own "Testing" section, written before this one existed, each ending in the same sentence: *"Beyond the predicate and mutator tests permissions.md §10 [and others] already specify."* Those sections stay — they are the authority on **what** to test for their domain — but none of them fix the runner, the database strategy, or which tier a given test belongs to. This document is that missing layer, and it answers the three questions [HANDOFF.md](./HANDOFF.md) left open for it: mutator unit tests, permission predicate tests, sync-scope tests, and whether E2E runs against a real `zero-cache`.

There is no test runner in the repo yet — [CLAUDE.md](../CLAUDE.md) says so plainly. Everything below is a decision to be applied in build step 1, alongside the schema, Zero and auth work those other documents already assign there.

---

## 1. The shape of it

Three tiers, widest at the bottom:

| Tier | Runs against | Covers | Roughly |
| --- | --- | --- | --- |
| **Unit** | nothing — pure functions, in memory | `src/lib/permissions.ts` (permissions.md §10) | the largest number of cases, sub-millisecond each |
| **Integration** | a real Postgres (`team_works_test`), no `zero-cache` | mutators, invariants, sync-scope/publication checks, auth token storage and rotation, notification and attachment logic | the bulk of the suite |
| **E2E** | the full stack — Next.js, real Postgres, real `zero-cache`, Mailpit | sign-in, live cross-client sync, the two remaining build-step-1 verifications that need a running `zero-cache` | a handful of scenarios |

Nothing here is mocked out of laziness. Postgres is real in tier 2 because half of what auth.md §12 and data-model.md §8 ask for — "assert no column contains the raw value," "assert the delete succeeds and all three issues are gone" — is a claim about what the database actually does, and a mock of Drizzle would just be re-asserting the mock's own behavior. `zero-cache` is real only in tier 3, and only for the handful of things nothing else can prove (§8).

---

## 2. Tooling

- **Vitest**, for tiers 1 and 2. It runs TypeScript and ESM natively with no transform config, which matters here because the codebase has none of Jest's usual reasons to exist (no `create-react-app`, no legacy babel setup) — and its `describe`/`it`/`expect` surface is close enough to Jest's that nothing in this document is tool-specific beyond this section.
- **Playwright**, for tier 3. The one property that matters is multi-context: two independent browser contexts, signed in as two different users, in the same test — that's what lets §8's live-sync scenario exist at all. It also has first-class Next.js support and a trace viewer, which a Docker-and-browser-dependent suite will need when it's flaky.
- **No component-testing library** (React Testing Library or similar) in v1. The two views are thin renderers over already-tested queries and predicates (§4, §5); the integration risk that matters is the one E2E covers. This is a deliberate omission, not an oversight — revisit if a screen grows real client-side logic of its own.

---

## 3. The test database, and how tests stay isolated

A second local database, `team_works_test`, created the same way as `team_works_dev` (local-dev.md §2) and kept current with the same migration files (`npm run db:migrate` against it) — never `drizzle-kit push`, here either, so the migration history exercised in tests is the one that ships.

**Isolation: one transaction per test, always rolled back.** Each test opens a transaction, runs the mutator or query under test inside it, makes its assertions, and the harness rolls the transaction back regardless of outcome. No row a test writes is ever committed, so:

- tests can run in any order, and in parallel worker processes, against the same live database, with no truncation step and no sequence reset between them;
- the only remaining collision risk is a unique constraint hit *within* a single transaction (two tests never see each other's writes), which fixture factories avoid by generating randomized-but-valid values (a random project `key`, a random email local-part) rather than fixed literals.

```ts
// tests/db.ts
export async function withTx<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
  let result: T
  await db.transaction(async (tx) => {
    result = await fn(tx)
    tx.rollback() // Drizzle aborts the transaction; the throw is caught internally
  }).catch((e) => { if (!isRollback(e)) throw e })
  return result!
}
```

**This constrains mutator design.** For a test to inject its own transaction, a mutator must accept its `db` handle as a parameter rather than importing a module-level singleton — production passes the real pool, tests pass `tx`. Nothing in permissions.md or data-model.md fixes this yet because the mutator modules don't exist; this document is where the constraint is first written down, ahead of that code being written.

**One exception.** Auth.md §12's "boot fails with a missing or short `AUTH_SECRET`" test exercises process startup, not a query — it spawns the app as a subprocess with a bad environment and asserts it exits, outside the transaction harness entirely.

---

## 4. Predicate tests (unit tier)

`src/lib/permissions.ts` is pure — no I/O, no framework imports (permissions.md §8) — so it is table-driven: one case per cell of the permissions matrix (permissions.md §3), admin / member / non-member × every action. This is the largest block of tests in the suite and the cheapest, and permissions.md §10 already names it as such; nothing here adds to that list, only fixes that it runs in tier 1, with no database and no setup beyond constructing an `Actor` and a `Membership` set by hand.

---

## 5. Mutator and invariant tests (integration tier)

For every mutator named in permissions.md §5 — fifteen `isAdmin`-only, seven plain `isMember`, three `isMember` + authorship, two self-only — one allowed case and one denied case, asserting the denial happens **inside the mutator**, not just in the client-side predicate (permissions.md §10). The three mutators with an extra precondition (`deleteProject`, `updateProject`, `createIssue`/`updateIssue`'s nesting check, per permissions.md §5) get a further case each for that precondition, independent of the role check.

Beyond authorization:

- **`updated_at` advances.** For every mutator that updates a row: read `updated_at`, invoke the mutator, assert it advanced. Data-model.md §1 calls this test out by name as "not optional," since a missed `touched()` call fails silently otherwise.
- **The eight invariants** (data-model.md §9) — one test each, attempting the violation directly through the mutator that should refuse it.
- **The removal test** (permissions.md §7) — remove a member from a project with an issue assigned to them; assert the issue is unchanged, stays visible, and is no longer editable by them.
- **The state-machine non-cascades** (state-machines.md §3) — closing a parent issue, canceling a project: each is a claim that *nothing else* happens, which is exactly the kind of fact a future change can violate by accident with no test to catch it. One test per claim: close a parent, assert its sub-issue's status is untouched; cancel a project, assert its issues and milestones keep their prior status.
- **The composite-FK cascade verification** (data-model.md §8), promoted from a one-off check to a permanent regression test: create a project with a parent issue and two sub-issues, cancel it, delete it, assert the delete succeeds and all three issues are gone. If it fails, data-model.md §8 already names the fallback (drop the composite FK, enforce same-project parentage in the mutators instead) — that branch gets its own test rewritten to match, and this one is deleted rather than left red.

All of this runs against `team_works_test`, through the transaction harness in §3, using small factory functions (`tests/factories.ts`) that build one valid row per entity with randomized unique fields — not the `db:seed` fixture set, which is for a human developer's local database, not per-test isolation.

---

## 6. Sync-scope tests (integration tier — no `zero-cache` needed)

Three checks, all answerable from Postgres and the Zero schema's source alone, no live sync round trip required:

- **Publication membership.** Query `pg_publication_tables` and `pg_publication_columns` for `zero_data`; assert exactly the ten tables in data-model.md §3 and, for `user`, exactly the six listed columns. Assert `invite`, `login_token`, `session` and `issue_counter` are absent — auth.md §12 already specifies this for the three auth tables; this generalizes it to the whole publication.
- **Schema parity.** The Zero client schema is a separate declaration from the Drizzle schema and "a mismatch surfaces as a sync error rather than a type error" (data-model.md §11) — so diff the two declarations directly (table names, column names) and fail the build before that mismatch ever reaches a browser.
- **The notification read rule**, exercised as what it actually is: a plain function. Import it and call it against fixture rows and two different `auth.userId` values, asserting each caller gets only their own notifications. No `zero-cache` process needed to test a function.

---

## 7. Auth, notification and attachment tests (integration tier)

Already fully specified where they live — auth.md §12, notifications.md §8, attachments.md §7 — and nothing here repeats those lists. All of it runs in the integration tier, through the same `team_works_test` database and transaction harness as §5, with one adjustment: attachment tests point `ATTACHMENTS_DIR` at a fresh temp directory per test run (not the developer's `.data/attachments`), removed afterward, so upload and reclamation tests never touch a real dev workspace's files.

---

## 8. End-to-end tests: yes, against a real `zero-cache` — narrowly

This is HANDOFF's third open question, and the answer is yes, but for a small, named set of scenarios rather than as the default way anything gets tested.

**Why it has to be real here.** Every tier above exercises Postgres or a plain function — never `zero-cache` itself. The actual risk in a Zero app is the seam between what the schema and read rules declare and what the pinned `zero-cache` package really does with them, and that seam is invisible to a mock. Two of the three build-step-1 verifications the other documents already flagged live exactly there and can only be settled by running the real thing.

**A separate database.** E2E runs against `team_works_e2e`, not `team_works_test` — §3's rollback-per-test strategy would leave `zero-cache` nothing to replicate, since it reads committed WAL, and no E2E row is ever meant to be rolled back. Each E2E run drops and recreates `team_works_e2e`, migrates it, and seeds it with the same small fixture shape local-dev.md §7 describes (an admin, a member, two projects) so scenarios have real users to sign in as.

**A separate stack.** Postgres, `zero-cache` and Mailpit for E2E come up via a dedicated `docker-compose.e2e.yml` — the same shape as local-dev.md §4's dev compose file, pointed at `team_works_e2e`, its own replica volume, and its own ports — so an E2E run never collides with a developer's already-running dev stack or drops a stray message in their dev inbox.

**Scenarios:**

1. **Sign-in.** Request a link, poll Mailpit's message API for the address under test, extract the magic-link URL, redeem it, land authenticated. No human reads a UI here, unlike local-dev.md §7's manual flow.
2. **Live cross-client sync.** Two Playwright browser contexts, signed in as the seeded admin and member. One drags a board card to a new column; assert the second context's board updates with no reload — the test that actually proves the optimistic-then-authoritative round trip, and the two-phase cascade settle (data-model.md §4), work as designed rather than just as described.
3. **Denial round-trips visibly.** A non-member's optimistic write is rejected server-side; assert the client's local store rebases back to its pre-write state and a toast names why (permissions.md §9).
4. **Date mapping** (data-model.md §11). Create an issue with a `due_date`, read it back through the client, and assert whichever shape the pinned Zero version actually produces. Once run once and confirmed, this becomes a permanent regression test on whichever branch won — the one thing standing between a future `zero-cache` upgrade and the fallback silently reverting.
5. **Auth callback re-invocation** (auth.md §5). Force an access token to expire mid-session and assert the client recovers without a manual reload. If Zero does not re-invoke `auth` on rejection, auth.md §5's fallback (a client-owned refresh timer) is what this test asserts instead — same test, whichever branch is true.

**Deliberately not covered here:** screen layout, form validation, and the disabled-control states ui-spec.md defines. Those are numerous, mostly deterministic given already-tested mutators and predicates, and belong to ui-spec.md's own scope if it ever needs one — E2E stays reserved for what only a live stack can prove.

---

## 9. CI

Two stages, not one, given the cost difference:

- **Fast** — a Postgres service container, `db:migrate` against `team_works_test`, then `npm run test:unit` and `npm run test:integration`. Runs on every push.
- **Slow** — additionally brings up `zero-cache` and Mailpit (via `docker-compose.e2e.yml`, §8) and runs `npm run test:e2e`. Runs on merge to `main`, given the Docker-and-browser overhead; not on every push.

[deployment.md](./deployment.md), when written, owns the actual CI provider config. This section only fixes the shape it should take.

---

## 10. Out of scope for v1

- **Load and data-volume testing.** [non-functional.md](./non-functional.md), when written, owns perf budgets and is where this belongs.
- **Visual regression testing.** No tool for it in the stack; deferred.
- **A cross-browser or cross-device matrix** beyond Playwright's default Chromium config. Browser support policy is non-functional.md's, not this document's.
- **Coverage-percentage gates or mutation testing.** Coverage is a signal a developer can look at, not a merge gate, for a team this size.
- **Component-level UI unit tests**, per §2.

---

## 11. Changes this spec requires elsewhere

### Applied 2026-07-31, the documents now agree

- **CLAUDE.md** — the Commands section's "There is no test runner configured yet" now points to this document and names the two tools and the four scripts; the planned-architecture dependency note gains `vitest` and `@playwright/test`. (Not added to the curated doc list in "Project state" — that list already omits local-dev.md, ui-spec.md, notifications.md, attachments.md and state-machines.md, so this document follows the same precedent rather than becoming the exception.)
- **local-dev.md §2** — gains the `team_works_test` database, created alongside `team_works_dev`. **§5** gains the second `db:migrate` run against it and the one-time `npx playwright install`.
- **permissions.md §10, data-model.md §1/§8/§11, auth.md §12, notifications.md §8, attachments.md §7, state-machines.md §3** — each already specifies what to test (or, for state-machines.md, a claim worth testing); each now points to this document for the runner, the database strategy, and which tier its tests run in.
- **README.md** — doc list and the Development section both gain a pointer to this document.
- **HANDOFF.md** — item 11 struck.

### Not yet applied

- **package.json** (build step 1, joining the dependency lists data-model.md §12 and auth.md §12 already started) — `devDependencies` gain `vitest` and `@playwright/test`; `scripts` gain `test`, `test:unit`, `test:integration`, `test:e2e`. The scaffold is untouched, per CLAUDE.md, so this cannot be applied until build step 1.

---

_Decisions here are settled. Revise deliberately, and reconcile permissions.md, data-model.md, auth.md, notifications.md and attachments.md in the same change._
