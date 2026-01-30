#!/usr/bin/env bash
set -euo pipefail

HOST="localhost"
PORT="1344"
TIMEOUT="5"
STRICT="0"
RESP_FILE="/tmp/icap-test-last-response.txt"
MAX_LINES="200"

# Avoid SIGPIPE termination when limiting output with head.
trap '' PIPE

SKIP_ECHO="0"
SKIP_REWRITE="0"
SKIP_CONTENT="0"
SKIP_VIRUS="0"
SKIP_URL_CHECK="0"

usage() {
  cat <<'USAGE'
Usage: run_icap_tests.sh [options]

Options:
  --host HOST           ICAP host (default: localhost)
  --port PORT           ICAP port (default: 1344)
  --timeout SECONDS     nc timeout (default: 5)
  --strict              fail if expectations are not met
  --skip-echo           skip echo tests
  --skip-rewrite         skip rewrite_demo tests
  --skip-content-filter skip content_filter tests
  --skip-virus-scan      skip virus_scan tests
  --skip-url-check       skip url_check tests
  -h, --help            show help

Examples:
  ./tests/run_icap_tests.sh
  ./tests/run_icap_tests.sh --host 127.0.0.1 --port 1344 --strict
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --strict) STRICT="1"; shift 1;;
    --skip-echo) SKIP_ECHO="1"; shift 1;;
    --skip-rewrite) SKIP_REWRITE="1"; shift 1;;
    --skip-content-filter) SKIP_CONTENT="1"; shift 1;;
    --skip-virus-scan) SKIP_VIRUS="1"; shift 1;;
    --skip-url-check) SKIP_URL_CHECK="1"; shift 1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
 done

if ! command -v nc >/dev/null 2>&1; then
  echo "Missing nc (netcat). Install it and retry." >&2
  exit 1
fi

pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; exit 1; }
warn() { echo "[WARN] $*"; }

get_status_file() {
  if [ ! -s "$RESP_FILE" ]; then
    echo ""
    return
  fi
  awk 'NR==1{gsub(/\r/,""); print $2; exit}' "$RESP_FILE"
}

send_raw() {
  local payload="$1"
  # Use timeout to avoid hanging on keep-alive responses.
  set +e
  set +o pipefail
  printf "%b" "$payload" | timeout "${TIMEOUT}s" nc -w "$TIMEOUT" "$HOST" "$PORT" | head -n "$MAX_LINES" > "$RESP_FILE"
  set -o pipefail
  set -e
  return 0
}

options_test() {
  local svc="$1"
  local status
  send_raw "OPTIONS icap://${HOST}:${PORT}/${svc} ICAP/1.0\r\nHost: ${HOST}\r\nConnection: close\r\n\r\n"
  status="$(get_status_file)"
  if [ "$status" = "200" ]; then
    pass "OPTIONS ${svc} -> 200"
  else
    fail "OPTIONS ${svc} -> status ${status}"
  fi
}

reqmod_test() {
  local svc="$1"
  local http_req
  printf -v http_req "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\nUser-Agent: icap-test\r\n\r\n"
  local req_hdr_len=${#http_req}
  local icap
  printf -v icap "REQMOD icap://%s:%s/%s ICAP/1.0\r\nHost: %s\r\nConnection: close\r\nAllow: 204\r\nEncapsulated: req-hdr=0, null-body=%d\r\n\r\n%s" \
    "$HOST" "$PORT" "$svc" "$HOST" "$req_hdr_len" "$http_req"

  local status
  send_raw "$icap"
  status="$(get_status_file)"

  if [ "$status" = "200" ] || [ "$status" = "204" ]; then
    pass "REQMOD ${svc} -> ${status}"
  else
    fail "REQMOD ${svc} -> status ${status}"
  fi
}

respmod_test() {
  local svc="$1"
  local body="$2"
  local content_type="$3"

  local res_hdr
  local chunk_len
  chunk_len=$(printf "%x" "${#body}")
  printf -v res_hdr "HTTP/1.1 200 OK\r\nContent-Type: %s\r\nTransfer-Encoding: chunked\r\n\r\n" \
    "$content_type"
  local res_hdr_len=${#res_hdr}
  local icap
  printf -v icap "RESPMOD icap://%s:%s/%s ICAP/1.0\r\nHost: %s\r\nConnection: close\r\nAllow: 204\r\nEncapsulated: res-hdr=0, res-body=%d\r\n\r\n%s%s\r\n%s\r\n0\r\n\r\n" \
    "$HOST" "$PORT" "$svc" "$HOST" "$res_hdr_len" "$res_hdr" "$chunk_len" "$body"

  local status
  send_raw "$icap"
  status="$(get_status_file)"

  if [ "$status" = "200" ] || [ "$status" = "204" ] || [ "$status" = "403" ]; then
    pass "RESPMOD ${svc} -> ${status}"
  else
    fail "RESPMOD ${svc} -> status ${status}"
  fi

  if [ "$svc" = "rewrite_demo" ]; then
    if grep -a -q "X-ICAP-Rewritten: 1" "$RESP_FILE"; then
      pass "rewrite_demo header rewrite verified"
      if grep -a -q "REWRITTEN" "$RESP_FILE"; then
        pass "rewrite_demo body token present"
      else
        warn "rewrite_demo body token not detected (response truncated)"
      fi
    else
      if [ "$STRICT" = "1" ]; then
        fail "rewrite_demo did not set X-ICAP-Rewritten header"
      else
        warn "rewrite_demo header not detected (check $RESP_FILE)"
      fi
    fi
  fi

  if [ "$svc" = "virus_scan" ]; then
    if grep -a -E -q "Virus|EICAR|FOUND" "$RESP_FILE"; then
      pass "virus_scan detection marker present"
    else
      if [ "$STRICT" = "1" ]; then
        fail "virus_scan did not report detection markers"
      else
        warn "virus_scan markers not detected (check /tmp/icap-test-last-response.txt)"
      fi
    fi
  fi
}

if [ "$SKIP_ECHO" = "0" ]; then
  options_test "echo"
  reqmod_test "echo"
fi

if [ "$SKIP_REWRITE" = "0" ]; then
  options_test "rewrite_demo"
  respmod_test "rewrite_demo" "HELLO ORIGINAL WORLD" "text/plain"
fi

if [ "$SKIP_CONTENT" = "0" ]; then
  options_test "content_filter"
  respmod_test "content_filter" "SAMPLE CONTENT FOR FILTER" "text/plain"
fi

if [ "$SKIP_VIRUS" = "0" ]; then
  options_test "virus_scan"
  respmod_test "virus_scan" 'X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*' "application/octet-stream"
fi

if [ "$SKIP_URL_CHECK" = "0" ]; then
  options_test "url_check"
  reqmod_test "url_check"
fi

echo "All tests completed. Last response saved to $RESP_FILE"
