#!/usr/bin/env bash
# Chaos scenario: image-pull failure (Phase 25, docs/sre/game-days.md#image-pull-failure)
# "Deploys" a tag that does not exist in the registry.
#   compose  EMS_IMAGE_TAG=<missing> docker compose up -d app: the pull fails before the old container is
#            replaced, so the old version keeps serving and the deploy (Ansible / CD) fails loudly
#   k8s      kubectl set image: new pods go ErrImagePull -> ImagePullBackOff, the rolling update stalls and
#            the old ReplicaSet keeps serving
# Expected alerts: none on the SLO. The signal is the failed deploy job; the lesson is that it is safe.
set -euo pipefail

ACTION=""
DRY_RUN=false
TARGET=compose
DURATION=300
NAMESPACE=ems
PROJECT=ems
PROJECT_DIR="${EMS_DIR:-/opt/ems}"
IMAGE=ems-app
TAG=chaos-does-not-exist

usage() {
    cat <<EOF
Usage: $(basename "$0") (--inject | --revert) [options]
       $(basename "$0") --dry-run            print the inject and revert commands, run nothing

Deploy an image tag that does not exist and watch the deploy fail safely.

  --inject              deploy the missing tag
  --revert              redeploy the tag from .env (compose) / roll back the deployment (k8s)
  --dry-run             only print the commands that would run
  --target compose|k8s  where to inject (default: compose)
  --duration SECONDS    revert automatically after SECONDS (default: 300; 0 = keep until --revert)
  --tag TAG             the missing tag (default: chaos-does-not-exist)
  --image REPO          k8s only: image repository (default: ems-app; e.g. <account>.dkr.ecr.<region>.amazonaws.com/ems-app)
  --project-dir DIR     Compose project directory with docker-compose.yml and .env (default: \$EMS_DIR or /opt/ems)
  --project NAME        Compose project name (default: ems)
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
    case "$TARGET" in
        compose)
            require docker
            run env EMS_IMAGE_TAG="$TAG" docker compose --project-directory "$PROJECT_DIR" -p "$PROJECT" \
                up -d --no-deps --pull always app || note "deploy failed, as expected (manifest unknown)"
            run docker compose -p "$PROJECT" ps app
            note "expected: the app container still runs the previous tag; curl http://<alb-dns>/health shows the old version"
            ;;
        k8s)
            require kubectl
            run kubectl -n "$NAMESPACE" set image deployment/ems-app "*=$IMAGE:$TAG"
            run kubectl -n "$NAMESPACE" rollout status deployment/ems-app --timeout=90s || note "rollout stalled, as expected"
            run kubectl -n "$NAMESPACE" get pods
            note "observe: kubectl -n $NAMESPACE describe pod <new-pod> | grep -A3 Events (Failed to pull image)"
            ;;
    esac
}

revert() {
    case "$TARGET" in
        compose) run docker compose --project-directory "$PROJECT_DIR" -p "$PROJECT" up -d --no-deps app ;;
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
        --tag) TAG="${2:-}"; shift ;;
        --image) IMAGE="${2:-}"; shift ;;
        --project-dir) PROJECT_DIR="${2:-}"; shift ;;
        --project) PROJECT="${2:-}"; shift ;;
        --namespace) NAMESPACE="${2:-}"; shift ;;
        -h | --help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ "$TARGET" == compose || "$TARGET" == k8s ]] || { echo "error: --target must be compose or k8s" >&2; exit 2; }
[[ "$DURATION" =~ ^[0-9]+$ ]] || { echo "error: --duration must be a number of seconds" >&2; exit 2; }
[[ -n "$TAG" ]] || { echo "error: --tag must not be empty" >&2; exit 2; }

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
