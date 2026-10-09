#!/usr/bin/env bash
# Phase 23 - one screen of "what is wrong in this namespace": the Kubernetes version of scripts/triage.sh.
set -euo pipefail

NAMESPACE="ems"
EVENTS=15
DRY_RUN=0

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--namespace ems] [--events 15] [--dry-run] [--help]

Shows, for one namespace: pods that are not Running/Ready, recent warning events, workloads,
Services with their endpoints, and for every unhealthy pod the describe summary and the logs
of the previous (crashed) container.

  --namespace   namespace to inspect (default: $NAMESPACE; k8s_samples use ems-samples)
  --events      how many recent events to show (default: $EVENTS)
  --dry-run     print the commands instead of running them
  --help        show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace) NAMESPACE="${2:?--namespace needs a value}"; shift ;;
        --events) EVENTS="${2:?--events needs a value}"; shift ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '+'; printf ' %q' "$@"; printf '\n'
    else
        "$@" || true      # triage keeps going: one failing command must not hide the rest
    fi
}

section() { printf '\n=== %s ===\n' "$1"; }

section "pods ($NAMESPACE)"
run kubectl -n "$NAMESPACE" get pods -o wide

section "workloads"
run kubectl -n "$NAMESPACE" get deployments,statefulsets,replicasets,hpa

section "services and endpoints (an empty ENDPOINTS column = selector matches no ready pod)"
run kubectl -n "$NAMESPACE" get services,endpoints

section "recent warning events"
if [[ "$DRY_RUN" -eq 1 ]]; then
    run kubectl -n "$NAMESPACE" get events --field-selector type=Warning --sort-by=.lastTimestamp
else
    kubectl -n "$NAMESPACE" get events --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null \
        | tail -n "$EVENTS" || true
fi

section "unhealthy pods"
if [[ "$DRY_RUN" -eq 1 ]]; then
    run kubectl -n "$NAMESPACE" describe pod POD
    run kubectl -n "$NAMESPACE" logs POD --all-containers --previous --tail 20
    exit 0
fi

# a pod is unhealthy when it is not Running/Succeeded or one of its containers is not ready
unhealthy="$(kubectl -n "$NAMESPACE" get pods --no-headers \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready' 2>/dev/null \
    | awk '$2 == "Succeeded" { next } $2 != "Running" || $3 ~ /false/ || $3 == "<none>" { print $1 }')" || true

if [[ -z "$unhealthy" ]]; then
    echo "all pods are Running and Ready"
    exit 0
fi

for pod in $unhealthy; do
    printf '\n--- %s ---\n' "$pod"
    kubectl -n "$NAMESPACE" get pod "$pod" \
        -o jsonpath='{range .status.containerStatuses[*]}{.name}: restarts={.restartCount} waiting={.state.waiting.reason} {.state.waiting.message} lastTerminated={.lastState.terminated.reason} exit={.lastState.terminated.exitCode}{"\n"}{end}' \
        2>/dev/null || true
    kubectl -n "$NAMESPACE" describe pod "$pod" 2>/dev/null \
        | sed -n '/^Conditions:/,/^Volumes:/p;/^Events:/,$p' | grep -v '^Volumes:' | tail -n 15 || true
    echo "logs of the previous container:"
    kubectl -n "$NAMESPACE" logs "$pod" --all-containers --previous --tail 10 2>/dev/null \
        || kubectl -n "$NAMESPACE" logs "$pod" --all-containers --tail 10 2>/dev/null \
        || echo "(no logs: the container never started)"
done
