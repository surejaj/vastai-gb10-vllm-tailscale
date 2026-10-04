#!/bin/bash
# gb10 supervisor, run inside the vastai-gb10-vllm-tailscale image on the vast.ai GB10.
#
#   1. tailscaled (userspace, RAM state) + tailscale up   -> node gb10-vast
#   2. one vLLM per model in GB10_MODELS, ONE AT A TIME, largest memory share
#      first, each on 127.0.0.1:8001.. and waited on until /health is OK
#   3. LiteLLM on 127.0.0.1:8080 mapping alias -> its vLLM (started ones only)
#   4. tailscale serve --tcp=8080 -> 127.0.0.1:8080 (REQUIRED)
#   5. supervise: log if a vLLM or LiteLLM process dies (no restart)
#
# Idempotent: flock-guarded, so a second run while the first is alive exits 0.
# Logs to $GB10_LOG. TS_AUTHKEY and HF_TOKEN are only ever passed through the
# environment; nothing here prints them and there is no `set -x`.
#
# GB10_MODELS: space-separated  alias=hf_repo@mem_frac@max_len[@extra]
#   extra: vLLM args joined with '+' instead of spaces
#          (e.g. --kv-cache-dtype+fp8+--max-num-seqs+4). Optionally also
#          GB10_EXTRA_<alias> (space separated, appended after 'extra').
# GB10_MAIN_FALLBACK: same spec (alias= optional, means 'main'), used if main
#   fails to become healthy.
#
# Every path/binary below can be overridden by env (used by the test harness).

set -uo pipefail
set -f   # extra vLLM args are word-split, never glob-expanded

LOG="${GB10_LOG:-/var/log/gb10.log}"
RUN="${GB10_RUN_DIR:-/run/gb10}"
LOCK="${GB10_LOCK:-$RUN/gb10.lock}"
mkdir -p "$RUN" "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
log() { echo "[$(date -u +%FT%TZ)] $*"; }

exec 9>"$LOCK"
flock -n 9 || { log "another start-gb10.sh is running; exiting"; exit 0; }
log "=== start-gb10 ==="

# Env set at create time; fall back to /etc/environment if not inherited.
if [ -z "${TS_AUTHKEY:-}" ] && [ -r "${GB10_ENV_FILE:-/etc/environment}" ]; then
  set -a; . "${GB10_ENV_FILE:-/etc/environment}"; set +a
fi
TS_HOSTNAME="${TS_HOSTNAME:-gb10-vast}"
TS_TAGS="${TS_TAGS:-tag:vastai-gb10}"
TS_SOCK="${TS_SOCK:-/var/run/tailscale/tailscaled.sock}"
TAILSCALED="${TAILSCALED:-tailscaled}"
TAILSCALE="${TAILSCALE:-tailscale}"
VLLM_BIN="${VLLM_BIN:-vllm}"
LITELLM_BIN="${LITELLM_BIN:-/opt/litellm/bin/litellm}"
PORT="${GB10_PORT:-8080}"                  # LiteLLM, exposed via tailscale serve
VLLM_BASE_PORT="${GB10_VLLM_BASE_PORT:-8001}"
HEALTH_TIMEOUT="${GB10_HEALTH_TIMEOUT:-2400}"   # first boot downloads weights
SUPERVISE_INTERVAL="${GB10_SUPERVISE_INTERVAL:-30}"
export HF_HOME="${HF_HOME:-/workspace/hf}"
GB10_MODELS="${GB10_MODELS:-main=unsloth/Qwen3.8-27B-NVFP4@0.38@65536@--kv-cache-dtype+fp8+--reasoning-parser+qwen3+--enable-auto-tool-choice+--tool-call-parser+qwen3_xml+--max-num-seqs+4+--kv-cache-memory-bytes+19327352832 worker=NVFP4/Qwen3-30B-A3B-Instruct-2507-FP4@0.25@32768@--kv-cache-dtype+fp8+--enable-auto-tool-choice+--tool-call-parser+hermes+--max-num-seqs+4+--kv-cache-memory-bytes+8589934592 vision=Qwen/Qwen3-VL-8B-Instruct-FP8@0.12@16384@--max-num-seqs+2+--kv-cache-memory-bytes+3221225472 embed=nomic-ai/nomic-embed-text-v1.5@0.03@8192@--runner+pooling+--trust-remote-code+--kv-cache-memory-bytes+1073741824}"
mkdir -p "$HF_HOME" "$(dirname "$TS_SOCK")"

# ---------------------------------------------------------------- 1. tailscale
if ! pgrep -x tailscaled >/dev/null; then
  nohup "$TAILSCALED" --tun=userspace-networking --state=mem: \
    --socket="$TS_SOCK" >>"$RUN/tailscaled.log" 2>&1 9>&- &
  sleep "${GB10_TS_SETTLE:-3}"
fi
if ! "$TAILSCALE" --socket="$TS_SOCK" status >/dev/null 2>&1; then
  [ -n "${TS_AUTHKEY:-}" ] || { log "TS_AUTHKEY is not set; cannot join tailnet"; exit 1; }
  # No --shields-up: the proxy must be able to dial in. --ssh: Tailscale SSH,
  # gated by the tailnet ACL ssh rule (README section 5).
  "$TAILSCALE" --socket="$TS_SOCK" up --auth-key="$TS_AUTHKEY" \
    --hostname="$TS_HOSTNAME" --advertise-tags="$TS_TAGS" --ssh \
    --accept-dns=false --accept-routes=false >/dev/null 2>&1 \
    || { log "tailscale up failed"; exit 1; }
fi
unset TS_AUTHKEY
log "tailscale up as $TS_HOSTNAME"

# ---------------------------------------------------------------- 2. vLLM
declare -a STARTED_ALIAS=() STARTED_PORT=() STARTED_PID=() STARTED_EMB=()
NEXT_PORT="$VLLM_BASE_PORT"

# start_model "alias=repo@frac@len[@extra]"  -> 0 if healthy (and recorded)
start_model() {
  local spec="$1" alias rest repo frac maxlen extra var port pid t0 mlog
  case "$spec" in *=*) alias="${spec%%=*}"; rest="${spec#*=}" ;; *) alias=main; rest="$spec" ;; esac
  [[ "$alias" =~ ^[A-Za-z0-9_-]+$ ]] || { log "bad alias '$alias'; skipping"; return 1; }
  IFS='@' read -r repo frac maxlen extra <<<"$rest"
  if [ -z "$repo" ] || [ -z "$frac" ] || [ -z "$maxlen" ]; then
    log "bad spec for $alias (want alias=repo@frac@len[@extra]); skipping"; return 1
  fi
  extra="${extra//+/ }"
  var="GB10_EXTRA_${alias//-/_}"; extra="$extra ${!var:-}"
  local -a xargs; read -ra xargs <<<"$extra"
  port="$NEXT_PORT"; NEXT_PORT=$((NEXT_PORT + 1))
  mlog="$RUN/vllm-$alias.log"
  log "starting $alias: $repo frac=$frac max_len=$maxlen port=$port extra='${xargs[*]-}'"
  nohup "$VLLM_BIN" serve "$repo" --served-model-name "$alias" \
    --host 127.0.0.1 --port "$port" \
    --gpu-memory-utilization "$frac" --max-model-len "$maxlen" \
    ${xargs[@]+"${xargs[@]}"} >"$mlog" 2>&1 9>&- &
  pid=$!
  t0=$SECONDS
  while :; do
    if curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      log "$alias healthy on :$port after $((SECONDS - t0))s"
      STARTED_ALIAS+=("$alias"); STARTED_PORT+=("$port"); STARTED_PID+=("$pid")
      case "$alias$extra" in embed*|*pooling*) STARTED_EMB+=(1) ;; *) STARTED_EMB+=(0) ;; esac
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then log "$alias: vLLM exited before becoming healthy"; break; fi
    if [ $((SECONDS - t0)) -ge "$HEALTH_TIMEOUT" ]; then log "$alias: health timeout after ${HEALTH_TIMEOUT}s"; break; fi
    sleep "${GB10_HEALTH_POLL:-5}"
  done
  log "FAILED $alias; last lines of $mlog:"; tail -n 30 "$mlog" 2>/dev/null | sed 's/^/    | /'
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return 1
}

# Largest memory share first (one at a time: each vLLM profiles the free
# memory left by the previous one, so parallel starts would race).
SORTED="$(for s in $GB10_MODELS; do r="${s#*=}"; f="${r#*@}"; f="${f%%@*}"; echo "$f $s"; done | sort -rn | cut -d' ' -f2-)"
for spec in $SORTED; do
  if ! start_model "$spec" && [ "${spec%%=*}" = main ] && [ -n "${GB10_MAIN_FALLBACK:-}" ]; then
    log "main failed; trying GB10_MAIN_FALLBACK"
    start_model "${GB10_MAIN_FALLBACK}" || log "main fallback failed too"
  fi
done
if [ "${#STARTED_ALIAS[@]}" -eq 0 ]; then log "no model started; exiting"; exit 1; fi

# ---------------------------------------------------------------- 3. LiteLLM
# No master key: LiteLLM listens on loopback only and is reached solely through
# tailscale serve, so access control is the tailnet ACL (tag:vastai-client ->
# tag:vastai-gb10:8080). Do not expose it any other way.
CFG="$RUN/litellm.yaml"
{
  echo "model_list:"
  for i in "${!STARTED_ALIAS[@]}"; do
    echo "  - model_name: ${STARTED_ALIAS[$i]}"
    echo "    litellm_params:"
    echo "      model: openai/${STARTED_ALIAS[$i]}"
    echo "      api_base: http://127.0.0.1:${STARTED_PORT[$i]}/v1"
    echo "      api_key: none"
    [ "${STARTED_EMB[$i]}" = 1 ] && { echo "    model_info:"; echo "      mode: embedding"; }
  done
  echo "litellm_settings:"
  echo "  drop_params: true"
} >"$CFG"
log "litellm config written: $CFG (aliases: ${STARTED_ALIAS[*]})"
env -u HF_TOKEN nohup "$LITELLM_BIN" --config "$CFG" --host 127.0.0.1 --port "$PORT" \
  >"$RUN/litellm.log" 2>&1 9>&- &
LITELLM_PID=$!
for _ in $(seq 1 "${GB10_LITELLM_WAIT:-60}"); do
  curl -fsS "http://127.0.0.1:$PORT/health/liveliness" >/dev/null 2>&1 && break
  sleep "${GB10_HEALTH_POLL:-2}"
done
curl -fsS "http://127.0.0.1:$PORT/health/liveliness" >/dev/null 2>&1 \
  || { log "litellm did not come up; see $RUN/litellm.log"; tail -n 20 "$RUN/litellm.log" | sed 's/^/    | /'; exit 1; }
log "litellm up on 127.0.0.1:$PORT"

# ---------------------------------------------------------------- 4. serve
# LiteLLM is loopback-only, so this is the only way in from the tailnet.
"$TAILSCALE" --socket="$TS_SOCK" serve --bg --tcp="$PORT" "tcp://127.0.0.1:$PORT" \
  || { log "tailscale serve failed; the GB10 would be unreachable"; exit 1; }
log "tailscale serve: tailnet :$PORT -> 127.0.0.1:$PORT"

# ---------------------------------------------------------------- 5. supervise
# Logging only; a dead process stays dead (recreate the instance to recover).
DEAD=" "   # space-separated names already reported
while :; do
  for i in "${!STARTED_PID[@]}"; do
    a="${STARTED_ALIAS[$i]}"
    case "$DEAD" in *" $a "*) continue ;; esac
    if ! kill -0 "${STARTED_PID[$i]}" 2>/dev/null; then
      DEAD="$DEAD$a "; log "DIED: vLLM for $a (see $RUN/vllm-$a.log)"
    fi
  done
  case "$DEAD" in *" litellm "*) ;; *)
    if ! kill -0 "$LITELLM_PID" 2>/dev/null; then
      DEAD="${DEAD}litellm "; log "DIED: litellm (see $RUN/litellm.log)"
    fi ;;
  esac
  [ -n "${GB10_SUPERVISE_ONCE:-}" ] && { log "supervise-once: done"; exit 0; }
  sleep "$SUPERVISE_INTERVAL"
done
