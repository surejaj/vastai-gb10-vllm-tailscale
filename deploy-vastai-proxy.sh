#!/usr/bin/env bash
# Deploy the vast.ai egress proxy (vastai-ts-proxy) on host 'wolverine' and
# attach gbrain-server / gbrain-worker / Hermes-Agent to the internal
# `vastai-access` network. See README.md for the design.
#
# Usage: deploy-vastai-proxy.sh [--dry-run] [--offer-id N [--max-price X]] [--skip-provision]
#   --dry-run  print every docker command (and every check / mint) without
#              running anything: no docker, gpg, infisical or network calls.
#   --offer-id N      after the proxy is up, rent vast.ai offer N as the GB10
#                     via provision-gb10.py (skipped if a gb10-vast instance
#                     already exists). Without it, only `search` runs and
#                     nothing is rented.
#   --max-price X     refuse offers above X $/hr (passed to provision-gb10.py)
#   --skip-provision  do not run the GB10 provisioning step at all
#
# Provisioning secrets (never printed): provision-gb10.py itself fetches the
# vast.ai key (VAST_API_KEY) from Infisical via the `infisical` CLI (run
# `infisical login --domain ...` first; env VAST_API_KEY is only a fallback),
# so nothing is checked here. When renting, env TS_AUTHKEY is required: a FRESH single-use, ephemeral, pre-tagged tag:vastai-gb10 key
# for the GB10. It is NOT the proxy's key (that is Infisical /vastai-tailscale,
# tag:vastai-client). Python: ${PYTHON:-python3} with vastai-sdk installed
# (pip install -r requirements.txt).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${DOCKER_CONTEXT:=unraid-remote}"
export DOCKER_CONTEXT

readonly TS_IMAGE="tailscale/tailscale:stable"
readonly PROXY="vastai-ts-proxy"
readonly ACCESS_NETWORK="vastai-access"
readonly EGRESS_NETWORK="infisical-access"   # egress + Infisical reachability
readonly DATA_ROOT="/mnt/main/app-data/vastai-ts-proxy"
readonly STATE_DIR="${DATA_ROOT}/tailscale"
readonly TS_TAG="tag:vastai-client"
readonly CLIENTS=(gbrain-server gbrain-worker Hermes-Agent)

# Configurable target: the GB10's tailnet hostname and Ollama port.
: "${VAST_TS_HOST:=gb10-vast}"
: "${VAST_PORT:=8080}"

# Infisical: per-service bootstrap file (gpg), shared host-wide runtime volume.
BOOTSTRAP_FILE="${SCRIPT_DIR}/infisical.env.gpg"
: "${INFISICAL_SECRET_PATH:=/vastai-tailscale}"   # holds TS_AUTHKEY (tag:vastai-client key; NOT gbrain's /tailscale)

DRY_RUN=false
SKIP_PROVISION=false
OFFER_ID=""
MAX_PRICE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --skip-provision) SKIP_PROVISION=true ;;
    --offer-id|--max-price)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 needs a value" >&2; exit 1; }
      [[ "$1" == "--offer-id" ]] && OFFER_ID="$2" || MAX_PRICE="$2"
      shift ;;
    *) echo "ERROR: unknown argument $1" >&2; exit 1 ;;
  esac
  shift
done
[[ -z "${OFFER_ID}" || "${OFFER_ID}" =~ ^[0-9]+$ ]] || { echo "ERROR: --offer-id must be a number" >&2; exit 1; }
[[ -z "${MAX_PRICE}" || "${MAX_PRICE}" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "ERROR: --max-price must be a number" >&2; exit 1; }
[[ -z "${MAX_PRICE}" || -n "${OFFER_ID}" ]] || { echo "ERROR: --max-price needs --offer-id" >&2; exit 1; }

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Only sourced: defines functions, runs nothing. Lives in the docker-mgmt repo.
: "${INFISICAL_SCRIPTS_DIR:=${HOME}/workspace/wolverine_docker_mgmt_tsdproxy/infisical/scripts}"
[[ -r "${INFISICAL_SCRIPTS_DIR}/infisical-runtime.sh" ]] \
  || die "infisical-runtime.sh not found in ${INFISICAL_SCRIPTS_DIR}; set INFISICAL_SCRIPTS_DIR"
source "${INFISICAL_SCRIPTS_DIR}/infisical-runtime.sh"

# dk ARGS...: run docker, or just print the command in dry-run.
dk() {
  if "${DRY_RUN}"; then
    printf '[dry-run] docker'; printf ' %q' "$@"; printf '\n'
  else
    docker "$@"
  fi
}

# Read-only checks. These call docker directly, so every caller branches on
# DRY_RUN first and prints "would check" instead.
network_exists() { docker network inspect "$1" >/dev/null 2>&1; }
container_exists() { docker container inspect "$1" >/dev/null 2>&1; }
is_connected() {
  docker network inspect "$1" --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' | grep -qx "$2"
}

ensure_network() {
  if "${DRY_RUN}"; then
    log "would check whether network ${ACCESS_NETWORK} exists"
    dk network create --driver bridge --internal "${ACCESS_NETWORK}"
  elif network_exists "${ACCESS_NETWORK}"; then
    log "Network ${ACCESS_NETWORK} already exists."
  else
    log "Creating internal network ${ACCESS_NETWORK}"
    dk network create --driver bridge --internal "${ACCESS_NETWORK}" >/dev/null
  fi
}

# Created via a throwaway container (Docker API only; no ssh). Done before
# any bind-mount probe, which would otherwise auto-create the source as root.
ensure_state_dir() {
  log "Ensuring ${STATE_DIR}"
  dk run --rm --mount "type=bind,src=/mnt/main/app-data,dst=/x" --entrypoint sh \
    "${INFISICAL_HELPER_IMAGE}" -c 'mkdir -p /x/vastai-ts-proxy/tailscale'
}

# Mint a one-time Infisical secret only when tailscale state is not yet
# initialised (same rule infisical-fetch.sh applies via --unless-contains).
mint_if_needed() {
  local secret=""
  if "${DRY_RUN}"; then
    log "would decrypt ${BOOTSTRAP_FILE}, install runtime volume ${INFISICAL_RUNTIME_VOLUME}, and check ${STATE_DIR}/tailscaled.state for _current-profile"
    log "would mint a one-time Infisical client secret only if the state is uninitialised"
    echo "<ONE_TIME_SECRET_PLACEHOLDER>"
    return 0
  fi
  load_bootstrap >&2
  install_infisical_runtime >&2
  if path_contains "${STATE_DIR}" tailscaled.state _current-profile; then
    log "Tailscale state already initialised; no auth key fetch needed." >&2
  else
    secret="$(mint_client_secret vastai-ts-proxy)"
  fi
  printf '%s\n' "${secret}"
}

run_proxy() {
  local secret="$1"
  if "${DRY_RUN}"; then
    log "would remove existing ${PROXY} if present"
    dk rm -f "${PROXY}"
  elif container_exists "${PROXY}"; then
    log "Removing existing container ${PROXY} for redeploy (state kept)"
    docker rm -f "${PROXY}" >/dev/null
  fi

  # Same shape as gbrain-runpod-proxy. Values are single-quoted so ${VAR}
  # expands in the container shell, not here.
  local cmd
  cmd='(unset INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET
   exec busybox nc -lk -p "${VAST_PORT}" -e tailscale --socket=/tmp/tailscaled.sock nc "${VAST_TS_HOST}" "${VAST_PORT}") &
exec /opt/infisical/infisical-fetch.sh --path '"${INFISICAL_SECRET_PATH}"' \
  --unless-contains /var/lib/tailscale/tailscaled.state _current-profile TS_AUTHKEY \
  -- /usr/local/bin/containerboot'

  log "Creating ${PROXY} on ${ACCESS_NETWORK} (+ ${EGRESS_NETWORK} for egress/Infisical)"
  local args=(
    create --name "${PROXY}" --restart unless-stopped
    --network "${ACCESS_NETWORK}"
    -e TS_STATE_DIR=/var/lib/tailscale
    -e TS_USERSPACE=true
    -e TS_ACCEPT_DNS=false
    -e TS_AUTH_ONCE=true
    -e "TS_EXTRA_ARGS=--shields-up --advertise-tags=${TS_TAG}"
    -e "TS_HOSTNAME=${PROXY}"
    -e "VAST_TS_HOST=${VAST_TS_HOST}"
    -e "VAST_PORT=${VAST_PORT}"
    -v "${STATE_DIR}:/var/lib/tailscale"
    "${INFISICAL_MOUNTS[@]}"
  )
  if "${DRY_RUN}"; then
    printf '[dry-run] docker'; printf ' %q' "${args[@]}"
    printf ' --env-file <(runtime_env <secret if minted>) --entrypoint /bin/sh %q -c %q\n' "${TS_IMAGE}" "${cmd}"
    dk network connect "${EGRESS_NETWORK}" "${PROXY}"
    dk start "${PROXY}"
    return 0
  fi
  # `docker create` first so the second network can be attached before start
  # (Infisical fetch and tailscale login both need egress on first boot).
  docker "${args[@]}" --env-file <(runtime_env "${secret}") \
    --entrypoint /bin/sh "${TS_IMAGE}" -c "${cmd}" >/dev/null
  docker network connect "${EGRESS_NETWORK}" "${PROXY}"
  docker start "${PROXY}" >/dev/null
}

connect_clients() {
  local c
  for c in "${CLIENTS[@]}"; do
    if "${DRY_RUN}"; then
      log "would check whether ${c} exists and is on ${ACCESS_NETWORK}"
      dk network connect "${ACCESS_NETWORK}" "${c}"
    elif ! container_exists "${c}"; then
      echo "WARNING: container ${c} not found; skipping (re-run once it exists)." >&2
    elif is_connected "${ACCESS_NETWORK}" "${c}"; then
      log "${c} already on ${ACCESS_NETWORK}"
    else
      log "Connecting ${c} to ${ACCESS_NETWORK}"
      docker network connect "${ACCESS_NETWORK}" "${c}"
    fi
  done
}

# Rent the GB10 on vast.ai. Runs after the proxy so the proxy is ready first.
# Nothing is rented without an explicit --offer-id. Secret values are only
# checked for presence, never printed.
provision_gb10() {
  local py="${PYTHON:-python3}" prov="${SCRIPT_DIR}/provision-gb10.py"
  if "${SKIP_PROVISION}"; then
    log "Skipping GB10 provisioning (--skip-provision)"
    return 0
  fi
  if "${DRY_RUN}"; then
    if [[ -n "${OFFER_ID}" ]]; then
      log "GB10 provisioning preview (offline, nothing is rented):"
      "${py}" "${prov}" create --offer-id "${OFFER_ID}" ${MAX_PRICE:+--max-price "${MAX_PRICE}"}
    else
      log "would run provision-gb10.py status (skip if a gb10-vast instance exists)"
      log "would run provision-gb10.py search (no --offer-id: nothing is rented)"
    fi
    return 0
  fi

  "${py}" -c 'import vastai_sdk' >/dev/null 2>&1 \
    || die "vastai_sdk is not importable with ${py}. Run: ${py} -m pip install -r ${SCRIPT_DIR}/requirements.txt (or set PYTHON=/path/to/venv/bin/python), or pass --skip-provision."

  log "Checking for an existing gb10-vast instance"
  local ids
  ids="$("${py}" "${prov}" status --ids)" || die "could not reach vast.ai (see error above)"
  if [[ -n "${ids}" ]]; then
    log "gb10-vast instance already exists (id: $(echo ${ids})); not creating another"
    "${py}" "${prov}" status
    return 0
  fi
  if [[ -z "${OFFER_ID}" ]]; then
    "${py}" "${prov}" search
    log "No gb10-vast instance. Re-run with --offer-id <id> to rent (needs TS_AUTHKEY: a fresh single-use GB10 key)."
    return 0
  fi
  [[ -n "${TS_AUTHKEY:-}" ]] || die "TS_AUTHKEY is not set. Export a FRESH single-use, ephemeral, tag:vastai-gb10 key (the GB10's key, not the proxy's)."
  log "Renting vast.ai offer ${OFFER_ID} (billable)"
  "${py}" "${prov}" create --offer-id "${OFFER_ID}" --yes ${MAX_PRICE:+--max-price "${MAX_PRICE}"}
}

main() {
  "${DRY_RUN}" && log "DRY RUN: nothing will be executed (DOCKER_CONTEXT=${DOCKER_CONTEXT})"
  ensure_network
  ensure_state_dir
  local secret
  secret="$(mint_if_needed)"
  # In dry-run the placeholder line is only informational.
  "${DRY_RUN}" && secret=""
  run_proxy "${secret}"
  connect_clients
  provision_gb10
  log "Done. Clients use http://${PROXY}:${VAST_PORT}/v1 -- see README.md to verify."
}

main
