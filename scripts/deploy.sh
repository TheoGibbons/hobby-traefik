#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Refusing to deploy over tracked changes in $repo_dir" >&2
  exit 1
fi

git pull --ff-only

# What we just pulled has to survive a Windows checkout. A CR in a shell script
# fails as `bad interpreter: ...^M` or `set: pipefail: invalid option name`,
# neither of which names line endings; a lost mode bit fails as `Permission
# denied`. Check here, where the previous release is still serving and nothing
# has been rebuilt yet. `|| true` because grep and awk exit non-zero on no
# match, which is the healthy case.
crlf="$(git ls-files --eol -- '*.sh' | grep -E 'w/(crlf|mixed)' || true)"
if [[ -n "$crlf" ]]; then
  echo "CRLF line endings in tracked scripts:" >&2
  echo "$crlf" >&2
  echo "Commit a .gitattributes, then: git add --renormalize . && git commit" >&2
  exit 1
fi

not_exec="$(git ls-files -s -- '*.sh' | awk '$1 != "100755" {print $4}' || true)"
if [[ -n "$not_exec" ]]; then
  echo "Tracked scripts are not executable:" >&2
  echo "$not_exec" >&2
  echo "Fix with: git update-index --chmod=+x <file>" >&2
  exit 1
fi

if ! docker network inspect traefik-public >/dev/null 2>&1; then
  docker network create traefik-public
fi

# Ignore any accidentally copied local .env file: production always uses the
# base Compose file and its public 80/443 defaults.
compose=(docker compose --env-file /dev/null -f docker-compose.yml)
"${compose[@]}" config --quiet
"${compose[@]}" up -d --remove-orphans --wait --wait-timeout 60
"${compose[@]}" ps
