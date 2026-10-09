#!/usr/bin/env bash
# Phase 24 - Prometheus + Grafana on Kubernetes (k8s/monitoring). The rules and dashboards stay in
# monitoring/ (one copy for Compose and Kubernetes); this script turns them into ConfigMaps.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAMESPACE="monitoring"
TIMEOUT="180s"
DRY_RUN=0

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--dry-run] [--timeout 180s] [--help]

Creates ConfigMaps prometheus-rules (monitoring/prometheus/rules/*.yml) and grafana-dashboards
(monitoring/grafana/dashboards/*.json) in namespace "$NAMESPACE", a random Grafana admin password,
then applies k8s/monitoring and waits for Prometheus and Grafana.
Open them with: kubectl -n $NAMESPACE port-forward svc/prometheus 9090  (or svc/grafana 3000)

  --dry-run     print the commands instead of running them
  --timeout     how long to wait for each rollout (default: $TIMEOUT)
  --help        show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '+'; printf ' %q' "$@"; printf '\n'
    else
        "$@"
    fi
}

# render a ConfigMap/Secret client-side and apply it (create-or-update)
apply_generated() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '+'; printf ' %q' kubectl "$@" --dry-run=client -o yaml; printf ' | kubectl apply -f -\n'
    else
        kubectl "$@" --dry-run=client -o yaml | kubectl apply -f -
    fi
}

run kubectl apply -f "$ROOT/k8s/monitoring/namespace.yaml"
apply_generated -n "$NAMESPACE" create configmap prometheus-rules --from-file="$ROOT/monitoring/prometheus/rules"
apply_generated -n "$NAMESPACE" create configmap grafana-dashboards --from-file="$ROOT/monitoring/grafana/dashboards"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ create secret grafana-admin with a random password (only if it does not exist)"
elif ! kubectl -n "$NAMESPACE" get secret grafana-admin >/dev/null 2>&1; then
    kubectl -n "$NAMESPACE" create secret generic grafana-admin \
        --from-literal=password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
fi
run kubectl apply -k "$ROOT/k8s/monitoring"
run kubectl -n "$NAMESPACE" rollout status deployment/prometheus --timeout "$TIMEOUT"
run kubectl -n "$NAMESPACE" rollout status deployment/grafana --timeout "$TIMEOUT"
