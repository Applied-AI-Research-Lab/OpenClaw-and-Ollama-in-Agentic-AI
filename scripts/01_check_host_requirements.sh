#!/usr/bin/env bash
set -euo pipefail

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

need_cmd docker
need_cmd nvidia-smi

DOCKER_CMD=(docker)
if ! docker info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER_CMD=(sudo -n docker)
  fi
fi

if ! "${DOCKER_CMD[@]}" compose version >/dev/null 2>&1; then
  echo "Docker Compose plugin is missing" >&2
  exit 1
fi

if ! "${DOCKER_CMD[@]}" info >/dev/null 2>&1; then
  echo "Docker daemon is not accessible" >&2
  exit 1
fi

echo "[ok] docker reachable"
echo "[ok] docker compose available"
echo "[ok] nvidia-smi available"

echo "--- GPU summary ---"
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv,noheader

echo "--- Docker GPU test ---"
# Standard Docker hosts support --gpus all. Some managed providers require CDI devices.
gpu_err="$(mktemp)"
trap 'rm -f "$gpu_err"' EXIT

if [[ "${OPENCLAW_ALLOW_CPU_ONLY:-0}" == "1" ]]; then
  echo "[warn] Skipping Docker GPU runtime test because OPENCLAW_ALLOW_CPU_ONLY=1"
  echo "[warn] Pipeline will run in CPU-only mode (slower; large models may be impractical)."
  exit 0
fi

if "${DOCKER_CMD[@]}" run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>"$gpu_err"; then
  echo "[ok] docker GPU runtime works (--gpus all)"
elif "${DOCKER_CMD[@]}" run --rm --device nvidia.com/gpu=all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>"$gpu_err"; then
  echo "[ok] docker GPU runtime works (--device nvidia.com/gpu=all)"
else
  if grep -qi "libthunder.so" "$gpu_err" && [[ -f /etc/thunder/libthunder-nogpu.so ]] && [[ ! -f /etc/thunder/libthunder.so ]]; then
    echo "[warn] Host runtime appears to be in Thunder no-GPU mode (/etc/thunder/libthunder.so missing)." >&2
    echo "[warn] Ask your provider to enable GPU container runtime for this instance." >&2
  fi
  echo "[warn] docker GPU runtime stderr:" >&2
  sed -n '1,5p' "$gpu_err" >&2
  echo "[warn] docker GPU runtime test failed. Check NVIDIA Container Toolkit or CDI GPU device support." >&2
  echo "[hint] To continue without container GPU, set OPENCLAW_ALLOW_CPU_ONLY=1 and rerun." >&2
  exit 1
fi
