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
# Build + push (multi-arch, linux/amd64 + linux/arm64): ./build-push.sh <tag>
# Local single-platform build: docker build --platform linux/arm64 -t <name> .
FROM vllm/vllm-openai:v0.11.0

# Pin Alloy; the alloy-linux-<arch> zip asset naming is stable across 1.x.
ARG ALLOY_VERSION=1.16.2
# Set by BuildKit to the platform being built (amd64 / arm64). No default: a
# default here overrides BuildKit's value, so an arm64 build would install the
# amd64 Alloy binary. Requires BuildKit (Docker's default builder since 23.0).
ARG TARGETARCH

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
COPY entrypoint.sh egress_preflight.sh /usr/local/bin/
COPY gpu_exporter.py /usr/local/bin/gpu_exporter.py
# pynvml (nvidia-ml-py) ships with vLLM, but pin it so the GPU exporter never
# breaks if the base image drops it. No GPU needed at build time.
RUN pip install --no-cache-dir nvidia-ml-py && \
    chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/gpu_exporter.py

EXPOSE 8000

# tini as PID 1: clean signal forwarding (-g = to the whole process group) and
# zombie reaping for the backgrounded Alloy process.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]
