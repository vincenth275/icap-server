# Hardening Plan (Build Robustness, Idempotency, Debug Mode)

This plan focuses on making the generator and build pipeline resilient to upstream changes (versions, mirror issues, API changes) while improving test coverage and diagnostics.

## 1) Pinning + verification
- Pin upstream repos by **tag + commit SHA** (server + modules) in `upstream.env`.
- Record expected `git rev-parse HEAD` for each upstream and verify after fetch.
- Add optional **tarball checksum** verification when using release archives.
- Provide a `--latest` flag to override pins (explicit opt‑in only).

## 2) Deterministic fetch
- Add a `FETCH_MODE` in `upstream.env`: `git` vs `tarball`.
- Fail fast if the tag/commit is missing, rather than silently falling back.
- Log the exact fetch command and resolved refs in a build log.

## 3) Idempotent generator
- Introduce `--force` and `--dry-run` flags for `create_cicap_full.sh`:
  - `--force`: overwrite existing scaffold (with a summary of changes).
  - `--dry-run`: print actions without writing.
- Detect existing files and only update when content differs (checksum/compare), not timestamps.
- Add `--keep-config` to preserve user-edited configs across re-runs.

## 4) Build-time sanity checks
- After compile, verify **expected modules** exist in `/work/out/usr/lib/c_icap`.
- Fail the build if any required `.so` is missing (list in a single source of truth).
- Verify `c-icap -V` and `c-icap-modules` version output (if available).

## 5) Runtime validation (smoke tests)
- Add a post-build target `tests/run_icap_tests.sh` to validate:
  - `echo`, `rewrite_demo`, `content_filter`, `virus_scan`, `url_check`.
- Provide `--skip-*` flags for services that require external dependencies.
- Capture the last ICAP response to `/tmp/icap-test-last-response.txt` for debugging.

## 6) Debug build mode
- Add a `DEBUG=1` build mode that:
  - Enables `set -x` in build scripts.
  - Keeps build directories (no cleanup).
  - Adds `c-icap` verbose logging flags.
  - Writes logs to `/work/logs/*` and copies them into `/var/log/c-icap`.

## 7) CI gate (quality bar)
- Add a CI workflow to run:
  - build + module presence checks
  - smoke ICAP OPTIONS tests
  - REQMOD/RESPMOD tests for `rewrite_demo`
- Fail CI if any upstream reference changes unexpectedly.

## 8) Documented upgrade workflow
- Add `docs/UPGRADE.md` with:
  - how to bump tags/commits safely
  - how to re‑run tests
  - how to validate module coverage

## 9) Supply‑chain hygiene
- Capture SBOM (CycloneDX) for the runtime image.
- Add reproducible base image tags (digest pinned).

## 10) Docker Hub release process (next step)
- Publish versioned tags (e.g., `v0.1.0`, `latest`) with release notes.
- Include a build provenance label with upstream SHAs.
- Document the image labels in README.

---

This plan is designed so **default builds are stable** and **updates are intentional**. If you want, I can implement items in priority order (1 → 5 first) and add CI once the repo is on GitHub.
