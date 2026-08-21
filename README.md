# Shared Traefik proxy

This repository owns the single Traefik instance used by every Docker Compose
project on this machine. It runs the same way locally and on EC2:

- Traefik alone publishes the host's HTTP and HTTPS ports.
- Every public application joins the external `traefik-public` Docker network.
- Each application owns its hostname routing labels in its own repository.
- Local applications use plain HTTP at `*.localhost`; EC2 applications add a
  small production overlay for HTTPS and Let's Encrypt.

Application repositories remain usable without this stack. Their default
`docker compose up` path publishes a loopback port; Traefik networking and
labels live in an optional application overlay used only by our infrastructure.

See [playbook-traefik-integration.md](playbook-traefik-integration.md) when
converting another project.

## Repository layout

```text
docker-compose.yml         shared proxy service (production defaults)
docker-compose.local.yml   swaps in local static configuration
traefik.yml                production redirects and Let's Encrypt
traefik.local.yml          local HTTP configuration
scripts/up-local.sh        creates the network and starts local Traefik
scripts/deploy.sh          pulls and safely updates the EC2 proxy
.gitattributes             pins LF endings so Windows checkouts stay runnable
```

## Local setup

Docker must be running and the current user must have access to it.

```bash
git clone git@github.com:TheoGibbons/hobby-traefik.git ~/projects/hobby-traefik
cd ~/projects/hobby-traefik
cp .env.local.example .env
./scripts/up-local.sh
```

The `.env` file sets `COMPOSE_FILE` so ordinary `docker compose` commands use
both the base file and the local overlay. It is ignored by Git and must not be
copied to EC2.

The local dashboard is available at <http://localhost:8086/dashboard/>. It has
no password because its published dashboard port is bound to loopback only.

After this, start any integrated application and open its `*.localhost` URL.
For example, Measure the Baby uses <http://baby.localhost:8085>. The local ports
are configurable in `.env`; EC2 still defaults to public ports 80 and 443.

## First EC2 setup

Allow inbound TCP 22, 80 and 443 in the EC2 security group. Add other ports only
for protocols that do not use HTTP, and point each application's DNS record at
the instance before starting it so Let's Encrypt can validate the hostname.

Install Docker and the Compose plugin, then give the deployment user Docker
access. On Ubuntu 24.04:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

Log out and back in after changing group membership. Then clone and start the
proxy without the local `.env` file:

```bash
git clone git@github.com:TheoGibbons/hobby-traefik.git ~/projects/hobby-traefik
cd ~/projects/hobby-traefik
./scripts/deploy.sh
```

Local and production repositories use the same `~/projects/<repository-name>`
layout. Deployment workflows must use that production path.

Baby Sign Language is a deliberate exception to the HTTP proxy pattern: its app
runs on Vercel, while only PostgreSQL runs on EC2 from
`~/projects/baby-sign-language`. That database publishes its dedicated TCP port
directly and does not join the Traefik network.

The deployment script creates `traefik-public` once, validates Compose, and
waits for Traefik to become healthy. The external network survives
`docker compose down` in this or any application repository.

To inspect the dashboard from EC2, use an SSH tunnel:

```bash
ssh -L 8080:localhost:8080 ubuntu@your-server
```

Then open <http://localhost:8080/dashboard/>.

## Push-to-deploy

The workflow in `.github/workflows/deploy.yml` runs after a push to `main` and
invokes `~/projects/hobby-traefik/scripts/deploy.sh` over SSH. Configure a GitHub
environment named `production` with these secrets:

| Secret | Value |
|---|---|
| `EC2_HOST` | Public DNS name or IP of the instance |
| `EC2_USER` | Deployment user, usually `ubuntu` |
| `EC2_SSH_PRIVATE_KEY` | Private key whose public half is in the user's EC2 `authorized_keys` |
| `EC2_KNOWN_HOSTS` | Verified `known_hosts` line for `EC2_HOST` |

The EC2 checkout also needs its own read access to this GitHub repository so
`git pull --ff-only` succeeds. A repository deploy key is preferable to a
personal key with access to every repository.

The deployment intentionally stops if tracked files were edited directly on
the server. Commit changes through Git instead of letting live and local copies
drift again.

It also stops if the pulled checkout has CRLF line endings or a shell script
that lost its executable bit — the two ways a Windows commit produces a
repository that is correct in Git and broken on Ubuntu. `.gitattributes`
prevents the first for every clone; the second has no repository-wide setting,
so the check is what catches it — here, before anything is rebuilt, rather than
as `bad interpreter: /usr/bin/env bash^M` at 3am. See
[the playbook](playbook-traefik-integration.md#line-endings-and-the-executable-bit)
for the full explanation and the repair steps.

## Production behavior

Production static configuration redirects HTTP to HTTPS globally and stores
Let's Encrypt state in the `letsencrypt` named volume. Back up that volume; if
it is lost, certificates must be reissued and duplicate-certificate rate limits
can apply.

The Docker socket mounted into Traefik is a privileged interface: `:ro` does not
make the Docker API read-only. Keep the Traefik container minimal and do not run
untrusted plugins or code inside it.
