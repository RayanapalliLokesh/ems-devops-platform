# Kubernetes object guide (Phases 22-23)

The same `ems-app` image that Docker Compose runs (phase 17) runs on Kubernetes. Everything lives in
`k8s/`, built with Kustomize:

```
k8s/
  kind-config.yaml          kind cluster "ems": host 8081 -> NodePort 30080, host 8082/8443 -> ingress-nginx
  base/                     every object the app needs, namespace "ems"
  overlays/local/           kind: image ems-app:local, Service type NodePort 30080
  overlays/playground/      EKS: ECR image, 2 app pods + postgres = 3 pods, rolling update without surge
  monitoring/               Prometheus + Grafana in namespace "monitoring" (phase 24)
k8s_samples/                eight broken workloads in namespace "ems-samples" (phase 23)
scripts/k8s/                k8s-up.sh, k8s-rollout.sh, k8s-triage.sh, k8s-monitoring.sh, k8s-playground.sh
```

```
curl localhost:8081 -> kind node :30080 -> Service ems-app -> Pods (2 replicas, :5000)
curl localhost:8082 -> ingress-nginx -> Ingress ems -> Service ems-app -> Pods
                                         Service postgres (headless) -> StatefulSet postgres-0 -> PVC
```

## Quick start (kind)

```bash
docker build -t ems-app:local .
scripts/k8s/k8s-up.sh              # add --ingress for ingress-nginx on :8082, --dry-run to see the commands
curl localhost:8081/health
scripts/k8s/k8s-rollout.sh --tag 1.2.3       # rolls back by itself if the new pods never become ready
scripts/k8s/k8s-triage.sh                     # one screen: pods, events, endpoints, failing pods + their logs
kind delete cluster --name ems
```

Host port 8080 stays with the Docker Compose stack, so kind uses 8081 (NodePort) and 8082 (ingress).

## The objects and why each one is here

| Object | Name | What it does here | Why |
|---|---|---|---|
| Namespace | `ems` | a folder for every EMS object | one `kubectl delete namespace ems` removes everything; quotas (playground: 3 pods) apply per namespace |
| ConfigMap | `ems-config-<hash>` | non-secret settings (`FLASK_ENV`, `LOG_FORMAT`, `TRUSTED_PROXIES`, `GUNICORN_WORKERS`, DB name/user) generated from `k8s/base/config.env` | the phase 10 idea (config from environment variables) without rebuilding the image. The hash suffix changes when the content changes, so the Deployment rolls out new pods automatically |
| Secret | `ems-secret-<hash>` | `SECRET_KEY`, `POSTGRES_PASSWORD` from the gitignored `k8s/base/secret.env` (template: `secret.env.example`; `k8s-up.sh` generates random values) | passwords never go to git and are kept apart from plain config (RBAC can restrict Secrets separately). Note: a Secret is only base64, not encrypted, unless etcd encryption / an external secret store is used |
| Deployment | `ems-app` | keeps 2 identical app pods running, replaces any pod that dies, and rolls out new images pod by pod (`maxSurge: 1`, `maxUnavailable: 0`: capacity never drops) | stateless pods are interchangeable, so a Deployment (via a ReplicaSet) is the right controller. `DATABASE_URL` is built with `$(POSTGRES_PASSWORD)` expansion from the Secret, so the password lives in one place |
| initContainer | `wait-for-postgres` | waits until `postgres:5432` accepts TCP connections | on a fresh cluster the app would otherwise crash-loop until PostgreSQL is up. Uses the app image: nothing extra to pull |
| Probes | startup, liveness, readiness | startup `/livez` (up to 90 s for boot), liveness `/livez`, readiness `/health` | see the self-check question below |
| securityContext | | `runAsNonRoot`, uid 10001 (the image's user), `readOnlyRootFilesystem`, no capabilities, no privilege escalation, `RuntimeDefault` seccomp; `/tmp` (Prometheus multiprocess dir), `/app/data` and `/app/logs` are `emptyDir` volumes | an attacker inside the container cannot write to the image or become root |
| Resources | requests 100m/192Mi, limits 250m/384Mi | requests reserve capacity for scheduling and are the base of the HPA percentage; limits cap a runaway pod (CPU is throttled, memory over the limit = OOMKilled) | fits the playground limit of 256m CPU / 512Mi per pod |
| Service | `ems-app` | stable name `ems-app.ems.svc` and port 80 -> container port 5000, load-balanced over the **ready** pods only. Overlay local turns it into `NodePort 30080` | pod IPs change on every restart; the Service name does not |
| StatefulSet | `postgres` | one PostgreSQL pod with a stable name (`postgres-0`) and its own PersistentVolumeClaim `data-postgres-0` (1Gi) | data must survive pod restarts; a StatefulSet re-attaches the same volume to the same pod identity |
| Headless Service | `postgres` | `clusterIP: None`: DNS `postgres` resolves straight to the pod IP | the app connects to `postgres:5432` exactly like in Compose |
| PersistentVolumeClaim | `data-postgres-0` | storage request; kind's `standard` StorageClass (local-path) or EBS on EKS provides the volume | deleting the pod (or the StatefulSet) keeps the data; deleting the PVC deletes it |
| NetworkPolicy | `postgres-allow-app-only` | only pods labelled `app.kubernetes.io/name=ems-app` may connect to PostgreSQL on 5432; everything else is dropped | a compromised or mistaken pod elsewhere cannot reach the database. Verified on kind (kindnet enforces policies since kind 0.24): a test pod times out, an app pod connects |
| Ingress | `ems` | HTTP routing (`/` -> Service `ems-app`) for the `nginx` ingress class | one HTTP entry point with TLS, host and path rules, instead of a NodePort/LoadBalancer per Service. Needs a controller: ingress-nginx (`k8s-up.sh --ingress`; on EKS behind an NLB) |
| HorizontalPodAutoscaler | `ems-app` | 2-4 pods (playground: 1-2) at 70% of the CPU request | adds pods under load, removes them when idle. Needs metrics-server (not in kind by default: the HPA then shows `<unknown>` and keeps the current replicas) |
| Prometheus annotations | `prometheus.io/scrape/port/path` | Prometheus in `k8s/monitoring` discovers the app pods through the API and scrapes `/metrics` with `job="ems-app"` | the alert and SLO rules in `monitoring/prometheus/rules/` work unchanged |

### Base and overlays (Kustomize)

`base/` holds the objects that are the same everywhere. An overlay lists `../../base` and changes only what
differs: `local` sets the image `ems-app:local` and makes the Service a NodePort; `playground` sets the ECR
image (placeholders `ACCOUNT_ID` / `IMAGE_TAG`, filled in by `scripts/k8s/k8s-playground.sh`), caps the HPA at
2 and rolls pods without a surge pod so the namespace never needs a 4th pod. Render without applying:
`kubectl kustomize k8s/overlays/playground`.

### Rollouts and rollbacks

`kubectl set image` creates a new ReplicaSet; the Deployment only removes an old pod after a new one is
**ready**. A broken image therefore never takes the app down: the new pod stays in `ImagePullBackOff` or
`0/1` while the old pods keep serving. `scripts/k8s/k8s-rollout.sh` waits with `kubectl rollout status
--timeout` and runs `kubectl rollout undo` when the timeout expires, then exits 1 so CI marks the deploy red.

## Self-check: why `/livez` for liveness and `/health` for readiness?

`/health` runs `SELECT 1` and returns 503 when PostgreSQL is unreachable. If the **liveness** probe used
`/health`, a database outage would make every app pod fail its liveness probe at the same time; the kubelet
would kill and restart all of them, over and over (a restart storm with growing CrashLoopBackOff delays). A
restart cannot fix the database, so this only adds damage: no pod can answer even static or cached
requests, the restarts hammer the recovering database with fresh connections, and when the database comes
back the pods are still in back-off and recover late.

So the two questions are kept apart:
- **liveness = `/livez`**: "is this process alive?" No database call. Fails only if gunicorn is hung, and
  then a restart really is the fix.
- **readiness = `/health`**: "can this pod serve traffic right now?" During a database outage the pods turn
  `0/1 Ready`, the Service stops sending them traffic (endpoints become empty), but they keep running; the
  moment `/health` returns 200 again they rejoin the Service without a restart.
- **startup = `/livez`**: gives a slow boot (imports, DB init, seeding) up to 90 s before liveness starts
  counting, so a slow start is not mistaken for a hang.

The other tools in the project (systemd timer, ALB target group, Docker HEALTHCHECK, Prometheus `ems_db_up`)
keep using `/health` because for them "unhealthy" means "stop sending traffic / alert", not "kill the process".
