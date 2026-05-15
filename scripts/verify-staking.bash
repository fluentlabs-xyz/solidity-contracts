#!/usr/bin/env bash
set -euo pipefail

# Verify deployed staking contracts on Fluent Blockscout.
# The script prompts for the target network before running.
#
# Optional env:
#   STAKING_MANIFEST       default: deployments/<env>/staking.json
#   VERIFIER_URL           default: https://fluentscan.xyz/api
#   FLUENT_TESTNET_RPC_URL default: https://rpc.testnet.fluent.xyz
#   FLUENT_MAINNET_RPC_URL default: https://rpc.fluent.xyz
#   VERIFY_MOCK_IMPLS=true verifies MockStaking/MockSystemReward impls
#   STAKING_IMPL_CONTRACT  override staking implementation source
#   SYSTEM_REWARD_IMPL_CONTRACT override system reward implementation source

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

select_network() {
    local choice="${1:-}"
    if [[ -z "$choice" ]]; then
        echo "Select Fluent network:"
        echo "  1) fluent-tesnet"
        echo "  2) fluent-mainnet"
        read -r -p "Network [fluent-tesnet/fluent-mainnet]: " choice
    fi

    case "$choice" in
        1|fluent-tesnet|fluent-testnet|testnet)
            ENV_NAME="testnet"
            NETWORK="testnet/l2"
            RPC="${FLUENT_TESTNET_RPC_URL:-https://rpc.testnet.fluent.xyz}"
            VERIFIER_URL="https://api-testnet.fluentscan.xyz/api"
            ;;
        2|fluent-mainnet|mainnet)
            ENV_NAME="mainnet"
            NETWORK="mainnet/l2"
            RPC="${FLUENT_MAINNET_RPC_URL:-https://rpc.fluent.xyz}"
            VERIFIER_URL="https://api.fluentscan.xyz/api"
            ;;
        *)
            echo "Unsupported network: $choice" >&2
            exit 2
            ;;
    esac
}

select_network "${1:-}"

MANIFEST="${STAKING_MANIFEST:-deployments/${ENV_NAME}/staking.json}"
CONFIG="scripts/config/${NETWORK}.json"

[[ -f "$MANIFEST" ]] || { echo "$MANIFEST not found" >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "$CONFIG not found" >&2; exit 1; }

addr() { jq -r ".$1 // empty" "$MANIFEST"; }

STAKING=$(addr staking)
STAKING_IMPL=$(addr staking_impl)
SLASHING_INDICATOR=$(addr slashing_indicator)
SLASHING_INDICATOR_IMPL=$(addr slashing_indicator_impl)
SYSTEM_REWARD=$(addr system_reward)
SYSTEM_REWARD_IMPL=$(addr system_reward_impl)
STAKING_POOL=$(addr staking_pool)
STAKING_POOL_IMPL=$(addr staking_pool_impl)
CHAIN_CONFIG=$(addr chain_config)
CHAIN_CONFIG_IMPL=$(addr chain_config_impl)
GOVERNANCE=$(addr governance)
GOVERNANCE_IMPL=$(addr governance_impl)
STAKING_TOKEN=$(jq -r '.staking.token' "$CONFIG")

CONFIG_CHAIN_ID=$(jq -r '.chainId' "$CONFIG")
RPC_CHAIN_ID="$(cast chain-id --rpc-url "$RPC")"
if [[ "$RPC_CHAIN_ID" != "$CONFIG_CHAIN_ID" ]]; then
    echo "Wrong RPC for $NETWORK" >&2
    echo "  config chainId: $CONFIG_CHAIN_ID" >&2
    echo "  rpc chainId:    $RPC_CHAIN_ID" >&2
    exit 1
fi

COMMON=(--rpc-url "$RPC" --verifier blockscout --verifier-url "$VERIFIER_URL" --watch)
PASS=0
FAIL=0

verify() {
    local label="$1"; shift
    echo "[$label]"
    if forge verify-contract "${COMMON[@]}" "$@" 2>&1; then
        PASS=$((PASS + 1))
    else
        echo "  FAILED (continuing)"
        FAIL=$((FAIL + 1))
    fi
    echo ""
}

STAKING_ARGS=$(cast abi-encode "f(address,address,address,address,address,address,address)" \
    "$STAKING" "$SLASHING_INDICATOR" "$SYSTEM_REWARD" "$STAKING_POOL" "$GOVERNANCE" "$CHAIN_CONFIG" "$STAKING_TOKEN")
GOVERNANCE_ARGS=$(cast abi-encode "f(address,address)" "$STAKING" "$CHAIN_CONFIG")

if [[ "${VERIFY_MOCK_IMPLS:-false}" == "true" || "${VERIFY_MOCK_IMPLS:-0}" == "1" ]]; then
    DEFAULT_STAKING_IMPL_CONTRACT="contracts/staking/mocks/MockStaking.sol:MockStaking"
    DEFAULT_SYSTEM_REWARD_IMPL_CONTRACT="contracts/staking/mocks/MockSystemReward.sol:MockSystemReward"
else
    DEFAULT_STAKING_IMPL_CONTRACT="contracts/staking/Staking.sol:Staking"
    DEFAULT_SYSTEM_REWARD_IMPL_CONTRACT="contracts/staking/SystemReward.sol:SystemReward"
fi

STAKING_IMPL_CONTRACT="${STAKING_IMPL_CONTRACT:-$DEFAULT_STAKING_IMPL_CONTRACT}"
SYSTEM_REWARD_IMPL_CONTRACT="${SYSTEM_REWARD_IMPL_CONTRACT:-$DEFAULT_SYSTEM_REWARD_IMPL_CONTRACT}"

echo "=== Verifying staking contracts (network: $NETWORK, chainId: $RPC_CHAIN_ID) ==="
echo "=== Manifest: $MANIFEST ==="
echo "=== Blockscout: $VERIFIER_URL ==="
echo ""

verify "Staking impl" "$STAKING_IMPL" "$STAKING_IMPL_CONTRACT" --constructor-args "$STAKING_ARGS"
verify "Staking proxy" "$STAKING" \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --guess-constructor-args

verify "SlashingIndicator impl" "$SLASHING_INDICATOR_IMPL" \
    contracts/staking/SlashingIndicator.sol:SlashingIndicator \
    --constructor-args "$STAKING_ARGS"
verify "SlashingIndicator proxy" "$SLASHING_INDICATOR" \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --guess-constructor-args

verify "SystemReward impl" "$SYSTEM_REWARD_IMPL" "$SYSTEM_REWARD_IMPL_CONTRACT" --constructor-args "$STAKING_ARGS"
verify "SystemReward proxy" "$SYSTEM_REWARD" \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --guess-constructor-args

verify "StakingPool impl" "$STAKING_POOL_IMPL" \
    contracts/staking/StakingPool.sol:StakingPool \
    --constructor-args "$STAKING_ARGS"
verify "StakingPool proxy" "$STAKING_POOL" \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --guess-constructor-args

verify "ChainConfig impl" "$CHAIN_CONFIG_IMPL" \
    contracts/staking/ChainConfig.sol:ChainConfig \
    --constructor-args "$STAKING_ARGS"
verify "ChainConfig proxy" "$CHAIN_CONFIG" \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --guess-constructor-args

verify "FluentGovernance impl" "$GOVERNANCE_IMPL" \
    contracts/governance/FluentGovernance.sol:FluentGovernance \
    --constructor-args "$GOVERNANCE_ARGS"
verify "FluentGovernance proxy" "$GOVERNANCE" \
    lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
    --guess-constructor-args

echo "=== Staking verification complete: $PASS passed, $FAIL failed ==="
