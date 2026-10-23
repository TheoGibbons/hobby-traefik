#!/usr/bin/env bash
# Installs the host's weekly maintenance jobs into the deploying user's crontab.
# Idempotent: the block between the markers is replaced on every run, and the
# rest of the crontab is left alone. Run by deploy.sh.
#
# Sundays, at a quiet hour:
#   04:00  docker-cleanup.sh       build cache and untagged images
#   04:15  prune-stale-certs.sh    certificates for hostnames no longer served
#                                  (restarts Traefik for a few seconds, and only
#                                  when there is something to remove)
#
# Output goes to syslog: journalctl -t hobby-traefik
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
begin='# BEGIN hobby-traefik (managed by scripts/install-cron.sh)'
end='# END hobby-traefik'

block="$begin
0 4 * * 0 bash $repo_dir/scripts/docker-cleanup.sh 2>&1 | logger -t hobby-traefik
15 4 * * 0 bash $repo_dir/scripts/prune-stale-certs.sh 2>&1 | logger -t hobby-traefik
$end"

current="$(crontab -l 2>/dev/null || true)"
others="$(awk -v b="$begin" -v e="$end" '$0 == b {skip = 1} !skip {print} $0 == e {skip = 0}' <<<"$current")"
printf '%s\n' "${others:+$others}" "$block" | sed '/./,$!d' | crontab -
