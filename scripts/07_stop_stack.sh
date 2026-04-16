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
	export PATH="$HOME/.npm-global/bin:$PATH"
	openclaw gateway stop >/dev/null 2>&1 || true
	pkill -f 'openclaw-gateway|openclaw gateway run' >/dev/null 2>&1 || true
	echo "Stopped host-openclaw-gateway"
	exit 0
fi

DOCKER_CMD=(docker)
if ! docker info >/dev/null 2>&1; then
	if sudo -n docker info >/dev/null 2>&1; then
		DOCKER_CMD=(sudo -n docker)
	fi
fi

"${DOCKER_CMD[@]}" compose down

echo "Stack stopped"
