#!/usr/bin/env bash
# Deploy Fluent testnet (L2) only: FluentBridge + UniversalTokenFactory + PaymentGateway (no mock token).
# Writes deployments/fluent_testnet.json. Run setup.bash after to link with Sepolia (source).
#
# Config: config/fluent_testnet.json
# Env: .env with PRIVATE_KEY, FLUENT_TESTNET_RPC_URL (and optional FLUENT_TESTNET_BLOCK_EXPLORER_URL, L2_GAS_PRICE)
#
# Usage:
#   ./scripts/deploy/bash/fluent_deploy.bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$PROJECT_ROOT"

command -v forge >/dev/null || { echo "forge is required"; exit 1; }
command -v cast >/dev/null || { echo "cast is required"; exit 1; }
if command -v python3 >/dev/null; then PYTHON=python3; elif command -v python >/dev/null; then PYTHON=python; else echo "python3 or python is required"; exit 1; fi

export FOUNDRY_OUT="${FOUNDRY_OUT:-forge-out}"

if [ -f .env ]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

PRIVATE_KEY="${PRIVATE_KEY:-}"
[ -n "$PRIVATE_KEY" ] || { echo "PRIVATE_KEY is required (set in .env or environment)"; exit 1; }

CONFIG_L2="${CONFIG_L2:-config/fluent_testnet.json}"
[ -f "$CONFIG_L2" ] || { echo "Config not found: $CONFIG_L2"; exit 1; }

DEPLOYMENT_JSON_SCRIPT="$PROJECT_ROOT/scripts/deploy/deployment_json.py"

read_config_key() {
  "$PYTHON" "$DEPLOYMENT_JSON_SCRIPT" get "$1" "$2"
}

expand_env() {
  local v="$1"
  v="${v//\$\{FLUENT_TESTNET_RPC_URL\}/${FLUENT_TESTNET_RPC_URL:-}}"
  v="${v//\$\{FLUENT_TESTNET_BLOCK_EXPLORER_URL\}/${FLUENT_TESTNET_BLOCK_EXPLORER_URL:-}}"
  echo "$v"
}

require_nonzero() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ] || [ "$value" = "0" ] || [ "$value" = "0x0000000000000000000000000000000000000000" ]; then
    echo "Required non-zero value missing or zero: $name"
    exit 1
  fi
}

L2_CHAIN_ID="$(read_config_key "$CONFIG_L2" chainId)"
[ -z "$L2_CHAIN_ID" ] && L2_CHAIN_ID="${L2_CHAIN_ID:-20994}"
L2_RPC_URL="$(expand_env "$(read_config_key "$CONFIG_L2" rpcUrl)")"
L2_BLOCK_EXPLORER_URL="$(expand_env "$(read_config_key "$CONFIG_L2" blockExplorerUrl)")"
L2_INITIAL_OWNER="$(read_config_key "$CONFIG_L2" initialOwner)"
L2_BRIDGE_AUTHORITY="$(read_config_key "$CONFIG_L2" bridgeAuthority)"
L2_RECEIVE_MSG_DEADLINE="$(read_config_key "$CONFIG_L2" receiveMessageDeadline)"
L2_L1BLOCK_ORACLE="$(read_config_key "$CONFIG_L2" l1BlockOracle)"

DEPLOYER_ADDRESS="$(cast wallet address --private-key "$PRIVATE_KEY")"
L2_INITIAL_OWNER="${L2_INITIAL_OWNER:-${INITIAL_OWNER:-$DEPLOYER_ADDRESS}}"
L2_BRIDGE_AUTHORITY="${L2_BRIDGE_AUTHORITY:-${RELAYER_ADDRESS:-$DEPLOYER_ADDRESS}}"
[ -z "$L2_RECEIVE_MSG_DEADLINE" ] && L2_RECEIVE_MSG_DEADLINE="${RECEIVE_MSG_DEADLINE:-0}"
L2_L1BLOCK_ORACLE="${L2_L1BLOCK_ORACLE:-0x0000000000000000000000000000000000000000}"

require_nonzero "L2 rpcUrl (set FLUENT_TESTNET_RPC_URL in .env if using placeholder)" "$L2_RPC_URL"
require_nonzero "L2 initialOwner" "$L2_INITIAL_OWNER"
L2_CHAIN_ID_RPC="$(cast chain-id --rpc-url "$L2_RPC_URL" 2>/dev/null || true)"
[ -n "$L2_CHAIN_ID_RPC" ] && L2_CHAIN_ID="$L2_CHAIN_ID_RPC" && echo "Using L2 chain id from RPC: $L2_CHAIN_ID"
require_nonzero "L2 chainId" "$L2_CHAIN_ID"

TMP_DIR="$PROJECT_ROOT/deployments/.tmp"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

read_json_key() {
  "$PYTHON" "$DEPLOYMENT_JSON_SCRIPT" get "$1" "$2"
}

run_forge() {
  local rpc="$1"
  shift 1
  FOUNDRY_OUT="${FOUNDRY_OUT:-forge-out}" forge script "$@" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --broadcast
}

run_forge_skip_sim() {
  local rpc="$1"
  shift 1
  local gas_price="${L2_GAS_PRICE:-0.00000002ether}"
  FOUNDRY_OUT="${FOUNDRY_OUT:-forge-out}" forge script "$@" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" \
    --broadcast --skip-simulation --slow --legacy --with-gas-price "$gas_price" --gas-estimate-multiplier 150
}

L2_BRIDGE_JSON="$TMP_DIR/l2-bridge.json"
L2_FACTORY_JSON="$TMP_DIR/l2-factory.json"
L2_GATEWAY_JSON="$TMP_DIR/l2-gateway.json"

echo ""
echo "=== Deploy L2 FluentBridge ==="
INITIAL_OWNER="$L2_INITIAL_OWNER" BRIDGE_AUTHORITY="$L2_BRIDGE_AUTHORITY" RECEIVE_MSG_DEADLINE="$L2_RECEIVE_MSG_DEADLINE" \
  L1_BLOCK_ORACLE="$L2_L1BLOCK_ORACLE" OTHER_BRIDGE_PLACEHOLDER="0x0000000000000000000000000000000000000001" \
  OUTPUT_PATH="$L2_BRIDGE_JSON" \
  run_forge "$L2_RPC_URL" scripts/deploy/DeployFluentBridge.s.sol:DeployFluentBridge
L2_BRIDGE="$(read_json_key "$L2_BRIDGE_JSON" bridge)"
require_nonzero "L2 bridge" "$L2_BRIDGE"
echo "L2 FluentBridge: $L2_BRIDGE"

echo ""
echo "=== Deploy L2 UniversalTokenFactory [--skip-simulation] ==="
sleep 2
INITIAL_OWNER="$L2_INITIAL_OWNER" OUTPUT_PATH="$L2_FACTORY_JSON" \
  run_forge_skip_sim "$L2_RPC_URL" scripts/deploy/DeployUniversalTokenFactory.s.sol:DeployUniversalTokenFactory
L2_FACTORY="$(read_json_key "$L2_FACTORY_JSON" factory)"
require_nonzero "L2 factory" "$L2_FACTORY"
echo "L2 Factory: $L2_FACTORY"

echo ""
echo "=== Deploy L2 PaymentGateway [--skip-simulation] ==="
INITIAL_OWNER="$L2_INITIAL_OWNER" BRIDGE_ADDRESS="$L2_BRIDGE" FACTORY_ADDRESS="$L2_FACTORY" OUTPUT_PATH="$L2_GATEWAY_JSON" \
  run_forge_skip_sim "$L2_RPC_URL" scripts/deploy/DeployPaymentGateway.s.sol:DeployPaymentGateway
L2_GATEWAY="$(read_json_key "$L2_GATEWAY_JSON" gateway)"
require_nonzero "L2 gateway" "$L2_GATEWAY"
echo "L2 Gateway: $L2_GATEWAY"

echo ""
echo "=== Save deployment (deployments/fluent_testnet.json) ==="
L2_CONFIG_EXPANDED="$TMP_DIR/fluent_testnet_expanded.json"
"$PYTHON" "$PROJECT_ROOT/scripts/deploy/expand_config.py" \
  "$CONFIG_L2" "$L2_CONFIG_EXPANDED" "$L2_RPC_URL" "$L2_BLOCK_EXPLORER_URL" "$L2_CHAIN_ID"
mkdir -p deployments
"$PYTHON" "$DEPLOYMENT_JSON_SCRIPT" merge_chain "$L2_CONFIG_EXPANDED" "deployments/fluent_testnet.json" \
  "$L2_BRIDGE_JSON" "$L2_FACTORY_JSON" "$L2_GATEWAY_JSON" --l2

echo ""
echo "=== Fluent deployment complete ==="
echo "  deployments/fluent_testnet.json"
echo "  L2_BRIDGE=$L2_BRIDGE"
echo "  L2_FACTORY=$L2_FACTORY"
echo "  L2_GATEWAY=$L2_GATEWAY"
echo ""
echo "Next: run setup to link source (Sepolia) and destination (Fluent):"
echo "  ./scripts/deploy/bash/setup.bash --source sepolia --destination fluent_testnet"
