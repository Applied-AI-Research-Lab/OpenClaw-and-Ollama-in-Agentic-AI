#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
	# shellcheck disable=SC1091
	source .env
fi

OLLAMA_MODE="${OPENCLAW_OLLAMA_MODE:-docker}"
if [[ "$OLLAMA_MODE" == "host" ]]; then
	exec tail -f -n 200 "$ROOT_DIR/state/openclaw/host-gateway.log"
fi

DOCKER_CMD=(docker)
if ! docker info >/dev/null 2>&1; then
	if sudo -n docker info >/dev/null 2>&1; then
		DOCKER_CMD=(sudo -n docker)
	fi
fi

"${DOCKER_CMD[@]}" compose logs -f --tail=200 ollama openclaw-gateway
