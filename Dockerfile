# vLLM (model server) + Grafana Alloy in one image, for Gcore Everywhere
# Inference.
#
# Gcore Everywhere Inference runs a managed container (no SSH / sidecar / node
# access), so observability must live INSIDE the image. We run vLLM AND Alloy
# (plus a small NVML->DCGM GPU exporter) in one container under tini; vLLM is
# the health-determining process.
#
# This image is MODEL-AGNOSTIC: the model, task, sequence length, and dtype are
# all supplied via environment variables at deploy time (see entrypoint.sh), so
# a single published image serves every model. See README.md for the full env
# contract.
#
# Build:
#   docker build -t registry.gitlab.com/uniluxembourg/snt/sedan/infratailors.ai/vllm-alloy/vllm-alloy:<tag> .
# Push:
#   docker push  registry.gitlab.com/uniluxembourg/snt/sedan/infratailors.ai/vllm-alloy/vllm-alloy:<tag>
FROM vllm/vllm-openai:v0.11.0

# Pin Alloy; the linux-amd64 zip asset naming is stable across the 1.x line.
ARG ALLOY_VERSION=1.16.2
ARG TARGETARCH=amd64

USER root
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates unzip tini curl; \
    curl -fsSL -o /tmp/alloy.zip \
      "https://github.com/grafana/alloy/releases/download/v${ALLOY_VERSION}/alloy-linux-${TARGETARCH}.zip"; \
    unzip /tmp/alloy.zip -d /tmp/alloy-extract; \
    install -m 0755 "/tmp/alloy-extract/alloy-linux-${TARGETARCH}" /usr/local/bin/alloy; \
    mkdir -p /etc/alloy /var/lib/alloy/data; \
    apt-get purge -y unzip; apt-get autoremove -y; \
    rm -rf /tmp/alloy.zip /tmp/alloy-extract /var/lib/apt/lists/*; \
    alloy --version

COPY alloy/config.alloy /etc/alloy/config.alloy
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY gpu_exporter.py /usr/local/bin/gpu_exporter.py
# pynvml (nvidia-ml-py) ships with vLLM, but pin it so the GPU exporter never
# breaks if the base image drops it. No GPU needed at build time.
RUN pip install --no-cache-dir nvidia-ml-py && \
    chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/gpu_exporter.py

EXPOSE 8000

# tini as PID 1: clean signal forwarding (-g = to the whole process group) and
# zombie reaping for the backgrounded Alloy process.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]
