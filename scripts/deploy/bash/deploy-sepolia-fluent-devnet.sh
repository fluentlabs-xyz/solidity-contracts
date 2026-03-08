#!/usr/bin/env bash
# Full deploy: bridges + ERC20 gateways on Sepolia (L1) and Fluent Devnet (L2), mock token on Sepolia.
# Then: deposit token (Sepolia -> Fluent dev), run relayer to submit receive message.
#
# Prerequisites:
#   - PRIVATE_KEY for deployer (and Sepolia ETH + Fluent dev ETH for gas)
#   - Optional: RELAYER_ADDRESS as bridgeAuthority (default: deployer)
#
# Usage:
#   ./scripts/deploy-sepolia-fluent-devnet.sh
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

L1_NETWORK="${L1_NETWORK:-sepoliaEth}"
L2_NETWORK="${L2_NETWORK:-fluentDev}"
L1_LOG="/tmp/fluent-l1-deploy.log"
L2_LOG="/tmp/fluent-l2-deploy.log"
L1_GW_LOG="/tmp/fluent-l1-gateway.log"
L2_GW_LOG="/tmp/fluent-l2-gateway.log"
MOCK_LOG="/tmp/fluent-mock-token.log"

echo "=== Step 1: Deploy L1 bridge (${L1_NETWORK}) ==="
npx hardhat run scripts/DeployBridgesNoRollup.js --network "$L1_NETWORK" 2>&1 | tee "$L1_LOG"
L1_BRIDGE=$(grep "FluentBridge:" "$L1_LOG" | head -1 | awk '{print $2}')
if [ -z "$L1_BRIDGE" ]; then
  L1_BRIDGE=$(grep "L1_BRIDGE_ADDRESS=" "$L1_LOG" | head -1 | cut -d= -f2)
fi
[ -n "$L1_BRIDGE" ] || { echo "Could not parse L1 bridge."; exit 1; }
echo "L1 FluentBridge: $L1_BRIDGE"

echo ""
echo "=== Step 2: Deploy L2 bridge (${L2_NETWORK}) ==="
npx hardhat run scripts/DeployBridgesNoRollup.js --network "$L2_NETWORK" 2>&1 | tee "$L2_LOG"
L2_BRIDGE=$(grep "FluentBridge:" "$L2_LOG" | head -1 | awk '{print $2}')
if [ -z "$L2_BRIDGE" ]; then
  L2_BRIDGE=$(grep "L2_BRIDGE_ADDRESS=" "$L2_LOG" | head -1 | cut -d= -f2)
fi
[ -n "$L2_BRIDGE" ] || { echo "Could not parse L2 bridge."; exit 1; }
echo "L2 FluentBridge: $L2_BRIDGE"

echo ""
echo "=== Step 3a: Set other bridge on L1 ==="
BRIDGE_ADDRESS="$L1_BRIDGE" OTHER_BRIDGE_ADDRESS="$L2_BRIDGE" npx hardhat run scripts/SetOtherBridge.js --network "$L1_NETWORK"

echo ""
echo "=== Step 3b: Set other bridge on L2 ==="
BRIDGE_ADDRESS="$L2_BRIDGE" OTHER_BRIDGE_ADDRESS="$L1_BRIDGE" npx hardhat run scripts/SetOtherBridge.js --network "$L2_NETWORK"

echo ""
echo "=== Step 4: Deploy ERC20 gateway stack on L1 (${L1_NETWORK}) ==="
BRIDGE_ADDRESS="$L1_BRIDGE" npx hardhat run scripts/DeployERC20GatewayNoRollup.js --network "$L1_NETWORK" 2>&1 | tee "$L1_GW_LOG"
L1_IMPL=$(grep "ERC20PeggedTokenImpl:" "$L1_GW_LOG" | head -1 | awk '{print $2}')
L1_FACTORY=$(grep "ERC20TokenFactory:" "$L1_GW_LOG" | head -1 | awk '{print $2}')
L1_BEACON=$(grep "ERC20TokenFactoryBeacon:" "$L1_GW_LOG" | head -1 | awk '{print $2}')
L1_GATEWAY=$(grep "ERC20Gateway:" "$L1_GW_LOG" | head -1 | awk '{print $2}')
[ -n "$L1_GATEWAY" ] || { echo "Could not parse L1 gateway."; exit 1; }
echo "L1 Gateway: $L1_GATEWAY  Factory: $L1_FACTORY  Beacon: $L1_BEACON"

echo ""
echo "=== Step 5: Deploy ERC20 gateway stack on L2 (${L2_NETWORK}) ==="
BRIDGE_ADDRESS="$L2_BRIDGE" npx hardhat run scripts/DeployERC20GatewayNoRollup.js --network "$L2_NETWORK" 2>&1 | tee "$L2_GW_LOG"
L2_IMPL=$(grep "ERC20PeggedTokenImpl:" "$L2_GW_LOG" | head -1 | awk '{print $2}')
L2_FACTORY=$(grep "ERC20TokenFactory:" "$L2_GW_LOG" | head -1 | awk '{print $2}')
L2_BEACON=$(grep "ERC20TokenFactoryBeacon:" "$L2_GW_LOG" | head -1 | awk '{print $2}')
L2_GATEWAY=$(grep "ERC20Gateway:" "$L2_GW_LOG" | head -1 | awk '{print $2}')
[ -n "$L2_GATEWAY" ] || { echo "Could not parse L2 gateway."; exit 1; }
echo "L2 Gateway: $L2_GATEWAY  Factory: $L2_FACTORY  Beacon: $L2_BEACON"

echo ""
echo "=== Step 6: Set other side on L1 gateway (use L2 beacon for Create2) ==="
GATEWAY_ADDRESS="$L1_GATEWAY" OTHER_GATEWAY="$L2_GATEWAY" OTHER_IMPL="$L2_BEACON" OTHER_FACTORY="$L2_FACTORY" \
  npx hardhat run scripts/SetGatewayOtherSide.js --network "$L1_NETWORK"

echo ""
echo "=== Step 7: Set other side on L2 gateway (use L1 beacon for Create2) ==="
GATEWAY_ADDRESS="$L2_GATEWAY" OTHER_GATEWAY="$L1_GATEWAY" OTHER_IMPL="$L1_BEACON" OTHER_FACTORY="$L1_FACTORY" \
  npx hardhat run scripts/SetGatewayOtherSide.js --network "$L2_NETWORK"

echo ""
echo "=== Step 8: Deploy MockERC20Token on L1 (${L1_NETWORK}) ==="
npx hardhat run scripts/DeployMockERC20.js --network "$L1_NETWORK" 2>&1 | tee "$MOCK_LOG"
MOCK_TOKEN=$(grep "MockERC20Token:" "$MOCK_LOG" | head -1 | awk '{print $2}')
[ -n "$MOCK_TOKEN" ] || { echo "Could not parse MockERC20Token."; exit 1; }
echo "MockERC20Token: $MOCK_TOKEN"

echo ""
echo "=== Deployment complete ==="
echo "L1_BRIDGE_ADDRESS=$L1_BRIDGE"
echo "L2_BRIDGE_ADDRESS=$L2_BRIDGE"
echo "L1_GATEWAY_ADDRESS=$L1_GATEWAY"
echo "L2_GATEWAY_ADDRESS=$L2_GATEWAY"
echo "MOCK_TOKEN_ADDRESS=$MOCK_TOKEN"
echo ""
echo "=== Step 9: Deposit token (Sepolia -> Fluent dev) ==="
echo "  Set RECIPIENT_ADDRESS (Fluent dev address that will receive pegged tokens), then run:"
echo "  L1_GATEWAY_ADDRESS=$L1_GATEWAY MOCK_TOKEN_ADDRESS=$MOCK_TOKEN RECIPIENT_ADDRESS=<addr> AMOUNT=1000 \\"
echo "    npx hardhat run scripts/DepositERC20SepoliaToFluent.js --network $L1_NETWORK"
echo ""
echo "=== Step 10: Submit receive message (run relayer) ==="
echo "  L1_BRIDGE_ADDRESS=$L1_BRIDGE L2_BRIDGE_ADDRESS=$L2_BRIDGE RELAYER_PRIVATE_KEY=<key> yarn relay:no-rollup"
echo "  (Relayer watches L1 SentMessage and calls L2 receiveMessage.)"
