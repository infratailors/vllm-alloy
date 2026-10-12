#!/usr/bin/env bash
# Tests for egress_preflight.sh. Hermetic: a stub `getent` on PATH decides which
# hosts resolve, so no real DNS is touched. Run: bash tests/test_egress_preflight.sh
# No -e: a false assertion must reach check() and print FAIL, not abort.
set -uo pipefail

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

out="$(run RESOLVABLE="" HF_ENDPOINT=https://hub.example.com ALLOY_REMOTE_WRITE_URL=https://hub.example.com/write)"
[[ "${out}" == *"cannot resolve hub.example.com."* ]]; check "a host shared by both URLs is checked once" $?

out="$(run RESOLVABLE="huggingface.co" PREFLIGHT_TIMEOUT_SECONDS=abc)"
[[ -z "${out}" ]]; check "a malformed timeout falls back instead of failing every lookup" $?

start=${SECONDS}
out="$(run RESOLVABLE="" HANG=1 PREFLIGHT_TIMEOUT_SECONDS=1)"
[[ $((SECONDS - start)) -lt 10 && "${out}" == *"cannot resolve huggingface.co"* ]]
check "a stalled lookup is capped and reported" $?

# The exit status is 0 even when lookups fail: the preflight never blocks vLLM.
run RESOLVABLE="" >/dev/null; check "returns 0 when lookups fail" $?

# End to end: run the real entrypoint.sh, as the Dockerfile lays it out
# (egress_preflight.sh next to it), with alloy / python3 stubbed by `proc`:
# "<delay>:<code>" sleeps then exits with code; "run" sleeps until TERM, then
# exits 0. VLLM / ALLOY pick each stub's behaviour.
BIN_DIR="${STUB_DIR}/bin"; mkdir -p "${BIN_DIR}"
cp "${ROOT}/entrypoint.sh" "${ROOT}/egress_preflight.sh" "${BIN_DIR}/"
cat > "${STUB_DIR}/proc" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == run ]]; then
  # STOP_DELAY: seconds to "drain" after the first TERM; later TERMs ignored.
  stopping=0
  trap '[[ ${stopping} -eq 1 ]] || { stopping=1; kill "$!" 2>/dev/null
        sleep "${STOP_DELAY:-0}"; echo "STOPPED $2"; exit 0; }' TERM
  sleep 30 & wait; exit 99
fi
[[ "$2" == vllm ]] && echo VLLM_STARTED
sleep "${1%%:*}"; exit "${1##*:}"
STUB
cat > "${STUB_DIR}/alloy" <<'STUB'
#!/usr/bin/env bash
exec "$(dirname "$0")/proc" "${ALLOY:-run}" alloy
STUB
cat > "${STUB_DIR}/python3" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == *gpu_exporter* ]] && exit 0  # best-effort; outside the wait set
exec "$(dirname "$0")/proc" "${VLLM:-run}" vllm
STUB
chmod +x "${STUB_DIR}/proc" "${STUB_DIR}/alloy" "${STUB_DIR}/python3"
entry() {  # entry <env...>: sets out and rc
  rc=0
  out="$(env -i PATH="${STUB_DIR}:${PATH}" "$@" bash "${BIN_DIR}/entrypoint.sh" 2>&1)" || rc=$?
}

entry RESOLVABLE="" VLLM=1:0
[[ ${rc} -eq 0 && "${out}" == *"PREFLIGHT FAILED"* && "${out}" == *"VLLM_STARTED"* ]]
check "entrypoint.sh sources the preflight and still starts vLLM" $?

# Regression: a vLLM that exits non-zero (the #338 crash loop) must still get
# the exit log line and a clean Alloy shutdown, with vLLM's code propagated.
entry RESOLVABLE="huggingface.co" VLLM=1:3
[[ ${rc} -eq 3 && "${out}" == *"vLLM exited (code 3)"* && "${out}" == *"STOPPED alloy"* ]]
check "a failing vLLM is logged, stops Alloy, and propagates its exit code" $?

entry RESOLVABLE="huggingface.co" VLLM=0:3
[[ ${rc} -eq 3 && "${out}" == *"vLLM exited (code 3)"* ]]
check "a vLLM that exits before the wait starts is still reported" $?

entry RESOLVABLE="huggingface.co" ALLOY=1:2
[[ ${rc} -eq 1 && "${out}" == *"Alloy exited unexpectedly"* && "${out}" == *"STOPPED vllm"* ]]
check "Alloy dying first stops vLLM and exits 1" $?

# The platform stopping the container is not an Alloy failure.
log="${STUB_DIR}/term.log"
env -i PATH="${STUB_DIR}:${PATH}" RESOLVABLE="huggingface.co" \
  bash "${BIN_DIR}/entrypoint.sh" > "${log}" 2>&1 &
pid=$!
sleep 1; kill -TERM "${pid}"; rc=0; wait "${pid}" || rc=$?
out="$(cat "${log}")"
[[ ${rc} -eq 0 && "${out}" == *"terminated by signal; vLLM exited (code 0)"* \
   && "${out}" != *"Alloy exited unexpectedly"* ]]
check "SIGTERM is reported as a shutdown, not an Alloy failure" $?

# A second SIGTERM while vLLM drains must not cut the shutdown short.
env -i PATH="${STUB_DIR}:${PATH}" RESOLVABLE="huggingface.co" STOP_DELAY=2 \
  bash "${BIN_DIR}/entrypoint.sh" > "${log}" 2>&1 &
pid=$!
sleep 1; kill -TERM "${pid}"; sleep 0.5; kill -TERM "${pid}"; rc=0; wait "${pid}" || rc=$?
out="$(cat "${log}")"
[[ "${out}" == *"STOPPED vllm"* && "${out}" == *"terminated by signal; vLLM exited (code 0)"* ]]
check "a second SIGTERM waits for vLLM to finish draining" $?

exit "${failures}"
