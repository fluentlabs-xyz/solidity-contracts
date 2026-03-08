#!/usr/bin/env bash
# Deploy L1 (Sepolia) + L2 (Fluent Devnet) using standalone scripts only.
#
# 1. Bridge: DeployFluentBridge.s.sol (both chains)
# 2. Gateways: DeployPaymentGateway.s.sol (both chains)
# 3. L1 factory: DeployERC20TokenFactory.s.sol
# 4. L2 factory: DeployUniversalTokenFactory.s.sol
# 5. Mock token (L1 only): DeployMockERC20Token.s.sol (dedicated step; can be removed later)
# 6. Set all configurations and link bridges/gateways
# 7. Save all addresses to deployments/sepolia.json and deployments/fluent_testnet.json
#
# Public config: ./config/sepolia.json and ./config/fluent_testnet.json
#   - initialOwner, bridgeAuthority, receiveMessageDeadline, l1BlockOracle (per chain)
#   - rpcUrl, blockExplorerUrl may use placeholders: ${SEPOLIA_RPC_URL}, ${SEPOLIA_BLOCK_EXPLORER_URL}, ${FLUENT_TESTNET_RPC_URL}, ${FLUENT_TESTNET_BLOCK_EXPLORER_URL} (set in .env)
# Private config: .env (PRIVATE_KEY, SEPOLIA_RPC_URL, SEPOLIA_BLOCK_EXPLORER_URL, FLUENT_TESTNET_RPC_URL, FLUENT_TESTNET_BLOCK_EXPLORER_URL required)
#
# Usage:
#   ./scripts/deploy/bash/deploy-sepolia-fluent-devnet.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$PROJECT_ROOT"

command -v forge >/dev/null || { echo "forge is required"; exit 1; }
command -v cast >/dev/null || { echo "cast is required"; exit 1; }
if command -v python3 >/dev/null; then PYTHON=python3; elif command -v python >/dev/null; then PYTHON=python; else echo "python3 or python is required"; exit 1; fi

# Load .env (private values)
if [ -f .env ]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

PRIVATE_KEY="${PRIVATE_KEY:-}"
[ -n "$PRIVATE_KEY" ] || { echo "PRIVATE_KEY is required (set in .env or environment)"; exit 1; }

CONFIG_L1="${CONFIG_L1:-config/sepolia.json}"
CONFIG_L2="${CONFIG_L2:-config/fluent_testnet.json}"
[ -f "$CONFIG_L1" ] || { echo "Config not found: $CONFIG_L1"; exit 1; }
[ -f "$CONFIG_L2" ] || { echo "Config not found: $CONFIG_L2"; exit 1; }

DEPLOYMENT_JSON_SCRIPT="$PROJECT_ROOT/scripts/deploy/deployment_json.py"

read_config_key() {
  "$PYTHON" "$DEPLOYMENT_JSON_SCRIPT" get "$1" "$2"
}

# Expand ${VAR} placeholders from environment (for rpcUrl, blockExplorerUrl in config)
expand_env() {
  local v="$1"
  v="${v//\$\{SEPOLIA_RPC_URL\}/$SEPOLIA_RPC_URL}"
  v="${v//\$\{SEPOLIA_BLOCK_EXPLORER_URL\}/$SEPOLIA_BLOCK_EXPLORER_URL}"
  v="${v//\$\{FLUENT_TESTNET_RPC_URL\}/$FLUENT_TESTNET_RPC_URL}"
  v="${v//\$\{FLUENT_TESTNET_BLOCK_EXPLORER_URL\}/$FLUENT_TESTNET_BLOCK_EXPLORER_URL}"
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

# Chain IDs (fallback if not in config)
L1_CHAIN_ID="$(read_config_key "$CONFIG_L1" chainId)"
L2_CHAIN_ID="$(read_config_key "$CONFIG_L2" chainId)"
[ -z "$L1_CHAIN_ID" ] && L1_CHAIN_ID="${L1_CHAIN_ID:-11155111}"
[ -z "$L2_CHAIN_ID" ] && L2_CHAIN_ID="${L2_CHAIN_ID:-20994}"

# RPC and explorer URLs (expand placeholders from .env)
L1_RPC_URL="$(expand_env "$(read_config_key "$CONFIG_L1" rpcUrl)")"
L2_RPC_URL="$(expand_env "$(read_config_key "$CONFIG_L2" rpcUrl)")"
L1_BLOCK_EXPLORER_URL="$(expand_env "$(read_config_key "$CONFIG_L1" blockExplorerUrl)")"
L2_BLOCK_EXPLORER_URL="$(expand_env "$(read_config_key "$CONFIG_L2" blockExplorerUrl)")"

# Per-chain config for bridge deploy (from config; fallback to env)
L1_INITIAL_OWNER="$(read_config_key "$CONFIG_L1" initialOwner)"
L1_BRIDGE_AUTHORITY="$(read_config_key "$CONFIG_L1" bridgeAuthority)"
L1_RECEIVE_MSG_DEADLINE="$(read_config_key "$CONFIG_L1" receiveMessageDeadline)"
L1_L1BLOCK_ORACLE="$(read_config_key "$CONFIG_L1" l1BlockOracle)"
L2_INITIAL_OWNER="$(read_config_key "$CONFIG_L2" initialOwner)"
L2_BRIDGE_AUTHORITY="$(read_config_key "$CONFIG_L2" bridgeAuthority)"
L2_RECEIVE_MSG_DEADLINE="$(read_config_key "$CONFIG_L2" receiveMessageDeadline)"
L2_L1BLOCK_ORACLE="$(read_config_key "$CONFIG_L2" l1BlockOracle)"

DEPLOYER_ADDRESS="$(cast wallet address --private-key "$PRIVATE_KEY")"
INITIAL_OWNER="${INITIAL_OWNER:-$DEPLOYER_ADDRESS}"
RELAYER_ADDRESS="${RELAYER_ADDRESS:-$DEPLOYER_ADDRESS}"
# Per-chain: config wins, then env INITIAL_OWNER/RELAYER_ADDRESS, then deployer
L1_INITIAL_OWNER="${L1_INITIAL_OWNER:-$INITIAL_OWNER}"
L1_BRIDGE_AUTHORITY="${L1_BRIDGE_AUTHORITY:-$RELAYER_ADDRESS}"
L2_INITIAL_OWNER="${L2_INITIAL_OWNER:-$INITIAL_OWNER}"
L2_BRIDGE_AUTHORITY="${L2_BRIDGE_AUTHORITY:-$RELAYER_ADDRESS}"
[ -z "$L1_RECEIVE_MSG_DEADLINE" ] && L1_RECEIVE_MSG_DEADLINE="${RECEIVE_MSG_DEADLINE:-0}"
[ -z "$L2_RECEIVE_MSG_DEADLINE" ] && L2_RECEIVE_MSG_DEADLINE="${RECEIVE_MSG_DEADLINE:-0}"
L1_L1BLOCK_ORACLE="${L1_L1BLOCK_ORACLE:-0x0000000000000000000000000000000000000000}"
L2_L1BLOCK_ORACLE="${L2_L1BLOCK_ORACLE:-0x0000000000000000000000000000000000000000}"

require_nonzero "L1 chainId" "$L1_CHAIN_ID"
require_nonzero "L1 rpcUrl (set SEPOLIA_RPC_URL in .env if using placeholder)" "$L1_RPC_URL"
require_nonzero "L2 rpcUrl (set FLUENT_TESTNET_RPC_URL in .env if using placeholder)" "$L2_RPC_URL"
# Use L2 chain id from RPC so L1 gateway's otherSideChainId matches L2's block.chainid (required for correct pegged token address computation)
L2_CHAIN_ID_RPC="$(cast chain-id --rpc-url "$L2_RPC_URL" 2>/dev/null || true)"
if [ -n "$L2_CHAIN_ID_RPC" ]; then
  L2_CHAIN_ID="$L2_CHAIN_ID_RPC"
  echo "Using L2 chain id from RPC: $L2_CHAIN_ID"
fi
require_nonzero "L2 chainId (from config or RPC)" "$L2_CHAIN_ID"
require_nonzero "L1 initialOwner (config or INITIAL_OWNER)" "$L1_INITIAL_OWNER"
require_nonzero "L2 initialOwner (config or INITIAL_OWNER)" "$L2_INITIAL_OWNER"

# Use a dir under deployments/ so Forge fs_permissions allow vm.writeJson
TMP_DIR="$PROJECT_ROOT/deployments/.tmp"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

read_json_key() {
  "$PYTHON" "$DEPLOYMENT_JSON_SCRIPT" get "$1" "$2"
}

send_tx() {
  local rpc="$1" to="$2" sig="$3"
  shift 3
  cast send "$to" "$sig" "$@" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" >/dev/null
}

run_forge() {
  local rpc="$1"
  shift 1
  forge script "$@" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --broadcast
}

# Use for L2 (Fluent) when simulation fails due to chain-specific precompiles (e.g. Create2Deployer)
run_forge_skip_sim() {
  local rpc="$1"
  shift 1
  forge script "$@" --rpc-url "$rpc" --private-key "$PRIVATE_KEY" --broadcast --skip-simulation
}

# ---------- 1. Bridges (standalone DeployFluentBridge.s.sol) ----------
L1_BRIDGE_JSON="$TMP_DIR/l1-bridge.json"
L2_BRIDGE_JSON="$TMP_DIR/l2-bridge.json"

echo "=== Step 1: Deploy L1 bridge (DeployFluentBridge.s.sol) ==="
INITIAL_OWNER="$L1_INITIAL_OWNER" BRIDGE_AUTHORITY="$L1_BRIDGE_AUTHORITY" RECEIVE_MSG_DEADLINE="$L1_RECEIVE_MSG_DEADLINE" \
  L1_BLOCK_ORACLE="$L1_L1BLOCK_ORACLE" OTHER_BRIDGE_PLACEHOLDER="0x0000000000000000000000000000000000000001" \
  OUTPUT_PATH="$L1_BRIDGE_JSON" \
  run_forge "$L1_RPC_URL" scripts/deploy/DeployFluentBridge.s.sol:DeployFluentBridge
L1_BRIDGE="$(read_json_key "$L1_BRIDGE_JSON" bridge)"
require_nonzero "L1 bridge" "$L1_BRIDGE"
echo "L1 FluentBridge: $L1_BRIDGE"

echo ""
echo "=== Step 2: Deploy L2 bridge (DeployFluentBridge.s.sol) ==="
INITIAL_OWNER="$L2_INITIAL_OWNER" BRIDGE_AUTHORITY="$L2_BRIDGE_AUTHORITY" RECEIVE_MSG_DEADLINE="$L2_RECEIVE_MSG_DEADLINE" \
  L1_BLOCK_ORACLE="$L2_L1BLOCK_ORACLE" OTHER_BRIDGE_PLACEHOLDER="0x0000000000000000000000000000000000000001" \
  OUTPUT_PATH="$L2_BRIDGE_JSON" \
  run_forge "$L2_RPC_URL" scripts/deploy/DeployFluentBridge.s.sol:DeployFluentBridge
L2_BRIDGE="$(read_json_key "$L2_BRIDGE_JSON" bridge)"
require_nonzero "L2 bridge" "$L2_BRIDGE"
echo "L2 FluentBridge: $L2_BRIDGE"

echo ""
echo "=== Step 3: Link bridges ==="
send_tx "$L1_RPC_URL" "$L1_BRIDGE" "setOtherBridge(address)" "$L2_BRIDGE"
send_tx "$L2_RPC_URL" "$L2_BRIDGE" "setOtherBridge(address)" "$L1_BRIDGE"
echo "Bridges linked."

# ---------- 2. L1 factory (standalone DeployERC20TokenFactory.s.sol) ----------
L1_FACTORY_JSON="$TMP_DIR/l1-factory.json"
echo ""
echo "=== Step 4: Deploy L1 ERC20TokenFactory (DeployERC20TokenFactory.s.sol) ==="
INITIAL_OWNER="$L1_INITIAL_OWNER" OUTPUT_PATH="$L1_FACTORY_JSON" \
  run_forge "$L1_RPC_URL" scripts/deploy/DeployERC20TokenFactory.s.sol:DeployERC20TokenFactory
L1_FACTORY="$(read_json_key "$L1_FACTORY_JSON" factory)"
L1_BEACON="$(read_json_key "$L1_FACTORY_JSON" factory_beacon)"
L1_PEGGED_IMPL="$(read_json_key "$L1_FACTORY_JSON" pegged_impl)"
require_nonzero "L1 factory" "$L1_FACTORY"
echo "L1 Factory: $L1_FACTORY  Beacon: $L1_BEACON"

# ---------- 3. L1 gateway (standalone DeployPaymentGateway.s.sol) ----------
L1_GATEWAY_JSON="$TMP_DIR/l1-gateway.json"
echo ""
echo "=== Step 5: Deploy L1 PaymentGateway (DeployPaymentGateway.s.sol) ==="
INITIAL_OWNER="$L1_INITIAL_OWNER" BRIDGE_ADDRESS="$L1_BRIDGE" FACTORY_ADDRESS="$L1_FACTORY" OUTPUT_PATH="$L1_GATEWAY_JSON" \
  run_forge "$L1_RPC_URL" scripts/deploy/DeployPaymentGateway.s.sol:DeployPaymentGateway
L1_GATEWAY="$(read_json_key "$L1_GATEWAY_JSON" gateway)"
require_nonzero "L1 gateway" "$L1_GATEWAY"
echo "L1 Gateway: $L1_GATEWAY"

# ---------- 4. L2 factory (standalone DeployUniversalTokenFactory.s.sol) ----------
L2_FACTORY_JSON="$TMP_DIR/l2-factory.json"
echo ""
echo "=== Step 6: Deploy L2 UniversalTokenFactory (DeployUniversalTokenFactory.s.sol) ==="
INITIAL_OWNER="$L2_INITIAL_OWNER" OUTPUT_PATH="$L2_FACTORY_JSON" \
  run_forge_skip_sim "$L2_RPC_URL" scripts/deploy/DeployUniversalTokenFactory.s.sol:DeployUniversalTokenFactory
L2_FACTORY="$(read_json_key "$L2_FACTORY_JSON" factory)"
require_nonzero "L2 factory" "$L2_FACTORY"
echo "L2 Factory: $L2_FACTORY"

# ---------- 5. L2 gateway (standalone DeployPaymentGateway.s.sol) ----------
L2_GATEWAY_JSON="$TMP_DIR/l2-gateway.json"
echo ""
echo "=== Step 7: Deploy L2 PaymentGateway (DeployPaymentGateway.s.sol) ==="
INITIAL_OWNER="$L2_INITIAL_OWNER" BRIDGE_ADDRESS="$L2_BRIDGE" FACTORY_ADDRESS="$L2_FACTORY" OUTPUT_PATH="$L2_GATEWAY_JSON" \
  run_forge_skip_sim "$L2_RPC_URL" scripts/deploy/DeployPaymentGateway.s.sol:DeployPaymentGateway
L2_GATEWAY="$(read_json_key "$L2_GATEWAY_JSON" gateway)"
require_nonzero "L2 gateway" "$L2_GATEWAY"
echo "L2 Gateway: $L2_GATEWAY"

# ---------- 6. Mock token L1 only (dedicated step; can be removed later) ----------
L1_MOCK_JSON="$TMP_DIR/l1-mock.json"
echo ""
echo "=== Step 8: Deploy mock token on L1 (DeployMockERC20Token.s.sol) ==="
MOCK_SUPPLY="${MOCK_SUPPLY:-1000000000000000000000000}"
INITIAL_OWNER="$L1_INITIAL_OWNER" MOCK_ERC20_RECIPIENT="${MOCK_ERC20_RECIPIENT:-$L1_INITIAL_OWNER}" MOCK_ERC20_SUPPLY="$MOCK_SUPPLY" \
  OUTPUT_PATH="$L1_MOCK_JSON" \
  run_forge "$L1_RPC_URL" scripts/deploy/DeployMockERC20Token.s.sol:DeployMockERC20Token
MOCK_TOKEN="$(read_json_key "$L1_MOCK_JSON" mock_erc20)"
echo "L1 Mock token: ${MOCK_TOKEN:-none}"

# ---------- 7. Set gateway config (link gateways) ----------
echo ""
echo "=== Step 9: Set other-side gateway config ==="
# L2 Universal: pegged_impl is the precompile runtime (0x520008)
L2_PEGGED_IMPL="0x0000000000000000000000000000000000520008"
send_tx "$L1_RPC_URL" "$L1_GATEWAY" "setOtherSideUniversal(address,address,address,uint256)" "$L2_GATEWAY" "$L2_PEGGED_IMPL" "$L2_FACTORY" "$L2_CHAIN_ID"
send_tx "$L2_RPC_URL" "$L2_GATEWAY" "setOtherSide(address,address,address,address)" "$L1_GATEWAY" "$L1_PEGGED_IMPL" "$L1_FACTORY" "$L1_BEACON"
echo "Gateways linked."

# ---------- 8. Save all addresses (2 files per chain) ----------
# Write expanded config (resolved URLs) so deployment JSON has real values
L1_CONFIG_EXPANDED="$TMP_DIR/sepolia_expanded.json"
L2_CONFIG_EXPANDED="$TMP_DIR/fluent_testnet_expanded.json"
"$PYTHON" "$PROJECT_ROOT/scripts/deploy/expand_config.py" \
  "$CONFIG_L1" "$L1_CONFIG_EXPANDED" "$L1_RPC_URL" "$L1_BLOCK_EXPLORER_URL" "$L1_CHAIN_ID"
"$PYTHON" "$PROJECT_ROOT/scripts/deploy/expand_config.py" \
  "$CONFIG_L2" "$L2_CONFIG_EXPANDED" "$L2_RPC_URL" "$L2_BLOCK_EXPLORER_URL" "$L2_CHAIN_ID"
mkdir -p deployments
echo ""
echo "=== Step 10: Save deployment addresses ==="
"$PYTHON" "$DEPLOYMENT_JSON_SCRIPT" merge_chain "$L1_CONFIG_EXPANDED" "deployments/sepolia.json" \
  "$L1_BRIDGE_JSON" "$L1_FACTORY_JSON" "$L1_GATEWAY_JSON" "$L1_MOCK_JSON"
"$PYTHON" "$DEPLOYMENT_JSON_SCRIPT" merge_chain "$L2_CONFIG_EXPANDED" "deployments/fluent_testnet.json" \
  "$L2_BRIDGE_JSON" "$L2_FACTORY_JSON" "$L2_GATEWAY_JSON" --l2

echo ""
echo "=== Deployment complete ==="
echo "Deployment files: deployments/sepolia.json  deployments/fluent_testnet.json"
echo "L1_BRIDGE=$L1_BRIDGE"
echo "L2_BRIDGE=$L2_BRIDGE"
echo "L1_GATEWAY=$L1_GATEWAY"
echo "L2_GATEWAY=$L2_GATEWAY"
echo "L1_FACTORY=$L1_FACTORY"
echo "L2_FACTORY=$L2_FACTORY"
echo "MOCK_TOKEN=${MOCK_TOKEN:-}"
echo ""
echo "=== Next: verify ==="
echo "  ETHERSCAN_API_KEY in .env then: ./scripts/deploy/bash/verify-sepolia-fluent-devnet.sh"
echo ""
echo "=== Deposit (L1 -> L2) example ==="
echo "  TOKEN_ADDRESS=\${MOCK_TOKEN:-<l1-erc20>} RECIPIENT_ADDRESS=<l2-recipient> AMOUNT=1000000000000000000"
echo "  cast send \$TOKEN_ADDRESS \"approve(address,uint256)\" \$L1_GATEWAY \$AMOUNT --rpc-url \"$L1_RPC_URL\" --private-key <key>"
echo "  cast send \$L1_GATEWAY \"sendTokens(address,address,uint256)\" \$TOKEN_ADDRESS \$RECIPIENT_ADDRESS \$AMOUNT --rpc-url \"$L1_RPC_URL\" --private-key <key>"
