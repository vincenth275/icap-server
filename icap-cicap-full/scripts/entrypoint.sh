#!/usr/bin/env bash
set -euo pipefail

echo "[entrypoint] Starting clamd (best effort)..."
( clamdbin=$(command -v clamd || true) && \
  if [[ -n "$clamdbin" ]]; then
    "$clamdbin" --foreground=true --config-file=/etc/clamav/clamd.conf >/tmp/clamd.log 2>&1 || true
  fi ) &

echo "[entrypoint] Starting rsyslog (best effort)..."
( rsyslogd_bin=$(command -v rsyslogd || true) && \
  if [[ -n "$rsyslogd_bin" ]]; then
    "$rsyslogd_bin" -n >/tmp/rsyslog.log 2>&1 || true
  fi ) &

echo "[entrypoint] Starting c-icap..."
cicap_bin="$(command -v c-icap 2>/dev/null || true)"
if [[ -z "$cicap_bin" ]]; then
  for p in /usr/sbin/c-icap /usr/bin/c-icap /usr/local/sbin/c-icap /usr/local/bin/c-icap; do
    if [[ -x "$p" ]]; then cicap_bin="$p"; break; fi
  done
fi

if [[ -z "$cicap_bin" ]]; then
  echo "[entrypoint] ERROR: c-icap binary not found."
  echo "[entrypoint] Listing common locations:"
  ls -la /usr/sbin /usr/bin /usr/local/sbin /usr/local/bin 2>/dev/null || true
  echo "[entrypoint] Searching filesystem for c-icap (maxdepth 4)..."
  find / -maxdepth 4 -type f -name 'c-icap' -print 2>/dev/null || true
  exit 127
fi

if [[ "${CICAP_DEBUG:-0}" == "1" ]]; then
  exec su -s /bin/sh -c "$cicap_bin -f /etc/c-icap/c-icap.conf -N -D -d 10" icap
else
  exec su -s /bin/sh -c "$cicap_bin -f /etc/c-icap/c-icap.conf -N" icap
fi
