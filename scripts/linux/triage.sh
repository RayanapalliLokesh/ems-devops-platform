#!/usr/bin/env bash
# Phase 12 (updated for Phase 17) - "what is wrong with this server?" on one screen.
# Read-only: it never restarts, stops or changes anything. Every section is skipped (SKIP) when its tool is
# missing or not permitted, so it also works on a half-broken host.
set -euo pipefail

PROJECT="ems"
URL="http://127.0.0.1/health"
DRY_RUN=0
LOG_LINES=20

usage() {
    cat <<'EOF'
Usage: triage.sh [--project NAME] [--url URL] [--dry-run] [--help]

Prints a one-screen health summary of the EMS host (Docker Compose stack):
  load and uptime, memory, disk, top CPU processes, compose services, unhealthy containers,
  last error lines of app and nginx, listening ports, /health through nginx, recent OOM kills.

Options:
  --project NAME   Compose project name (default: ems)
  --url URL        health URL to call through nginx (default: http://127.0.0.1/health;
                   locally the stack publishes 8080: --url http://127.0.0.1:8080/health)
  --dry-run        print the commands that would run, run nothing
  --help           show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) PROJECT="${2:?--project needs a value}"; shift 2 ;;
        --url) URL="${2:?--url needs a value}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

have() { command -v "$1" >/dev/null 2>&1; }

section() { printf '\n=== %s ===\n' "$1"; }

# run TITLE TOOL CMD... : print the section, then run the command (or SKIP / print it in dry-run)
run() {
    local title="$1" tool="$2"; shift 2
    section "$title"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '+ %s\n' "$*"
        return 0
    fi
    if ! have "$tool"; then
        echo "SKIP: $tool not installed"
        return 0
    fi
    # a failing check is information, not a reason to stop the triage
    bash -c "$*" 2>&1 || echo "(exit $?)"
}

docker_ok() { have docker && docker info >/dev/null 2>&1; }

container_of() {   # container ID of a compose service in the project
    docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
        --filter "label=com.docker.compose.service=$1" | head -1
}

echo "EMS triage on $(hostname 2>/dev/null || echo unknown) at $(date -u +%Y-%m-%dT%H:%M:%SZ) (project: $PROJECT)"

run "uptime and load" uptime "uptime; echo \"cpus: \$(nproc 2>/dev/null || echo ?)\""
run "memory" free "free -h"
run "disk" df "df -h -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null || df -h"
run "top CPU processes" ps "ps -eo pid,user,pcpu,pmem,rss,comm --sort=-pcpu | head -6"

if [[ $DRY_RUN -eq 0 ]] && ! docker_ok; then
    section "docker"
    echo "SKIP: docker not installed or not reachable (are you in the docker group / root?)"
else
    run "compose services ($PROJECT)" docker \
        "docker compose -p '$PROJECT' ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'"
    run "unhealthy or stopped containers" docker \
        "out=\$(docker ps -a --filter label=com.docker.compose.project='$PROJECT' --format '{{.Names}}\t{{.Status}}' \
            | grep -Ev 'Up [^(]*\$|\\(healthy\\)' || true); [ -n \"\$out\" ] && echo \"\$out\" || echo 'none'"
    for svc in app nginx; do
        if [[ $svc == app ]]; then
            pattern='"level": ?"(ERROR|CRITICAL)"|Traceback|\[(ERROR|CRITICAL)\]|Worker .*(timeout|exited)'
        else
            pattern='"status":5[0-9][0-9]|\[(error|crit|alert|emerg)\]'
        fi
        section "last $LOG_LINES error lines: $svc"
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "+ docker logs --tail 500 <${PROJECT}-${svc}> 2>&1 | grep -E '$pattern' | tail -$LOG_LINES"
            continue
        fi
        cid="$(container_of "$svc")"
        if [[ -z "$cid" ]]; then
            echo "SKIP: no $svc container in project $PROJECT"
            continue
        fi
        docker logs --tail 500 "$cid" 2>&1 \
            | grep -E "$pattern" | tail -"$LOG_LINES" || echo "no error lines"
    done
fi

run "listening TCP ports" ss "ss -tlnp 2>/dev/null || ss -tln"
run "health through nginx ($URL)" curl \
    "curl -sS --max-time 3 -o - -w '\\nHTTP %{http_code} in %{time_total}s\\n' '$URL'"

section "recent OOM kills"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ dmesg -T | grep -i 'out of memory|oom-kill' | tail -5   (fallback: journalctl -k --since -24h)"
else
    oom=""
    if have dmesg && dmesg >/dev/null 2>&1; then
        oom="$(dmesg -T 2>/dev/null | grep -Ei 'out of memory|oom-kill|killed process' | tail -5 || true)"
        echo "${oom:-none in dmesg}"
    elif have journalctl && journalctl -k -n 1 >/dev/null 2>&1; then
        oom="$(journalctl -k --since -24h --no-pager 2>/dev/null | grep -Ei 'out of memory|oom-kill' | tail -5 || true)"
        echo "${oom:-none in the kernel journal (24h)}"
    else
        echo "SKIP: kernel log not readable (run with sudo to see OOM kills)"
    fi
    if docker_ok; then
        docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" \
            | xargs -r docker inspect --format '{{.Name}} OOMKilled={{.State.OOMKilled}} restarts={{.RestartCount}}' 2>/dev/null \
            | sed 's#^/##'
    fi
fi
echo
echo "Next: docs/linux/troubleshooting.md and docs/docker/runtime-troubleshooting.md"
