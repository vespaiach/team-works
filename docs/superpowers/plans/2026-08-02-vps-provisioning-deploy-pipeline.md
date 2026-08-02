# VPS Provisioning & Deploy Pipeline (P0.1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the first end-to-end deploy pipeline for Team Works — a Debian 13 VPS provisioning script, the atomic-release deploy mechanics (`deploy.sh`, systemd, nginx, health check, auto-rollback), and a three-job GitHub Actions workflow — so that a push to `main` deploys to production and a broken deploy rolls itself back.

**Architecture:** All infra config lives in the repo as plain files (bash, systemd unit, nginx conf, GitHub Actions YAML) that the operator runs against the real box by hand; nothing here is executed against a live server by the implementer. The one real application change is a minimal `/api/health` route. Everything else — migrations, tests, `zero-cache` — is explicitly out of scope because those subsystems don't exist yet (they land in later, separately tracked tasks).

**Tech Stack:** Next.js 16 App Router (route handler), bash, systemd, nginx + Certbot, GitHub Actions, Debian 13 (trixie).

## Global Constraints

- Implements [GitHub issue #4](https://github.com/vespaiach/team-works/issues/4) (P0.1) per [the approved design spec](../specs/2026-08-02-vps-provisioning-deploy-pipeline-design.md). Read that spec's §1–§8 before starting if anything below is ambiguous.
- Provisioning target is **Debian 13 (trixie)**, not Ubuntu 22.04/Debian 12 as `deployment.md` currently says — that doc gets corrected in Task 8.
- Domain is the placeholder `team-works.example.com` everywhere — never invent or guess a real domain.
- **No task touches `db:migrate`, `test:unit`, `test:integration`, or `zero-cache`.** Those don't exist yet (Foundation A-4, B-3, and Phase-4 task D-2 respectively) and are deliberately out of scope — see design spec §3–§4.
- The repo is public: `https://github.com/vespaiach/team-works.git`. `deploy.sh` clones over plain HTTPS — no deploy key needed.
- Never generate, invent, or write real secrets (`AUTH_SECRET`, SMTP credentials, GitHub Actions secrets). Every secret-shaped value in this plan is a clearly-marked placeholder the operator replaces by hand.
- Run `npm run check` (Biome) before considering the plan done, per `AGENTS.md`.
- Verification tooling available in this dev environment: `shellcheck`, `bash -n`, a local `nginx` binary (for `-t` syntax checks via a temp wrapper config), `ruby -ryaml` (YAML syntax checks — no `pyyaml`/`js-yaml` installed), `npm`/`node`. There is no systemd, no `ufw`, no Debian package manager here — systemd/nginx units are verified structurally (grep for required directives) and by careful reading against the spec, not by running them.

---

### Task 1: Health check route

**Files:**
- Create: `src/app/api/health/route.ts`

**Interfaces:**
- Produces: `GET /api/health` → `200 { "status": "ok" }`. Consumed by Task 2's `deploy.sh` health-check loop and by the nginx config in Task 4 (proxied under `location /`).

- [ ] **Step 1: Create the route file**

```typescript
export async function GET() {
  return Response.json({ status: "ok" });
}
```

- [ ] **Step 2: Verify it builds**

Run: `npm run build`
Expected: `Route (app)` table in the output lists `ƒ /api/health` (dynamic, server-rendered), and the build finishes with no errors.

- [ ] **Step 3: Verify it serves correctly at runtime**

Run:
```bash
npm run dev > /tmp/health-dev.log 2>&1 &
sleep 4
curl -s -o /tmp/health-resp.json -w "HTTP %{http_code}\n" http://localhost:3000/api/health
cat /tmp/health-resp.json
kill %1
```
Expected: `HTTP 200` and body `{"status":"ok"}`.

- [ ] **Step 4: Lint and commit**

```bash
npm run check
git add src/app/api/health/route.ts
git commit -m "feat: add /api/health route"
```

---

### Task 2: `deploy.sh` — atomic release, health check, auto-rollback

**Files:**
- Create: `deploy.sh` (repo root)

**Interfaces:**
- Consumes: `GET http://localhost:3000/api/health` (Task 1).
- Produces: `/opt/team-works/current` symlink, restarts the `team-works` systemd unit (Task 3) via `sudo systemctl restart team-works`. Invoked by the `deploy` CI job (Task 7) as `/opt/team-works/deploy.sh` on the VPS, and by the provisioning runbook (Task 6).

- [ ] **Step 1: Write `deploy.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/vespaiach/team-works.git"
BASE=/opt/team-works

PREV=$(readlink -f "$BASE/current" || true)
RELEASE="$BASE/releases/$(date +%Y%m%d%H%M%S)"

git clone --depth 1 --branch main "$REPO_URL" "$RELEASE"
ln -s "$BASE/shared/.env" "$RELEASE/.env"
cd "$RELEASE" || exit 1
npm ci
npm run build

ln -sfn "$RELEASE" "$BASE/current"   # atomic — a rename, not a copy
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
  echo "health check failed, rolling back to $PREV"
  ln -sfn "$PREV" "$BASE/current"
  sudo systemctl restart team-works
  exit 1
fi

# keep the 5 most recent releases, prune the rest
cd "$BASE/releases" || exit 1
ls -1t | tail -n +6 | xargs -r rm -rf
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x deploy.sh`

- [ ] **Step 3: Verify with shellcheck and a syntax check**

Run: `shellcheck -S warning deploy.sh && bash -n deploy.sh`
Expected: both commands exit 0. (An info-level `SC2012` note about `ls -1t` vs `find` is expected and fine at the `warning` threshold — release directory names are pure timestamps, so `ls`'s handling of non-alphanumeric filenames doesn't apply. Do not "fix" this by rewriting the loop; it matches `deployment.md` §7's exact spec'd form.)

- [ ] **Step 4: Manually re-check the algorithm against deployment.md §7**

Confirm line-by-line: release dir is a timestamp, `.env` is symlinked in before `npm ci`, the `current` symlink swap happens only after a successful build, restart happens after the swap, the health-check loop polls up to 10 times at 1s intervals, rollback restores `PREV` and restarts again, and pruning keeps exactly 5 releases. This task's Definition of Done (issue #4) can only be exercised for real once this script runs on the actual VPS (Task 6's runbook) — there is no local systemd/VPS to run it against here.

- [ ] **Step 5: Commit**

```bash
git add deploy.sh
git commit -m "feat: add deploy.sh (atomic release, health check, auto-rollback)"
```

---

### Task 3: `team-works.service` systemd unit

**Files:**
- Create: `deploy/systemd/team-works.service`

**Interfaces:**
- Consumes: `/opt/team-works/current` (Task 2), `/opt/team-works/shared/.env` (Task 5).
- Produces: the `team-works` unit name, restarted by Task 2's `deploy.sh` and installed by Task 6's provisioning runbook.

- [ ] **Step 1: Write the unit file**

```ini
[Unit]
Description=Team Works application
After=network.target postgresql.service

[Service]
Type=simple
User=deploy
Group=deploy
WorkingDirectory=/opt/team-works/current
ExecStart=/usr/bin/npm run start
Restart=on-failure
EnvironmentFile=/opt/team-works/shared/.env

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Verify structurally**

There is no systemd in this dev environment to run `systemd-analyze verify` against, so check the required directives are present by hand:

Run:
```bash
for key in "ExecStart=" "WorkingDirectory=/opt/team-works/current" "Restart=on-failure" "EnvironmentFile=/opt/team-works/shared/.env" "User=deploy" "\[Install\]" "WantedBy="; do
  grep -qE "$key" deploy/systemd/team-works.service && echo "OK: $key" || echo "MISSING: $key"
done
```
Expected: `OK` for every line, no `MISSING`.

- [ ] **Step 3: Commit**

```bash
git add deploy/systemd/team-works.service
git commit -m "feat: add team-works.service systemd unit"
```

---

### Task 4: nginx reverse proxy config

**Files:**
- Create: `deploy/nginx/team-works.conf`

**Interfaces:**
- Consumes: app on `localhost:3000` (Task 1's route lives under `location /`).
- Produces: the file the operator symlinks into `/etc/nginx/sites-enabled/` and later hands to `certbot --nginx` (Task 6's runbook).

- [ ] **Step 1: Write the config**

```nginx
limit_req_zone $binary_remote_addr zone=authlimit:10m rate=5r/m;

server {
    listen 80;
    server_name team-works.example.com;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    # rate-limit the one unauthenticated endpoint (auth.md §9)
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

    # zero-cache's sync path (:4848) is added here once Phase 4 (D-2) stands
    # up the container — deliberately not present yet (design spec §4).
}
```

Note: the `proxy_set_header` lines and `server_name`/`listen` directives go beyond `deployment.md` §5's illustrative snippet (which only shows the two auth.md-specific requirements). They're standard, necessary reverse-proxy boilerplate — without `proxy_set_header Host $host`, the app would see every request as coming from `localhost`, breaking the `Origin` check and magic-link URL generation. Mention this in the PR description as a small, deliberate addition beyond the doc's literal snippet.

- [ ] **Step 2: Verify syntax with local nginx**

There's no way to test the real Certbot-managed TLS block locally, but the syntax of this file can be checked directly:

```bash
mkdir -p /tmp/nginx-check
cp deploy/nginx/team-works.conf /tmp/nginx-check/
cat > /tmp/nginx-check/nginx.test.conf <<CONF
events {}
http {
    include /tmp/nginx-check/team-works.conf;
}
CONF
nginx -t -c /tmp/nginx-check/nginx.test.conf
rm -rf /tmp/nginx-check
```
Expected: `syntax is ok` and `test is successful`.

- [ ] **Step 3: Commit**

```bash
git add deploy/nginx/team-works.conf
git commit -m "feat: add nginx reverse proxy config"
```

---

### Task 5: Environment file template

**Files:**
- Create: `deploy/env.production.example`

**Interfaces:**
- Produces: the template the operator copies to `/opt/team-works/shared/.env` (Task 6's runbook) and that Task 3's `EnvironmentFile=` points at once copied.

- [ ] **Step 1: Write the template**

```bash
# Production environment for Team Works.
# Copy to /opt/team-works/shared/.env on the VPS and fill in real values.
# This file holds placeholders only — never commit real secrets here.

DATABASE_URL=postgresql://team_works@localhost:5432/team_works
ATTACHMENTS_DIR=/var/lib/team-works/attachments

# AUTH_SECRET and ZERO_AUTH_SECRET MUST be the identical value (auth.md §2, §10).
# Generate once with: openssl rand -base64 32
AUTH_SECRET=replace-with-32-plus-byte-secret
ZERO_AUTH_SECRET=replace-with-32-plus-byte-secret

APP_URL=https://team-works.example.com

SMTP_HOST=replace-with-smtp-host
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=replace-with-smtp-user
SMTP_PASS=replace-with-smtp-password
SMTP_FROM=Team Works <noreply@team-works.example.com>
```

- [ ] **Step 2: Verify every required key from auth.md §10 is present**

Run:
```bash
for key in DATABASE_URL ATTACHMENTS_DIR AUTH_SECRET ZERO_AUTH_SECRET APP_URL SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_USER SMTP_PASS SMTP_FROM; do
  grep -q "^${key}=" deploy/env.production.example && echo "OK: $key" || echo "MISSING: $key"
done
```
Expected: `OK` for all eleven keys.

- [ ] **Step 3: Commit**

```bash
git add deploy/env.production.example
git commit -m "feat: add production env template"
```

---

### Task 6: VPS provisioning script + operator runbook

**Files:**
- Create: `scripts/provision-vps.sh`
- Note: the design spec's §6 runbook (`docs/superpowers/specs/2026-08-02-vps-provisioning-deploy-pipeline-design.md`) was already corrected during planning to add the two steps it had omitted — installing the systemd unit and the nginx site config onto the box before running Certbot. No further edit needed here; just follow it as written when writing the script's comment header.

**Interfaces:**
- Produces: the `deploy` system user, `/opt/team-works/{releases,shared}`, `/etc/sudoers.d/deploy` (consumed by Task 2's `sudo systemctl restart team-works`), `/var/lib/team-works/attachments` (consumed by `ATTACHMENTS_DIR` in Task 5), Postgres with `wal_level=logical`.

- [ ] **Step 1: Write the provisioning script**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Run once, as root, on a fresh Debian 13 (trixie) VPS.
# Safe to re-run (idempotent). Does NOT touch SSH hardening
# (PermitRootLogin / PasswordAuthentication) — that is a deliberate manual
# step, run only after `deploy` user SSH access has been verified. See the
# runbook in docs/superpowers/specs/2026-08-02-vps-provisioning-deploy-pipeline-design.md §6.

apt-get update
apt-get install -y \
  nodejs npm \
  postgresql postgresql-contrib \
  nginx \
  certbot python3-certbot-nginx \
  ufw \
  ca-certificates curl gnupg

# --- Docker (official repo, trixie codename) ---
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
ARCH=$(dpkg --print-architecture)
echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian trixie stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# --- Firewall: only 22, 80, 443 ---
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# --- deploy user: owns the app, is who GitHub Actions authenticates as ---
if ! id deploy >/dev/null 2>&1; then
  adduser --system --group --home /opt/team-works deploy
fi
mkdir -p /opt/team-works/releases /opt/team-works/shared
chown -R deploy:deploy /opt/team-works

cat > /etc/sudoers.d/deploy <<'EOF'
deploy ALL=(root) NOPASSWD: /usr/bin/systemctl restart team-works, /usr/bin/systemctl restart zero-cache
EOF
chmod 0440 /etc/sudoers.d/deploy
visudo -cf /etc/sudoers.d/deploy

# --- Postgres: enable logical replication ---
PG_CONF=$(find /etc/postgresql -maxdepth 3 -name postgresql.conf | head -n1)
if [ -z "$PG_CONF" ]; then
  echo "postgresql.conf not found under /etc/postgresql" >&2
  exit 1
fi
sed -i "s/^#\?wal_level.*/wal_level = logical/" "$PG_CONF"
systemctl restart postgresql

# --- attachments directory: outside any release tree, persistent data ---
mkdir -p /var/lib/team-works/attachments
chown deploy:deploy /var/lib/team-works/attachments

echo "Provisioning complete."
echo "Next: verify 'ssh deploy@<host>' works, THEN harden SSH by hand (see runbook §6 step 2)."
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/provision-vps.sh`

- [ ] **Step 3: Verify with shellcheck and a syntax check**

Run: `shellcheck -S warning scripts/provision-vps.sh && bash -n scripts/provision-vps.sh`
Expected: both exit 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/provision-vps.sh
git commit -m "feat: add Debian 13 VPS provisioning script"
```

---

### Task 7: GitHub Actions CI/deploy workflow

**Files:**
- Modify: `.github/workflows/ci.yml` (currently a single `verify` job — checkout, setup-node, `npm ci`, `npm run lint`, `npm run build`)

**Interfaces:**
- Consumes: `deploy.sh` at `/opt/team-works/deploy.sh` (Task 2 + Task 6's runbook step that copies it there); `DEPLOY_HOST`/`DEPLOY_USER`/`DEPLOY_SSH_KEY` GitHub Actions secrets (added by the operator, not by this task).

- [ ] **Step 1: Replace the workflow's single job with `fast` → `e2e` (stub) → `deploy`**

```yaml
name: CI

on:
  push:
    branches: ["**"]
  pull_request:
    branches: [main]

jobs:
  fast:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm

      - run: npm ci

      - run: npm run lint

      - run: npm run build

  e2e:
    needs: fast
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - run: echo "e2e - no scenarios yet, enabled once D-7 (E2E infrastructure) lands"

  deploy:
    needs: e2e
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.DEPLOY_HOST }}
          username: ${{ secrets.DEPLOY_USER }}
          key: ${{ secrets.DEPLOY_SSH_KEY }}
          script: /opt/team-works/deploy.sh
```

Renamed the job from `verify` to `fast` to match `deployment.md` §7's naming (no behavior change to its steps — same `npm ci`/`lint`/`build`). No Postgres service container and no `npm run db:migrate`/`test:unit`/`test:integration` steps yet — those don't exist until Foundation A-4/B-3 (design spec §3, approach B).

- [ ] **Step 2: Validate YAML syntax**

There's no `pyyaml`/`js-yaml`/`actionlint` installed in this environment, but Ruby ships a YAML parser in its standard library:

Run: `ruby -ryaml -e "p YAML.load_file('.github/workflows/ci.yml')" >/dev/null && echo "YAML OK"`
Expected: `YAML OK`. (Watch for the classic bug this exact check caught during design validation: an unquoted colon inside a `run:` string, e.g. `run: echo "e2e: ..."`, breaks YAML parsing because of the bare `:` followed by a space. If you need a colon inside a step's inline message, rephrase without it or quote the whole value.)

- [ ] **Step 3: Confirm the gating logic by inspection**

Confirm: `fast` has no `if:` (runs on every push and PR); `e2e` and `deploy` both carry `if: github.ref == 'refs/heads/main'`; `deploy` depends on `e2e` (not directly on `fast`), so nothing reaches the VPS without both fast checks and (once real) e2e passing.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: extend workflow to fast/e2e/deploy pipeline"
```

---

### Task 8: Reconcile `deployment.md` §2 for Debian 13

**Files:**
- Modify: `docs/deployment.md`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Add a revision note under the doc's status line**

Find:
```
_Deployment and operations runbook for v1. Companion to [team-works-concept-brief.md](./team-works-concept-brief.md), [data-model.md](./data-model.md), [auth.md](./auth.md), [attachments.md](./attachments.md) and [testing.md](./testing.md). Status: approved 2026-07-31._
```

Replace with:
```
_Deployment and operations runbook for v1. Companion to [team-works-concept-brief.md](./team-works-concept-brief.md), [data-model.md](./data-model.md), [auth.md](./auth.md), [attachments.md](./attachments.md) and [testing.md](./testing.md). Status: approved 2026-07-31._

_Revised 2026-08-02: §2's provisioning target changed from Ubuntu 22.04 LTS (or Debian 12) to Debian 13, per [the P0.1 design spec](./superpowers/specs/2026-08-02-vps-provisioning-deploy-pipeline-design.md)._
```

- [ ] **Step 2: Update §2's opening line and base-packages bullet**

Find:
```
Ubuntu 22.04 LTS (or Debian 12), assumed as a clean VPS with root SSH access initially.

1. **Base packages.** Node.js 20.x (matching local-dev.md's `.nvmrc`), PostgreSQL 15+, Docker, nginx, Certbot (`certbot` + `python3-certbot-nginx`).
```

Replace with:
```
Debian 13 (trixie), assumed as a clean VPS with root SSH access initially.

1. **Base packages.** Node.js 20.x and PostgreSQL 15+ ship natively in Debian 13's own apt repos (20.19.x and PostgreSQL 17 respectively) — `apt install nodejs npm postgresql postgresql-contrib`, no NodeSource or PGDG repo needed. Docker via its official repo (the `trixie` codename is supported directly), nginx, Certbot (`certbot` + `python3-certbot-nginx`). Automated by `scripts/provision-vps.sh`.
```

- [ ] **Step 3: Note that SSH hardening is deliberately manual**

Find:
```
3. **SSH.** Key-only auth (`PasswordAuthentication no`); disable root login once the `deploy` user (below) exists and has been verified to work.
```

Replace with:
```
3. **SSH.** Key-only auth (`PasswordAuthentication no`); disable root login once the `deploy` user (below) exists and has been verified to work. **Deliberately manual** — not part of `scripts/provision-vps.sh` — a mistake here is a lockout.
```

- [ ] **Step 4: Update the Postgres config path for Debian 13**

Find:
```
5. **Postgres.** Same steps as local-dev.md §2 — create the role and database, set `wal_level = logical` in `postgresql.conf`, restart, confirm with `SHOW wal_level`.
```

Replace with:
```
5. **Postgres.** Same steps as local-dev.md §2 — create the role and database, set `wal_level = logical` in `postgresql.conf` (Debian 13: `/etc/postgresql/17/main/postgresql.conf`), restart, confirm with `SHOW wal_level`.
```

- [ ] **Step 5: Confirm no other doc mentions an OS version**

Run: `grep -rn "Ubuntu\|Debian 12\|Debian 13" docs/*.md docs/adr/*.md`
Expected: only hits inside `docs/deployment.md` itself (the lines just edited), confirming no other doc needs a matching update.

- [ ] **Step 6: Commit**

```bash
git add docs/deployment.md
git commit -m "docs: reconcile deployment.md §2 for Debian 13"
```

---

### Task 9: Final integration pass

**Files:** none created; validates everything from Tasks 1–8 together.

- [ ] **Step 1: Run the full Biome check**

Run: `npm run check`
Expected: no errors; any auto-fixable formatting is applied and re-staged.

- [ ] **Step 2: Run the build one more time with everything in place**

Run: `npm run build`
Expected: succeeds, `/api/health` listed in the route table.

- [ ] **Step 3: Re-run every artifact's verification in sequence**

```bash
shellcheck -S warning deploy.sh scripts/provision-vps.sh
bash -n deploy.sh scripts/provision-vps.sh
ruby -ryaml -e "p YAML.load_file('.github/workflows/ci.yml')" >/dev/null && echo "YAML OK"
grep -n "Ubuntu\|Debian 12" docs/deployment.md
```
Expected: shellcheck/bash -n/YAML checks all clean. The last `grep` should match **exactly one line** — the revision note added in Task 8 Step 1, which deliberately mentions "Ubuntu 22.04 LTS (or Debian 12)" as historical context for what changed. If it matches inside §2's actual provisioning text (not the revision note), Task 8's edit didn't take — go back and fix it.

- [ ] **Step 4: Review the operator runbook one last time**

Re-read design spec §6 (the operator runbook) and confirm every file it references now exists at the path it names: `scripts/provision-vps.sh`, `deploy/nginx/team-works.conf`, `deploy/env.production.example`, `deploy.sh`, `deploy/systemd/team-works.service`.

- [ ] **Step 5: Push the branch and open a pull request**

```bash
git push -u origin HEAD
gh pr create --title "infra: provision Debian 13 VPS and wire deploy pipeline (#4)" --body "$(cat <<'EOF'
## Summary
- Provisioning script + systemd/nginx config for a Debian 13 VPS (deployment.md §2–§7)
- deploy.sh: atomic release, health-check-gated rollback
- .github/workflows/ci.yml extended to fast → e2e (stub) → deploy
- /api/health route (the one real app-code change)
- deployment.md §2 reconciled from Ubuntu 22.04/Debian 12 to Debian 13

Deliberately deferred: db:migrate, test:unit/integration, and zero-cache.service — none of the underlying scripts/schema exist yet (see design spec §3–§4). The operator runbook (design spec §6) covers the manual steps: SSH hardening, Certbot, real secrets, GitHub Actions secrets, and running the Definition-of-Done checks against the real box.

Closes #4

## Test plan
- [ ] Run scripts/provision-vps.sh on the real Debian 13 VPS
- [ ] Complete the operator runbook (design spec §6): SSH hardening, Certbot, .env, GitHub Actions secrets
- [ ] Push to main, confirm a new release directory appears and current repoints
- [ ] Confirm https://<real-domain>/api/health returns 200 over TLS
- [ ] Push a deliberately broken build, confirm current stays untouched and the site stays up
- [ ] Break /api/health deliberately, confirm auto-rollback fires within ~10s
- [ ] Confirm manual rollback (symlink swap) serves the older release
EOF
)"
```

Report the PR URL back. The Definition of Done in the issue is verified by the operator against the real box (Global Constraints, design spec §1) — this task's job ends at a mergeable, reviewed PR.
