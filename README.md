# Shared Traefik proxy

The single Traefik instance used by every Docker Compose project on this machine. It
runs the same way locally and on EC2: Traefik alone publishes the host's HTTP and
HTTPS ports, every public application joins the external `traefik-public` network, and
each application owns its own routing labels in its own repository.

This repository is also the store of runbooks the other projects follow:

| Document | Purpose |
|---|---|
| [playbook-traefik-integration.md](playbook-traefik-integration.md) | Adding a project to the shared proxy: overlays, ports, an optional password gate, required variables, line endings; and removing one |
| [playbook-zero-downtime-deploys.md](playbook-zero-downtime-deploys.md) | Making a project's LIVE deploy swap releases without taking the site down |
| [playbook-readme-standard.md](playbook-readme-standard.md) | The five deployment sections every project README carries |
| [templates/README.skeleton.md](templates/README.skeleton.md) | Fill-in-the-blanks README for a new project |

Application repositories stay usable without this stack. Their default
`docker compose up` path publishes a loopback port; Traefik networking and labels live
in an optional overlay used only by our infrastructure.

## Deploying to LIVE

Allow inbound TCP 22, 80 and 443 in the security group. Add other ports only for
protocols that do not use HTTP, and point each application's DNS record at the
instance before starting it so Let's Encrypt can validate the hostname.

Install Docker and the Compose plugin, then give the deployment user Docker access.
On Ubuntu 24.04:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Log out and back in after changing group membership, then:

```bash
git clone https://github.com/TheoGibbons/hobby-traefik.git ~/projects/hobby-traefik
cd ~/projects/hobby-traefik

# Set before continuing:
#   the ACME contact address in traefik.yml — Let's Encrypt sends expiry
#   warnings there, so it must be an address you actually read
nano traefik.yml

bash scripts/deploy.sh
```

**Do not create a `.env` here on the server.** It exists only to move the proxy onto
loopback ports for local development; on the server the defaults are the public 80 and
443. The deploy script ignores any `.env` that gets copied over by accident.

The script creates `traefik-public` once, installs the pinned
[docker-rollout](https://github.com/wowu/docker-rollout) plugin that application deploys
use to swap releases without downtime, validates Compose, and waits for Traefik to
become healthy. The external network survives `docker compose down` in this or any
application repository.

Deploy this before any application on a new server. Application deploy scripts stop
with an explanation when either the network or the plugin is missing, and rerunning this
script supplies both.

## Deploying to LIVE with hobby-traefik

Not applicable — this *is* hobby-traefik. See [Deploying to LIVE](#deploying-to-live).

## Deploying Locally

```bash
git clone https://github.com/TheoGibbons/hobby-traefik.git ~/projects/hobby-traefik
cd ~/projects/hobby-traefik
cp .env.example .env

bash scripts/up-local.sh
```

`.env` sets `COMPOSE_FILE` so ordinary `docker compose` commands pick up both the base
file and the local overlay, and moves the published ports onto loopback so they cannot
collide with anything else on the machine. It is gitignored and must never be copied to
the server.

The dashboard is at <http://localhost:8086/dashboard/> — the trailing slash matters. It
has no password because its port is bound to loopback only.

After this, start any integrated application and open its `*.localhost` URL; for
example Measure the Baby at <http://baby.localhost:8085>.

## Deploying Locally with hobby-traefik

Not applicable — this *is* hobby-traefik. See [Deploying Locally](#deploying-locally).

## Setup push-to-deploy

A push to `main` runs `.github/workflows/deploy.yml`, which SSHes to the instance and
runs `bash scripts/deploy.sh` in `~/projects/hobby-traefik`.

**Part 1 — once per server, not once per project.** The instance needs to read GitHub
so `git pull --ff-only` works. Skip this if another project on the same box has
already done it; skip it entirely if this repository is public.

```bash
# On the EC2 instance. Create a fine-grained PAT with Contents: Read-only,
# scoped to the repositories this box deploys:
#   https://github.com/settings/personal-access-tokens
read -rsp 'PAT: ' PAT && echo

git config --global credential.helper store
printf 'https://x-access-token:%s@github.com\n' "$PAT" > ~/.git-credentials
chmod 600 ~/.git-credentials
```

A deploy key cannot be shared between projects: GitHub binds one to a single
repository and rejects the same key on a second with "Key is already in use". One PAT
covers every repository on the box, which is the whole reason to prefer it.

**Part 2 — once per repository.** The same EC2 keypair is reused for every project,
so only these four secrets are new. The block creates the `production` environment
they live in, and stops before setting anything if the instance's host key is not
the one you expect:

```bash
# Locally, from inside this repository's checkout, with the gh CLI authenticated.
# <ed25519-fingerprint> is the SHA256:... this prints on the instance:
#   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
(
  set -euo pipefail
  host='<ec2-public-dns>'
  known_hosts="$(ssh-keyscan -H "$host" 2>/dev/null)"
  # GitHub Actions trusts whatever goes into EC2_KNOWN_HOSTS, so check it
  # against the instance's own fingerprint rather than the network's word.
  if ! ssh-keygen -lf - <<<"$known_hosts" | grep -qF '<ed25519-fingerprint>'; then
    echo "The host key for $host does not match; nothing was set." >&2
    exit 1
  fi
  # The workflow deploys from this environment; creating it again is a no-op.
  gh api -X PUT 'repos/{owner}/{repo}/environments/production' --silent
  gh secret set EC2_HOST            --env production --body "$host"
  gh secret set EC2_USER            --env production --body 'ubuntu'
  gh secret set EC2_SSH_PRIVATE_KEY --env production < ~/.ssh/<ec2-deploy-key>
  gh secret set EC2_KNOWN_HOSTS     --env production --body "$known_hosts"
)
```

The deploy stops if tracked files were edited directly on the server, and if the pulled
checkout has CRLF line endings or a script that lost its executable bit. Commit changes
through Git instead of letting the live and local copies drift.

## What it is

One proxy per machine, owned here, so that adding an application never means editing
this repository. Traefik discovers applications by watching Docker for containers
wearing routing labels; nothing in this directory changes when an application is added,
removed or redeployed.

```text
docker-compose.yml         shared proxy service (production defaults)
docker-compose.local.yml   swaps in local static configuration
traefik.yml                production redirects and Let's Encrypt
traefik.local.yml          local HTTP configuration
scripts/up-local.sh        creates the network and starts local Traefik
scripts/deploy.sh          pulls and safely updates the proxy on the server
scripts/install-docker-rollout.sh
                           pinned, checksummed zero-downtime deploy plugin
scripts/install-cron.sh    installs the weekly jobs below; run by deploy.sh
scripts/docker-cleanup.sh  weekly: old build cache and untagged images
scripts/prune-stale-certs.sh
                           weekly: certificates for hostnames no longer served
.gitattributes             pins LF endings so Windows checkouts stay runnable
```

## How it works

Static configuration is read once at startup, so changes to `traefik.yml` need a
container restart. Per-application routing is not here: it lives in labels on each
application's own containers and is picked up live.

Production redirects HTTP to HTTPS globally and stores Let's Encrypt state in the
`letsencrypt` named volume. Local uses plain HTTP at `*.localhost`, which needs neither
public DNS nor certificates.

Not every project uses the proxy. Baby Sign Language runs its app on Vercel and only
PostgreSQL on the instance, and brains-v2-scraper serves no HTTP at all — both publish
their own TCP ports and never join `traefik-public`. That is the documented pattern for
non-HTTP services, not an exception to it.

## Operating it

Inspect the dashboard on the server over an SSH tunnel:

```bash
ssh -L 8080:localhost:8080 ubuntu@your-server
```

Then open <http://localhost:8080/dashboard/>.

`scripts/deploy.sh` installs two weekly jobs into the deploying user's crontab,
both on Sunday mornings with output in `journalctl -t hobby-traefik`:

- **04:00 `scripts/docker-cleanup.sh`** removes build cache older than a week and
  untagged images. It never touches volumes or stopped containers.
- **04:15 `scripts/prune-stale-certs.sh`** removes certificates for hostnames no
  application serves any more, from removed applications or changed URLs.
  Traefik otherwise keeps renewing them, and every renewal fails once the DNS
  record is gone. A certificate goes only when no router uses its hostname
  *and* its DNS no longer points at this server, so an application that is
  mid-deploy or down keeps its certificate. When something is removed, Traefik
  restarts for a few seconds, and the previous `acme.json` is kept in
  `~/.local/state/hobby-traefik/acme-backups` (the last five). Run it with
  `--dry-run` to see what it would remove.

Back up the `letsencrypt` volume. If it is lost, certificates must be reissued and
Let's Encrypt's duplicate-certificate rate limits — five per week — can apply.

## Security notes

The Docker socket mounted into Traefik is a privileged interface: `:ro` does not make
the Docker API read-only, and access to that socket is effectively root on the host.
Keep this container minimal and never run untrusted plugins or code inside it.

The dashboard runs without authentication, which is safe only because its entry point
is published to `127.0.0.1`. Never publish `:8080` to `0.0.0.0`.
