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
#
# IMMUTABILITY: never re-push an existing tag — Gcore does not re-pull an
# unchanged tag. Bump the trailing counter (-2, -3, …) on every rebuild and
# update the pinned tag in the webapp (deployment.gcore_vllm_alloy_image).
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

# --- Build (amd64-only: vLLM base + Alloy asset are x86) ----------------------
echo "Building ${IMAGE}"
echo "  context: ${SCRIPT_DIR}"
docker build --platform linux/amd64 -t "${IMAGE}" "${SCRIPT_DIR}"

# --- Push --------------------------------------------------------------------
# Requires a ghcr.io login with the write:packages scope:
#   echo "$GITHUB_PAT" | docker login ghcr.io -u <github-username> --password-stdin
# A classic PAT with write:packages works; so does a fine-grained token with
# read+write on this repository's packages.
echo "Pushing ${IMAGE}"
docker push "${IMAGE}"

if [ "${PUSH_LATEST}" = "1" ]; then
  echo "Updating mutable pointer ${REGISTRY_IMAGE}:latest"
  docker tag "${IMAGE}" "${REGISTRY_IMAGE}:latest"
  docker push "${REGISTRY_IMAGE}:latest"
fi

echo
echo "Done: ${IMAGE}"
echo "Verify anonymous pull (package must be public -- see the note at the top):"
echo "  docker pull ${IMAGE}"
echo
echo "Then pin this exact tag in the webapp: deployment.gcore_vllm_alloy_image"
echo "A public image needs no Gcore registry credentials; a private one needs a"
echo "registry_credentials object referenced via credentials_name in terraform.tfvars."
