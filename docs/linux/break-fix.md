# Break and fix: five failures to practise on

`scripts/linux/break-fix.sh` causes five realistic failures on the Compose stack. For each one you diagnose
the problem with `triage.sh` and `netcheck.sh` **before** you read the "Fix" section. Use a lab host or your
laptop, never a server that real users depend on. Every break has a fix that puts the stack back exactly as
Compose defines it.

```
scripts/linux/break-fix.sh list            # the scenarios
scripts/linux/break-fix.sh --dry-run       # every break and fix command, nothing runs
scripts/linux/break-fix.sh break 1         # cause failure 1
scripts/linux/break-fix.sh check 1         # exit 0 = healthy, 1 = still broken
scripts/linux/break-fix.sh fix 1           # repair it (then runs check)
```

The script reads the Compose labels on the running containers: `config_files`, `environment_file` and
`working_dir`. When it recreates a service it therefore uses exactly the files the stack was started with,
whether that is `/opt/ems` on EC2 or a checkout with `.env.local` and the monitoring overlay on a laptop. The
health URL defaults to the port nginx publishes: 80 on EC2, 8080 locally.

The loop for every scenario:
**symptom → which layer (netcheck) → which component (compose ps / logs) → root cause → fix → verify → note**.

---

## 1. The app container is stopped

**Break:** `docker compose stop app`

**Symptoms:** `curl -i http://127.0.0.1/health` returns `502 Bad Gateway` from nginx. In netcheck, `tcp`
passes and `http` fails with 502, so nginx is up and the problem is behind it. `docker compose ps` shows app
`Exited (0)`. The nginx log has `connect() failed ... while connecting to upstream`.

**Why it stays down:** `restart: unless-stopped` restarts a container that *crashes*. It does not restart one
that an operator stopped. Phase 12's `Restart=on-failure` behaved the same way. To see the restart policy
work, crash the container instead: `docker compose exec app kill 1`. gunicorn exits and Docker starts it again.
`RestartCount` goes up.

**Fix:** `docker compose up -d --wait app`. `--wait` returns once the healthcheck reports healthy.

**Verify:** `break-fix.sh check 1`. The app is `running/healthy` and /health returns 200.

## 2. The disk is filling up

**Break:** `fallocate` creates a 512 MB file (`--fill-mb`, between 64 and 2048) in `/tmp`, or in `/var/tmp`
when `/tmp` is a RAM-backed tmpfs. The script refuses to run when that would leave less than 1 GB free. It
cannot fill the disk.

**Symptoms:** `df -h` shows the usage jump. On a small EC2 root volume (8 GB) you can push the usage high
enough to see what happens near 100%: PostgreSQL fails writes with `could not extend file ... No space left on
device`, `/health` answers 503 "degraded", and Docker cannot pull images.

**Diagnose:** `df -h` (which mount?), `sudo du -xh / --max-depth=2 | sort -h | tail`, `docker system df`.
`lsof +L1` finds deleted files that are still open; their space comes back only when the process closes them.

**Fix:** `break-fix.sh fix 2` removes the file. In real life also look at old images (`docker image prune -a`),
the build cache, container JSON logs, and the number of backups kept.

## 3. Wrong DATABASE_URL

**Break:** the script writes `/tmp/ems-break-fix/bad-database-url.yml`. That override sets the database host to
`db-typo` and the password to a wrong value. It then recreates only the app (`up -d --no-deps app`).

**Symptoms:** `create_app()` runs `db.create_all()` at start-up, so every gunicorn worker fails to boot
with `OperationalError ... failed to resolve host 'db-typo'`. gunicorn exits with `Reason: Worker failed to
boot`, and Docker restarts the container again and again: `docker compose ps` shows `Restarting (3)` and
`RestartCount` grows. nginx is fine and answers 502, so netcheck passes `tcp` and fails `http`. If the
database is lost *after* the app has started, the symptom is different: the app stays up and `/health`
answers 503 `{"status": "degraded", "database": "unhealthy: ..."}`.

**Diagnose:** `docker inspect ems-app-1 --format '{{json .Config.Env}}'` shows the URL the process really
received (hide the password before you paste it anywhere). Compare it with `.env`. Then check the database
itself: `docker compose exec db pg_isready -U ems`.

**Lesson:** a container's environment is fixed when the container is *created*. After you edit `.env`,
`docker compose restart app` does **not** pick up the change. You need `docker compose up -d app`, which
recreates the container. In Phase 12 the equivalent was editing `/etc/ems/ems.env` and running
`systemctl restart ems`.

**Fix:** `break-fix.sh fix 3` recreates the app from the real files and deletes the override.

## 4. nginx configuration syntax error

**Break:** the script copies `nginx/default.conf` to `/tmp/ems-break-fix/conf.d/` and deletes one semicolon
(`listen 80 default_server`). It then runs `nginx -t` inside the nginx container against the copy. The live
file and the running nginx are **not** touched.

**Symptom:** `nginx: [emerg] invalid parameter "server_name" in .../default.conf:26`. The error is reported on
the line *after* the missing semicolon, because nginx reads the next line as more arguments to `listen`.

**What would happen live:** `nginx -s reload` with a bad file is refused, and the old configuration keeps
serving. A *restart*, or a recreate of the container, would crash nginx. The container then restarts in a
loop, and `docker compose ps` shows `Restarting`.

**Safe change procedure:**
```
edit nginx/default.conf
docker compose exec nginx nginx -t          # the file is bind-mounted, so the container sees the edit
docker compose exec nginx nginx -s reload   # only after the test passes
```

**Fix:** `break-fix.sh fix 4` copies the good file back over the broken copy and runs `nginx -t` again.

## 5. Port conflict on the HTTP port

**Break:** the script stops ems nginx and starts a container named `ems-breakfix-rogue` that publishes the
same host port (80, or 8080 locally). It then tries `docker compose start nginx`.

**Symptom:** `Bind for 0.0.0.0:80 failed: port is already allocated`, and the ems nginx stays down. With a
non-Docker process holding the port, for example an `apache2` package installed by mistake, the error is
`address already in use`. Another server answers on the port, so `/health` returns that server's 404 or
welcome page, not the EMS JSON. That is why netcheck checks the *application* layer and not only HTTP.

**Diagnose:**
```
sudo ss -tlnp 'sport = :80'                   # which process holds the port
docker ps --filter publish=80                 # which container publishes it
```

**Fix:** `break-fix.sh fix 5` removes the rogue container and runs `docker compose up -d --wait nginx`.
For a host package: `sudo systemctl disable --now apache2`, and then work out why it was installed.

---

## Write it down

For every scenario, add a short entry to `docs/learning-log/` with five lines: *symptom, first failing layer,
root cause, fix, how I would detect it automatically*. The last answer is how the Phase 24 alerts came about:
`EMSAppDown`, `EMSDatabaseDown`, `HostDiskSpaceLow` (node-exporter) and `ContainerRestarting` (cAdvisor) in `monitoring/prometheus/rules/ems-alerts.yml`.
