# Gcore vLLM+Alloy image — publish & wire-up (RESUME HANDOFF)

> Self-contained handoff so this can be resumed on another machine. Captures
> what's already committed, the decisions made, and the remaining work.

## Status / what's already done

- **Branch `feature/new-gcore-templates`, commit `d4a3193` (webapp) — COMMITTED, NOT PUSHED.**
  Replaced Gcore deployment generation with observability-enabled Everywhere
  Inference templates; removed the Gcore Cloud-VM path; vendored a vLLM+Alloy
  Docker build context into the webapp gcore-inference template; added a config
  key `deployment.gcore_vllm_alloy_image`. All recommender unit tests pass (336),
  gcore unit tests pass (35), gcore integration route tests pass.
- **`../vllm-alloy` repo created (empty, only `.git`).** Remote:
  `git@gitlab.com:uniluxembourg/snt/sedan/infratailors.ai/vllm-alloy.git`.
- ⚠️ **To resume elsewhere, push BOTH:** the webapp branch
  `feature/new-gcore-templates` (has unpushed commit `d4a3193`) and this
  `vllm-alloy` repo.

## Decisions locked in

1. **vllm-alloy is Gcore-specific.** VM providers (AWS/GCP/Azure/OVH/Scaleway)
   keep the stock `vllm/vllm-openai` image + host-side Grafana Alloy + the
   official NVIDIA dcgm-exporter (installed by their `startup.sh`). Only Gcore
   Everywhere Inference (managed container, no host) needs Alloy baked into the
   image. No code change needed for this — webapp adapter already overrides
   `vllm_image` only when `provider == "gcore"`.
2. **Publish to a dedicated PUBLIC GitLab project** (guaranteed anonymous pull;
   Gcore pulls with no credentials). Final image path base:
   `registry.gitlab.com/uniluxembourg/snt/sedan/infratailors.ai/vllm-alloy/vllm-alloy`
3. The build context / Dockerfile / CI should live **in the `vllm-alloy` repo**
   (its own CI job token has `write_registry` to its own registry — no
   cross-project token needed).

## Remaining work

### A. Populate `../vllm-alloy` (then commit + push; set project Public in GitLab UI)

Add these **plain, buildable** files (NOT `.j2`):

- `Dockerfile` — vLLM + Alloy + tini + nvidia-ml-py. Same as
  `../gcore-deployment/docker/Dockerfile`.
- `entrypoint.sh` — **use the webapp EXTENDED version**, which reads `DTYPE` and
  `EXTRA_VLLM_ARGS` envs (the proven `../gcore-deployment/docker/entrypoint.sh`
  does NOT have these; the webapp templates depend on them for quirks). Source
  to copy from (strip nothing): the rendered output of
  `webapp/.../gcore-inference/docker/entrypoint.sh.j2`.
- `alloy/config.alloy` — identical to `../gcore-deployment/docker/alloy/config.alloy`.
- `gpu_exporter.py` — identical to `../gcore-deployment/docker/gpu_exporter.py`
  (PLAIN Python; the webapp copy wraps it in `{% raw %}` for Jinja — do NOT
  include that wrapper here).
- `.gitlab-ci.yml` — build + push to own registry using `$CI_REGISTRY_USER` /
  `$CI_REGISTRY_PASSWORD` (own job token). Tags:
  `v0.11.0-alloy1.16.2-$CI_COMMIT_SHORT_SHA` (immutable, never re-push) + `latest`.
  Use `docker:24` + `docker:24-dind`. Build on changes / on tags.
- `README.md` — what the image is, the model-agnostic env contract
  (`MODEL_NAME`, `VLLM_TASK`, `MAX_MODEL_LEN`, `GPU_MEM_UTIL`, `DTYPE`,
  `EXTRA_VLLM_ARGS`, `ALLOY_REMOTE_WRITE_URL`, `ALLOY_API_KEY`, `DEPLOYMENT_ID`,
  `USER_ID`, `PROJECT_ID`, `CLOUD_PROVIDER`, `INSTANCE_TYPE`,
  `HUGGING_FACE_HUB_TOKEN`), build/run instructions, tag-immutability note.
- (optional) `build-push.sh` for local manual builds.

Tag scheme: CI publishes immutable `…-<sha>` tags. The webapp config default
pins one immutable tag; bump it deliberately when rolling Gcore to a new image.

### B. Resolve webapp duplication (OPEN DECISION — pick one)

The webapp currently vendors `templates/gcore-inference/docker/*.j2` +
`build-push.sh.j2` into the user's downloadable zip (private-fork escape hatch).
Now that `vllm-alloy` owns the canonical context:

- **Option B1 (recommended — remove from webapp):** delete the vendored
  `docker/` + `build-push.sh.j2` from the gcore-inference template; point the
  README escape-hatch at the `vllm-alloy` repo. Also revert the now-unneeded
  bits from commit `d4a3193`: the `docker/` entries in
  `GCORE_INFERENCE_TEMPLATE_FILES`, the `validate_output` `docker/`-skip, and
  the `{% raw %}` handling. Removes drift + the Jinja hack. The byte-identity
  unit test (which compares against `../gcore-deployment/docker`) gets removed.
- **Option B2 (keep copy):** leave the vendored context in the zip; accept two
  copies (webapp + vllm-alloy) that can drift. Lower churn, weaker single-source.

### C. Point webapp at the final image path (regardless of B)

The committed default is a **wrong placeholder**:
`registry.gitlab.com/infratailors/vllm-alloy/vllm-alloy:v0.11.0-alloy1.16.2-1`.
Fix to the real path
`registry.gitlab.com/uniluxembourg/snt/sedan/infratailors.ai/vllm-alloy/vllm-alloy:<published-immutable-tag>`
in:
- `services/recommender/config.production.yml` → `deployment.gcore_vllm_alloy_image`
- `services/recommender/config.development.yml` → same
- `services/recommender/src/infrastructure/deployment/template_adapter.py` →
  `_DEFAULT_GCORE_VLLM_ALLOY_IMAGE`
- (if B2) `templates/gcore-inference/build-push.sh.j2` default `IMAGE`

### D. Tests
- If B1: remove `test_inference_docker_context_renders_verbatim`,
  `test_inference_entrypoint_reads_dtype_and_extra_args`, the
  `docker/*`-present assertions, and the build-push/docker file-list entries
  from `tests/unit/test_template_generation_gcore_inference.py`; keep the
  command-omitted / observability-env / cpu-trigger / provider-version tests.
- Update `test_inference_default_image_is_public_vllm_alloy` to the real path.
- Run: `cd services/recommender && PYTHONPATH=. ENVIRONMENT=test
  ../../test_env/bin/python -m pytest tests/unit -q` (test_env has respx).

## Verification
1. After first vllm-alloy CI run + project set Public: from a logged-out
   machine, `docker pull registry.gitlab.com/uniluxembourg/snt/sedan/infratailors.ai/vllm-alloy/vllm-alloy:<tag>`
   must succeed anonymously.
2. Render a gcore-inference package; assert `vllm_image` = published ref and
   `validate_output` PASS.
3. gcore unit tests pass.

## Key technical notes (don't lose these)
- entrypoint MUST keep the `DTYPE` / `EXTRA_VLLM_ARGS` extension (webapp
  `main.tf.j2` injects `DTYPE` env and an `EXTRA_VLLM_ARGS` string for quirks;
  omitting `command` means these envs are the only channel for dtype/CLI quirks).
- `gpu_exporter.py` has Python f-strings `{{{lbl}}}` — plain in vllm-alloy
  (no Jinja there); the webapp `.j2` copy wraps it in `{% raw %}`.
- vllm-alloy CI uses its OWN job token (write_registry to its own project) — no
  cross-project deploy token needed.
- Test venv: `webapp/test_env` (has httpx + respx + jinja2). `.venv` lacks httpx.

## Useful paths
- Canonical proven source: `../gcore-deployment/docker/`
- Webapp vendored copies: `webapp/services/recommender/src/infrastructure/deployment/templates/gcore-inference/docker/` + `build-push.sh.j2`
- Webapp adapter override: `template_adapter.py` `_DEFAULT_GCORE_VLLM_ALLOY_IMAGE` + the `provider == "gcore"` block
- Webapp config key: `deployment.gcore_vllm_alloy_image` (production + development yml)
- New repo: `../vllm-alloy` (remote `…/infratailors.ai/vllm-alloy.git`)
