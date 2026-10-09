# Image size and build optimisation

## Measured (scripts/image-report.sh, 2026-10-09, `ems-app:local`)

```
$ scripts/image-report.sh ems-app:local
Image report: ems-app:local (sha256:2f8a37288c84)

INFO  size         491 MB (uncompressed; add --max-size-mb N to enforce a limit)
INFO  layers       10 file system layers
PASS  user         10001 (non-root)
PASS  healthcheck  every 15s: CMD python -c import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127....
INFO  ports        5000/tcp
INFO  command      null ["gunicorn","--config","gunicorn.conf.py","run:app"]

biggest layers (docker history):
  248MB    COPY /opt/venv /opt/venv # buildkit
  87.7MB   # debian.sh --arch 'amd64' out/ 'trixie' '@1791158400'
  41.4MB   RUN /bin/sh -c set -eux;   savedAptMark="$(apt-mark showmanual)";  apt-get update;  apt-ge
  4.94MB   RUN /bin/sh -c set -eux;  apt-get update;  apt-get install -y --no-install-recommends   ca
  77.8kB   COPY --chown=10001:10001 app/ ./app/ # buildkit

image review passed
```

How to read the numbers:

- **491 MB** is the size Docker reports for the image. This host uses the containerd image store, so the
  figure covers the unpacked layers (`docker image ls` shows the same `491MB`). The **compressed** content
  that is pulled from ECR is about **109 MB** (the `CONTENT SIZE` column of `docker image ls`). Pull time and
  ECR storage depend on that number.
- The base image `python:3.12-slim` accounts for about 134 MB (87.7 + 41.4 + 4.9 MB).
- **The venv is 248 MB, half the image.** The application code is 78 kB. Inside the venv
  (`du -sh site-packages/*`): pandas 75 MB, numpy 43 MB plus 27 MB of bundled OpenBLAS (`numpy.libs`),
  SQLAlchemy 28 MB, psycopg-binary 19 MB, pip itself 13 MB, OpenTelemetry 5 MB.

CI (Phase 18, job `docker`) runs `image-report.sh --max-size-mb 600`. That leaves room to grow while catching
an accident such as a copied `venv/` or a build toolchain, either of which adds hundreds of MB.

## What is already optimised

| Technique | In the Dockerfile | Saves |
|---|---|---|
| `slim` base instead of `python:3.12` (full Debian with gcc) | `FROM python:3.12-slim` | about 900 MB |
| Multi-stage build: only `/opt/venv` crosses over | `COPY --from=build /opt/venv /opt/venv` | the pip cache and `/build`; any compiler added later stays out |
| No pip cache | `PIP_NO_CACHE_DIR=1` | 50 to 100 MB of wheel files |
| No bytecode written at run time | `PYTHONDONTWRITEBYTECODE=1` | writes to a read-only file system |
| `.dockerignore` | excludes venv, tests, docs, terraform, k8s, .git, .env* | build context of kB instead of hundreds of MB; no secrets in the image |
| Cache-friendly order | `requirements.txt` → install → code | a code-only rebuild reuses the 248 MB layer and takes seconds |
| Few layers | related `RUN`s chained with `&&` | 10 layers |

## Options not taken (yet), with their trade-offs

| Idea | Gain | Why not now |
|---|---|---|
| Drop pandas/numpy (used only by the statistics code in `app/services.py`) | about 145 MB of venv | it changes app code and behaviour; the stats module would need rewriting in plain Python. The biggest single win if size starts to matter |
| Remove pip from the runtime venv (`/opt/venv/bin/pip uninstall -y pip` at the end of the build stage) | 13 MB | small gain; a debugging session can no longer `pip list` inside the container (use `python -c "import importlib.metadata as m; print(sorted(d.name for d in m.distributions()))"` instead) |
| `pip install --no-compile`, strip `tests/` folders from site-packages | 20 to 40 MB | fragile (some packages ship needed data in such folders); slower imports without `.pyc` |
| Distroless (`gcr.io/distroless/python3`) | about 50 MB smaller base, no shell | no shell means no `docker exec ... sh` for troubleshooting, and the Python version must match the base. Revisit when debugging moves to ephemeral debug containers |
| `alpine` | smaller base | musl: numpy and pandas compile from source (slow builds), and subtle DNS and locale differences |
| BuildKit cache mount `RUN --mount=type=cache,target=/root/.cache/pip` | faster CI rebuilds when requirements change | needs cache export in CI; worth adding together with `cache-from: type=gha` |

## Commands

```
scripts/image-report.sh ems-app:local --max-size-mb 600      # the gate CI runs
docker history --no-trunc ems-app:local                       # every layer and the command that made it
docker run --rm ems-app:local sh -c 'du -sh /opt/venv/lib/python3.12/site-packages/* | sort -h | tail'
docker buildx du                                              # build cache size
docker image ls ems-app                                       # disk usage and content (compressed) size
```
