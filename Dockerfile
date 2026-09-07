# syntax=docker/dockerfile:1.7
ARG ALPINE_VERSION=3.23
FROM alpine:${ALPINE_VERSION}

ARG KEEPALIVED_VERSION=2.3.4-r3
ARG BIND_TOOLS_VERSION=9.20.26-r0
ARG COREUTILS_VERSION=9.8-r1

LABEL org.opencontainers.image.title="Pi-hole Keepalived" \
      org.opencontainers.image.description="Environment-configured Keepalived sidecar for Pi-hole" \
    org.opencontainers.image.source="https://github.com/FriedCheese2006/pi-keepalived" \
      org.opencontainers.image.licenses="MIT"

RUN apk upgrade --no-cache \
    && apk add --no-cache \
        "bind-tools=${BIND_TOOLS_VERSION}" \
        "coreutils=${COREUTILS_VERSION}" \
        "keepalived=${KEEPALIVED_VERSION}" \
    && mkdir -p /run/keepalived \
    && chmod 0755 /run/keepalived

COPY --chmod=0755 entrypoint.sh check-dns.sh /usr/local/bin/

STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["sh", "-ec", "pidof keepalived >/dev/null"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["run"]