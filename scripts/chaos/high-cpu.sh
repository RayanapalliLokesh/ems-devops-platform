#!/usr/bin/env bash
# Chaos scenario: high CPU (Phase 25, docs/sre/game-days.md#high-cpu)
# Starts a throwaway container (Compose) or pod (Kubernetes) that burns every CPU core with `yes`.
# Expected alert: HostHighCPU (ticket) after ~10-15 minutes. The burner stops itself after the duration
# (plus 60 s), even if this script is killed with SIGKILL and its cleanup trap never runs.
set -euo pipefail

ACTION=""
DRY_RUN=false
TARGET=compose
DURATION=900
NAMESPACE=ems
WORKERS=""
NAME=ems-chaos-cpu
IMAGE=alpine:3.20

usage() {
    cat <<EOF
Usage: $(basename "$0") (--inject | --revert) [options]
       $(basename "$0") --dry-run            print the inject and revert commands, run nothing

Burn all CPU cores of the host (or k8s node) to rehearse HostHighCPU.

  --inject              start the CPU burner
  --revert              remove the CPU burner
  --dry-run             only print the commands that would run
  --target compose|k8s  where to inject (default: compose)
  --duration SECONDS    revert automatically after SECONDS (default: 900; 0 = keep until --revert)
  --workers N           number of busy loops (default: number of CPUs)
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

burner_command() {
    local limit=$((DURATION > 0 ? DURATION + 60 : 3600))
    # shellcheck disable=SC2016  # $(seq) must expand inside the container, not here
    printf 'for i in $(seq %s); do timeout %s yes > /dev/null & done; wait' "$WORKERS" "$limit"
}

inject() {
    case "$TARGET" in
        compose)
            require docker
            run docker run -d --rm --name "$NAME" --label ems.chaos=high-cpu "$IMAGE" sh -c "$(burner_command)"
            note "observe: docker stats --no-stream; Grafana USE dashboard 'Host CPU utilisation'"
            ;;
        k8s)
            require kubectl
            run kubectl -n "$NAMESPACE" run "$NAME" --image="$IMAGE" --restart=Never --labels=ems.chaos=high-cpu \
                -- sh -c "$(burner_command)"
            note "observe: kubectl top nodes; kubectl -n $NAMESPACE top pods"
            ;;
    esac
    note "expected: HostHighCPU fires after 10 minutes above 85% (PromQL: 100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m]))))"
}

revert() {
    case "$TARGET" in
        compose) run docker rm -f "$NAME" || true ;;
        k8s) run kubectl -n "$NAMESPACE" delete pod "$NAME" --ignore-not-found ;;
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
        --workers) WORKERS="${2:-}"; shift ;;
        --namespace) NAMESPACE="${2:-}"; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ "$TARGET" == compose || "$TARGET" == k8s ]] || { echo "error: --target must be compose or k8s" >&2; exit 2; }
[[ "$DURATION" =~ ^[0-9]+$ ]] || { echo "error: --duration must be a number of seconds" >&2; exit 2; }
WORKERS="${WORKERS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
[[ "$WORKERS" =~ ^[1-9][0-9]*$ ]] || { echo "error: --workers must be a positive number" >&2; exit 2; }

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
