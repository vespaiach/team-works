# Team Works — local development

_Local setup spec for v1. Companion to [team-works-concept-brief.md](./team-works-concept-brief.md), [data-model.md](./data-model.md) and [auth.md](./auth.md). Status: approved 2026-07-31._

This document gets a contributor from a clean checkout to a running app: Postgres with logical replication, `zero-cache`, a local mail catcher, migrations, seed data, and a first admin to sign in as. It fills in real local values for the environment contract [auth.md](./auth.md) §10 already fixed; it does not redefine that contract.

**Postgres runs as a native install, not in Docker.** Only `zero-cache` is containerized — that mirrors the shape [team-works-concept-brief.md](./team-works-concept-brief.md) §5 already committed to for the VPS, where Postgres runs directly on the box and `zero-cache` runs in its own container. Mailpit, being dev-only, is also a native binary; Docker here is used for exactly the one piece that's containerized in production too.

---

## 1. Prerequisites

| Tool | Version | Why |
| --- | --- | --- |
| Node.js | 20.x (LTS) | pinned via `.nvmrc`; run `nvm use` on entry |
| PostgreSQL | 15+ | the floor [data-model.md](./data-model.md) §1 sets, for the publication column lists and column-scoped `ON DELETE SET NULL` |
| Docker | any recent | `zero-cache` only |
| Mailpit | latest | local SMTP catcher; `brew install mailpit` or the release binary on Linux |

Add `.nvmrc` at the repo root containing `20`.

---

## 2. Postgres (native)

1. Install: `brew install postgresql@15` (macOS) or `sudo apt install postgresql-15` (Linux), then start it as a service.
2. Create a role and two databases for the project — one for development, one for the test suite ([testing.md](./testing.md) §3):

   ```bash
   createuser -s team_works
   createdb -O team_works team_works_dev
   createdb -O team_works team_works_test
   ```

3. **Enable logical replication.** Find `postgresql.conf` (`brew` puts it under the formula's data dir; `apt` under `/etc/postgresql/15/main/`) and set:

   ```
   wal_level = logical
   ```

   Restart Postgres, then confirm:

   ```sql
   SHOW wal_level;  -- logical
   ```

   This is the same setting [team-works-concept-brief.md](./team-works-concept-brief.md) §5 requires on the VPS — nothing local-only about it.

4. Resulting connection string for step 3: `postgresql://team_works@localhost:5432/team_works_dev`.

---

## 3. Environment (`.env.local`)

Fills [auth.md](./auth.md) §10's contract with local values. Copy `.env.example` to `.env.local` and set:

| Variable | Local value | Notes |
| --- | --- | --- |
| `DATABASE_URL` | `postgresql://team_works@localhost:5432/team_works_dev` | from §2 |
| `ATTACHMENTS_DIR` | `./.data/attachments` | create it (`mkdir -p .data/attachments`) before first upload; gitignored |
| `AUTH_SECRET` | output of `openssl rand -base64 32` | ≥ 32 bytes, per auth.md §10 |
| `ZERO_AUTH_SECRET` | **the same value as `AUTH_SECRET`** | one secret, two names (auth.md §2) — do not generate a second value |
| `APP_URL` | `http://localhost:3000` | plain HTTP locally, so the `Secure` cookie flag is auto-omitted (auth.md §7) — no local-only branch needed in the cookie code |
| `SMTP_HOST` | `localhost` | Mailpit |
| `SMTP_PORT` | `1025` | Mailpit's default SMTP port |
| `SMTP_SECURE` | `false` | Mailpit doesn't speak TLS |
| `SMTP_USER` / `SMTP_PASS` | any non-empty string | Mailpit does not check credentials, but the boot-time contract validator (auth.md §10) requires the vars to be present |
| `SMTP_FROM` | `Team Works <dev@localhost>` | |

`.env.example` itself is rewritten to this shape (minus secrets) as part of build step 1 — data-model.md §12 and auth.md §14 already flag the placeholder `SECRET_KEY` for deletion.

Start Mailpit before signing in for the first time: `mailpit` (default: SMTP on `:1025`, web UI on `:8025`).

---

## 4. `zero-cache` (Docker)

A single-service `docker-compose.yml`:

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

`host.docker.internal` lets the container reach the native Postgres install on the host; on Linux this may instead need `--add-host=host.docker.internal:host-gateway` or the host's bridge IP, depending on the Docker version.

**Verify during Foundation, alongside the other three items already assigned there** (data-model.md §11, §8; auth.md §5): confirm the exact environment variable names and the image tag against whichever `zero-cache` version gets pinned. The shape above — an upstream connection string, a replica file path, the shared auth secret, and a port — is stable across recent Zero versions, but the literal variable names are not re-verified as part of this document and should be checked against the pinned package's own docs before being treated as final.

Bring it up with `docker compose up -d`, after Postgres is running and migrated (§5).

---

## 5. Migrations

`drizzle-kit generate` + a migrate script — versioned SQL files, applied explicitly, rather than `drizzle-kit push`. This gives deployment.md an actual migration history to run on the VPS, and a natural point to decide whether a given migration needs a `zero-cache` replica reset (data-model.md §11).

```bash
npm run db:generate   # drizzle-kit generate — writes a new migration file from schema changes
npm run db:migrate     # applies pending migrations to DATABASE_URL
```

Run `db:migrate` once after cloning and after every pull that touches the schema. Run it a second time against `team_works_test` (`DATABASE_URL=postgresql://team_works@localhost:5432/team_works_test npm run db:migrate`) before running the test suite for the first time and after every pull that touches the schema — [testing.md](./testing.md) §3 keeps that database on the same migration history rather than `drizzle-kit push`.

One additional one-time step for the E2E layer: `npx playwright install` downloads the browser binaries Playwright drives (testing.md §2, §8).

---

## 6. Bootstrapping the first admin

```bash
npm run admin:grant -- --email=you@example.com --name="Your Name"
```

The same script auth.md §4.6 defines for the VPS break-glass path, run locally against `DATABASE_URL` instead of over SSH. It upserts a `user` row with `role = 'admin'` and sends no email — sign in afterward through the ordinary flow (§7 below), reading the magic link from Mailpit.

---

## 7. Seed data

```bash
npm run db:seed
```

Inserts a small, realistic fixture set directly (not through the invite flow, the same way `admin:grant` bypasses it):

- one additional `user` row with `role = 'member'`, so there's a second identity to sign in as and to assign work to
- two `project` rows with distinct keys, one carrying a `milestone`
- half a dozen `issue` rows spread across statuses and priorities, split across the two projects and both users
- two `label` rows applied to a few of the issues

Both the admin (§6) and the seeded member sign in the same way: request a link at `/signin`, then open it from Mailpit's web UI at `http://localhost:8025`, since no real mail transport runs locally.

`db:seed` is safe to re-run only against a fresh database — it does not check for existing rows.

---

## 8. Running it

```bash
npm run dev
```

| Service | Address |
| --- | --- |
| App | http://localhost:3000 |
| Postgres | localhost:5432 |
| `zero-cache` | http://localhost:4848 |
| Mailpit UI | http://localhost:8025 |

Postgres and Mailpit run as always-on native processes; `zero-cache` is brought up with `docker compose up -d` and left running; `npm run dev` is the only thing restarted on every edit.

---

## 9. Changes this spec requires elsewhere

This document operationalizes decisions already settled in [auth.md](./auth.md) §10 and §4.6 and [data-model.md](./data-model.md) §1 and §11; it does not change any of them.

- `.env.example` — to be rewritten per §3 above, discharging the flag data-model.md §12 and auth.md §14 already raised against the scaffold's placeholder `SECRET_KEY`. Not yet applied — the repo scaffold itself is untouched, per [CLAUDE.md](../CLAUDE.md).
- `package.json` — needs the `admin:grant`, `db:generate`, `db:migrate` and `db:seed` scripts referenced above, in addition to the dependencies data-model.md §12 and auth.md §12 already listed. Not yet applied, for the same reason.
