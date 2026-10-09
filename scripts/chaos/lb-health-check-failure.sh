#!/usr/bin/env bash
# Chaos scenario: load-balancer health-check failure (Phase 25, docs/sre/game-days.md#lb-health-check-failure)
#   stop-nginx  nothing listens on :80, the ALB health check (/health) fails, the only target goes unhealthy
#               and the ALB answers 503 itself. The app sees no traffic at all.
#   stop-app    nginx answers 502 for /health: the target goes unhealthy and Prometheus loses the app too.
# Expected: CloudWatch alarm ems-dev-alb-unhealthy-hosts within ~2 minutes; Prometheus EMSNoTraffic after
# ~20 minutes (stop-nginx) or EMSAppDown after 1 minute (stop-app).
# Compose only: in Kubernetes the same failure is a readiness probe failure (see dns-failure.sh --target k8s).
set -euo pipefail

ACTION=""
DRY_RUN=false
TARGET=compose
MODE=stop-nginx
DURATION=1200
PROJECT=ems

usage() {
    cat <<EOF
Usage: $(basename "$0") (--inject | --revert) [options]
       $(basename "$0") --dry-run            print the inject and revert commands, run nothing

Make the ALB target group health check fail.

  --inject                   inject the failure
  --revert                   start the stopped service again
  --dry-run                  only print the commands that would run
  --target compose           the only target (kept for a uniform interface)
  --mode stop-nginx|stop-app what to stop (default: stop-nginx)
  --duration SECONDS         revert automatically after SECONDS (default: 1200; 0 = keep until --revert)
  --project NAME             Compose project name (default: ems)
  -h, --help                 show this help
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

service() { [[ "$MODE" == stop-nginx ]] && echo nginx || echo app; }

inject() {
    require docker
    run docker compose -p "$PROJECT" stop "$(service)"
    note "observe: aws elbv2 describe-target-health --target-group-arn <tg-arn> --query 'TargetHealthDescriptions[].TargetHealth'"
    note "observe: curl -s -o /dev/null -w '%{http_code}\\n' http://<alb-dns>/health   (503 from the ALB itself)"
    note "observe: aws cloudwatch describe-alarms --alarm-names ems-dev-alb-unhealthy-hosts --query 'MetricAlarms[].StateValue'"
}

revert() {
    run docker compose -p "$PROJECT" start "$(service)"
    note "the target is healthy again after the healthy-threshold checks pass (aws elbv2 describe-target-health)"
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
        -h | --help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ "$TARGET" == compose ]] || { echo "error: only --target compose is supported" >&2; exit 2; }
[[ "$MODE" == stop-nginx || "$MODE" == stop-app ]] || { echo "error: --mode must be stop-nginx or stop-app" >&2; exit 2; }
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
            note "injection stays until: $0 --revert --mode $MODE"
        fi
        ;;
    revert) revert ;;
    plan)
        note "dry run, mode=$MODE: inject"
        inject
        note "wait ${DURATION}s, then revert"
        revert
        ;;
esac
