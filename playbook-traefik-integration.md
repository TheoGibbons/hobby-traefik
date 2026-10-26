# Optional Traefik integration playbook

Use this file as the contract when adding another Docker Compose project to the
shared proxy. It is specific enough to hand to an LLM with the target repository.

## Goals

- The open-source/default experience must not require Traefik or a pre-existing
  Docker network.
- `docker compose up -d --build` must expose the application on a loopback port.
- Our local and EC2 deployments must use the same optional Traefik overlay.
- Production differences must be limited to hostname, secrets, and TLS policy.

## Files in an application repository

| File | Purpose |
|---|---|
| `docker-compose.yml` | Proxy-agnostic services, volumes and health checks |
| `docker-compose.override.yml` | Automatically loaded standalone host port |
| `docker-compose.traefik.yml` | Optional shared network and HTTP routing labels |
| `docker-compose.prod.yml` | HTTPS, secure-cookie and other production-only settings |
| `.gitattributes` | Forces LF endings so Windows checkouts produce runnable scripts |

## Host contract for our deployments

- The proxy is managed by `~/projects/hobby-traefik`.
- Local and production application checkouts use `~/projects/<repository-name>`.
  The deployment workflow must use that production path on EC2.
- The external Docker network is always named `traefik-public`.
- Local HTTP uses the `web` entry point and a unique `*.localhost` hostname.
- Production HTTPS uses the `websecure` entry point and the `letsencrypt`
  certificate resolver.
- In production, only Traefik publishes host ports 80 and 443.
- Documented non-HTTP services may still publish host ports. For example, SMTP
  can be intentionally public while a remotely accessible database must be
  protected by a source-restricted cloud firewall/security-group rule.
- Every published host port is unique across the instance, split into a
  `${X_BIND:-127.0.0.1}:${X_PORT:-nnnn}:nnnn` pair so a local checkout exposes
  nothing and only production widens the bind address. Record new allocations
  here, because a collision surfaces as a container that will not start:

  | Port | Owner | Notes |
  |---|---|---|
  | 80, 443 | hobby-traefik | The only public HTTP ports on the instance |
  | 8080 | hobby-traefik | Dashboard, loopback only, reached over SSH |
  | 2525 | sink-mailer | SMTP ingest, intentionally public |
  | 3083 | shred-link | HTTP, loopback only unless a standalone LIVE run widens it |
  | 3084 | mysql-browser | Marketing site, loopback only unless a standalone LIVE run widens it |
  | 3085 | reelmarks | HTTP, loopback only unless a standalone LIVE run widens it |
  | 3087 | dishly | HTTP, loopback only unless a standalone LIVE run widens it |
  | 5434 | sink-mailer | Postgres, source-restricted |
  | 5436 | baby-sign-language | Postgres, source-restricted, TLS + pg_hba |
  | 5437 | brains-v2-scraper | Postgres, source-restricted |
  | 5441 | dishly | Postgres, source-restricted |
- Router, service and middleware names must be globally unique. Prefix all of
  them with the repository name.
- Databases and private workers do not join `traefik-public` and never receive
  `traefik.enable=true`.

## Changes to make

1. Keep the base Compose file free of Traefik labels, external networks, public
   hostnames and TLS assumptions.
2. Put the standalone loopback port only in `docker-compose.override.yml`.
   Required non-HTTP host ports belong in the base file when they must remain
   available in standalone and Traefik modes.
3. Put the shared network and common routing labels only in
   `docker-compose.traefik.yml`.
4. Put TLS and secure-cookie overrides only in `docker-compose.prod.yml`.
5. Document standalone settings in `.env.example`, local proxy settings in
   `.env.traefik.example`, and production settings in
   `.env.production.example`. Never commit the actual `.env` or secrets.
6. Make local and deployment scripts pass all required `-f` files explicitly.
   Explicit file selection intentionally prevents Compose from automatically
   loading the standalone override.
7. Add a deployment script that pulls with `--ff-only`, validates Compose,
   rebuilds, and waits for healthy containers. Public web services swap
   releases with `docker rollout` rather than `up`, so a deploy does not take the
   site down; follow [playbook-zero-downtime-deploys.md](playbook-zero-downtime-deploys.md).
8. Add a GitHub Actions workflow that SSHes to the EC2 checkout and invokes the
   deployment script. The server checkout remains the deployment source.
9. Commit a `.gitattributes` that pins LF, record the executable bit through
   Git, and invoke scripts as `bash script.sh` so neither can break a deploy.
   See "Line endings and the executable bit" below.
10. Mark every variable that has no safe default as required with `${VAR:?...}`
    so a missing secret fails `docker compose config` instead of the container.
    See "Required variables" below.

## Base pattern

Replace `my-app` and port `3000` with values from the target project.

```yaml
name: my-app

services:
  app:
    build: .
    restart: unless-stopped
    expose:
      - '3000'
```

Never give a Traefik-routed service a `container_name`. A zero-downtime deploy
runs two copies of it for a few seconds, and they cannot share a fixed name.

## Standalone override pattern

Docker Compose automatically loads this file when a user runs an ordinary
`docker compose` command.

```yaml
# docker-compose.override.yml
services:
  app:
    ports:
      - '${APP_BIND:-127.0.0.1}:${APP_PORT:-3000}:3000'
```

## Traefik overlay pattern

Use mapping-style labels so the production overlay merges predictably.

```yaml
# docker-compose.traefik.yml
services:
  app:
    networks:
      - default
      - traefik-public
    labels:
      traefik.enable: 'true'
      traefik.docker.network: traefik-public
      traefik.http.routers.my-app.rule: 'Host(`${APP_HOST:?Set APP_HOST in .env}`)'
      traefik.http.routers.my-app.entrypoints: web
      traefik.http.services.my-app.loadbalancer.server.port: '3000'

networks:
  traefik-public:
    external: true
```

For a single-container application, the `default` network may be omitted.
Multi-service applications should keep backend communication on `default` and
attach only the public web service to both networks.

## Production overlay pattern

```yaml
# docker-compose.prod.yml
services:
  app:
    labels:
      traefik.http.routers.my-app.entrypoints: websecure
      traefik.http.routers.my-app.tls: 'true'
      traefik.http.routers.my-app.tls.certresolver: letsencrypt
```

## Optional password gate

A project that should not be public, such as a staging copy or a private tool,
can sit behind the browser's username and password prompt: the equivalent of
nginx's `auth_basic` with an `htpasswd` file. Traefik's `basicAuth` middleware
does it with labels on the application's own container, so this repository
still needs no change.

Put it in `docker-compose.prod.yml` only, beside the TLS labels. Basic auth
resends the password with every request, merely base64-encoded, and production
is the one mode where every request is HTTPS. The local `*.localhost` route and
the standalone loopback port stay open.

```yaml
# docker-compose.prod.yml
services:
  app:
    labels:
      traefik.http.routers.my-app.middlewares: my-app-auth
      traefik.http.middlewares.my-app-auth.basicauth.users: '${APP_BASIC_AUTH_USERS:?set APP_BASIC_AUTH_USERS in .env}'
      # The application never sees the password.
      traefik.http.middlewares.my-app-auth.basicauth.removeheader: 'true'
```

Generate an entry on any machine with Docker. It prompts for the password, which
keeps it out of shell history, and prints a bcrypt `admin:$2y$05$…` line:

```bash
docker run --rm -it httpd:2.4-alpine htpasswd -nB admin
```

Put it in the server's `.env` **in single quotes**, comma-separating users:

```bash
APP_BASIC_AUTH_USERS='admin:$2y$05$…,alice:$2y$05$…'
```

Leave it blank in `.env.production.example`, so a missing value fails
`docker compose config` like any other required secret.

Things to watch:

- **Single quotes, or every login fails.** Compose interpolates unquoted and
  double-quoted `.env` values, so each `$…` in the hash is read as a variable
  and replaced with nothing. Validation still passes, Traefik loads the mangled
  hash, and every login, the correct one included, is `401`. The only sign is a
  run of warnings from `docker compose config` such as
  `The "apr1" variable is not set. Defaulting to a blank string.` Never write
  the hash into a Compose file instead: every `$` would need doubling, and it is
  a secret.
- **`middlewares` is one list.** The production overlay replaces the router's
  whole `middlewares` label, so repeat any that the Traefik overlay already
  sets: `my-app-retry,my-app-auth`.
- **Health checks are unaffected; probes from outside are not.** Docker health
  checks run inside the container and never pass through Traefik, so
  zero-downtime deploys work unchanged. Anything that requests the public URL,
  such as the checklist below, the curl loop in the zero-downtime playbook or an
  uptime monitor, gets `401` unless it sends `-u <user>:<password>`.
- **It is a gate, not an account system.** There is no logout, because the
  browser keeps the credentials until it closes, and no lockout or rate limit,
  so use a long random password. An application whose clients send their own
  `Authorization` header, such as bearer tokens for an API, cannot sit behind
  it: the header holds one credential, and the gate consumes it.

## Commands

Standalone users need only:

```bash
docker compose up -d --build
```

Our local proxy mode explicitly skips the automatic standalone override:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.traefik.yml \
  up -d --build
```

Production adds the TLS overlay:

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.traefik.yml \
  -f docker-compose.prod.yml \
  up -d --build
```

## Required variables

An example `.env` ships required secrets blank, because a placeholder that
happens to work is how a weak password reaches production. Blank values must
therefore fail loudly, and the useful place to fail is the validation step the
deployment script already runs — before anything is built, while the previous
release is still serving.

Compose's `${VAR:?message}` does exactly that. Use it for every variable with no
safe default, and `${VAR:-default}` for every variable that has one:

```yaml
environment:
  POSTGRES_USER: ${POSTGRES_USER:?set POSTGRES_USER in .env}
  POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set a non-empty POSTGRES_PASSWORD in .env}
  SCRAPER_DAILY_UTC_HOUR: ${SCRAPER_DAILY_UTC_HOUR:-21}
```

```text
$ docker compose config --quiet
error while interpolating services.db.environment.POSTGRES_PASSWORD: required
variable POSTGRES_PASSWORD is missing a value: set a non-empty POSTGRES_PASSWORD
in .env
```

Two things to watch:

- **No colons in the message.** The value is an unquoted YAML scalar, so a `:`
  in the text fails as `mapping values are not allowed in this context` — an
  error about the Compose file, not about the variable. Quote the scalar or
  write the message without colons.
- **One `:?` per variable is enough.** It fails the whole `config`, so the same
  variable interpolated into other services can stay plain and unrepeated.

Marking a variable required is not the same as waiting for the service. Pair it
with `--wait` on the dependency that must come up first, so a container that
starts and dies is reported against itself with its own logs rather than as
`dependency failed to start` against whatever depended on it:

```bash
if ! docker compose up -d --wait --wait-timeout 90 db; then
  echo "ERROR: the database did not become healthy. Last lines of its log:" >&2
  docker compose logs --tail 30 db >&2
  exit 1
fi
```

## Line endings and the executable bit

Development happens on Windows and every deployment target is Linux, so two Git
for Windows defaults quietly corrupt shell scripts in transit. Both survive code
review, because both fail on the server and never on the laptop.

`core.autocrlf=true` rewrites LF to CRLF **on checkout**. Git stores LF, so the
repository, every diff and every code review look correct — the damage exists
only in the working tree of the clone. Bash then reads the CR as part of the
token:

| Invocation | Error |
|---|---|
| `./deploy.sh` | `bad interpreter: /usr/bin/env bash^M: no such file or directory` |
| `bash deploy.sh` | `set: pipefail: invalid option name` |

Neither message mentions line endings, which is why this costs an afternoon
every time.

`core.filemode=false` is unavoidable on Windows — NTFS has no execute bit — and
it makes `chmod +x` a silent no-op. The script is committed as mode `100644`,
and `./deploy.sh` on the server is `Permission denied`.

Fix both in the repository, never in a machine's Git config: `core.autocrlf` is
per clone, and a deployment must not depend on how a contributor's laptop
happens to be set up.

### 1. Commit a `.gitattributes`

A committed `.gitattributes` overrides `core.autocrlf` on every machine that
clones the repository, including CI runners and the EC2 checkout.

```gitattributes
# Windows checkouts must not rewrite these to CRLF. Every tracked file here is
# read by bash on Ubuntu or by a Linux container, where a CR is a syntax error
# rather than whitespace.
* text=auto eol=lf

# Explicit for the files that actually break, so Git's text/binary heuristic is
# never in the loop for them.
*.sh text eol=lf

# The heuristic's real failure mode is calling a binary "text" and mangling it.
*.png binary
*.jpg binary
*.gz binary
*.zip binary
```

### 2. Record the executable bit through Git

`chmod +x` does nothing on a `core.filemode=false` checkout. Set the mode in the
index directly — this works identically on Windows, WSL and Linux:

```bash
git update-index --chmod=+x scripts/deploy.sh
git ls-files -s -- '*.sh'   # every line must start with 100755
```

### 3. Do not let a deploy depend on the executable bit

`.gitattributes` fixes line endings for good; nothing equivalent guarantees the
mode bit on a file someone adds later from Windows. So invoke scripts through
the interpreter in workflows and documentation, which works at either mode:

```bash
bash ./scripts/deploy.sh     # not ./scripts/deploy.sh
```

### 4. Fail the deploy, not the container

Put this in the deployment script immediately after `git pull --ff-only` and
before anything is built. It runs against what was actually pulled, and it fails
while the previous release is still serving:

```bash
# `|| true` because grep and awk exit non-zero when they match nothing, which is
# the healthy case and must not trip `set -e`.
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
```

Both patterns match `*.sh` only. Extensionless scripts need adding to the globs
by hand, which is a good reason to keep the `.sh` suffix on everything.

### Diagnosing and repairing an existing repository

`git ls-files --eol` is the purpose-built diagnostic. It reports the index and
working-tree endings separately, which is what distinguishes the two failures:

```bash
git ls-files --eol -- '*.sh'
```

```text
i/lf    w/crlf  attr/                    scripts/deploy.sh   # no .gitattributes
i/lf    w/lf    attr/text=auto eol=lf    scripts/deploy.sh   # fixed
```

`i/lf w/crlf` is the common case: the repository is clean and only the checkout
is wrong, so committing `.gitattributes` and re-checking-out is the whole fix:

```bash
git rm --cached -r . && git reset --hard
```

`i/crlf` means CRLF was committed and every clone gets it regardless of config.
That needs a one-time renormalisation, which touches every affected file and
should land as its own commit so it does not bury a real change:

```bash
git add --renormalize .
git commit -m "Normalize line endings to LF"
```

## Removing an application

Taking an application off the instance is more than deleting its checkout.

1. Stop it from its checkout, with the same files its deploy uses:

   ```bash
   cd ~/projects/<repository-name>
   docker compose --env-file .env -f docker-compose.yml \
     -f docker-compose.traefik.yml -f docker-compose.prod.yml down
   ```

   Add `-v` only once its data is backed up or no longer wanted: it deletes the
   named volumes, databases included. Deleting the directory first leaves the
   containers running with nothing to stop them from.
2. Delete its DNS records, and remove its rows from the port table under
   [Host contract for our deployments](#host-contract-for-our-deployments).
3. Delete the checkout, `~/projects/<repository-name>`.

Its certificates need no step. Traefik keeps renewing every certificate in
`acme.json`, used or not, and once the DNS record is gone each attempt fails with
`NXDOMAIN` and counts against Let's Encrypt's rate limits.
`scripts/prune-stale-certs.sh` in this repository removes them every Sunday;
see [Operating it](README.md#operating-it). The same covers an application that
moves to a new hostname. To clear them straight away, which restarts Traefik for
a few seconds:

```bash
bash ~/projects/hobby-traefik/scripts/prune-stale-certs.sh --dry-run   # list them
bash ~/projects/hobby-traefik/scripts/prune-stale-certs.sh
```

## Verification checklist

- Plain `docker compose config` succeeds without `traefik-public` and contains
  a loopback host port.
- Local Traefik config succeeds and contains `traefik-public` but no host port.
- Production config succeeds, enables TLS and contains no host application port.
- `docker compose ps` reports the web service healthy in the selected mode.
- The standalone localhost URL works without Traefik running.
- The local `*.localhost` URL works through Traefik.
- HTTP redirects to HTTPS and the health endpoint succeeds in production.
- With a password gate, the production URL returns `401` without credentials
  and `200` with `curl -u <user>:<password>`, and the local `*.localhost` URL
  asks for none.
- Taking down an application cannot remove the external `traefik-public` network.
- `git ls-files --eol -- '*.sh'` reports `w/lf` for every script, and a fresh
  clone on the Windows machine produces scripts that still start with `#!`.
- `git ls-files -s -- '*.sh'` reports mode `100755` for every script.
- `docker compose config` fails with a message naming the variable when a
  required secret in `.env` is blank.
- The verification checklist in
  [playbook-zero-downtime-deploys.md](playbook-zero-downtime-deploys.md) passes
  for every Traefik-routed service.
