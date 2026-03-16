#!/usr/bin/env bash
# Verify all L2 contracts (including proxies) on Fluent Testnet (Fluent Scan / Blockscout).
# Reads deployments/fluent-testnet-l2-bridge.json and deployments/fluent-testnet-l2-stack.json.
# Uses: --verifier blockscout --verifier-url https://testnet.fluentscan.xyz/api/
# Optional: INITIAL_OWNER, RELAYER_ADDRESS, PRIVATE_KEY (to derive owner), L2_RPC_URL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

command -v forge >/dev/null || { echo "forge required"; exit 1; }
command -v cast >/dev/null || { echo "cast required"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

[ -f deployments/fluent-testnet-l2-bridge.json ] || { echo "deployments/fluent-testnet-l2-bridge.json not found"; exit 1; }
[ -f deployments/fluent-testnet-l2-stack.json ] || { echo "deployments/fluent-testnet-l2-stack.json not found"; exit 1; }

read_json_key() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f).get(sys.argv[2], "") or "")
PY
}

BRIDGE_IMPL=$(read_json_key deployments/fluent-testnet-l2-bridge.json bridge_impl)
BRIDGE=$(read_json_key deployments/fluent-testnet-l2-bridge.json bridge)
PEGGED_IMPL=$(read_json_key deployments/fluent-testnet-l2-stack.json pegged_impl)
FACTORY_IMPL=$(read_json_key deployments/fluent-testnet-l2-stack.json factory_impl)
FACTORY=$(read_json_key deployments/fluent-testnet-l2-stack.json factory)
BEACON=$(read_json_key deployments/fluent-testnet-l2-stack.json factory_beacon)
GATEWAY_IMPL=$(read_json_key deployments/fluent-testnet-l2-stack.json gateway_impl)
GATEWAY=$(read_json_key deployments/fluent-testnet-l2-stack.json gateway)

INITIAL_OWNER="${INITIAL_OWNER:-}"
ADMIN_ROLE="${ADMIN_ROLE:-$INITIAL_OWNER}"
PAUSER_ROLE="${PAUSER_ROLE:-$ADMIN_ROLE}"
RELAYER_ROLE="${RELAYER_ROLE:-${RELAYER_ADDRESS:-$ADMIN_ROLE}}"
RECEIVE_MSG_DEADLINE="${RECEIVE_MSG_DEADLINE:-0}"
L2_L1BLOCK_ORACLE="${L2_L1BLOCK_ORACLE:-0x0000000000000000000000000000000000000000}"
OTHER_BRIDGE_PLACEHOLDER="${OTHER_BRIDGE_PLACEHOLDER:-0x0000000000000000000000000000000000000001}"

if [ -z "$ADMIN_ROLE" ] || [ -z "$PAUSER_ROLE" ] || [ -z "$RELAYER_ROLE" ]; then
  DEPLOYER_ADDRESS="$(cast wallet address --private-key "${PRIVATE_KEY:-}" 2>/dev/null || true)"
  INITIAL_OWNER="${INITIAL_OWNER:-$DEPLOYER_ADDRESS}"
  ADMIN_ROLE="${ADMIN_ROLE:-$INITIAL_OWNER}"
  PAUSER_ROLE="${PAUSER_ROLE:-$ADMIN_ROLE}"
  RELAYER_ROLE="${RELAYER_ROLE:-${RELAYER_ADDRESS:-$ADMIN_ROLE}}"
fi

is_valid_address() {
  [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]
}

is_valid_address "$ADMIN_ROLE" || { echo "ADMIN_ROLE must be a valid address"; exit 1; }
is_valid_address "$PAUSER_ROLE" || { echo "PAUSER_ROLE must be a valid address"; exit 1; }
is_valid_address "$RELAYER_ROLE" || { echo "RELAYER_ROLE must be a valid address"; exit 1; }
INITIAL_OWNER="${INITIAL_OWNER:-$ADMIN_ROLE}"

RPC="${L2_RPC_URL:-${RPC_URL_FLUENT_TESTNET:-https://rpc.testnet.fluent.xyz/}}"
VERIFIER_URL="https://testnet.fluentscan.xyz/api/"
CHAIN="20994"

echo "Verifying L2 contracts on Fluent Testnet (chain: $CHAIN)"
echo "Using: --verifier blockscout --verifier-url $VERIFIER_URL"
echo ""

# 1) FluentBridge implementation
echo "[1/8] FluentBridge implementation..."
forge verify-contract --rpc-url "$RPC" "$BRIDGE_IMPL" contracts/FluentBridge.sol:FluentBridge \
  --verifier blockscout --verifier-url "$VERIFIER_URL" --chain "$CHAIN" || true

# 2) Bridge proxy
BRIDGE_INIT_CONFIG=$(cast abi-encode "(address,address,address,address,uint256,address,address)" "$ADMIN_ROLE" "$PAUSER_ROLE" "$RELAYER_ROLE" 0x0000000000000000000000000000000000000000 "$RECEIVE_MSG_DEADLINE" "$OTHER_BRIDGE_PLACEHOLDER" "$L2_L1BLOCK_ORACLE")
INIT_BRIDGE=$(cast calldata "initialize(bytes)" "$BRIDGE_INIT_CONFIG")
BRIDGE_PROXY_ARGS=$(cast abi-encode "f(address,bytes)" "$BRIDGE_IMPL" "$INIT_BRIDGE")
echo "[2/8] Bridge proxy (ERC1967Proxy)..."
forge verify-contract --rpc-url "$RPC" "$BRIDGE" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --constructor-args "$BRIDGE_PROXY_ARGS" --verifier blockscout --verifier-url "$VERIFIER_URL" --chain "$CHAIN" || true

# 3) Factory implementation
if [ "$BEACON" = "0x0000000000000000000000000000000000000000" ]; then
  FACTORY_CONTRACT="contracts/factories/UniversalTokenFactory.sol:UniversalTokenFactory"
  INIT_FACTORY=$(cast calldata "initialize(address)" "$INITIAL_OWNER")
else
  FACTORY_CONTRACT="contracts/factories/ERC20TokenFactory.sol:ERC20TokenFactory"
  echo "[3/8] ERC20PeggedToken implementation..."
  forge verify-contract --rpc-url "$RPC" "$PEGGED_IMPL" contracts/tokens/ERC20PeggedToken.sol:ERC20PeggedToken \
    --verifier blockscout --verifier-url "$VERIFIER_URL" --chain "$CHAIN" || true
  INIT_FACTORY=$(cast calldata "initialize(address,address)" "$INITIAL_OWNER" "$PEGGED_IMPL")
fi

echo "[4/8] Factory implementation..."
forge verify-contract --rpc-url "$RPC" "$FACTORY_IMPL" "$FACTORY_CONTRACT" \
  --verifier blockscout --verifier-url "$VERIFIER_URL" --chain "$CHAIN" || true

# 5) Factory proxy
FACTORY_PROXY_ARGS=$(cast abi-encode "f(address,bytes)" "$FACTORY_IMPL" "$INIT_FACTORY")
echo "[5/8] Factory proxy (ERC1967Proxy)..."
forge verify-contract --rpc-url "$RPC" "$FACTORY" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --constructor-args "$FACTORY_PROXY_ARGS" --verifier blockscout --verifier-url "$VERIFIER_URL" --chain "$CHAIN" || true

# 6) UpgradeableBeacon
if [ "$BEACON" != "0x0000000000000000000000000000000000000000" ]; then
  BEACON_ARGS=$(cast abi-encode "f(address,address)" "$PEGGED_IMPL" "$FACTORY")
  echo "[6/8] UpgradeableBeacon..."
  forge verify-contract --rpc-url "$RPC" "$BEACON" lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon \
    --constructor-args "$BEACON_ARGS" --verifier blockscout --verifier-url "$VERIFIER_URL" --chain "$CHAIN" || true
else
  echo "[6/8] UpgradeableBeacon skipped (UniversalTokenFactory path)"
fi

# 7) PaymentGateway implementation
echo "[7/8] PaymentGateway implementation..."
forge verify-contract --rpc-url "$RPC" "$GATEWAY_IMPL" contracts/gateways/PaymentGateway.sol:PaymentGateway \
  --verifier blockscout --verifier-url "$VERIFIER_URL" --chain "$CHAIN" || true

# 8) Gateway proxy
INIT_GATEWAY=$(cast calldata "initialize(address,address,address)" "$INITIAL_OWNER" "$BRIDGE" "$FACTORY")
GATEWAY_PROXY_ARGS=$(cast abi-encode "f(address,bytes)" "$GATEWAY_IMPL" "$INIT_GATEWAY")
echo "[8/8] Gateway proxy (ERC1967Proxy)..."
forge verify-contract --rpc-url "$RPC" "$GATEWAY" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --constructor-args "$GATEWAY_PROXY_ARGS" --verifier blockscout --verifier-url "$VERIFIER_URL" --chain "$CHAIN" || true

echo ""
echo "Verification complete."
