#!/usr/bin/env bash
# Run the full benchmark pipeline for all models, then generate cross-model comparison artifacts.
#
# Usage:
#   ./scripts/10_run_all_models.sh [--models qwen,gemma4] [--repeats 1]
#
# Outputs:
#   paper_pipeline/results/qwen3-5-4b/   — per-task traces + per-model figures/tables
#   paper_pipeline/results/gemma4-e4b/   — same for Gemma
#   paper_pipeline/results/comparison/   — grouped bar charts, cross-model LaTeX table
#
# Requirements: server stack running (03_start_stack.sh), models pulled (05_pull_models.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PIPE_DIR="$ROOT_DIR/paper_pipeline"
VENV_DIR="$ROOT_DIR/.venv-report"

cd "$ROOT_DIR"

# ── argument parsing ──────────────────────────────────────────────────────────
MODELS="qwen,gemma4"
REPEATS="${PAPER_REPEATS:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --models)  MODELS="$2"; shift 2 ;;
    --repeats) REPEATS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

IFS=',' read -r -a MODEL_LIST <<< "$MODELS"

# ── ensure venv ───────────────────────────────────────────────────────────────
echo "[setup] Prepare Python venv"
if [[ ! -d "$VENV_DIR" ]]; then
  python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
python -m pip install -q --upgrade pip
python -m pip install -q -r "$PIPE_DIR/scripts/requirements.txt"

# ── run each model ────────────────────────────────────────────────────────────
RESULT_DIRS=()

for model_profile in "${MODEL_LIST[@]}"; do
  echo ""
  echo "========================================================"
  echo "  Running benchmark for model profile: $model_profile"
  echo "========================================================"

  # Set model profile in .env
  "$SCRIPT_DIR/09_set_model_profile.sh" "$model_profile"

  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"

  MODEL_LABEL="${PAPER_MODEL_LABEL:-$(echo "${OPENCLAW_MODEL_ID:-unknown}" | sed 's/[^a-zA-Z0-9]/-/g')}"
  RESULTS_DIR="$PIPE_DIR/results/$MODEL_LABEL"
  RUNS_DIR="$RESULTS_DIR/runs"
  OUTPUT_DIR="$RESULTS_DIR/output"
  mkdir -p "$RUNS_DIR" "$OUTPUT_DIR"
  RESULT_DIRS+=("${MODEL_LABEL}:${RESULTS_DIR}")

  export PAPER_REPEATS="$REPEATS"
  export PAPER_MODEL_LABEL="$MODEL_LABEL"

  # Run single-model pipeline (no venv setup, no artifact generation — we do that below)
  OLLAMA_MODE="${OPENCLAW_OLLAMA_MODE:-docker}"
  if [[ "$OLLAMA_MODE" == "host" ]]; then
    export PATH="$HOME/.npm-global/bin:$PATH"
    export OPENCLAW_AGENT_MODE="host"
    export OPENCLAW_HOME="$ROOT_DIR/state/openclaw"
    export OPENCLAW_STATE_DIR="$ROOT_DIR/state/openclaw"
    export OPENCLAW_CONFIG_PATH="$ROOT_DIR/state/openclaw/openclaw.json"
  fi

  RUN_GROUP="paper-$(date +%s)"
  MODEL_C1="${PAPER_MODEL_C1:-${OPENCLAW_MODEL_ID}}"
  MODEL_C2="${PAPER_MODEL_C2:-${OPENCLAW_MODEL_ID}}"
  MODEL_C3="${PAPER_MODEL_C3:-${OPENCLAW_MODEL_ID}}"

  echo "[run] C1 → $MODEL_C1"
  PAPER_MODEL_OVERRIDE="$MODEL_C1" python "$PIPE_DIR/scripts/run_benchmark.py" \
    --config "$PIPE_DIR/configs/c1_ollama_only.json" \
    --runs-dir "$RUNS_DIR" \
    --label "c1-full-r1" \
    --run-group "$RUN_GROUP" \
    --rep 1

  echo "[run] C2 → $MODEL_C2"
  PAPER_MODEL_OVERRIDE="$MODEL_C2" python "$PIPE_DIR/scripts/run_benchmark.py" \
    --config "$PIPE_DIR/configs/c2_openclaw_stateless.json" \
    --runs-dir "$RUNS_DIR" \
    --label "c2-full-r1" \
    --run-group "$RUN_GROUP" \
    --rep 1

  echo "[run] C3 → $MODEL_C3"
  PAPER_MODEL_OVERRIDE="$MODEL_C3" python "$PIPE_DIR/scripts/run_benchmark.py" \
    --config "$PIPE_DIR/configs/c3_openclaw_full.json" \
    --runs-dir "$RUNS_DIR" \
    --label "c3-full-r1" \
    --run-group "$RUN_GROUP" \
    --rep 1

  echo "[artifacts] Generating per-model figures and tables → $OUTPUT_DIR"
  python "$PIPE_DIR/scripts/generate_paper_artifacts.py" \
    --runs-dir "$RUNS_DIR" \
    --output-dir "$OUTPUT_DIR"
done

# ── cross-model comparison ────────────────────────────────────────────────────
echo ""
echo "========================================================"
echo "  Generating cross-model comparison artifacts"
echo "========================================================"

COMPARISON_DIR="$PIPE_DIR/results/comparison"
mkdir -p "$COMPARISON_DIR"

# Build --model-dirs argument: "label:path label:path ..."
MODEL_DIRS_ARG=()
for spec in "${RESULT_DIRS[@]}"; do
  MODEL_DIRS_ARG+=("$spec")
done

python "$PIPE_DIR/scripts/compare_models.py" \
  --model-dirs "${MODEL_DIRS_ARG[@]}" \
  --output-dir "$COMPARISON_DIR"

echo ""
echo "========================================================"
echo "  All done."
echo ""
echo "  Per-model artifacts:"
for spec in "${RESULT_DIRS[@]}"; do
  label="${spec%%:*}"
  path="${spec##*:}"
  echo "    $label → $path/output/"
done
echo "  Comparison artifacts → $COMPARISON_DIR"
echo "========================================================"
