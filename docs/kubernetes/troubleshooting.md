# Kubernetes troubleshooting (Phase 23)

Start every investigation with one screen of facts:

```bash
scripts/k8s/k8s-triage.sh                    # namespace ems
scripts/k8s/k8s-triage.sh -n ems-samples     # the practice workloads in k8s_samples/
```

It prints pods, workloads, Services with endpoints, recent Warning events, and for each unhealthy pod the
container state (reason, exit code, restarts), the describe Conditions/Events and the logs of the previous
container. Then narrow down with the table.

## Symptom -> command -> cause

| Symptom | Command | Likely cause | Fix |
|---|---|---|---|
| `ErrImagePull` / `ImagePullBackOff` | `kubectl describe pod P` (Events) | wrong tag/name; private registry without credentials; on kind the image was not loaded | correct the tag; `kind load docker-image ems-app:local --name ems`; EKS: node role needs `AmazonEC2ContainerRegistryReadOnly` |
| `CrashLoopBackOff` | `kubectl logs P --previous`; `describe` (Last State, Exit Code) | the app exits at start: bad command (127), missing setting, e.g. `SECRET_KEY must be set` (1) | fix the command or the ConfigMap/Secret; `kubectl rollout undo deploy/ems-app` |
| `OOMKilled`, exit code 137 | `kubectl describe pod P` (Last State: Reason OOMKilled) | memory limit too low for the process (or a leak) | raise `limits.memory`; fewer `GUNICORN_WORKERS` per pod |
| Exit 137 but **not** OOMKilled, events `Liveness probe failed` | `kubectl describe pod P` | liveness probe kills a slow/hung process; probe timeout too short on a CPU-throttled pod | fix the hang; raise `timeoutSeconds`; use a `startupProbe` for slow boots |
| `Running` but `0/1 READY`, no restarts | `kubectl describe pod P` (Readiness probe failed ...); `kubectl get endpoints` | readiness probe fails: wrong path/port, or `/health` 503 because the DB is down | fix the probe path; check `postgres-0`, the Secret, the NetworkPolicy |
| `Pending`, NODE `<none>` | `kubectl describe pod P` (FailedScheduling) | requests larger than any node; taints; nodeSelector; PVC unbound; namespace quota | lower requests; add nodes; fix the StorageClass |
| Pod not created at all, ReplicaSet shows `0/2` | `kubectl describe rs -l app.kubernetes.io/name=ems-app`; `kubectl get events` | ResourceQuota/LimitRange rejected it (`exceeded quota`, e.g. the playground 3-pod limit during a surge) | `maxSurge: 0`; fewer replicas; limits within the LimitRange |
| `CreateContainerConfigError` | `kubectl describe pod P` (`configmap ... not found` / `secret ... not found` / `couldn't find key`) | referenced ConfigMap/Secret/key missing (e.g. `k8s/base/secret.env` never created) | create it; `kubectl apply -k` again |
| `ContainerCreating` for minutes | `kubectl describe pod P` (FailedMount / FailedAttachVolume) | volume cannot be mounted: PVC pending, EBS in another AZ, missing EBS CSI driver | fix storage; check `kubectl get pvc,pv` |
| Pods Ready but Service gives timeouts / refused | `kubectl get endpoints SVC`; `kubectl get svc SVC -o wide` vs `kubectl get pods --show-labels` | selector does not match the pod labels; wrong `targetPort` | match labels; `targetPort: http` (named port) |
| App logs `connection timed out` to `postgres:5432` | `kubectl get networkpolicy -o yaml`; `kubectl get pods --show-labels` | NetworkPolicy does not admit the client's labels | label the client correctly or widen the policy |
| App logs `could not translate host name "postgres"` | `kubectl get svc postgres`; `kubectl run -it --rm dns --image=busybox:1.36 -- nslookup postgres.ems` | Service missing or in another namespace; CoreDNS down | create the Service; use `postgres.<namespace>` across namespaces |
| `curl localhost:8081` refused | `docker ps` (port mapping of `ems-control-plane`); `kubectl get svc ems-app` | kind cluster created without `k8s/kind-config.yaml`, or Service not NodePort 30080 | recreate the cluster with the config; apply overlay `local` |
| Ingress returns 404 / 503 | `kubectl get ingress ems`; `kubectl -n ingress-nginx logs deploy/ingress-nginx-controller` | no controller / wrong `ingressClassName` (404); no ready endpoints behind the Service (503) | install ingress-nginx; fix readiness |
| HPA `TARGETS <unknown>` | `kubectl describe hpa ems-app` | metrics-server not installed, or the container has no CPU request | install metrics-server (on kind add `--kubelet-insecure-tls`); keep `requests.cpu` |
| Rollout stuck: `Waiting for deployment ... 1 out of 2 new replicas` | `kubectl rollout status deploy/ems-app`; triage | new pods never become ready | `scripts/k8s/k8s-rollout.sh` undoes it automatically; manual: `kubectl rollout undo deploy/ems-app` |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | the process finished (wrong for a server: check `command`) |
| 1 | application error: read `logs --previous` |
| 126 / 127 | command not executable / not found |
| 137 | SIGKILL: OOMKilled or killed after failing liveness |
| 143 | SIGTERM: normal shutdown (rollout, scale down, node drain) |

## Practise

`k8s_samples/README.md` has eight broken workloads with symptom, diagnosis command and fix for each.
