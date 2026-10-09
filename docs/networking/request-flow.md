# Request flow: browser to PostgreSQL and back

```
browser
  │  DNS: ems-alb-123.eu-west-1.elb.amazonaws.com → ALB node IPs (one per zone)
  ▼
ALB :80 (SG alb: 80 from 0.0.0.0/0)           adds  X-Forwarded-For: <client>
  │  target group, health check GET /health        X-Forwarded-Proto: http
  ▼
EC2 host :80 (SG host: 80 only from SG alb)
  │  docker-proxy / iptables DNAT
  ▼
nginx container :80                            appends the ALB IP: X-Forwarded-For: <client>, <alb>
  │  upstream app:5000 (Docker DNS 127.0.0.11, re-resolved by `resolve`)
  │  sets X-Request-ID, X-Real-IP, X-Forwarded-Proto; keepalive 16
  ▼
app container :5000 → gunicorn master → worker (2 workers x 2 threads)
  │  ProxyFix(x_for=2, x_proto=2) because TRUSTED_PROXIES=2
  ▼
Flask route → service layer → SQLAlchemy (psycopg) → db:5432 → PostgreSQL container
  │
  ▲  JSON back the same way; the app logs one JSON line with the request_id and trace_id,
     nginx logs one JSON line with the same request_id
```

Locally (Phase 13 and the laptop stack), the ALB step is missing: `browser → nginx (8080 or 80) → app → db`,
with `TRUSTED_PROXIES=1`.

## Hop by hop

| Hop | What happens | What can go wrong | How to see it |
|---|---|---|---|
| DNS | The ALB name resolves to 2 or more IPs that change over time. Never pin them | stale `/etc/hosts`, wrong name | `dig +short <alb-dns>`, netcheck layer `name` |
| ALB | Ends the client TCP connection and opens a new one to a healthy target; adds `X-Forwarded-*` | no healthy targets → `503`; target timeout → `504` | target group health in the console, `aws elbv2 describe-target-health` |
| Security groups | `host` accepts 80 only from the `alb` group | port 80 from 0.0.0.0/0 on the host = ALB bypass | `alb.sh verify` / Terraform plan |
| nginx | Reverse proxy, the only public listener; adds a request ID; `/metrics` returns 404 | app down → `502`; app slow → `504` after `proxy_read_timeout 35s` | `docker logs ems-nginx-1` (JSON: `status`, `upstream_s`) |
| gunicorn | Spreads requests over the workers; `timeout 30` kills a stuck worker | all workers busy → requests queue → latency | app log `WORKER TIMEOUT`, `ems_http_request_duration_seconds` |
| Flask | Routing, validation, JSON | `500` with a traceback in the log | app log `"level": "ERROR"` with the `request_id` |
| PostgreSQL | SQL through the SQLAlchemy pool | db down → `/health` 503 "degraded" | `docker compose exec db pg_isready`, `ems_db_up` metric |

## X-Forwarded-For and TRUSTED_PROXIES

Each proxy *appends* the address it received the connection from:

```
client 203.0.113.7 sends:             (no header, or a forged "X-Forwarded-For: 1.2.3.4")
ALB forwards:                         X-Forwarded-For: [1.2.3.4, ]203.0.113.7
nginx ($proxy_add_x_forwarded_for):   X-Forwarded-For: [1.2.3.4, ]203.0.113.7, 10.0.1.25   (10.0.1.25 = ALB node)
gunicorn sees REMOTE_ADDR:            172.19.0.4   (the nginx container)
```

The app must decide which entry is the real client. A client can write anything into the header, so the
*leftmost* entry is never trustworthy. What can be trusted is the number of proxies **we** run.
`TRUSTED_PROXIES=N` (config.py) wraps the app in `werkzeug.middleware.proxy_fix.ProxyFix(x_for=N, x_proto=N)`
(app/__init__.py). ProxyFix takes the N-th entry **from the right**:

| Deployment | Proxies we own | `TRUSTED_PROXIES` | Entry used (from the right) | `request.remote_addr` |
|---|---|---|---|---|
| `python run.py` (dev) | none | 0 (ProxyFix off) | — | the TCP peer |
| Phase 13 / local Compose | nginx | 1 | 1st = what nginx appended | the client (or your docker gateway) |
| AWS (Phase 15+) | ALB + nginx | **2** | 2nd = what the ALB appended | the real client 203.0.113.7 |

With 1 on AWS, every request would appear to come from the ALB's private IP (10.0.x.x). Rate limits and
audit logs would then be useless. With 3, an attacker could choose their own IP through a forged first
entry. `x_proto=N` works the same way for `X-Forwarded-Proto`, so redirects and `url_for(..., _external=True)`
use the scheme the client used.

gunicorn's `forwarded_allow_ips` (`FORWARDED_ALLOW_IPS="*"` in Compose) controls whether *gunicorn* trusts
the proxy headers from its peer. That is safe here because nothing except nginx can reach port 5000.

## The request ID

nginx keeps an incoming `X-Request-ID` or creates one (`$request_id`). It passes the ID to the app, and both
log it. Search for one request across both logs:

```
id=$(curl -si http://127.0.0.1/health | awk -F': ' 'tolower($1)=="x-request-id" {print $2}' | tr -d '\r')
docker compose -p ems logs app nginx | grep "$id"
```
Jaeger links the same request through `trace_id` (Phase 24).
