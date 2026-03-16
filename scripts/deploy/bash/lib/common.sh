#!/usr/bin/env bash

set -euo pipefail

EIP1967_IMPL_SLOT="0x360894A13BA1A3210667C828492DB98DCA3E2076CC3735A920A3CA505D382BBC"

root_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd
}

load_dotenv_if_present() {
  if [[ -f ".env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source ".env"
    set +a
  fi
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env: $name"
    exit 1
  fi
}

json_get() {
  local file="$1"
  local query="$2"
  jq -er "$query" "$file"
}

impl_from_proxy() {
  local proxy="$1"
  local rpc_url="$2"
  cast parse-bytes32-address "$(cast storage "$proxy" "$EIP1967_IMPL_SLOT" --rpc-url "$rpc_url")"
}
