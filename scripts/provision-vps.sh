#!/usr/bin/env bash
set -euo pipefail

# Run once, as root, on a fresh Debian 13 (trixie) VPS.
# Safe to re-run (idempotent). Does NOT touch SSH hardening
# (PermitRootLogin / PasswordAuthentication) — that is a deliberate manual
# step, run only after `deploy` user SSH access has been verified. See the
# runbook in docs/superpowers/specs/2026-08-02-vps-provisioning-deploy-pipeline-design.md §6.

apt-get update
apt-get install -y \
  git sudo \
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
  adduser --system --group --home /opt/team-works --shell /bin/bash deploy
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

# --- Postgres: role + database (idempotent) ---
# No password is set here — that is a secret. The operator sets it by hand to
# match DATABASE_URL in /opt/team-works/shared/.env:
#   sudo -u postgres psql -c "ALTER ROLE team_works WITH PASSWORD '...';"
# See runbook §6.
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname = 'team_works'" | grep -q 1 || sudo -u postgres createuser team_works
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname = 'team_works'" | grep -q 1 || sudo -u postgres createdb -O team_works team_works

# --- attachments directory: outside any release tree, persistent data ---
mkdir -p /var/lib/team-works/attachments
chown deploy:deploy /var/lib/team-works/attachments

echo "Provisioning complete."
echo "Next: authorize the deploy SSH key, verify 'ssh deploy@<host>' works, THEN"
echo "harden SSH by hand (see runbook §6 steps 2-3)."
