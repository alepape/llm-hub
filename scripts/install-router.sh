#!/usr/bin/env bash
# Install the LiteLLM proxy on the control plane (imac-thunder).
# Creates .venv/ in the repo root. Python >= 3.10 required.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PYTHON="${PYTHON:-python3}"

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "error: $PYTHON not found" >&2
  exit 1
fi

if ! "$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
  echo "error: Python >= 3.10 required, found $("$PYTHON" -V 2>&1)" >&2
  echo "hint: brew install python" >&2
  exit 1
fi

echo "==> creating venv with $("$PYTHON" -V 2>&1)"
"$PYTHON" -m venv "$REPO_ROOT/.venv"
"$REPO_ROOT/.venv/bin/pip" install --upgrade pip >/dev/null
"$REPO_ROOT/.venv/bin/pip" install "litellm[proxy]"

if [ ! -f "$REPO_ROOT/config/router/router.env" ]; then
  cp "$REPO_ROOT/config/router/router.env.example" "$REPO_ROOT/config/router/router.env"
  KEY="sk-$(openssl rand -hex 24)"
  # macOS sed -i needs an explicit backup suffix
  sed -i '' "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=$KEY|" "$REPO_ROOT/config/router/router.env"
  echo
  echo "==> created config/router/router.env from the example"
  echo "    client key: $KEY"
  echo "    edit M4PRO_BASE / M2PRO_BASE before starting the router"
fi

echo
echo "installed: $("$REPO_ROOT/.venv/bin/litellm" --version 2>/dev/null || echo 'litellm (venv)')"
echo "next: edit config/router/router.env, then ./scripts/start-router.sh"
