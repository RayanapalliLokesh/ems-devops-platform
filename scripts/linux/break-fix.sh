#!/usr/bin/env bash
# Phase 12 (updated for Phase 17) - five failures to break, diagnose and fix on the EMS Compose stack.
# Practise on a lab host or your laptop, never on a server that serves real users. Every "break" has a "fix"
# that puts the stack back exactly as Compose defines it. Walkthrough: docs/linux/break-fix.md
set -euo pipefail

PROJECT="ems"
DRY_RUN=0
URL=""
FILL_MB=512
STATE_DIR="/tmp/ems-break-fix"
FILL_FILE=""   # set below: /tmp, or /var/tmp when /tmp is a tmpfs (RAM, not disk)
ROGUE="ems-breakfix-rogue"
NGINX_IMAGE="nginx:1.27.4-alpine"

usage() {
    cat <<'EOF'
Usage: break-fix.sh [options] list
       break-fix.sh [options] break N | fix N | check N

Scenarios (N):
  1  app container stopped            -> nginx answers 502
  2  disk filling up (bounded file)   -> a big file in /tmp (/var/tmp if /tmp is tmpfs) eats free space
  3  wrong DATABASE_URL               -> app recreated with a bad database host, /health 503 / unhealthy
  4  nginx config syntax error        -> a broken COPY of nginx/default.conf fails `nginx -t`
  5  port conflict on the HTTP port   -> another container holds the port, ems nginx cannot start

Commands:
  list       show the scenarios
  break N    cause failure N
  check N    exit 0 when scenario N is healthy (fixed), 1 when it is broken
  fix N      repair failure N

Options:
  --project NAME   Compose project (default: ems)
  --url URL        health URL (default: http://127.0.0.1:<published nginx port>/health)
  --fill-mb N      size of the scenario 2 file, 64..2048 MB (default: 512)
  --dry-run        print the commands, change nothing (without a command: print every scenario)
  --help           show this help
EOF
}

CMD=""
N=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) PROJECT="${2:?--project needs a value}"; shift 2 ;;
        --url) URL="${2:?--url needs a value}"; shift 2 ;;
        --fill-mb) FILL_MB="${2:?--fill-mb needs a value}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        list) CMD="list"; shift ;;
        break|fix|check) CMD="$1"; N="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ ! "$FILL_MB" =~ ^[0-9]+$ ]] || (( FILL_MB < 64 || FILL_MB > 2048 )); then
    echo "--fill-mb must be between 64 and 2048" >&2; exit 2
fi

say() { echo "[break-fix] $*"; }

run() {   # print and run a command; in dry-run only print it
    printf '+ %s\n' "$*"
    [[ $DRY_RUN -eq 1 ]] && return 0
    "$@"
}

# Docker calls can be slow on a loaded host, so the facts about the stack are collected once at start
HAVE_DOCKER=0
declare -A CIDS=()
COMPOSE_BASE=(-p "$PROJECT")
COMPOSE_WDIR="/opt/ems"
HTTP_PORT="${EMS_HTTP_PORT:-80}"

have_docker() { [[ $HAVE_DOCKER -eq 1 ]]; }

refresh_containers() {   # one docker call: compose service -> container ID
    CIDS=()
    have_docker || return 0
    local svc id
    while read -r svc id; do
        if [[ -n "$svc" && -z "${CIDS[$svc]:-}" ]]; then CIDS[$svc]="$id"; fi
    done < <(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
                 --format '{{.Label "com.docker.compose.service"}} {{.ID}}')
    return 0
}

container_of() { echo "${CIDS[$1]:-}"; }

# Recreate services exactly as they were started: same compose files, env file and directory, read from the
# labels Compose puts on its containers
load_compose_args() {
    local cid info files envf wdir f
    local -a parts=()
    cid="$(container_of app)"
    [[ -z "$cid" ]] && cid="$(container_of db)"
    [[ -z "$cid" ]] && return 0
    info="$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}|{{index .Config.Labels "com.docker.compose.project.environment_file"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
    IFS='|' read -r files envf wdir <<< "$info"
    COMPOSE_WDIR="${wdir:-$COMPOSE_WDIR}"
    COMPOSE_BASE=(-p "$PROJECT" --project-directory "$COMPOSE_WDIR")
    IFS=',' read -r -a parts <<< "$files"
    for f in "${parts[@]}"; do COMPOSE_BASE+=(-f "$f"); done
    if [[ -n "$envf" ]]; then COMPOSE_BASE+=(--env-file "$envf"); fi
    return 0
}

load_http_port() {   # the published host port of nginx: 80 on EC2, 8080 locally
    local cid port
    cid="$(container_of nginx)"
    [[ -z "$cid" ]] && return 0
    port="$(docker port "$cid" 80/tcp 2>/dev/null | head -1 | sed 's/.*://')" || true
    if [[ -n "$port" ]]; then HTTP_PORT="$port"; fi
    return 0
}

compose() {   # compose [--extra FILE] ARGS...
    local -a base=("${COMPOSE_BASE[@]}")
    if [[ "${1:-}" == "--extra" ]]; then base+=(-f "$2"); shift 2; fi
    run docker compose "${base[@]}" "$@"
}

health_code() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$URL" 2>/dev/null || true
}

expect_healthy() {   # used by every check: the request path through nginx must answer 200
    local code
    code="$(health_code)"
    if [[ "$code" == "200" ]]; then
        say "OK   $URL -> 200"
        return 0
    fi
    say "FAIL $URL -> ${code:-no answer}"
    return 1
}

need_n() {
    [[ "$N" =~ ^[1-5]$ ]] || { echo "$CMD needs a scenario number 1-5 (see: break-fix.sh list)" >&2; exit 2; }
}

list() {
    cat <<'EOF'
1  app container stopped        symptom: 502 Bad Gateway from nginx; `docker compose ps` shows app exited
2  disk filling up              symptom: df shows less free space; at 100% postgres and logging fail
3  wrong DATABASE_URL           symptom: /health 503 or no answer; app unhealthy, connection errors in logs
4  nginx config syntax error    symptom: `nginx -t` fails; a reload would be refused, a restart would crash
5  port conflict on HTTP port   symptom: "port is already allocated"; ems nginx cannot start
EOF
}

# ---------------------------------------------------------------------------------------------- scenarios
break_1() {
    say "stopping the app container (a manual stop: the restart policy will NOT bring it back)"
    compose stop app
    say "now try: curl -i $URL   (expect 502 from nginx)"
}
fix_1() { compose up -d --no-build --wait app; }
check_1() {
    local cid state
    cid="$(container_of app)"
    state="$( [[ -n "$cid" ]] && docker inspect "$cid" --format '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{end}}')" || true
    say "app container: ${state:-missing}"
    expect_healthy
}

break_2() {
    local avail_mb
    avail_mb="$(df -Pm "$(dirname "$FILL_FILE")" | awk 'NR==2 {print $4}')"
    if (( avail_mb < FILL_MB + 1024 )); then
        say "refusing: only ${avail_mb} MB free next to $FILL_FILE; the scenario keeps at least 1 GB free"
        return 1
    fi
    say "writing a ${FILL_MB} MB file to $FILL_FILE"
    run fallocate -l "${FILL_MB}M" "$FILL_FILE"
    run df -h "$(dirname "$FILL_FILE")"
    say "now find it: df -h; sudo du -xh / --max-depth=2 | sort -h | tail; ls -lh $(dirname "$FILL_FILE")"
}
fix_2() { run rm -f "$FILL_FILE"; run df -h "$(dirname "$FILL_FILE")"; }
check_2() {
    df -h "$(dirname "$FILL_FILE")" | tail -1
    if [[ -e "$FILL_FILE" ]]; then
        say "FAIL $FILL_FILE is still there ($(du -h "$FILL_FILE" | cut -f1))"
        return 1
    fi
    local use
    use="$(df -P / | awk 'NR==2 {gsub("%",""); print $5}')"
    if (( use >= 90 )); then say "FAIL root file system ${use}% used"; return 1; fi
    say "OK   no fill file, root file system ${use}% used"
}

break_3() {
    run mkdir -p "$STATE_DIR"
    say "writing an override with a wrong database host and recreating only the app"
    if [[ $DRY_RUN -eq 0 ]]; then
        cat > "$STATE_DIR/bad-database-url.yml" <<'EOF'
services:
  app:
    environment:
      DATABASE_URL: postgresql+psycopg://ems:wrong-password@db-typo:5432/ems
EOF
    fi
    compose --extra "$STATE_DIR/bad-database-url.yml" up -d --no-build --no-deps app
    say "now look: docker compose -p $PROJECT ps; docker compose -p $PROJECT logs --tail 30 app; curl -i $URL"
}
fix_3() {
    compose up -d --no-build --no-deps --wait app
    run rm -f "$STATE_DIR/bad-database-url.yml"
}
check_3() {
    local cid host
    cid="$(container_of app)"
    if [[ -n "$cid" ]]; then
        host="$(docker inspect "$cid" --format '{{range .Config.Env}}{{println .}}{{end}}' \
            | sed -n 's/^DATABASE_URL=.*@\([^:/]*\).*/\1/p')"
        say "app DATABASE_URL host: ${host:-unknown} (expected: db)"
        [[ "$host" == "db" ]] || { expect_healthy || true; return 1; }
    fi
    expect_healthy
}

nginx_test_copy() {   # run `nginx -t` inside the nginx container against the copy in $STATE_DIR/conf.d
    local cid
    cid="$(container_of nginx)"
    [[ -z "$cid" && $DRY_RUN -eq 0 ]] && { say "no nginx container in project $PROJECT"; return 1; }
    cid="${cid:-<nginx>}"
    run docker exec "$cid" mkdir -p /tmp/ems-break-fix/conf.d
    run docker cp "$STATE_DIR/conf.d/default.conf" "$cid:/tmp/ems-break-fix/conf.d/default.conf"
    run docker exec "$cid" sh -c \
        "sed 's#/etc/nginx/conf.d/\*.conf#/tmp/ems-break-fix/conf.d/*.conf#' /etc/nginx/nginx.conf \
         > /tmp/ems-break-fix/nginx.conf && nginx -t -c /tmp/ems-break-fix/nginx.conf"
}
live_conf() { echo "$COMPOSE_WDIR/nginx/default.conf"; }
break_4() {
    run mkdir -p "$STATE_DIR/conf.d"
    say "copying $(live_conf) and deleting one semicolon (the live file is not touched)"
    if [[ $DRY_RUN -eq 0 ]]; then
        sed 's/listen 80 default_server;/listen 80 default_server/' "$(live_conf)" > "$STATE_DIR/conf.d/default.conf"
    fi
    nginx_test_copy || say "nginx -t failed, as intended. Read the line number it reports."
    say "lesson: always 'nginx -t' before 'nginx -s reload'; a failed reload keeps the old config running"
}
fix_4() {
    run mkdir -p "$STATE_DIR/conf.d"
    run cp "$(live_conf)" "$STATE_DIR/conf.d/default.conf"
    nginx_test_copy
}
check_4() {
    if [[ -f "$STATE_DIR/conf.d/default.conf" ]]; then
        if ! nginx_test_copy >/dev/null 2>&1; then say "FAIL the copy in $STATE_DIR does not pass nginx -t"; return 1; fi
        say "OK   the copy passes nginx -t"
    fi
    local cid
    cid="$(container_of nginx)"
    [[ -n "$cid" ]] && docker exec "$cid" nginx -t
    expect_healthy
}

break_5() {
    local port
    port="$HTTP_PORT"
    say "freeing port $port by stopping ems nginx, then a rogue container takes it"
    compose stop nginx
    run docker run -d --name "$ROGUE" --restart no -p "$port:80" "$NGINX_IMAGE"
    say "ems nginx now tries to start and cannot get the port:"
    compose start nginx || say "start failed, as intended. Find the owner: ss -tlnp 'sport = :$port'; docker ps --filter publish=$port"
}
fix_5() {
    run docker rm -f "$ROGUE"
    compose up -d --no-build --wait nginx
}
check_5() {
    local port owner
    port="$HTTP_PORT"
    owner="$(docker ps --filter "publish=$port" --format '{{.Names}}' 2>/dev/null | head -1)"
    say "port $port is published by: ${owner:-nobody (or a non-container process: ss -tlnp)}"
    if docker ps -a --format '{{.Names}}' | grep -qx "$ROGUE"; then say "FAIL rogue container $ROGUE exists"; return 1; fi
    expect_healthy
}

# ---------------------------------------------------------------------------------------------- main
fill_dir=/tmp
if [[ "$(df --output=fstype /tmp 2>/dev/null | tail -1)" == "tmpfs" ]]; then fill_dir=/var/tmp; fi
FILL_FILE="$fill_dir/ems-break-fix-fill.bin"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then HAVE_DOCKER=1; fi
refresh_containers
load_compose_args
load_http_port
if [[ -z "$URL" ]]; then URL="http://127.0.0.1:$HTTP_PORT/health"; fi

if [[ -z "$CMD" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        list
        for i in 1 2 3 4 5; do
            echo; echo "--- scenario $i: break"; "break_$i" || true
            echo "--- scenario $i: fix"; "fix_$i" || true
        done
        exit 0
    fi
    usage; exit 2
fi

case "$CMD" in
    list) list ;;
    break) need_n; "break_$N" ;;
    fix) need_n; "fix_$N"; refresh_containers; say "after fix:"; "check_$N" ;;
    check) need_n; "check_$N" ;;
esac
