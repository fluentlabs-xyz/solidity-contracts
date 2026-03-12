#!/usr/bin/env bash
# Link source and destination chains: set other bridge on both, set other-side gateway config on both.
# Reads deployments/<source>.json and deployments/<destination>.json (addresses and RPC URLs).
#
# Usage:
#   ./scripts/deploy/bash/setup.bash --source sepolia --destination fluent_testnet
#
# Expects:
#   - deployments/sepolia.json (from sepolia_deploy.bash)
#   - deployments/fluent_testnet.json (from fluent_deploy.bash)
#   - .env with PRIVATE_KEY
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$PROJECT_ROOT"

SOURCE_CHAIN=""
DEST_CHAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source)  SOURCE_CHAIN="$2"; shift 2 ;;
    --destination) DEST_CHAIN="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; echo "Usage: $0 --source sepolia --destination fluent_testnet"; exit 1 ;;
  esac
done

[ -n "$SOURCE_CHAIN" ] || { echo "Missing --source (e.g. sepolia)"; exit 1; }
[ -n "$DEST_CHAIN" ] || { echo "Missing --destination (e.g. fluent_testnet)"; exit 1; }

command -v cast >/dev/null || { echo "cast is required"; exit 1; }
if command -v python3 >/dev/null; then PYTHON=python3; elif command -v python >/dev/null; then PYTHON=python; else echo "python3 or python is required"; exit 1; fi

if [ -f .env ]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

PRIVATE_KEY="${PRIVATE_KEY:-}"
[ -n "$PRIVATE_KEY" ] || { echo "PRIVATE_KEY is required (set in .env or environment)"; exit 1; }

DEPLOYMENT_JSON_SCRIPT="$PROJECT_ROOT/scripts/deploy/deployment_json.py"
SOURCE_JSON="$PROJECT_ROOT/deployments/${SOURCE_CHAIN}.json"
DEST_JSON="$PROJECT_ROOT/deployments/${DEST_CHAIN}.json"

[ -f "$SOURCE_JSON" ] || { echo "Source deployment not found: $SOURCE_JSON (run sepolia_deploy.bash first)"; exit 1; }
[ -f "$DEST_JSON" ] || { echo "Destination deployment not found: $DEST_JSON (run fluent_deploy.bash first)"; exit 1; }

read_json_key() {
  "$PYTHON" "$DEPLOYMENT_JSON_SCRIPT" get "$1" "$2"
}

require_nonzero() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ] || [ "$value" = "0" ] || [ "$value" = "0x0000000000000000000000000000000000000000" ]; then
    echo "Required non-zero value missing or zero: $name"
    exit 1
  fi
}

send_tx() {
  local rpc="$1" to="$2" sig="$3"
  shift 3
  cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" >/dev/null
}

# Source (e.g. Sepolia L1)
L1_RPC_URL="$(read_json_key "$SOURCE_JSON" rpcUrl)"
L1_BRIDGE="$(read_json_key "$SOURCE_JSON" bridge)"
L1_FACTORY="$(read_json_key "$SOURCE_JSON" factory)"
L1_GATEWAY="$(read_json_key "$SOURCE_JSON" gateway)"
L1_BEACON="$(read_json_key "$SOURCE_JSON" factory_beacon)"
L1_PEGGED_IMPL="$(read_json_key "$SOURCE_JSON" pegged_impl)"

# Destination (e.g. Fluent L2)
L2_RPC_URL="$(read_json_key "$DEST_JSON" rpcUrl)"
L2_CHAIN_ID="$(read_json_key "$DEST_JSON" chainId)"
L2_BRIDGE="$(read_json_key "$DEST_JSON" bridge)"
L2_FACTORY="$(read_json_key "$DEST_JSON" factory)"
L2_GATEWAY="$(read_json_key "$DEST_JSON" gateway)"

require_nonzero "Source rpcUrl" "$L1_RPC_URL"
require_nonzero "Source bridge" "$L1_BRIDGE"
require_nonzero "Source factory" "$L1_FACTORY"
require_nonzero "Source gateway" "$L1_GATEWAY"
require_nonzero "Source factory_beacon" "$L1_BEACON"
require_nonzero "Source pegged_impl" "$L1_PEGGED_IMPL"
require_nonzero "Destination rpcUrl" "$L2_RPC_URL"
require_nonzero "Destination chainId" "$L2_CHAIN_ID"
require_nonzero "Destination bridge" "$L2_BRIDGE"
require_nonzero "Destination factory" "$L2_FACTORY"
require_nonzero "Destination gateway" "$L2_GATEWAY"

# L2 Universal: pegged "impl" is the precompile runtime
L2_PEGGED_IMPL="0x0000000000000000000000000000000000520008"

echo "=== Setup: source=$SOURCE_CHAIN -> destination=$DEST_CHAIN ==="
echo "  Source bridge: $L1_BRIDGE"
echo "  Destination bridge: $L2_BRIDGE"
echo ""

echo "=== Link bridges ==="
send_tx "$L1_RPC_URL" "$L1_BRIDGE" "setOtherBridge(address)" "$L2_BRIDGE"
send_tx "$L2_RPC_URL" "$L2_BRIDGE" "setOtherBridge(address)" "$L1_BRIDGE"
echo "Bridges linked."

echo ""
echo "=== Set other-side gateway config ==="
send_tx "$L1_RPC_URL" "$L1_GATEWAY" "setOtherSideUniversal(address,address,address,uint256)" "$L2_GATEWAY" "$L2_PEGGED_IMPL" "$L2_FACTORY" "$L2_CHAIN_ID"
send_tx "$L2_RPC_URL" "$L2_GATEWAY" "setOtherSide(address,address,address,address)" "$L1_GATEWAY" "$L1_PEGGED_IMPL" "$L1_FACTORY" "$L1_BEACON"
echo "Gateways linked."

echo ""
echo "=== Setup complete ==="
echo "  Source ($SOURCE_CHAIN) <-> Destination ($DEST_CHAIN) are linked."
echo "  You can now deposit tokens from source to destination (e.g. sendTokens on L1 gateway)."
