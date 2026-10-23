#!/usr/bin/env bash
# Reclaims disk from Docker leftovers that every application's deploys pile up.
# Installed by install-cron.sh to run weekly.
#
# Deliberately never touches volumes, which hold databases, or stopped
# containers, which may be stopped on purpose.
set -Eeuo pipefail

# Build cache older than a week. The recent week stays, so active projects
# still build quickly.
docker builder prune -f --filter until=168h

# Untagged images left behind when a deploy re-tags a name to a new build.
docker image prune -f
