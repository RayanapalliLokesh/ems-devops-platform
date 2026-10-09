#!/usr/bin/env bash
# Chaos scenario: DNS failure (Phase 25, docs/sre/game-days.md#dns-failure)
#   compose  disconnect the db container from the backend network: the name "db" no longer resolves
#            for the app ("could not translate host name"), exactly like a broken DNS record
#   k8s      roll out ems-app pods whose only nameserver is an unroutable address (192.0.2.1, TEST-NET-1):
#            every lookup times out, readiness (/health) fails, the rollout stalls, old pods keep serving
# Expected alerts: compose -> EMSDatabaseDown + EMSErrorBudgetFastBurn; k8s -> none (that is the lesson).
set -euo pipefail

ACTION=""
DRY_RUN=false
TARGET=compose
DURATION=600
NAMESPACE=ems
PROJECT=ems

usage() {
    cat <<EOF
Usage: $(basename "$0") (--inject | --revert) [options]
       $(basename "$0") --dry-run            print the inject and revert commands, run nothing

Break name resolution between the app and PostgreSQL.

  --inject              inject the failure
  --revert              reconnect db with its "db" alias (compose) / roll back the deployment (k8s)
  --dry-run             only print the commands that would run
  --target compose|k8s  where to inject (default: compose)
  --duration SECONDS    revert automatically after SECONDS (default: 600; 0 = keep until --revert)
  --project NAME        Compose project name (default: ems -> network ems_backend, container ems-db-1)
  --namespace NS        Kubernetes namespace (default: ems)
  -h, --help            show this help
EOF
}

run() {
    # print the command (quoted only where needed), then run it unless this is a dry run
    local line="+" arg
    for arg in "$@"; do
        if [[ "$arg" =~ ^[A-Za-z0-9_./:=,@%+-]+$ ]]; then line+=" $arg"; else line+=" ${arg@Q}"; fi
    done
    printf '%s\n' "$line"
    if [[ "$DRY_RUN" == false ]]; then
        "$@"
    fi
}

note() { printf '# %s\n' "$*"; }

require() {
    [[ "$DRY_RUN" == true ]] && return 0
    command -v "$1" >/dev/null || { echo "error: $1 is not installed" >&2; exit 1; }
}

BAD_DNS_PATCH='{"spec":{"template":{"metadata":{"annotations":{"ems.chaos":"dns-failure"}},"spec":{"dnsPolicy":"None","dnsConfig":{"nameservers":["192.0.2.1"],"searches":["ems.svc.cluster.local"]}}}}}'

inject() {
    case "$TARGET" in
        compose)
            require docker
            run docker network disconnect "${PROJECT}_backend" "$PROJECT-db-1"
            note "observe: docker exec $PROJECT-app-1 python -c \"import socket; socket.gethostbyname('db')\"  (fails)"
            note "observe: docker logs --since 5m $PROJECT-app-1 | jq -r 'select(.level == \"ERROR\") | .message' | sort | uniq -c"
            ;;
        k8s)
            require kubectl
            run kubectl -n "$NAMESPACE" patch deployment ems-app --type=strategic -p "$BAD_DNS_PATCH"
            run kubectl -n "$NAMESPACE" rollout status deployment/ems-app --timeout=120s || true
            note "observe: kubectl -n $NAMESPACE get pods -o wide; kubectl -n $NAMESPACE describe pod <new-pod> (Readiness probe failed)"
            ;;
    esac
}

revert() {
    case "$TARGET" in
        compose) run docker network connect --alias db "${PROJECT}_backend" "$PROJECT-db-1" || true ;;
        k8s)
            run kubectl -n "$NAMESPACE" rollout undo deployment/ems-app
            run kubectl -n "$NAMESPACE" rollout status deployment/ems-app --timeout=180s
            ;;
    esac
}

if [[ $# -eq 0 ]]; then
    usage
    exit 2
fi
while [[ $# -gt 0 ]]; do
    case "$1" in
        --inject) ACTION=inject ;;
        --revert) ACTION=revert ;;
        --dry-run) DRY_RUN=true ;;
        --target) TARGET="${2:-}"; shift ;;
        --duration) DURATION="${2:-}"; shift ;;
        --project) PROJECT="${2:-}"; shift ;;
        --namespace) NAMESPACE="${2:-}"; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ "$TARGET" == compose || "$TARGET" == k8s ]] || { echo "error: --target must be compose or k8s" >&2; exit 2; }
[[ "$DURATION" =~ ^[0-9]+$ ]] || { echo "error: --duration must be a number of seconds" >&2; exit 2; }

if [[ -z "$ACTION" ]]; then
    [[ "$DRY_RUN" == true ]] || { usage >&2; exit 2; }
    ACTION=plan
fi

case "$ACTION" in
    inject)
        if ((DURATION > 0)); then
            trap revert EXIT
            trap 'exit 130' INT TERM
        fi
        inject
        if ((DURATION > 0)); then
            note "keeping the injection for ${DURATION}s, then reverting (Ctrl-C reverts now)"
            run sleep "$DURATION"
        else
            note "injection stays until: $0 --revert --target $TARGET"
        fi
        ;;
    revert) revert ;;
    plan)
        note "dry run, target=$TARGET: inject"
        inject
        note "wait ${DURATION}s, then revert"
        revert
        ;;
esac
