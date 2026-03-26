#!/usr/bin/env bash
set -euo pipefail

# E2E test: Native token bridge L1→L2
# Requires: L1_RPC, L2_RPC, DEPLOYER, plus deployment manifests
#
# Usage: ./scripts/test-native-bridge.sh

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
l1_bridge=$(jq -r '.bridge // .deployment.bridge' "$L1_MANIFEST")
l2_bridge=$(jq -r '.bridge // .deployment.bridge' "$L2_MANIFEST")
l1_native_gw=$(jq -r '.native_gateway // .deployment.native_gateway' "$L1_MANIFEST")
l2_native_gw=$(jq -r '.native_gateway // .deployment.native_gateway' "$L2_MANIFEST")
l1_block_oracle=$(jq -r '.l1_block_oracle // .deployment.l1_block_oracle' "$L2_MANIFEST")

RECIPIENT="${RECIPIENT:-$(cast wallet address --account "$DEPLOYER")}"
AMOUNT_WEI="${AMOUNT_WEI:-10000000000000000}" # 0.01 ETH

echo "=== Step 1: Send native L1→L2 ==="
GATEWAY_ADDRESS="$l1_native_gw" RECIPIENT="$RECIPIENT" AMOUNT_WEI="$AMOUNT_WEI" \
    forge script scripts/operations/SendNative.s.sol \
    --rpc-url "$L1_RPC" --account "$DEPLOYER" --broadcast

echo "=== Step 2: Parse SentMessage event from broadcast ==="
L1_CHAIN_ID=$(cast chain-id --rpc-url "$L1_RPC")
BROADCAST_JSON="broadcast/SendNative.s.sol/${L1_CHAIN_ID}/run-latest.json"

# SentMessage is the last log in the last receipt, emitted by the bridge
EVENT_DATA=$(jq -r '.receipts[-1].logs[-1].data' "$BROADCAST_JSON")
echo "Event data: ${EVENT_DATA:0:66}..."

# Data layout: (uint256 value, uint256 chainId, uint256 blockNumber, uint256 nonce, bytes32 msgHash, bytes message)
DECODED=$(cast abi-decode --input "e(uint256,uint256,uint256,uint256,bytes32,bytes)" "$EVENT_DATA")
# Strip bracket notation (e.g. "10514421 [1.051e7]" → "10514421")
SRC_BLOCK=$(echo "$DECODED" | sed -n '3p' | awk '{print $1}')
NONCE=$(echo "$DECODED" | sed -n '4p' | awk '{print $1}')
MESSAGE=$(echo "$DECODED" | sed -n '6p')

echo "  Block: $SRC_BLOCK, Nonce: $NONCE, Chain: $L1_CHAIN_ID"

echo "=== Step 3: Update L1BlockOracle on L2 ==="
L1_BLOCK=$(cast block-number --rpc-url "$L1_RPC")
cast send "$l1_block_oracle" "updateL1BlockNumber(uint256)" "$L1_BLOCK" \
    --rpc-url "$L2_RPC" --account "$DEPLOYER"

echo "=== Step 4: Fund L2 bridge (simulates consensus-layer minting) ==="
cast send "$l2_bridge" --value "${AMOUNT_WEI}wei" \
    --rpc-url "$L2_RPC" --account "$DEPLOYER"

echo "=== Step 5: Relay message on L2 ==="
cast send "$l2_bridge" \
    "receiveMessage(address,address,uint256,uint256,uint256,uint256,bytes)" \
    "$l1_native_gw" "$l2_native_gw" "$AMOUNT_WEI" "$L1_CHAIN_ID" "$SRC_BLOCK" "$NONCE" "$MESSAGE" \
    --rpc-url "$L2_RPC" --account "$DEPLOYER"

echo "=== Step 6: Verify recipient balance on L2 ==="
L2_BAL=$(cast balance "$RECIPIENT" --rpc-url "$L2_RPC")
echo "  Recipient L2 balance: $L2_BAL"

echo "=== Native bridge L1→L2 test complete ==="
