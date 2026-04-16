#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNS_DIR="$ROOT_DIR/paper_pipeline/runs"
OUT_DIR="$ROOT_DIR/paper_pipeline/output"

render_bar() {
  local pct="$1"
  local width=30
  local fill=$((pct * width / 100))
  local empty=$((width - fill))
  printf "["
  printf "%0.s#" $(seq 1 "$fill")
  printf "%0.s-" $(seq 1 "$empty")
  printf "] %3d%%" "$pct"
}

has_run_for_config() {
  local cfg="$1"
  grep -Rsl "\"config_id\": \"$cfg\"" "$RUNS_DIR"/run_*.json >/dev/null 2>&1
}

is_pipeline_running() {
  pgrep -f "scripts/08_run_project_pipeline.sh" >/dev/null 2>&1
}

current_stage() {
  if pgrep -f "run_benchmark.py --config .*c1_ollama_only.json" >/dev/null 2>&1; then
    echo "C1 benchmark"
    return
  fi
  if pgrep -f "run_benchmark.py --config .*c2_openclaw_stateless.json" >/dev/null 2>&1; then
    echo "C2 benchmark"
    return
  fi
  if pgrep -f "run_benchmark.py --config .*c3_openclaw_full.json" >/dev/null 2>&1; then
    echo "C3 benchmark"
    return
  fi
  if pgrep -f "generate_paper_artifacts.py" >/dev/null 2>&1; then
    echo "Generating artifacts"
    return
  fi
  echo "Startup/idle"
}

compute_progress() {
  local pct=5

  if has_run_for_config "c1-ollama-only"; then
    pct=35
  fi
  if has_run_for_config "c2-openclaw-stateless"; then
    pct=65
  fi
  if has_run_for_config "c3-openclaw-full"; then
    pct=90
  fi

  if [[ -f "$OUT_DIR/tables/main_results.tex" ]] \
    && [[ -f "$OUT_DIR/tables/category_results.tex" ]] \
    && [[ -f "$OUT_DIR/figures/success_rate.pdf" ]] \
    && [[ -f "$OUT_DIR/figures/latency_ms.pdf" ]] \
    && [[ -f "$OUT_DIR/failure_diagnostics.md" ]] \
    && [[ -f "$OUT_DIR/paper_section.md" ]]; then
    pct=100
  fi

  echo "$pct"
}

print_snapshot() {
  local stage
  local pct
  stage="$(current_stage)"
  pct="$(compute_progress)"

  printf "\r%s  stage: %-24s  " "$(render_bar "$pct")" "$stage"
}

echo "Monitoring pipeline progress. Press Ctrl+C to stop."

while true; do
  print_snapshot

  if ! is_pipeline_running; then
    final_pct="$(compute_progress)"
    echo
    if [[ "$final_pct" -eq 100 ]]; then
      echo "Pipeline appears complete."
      exit 0
    fi
    echo "Pipeline process is not running."
    exit 1
  fi

  sleep 2
done
