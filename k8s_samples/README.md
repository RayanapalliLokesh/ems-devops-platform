# k8s_samples: eight broken workloads (Phase 23)

Each file is one broken workload in namespace `ems-samples`; the real app in `ems` is never touched.
Start them, diagnose them with `scripts/k8s/k8s-triage.sh -n ems-samples`, then fix them one by one.

```bash
kubectl apply -k k8s_samples                     # all eight (or: kubectl apply -f k8s_samples/namespace.yaml -f k8s_samples/03-oom-killed.yaml)
scripts/k8s/k8s-triage.sh --namespace ems-samples
kubectl delete namespace ems-samples             # clean up
```

The yamllint config ignores this folder on purpose: some files are wrong by design.

| Sample | Symptom (what you see) | Diagnosis command | Cause | Fix |
|---|---|---|---|---|
| `01-image-pull-backoff` | `ErrImagePull` then `ImagePullBackOff`; container never starts | `kubectl -n ems-samples describe pod -l app=s01` (Events: `manifest unknown` / `not found`) | the image tag does not exist | use a tag that exists (`nginx:1.27.4-alpine`); on kind also `kind load docker-image`; on EKS check ECR + node IAM role |
| `02-crashloop` | `CrashLoopBackOff`, RESTARTS climbing, exit code 127 | `kubectl -n ems-samples logs deploy/s02-crashloop --previous` and `describe` (Last State: exit 127) | the command `/bin/start-server` is not in the image | fix `command:` (or remove it to use the image's own CMD) |
| `03-oom-killed` | `CrashLoopBackOff` / `OOMKilled`, exit code 137 | `kubectl -n ems-samples describe pod -l app=s03` (Last State: Terminated, Reason: OOMKilled) | the memory limit (16Mi) is below what the process needs (~64Mi) | raise `resources.limits.memory` (e.g. 128Mi) or make the process use less memory |
| `04-failing-readiness` | `Running` but `READY 0/1`, no restarts; Service has no endpoints | `kubectl -n ems-samples describe pod -l app=s04` (Readiness probe failed: HTTP 404) and `kubectl -n ems-samples get endpoints s04-failing-readiness` | the readiness probe path `/healthz` does not exist | point the probe at a real path (`/`); for EMS: `/health` |
| `05-pending-unschedulable` | `Pending`, NODE `<none>`, forever | `kubectl -n ems-samples describe pod -l app=s05` (FailedScheduling: Insufficient cpu) | requests 64 CPUs: no node fits | lower `resources.requests.cpu` (e.g. 100m) or add bigger nodes |
| `06-service-selector-mismatch` | pods Ready, but the Service gives timeouts / connection refused | `kubectl -n ems-samples get endpoints s06-web` (`<none>`) and compare `kubectl -n ems-samples get svc s06-web -o wide` with `get pods --show-labels` | the Service selector `app=s06-web` matches no pod (`app=s06`) | make the selector and the pod labels match |
| `07-missing-configmap` | `CreateContainerConfigError` | `kubectl -n ems-samples describe pod -l app=s07` (Error: configmap "s07-config" not found) | `envFrom` references a ConfigMap that does not exist | create it: `kubectl -n ems-samples create configmap s07-config --from-literal=LOG_LEVEL=INFO` (or mark it `optional: true`) |
| `08-networkpolicy-blocks-db` | client logs `db:5432 unreachable` (timeouts); both pods Running and Ready | `kubectl -n ems-samples logs deploy/s08-client`, `kubectl -n ems-samples get networkpolicy s08-db-allow-api -o yaml`, `kubectl -n ems-samples get pods --show-labels` | the policy only admits `role=api`; the client is `role=web` | label the client correctly (`role: api`) or widen the policy's `from` |

Reading the signals:
- **Timeout** to a Service usually means a NetworkPolicy (packets dropped) or no endpoints; **connection refused** means the pod
  is reachable but nothing listens on that port.
- **Exit code 137** = SIGKILL: OOMKilled (check `Reason`) or killed by a failing liveness probe (check Events).
- **Exit code 127** = command not found; **1** = the app itself failed: read `logs --previous`.
- **Pending** is always a scheduling problem: resources, taints, node selectors, or a PVC that does not bind.
