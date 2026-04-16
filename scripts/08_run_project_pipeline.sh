#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PIPE_DIR="$ROOT_DIR/paper_pipeline"
VENV_DIR="$ROOT_DIR/.venv-report"

cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "Missing .env. Run: cp .env.example .env" >&2
  exit 1
fi

# shellcheck disable=SC1091
source .env

OLLAMA_MODE="${OPENCLAW_OLLAMA_MODE:-docker}"
PAPER_REPEATS="${PAPER_REPEATS:-1}"
if ! [[ "$PAPER_REPEATS" =~ ^[0-9]+$ ]] || [[ "$PAPER_REPEATS" -lt 1 ]]; then
  echo "PAPER_REPEATS must be a positive integer" >&2
  exit 1
fi
RUN_GROUP="paper-$(date +%s)"

# Resolve the current model from env (set by 09_set_model_profile.sh)
CURRENT_MODEL="${OPENCLAW_MODEL_ID:-unknown}"
# Map model id to short label for result directory
MODEL_LABEL="${PAPER_MODEL_LABEL:-$(echo "$CURRENT_MODEL" | sed 's/[^a-zA-Z0-9]/-/g')}"
RESULTS_DIR="$PIPE_DIR/results/$MODEL_LABEL"
RUNS_DIR="$RESULTS_DIR/runs"
OUTPUT_DIR="$RESULTS_DIR/output"
mkdir -p "$RUNS_DIR" "$OUTPUT_DIR"

DOCKER_CMD=(docker)
if ! docker info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER_CMD=(sudo -n docker)
  fi
fi
export OPENCLAW_DOCKER_CMD="${DOCKER_CMD[*]}"
export OPENCLAW_DOCKER_RUN_MODE="compose"
export OPENCLAW_AGENT_MODE="docker"

echo "[1/7] Ensure stack is up"
if [[ "$OLLAMA_MODE" == "host" ]]; then
  export PATH="$HOME/.npm-global/bin:$PATH"
  export OPENCLAW_AGENT_MODE="host"
  export OPENCLAW_HOME="$ROOT_DIR/state/openclaw"
  export OPENCLAW_STATE_DIR="$ROOT_DIR/state/openclaw"
  export OPENCLAW_CONFIG_PATH="$ROOT_DIR/state/openclaw/openclaw.json"
  export OPENCLAW_GATEWAY_TOKEN
  ./scripts/03_start_stack.sh
else
  "${DOCKER_CMD[@]}" compose up -d ollama openclaw-gateway
fi

echo "[2/7] Wait for services"
for i in {1..90}; do
  if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    break
  fi
  sleep 2
  if [[ $i -eq 90 ]]; then
    echo "Ollama not ready" >&2
    exit 1
  fi
done

for i in {1..90}; do
  if curl -fsS "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 2
  if [[ $i -eq 90 ]]; then
    echo "OpenClaw gateway not ready" >&2
    exit 1
  fi
done

echo "[3/7] Prepare isolated Python venv for report dependencies"
if [[ ! -d "$VENV_DIR" ]]; then
  python3 -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
python -m pip install -q --upgrade pip
python -m pip install -q -r "$PIPE_DIR/scripts/requirements.txt"

echo "[4/7] Resolve model choices"
MODEL_C1="${PAPER_MODEL_C1:-${OPENCLAW_MODEL_ID}}"
MODEL_C2="${PAPER_MODEL_C2:-${OPENCLAW_MODEL_ID}}"
MODEL_C3="${PAPER_MODEL_C3:-${OPENCLAW_MODEL_ID}}"

echo "Using models: C1=$MODEL_C1 C2=$MODEL_C2 C3=$MODEL_C3"
echo "Run group: $RUN_GROUP (repeats=$PAPER_REPEATS)"
echo "Output directory: $RESULTS_DIR"

for rep in $(seq 1 "$PAPER_REPEATS"); do
  echo "[5/7][rep=$rep/$PAPER_REPEATS] Run C1"
  PAPER_MODEL_OVERRIDE="$MODEL_C1" python "$PIPE_DIR/scripts/run_benchmark.py" \
    --config "$PIPE_DIR/configs/c1_ollama_only.json" \
    --runs-dir "$RUNS_DIR" \
    --label "c1-full-r${rep}" \
    --run-group "$RUN_GROUP" \
    --rep "$rep"

  echo "[6/7][rep=$rep/$PAPER_REPEATS] Run C2 and C3"
  PAPER_MODEL_OVERRIDE="$MODEL_C2" python "$PIPE_DIR/scripts/run_benchmark.py" \
    --config "$PIPE_DIR/configs/c2_openclaw_stateless.json" \
    --runs-dir "$RUNS_DIR" \
    --label "c2-full-r${rep}" \
    --run-group "$RUN_GROUP" \
    --rep "$rep"

  PAPER_MODEL_OVERRIDE="$MODEL_C3" python "$PIPE_DIR/scripts/run_benchmark.py" \
    --config "$PIPE_DIR/configs/c3_openclaw_full.json" \
    --runs-dir "$RUNS_DIR" \
    --label "c3-full-r${rep}" \
    --run-group "$RUN_GROUP" \
    --rep "$rep"
done

echo "[7/7] Generate LaTeX tables, PDF figures, diagnostics"
python "$PIPE_DIR/scripts/generate_paper_artifacts.py" \
  --runs-dir "$RUNS_DIR" \
  --output-dir "$OUTPUT_DIR"

echo "Done. Results in: $RESULTS_DIR"
