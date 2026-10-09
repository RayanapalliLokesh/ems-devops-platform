#!/usr/bin/env bash
# Phase 13 (updated for Phase 17) - check the path to EMS one layer at a time:
#   1 name -> 2 tcp -> 3 http -> 4 application -> 5 exposure
# The first FAIL from the top is where to look. Every probe has a timeout of at most 3 seconds.
set -euo pipefail

HOST="127.0.0.1"
PORT=80
DRY_RUN=0
TIMEOUT=3
# Listeners that must never be reachable from another machine: gunicorn, PostgreSQL, the monitoring UIs
INTERNAL_PORTS=(5000 5432)
LOOPBACK_ONLY_PORTS=(9090 9093 3000 16686)

usage() {
    cat <<'EOF'
Usage: netcheck.sh [--host HOST] [--port PORT] [--dry-run] [--help]

Checks, in order, and prints PASS/FAIL per line (exit 1 if any FAIL):
  1 name         HOST resolves to an address (getent / DNS)
  2 tcp          a TCP connection to HOST:PORT opens
  3 http         GET / answers with a 2xx/3xx status
  4 application  GET /health answers JSON with "status": "healthy"
  5 exposure     app 5000 and PostgreSQL 5432 are NOT reachable (only 80 and 22 should be open);
                 the monitoring ports 9090/9093/3000/16686 must not be reachable on a non-loopback address

Options:
  --host HOST   host name or IP (default: 127.0.0.1; on AWS use the ALB DNS name or the host IP)
  --port PORT   HTTP port of nginx / the ALB (default: 80; the local stack publishes 8080)
  --dry-run     print the probes for every layer, connect to nothing
  --help        show this help

When HOST is a loopback address the exposure layer also probes this machine's primary IP,
because a port bound to 127.0.0.1 is reachable locally but not from outside.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) HOST="${2:?--host needs a value}"; shift 2 ;;
        --port) PORT="${2:?--port needs a value}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "--port must be a number" >&2; exit 2; }

FAILS=0
pass() { printf 'PASS  %-12s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-12s %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }
info() { printf 'INFO  %-12s %s\n' "$1" "$2"; }
plan() { printf 'DRY   %-12s %s\n' "$1" "$2"; }

tcp_open() {   # tcp_open HOST PORT -> 0 when a connection opens within the timeout
    # shellcheck disable=SC2016  # $1/$2 are expanded by the inner bash, not here
    timeout "$TIMEOUT" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2>/dev/null
}

is_ip() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ || "$1" == *:* ]]; }
is_loopback() { [[ "$1" == 127.* || "$1" == "::1" || "$1" == "localhost" ]]; }

primary_ip() {   # the source address this machine uses to reach the internet
    { ip -4 route get 1.1.1.1 2>/dev/null || true; } | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1
}

BASE="http://$HOST:$PORT"
CURL=(curl -sS --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT")

if [[ $DRY_RUN -eq 1 ]]; then
    plan "name" "getent ahosts $HOST   (skipped when HOST is an IP)"
    plan "tcp" "timeout $TIMEOUT bash -c 'exec 3<>/dev/tcp/$HOST/$PORT'"
    plan "http" "${CURL[*]} -o /dev/null -w '%{http_code}' $BASE/   (expect 2xx/3xx)"
    plan "application" "${CURL[*]} $BASE/health   (expect \"status\": \"healthy\")"
    for p in "${INTERNAL_PORTS[@]}"; do
        plan "exposure" "timeout $TIMEOUT bash -c 'exec 3<>/dev/tcp/$HOST/$p'   (expect CLOSED)"
    done
    for p in "${LOOPBACK_ONLY_PORTS[@]}"; do
        plan "exposure" "port $p closed on non-loopback addresses (127.0.0.1-only by design)"
    done
    exit 0
fi

# ---- 1 name ------------------------------------------------------------------------------------------
ADDR="$HOST"
if is_ip "$HOST"; then
    pass "name" "$HOST is an IP address, nothing to resolve"
else
    ADDR="$(getent ahosts "$HOST" 2>/dev/null | awk 'NR==1 {print $1}')" || true
    if [[ -n "$ADDR" ]]; then
        pass "name" "$HOST -> $ADDR"
    else
        fail "name" "$HOST does not resolve (check /etc/hosts, DNS: dig $HOST)"
    fi
fi

# ---- 2 tcp -------------------------------------------------------------------------------------------
if tcp_open "$HOST" "$PORT"; then
    pass "tcp" "$HOST:$PORT accepts connections"
else
    fail "tcp" "$HOST:$PORT refused or timed out (nginx down? security group / ufw? ss -tlnp)"
fi

# ---- 3 http ------------------------------------------------------------------------------------------
code="$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE/" 2>/dev/null)" || true
if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
    pass "http" "GET / -> $code"
else
    case "${code:-000}" in
        000) fail "http" "GET / -> no answer (see the tcp line)" ;;
        502|504) fail "http" "GET / -> $code (nginx is up but cannot reach the app: docker compose ps app)" ;;
        *) fail "http" "GET / -> $code" ;;
    esac
fi

# ---- 4 application -----------------------------------------------------------------------------------
body="$("${CURL[@]}" -w '\n%{http_code}' "$BASE/health" 2>/dev/null)" || true
hcode="$(tail -1 <<< "$body")"
body="$(sed '$d' <<< "$body")"
if [[ "$hcode" == "200" ]] && grep -Eq '"status" *: *"healthy"' <<< "$body"; then
    pass "application" "GET /health -> 200 $body"
else
    case "${hcode:-000}" in
        000) fail "application" "GET /health -> no answer" ;;
        503) fail "application" "GET /health -> 503 ${body:0:120} (degraded: the app cannot reach PostgreSQL)" ;;
        *) fail "application" "GET /health -> $hcode ${body:0:120}" ;;
    esac
fi

# ---- 5 exposure --------------------------------------------------------------------------------------
targets=("${ADDR:-$HOST}")
if is_loopback "$HOST"; then
    ext="$(primary_ip)"
    if [[ -n "$ext" ]]; then
        targets+=("$ext")
    else
        info "exposure" "no non-loopback address found; only loopback probed"
    fi
fi
for t in "${targets[@]}"; do
    for p in "${INTERNAL_PORTS[@]}"; do
        if tcp_open "$t" "$p"; then
            fail "exposure" "$t:$p is OPEN (must only be reachable inside the Compose network)"
        else
            pass "exposure" "$t:$p closed"
        fi
    done
    for p in "${LOOPBACK_ONLY_PORTS[@]}"; do
        if is_loopback "$t"; then
            continue
        fi
        if tcp_open "$t" "$p"; then
            fail "exposure" "$t:$p is OPEN (monitoring must bind 127.0.0.1 only; use ssh -L)"
        else
            pass "exposure" "$t:$p closed"
        fi
    done
done
if is_loopback "$HOST"; then
    info "exposure" "monitoring ports on 127.0.0.1 are expected to be open locally (ssh -L to reach them)"
fi

echo
if (( FAILS > 0 )); then
    echo "$FAILS check(s) FAILED - fix the first FAIL from the top first"
    exit 1
fi
echo "all checks passed"
