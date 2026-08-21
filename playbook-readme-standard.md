# README standard for deployable projects

Every project on this instance answers the same three questions — how do I put it
live, how do I run it locally, how do I wire up push-to-deploy — and until this
standard existed, every project answered them with different words in a different
place. Deployment instructions sat at line 373 in one README and line 40 in another.

The goal is narrow and worth stating plainly: **a developer who reads only this
project's README knows the exact commands to run.** Not "understands the
architecture" — knows what to type.

Use [templates/README.skeleton.md](templates/README.skeleton.md) as the starting
point for a new project.

## The five sections

These H2 headings come first, in this order, immediately after the project title and
a one-paragraph description of what the project is:

```markdown
## Deploying to LIVE
## Deploying to LIVE with hobby-traefik
## Deploying Locally
## Deploying Locally with hobby-traefik
## Setup push-to-deploy
```

**Every project carries all five headings, even where one does not apply.** A reader
who learns the shape once should find the same heading in the same place in every
repository; a missing heading makes them wonder whether they missed something. Where
a section does not apply, it holds one sentence saying why, and points at the section
that does:

```markdown
## Deploying to LIVE with hobby-traefik

Not applicable — this project serves no HTTP, so Traefik has nothing to route.
Deploy it exactly as described in [Deploying to LIVE](#deploying-to-live).
```

Anything else the project has to say goes after those five.

## The command block

Each of the four deploy sections contains **one** fenced `bash` block that a
developer can paste to get running.

**Self-contained.** No "as above, but…" between the four blocks. They will repeat
each other's clone and configuration lines, and that repetition is the point — a
block that sends the reader to another section is not a block they can paste.

**Required values as comments, immediately before the editor line.** Anything the
project cannot start without is named, with how to produce it:

````markdown
```bash
git clone https://github.com/TheoGibbons/<repo>.git ~/projects/<repo>
cd ~/projects/<repo>
cp .env.production.example .env

# Set before continuing:
#   POSTGRES_PASSWORD  generate with: openssl rand -base64 24
#   APP_HOST           public DNS name, already pointed at this instance
nano .env

bash scripts/deploy.sh
```
````

**End at the deploy command.** No verification step: the scripts wait for healthy
containers and print `docker compose ps` themselves. That is a contract — see
[Scripts](#scripts) below.

**`bash script.sh`, never `./script.sh`.** A Windows commit can drop the executable
bit, and `bash` does not care. See
[Line endings and the executable bit](playbook-traefik-integration.md#line-endings-and-the-executable-bit).

**Absolute clone path.** Always `~/projects/<repository-name>`, because the deploy
workflow depends on it.

## What each of the four means

| Section | Proxy | Where it listens |
|---|---|---|
| Deploying to LIVE | none | Port 80, plain HTTP, operator brings their own TLS |
| Deploying to LIVE with hobby-traefik | shared Traefik | 443 with Let's Encrypt, via `traefik-public` |
| Deploying Locally | none | Loopback port, no DNS, no shared network |
| Deploying Locally with hobby-traefik | shared Traefik | `*.localhost` on the local proxy port |

**Standalone LIVE should cost no new Compose file.** Most projects already publish
`'${APP_BIND:-127.0.0.1}:${APP_PORT:-3000}:3000'` in `docker-compose.override.yml`,
so `APP_BIND=0.0.0.0` and `APP_PORT=80` in `.env` is the entire difference. Reach for
a new overlay only when environment values genuinely cannot express it.

Say plainly that TLS is the operator's job in standalone LIVE, and name the usual
options (Cloudflare, nginx, Caddy) without building any of them.

## Scripts

Standardised names, because the four blocks should differ only where the projects
genuinely differ:

| Script | Purpose |
|---|---|
| `scripts/deploy.sh` | LIVE. Refuses a dirty tree, `git pull --ff-only`, validates, builds, waits for healthy |
| `scripts/up-local.sh` | Local, standalone |
| `scripts/up-local-traefik.sh` | Local, through the shared proxy |

Only create `up-local-traefik.sh` where the project actually has a Traefik overlay.

**Every script ends healthy or fails.** Because the README has no verification step,
each script must finish with `up -d --wait` (or an equivalent poll) and then
`docker compose ps`. A script that returns 0 while a container crash-loops breaks the
contract the standard depends on.

## Environment files

| File | Purpose |
|---|---|
| `.env.example` | Standalone defaults, safe to run as-is locally |
| `.env.production.example` | LIVE values; required secrets deliberately **blank** |
| `.env.traefik.example` | Hostname and proxy settings, where a Traefik overlay exists |

Never ship a working placeholder for a secret — a password that happens to work is
how a weak password reaches production. Leave it blank and mark the variable required
with `${VAR:?message}` so `docker compose config` fails before anything is built. See
[Required variables](playbook-traefik-integration.md#required-variables).

## Push-to-deploy

Identical wording in every project. Two parts, and the split matters because the
first is done **once for the whole server** and people keep repeating it per project.

### Part 1 — once per server

The EC2 box needs to read GitHub so `git pull --ff-only` works. Use one fine-grained
PAT in a credential helper, covering every private repository over the HTTPS remotes
already in use. Public repositories need no credential at all.

**Why not a deploy key:** a deploy key is bound to a single repository, and GitHub
rejects the same public key on a second one with "Key is already in use". One key for
every project is not a preference that was rejected, it is not possible. A PAT has no
such restriction, and neither would a machine user.

### Part 2 — once per repository

The four `production` environment secrets. **The same EC2 keypair is reused across
every project** — only the secrets have to be created again, and `gh secret set`
makes that one paste rather than sixteen form fields.

| Secret | Value |
|---|---|
| `EC2_HOST` | Public DNS name or IP of the instance |
| `EC2_USER` | Deployment user, usually `ubuntu` |
| `EC2_SSH_PRIVATE_KEY` | Private key whose public half is in the instance's `authorized_keys` |
| `EC2_KNOWN_HOSTS` | Verified `known_hosts` line for `EC2_HOST` |

## Databases

Every project with a database publishes it on a host port so a client can reach it,
restricted by an EC2 security-group rule. The LIVE sections carry the rule, and say
why the security group is the enforcement boundary: Docker publishes ports by writing
DNAT rules straight into iptables, which bypasses host firewalls such as `ufw`.

Allocated ports are listed under the host contract in
[playbook-traefik-integration.md](playbook-traefik-integration.md).

## Standalone, and no links into this repository

Two independent requirements that pull the same way:

- **Projects must work without hobby-traefik.** The standalone sections are the path
  an outside contributor takes, and they must be complete.
- **Projects may name this repository but must not link to files inside it.** A
  reader who cloned one project has no `../hobby-traefik/` on disk, so
  `../hobby-traefik/README.md` is a broken link for everyone but us. Inline what the
  reader needs.

The exception is this repository's own documents, which link to each other freely.
hobby-traefik is the store of runbooks; the projects are standalone consumers of it.
