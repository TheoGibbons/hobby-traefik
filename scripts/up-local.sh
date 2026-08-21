#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

if [[ ! -f .env ]]; then
  cp .env.example .env
fi

if ! docker network inspect traefik-public >/dev/null 2>&1; then
  docker network create traefik-public
fi

docker compose config --quiet
docker compose up -d --remove-orphans --wait --wait-timeout 60
docker compose ps
