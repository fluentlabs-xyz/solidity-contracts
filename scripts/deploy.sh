#!/usr/bin/env bash
set -euo pipefail

# Deployment orchestrator — runs all forge scripts in dependency order.
# Usage: ./scripts/deploy.sh [--l1-only] [--l2-only] [--setup-only] [--preflight]
#
# Required env:
#   L1_RPC          L1 RPC URL (e.g. Sepolia)
#   L2_RPC          L2 RPC URL (e.g. Fluent)
#   DEPLOYER        Account name (cast wallet import)
#
# Optional env:
#   NETWORK_L1      Config name for L1 (default: testnet/l1)
#   NETWORK_L2      Config name for L2 (default: testnet/l2)
#   VERIFY          Set to 1 to verify contracts (default: 0)
#   L2_FORGE        Forge binary for L2 (default: gblend)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Auto-load .env if present
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

# OZ Upgrades plugin reads FOUNDRY_OUT for artifact directory
export FOUNDRY_OUT="${FOUNDRY_OUT:-forge-out}"

DEPLOY_DIR="$SCRIPT_DIR/deploy"

NETWORK_L1="${NETWORK_L1:-testnet/l1}"
NETWORK_L2="${NETWORK_L2:-testnet/l2}"
DEPLOYER="${DEPLOYER:?DEPLOYER account name required}"
L1_RPC="${L1_RPC:?L1_RPC required}"
L2_RPC="${L2_RPC:?L2_RPC required}"
L2_FORGE="${L2_FORGE:-gblend}"

VERIFY_FLAGS=""
if [[ "${VERIFY:-0}" == "1" ]]; then
    VERIFY_FLAGS="--verify --retries 5 --delay 10"
fi

COMMON_L1="--rpc-url $L1_RPC --account $DEPLOYER --broadcast $VERIFY_FLAGS"
COMMON_L2="--rpc-url $L2_RPC --account $DEPLOYER --broadcast --skip-simulation $VERIFY_FLAGS"

preflight() {
    echo "=== Pre-flight: clean build ==="
    forge clean && forge build
}

deploy_l1() {
    echo "=== L1: Deploy full stack ==="
    NETWORK=$NETWORK_L1 forge script "$DEPLOY_DIR/DeployL1.s.sol" $COMMON_L1
}

deploy_l2() {
    echo "=== L2: Deploy full stack ==="
    NETWORK=$NETWORK_L2 ALLOW_UNSAFE_UPGRADES=true \
        $L2_FORGE script "$DEPLOY_DIR/DeployL2.s.sol" $COMMON_L2
}

setup_bridges() {
    echo "=== Setup: Link L1 → L2 ==="
    forge script "$DEPLOY_DIR/SetupL1.s.sol" $COMMON_L1

    echo "=== Setup: Link L2 → L1 ==="
    $L2_FORGE script "$DEPLOY_DIR/SetupL2.s.sol" $COMMON_L2
}

case "${1:-all}" in
    --preflight)  preflight ;;
    --l1-only)    deploy_l1 ;;
    --l2-only)    deploy_l2 ;;
    --setup-only) setup_bridges ;;
    all)          deploy_l1; deploy_l2; setup_bridges ;;
    *)            echo "Usage: $0 [--preflight|--l1-only|--l2-only|--setup-only]"; exit 1 ;;
esac

echo "=== Deployment complete ==="
