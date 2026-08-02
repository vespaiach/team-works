# GitHub CI: verify code on push

**Date:** 2026-08-02
**Status:** Approved

## Purpose

Add a GitHub Actions workflow that automatically verifies code on every push and pull request, so lint and build failures are caught before merge. No CI currently exists in this repo.

## Design

**New file:** `.github/workflows/ci.yml`

- Single `verify` job, `ubuntu-latest`.
- Triggers: `push` (all branches) and `pull_request` (targeting `main`).
- Steps:
  1. `actions/checkout@v4`
  2. `actions/setup-node@v4` — Node 20, npm cache enabled
  3. `npm ci`
  4. `npm run lint` (existing `biome check`, read-only)
  5. `npm run build`

Node 20 is chosen because `@types/node` is pinned to `^20` and the repo has no `.nvmrc`.

**`package.json` change:** add a `"check": "biome check --write"` script, matching the command AGENTS.md already documents (`npm run check`) but which doesn't currently exist in `package.json`.

**Why CI uses `lint`, not `check`, for verification:** `biome check --write` auto-fixes issues in place and exits 0 once fixes are applied. In an ephemeral CI checkout, that means a push with unformatted/lint-violating code would get silently "fixed" and the job would pass — defeating the purpose of a verify-on-push gate. `npm run lint` (`biome check`, no `--write`) is read-only and fails the job when it finds issues, which is what CI verification requires. `check` remains a local, developer-facing convenience command only.

## Out of scope

- No test step: AGENTS.md notes no test runner exists yet (Vitest + Playwright are planned as part of build step 1). A test step can be added to this workflow once that lands.
- No matrix builds, no deployment step, no caching beyond npm's built-in setup-node cache.

## Testing

Verify the workflow is syntactically valid and, once pushed, actually runs and passes on GitHub Actions for this branch.
