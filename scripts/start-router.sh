#!/usr/bin/env bash
# Start the LiteLLM router (control plane). Foreground; Ctrl-C to stop.
#
# Env (usually via config/router/router.env):
#   M4PRO_BASE, M2PRO_BASE, LOCAL_KEY, ROUTER_PORT
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROUTER_ENV:-$REPO_ROOT/config/router/router.env}"

if [ ! -x "$REPO_ROOT/.venv/bin/litellm" ]; then
  echo "error: .venv/bin/litellm missing; run ./scripts/install-router.sh" >&2
  exit 1
fi

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
else
  echo "warning: $ENV_FILE not found, using defaults" >&2
fi

: "${M4PRO_BASE:=http://FM7XXRXT4V.local:8080/v1}"
: "${M2PRO_BASE:=http://mini-thunder:8080/v1}"
: "${LOCAL_KEY:=sk-local}"
export M4PRO_BASE M2PRO_BASE LOCAL_KEY

# Make the callback importable regardless of cwd (including launchd).
export PYTHONPATH="$REPO_ROOT/config/router${PYTHONPATH:+:$PYTHONPATH}"

if [ -z "${LITELLM_MASTER_KEY:-}" ]; then
  echo "error: LITELLM_MASTER_KEY is not set." >&2
  echo "       LiteLLM refuses to start without it; see $ENV_FILE" >&2
  exit 1
fi
export LITELLM_MASTER_KEY

echo "big   -> $M4PRO_BASE"
echo "small -> $M2PRO_BASE"
echo "listen: 0.0.0.0:${ROUTER_PORT:-4000}"
echo "client key: ${LITELLM_MASTER_KEY:0:8}..."
echo "connect timeout: ${HUB_CONNECT_TIMEOUT:-3}s (read budgets unchanged)"
echo

exec "$REPO_ROOT/.venv/bin/litellm" \
  --config "$REPO_ROOT/config/router/config.yaml" \
  --host "${ROUTER_HOST:-0.0.0.0}" \
  --port "${ROUTER_PORT:-4000}"
