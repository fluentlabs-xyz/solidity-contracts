#!/usr/bin/env bash
# Verify deployed contracts on both chains. Reads deployments/sepolia.json and deployments/fluent_testnet.json.
# Requires ETHERSCAN_API_KEY in .env (for Sepolia). L2 uses Blockscout (no API key required).
# Optional .env: PRIVATE_KEY, INITIAL_OWNER, RELAYER_ADDRESS, RECEIVE_MSG_DEADLINE, L1_L1BLOCK_ORACLE, L2_L1BLOCK_ORACLE, MOCK_SUPPLY, MOCK_RECIPIENT, L1_RPC_URL, L2_RPC_URL.
#
# Usage:
#   ./scripts/deploy/bash/verify-sepolia-fluent-testnet.sh
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

ETHERSCAN_API_KEY="${ETHERSCAN_API_KEY:-}"
[ -n "$ETHERSCAN_API_KEY" ] || { echo "ETHERSCAN_API_KEY is required (set in .env)"; exit 1; }

[ -f deployments/sepolia.json ] || { echo "deployments/sepolia.json not found; run deploy-sepolia-fluent-testnet.sh first"; exit 1; }
[ -f deployments/fluent_testnet.json ] || { echo "deployments/fluent_testnet.json not found; run deploy-sepolia-fluent-testnet.sh first"; exit 1; }

DEPLOYMENT_JSON_SCRIPT="$PROJECT_ROOT/scripts/deploy/deployment_json.py"

read_json_key() {
  "$PYTHON" "$DEPLOYMENT_JSON_SCRIPT" get "$1" "$2"
}

read_config_key() {
  "$PYTHON" "$DEPLOYMENT_JSON_SCRIPT" get "$1" "$2"
}

# Init params (must match deploy)
DEPLOYER_ADDRESS="${INITIAL_OWNER:-}"
[ -z "$DEPLOYER_ADDRESS" ] && [ -n "${PRIVATE_KEY:-}" ] && DEPLOYER_ADDRESS="$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null)" || true
INITIAL_OWNER="${INITIAL_OWNER:-$DEPLOYER_ADDRESS}"
ADMIN_ROLE="${ADMIN_ROLE:-$INITIAL_OWNER}"
PAUSER_ROLE="${PAUSER_ROLE:-$ADMIN_ROLE}"
BRIDGE_AUTHORITY="${BRIDGE_AUTHORITY:-$ADMIN_ROLE}"
RELAYER_ROLE="${RELAYER_ROLE:-${BRIDGE_AUTHORITY:-$ADMIN_ROLE}}"
RECEIVE_MSG_DEADLINE="${RECEIVE_MSG_DEADLINE:-0}"
L1_L1BLOCK_ORACLE="${L1_L1BLOCK_ORACLE:-0x0000000000000000000000000000000000000000}"
L2_L1BLOCK_ORACLE="${L2_L1BLOCK_ORACLE:-0x0000000000000000000000000000000000000000}"
OTHER_BRIDGE_PLACEHOLDER="${OTHER_BRIDGE_PLACEHOLDER:-0x0000000000000000000000000000000000000001}"
MOCK_SUPPLY="${MOCK_SUPPLY:-1000000000000000000000000}"
MOCK_RECIPIENT="${MOCK_RECIPIENT:-$INITIAL_OWNER}"

L1_RPC="$(read_config_key deployments/sepolia.json rpcUrl)"
L2_RPC="$(read_config_key deployments/fluent_testnet.json rpcUrl)"
[ -z "$L1_RPC" ] && L1_RPC="${L1_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
[ -z "$L2_RPC" ] && L2_RPC="${L2_RPC_URL:-https://rpc.dev.fluent.xyz/}"

# ---------- L1 (Sepolia) ----------
echo "========== L1 (Sepolia) =========="
BRIDGE_IMPL=$(read_json_key deployments/sepolia.json bridge_impl)
BRIDGE=$(read_json_key deployments/sepolia.json bridge)
PEGGED_IMPL=$(read_json_key deployments/sepolia.json pegged_impl)
FACTORY_IMPL=$(read_json_key deployments/sepolia.json factory_impl)
FACTORY=$(read_json_key deployments/sepolia.json factory)
BEACON=$(read_json_key deployments/sepolia.json factory_beacon)
GATEWAY_IMPL=$(read_json_key deployments/sepolia.json gateway_impl)
GATEWAY=$(read_json_key deployments/sepolia.json gateway)
MOCK_TOKEN=$(read_json_key deployments/sepolia.json mock_token)

CHAIN_L1="sepolia"
echo "Verifying L1 contracts (chain: $CHAIN_L1) with ETHERSCAN_API_KEY from .env"
echo ""

[ -n "$BRIDGE_IMPL" ] && echo "[1/9] FluentBridge implementation..." && forge verify-contract --watch --chain "$CHAIN_L1" "$BRIDGE_IMPL" contracts/FluentBridge.sol:FluentBridge --rpc-url "$L1_RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

BRIDGE_INIT_CONFIG_L1=$(cast abi-encode "(address,address,address,address,uint256,address,address)" "$ADMIN_ROLE" "$PAUSER_ROLE" "$RELAYER_ROLE" 0x0000000000000000000000000000000000000000 "$RECEIVE_MSG_DEADLINE" "$OTHER_BRIDGE_PLACEHOLDER" "$L1_L1BLOCK_ORACLE")
INIT_BRIDGE=$(cast calldata "initialize(bytes)" "$BRIDGE_INIT_CONFIG_L1")
BRIDGE_PROXY_ARGS=$(cast abi-encode "f(address,bytes)" "$BRIDGE_IMPL" "$INIT_BRIDGE")
[ -n "$BRIDGE" ] && echo "[2/9] Bridge proxy (ERC1967Proxy)..." && forge verify-contract --watch --chain "$CHAIN_L1" "$BRIDGE" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy --constructor-args "$BRIDGE_PROXY_ARGS" --rpc-url "$L1_RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

[ -n "$PEGGED_IMPL" ] && echo "[3/9] ERC20PeggedToken implementation..." && forge verify-contract --watch --chain "$CHAIN_L1" "$PEGGED_IMPL" contracts/tokens/ERC20PeggedToken.sol:ERC20PeggedToken --rpc-url "$L1_RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

[ -n "$FACTORY_IMPL" ] && echo "[4/9] ERC20TokenFactory implementation..." && forge verify-contract --watch --chain "$CHAIN_L1" "$FACTORY_IMPL" contracts/factories/ERC20TokenFactory.sol:ERC20TokenFactory --rpc-url "$L1_RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

INIT_FACTORY=$(cast calldata "initialize(address,address)" "$INITIAL_OWNER" "$PEGGED_IMPL")
FACTORY_PROXY_ARGS=$(cast abi-encode "f(address,bytes)" "$FACTORY_IMPL" "$INIT_FACTORY")
[ -n "$FACTORY" ] && echo "[5/9] Factory proxy (ERC1967Proxy)..." && forge verify-contract --watch --chain "$CHAIN_L1" "$FACTORY" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy --constructor-args "$FACTORY_PROXY_ARGS" --rpc-url "$L1_RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

BEACON_ARGS=$(cast abi-encode "f(address,address)" "$PEGGED_IMPL" "$FACTORY")
[ -n "$BEACON" ] && echo "[6/9] UpgradeableBeacon..." && forge verify-contract --watch --chain "$CHAIN_L1" "$BEACON" lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon --constructor-args "$BEACON_ARGS" --rpc-url "$L1_RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

[ -n "$GATEWAY_IMPL" ] && echo "[7/9] PaymentGateway implementation..." && forge verify-contract --watch --chain "$CHAIN_L1" "$GATEWAY_IMPL" contracts/gateways/PaymentGateway.sol:PaymentGateway --rpc-url "$L1_RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

INIT_GATEWAY=$(cast calldata "initialize(address,address,address)" "$INITIAL_OWNER" "$BRIDGE" "$FACTORY")
GATEWAY_PROXY_ARGS=$(cast abi-encode "f(address,bytes)" "$GATEWAY_IMPL" "$INIT_GATEWAY")
[ -n "$GATEWAY" ] && echo "[8/9] Gateway proxy (ERC1967Proxy)..." && forge verify-contract --watch --chain "$CHAIN_L1" "$GATEWAY" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy --constructor-args "$GATEWAY_PROXY_ARGS" --rpc-url "$L1_RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

if [ -n "$MOCK_TOKEN" ] && [ "$MOCK_TOKEN" != "0x0000000000000000000000000000000000000000" ]; then
  MOCK_ARGS=$(cast abi-encode "f(string,string,uint256,address)" "Mock Deposit Token" "MDT" "$MOCK_SUPPLY" "$MOCK_RECIPIENT")
  echo "[9/9] MockERC20Token..."
  forge verify-contract --watch --chain "$CHAIN_L1" "$MOCK_TOKEN" contracts/mocks/MockERC20.sol:MockERC20Token --constructor-args "$MOCK_ARGS" --rpc-url "$L1_RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true
else
  echo "[9/9] MockERC20Token skipped (no address)"
fi

echo ""
echo "========== L2 (Fluent Testnet) =========="
# ---------- L2 (Fluent) ----------
BRIDGE_IMPL_L2=$(read_json_key deployments/fluent_testnet.json bridge_impl)
BRIDGE_L2=$(read_json_key deployments/fluent_testnet.json bridge)
PEGGED_IMPL_L2=$(read_json_key deployments/fluent_testnet.json pegged_impl)
FACTORY_IMPL_L2=$(read_json_key deployments/fluent_testnet.json factory_impl)
FACTORY_L2=$(read_json_key deployments/fluent_testnet.json factory)
BEACON_L2=$(read_json_key deployments/fluent_testnet.json factory_beacon)
GATEWAY_IMPL_L2=$(read_json_key deployments/fluent_testnet.json gateway_impl)
GATEWAY_L2=$(read_json_key deployments/fluent_testnet.json gateway)

VERIFIER_URL_L2="${FLUENT_VERIFIER_URL:-https://testnet.fluentscan.xyz/api/}"
CHAIN_L2="$(read_config_key deployments/fluent_testnet.json chainId)"
[ -z "$CHAIN_L2" ] && CHAIN_L2="20994"
echo "Verifying L2 contracts (chain: $CHAIN_L2) with Blockscout"
echo ""

[ -n "$BRIDGE_IMPL_L2" ] && echo "[1/8] FluentBridge implementation..." && forge verify-contract --rpc-url "$L2_RPC" "$BRIDGE_IMPL_L2" contracts/FluentBridge.sol:FluentBridge --verifier blockscout --verifier-url "$VERIFIER_URL_L2" --chain "$CHAIN_L2" || true

BRIDGE_INIT_CONFIG_L2=$(cast abi-encode "(address,address,address,address,uint256,address,address)" "$ADMIN_ROLE" "$PAUSER_ROLE" "$RELAYER_ROLE" 0x0000000000000000000000000000000000000000 "$RECEIVE_MSG_DEADLINE" "$OTHER_BRIDGE_PLACEHOLDER" "$L2_L1BLOCK_ORACLE")
INIT_BRIDGE_L2=$(cast calldata "initialize(bytes)" "$BRIDGE_INIT_CONFIG_L2")
BRIDGE_PROXY_ARGS_L2=$(cast abi-encode "f(address,bytes)" "$BRIDGE_IMPL_L2" "$INIT_BRIDGE_L2")
[ -n "$BRIDGE_L2" ] && echo "[2/8] Bridge proxy (ERC1967Proxy)..." && forge verify-contract --rpc-url "$L2_RPC" "$BRIDGE_L2" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy --constructor-args "$BRIDGE_PROXY_ARGS_L2" --verifier blockscout --verifier-url "$VERIFIER_URL_L2" --chain "$CHAIN_L2" || true

if [ "$BEACON_L2" = "0x0000000000000000000000000000000000000000" ] || [ -z "$BEACON_L2" ]; then
  FACTORY_CONTRACT_L2="contracts/factories/UniversalTokenFactory.sol:UniversalTokenFactory"
  INIT_FACTORY_L2=$(cast calldata "initialize(address)" "$INITIAL_OWNER")
else
  FACTORY_CONTRACT_L2="contracts/factories/ERC20TokenFactory.sol:ERC20TokenFactory"
  [ -n "$PEGGED_IMPL_L2" ] && echo "[3/8] ERC20PeggedToken implementation..." && forge verify-contract --rpc-url "$L2_RPC" "$PEGGED_IMPL_L2" contracts/tokens/ERC20PeggedToken.sol:ERC20PeggedToken --verifier blockscout --verifier-url "$VERIFIER_URL_L2" --chain "$CHAIN_L2" || true
  INIT_FACTORY_L2=$(cast calldata "initialize(address,address)" "$INITIAL_OWNER" "$PEGGED_IMPL_L2")
fi

[ -n "$FACTORY_IMPL_L2" ] && echo "[4/8] Factory implementation..." && forge verify-contract --rpc-url "$L2_RPC" "$FACTORY_IMPL_L2" "$FACTORY_CONTRACT_L2" --verifier blockscout --verifier-url "$VERIFIER_URL_L2" --chain "$CHAIN_L2" || true

FACTORY_PROXY_ARGS_L2=$(cast abi-encode "f(address,bytes)" "$FACTORY_IMPL_L2" "$INIT_FACTORY_L2")
[ -n "$FACTORY_L2" ] && echo "[5/8] Factory proxy (ERC1967Proxy)..." && forge verify-contract --rpc-url "$L2_RPC" "$FACTORY_L2" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy --constructor-args "$FACTORY_PROXY_ARGS_L2" --verifier blockscout --verifier-url "$VERIFIER_URL_L2" --chain "$CHAIN_L2" || true

if [ -n "$BEACON_L2" ] && [ "$BEACON_L2" != "0x0000000000000000000000000000000000000000" ]; then
  BEACON_ARGS_L2=$(cast abi-encode "f(address,address)" "$PEGGED_IMPL_L2" "$FACTORY_L2")
  echo "[6/8] UpgradeableBeacon..."
  forge verify-contract --rpc-url "$L2_RPC" "$BEACON_L2" lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon --constructor-args "$BEACON_ARGS_L2" --verifier blockscout --verifier-url "$VERIFIER_URL_L2" --chain "$CHAIN_L2" || true
else
  echo "[6/8] UpgradeableBeacon skipped (UniversalTokenFactory)"
fi

[ -n "$GATEWAY_IMPL_L2" ] && echo "[7/8] PaymentGateway implementation..." && forge verify-contract --rpc-url "$L2_RPC" "$GATEWAY_IMPL_L2" contracts/gateways/PaymentGateway.sol:PaymentGateway --verifier blockscout --verifier-url "$VERIFIER_URL_L2" --chain "$CHAIN_L2" || true

INIT_GATEWAY_L2=$(cast calldata "initialize(address,address,address)" "$INITIAL_OWNER" "$BRIDGE_L2" "$FACTORY_L2")
GATEWAY_PROXY_ARGS_L2=$(cast abi-encode "f(address,bytes)" "$GATEWAY_IMPL_L2" "$INIT_GATEWAY_L2")
[ -n "$GATEWAY_L2" ] && echo "[8/8] Gateway proxy (ERC1967Proxy)..." && forge verify-contract --rpc-url "$L2_RPC" "$GATEWAY_L2" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy --constructor-args "$GATEWAY_PROXY_ARGS_L2" --verifier blockscout --verifier-url "$VERIFIER_URL_L2" --chain "$CHAIN_L2" || true

echo ""
echo "Verification complete (L1 + L2)."
