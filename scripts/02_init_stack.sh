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

mkdir -p state/openclaw state/ollama workspace

if [[ "$OLLAMA_MODE" == "host" ]]; then
  OPENCLAW_ALLOW_CPU_ONLY=1 ./scripts/01_check_host_requirements.sh
else
  ./scripts/01_check_host_requirements.sh
fi

echo "[1/4] Starting Ollama"
if [[ "$OLLAMA_MODE" == "host" ]]; then
  ./scripts/10_start_host_ollama.sh
else
  "${DOCKER_CMD[@]}" compose up -d ollama
fi

echo "[2/4] Waiting for Ollama API"
for i in {1..90}; do
  if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    echo "Ollama is ready"
    break
  fi
  sleep 2
  if [[ $i -eq 90 ]]; then
    echo "Ollama did not become ready in time" >&2
    exit 1
  fi
done

echo "[3/4] Pulling configured models"
./scripts/05_pull_models.sh

echo "[4/4] Running OpenClaw onboarding"
if [[ "$OLLAMA_MODE" == "host" ]]; then
  export PATH="$HOME/.npm-global/bin:$PATH"
  if ! command -v openclaw >/dev/null 2>&1; then
    echo "Missing required command: openclaw (install host CLI for OPENCLAW_OLLAMA_MODE=host)" >&2
    exit 1
  fi
  OLLAMA_BASE_URL="http://127.0.0.1:11434"
  export OPENCLAW_HOME="$ROOT_DIR/state/openclaw"
  export OPENCLAW_STATE_DIR="$ROOT_DIR/state/openclaw"
  export OPENCLAW_CONFIG_PATH="$ROOT_DIR/state/openclaw/openclaw.json"
  openclaw onboard \
    --non-interactive \
    --accept-risk \
    --mode local \
    --auth-choice ollama \
    --custom-base-url "${OLLAMA_BASE_URL}" \
    --custom-model-id "${OPENCLAW_MODEL_ID}" \
    --gateway-port "${OPENCLAW_GATEWAY_PORT}" \
    --gateway-bind "${OPENCLAW_GATEWAY_BIND}" \
    --gateway-auth token \
    --gateway-token "${OPENCLAW_GATEWAY_TOKEN}" \
    --no-install-daemon \
    --skip-channels \
    --skip-search \
    --skip-skills \
    --skip-ui \
    --skip-health
else
  OLLAMA_BASE_URL="http://ollama:11434"
  "${DOCKER_CMD[@]}" compose run --rm openclaw-cli onboard \
    --no-deps \
    --non-interactive \
    --accept-risk \
    --mode local \
    --auth-choice ollama \
    --custom-base-url "${OLLAMA_BASE_URL}" \
    --custom-model-id "${OPENCLAW_MODEL_ID}" \
    --gateway-port "${OPENCLAW_GATEWAY_PORT}" \
    --gateway-bind "${OPENCLAW_GATEWAY_BIND}" \
    --gateway-auth token \
    --gateway-token "${OPENCLAW_GATEWAY_TOKEN}" \
    --no-install-daemon \
    --skip-channels \
    --skip-search \
    --skip-skills \
    --skip-ui \
    --skip-health
fi

echo "Initialization complete. Next: ./scripts/03_start_stack.sh"
