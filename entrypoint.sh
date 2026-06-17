#!/usr/bin/env bash
# entrypoint.sh — supervise vLLM (model server) + Grafana Alloy in one
# managed container. vLLM is the health-determining process: if it dies, the
# container exits (with vLLM's code) so Gcore restarts/marks it unhealthy.
#
# All vLLM args come from envs (set by the deployment), so no `command` is
# needed on the Gcore side for this image.
#
# This entrypoint reads DTYPE (default "auto") and EXTRA_VLLM_ARGS (default
# empty) so a deployment's per-architecture quirks (e.g. --dtype bfloat16,
# Turing sampler flags) survive even though `command` is omitted.
# EXTRA_VLLM_ARGS is a space-separated list of extra CLI flags appended
# verbatim.
set -euo pipefail

# --- Alloy (background) ------------------------------------------------------
# Its own HTTP UI binds to localhost only; the service port is vLLM's 8000.
alloy run \
  --server.http.listen-addr=127.0.0.1:12345 \
  --storage.path=/var/lib/alloy/data \
  /etc/alloy/config.alloy &
ALLOY_PID=$!

# --- GPU exporter (background; NVML -> DCGM_FI_DEV_* on :9400) ----------------
# Best-effort: emits GPU metrics for Alloy to scrape. Deliberately NOT in the
# wait -n set below — if NVML is blocked in this managed container it must not
# take the container down (vLLM stays health-determining).
python3 /usr/local/bin/gpu_exporter.py &
GPU_PID=$!

# --- vLLM (background, but health-determining) -------------------------------
# Split EXTRA_VLLM_ARGS into an array so each flag is its own argv entry.
read -ra EXTRA_ARGS <<< "${EXTRA_VLLM_ARGS:-}"
python3 -m vllm.entrypoints.openai.api_server \
  --model "${MODEL_NAME:-bigcode/starcoder2-3b}" \
  --task "${VLLM_TASK:-generate}" \
  --host 0.0.0.0 \
  --port "${LISTEN_PORT:-8000}" \
  --max-model-len "${MAX_MODEL_LEN:-16384}" \
  --gpu-memory-utilization "${GPU_MEM_UTIL:-0.90}" \
  --dtype "${DTYPE:-auto}" \
  "${EXTRA_ARGS[@]}" &
VLLM_PID=$!

# --- Forward termination signals to both children ---------------------------
term_handler() {
  kill -TERM "${VLLM_PID}"  2>/dev/null || true
  kill -TERM "${ALLOY_PID}" 2>/dev/null || true
  kill -TERM "${GPU_PID}"   2>/dev/null || true
}
trap term_handler SIGTERM SIGINT

# --- Wait for whichever child exits first -----------------------------------
wait -n "${VLLM_PID}" "${ALLOY_PID}"

if ! kill -0 "${VLLM_PID}" 2>/dev/null; then
  # vLLM exited — propagate its real code and stop Alloy.
  wait "${VLLM_PID}"; rc=$?
  echo "entrypoint: vLLM exited (code ${rc}); stopping Alloy and container." >&2
  kill -TERM "${ALLOY_PID}" 2>/dev/null || true
  wait "${ALLOY_PID}" 2>/dev/null || true
  exit "${rc}"
else
  # Alloy died first while vLLM is still up: exit non-zero to force a restart
  # so metrics resume (vLLM stays health-determining via its /health probe).
  echo "entrypoint: Alloy exited unexpectedly; terminating to force a restart." >&2
  kill -TERM "${VLLM_PID}" 2>/dev/null || true
  wait "${VLLM_PID}" 2>/dev/null || true
  exit 1
fi
