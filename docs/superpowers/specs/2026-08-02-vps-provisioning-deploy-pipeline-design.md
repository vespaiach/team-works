# Team Works — VPS provisioning & deploy pipeline (P0.1)

_Design spec, 2026-08-02. Implements [GitHub issue #4](https://github.com/vespaiach/team-works/issues/4) — "01 · [INFRA/DEVOPS]: P0.1 — Provision the VPS and wire the deploy pipeline", the first task in the 59-task build (Phase 0, no dependencies). Specified against [deployment.md](../../deployment.md) §2–§7 and §10, and [the task breakdown](2026-08-02-implementation-task-breakdown-design.md) §6.1._

---

## 1. Scope

**Delivered by this task, checked into the repo:**

- A Debian 13 provisioning script and runbook the operator runs by hand against the real VPS.
- The atomic-release deploy mechanics: `deploy.sh`, `team-works.service`, nginx config, `/api/health`.
- The CI pipeline shape: `fast` → `e2e` (stubbed) → `deploy`, gated on `main`.
- Documentation reconciliation: `deployment.md` §2 updated from "Ubuntu 22.04 LTS (or Debian 12)" to Debian 13.

**Explicitly not delivered here** (each already tracked as a separate, later task):

- Anything requiring the app to be non-empty: migrations (`db:migrate`), unit/integration tests, `zero-cache` actually running. See §3.
- `zero-cache.service` and its compose file (Phase 4, task D-2) — see §4.
- Actually executing the provisioning against the live box. Per the answered clarifying question, this is infra-as-code + a runbook; the operator runs it themselves and reports back results (or errors, which get fixed in follow-up).

## 2. Provisioning target: Debian 13 (reconciles deployment.md §2)

`deployment.md` §2 currently reads "Ubuntu 22.04 LTS (or Debian 12)". The real box is Debian 13 (trixie). Verified package-availability facts that make this a clean swap rather than a workaround:

| Component | Debian 12 (as documented) | Debian 13 (actual target) |
| --- | --- | --- |
| Node.js 20 | NodeSource repo (`setup_20.x`) | **Native `apt install nodejs npm`** — Debian 13 ships 20.19.2 directly. NodeSource's legacy setup script has a known bug misdetecting `trixie`, so native apt avoids it entirely. |
| PostgreSQL 15+ | PGDG repo for a pinned version | **Native `apt install postgresql`** — Debian 13's default package is v17, satisfying the "15+" floor with no extra repo. |
| Docker | Docker's official repo, `bookworm` codename | Docker's official repo, **`trixie` codename** — confirmed supported. |
| nginx, certbot, ufw | distro packages | unchanged — same packages, present in Debian 13. |

`deployment.md` §2's provisioning list and opening sentence get updated to this shape; a dated note is added under its §12 change-log recording the swap. No other doc mentions an OS version (checked via grep across `docs/*.md`).

## 3. Deploy mechanics vs. scripts that don't exist yet

`deployment.md`'s example `deploy.sh` runs `npm run db:migrate`; its `fast` CI job runs `npm run test:unit` / `test:integration` against a Postgres service container. None of these npm scripts exist yet — Vitest config (Foundation A-4) and migration tooling (Foundation B-3) are separate, later tasks, and the app currently has no `src/lib`, no Drizzle, no test runner.

**Decision: ship only what's real today (approach B).**

- `deploy.sh` builds, restarts, health-checks, and rolls back — no migrate step. Foundation B-3 adds that one line when migration tooling lands.
- `ci.yml`'s `fast` job keeps today's `lint` + `build` steps (already present) and adds nothing test-shaped yet. Foundation A-4 adds the Postgres service container and test steps when Vitest lands.
- `e2e` job is present in the workflow file (so the three-job shape exists per spec) but is a no-op — matches the issue's own text: "The `e2e` job is defined but skipped until D-7 gives it tests to run."
- `deploy` job depends on `e2e`, gated to `main`, SSHes in and runs `/opt/team-works/deploy.sh`.

Rejected alternative: adding placeholder `echo`-and-exit-0 scripts for `db:migrate`/`test:unit`/`test:integration` now, so the pipeline files match deployment.md's example byte-for-byte from day one. Rejected because a CI step that trivially passes forever until someone remembers to fill it in is a false-confidence trap, and those scripts are Foundation A/B's job to define, not this task's. This task's Definition of Done (release round-trip, health check, rollback) doesn't require either to exist.

## 4. Deferred: `zero-cache.service`

Not created in this task. Standing up the `zero-cache` container now would crash-loop — there is no schema or `zero_data` publication yet for it to replicate (that lands in Foundation B, Phase 2). It's already tracked as its own task (D-2, Phase 4, "Verify `zero-cache` env vars and image tag"). The issue's framing ("proves logical replication, the container, nginx and auto-rollback") is read as describing the eventual state of Phase 0's infrastructure once later phases land on top of it, not a literal requirement of this task's Definition of Done — which only lists release round-trip, health check over TLS, and rollback.

## 5. Deliverables

| File | Purpose |
| --- | --- |
| [src/app/api/health/route.ts](../../../src/app/api/health/route.ts) | Minimal `200 { status: "ok" }` route. The one actual app-code change — `deploy.sh`'s health check depends on it existing. |
| `scripts/provision-vps.sh` | Idempotent, root-run-once: base packages (§2), `ufw allow 22,80,443/tcp`, `deploy` system user + home dirs, scoped `sudoers.d/deploy`, Postgres `wal_level=logical`, `/var/lib/team-works/attachments`. **Excludes** SSH hardening (below). |
| `deploy/nginx/team-works.conf` | Reverse proxy to `:3000`; `limit_req` on `/api/auth/` (auth.md §9); `access_log off` on `/auth/verify` (auth.md §4.3). Domain is the placeholder `team-works.example.com`, marked for find-replace. |
| `deploy/systemd/team-works.service` | `simple`, `WorkingDirectory=/opt/team-works/current`, `ExecStart=npm run start`, `EnvironmentFile=/opt/team-works/shared/.env`, `Restart=on-failure`, runs as `deploy`. |
| `deploy.sh` (repo root) | Clone a timestamped release, `npm ci`, `npm run build`, symlink swap, restart, poll `/api/health` for ~10s, roll back to the previous release on failure, prune to last 5 releases. |
| `.github/workflows/ci.yml` | Extended from the current single `verify` job into `fast` (checkout, setup-node 20, `npm ci`, `npm run lint`, `npm run build`) → `e2e` (defined, no-op, `main`-only) → `deploy` (needs `e2e`, `main`-only, `appleboy/ssh-action` running `/opt/team-works/deploy.sh`). |
| `deploy/env.production.example` | Template of auth.md §10's env contract (`DATABASE_URL`, `ATTACHMENTS_DIR`, `AUTH_SECRET`, `ZERO_AUTH_SECRET`, `APP_URL`, `SMTP_*`) with placeholder values — never real secrets. Operator copies this to `/opt/team-works/shared/.env` and fills in real values by hand on the box. |
| `docs/deployment.md` | §2 updated for Debian 13 (§2 above); dated changelog note added. |
| Runbook (in this spec, §6) | The exact commands the operator runs, in order, against the real box. |

## 6. Operator runbook (what you run by hand)

1. Get this repo's files onto the box. Copy the provisioning script over and run it as root — e.g. `scp scripts/provision-vps.sh root@<host>:/root/`, then `ssh root@<host> bash /root/provision-vps.sh`. It installs `git` among its packages, so afterwards you can clone the full repo for the remaining files this runbook references: `git clone https://github.com/vespaiach/team-works.git /root/team-works-src`. Later steps that say "copy `deploy/...`" or "copy `deploy.sh`" mean from this checkout.
2. Authorize the deploy SSH key. Generate a dedicated keypair locally: `ssh-keygen -t ed25519 -f deploy_key -N ""`. On the box, create `/opt/team-works/.ssh` owned `deploy:deploy` mode `0700`, and append `deploy_key.pub`'s contents to `/opt/team-works/.ssh/authorized_keys` (mode `0600`, owned `deploy:deploy`). The private half (`deploy_key`) is what step 9 puts into the `DEPLOY_SSH_KEY` GitHub Actions secret.
3. Verify the `deploy` user's SSH key works (`ssh deploy@<host>`), **then and only then** manually flip `PasswordAuthentication no` and `PermitRootLogin no` in `sshd_config` and restart `sshd`. Not automated — a mistake here locks you out, and it's cheap to do carefully by hand once.
4. Install the systemd unit: copy `deploy/systemd/team-works.service` to `/etc/systemd/system/team-works.service`, then `systemctl daemon-reload && systemctl enable team-works` (don't start it yet — there's no release at `/opt/team-works/current` until the first deploy runs).
5. Install the nginx site: replace the placeholder domain in `deploy/nginx/team-works.conf`, copy it to `/etc/nginx/sites-available/team-works.conf`, symlink it into `sites-enabled`, then `nginx -t && systemctl reload nginx`. Certbot (next step) needs an existing enabled site to attach the certificate to.
6. `certbot --nginx -d <your-real-domain>` once DNS points at the box.
7. Write `/opt/team-works/shared/.env` from `deploy/env.production.example`, with real generated secrets (`AUTH_SECRET` = `ZERO_AUTH_SECRET`, both ≥32 bytes) and real SMTP credentials.
   - **Set `APP_URL` to the real production domain**, replacing the placeholder `https://team-works.example.com` — the same domain Certbot issued a cert for in step 6. It is auth-critical: magic-link URLs, the `Origin` check, and the `Secure` cookie flag all derive from it.
   - **Set the Postgres role's password to match `DATABASE_URL`.** `provision-vps.sh` creates the `team_works` role and database but deliberately sets no password (a secret does not belong in a checked-in script): `sudo -u postgres psql -c "ALTER ROLE team_works WITH PASSWORD '...';"`, using the same password you put in `DATABASE_URL`.
   - Lock the file down once written — it holds every production secret, and `deploy.sh` symlinks each release's `.env` at it: `chown deploy:deploy /opt/team-works/shared/.env && chmod 0600 /opt/team-works/shared/.env`.
8. Copy `deploy.sh` to `/opt/team-works/deploy.sh` (the CI SSH step runs this fixed path — updates to the repo's `deploy.sh` need re-copying here; a known small gap in deployment.md's design, not fixed by this task).
9. Add the three GitHub Actions secrets yourself (`DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY` — the last being the private `deploy_key` from step 2) — not something I can or should do on your behalf.
10. Push to `main`; confirm against the Definition of Done below. The first push will start `team-works.service` for real (via `deploy.sh`'s `sudo systemctl restart team-works`) — nothing before this step actually runs the app.

## 7. Definition of Done (from the issue, unchanged)

- [ ] A push to `main` produces a new release directory and repoints `current`
- [ ] `https://<domain>/api/health` returns 200 over TLS
- [ ] A deliberately broken build leaves `current` untouched and the site up
- [ ] A deliberately broken `/api/health` triggers automatic rollback within ~10s
- [ ] Manual rollback by symlink swap serves the older release

These are verified by you against the real box (§1) — I'll help debug from whatever output/errors you share.

## 8. Changes this spec requires elsewhere

- **`docs/deployment.md` §2** — Debian 13 provisioning target, per §2 above. Dated note added to its own §12 changelog.
- No other doc requires changes (grepped for OS-version mentions; `deployment.md` §2 was the only hit).
