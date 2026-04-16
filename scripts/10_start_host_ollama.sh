#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p state/ollama
LOG_FILE="state/ollama/host-ollama.log"

if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo "[ok] Host Ollama already running"
  exit 0
fi

if ! command -v ollama >/dev/null 2>&1; then
  echo "Missing required command: ollama" >&2
  echo "Install Ollama on host to use OPENCLAW_OLLAMA_MODE=host" >&2
  exit 1
fi

echo "Starting host Ollama..."
nohup ollama serve >"$LOG_FILE" 2>&1 &

for i in {1..90}; do
  if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    echo "[ok] Host Ollama is ready"
    exit 0
  fi
  sleep 2
done

echo "Host Ollama did not become ready in time. Check: $LOG_FILE" >&2
exit 1
