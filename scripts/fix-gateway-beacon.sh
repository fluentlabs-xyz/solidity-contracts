#!/usr/bin/env bash
# Fix existing gateways: set other side using the **factory beacon** (not impl) so Create2
# pegged-token addresses match and receivePeggedTokens mints on L2.
# No redeploy: only calls setOtherSide on both gateways.
#
# Usage: set L1_GATEWAY, L1_FACTORY, L2_GATEWAY, L2_FACTORY (from your deploy output), then:
#   ./scripts/fix-gateway-beacon.sh
#
# Example (replace with your addresses):
#   L1_GATEWAY=0x... L1_FACTORY=0x... L2_GATEWAY=0x... L2_FACTORY=0x... ./scripts/fix-gateway-beacon.sh

set -e
L1_NETWORK="${L1_NETWORK:-sepoliaEth}"
L2_NETWORK="${L2_NETWORK:-fluentDev}"

for v in L1_GATEWAY L1_FACTORY L2_GATEWAY L2_FACTORY; do
  [ -n "${!v}" ] || { echo "Set $v (e.g. from deploy output)."; exit 1; }
done

echo "=== Get L2 factory beacon (${L2_NETWORK}) ==="
L2_BEACON=$(FACTORY_ADDRESS="$L2_FACTORY" npx hardhat run scripts/GetFactoryBeacon.js --network "$L2_NETWORK" 2>/dev/null | grep "ERC20TokenFactoryBeacon:" | head -1 | awk '{print $2}')
[ -n "$L2_BEACON" ] || { echo "Could not get L2 beacon."; exit 1; }
echo "L2_BEACON=$L2_BEACON"

echo ""
echo "=== Get L1 factory beacon (${L1_NETWORK}) ==="
L1_BEACON=$(FACTORY_ADDRESS="$L1_FACTORY" npx hardhat run scripts/GetFactoryBeacon.js --network "$L1_NETWORK" 2>/dev/null | grep "ERC20TokenFactoryBeacon:" | head -1 | awk '{print $2}')
[ -n "$L1_BEACON" ] || { echo "Could not get L1 beacon."; exit 1; }
echo "L1_BEACON=$L1_BEACON"

echo ""
echo "=== Set other side on L1 gateway (use L2 beacon) ==="
GATEWAY_ADDRESS="$L1_GATEWAY" OTHER_GATEWAY="$L2_GATEWAY" OTHER_IMPL="$L2_BEACON" OTHER_FACTORY="$L2_FACTORY" \
  npx hardhat run scripts/SetGatewayOtherSide.js --network "$L1_NETWORK"

echo ""
echo "=== Set other side on L2 gateway (use L1 beacon) ==="
GATEWAY_ADDRESS="$L2_GATEWAY" OTHER_GATEWAY="$L1_GATEWAY" OTHER_IMPL="$L1_BEACON" OTHER_FACTORY="$L1_FACTORY" \
  npx hardhat run scripts/SetGatewayOtherSide.js --network "$L2_NETWORK"

echo ""
echo "Done. Gateways now use the correct beacon for Create2. Do a new deposit and run the relayer to get tokens on Fluent."
