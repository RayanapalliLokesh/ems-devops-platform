#!/usr/bin/env bash
# Phase 22 - roll out a new image tag and undo it automatically if the new pods do not become ready.
set -euo pipefail

NAMESPACE="ems"
DEPLOYMENT="ems-app"
CONTAINER="app"
IMAGE_NAME=""
TAG=""
TIMEOUT="120s"
DRY_RUN=0

usage() {
    cat <<USAGE
Usage: $(basename "$0") --tag TAG [--image-name NAME] [--namespace ems] [--timeout 120s] [--dry-run] [--help]

Sets deployment/$DEPLOYMENT (container "$CONTAINER") to NAME:TAG and waits for the rollout.
If the pods are not ready within the timeout it runs "kubectl rollout undo" and exits 1.

  --tag          new image tag (required)
  --image-name   image repository (default: the current one of the deployment)
  --namespace    namespace (default: $NAMESPACE)
  --timeout      how long the new pods get to become ready (default: $TIMEOUT)
  --dry-run      print the commands instead of running them
  --help         show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag) TAG="${2:?--tag needs a value}"; shift ;;
        --image-name) IMAGE_NAME="${2:?--image-name needs a value}"; shift ;;
        -n|--namespace) NAMESPACE="${2:?--namespace needs a value}"; shift ;;
        --timeout) TIMEOUT="${2:?--timeout needs a value}"; shift ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ -z "$TAG" ]]; then
    echo "--tag is required" >&2
    usage >&2
    exit 2
fi

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '+'; printf ' %q' "$@"; printf '\n'
    else
        "$@"
    fi
}

if [[ -z "$IMAGE_NAME" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        IMAGE_NAME="ems-app"
    else
        current="$(kubectl -n "$NAMESPACE" get deployment "$DEPLOYMENT" \
            -o jsonpath="{.spec.template.spec.containers[?(@.name==\"$CONTAINER\")].image}")"
        IMAGE_NAME="${current%:*}"
    fi
fi
NEW_IMAGE="$IMAGE_NAME:$TAG"

echo "rolling out $NEW_IMAGE to deployment/$DEPLOYMENT in namespace $NAMESPACE (timeout $TIMEOUT)"
run kubectl -n "$NAMESPACE" set image "deployment/$DEPLOYMENT" "$CONTAINER=$NEW_IMAGE"
run kubectl -n "$NAMESPACE" annotate "deployment/$DEPLOYMENT" --overwrite \
    "kubernetes.io/change-cause=k8s-rollout.sh: $NEW_IMAGE"

if [[ "$DRY_RUN" -eq 1 ]]; then
    run kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout "$TIMEOUT"
    echo "# only if the rollout status above fails:"
elif kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout "$TIMEOUT"; then
    echo "rollout of $NEW_IMAGE succeeded"
    exit 0
fi

echo "new pods did not become ready within $TIMEOUT - rolling back" >&2
run kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/name=$DEPLOYMENT" -o wide || true
run kubectl -n "$NAMESPACE" rollout undo "deployment/$DEPLOYMENT"
run kubectl -n "$NAMESPACE" rollout status "deployment/$DEPLOYMENT" --timeout "$TIMEOUT"
echo "rolled back: deployment/$DEPLOYMENT runs the previous revision again" >&2
[[ "$DRY_RUN" -eq 1 ]] && exit 0
exit 1
