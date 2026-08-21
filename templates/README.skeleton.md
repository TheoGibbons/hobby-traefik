# <Project name>

<One paragraph: what this is and who it is for. No history, no architecture — the
reader is here to deploy it.>

## Deploying to LIVE

<One or two sentences. State that this path needs nothing but Docker, and that TLS
is the operator's job — put Cloudflare, nginx or Caddy in front of port 80.>

```bash
git clone https://github.com/<owner>/<repo>.git ~/projects/<repo>
cd ~/projects/<repo>
cp .env.production.example .env

# Set before continuing:
#   <VAR>  <what it is, and how to generate it>
#   APP_BIND=0.0.0.0   APP_PORT=80   <- publishes publicly instead of on loopback
nano .env

docker compose up -d --build
```

<Security-group table if any port is published. Delete if nothing is exposed.>

| TCP port | Allowed source | Purpose |
|---|---|---|
| 22 | Administrator IP | SSH and deployment |
| 80 | Public internet | Application |

## Deploying to LIVE with hobby-traefik

<Delete this whole block if the project serves no HTTP, and say so in one sentence
instead — see the README standard.>

Requires the shared proxy. If it is not running on this instance yet:

```bash
git clone https://github.com/TheoGibbons/hobby-traefik.git ~/projects/hobby-traefik
cd ~/projects/hobby-traefik
bash scripts/deploy.sh
```

Point `<APP_HOST>`'s DNS record at this instance **before** deploying, or Let's
Encrypt cannot validate it. Then:

```bash
git clone https://github.com/<owner>/<repo>.git ~/projects/<repo>
cd ~/projects/<repo>
cp .env.production.example .env

# Set before continuing:
#   APP_HOST  public DNS name, already pointing at this instance
#   <VAR>     <what it is, and how to generate it>
nano .env

bash scripts/deploy.sh
```

## Deploying Locally

Needs only Docker. Nothing is published beyond loopback.

```bash
git clone https://github.com/<owner>/<repo>.git ~/projects/<repo>
cd ~/projects/<repo>
cp .env.example .env

bash scripts/up-local.sh
```

Open <http://localhost:PORT>.

## Deploying Locally with hobby-traefik

Start the shared proxy first if it is not already running:

```bash
git clone https://github.com/TheoGibbons/hobby-traefik.git ~/projects/hobby-traefik
cd ~/projects/hobby-traefik
cp .env.example .env
bash scripts/up-local.sh
```

Then:

```bash
git clone https://github.com/<owner>/<repo>.git ~/projects/<repo>
cd ~/projects/<repo>
cp .env.traefik.example .env

bash scripts/up-local-traefik.sh
```

Open <http://HOST.localhost:8085>.

## Setup push-to-deploy

A push to `main` deploys to EC2 through `.github/workflows/deploy.yml`.

**Part 1 — once per server, not once per project.** Skip if another project on this
instance has already done it. Public repositories can skip it entirely.

```bash
# On the EC2 instance. Create a fine-grained PAT with Contents: Read-only,
# scoped to the repositories this box deploys:
#   https://github.com/settings/personal-access-tokens
read -rsp 'PAT: ' PAT && echo

git config --global credential.helper store
printf 'https://x-access-token:%s@github.com\n' "$PAT" > ~/.git-credentials
chmod 600 ~/.git-credentials
```

A deploy key cannot be shared: GitHub binds one to a single repository and rejects
the same key on a second with "Key is already in use". The PAT has no such limit.

**Part 2 — once per repository.** The same EC2 keypair is reused for every project,
so only these four secrets are new:

```bash
# Locally, with the gh CLI authenticated:
gh secret set EC2_HOST            --env production --body '<ec2-public-dns>'
gh secret set EC2_USER            --env production --body 'ubuntu'
gh secret set EC2_SSH_PRIVATE_KEY --env production < ~/.ssh/<ec2-deploy-key>
gh secret set EC2_KNOWN_HOSTS     --env production \
  --body "$(ssh-keyscan -H <ec2-public-dns> 2>/dev/null)"
```

The deploy stops rather than overwrite tracked files edited directly on the server.
Commit through Git instead of letting the live and local copies drift.

## What it is

<Why this project exists. The reasoning a newcomer cannot get from the code.>

## How it works

<Architecture, data flow, the decisions worth knowing.>

## Configuration

<Environment variables that matter, and what happens if they are wrong.>

## Operating it

<Day-two commands: logs, backups, one-off tasks, database access.>

## Security notes

<What is exposed, what protects it, what the operator must not do.>

## Development

<Running tests, working outside Docker, contributing.>
