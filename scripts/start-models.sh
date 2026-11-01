#!/usr/bin/env bash
# Start llama-swap for a host role.
#
#   ./scripts/start-models.sh m2pro      # mini-thunder
#   ./scripts/start-models.sh m4pro      # laptop
#
# Env:
#   LISTEN            default 0.0.0.0:8080
#   LLAMA_SERVER_BIN  default $HOME/DEV/gits/llama.cpp/build/bin/llama-server
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLE="${1:-}"

if [ -z "$ROLE" ]; then
  echo "usage: $0 <m2pro|m4pro>" >&2
  echo "available: $(cd "$REPO_ROOT/config/llama-swap" && ls -1 *.yaml | sed 's/\.yaml$//' | tr '\n' ' ')" >&2
  exit 2
fi

CONFIG="$REPO_ROOT/config/llama-swap/$ROLE.yaml"
if [ ! -f "$CONFIG" ]; then
  echo "error: no config for role '$ROLE' ($CONFIG)" >&2
  exit 1
fi

if ! command -v llama-swap >/dev/null 2>&1; then
  echo "error: llama-swap not installed; run ./scripts/install-llama-swap.sh" >&2
  exit 1
fi

: "${LLAMA_SERVER_BIN:=$HOME/DEV/gits/llama.cpp/build/bin/llama-server}"
export LLAMA_SERVER_BIN

if [ ! -x "$LLAMA_SERVER_BIN" ]; then
  echo "warning: LLAMA_SERVER_BIN is not executable: $LLAMA_SERVER_BIN" >&2
  echo "         set LLAMA_SERVER_BIN, e.g. LLAMA_SERVER_BIN=\$(command -v llama-server)" >&2
fi

echo "role:   $ROLE"
echo "config: $CONFIG"
echo "llama:  $LLAMA_SERVER_BIN"
echo "listen: ${LISTEN:-0.0.0.0:8080}"
echo

exec llama-swap --config "$CONFIG" --listen "${LISTEN:-0.0.0.0:8080}"
