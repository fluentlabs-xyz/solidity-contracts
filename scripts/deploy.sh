#!/usr/bin/env bash
set -euo pipefail

# Deployment orchestrator — runs all forge scripts in dependency order.
#
# Usage:
#   ./scripts/deploy.sh                    # deploy all (L1 + L2 + setup)
#   ./scripts/deploy.sh --l1-only          # deploy L1 only
#   ./scripts/deploy.sh --l2-only          # deploy L2 only
#   ./scripts/deploy.sh --setup-only       # setup only (requires deployed manifests)
#   ./scripts/deploy.sh --preflight        # clean build
#
# Required env:
#   L1_RPC          L1 RPC URL (e.g. Sepolia)
#   L2_RPC          L2 RPC URL (e.g. Fluent)
#   DEPLOYER        Account name (cast wallet import) — or use DEPLOYER_KEY instead
#
# Optional env:
#   DEPLOYER_KEY    Private key (takes precedence over DEPLOYER, useful for Anvil)
#   ENV             Deployment environment (default: testnet) — determines config and manifest paths
#   VERIFY          Set to 1 to verify contracts (default: 0)
#   L2_FORGE        Forge binary for L2 (default: forge)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Save CLI overrides before sourcing .env (command-line takes precedence)
_CLI_ENV="${ENV:-}" _CLI_L1_RPC="${L1_RPC:-}" _CLI_L2_RPC="${L2_RPC:-}"
_CLI_L2_FORGE="${L2_FORGE:-}" _CLI_DEPLOYER="${DEPLOYER:-}" _CLI_DEPLOYER_KEY="${DEPLOYER_KEY:-}"
_CLI_VERIFY="${VERIFY:-}"

# Auto-load .env if present
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

# Restore CLI overrides
[[ -n "$_CLI_ENV" ]] && ENV="$_CLI_ENV"
[[ -n "$_CLI_L1_RPC" ]] && L1_RPC="$_CLI_L1_RPC"
[[ -n "$_CLI_L2_RPC" ]] && L2_RPC="$_CLI_L2_RPC"
[[ -n "$_CLI_L2_FORGE" ]] && L2_FORGE="$_CLI_L2_FORGE"
[[ -n "$_CLI_DEPLOYER" ]] && DEPLOYER="$_CLI_DEPLOYER"
[[ -n "$_CLI_DEPLOYER_KEY" ]] && DEPLOYER_KEY="$_CLI_DEPLOYER_KEY"
[[ -n "$_CLI_VERIFY" ]] && VERIFY="$_CLI_VERIFY"

DEPLOY_DIR="$SCRIPT_DIR/deploy"

# OZ foundry-upgrades reads artifacts via FOUNDRY_OUT; align with foundry.toml
export FOUNDRY_OUT="${FOUNDRY_OUT:-out}"

ENV="${ENV:-testnet}"
L1_RPC="${L1_RPC:?L1_RPC required}"
L2_RPC="${L2_RPC:?L2_RPC required}"
L2_FORGE="${L2_FORGE:-forge}"

# Auth: DEPLOYER_KEY (private key) takes precedence over DEPLOYER (cast wallet account)
if [[ -n "${DEPLOYER_KEY:-}" ]]; then
    AUTH="--private-key $DEPLOYER_KEY"
elif [[ -n "${DEPLOYER:-}" ]]; then
    AUTH="--account $DEPLOYER"
else
    echo "Error: either DEPLOYER_KEY or DEPLOYER must be set" >&2
    exit 1
fi

# Derived from ENV: config paths and manifest output
NETWORK_L1="${ENV}/l1"
NETWORK_L2="${ENV}/l2"

# Ensure deployment output directory exists
mkdir -p "deployments/${ENV}"

VERIFY_FLAGS=""
if [[ "${VERIFY:-0}" == "1" ]]; then
    VERIFY_FLAGS="--verify --retries 5 --delay 10"
fi

COMMON_L1="--rpc-url $L1_RPC $AUTH --broadcast $VERIFY_FLAGS"
COMMON_L2="--rpc-url $L2_RPC $AUTH --broadcast --skip-simulation $VERIFY_FLAGS"

preflight() {
    echo "=== Pre-flight: clean build ==="
    forge clean && forge build
}

deploy_l1() {
    echo "=== L1: Deploy full stack (env: $ENV) ==="
    NETWORK=$NETWORK_L1 forge script "$DEPLOY_DIR/DeployL1.s.sol" $COMMON_L1
}

deploy_l2() {
    echo "=== L2: Deploy full stack (env: $ENV) ==="
    NETWORK=$NETWORK_L2 \
        $L2_FORGE script "$DEPLOY_DIR/DeployL2.s.sol" $COMMON_L2
}

setup_bridges() {
    echo "=== Setup: Link L1 → L2 (env: $ENV) ==="
    ENV=$ENV forge script "$DEPLOY_DIR/SetupL1.s.sol" $COMMON_L1

    echo "=== Setup: Link L2 → L1 (env: $ENV) ==="
    ENV=$ENV $L2_FORGE script "$DEPLOY_DIR/SetupL2.s.sol" $COMMON_L2
}

case "${1:-all}" in
    --preflight)  preflight ;;
    --l1-only)    deploy_l1 ;;
    --l2-only)    deploy_l2 ;;
    --setup-only) setup_bridges ;;
    all)          deploy_l1; deploy_l2; setup_bridges ;;
    *)            echo "Usage: $0 [--l1-only|--l2-only|--setup-only|--preflight]"; exit 1 ;;
esac

echo "=== Done ==="
