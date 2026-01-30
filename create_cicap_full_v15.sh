#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# create_cicap_full.sh
# Scaffold: official c-icap-server + official c-icap-modules + custom rewrite service
#
# Goal: a generic ICAP server demo that works with *any* load balancer / reverse proxy
# supporting ICAP (REQMOD/RESPMOD).
#
# Usage:
#   ./create_cicap_full.sh icap-cicap-full
# ------------------------------------------------------------------------------

PROJECT_NAME="${1:-${PROJECT_NAME:-icap-cicap-full}}"
ROOT_DIR="${ROOT_DIR:-$PWD/$PROJECT_NAME}"

if [[ "$ROOT_DIR" == "/" || -z "$ROOT_DIR" ]]; then
  echo "Refusing ROOT_DIR='${ROOT_DIR}'"
  exit 1
fi

echo "Creating project at: ${ROOT_DIR}"
mkdir -p "$ROOT_DIR"

write_if_missing() {
  local f="$1"; shift
  if [[ ! -f "$f" ]]; then
    mkdir -p "$(dirname "$f")"
    cat > "$f" <<'EOF'
$*
EOF
  fi
}

append_if_missing() {
  local f="$1" needle="$2" content="$3"
  mkdir -p "$(dirname "$f")"
  touch "$f"
  if ! grep -qF "$needle" "$f"; then
    printf "\n%s\n" "$content" >> "$f"
  fi
}

chmodx() { chmod +x "$1" 2>/dev/null || true; }

# ------------------------------------------------------------------------------
# Tree
# ------------------------------------------------------------------------------
mkdir -p \
  "$ROOT_DIR/src" \
  "$ROOT_DIR/config" \
  "$ROOT_DIR/docker" \
  "$ROOT_DIR/scripts" \
  "$ROOT_DIR/custom_services/srv_rewrite_demo" \
  "$ROOT_DIR/docs"

# ------------------------------------------------------------------------------
# Upstream config (official repos)
# ------------------------------------------------------------------------------
cat > "$ROOT_DIR/config/upstream.env" <<'EOF'
CICAP_SERVER_URL="https://github.com/c-icap/c-icap-server"
CICAP_SERVER_REF="master"

CICAP_MODULES_URL="https://github.com/c-icap/c-icap-modules"
CICAP_MODULES_REF="master"

PREFIX="/usr"
SYSCONFDIR="/etc"
LOCALSTATEDIR="/var"

SERVER_EXTRA_CONFIGURE_FLAGS=""
MODULES_EXTRA_CONFIGURE_FLAGS=""
EOF

cat > "$ROOT_DIR/.gitignore" <<'EOF'
src/c-icap-server/
src/c-icap-modules/
out/
build/
.env
.env.*
!.env.example
EOF

cat > "$ROOT_DIR/.env.example" <<'EOF'
CICAP_SERVER_REF=master
CICAP_MODULES_REF=master
ICAP_LISTEN_ADDR=0.0.0.0
ICAP_LISTEN_PORT=1344
CLAMD_HOST=127.0.0.1
CLAMD_PORT=3310
EOF

# ------------------------------------------------------------------------------
# c-icap main conf
# ------------------------------------------------------------------------------
cat > "$ROOT_DIR/config/c-icap.conf" <<'EOF'
# Minimal c-icap config for containers

Port 0.0.0.0:1344
PidFile /var/run/c-icap/c-icap.pid

StartServers 2
MaxServers 10
ThreadsPerChild 10

ModulesDir /usr/lib/c_icap
ServicesDir /usr/lib/c_icap

# Always-on demo service
Include /etc/c-icap/srv_rewrite_demo.conf

# Optional AV (enable only if module names exist in /usr/lib/c_icap)
# Include /etc/c-icap/virus_scan.conf
# Include /etc/c-icap/clamd_mod.conf
EOF

cat > "$ROOT_DIR/config/virus_scan.conf" <<'EOF'
# Enable virus_scan service (c-icap-modules)
# Service name / .so can differ by version; we keep the common one.
Service virus_scan srv_virus_scan.so
EOF

cat > "$ROOT_DIR/config/clamd_mod.conf" <<'EOF'
# clamd_mod: addon for virus_scan to use clamd daemon (ClamAV)
clamd_mod.ClamdHost 127.0.0.1
clamd_mod.ClamdPort 3310
EOF

cat > "$ROOT_DIR/config/srv_rewrite_demo.conf" <<'EOF'
# Custom service: rewrite headers + body (demo)
Service rewrite_demo srv_rewrite_demo.so
EOF

# ------------------------------------------------------------------------------
# Custom service: srv_rewrite_demo
# - Adds header: X-ICAP-Rewritten: 1
# - If Content-Type is text/*, replaces token ORIGINAL -> REWRITTEN in the response body stream
#
# NOTE: Written against the public c-icap service API (ci_service_module_t) as seen in srv_echo.c
# from c-icap 0.5.x (Debian bookworm uses 0.5.10). This avoids mismatches across versions.
# ------------------------------------------------------------------------------
cat > "$ROOT_DIR/custom_services/srv_rewrite_demo/srv_rewrite_demo.c" <<'EOF'
/*
 * srv_rewrite_demo - minimal c-icap service to demonstrate header + body rewrite.
 *
 * Behavior:
 *  - Always adds a response header: X-ICAP-Rewritten: 1
 *  - If Content-Type starts with text/, replace ASCII token ORIGINAL with REWRITTEN
 *    in the payload stream (same length replacement).
 *
 * Deterministic, intentionally tiny.
 */
#include <stdlib.h>
#include <string.h>

#include <c_icap/c-icap.h>
#include <c_icap/service.h>
#include <c_icap/header.h>
#include <c_icap/body.h>
#include <c_icap/simple_api.h>

struct rewrite_req_data {
    int is_text;
};

static int  rewrite_init_service(ci_service_xdata_t *srv_xdata, struct ci_server_conf *server_conf);
static void rewrite_close_service(void);
static void *rewrite_init_request_data(ci_request_t *req);
static void rewrite_release_request_data(void *data);
static int  rewrite_check_preview_handler(char *preview_data, int preview_data_len, ci_request_t *req);
static int  rewrite_end_of_data_handler(ci_request_t *req);
static int  rewrite_io(char *wbuf, int *wlen, char *rbuf, int *rlen, int iseof, ci_request_t *req);

CI_DECLARE_MOD_DATA ci_service_module_t service = {
    "rewrite_demo",
    "Rewrite demo service (header + body token rewrite)",
    ICAP_RESPMOD | ICAP_REQMOD,
    rewrite_init_service,
    NULL,
    rewrite_close_service,
    rewrite_init_request_data,
    rewrite_release_request_data,
    rewrite_check_preview_handler,
    rewrite_end_of_data_handler,
    rewrite_io,
    NULL,
    NULL
};

static int starts_with_ci(const char *s, const char *p) {
    if (!s || !p) return 0;
    return strncasecmp(s, p, strlen(p)) == 0;
}

static void add_demo_header(ci_request_t *req) {
    ci_headers_list_t *hdrs = ci_http_response_headers(req);
    if (!hdrs) return;
    ci_headers_add(hdrs, "X-ICAP-Rewritten: 1");
}

static int is_textual(ci_request_t *req) {
    const char *ct = ci_http_response_get_header(req, "Content-Type");
    if (!ct) return 0;
    return starts_with_ci(ct, "text/");
}

static void replace_token_inplace(char *buf, int len) {
    const char *from = "ORIGINAL";
    const char *to   = "REWRITTEN";
    const int from_len = (int)strlen(from);
    const int to_len   = (int)strlen(to);
    if (from_len != to_len) return; // keep it simple: same length required

    for (int i = 0; i <= len - from_len; i++) {
        if (memcmp(buf + i, from, (size_t)from_len) == 0) {
            memcpy(buf + i, to, (size_t)to_len);
            i += from_len - 1;
        }
    }
}

/* Called when service is loaded */
static int rewrite_init_service(ci_service_xdata_t *srv_xdata, struct ci_server_conf *server_conf) {
    (void)server_conf;
    /* Ask clients to send preview data; 1024 is a sensible demo value */
    ci_service_set_preview(srv_xdata, 1024);
    /* Allow 204 responses (no modification) */
    ci_service_enable_204(srv_xdata);
    /* Request preview for all content-types */
    ci_service_set_transfer_preview(srv_xdata, "*");
    return CI_OK;
}

/* Called when service shuts down */
static void rewrite_close_service(void) {
    /* nothing */
}

/* Per-request init: allocate ctx, decide if text, add header once */
static void *rewrite_init_request_data(ci_request_t *req) {
    struct rewrite_req_data *d = (struct rewrite_req_data*)calloc(1, sizeof(*d));
    if (!d) return NULL;

    d->is_text = is_textual(req);
    add_demo_header(req);
    return d;
}

static void rewrite_release_request_data(void *data) {
    free(data);
}

static int rewrite_check_preview_handler(char *preview_data, int preview_data_len, ci_request_t *req) {
    (void)preview_data; (void)preview_data_len; (void)req;
    return CI_MOD_CONTINUE;
}

static int rewrite_end_of_data_handler(ci_request_t *req) {
    (void)req;
    return CI_OK;
}

/* Streaming I/O:
 *  - rbuf/rlen: bytes from origin (encapsulated HTTP)
 *  - wbuf/wlen: bytes to client
 *
 * We only do in-place rewrite of rbuf for text/*.
 */
static int rewrite_io(char *wbuf, int *wlen, char *rbuf, int *rlen, int iseof, ci_request_t *req) {
    (void)wbuf; (void)wlen; (void)iseof;
    struct rewrite_req_data *d = (struct rewrite_req_data*)ci_service_data(req);
    if (!d || !d->is_text) return CI_MOD_CONTINUE;

    if (rbuf && rlen && *rlen > 0) {
        replace_token_inplace(rbuf, *rlen);
    }
    return CI_MOD_CONTINUE;
}
EOF

cat > "$ROOT_DIR/custom_services/srv_rewrite_demo/Makefile" <<'EOF'
CC ?= gcc
CFLAGS ?= -O2 -fPIC -Wall -Wextra
LDFLAGS ?= -shared

# c-icap installs public headers under /usr/include/c_icap
INCLUDES ?= -I/usr/include

OUT ?= srv_rewrite_demo.so

all: $(OUT)

$(OUT): srv_rewrite_demo.c
	$(CC) $(CFLAGS) $(INCLUDES) -o $(OUT) srv_rewrite_demo.c $(LDFLAGS)

clean:
	rm -f $(OUT)
EOF

# ------------------------------------------------------------------------------
# Dockerfile: build server + modules + custom service, runtime runs c-icap + clamd
# ------------------------------------------------------------------------------
cat > "$ROOT_DIR/docker/Dockerfile" <<'EOF'
FROM debian:bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git \
    build-essential pkg-config \
    autoconf automake libtool \
    flex bison \
    libpcre2-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY config/upstream.env /work/upstream.env
COPY scripts /work/scripts
RUN chmod +x /work/scripts/*.sh

RUN /work/scripts/fetch_two_repos.sh /work/upstream.env /work/src

RUN /work/scripts/build_server.sh  /work/upstream.env /work/src/c-icap-server  /work/out
RUN /work/scripts/build_modules.sh /work/upstream.env /work/src/c-icap-modules /work/out

# Build custom service against installed headers in the build image
COPY custom_services/srv_rewrite_demo /work/custom_services/srv_rewrite_demo
RUN make -C /work/custom_services/srv_rewrite_demo \
  && install -D -m 0755 /work/custom_services/srv_rewrite_demo/srv_rewrite_demo.so /work/out/usr/lib/c_icap/srv_rewrite_demo.so

# Avoid conflicts when copying into Debian runtime where /var/run is a symlink to /run.
# The runtime stage creates needed run dirs explicitly.
RUN rm -rf /work/out/var/run || true

# --- runtime ---
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libpcre2-8-0 \
    libatomic1 \
    clamav clamav-daemon \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -r -u 10001 -g nogroup -m -d /home/icap icap
RUN mkdir -p /var/run/c-icap /var/log/c-icap /run/clamav \
 && chown -R icap:nogroup /var/run/c-icap /var/log/c-icap /run/clamav

COPY --from=builder /work/out/ /
RUN mkdir -p /etc/c-icap
COPY config/c-icap.conf /etc/c-icap/c-icap.conf
COPY config/virus_scan.conf /etc/c-icap/virus_scan.conf
COPY config/clamd_mod.conf /etc/c-icap/clamd_mod.conf
COPY config/srv_rewrite_demo.conf /etc/c-icap/srv_rewrite_demo.conf

EXPOSE 1344

COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER icap
ENTRYPOINT ["/entrypoint.sh"]
EOF

# ------------------------------------------------------------------------------
# scripts
# ------------------------------------------------------------------------------
cat > "$ROOT_DIR/scripts/fetch_two_repos.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ENV_FILE="${1:?env_file_path}"
DEST_ROOT="${2:?dest_root}"

# shellcheck disable=SC1090
source "$ENV_FILE"

clone_or_update() {
  local url="$1" ref="$2" dir="$3"
  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" fetch --all --tags
    git -C "$dir" checkout "$ref"
    git -C "$dir" pull --ff-only || true
  else
    git clone --depth 1 --branch "$ref" "$url" "$dir" || {
      git clone "$url" "$dir"
      git -C "$dir" checkout "$ref"
    }
  fi
}

mkdir -p "$DEST_ROOT"
clone_or_update "$CICAP_SERVER_URL"  "${CICAP_SERVER_REF:-master}"  "$DEST_ROOT/c-icap-server"
clone_or_update "$CICAP_MODULES_URL" "${CICAP_MODULES_REF:-master}" "$DEST_ROOT/c-icap-modules"
echo "✅ Sources ready"
EOF

cat > "$ROOT_DIR/scripts/build_server.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ENV_FILE="${1:?env_file_path}"
SRC_DIR="${2:?src}"
OUT_DIR="${3:?out}"

# shellcheck disable=SC1090
source "$ENV_FILE"

PREFIX="${PREFIX:-/usr}"
SYSCONFDIR="${SYSCONFDIR:-/etc}"
LOCALSTATEDIR="${LOCALSTATEDIR:-/var}"

mkdir -p "$OUT_DIR"
cd "$SRC_DIR"

# Some git checkouts do not ship VERSION.m4 (required by configure.ac).
# Generate it if missing.
if [[ ! -f VERSION.m4 ]]; then
  ver="$(git describe --tags --always 2>/dev/null | sed 's/^v//')"
  [[ -n "$ver" ]] || ver="0.0.0"
  printf "%s\n" "$ver" > VERSION.m4
fi


# The upstream repo has a generated ./configure. Using autoreconf sometimes fails
# depending on the ref, so we prefer ./configure when present.
if [[ -x ./configure ]]; then
  :
else
  if [[ -x ./RECONF ]]; then
    ./RECONF
  else
    autoreconf -fi
  fi
fi

./configure --prefix="$PREFIX" --sysconfdir="$SYSCONFDIR" --localstatedir="$LOCALSTATEDIR" ${SERVER_EXTRA_CONFIGURE_FLAGS:-}
make -j"$(nproc)"

# Install into the builder image so headers (and c-icap-config) are available for c-icap-modules.
make install
hash -r

# Stage files for the runtime image
make DESTDIR="$OUT_DIR" install

# Make c-icap-config visible during the same Docker build stage (needed by c-icap-modules)
if [[ -x "$OUT_DIR$PREFIX/bin/c-icap-config" ]]; then
  install -D -m 0755 "$OUT_DIR$PREFIX/bin/c-icap-config" /usr/local/bin/c-icap-config
elif [[ -x "$OUT_DIR$PREFIX/sbin/c-icap-config" ]]; then
  install -D -m 0755 "$OUT_DIR$PREFIX/sbin/c-icap-config" /usr/local/bin/c-icap-config
fi

command -v c-icap-config >/dev/null 2>&1 || {
  echo "ERROR: c-icap-config not found after install."
  echo "Searched PATH: $PATH"
  echo "Staged tree: $OUT_DIR"
  find "$OUT_DIR" -maxdepth 4 -name 'c-icap-config' -print || true
  exit 255
}

echo "✅ c-icap-server staged"
EOF

cat > "$ROOT_DIR/scripts/build_modules.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ENV_FILE="${1:?env_file_path}"
SRC_DIR="${2:?src}"
OUT_DIR="${3:?out}"

# shellcheck disable=SC1090
source "$ENV_FILE"

PREFIX="${PREFIX:-/usr}"
SYSCONFDIR="${SYSCONFDIR:-/etc}"
LOCALSTATEDIR="${LOCALSTATEDIR:-/var}"

mkdir -p "$OUT_DIR"
cd "$SRC_DIR"

# Some git checkouts do not ship VERSION.m4 (required by configure.ac).
# Generate it if missing.
if [[ ! -f VERSION.m4 ]]; then
  ver="$(git describe --tags --always 2>/dev/null | sed 's/^v//')"
  [[ -n "$ver" ]] || ver="0.0.0"
  printf "%s\n" "$ver" > VERSION.m4
fi


# Ensure c-icap-config is available (created by build_server.sh)
command -v c-icap-config >/dev/null 2>&1 || {
  echo "ERROR: c-icap-config not found! (required by c-icap-modules configure)"
  echo "PATH=$PATH"
  exit 255
}

if [[ -x ./configure ]]; then
  :
else
  autoreconf -fi
fi

./configure --prefix="$PREFIX" --sysconfdir="$SYSCONFDIR" --localstatedir="$LOCALSTATEDIR" ${MODULES_EXTRA_CONFIGURE_FLAGS:-}
make -j"$(nproc)"
make DESTDIR="$OUT_DIR" install

echo "✅ c-icap-modules staged"
EOF

cat > "$ROOT_DIR/scripts/entrypoint.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "[entrypoint] Starting clamd (best effort)..."
( clamdbin=$(command -v clamd || true) && \
  if [[ -n "$clamdbin" ]]; then
    "$clamdbin" --foreground=true --config-file=/etc/clamav/clamd.conf >/tmp/clamd.log 2>&1 || true
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

exec "$cicap_bin" -f /etc/c-icap/c-icap.conf -N
EOF

chmodx "$ROOT_DIR/scripts/entrypoint.sh"
chmodx "$ROOT_DIR/scripts/fetch_two_repos.sh"
chmodx "$ROOT_DIR/scripts/build_server.sh"
chmodx "$ROOT_DIR/scripts/build_modules.sh"

# ------------------------------------------------------------------------------
# README
# ------------------------------------------------------------------------------
cat > "$ROOT_DIR/README.md" <<EOF
# ${PROJECT_NAME}

This project builds a container image with:

- **c-icap-server** (official upstream)
- **c-icap-modules** (official upstream), including **virus_scan**
- a small custom ICAP service: **rewrite_demo**
  - injects header: \`X-ICAP-Rewritten: 1\`
  - for \`Content-Type: text/*\`, rewrites \`ORIGINAL\` -> \`REWRITTEN\` in the response body stream

## Build
\`\`\`bash
docker build -t cicap:dev -f docker/Dockerfile .
\`\`\`

## Run
\`\`\`bash
docker run --rm -p 1344:1344 cicap:dev
\`\`\`

## Notes
- The rewrite service is deterministic and meant for demos/tests.
- Antivirus scanning depends on **clamd** being operational inside the container.
EOF

echo
echo "✅ Done."
echo "Next:"
echo "  cd \"$ROOT_DIR\""
echo "  docker build -t cicap:dev -f docker/Dockerfile ."
echo "  docker run --rm -p 1344:1344 cicap:dev"
