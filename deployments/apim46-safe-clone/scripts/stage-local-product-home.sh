#!/usr/bin/env bash
set -euo pipefail

if [ -z "${APIM_HOME:-}" ]; then
  echo "Set APIM_HOME before running this script." >&2
  exit 1
fi

if [ ! -d "$APIM_HOME" ]; then
  echo "APIM_HOME does not exist: $APIM_HOME" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST_DIR="$ROOT_DIR/staging/product-home/wso2am-4.6.0"

mkdir -p "$DEST_DIR"

rsync -a --delete \
  --exclude 'backup/' \
  --exclude 'repository/conf/deployment.toml' \
  --exclude 'repository/conf/deployment.toml.*' \
  --exclude 'repository/database/' \
  --exclude 'repository/logs/' \
  --exclude 'repository/resources/security/*.jks' \
  --exclude 'repository/resources/security/*.cer' \
  --exclude 'repository/resources/security/tokenstore' \
  --exclude 'repository/components/default/configuration/org.eclipse.osgi/' \
  --exclude 'repository/components/default/configuration/*.log' \
  --exclude 'repository/components/dropins/*.bak' \
  --exclude 'diagnostics-tool/' \
  --exclude 'tmp/' \
  --exclude 'wso2carbon.pid' \
  "$APIM_HOME/" "$DEST_DIR/"

# Ensure logs dir exists (needed by JVM for patches.log.lck at startup)
mkdir -p "$DEST_DIR/repository/logs"

echo "Staged sanitized product home at $DEST_DIR"