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
