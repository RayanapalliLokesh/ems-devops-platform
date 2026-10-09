# Troubleshooting the running containers

The stack is the Compose project `ems`: services `db`, `app` and `nginx`, plus the monitoring overlay. On EC2
it lives in `/opt/ems`. `-p ems` works from any directory because Compose finds the project through its
container labels. Container names are `ems-<service>-1`.

## The five commands

| Command | Use it for |
|---|---|
| `docker compose -p ems ps` | state and health of every service: `Up (healthy)`, `(health: starting)`, `(unhealthy)`, `Restarting`, `Exited (1)` |
| `docker compose -p ems logs --tail 100 -f app nginx` | stdout/stderr of the services; the app and nginx both write one JSON line per request |
| `docker compose -p ems exec app sh` | a shell inside the running container (as uid 10001); `exec -T` for scripts |
| `docker inspect ems-app-1` | the real configuration: env, mounts, networks, restart count, OOM flag, health log |
| `docker stats --no-stream` | CPU and memory per container against `mem_limit` |

Useful `inspect` formats:

```
docker inspect ems-app-1 --format '{{.State.Status}} restarts={{.RestartCount}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}}'
docker inspect ems-app-1 --format '{{json .Config.Env}}' | jq -r '.[]' | sed 's/PASSWORD=.*/PASSWORD=***/'
docker inspect ems-app-1 --format '{{range $n, $v := .NetworkSettings.Networks}}{{$n}} {{$v.IPAddress}}{{"\n"}}{{end}}'
docker inspect ems-app-1 --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'
```

## Healthcheck status

```
docker inspect ems-app-1 --format '{{json .State.Health}}' | jq '{Status, FailingStreak, Log: [.Log[-3:][] | {ExitCode, Output}]}'
```

- `starting` lasts up to `start-period` (20 s for the app). Failures during it do not count.
- `unhealthy` means 3 consecutive failures (`--retries=3`, every 15 s, 3 s timeout). The `Output` of the last
  attempts shows why, for example `HTTP Error 503` (database) or `timed out` (workers stuck).
- Docker does **not** restart an unhealthy container. Only Compose's `depends_on: service_healthy` (at start)
  and the ALB or Kubernetes act on health. A container that stays `unhealthy` needs a person or an alert
  (`EMSAppDown`).
- The app's healthcheck calls `/health` *inside* the container (127.0.0.1:5000). nginx's healthcheck calls
  `/nginx-health`, which does not depend on the app, so a broken app never makes nginx look unhealthy.

Run the same check by hand:
```
docker compose -p ems exec app python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:5000/health').read())"
docker compose -p ems exec nginx wget -qO- http://app:5000/health      # the path nginx takes
docker compose -p ems exec db pg_isready -U ems
```

## Common failures

| Symptom | Likely cause | Check | Fix |
|---|---|---|---|
| `app` keeps `Restarting` | workers fail to boot: bad `DATABASE_URL`, missing `SECRET_KEY`, import error | `docker compose logs --tail 50 app` (`Worker failed to boot`) | correct `.env`, then `docker compose up -d app` (a restart does not reload env) |
| `required variable SECRET_KEY is missing` before anything starts | `.env` missing or incomplete | `ls -l /opt/ems/.env` | copy from `.env.example` and fill it in |
| `nginx` waits forever / `dependency failed to start` | the app never became healthy | `docker inspect ems-app-1 --format '{{json .State.Health}}'` | fix the app first |
| `502 Bad Gateway` | app down or restarting, or nginx using an old IP (see below) | `docker compose ps app`, nginx log `connect() failed` | start the app; check the `resolve` setup |
| `504 Gateway Time-out` after 35 s | a request longer than `proxy_read_timeout`, or all workers busy | app log `WORKER TIMEOUT`, `docker stats` | find the slow query; raise `GUNICORN_WORKERS` only if CPU allows |
| `exec ... operation not permitted` | `no-new-privileges` on an AppArmor host | `docker inspect --format '{{.HostConfig.SecurityOpt}}'` | leave it out (see image-review.md) |
| `Read-only file system` in the app log | the code writes outside `/tmp` or `/app/data` | the traceback path | write to `/tmp` (tmpfs) or the `app-data` volume |
| Exit code 137 | SIGKILL: OOM (`OOMKilled=true`) or a stop that took too long | `docker inspect ... OOMKilled`, `dmesg \| grep -i oom` | find the leak; raise `mem_limit` carefully |
| `port is already allocated` | another container or process holds the port | `ss -tlnp 'sport = :80'`, `docker ps --filter publish=80` | stop the other one (break-fix scenario 5) |

## nginx 502 after the app is recreated, and why `resolve` fixes it

`docker compose up -d app` (a new image tag, an env change, a rollback) **replaces** the app container. The
new container usually gets a **new IP address** on the `backend` network.

Plain nginx resolves the names in an `upstream` block **once, at start-up**, and caches the IP until a restart
or reload:

```nginx
upstream ems_app { server app:5000; }        # resolved once -> 172.19.0.3 forever
```

After the recreate, nginx keeps sending requests to the old IP. Nothing listens there any more, or worse, a
different container now has that address. The result is `502 Bad Gateway` with
`connect() failed (113: Host is unreachable) while connecting to upstream` (or `111: Connection refused`) in
the nginx log, until someone runs `docker compose restart nginx`. That gives you a short outage on every deploy.

The project's `nginx/default.conf` solves it:

```nginx
resolver 127.0.0.11 valid=10s ipv6=off;      # Docker's embedded DNS server, answers are cached at most 10 s

upstream ems_app {
    zone ems_app 64k;                        # shared memory: required for re-resolvable servers
    server app:5000 resolve;                 # re-resolve "app" in the background, follow IP changes
    keepalive 16;
}
```

- `resolver 127.0.0.11` points nginx at Docker's DNS, the same server that answers `app` for every container
  on the network.
- `resolve` on the `server` line makes nginx look the name up again (honouring `valid=10s`) and update the
  upstream's address list. Open-source nginx supports this since 1.27.3. The project uses 1.27.4; earlier it
  was an NGINX Plus feature.
- `zone` is required for `resolve`: the address list lives in shared memory so all worker processes see the
  update.
- `keepalive 16` stays: idle connections to the old IP are dropped when it disappears.
- `ipv6=off` stops nginx from asking for AAAA records that Docker's DNS does not serve on these networks.

**Verify:** recreate the app and watch for 502s.
```
docker compose -p ems up -d --force-recreate --no-deps app
for i in $(seq 40); do curl -s -o /dev/null -w '%{http_code} ' http://127.0.0.1/health; sleep 1; done; echo
```
Expect a few `502` while the new container boots (there is only one app container, so no zero-downtime), then
`200`. Before the `resolve` fix, the `502` never stopped. Truly zero-downtime deploys need two app replicas
or Kubernetes (Phase 22: Service and readiness probes).

## Cleaning up safely

```
docker compose -p ems down          # removes containers and networks; KEEPS the volumes (database!)
docker compose -p ems down -v       # also deletes db-data / app-data: the database is gone. Back up first
docker image prune -a --filter until=168h
```
Take a backup with `scripts/linux/backup-db.sh` before anything that touches volumes.
