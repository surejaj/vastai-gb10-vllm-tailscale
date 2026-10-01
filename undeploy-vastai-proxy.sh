#!/usr/bin/env bash
# Undeploy the vast.ai egress proxy from host 'wolverine'.
# Disconnects the three clients, removes vastai-ts-proxy and the
# vastai-access network. Tailscale state is kept unless --purge is passed.
#
# Usage: undeploy-vastai-proxy.sh [--purge] [--destroy-gb10] [--dry-run]
#   --destroy-gb10  also destroy the vast.ai gb10-vast instance (deletes its
#                   disk and models) via provision-gb10.py, after a prompt.
#                   Without it, a reminder is printed if one is still billing.
#                   Needs vastai-sdk (PYTHON, default python3); provision-gb10.py
#                   fetches the vast.ai key from Infisical (infisical login first).

set -euo pipefail

: "${DOCKER_CONTEXT:=unraid-remote}"
export DOCKER_CONTEXT

readonly PROXY="vastai-ts-proxy"
readonly ACCESS_NETWORK="vastai-access"
readonly DATA_ROOT="/mnt/main/app-data/vastai-ts-proxy"
readonly HELPER_IMAGE="busybox:stable"
readonly CLIENTS=(gbrain-server gbrain-worker Hermes-Agent)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PURGE=false
DESTROY_GB10=false
DRY_RUN=false
for arg in "$@"; do
  case "${arg}" in
    --purge) PURGE=true ;;
    --destroy-gb10) DESTROY_GB10=true ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "ERROR: unknown argument ${arg}" >&2; exit 1 ;;
  esac
done

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

dk() {
  if "${DRY_RUN}"; then
    printf '[dry-run] docker'; printf ' %q' "$@"; printf '\n'
  else
    docker "$@"
  fi
}

is_connected() {
  docker network inspect "${ACCESS_NETWORK}" --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -qx "$1"
}

disconnect_clients() {
  local c
  for c in "${CLIENTS[@]}"; do
    if "${DRY_RUN}"; then
      log "would check whether ${c} is on ${ACCESS_NETWORK}"
      dk network disconnect "${ACCESS_NETWORK}" "${c}"
    elif is_connected "${c}"; then
      log "Disconnecting ${c} from ${ACCESS_NETWORK}"
      docker network disconnect "${ACCESS_NETWORK}" "${c}"
    fi
  done
}

remove_proxy() {
  if "${DRY_RUN}"; then
    log "would check whether ${PROXY} exists"
    dk rm -f "${PROXY}"
  elif docker container inspect "${PROXY}" >/dev/null 2>&1; then
    log "Removing container ${PROXY}"
    docker rm -f "${PROXY}" >/dev/null
  fi
}

remove_network() {
  if "${DRY_RUN}"; then
    log "would check whether network ${ACCESS_NETWORK} exists"
    dk network rm "${ACCESS_NETWORK}"
  elif docker network inspect "${ACCESS_NETWORK}" >/dev/null 2>&1; then
    log "Removing network ${ACCESS_NETWORK}"
    docker network rm "${ACCESS_NETWORK}" >/dev/null
  fi
}

# Never touched here: the shared infisical-runtime volume, infisical-access.
purge_data() {
  echo "This will permanently delete the Tailscale state (node identity):"
  echo "  ${DATA_ROOT}"
  if "${DRY_RUN}"; then
    log "would prompt for confirmation ('vastai-ts-proxy')"
    dk run --rm --mount "type=bind,src=/mnt/main/app-data,dst=/x" --entrypoint sh "${HELPER_IMAGE}" -c 'rm -rf /x/vastai-ts-proxy'
    return 0
  fi
  echo "Type 'vastai-ts-proxy' to confirm, anything else cancels:"
  local confirm
  read -r confirm
  [[ "${confirm}" == "vastai-ts-proxy" ]] || die "Purge cancelled."
  docker run --rm --mount "type=bind,src=/mnt/main/app-data,dst=/x" --entrypoint sh "${HELPER_IMAGE}" -c 'rm -rf /x/vastai-ts-proxy'
}

# gb10_ids: print gb10-vast instance ids (one per line). Returns non-zero if
# they cannot be listed (no vastai_sdk, key lookup or API error).
gb10_ids() {
  local py="${PYTHON:-python3}"
  "${py}" -c 'import vastai_sdk' >/dev/null 2>&1 || return 1
  "${py}" "${SCRIPT_DIR}/provision-gb10.py" status --ids 2>/dev/null
}

destroy_gb10() {
  local py="${PYTHON:-python3}" prov="${SCRIPT_DIR}/provision-gb10.py"
  if "${DRY_RUN}"; then
    log "would list gb10-vast instances (provision-gb10.py status --ids)"
    log "would ask for confirmation, then run: provision-gb10.py destroy --instance-id <id> --yes"
    return 0
  fi
  "${py}" -c 'import vastai_sdk' >/dev/null 2>&1 \
    || die "vastai_sdk is not importable with ${py}. Run: ${py} -m pip install -r ${SCRIPT_DIR}/requirements.txt"
  local ids id confirm
  ids="$("${py}" "${prov}" status --ids)" || die "could not reach vast.ai (see error above); cannot destroy the GB10."
  if [[ -z "${ids}" ]]; then
    log "No gb10-vast instance to destroy."
    return 0
  fi
  for id in ${ids}; do
    echo "This destroys vast.ai instance ${id} (label gb10-vast): its disk and pulled models are deleted."
    echo "Type 'gb10-vast' to confirm, anything else cancels:"
    read -r confirm || confirm=""
    [[ "${confirm}" == "gb10-vast" ]] || die "GB10 destroy cancelled."
    "${py}" "${prov}" destroy --instance-id "${id}" --yes
  done
}

# Non-dry-run reminder; silent if it cannot check.
remind_gb10() {
  local ids
  ids="$(gb10_ids)" || return 0
  [[ -z "${ids}" ]] || log "REMINDER: gb10-vast instance still billing on vast.ai (id: $(echo ${ids})). Use --destroy-gb10 to destroy it."
}

main() {
  "${DRY_RUN}" && log "DRY RUN: nothing will be executed (DOCKER_CONTEXT=${DOCKER_CONTEXT})"
  disconnect_clients
  remove_proxy
  remove_network
  if "${PURGE}"; then
    purge_data
  else
    log "Tailscale state kept under ${DATA_ROOT}. Use --purge to delete it."
  fi
  if "${DESTROY_GB10}"; then
    destroy_gb10
  elif ! "${DRY_RUN}"; then
    remind_gb10
  fi
}

main
