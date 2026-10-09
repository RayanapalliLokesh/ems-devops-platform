# Logs (Phase 24)

Both nginx and the app write **one JSON object per line** to stdout. Docker keeps them (`docker logs`), and any
pipeline (CloudWatch, Loki, `kubectl logs | jq`) can parse them without regexes.

## App log line

Enabled by `LOG_FORMAT=json` (set in the Dockerfile; local development uses the text format). Written by
`JsonFormatter` in [`app/observability.py`](../../app/observability.py); the request line comes from `after_request`.

```json
{"ts": "2026-10-09T10:15:02", "level": "INFO", "logger": "observability", "message": "GET /api/employees 200",
 "request_id": "7f3c9a0d2b8e4f61a5c3d9e8b7a6f5e4", "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736",
 "method": "GET", "path": "/api/employees", "status": 200, "duration_ms": 12.48, "remote_addr": "203.0.113.7"}
```

| Field | Meaning |
|---|---|
| `ts`, `level`, `logger`, `message` | always present; `level` is `ERROR` for any 5xx response |
| `request_id` | the `X-Request-ID` of this request (see below) |
| `trace_id` | 32-hex OpenTelemetry trace id, `null` when tracing is off |
| `method`, `path`, `status`, `duration_ms` | the request and its outcome |
| `remote_addr` | the client IP (behind nginx + ALB thanks to `TRUSTED_PROXIES` / ProxyFix) |
| `exception` | traceback, on lines logged with an exception |

`/metrics` and `/livez` are not logged (they would drown the log) but are still counted in the metrics.
Gunicorn's own lines (boot, worker timeouts) are plain text on stderr; use `jq -R 'fromjson?'` to skip them.

## nginx log line

`log_format ems_json` in [`nginx/default.conf`](../../nginx/default.conf):

```json
{"ts":"2026-10-09T10:15:02+00:00","remote_addr":"10.0.1.23","xff":"203.0.113.7","request_id":"7f3c9a0d2b8e4f61a5c3d9e8b7a6f5e4",
 "method":"GET","path":"/api/employees","status":200,"bytes":5120,"duration_s":0.013,"upstream_s":"0.012","user_agent":"curl/8.5.0"}
```

`duration_s` is the total time at nginx, `upstream_s` the time the app took. Requests that never reached the app
or timed out (502/504) appear **only** here.

## The request ID flow

```
client --(optional X-Request-ID)--> ALB --> nginx --X-Request-ID--> app --> response header X-Request-ID
                                             |                      |
                                     nginx log request_id     app log request_id (+ trace_id) --> Jaeger
```

1. **nginx**: `map $http_x_request_id $ems_request_id` keeps an incoming ID or generates one (`$request_id`,
   32 hex chars). It logs it and forwards it with `proxy_set_header X-Request-ID`. (The ALB adds no request ID
   of its own; it adds `X-Amzn-Trace-Id`.)
2. **app**: `before_request` accepts the header if it is 1-128 printable characters, otherwise generates a UUID.
   It is stored in `g.request_id`, written to the request log line and returned as the `X-Request-ID` response header.
3. **trace**: the same log line carries the `trace_id` of the OpenTelemetry span, which links to Jaeger.

## Following one request

```bash
# 1. make (or take) a request and note its ID
curl -si http://$ALB/api/employees | grep -i x-request-id
RID=7f3c9a0d2b8e4f61a5c3d9e8b7a6f5e4

# 2. on the host: nginx view and app view of the same request
docker logs --since 1h ems-nginx-1 2>&1 | jq -cR --arg r "$RID" 'fromjson? | select(.request_id == $r)'
docker logs --since 1h ems-app-1   2>&1 | jq -cR --arg r "$RID" 'fromjson? | select(.request_id == $r)'

# 3. the trace: take trace_id from the app line
TID=$(docker logs --since 1h ems-app-1 2>&1 | jq -rR --arg r "$RID" 'fromjson? | select(.request_id == $r) | .trace_id' | head -1)
echo "http://127.0.0.1:16686/trace/$TID"          # open through the SSH tunnel
```

Other everyday queries:

```bash
docker logs --since 15m ems-app-1 2>&1 | jq -cR 'fromjson? | select(.status >= 500)'                   # errors
docker logs --since 15m ems-app-1 2>&1 | jq -cR 'fromjson? | select(.duration_ms > 500) | {path, duration_ms, request_id}'
docker logs --since 1h  ems-app-1 2>&1 | jq -rR 'fromjson? | .path' | sort | uniq -c | sort -rn | head   # top paths
kubectl -n ems logs deploy/ems-app --since=15m | jq -cR 'fromjson? | select(.status >= 500)'           # Kubernetes
```

When a user reports an error, ask for the `X-Request-ID` shown by the browser's network tab: it leads straight
to the log lines and the trace.

## CloudWatch

The project keeps logs in Docker's json-file driver on the host (no extra cost). To ship them to CloudWatch Logs,
set the `awslogs` driver for the services (`logging: driver: awslogs`, `awslogs-group: /ems/dev/app`,
`awslogs-region`, `awslogs-stream: ...`) and allow `logs:CreateLogStream` / `logs:PutLogEvents` on the instance
role. Because every line is JSON, CloudWatch Logs Insights can query fields directly:

```
fields ts, status, path, duration_ms, request_id
| filter status >= 500
| sort ts desc
| limit 50
```

Whatever the destination, set rotation on the host (`max-size`, `max-file` in `/etc/docker/daemon.json`) so logs
cannot fill the disk ([HostDiskSpaceLow](../runbooks/HostDiskSpaceLow.md)).
