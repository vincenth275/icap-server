# icap-cicap-full

This project builds a container image with:

- **c-icap-server** (official upstream)
- **c-icap-modules** (official upstream), including **virus_scan**
- a small custom ICAP service: **rewrite_demo**
  - injects header: `X-ICAP-Rewritten: 1`
  - for `Content-Type: text/*`, rewrites `ORIGINAL` -> `REWRITTEN` in the response body stream

## Build
```bash
docker build -t cicap:dev -f docker/Dockerfile .
```

## Run
```bash
docker run --rm -p 1344:1344 cicap:dev
```

## Notes
- The rewrite service is deterministic and meant for demos/tests.
- Antivirus scanning depends on **clamd** being operational inside the container.
