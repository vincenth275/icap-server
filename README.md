# icap-server scaffolding

This repository contains generator scripts to scaffold a containerized ICAP demo server based on c-icap.
The focus is a reproducible, configuration-driven setup where *all* official modules are compiled,
and services are enabled only via configuration files.

## What the generated project provides
- c-icap-server compiled from official sources
- c-icap-modules compiled from official sources
- a custom service `rewrite_demo` (REQMOD + RESPMOD)
  - adds header `X-ICAP-Rewritten: 1`
  - for textual bodies, replaces `ORIGINAL` -> `REWRITTEN` in-stream
- a multi-stage Docker build (Debian Bookworm)
- configuration-driven activation (no service activation at build time)

## Script in this repo
- `create_cicap_full.sh` (canonical generator)
  - validated working path
  - uses a minimal container config that includes `services.conf`

## Quick start (current focus)
Generate a project with the canonical script:

```bash
./create_cicap_full.sh icap-cicap-full
cd icap-cicap-full

docker build -t cicap:dev -f docker/Dockerfile .
docker run --rm -p 1344:1344 cicap:dev
```

ICAP OPTIONS test:

```bash
printf "OPTIONS icap://localhost:1344/rewrite_demo ICAP/1.0\r\nHost: localhost\r\n\r\n" | nc -w 2 localhost 1344
```

Expected: `ICAP/1.0 200 OK` with `Methods: RESPMOD, REQMOD` and service name.

ICAP RESPMOD test:

```bash
printf "RESPMOD icap://localhost:1344/rewrite_demo ICAP/1.0\r\nHost: localhost\r\nAllow: 204\r\nEncapsulated: res-hdr=0, res-body=73\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n14\r\nHELLO ORIGINAL WORLD\r\n0\r\n\r\n" | nc -w 2 localhost 1344
```

Expected: `X-ICAP-Rewritten: 1` header and body token `ORIGINAL` rewritten to `REWRITTEN`.

## Verified modules (Jan 30, 2026)
The following modules are present in the built image (`cicap:dev`) under `/usr/lib/c_icap`:
- srv_content_filtering (HTTP body content filtering)
- virus_scan (antivirus scanning)
- dnsbl_tables (IP/DNS blacklists)
- srv_url_check (URL reputation checks)
- shared_cache (decision caching)
- sys_logger (advanced logging)

Verification command:

```bash
docker run --rm --entrypoint /bin/sh cicap:dev -c "ls /usr/lib/c_icap"
```

## Services configuration
All services are prelisted in `icap-cicap-full/config/services.conf`.

Default enabled:
- `echo` (`srv_echo.so`)

Optional services (commented by default in `services.conf`):
- `rewrite_demo` (`srv_rewrite_demo.so`)
- `content_filter` (`srv_content_filtering.so`)
- `virus_scan` (`srv_virus_scan.so`)
- `dnsbl_tables` (`dnsbl_tables.so`)
- `url_check` (`srv_url_check.so`)
- `shared_cache` (`shared_cache.so`)
- `sys_logger` (`sys_logger.so`)

To enable any service, uncomment its line in `services.conf` and restart the container.

Note: `sys_logger` is **not** an ICAP service. It is a logger module, enabled via
`sys_logger.conf` (see below). It will not respond to ICAP `OPTIONS`.

Note: `dnsbl_tables` is **not** an ICAP service. It is a lookup module used by
`srv_url_check` and is enabled via `dnsbl_tables.conf` (see below).

Note: `shared_cache` is **not** an ICAP service. It is a cache module enabled
via `shared_cache.conf`.

## virus_scan (ClamAV) setup
The `virus_scan` service requires a running ClamAV `clamd` daemon. We run it as a
separate container on the same Docker network as the ICAP server. The official
ClamAV images are published as `clamav/clamav` on Docker Hub; the ClamAV docs
describe the official Docker image tags.

### Start ClamAV (external container)

```bash
docker network create icap-net || true
docker run -d --name clamav --network icap-net -p 3310:3310 clamav/clamav:latest
```

Wait for ClamAV to finish its initial database load (it can take a bit on first
start), then enable the ICAP service:

### Enable virus_scan in ICAP config
1) Uncomment in `icap-cicap-full/config/services.conf`:

```
Service virus_scan virus_scan.so
```

2) Uncomment in `icap-cicap-full/config/c-icap.conf`:

```
Include /etc/c-icap/virus_scan.conf
Include /etc/c-icap/clamd_mod.conf
```

3) Ensure `icap-cicap-full/config/clamd_mod.conf` points to the ClamAV container:

```
clamd_mod.ClamdHost clamav
clamd_mod.ClamdPort 3310
```

4) Restart the ICAP container:

```bash
docker rm -f cicap_dev || true
docker run -d --name cicap_dev --network icap-net -p 1344:1344 \
  -v ./config:/etc/c-icap cicap:dev
```

### Verify

```bash
printf "OPTIONS icap://localhost:1344/virus_scan ICAP/1.0\r\nHost: localhost\r\n\r\n" | nc -w 2 localhost 1344
```

## sys_logger setup
`sys_logger` is a logger module (not a service). To enable it:

1) Uncomment in `config/c-icap.conf`:

```
Include /etc/c-icap/sys_logger.conf
```

2) Restart the ICAP container:

```bash
docker restart cicap_dev
```

3) Verify ICAP still responds (for example using `echo`):

```bash
printf "OPTIONS icap://localhost:1344/echo ICAP/1.0\r\nHost: localhost\r\n\r\n" | nc -w 2 localhost 1344
```

To actually emit logs, the container needs a syslog daemon. The runtime image
now installs and starts `rsyslog` by default (best effort).

Note: the container runs as root so `rsyslogd` can create `/dev/log`, but
`c-icap` still runs as the unprivileged `icap` user.

## dnsbl_tables + url_check setup
`dnsbl_tables` is a lookup module used by `srv_url_check` (URL reputation checks).

1) Uncomment in `config/c-icap.conf`:

```
Include /etc/c-icap/dnsbl_tables.conf
Include /etc/c-icap/srv_url_check.conf
```

2) Uncomment in `config/services.conf`:

```
Service url_check srv_url_check.so
```

3) Restart the ICAP container:

```bash
docker restart cicap_dev
```

4) Verify:

```bash
printf "OPTIONS icap://localhost:1344/url_check ICAP/1.0\r\nHost: localhost\r\n\r\n" | nc -w 2 localhost 1344
```

## shared_cache setup
`shared_cache` is a module used by services that support caching. To enable it:

1) Uncomment in `config/c-icap.conf`:

```
Include /etc/c-icap/shared_cache.conf
```

2) Restart the ICAP container:

```bash
docker restart cicap_dev
```

## Multi-container workflow (recommended)
Goal: users only uncomment config lines and start containers on the same Docker network.

1) Create a shared network once:

```bash
docker network create icap-net || true
```

2) Start required backend containers (example: ClamAV for `virus_scan`):

```bash
docker run -d --name clamav --network icap-net -p 3310:3310 clamav/clamav:latest
```

3) Enable the ICAP service in config:
- Uncomment the service in `config/services.conf`
- Uncomment any related includes in `config/c-icap.conf`

4) Start ICAP with the config directory mounted:

```bash
docker rm -f cicap_dev || true
docker run -d --name cicap_dev --network icap-net -p 1344:1344 \
  -v ./config:/etc/c-icap cicap:dev
```

## Service test results (Jan 30, 2026)
Test method: enable one service at a time in `services.conf` (echo always enabled), restart container, run ICAP `OPTIONS` for that service.

```
echo           -> 200 OK (Echo demo service)
rewrite_demo   -> 200 OK (Rewrite demo service)
content_filter -> 200 OK (srv_content_filtering service)
url_check      -> 200 OK (Url_Check demo service)
virus_scan     -> 200 OK (requires clamd container on same network)
dnsbl_tables   -> N/A (lookup module used by url_check)
shared_cache   -> N/A (cache module, not a service)
sys_logger     -> N/A (logger module, not a service)
```

Notes:
- Some services may require extra configuration or backends (e.g., clamd for `virus_scan`) to respond.

## Next steps
- Test each service one by one and record results.
- Build a small HTML test page to exercise ICAP services end‑to‑end.

## Notes
- The demo is intended for integration tests and presales demonstrations, not production AV.
- AV-related config files are included but disabled by default to avoid startup failures when clamd
  is not configured or when modules are not enabled.
- The validated config file is `icap-cicap-full/config/c-icap.conf`.
