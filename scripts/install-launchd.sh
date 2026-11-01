#!/usr/bin/env bash
# Install a launchd agent so the service survives logout/reboot.
#
#   ./scripts/install-launchd.sh router          # on imac-thunder
#   ./scripts/install-launchd.sh models m2pro    # on mini-thunder
#   ./scripts/install-launchd.sh models m4pro    # on the laptop (optional)
#
# Logs: ~/Library/Logs/llm-hub-<label>.log
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND="${1:-}"
ROLE="${2:-}"

render() {
  local template="$1" label="$2" out="$3"
  shift 3
  local content
  content="$(cat "$template")"
  content="${content//__REPO__/$REPO_ROOT}"
  content="${content//__HOME__/$HOME}"
  content="${content//__LABEL__/$label}"
  content="${content//__LOG__/$HOME/Library/Logs/llm-hub-$label.log}"
  content="${content//__ROLE__/$ROLE}"
  printf '%s\n' "$content" > "$out"
}

case "$KIND" in
  router)
    label="com.alepape.llmhub.router"
    template="$REPO_ROOT/launchd/router.plist.template"
    ;;
  models)
    if [ -z "$ROLE" ]; then
      echo "usage: $0 models <m2pro|m4pro>" >&2; exit 2
    fi
    if [ ! -f "$REPO_ROOT/config/llama-swap/$ROLE.yaml" ]; then
      echo "error: no llama-swap config for role '$ROLE'" >&2; exit 1
    fi
    label="com.alepape.llmhub.llama-swap"
    template="$REPO_ROOT/launchd/llama-swap.plist.template"
    ;;
  *)
    echo "usage: $0 router | models <m2pro|m4pro>" >&2
    exit 2
    ;;
esac

dest="$HOME/Library/LaunchAgents/$label.plist"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
render "$template" "$label" "$dest"

plutil -lint "$dest" >/dev/null

launchctl bootout "gui/$UID/$label" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$dest"
launchctl enable "gui/$UID/$label" 2>/dev/null || true

echo "installed and bootstrapped: $dest"
echo "logs:     $HOME/Library/Logs/llm-hub-$label.log"
echo "stop:     launchctl bootout gui/$UID/$label"
echo "restart:  launchctl kickstart -k gui/$UID/$label"
