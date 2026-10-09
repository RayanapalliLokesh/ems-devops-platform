# Port map

Every port in `docker-compose.yml` and `docker-compose.monitoring.yml`, plus SSH and the ALB. On AWS, only
the ALB's port 80 is open to the internet. `tests/test_platform_scripts.py` checks that every port in the
Compose files, in the nginx `listen` and in the gunicorn bind appears in this table.

"Bound to" is the address the listener accepts connections on. **host** means it is published on the EC2
host. **container** means it is reachable only inside a Compose network, and the network is named in
brackets.

| Port | Listener | Bound to | Reachable from |
|---|---|---|---|
| 80 | ALB listener (HTTP) | the ALB's public addresses in public-a / public-b | the internet (security group `alb`: 80 from 0.0.0.0/0) |
| 80 | nginx, published as `${EMS_HTTP_PORT:-80}:80` | host `0.0.0.0:80` (docker-proxy), container `0.0.0.0:80` | only the ALB (security group `host`: 80 from group `alb`); locally anyone who can reach your machine |
| 8080 | nginx on a laptop, `EMS_HTTP_PORT=8080` in `.env.local` | host `0.0.0.0:8080` | your machine and your LAN (dev only; never on EC2) |
| 22 | sshd (host, not a container) | host `0.0.0.0:22` | your IP only (security group `host`: 22 from `my_ip/32`); ufw allows 22 in Phase 13 |
| 5000 | gunicorn (`GUNICORN_BIND=0.0.0.0:5000` in the image) | container `0.0.0.0:5000`, **not published** | nginx and Prometheus on the `backend` network |
| 5432 | PostgreSQL (`db`) | container `0.0.0.0:5432`, **not published** | the app on the `backend` network (and `docker compose exec db`) |
| 9090 | Prometheus UI/API | host `127.0.0.1:9090` | the host itself; you via `ssh -L 9090:127.0.0.1:9090` |
| 9093 | Alertmanager UI/API | host `127.0.0.1:9093` | the host itself; Prometheus via `alertmanager:9093` on `backend`/`monitoring` |
| 3000 | Grafana | host `127.0.0.1:3000` | the host itself; you via `ssh -L 3000:127.0.0.1:3000` |
| 16686 | Jaeger UI | host `127.0.0.1:16686` | the host itself; you via `ssh -L 16686:127.0.0.1:16686` |
| 4318 | Jaeger OTLP/HTTP collector | container, not published | the app (`OTEL_EXPORTER_OTLP_ENDPOINT=http://jaeger:4318`) on `backend` |
| 4317 | Jaeger OTLP/gRPC collector | container, not published | containers on `backend`/`monitoring` (unused by EMS) |
| 9100 | node-exporter metrics | container, not published (`pid: host`, own network namespace) | Prometheus on `monitoring` |
| 8080 | cAdvisor metrics/UI (container port) | container, not published | Prometheus on `monitoring` (`cadvisor:8080`) |

Phase 12 and 13 history: before containers, gunicorn bound `127.0.0.1:5000` and PostgreSQL bound
`127.0.0.1:5432` on the host. ufw allowed only 22 and 80. The exposure rule is the same today: **only 80 (and
22) are reachable from outside.** Containers enforce it differently: a port without `ports:` is not published
on the host at all.

## How to verify

```
sudo ss -tlnp                                                   # what really listens on the host
docker compose -p ems ps --format 'table {{.Service}}\t{{.Ports}}'
scripts/net/netcheck.sh --host 127.0.0.1 --port 80              # layer 5 "exposure" probes 5000/5432
                                                                # and the monitoring ports on the primary IP
```

Docker publishes ports with its own iptables rules (the `DOCKER` chain), and those rules are evaluated
**before** ufw's INPUT rules. `ports: ["5000:5000"]` would therefore be reachable even with `ufw deny 5000`.
For that reason this project never publishes app or db ports, and binds the monitoring UIs to `127.0.0.1`.
See firewall.md.
