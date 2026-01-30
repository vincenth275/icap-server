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

## Service test results (Jan 30, 2026)
Test method: enable one service at a time in `services.conf` (echo always enabled), restart container, run ICAP `OPTIONS` for that service.

```
echo           -> 200 OK (Echo demo service)
rewrite_demo   -> 200 OK (Rewrite demo service)
content_filter -> 200 OK (srv_content_filtering service)
url_check      -> 200 OK (Url_Check demo service)
virus_scan     -> NO RESPONSE (within 5s)
dnsbl_tables   -> NO RESPONSE (within 5s)
shared_cache   -> NO RESPONSE (within 5s)
sys_logger     -> NO RESPONSE (within 5s)
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
