#!/usr/bin/env bash
# Tests for egress_preflight.sh. Hermetic: a stub `getent` on PATH decides which
# hosts resolve, so no real DNS is touched. Run: bash tests/test_egress_preflight.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "${STUB_DIR}"' EXIT

# Stub: resolves every host listed in $RESOLVABLE (space-separated) and fails
# the rest; with HANG=1 it stalls like a broken resolver.
cat > "${STUB_DIR}/getent" <<'STUB'
#!/usr/bin/env bash
[[ "${HANG:-0}" == "1" ]] && sleep 30
[[ " ${RESOLVABLE:-} " == *" $2 "* ]]
STUB
chmod +x "${STUB_DIR}/getent"

failures=0
# run <env assignments...>: prints the preflight's stderr; asserts exit code 0.
run() {
  env -i PATH="${STUB_DIR}:${PATH}" "$@" bash -c \
    "set -euo pipefail; source '${ROOT}/egress_preflight.sh'; egress_preflight" 2>&1
}
check() {  # check <name> <condition-exit-code>
  if [[ "$2" -eq 0 ]]; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}

out="$(run RESOLVABLE="huggingface.co grafana.example.com" \
  ALLOY_REMOTE_WRITE_URL=https://grafana.example.com/api/v1/write)"
[[ -z "${out}" ]]; check "silent when every host resolves" $?

out="$(run RESOLVABLE="" ALLOY_REMOTE_WRITE_URL=https://grafana.example.com:443/api/v1/write)"
[[ "${out}" == *"cannot resolve huggingface.co"* ]]; check "names huggingface.co when DNS is down" $?
[[ "${out}" == *"cannot resolve grafana.example.com."* ]]; check "strips scheme, port and path from the remote-write URL" $?
[[ "$(grep -c PREFLIGHT <<< "${out}")" -eq 2 ]]; check "one line per unresolvable host" $?

out="$(run RESOLVABLE="" HF_HUB_OFFLINE=1)"
[[ -z "${out}" ]]; check "HF_HUB_OFFLINE=1 and no remote-write URL: nothing to check" $?

out="$(run RESOLVABLE="huggingface.co" ALLOY_REMOTE_WRITE_URL="")"
[[ -z "${out}" ]]; check "empty remote-write URL is skipped" $?

start=${SECONDS}
out="$(run RESOLVABLE="" HANG=1 PREFLIGHT_TIMEOUT_SECONDS=1)"
[[ $((SECONDS - start)) -lt 10 && "${out}" == *"cannot resolve huggingface.co"* ]]
check "a stalled lookup is capped and reported" $?

# The exit status is 0 even when lookups fail: the preflight never blocks vLLM.
run RESOLVABLE="" >/dev/null; check "returns 0 when lookups fail" $?

exit "${failures}"
