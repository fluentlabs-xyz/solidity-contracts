#!/usr/bin/env bash
set -euo pipefail

# Verify all L2 contracts on Blockscout.
# Reads deployment manifest and config to reconstruct constructor args.
#
# Required env: L2_RPC
# Optional env: ENV (default: testnet), VERIFIER_URL (default: Fluent testnet Blockscout)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
#cd "$PROJECT_ROOT"

if [[ -f .env ]]; then set -a; source .env; set +a; fi

ENV="${ENV:-testnet}"
MANIFEST="deployments/${ENV}/l2.json"
CONFIG="scripts/config/${ENV}/l2.json"
RPC="${L2_RPC:?L2_RPC required}"
VERIFIER_URL="${VERIFIER_URL:-https://fluentscan.xyz/api}"

[ -f "$MANIFEST" ] || { echo "$MANIFEST not found"; exit 1; }
[ -f "$CONFIG" ] || { echo "$CONFIG not found"; exit 1; }

# Read addresses from manifest
addr() { jq -r ".$1 // empty" "$MANIFEST"; }

L1_BLOCK_ORACLE=$(addr l1_block_oracle)
BRIDGE=$(addr bridge)
BRIDGE_IMPL=$(addr bridge_impl)
FACTORY=$(addr factory)
FACTORY_IMPL=$(addr factory_impl)
ERC20_GW=$(addr erc20_gateway)
ERC20_GW_IMPL=$(addr erc20_gateway_impl)
NATIVE_GW=$(addr native_gateway)
NATIVE_GW_IMPL=$(addr native_gateway_impl)

# Read config
RELAYER=$(jq -r '.roles.relayer' "$CONFIG")

CHAIN_ID=$(jq -r '.chainId' "$MANIFEST")
COMMON="--rpc-url $RPC --verifier blockscout --verifier-url $VERIFIER_URL --watch"
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

echo "=== Verifying L2 contracts (env: $ENV, chainId: $CHAIN_ID) ==="
echo "=== Blockscout: $VERIFIER_URL ==="
echo ""

# 1. L1BlockOracle (plain contract, constructor: submitter)
ORACLE_ARGS=$(cast abi-encode "f(address)" "$RELAYER")
verify "L1BlockOracle" "$L1_BLOCK_ORACLE" contracts/oracles/L1BlockOracle.sol:L1BlockOracle \
    --constructor-args "$ORACLE_ARGS"

# 2. L2FluentBridge implementation
verify "L2FluentBridge impl" "$BRIDGE_IMPL" contracts/bridge/L2/L2FluentBridge.sol:L2FluentBridge

# 3. L2FluentBridge proxy
verify "L2FluentBridge proxy" "$BRIDGE" \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --guess-constructor-args

# 4. UniversalTokenFactory implementation
verify "UniversalTokenFactory impl" "$FACTORY_IMPL" contracts/factories/UniversalTokenFactory.sol:UniversalTokenFactory

# 5. UniversalTokenFactory proxy
verify "UniversalTokenFactory proxy" "$FACTORY" \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --guess-constructor-args

# 6. ERC20Gateway implementation
verify "ERC20Gateway impl" "$ERC20_GW_IMPL" contracts/gateways/ERC20Gateway.sol:ERC20Gateway

# 7. ERC20Gateway proxy
verify "ERC20Gateway proxy" "$ERC20_GW" \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --guess-constructor-args

# 8. NativeGateway implementation
verify "NativeGateway impl" "$NATIVE_GW_IMPL" contracts/gateways/NativeGateway.sol:NativeGateway

# 9. NativeGateway proxy
verify "NativeGateway proxy" "$NATIVE_GW" \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --guess-constructor-args

echo "=== L2 verification complete: $PASS passed, $FAIL failed ==="
