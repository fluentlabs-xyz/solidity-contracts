#!/usr/bin/env bash
set -euo pipefail

# E2E test: ERC20 token bridge L1→L2.
#
# Deploys a fresh mock token on L1, deposits it via ERC20Gateway, and polls
# the L2 factory until the relayer delivers the message and the pegged
# token is created and minted. Assumes a live relayer and L1BlockOracle
# updater are running against both chains — no manual relay or oracle
# update.
#
# Required env: L1_RPC, L2_RPC, DEPLOYER
# Optional env: RECIPIENT, AMOUNT, POLL_TIMEOUT (s), POLL_INTERVAL (s),
#               ENV, L1_MANIFEST, L2_MANIFEST
#
# Usage: ./scripts/test-erc20-bridge.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ -f .env ]]; then set -a; source .env; set +a; fi

DEPLOYER="${DEPLOYER:?DEPLOYER required}"
L1_RPC="${L1_RPC:?L1_RPC required}"
L2_RPC="${L2_RPC:?L2_RPC required}"

ENV="${ENV:-testnet}"
L1_MANIFEST="${L1_MANIFEST:-deployments/${ENV}/l1.json}"
L2_MANIFEST="${L2_MANIFEST:-deployments/${ENV}/l2.json}"

l1_erc20_gw=$(jq -r '.erc20_gateway // .deployment.erc20_gateway' "$L1_MANIFEST")
l2_factory=$(jq -r '.factory // .deployment.factory' "$L2_MANIFEST")

RECIPIENT="${RECIPIENT:-$(cast wallet address --account "$DEPLOYER")}"
AMOUNT="${AMOUNT:-1000000000000000000}" # 1 token
POLL_TIMEOUT="${POLL_TIMEOUT:-180}"
POLL_INTERVAL="${POLL_INTERVAL:-3}"
ZERO_ADDR="0x0000000000000000000000000000000000000000"

echo "=== Step 1: Deploy fresh test token on L1 ==="
DEPLOY_LOG=$(mktemp)
forge create test/mocks/MockERC20.sol:MockERC20Token \
    --rpc-url "$L1_RPC" --account "$DEPLOYER" \
    --constructor-args "Test Token" "TST" "$AMOUNT" "$RECIPIENT" | tee "$DEPLOY_LOG"
mock_token=$(grep "Deployed to:" "$DEPLOY_LOG" | awk '{print $3}')
rm -f "$DEPLOY_LOG"
echo "  Token: $mock_token"

echo "=== Step 2: Deposit ERC20 L1→L2 ==="
GATEWAY_ADDRESS="$l1_erc20_gw" TOKEN_ADDRESS="$mock_token" \
    RECIPIENT="$RECIPIENT" AMOUNT="$AMOUNT" \
    forge script scripts/operations/DepositTokens.s.sol \
    --rpc-url "$L1_RPC" --account "$DEPLOYER" --broadcast

echo "=== Step 3: Poll for pegged token on L2 (timeout ${POLL_TIMEOUT}s) ==="
DEADLINE=$(( $(date +%s) + POLL_TIMEOUT ))
PEGGED="$ZERO_ADDR"
while (( $(date +%s) < DEADLINE )); do
    PEGGED=$(cast call "$l2_factory" "bridgedTokens(address)(address)" "$mock_token" --rpc-url "$L2_RPC" 2>/dev/null || echo "$ZERO_ADDR")
    if [[ "$PEGGED" != "$ZERO_ADDR" ]]; then
        break
    fi
    sleep "$POLL_INTERVAL"
done

if [[ "$PEGGED" == "$ZERO_ADDR" ]]; then
    echo "=== ERC20 bridge L1→L2 test FAILED — timeout waiting for pegged token ==="
    exit 1
fi
echo "  Pegged token: $PEGGED"

echo "=== Step 4: Verify recipient balance on L2 ==="
BAL=$(cast call "$PEGGED" "balanceOf(address)(uint256)" "$RECIPIENT" --rpc-url "$L2_RPC")
BAL_DECIMAL=$(echo "$BAL" | awk '{print $1}')
echo "  Balance: $BAL"

if [[ "$BAL_DECIMAL" == "0" ]]; then
    echo "=== ERC20 bridge L1→L2 test FAILED — pegged token deployed but recipient balance is zero ==="
    exit 1
fi
echo "=== ERC20 bridge L1→L2 test PASSED ==="
