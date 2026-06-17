# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A single **public, model-agnostic** Docker image bundling vLLM (OpenAI-compatible
model server) + Grafana Alloy + a small NVML→DCGM GPU metrics exporter in one
container. It exists for **Gcore Everywhere Inference**, a managed-container
platform with no SSH / sidecar / node access — so observability must live *inside*
the image. There is no application source tree; the repo is a Docker build context.

Image path: `registry.gitlab.com/uniluxembourg/snt/sedan/infratailors.ai/vllm-alloy/vllm-alloy:<tag>`

## Build & release

- **CI publishes on git tags only** (`.gitlab-ci.yml`): the git tag name becomes
  the image tag, built+pushed via the project's own CI job token (no cross-project
  deploy token). `latest` is also pushed but is mutable — never reference it from
  the webapp.
  ```bash
  git tag -a v0.11.0-alloy1.16.2-2 -m "rebuild"
  git push origin v0.11.0-alloy1.16.2-2
  ```
- **Local/manual build:** `./build-push.sh` (override target with `IMAGE=...`).
- **Tag immutability is a hard rule:** never re-push an existing tag — Gcore does
  not re-pull an unchanged tag. Bump the trailing counter (`-2`, `-3`, …) on every
  rebuild and update the pinned tag in the webapp config
  (`deployment.gcore_vllm_alloy_image`) deliberately.

## Architecture (spans multiple files)

One container runs three processes under `tini` (PID 1, `-g` forwards signals to
the whole group and reaps zombies):

- **vLLM** — the only health-determining process. `entrypoint.sh` `wait -n`s on
  vLLM and Alloy; if vLLM exits the container exits with vLLM's real code, if Alloy
  dies first the container exits non-zero to force a restart. The GPU exporter is
  deliberately excluded from the wait set (best-effort, must never take the
  container down).
- **Grafana Alloy** (`alloy/config.alloy`, River syntax) — scrapes vLLM's
  `localhost:8000/metrics` and the GPU exporter's `localhost:9400/metrics` every
  15s and remote-writes to InfraTailors Grafana, tagging every series with
  deployment-identity labels read from env vars (`sys.env(...)` + `coalesce` default).
- **`gpu_exporter.py`** — minimal NVML→Prometheus exporter on `127.0.0.1:9400`. It
  emits the *exact* `DCGM_FI_DEV_*` metric names the existing Grafana panels query,
  so the standard NVIDIA `dcgm-exporter` (which needs `CAP_SYS_ADMIN`, denied here)
  isn't required. Returns 500 if NVML is blocked; never crashes the container.

### Model-agnostic env contract — the central design rule
There is **no `command` override**: `entrypoint.sh` composes the entire vLLM CLI
from env vars, so one published image serves every model. When changing how vLLM
is launched, the env vars are the only interface. Critically, `DTYPE` (→`--dtype`)
and `EXTRA_VLLM_ARGS` (space-split, appended verbatim) are the **only** channel for
per-architecture quirks (e.g. `--dtype bfloat16`, Turing sampler flags) — do not
remove them. See README.md for the full env table (runtime + observability labels).

## Coordination with the webapp

This image is consumed by the separate webapp repo, which pins one immutable tag in
`deployment.gcore_vllm_alloy_image` and injects the env contract at deploy time. The
env var names here (`MODEL_NAME`, `VLLM_TASK`, `MAX_MODEL_LEN`, `GPU_MEM_UTIL`,
`DTYPE`, `EXTRA_VLLM_ARGS`, `ALLOY_*`, `DEPLOYMENT_ID`, `USER_ID`, `PROJECT_ID`,
`CLOUD_PROVIDER`, `INSTANCE_TYPE`) are a contract with that webapp — renaming one is
a breaking change on the deployment side.
