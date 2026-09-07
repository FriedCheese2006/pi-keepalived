#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE=${IMAGE:-pi-keepalived:test}
TEST_ROOT=$(mktemp -d)
NETWORK_NAME="pi-keepalived-test-$$"
CONTAINER_NAME="pi-keepalived-signal-test-$$"
tests_run=0

cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker network rm "$NETWORK_NAME" >/dev/null 2>&1 || true
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
    tests_run=$((tests_run + 1))
    printf 'ok %d - %s\n' "$tests_run" "$1"
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    output=$1
    expected=$2
    test_name=$3
    grep -Fq -- "$expected" <<<"$output" || fail "$test_name: expected '$expected'"
}

assert_not_contains() {
    output=$1
    unexpected=$2
    test_name=$3
    if grep -Fq -- "$unexpected" <<<"$output"; then
        fail "$test_name: unexpectedly exposed prohibited content"
    fi
}

render_config() {
    docker run --rm \
        -e VRRP_PRIORITY=110 \
        -e VRRP_VIRTUAL_IP=192.0.2.10/24 \
        -e VRRP_UNICAST_SRC_IP=192.0.2.11 \
        -e VRRP_UNICAST_PEERS=192.0.2.12 \
        "$@" \
        "$IMAGE" config-test
}

expect_config_failure() {
    test_name=$1
    expected_error=$2
    shift 2

    if failure_output=$(render_config "$@" 2>&1); then
        fail "$test_name: configuration unexpectedly succeeded"
    fi
    assert_contains "$failure_output" "$expected_error" "$test_name"
    pass "$test_name"
}

primary_output=$(render_config)
assert_contains "$primary_output" 'priority 110' 'primary config generation'
assert_contains "$primary_output" 'unicast_src_ip 192.0.2.11' 'primary config generation'
assert_contains "$primary_output" '        192.0.2.12' 'primary config generation'
pass 'primary config generation'

secondary_output=$(render_config \
    -e VRRP_PRIORITY=100 \
    -e VRRP_UNICAST_SRC_IP=192.0.2.12 \
    -e VRRP_UNICAST_PEERS=192.0.2.11)
assert_contains "$secondary_output" 'state BACKUP' 'secondary config generation'
assert_contains "$secondary_output" 'priority 100' 'secondary config generation'
assert_contains "$secondary_output" 'unicast_src_ip 192.0.2.12' 'secondary config generation'
pass 'secondary config generation'

peers_output=$(render_config -e 'VRRP_UNICAST_PEERS=192.0.2.12, 192.0.2.13 192.0.2.14')
assert_contains "$peers_output" '        192.0.2.12' 'multiple unicast peers'
assert_contains "$peers_output" '        192.0.2.13' 'multiple unicast peers'
assert_contains "$peers_output" '        192.0.2.14' 'multiple unicast peers'
pass 'multiple unicast peers'

nopreempt_output=$(render_config -e VRRP_PREEMPT=false)
assert_contains "$nopreempt_output" '    nopreempt' 'nopreempt rendering'
pass 'nopreempt rendering'

multicast_output=$(render_config \
    -e VRRP_MODE=multicast \
    -e VRRP_UNICAST_SRC_IP= \
    -e VRRP_UNICAST_PEERS=)
assert_not_contains "$multicast_output" 'unicast_src_ip' 'explicit multicast rendering'
assert_not_contains "$multicast_output" 'unicast_peer' 'explicit multicast rendering'
pass 'explicit multicast rendering'

printf '%s\n' 'S3cr3t-1' > "$TEST_ROOT/vrrp-auth"
chmod 600 "$TEST_ROOT/vrrp-auth"
secret_output=$(render_config \
    --volume "$TEST_ROOT/vrrp-auth:/run/secrets/vrrp-auth:ro" \
    -e VRRP_AUTH_PASS_FILE=/run/secrets/vrrp-auth)
assert_contains "$secret_output" 'auth_type PASS' 'secret file loading'
assert_contains "$secret_output" 'auth_pass [REDACTED]' 'secret file loading'
assert_not_contains "$secret_output" 'S3cr3t-1' 'secret file loading'
pass 'secret loaded through VRRP_AUTH_PASS_FILE without disclosure'

expect_config_failure 'malformed VIP rejection' 'VRRP_VIRTUAL_IP contains an invalid IPv4 address' \
    -e VRRP_VIRTUAL_IP=10.21.999.2/24
expect_config_failure 'invalid priority rejection' 'VRRP_PRIORITY must be between 1 and 255' \
    -e VRRP_PRIORITY=0
expect_config_failure 'invalid router ID rejection' 'VRRP_VIRTUAL_ROUTER_ID must be between 1 and 255' \
    -e VRRP_VIRTUAL_ROUTER_ID=256

assert_contains "$primary_output" 'Generated Keepalived configuration' 'Keepalived config validation'
pass 'Keepalived config validation'

cat > "$TEST_ROOT/dig-success" <<'EOF'
#!/bin/sh
expected_name=${EXPECTED_DNS_NAME:-pi.hole}
case " $* " in
    *" $expected_name "*) ;;
    *) exit 1 ;;
esac
cat <<'RESPONSE'
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 1
pi.hole. 60 IN A 192.0.2.11
RESPONSE
EOF

cat > "$TEST_ROOT/dig-failure" <<'EOF'
#!/bin/sh
printf '%s\n' ';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1'
EOF

cat > "$TEST_ROOT/dig-timeout" <<'EOF'
#!/bin/sh
exec tail -f /dev/null
EOF
chmod 755 "$TEST_ROOT"/dig-*

docker run --rm \
    --entrypoint /usr/local/bin/check-dns.sh \
    --volume "$TEST_ROOT:/test:ro" \
    -e CHECK_DNS_DIG_COMMAND=/test/dig-success \
    "$IMAGE"
pass 'DNS health script success'

docker run --rm \
    --entrypoint /usr/local/bin/check-dns.sh \
    --volume "$TEST_ROOT:/test:ro" \
    -e CHECK_DNS_DIG_COMMAND=/test/dig-success \
    -e HEALTHCHECK_MODE=recursive \
    -e EXPECTED_DNS_NAME=example.com \
    "$IMAGE"
pass 'recursive DNS health mode'

if docker run --rm \
    --entrypoint /usr/local/bin/check-dns.sh \
    --volume "$TEST_ROOT:/test:ro" \
    -e CHECK_DNS_DIG_COMMAND=/test/dig-failure \
    "$IMAGE" >/dev/null 2>&1; then
    fail 'DNS health script failure: SERVFAIL unexpectedly succeeded'
fi
pass 'DNS health script failure'

timeout_started=$(date +%s)
if docker run --rm \
    --entrypoint /usr/local/bin/check-dns.sh \
    --volume "$TEST_ROOT:/test:ro" \
    -e CHECK_DNS_DIG_COMMAND=/test/dig-timeout \
    -e HEALTHCHECK_TIMEOUT=1 \
    "$IMAGE" >/dev/null 2>&1; then
    fail 'DNS health script timeout: hanging query unexpectedly succeeded'
fi
timeout_elapsed=$(( $(date +%s) - timeout_started ))
[ "$timeout_elapsed" -le 3 ] || fail "DNS health script timeout took ${timeout_elapsed}s"
pass 'DNS health script timeout'

docker network create --subnet 172.30.253.0/24 "$NETWORK_NAME" >/dev/null
docker run --detach \
    --name "$CONTAINER_NAME" \
    --network "$NETWORK_NAME" \
    --ip 172.30.253.10 \
    --cap-drop ALL \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    --read-only \
    --tmpfs /run/keepalived:rw,noexec,nosuid,nodev,mode=0755 \
    -e VRRP_PRIORITY=110 \
    -e VRRP_VIRTUAL_IP=172.30.253.20/24 \
    -e VRRP_UNICAST_SRC_IP=172.30.253.10 \
    -e VRRP_UNICAST_PEERS=172.30.253.11 \
    -e HEALTHCHECK_ENABLED=false \
    "$IMAGE" >/dev/null

keepalived_ready=false
for _attempt in {1..100}; do
    if docker exec "$CONTAINER_NAME" sh -c '[ "$(cat /proc/1/comm)" = keepalived ]' 2>/dev/null; then
        keepalived_ready=true
        break
    fi
done
[ "$keepalived_ready" = true ] || fail 'signal handling: Keepalived did not become PID 1'

docker stop --time 3 "$CONTAINER_NAME" >/dev/null
container_exit=$(docker inspect --format '{{.State.ExitCode}}' "$CONTAINER_NAME")
[ "$container_exit" -ne 137 ] || fail 'signal handling: container required SIGKILL'
pass 'clean signal handling with Keepalived as PID 1'

printf '1..%d\n' "$tests_run"