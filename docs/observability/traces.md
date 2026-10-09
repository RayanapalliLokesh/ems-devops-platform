# Traces (Phase 24)

Tracing answers "where did the time go in *this* request?": a trace is a tree of spans, one for the HTTP request
and one per SQL query inside it.

## Setup

Code: `init_tracing()` in [`app/observability.py`](../../app/observability.py). Packages (in `requirements.txt`):
`opentelemetry-sdk`, `opentelemetry-exporter-otlp-proto-http`, `opentelemetry-instrumentation-flask`,
`opentelemetry-instrumentation-sqlalchemy`.

| Piece | What it does |
|---|---|
| `TracerProvider` with resource `service.name=$OTEL_SERVICE_NAME` (default `ems-app`), `service.version=$APP_VERSION` | names the service in Jaeger and tags every span with the release |
| `FlaskInstrumentor().instrument_app(app, excluded_urls='metrics,livez')` | one server span per request (`GET /api/employees/<int:employee_id>`), with `http.method`, `http.route`, `http.status_code`; errors mark the span as failed |
| `SQLAlchemyInstrumentor().instrument(engine=db.engine)` | one child span per SQL statement, with `db.statement` and `db.system=postgresql` |
| `BatchSpanProcessor(OTLPSpanExporter(<endpoint>/v1/traces))` | exports spans in batches over OTLP/HTTP in the background (requests do not wait for the exporter) |

## Enabling it

Tracing is **off** unless `OTEL_EXPORTER_OTLP_ENDPOINT` is set: no endpoint, no instrumentation, no overhead
(tests and plain `docker-compose.yml` run without it).

```bash
# with the monitoring overlay it is set for you: OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger:4318
docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d

# or point the app at any OTLP/HTTP collector in /opt/ems/.env
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
OTEL_SERVICE_NAME=ems-app
```

The app log says `Tracing enabled: http://jaeger:4318` at start. Jaeger (`jaegertracing/all-in-one:1.62.0`) receives
OTLP on 4318 (`COLLECTOR_OTLP_ENABLED=true`), keeps up to `MEMORY_MAX_TRACES=20000` traces **in memory** (lost on
restart; fine for debugging, not an archive) and serves the UI on `127.0.0.1:16686`. Grafana has a Jaeger data
source too.

## Using it

```bash
ssh -L 16686:127.0.0.1:16686 ec2-user@$HOST     # then http://localhost:16686
```

- Search: Service `ems-app`, Operation e.g. `GET /api/employees`, Tags `error=true` or
  `http.status_code=500`, Min Duration `500ms`.
- From a log line: `trace_id` -> `http://localhost:16686/trace/<trace_id>`. From a request ID: see
  [logs.md](logs.md#following-one-request).
- API (scripts): `curl -s 'http://localhost:16686/api/traces?service=ems-app&minDuration=500ms&limit=20' | jq '.data[].traceID'`

Reading a trace:

| Shape | Meaning |
|---|---|
| request span long, one SQL span almost as long | a slow query: `EXPLAIN ANALYZE` the `db.statement` |
| many short SQL spans in a row | N+1 queries: load related rows in one query |
| request span long, SQL spans short, gaps between them | app CPU (serialisation, Python loops) or CPU throttling (check credits) |
| SQL span in error | the database rejected or dropped the query ([EMSDatabaseDown](../runbooks/EMSDatabaseDown.md)) |
| no trace for a request that has a log line | `trace_id` is `null`: tracing was off, or the request was `/metrics` / `/livez` |

## Limits

- Sampling is "always on" (every request). Fine at this traffic; at scale use a ratio sampler
  (`OTEL_TRACES_SAMPLER=parentbased_traceidratio`, `OTEL_TRACES_SAMPLER_ARG=0.1`).
- nginx creates no span; the trace starts in the app. The request ID ties nginx to it instead.
- Kubernetes: `k8s/monitoring` deploys Prometheus and Grafana only; set `OTEL_EXPORTER_OTLP_ENDPOINT` to a Jaeger
  or collector service there if needed.
