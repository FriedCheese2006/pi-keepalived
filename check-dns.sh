#!/bin/sh
set -eu

mode=${HEALTHCHECK_MODE:-local}
server=${HEALTHCHECK_DNS_SERVER:-127.0.0.1}
port=${HEALTHCHECK_DNS_PORT:-53}
timeout_seconds=${HEALTHCHECK_TIMEOUT:-1}
local_name=${HEALTHCHECK_DNS_NAME:-pi.hole}
recursive_name=${HEALTHCHECK_RECURSIVE_NAME:-example.com}
dig_command=${CHECK_DNS_DIG_COMMAND:-/usr/bin/dig}
timeout_command=${CHECK_DNS_TIMEOUT_COMMAND:-/usr/bin/timeout}

case "$mode" in
    local) query_name=$local_name ;;
    recursive) query_name=$recursive_name ;;
    *) printf 'DNS health check: unsupported mode\n' >&2; exit 1 ;;
esac

if ! response=$(
    "$timeout_command" --signal=KILL "${timeout_seconds}s" \
        "$dig_command" "@$server" -p "$port" "$query_name" A \
        "+time=$timeout_seconds" +tries=1 +retry=0 +noall +comments +answer 2>&1
); then
    printf 'DNS health check: query failed or timed out\n' >&2
    exit 1
fi

printf '%s\n' "$response" | grep -q 'status: NOERROR' || {
    printf 'DNS health check: resolver returned a non-success status\n' >&2
    exit 1
}

printf '%s\n' "$response" | awk '
    $1 !~ /^;/ && NF >= 5 { answer_found = 1 }
    END { exit(answer_found ? 0 : 1) }
' || {
    printf 'DNS health check: response contained no answer records\n' >&2
    exit 1
}