#!/usr/bin/env bash
# Removes certificates for hostnames this server no longer serves from Traefik's
# acme.json.
#
# Traefik renews every certificate in acme.json, whether or not a router still
# uses its hostname. Once an application is removed, or moves to another URL,
# and its DNS record goes, every renewal fails with NXDOMAIN and counts against
# Let's Encrypt's rate limits. Installed by install-cron.sh to run weekly.
#
# A certificate is removed only when, for every name on it, both hold:
#   - no Traefik router uses the name, and
#   - its DNS does not point at this server (the addresses the live hostnames
#     resolve to).
# The DNS check keeps the certificate of an application that is mid-deploy or
# has crashed: its router is missing for the moment, but its DNS still points
# here. A certificate whose DNS points elsewhere could never renew anyway.
#
# When nothing is stale it changes nothing. Otherwise it backs up acme.json,
# stops Traefik for a few seconds (a running Traefik writes its in-memory copy
# back over any edit), removes the stale entries and starts it again.
#
# Usage:
#   bash scripts/prune-stale-certs.sh                  remove stale certificates
#   bash scripts/prune-stale-certs.sh --dry-run        only report them
#   bash scripts/prune-stale-certs.sh --dry-run FILE   report against a copy of acme.json
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

dry_run=0
acme_from=""
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=1
  acme_from="${2:-}"
elif [[ -n "${1:-}" ]]; then
  echo "Unknown argument: $1" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required: sudo apt-get install -y jq" >&2
  exit 1
fi

# The dashboard API, published to loopback only in docker-compose.yml.
api="${TRAEFIK_API:-http://127.0.0.1:8080}"
compose=(docker compose --env-file /dev/null -f docker-compose.yml)
backup_dir="$HOME/.local/state/hobby-traefik/acme-backups"
keep_backups=5

resolve() { getent ahosts "$1" | awk '{print $1}' | sort -u || true; }

# Every hostname a router matches, from both Host(`a`) and Host(`a`, `b`).
live_hosts="$(curl -fsS -m 10 "$api/api/http/routers?per_page=1000" \
  | jq -r '.[].rule // empty' \
  | grep -oE 'Host\([^)]*\)' | grep -oE '`[^`]+`' | tr -d '`' | sort -u || true)"
if [[ -z "$live_hosts" ]]; then
  # An empty list would make every certificate look stale.
  echo "Traefik reports no Host routers at $api; refusing to judge certificates." >&2
  exit 1
fi

server_ips="$(while read -r host; do resolve "$host"; done <<<"$live_hosts" | sort -u)"
if [[ -z "$server_ips" ]]; then
  echo "None of the live hostnames resolve; refusing to judge certificates." >&2
  exit 1
fi

read_acme() {
  if [[ -n "$acme_from" ]]; then
    cat "$acme_from"
  else
    "${compose[@]}" exec -T traefik cat /letsencrypt/acme.json
  fi
}

stale=()
while read -r cert; do
  [[ -z "$cert" ]] && continue
  keep=0
  for name in $cert; do
    if grep -qxF "$name" <<<"$live_hosts"; then keep=1; break; fi
    if [[ -n "$(comm -12 <(resolve "$name") <(echo "$server_ips"))" ]]; then keep=1; break; fi
  done
  (( keep )) || stale+=("${cert%% *}")
done < <(read_acme | jq -r '.[].Certificates[]? | [.domain.main] + (.domain.sans // []) | join(" ")')

if (( ${#stale[@]} == 0 )); then
  echo "No stale certificates."
  exit 0
fi

echo "Stale certificates: ${stale[*]}"
if (( dry_run )); then
  exit 0
fi

stale_json="$(printf '%s\n' "${stale[@]}" | jq -R . | jq -s .)"
work="$(mktemp -d)"
# Whatever happens below, Traefik must not be left stopped.
trap '"${compose[@]}" start traefik >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

umask 077
mkdir -p "$backup_dir"
"${compose[@]}" stop traefik
container="$("${compose[@]}" ps --all --quiet traefik)"

# Copied out after the stop, so the edit starts from Traefik's final write.
docker cp "$container:/letsencrypt/acme.json" "$work/acme.json"
cp -p "$work/acme.json" "$backup_dir/acme.json.$(date +%Y%m%d-%H%M%S)"

jq --argjson stale "$stale_json" \
  'map_values(if .Certificates then .Certificates |= map(select(.domain.main as $m | $stale | index($m) | not)) else . end)' \
  "$work/acme.json" >"$work/acme.json.new"

before="$(jq '[.[].Certificates[]?] | length' "$work/acme.json")"
after="$(jq '[.[].Certificates[]?] | length' "$work/acme.json.new")"
if (( after != before - ${#stale[@]} )) || ! jq -e 'all(.[]; .Account != null)' "$work/acme.json.new" >/dev/null; then
  echo "Edited acme.json failed its checks ($before -> $after certificates); left unchanged." >&2
  exit 1
fi

chmod 600 "$work/acme.json.new"
docker cp "$work/acme.json.new" "$container:/letsencrypt/acme.json"
"${compose[@]}" up -d --no-recreate --wait --wait-timeout 60 traefik
echo "Removed ${#stale[@]} certificate(s); $after remain. Backup in $backup_dir."

# Backups hold private keys; keep only the most recent few.
ls -1t "$backup_dir"/acme.json.* | tail -n +$((keep_backups + 1)) | xargs -r rm --
