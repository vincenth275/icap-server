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
