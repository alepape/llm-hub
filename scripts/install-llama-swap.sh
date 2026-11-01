#!/usr/bin/env bash
# Install llama-swap on a macOS model host (mini-thunder or m4pro).
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if ! command -v brew >/dev/null 2>&1; then
  echo "error: Homebrew not found in PATH" >&2
  exit 1
fi

if command -v llama-swap >/dev/null 2>&1; then
  echo "llama-swap already installed: $(command -v llama-swap)"
  llama-swap -version 2>/dev/null || true
  exit 0
fi

brew tap mostlygeek/llama-swap
brew install llama-swap

echo
echo "installed: $(command -v llama-swap)"
llama-swap -version 2>/dev/null || true
echo
echo "next: ./scripts/start-models.sh <m2pro|m4pro>"
