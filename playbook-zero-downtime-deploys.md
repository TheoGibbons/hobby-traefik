# Zero-downtime deploys playbook

Use this file as the contract when changing a project's LIVE deploy so that a push
to `main` no longer takes the site offline. It assumes the project already follows
[playbook-traefik-integration.md](playbook-traefik-integration.md), and it is
specific enough to hand to an LLM together with the target repository.

Four projects implement it, each verified by deploying under continuous load
through Traefik with no failed requests. Their `scripts/deploy.sh` differ only in
their service lists and project-specific checks; read the one closest in shape:

| Project | Shape |
|---|---|
| shred-link | One web service; secrets held in memory, so sticky cookies are essential |
| measure-the-baby | One web service on SQLite; needed a SIGTERM handler |
| mysql-browser | One nginx static site with a Compose-defined health check |
| sink-mailer | Postgres, one-shot migrations, a rolled web service with 60 s long-polls, and SMTP on a host port that cannot roll |

## Goals

- A deploy never refuses, drops or 404s a request, including one already in flight.
- A release that fails its health check is discarded while the previous release
  keeps serving, and the deploy fails.
- A server that is missing a prerequisite fails the deploy before anything
  changes, with the fix in the message.
- Standalone and local paths are unchanged.

## Why a deploy goes down

`docker compose up -d --build` builds first, while the old container still serves,
so the build is not the outage. The outage is what follows: Compose **stops the
old container, then starts the new one**, and Traefik sends nothing to a container
until Docker reports it `healthy`. With a single container there is nothing to
serve the gap.

Measured through the shared Traefik proxy with eight clients requesting
continuously:

| Deploy method | Failed requests |
|---|---|
| `up -d` recreating the container | ~9 s of 502 then 404 |
| `docker rollout`, no draining | ~0.1 s blip, 8 requests hung for 10 s |
| `docker rollout` with draining | **none** in ~12,000 requests |
| `docker rollout` with draining, but a routing label changed | ~10 s of 404 |
| `docker rollout` without draining, a routing label changed | ~0.1 s blip |
| `docker rollout`, new release never turns healthy | none; old release kept, deploy fails |

The rest of this playbook is how to get the bold row, and how to avoid the
10-second one.

## How it works

**docker rollout.** [docker-rollout](https://github.com/wowu/docker-rollout) is a
single shell script installed as a Docker CLI plugin. `docker rollout app` scales
`app` to two containers with `--no-recreate`, so the new release starts beside the
old one; waits for the new container's health check; then stops and removes the
old container. If the new one is not healthy within `--timeout`, it prints that
container's health log and output, removes it, and exits 1.

**Traefik load balancing.** Two containers carrying the same
`traefik.http.services.<name>` labels become two servers in one load-balancer
pool. No proxy configuration changes during a rollout.

**Draining.** Stopping a container that Traefik still routes to fails the requests
in flight on it. So before the old container is stopped, a pre-stop hook creates
`/tmp/drain` inside it; the health check fails while that file exists; Docker marks
the container unhealthy; Traefik stops routing to it; the hook's `sleep` lets
in-flight requests finish. Only then is it stopped.

**The routing-label trap.** When two containers describe the same Traefik service
or router with *different* labels, Traefik logs `HTTP service defined multiple
times with different configurations` and serves **neither**: 404 for as long as
both exist. Draining makes that window longer. The deploy script therefore
compares the running container's `traefik.*` labels with the new configuration's,
and skips draining when they differ, trading a 20-second outage for a sub-second
blip on the rare deploy that changes routing.

## Host prerequisite

The plugin belongs to the host, not the project:

- `~/projects/hobby-traefik/scripts/install-docker-rollout.sh` installs a pinned,
  checksummed release into the deploying user's `~/.docker/cli-plugins`. It is
  idempotent.
- hobby-traefik's own `scripts/deploy.sh` runs it, and hobby-traefik is deployed
  first on every server, so a new server following the documented order has it.
- Each project's `scripts/deploy.sh` checks for it **before** `git pull` and stops
  with the install command if it is missing.

The plugin is per user. It must be installed for the user CI deploys as
(`EC2_USER`, usually `ubuntu`), and a manual `sudo bash scripts/deploy.sh` will not
find it. Do not run deploys with sudo.

⚠️ **Do not detect the plugin by exit code.** When it is missing,
`docker rollout --version` is answered by Docker itself — it prints Docker's own
version and exits 0. Match the output text, as the template below does.

The health-check timings below need Docker Engine 25 or newer for
`start_interval`. Check with `docker version --format '{{.Server.Version}}'`.

## Step 1 — Decide which services to roll

Run `docker compose -f docker-compose.yml -f docker-compose.traefik.yml -f
docker-compose.prod.yml config` (the exact files `scripts/deploy.sh` passes) and
classify every service. Every service goes in exactly one list, and the deploy
script enforces that.

| Service | List | Why |
|---|---|---|
| Receives HTTP through Traefik (`traefik.enable: 'true'`) | `rolled` | This is what users see go down |
| Something a rolled service needs to start: database, cache, queue broker | `before_rollout` | Must be up and current before the new release boots |
| A job that runs to completion and exits, such as migrations, when it is not behind a Compose profile | `one_shot` | Must finish before the new release boots; see the note under the template |
| Everything else: workers, schedulers, SMTP, anything without inbound HTTP | `after_rollout` | No traffic to protect, and two copies of a worker run jobs twice |

Services behind an inactive Compose `profiles:` entry are not listed by
`config --services` and need no list; keep however the script already runs them.

A service that would otherwise be `rolled` **cannot** be rolled, and belongs in
`after_rollout`, if any of these is true. Say so in the report rather than working
around it:

- It publishes a host port (`ports:`) in the production file set. Two containers
  cannot bind one port. Moving an HTTP port into `docker-compose.override.yml` is
  the fix when the port is only for standalone use.
- It uses `network_mode: host`.
- Two copies cannot safely run at once for about 30 seconds. Examples: exclusive
  locks on a shared volume (LevelDB, BoltDB, SQLite with `locking_mode=EXCLUSIVE`;
  plain SQLite in WAL mode is fine), a hardware device, a licence or login that
  permits one session, a user profile or desktop session directory both would
  write to.
- It serves only long-lived connections (VNC, RDP, WebSocket-only, SSH) **and**
  holds each user's session inside the container. Rolling still ends those
  sessions when the old container stops; it only keeps new connections working.
  Roll it only if accepting new connections throughout the deploy is worth the
  checks below.

If nothing qualifies for `rolled`, change nothing and report why.

## Step 2 — Make each rolled service safe to run twice

Work through every item for every service in `rolled`.

### 2.1 No `container_name`

Remove it from the service in every Compose file. Replace it with a comment so it
does not come back:

```yaml
services:
  app:
    build: .
    # No container_name: a LIVE deploy briefly runs the new release beside the old
    # one (scripts/deploy.sh), and two containers cannot share a fixed name.
```

Then search the repository — README, scripts, CI, docs — for the old name used
with `docker logs`, `docker exec`, `docker restart` and so on, and replace each
with the Compose form, for example `docker compose -f … logs app`. Container
names now change on every deploy (`my-app-app-1`, then `-2`, then `-3`).

### 2.2 No host ports in the production file set

`docker compose … config` with the deploy script's files must show no `ports:` on
the service. The integration playbook already puts standalone ports in the
override, which the deploy never loads.

### 2.3 A health check with deploy timings and a drain check

Required. docker-rollout without a health check just waits a fixed time and hopes.

The timings are deliberate:

| Setting | Value | Why |
|---|---|---|
| `start_interval` | `1s` | Probe every second while booting, so the new release takes traffic as soon as it answers |
| `start_period` | `30s`, or longer than the slowest boot | Failures during it do not count |
| `interval` | `5s` | How quickly a drained container goes unhealthy |
| `retries` | `3` | Tolerates a slow probe; unhealthy within 15 s of draining |
| `timeout` | `3s` | |

The drain hook's sleep must exceed `interval × retries` plus Traefik's reaction
time and the longest normal request. With the values above, 20 seconds.

The probe must hit a route that is cheap, needs no authentication, and has no side
effects: no view counting, no logging a visit, no sending mail.

In the `Dockerfile`:

```dockerfile
# Traefik routes only to a healthy container, so these timings are what make a
# LIVE deploy seamless (scripts/deploy.sh). --start-interval probes every second
# while booting, so a new release takes traffic as soon as it answers. The short
# --interval and the /tmp/drain check let a deploy take the outgoing release out
# of rotation within 15 seconds, before it is stopped.
HEALTHCHECK --interval=5s --timeout=3s --start-period=30s --start-interval=1s --retries=3 \
  CMD test ! -f /tmp/drain && wget -q -O /dev/null http://127.0.0.1:3000/health || exit 1
```

Or in the base `docker-compose.yml`, which wins over the `Dockerfile` — use this
form for images you do not build, and escape any `$` as `$$`:

```yaml
    healthcheck:
      test: ['CMD-SHELL', 'test ! -f /tmp/drain && wget -q -O /dev/null http://127.0.0.1:3000/health || exit 1']
      interval: 5s
      timeout: 3s
      retries: 3
      start_period: 30s
      start_interval: 1s
```

Check these against the actual image:

- **The probe tool exists in the image.** Alpine has `wget` (BusyBox) but usually
  not `curl`. Debian slim images often have neither. Use what is there:
  `node -e "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"`,
  `php -r "exit(@file_get_contents('http://127.0.0.1/health') === false ? 1 : 0);"`,
  or `python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health')"`.
  Confirm with `docker compose … exec app sh -c '<the test>' ; echo $?`.
- **The image has a shell.** `CMD-SHELL` and `test` need `/bin/sh`. Distroless and
  scratch images have none; the health check has to be a binary the app ships,
  and the drain check must be implemented inside it (or skip draining and accept
  the blip).
- **`/tmp` is writable by the container user.** The hook runs as that user. With
  `read_only: true`, add `tmpfs: [/tmp]`.
- **The port is the container port**, not a host port.
- **nginx or php-fpm pairs.** Probe through the web server if that is what Traefik
  routes to, and roll the web server. If the web server and the application run as
  separate services, rolling only the web server does not replace the application
  without downtime; say so in the report.

### 2.4 Shuts down promptly on SIGTERM

`docker stop` sends SIGTERM and kills after a timeout, 10 seconds by default. An
app that ignores it still works with draining, but every deploy waits out the
timeout, and the kill (exit code 137) can interrupt writes.

- Use exec-form `CMD ["node", "server.js"]`, not `CMD npm start` or
  `CMD node server.js`. The shell form and `npm` do not forward signals.
- **Exec form is not enough for Node.** As PID 1 the kernel ignores any signal
  without a handler, and measure-the-baby, exec form and all, was killed with 137
  rather than exiting. Handle it: stop accepting connections, finish in-flight
  requests, close the database, exit 0. Confirm with
  `docker stop <container>; docker inspect <container> --format '{{.State.ExitCode}}'`,
  which must print 0.
- Where the app cannot handle signals itself, add `init: true` to the service.
- **Long requests need a longer grace period.** A long-poll, a large download or a
  streaming response still running on the drained container is cut off when the
  timeout expires. Set `stop_grace_period` on the service to the longest such
  request plus 15 seconds, and make sure shutdown waits for in-flight requests
  rather than exiting straight away.

### 2.5 Keep a browser on one container

For about 30 seconds both releases serve, and Traefik alternates between them
request by request — verified in its access log. Anything that must come from the
same release as the request before it breaks:

- in-memory sessions (express-session's default `MemoryStore`, PHP file sessions
  in the container, Flask server-side sessions on local disk)
- CSRF tokens, upload progress, multi-step forms, one-time tickets held in memory
- WebSocket or SSE setups that rely on an earlier HTTP request
- **static assets**: the old release's HTML followed by the new release's
  JavaScript. With hashed bundle names (Vite, webpack, Next.js) the new container
  has no file by the old name and answers 404, so the page fails to load
- a service worker installing its cache from both releases, which then persists
  the mix

Nearly every app serving a browser hits the static-asset case, so add the cookie
to every rolled service that serves HTML. Only a pure API, whose clients never
chain requests to per-container state, can go without. Use the service name from
the existing labels:

```yaml
# docker-compose.traefik.yml
      # A LIVE deploy runs the old and new release side by side for a few
      # seconds, and <what> lives in one container's memory. The cookie keeps a
      # browser on the container holding it.
      traefik.http.services.my-app.loadbalancer.sticky.cookie.name: my-app-lb
      traefik.http.services.my-app.loadbalancer.sticky.cookie.httponly: 'true'
      traefik.http.services.my-app.loadbalancer.sticky.cookie.samesite: lax
```

```yaml
# docker-compose.prod.yml
      traefik.http.services.my-app.loadbalancer.sticky.cookie.secure: 'true'
```

The cookie holds only a hash identifying the container. Once the old container is
drained, its browsers move to the new one. In-memory state still does not survive
a deploy — no more than it survives a restart — and the README should say so.

### 2.6 Two releases running at once must be harmless

Confirm each of these, and change the code only where one fails:

- **Startup work runs while the old release is still serving.** Migrations must
  be backward compatible: add columns and tables, do not rename or drop what the
  running release reads. A destructive migration goes in a later release, once no
  running code uses the old shape.
- **Timers and schedulers inside the web process run in both** for about 30
  seconds. Jobs must be idempotent, or guarded by a database lock.
- **Shared volumes are opened by both.** See the exclusive-lock list in Step 1.

## Step 3 — Replace the end of `scripts/deploy.sh`

Two changes. Keep everything else in the existing script: the `.env` check, the
dirty-tree check, `git pull --ff-only`, the CRLF and executable-bit checks and the
`traefik-public` check.

**First**, directly after the `.env` check and before the dirty-tree check and
`git pull`:

```bash
# Releases are swapped with the docker-rollout CLI plugin, which belongs to the
# host rather than to this repository. Check before pulling, so a new server
# fails here, naming the fix, while nothing has changed. Match the output: when
# the plugin is missing, Docker answers `docker rollout --version` with its own
# version and exits 0.
if [[ "$(docker rollout --version 2>/dev/null || true)" != "docker-rollout version "* ]]; then
  echo "The docker-rollout plugin is not installed for $(id -un) on this host." >&2
  echo "Deploying hobby-traefik installs it, or run:" >&2
  echo "  bash ~/projects/hobby-traefik/scripts/install-docker-rollout.sh" >&2
  exit 1
fi
```

**Second**, replace the `compose=(…)`, `config`, `up` and `ps` lines at the end
with this, filling in the four lists from Step 1 and keeping the project's own
Compose files:

```bash
compose_args=(--env-file .env -f docker-compose.yml -f docker-compose.traefik.yml -f docker-compose.prod.yml)
compose=(docker compose "${compose_args[@]}")

# Every service must be in exactly one list; see "Decide which services to roll"
# in hobby-traefik's playbook-zero-downtime-deploys.md.
#   before_rollout  what the rolled services need running first (databases)
#   one_shot        jobs that run to completion before the rollout (migrations)
#   rolled          Traefik-routed services, swapped without downtime
#   after_rollout   everything else, updated with a plain `up`
before_rollout=()
one_shot=()
rolled=(app)
after_rollout=()
long_running=("${before_rollout[@]}" "${rolled[@]}" "${after_rollout[@]}")

"${compose[@]}" config --quiet

# A service missing from the lists would be started once and never updated, so a
# service added to Compose later has to be classified before the next deploy.
listed=" ${long_running[*]} ${one_shot[*]} "
for service in $("${compose[@]}" config --services); do
  if [[ "$listed" != *" $service "* ]]; then
    echo "Service '$service' is not in a service list in scripts/deploy.sh." >&2
    exit 1
  fi
done

"${compose[@]}" build

if (( ${#before_rollout[@]} )); then
  "${compose[@]}" up -d --wait --wait-timeout 90 "${before_rollout[@]}"
fi

# One-shot jobs finish while the previous release is still serving, so
# migrations must stay backward compatible with it. They run through `up` rather
# than `run` so their service container is replaced too: the rollout starts the
# rolled services' dependencies again, and would otherwise re-run the previous
# release's job.
for service in "${one_shot[@]}"; do
  "${compose[@]}" up --no-deps --exit-code-from "$service" "$service"
done

# `up` would stop the running release before starting the new one, and the site
# would be down until the new one passed its health check. docker rollout starts
# the new container beside the old, waits for it to turn healthy, then removes
# the old. A release that never turns healthy is removed instead, the old one
# keeps serving, and the deploy fails.
#
# The pre-stop hook drains the outgoing container first: /tmp/drain fails its
# health check, Traefik stops routing to it, and in-flight requests finish. 20
# seconds covers three failed probes 5 seconds apart plus Traefik noticing.
#
# Unless the routing labels changed. Traefik refuses a service that two
# containers describe differently and serves 404 while both exist, so draining
# would stretch that into a 20-second outage. Stop the old one immediately
# instead and accept a sub-second blip.
routing_labels() { { grep -o '"traefik\.[^"]*": *"[^"]*"' || true; } | sed 's/": *"/":"/' | sort; }
for service in "${rolled[@]}"; do
  rollout=(docker rollout "${compose_args[@]}" --timeout 90)
  running_ids="$("${compose[@]}" ps --quiet "$service")"
  if [[ -n "$running_ids" ]]; then
    live_labels="$(docker inspect --format '{{json .Config.Labels}}' "${running_ids%%$'\n'*}" | routing_labels)"
    new_labels="$("${compose[@]}" config --format json "$service" | routing_labels)"
    if [[ "$live_labels" == "$new_labels" ]]; then
      rollout+=(--pre-stop-hook 'touch /tmp/drain && sleep 20')
    else
      echo "Routing labels of $service changed; replacing its old container without draining it."
    fi
  fi
  "${rollout[@]}" "$service"
done

# --no-deps, so a worker that depends_on a rolled service cannot recreate it.
if (( ${#after_rollout[@]} )); then
  "${compose[@]}" up -d --no-deps --wait --wait-timeout 90 "${after_rollout[@]}"
fi

# Removes containers of services no longer in the Compose files and confirms
# every long-running service is healthy. Naming them with --no-deps keeps it from
# re-running one-shot jobs or waiting on their exited containers, and
# --no-recreate stops it replacing what was just rolled.
"${compose[@]}" up -d --no-deps --no-recreate --remove-orphans --wait --wait-timeout 90 "${long_running[@]}"
"${compose[@]}" ps
```

Adjust only these, and say so in the report:

- `--timeout 90` must exceed the slowest realistic boot, including migrations run
  at startup.
- `sleep 20` must exceed `interval × retries` + 5 seconds + the longest normal
  request. Long-polls, uploads and downloads are covered by `stop_grace_period`
  instead; see Step 2.4.

Verified behaviour of the `one_shot` step, so it is not "fixed" later: a failing
job fails the deploy with its own exit code before anything is rolled; the rolled
service's `depends_on: condition: service_completed_successfully` then re-runs the
job once more during the rollout, from the new image, which is harmless for
idempotent migrations; and the final `up` neither runs it again nor waits on it.

The CI workflow does not change.

## Step 4 — Update the README

Following [playbook-readme-standard.md](playbook-readme-standard.md), and without
linking into this repository:

- **Deploying to LIVE with hobby-traefik:** deploys do not take the site down; a
  release that fails its health check is discarded; hobby-traefik installs the
  docker-rollout plugin and the script stops with the install command where it is
  missing.
- **Setup push-to-deploy:** a push runs the `scripts/deploy.sh` already on the
  server, which then pulls, so a change to the script takes effect from the
  following deploy.
- **Operating it:** container names change on every deploy, so use
  `docker compose … logs app`. If Step 2.5 applied, what does not survive a
  deploy.
- Remove any instruction that relies on `container_name`.

## What the first deploy looks like

Expect this, and do not mistake it for failure:

1. **The deploy that ships this change still has the old downtime.** CI runs the
   `scripts/deploy.sh` already on the server, which opens before `git pull`
   replaces it, so that run is a plain `up`.
   That run also recreates the container from the new image and labels, so:
2. **Every deploy after that is seamless.**

If instead the change is first deployed by hand with `git pull` and then the new
script, that run is a rollout but blips once: the container it replaces lacks the
drain check, and if routing labels changed (for example sticky cookies were added)
the script deliberately skips draining.

To see seamless behaviour straight away, run the workflow again after the first
deploy: `gh workflow run deploy.yml`, or push an empty commit.

## Verification checklist

Statically, in the repository:

- `docker compose -f docker-compose.yml -f docker-compose.traefik.yml -f docker-compose.prod.yml config`
  shows no `container_name` and no `ports:` on any rolled service, and a
  `healthcheck` with `start_interval`. (Set `APP_HOST` and required variables in
  the shell for this, or use the example env file.)
- `grep -rn "<old container_name>"` finds nothing outside Git history.
- `bash -n scripts/deploy.sh` passes, the service lists cover every service from
  `config --services`, and the script still ends with `up … --wait` and `ps`.
- The health check passes inside a running container, and fails within
  `interval × retries` of `touch /tmp/drain`:
  ```bash
  docker compose … exec app sh -c 'touch /tmp/drain'
  sleep 20; docker compose … ps app   # (unhealthy)
  docker compose … exec app sh -c 'rm /tmp/drain'
  ```

Locally, through hobby-traefik (install the plugin once with
`bash ~/projects/hobby-traefik/scripts/install-docker-rollout.sh`):

```bash
compose_args=(--env-file .env -f docker-compose.yml -f docker-compose.traefik.yml)
docker compose "${compose_args[@]}" up -d --build --wait

# In a second terminal, and watch for anything other than 200:
while true; do curl -s -o /dev/null -w '%{http_code} ' http://<app>.localhost:8085/; sleep 0.1; done

# Run twice; the second run drains a container that has the drain check:
docker rollout "${compose_args[@]}" --timeout 90 --pre-stop-hook 'touch /tmp/drain && sleep 20' app
```

- Only `200` (or whatever the route normally returns) is printed through the
  second rollout.
- A rollout of a release whose health check fails prints
  `New containers are not healthy. Rolling back.`, exits 1, and the curl loop
  never stops returning 200.

On the server, after the second deploy:

- The same curl loop against `https://<APP_HOST>/`, run from a laptop during a
  deploy, prints only 200.
- The deploy log shows `Running pre-stop hook`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `The docker-rollout plugin is not installed` | New server, or deploying as a different user. Deploy hobby-traefik, or run its `scripts/install-docker-rollout.sh` as the deploy user |
| `docker rollout --version` prints Docker's version | The plugin is missing; Docker ignores unknown commands for `--version` |
| `The container name "/…" is already in use` | A `container_name` survived in one of the Compose files |
| `port is already allocated` during a rollout | The rolled service publishes a host port in the production files |
| `New containers are not healthy. Rolling back.` | The release is broken, or boots slower than `--timeout`. The output above it has the health log and container logs. The old release is still serving |
| Health check always unhealthy on a fresh image | The probe tool is not in the image, or the probe uses the host port |
| 404 for 10+ seconds; Traefik logs `defined multiple times with different configurations` | Old and new containers have different routing labels, and the old one was drained. Check the label comparison in the script matches the service |
| 502s or hung requests on every deploy | The running image lacks the drain check, or `interval × retries` exceeds the hook's sleep |
| Users lose a session or a multi-step action fails during deploys | In-memory state without sticky cookies; see Step 2.5 |
| A page loads blank or its JavaScript 404s during deploys | HTML and assets came from different releases; see Step 2.5 |
| API clients see 502 on long-polls or downloads during deploys | `stop_grace_period` shorter than the request; see Step 2.4 |
| Every deploy pauses 10 s at "Stopping and removing old containers" | The app ignores SIGTERM; see Step 2.4 |
| A worker never picks up new code | It is not in `after_rollout`, or it was put in `rolled` |

## What to report back

- Each service and the list it went in, with the reason for anything not rolled.
- Health-check route and probe command, and how they were confirmed to work in
  the image.
- Whether sticky cookies were added, and what in-memory state required them.
- Anything from Step 2.6 that needed a code change, or that looks unsafe but was
  left alone.
- Any value changed from the template (`--timeout`, the sleep) and why.
- The verification that was actually run, and its output.
