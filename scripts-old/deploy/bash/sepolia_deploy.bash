#!/usr/bin/env bash
# Deploy Sepolia (L1) only: FluentBridge + ERC20TokenFactory + PaymentGateway + mock token.
# Writes deployments/sepolia.json. Run setup.bash after to link with Fluent (destination).
#
# Config: config/sepolia.json
# Env: .env with PRIVATE_KEY, SEPOLIA_RPC_URL (and optional SEPOLIA_BLOCK_EXPLORER_URL)
#
# Usage:
#   ./scripts/deploy/bash/sepolia_deploy.bash
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

CONFIG_L1="${CONFIG_L1:-config/sepolia.json}"
[ -f "$CONFIG_L1" ] || { echo "Config not found: $CONFIG_L1"; exit 1; }

DEPLOYMENT_JSON_SCRIPT="$PROJECT_ROOT/scripts/deploy/deployment_json.py"

read_config_key() {
  "$PYTHON" "$DEPLOYMENT_JSON_SCRIPT" get "$1" "$2"
}

expand_env() {
  local v="$1"
  v="${v//\$\{SEPOLIA_RPC_URL\}/${SEPOLIA_RPC_URL:-}}"
  v="${v//\$\{SEPOLIA_BLOCK_EXPLORER_URL\}/${SEPOLIA_BLOCK_EXPLORER_URL:-}}"
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

L1_CHAIN_ID="$(read_config_key "$CONFIG_L1" chainId)"
[ -z "$L1_CHAIN_ID" ] && L1_CHAIN_ID="${L1_CHAIN_ID:-11155111}"
L1_RPC_URL="$(expand_env "$(read_config_key "$CONFIG_L1" rpcUrl)")"
L1_BLOCK_EXPLORER_URL="$(expand_env "$(read_config_key "$CONFIG_L1" blockExplorerUrl)")"
L1_INITIAL_OWNER="$(read_config_key "$CONFIG_L1" initialOwner)"
L1_BRIDGE_AUTHORITY="$(read_config_key "$CONFIG_L1" bridgeAuthority)"
L1_RECEIVE_MSG_DEADLINE="$(read_config_key "$CONFIG_L1" receiveMessageDeadline)"
L1_L1BLOCK_ORACLE="$(read_config_key "$CONFIG_L1" l1BlockOracle)"

DEPLOYER_ADDRESS="$(cast wallet address --private-key "$PRIVATE_KEY")"
L1_INITIAL_OWNER="${L1_INITIAL_OWNER:-${INITIAL_OWNER:-$DEPLOYER_ADDRESS}}"
L1_BRIDGE_AUTHORITY="${L1_BRIDGE_AUTHORITY:-${RELAYER_ADDRESS:-$DEPLOYER_ADDRESS}}"
[ -z "$L1_RECEIVE_MSG_DEADLINE" ] && L1_RECEIVE_MSG_DEADLINE="${RECEIVE_MSG_DEADLINE:-0}"
L1_L1BLOCK_ORACLE="${L1_L1BLOCK_ORACLE:-0x0000000000000000000000000000000000000000}"

require_nonzero "L1 rpcUrl (set SEPOLIA_RPC_URL in .env if using placeholder)" "$L1_RPC_URL"
require_nonzero "L1 initialOwner" "$L1_INITIAL_OWNER"

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

L1_BRIDGE_JSON="$TMP_DIR/l1-bridge.json"
L1_FACTORY_JSON="$TMP_DIR/l1-factory.json"
L1_GATEWAY_JSON="$TMP_DIR/l1-gateway.json"
L1_MOCK_JSON="$TMP_DIR/l1-mock.json"

echo ""
echo "=== Deploy L1 FluentBridge ==="
INITIAL_OWNER="$L1_INITIAL_OWNER" BRIDGE_AUTHORITY="$L1_BRIDGE_AUTHORITY" RECEIVE_MSG_DEADLINE="$L1_RECEIVE_MSG_DEADLINE" \
  L1_BLOCK_ORACLE="$L1_L1BLOCK_ORACLE" OTHER_BRIDGE_PLACEHOLDER="0x0000000000000000000000000000000000000001" \
  OUTPUT_PATH="$L1_BRIDGE_JSON" \
  run_forge "$L1_RPC_URL" scripts/deploy/DeployFluentBridge.s.sol:DeployFluentBridge
L1_BRIDGE="$(read_json_key "$L1_BRIDGE_JSON" bridge)"
require_nonzero "L1 bridge" "$L1_BRIDGE"
echo "L1 FluentBridge: $L1_BRIDGE"

echo ""
echo "=== Deploy L1 ERC20TokenFactory ==="
INITIAL_OWNER="$L1_INITIAL_OWNER" OUTPUT_PATH="$L1_FACTORY_JSON" \
  run_forge "$L1_RPC_URL" scripts/deploy/DeployERC20TokenFactory.s.sol:DeployERC20TokenFactory
[ -f "$L1_FACTORY_JSON" ] || { echo "Missing deployment JSON: $L1_FACTORY_JSON"; exit 1; }
L1_FACTORY="$(read_json_key "$L1_FACTORY_JSON" factory)"
require_nonzero "L1 factory" "${L1_FACTORY:-}"
echo "L1 Factory: $L1_FACTORY"

echo ""
echo "=== Deploy L1 PaymentGateway ==="
INITIAL_OWNER="$L1_INITIAL_OWNER" BRIDGE_ADDRESS="$L1_BRIDGE" FACTORY_ADDRESS="$L1_FACTORY" OUTPUT_PATH="$L1_GATEWAY_JSON" \
  run_forge "$L1_RPC_URL" scripts/deploy/DeployPaymentGateway.s.sol:DeployPaymentGateway
L1_GATEWAY="$(read_json_key "$L1_GATEWAY_JSON" gateway)"
require_nonzero "L1 gateway" "$L1_GATEWAY"
echo "L1 Gateway: $L1_GATEWAY"

echo ""
echo "=== Deploy mock token on L1 ==="
MOCK_SUPPLY="${MOCK_SUPPLY:-1000000000000000000000000}"
INITIAL_OWNER="$L1_INITIAL_OWNER" MOCK_ERC20_RECIPIENT="${MOCK_ERC20_RECIPIENT:-$L1_INITIAL_OWNER}" MOCK_ERC20_SUPPLY="$MOCK_SUPPLY" \
  OUTPUT_PATH="$L1_MOCK_JSON" \
  run_forge "$L1_RPC_URL" scripts/deploy/DeployMockERC20Token.s.sol:DeployMockERC20Token
MOCK_TOKEN="$(read_json_key "$L1_MOCK_JSON" mock_erc20)"
echo "L1 Mock token: ${MOCK_TOKEN:-none}"

echo ""
echo "=== Save deployment (deployments/sepolia.json) ==="
L1_CONFIG_EXPANDED="$TMP_DIR/sepolia_expanded.json"
"$PYTHON" "$PROJECT_ROOT/scripts/deploy/expand_config.py" \
  "$CONFIG_L1" "$L1_CONFIG_EXPANDED" "$L1_RPC_URL" "$L1_BLOCK_EXPLORER_URL" "$L1_CHAIN_ID"
mkdir -p deployments
"$PYTHON" "$DEPLOYMENT_JSON_SCRIPT" merge_chain "$L1_CONFIG_EXPANDED" "deployments/sepolia.json" \
  "$L1_BRIDGE_JSON" "$L1_FACTORY_JSON" "$L1_GATEWAY_JSON" "$L1_MOCK_JSON"

echo ""
echo "=== Sepolia deployment complete ==="
echo "  deployments/sepolia.json"
echo "  L1_BRIDGE=$L1_BRIDGE"
echo "  L1_FACTORY=$L1_FACTORY"
echo "  L1_GATEWAY=$L1_GATEWAY"
echo "  MOCK_TOKEN=${MOCK_TOKEN:-}"
echo ""
echo "Next: deploy Fluent (./scripts/deploy/bash/fluent_deploy.bash), then run setup:"
echo "  ./scripts/deploy/bash/setup.bash --source sepolia --destination fluent_testnet"
