#!/usr/bin/env bash
# build-push.sh — local/manual build + push of the vLLM+Alloy image.
#
# CI normally publishes this image on git tags (see .gitlab-ci.yml); use this
# script only for a manual build (e.g. a private fork to your own registry).
#
# IMPORTANT: never re-push the SAME tag — Gcore does not re-pull an unchanged
# tag. Bump the tag on every rebuild (append -2, -3, ... or a git SHA).
set -euo pipefail

# Where to push. Override via the IMAGE env var or edit this default.
IMAGE="${IMAGE:-registry.gitlab.com/uniluxembourg/snt/sedan/infratailors.ai/vllm-alloy/vllm-alloy:0.11.0-custom}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Building ${IMAGE} from ${SCRIPT_DIR} ..."
docker build -t "${IMAGE}" "${SCRIPT_DIR}"

echo "Pushing ${IMAGE} ..."
docker push "${IMAGE}"

echo
echo "Done: ${IMAGE}"
echo "A public image needs no Gcore registry credentials; a private one needs a"
echo "registry_credentials object referenced via credentials_name in terraform.tfvars."
