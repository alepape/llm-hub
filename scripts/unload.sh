#!/usr/bin/env bash
# Unload every model on a host, freeing memory now.
#
#   ./scripts/unload.sh m4pro
#   ./scripts/unload.sh m2pro
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

case "${1:-}" in
  m4pro) URL="${M4PRO_HOST:-http://m4pro.local:8080}" ;;
  m2pro) URL="${M2PRO_HOST:-http://mini-thunder:8080}" ;;
  *) echo "usage: $0 <m2pro|m4pro>" >&2; exit 2 ;;
esac

echo "unloading models on $URL"
curl -sS --max-time 60 -X POST "$URL/api/models/unload" || true
echo
curl -s --max-time 5 "$URL/running" || true
echo
