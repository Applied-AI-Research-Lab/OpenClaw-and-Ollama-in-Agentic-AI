#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "Missing .env. Copy .env.example first." >&2
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

if [[ -z "${OLLAMA_MODELS:-}" ]]; then
  echo "OLLAMA_MODELS is empty in .env" >&2
  exit 1
fi

IFS=',' read -r -a MODELS <<< "$OLLAMA_MODELS"

for model in "${MODELS[@]}"; do
  model_trimmed="$(echo "$model" | xargs)"
  if [[ -n "$model_trimmed" ]]; then
    echo "Pulling model: $model_trimmed"
    if [[ "$OLLAMA_MODE" == "host" ]]; then
      if ! command -v ollama >/dev/null 2>&1; then
        echo "Missing required command: ollama (needed for OPENCLAW_OLLAMA_MODE=host)" >&2
        exit 1
      fi
      ollama pull "$model_trimmed"
    else
      "${DOCKER_CMD[@]}" compose exec -T ollama ollama pull "$model_trimmed"
    fi
  fi
done

echo "Model pull complete"
