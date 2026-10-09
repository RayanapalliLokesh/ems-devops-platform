# Service model: from a systemd unit (Phase 12) to a container (Phase 17)

Phase 12 turned `python run.py` into a managed service: gunicorn run by systemd. Phase 17 moved the same
process into a container, and the Ansible role `ems_stack` retired the host services. **The repository is now
at the container stage.** This page explains the systemd model as history and maps each part to the line in
`Dockerfile` / `docker-compose.yml` that does the same job today.

## The process has not changed

In both models the process is the same:

```
gunicorn --config gunicorn.conf.py run:app      # 2 workers x 2 threads, timeout 30s, max_requests 1000
```

`gunicorn.conf.py` reads every setting from the environment. That lets one file serve both models:

| Setting | systemd (Phase 12) | container (Phase 17) |
|---|---|---|
| `GUNICORN_BIND` | default `127.0.0.1:5000`: only nginx on the same host can connect | `0.0.0.0:5000` (Dockerfile `ENV`): the container has its own network namespace, and nginx connects from another container |
| `GUNICORN_WORKER_TMP_DIR` | unset (disk) | `/dev/shm`: worker heartbeat files stay in RAM, which matters on a read-only root file system |
| `FORWARDED_ALLOW_IPS` | `127.0.0.1` | `*`: nginx's container IP changes, and only nginx can reach port 5000 anyway |

## The Phase 12 unit (for learning; no longer installed)

```ini
# /etc/systemd/system/ems.service  (Phase 12; removed by the ems_stack role in Phase 17)
[Unit]
Description=Employee Management System (gunicorn)
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=notify                       # gunicorn (20+) sends READY=1 to systemd once the workers are up
User=ems
Group=ems
WorkingDirectory=/opt/ems/current # symlink -> /opt/ems/releases/<version>
EnvironmentFile=/etc/ems/ems.env  # SECRET_KEY, DATABASE_URL ... mode 0640 root:ems
ExecStart=/opt/ems/current/venv/bin/gunicorn --config gunicorn.conf.py run:app
ExecReload=/bin/kill -s HUP $MAINPID
Restart=on-failure
RestartSec=3
TimeoutStopSec=25                 # longer than graceful_timeout = 20 in gunicorn.conf.py
KillMode=mixed

# sandbox
NoNewPrivileges=yes
ProtectSystem=strict              # the whole file system is read-only ...
ReadWritePaths=/opt/ems/shared/data /opt/ems/shared/logs   # ... except these
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
CapabilityBoundingSet=
MemoryMax=512M

[Install]
WantedBy=multi-user.target
```

Commands you used then: `systemctl status ems`, `journalctl -u ems -f`, `systemctl restart ems`,
`systemd-analyze security ems` (scores the sandbox).

### Releases through a symlink (Phase 12)

```
/opt/ems/releases/v1.0.0/   /opt/ems/releases/v1.1.0/   /opt/ems/current -> releases/v1.1.0
deploy:   unpack to releases/<new>; ln -sfn releases/<new> current.tmp && mv -T current.tmp current; restart
rollback: point current back to the previous folder; restart
```
`mv -T` is a single `rename()` system call, so `current` always points to a complete release, never to a
half-copied one. In Phase 17 a release is an **image tag** (`EMS_IMAGE_TAG`), and a rollback runs the older tag:
`EMS_IMAGE_TAG=v1.0.0 docker compose up -d app`.

## Mapping: each systemd setting and what replaced it

| Concern | systemd unit (Phase 12) | Container (Phase 17) | Where |
|---|---|---|---|
| Who the process runs as | `User=ems` (system user, no shell) | `USER 10001`, user `ems` uid/gid 10001, shell `/usr/sbin/nologin` | Dockerfile |
| Start at boot | `WantedBy=multi-user.target` + `systemctl enable` | `docker.service` is enabled, and it restarts containers that have a restart policy | docker-compose.yml `restart:` |
| Restart on crash | `Restart=on-failure`, `RestartSec=3` | `restart: unless-stopped` (does **not** restart after a manual `docker compose stop`) | docker-compose.yml |
| Start order | `After=`/`Requires=postgresql.service` | `depends_on: db: condition: service_healthy` (waits for health, not just for start) | docker-compose.yml |
| Configuration | `EnvironmentFile=/etc/ems/ems.env` | `.env` in `/opt/ems`, mode 0600, read by Compose and passed as `environment:` | docker-compose.yml, `.env.example` |
| Required secrets | the app refuses to start (`ProductionConfig.validate()`) | the same, and Compose refuses earlier: `${SECRET_KEY:?set SECRET_KEY in .env}` | docker-compose.yml |
| Read-only file system | `ProtectSystem=strict` + `ReadWritePaths=` | `read_only: true`, with writable `tmpfs: /tmp` and volume `app-data:/app/data` | docker-compose.yml |
| Private /tmp | `PrivateTmp=yes` | `tmpfs: - /tmp` (also holds `PROMETHEUS_MULTIPROC_DIR=/tmp/prometheus`) | docker-compose.yml |
| Capabilities | `CapabilityBoundingSet=` (none) | `cap_drop: [ALL]` | docker-compose.yml |
| No privilege gain | `NoNewPrivileges=yes` | **not set**: on this project's AppArmor hosts `no-new-privileges` made every `exec` fail with "operation not permitted". Non-root user and no capabilities already cover most of it (see docs/docker/image-review.md) | docker-compose.yml comment |
| Memory limit | `MemoryMax=512M` (cgroup) | `mem_limit: 512m` (the same cgroup setting) | docker-compose.yml |
| Health | none in systemd; checked by `triage.sh` / nginx | `HEALTHCHECK` calls `/health` every 15s; the status shows in `docker compose ps` and gates `depends_on` | Dockerfile |
| Logs | `journalctl -u ems` (stdout/stderr to journald) | `docker logs ems-app-1` (stdout/stderr, JSON lines, `LOG_FORMAT=json`, `LOG_FILE=` empty) | Dockerfile `ENV` |
| Graceful stop | `TimeoutStopSec=25`, SIGTERM then SIGKILL | `docker stop` sends SIGTERM, then SIGKILL after 10s (`stop_grace_period`) | Compose default |
| Network exposure | bind `127.0.0.1:5000` + ufw | no `ports:` on app or db; only nginx publishes 80 | docker-compose.yml |
| Release / rollback | symlink `current` | image tag | `EMS_IMAGE_TAG` |

## What stayed on the host after Phase 17

- **sshd** (port 22, security group: your IP only) and the **Docker engine**.
- `/opt/ems` holds `docker-compose.yml`, `docker-compose.monitoring.yml`, `nginx/default.conf` and `.env`.
- The PostgreSQL data lives in the Docker volume `ems_db-data`. During the migration `ems_stack` dumped the old
  host database and loaded it into the container.
- The `scripts/linux/*.sh` tools now work against the container stack: `triage.sh`, `backup-db.sh` and `break-fix.sh`.

## Quick equivalents

| Phase 12 | Phase 17 |
|---|---|
| `systemctl status ems` | `docker compose -p ems ps app` |
| `journalctl -u ems -n 50` | `docker compose -p ems logs --tail 50 app` |
| `systemctl restart ems` | `docker compose -p ems restart app` (same container) or `up -d app` (recreate with new config) |
| `sudo -u ems bash` | `docker compose -p ems exec app sh` (runs as uid 10001) |
| `cat /proc/$(pgrep -f gunicorn | head -1)/environ` | `docker inspect ems-app-1 --format '{{json .Config.Env}}'` |
