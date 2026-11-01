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

payload="$(python3 -c '
import json, sys
print(json.dumps({
    "model": sys.argv[1],
    "messages": [{"role": "user", "content": sys.argv[2]}],
    "max_tokens": 256,
    "stream": False,
    "chat_template_kwargs": {"enable_thinking": False},
}))
' "$MODEL" "$PROMPT")"

resp="$(curl -sS --max-time 900 -X POST "$ROUTER/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $KEY" \
  -d "$payload")"

end=$(date +%s)

echo "elapsed: $((end - start))s  (cold starts include downloading/loading)"
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
    choice = d["choices"][0]
    msg = choice["message"]
except (KeyError, IndexError, TypeError):
    print("Unexpected response:", json.dumps(d, indent=2)[:2000])
    raise SystemExit(1)
print("model:", d.get("model", "(not reported)"))
print("finish_reason:", choice.get("finish_reason"))
print("usage:", json.dumps(d.get("usage", {})))
extra = msg.get("provider_specific_fields") or {}
reasoning = msg.get("reasoning_content") or msg.get("reasoning") or extra.get("reasoning_content")
if reasoning:
    print("reasoning:", str(reasoning)[:2000])
content = msg.get("content")
if not isinstance(content, str) or not content.strip():
    print("FAIL: no visible reply (possibly reasoning exhausted the token budget).")
    raise SystemExit(1)
print("reply:", content.strip())
'
