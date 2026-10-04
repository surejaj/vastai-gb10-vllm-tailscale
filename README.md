# `vastai-ts-proxy` — egress proxy to a vast.ai GB10 over Tailscale

Status: **PLAN — not yet applied.** Nothing here exists on `wolverine` yet.
Host Unraid `wolverine`, tailnet `rattlesnake-pauling.ts.net`, Docker via the
`unraid-remote` context (no SSH).

## 1. Purpose

`gbrain-server`, `gbrain-worker` and `Hermes-Agent` need an LLM/embedding
backend on a rented NVIDIA GB10 (vast.ai). The GB10 runs **vLLM** (one server per model) behind
**LiteLLM** (OpenAI-compatible `/v1`, routes by alias) on one port and joins the
tailnet. The image is built from `image/` (section 13).
The GB10 is an untrusted host, so the clients never join the tailnet
themselves. One small proxy container does, on a locked-down tag.

## 2. Architecture

```
 gbrain-server ─┐
 gbrain-worker ─┼─ vastai-access (docker, --internal) ─► vastai-ts-proxy :8080
 Hermes-Agent  ─┘                                          │  (also on infisical-access:
                                                           │   egress + Infisical)
                                       tailscale userspace │  tag:vastai-client
                                                           ▼
                                        gb10-vast (tag:vastai-gb10) :8080  LiteLLM -> vLLM x4
```

- `vastai-access` is `--internal`: no route out, only the proxy and its three
  clients are on it.
- The proxy is modelled on `gbrain-runpod-proxy`: `busybox nc -lk -e tailscale nc`
  in userspace mode (`TS_USERSPACE=true`, `--shields-up`). Egress and Infisical
  access come from `infisical-access`.
- Clients use `http://vastai-ts-proxy:8080/v1`.
- On the GB10, LiteLLM listens on **127.0.0.1:8080 only** and each vLLM on
  127.0.0.1:8001.. (nothing on an external or tailnet interface).
  `tailscale serve --bg --tcp=8080 tcp://127.0.0.1:8080` is the only way in from
  the tailnet, so the supervisor treats it as required and exits 1 if it fails.
  LiteLLM runs with **no master key**: access control is the tailnet ACL
  (section 5) plus the loopback bind. Clients call model **aliases** (section 7).

## 3. Files

| File | Purpose |
|---|---|
| `deploy-vastai-proxy.sh [--dry-run] [--offer-id N [--max-price X]] [--skip-provision]` | idempotent deploy; final step provisions the GB10 (section 12) |
| `undeploy-vastai-proxy.sh [--purge] [--destroy-gb10] [--dry-run]` | disconnect clients, remove container + network; state dir kept unless `--purge`; `--destroy-gb10` also destroys the vast.ai instance |
| `provision-gb10.py` | search / rent / status / destroy the GB10 on vast.ai (section 12) |
| `requirements.txt` | `vastai-sdk`, for `provision-gb10.py` |
| `image/` | Dockerfile, `start-gb10.sh`, GitHub Actions workflow for the GB10 image (section 13) |

`--dry-run` runs no docker, gpg, infisical or network call; it prints the
planned commands and "would check" lines. Env overrides: `VAST_TS_HOST`
(default `gb10-vast`), `VAST_PORT` (default `8080`), `DOCKER_CONTEXT`
(default `unraid-remote`), `INFISICAL_SECRET_PATH`.

State: `/mnt/main/app-data/vastai-ts-proxy/tailscale` (bind, rw).

## 4. Infisical (assumptions, please check)

- **Runtime volume:** the repo pattern is `infisical/scripts/infisical-runtime.sh`
  with the host-wide `infisical-runtime` volume (mounted ro at `/opt/infisical`).
  `gbrain-infisical-runtime` is gbrain's older private copy (gbrain repo, not
  visible here). This script uses the shared `infisical-runtime` volume and
  refreshes it with `install_infisical_runtime`. If you prefer to mount
  `gbrain-infisical-runtime`, set `INFISICAL_RUNTIME_VOLUME` before running.
- **Bootstrap file:** `infisical.env.gpg` (one runtime identity per
  service, keys per `infisical/scripts/README.md`) must exist. It is not
  created here. To reuse gbrain's identity instead, point `BOOTSTRAP_FILE` at it.
- **Auth key path:** secret `TS_AUTHKEY` at Infisical path `/vastai-tailscale`
  (gbrain's `/tailscale` holds a `tag:gbrain-worker` key, wrong tag). The
  runtime identity needs read access to that path.
- The auth key must be pre-approved and pre-tagged
  `tag:vastai-client`. It is fetched only while state has no
  `_current-profile` (first start).
- One-time client secret is minted only when state is uninitialised.

## 5. Tailscale ACL snippet (not applied)

```jsonc
{
  "tagOwners": {
    "tag:vastai-client": ["autogroup:admin"],
    "tag:vastai-gb10":   ["autogroup:admin"]
  },
  "acls": [
    // the ONLY rules involving these tags
    {"action": "accept", "src": ["tag:vastai-client"], "dst": ["tag:vastai-gb10:8080"]},
    // Tailscale SSH into the GB10 (also needs the ssh rule below)
    {"action": "accept", "src": ["autogroup:member"], "dst": ["tag:vastai-gb10:22"]}
    // tag:vastai-gb10 as src: no rule => no access into the tailnet
  ],
  "ssh": [
    {"action": "check", "src": ["autogroup:member"], "dst": ["tag:vastai-gb10"], "users": ["root"]}
  ]
}
```

- Do not use `--shields-up` on the GB10 (it would block the proxy and SSH); the ACL is what restricts it.
- The GB10 runs `tailscale up --ssh`; `tailscale ssh root@gb10-vast` works once the
  ssh rule is applied. `check` forces a browser re-auth periodically.
- Never put `tag:vastai-gb10` in a `src` (ACL, grant or SSH rule): it must not reach into the tailnet.
- GB10 auth key: **ephemeral, pre-tagged** `tag:vastai-gb10`, single-purpose,
  short expiry. The GB10 hostname must match `VAST_TS_HOST` (`gb10-vast`).
- Leave `--shields-up` on the proxy: nothing may dial in.

## 6. Deploy

```bash
./deploy-vastai-proxy.sh --dry-run   # review
./deploy-vastai-proxy.sh
```

Connections made with `docker network connect` are lost when a client is
recreated. `Hermes-Agent` (Unraid template): add `--network vastai-access` to
Extra Parameters. `gbrain-server` / `gbrain-worker`: add `vastai-access` to
their deploy definitions, or re-run the deploy script.

## 7. Models

Four vLLM servers, one per alias, all on the one GPU. `--gpu-memory-utilization`
is each server's share of the unified memory (total 0.78, about 95 GB of 121 GB;
the rest is the OS, page cache, Tailscale, LiteLLM and the CUDA contexts).

| alias | HF repo | mem share | max_len | notes |
|---|---|---|---|---|
| `main` | `unsloth/Qwen3.8-27B-NVFP4` | 0.38 (~46 GB) | 65536 | fp8 KV, `--reasoning-parser qwen3`, tool calling `qwen3_xml` |
| `worker` | `NVFP4/Qwen3-30B-A3B-Instruct-2507-FP4` | 0.25 (~30 GB) | 32768 | fp8 KV, tool calling `hermes` |
| `vision` | `Qwen/Qwen3-VL-8B-Instruct-FP8` | 0.12 (~15 GB) | 16384 | |
| `embed` | `nomic-ai/nomic-embed-text-v1.5` | 0.03 (~4 GB) | 8192 | `--runner pooling --trust-remote-code`, 768 d |

Repo confidence (checked on Hugging Face 2026-09-29; none was run on a GB10):
- `unsloth/Qwen3.8-27B-NVFP4`: high that it exists (public, 23.4 GB) and that
  vLLM serves it on a Spark, with `--reasoning-parser qwen3 --tool-call-parser
  qwen3_xml --enable-auto-tool-choice`
  (https://forums.developer.nvidia.com/t/qwen3-8-27b-nvfp4-on-a-single-dgx-spark-up-to-1m-context-vllm-mtp-measurements/380244,
  https://huggingface.co/unsloth/Qwen3.8-27B-NVFP4). The NVIDIA forum thread
  "Qwen3.8-27B at 34-38 tok/s ..." uses `RadixArk/Qwen3.8-27B-NVFP4` instead,
  but that is an SGLang setup (https://forums.developer.nvidia.com/t/qwen3-8-27b-at-34-38-tok-s-on-dgx-spark-open-source-one-command-setup-sglang-nvfp4-dspark/380257);
  its vLLM compatibility is untested, so it is not the default.
- `NVFP4/Qwen3-30B-A3B-Instruct-2507-FP4` (https://huggingface.co/NVFP4/Qwen3-30B-A3B-Instruct-2507-FP4):
  medium-low. There is **no `nvidia/` or `RedHatAI/` NVFP4 of Instruct-2507**
  (I searched; only the 235B ones exist, plus `nvidia/Qwen3-30B-A3B-NVFP4`, a
  different model). This community ModelOpt checkpoint (~18 GB, 1.1k downloads)
  is the best NVFP4 match. Fallback if it misbehaves on sm_121:
  `cyankiwi/Qwen3-30B-A3B-Instruct-2507-AWQ-4bit` (209k downloads), same
  parsers. The official `Qwen/Qwen3-30B-A3B-Instruct-2507-FP8` (~30 GB) does
  not fit in a 0.25 share.
- `Qwen/Qwen3-VL-8B-Instruct-FP8` (https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct-FP8):
  high (official, 2M downloads).
- `nomic-ai/nomic-embed-text-v1.5` (https://huggingface.co/nomic-ai/nomic-embed-text-v1.5):
  high that it exists (`NomicBertModel`, custom code, so `--trust-remote-code`);
  medium that vLLM serves it at the full 8192 (unverified: the vLLM docs I could
  fetch do not mention Nomic or its context length; set `max_len` to 2048 in
  the spec if it refuses). `--runner pooling` is the current flag
  (https://docs.vllm.ai/en/latest/models/pooling_models/).

**Spec format.** `GB10_MODELS` (`--models` on `create`) is space separated
`alias=hf_repo@mem_frac@max_len[@extra]`. `extra` is vLLM arguments joined with
`+` instead of spaces (`--kv-cache-dtype+fp8+--max-num-seqs+4`; no JSON with `+`
in it). An env var `GB10_EXTRA_<alias>` (space separated) appends more.
`GB10_MAIN_FALLBACK` (`--main-fallback`) is a spec used if `main` fails.
**Alias contract:** clients only call `main`, `worker`, `vision`, `embed`. Swap
a model by changing `--models` and recreating the instance; no client change.

**Startup order.** The supervisor starts the servers **one at a time, largest
share first** (main, worker, vision, embed), each on its own loopback port
(8001..), and waits for that server's `/health` before starting the next. Each
vLLM sizes its KV cache from the memory that is free when it starts, so
parallel starts would race on the unified memory. A server that exits or
misses the health timeout (default 2400 s, because first boot downloads the
weights) is logged with the tail of its log and **skipped**; the rest still
come up. If `main` fails and `GB10_MAIN_FALLBACK` is set, that spec is tried in
its place. LiteLLM is then started with only the healthy aliases, and
`tailscale serve` (required) publishes it.

Known risks:
- **vLLM memory profiling on unified memory (hit on 2026-10-01).** Without an
  explicit KV size, `main` died with `Error in memory profiling. Initial free
  memory 50.92 GiB, current free memory 80.31 GiB`: page cache from the
  weight downloads was freed while vLLM profiled, and the container can't drop
  caches (`/proc/sys/vm` is read-only). Every default spec therefore sets
  `--kv-cache-memory-bytes` (main 18 GiB, worker 8, vision 3, embed 1), which
  skips the check. Keep it on any spec you add.
- **vLLM on sm_121.** v0.30.0 lists GB10 work (SM12x FP8 swizzle, W4A4 NVFP4
  preferred on SM120/121, B12X attention) but I found no report of this exact
  set on a vast.ai GB10. NVFP4 MoE (`worker`) is the likeliest to hit a kernel
  problem; the AWQ fallback above avoids that path.
- **Memory over-estimation.** The hybrid-attention `main` (Qwen3.5 architecture)
  measured 37 KB of KV per token, about 12% above the attention-only estimate
  (forum link above); vLLM may also want more than the share at startup. If a
  server fails at startup, lower `max_len` or raise its share; keep the total
  below about 0.85.
- **First-boot download time.** About 60 GB of weights over the host's link,
  sequentially; `running` on vast.ai says nothing about readiness. Watch
  `/var/log/gb10.log`. Default disk is 100 GB.
- Several vLLM instances plus fp8 KV: the vLLM DGX Spark post notes fp8 KV can
  cost speed; drop `--kv-cache-dtype+fp8` from the spec if quality or speed
  suffers (https://vllm.ai/blog/2026-06-01-vllm-dgx-spark).

## 8. Client configuration

Documentation only: nothing here has been applied. Base URL for everything:
`http://vastai-ts-proxy:8080/v1` (OpenAI-compatible, served by LiteLLM). Model
names are the aliases.

**gbrain**
- Query-time embeddings stay on the local `gbrain-ollama`
  (`ollama:nomic-embed-text`, 768 d), so search keeps working when the GB10 is
  down. Keep `GBRAIN_EMBEDDING_DIMENSIONS=768`.
- Chat models use the `litellm:` provider with `LITELLM_BASE_URL=http://vastai-ts-proxy:8080/v1`
  (now a real LiteLLM): `models.default`, `tier.subagent`, `tier.reasoning`,
  `tier.utility` = `litellm:worker`; `tier.deep` = `litellm:main`. (The
  `ollama:` recipe disables tools, hence `litellm:`.)
- RunPod bursts are to be disabled in the gbrain deploy repo (separate change).
- **Bulk embedding on the GB10 `embed` alias only after a parity check** against
  the local model, cosine >= 0.999 on a sample of your real texts. Both models
  are nomic-embed-text but different runtimes and quantisation, so verify:

```bash
python3 - <<'PY'
import json, math, urllib.request
texts = ["a sample sentence from the brain", "another, longer passage ..."]  # use ~50 real chunks
def post(url, body):
    r = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=120))
# run inside a container that can reach both, e.g. docker exec gbrain-server python3 -
local = post("http://gbrain-ollama:11434/api/embed", {"model": "nomic-embed-text", "input": texts})["embeddings"]
gb10 = [d["embedding"] for d in post("http://vastai-ts-proxy:8080/v1/embeddings", {"model": "embed", "input": texts})["data"]]
cos = lambda a, b: sum(x*y for x, y in zip(a, b)) / math.sqrt(sum(x*x for x in a) * sum(y*y for y in b))
print("min cosine:", min(cos(a, b) for a, b in zip(local, gb10)), "dims:", len(gb10[0]))
PY
```

  If the minimum is below 0.999 (or dims is not 768), keep embeddings local. Note
  nomic-embed-text-v1.5 expects task prefixes (`search_document: `,
  `search_query: `); use the same prefixes on both sides.
- Rollback: restore the previous `ollama:` values; `gbrain-ollama` stays.

**Hermes-Agent** (config key names below are **to confirm** against Hermes'
config schema):
- Custom provider `gb10`: OpenAI-compatible, `base_url` =
  `http://vastai-ts-proxy:8080/v1`. Global `model.default` = `gb10/worker`.
- Per profile (no fallback means it fails closed, so chats stay local to the GB10):

| profile | model | auxiliary | fallback |
|---|---|---|---|
| `surej_personal_assistant` | `main` | `worker` for delegation, compression, summary, web-extract; `vision` for vision | none |
| `surej` | `worker` | (same worker/vision split) | none |
| bot profiles | `worker` | (same) | opt-in per bot |

- Set the compression threshold below the model's context: 48k for `main`
  (ctx 64k), 24k for `worker` (ctx 32k).

## 9. Verification

```bash
docker logs --tail 30 vastai-ts-proxy            # tailscale up, tag applied
docker network inspect vastai-access --format '{{range .Containers}}{{.Name}} {{end}}'
# expect: vastai-ts-proxy gbrain-server gbrain-worker Hermes-Agent
docker exec Hermes-Agent curl -sS http://vastai-ts-proxy:8080/v1/models
docker exec gbrain-server curl -sS http://vastai-ts-proxy:8080/v1/models
# negative check: vastai-access has no internet
docker run --rm --network vastai-access busybox:stable wget -T3 -qO- http://1.1.1.1 ; echo "exit=$? (non-zero expected)"
```

## 10. Rollback

1. Restore the gbrain / Hermes settings in section 8 (local Ollama / OpenRouter).
2. `./undeploy-vastai-proxy.sh` (state kept) or `--purge` to also delete the
   Tailscale node identity. Remove the node in the Tailscale admin console.
3. Revoke the GB10 auth key and destroy the vast.ai instance
   (`provision-gb10.py destroy --instance-id N --yes`).

## 11. Caveats

- `nc -e` forks one process per connection. Fine for LLM request rates;
  long streaming plus many concurrent requests may exhaust it. Upgrade path:
  `socat TCP-LISTEN:8080,fork,reuseaddr EXEC:"tailscale --socket=... nc host 8080"`
  (needs socat in the image), or Tailscale serve/`tailscale nc` wrapped in a
  proper proxy.
- The vLLM servers keep their models resident. After boot the aliases appear in
  `/v1/models` one by one as each becomes healthy (first boot: tens of minutes
  of downloads); raise client timeouts and expect 404/502 for a missing alias.
- The GB10 is untrusted: treat every response as untrusted data, and send it
  only what you would send any third-party host.

## 12. Provisioning the GB10 (`provision-gb10.py`)

Python 3.10+, `pip install -r requirements.txt` (`vastai-sdk`; only needed for
real API calls, not for `--help`, `--print-onstart` or a `create` dry run).
Secrets are never taken from CLI args and never printed or written.

**vast.ai API key (Infisical is the source of truth).** `provision-gb10.py`
resolves it itself, so the deploy script, the undeploy script and direct use
share one path, and only when a vast.ai client is actually needed (`--help`,
`--print-onstart` and a dry-run `create` need nothing).

1. In Infisical, store secret `VAST_API_KEY` (and optionally `HF_TOKEN`) at path
   `/vast-ai` (env `prod`). The proxy's runtime identity must **not** have read
   access to `/vast-ai`; it only needs `/vastai-tailscale`. The proxy bootstrap
   file `infisical.env.gpg` is unrelated and cannot read this key.
2. Once per session on your Mac: `infisical login --domain
   https://infisical.rattlesnake-pauling.ts.net`.
3. Tell the CLI which project: run `infisical init` once in this repo directory
   (writes `.infisical.json`, git-ignored; the script runs the CLI with that
   directory as cwd), or `export INFISICAL_PROJECT_ID=<id>`.
4. The script then runs `infisical secrets get VAST_API_KEY --plain --silent
   --path /vast-ai --env prod --domain <domain> [--projectId <id>]`. Overrides
   (env): `INFISICAL_DOMAIN`, `INFISICAL_ENV`, `VAST_INFISICAL_PATH`,
   `INFISICAL_PROJECT_ID`, `INFISICAL_TIMEOUT`. On failure only a generic error
   and the CLI exit code are shown (never its stderr).
5. **Fallback only:** if Infisical fails or the CLI is missing, an exported
   `VAST_API_KEY` is used, with a WARNING on stderr ("Infisical is the source of
   truth"). If both fail, the error names both ways to fix it.
6. `HF_TOKEN` is looked up the same way (Infisical, then env) but is optional:
   if absent in both, the instance simply gets none, with no warning.
7. `TS_AUTHKEY` stays **env only**: a fresh single-use key per `create`, never
   stored in Infisical.

```bash
./provision-gb10.py search                          # GB10 offers, cheapest first
./provision-gb10.py create --offer-id N             # DRY RUN: prints request + onstart, offline
TS_AUTHKEY=... ./provision-gb10.py create --offer-id N --yes   # rents (billable)
./provision-gb10.py status                          # --ids for bare ids
./provision-gb10.py destroy --instance-id N --yes   # deletes the disk and models
./provision-gb10.py --print-onstart                 # dump the onstart command
```

- `search`: on-demand, rentable, verified, reliability >= 0.98, disk >= `--disk`
  (default 100), arm64 hosts, sorted by $/hr with an estimated $/month (730 h).
- `create --yes`: re-fetches the offer and prints the price, refuses if an
  instance labelled `gb10-vast` exists (`--allow-duplicate`), rents
  `--image` (default `ghcr.io/surejaj/vastai-gb10-vllm-tailscale:latest`; pin a digest, see
  `image/README.md`), waits for `running`. Also `--max-price`, `--models`,
  `--main-fallback`, `--timeout`. `destroy` acts only on label `gb10-vast`.
  There is no `stop`/`start`.
- The onstart is one line, `nohup /opt/gb10/start-gb10.sh ... &`, because the
  image ships the supervisor (vast.ai's ssh launch mode replaces the image
  entrypoint). The supervisor is flock-guarded (a repeated onstart is a no-op)
  and logs to `/var/log/gb10.log` on the instance (per-model logs in
  `/run/gb10/`). It runs `tailscaled --tun=userspace-networking --state=mem:`,
  `tailscale up --hostname=gb10-vast --advertise-tags=tag:vastai-gb10 --ssh` (no
  `--shields-up`), then the vLLM servers, LiteLLM and the required
  `tailscale serve` (section 7). No public ports are requested.

**TS_AUTHKEY handling.** The key is handed to a third-party host as an instance
env var. Create it in the Tailscale admin console as **single-use, ephemeral,
pre-tagged `tag:vastai-gb10`, short expiry**, for this one instance only. It is
a different key from the proxy's own (`tag:vastai-client`, Infisical
`/vastai-tailscale`). **Lifecycle is destroy/recreate only**: Tailscale state is
RAM-only, so a stopped and restarted instance would re-use an already consumed
key and could not rejoin. That is why `stop`/`start` do not exist. Every `create`
needs a fresh key. If the old ephemeral node has not been reaped yet, the new
one may register as `gb10-vast-1` and the proxy will not find it: check that
`tailscale status` shows exactly `gb10-vast`. `HF_TOKEN` (optional, read-only
scope) is also visible to the host; it is not needed for the default public
repos.

**From the deploy script.** `deploy-vastai-proxy.sh` runs `provision-gb10.py` as
its last step (after the proxy is up), using `${PYTHON:-python3}` with `vastai-sdk`
importable (checked first; the vast.ai key is resolved by the Python script as
above, so the deploy script no longer checks `VAST_API_KEY`; if `status` cannot
reach vast.ai it stops with "could not reach vast.ai (see error above)"):

```bash
./deploy-vastai-proxy.sh                              # proxy + `search`; rents nothing
TS_AUTHKEY=... ./deploy-vastai-proxy.sh --offer-id N [--max-price 0.60]   # + rent offer N
./deploy-vastai-proxy.sh --skip-provision             # proxy only
./deploy-vastai-proxy.sh --dry-run [--offer-id N]     # offline; with an id, previews the create request
```

If a `gb10-vast` instance already exists, the step logs it and creates nothing
(safe re-deploy). Nothing is rented without an explicit `--offer-id`.
`undeploy-vastai-proxy.sh --destroy-gb10` destroys it after a typed confirmation;
without the flag it prints a reminder if one is still billing (silently skipped
when `vastai-sdk` is missing or `status` fails; `--destroy-gb10` dies on failure).

**Not verified (no rental was made, nothing was built or run on a GB10):**
- The vast.ai `gpu_name` for this hardware. Default `GB10` + `cpu_arch=arm64`
  is a guess from the pricing URL (https://vast.ai/pricing/gpu/GB10). If
  `search` finds nothing, run `search --gpu-name any` and read the gpu column,
  then pass that value with `--gpu-name`.
- That the onstart runs in the `ssh_proxy` launch mode the script requests
  (vast.ai runs onstart in ssh/jupyter modes, not entrypoint mode), that vast.ai
  can pull a ~15+ GB image from GHCR within its start timeout, and that the host
  driver runs the CUDA 13.0 build (stock DGX OS driver; the NGC 26.04+ images
  need a newer one, which is why they were not chosen).
- Inbound delivery in userspace mode. The Tailscale Docker docs say incoming
  connections are "forwarded to the same port on localhost"
  (https://hub.docker.com/r/tailscale/tailscale), but a known issue reports it
  is not always ready right after start
  (https://github.com/tailscale/tailscale/issues/2642). Everything is
  loopback-only, so the supervisor relies on the explicit
  `tailscale serve --bg --tcp=8080 tcp://127.0.0.1:8080` (required). Check with
  `docker exec Hermes-Agent curl -sS http://vastai-ts-proxy:8080/v1/models`.
- The HF repos, vLLM flags and embed length in section 7.

## 13. The image

`image/` is the build context for `.github/workflows/build-image.yml`, which
builds `ghcr.io/surejaj/vastai-gb10-vllm-tailscale` (arm64) on a native
runner. See `image/README.md` for making the package public
and pinning the digest. Base: `vllm/vllm-openai:v0.30.0-aarch64` (CUDA 13.0,
release notes list GB10/SM121 work), plus Tailscale 1.102.4 and
`litellm[proxy]==1.103.1` in its own venv.
