# syntax=docker/dockerfile:1
#
# vastai-gb10-vllm-tailscale: vLLM + LiteLLM + Tailscale for a rented NVIDIA GB10 (DGX Spark,
# sm_121, arm64) on vast.ai. Published as ghcr.io/surejaj/vastai-gb10-vllm-tailscale.
# No secrets are baked in: TS_AUTHKEY / HF_TOKEN arrive as env vars at run time.
#
# Base: upstream vLLM v0.30.0 (CUDA 13.0 is the default build), arm64 image.
# Evidence (fetched 2026-09-29):
#  - v0.30.0 release notes list GB10 / SM121 work: "SM12x blockwise FP8 CTA
#    raster swizzle for GB10/DGX Spark", "W4A4 NVFP4 preferred on SM120/121",
#    "B12X causal paged attention for SM120/SM121", and publish
#    vllm/vllm-openai:v0.30.0 (CUDA 13.0) https://github.com/vllm-project/vllm/releases/tag/v0.30.0
#  - the arm64 image and digest come from Docker Hub
#    https://hub.docker.com/v2/repositories/vllm/vllm-openai/tags?name=v0.30.0-aarch64
#  - CUDA 13.0 runs on the Spark's stock driver; the NGC nvcr.io/nvidia/vllm
#    26.04+ images need CUDA forward-compat / driver >= 595.58 there
#    https://forums.developer.nvidia.com/t/vllm-release-26-04/368935
#    (NGC 26.08 notes do not mention GB10/sm_121: rel-26-08.html), so NGC was
#    not chosen.
# Verify before the first build (digest of the arm64 image):
#   docker buildx imagetools inspect vllm/vllm-openai:v0.30.0-aarch64
FROM --platform=linux/arm64 vllm/vllm-openai:v0.30.0-aarch64@sha256:4864d46625cbc3307623e29ac742030655e27249feba7b97ec925ce4cc4dfb56

ARG TS_VERSION=1.102.4
ARG LITELLM_VERSION=1.103.1

# The base image's ENTRYPOINT is `vllm serve`; vast.ai's ssh launch mode
# replaces it anyway, and our supervisor is started from the onstart script.
ENTRYPOINT []
CMD ["/bin/bash"]

USER root
# curl, jq, flock (util-linux), pgrep (procps), venv for LiteLLM.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl jq util-linux procps python3-venv \
 && rm -rf /var/lib/apt/lists/*

# Static Tailscale (arm64), pinned. tailscaled runs in userspace mode.
RUN curl -fsSL "https://pkgs.tailscale.com/stable/tailscale_${TS_VERSION}_arm64.tgz" \
    | tar -xz -C /usr/local/bin --strip-components=1 \
        "tailscale_${TS_VERSION}_arm64/tailscale" "tailscale_${TS_VERSION}_arm64/tailscaled" \
 && tailscale version

# LiteLLM in its own venv so its pins cannot disturb vLLM's torch/openai stack.
RUN python3 -m venv /opt/litellm \
 && /opt/litellm/bin/pip install --no-cache-dir "litellm[proxy]==${LITELLM_VERSION}"

COPY start-gb10.sh /opt/gb10/start-gb10.sh
RUN chmod 0755 /opt/gb10/start-gb10.sh
