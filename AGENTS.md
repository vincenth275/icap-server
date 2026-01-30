# Project context

## Goal
Build a containerized ICAP demo server based on c-icap for integration demos (REQMOD/RESPMOD), with a clean, reproducible, and config-driven setup.

## Key decisions
- Build compiles **all** official c-icap modules.
- No service activation in the Dockerfile; activation happens only via config files.
- Default config enables the custom rewrite demo service and keeps AV includes commented out.

## Current validated path
- Generator script: `create_cicap_full_v15.sh`
- Config file used: `icap-cicap-full/config/c-icap.conf`

## Quick commands
Generate, build, and run:

```bash
./create_cicap_full_v15.sh icap-cicap-full
cd icap-cicap-full

docker build -t cicap:dev -f docker/Dockerfile .
docker run --rm -p 1344:1344 cicap:dev
```

ICAP OPTIONS test:

```bash
printf "OPTIONS icap://localhost:1344/rewrite_demo ICAP/1.0\r\nHost: localhost\r\n\r\n" | nc -w 2 localhost 1344
```

ICAP RESPMOD test:

```bash
printf "RESPMOD icap://localhost:1344/rewrite_demo ICAP/1.0\r\nHost: localhost\r\nAllow: 204\r\nEncapsulated: res-hdr=0, res-body=73\r\n\r\nHTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n14\r\nHELLO ORIGINAL WORLD\r\n0\r\n\r\n" | nc -w 2 localhost 1344
```

Expected results:
- OPTIONS: `ICAP/1.0 200 OK` with `Methods: RESPMOD, REQMOD`
- RESPMOD: header `X-ICAP-Rewritten: 1` and token rewrite `ORIGINAL` -> `REWRITTEN`

## Notes
- AV configs exist but are commented out by default; enable only with proper modules and clamd setup.
- The `create_cicap_full_idempotent_v2_fixed.sh` script is experimental and not the current validated path.
