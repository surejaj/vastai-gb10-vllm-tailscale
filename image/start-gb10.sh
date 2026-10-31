#!/bin/bash
# gb10 supervisor, run inside the vastai-gb10-vllm-tailscale image on the vast.ai GB10.
#
#   1. tailscaled (userspace, RAM state) + tailscale up   -> node gb10-vast
#   2. one vLLM per model in GB10_MODELS, ONE AT A TIME, largest memory share
#      first, each on 127.0.0.1:8001.. and waited on until /health is OK
#   3. LiteLLM on 127.0.0.1:8090 mapping alias -> its vLLM (started ones only)
#   4. tailscale serve --tcp=8080 -> 127.0.0.1:8090 (REQUIRED)
#   5. supervise: a vLLM or LiteLLM that dies is restarted with the same
#      command, env and log file (appended), at most GB10_RESTART_MAX times per
#      GB10_RESTART_WINDOW seconds each, then "GIVING UP: <alias>" and left down
#
# Idempotent: flock-guarded, so a second run while the first is alive exits 0.
# Pre-flight: if any target port (each vLLM port, LITELLM_PORT) already has a
# listener (a dead supervisor's children still running), it logs the busy ports
# and exits 1 without starting anything.
# Logs to $GB10_LOG. TS_AUTHKEY and HF_TOKEN are only ever passed through the
# environment; nothing here prints them and there is no `set -x`.
#
# GB10_MODELS: space-separated  alias=hf_repo@mem_frac@max_len[@extra]
#   extra: vLLM args joined with '+' instead of spaces
#          (e.g. --kv-cache-dtype+fp8+--max-num-seqs+4). Optionally also
#          GB10_EXTRA_<alias> (space separated, appended after 'extra').
# GB10_MAIN_FALLBACK: same spec (alias= optional, means 'main'), used if main
#   fails to become healthy.
# GB10_ALIASES: space-separated  alias=target  LiteLLM-only aliases served by
#   an already-started model (no extra vLLM). Default: worker=main vision=main.
# GB10_RESTART_MAX / GB10_RESTART_WINDOW: restart budget per process (default
#   5 per 3600 s). GB10_STOP_GRACE: seconds between SIGTERM and SIGKILL when
#   clearing a dead process group before a relaunch (default 60).
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

# Env set at create time; if not inherited (a hand run over ssh), read the
# provisioner's keys from /etc/environment. Parsed, never sourced: that file
# has unquoted values with spaces and '>' (TORCH_CUDA_ARCH_LIST=8.0 8.7 ...,
# NVIDIA_REQUIRE_CUDA=cuda>=13.0 ...) that would run as commands or create
# files. Only the keys below are read; an inherited non-empty value wins.
ENV_FILE_KEYS="TS_AUTHKEY HF_TOKEN TS_HOSTNAME TS_TAGS HF_HOME GB10_MODELS GB10_ALIASES GB10_MAIN_FALLBACK"
load_env_file() {
  local line k v
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line#export }"
    k="${line%%=*}"; [ "$k" = "$line" ] && continue
    case " $ENV_FILE_KEYS " in *" $k "*) ;; *) continue ;; esac
    [ -n "${!k:-}" ] && continue
    v="${line#*=}"
    case "$v" in \"*\") v="${v#\"}"; v="${v%\"}" ;; \'*\') v="${v#\'}"; v="${v%\'}" ;; esac
    printf -v "$k" '%s' "$v"; export "${k?}"
  done <"$1"
}
if [ -z "${TS_AUTHKEY:-}" ] && [ -r "${GB10_ENV_FILE:-/etc/environment}" ]; then
  load_env_file "${GB10_ENV_FILE:-/etc/environment}"
fi
TS_HOSTNAME="${TS_HOSTNAME:-gb10-vast}"
TS_TAGS="${TS_TAGS:-tag:vastai-gb10}"
TS_SOCK="${TS_SOCK:-/var/run/tailscale/tailscaled.sock}"
TAILSCALED="${TAILSCALED:-tailscaled}"
TAILSCALE="${TAILSCALE:-tailscale}"
VLLM_BIN="${VLLM_BIN:-vllm}"
LITELLM_BIN="${LITELLM_BIN:-/opt/litellm/bin/litellm}"
PORT="${GB10_PORT:-8080}"                  # tailnet port (tailscale serve)
# Not 8080: vast's ssh_proxy forwards container :8080 publicly (ssh_port+1 on
# sshN.vast.ai) for Jupyter, loopback bind or not.
LITELLM_PORT="${GB10_LITELLM_PORT:-8090}"
VLLM_BASE_PORT="${GB10_VLLM_BASE_PORT:-8001}"
HEALTH_TIMEOUT="${GB10_HEALTH_TIMEOUT:-3600}"   # first boot downloads ~77 GB of weights
SUPERVISE_INTERVAL="${GB10_SUPERVISE_INTERVAL:-30}"
RESTART_MAX="${GB10_RESTART_MAX:-5}"            # restarts per process per window
RESTART_WINDOW="${GB10_RESTART_WINDOW:-3600}"   # seconds
STOP_GRACE="${GB10_STOP_GRACE:-60}"             # SIGTERM -> SIGKILL, seconds
export HF_HOME="${HF_HOME:-/workspace/hf}"
# Default kept in single quotes: the JSON's '}' would end a ${..:-..} early.
DEFAULT_MODELS='main=nvidia/Qwen3.8-27B-NVFP4@0.70@262144@--trust-remote-code+--max-num-batched-tokens+8192+--enable-prefix-caching+--kv-cache-dtype+fp8_e4m3+--speculative-config.method+mtp+--speculative-config.num_speculative_tokens+3+--reasoning-parser+qwen3+--enable-auto-tool-choice+--tool-call-parser+qwen3_coder+--max-num-seqs+8+--kv-cache-memory-bytes+32212254720+--no-async-scheduling+--limit-mm-per-prompt+{"image":4,"video":0} embed=nomic-ai/nomic-embed-text-v1.5@0.03@8192@--runner+pooling+--trust-remote-code+--kv-cache-memory-bytes+1073741824'
GB10_MODELS="${GB10_MODELS:-$DEFAULT_MODELS}"
GB10_ALIASES="${GB10_ALIASES-worker=main vision=main}"
mkdir -p "$HF_HOME" "$(dirname "$TS_SOCK")"

# ---------------------------------------------------------------- helpers
# port_busy port -> 0 if something accepts connections on 127.0.0.1:port
# (bash /dev/tcp; the image has no ss/netstat).
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# spawn logfile cmd...  -> SPAWN_PID. Log appended (crash evidence survives a
# restart), lock fd closed, and its own process group (set -m) so stop_group
# also catches vLLM's EngineCore/worker children, which can outlive the API
# server and keep holding unified memory.
spawn() {
  local out="$1"; shift
  set -m
  nohup "$@" >>"$out" 2>&1 9>&- &
  SPAWN_PID=$!
  set +m
}

# stop_group pid -> 0 once nothing in its process group is left (TERM, then
# KILL after STOP_GRACE s).
group_alive() { kill -0 -- "-$1" 2>/dev/null || kill -0 "$1" 2>/dev/null; }
stop_group() {
  local pid="$1" n
  group_alive "$pid" || return 0
  kill -TERM -- "-$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
  for ((n = 0; n < STOP_GRACE; n++)); do group_alive "$pid" || return 0; sleep 1; done
  kill -KILL -- "-$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
  for ((n = 0; n < 10; n++)); do group_alive "$pid" || return 0; sleep 1; done
  return 1
}

# free_slot name pid port -> 0 when the old process group is gone and the port
# is free, so a relaunch neither doubles memory nor passes health against a
# leftover server.
free_slot() {
  local n
  stop_group "$2" || { log "$1: old process group $2 will not die; not relaunching"; return 1; }
  for ((n = 0; n < 30; n++)); do port_busy "$3" || return 0; sleep 1; done
  log "$1: port $3 still busy; not relaunching"; return 1
}

# budget_take "t1 t2 .." -> BUDGET (restart times inside RESTART_WINDOW, plus
# now if allowed) and BUDGET_N; returns 1 once RESTART_MAX is used up.
budget_take() {
  local t
  BUDGET=""; BUDGET_N=0
  for t in $1; do
    [ $((SECONDS - t)) -lt "$RESTART_WINDOW" ] && { BUDGET="$BUDGET $t"; BUDGET_N=$((BUDGET_N + 1)); }
  done
  [ "$BUDGET_N" -ge "$RESTART_MAX" ] && return 1
  BUDGET="$BUDGET $SECONDS"; BUDGET_N=$((BUDGET_N + 1)); return 0
}

# ---------------------------------------------------------------- 0. pre-flight
# The flock only stops a second copy while the supervisor is alive. If it died
# and left vLLM/LiteLLM running, a hand re-run would load a second copy of the
# model (OOM on 120 GB unified memory) and its health checks would pass against
# the old servers. So refuse while any target port is taken.
n=0; for _ in $GB10_MODELS ${GB10_MAIN_FALLBACK:+fallback}; do n=$((n + 1)); done
busy=""
for ((p = VLLM_BASE_PORT; p < VLLM_BASE_PORT + n; p++)); do port_busy "$p" && busy="$busy $p"; done
port_busy "$LITELLM_PORT" && busy="$busy $LITELLM_PORT"
if [ -n "$busy" ]; then
  log "REFUSING to start: port(s) already in use:$busy (an old vLLM/LiteLLM still running?); started nothing"
  exit 1
fi

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
declare -a STARTED_REPO=() STARTED_FRAC=() STARTED_LEN=() STARTED_EXTRA=()
NEXT_PORT="$VLLM_BASE_PORT"

# launch_vllm alias repo frac max_len extra port -> SPAWN_PID (not waited on).
# Shared by the first start and restarts, so a restart is the same command.
launch_vllm() {
  local -a xargs; read -ra xargs <<<"$5"
  log "launch $1" >>"$RUN/vllm-$1.log"
  spawn "$RUN/vllm-$1.log" "$VLLM_BIN" serve "$2" --served-model-name "$1" \
    --host 127.0.0.1 --port "$6" \
    --gpu-memory-utilization "$3" --max-model-len "$4" \
    ${xargs[@]+"${xargs[@]}"}
}

# wait_vllm alias port pid -> 0 once /health is OK; 1 (logged) if it exits or
# times out.
wait_vllm() {
  local t0=$SECONDS
  while :; do
    if curl -fsS "http://127.0.0.1:$2/health" >/dev/null 2>&1; then
      log "$1 healthy on :$2 after $((SECONDS - t0))s"; return 0
    fi
    if ! kill -0 "$3" 2>/dev/null; then log "$1: vLLM exited before becoming healthy"; return 1; fi
    if [ $((SECONDS - t0)) -ge "$HEALTH_TIMEOUT" ]; then log "$1: health timeout after ${HEALTH_TIMEOUT}s"; return 1; fi
    sleep "${GB10_HEALTH_POLL:-5}"
  done
}

# vllm_failed alias pid -> log the tail of its log and make sure it is gone.
vllm_failed() {
  log "FAILED $1; last lines of $RUN/vllm-$1.log:"
  tail -n 30 "$RUN/vllm-$1.log" 2>/dev/null | sed 's/^/    | /'
  stop_group "$2"
}

# start_model "alias=repo@frac@len[@extra]"  -> 0 if healthy (and recorded)
start_model() {
  local spec="$1" alias rest repo frac maxlen extra var port
  local -a xargs
  case "$spec" in *=*) alias="${spec%%=*}"; rest="${spec#*=}" ;; *) alias=main; rest="$spec" ;; esac
  [[ "$alias" =~ ^[A-Za-z0-9_-]+$ ]] || { log "bad alias '$alias'; skipping"; return 1; }
  IFS='@' read -r repo frac maxlen extra <<<"$rest"
  if [ -z "$repo" ] || [ -z "$frac" ] || [ -z "$maxlen" ]; then
    log "bad spec for $alias (want alias=repo@frac@len[@extra]); skipping"; return 1
  fi
  extra="${extra//+/ }"
  var="GB10_EXTRA_${alias//-/_}"; extra="$extra ${!var:-}"
  read -ra xargs <<<"$extra"
  port="$NEXT_PORT"; NEXT_PORT=$((NEXT_PORT + 1))
  log "starting $alias: $repo frac=$frac max_len=$maxlen port=$port extra='${xargs[*]-}'"
  launch_vllm "$alias" "$repo" "$frac" "$maxlen" "$extra" "$port"
  if ! wait_vllm "$alias" "$port" "$SPAWN_PID"; then vllm_failed "$alias" "$SPAWN_PID"; return 1; fi
  STARTED_ALIAS+=("$alias"); STARTED_PORT+=("$port"); STARTED_PID+=("$SPAWN_PID")
  STARTED_REPO+=("$repo"); STARTED_FRAC+=("$frac"); STARTED_LEN+=("$maxlen"); STARTED_EXTRA+=("$extra")
  case "$alias$extra" in embed*|*pooling*) STARTED_EMB+=(1) ;; *) STARTED_EMB+=(0) ;; esac
  return 0
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
# tag:vastai-gb10:8080). Do not expose it any other way, and keep it off
# container :8080 (see LITELLM_PORT).
# litellm_entry name served_model port is_embedding -> one model_list entry
litellm_entry() {
  echo "  - model_name: $1"
  echo "    litellm_params:"
  echo "      model: openai/$2"
  echo "      api_base: http://127.0.0.1:$3/v1"
  echo "      api_key: none"
  # worker gets short, direct answers (approval guardian, titles, compression).
  # Its model runs with --reasoning-parser (Hermes sends thinking_token_budget),
  # so with thinking on the answer can land in reasoning_content and content
  # comes back null; the guardian then escalates every command to the user.
  # top_k on every chat model: vLLM 0.32.0 emits token 0 once
  # thinking_token_budget runs out under MTP on rows with top-p but no top-k
  # (vllm #58231, fixed after 0.32.0); rows with top-k take an unaffected path.
  if [ "$4" != 1 ]; then
    echo "      extra_body:"
    echo "        top_k: 20"
    if [ "$1" = worker ]; then
      echo "        chat_template_kwargs:"
      echo "          enable_thinking: false"
    fi
  fi
  [ "$4" = 1 ] && { echo "    model_info:"; echo "      mode: embedding"; }
  return 0
}
CFG="$RUN/litellm.yaml"
{
  echo "model_list:"
  for i in "${!STARTED_ALIAS[@]}"; do
    litellm_entry "${STARTED_ALIAS[$i]}" "${STARTED_ALIAS[$i]}" "${STARTED_PORT[$i]}" "${STARTED_EMB[$i]}"
  done
  for spec in $GB10_ALIASES; do
    a="${spec%%=*}"; t="${spec#*=}"; found=""
    for i in "${!STARTED_ALIAS[@]}"; do
      [ "${STARTED_ALIAS[$i]}" = "$a" ] && { found=dup; break; }
      [ "${STARTED_ALIAS[$i]}" = "$t" ] && found="$i"
    done
    case "$found" in
      dup) log "alias $a is already a served model; skipping $spec" >&2 ;;
      "")  log "alias $a: target $t not started; skipping" >&2 ;;
      *)   litellm_entry "$a" "$t" "${STARTED_PORT[$found]}" "${STARTED_EMB[$found]}" ;;
    esac
  done
  echo "litellm_settings:"
  echo "  drop_params: true"
} >"$CFG"
log "litellm config written: $CFG (aliases: ${STARTED_ALIAS[*]})"
# launch_litellm -> LITELLM_PID; wait_litellm -> 0 once /health/liveliness is OK.
launch_litellm() {
  log "launch litellm" >>"$RUN/litellm.log"
  spawn "$RUN/litellm.log" env -u HF_TOKEN "$LITELLM_BIN" --config "$CFG" --host 127.0.0.1 --port "$LITELLM_PORT"
  LITELLM_PID=$SPAWN_PID
}
wait_litellm() {
  local n
  for ((n = 0; n < ${GB10_LITELLM_WAIT:-60}; n++)); do
    curl -fsS "http://127.0.0.1:$LITELLM_PORT/health/liveliness" >/dev/null 2>&1 && return 0
    kill -0 "$LITELLM_PID" 2>/dev/null || break
    sleep "${GB10_HEALTH_POLL:-2}"
  done
  curl -fsS "http://127.0.0.1:$LITELLM_PORT/health/liveliness" >/dev/null 2>&1 && return 0
  log "litellm did not come up; see $RUN/litellm.log"; tail -n 20 "$RUN/litellm.log" | sed 's/^/    | /'
  return 1
}
launch_litellm
wait_litellm || exit 1
log "litellm up on 127.0.0.1:$LITELLM_PORT"

# ---------------------------------------------------------------- 4. serve
# LiteLLM is loopback-only, so this is the only way in from the tailnet.
"$TAILSCALE" --socket="$TS_SOCK" serve --bg --tcp="$PORT" "tcp://127.0.0.1:$LITELLM_PORT" \
  || { log "tailscale serve failed; the GB10 would be unreachable"; exit 1; }
log "tailscale serve: tailnet :$PORT -> 127.0.0.1:$LITELLM_PORT"

# ---------------------------------------------------------------- 5. supervise
# A dead process is restarted one at a time (the loop blocks while a vLLM
# reloads, so two never load at once), after its old process group is gone
# and its port is free. Each has its own budget of RESTART_MAX restarts per
# RESTART_WINDOW s; past that it is logged once as GIVING UP and left down
# (recreate the instance to recover).
declare -a RESTART_TIMES=() GAVE_UP=()
LITELLM_TIMES=""; LITELLM_GAVE_UP=""

# restart_vllm index -> 0 if healthy again
restart_vllm() {
  local i="$1" a="${STARTED_ALIAS[$1]}" port="${STARTED_PORT[$1]}"
  if ! budget_take "${RESTART_TIMES[$i]:-}"; then
    RESTART_TIMES[$i]="$BUDGET"; GAVE_UP[$i]=1
    log "GIVING UP: $a ($RESTART_MAX restarts in ${RESTART_WINDOW}s; see $RUN/vllm-$a.log)"
    stop_group "${STARTED_PID[$i]}"
    return 1
  fi
  RESTART_TIMES[$i]="$BUDGET"
  log "RESTART: vLLM for $a, attempt $BUDGET_N/$RESTART_MAX in ${RESTART_WINDOW}s"
  free_slot "$a" "${STARTED_PID[$i]}" "$port" || return 1
  launch_vllm "$a" "${STARTED_REPO[$i]}" "${STARTED_FRAC[$i]}" "${STARTED_LEN[$i]}" "${STARTED_EXTRA[$i]}" "$port"
  STARTED_PID[$i]="$SPAWN_PID"
  wait_vllm "$a" "$port" "$SPAWN_PID" || { vllm_failed "$a" "$SPAWN_PID"; return 1; }
}

# restart_litellm -> 0 if healthy again (same $CFG, which is not rewritten)
restart_litellm() {
  if ! budget_take "$LITELLM_TIMES"; then
    LITELLM_TIMES="$BUDGET"; LITELLM_GAVE_UP=1
    log "GIVING UP: litellm ($RESTART_MAX restarts in ${RESTART_WINDOW}s; see $RUN/litellm.log)"
    stop_group "$LITELLM_PID"
    return 1
  fi
  LITELLM_TIMES="$BUDGET"
  log "RESTART: litellm, attempt $BUDGET_N/$RESTART_MAX in ${RESTART_WINDOW}s"
  free_slot litellm "$LITELLM_PID" "$LITELLM_PORT" || return 1
  launch_litellm
  wait_litellm || { stop_group "$LITELLM_PID"; return 1; }
  log "litellm up on 127.0.0.1:$LITELLM_PORT"
}

while :; do
  for i in "${!STARTED_PID[@]}"; do
    [ -n "${GAVE_UP[$i]:-}" ] && continue
    kill -0 "${STARTED_PID[$i]}" 2>/dev/null && continue
    log "DIED: vLLM for ${STARTED_ALIAS[$i]} (see $RUN/vllm-${STARTED_ALIAS[$i]}.log)"
    restart_vllm "$i"
  done
  if [ -z "$LITELLM_GAVE_UP" ] && ! kill -0 "$LITELLM_PID" 2>/dev/null; then
    log "DIED: litellm (see $RUN/litellm.log)"
    restart_litellm
  fi
  [ -n "${GB10_SUPERVISE_ONCE:-}" ] && { log "supervise-once: done"; exit 0; }
  # 9>&-: an orphaned sleep must not hold the lock if the supervisor dies.
  sleep "$SUPERVISE_INTERVAL" 9>&-
done
