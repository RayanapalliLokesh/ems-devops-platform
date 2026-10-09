#!/usr/bin/env bash
# Chaos scenario: database timeout (Phase 25, docs/sre/game-days.md#db-timeout)
#   pause  docker pause the db container: TCP connects still succeed, queries hang (a real "timeout")
#   stop   docker compose stop db: connections fail at once (a hard outage)
#   k8s    scale the postgres StatefulSet to 0
# Expected alerts: EMSDatabaseDown (stop) or EMSAppDown (pause: /metrics hangs on SELECT 1), then
# EMSErrorBudgetFastBurn (the ALB health checks on /health answer 503 and count as 5xx).
set -euo pipefail

ACTION=""
DRY_RUN=false
TARGET=compose
MODE=pause
DURATION=600
NAMESPACE=ems
PROJECT=ems

usage() {
    cat <<EOF
Usage: $(basename "$0") (--inject | --revert) [options]
       $(basename "$0") --dry-run            print the inject and revert commands, run nothing

Make PostgreSQL unreachable or unresponsive to rehearse EMSDatabaseDown / EMSErrorBudgetFastBurn.

  --inject              inject the failure
  --revert              undo it (unpause / start db, or scale postgres back to 1)
  --dry-run             only print the commands that would run
  --target compose|k8s  where to inject (default: compose)
  --mode pause|stop     compose only: freeze the container or stop it (default: pause)
  --duration SECONDS    revert automatically after SECONDS (default: 600; 0 = keep until --revert)
  --project NAME        Compose project name (default: ems -> container ems-db-1)
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

inject() {
    case "$TARGET:$MODE" in
        compose:pause) require docker; run docker pause "$PROJECT-db-1" ;;
        compose:stop) require docker; run docker compose -p "$PROJECT" stop db ;;
        k8s:*) require kubectl; run kubectl -n "$NAMESPACE" scale statefulset/postgres --replicas=0 ;;
    esac
    note "observe: curl -s -o /dev/null -w '%{http_code} %{time_total}s\\n' http://<alb-dns>/health"
    note "observe: PromQL ems_db_up, up{job=\"ems-app\"}, ems:slo_errors:ratio_rate5m"
    note "observe: docker logs --since 5m $PROJECT-app-1 | jq -c 'select(.status >= 500)'"
}

revert() {
    case "$TARGET:$MODE" in
        compose:pause) run docker unpause "$PROJECT-db-1" || true ;;
        compose:stop) run docker compose -p "$PROJECT" start db ;;
        k8s:*)
            run kubectl -n "$NAMESPACE" scale statefulset/postgres --replicas=1
            run kubectl -n "$NAMESPACE" rollout status statefulset/postgres --timeout=180s
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
        --mode) MODE="${2:-}"; shift ;;
        --duration) DURATION="${2:-}"; shift ;;
        --project) PROJECT="${2:-}"; shift ;;
        --namespace) NAMESPACE="${2:-}"; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ "$TARGET" == compose || "$TARGET" == k8s ]] || { echo "error: --target must be compose or k8s" >&2; exit 2; }
[[ "$MODE" == pause || "$MODE" == stop ]] || { echo "error: --mode must be pause or stop" >&2; exit 2; }
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
            note "injection stays until: $0 --revert --target $TARGET --mode $MODE"
        fi
        ;;
    revert) revert ;;
    plan)
        note "dry run, target=$TARGET mode=$MODE: inject"
        inject
        note "wait ${DURATION}s, then revert"
        revert
        ;;
esac
