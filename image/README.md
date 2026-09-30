# vastai-gb10-vllm-tailscale image

Image for the rented NVIDIA GB10 (DGX Spark, arm64, sm_121) on vast.ai:
vLLM (one server per model) + LiteLLM + Tailscale. Published as
`ghcr.io/surejaj/vastai-gb10-vllm-tailscale`, built by GitHub Actions in this
repo (`surejaj/vastai-gb10-vllm-tailscale`) with `image/` as the build context.

| File | Purpose |
|---|---|
| `Dockerfile` | arm64 only. Base `vllm/vllm-openai:v0.30.0-aarch64` pinned by digest, plus static Tailscale 1.102.4, `litellm[proxy]==1.103.1` (own venv), curl, jq, flock |
| `start-gb10.sh` | supervisor at `/opt/gb10/start-gb10.sh`: tailscale, vLLM one at a time, LiteLLM, `tailscale serve` |
| `../.github/workflows/build-image.yml` | builds and pushes to GHCR on a native arm64 runner |

No secrets are baked in. `TS_AUTHKEY` and `HF_TOKEN` are passed as env vars at
run time by `provision-gb10.py`.

## Publish

Pushing changes under `image/` (or the workflow) to `main` builds the image.
The workflow runs in the Actions tab (also runnable with
"Run workflow"). Runner: `ubuntu-24.04-arm` (native arm64, free for public
repos). The job frees disk first because the vLLM base is 15-20 GB. Tags:
`latest` (main), `sha-<short>` (every push), semver on `v*` tags
(`git tag v0.1.0 && git push origin v0.1.0`). The last step prints the pushed
digest (also in the job summary).

## Make the package public (once, after the first push)

vast.ai pulls without registry credentials, so the package must be public:
GitHub -> your profile -> Packages -> `vastai-gb10-vllm-tailscale` -> Package settings ->
Danger Zone -> Change visibility -> Public. If the package is not linked to the
repo automatically, link it under "Connect repository". Safe because the image
contains no secrets.

## Pin by digest

```bash
./provision-gb10.py create --offer-id N \
  --image ghcr.io/surejaj/vastai-gb10-vllm-tailscale@sha256:<digest from the workflow summary>
```

`latest` is convenient but moves; pin the digest once a build is verified on a
real GB10.

## Before the first build

- Confirm the base digest: `docker buildx imagetools inspect
  vllm/vllm-openai:v0.30.0-aarch64` should match the `@sha256:` in the
  Dockerfile (taken from the Docker Hub API on 2026-09-29).
- Why this base: see the comment block at the top of the Dockerfile.

## Optional: build locally (Apple Silicon)

```bash
docker build --platform linux/arm64 -t ghcr.io/surejaj/vastai-gb10-vllm-tailscale:dev image/
```

Not needed when using the workflow. Expect a large pull of the base image.
