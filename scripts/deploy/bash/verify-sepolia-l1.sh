#!/usr/bin/env bash
# Verify all L1 contracts (including proxies) on Sepolia Etherscan.
# Reads deployments/sepolia-l1-bridge.json and deployments/sepolia-l1-stack.json.
# Uses: forge verify-contract --watch --chain sepolia <addr> <contract> --verifier etherscan --etherscan-api-key <key>
# Requires: ETHERSCAN_API_KEY. Optional: INITIAL_OWNER, RELAYER_ADDRESS, etc. (must match deploy).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

command -v forge >/dev/null || { echo "forge required"; exit 1; }
command -v cast >/dev/null || { echo "cast required"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

[ -f deployments/sepolia-l1-bridge.json ] || { echo "deployments/sepolia-l1-bridge.json not found"; exit 1; }
[ -f deployments/sepolia-l1-stack.json ] || { echo "deployments/sepolia-l1-stack.json not found"; exit 1; }
[ -n "${ETHERSCAN_API_KEY:-}" ] || { echo "ETHERSCAN_API_KEY required for Etherscan verification"; exit 1; }

read_json_key() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f).get(sys.argv[2], "") or "")
PY
}

BRIDGE_IMPL=$(read_json_key deployments/sepolia-l1-bridge.json bridge_impl)
BRIDGE=$(read_json_key deployments/sepolia-l1-bridge.json bridge)
PEGGED_IMPL=$(read_json_key deployments/sepolia-l1-stack.json pegged_impl)
FACTORY_IMPL=$(read_json_key deployments/sepolia-l1-stack.json factory_impl)
FACTORY=$(read_json_key deployments/sepolia-l1-stack.json factory)
BEACON=$(read_json_key deployments/sepolia-l1-stack.json factory_beacon)
GATEWAY_IMPL=$(read_json_key deployments/sepolia-l1-stack.json gateway_impl)
GATEWAY=$(read_json_key deployments/sepolia-l1-stack.json gateway)
MOCK_TOKEN=$(read_json_key deployments/sepolia-l1-stack.json mock_token)

DEPLOYER_ADDRESS="${INITIAL_OWNER:-$(cast wallet address --private-key "${PRIVATE_KEY:-}")}"
INITIAL_OWNER="${INITIAL_OWNER:-$DEPLOYER_ADDRESS}"
ADMIN_ROLE="${ADMIN_ROLE:-$INITIAL_OWNER}"
PAUSER_ROLE="${PAUSER_ROLE:-$ADMIN_ROLE}"
RELAYER_ROLE="${RELAYER_ROLE:-${RELAYER_ADDRESS:-$ADMIN_ROLE}}"
RECEIVE_MSG_DEADLINE="${RECEIVE_MSG_DEADLINE:-0}"
L1_L1BLOCK_ORACLE="${L1_L1BLOCK_ORACLE:-0x0000000000000000000000000000000000000000}"
OTHER_BRIDGE_PLACEHOLDER="${OTHER_BRIDGE_PLACEHOLDER:-0x0000000000000000000000000000000000000001}"
MOCK_SUPPLY="${MOCK_SUPPLY:-1000000000000000000000000}"
MOCK_RECIPIENT="${MOCK_RECIPIENT:-$INITIAL_OWNER}"

RPC="${L1_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
CHAIN="sepolia"

echo "Verifying L1 contracts on Sepolia (chain: $CHAIN)"
echo "Using: --verifier etherscan --etherscan-api-key <key> --watch"
echo ""

# 1) FluentBridge implementation (no constructor args)
echo "[1/9] FluentBridge implementation..."
forge verify-contract --watch --chain "$CHAIN" "$BRIDGE_IMPL" contracts/FluentBridge.sol:FluentBridge \
  --rpc-url "$RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

# 2) Bridge proxy: ERC1967Proxy(implementation, initData)
#    initData = initialize(abi.encode(InitConfiguration))
BRIDGE_INIT_CONFIG=$(cast abi-encode "(address,address,address,address,uint256,address,address)" "$ADMIN_ROLE" "$PAUSER_ROLE" "$RELAYER_ROLE" 0x0000000000000000000000000000000000000000 "$RECEIVE_MSG_DEADLINE" "$OTHER_BRIDGE_PLACEHOLDER" "$L1_L1BLOCK_ORACLE")
INIT_BRIDGE=$(cast calldata "initialize(bytes)" "$BRIDGE_INIT_CONFIG")
BRIDGE_PROXY_ARGS=$(cast abi-encode "f(address,bytes)" "$BRIDGE_IMPL" "$INIT_BRIDGE")
echo "[2/9] Bridge proxy (ERC1967Proxy)..."
forge verify-contract --watch --chain "$CHAIN" "$BRIDGE" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --constructor-args "$BRIDGE_PROXY_ARGS" --rpc-url "$RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

# 3) ERC20PeggedToken implementation
echo "[3/9] ERC20PeggedToken implementation..."
forge verify-contract --watch --chain "$CHAIN" "$PEGGED_IMPL" contracts/tokens/ERC20PeggedToken.sol:ERC20PeggedToken \
  --rpc-url "$RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

# 4) ERC20TokenFactory implementation
echo "[4/9] ERC20TokenFactory implementation..."
forge verify-contract --watch --chain "$CHAIN" "$FACTORY_IMPL" contracts/factories/ERC20TokenFactory.sol:ERC20TokenFactory \
  --rpc-url "$RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

# 5) Factory proxy: ERC1967Proxy(factory_impl, initialize(owner, pegged_impl))
INIT_FACTORY=$(cast calldata "initialize(address,address)" "$INITIAL_OWNER" "$PEGGED_IMPL")
FACTORY_PROXY_ARGS=$(cast abi-encode "f(address,bytes)" "$FACTORY_IMPL" "$INIT_FACTORY")
echo "[5/9] Factory proxy (ERC1967Proxy)..."
forge verify-contract --watch --chain "$CHAIN" "$FACTORY" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --constructor-args "$FACTORY_PROXY_ARGS" --rpc-url "$RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

# 6) UpgradeableBeacon(implementation, owner) = (pegged_impl, factory proxy)
BEACON_ARGS=$(cast abi-encode "f(address,address)" "$PEGGED_IMPL" "$FACTORY")
echo "[6/9] UpgradeableBeacon..."
forge verify-contract --watch --chain "$CHAIN" "$BEACON" lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon \
  --constructor-args "$BEACON_ARGS" --rpc-url "$RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

# 7) PaymentGateway implementation
echo "[7/9] PaymentGateway implementation..."
forge verify-contract --watch --chain "$CHAIN" "$GATEWAY_IMPL" contracts/gateways/PaymentGateway.sol:PaymentGateway \
  --rpc-url "$RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

# 8) Gateway proxy: ERC1967Proxy(gateway_impl, initialize(owner, bridge, factory))
INIT_GATEWAY=$(cast calldata "initialize(address,address,address)" "$INITIAL_OWNER" "$BRIDGE" "$FACTORY")
GATEWAY_PROXY_ARGS=$(cast abi-encode "f(address,bytes)" "$GATEWAY_IMPL" "$INIT_GATEWAY")
echo "[8/9] Gateway proxy (ERC1967Proxy)..."
forge verify-contract --watch --chain "$CHAIN" "$GATEWAY" lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
  --constructor-args "$GATEWAY_PROXY_ARGS" --rpc-url "$RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true

# 9) MockERC20Token
if [ -n "$MOCK_TOKEN" ] && [ "$MOCK_TOKEN" != "0x0000000000000000000000000000000000000000" ]; then
  MOCK_ARGS=$(cast abi-encode "f(string,string,uint256,address)" "Mock Deposit Token" "MDT" "$MOCK_SUPPLY" "$MOCK_RECIPIENT")
  echo "[9/9] MockERC20Token..."
  forge verify-contract --watch --chain "$CHAIN" "$MOCK_TOKEN" contracts/mocks/MockERC20.sol:MockERC20Token \
    --constructor-args "$MOCK_ARGS" --rpc-url "$RPC" --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY" || true
else
  echo "[9/9] MockERC20Token skipped (no address)"
fi

echo ""
echo "Verification complete."
