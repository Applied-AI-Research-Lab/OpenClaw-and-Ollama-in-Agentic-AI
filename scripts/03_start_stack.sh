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
GATEWAY_LOG_FILE="$ROOT_DIR/state/openclaw/host-gateway.log"

DOCKER_CMD=(docker)
if ! docker info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER_CMD=(sudo -n docker)
  fi
fi

if [[ "$OLLAMA_MODE" == "host" ]]; then
  ./scripts/10_start_host_ollama.sh
  export PATH="$HOME/.npm-global/bin:$PATH"
  if ! command -v openclaw >/dev/null 2>&1; then
    echo "Missing required command: openclaw (install host CLI for OPENCLAW_OLLAMA_MODE=host)" >&2
    exit 1
  fi

  mkdir -p "$ROOT_DIR/state/openclaw"
  openclaw gateway stop >/dev/null 2>&1 || true

  export OPENCLAW_HOME="$ROOT_DIR/state/openclaw"
  export OPENCLAW_STATE_DIR="$ROOT_DIR/state/openclaw"
  export OPENCLAW_CONFIG_PATH="$ROOT_DIR/state/openclaw/openclaw.json"
  export OPENCLAW_GATEWAY_TOKEN
  nohup openclaw gateway run --force >"$GATEWAY_LOG_FILE" 2>&1 &
else
  "${DOCKER_CMD[@]}" compose up -d ollama openclaw-gateway
fi

echo "Stack started"
./scripts/04_healthcheck.sh
