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

## Host contract for our deployments

- The proxy is managed by `~/hobby-traefik`.
- The external Docker network is always named `traefik-public`.
- Local HTTP uses the `web` entry point and a unique `*.localhost` hostname.
- Production HTTPS uses the `websecure` entry point and the `letsencrypt`
  certificate resolver.
- In production, only Traefik publishes host ports 80 and 443.
- Documented non-HTTP services may still publish host ports. For example, SMTP
  can be intentionally public while a remotely accessible database must be
  protected by a source-restricted cloud firewall/security-group rule.
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
   rebuilds, and waits for healthy containers.
8. Add a GitHub Actions workflow that SSHes to the EC2 checkout and invokes the
   deployment script. The server checkout remains the deployment source.

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

## Verification checklist

- Plain `docker compose config` succeeds without `traefik-public` and contains
  a loopback host port.
- Local Traefik config succeeds and contains `traefik-public` but no host port.
- Production config succeeds, enables TLS and contains no host application port.
- `docker compose ps` reports the web service healthy in the selected mode.
- The standalone localhost URL works without Traefik running.
- The local `*.localhost` URL works through Traefik.
- HTTP redirects to HTTPS and the health endpoint succeeds in production.
- Taking down an application cannot remove the external `traefik-public` network.
