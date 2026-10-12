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
[[ "${out}" == *"cannot resolve huggingface.co grafana.example.com."* ]]; check "names every host when DNS is down" $?
[[ "${out}" == *"provider network"* ]]; check "blames the provider when nothing resolves" $?
[[ "$(grep -c PREFLIGHT <<< "${out}")" -eq 1 ]]; check "one line, not one per host" $?

out="$(run RESOLVABLE="huggingface.co" ALLOY_REMOTE_WRITE_URL=https://grafana.example.com/api/v1/write)"
[[ "${out}" == *"cannot resolve grafana.example.com, although other hosts resolve"* && "${out}" != *"provider network"* ]]
check "a single bad host is not blamed on the provider" $?

out="$(run RESOLVABLE="huggingface.co grafana.example.com" \
  ALLOY_REMOTE_WRITE_URL="https://user:pw@GRAFANA.example.com:8443/api/v1/write?x=1#f")"
[[ -z "${out}" ]]; check "strips scheme, userinfo, port, path, query, fragment; lowercases" $?

out="$(run RESOLVABLE="huggingface.co" ALLOY_REMOTE_WRITE_URL="http://[2001:db8::1]:9090/write")"
[[ -z "${out}" ]]; check "IPv6 literal is not looked up" $?

out="$(run RESOLVABLE="hf-mirror.example.com")"
[[ "${out}" == *"cannot resolve huggingface.co"* ]]; check "checks huggingface.co by default" $?
out="$(run RESOLVABLE="hf-mirror.example.com" HF_ENDPOINT=https://hf-mirror.example.com)"
[[ -z "${out}" ]]; check "HF_ENDPOINT mirror is checked instead of huggingface.co" $?

for v in 1 true YES on; do
  out="$(run RESOLVABLE="" HF_HUB_OFFLINE="${v}")"
  [[ -z "${out}" ]]; check "HF_HUB_OFFLINE=${v} skips the HF check" $?
done


out="$(run RESOLVABLE="huggingface.co" ALLOY_REMOTE_WRITE_URL="")"
[[ -z "${out}" ]]; check "empty remote-write URL is skipped" $?

start=${SECONDS}
out="$(run RESOLVABLE="" HANG=1 PREFLIGHT_TIMEOUT_SECONDS=1)"
[[ $((SECONDS - start)) -lt 10 && "${out}" == *"cannot resolve huggingface.co"* ]]
check "a stalled lookup is capped and reported" $?

# The exit status is 0 even when lookups fail: the preflight never blocks vLLM.
run RESOLVABLE="" >/dev/null; check "returns 0 when lookups fail" $?

# End to end: run the real entrypoint.sh, as the Dockerfile lays it out
# (egress_preflight.sh next to it), with alloy / python3 stubbed. Proves the
# source line works and that vLLM still starts after a failed preflight.
BIN_DIR="${STUB_DIR}/bin"; mkdir -p "${BIN_DIR}"
cp "${ROOT}/entrypoint.sh" "${ROOT}/egress_preflight.sh" "${BIN_DIR}/"
cat > "${STUB_DIR}/alloy" <<'STUB'
#!/usr/bin/env bash
exec sleep 30
STUB
cat > "${STUB_DIR}/python3" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == *gpu_exporter* ]] && exit 0  # best-effort; outside the wait set
echo "VLLM_STARTED"
STUB
chmod +x "${STUB_DIR}/alloy" "${STUB_DIR}/python3"
rc=0
out="$(env -i PATH="${STUB_DIR}:${PATH}" RESOLVABLE="" bash "${BIN_DIR}/entrypoint.sh" 2>&1)" || rc=$?
[[ ${rc} -eq 0 && "${out}" == *"PREFLIGHT FAILED"* && "${out}" == *"VLLM_STARTED"* ]]
check "entrypoint.sh sources the preflight and still starts vLLM" $?

exit "${failures}"
