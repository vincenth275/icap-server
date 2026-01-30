# Next session prompt

We completed option 1 (automated ICAP tests) and now want to implement the hardening plan (option 2).
Please focus on making create_cicap_full.sh robust and idempotent: pin upstream tags+commits in upstream.env, verify SHAs, add --force/--dry-run/--keep-config flags, add deterministic fetch with clear errors, add build-time module presence checks, and implement a debug build mode (more logs, no cleanup).
Wire the automated tests into the scaffolded output, and update README/HARDENING_PLAN.md accordingly.
Keep container naming as icap-server.
Please propose and implement the first batch of changes (pinning + verification + idempotent flags + debug mode), then summarize.
