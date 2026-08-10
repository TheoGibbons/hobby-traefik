#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Refusing to deploy over tracked changes in $repo_dir" >&2
  exit 1
fi

git pull --ff-only

if ! docker network inspect traefik-public >/dev/null 2>&1; then
  docker network create traefik-public
fi

# Ignore any accidentally copied local .env file: production always uses the
# base Compose file and its public 80/443 defaults.
compose=(docker compose --env-file /dev/null -f docker-compose.yml)
"${compose[@]}" config --quiet
"${compose[@]}" up -d --remove-orphans --wait --wait-timeout 60
"${compose[@]}" ps
