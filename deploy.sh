#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/vespaiach/team-works.git"
BASE=/opt/team-works

# -L guard matters: GNU `readlink -f` on a nonexistent `current` still exits 0
# and echoes the literal path, which would make PREV non-empty on a first-ever
# deploy and produce a self-referential `current -> current` symlink on rollback.
PREV=$([ -L "$BASE/current" ] && readlink -f "$BASE/current" || true)
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
  if [ -n "$PREV" ] && [ -d "$PREV" ]; then
    echo "health check failed, rolling back to $PREV"
    ln -sfn "$PREV" "$BASE/current"
    sudo systemctl restart team-works
  else
    echo "health check failed and there is no previous release to roll back to"
    rm -f "$BASE/current"
  fi
  exit 1
fi

# keep the 5 most recent releases, prune the rest
cd "$BASE/releases" || exit 1
ls -1t | tail -n +6 | xargs -r rm -rf
