#!/usr/bin/env bash
# Single deploy script: L1 (Sepolia) + L2 (Fluent Devnet) with Foundry.
# - Deploy FluentBridge on L1 and L2 (DeployFluentBridge.s.sol), link bridges
# - Deploy L1 gateway stack: ERC20 factory + PaymentGateway (DeployL1.s.sol)
# - Deploy L2 gateway stack: UniversalTokenFactory + PaymentGateway (DeployL2.s.sol)
# - Link gateways: L1 uses setOtherSideUniversal(L2), L2 uses setOtherSide(L1)
# Writes: deployments/sepolia-l1-bridge.json, sepolia-l1-stack.json, fluent-testnet-l2-bridge.json, fluent-testnet-l2-stack.json
#
# Required env vars:
#   PRIVATE_KEY
#
# Optional env vars:
#   L1_RPC_URL           (default: Sepolia public RPC)
#   L2_RPC_URL           (default: Fluent dev RPC)
#   L2_CHAIN_ID          (default: 901, for setOtherSideUniversal)
#   RELAYER_ADDRESS      (defaults to deployer address)
#   INITIAL_OWNER        (defaults to deployer address)
#   RECEIVE_MSG_DEADLINE (defaults to 0)
#   L1_L1BLOCK_ORACLE    (defaults to zero address)
#   L2_L1BLOCK_ORACLE    (defaults to zero address)
#   MOCK_SUPPLY          (defaults to 1,000,000 tokens @18)
#
# Usage:
#   ./scripts/deploy-sepolia-fluent-devnet.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

command -v forge >/dev/null || { echo "forge is required"; exit 1; }
command -v cast >/dev/null || { echo "cast is required"; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }

PRIVATE_KEY="${PRIVATE_KEY:-}"
[ -n "$PRIVATE_KEY" ] || { echo "PRIVATE_KEY is required"; exit 1; }

L1_RPC_URL="${L1_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
L2_RPC_URL="${L2_RPC_URL:-https://rpc.dev.fluent.xyz/}"
RECEIVE_MSG_DEADLINE="${RECEIVE_MSG_DEADLINE:-0}"
L1_L1BLOCK_ORACLE="${L1_L1BLOCK_ORACLE:-0x0000000000000000000000000000000000000000}"
L2_L1BLOCK_ORACLE="${L2_L1BLOCK_ORACLE:-0x0000000000000000000000000000000000000000}"
MOCK_SUPPLY="${MOCK_SUPPLY:-1000000000000000000000000}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

DEPLOYER_ADDRESS="$(cast wallet address --private-key "$PRIVATE_KEY")"
RELAYER_ADDRESS="${RELAYER_ADDRESS:-$DEPLOYER_ADDRESS}"
INITIAL_OWNER="${INITIAL_OWNER:-$DEPLOYER_ADDRESS}"

read_json_key() {
  local file="$1"
  local key="$2"
  python3 - "$file" "$key" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
value = data.get(key) or (data.get("deployment") or {}).get(key)
print(value or "")
PY
}

send_tx() {
  local rpc="$1"
  local to="$2"
  local sig="$3"
  shift 3
  cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" >/dev/null
}

run_bridge_deploy() {
  local rpc="$1"
  local oracle="$2"
  local output="$3"
  INITIAL_OWNER="$INITIAL_OWNER" \
  BRIDGE_AUTHORITY="$RELAYER_ADDRESS" \
  RECEIVE_MSG_DEADLINE="$RECEIVE_MSG_DEADLINE" \
  L1_BLOCK_ORACLE="$oracle" \
  OTHER_BRIDGE_PLACEHOLDER="0x0000000000000000000000000000000000000001" \
  OUTPUT_PATH="$output" \
  forge script scripts/deploy/DeployFluentBridge.s.sol:DeployFluentBridge \
    --rpc-url "$rpc" \
    --private-key "$PRIVATE_KEY" \
    --broadcast
}

run_l1_gateway_deploy() {
  local rpc="$1"
  local bridge="$2"
  local deploy_mock="$3"
  local output="$4"
  INITIAL_OWNER="$INITIAL_OWNER" \
  BRIDGE_ADDRESS="$bridge" \
  DEPLOY_MOCK="$deploy_mock" \
  MOCK_SUPPLY="$MOCK_SUPPLY" \
  MOCK_RECIPIENT="$DEPLOYER_ADDRESS" \
  OUTPUT_PATH="$output" \
  forge script scripts/deploy/DeployL1.s.sol:DeployL1 \
    --rpc-url "$rpc" \
    --private-key "$PRIVATE_KEY" \
    --broadcast
}

run_l2_gateway_deploy() {
  local rpc="$1"
  local bridge="$2"
  local output="$3"
  INITIAL_OWNER="$INITIAL_OWNER" \
  BRIDGE_ADDRESS="$bridge" \
  OUTPUT_PATH="$output" \
  forge script scripts/deploy/DeployL2.s.sol:DeployL2 \
    --rpc-url "$rpc" \
    --private-key "$PRIVATE_KEY" \
    --broadcast
}

L1_BRIDGE_JSON="$TMP_DIR/l1-bridge.json"
L2_BRIDGE_JSON="$TMP_DIR/l2-bridge.json"
L1_STACK_JSON="$TMP_DIR/l1-stack.json"
L2_STACK_JSON="$TMP_DIR/l2-stack.json"

echo "=== Step 1: Deploy L1 bridge with DeployFluentBridge.s.sol ==="
run_bridge_deploy "$L1_RPC_URL" "$L1_L1BLOCK_ORACLE" "$L1_BRIDGE_JSON"
L1_BRIDGE="$(read_json_key "$L1_BRIDGE_JSON" "bridge")"
echo "L1 FluentBridge: $L1_BRIDGE"

echo ""
echo "=== Step 2: Deploy L2 bridge with DeployFluentBridge.s.sol ==="
run_bridge_deploy "$L2_RPC_URL" "$L2_L1BLOCK_ORACLE" "$L2_BRIDGE_JSON"
L2_BRIDGE="$(read_json_key "$L2_BRIDGE_JSON" "bridge")"
echo "L2 FluentBridge: $L2_BRIDGE"

echo ""
echo "=== Step 3: Link bridges ==="
send_tx "$L1_RPC_URL" "$L1_BRIDGE" "setOtherBridge(address)" "$L2_BRIDGE"
send_tx "$L2_RPC_URL" "$L2_BRIDGE" "setOtherBridge(address)" "$L1_BRIDGE"
echo "Bridges linked."

echo ""
echo "=== Step 4: Deploy L1 gateway stack with DeployL1.s.sol ==="
run_l1_gateway_deploy "$L1_RPC_URL" "$L1_BRIDGE" "true" "$L1_STACK_JSON"
L1_FACTORY="$(read_json_key "$L1_STACK_JSON" "factory")"
L1_BEACON="$(read_json_key "$L1_STACK_JSON" "factory_beacon")"
L1_PEGGED_IMPL="$(read_json_key "$L1_STACK_JSON" "pegged_impl")"
L1_GATEWAY="$(read_json_key "$L1_STACK_JSON" "gateway")"
MOCK_TOKEN="$(read_json_key "$L1_STACK_JSON" "mock_token")"
echo "L1 Gateway: $L1_GATEWAY  Factory: $L1_FACTORY  Beacon: $L1_BEACON"

echo ""
echo "=== Step 5: Deploy L2 gateway stack with DeployL2.s.sol (UniversalTokenFactory) ==="
run_l2_gateway_deploy "$L2_RPC_URL" "$L2_BRIDGE" "$L2_STACK_JSON"
L2_FACTORY="$(read_json_key "$L2_STACK_JSON" "factory")"
L2_PEGGED_IMPL="$(read_json_key "$L2_STACK_JSON" "pegged_impl")"
L2_GATEWAY="$(read_json_key "$L2_STACK_JSON" "gateway")"
echo "L2 Gateway: $L2_GATEWAY  Factory: $L2_FACTORY"

L2_CHAIN_ID="${L2_CHAIN_ID:-901}"
echo ""
echo "=== Step 6: Set other side gateway config ==="
send_tx "$L1_RPC_URL" "$L1_GATEWAY" "setOtherSideUniversal(address,address,address,uint256)" "$L2_GATEWAY" "$L2_PEGGED_IMPL" "$L2_FACTORY" "$L2_CHAIN_ID"
send_tx "$L2_RPC_URL" "$L2_GATEWAY" "setOtherSide(address,address,address,address)" "$L1_GATEWAY" "$L1_PEGGED_IMPL" "$L1_FACTORY" "$L1_BEACON"
echo "Gateways linked."

mkdir -p deployments
cp "$L1_BRIDGE_JSON" deployments/sepolia-l1-bridge.json
cp "$L2_BRIDGE_JSON" deployments/fluent-testnet-l2-bridge.json
cp "$L1_STACK_JSON" deployments/sepolia-l1-stack.json
cp "$L2_STACK_JSON" deployments/fluent-testnet-l2-stack.json

echo ""
echo "=== Deployment complete ==="
echo "L1_BRIDGE_ADDRESS=$L1_BRIDGE"
echo "L2_BRIDGE_ADDRESS=$L2_BRIDGE"
echo "L1_GATEWAY_ADDRESS=$L1_GATEWAY"
echo "L2_GATEWAY_ADDRESS=$L2_GATEWAY"
echo "L1_FACTORY_ADDRESS=$L1_FACTORY"
echo "L2_FACTORY_ADDRESS=$L2_FACTORY"
echo "MOCK_TOKEN_ADDRESS=$MOCK_TOKEN"
echo ""
echo "=== Next: deposit (L1 -> L2) with cast ==="
echo "  RECIPIENT_ADDRESS=<l2-recipient> AMOUNT=1000000000000000000"
echo "  cast send \$MOCK_TOKEN_ADDRESS \"approve(address,uint256)\" \$L1_GATEWAY_ADDRESS \$AMOUNT --rpc-url \"$L1_RPC_URL\" --private-key <key>"
echo "  cast send \$L1_GATEWAY_ADDRESS \"sendTokens(address,address,uint256)\" \$MOCK_TOKEN_ADDRESS \$RECIPIENT_ADDRESS \$AMOUNT --rpc-url \"$L1_RPC_URL\" --private-key <key>"
echo ""
echo "=== Relayer ==="
echo "  L1_BRIDGE_ADDRESS=$L1_BRIDGE L2_BRIDGE_ADDRESS=$L2_BRIDGE run your relayer with these addresses"
