#!/usr/bin/env bash
set -euo pipefail

# Verify all L1 contracts on Etherscan.
# Reads deployment manifest and config to reconstruct constructor args.
#
# Required env: ETHERSCAN_API_KEY, L1_RPC
# Optional env: ENV (default: testnet)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
#cd "$PROJECT_ROOT"

# Source .env for defaults (exported vars take precedence via :- syntax below)
if [[ -f .env ]]; then set -a; source .env; set +a; fi

ENV="${ENV:-testnet}"
MANIFEST="deployments/${ENV}/l1.json"
CONFIG="scripts/config/${ENV}/l1.json"
RPC="${L1_RPC:?L1_RPC required}"
CHAIN="${L1_CHAIN:-sepolia}"

[ -f "$MANIFEST" ] || { echo "$MANIFEST not found"; exit 1; }
[ -f "$CONFIG" ] || { echo "$CONFIG not found"; exit 1; }
[ -n "${ETHERSCAN_API_KEY:-}" ] || { echo "ETHERSCAN_API_KEY required"; exit 1; }

# Read addresses from manifest
addr() { jq -r ".$1 // empty" "$MANIFEST"; }

NITRO_VERIFIER=$(addr nitro_verifier)
ROLLUP=$(addr rollup)
ROLLUP_IMPL=$(addr rollup_impl)
BRIDGE=$(addr bridge)
BRIDGE_IMPL=$(addr bridge_impl)
FACTORY=$(addr factory)
FACTORY_IMPL=$(addr factory_impl)
FACTORY_BEACON=$(addr factory_beacon)
PEGGED_IMPL=$(addr pegged_impl)
ERC20_GW=$(addr erc20_gateway)
ERC20_GW_IMPL=$(addr erc20_gateway_impl)
NATIVE_GW=$(addr native_gateway)
NATIVE_GW_IMPL=$(addr native_gateway_impl)
MOCK_TOKEN=$(addr mock_token)

# Read config for constructor args
ADMIN=$(jq -r '.roles.admin' "$CONFIG")
PAUSER=$(jq -r '.roles.pauser' "$CONFIG")
RELAYER=$(jq -r '.roles.relayer' "$CONFIG")
INITIAL_OWNER=$(jq -r '.roles.initialOwner' "$CONFIG")
SP1_VERIFIER=$(jq -r '.rollup.sp1Verifier' "$CONFIG")

COMMON="--chain $CHAIN --rpc-url $RPC --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY --watch"
PASS=0
FAIL=0

verify() {
    local label="$1"; shift
    echo "[$label]"
    if forge verify-contract $COMMON "$@" 2>&1; then
        PASS=$((PASS + 1))
    else
        echo "  FAILED (continuing)"
        FAIL=$((FAIL + 1))
    fi
    echo ""
}

echo "=== Verifying L1 contracts (env: $ENV, chain: $CHAIN) ==="
echo ""

# 1. NitroVerifier (plain contract, constructor: sp1Verifier, admin)
NITRO_ARGS=$(cast abi-encode "f(address,address)" "$SP1_VERIFIER" "$ADMIN")
verify "NitroVerifier" "$NITRO_VERIFIER" contracts/verifier/NitroVerifier.sol:NitroVerifier \
    --constructor-args "$NITRO_ARGS"

# 2. Rollup implementation (no constructor args — _disableInitializers only)
verify "Rollup impl" "$ROLLUP_IMPL" contracts/rollup/Rollup.sol:Rollup

# 3. Rollup proxy (ERC1967Proxy)
# Constructor: ERC1967Proxy(implementation, initData)
# initData = Rollup.initialize(abi.encode(InitConfiguration))
# We can't easily reconstruct the full InitConfiguration ABI encoding in bash.
# Use --guess-constructor-args for proxies.
verify "Rollup proxy" "$ROLLUP" \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --guess-constructor-args

# 4. L1FluentBridge implementation
verify "L1FluentBridge impl" "$BRIDGE_IMPL" contracts/bridge/L1/L1FluentBridge.sol:L1FluentBridge

# 5. L1FluentBridge proxy
verify "L1FluentBridge proxy" "$BRIDGE" \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --guess-constructor-args

# 6. ERC20PeggedToken implementation
verify "ERC20PeggedToken impl" "$PEGGED_IMPL" contracts/tokens/ERC20PeggedToken.sol:ERC20PeggedToken

# 7. ERC20TokenFactory implementation
verify "ERC20TokenFactory impl" "$FACTORY_IMPL" contracts/factories/ERC20TokenFactory.sol:ERC20TokenFactory

# 8. ERC20TokenFactory proxy
verify "ERC20TokenFactory proxy" "$FACTORY" \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --guess-constructor-args

# 9. UpgradeableBeacon (constructor: implementation, owner)
BEACON_ARGS=$(cast abi-encode "f(address,address)" "$PEGGED_IMPL" "$FACTORY")
verify "UpgradeableBeacon" "$FACTORY_BEACON" \
    lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon \
    --constructor-args "$BEACON_ARGS"

# 10. ERC20Gateway implementation
verify "ERC20Gateway impl" "$ERC20_GW_IMPL" contracts/gateways/ERC20Gateway.sol:ERC20Gateway

# 11. ERC20Gateway proxy
verify "ERC20Gateway proxy" "$ERC20_GW" \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --guess-constructor-args

# 12. NativeGateway implementation
verify "NativeGateway impl" "$NATIVE_GW_IMPL" contracts/gateways/NativeGateway.sol:NativeGateway

# 13. NativeGateway proxy
verify "NativeGateway proxy" "$NATIVE_GW" \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --guess-constructor-args

# 14. MockERC20Token (optional)
if [[ -n "$MOCK_TOKEN" && "$MOCK_TOKEN" != "0x0000000000000000000000000000000000000000" ]]; then
    MOCK_ARGS=$(cast abi-encode "f(string,string,uint256,address)" "Mock Deposit Token" "MDT" "1000000000000000000000000" "$INITIAL_OWNER")
    verify "MockERC20Token" "$MOCK_TOKEN" test/mocks/MockERC20.sol:MockERC20Token \
        --constructor-args "$MOCK_ARGS"
fi

echo "=== L1 verification complete: $PASS passed, $FAIL failed ==="
