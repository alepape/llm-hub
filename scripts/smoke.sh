#!/usr/bin/env bash
# End-to-end check through the router. Generates real load, may cold-start a
# model (and download it on first ever run).
#
#   ./scripts/smoke.sh            # model: auto
#   ./scripts/smoke.sh big        # force the laptop
#   ./scripts/smoke.sh small      # force the mini
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "${LITELLM_MASTER_KEY:-}" ] && [ -f "$REPO_ROOT/config/router/router.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$REPO_ROOT/config/router/router.env"
  set +a
fi
KEY="${ROUTER_KEY:-${LITELLM_MASTER_KEY:-}}"

if [ -z "$KEY" ]; then
  echo "error: no client key. Set LITELLM_MASTER_KEY or run from imac-thunder." >&2
  exit 1
fi

ROUTER="${ROUTER:-http://imac-thunder:4000}"
MODEL="${1:-auto}"
PROMPT="${PROMPT:-Reply with exactly: ok}"

echo "POST $ROUTER/v1/chat/completions  model=$MODEL"
echo

start=$(date +%s)

resp="$(curl -sS --max-time 900 -X POST "$ROUTER/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $KEY" \
  -d "$(printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":32,"stream":false}' "$MODEL" "$PROMPT")")"

end=$(date +%s)

echo "$resp" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("non-JSON response:"); print(raw[:2000]); raise SystemExit(1)
if "error" in d:
    print("ERROR:", json.dumps(d["error"], indent=2)); raise SystemExit(1)
try:
    print("reply:", d["choices"][0]["message"]["content"].strip())
except Exception:
    print(json.dumps(d, indent=2)[:2000])
'

echo
echo "elapsed: $((end - start))s  (a cold start is expected to be slow)"
