# egress_preflight.sh: sourced by entrypoint.sh, not executed.
#
# A provider pod without outbound DNS makes vLLM die on the HuggingFace
# download with a 200-line traceback, and the restart loop looks like an image
# bug. Say what is wrong in one line up front. Never blocks: vLLM still starts,
# so a model that is already cached (or HF_HUB_OFFLINE set) keeps working.
# Each lookup is capped at PREFLIGHT_TIMEOUT_SECONDS (default 10).

# url_host <url>: the bare hostname of a URL (no scheme, userinfo, port, path,
# query or fragment), lowercased. Empty for an IPv6 literal: nothing to resolve.
url_host() {
  local host="${1#*://}"
  host="${host%%[/?#]*}"   # authority only
  host="${host##*@}"       # drop user:password@
  [[ "${host}" == \[* ]] && return 0
  host="${host%%:*}"       # drop :port
  printf '%s' "${host,,}"
}

egress_preflight() {
  local hosts=() failed=() host
  case "${HF_HUB_OFFLINE:-}" in
    1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]) ;;
    *) host="$(url_host "${HF_ENDPOINT:-https://huggingface.co}")"
       [[ -z "${host}" ]] || hosts+=("${host}") ;;
  esac
  host="$(url_host "${ALLOY_REMOTE_WRITE_URL:-}")"
  [[ -z "${host}" || " ${hosts[*]} " == *" ${host} "* ]] || hosts+=("${host}")

  # A malformed cap would make `timeout` fail every lookup: a false alarm.
  local cap="${PREFLIGHT_TIMEOUT_SECONDS:-10}"
  [[ "${cap}" =~ ^[1-9][0-9]*$ ]] || cap=10

  for host in "${hosts[@]}"; do
    # A broken resolver can stall each lookup for ~20s; cap it so a pod
    # without DNS doesn't also start late.
    timeout "${cap}" getent hosts "${host}" >/dev/null 2>&1 \
      || failed+=("${host}")
  done

  [[ ${#failed[@]} -eq 0 ]] && return 0
  if [[ ${#failed[@]} -eq ${#hosts[@]} ]]; then
    echo "entrypoint: PREFLIGHT FAILED: cannot resolve ${failed[*]}. This pod" \
         "has no working DNS or outbound network; that is a provider network" \
         "issue, not a vLLM or model problem. Try another region or contact" \
         "the provider." >&2
  else
    echo "entrypoint: PREFLIGHT FAILED: cannot resolve ${failed[*]}, although" \
         "other hosts resolve. Check that hostname in the deployment's env." >&2
  fi
  return 0
}
