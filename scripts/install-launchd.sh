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

service_loaded() {
  launchctl print "gui/$UID/$label" >/dev/null 2>&1
}

# bootout returns before launchd has actually removed the job, and bootstrapping
# a job that is still loaded fails with the unhelpful "Bootstrap failed: 5:
# Input/output error". Wait for it to disappear, then retry the bootstrap.
if service_loaded; then
  launchctl bootout "gui/$UID/$label" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    service_loaded || break
    sleep 0.5
  done
fi

bootstrap_error=""
for _ in 1 2 3 4 5; do
  service_loaded && break
  if bootstrap_error="$(launchctl bootstrap "gui/$UID" "$dest" 2>&1)"; then
    break
  fi
  sleep 1
done

if ! service_loaded; then
  echo "error: could not load $label" >&2
  [ -n "$bootstrap_error" ] && printf '%s\n' "$bootstrap_error" >&2
  echo "the plist was written to $dest; fix the error above and re-run" >&2
  echo "to load it by hand: launchctl bootstrap gui/$UID \"$dest\"" >&2
  exit 1
fi

launchctl enable "gui/$UID/$label" 2>/dev/null || true

echo "installed and bootstrapped: $dest"
echo "logs:     $HOME/Library/Logs/llm-hub-$label.log"
echo "stop:     launchctl bootout gui/$UID/$label"
echo "restart:  launchctl kickstart -k gui/$UID/$label"
