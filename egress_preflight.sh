# egress_preflight.sh: sourced by entrypoint.sh, not executed.
#
# A provider pod without outbound DNS makes vLLM die on the HuggingFace
# download with a 200-line traceback, and the restart loop looks like an image
# bug. Say what is wrong in one line up front. Never blocks: vLLM still starts,
# so a model that is already cached (or HF_HUB_OFFLINE=1) keeps working.
# Each lookup is capped at PREFLIGHT_TIMEOUT_SECONDS (default 5).
egress_preflight() {
  local hosts=() host
  [[ "${HF_HUB_OFFLINE:-0}" == "1" ]] || hosts+=("huggingface.co")
  if [[ -n "${ALLOY_REMOTE_WRITE_URL:-}" ]]; then
    host="${ALLOY_REMOTE_WRITE_URL#*://}"; host="${host%%[/:]*}"
    [[ -z "${host}" ]] || hosts+=("${host}")
  fi
  for host in "${hosts[@]}"; do
    # A broken resolver can stall each lookup for ~20s; cap it so a pod
    # without DNS doesn't also start late.
    if ! timeout "${PREFLIGHT_TIMEOUT_SECONDS:-5}" getent hosts "${host}" >/dev/null 2>&1; then
      echo "entrypoint: PREFLIGHT FAILED: cannot resolve ${host}. This pod has" \
           "no outbound DNS; that is a provider network issue, not a vLLM or" \
           "model problem. Try another region or contact the provider." >&2
    fi
  done
}
