# Dockerfile review, line by line

The image `ems-app` is built once and runs unchanged on Compose (EC2), kind and EKS. Each line below explains
what the instruction does and why it is written that way. `scripts/image-report.sh` checks the result
(non-root, healthcheck, size).

## Build stage

```dockerfile
# syntax=docker/dockerfile:1
```
This line pins the Dockerfile frontend to the stable 1.x syntax. BuildKit fetches it, so features such as
`COPY --chown` and heredocs behave the same on every builder (your laptop, GitHub Actions).

```dockerfile
FROM python:3.12-slim AS build
```
The first of two stages. `slim` is Debian with Python and nothing else. Every dependency in
requirements.txt ships manylinux wheels (`psycopg[binary]`, numpy, pandas), so no compiler is needed.
`alpine` was rejected: musl libc means numpy and pandas have to compile from source, which makes the build
slow and the image no smaller.

```dockerfile
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
```
No pip download cache in the layer, which would add tens of MB of `.whl` files, and no version-check
network call.

```dockerfile
WORKDIR /build
COPY requirements.txt .
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install -r requirements.txt
```
**Layer caching:** only `requirements.txt` is copied before the install, so a code change does not reinstall
the dependencies. The rebuild after a code edit takes seconds. The dependencies go into a **virtual
environment** at `/opt/venv`, a single folder that the next stage can copy whole.

## Runtime stage

```dockerfile
FROM python:3.12-slim AS runtime
```
A fresh, clean base. Nothing from the build stage comes along except what is copied explicitly: no pip
cache, no `/build`, and no build-only tools if any are added later. This is the point of a **multi-stage**
build.

```dockerfile
ARG APP_VERSION=dev
ARG VCS_REF=unknown
LABEL org.opencontainers.image.title="ems-app" ... version="${APP_VERSION}" revision="${VCS_REF}" source="https://github.com/..."
```
OCI labels record what the image is and where it came from. CI passes `APP_VERSION` (the tag) and `VCS_REF`
(the commit SHA), so `docker inspect` on any running container answers "which commit is this?". ECR and
scanners show these labels too.

```dockerfile
ENV PATH="/opt/venv/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 FLASK_ENV=production \
    APP_VERSION=${APP_VERSION} GUNICORN_BIND=0.0.0.0:5000 GUNICORN_WORKER_TMP_DIR=/dev/shm \
    PROMETHEUS_MULTIPROC_DIR=/tmp/prometheus LOG_FORMAT=json LOG_FILE=
```
| Variable | Why |
|---|---|
| `PATH` | `gunicorn` and `python` come from the venv; no `source activate` is needed |
| `PYTHONDONTWRITEBYTECODE=1` | no `.pyc` writes at run time; the root file system is read-only anyway |
| `PYTHONUNBUFFERED=1` | log lines reach `docker logs` immediately, not when a buffer fills or at a crash |
| `FLASK_ENV=production` | production config by default, which runs `ProductionConfig.validate()` (refuses to start without `SECRET_KEY`) |
| `GUNICORN_BIND=0.0.0.0:5000` | inside a container, 127.0.0.1 would be reachable only from the container itself |
| `GUNICORN_WORKER_TMP_DIR=/dev/shm` | worker heartbeat files in RAM; no disk I/O stalls, works with `read_only: true` |
| `PROMETHEUS_MULTIPROC_DIR=/tmp/prometheus` | metrics shared across workers; `/tmp` is a tmpfs in Compose |
| `LOG_FORMAT=json`, `LOG_FILE=` | one JSON line per event to stdout, no log file; the platform collects stdout |

```dockerfile
RUN groupadd --system --gid 10001 ems \
    && useradd --system --uid 10001 --gid ems --home-dir /app --shell /usr/sbin/nologin ems
```
A dedicated **non-root** user with a fixed high UID/GID. 10001 does not collide with users on the host or in
the base image (system users are below 1000, normal users start at 1000). It also matches Kubernetes'
`runAsUser: 10001` / `runAsNonRoot: true` (Phase 22). There is no login shell.

```dockerfile
WORKDIR /app
COPY --from=build /opt/venv /opt/venv
```
Only the finished venv crosses over from the build stage. It stays owned by root, so the app user cannot
modify its own libraries.

```dockerfile
COPY --chown=10001:10001 app/ ./app/
COPY --chown=10001:10001 config.py run.py gunicorn.conf.py ./
```
Only the code the app needs. `.dockerignore` keeps out `tests`, `docs`, `venv`, `.env*`, `.git`, `terraform`,
`k8s`, `scripts` and the rest. That keeps secrets out of the image and keeps the build context small. The
code goes in *after* the dependencies so that the cache order holds.

```dockerfile
RUN mkdir -p /app/data /app/logs && chown 10001:10001 /app/data /app/logs
```
The two writable folders. Compose mounts the volume `app-data` on `/app/data`. On a fresh volume, Docker
copies the folder's ownership (10001) into it, so the app can write without running as root.

```dockerfile
USER 10001
```
Everything from here, including `CMD`, `HEALTHCHECK` and `docker exec`, runs as uid 10001. The UID is given as
a number, not `ems`, so Kubernetes can verify `runAsNonRoot` without reading `/etc/passwd`.
`image-report.sh` fails the image if this line is missing.

```dockerfile
EXPOSE 5000
```
Documentation only. It does **not** publish the port. Compose deliberately has no `ports:` for the app; see
docs/networking/port-map.md.

```dockerfile
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=2).status == 200 else 1)"]
```
- It calls the real `/health`, which runs `SELECT 1` against the database, so "healthy" means the app can do
  its job.
- It uses Python's standard library instead of `curl`. `curl` is not in `slim`, and installing it would add
  packages and attack surface.
- **Exec form** (JSON array): no shell is needed.
- `start-period=20s` gives gunicorn time to boot, run `create_all()` and seed, without counting failures.
- After 3 failures the container is `unhealthy`. Compose's `depends_on: condition: service_healthy` holds
  nginx back until then. Docker itself does **not** restart an unhealthy container; Kubernetes uses separate
  probes for that (`/livez`, Phase 22).

```dockerfile
CMD ["gunicorn", "--config", "gunicorn.conf.py", "run:app"]
```
Exec form, so gunicorn is **PID 1** and receives `SIGTERM` from `docker stop` directly. It then shuts down
gracefully within `graceful_timeout = 20`. With shell form (`CMD gunicorn ...`), `/bin/sh` would be PID 1
and would not pass the signal on, and Docker would `SIGKILL` the app after 10 s.

## Runtime hardening in docker-compose.yml (not in the image)

| Setting | Effect |
|---|---|
| `read_only: true` | the root file system is read-only. A compromised process cannot change code or drop tools into it |
| `tmpfs: [/tmp]` | the only scratch space, in RAM, cleared on restart |
| `cap_drop: [ALL]` | no Linux capabilities (no `chown`, no `net_raw`, no binding to ports below 1024) |
| `mem_limit: 512m` | cgroup memory limit, the same as `MemoryMax=` in the Phase 12 unit |
| no `ports:` | reachable only on the `backend` network |

### Why `no-new-privileges` is not set

`security_opt: ["no-new-privileges:true"]` stops a process from gaining privileges through setuid binaries
or file capabilities. It is normally recommended. On this project's Ubuntu hosts with AppArmor, it made
**every `exec` in the container fail** with `operation not permitted`. That broke `docker compose exec`, the
`HEALTHCHECK`, and therefore `depends_on: service_healthy` and the whole start-up order. The combination of
the Docker AppArmor profile with `no_new_privs` blocked the profile transition on exec.

The setting was removed, and docker-compose.yml records why. The risk it covered is small here:

- The process already runs as **non-root** (10001).
- `cap_drop: [ALL]` empties the capability bounding set. Even a setuid-root binary cannot gain capabilities
  beyond that set, so a setuid escalation gets nothing useful.
- The image has no tools added beyond `python:3.12-slim`.

Kubernetes (Phase 22) sets `allowPrivilegeEscalation: false`, the same flag, on nodes where it works. Revisit
the Compose setting when the host's AppArmor profile is updated.

## Checklist (run before every push)

```
scripts/image-report.sh ems-app:local --max-size-mb 600
docker run --rm ems-app:local id            # uid=10001(ems) gid=10001(ems)
docker history ems-app:local                # no secrets in any layer's command
```
CI also scans the image (Trivy), and ECR scans on push.
