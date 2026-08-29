# vllm-alloy

A **public, model-agnostic** container image bundling [vLLM](https://github.com/vllm-project/vllm)
(OpenAI-compatible model server) with [Grafana Alloy](https://grafana.com/docs/alloy/)
and a small NVML→DCGM GPU metrics exporter, in a single container.

It exists for **Gcore Everywhere Inference**, which runs a managed container
with no SSH / sidecar / node access — so observability must live *inside* the
image rather than on a host VM. vLLM, Alloy, and the GPU exporter run together
under `tini`; vLLM is the health-determining process (if it dies, the container
exits with vLLM's code so Gcore restarts/marks it unhealthy).

The image is **model-agnostic**: the model and all runtime parameters are passed
as environment variables at deploy time, so a single published image serves
every model. There is **no `command` override** — the entrypoint composes the
vLLM CLI entirely from the envs below.

## Image path

```
ghcr.io/infratailors/vllm-alloy:<tag>
```

The package is public, so Gcore (and anyone) can pull it anonymously — no
registry credentials required.

> GHCR package visibility is **independent of repository visibility**, and a
> newly created package defaults to private even in a public repo. After the
> first push, set it to public once under
> [Packages → vllm-alloy → Package settings](https://github.com/orgs/infratailors/packages).
> Until then an anonymous pull fails with a 403 that reads like a missing image.

## Environment contract

### vLLM runtime

| Env | Default | Purpose |
|-----|---------|---------|
| `MODEL_NAME` | `bigcode/starcoder2-3b` | HuggingFace model id served by vLLM |
| `VLLM_TASK` | `generate` | vLLM `--task` (e.g. `generate`, `embed`) |
| `MAX_MODEL_LEN` | `16384` | vLLM `--max-model-len` |
| `GPU_MEM_UTIL` | `0.90` | vLLM `--gpu-memory-utilization` |
| `DTYPE` | `auto` | vLLM `--dtype` (e.g. `bfloat16` for quirks) |
| `EXTRA_VLLM_ARGS` | _(empty)_ | Space-separated extra CLI flags appended verbatim (e.g. `--enforce-eager`) |
| `LISTEN_PORT` | `8000` | Port vLLM binds; also the container's service port |
| `HUGGING_FACE_HUB_TOKEN` | _(unset)_ | HF token for gated/private models (read by vLLM) |

`DTYPE` and `EXTRA_VLLM_ARGS` are the only channel for per-architecture quirks
(e.g. `--dtype bfloat16`, Turing sampler flags) because `command` is omitted.

### Observability (Alloy remote-write)

| Env | Default | Purpose |
|-----|---------|---------|
| `ALLOY_REMOTE_WRITE_URL` | `https://grafana.dev.infratailors.ai/api/v1/write` | Prometheus remote-write endpoint |
| `ALLOY_API_KEY` | _(unset)_ | Bearer token for remote-write auth |
| `DEPLOYMENT_ID` | _(unset)_ | Series label: deployment identity |
| `USER_ID` | _(unset)_ | Series label: owning user |
| `PROJECT_ID` | _(unset)_ | Series label: webapp tenant/project id |
| `MODEL_NAME` | `bigcode/starcoder2-3b` | Series label: model name |
| `CLOUD_PROVIDER` | `gcore` | Series label: provider |
| `INSTANCE_TYPE` | _(unset)_ | Series label: instance/flavor |

Alloy scrapes vLLM's `/metrics` (TTFT, inter-token latency, throughput,
KV-cache usage, …) and the local GPU exporter's `DCGM_FI_DEV_*` metrics
(utilization, VRAM, power, temperature) every 15s, tags every series with the
labels above, and remote-writes to InfraTailors Grafana.

## Running locally

```bash
docker run --gpus all -p 8000:8000 \
  -e MODEL_NAME=bigcode/starcoder2-3b \
  -e MAX_MODEL_LEN=16384 \
  -e ALLOY_REMOTE_WRITE_URL=https://grafana.dev.infratailors.ai/api/v1/write \
  -e ALLOY_API_KEY=<token> \
  -e DEPLOYMENT_ID=local -e USER_ID=me -e PROJECT_ID=test \
  ghcr.io/infratailors/vllm-alloy:<tag>
```

## Building / publishing

`./build-push.sh` is the only publish path. There is deliberately no CI build:
the image sits on the multi-GB `vllm/vllm-openai` base and overruns a hosted
shared runner's disk, and it changes rarely enough that a deliberate local
build+push is simpler and more reliable.

```bash
echo "$GITHUB_PAT" | docker login ghcr.io -u <github-username> --password-stdin
./build-push.sh                        # default tag, derived from the pinned versions
./build-push.sh v0.11.0-alloy1.16.2-2  # or an explicit one
```

Tags are immutable by convention and the script refuses to overwrite one: Gcore
does not re-pull an unchanged tag, so bump the trailing counter on every rebuild
and update `deployment.gcore_vllm_alloy_image` in the webapp.

**Tag immutability:** never re-push the same tag — Gcore does not re-pull an
unchanged tag. Bump the trailing counter on every rebuild and update the pinned
tag in the webapp (`deployment.gcore_vllm_alloy_image`) deliberately.
