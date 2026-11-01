#!/usr/bin/env bash
# Show what is up and what is loaded. Safe to run from any host.
#
#   ./scripts/status.sh
#
# Env: ROUTER, M4PRO_HOST, M2PRO_HOST (service roots, no path)
#      LITELLM_MASTER_KEY / ROUTER_KEY (read from config/router/router.env if present)
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "${LITELLM_MASTER_KEY:-}" ] && [ -f "$REPO_ROOT/config/router/router.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$REPO_ROOT/config/router/router.env"
  set +a
fi
KEY="${ROUTER_KEY:-${LITELLM_MASTER_KEY:-}}"

ROUTER="${ROUTER:-http://imac-thunder:4000}"
M4PRO_HOST="${M4PRO_HOST:-http://m4pro.local:8080}"
M2PRO_HOST="${M2PRO_HOST:-http://mini-thunder:8080}"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$1" 2>/dev/null || true; }
body() { curl -s --max-time 5 "$@" 2>/dev/null; }

# Tolerant of the three shapes we might get back: a bare list, {"data": [...]}
# (LiteLLM /v1/models) or {"running": [...]} (llama-swap). Entries may be plain
# id strings or objects carrying id/model.
ids() {
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("  (unparseable response)"); raise SystemExit
if isinstance(d, list):
    items = d
elif isinstance(d, dict):
    items = d.get("running") or d.get("data") or d.get("models") or []
else:
    items = []
out = []
for it in items:
    if isinstance(it, str):
        out.append(it)
    elif isinstance(it, dict):
        v = it.get("id") or it.get("model") or it.get("model_id")
        if v:
            out.append(str(v))
print("  " + (", ".join(out) if out else "(none)"))
'
}

echo "router   $ROUTER"
# /health/liveliness, not /health: the latter makes upstream model health checks
# and returns 500 without a DB configured. It would also cold-start models.
c="$(code "$ROUTER/health/liveliness")"; c="${c:-000}"
if [ "$c" = "200" ]; then
  echo "  health: up"
  if [ -n "$KEY" ]; then
    printf "  models:"
    body -H "Authorization: Bearer $KEY" "$ROUTER/v1/models" | ids
  else
    echo "  models: (no key; set LITELLM_MASTER_KEY or run from imac-thunder)"
  fi
else
  echo "  health: DOWN (http $c) — run scripts/start-router.sh on imac-thunder"
fi

for pair in "m4pro  $M4PRO_HOST" "m2pro  $M2PRO_HOST"; do
  name="${pair%% *}"
  url="${pair##* }"
  echo
  echo "$name $url"
  c="$(code "$url/health")"; c="${c:-000}"
  if [ "$c" = "200" ]; then
    printf "  loaded:"
    body "$url/running" | ids
  else
    echo "  DOWN (http $c)"
  fi
done

echo
echo "tip: a model shows as loaded only after its first request; idle hosts hold nothing."
