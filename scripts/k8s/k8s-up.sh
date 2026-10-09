#!/usr/bin/env bash
# Phase 22 - create the kind cluster "ems", load the local image and deploy overlay k8s/overlays/local.
#   http://localhost:8081  -> NodePort 30080 -> Service ems-app -> 2 pods
#   http://localhost:8082  -> ingress-nginx (only with --ingress)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER="ems"
IMAGE="ems-app:local"
NAMESPACE="ems"
TIMEOUT="180s"
DRY_RUN=0
INGRESS=0
INGRESS_NGINX_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/kind/deploy.yaml"
SECRET_ENV="$ROOT/k8s/base/secret.env"

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--dry-run] [--ingress] [--image NAME:TAG] [--timeout 180s] [--help]

Creates the kind cluster "$CLUSTER" (k8s/kind-config.yaml) if it does not exist, loads the image into it,
generates k8s/base/secret.env if missing, applies k8s/overlays/local and waits for the rollout.

  --dry-run     print the commands instead of running them
  --ingress     also install ingress-nginx (reachable on http://localhost:8082)
  --image       image to load into kind (default: $IMAGE)
  --timeout     how long to wait for each rollout (default: $TIMEOUT)
  --help        show this help
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --ingress) INGRESS=1 ;;
        --image) IMAGE="${2:?--image needs a value}"; shift ;;
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

random_hex() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$1"
    else
        python3 -c "import secrets,sys; print(secrets.token_hex(int(sys.argv[1])))" "$1"
    fi
}

# 1. cluster
if [[ "$DRY_RUN" -eq 0 ]] && kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    echo "kind cluster '$CLUSTER' already exists"
else
    run kind create cluster --name "$CLUSTER" --config "$ROOT/k8s/kind-config.yaml" --wait 120s
fi
run kubectl config use-context "kind-$CLUSTER"

# 2. image: kind nodes cannot see the host's Docker images, so copy it in
run kind load docker-image "$IMAGE" --name "$CLUSTER"

# 3. secret.env (gitignored) with random values
if [[ -f "$SECRET_ENV" ]]; then
    echo "using existing $SECRET_ENV"
elif [[ "$DRY_RUN" -eq 1 ]]; then
    echo "+ generate $SECRET_ENV (SECRET_KEY, POSTGRES_PASSWORD) with random hex values"
else
    umask 077
    printf 'SECRET_KEY=%s\nPOSTGRES_PASSWORD=%s\n' "$(random_hex 32)" "$(random_hex 16)" > "$SECRET_ENV"
    echo "generated $SECRET_ENV"
fi

# 4. optional ingress controller
if [[ "$INGRESS" -eq 1 ]]; then
    run kubectl apply -f "$INGRESS_NGINX_URL"
    run kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout "$TIMEOUT"
fi

# 5. the app
run kubectl apply -k "$ROOT/k8s/overlays/local"
run kubectl -n "$NAMESPACE" rollout status statefulset/postgres --timeout "$TIMEOUT"
run kubectl -n "$NAMESPACE" rollout status deployment/ems-app --timeout "$TIMEOUT"
run kubectl -n "$NAMESPACE" get pods,svc,endpoints -o wide

echo "EMS on kind: curl http://localhost:8081/health"
