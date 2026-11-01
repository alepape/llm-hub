#!/usr/bin/env bash
# Start llama-swap for a host role.
#
#   ./scripts/start-models.sh m2pro      # mini-thunder
#   ./scripts/start-models.sh m4pro      # laptop
#
# Env:
#   LISTEN            default 0.0.0.0:8080
#   LLAMA_SERVER_BIN  default $HOME/DEV/gits/llama.cpp/build/bin/llama-server
#   LLAMA_CACHE       m2pro: /Volumes/Fast Data/LLM/llama.cpp
#                     m4pro: llama.cpp's platform default
#   MODEL_ENV         optional host-local env file (default config/llama-swap/<role>.env)
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

ENV_FILE="${MODEL_ENV:-$REPO_ROOT/config/llama-swap/$ROLE.env}"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

if [ "$ROLE" = "m2pro" ]; then
  : "${LLAMA_CACHE:=/Volumes/Fast Data/LLM/llama.cpp}"
fi

if [ -n "${LLAMA_CACHE:-}" ]; then
  # Never create /Volumes/<missing drive> on the system disk. A directory
  # existing alone is insufficient: require an actual mounted filesystem.
  case "$LLAMA_CACHE" in
    /Volumes/*/*)
      volume="${LLAMA_CACHE#/Volumes/}"
      volume="/Volumes/${volume%%/*}"
      if ! /sbin/mount | grep -Fq " on $volume ("; then
        echo "error: model volume is not mounted: $volume" >&2
        exit 1
      fi
      ;;
  esac
  mkdir -p "$LLAMA_CACHE"
  if [ ! -w "$LLAMA_CACHE" ]; then
    echo "error: model cache is not writable: $LLAMA_CACHE" >&2
    exit 1
  fi
  export LLAMA_CACHE
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
echo "cache:  ${LLAMA_CACHE:-llama.cpp platform default}"
echo "listen: ${LISTEN:-0.0.0.0:8080}"
echo

exec llama-swap --config "$CONFIG" --listen "${LISTEN:-0.0.0.0:8080}"
