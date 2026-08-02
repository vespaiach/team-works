# Team Works — deployment

_Deployment and operations runbook for v1. Companion to [team-works-concept-brief.md](./team-works-concept-brief.md), [data-model.md](./data-model.md), [auth.md](./auth.md), [attachments.md](./attachments.md) and [testing.md](./testing.md). Status: approved 2026-07-31._

_Revised 2026-08-02: §2's provisioning target changed from Ubuntu 22.04 LTS (or Debian 12) to Debian 13, per [the P0.1 design spec](./superpowers/specs/2026-08-02-vps-provisioning-deploy-pipeline-design.md)._

This document gets the app from a git repository to a running production instance on a single VPS, and covers what keeps it running afterward: provisioning, the deploy pipeline, environment and secrets, the three background timers other specs already defined, migrations and the one operation among them that needs special handling — resetting the `zero-cache` replica — and backups with a restore drill. It is a runbook, not new application code; nothing here changes the schema, the permission model, or the sync contract.

**Out of scope**, named so it doesn't read as an oversight: a monitoring/alerting stack, log aggregation, multi-region or high-availability deployment, blue-green or zero-downtime releases, and a CDN. All are disproportionate to a single team under twenty on one VPS; if usage ever outgrows that, this document is the one to revise.

---

## 1. Topology

One VPS runs everything:

| Process | Supervised by | Port |
| --- | --- | --- |
| Next.js app | systemd | 3000 (internal) |
| `zero-cache` | systemd, wrapping a Docker container | 4848 (internal) |
| PostgreSQL 15+ | systemd (the distro package's own unit), native install | 5432 (internal) |
| nginx | systemd (distro package) | 80, 443 (public) |

Only nginx is reachable from outside the box. Everything else binds to `localhost` and is reached through nginx or directly by another local process. This mirrors local-dev.md's shape exactly — native Postgres, containerized `zero-cache` — the only thing that changes moving from a laptop to the VPS is that nginx now fronts real traffic and Certbot manages a real certificate.

---

## 2. Provisioning

Debian 13 (trixie), assumed as a clean VPS with root SSH access initially.

1. **Base packages.** Node.js 20.x and PostgreSQL 15+ ship natively in Debian 13's own apt repos (20.19.x and PostgreSQL 17 respectively) — `apt install nodejs npm postgresql postgresql-contrib`, no NodeSource or PGDG repo needed. Docker via its official repo (the `trixie` codename is supported directly), nginx, Certbot (`certbot` + `python3-certbot-nginx`). Automated by `scripts/provision-vps.sh`.
2. **Firewall.** `ufw allow 22,80,443/tcp`, `ufw enable`. Nothing else is exposed.
3. **SSH.** Key-only auth (`PasswordAuthentication no`); disable root login once the `deploy` user (below) exists and has been verified to work. **Deliberately manual** — not part of `scripts/provision-vps.sh` — a mistake here is a lockout.
4. **The `deploy` user.** A dedicated, non-root system user that owns the app and is what GitHub Actions authenticates as:

   ```bash
   adduser --system --group --home /opt/team-works --shell /bin/bash deploy
   mkdir -p /opt/team-works/releases /opt/team-works/shared
   chown -R deploy:deploy /opt/team-works
   ```

   `deploy` gets narrowly-scoped passwordless `sudo`, limited to restarting the two units it needs — not blanket root:

   ```
   # /etc/sudoers.d/deploy
   deploy ALL=(root) NOPASSWD: /usr/bin/systemctl restart team-works, /usr/bin/systemctl restart zero-cache
   ```
5. **Postgres.** Same steps as local-dev.md §2 — create the role and database, set `wal_level = logical` in `postgresql.conf` (Debian 13: `/etc/postgresql/17/main/postgresql.conf`), restart, confirm with `SHOW wal_level`.
6. **Attachments directory**, outside any release tree since it's persistent data, not code:

   ```bash
   mkdir -p /var/lib/team-works/attachments
   chown deploy:deploy /var/lib/team-works/attachments
   ```

   This is the path `ATTACHMENTS_DIR` (auth.md §10) points at in production — matches the layout attachments.md §3 already shows (`{ATTACHMENTS_DIR}/{project_key}/{issue_number}/…`).

---

## 3. Releases: an atomic deploy layout

```
/opt/team-works/
  releases/
    20260731153000/       ← one directory per deploy, named by timestamp
    20260731161500/
  shared/
    .env                  ← not per-release; symlinked into each one
  current -> releases/20260731161500/   ← atomic symlink; this is what's live
```

`team-works.service` (§4) points at `/opt/team-works/current`, never at a specific release directory. A deploy builds an entirely new, isolated release — its own `npm ci`, its own build output — and only the final symlink swap makes it live. A build that fails midway (a broken `npm ci`, a failing `next build`) never touches `current`; the previous release keeps serving traffic the whole time. `ATTACHMENTS_DIR` lives outside this tree entirely (§2, step 6), so pruning old releases never touches uploaded files.

The last 5 releases are kept on disk (§7) so a rollback is a symlink swap, not a rebuild.

---

## 4. Runtime services (systemd)

| Unit | Type | Runs |
| --- | --- | --- |
| `team-works.service` | `simple`, `WorkingDirectory=/opt/team-works/current` | `npm run start` |
| `zero-cache.service` | `simple`, wraps `docker compose -f /opt/team-works/current/docker-compose.zero.yml up` | the `zero-cache` container |
| `team-works-auth-purge.timer` / `.service` | `oneshot`, daily | `npm run auth:purge` (auth.md §11) |
| `team-works-notify-outbox.timer` / `.service` | `oneshot`, every 1 minute | `npm run notify:send-outbox` (notifications.md §5) |
| `team-works-attachments-reclaim.timer` / `.service` | `oneshot`, weekly | `npm run attachments:reclaim` (attachments.md §5) |
| `team-works-backup.timer` / `.service` | `oneshot`, daily | the backup script (§9) |

All five `.service` units set `Restart=on-failure` and `EnvironmentFile=/opt/team-works/shared/.env` (the app units) or `/etc/team-works/backup.env` (the backup unit — §6). Logs go to `journalctl -u <unit>`; no separate log files or log rotation config to maintain.

`zero-cache`'s compose file is local-dev.md §4's, with two production changes:

```yaml
services:
  zero-cache:
    image: rocicorp/zero-cache   # pinned to the version resolved in build step 1
    ports:
      - "4848:4848"
    environment:
      ZERO_UPSTREAM_DB: postgresql://team_works@host.docker.internal:5432/team_works
      ZERO_REPLICA_FILE: /data/zero-replica.sqlite
      ZERO_AUTH_SECRET: ${ZERO_AUTH_SECRET}
      ZERO_PORT: "4848"
    extra_hosts:
      - "host.docker.internal:host-gateway"   # Linux needs this explicitly; local-dev.md's Mac docker didn't
    volumes:
      - /var/lib/team-works/zero-replica:/data   # local disk, not network-attached — brief §5's "fast local storage"
```

---

## 5. nginx

Reverse-proxies `/` to the app on `:3000` and the Zero sync path to `zero-cache` on `:4848`. Certbot (`certbot --nginx`) issues and auto-renews the certificate — it installs its own systemd timer, nothing added here.

Two requirements auth.md assigned to this document:

```nginx
# rate-limit the one unauthenticated endpoint (auth.md §9)
limit_req_zone $binary_remote_addr zone=authlimit:10m rate=5r/m;

server {
  # ...
  location /api/auth/ {
    limit_req zone=authlimit burst=5 nodelay;
    proxy_pass http://localhost:3000;
  }

  # never log the single-use token in the query string (auth.md §4.3)
  location /auth/verify {
    access_log off;
    proxy_pass http://localhost:3000;
  }

  location / {
    proxy_pass http://localhost:3000;
  }
}
```

---

## 6. Environment and secrets

`/opt/team-works/shared/.env` fills auth.md §10's contract with production values — generated once during provisioning, never regenerated on deploy (that would invalidate every session). `AUTH_SECRET` and `ZERO_AUTH_SECRET` are set to the identical value, per that document's warning that generating two different values is the most likely misconfiguration. `APP_URL` is `https://…`, which turns on the `Secure` cookie flag automatically (auth.md §7) — no production-specific branch in application code.

Each release symlinks this file in at deploy time (§3, §7) rather than each release carrying its own copy — one file to rotate, one file a leaked release directory doesn't duplicate.

**Backup credentials are separate**, in `/etc/team-works/backup.env` (bucket endpoint, key, secret — §9). This is a deployment-layer concern, not part of the application's own environment contract, so auth.md §10 is unchanged by this document.

**GitHub Actions secrets**: `DEPLOY_SSH_KEY` (a key authorized only for the `deploy` user, nothing else), `DEPLOY_HOST`, `DEPLOY_USER`.

---

## 7. CI and deploy pipeline

testing.md §9 fixes the CI shape and names this document as owner of the actual provider config: a **fast** stage (Postgres service container, migrate, unit + integration tests) on every push, and a **slow** stage (additionally `zero-cache` and Mailpit via `docker-compose.e2e.yml`, running E2E) on merge to `main` only, given the Docker-and-browser cost. Deploying anything that hasn't passed both is not a risk worth taking for the sake of a simpler workflow, so the deploy job is gated behind both — one workflow, three jobs:

> **As of 2026-08-02 (P0.1, [GitHub issue #4](https://github.com/vespaiach/team-works/issues/4)):** the `deploy.sh` and CI shape below is the eventual target, once Foundation A/B land. The shipped `deploy.sh` and `ci.yml` today omit `db:migrate` and the test steps — see [the P0.1 design spec](./superpowers/specs/2026-08-02-vps-provisioning-deploy-pipeline-design.md) §3 for why.

```yaml
# .github/workflows/ci.yml
name: ci
on: push
jobs:
  fast:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:15
        env: { POSTGRES_USER: team_works, POSTGRES_DB: team_works_test }
        ports: ["5432:5432"]
        options: --health-cmd pg_isready
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci
      - run: npm run db:migrate
        env: { DATABASE_URL: postgresql://team_works@localhost:5432/team_works_test }
      - run: npm run test:unit
      - run: npm run test:integration

  e2e:
    needs: fast
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: npm ci
      - run: docker compose -f docker-compose.e2e.yml up -d
      - run: npm run test:e2e
      - run: docker compose -f docker-compose.e2e.yml down -v

  deploy:
    needs: e2e
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      # pinned to a commit SHA, not the mutable v1 tag — this step receives the
      # production SSH private key
      - uses: appleboy/ssh-action@0ff4204d59e8e51228ff73bce53f80d53301dee2 # v1.2.5
        with:
          host: ${{ secrets.DEPLOY_HOST }}
          username: ${{ secrets.DEPLOY_USER }}
          key: ${{ secrets.DEPLOY_SSH_KEY }}
          script: /opt/team-works/deploy.sh
```

`fast` runs on every branch and every PR — the ordinary CI signal. `e2e` and `deploy` both carry the `main`-only condition and `deploy` additionally depends on `e2e`, so nothing reaches the VPS without a green E2E run first; a push to any other branch stops after `fast`.

`deploy.sh`, checked into the repo, run by `deploy` on the box:

```bash
#!/usr/bin/env bash
set -euo pipefail

# the -L guard matters: GNU `readlink -f` on a nonexistent `current` still exits
# 0 and echoes the literal path, so without it PREV is non-empty even on a
# first-ever deploy and rollback writes a self-referential `current -> current`
PREV=$([ -L /opt/team-works/current ] && readlink -f /opt/team-works/current || true)
RELEASE=/opt/team-works/releases/$(date +%Y%m%d%H%M%S)

git clone --depth 1 --branch main <repo-url> "$RELEASE"
ln -s /opt/team-works/shared/.env "$RELEASE/.env"
cd "$RELEASE"
npm ci
npm run build
npm run db:migrate

ln -sfn "$RELEASE" /opt/team-works/current   # atomic — a rename, not a copy
sudo systemctl restart team-works

healthy=false
for _ in $(seq 1 10); do
  sleep 1
  if curl -fs http://localhost:3000/api/health >/dev/null; then
    healthy=true
    break
  fi
done

if [ "$healthy" = false ]; then
  if [ -n "$PREV" ] && [ -d "$PREV" ]; then
    echo "health check failed, rolling back to $PREV"
    ln -sfn "$PREV" /opt/team-works/current
    sudo systemctl restart team-works
  else
    echo "health check failed and there is no previous release to roll back to"
    rm -f /opt/team-works/current
  fi
  exit 1
fi

# keep the 5 most recent releases, prune the rest
cd /opt/team-works/releases && ls -1t | tail -n +6 | xargs -r rm -rf
```

A build that fails (`npm ci`, `next build`, or the migration itself) exits before the symlink swap — `current` and the running process are untouched, and the old release keeps serving traffic through the whole build. A deploy that builds and migrates cleanly but serves a broken app is caught by the health check and rolled back automatically within about ten seconds, no human required.

**What auto-rollback does not undo: the migration.** `db:migrate` runs before the symlink swap, against the one shared database every release points at. If health-check rollback fires, the *code* reverts to the previous release, but any migration that already ran stays applied — there is no corresponding "undo" step. This is only a real hazard for a migration that changes something the previous release's code depends on in an incompatible way. Practically: keep migrations that ship alongside risky code changes additive (new nullable columns, new tables) rather than destructive, and land a genuinely breaking schema change as its own deploy, confirmed healthy, before the code that depends on it ships in a later one. This is a discipline this document can name but not enforce — nothing here checks it.

**Manual rollback** (past the last automatic attempt, or to go back further than one release) is the same symlink-and-restart, run by hand:

```bash
ln -sfn /opt/team-works/releases/<previous-timestamp> /opt/team-works/current
sudo systemctl restart team-works
```

---

## 8. Migrations and the `zero-cache` replica reset

`db:migrate` (local-dev.md §5) runs against production `DATABASE_URL` as part of every deploy (§7). Most migrations need nothing further — `zero-cache` picks up ordinary `INSERT`/`UPDATE`/`DELETE` activity through logical replication continuously, and additive schema changes to already-synced tables (a new index, a new `CHECK`, a new non-synced table) don't change what it's replicating.

**Decision rule.** A migration requires a replica reset if and only if it changes the shape `zero-cache` actually replicates:

- it edits the `zero_data` publication itself (data-model.md §3) — adding or removing a table, or adding or removing a column from a table's column list (the `user` six-column list is the one most likely to move); or
- it changes the **type** of a column already in that list.

A migration that only touches non-synced tables (`invite`, `login_token`, `session`, `issue_counter`, `notification_email`), or that adds a constraint, default, or index to an already-synced column without changing its type, does **not** need one.

This is a documentation convention, not tooling: `deploy.sh` does not inspect migration SQL. Every migration PR states in its description whether it trips the rule — reviewed and caught at that point, the same way any other schema consequence is caught in review.

**Reset procedure**, run by hand immediately after a flagged migration has deployed:

```bash
sudo systemctl stop zero-cache
rm -f /var/lib/team-works/zero-replica/zero-replica.sqlite
sudo systemctl start zero-cache   # re-snapshots from the publication, from scratch
```

Order matters: `zero-cache` is stopped *before* touching anything further, so it never attempts to replicate a DDL statement its running replica doesn't understand; the replica file is then wiped so the restart does a clean initial snapshot rather than trying to reconcile. Sync is unavailable for the rebuild window — at this data volume, seconds to low minutes. Every connected client behaves exactly like the "disconnected" state permissions.md §9 already specifies: reads keep working against the local store, writes are rejected until the connection returns. No new state to design for this; run resets outside working hours as a courtesy, not a requirement.

---

## 9. Backups and restore drill

Nightly, off-box, to an S3-compatible bucket (Backblaze B2, Hetzner Storage Box, or equivalent — the provider isn't pinned here, the mechanism is):

```bash
#!/usr/bin/env bash
set -euo pipefail
STAMP=$(date +%F)
pg_dump --format=custom "$DATABASE_URL" | gzip > /tmp/team-works-$STAMP.pgdump.gz
tar czf /tmp/team-works-attachments-$STAMP.tar.gz -C "$ATTACHMENTS_DIR" .
rclone copy /tmp/team-works-$STAMP.pgdump.gz remote:team-works-backups/
rclone copy /tmp/team-works-attachments-$STAMP.tar.gz remote:team-works-backups/
rm -f /tmp/team-works-$STAMP.pgdump.gz /tmp/team-works-attachments-$STAMP.tar.gz
```

Both artifacts are produced and pushed **in the same run**, never on separate schedules — attachments.md §6 is explicit that a Postgres backup and an attachments backup are only meaningful together, since a restore mixing two different points in time is exactly the "row exists, file missing" case that document already made §2 degrade to a clean 404 rather than an error. 14 daily backups are retained via a bucket lifecycle rule, pruned by the storage provider rather than by a script here.

**Restore drill** — run periodically (quarterly is a reasonable cadence for a team this size), as a checklist rather than automation:

1. Provision a scratch Postgres and an empty directory standing in for `ATTACHMENTS_DIR`.
2. Restore the same day's `pgdump` (`pg_restore`) and extract the matching `tar.gz`.
3. Point a local build of the app at the restored database and directory; confirm sign-in works (a fresh magic link, since `login_token` rows are short-lived and the restored ones are likely expired) and that a known issue and its attachment both render.
4. Confirm the expected skew case: an attachment uploaded after the Postgres dump's timestamp has a row with no file, or a file with no row — both should 404 cleanly (attachments.md §2 step 4), not error. This is the accepted cost of two backups from the same moment, not a bug the drill is looking for.

---

## 10. First boot

> **As of 2026-08-02 (P0.1, [GitHub issue #4](https://github.com/vespaiach/team-works/issues/4)):** steps 4 and 5 below describe the eventual target — today's shipped `deploy.sh` has no `db:migrate` step and there is no `zero-cache` unit to bring up yet. For the runbook that matches what actually ships today, see [the P0.1 design spec](./superpowers/specs/2026-08-02-vps-provisioning-deploy-pipeline-design.md) §6 (and §3 for why).

1. Provision the box (§2): packages, firewall, the `deploy` user, Postgres with `wal_level=logical`, the attachments directory.
2. Write `/opt/team-works/shared/.env` (§6): freshly generated `AUTH_SECRET`/`ZERO_AUTH_SECRET` (identical value), real SMTP credentials, `APP_URL` set to the production domain.
3. Write `/etc/team-works/backup.env` (§9) with bucket credentials.
4. Run `deploy.sh` once by hand (or trigger it via the first push to `main`) — this creates the first release, runs `npm run db:migrate` for the first time (creating the schema and the `zero_data` publication), and starts `team-works.service`.
5. Bring up `zero-cache` — first snapshot of an empty-but-schema'd database.
6. `npm run admin:grant -- --email=you@example.com --name="Your Name"` (auth.md §4.6), run from the box against `DATABASE_URL` — the one account created outside the invite flow, and the recovery path if every admin ever loses mailbox access.

   The same script is the workaround for changing a user's email address, which v1 has no mutator for (auth.md §13): a direct `UPDATE "user" SET email = … WHERE id = …`, run the same way, over SSH.
7. Enable and start every timer in §4 (`systemctl enable --now team-works-auth-purge.timer …`).
8. Sign in through the ordinary magic-link flow, confirm the email actually arrives through the real SMTP provider (not Mailpit), and start inviting the rest of the team.

---

## 11. Operational checklist

Not a formal test suite — this document is a runbook, and these are the things worth confirming work before relying on them:

- **Deploy round-trip.** Push a trivial change to `main`, confirm the workflow runs, a new release directory appears, `current` repoints, and the app serves the change.
- **Auto-rollback.** Deliberately push a change that fails to build, or one whose `/api/health` route is broken, and confirm `deploy.sh` repoints `current` back and the site stays up throughout.
- **Manual rollback.** Confirm the by-hand symlink-and-restart command actually serves the older release.
- **Replica reset.** Run the §8 procedure once against a real flagged migration in a non-production environment first, and confirm clients reconnect and re-sync cleanly afterward.
- **Restore drill.** §9's checklist, on the cadence you settle on.
- **Timers are actually running.** `systemctl list-timers` after first boot, and again after any VPS reboot — confirms `auth:purge`, `notify:send-outbox`, `attachments:reclaim`, and the backup job are all scheduled, not just installed.
- **Backup failure count**, spot-checked occasionally rather than alerted on: `SELECT count(*) FROM notification_email WHERE status = 'failed'`. notifications.md §6 names this as an optional signal this document may add; a periodic manual check is the whole of what's added here — no new timer, no alerting pipeline.
- **Boot-time env validation.** Confirm the app actually refuses to start if `.env` is incomplete or `AUTH_SECRET` is too short (auth.md §10) — deliberately break `.env` once on a non-production box and watch it fail loudly rather than starting in a broken state.

---

## 12. Changes this spec requires elsewhere

### To [team-works-concept-brief.md](./team-works-concept-brief.md) — applied 2026-07-31

- **§5, "Deployment (VPS)"** — "the Next.js app (PM2 or systemd)" resolves to **systemd**, per §4 above. The brief had left this an open "or"; it is no longer one.
- **§7, Settled** — decision 20 added: **Process manager: systemd** (this document).

### Discharges deferred items from other specs — no edits made to those documents

Following the pattern attachments.md and ui-spec.md already set: the documents below named deployment.md as the owner of specific open questions, and this document resolves them in its own text rather than editing their deferred-items tables retroactively.

- **data-model.md §3, §11, §12** — "which migrations force a `zero-cache` replica reset" is answered by §8 above.
- **auth.md §4.3, §9, §11, §13, §14** — nginx `limit_req` on `/api/auth/*` and query-string suppression on `/auth/verify` (§5 above); the daily `auth:purge` timer (§4 above); `admin:grant` in the provisioning runbook, and the email-change workaround noted alongside it (§10 above).
- **attachments.md §6** — the backup mechanism (§9 above), and the requirement that Postgres and attachment backups run on one shared schedule, not separate ones.
- **notifications.md §5, §6** — the `notify:send-outbox` timer (§4 above); the optional failed-count health check (§11 above).
- **testing.md §9** — the actual CI provider config: the fast/slow two-stage split, the Postgres service container, and `docker-compose.e2e.yml` are all implemented in §7 above exactly as that document fixed their shape.

### To `README.md` — applied 2026-07-31

Doc index gains a line for this document.

### To `CLAUDE.md`

No changes required — it does not enumerate the full spec set or assert anything about process management that this document contradicts.

---

_Decisions here are settled. Revise deliberately, and reconcile the concept brief, data-model.md and auth.md in the same change if a future change touches the publication, the environment contract, or the process-manager decision._
