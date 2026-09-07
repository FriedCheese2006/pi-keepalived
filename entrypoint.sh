#!/bin/sh
set -eu

export LC_ALL=C
umask 077

CONFIG_DIR=/run/keepalived
CONFIG_FILE=$CONFIG_DIR/keepalived.conf
VALIDATION_LOG=$CONFIG_DIR/config-test.log
AUTH_PASS=
UNICAST_PEER_LINES=

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

validate_uint_range() {
    variable_name=$1
    variable_value=$2
    minimum=$3
    maximum=$4

    case "$variable_value" in
        ''|*[!0-9]*) fail "$variable_name must be an integer between $minimum and $maximum" ;;
    esac
    [ "${#variable_value}" -le 10 ] || fail "$variable_name must be an integer between $minimum and $maximum"
    if ! { [ "$variable_value" -ge "$minimum" ] 2>/dev/null && [ "$variable_value" -le "$maximum" ] 2>/dev/null; }; then
        fail "$variable_name must be between $minimum and $maximum"
    fi
}

validate_bool() {
    variable_name=$1
    variable_value=$2
    case "$variable_value" in
        true|false) ;;
        *) fail "$variable_name must be true or false" ;;
    esac
}

is_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (octet = 1; octet <= 4; octet++) {
                if ($octet !~ /^[0-9]+$/ || $octet > 255 ||
                    (length($octet) > 1 && substr($octet, 1, 1) == "0")) {
                    exit 1
                }
            }
        }
    '
}

validate_ipv4() {
    variable_name=$1
    variable_value=$2
    is_ipv4 "$variable_value" || fail "$variable_name must be a valid IPv4 address"
}

validate_cidr() {
    variable_name=$1
    variable_value=$2
    case "$variable_value" in
        */*/*|/*|*/|'') fail "$variable_name must be an IPv4 address with a prefix, for example 192.0.2.10/24" ;;
    esac

    cidr_address=${variable_value%/*}
    cidr_prefix=${variable_value##*/}
    is_ipv4 "$cidr_address" || fail "$variable_name contains an invalid IPv4 address"
    validate_uint_range "$variable_name prefix" "$cidr_prefix" 0 32
}

validate_dns_name() {
    variable_name=$1
    variable_value=$2
    [ "${#variable_value}" -le 253 ] || fail "$variable_name must not exceed 253 characters"
    printf '%s\n' "$variable_value" | grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*\.?$' ||
        fail "$variable_name must be a valid DNS name"
}

load_authentication() {
    if [ -n "$VRRP_AUTH_PASS" ] && [ -n "$VRRP_AUTH_PASS_FILE" ]; then
        fail "set only one of VRRP_AUTH_PASS and VRRP_AUTH_PASS_FILE"
    fi

    if [ -n "$VRRP_AUTH_PASS_FILE" ]; then
        [ -f "$VRRP_AUTH_PASS_FILE" ] || fail "VRRP_AUTH_PASS_FILE does not name a regular file"
        [ -r "$VRRP_AUTH_PASS_FILE" ] || fail "VRRP_AUTH_PASS_FILE is not readable"
        AUTH_PASS=$(cat -- "$VRRP_AUTH_PASS_FILE")
        [ -n "$AUTH_PASS" ] || fail "VRRP_AUTH_PASS_FILE is empty"
    else
        AUTH_PASS=$VRRP_AUTH_PASS
    fi

    [ -z "$AUTH_PASS" ] && return
    [ "${#AUTH_PASS}" -le 8 ] || fail "VRRP authentication passwords are limited to 8 bytes by Keepalived"
    case "$AUTH_PASS" in
        *[!A-Za-z0-9_.-]*) fail "VRRP authentication passwords may contain only letters, digits, dot, underscore, and hyphen" ;;
    esac
}

validate_peers() {
    peer_input=$VRRP_UNICAST_PEERS
    peer_compact=$(printf '%s' "$peer_input" | tr -d '[:space:]')
    case "$peer_compact" in
        ''|,*|*,|*,,*) fail "VRRP_UNICAST_PEERS must contain one or more comma- or space-separated IPv4 addresses" ;;
        *[!0-9.,]*) fail "VRRP_UNICAST_PEERS contains invalid characters" ;;
    esac

    normalized_peers=$(printf '%s' "$peer_input" | tr ',' ' ')
    for peer_address in $normalized_peers; do
        is_ipv4 "$peer_address" || fail "VRRP_UNICAST_PEERS contains an invalid IPv4 address"
        if [ -z "$UNICAST_PEER_LINES" ]; then
            UNICAST_PEER_LINES="        $peer_address"
        else
            UNICAST_PEER_LINES="$UNICAST_PEER_LINES
        $peer_address"
        fi
    done
}

apply_defaults() {
    : "${VRRP_INTERFACE:=eth0}"
    : "${VRRP_VIRTUAL_ROUTER_ID:=51}"
    : "${VRRP_INSTANCE_NAME:=VI_1}"
    : "${VRRP_STATE:=BACKUP}"
    : "${VRRP_ADVERT_INT:=1}"
    : "${VRRP_PREEMPT:=true}"
    : "${VRRP_MODE:=unicast}"
    : "${VRRP_PRIORITY:=}"
    : "${VRRP_VIRTUAL_IP:=}"
    : "${VRRP_UNICAST_SRC_IP:=}"
    : "${VRRP_UNICAST_PEERS:=}"
    : "${VRRP_AUTH_PASS:=}"
    : "${VRRP_AUTH_PASS_FILE:=}"
    : "${VRRP_GARP_MASTER_DELAY:=}"
    : "${VRRP_GARP_MASTER_REPEAT:=}"
    : "${HEALTHCHECK_ENABLED:=true}"
    : "${HEALTHCHECK_MODE:=local}"
    : "${HEALTHCHECK_DNS_SERVER:=127.0.0.1}"
    : "${HEALTHCHECK_DNS_PORT:=53}"
    : "${HEALTHCHECK_DNS_NAME:=pi.hole}"
    : "${HEALTHCHECK_RECURSIVE_NAME:=example.com}"
    : "${HEALTHCHECK_INTERVAL:=2}"
    : "${HEALTHCHECK_TIMEOUT:=1}"
    : "${HEALTHCHECK_RISE:=2}"
    : "${HEALTHCHECK_FALL:=2}"

    export HEALTHCHECK_MODE HEALTHCHECK_DNS_SERVER HEALTHCHECK_DNS_PORT
    export HEALTHCHECK_DNS_NAME HEALTHCHECK_RECURSIVE_NAME HEALTHCHECK_TIMEOUT
}

validate_environment() {
    [ -n "$VRRP_PRIORITY" ] || fail "VRRP_PRIORITY is required"
    [ -n "$VRRP_VIRTUAL_IP" ] || fail "VRRP_VIRTUAL_IP is required"

    [ "${#VRRP_INTERFACE}" -le 15 ] || fail "VRRP_INTERFACE must not exceed Linux's 15-character interface-name limit"
    case "$VRRP_INTERFACE" in
        ''|*[!A-Za-z0-9_.:-]*) fail "VRRP_INTERFACE contains invalid characters" ;;
    esac
    [ "${#VRRP_INSTANCE_NAME}" -le 32 ] || fail "VRRP_INSTANCE_NAME must not exceed 32 characters"
    case "$VRRP_INSTANCE_NAME" in
        ''|*[!A-Za-z0-9_-]*) fail "VRRP_INSTANCE_NAME contains invalid characters" ;;
    esac
    case "$VRRP_STATE" in
        BACKUP|MASTER) ;;
        *) fail "VRRP_STATE must be BACKUP or MASTER" ;;
    esac
    case "$VRRP_MODE" in
        unicast|multicast) ;;
        *) fail "VRRP_MODE must be unicast or multicast" ;;
    esac

    validate_uint_range VRRP_VIRTUAL_ROUTER_ID "$VRRP_VIRTUAL_ROUTER_ID" 1 255
    validate_uint_range VRRP_PRIORITY "$VRRP_PRIORITY" 1 255
    validate_uint_range VRRP_ADVERT_INT "$VRRP_ADVERT_INT" 1 255
    validate_bool VRRP_PREEMPT "$VRRP_PREEMPT"
    validate_cidr VRRP_VIRTUAL_IP "$VRRP_VIRTUAL_IP"

    if [ "$VRRP_PREEMPT" = false ] && [ "$VRRP_STATE" != BACKUP ]; then
        fail "VRRP_PREEMPT=false requires VRRP_STATE=BACKUP"
    fi

    if [ "$VRRP_MODE" = unicast ]; then
        [ -n "$VRRP_UNICAST_SRC_IP" ] || fail "VRRP_UNICAST_SRC_IP is required in unicast mode"
        validate_ipv4 VRRP_UNICAST_SRC_IP "$VRRP_UNICAST_SRC_IP"
        validate_peers
    else
        [ -z "$VRRP_UNICAST_SRC_IP" ] || fail "VRRP_UNICAST_SRC_IP must be unset in multicast mode"
        [ -z "$VRRP_UNICAST_PEERS" ] || fail "VRRP_UNICAST_PEERS must be unset in multicast mode"
    fi

    if [ -n "$VRRP_GARP_MASTER_DELAY" ]; then
        validate_uint_range VRRP_GARP_MASTER_DELAY "$VRRP_GARP_MASTER_DELAY" 0 3600
    fi
    if [ -n "$VRRP_GARP_MASTER_REPEAT" ]; then
        validate_uint_range VRRP_GARP_MASTER_REPEAT "$VRRP_GARP_MASTER_REPEAT" 1 255
    fi

    validate_bool HEALTHCHECK_ENABLED "$HEALTHCHECK_ENABLED"
    case "$HEALTHCHECK_MODE" in
        local|recursive) ;;
        *) fail "HEALTHCHECK_MODE must be local or recursive" ;;
    esac
    validate_ipv4 HEALTHCHECK_DNS_SERVER "$HEALTHCHECK_DNS_SERVER"
    validate_uint_range HEALTHCHECK_DNS_PORT "$HEALTHCHECK_DNS_PORT" 1 65535
    validate_dns_name HEALTHCHECK_DNS_NAME "$HEALTHCHECK_DNS_NAME"
    validate_dns_name HEALTHCHECK_RECURSIVE_NAME "$HEALTHCHECK_RECURSIVE_NAME"
    validate_uint_range HEALTHCHECK_INTERVAL "$HEALTHCHECK_INTERVAL" 1 3600
    validate_uint_range HEALTHCHECK_TIMEOUT "$HEALTHCHECK_TIMEOUT" 1 60
    validate_uint_range HEALTHCHECK_RISE "$HEALTHCHECK_RISE" 1 255
    validate_uint_range HEALTHCHECK_FALL "$HEALTHCHECK_FALL" 1 255
    [ "$HEALTHCHECK_TIMEOUT" -le "$HEALTHCHECK_INTERVAL" ] ||
        fail "HEALTHCHECK_TIMEOUT must be less than or equal to HEALTHCHECK_INTERVAL"

    vip_address=${VRRP_VIRTUAL_IP%/*}
    [ "$HEALTHCHECK_DNS_SERVER" != "$vip_address" ] ||
        fail "HEALTHCHECK_DNS_SERVER must address the local DNS service, not the VRRP VIP"

    load_authentication
}

render_config() {
    config_temp=$(mktemp "$CONFIG_DIR/keepalived.conf.XXXXXX") ||
        fail "$CONFIG_DIR must be writable; mount a tmpfs there when using a read-only root filesystem"
    trap 'rm -f "${config_temp:-}" "$VALIDATION_LOG"' EXIT HUP INT TERM

    {
        printf 'global_defs {\n'
        printf '    enable_script_security\n'
        printf '    script_user root\n'
        printf '}\n\n'

        if [ "$HEALTHCHECK_ENABLED" = true ]; then
            printf 'vrrp_script check_dns {\n'
            printf '    script "/usr/local/bin/check-dns.sh"\n'
            printf '    interval %s\n' "$HEALTHCHECK_INTERVAL"
            printf '    timeout %s\n' "$HEALTHCHECK_TIMEOUT"
            printf '    rise %s\n' "$HEALTHCHECK_RISE"
            printf '    fall %s\n' "$HEALTHCHECK_FALL"
            printf '    weight 0\n'
            printf '    init_fail\n'
            printf '}\n\n'
        fi

        printf 'vrrp_instance %s {\n' "$VRRP_INSTANCE_NAME"
        printf '    state %s\n' "$VRRP_STATE"
        printf '    interface %s\n' "$VRRP_INTERFACE"
        printf '    virtual_router_id %s\n' "$VRRP_VIRTUAL_ROUTER_ID"
        printf '    priority %s\n' "$VRRP_PRIORITY"
        printf '    advert_int %s\n' "$VRRP_ADVERT_INT"

        if [ "$VRRP_MODE" = unicast ]; then
            printf '    unicast_src_ip %s\n' "$VRRP_UNICAST_SRC_IP"
            printf '    unicast_peer {\n'
            printf '%s\n' "$UNICAST_PEER_LINES"
            printf '    }\n'
        fi
        if [ "$VRRP_PREEMPT" = false ]; then
            printf '    nopreempt\n'
        fi
        if [ -n "$VRRP_GARP_MASTER_DELAY" ]; then
            printf '    garp_master_delay %s\n' "$VRRP_GARP_MASTER_DELAY"
        fi
        if [ -n "$VRRP_GARP_MASTER_REPEAT" ]; then
            printf '    garp_master_repeat %s\n' "$VRRP_GARP_MASTER_REPEAT"
        fi
        if [ -n "$AUTH_PASS" ]; then
            printf '    authentication {\n'
            printf '        auth_type PASS\n'
            printf '        auth_pass %s\n' "$AUTH_PASS"
            printf '    }\n'
        fi

        printf '    virtual_ipaddress {\n'
        printf '        %s dev %s\n' "$VRRP_VIRTUAL_IP" "$VRRP_INTERFACE"
        printf '    }\n'
        if [ "$HEALTHCHECK_ENABLED" = true ]; then
            printf '    track_script {\n'
            printf '        check_dns\n'
            printf '    }\n'
        fi
        printf '}\n'
    } > "$config_temp"

    chmod 600 "$config_temp"
}

redact_config() {
    sed 's/^\([[:space:]]*auth_pass[[:space:]]*\).*/\1[REDACTED]/' "$1"
}

validate_config() {
    if ! /usr/sbin/keepalived --config-test --use-file="$config_temp" >"$VALIDATION_LOG" 2>&1; then
        printf 'ERROR: Keepalived rejected the generated configuration:\n' >&2
        redact_config "$VALIDATION_LOG" >&2
        exit 1
    fi
    rm -f "$VALIDATION_LOG"
    mv -f "$config_temp" "$CONFIG_FILE"
    config_temp=
}

print_config() {
    printf '%s\n' 'Generated Keepalived configuration (authentication redacted):'
    printf '%s\n' '-----'
    redact_config "$CONFIG_FILE"
    printf '%s\n' '-----'
}

main() {
    apply_defaults
    validate_environment
    render_config
    validate_config
    print_config

    case "${1:-run}" in
        config-test) exit 0 ;;
        run)
            exec /usr/sbin/keepalived \
                --dont-fork \
                --log-console \
                --no-syslog \
                --vrrp \
                --use-file="$CONFIG_FILE" \
                --pid="$CONFIG_DIR/keepalived.pid" \
                --vrrp_pid="$CONFIG_DIR/keepalived-vrrp.pid"
            ;;
        *) fail "unknown entrypoint command: $1" ;;
    esac
}

main "$@"