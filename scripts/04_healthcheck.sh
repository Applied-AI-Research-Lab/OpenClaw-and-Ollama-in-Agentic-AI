#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "Missing .env. Run: cp .env.example .env" >&2
  exit 1
fi

# shellcheck disable=SC1091
source .env

OLLAMA_MODE="${OPENCLAW_OLLAMA_MODE:-docker}"

DOCKER_CMD=(docker)
if ! docker info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER_CMD=(sudo -n docker)
  fi
fi

echo "--- Ollama health ---"
curl -fsS http://127.0.0.1:11434/api/tags | sed -n '1,120p'

echo "\n--- OpenClaw health ---"
for i in {1..60}; do
  if curl -fsS "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/healthz" >/tmp/openclaw_health.out 2>/dev/null; then
    sed -n '1,120p' /tmp/openclaw_health.out
    break
  fi
  sleep 1
  if [[ $i -eq 60 ]]; then
    echo "OpenClaw gateway not reachable on port ${OPENCLAW_GATEWAY_PORT}" >&2
    exit 1
  fi
done

echo "\n--- Containers ---"
if [[ "$OLLAMA_MODE" == "host" ]]; then
  gw_pid="$(pgrep -f 'openclaw-gateway|openclaw gateway run' | head -n1 || true)"
  if [[ -n "$gw_pid" ]]; then
    echo "host-openclaw-gateway  running (pid=$gw_pid)"
  else
    echo "host-openclaw-gateway  running (pid=unknown)"
  fi
else
  "${DOCKER_CMD[@]}" compose ps
fi
