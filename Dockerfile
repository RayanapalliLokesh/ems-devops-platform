# syntax=docker/dockerfile:1
# Phase 17 - one image, built once, run everywhere (Compose on EC2, kind, EKS)

# ---- build stage: compile/download wheels into a virtual environment ------------------------------------
FROM python:3.12-slim AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /build
COPY requirements.txt .
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install -r requirements.txt

# ---- runtime stage: only the venv and the code, as a non-root user ---------------------------------------
FROM python:3.12-slim AS runtime
ARG APP_VERSION=dev
ARG VCS_REF=unknown
LABEL org.opencontainers.image.title="ems-app" \
      org.opencontainers.image.description="Employee Management System (Flask + gunicorn)" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/RayanapalliLokesh/ems-devops-platform"

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    FLASK_ENV=production \
    APP_VERSION=${APP_VERSION} \
    GUNICORN_BIND=0.0.0.0:5000 \
    GUNICORN_WORKER_TMP_DIR=/dev/shm \
    PROMETHEUS_MULTIPROC_DIR=/tmp/prometheus \
    LOG_FORMAT=json \
    LOG_FILE=

RUN groupadd --system --gid 10001 ems \
    && useradd --system --uid 10001 --gid ems --home-dir /app --shell /usr/sbin/nologin ems
WORKDIR /app
COPY --from=build /opt/venv /opt/venv
COPY --chown=10001:10001 app/ ./app/
COPY --chown=10001:10001 config.py run.py gunicorn.conf.py ./
RUN mkdir -p /app/data /app/logs && chown 10001:10001 /app/data /app/logs

USER 10001
EXPOSE 5000
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:5000/health', timeout=2).status == 200 else 1)"]
CMD ["gunicorn", "--config", "gunicorn.conf.py", "run:app"]
