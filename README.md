# Traefik on the EC2 instance

One Traefik owns ports 80 and 443 and routes to every app on the box by hostname.
Apps don't get published web ports of their own — they join a shared Docker network
and describe their routing in labels on their own containers.

These two files are the whole proxy. They aren't specific to Sink Mailer: keep them
in this repository, clone it onto the instance, start them once, and leave them running.

```
  docker-compose.yml   the proxy container
  traefik.yml          its static config — ports, Docker discovery, Let's Encrypt
```

## Before you start

**Security group** — inbound `22` (SSH), `80` and `443` (Traefik), `2525` (SMTP
ingest, which does not go through Traefik). Nothing else. Note that Docker writes
port mappings straight into iptables and bypasses host firewalls like ufw, so the
security group is the control that actually applies here.

**DNS** — point an A record at the instance's public IP *before* the first start.
Let's Encrypt validates by fetching a file over HTTP from the domain, so a name
that doesn't resolve yet means no certificate.

**Docker** — on `ubuntu-noble-24.04-arm64-server`:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2
sudo systemctl enable --now docker
sudo usermod -aG docker $USER   # log out and back in for this to take effect
```

Everything here builds from source or uses a multi-arch image, so arm64 needs no
special handling.

**Git** — The repository is private, so the instance needs GitHub credentials that can read it
The below commands give the server access to all the private repos in your GitHub account.
```bash
ssh-keygen -t ed25519 -C "EC2 GitHub" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
# Copy result to https://github.com/settings/keys
```

## Deploy

```bash
# On the instance
git clone git@github.com:TheoGibbons/hobby-traefik.git ~/hobby-traefik
cd ~/hobby-traefik

docker network create traefik-public   # once, ever — shared by every app
docker compose up -d
docker compose logs -f
```

To deploy later changes to the proxy:

```bash
cd ~/hobby-traefik
git pull --ff-only
docker compose up -d
```

The network is created by hand rather than by a compose file so that
`docker compose down` in any one stack can't delete it and break the routing of
everything else on the instance.

## Deploy Sink Mailer behind it

```bash
# On the instance
git clone git@github.com:TheoGibbons/sink-mailer.git ~/sink-mailer
cd ~/sink-mailer
cp .env.example .env
nano .env
```

Set at least:

| Variable | Value |
|---|---|
| `WEB_DOMAIN` | the hostname you pointed at the instance |
| `WEB_BIND` | `127.0.0.1` — Traefik connects over the Docker network, not the host port |
| `SINK_ENCRYPTION_KEY` | `node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"` |
| `POSTGRES_PASSWORD` | anything but the default |
| `MAIL_HOST`, `PUBLIC_SMTP_HOST` | the hostname apps will point their SMTP config at |

Then bring it up with both compose files — the overlay adds the Traefik labels and
the HTTPS settings, and is not usable on its own:

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

`APP_URL`, `SESSION_COOKIE_SECURE` and `TRUST_PROXY` are set by the overlay; don't
set them in `.env`.

## Check it worked

```bash
curl -I http://www.sinkmailer.com                  # 301 to https
curl -s https://www.sinkmailer.com/api/health      # {"status":"ok",...}
docker compose -f ~/hobby-traefik/docker-compose.yml logs | grep -i acme
```

## Adding the next app

Nothing in this directory changes. In the new app's compose file:

```yaml
services:
  app:
    networks: [default, traefik-public]
    labels:
      - 'traefik.enable=true'
      - 'traefik.docker.network=traefik-public'
      - 'traefik.http.routers.myapp.rule=Host(`myapp.example.com`)'
      - 'traefik.http.routers.myapp.entrypoints=websecure'
      - 'traefik.http.routers.myapp.tls.certresolver=letsencrypt'
      - 'traefik.http.services.myapp.loadbalancer.server.port=8000'

networks:
  traefik-public:
    external: true
```

Give the router and service a name unique to that app (`myapp` above) — the names
are global across the instance, and two apps sharing one will fight over it.

## Three things worth knowing

**`WEB_BIND=127.0.0.1` is a security setting, not a tidiness one.** The overlay sets
`TRUST_PROXY=true`, which makes the app read the client's address from
`X-Forwarded-For` — necessary, or every user shares one rate-limit bucket keyed on
Traefik. It also trusts that header unconditionally. Traefik overwrites it with the
address it actually saw (its entry points trust no inbound `X-Forwarded-*` by
default), so a spoofed header dies at the proxy — but only for traffic that goes
*through* the proxy. Publish the app's port on `0.0.0.0` as well and anyone can send
their own `X-Forwarded-For`, choose their own rate-limit bucket, and brute-force
logins unthrottled.

**SMTP does not go through Traefik.** It's raw TCP with no hostname to route on
before STARTTLS, so a TCP router would be a pass-through that buys nothing over
publishing 2525 directly — which the base compose file already does.

**SMTP STARTTLS has no certificate under this setup.** Traefik keeps its
certificates inside `acme.json` in a format the SMTP app can't read, so
`SMTP_TLS_KEY_PATH` / `SMTP_TLS_CERT_PATH` stay unset and STARTTLS stays disabled —
meaning SMTP AUTH passwords cross the network in cleartext. That's the same as
today and fine for a sandbox on a trusted network, but if you want it fixed the
options are a separate certbot for the SMTP hostname, or `traefik-certs-dumper`
writing PEM files out of the volume for the SMTP container to mount.
