#!/usr/bin/env bash
set -euo pipefail

# E2E test: ERC20 token bridge L1→L2
# Requires: L1_RPC, L2_RPC, DEPLOYER, plus deployment manifests
#
# Usage: ./scripts/test-erc20-bridge.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ -f .env ]]; then set -a; source .env; set +a; fi


L2_FORGE="${L2_FORGE:-gblend}"
DEPLOYER="${DEPLOYER:?DEPLOYER required}"
L1_RPC="${L1_RPC:?L1_RPC required}"
L2_RPC="${L2_RPC:?L2_RPC required}"

ENV="${ENV:-testnet}"
L1_MANIFEST="${L1_MANIFEST:-deployments/${ENV}/l1.json}"
L2_MANIFEST="${L2_MANIFEST:-deployments/${ENV}/l2.json}"

# Read addresses from manifests
l2_bridge=$(jq -r '.bridge // .deployment.bridge' "$L2_MANIFEST")
l1_erc20_gw=$(jq -r '.erc20_gateway // .deployment.erc20_gateway' "$L1_MANIFEST")
l2_erc20_gw=$(jq -r '.erc20_gateway // .deployment.erc20_gateway' "$L2_MANIFEST")
l1_block_oracle=$(jq -r '.l1_block_oracle // .deployment.l1_block_oracle' "$L2_MANIFEST")

RECIPIENT="${RECIPIENT:-$(cast wallet address --account "$DEPLOYER")}"
AMOUNT="${AMOUNT:-1000000000000000000}" # 1 token

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

echo "=== Step 3: Parse SentMessage event from broadcast ==="
L1_CHAIN_ID=$(cast chain-id --rpc-url "$L1_RPC")
BROADCAST_JSON="broadcast/DepositTokens.s.sol/${L1_CHAIN_ID}/run-latest.json"

# SentMessage is the last log in the last receipt, emitted by the bridge
EVENT_DATA=$(jq -r '.receipts[-1].logs[-1].data' "$BROADCAST_JSON")
echo "Event data: ${EVENT_DATA:0:66}..."

# Data layout: (uint256 value, uint256 chainId, uint256 blockNumber, uint256 nonce, bytes32 msgHash, bytes message)
DECODED=$(cast abi-decode --input "e(uint256,uint256,uint256,uint256,bytes32,bytes)" "$EVENT_DATA")
# Strip bracket notation (e.g. "10514421 [1.051e7]" → "10514421")
SRC_BLOCK=$(echo "$DECODED" | sed -n '3p' | awk '{print $1}')
NONCE=$(echo "$DECODED" | sed -n '4p' | awk '{print $1}')
MESSAGE=$(echo "$DECODED" | sed -n '6p')

echo "  Block: $SRC_BLOCK, Nonce: $NONCE"

echo "=== Step 4: Update L1BlockOracle on L2 ==="
L1_BLOCK=$(cast block-number --rpc-url "$L1_RPC")
cast send "$l1_block_oracle" "updateL1BlockNumber(uint256)" "$L1_BLOCK" \
    --rpc-url "$L2_RPC" --account "$DEPLOYER"

echo "=== Step 5: Relay message on L2 ==="
# Use cast send directly — gblend script can't simulate proxy delegation
cast send "$l2_bridge" \
    "receiveMessage(address,address,uint256,uint256,uint256,uint256,bytes)" \
    "$l1_erc20_gw" "$l2_erc20_gw" 0 "$L1_CHAIN_ID" "$SRC_BLOCK" "$NONCE" "$MESSAGE" \
    --rpc-url "$L2_RPC" --account "$DEPLOYER"

echo "=== Step 6: Verify pegged token deployed on L2 ==="
l2_factory=$(jq -r '.factory // .deployment.factory' "$L2_MANIFEST")
# bridgedTokens maps originToken → peggedToken on the factory
PEGGED=$(cast call "$l2_factory" "bridgedTokens(address)(address)" "$mock_token" \
    --rpc-url "$L2_RPC" 2>/dev/null || echo "0x0")
echo "  Pegged token on L2: $PEGGED"

if [[ "$PEGGED" != "0x0000000000000000000000000000000000000000" && "$PEGGED" != "0x0" ]]; then
    BAL=$(cast call "$PEGGED" "balanceOf(address)(uint256)" "$RECIPIENT" --rpc-url "$L2_RPC")
    echo "  Recipient balance: $BAL"
    echo "=== ERC20 bridge L1→L2 test PASSED ==="
else
    echo "=== ERC20 bridge L1→L2 test FAILED — no pegged token found ==="
    exit 1
fi
