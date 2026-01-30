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
