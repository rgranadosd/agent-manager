#!/usr/bin/env bash
set -euo pipefail

if [ -z "${APIM_HOME:-}" ]; then
  echo "Set APIM_HOME before running this script." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

mkdir -p "$ROOT_DIR/build-overlay/dropins" "$ROOT_DIR/build-overlay/lib"

find "$APIM_HOME/repository/components/dropins" -maxdepth 1 -type f -name '*.jar' -exec cp -f {} "$ROOT_DIR/build-overlay/dropins/" \;
find "$APIM_HOME/repository/components/lib" -maxdepth 1 -type f -name '*.jar' -exec cp -f {} "$ROOT_DIR/build-overlay/lib/" \;

echo "Copied JAR overlays into $ROOT_DIR/build-overlay"