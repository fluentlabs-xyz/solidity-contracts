#!/usr/bin/env bash
set -euo pipefail

# Verifies deployed implementation contracts on Sepolia + Fluent.
# Usage:
#   bash scripts/deploy/bash/verify_contracts.bash
#
# Required env:
#   ETHERSCAN_API_KEY
#   SEPOLIA_RPC_URL
#   FLUENT_DEV_RPC_URL
# Optional env:
#   FLUENT_NETWORK ("dev" or "testnet", default: testnet)
#   FLUENT_DEV_BLOCK_EXPLORER_URL (default: https://dev.fluentscan.xyz)
#   FLUENT_TESTNET_BLOCK_EXPLORER_URL (default: https://testnet.fluentscan.xyz)
#   FLUENTSCAN_API_KEY (if required by explorer)

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
cd "$(root_dir)"

load_dotenv_if_present

require_env "ETHERSCAN_API_KEY"
require_env "SEPOLIA_RPC_URL"
require_env "FLUENT_DEV_RPC_URL"

FLUENT_NETWORK="${FLUENT_NETWORK:-testnet}"

sep_bridge_proxy="$(json_get "deployments/sepolia.json" '.bridge')"
sep_gateway_proxy="$(json_get "deployments/sepolia.json" '.gateway')"
sep_factory_proxy="$(json_get "deployments/sepolia.json" '.factory')"
sep_pegged_impl="$(json_get "deployments/sepolia.json" '.pegged_impl')"

if [[ "$FLUENT_NETWORK" == "dev" ]]; then
  fluent_deploy_file="deployments/fluent_dev.json"
  fluent_rpc="${FLUENT_DEV_RPC_URL}"
  fluent_chain_id="20993"
  FLUENT_DEV_BLOCK_EXPLORER_URL="${FLUENT_DEV_BLOCK_EXPLORER_URL:-https://dev.fluentscan.xyz}"
  FLUENT_VERIFIER_URL="${FLUENT_DEV_BLOCK_EXPLORER_URL%/}/api/"
  flu_bridge_proxy="$(json_get "deployments/fluent_dev.json" '.bridge')"
  flu_gateway_proxy="$(json_get "deployments/fluent_dev.json" '.gateway')"
  flu_factory_proxy="$(json_get "deployments/fluent_dev.json" '.factory')"
elif [[ "$FLUENT_NETWORK" == "testnet" ]]; then
  fluent_deploy_file="deployments/fluent_testnet.json"
  fluent_rpc="${FLUENT_TESTNET_RPC_URL:-https://rpc.testnet.fluent.xyz/}"
  fluent_chain_id="20994"
  FLUENT_TESTNET_BLOCK_EXPLORER_URL="${FLUENT_TESTNET_BLOCK_EXPLORER_URL:-https://testnet.fluentscan.xyz}"
  FLUENT_VERIFIER_URL="${FLUENT_TESTNET_BLOCK_EXPLORER_URL%/}/api/"
  flu_bridge_proxy="$(json_get "deployments/fluent_testnet.json" '.deployment.bridge')"
  flu_gateway_proxy="$(json_get "deployments/fluent_testnet.json" '.deployment.gateway')"
  flu_factory_proxy="$(json_get "deployments/fluent_testnet.json" '.deployment.factory')"
else
  echo "Unsupported FLUENT_NETWORK=$FLUENT_NETWORK (expected: dev|testnet)"
  exit 1
fi

sep_bridge_impl="$(impl_from_proxy "$sep_bridge_proxy" "$SEPOLIA_RPC_URL")"
sep_gateway_impl="$(impl_from_proxy "$sep_gateway_proxy" "$SEPOLIA_RPC_URL")"
sep_factory_impl="$(impl_from_proxy "$sep_factory_proxy" "$SEPOLIA_RPC_URL")"

flu_bridge_impl="$(impl_from_proxy "$flu_bridge_proxy" "$fluent_rpc")"
flu_gateway_impl="$(impl_from_proxy "$flu_gateway_proxy" "$fluent_rpc")"
flu_factory_impl="$(impl_from_proxy "$flu_factory_proxy" "$fluent_rpc")"

echo "== Sepolia implementations =="
echo "FluentBridge:       $sep_bridge_impl"
echo "PaymentGateway:     $sep_gateway_impl"
echo "ERC20TokenFactory:  $sep_factory_impl"
echo "ERC20PeggedToken:   $sep_pegged_impl"
echo
echo "== Fluent implementations =="
echo "FluentBridge:          $flu_bridge_impl"
echo "PaymentGateway:        $flu_gateway_impl"
echo "UniversalTokenFactory: $flu_factory_impl"
echo "Fluent deployment file: $fluent_deploy_file"
echo "Fluent verifier URL:    $FLUENT_VERIFIER_URL"
echo

echo "Verifying on Sepolia (Etherscan)..."
forge verify-contract "$sep_bridge_impl" contracts/FluentBridge.sol:FluentBridge --chain sepolia --watch
forge verify-contract "$sep_gateway_impl" contracts/gateways/PaymentGateway.sol:PaymentGateway --chain sepolia --watch
forge verify-contract "$sep_factory_impl" contracts/factories/ERC20TokenFactory.sol:ERC20TokenFactory --chain sepolia --watch
forge verify-contract "$sep_pegged_impl" contracts/tokens/ERC20PeggedToken.sol:ERC20PeggedToken --chain sepolia --watch

echo
echo "Verifying on Fluent ($FLUENT_NETWORK) ..."
if [[ -n "${FLUENTSCAN_API_KEY:-}" ]]; then
  forge verify-contract "$flu_bridge_impl" contracts/FluentBridge.sol:FluentBridge \
    --chain-id "$fluent_chain_id" --verifier blockscout --verifier-url "$FLUENT_VERIFIER_URL" --etherscan-api-key "$FLUENTSCAN_API_KEY" --watch
  forge verify-contract "$flu_gateway_impl" contracts/gateways/PaymentGateway.sol:PaymentGateway \
    --chain-id "$fluent_chain_id" --verifier blockscout --verifier-url "$FLUENT_VERIFIER_URL" --etherscan-api-key "$FLUENTSCAN_API_KEY" --watch
  forge verify-contract "$flu_factory_impl" contracts/factories/UniversalTokenFactory.sol:UniversalTokenFactory \
    --chain-id "$fluent_chain_id" --verifier blockscout --verifier-url "$FLUENT_VERIFIER_URL" --etherscan-api-key "$FLUENTSCAN_API_KEY" --watch
else
  forge verify-contract "$flu_bridge_impl" contracts/FluentBridge.sol:FluentBridge \
    --chain-id "$fluent_chain_id" --verifier blockscout --verifier-url "$FLUENT_VERIFIER_URL" --watch
  forge verify-contract "$flu_gateway_impl" contracts/gateways/PaymentGateway.sol:PaymentGateway \
    --chain-id "$fluent_chain_id" --verifier blockscout --verifier-url "$FLUENT_VERIFIER_URL" --watch
  forge verify-contract "$flu_factory_impl" contracts/factories/UniversalTokenFactory.sol:UniversalTokenFactory \
    --chain-id "$fluent_chain_id" --verifier blockscout --verifier-url "$FLUENT_VERIFIER_URL" --watch
fi

echo
echo "Verification flow finished."
