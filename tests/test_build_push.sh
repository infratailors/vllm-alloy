#!/usr/bin/env bash
# Tests for build-push.sh against a stub `docker` that records its calls: no
# daemon, registry or build. Run: bash tests/test_build_push.sh
# No -e: a false assertion must reach check() and print FAIL, not abort.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "${STUB_DIR}"' EXIT
CALLS="${STUB_DIR}/calls"

# Stub docker. TAG_EXISTS=1: the tag is already in the registry.
# BUILDER_EXISTS=0: no builder yet. HOST_PLATFORMS: what `buildx inspect` lists.
cat > "${STUB_DIR}/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "${CALLS}"
case "$1 $2" in
  "manifest inspect") [[ "${TAG_EXISTS:-0}" == 1 ]] ;;
  "buildx inspect")
    if [[ "$3" == --bootstrap ]]; then
      printf 'Name: x\nDriver: docker-container\nPlatforms:             %s\n' "${HOST_PLATFORMS}"
    else
      [[ "${BUILDER_EXISTS:-1}" == 1 ]]
    fi ;;
  "buildx imagetools") printf '  Platform:  linux/amd64\n  Platform:  linux/arm64\n' ;;
  *) exit 0 ;;
esac
STUB
chmod +x "${STUB_DIR}/docker"

failures=0
check() {  # check <name> <condition-exit-code>
  if [[ "$2" -eq 0 ]]; then echo "ok   $1"; else echo "FAIL $1"; failures=$((failures + 1)); fi
}
run() {  # run <env...>: sets out, rc, calls
  : > "${CALLS}"
  rc=0
  out="$(env -i PATH="${STUB_DIR}:${PATH}" CALLS="${CALLS}" "$@" \
    bash "${ROOT}/build-push.sh" v-test 2>&1)" || rc=$?
  calls="$(cat "${CALLS}")"
}
IMG="ghcr.io/infratailors/vllm-alloy"

# An ARM host without amd64 emulation (the original failure): stop before
# building, and say how to fix it.
run HOST_PLATFORMS="linux/arm64, linux/arm/v7"
[[ ${rc} -ne 0 && "${calls}" != *"buildx build"* ]]; check "missing platform stops before building" $?
[[ "${out}" == *"cannot build: linux/amd64"* && "${out}" == *"tonistiigi/binfmt --install amd64"* ]]
check "names the missing platform and the binfmt fix" $?

# Same on an x86 host without arm64 emulation.
run HOST_PLATFORMS="linux/amd64, linux/386"
[[ ${rc} -ne 0 && "${out}" == *"--install arm64"* ]]; check "x86 host without arm64 emulation is told to install arm64" $?

# Both platforms available (* marks are tolerated): one multi-arch push.
run HOST_PLATFORMS="linux/amd64*, linux/arm64, linux/386"
[[ ${rc} -eq 0 ]]; check "builds when every platform is available" $?
[[ "${calls}" == *"buildx build --builder vllm-alloy --platform linux/amd64,linux/arm64 -t ${IMG}:v-test -t ${IMG}:latest --push "* ]]
check "one buildx push for both platforms, with :latest" $?
[[ "${out}" == *"linux/amd64"*"linux/arm64"* ]]; check "reports the pushed platforms" $?

# One platform only, e.g. no emulation wanted.
run HOST_PLATFORMS="linux/arm64" PLATFORMS=linux/arm64
[[ ${rc} -eq 0 && "${calls}" == *"--platform linux/arm64 "* ]]; check "PLATFORMS narrows the build" $?

run HOST_PLATFORMS="linux/amd64, linux/arm64" PUSH_LATEST=0
[[ ${rc} -eq 0 && "${calls}" != *":latest"* ]]; check "PUSH_LATEST=0 skips :latest" $?

run HOST_PLATFORMS="linux/amd64, linux/arm64" BUILDER_EXISTS=0
[[ "${calls}" == *"buildx create --name vllm-alloy --driver docker-container"* ]]
check "creates the builder when it is missing" $?

# A platform name that is a prefix of a supported one must not match.
run HOST_PLATFORMS="linux/arm64/v8" PLATFORMS=linux/arm64
[[ ${rc} -ne 0 ]]; check "platform match is exact, not a prefix" $?

# Immutability guard still runs first.
run HOST_PLATFORMS="linux/amd64, linux/arm64" TAG_EXISTS=1
[[ ${rc} -ne 0 && "${calls}" != *"buildx"* && "${out}" == *"already exists"* ]]
check "an existing tag is refused before any build" $?

# A default on TARGETARCH overrides BuildKit's value: the arm64 half of the
# image would install the amd64 Alloy binary and fail with "Exec format error".
grep -qxE 'ARG TARGETARCH' "${ROOT}/Dockerfile" && ! grep -qE '^ARG TARGETARCH=' "${ROOT}/Dockerfile"
check "Dockerfile declares TARGETARCH without a default" $?
! grep -nE 'alloy-linux-(amd64|arm64)' "${ROOT}/Dockerfile" | grep -v '^[0-9]*:#' | grep -q .
check "Dockerfile hard-codes no architecture" $?

exit "${failures}"
