#!/usr/bin/env bash
# Installs docker-rollout, the Docker CLI plugin application deploy scripts use
# to replace a running release without downtime. See
# playbook-zero-downtime-deploys.md.
#
# Pinned and checksummed rather than fetched from the project's main branch, so a
# deploy never runs code nobody has read. To upgrade, read the new release's
# script, then change both values together:
#   https://github.com/wowu/docker-rollout/releases
set -Eeuo pipefail

version=v0.14
sha256=cdeaba6ae9eee3b0b606286e585bbda6787283d801a6ad6d9b9d2bc347fda05b

# The deploying user's own plugin directory. Docker searches it before the
# system-wide ones, and it needs no sudo, so this can run inside a CI deploy.
plugin_dir="${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins"

if [[ "$(docker rollout --version 2>/dev/null || true)" == "docker-rollout version $version" ]]; then
  echo "docker-rollout $version is already installed."
  exit 0
fi

download="$(mktemp)"
trap 'rm -f "$download"' EXIT

curl -fsSL -o "$download" \
  "https://github.com/wowu/docker-rollout/releases/download/$version/docker-rollout"

if ! echo "$sha256  $download" | sha256sum --check --status; then
  echo "docker-rollout $version does not match its pinned checksum; not installing." >&2
  exit 1
fi

install -D -m 0755 "$download" "$plugin_dir/docker-rollout"
echo "Installed $(docker rollout --version) in $plugin_dir"
