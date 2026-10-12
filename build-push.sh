#!/usr/bin/env bash
# build-push.sh — local build + push of the public vLLM+Alloy image.
#
# This is the PRIMARY publish path. CI-on-tag is impractical here because the
# image builds on top of the multi-GB vllm/vllm-openai base, which overruns a
# hosted shared runner's disk (this was true of GitLab SaaS and GitHub-hosted
# runners start from a comparable ~14GB). The image changes rarely, so a
# deliberate local build+push is the simplest reliable option.
#
# Usage:
#   ./build-push.sh                          # build+push the default tag below
#   ./build-push.sh v0.11.0-alloy1.16.2-2    # build+push a specific tag
#   TAG=v0.11.0-alloy1.16.2-2 ./build-push.sh  # same, via env
#   PUSH_LATEST=0 ./build-push.sh            # skip updating the :latest pointer
#   FORCE=1 ./build-push.sh <existing-tag>   # override the immutability guard
#   PLATFORMS=linux/amd64 ./build-push.sh    # build only some platforms
#
# PLATFORMS: the image is multi-arch by default (linux/amd64 + linux/arm64, the
# two platforms the vllm/vllm-openai base ships), pushed as ONE tag so each host
# pulls its own architecture. It builds from an x86_64 or an ARM host alike:
# the host's own platform builds natively and the other needs QEMU emulation
# (the script checks before building and says how to enable it).
#
# IMMUTABILITY: never re-push an existing tag — Gcore does not re-pull an
# unchanged tag. Bump the trailing counter (-2, -3, …) on every rebuild and
# update the pinned tag in the webapp (deployment.vllm_alloy_image).
# This script refuses to overwrite a tag that already exists in the registry.
set -euo pipefail

# GitHub Container Registry. The package must be PUBLIC so the customer's Gcore
# Everywhere Inference container can pull it anonymously -- no credentials_name
# on their side. Note that a newly created GHCR package defaults to PRIVATE even
# when its source repository is public: after the very first push, set it to
# public once under
# https://github.com/orgs/infratailors/packages -> vllm-alloy -> Package settings.
# Skip that and the pull fails with a 403 that reads like "image not found".
REGISTRY_IMAGE="ghcr.io/infratailors/vllm-alloy"

# Versions pinned in the Dockerfile — keep these in sync with it (FROM line and
# the ALLOY_VERSION arg). They form the default tag.
VLLM_VERSION="0.11.0"
ALLOY_VERSION="1.16.2"
DEFAULT_TAG="v${VLLM_VERSION}-alloy${ALLOY_VERSION}-1"

# Tag precedence: 1st CLI arg > $TAG > derived default.
TAG="${1:-${TAG:-$DEFAULT_TAG}}"
IMAGE="${REGISTRY_IMAGE}:${TAG}"
PUSH_LATEST="${PUSH_LATEST:-1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Immutability guard ------------------------------------------------------
# A public project's registry is anonymously readable, so this manifest check
# works without write creds. Refuse to clobber an existing immutable tag.
if docker manifest inspect "${IMAGE}" >/dev/null 2>&1; then
  if [ "${FORCE:-0}" != "1" ]; then
    echo "ERROR: ${IMAGE} already exists in the registry." >&2
    echo "Tags are immutable — bump the counter (e.g. ${DEFAULT_TAG%-*}-2) instead." >&2
    echo "(Set FORCE=1 to overwrite, but Gcore will NOT re-pull an unchanged tag.)" >&2
    exit 1
  fi
  echo "WARNING: ${IMAGE} exists; FORCE=1 set — overwriting." >&2
fi

# --- Builder -----------------------------------------------------------------
# A multi-platform push needs a BuildKit builder with the docker-container
# driver; Docker's default builder can only build the host's own platform.
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER="${BUILDER:-vllm-alloy}"
if ! docker buildx inspect "${BUILDER}" >/dev/null 2>&1; then
  echo "Creating buildx builder ${BUILDER}"
  docker buildx create --name "${BUILDER}" --driver docker-container >/dev/null
fi

# Fail fast if the builder cannot run a requested platform. Without this, a
# foreign platform with no QEMU emulation dies mid-build with
# "exec /bin/bash: exec format error".
# "Platforms:" lists e.g. "linux/arm64, linux/amd64*" (* = set by the user).
supported="$(docker buildx inspect --bootstrap "${BUILDER}" | sed -n 's/^Platforms:[[:space:]]*//p')"
supported="${supported//\*/}"
missing=()
IFS=',' read -ra wanted <<< "${PLATFORMS}"
for platform in "${wanted[@]}"; do
  [[ ",${supported// /}," == *",${platform},"* ]] || missing+=("${platform}")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: builder ${BUILDER} cannot build: ${missing[*]} (it supports: ${supported})." >&2
  echo "Enable QEMU emulation for the missing architecture(s), then recreate the builder:" >&2
  for platform in "${missing[@]}"; do
    echo "  docker run --privileged --rm tonistiigi/binfmt --install ${platform#linux/}" >&2
  done
  echo "  docker buildx rm ${BUILDER}" >&2
  echo "Or build only what this host can: PLATFORMS=<platforms> ./build-push.sh" >&2
  exit 1
fi

# --- Build + push --------------------------------------------------------------
# Requires a ghcr.io login with the write:packages scope:
#   echo "$GITHUB_PAT" | docker login ghcr.io -u <github-username> --password-stdin
# A classic PAT with write:packages works; so does a fine-grained token with
# read+write on this repository's packages. buildx pushes straight from the
# builder: a multi-platform image cannot be loaded into the local image store.
tags=(-t "${IMAGE}")
if [ "${PUSH_LATEST}" = "1" ]; then
  tags+=(-t "${REGISTRY_IMAGE}:latest")
fi
echo "Building and pushing ${IMAGE} for ${PLATFORMS}"
echo "  context: ${SCRIPT_DIR}"
docker buildx build --builder "${BUILDER}" --platform "${PLATFORMS}" \
  "${tags[@]}" --push "${SCRIPT_DIR}"

echo
echo "Pushed platforms:"
docker buildx imagetools inspect "${IMAGE}" | sed -n 's/^ *Platform: */  /p'
echo
echo "Done: ${IMAGE}"
echo "Verify anonymous pull (package must be public -- see the note at the top):"
echo "  docker pull ${IMAGE}"
echo
echo "Then pin this exact tag in the webapp: deployment.vllm_alloy_image"
echo "A public image needs no Gcore registry credentials; a private one needs a"
echo "registry_credentials object referenced via credentials_name in terraform.tfvars."
