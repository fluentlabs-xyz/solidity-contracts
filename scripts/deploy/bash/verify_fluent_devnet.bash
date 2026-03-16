#!/usr/bin/env bash
set -euo pipefail

# Verifies Fluent Devnet implementation contracts (UUPS impls behind proxies).
# Usage:
#   bash scripts/deploy/bash/verify_fluent_devnet.bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
cd "$(root_dir)"

load_dotenv_if_present

require_env "FLUENT_DEV_RPC_URL"

VERIFIER_URL="${FLUENT_DEV_VERIFIER_URL:-https://api-devnet.fluentscan.xyz/api/}"
CHAIN_ID="20993"

bridge_proxy="$(json_get "deployments/fluent_dev.json" '.bridge')"
gateway_proxy="$(json_get "deployments/fluent_dev.json" '.gateway')"
factory_proxy="$(json_get "deployments/fluent_dev.json" '.factory')"

bridge_impl="$(impl_from_proxy "$bridge_proxy" "$FLUENT_DEV_RPC_URL")"
gateway_impl="$(impl_from_proxy "$gateway_proxy" "$FLUENT_DEV_RPC_URL")"
factory_impl="$(impl_from_proxy "$factory_proxy" "$FLUENT_DEV_RPC_URL")"

echo "Fluent Devnet proxies:"
echo "  bridge:  $bridge_proxy"
echo "  gateway: $gateway_proxy"
echo "  factory: $factory_proxy"
echo
echo "Fluent Devnet implementations:"
echo "  bridge_impl:  $bridge_impl"
echo "  gateway_impl: $gateway_impl"
echo "  factory_impl: $factory_impl"
echo "  verifier_url: $VERIFIER_URL"
echo

forge verify-contract "$bridge_impl" contracts/FluentBridge.sol:FluentBridge \
  --chain-id "$CHAIN_ID" --verifier blockscout --verifier-url "$VERIFIER_URL" --watch

forge verify-contract "$gateway_impl" contracts/gateways/PaymentGateway.sol:PaymentGateway \
  --chain-id "$CHAIN_ID" --verifier blockscout --verifier-url "$VERIFIER_URL" --watch

forge verify-contract "$factory_impl" contracts/factories/UniversalTokenFactory.sol:UniversalTokenFactory \
  --chain-id "$CHAIN_ID" --verifier blockscout --verifier-url "$VERIFIER_URL" --watch

echo
echo "Fluent Devnet verification completed."
