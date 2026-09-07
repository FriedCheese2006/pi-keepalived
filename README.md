# Pi-hole Keepalived sidecar

A small, multi-architecture Keepalived image that shares a Pi-hole container's
network namespace and moves a DNS virtual IP (VIP) between two hosts. Its
configuration is validated and generated atomically from environment variables
at every start. No package manager or network download runs during startup.

The implementation currently supports IPv4 VRRP and IPv4 VIPs. Both nodes
should normally use `VRRP_STATE=BACKUP`; priority determines the elected master.

## How it works

Compose's `network_mode: "service:pihole"` puts the sidecar in the Pi-hole
container's existing network namespace. Keepalived therefore sees Pi-hole's
interfaces and addresses, adds the VIP there, and can query the local resolver
at `127.0.0.1`. The sidecar must not define its own networks or published ports.
Restarting the Pi-hole container recreates that namespace, so Compose's
`depends_on` restart behavior and `restart: unless-stopped` are important.

The generated `vrrp_script` queries `pi.hole` through the configured local DNS
server. It uses a one-shot `dig` query wrapped by an independent hard timeout,
requires `NOERROR` and at least one answer record, and never queries through the
VIP. `weight 0` gives the tracked script fault semantics: after
`HEALTHCHECK_FALL` failures the instance enters FAULT and releases the VIP; it
recovers after `HEALTHCHECK_RISE` successful checks. `init_fail` prevents a node
from taking the VIP before DNS first passes.

Set `HEALTHCHECK_MODE=recursive` to query `HEALTHCHECK_RECURSIVE_NAME` instead.
That mode tests Pi-hole plus its upstream path, but is intentionally disabled by
default so an Internet outage does not make both local DNS nodes abandon the
VIP.

## Build and test

```sh
make test
make lint
make scan
```

`make test` builds `pi-keepalived:test` and runs configuration, parser, DNS
probe, capability, PID 1, and signal-handling tests. `make lint` runs the pinned
ShellCheck container. `make scan` runs a pinned Trivy container and fails for
fixed HIGH or CRITICAL vulnerabilities. Docker with permission to create a
bridge network and add `NET_ADMIN`/`NET_RAW` is required.

The runtime image uses Alpine 3.23 and pins Keepalived 2.3.4-r3 and its direct
runtime tools. The build also applies available Alpine security upgrades. These
packages are installed only by `docker build`. Installing
at startup would make availability depend on repositories and DNS, increase
startup time, make rollbacks non-reproducible, and require unnecessary network
access from a privileged networking process.

## Two-node deployment

[docker-compose.example.yaml](docker-compose.example.yaml) is one per-host
Compose definition. It pins Pi-hole v6 and the sidecar image, uses a read-only
sidecar root filesystem, and mounts only `/run/keepalived` as tmpfs. It does not
mount a Keepalived configuration. Create an external macvlan or ipvlan network
appropriate for the host first; for example, adjust the parent and gateway:

All addresses in this section use the RFC 5737 documentation range and must be
replaced with addresses from the deployment network.

```sh
docker network create --driver macvlan \
	--subnet 192.0.2.0/24 --gateway 192.0.2.1 \
	--opt parent=enp1s0 pihole_lan
```

On the higher-priority node, place these values in the deployment environment
(for example a root-readable `.env` next to a local copy of the example):

```dotenv
NODE_NAME=pihole-a
PIHOLE_ADDRESS=192.0.2.11
VRRP_PRIORITY=110
VRRP_UNICAST_PEER=192.0.2.12
PIHOLE_PASSWORD=replace-with-a-node-specific-password
```

On the lower-priority node:

```dotenv
NODE_NAME=pihole-b
PIHOLE_ADDRESS=192.0.2.12
VRRP_PRIORITY=100
VRRP_UNICAST_PEER=192.0.2.11
PIHOLE_PASSWORD=replace-with-a-node-specific-password
```

Then deploy the same file on each host:

```sh
docker compose --env-file .env -f docker-compose.example.yaml up -d
```

The Pi-hole example uses `FTLCONF_dns_listeningMode=ALL`, which is needed when
serving from a Docker/macvlan interface. It deliberately does not use the
removed Pi-hole v6 variable `FTLCONF_LOCAL_IPV4`.

Compose implementations that support the long `depends_on` syntax wait for
Pi-hole to be healthy before starting Keepalived. The VRRP health script remains
the authority for ongoing failover after startup.

## Required capabilities and firewall

Do not use privileged mode. Unicast VRRP needs only:

- `NET_ADMIN` to add and remove the VIP and receive network changes.
- `NET_RAW` to send and receive VRRP advertisements.

The test suite also drops every other capability. Linux normally does not
require `NET_BROADCAST` for VRRP multicast; add it only if a particular kernel
or security policy proves it necessary. Multicast mode still requires
`NET_ADMIN` and `NET_RAW`.

Allow IP protocol **112** (VRRP), not TCP or UDP port 112, in both directions
between each node's `VRRP_UNICAST_SRC_IP` and `VRRP_UNICAST_PEERS`. The
addresses must be directly routable between peers. For multicast mode, the
network must also carry VRRP multicast traffic to `224.0.0.18`.

## Configuration

| Variable | Default | Validation and purpose |
| --- | --- | --- |
| `VRRP_INTERFACE` | `eth0` | Linux interface name, at most 15 characters |
| `VRRP_VIRTUAL_ROUTER_ID` | `51` | Integer 1-255; must match on both nodes |
| `VRRP_PRIORITY` | required | Integer 1-255; higher wins |
| `VRRP_VIRTUAL_IP` | required | IPv4 CIDR, such as `192.0.2.10/24` |
| `VRRP_UNICAST_SRC_IP` | required in unicast | Local Pi-hole IPv4 address |
| `VRRP_UNICAST_PEERS` | required in unicast | Comma- or space-separated peer IPv4 addresses |
| `VRRP_INSTANCE_NAME` | `VI_1` | Keepalived instance identifier |
| `VRRP_STATE` | `BACKUP` | `BACKUP` or explicitly selected `MASTER` |
| `VRRP_ADVERT_INT` | `1` | Advertisement interval, 1-255 seconds |
| `VRRP_PREEMPT` | `true` | `false` renders `nopreempt` and requires `BACKUP` |
| `VRRP_MODE` | `unicast` | `unicast` or explicit `multicast` |
| `VRRP_AUTH_PASS` | unset | Optional 1-8 byte authentication token |
| `VRRP_AUTH_PASS_FILE` | unset | File containing the token; preferred for Docker secrets |
| `VRRP_GARP_MASTER_DELAY` | unset | Optional integer delay, 0-3600 seconds |
| `VRRP_GARP_MASTER_REPEAT` | unset | Optional repeat count, 1-255 |
| `HEALTHCHECK_ENABLED` | `true` | Enables DNS fault tracking |
| `HEALTHCHECK_MODE` | `local` | `local` or opt-in `recursive` |
| `HEALTHCHECK_DNS_SERVER` | `127.0.0.1` | Local IPv4 resolver; the VIP is rejected |
| `HEALTHCHECK_DNS_PORT` | `53` | Resolver port, 1-65535 |
| `HEALTHCHECK_DNS_NAME` | `pi.hole` | Local-mode name that must return an answer |
| `HEALTHCHECK_RECURSIVE_NAME` | `example.com` | Recursive-mode name that must return an answer |
| `HEALTHCHECK_INTERVAL` | `2` | Check interval, 1-3600 seconds |
| `HEALTHCHECK_TIMEOUT` | `1` | Query timeout, 1-60 and no greater than interval |
| `HEALTHCHECK_RISE` | `2` | Consecutive successes required to recover |
| `HEALTHCHECK_FALL` | `2` | Consecutive failures required to enter FAULT |

For multicast, set `VRRP_MODE=multicast` and leave both unicast variables unset.
Unicast is preferred across Docker and switched networks because peer traffic is
explicit and does not depend on multicast forwarding.

When using Compose secrets, set `VRRP_AUTH_PASS_FILE=/run/secrets/vrrp_auth` and
grant the service that secret. Keepalived implements VRRP `PASS` authentication
with an actual maximum of eight bytes; this image rejects longer values rather
than silently truncating them. VRRP authentication is not cryptographic
security and does not provide confidentiality or meaningful protection against
an on-path attacker. Use firewall policy and network isolation as the security
boundary. Authentication values are never printed; startup output replaces the
value with `[REDACTED]`.

## Operations

Inspect the redacted generated configuration in startup logs:

```sh
docker compose -f docker-compose.example.yaml logs keepalived
```

An administrator can inspect the exact runtime file, including any configured
authentication token, with:

```sh
docker compose -f docker-compose.example.yaml exec keepalived \
	cat /run/keepalived/keepalived.conf
```

For a rollout, first verify protocol 112 between the node addresses and deploy
the lower-priority node. Confirm its logs show valid configuration and BACKUP,
then deploy the higher-priority node. Confirm the VIP is present on the elected
master and query it from a third machine. Upgrade or restart the BACKUP first,
verify it rejoins, then upgrade the MASTER.

To test failover, continuously query the VIP from a third machine, stop Pi-hole
on the current master, and watch Keepalived logs on both nodes:

```sh
dig @192.0.2.10 pi.hole
docker compose -f docker-compose.example.yaml stop pihole
docker compose -f docker-compose.example.yaml logs --follow keepalived
```

After at least `HEALTHCHECK_FALL` failed checks, the VIP should appear on the
peer. Start Pi-hole again, wait for `HEALTHCHECK_RISE` successes, and verify the
election behavior. With preemption enabled, the healthy higher-priority node
should retake the VIP; with `VRRP_PREEMPT=false`, the healthy current master
retains it.

## GitHub CI/CD

[.github/workflows/ci.yaml](.github/workflows/ci.yaml) runs on pull requests,
`main`, version tags, manual dispatch, and every Monday at 04:17 UTC. It runs
ShellCheck, all tests, and Trivy before publishing an amd64/arm64 image with
provenance and an SBOM. Scheduled builds use `--pull` and no cache, so Alpine
base changes are incorporated; removed or changed pinned packages fail loudly
and require an intentional version update.

GitHub-hosted Linux runners provide Docker and QEMU. Publishing to GitHub
Container Registry uses the built-in `GITHUB_TOKEN`, so no registry secrets are
required. Push `v1.0.0` to publish the `:1.0.0` tag used by the Compose example;
`latest` and immutable `sha-<commit>` tags are also published.

