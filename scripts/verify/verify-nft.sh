#!/usr/bin/env bash
set -euo pipefail

# Verify the NFT bridge contracts (ERC721 + ERC1155) on L1 (Etherscan) and L2 (Blockscout).
# The main verify-l1.sh / verify-l2.sh cover only the core stack; the NFT bundle lives in
# deployments/<env>/{l1,l2}.nft.json and is verified here.
#
# Required env: L1_RPC, L2_RPC, ETHERSCAN_API_KEY (L1 only)
# Optional env: ENV (default: testnet), VERIFIER_URL (default: Fluent testnet Blockscout),
#               L1_CHAIN (default: sepolia)
#
# Usage:
#   ./scripts/verify/verify-nft.sh          # both chains
#   ./scripts/verify/verify-nft.sh l2       # L2 (Fluent) only
#   ./scripts/verify/verify-nft.sh l1       # L1 (Sepolia) only

if [[ -f .env ]]; then set -a; source .env; set +a; fi

ENV="${ENV:-testnet}"
L1_MANIFEST="deployments/${ENV}/l1.nft.json"
L2_MANIFEST="deployments/${ENV}/l2.nft.json"
L1_CHAIN="${L1_CHAIN:-sepolia}"

# Fluent Blockscout URL differs per env; testnet is a distinct host. Override with VERIFIER_URL.
if [[ -z "${VERIFIER_URL:-}" ]]; then
    if [[ "$ENV" == "mainnet" ]]; then
        VERIFIER_URL="https://fluentscan.xyz/api"
    else
        VERIFIER_URL="https://testnet.fluentscan.xyz/api"
    fi
fi
WHICH="${1:-all}"

PASS=0
FAIL=0

# addr <manifest> <key>
addr() { jq -r ".$2 // empty" "$1"; }

# verify <label> <common-flags> <address> <contract> [extra args...]
verify() {
    local label="$1"; shift
    local common="$1"; shift
    local address="$1"; shift
    local contract="$1"; shift
    echo "[$label] $address"
    if forge verify-contract $common "$address" "$contract" "$@" 2>&1; then
        PASS=$((PASS + 1))
    else
        echo "  FAILED (continuing)"
        FAIL=$((FAIL + 1))
    fi
    echo ""
}

# verify_nft_set <manifest> <common-flags> <std>   (std = erc721 | erc1155)
verify_nft_set() {
    local m="$1" common="$2" std="$3"
    local Std                       # PascalCase for contract names
    [[ "$std" == "erc721" ]] && Std="ERC721" || Std="ERC1155"

    local pegged_impl factory_impl beacon factory gateway_impl gateway
    pegged_impl=$(addr "$m" "${std}_pegged_impl")
    factory_impl=$(addr "$m" "${std}_factory_impl")
    beacon=$(addr "$m" "${std}_factory_beacon")
    factory=$(addr "$m" "${std}_factory")
    gateway_impl=$(addr "$m" "${std}_gateway_impl")
    gateway=$(addr "$m" "${std}_gateway")

    # Implementations: constructor is _disableInitializers() only — no args.
    verify "${Std}PeggedToken impl" "$common" "$pegged_impl" \
        "contracts/tokens/${Std}PeggedToken.sol:${Std}PeggedToken"
    verify "${Std}TokenFactory impl" "$common" "$factory_impl" \
        "contracts/factories/${Std}TokenFactory.sol:${Std}TokenFactory"
    verify "${Std}Gateway impl" "$common" "$gateway_impl" \
        "contracts/gateways/${Std}Gateway.sol:${Std}Gateway"

    # Beacon: UpgradeableBeacon(implementation = peggedImpl, owner = factory).
    local beacon_args
    beacon_args=$(cast abi-encode "f(address,address)" "$pegged_impl" "$factory")
    verify "${Std} factory beacon" "$common" "$beacon" \
        "lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon" \
        --constructor-args "$beacon_args"

    # UUPS proxies: ERC1967Proxy(impl, initData) — let forge recover args from the creation tx.
    verify "${Std} factory proxy" "$common" "$factory" \
        "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy" \
        --guess-constructor-args
    verify "${Std} gateway proxy" "$common" "$gateway" \
        "lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy" \
        --guess-constructor-args
}

if [[ "$WHICH" == "all" || "$WHICH" == "l1" ]]; then
    [ -f "$L1_MANIFEST" ] || { echo "$L1_MANIFEST not found"; exit 1; }
    [ -n "${ETHERSCAN_API_KEY:-}" ] || { echo "ETHERSCAN_API_KEY required for L1"; exit 1; }
    L1_COMMON="--chain $L1_CHAIN --rpc-url ${L1_RPC:?L1_RPC required} --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY --watch"
    echo "=== Verifying NFT contracts on L1 (Etherscan, env: $ENV) ==="
    verify_nft_set "$L1_MANIFEST" "$L1_COMMON" erc721
    verify_nft_set "$L1_MANIFEST" "$L1_COMMON" erc1155
fi

if [[ "$WHICH" == "all" || "$WHICH" == "l2" ]]; then
    [ -f "$L2_MANIFEST" ] || { echo "$L2_MANIFEST not found"; exit 1; }
    L2_COMMON="--rpc-url ${L2_RPC:?L2_RPC required} --verifier blockscout --verifier-url $VERIFIER_URL --watch"
    echo "=== Verifying NFT contracts on L2 (Blockscout: $VERIFIER_URL, env: $ENV) ==="
    verify_nft_set "$L2_MANIFEST" "$L2_COMMON" erc721
    verify_nft_set "$L2_MANIFEST" "$L2_COMMON" erc1155
fi

echo "=== NFT verification complete: $PASS passed, $FAIL failed ==="
