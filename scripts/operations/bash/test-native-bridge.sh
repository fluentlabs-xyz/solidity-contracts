#!/usr/bin/env bash
set -euo pipefail

# E2E test: Native token bridge L1→L2.
#
# Sends native ETH from L1 via NativeGateway and polls the L2 recipient
# balance until the relayer delivers the message. Assumes a live relayer
# and L1BlockOracle updater are running against both chains — no manual
# relay or oracle update.
#
# Required env: L1_RPC, L2_RPC, DEPLOYER
# Optional env: RECIPIENT, AMOUNT_WEI, POLL_TIMEOUT (s), POLL_INTERVAL (s),
#               ENV, L1_MANIFEST, L2_MANIFEST
#
# Usage: ./scripts/test-native-bridge.sh

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

l1_native_gw=$(jq -r '.native_gateway // .deployment.native_gateway' "$L1_MANIFEST")

RECIPIENT="${RECIPIENT:-$(cast wallet address --account "$DEPLOYER")}"
AMOUNT_WEI="${AMOUNT_WEI:-10000000000000000}" # 0.01 ETH
POLL_TIMEOUT="${POLL_TIMEOUT:-180}"
POLL_INTERVAL="${POLL_INTERVAL:-3}"

echo "=== Step 1: Snapshot L2 recipient balance ==="
BAL_BEFORE=$(cast balance "$RECIPIENT" --rpc-url "$L2_RPC")
EXPECTED=$(echo "$BAL_BEFORE + $AMOUNT_WEI" | bc)
echo "  Recipient: $RECIPIENT"
echo "  Before:    $BAL_BEFORE"
echo "  Expected:  $EXPECTED"

echo "=== Step 2: Send native L1→L2 ==="
GATEWAY_ADDRESS="$l1_native_gw" RECIPIENT="$RECIPIENT" AMOUNT_WEI="$AMOUNT_WEI" \
    forge script scripts/operations/SendNative.s.sol \
    --rpc-url "$L1_RPC" --account "$DEPLOYER" --broadcast

echo "=== Step 3: Poll L2 balance (timeout ${POLL_TIMEOUT}s) ==="
DEADLINE=$(( $(date +%s) + POLL_TIMEOUT ))
while (( $(date +%s) < DEADLINE )); do
    BAL_NOW=$(cast balance "$RECIPIENT" --rpc-url "$L2_RPC")
    if [[ "$(echo "$BAL_NOW >= $EXPECTED" | bc)" == "1" ]]; then
        echo "  After: $BAL_NOW"
        echo "=== Native bridge L1→L2 test PASSED ==="
        exit 0
    fi
    sleep "$POLL_INTERVAL"
done

echo "  Last observed L2 balance: $(cast balance "$RECIPIENT" --rpc-url "$L2_RPC")"
echo "  Expected at least:        $EXPECTED"
echo "=== Native bridge L1→L2 test FAILED — timeout waiting for relayer ==="
exit 1
