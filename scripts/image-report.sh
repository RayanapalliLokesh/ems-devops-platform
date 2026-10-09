#!/usr/bin/env bash
# Phase 17 - review a built image before it is pushed: size, layers, user, healthcheck, ports, labels.
# Fails (exit 1) when the image runs as root, has no HEALTHCHECK, or is bigger than --max-size-mb.
set -euo pipefail

IMAGE="ems-app:local"
MAX_MB=""
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: image-report.sh [IMAGE] [--max-size-mb N] [--dry-run] [--help]

Reports on IMAGE (default: ems-app:local):
  size, layer count, user (FAIL if root), healthcheck (FAIL if missing), exposed ports, labels,
  and the biggest layers from `docker history`.

Options:
  --max-size-mb N   FAIL when the image is larger than N MB
  --dry-run         print the docker commands, run nothing
  --help            show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-size-mb) MAX_MB="${2:?--max-size-mb needs a value}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) IMAGE="$1"; shift ;;
    esac
done
if [[ -n "$MAX_MB" && ! "$MAX_MB" =~ ^[0-9]+$ ]]; then
    echo "--max-size-mb must be a whole number" >&2; exit 2
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ docker image inspect $IMAGE --format '{{.Size}} {{len .RootFS.Layers}} {{.Config.User}} ...'"
    echo "+ docker image inspect $IMAGE --format '{{json .Config.Healthcheck}} {{json .Config.ExposedPorts}} {{json .Config.Labels}}'"
    printf '%s\n' "+ docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' $IMAGE"
    exit 0
fi

command -v docker >/dev/null 2>&1 || { echo "docker is not installed" >&2; exit 1; }
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "image $IMAGE not found (build it: docker compose build app)" >&2
    exit 1
fi

FAILS=0
row() { printf '%-5s %-12s %s\n' "$1" "$2" "$3"; }
pass() { row PASS "$1" "$2"; }
fail() { row FAIL "$1" "$2"; FAILS=$((FAILS + 1)); }
info() { row INFO "$1" "$2"; }

inspect() { docker image inspect "$IMAGE" --format "$1"; }

echo "Image report: $IMAGE ($(inspect '{{.Id}}' | cut -c1-19))"
echo

size_bytes="$(inspect '{{.Size}}')"
size_mb=$(( (size_bytes + 500000) / 1000000 ))   # MB as the docker CLI prints it (10^6 bytes)
if [[ -n "$MAX_MB" ]] && (( size_mb > MAX_MB )); then
    fail "size" "${size_mb} MB > limit ${MAX_MB} MB"
elif [[ -n "$MAX_MB" ]]; then
    pass "size" "${size_mb} MB <= limit ${MAX_MB} MB"
else
    info "size" "${size_mb} MB (uncompressed; add --max-size-mb N to enforce a limit)"
fi

layers="$(inspect '{{len .RootFS.Layers}}')"
info "layers" "$layers file system layers"

user="$(inspect '{{.Config.User}}')"
case "$user" in
    ""|root|0|0:0|root:root|root:*|0:*) fail "user" "'${user:-<empty>}' runs as root (add USER 10001 to the Dockerfile)" ;;
    *) pass "user" "$user (non-root)" ;;
esac

hc="$(inspect '{{if .Config.Healthcheck}}{{join .Config.Healthcheck.Test " "}}{{end}}')"
if [[ -n "$hc" && "$hc" != "NONE" ]]; then
    interval="$(inspect '{{.Config.Healthcheck.Interval}}')"
    pass "healthcheck" "every ${interval}: ${hc:0:90}..."
else
    fail "healthcheck" "no HEALTHCHECK (Compose depends_on: service_healthy cannot work)"
fi

# shellcheck disable=SC2016  # Go template variables, not shell ones
ports="$(inspect '{{range $p, $_ := .Config.ExposedPorts}}{{$p}} {{end}}')"
info "ports" "${ports:-none exposed}"

entry="$(inspect '{{json .Config.Entrypoint}} {{json .Config.Cmd}}')"
info "command" "$entry"

echo
echo "labels:"
# shellcheck disable=SC2016
inspect '{{range $k, $v := .Config.Labels}}{{printf "  %s=%s\n" $k $v}}{{end}}'

echo "biggest layers (docker history):"
docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' "$IMAGE" \
    | awk -F'\t' '$1 != "0B" {printf "  %-8s %s\n", $1, substr($2, 1, 90)}' \
    | sort -h -r -k1,1 | head -5 || true   # head may close the pipe early

echo
if (( FAILS > 0 )); then
    echo "$FAILS check(s) FAILED"
    exit 1
fi
echo "image review passed"
