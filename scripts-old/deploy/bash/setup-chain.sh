#!/usr/bin/env bash
# Link L1 (Sepolia) and L2 (Fluent Testnet) after both sides are deployed.
# - setOtherBridge on both bridges
# - setOtherSide on both gateways (other gateway, pegged impl, factory, beacon)
#
# Reads: deployments/sepolia-l1-bridge.json, deployments/sepolia-l1-stack.json
#        deployments/fluent-testnet-l2-bridge.json, deployments/fluent-testnet-l2-stack.json
# Required: PRIVATE_KEY
# Optional: L1_RPC_URL, L2_RPC_URL
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

command -v cast >/dev/null || { echo "cast required"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

PRIVATE_KEY="${PRIVATE_KEY:-}"
[ -n "$PRIVATE_KEY" ] || { echo "PRIVATE_KEY required"; exit 1; }

L1_RPC_URL="${L1_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
L2_RPC_URL="${L2_RPC_URL:-${RPC_URL_FLUENT_TESTNET:-https://rpc.testnet.fluent.xyz/}}"

for f in deployments/sepolia-l1-bridge.json deployments/sepolia-l1-stack.json \
         deployments/fluent-testnet-l2-bridge.json deployments/fluent-testnet-l2-stack.json; do
  [ -f "$f" ] || { echo "Missing $f"; exit 1; }
done

read_json_key() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f).get(sys.argv[2], "") or "")
PY
}

L1_BRIDGE="$(read_json_key deployments/sepolia-l1-bridge.json bridge)"
L1_GATEWAY="$(read_json_key deployments/sepolia-l1-stack.json gateway)"
L1_PEGGED_IMPL="$(read_json_key deployments/sepolia-l1-stack.json pegged_impl)"
L1_FACTORY="$(read_json_key deployments/sepolia-l1-stack.json factory)"
L1_BEACON="$(read_json_key deployments/sepolia-l1-stack.json factory_beacon)"

L2_BRIDGE="$(read_json_key deployments/fluent-testnet-l2-bridge.json bridge)"
L2_GATEWAY="$(read_json_key deployments/fluent-testnet-l2-stack.json gateway)"
L2_PEGGED_IMPL="$(read_json_key deployments/fluent-testnet-l2-stack.json pegged_impl)"
L2_FACTORY="$(read_json_key deployments/fluent-testnet-l2-stack.json factory)"
L2_BEACON="$(read_json_key deployments/fluent-testnet-l2-stack.json factory_beacon)"
L2_FACTORY_IMPL="$(read_json_key deployments/fluent-testnet-l2-stack.json factory_impl)"
L2_CHAIN_ID="${L2_CHAIN_ID:-20994}"

send_tx() {
  local rpc="$1" to="$2" sig="$3"
  shift 3
  cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$PRIVATE_KEY"
}

echo "=== Linking bridges ==="
send_tx "$L1_RPC_URL" "$L1_BRIDGE" "setOtherBridge(address)" "$L2_BRIDGE"
send_tx "$L2_RPC_URL" "$L2_BRIDGE" "setOtherBridge(address)" "$L1_BRIDGE"
echo "Bridges linked."

echo ""
echo "=== Linking gateways (setOtherSide) ==="
if [ "$L2_BEACON" = "0x0000000000000000000000000000000000000000" ]; then
  send_tx "$L1_RPC_URL" "$L1_GATEWAY" "setOtherSideUniversal(address,address,address,uint256)" \
    "$L2_GATEWAY" "$L2_FACTORY_IMPL" "$L2_FACTORY" "$L2_CHAIN_ID"
else
  send_tx "$L1_RPC_URL" "$L1_GATEWAY" "setOtherSide(address,address,address,address)" \
    "$L2_GATEWAY" "$L2_PEGGED_IMPL" "$L2_FACTORY" "$L2_BEACON"
fi
send_tx "$L2_RPC_URL" "$L2_GATEWAY" "setOtherSide(address,address,address,address)" \
  "$L1_GATEWAY" "$L1_PEGGED_IMPL" "$L1_FACTORY" "$L1_BEACON"
echo "Gateways linked."

echo ""
echo "=== Setup complete ==="
echo "L1 Bridge: $L1_BRIDGE  L2 Bridge: $L2_BRIDGE"
echo "L1 Gateway: $L1_GATEWAY  L2 Gateway: $L2_GATEWAY"
echo ""
echo "Next: use ./scripts/bash/transfer-l1-to-l2.sh to send mock token L1 -> L2 (relayer must be running)."
