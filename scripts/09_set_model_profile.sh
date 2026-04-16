#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/09_set_model_profile.sh qwen [qwen-model-tag]
  ./scripts/09_set_model_profile.sh gemma4 [gemma-model-tag]

Examples:
  ./scripts/09_set_model_profile.sh qwen
  ./scripts/09_set_model_profile.sh qwen qwen3.5:4b
  ./scripts/09_set_model_profile.sh gemma4
  ./scripts/09_set_model_profile.sh gemma4 gemma4:e4b

Notes:
- Updates OPENCLAW_MODEL_ID and PAPER_MODEL_C1/C2/C3 in .env
- Ensures selected model is present in OLLAMA_MODELS
EOF
}

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing .env. Run: cp .env.example .env" >&2
  exit 1
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

profile="$1"
model_override="${2:-}"

case "$profile" in
  qwen)
    model="${model_override:-qwen3.5:4b}"
    paper_label="qwen3-5-4b"
    ;;
  gemma4)
    model="${model_override:-gemma4:e4b}"
    paper_label="gemma4-e4b"
    ;;
  *)
    echo "Unknown profile: $profile" >&2
    usage
    exit 1
    ;;
esac

set_key_value() {
  local key="$1"
  local value="$2"
  if grep -Eq "^${key}=" "$ENV_FILE"; then
    sed -i.bak -E "s|^${key}=.*$|${key}=${value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

append_model_if_missing() {
  local selected="$1"
  local current
  current="$(grep -E '^OLLAMA_MODELS=' "$ENV_FILE" | head -n1 | cut -d'=' -f2- || true)"

  if [[ -z "$current" ]]; then
    set_key_value "OLLAMA_MODELS" "$selected"
    return
  fi

  IFS=',' read -r -a arr <<< "$current"
  local found=0
  local item
  for item in "${arr[@]}"; do
    if [[ "$(echo "$item" | xargs)" == "$selected" ]]; then
      found=1
      break
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    set_key_value "OLLAMA_MODELS" "${current},${selected}"
  fi
}

set_key_value "OPENCLAW_MODEL_ID" "$model"
set_key_value "PAPER_MODEL_C1" "$model"
set_key_value "PAPER_MODEL_C2" "$model"
set_key_value "PAPER_MODEL_C3" "$model"
set_key_value "PAPER_MODEL_LABEL" "$paper_label"
append_model_if_missing "$model"

rm -f "$ENV_FILE.bak"

echo "[ok] Switched model profile: $profile"
echo "[ok] OPENCLAW_MODEL_ID=$model"
echo "[ok] PAPER_MODEL_C1/C2/C3=$model"
echo "[ok] PAPER_MODEL_LABEL=$paper_label"
echo "[ok] OLLAMA_MODELS includes: $model"
