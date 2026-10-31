# syntax=docker/dockerfile:1
#
# vastai-gb10-vllm-tailscale: vLLM + LiteLLM + Tailscale for a rented NVIDIA GB10 (DGX Spark,
# sm_121, arm64) on vast.ai. Published as ghcr.io/surejaj/vastai-gb10-vllm-tailscale.
# No secrets are baked in: TS_AUTHKEY / HF_TOKEN arrive as env vars at run time.
#
# Base: upstream vLLM v0.32.0 (CUDA 13.0 is the default build), arm64 image.
# Matches the live GB10 (pip vLLM 0.32.0, torch 2.13.0, FlashInfer 0.7.0.post1)
# that start-gb10.sh's default nvidia/Qwen3.8-27B-NVFP4 runs on.
# Evidence (fetched 2026-10-30):
#  - Docker Hub: vllm/vllm-openai:v0.32.0-aarch64 is linux/arm64, pushed
#    2026-10-18, CUDA_VERSION=13.0.2, built from commit 5df63a7 (= git tag v0.32.0)
#    https://hub.docker.com/v2/repositories/vllm/vllm-openai/tags?name=v0.32.0-aarch64
#  - v0.32.0 requirements/cuda.txt pins torch==2.13.0, flashinfer-python==0.7.0.post1
#    https://github.com/vllm-project/vllm/blob/v0.32.0/requirements/cuda.txt
#  - the upstream image already runs `flashinfer download-kernels`
#    https://github.com/vllm-project/vllm/blob/v0.32.0/docker/Dockerfile
#    and that layer holds flashinfer-cubin 0.7.0.post1 and flashinfer-jit-cache
#    (+ per-arch -sm121a etc.) 0.7.0.post1+cu130, so no kernel install here.
#    Never install flashinfer-jit-cache from PyPI (squatted); the real wheels are on
#    https://flashinfer.ai/whl/flashinfer-cubin/ and https://flashinfer.ai/whl/cu130/flashinfer-jit-cache/
#  - earlier base v0.30.0 notes list the GB10 / SM121 work (SM12x FP8 swizzle,
#    W4A4 NVFP4 on SM120/121, B12X attention)
#    https://github.com/vllm-project/vllm/releases/tag/v0.30.0
#  - CUDA 13.0 runs on the Spark's stock driver; the NGC nvcr.io/nvidia/vllm
#    26.04+ images need CUDA forward-compat / driver >= 595.58 there
#    https://forums.developer.nvidia.com/t/vllm-release-26-04/368935
#    (NGC 26.08 notes do not mention GB10/sm_121: rel-26-08.html), so NGC was
#    not chosen.
# Verify before the first build (digest of the arm64 image):
#   docker buildx imagetools inspect vllm/vllm-openai:v0.32.0-aarch64
FROM --platform=linux/arm64 vllm/vllm-openai:v0.32.0-aarch64@sha256:6ff5ff0ddf3658d2c2d677dac5ca2d4726ce0156b4371166d918181b210bd4bc

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

# Fail the build if the base's vLLM / FlashInfer stack drifts from what the GB10
# runs (vLLM 0.32.0; flashinfer-python, -cubin, -jit-cache, -jit-cache-sm121a
# all 0.7.0.post1). Reads package metadata only, so no GPU is needed here.
RUN python3 - <<'PY'
from importlib.metadata import version
want = {
    "vllm": "0.32.0",
    "flashinfer-python": "0.7.0.post1",
    "flashinfer-cubin": "0.7.0.post1",
    "flashinfer-jit-cache": "0.7.0.post1+cu130",
    "flashinfer-jit-cache-sm121a": "0.7.0.post1+cu130",
}
got = {p: version(p) for p in want}
print(got)
bad = {p: (got[p], v) for p, v in want.items() if got[p] != v}
if bad:
    raise SystemExit(f"version mismatch (got, want): {bad}")
PY

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
