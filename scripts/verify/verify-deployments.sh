#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# verify-deployments.sh
#
# Unified Etherscan / Blockscout verifier for every address listed in
#   deployments/<ENV>/l1.json  and  deployments/<ENV>/l2.json
#
# For each proxy the script reads the live ERC-1967 implementation slot via
# `cast implementation` and warns if it differs from the manifest's `_impl`
# key, then verifies both the proxy (ERC1967Proxy, --guess-constructor-args)
# and its implementation (using a static manifest-key -> source-path map).
#
# Usage:
#   ./scripts/verify/verify-deployments.sh --env mainnet --layer l1
#   ./scripts/verify/verify-deployments.sh --env testnet --layer both
#   ./scripts/verify/verify-deployments.sh --env mainnet --layer l1 --only bridge
#   ./scripts/verify/verify-deployments.sh --env mainnet --layer l1 --clean
#   ./scripts/verify/verify-deployments.sh --env mainnet --layer l1 --dry-run
#
# Required env:
#   ETHERSCAN_API_KEY   for L1 Etherscan verification
#   L1_RPC              for reading L1 impl slots + constructor-arg guessing
#   L2_RPC              for L2 impl slots + Blockscout verification
# Optional:
#   L1_CHAIN            forge --chain for L1 (auto-detected: mainnet/sepolia)
#   L2_VERIFIER_URL     override Blockscout API URL
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

ENV=testnet
LAYER=both
ONLY=""
DRY_RUN=false
CLEAN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)     ENV="$2"; shift 2 ;;
        --layer)   LAYER="$2"; shift 2 ;;
        --only)    ONLY="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --clean)   CLEAN=true; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

[[ -f .env ]] && { set -a; source .env; set +a; }

if $CLEAN; then
    echo "==> forge clean"
    forge clean >/dev/null 2>&1 || true
fi

PASS=0; FAIL=0; SKIP=0
WARNINGS=()

lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

matches() {
    # Returns 0 when --only filter is unset or matches the key.
    [[ -z "$ONLY" ]] && return 0
    [[ "$1" == *"$ONLY"* ]]
}

run() {
    # run <label> <forge verify-contract args...>
    local label="$1"; shift
    echo "[$label]"
    if $DRY_RUN; then
        # Mask sensitive flag values so the plan can be pasted/archived safely.
        local masked=() prev=""
        local x
        for x in "$@"; do
            case "$prev" in
                --etherscan-api-key|--verifier-url)
                    masked+=("***") ;;
                *) masked+=("$x") ;;
            esac
            prev="$x"
        done
        echo "  (dry-run) forge verify-contract ${masked[*]}"
        SKIP=$((SKIP + 1)); echo ""; return 0
    fi
    if forge verify-contract "$@" 2>&1; then
        PASS=$((PASS + 1))
    else
        echo "  FAILED (continuing)"
        FAIL=$((FAIL + 1))
    fi
    echo ""
}

check_impl_drift() {
    # check_impl_drift <layer> <proxy_key> <proxy_addr> <manifest_impl_key> <manifest_impl_addr> <rpc>
    local layer="$1" key="$2" proxy="$3" impl_key="$4" manifest_impl="$5" rpc="$6"
    [[ -n "$proxy" && "$proxy" != "0x0000000000000000000000000000000000000000" ]] || return 0
    local live
    live=$(cast implementation "$proxy" --rpc-url "$rpc" 2>/dev/null || true)
    [[ -n "$live" ]] || return 0
    if [[ -n "$manifest_impl" ]] && [[ "$(lc "$live")" != "$(lc "$manifest_impl")" ]]; then
        local msg="[$layer] $key: manifest $impl_key=$manifest_impl != on-chain impl=$live"
        echo "  WARN: $msg"
        WARNINGS+=("$msg")
    fi
}

# -----------------------------------------------------------------------------
# L1 (Etherscan)
# -----------------------------------------------------------------------------
verify_l1() {
    local MANIFEST="deployments/${ENV}/l1.json"
    local CONFIG="scripts/config/${ENV}/l1.json"

    [[ -f "$MANIFEST" ]] || { echo "L1: $MANIFEST missing, skipping"; return 0; }
    [[ -n "${ETHERSCAN_API_KEY:-}" ]] || { echo "ETHERSCAN_API_KEY required for L1"; return 1; }
    [[ -n "${L1_RPC:-}" ]] || { echo "L1_RPC required for L1"; return 1; }

    local CHAIN="${L1_CHAIN:-}"
    if [[ -z "$CHAIN" ]]; then
        case "$ENV" in
            mainnet) CHAIN=mainnet ;;
            testnet) CHAIN=sepolia ;;
            *)       CHAIN=mainnet ;;
        esac
    fi

    local FLAGS="--chain $CHAIN --rpc-url $L1_RPC --verifier etherscan --etherscan-api-key $ETHERSCAN_API_KEY --watch"
    local PROXY_ARTIFACT="lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy"

    addr() { jq -r ".$1 // empty" "$MANIFEST"; }
    cfg()  { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null; }

    echo ""
    echo "============================================================"
    echo "L1 verify -- env=$ENV chain=$CHAIN"
    echo "manifest=$MANIFEST"
    echo "============================================================"

    # Implementation contracts (constructor is just _disableInitializers).
    # Format: <manifest_key>|<source_path:ContractName>
    local L1_IMPLS=(
        "rollup_impl|contracts/rollup/Rollup.sol:Rollup"
        "bridge_impl|contracts/bridge/L1/L1FluentBridge.sol:L1FluentBridge"
        "pegged_impl|contracts/tokens/ERC20PeggedToken.sol:ERC20PeggedToken"
        "factory_impl|contracts/factories/ERC20TokenFactory.sol:ERC20TokenFactory"
        "erc20_gateway_impl|contracts/gateways/ERC20Gateway.sol:ERC20Gateway"
        "native_gateway_impl|contracts/gateways/NativeGateway.sol:NativeGateway"
        "fast_withdrawal_list_impl|contracts/fastlist/FastWithdrawalList.sol:FastWithdrawalList"
        "blacklist_impl|contracts/blacklist/Blacklist.sol:Blacklist"
        "weth_gateway_impl|contracts/gateways/WETHGateway.sol:WETHGateway"
    )
    # ERC-1967 proxies. Format: <proxy_key>|<impl_key>
    local L1_PROXIES=(
        "rollup|rollup_impl"
        "bridge|bridge_impl"
        "factory|factory_impl"
        "erc20_gateway|erc20_gateway_impl"
        "native_gateway|native_gateway_impl"
        "fast_withdrawal_list_proxy|fast_withdrawal_list_impl"
        "blacklist_proxy|blacklist_impl"
        "weth_gateway_proxy|weth_gateway_impl"
    )

    local row key path impl_key a
    for row in "${L1_IMPLS[@]}"; do
        key="${row%%|*}"; path="${row##*|}"
        matches "$key" || continue
        a=$(addr "$key")
        if [[ -z "$a" ]]; then
            echo "[$key] (missing in manifest, skip)"; SKIP=$((SKIP + 1)); echo ""; continue
        fi
        run "$key" $FLAGS "$a" "$path"
    done

    for row in "${L1_PROXIES[@]}"; do
        key="${row%%|*}"; impl_key="${row##*|}"
        matches "$key" || continue
        a=$(addr "$key")
        [[ -n "$a" ]] || { SKIP=$((SKIP + 1)); continue; }
        check_impl_drift L1 "$key" "$a" "$impl_key" "$(addr "$impl_key")" "$L1_RPC"
        run "$key (ERC1967Proxy)" $FLAGS "$a" "$PROXY_ARTIFACT" --guess-constructor-args
    done

    # NitroVerifier: plain contract, constructor (address sp1Verifier, address admin)
    if matches nitro_verifier; then
        local nv=$(addr nitro_verifier)
        if [[ -n "$nv" && -f "$CONFIG" ]]; then
            local admin=$(cfg 'roles.admin')
            local sp1=$(cfg 'rollup.sp1Verifier')
            if [[ -n "$admin" && -n "$sp1" ]]; then
                local args=$(cast abi-encode "f(address,address)" "$sp1" "$admin")
                run "nitro_verifier" $FLAGS "$nv" contracts/verifier/NitroVerifier.sol:NitroVerifier --constructor-args "$args"
            fi
        fi
    fi

    # factory_beacon: UpgradeableBeacon(impl, owner)
    if matches factory_beacon; then
        local fb=$(addr factory_beacon)
        local pi=$(addr pegged_impl)
        local fp=$(addr factory)
        if [[ -n "$fb" && -n "$pi" && -n "$fp" ]]; then
            local args=$(cast abi-encode "f(address,address)" "$pi" "$fp")
            run "factory_beacon" $FLAGS "$fb" \
                lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon \
                --constructor-args "$args"
        fi
    fi

    # timelock: FluentTimeLock(uint256 minDelay, address[] proposers, address[] executors)
    # Array args are awkward to reconstruct in bash — ask etherscan/forge to guess.
    if matches timelock; then
        local tl=$(addr timelock)
        if [[ -n "$tl" ]]; then
            run "timelock" $FLAGS "$tl" contracts/governance/FluentTimeLock.sol:FluentTimeLock \
                --guess-constructor-args
        fi
    fi

    # mock_token: MockERC20Token(string,string,uint256,address) — testnet only
    if matches mock_token; then
        local mt=$(addr mock_token)
        if [[ -n "$mt" && "$mt" != "0x0000000000000000000000000000000000000000" && -f "$CONFIG" ]]; then
            local owner=$(cfg 'roles.initialOwner')
            if [[ -n "$owner" ]]; then
                local args=$(cast abi-encode "f(string,string,uint256,address)" \
                    "Mock Deposit Token" "MDT" "1000000000000000000000000" "$owner")
                run "mock_token" $FLAGS "$mt" test/mocks/MockERC20.sol:MockERC20Token --constructor-args "$args"
            fi
        fi
    fi

    # weth_token: off-repo artifact (canonical WETH9). Skip unless user passed --only weth_token.
    if matches weth_token && [[ "$ONLY" == *weth_token* ]]; then
        local wt=$(addr weth_token)
        [[ -n "$wt" ]] && echo "[weth_token] off-repo artifact; verify manually: $wt"
    fi
}

# -----------------------------------------------------------------------------
# L2 (Blockscout)
# -----------------------------------------------------------------------------
verify_l2() {
    local MANIFEST="deployments/${ENV}/l2.json"
    local CONFIG="scripts/config/${ENV}/l2.json"

    [[ -f "$MANIFEST" ]] || { echo "L2: $MANIFEST missing, skipping"; return 0; }
    [[ -n "${L2_RPC:-}" ]] || { echo "L2_RPC required for L2"; return 1; }

    local vurl="${L2_VERIFIER_URL:-}"
    if [[ -z "$vurl" ]]; then
        case "$ENV" in
            mainnet) vurl="https://fluentscan.xyz/api" ;;
            testnet) vurl="https://testnet.fluentscan.xyz/api" ;;
            *)       vurl="https://fluentscan.xyz/api" ;;
        esac
    fi

    local FLAGS="--rpc-url $L2_RPC --verifier blockscout --verifier-url $vurl --watch"
    local PROXY_ARTIFACT="lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy"

    addr() { jq -r ".$1 // empty" "$MANIFEST"; }
    cfg()  { jq -r ".$1 // empty" "$CONFIG" 2>/dev/null; }

    echo ""
    echo "============================================================"
    echo "L2 verify -- env=$ENV blockscout=$vurl"
    echo "manifest=$MANIFEST"
    echo "============================================================"

    local L2_IMPLS=(
        "bridge_impl|contracts/bridge/L2/L2FluentBridge.sol:L2FluentBridge"
        "factory_impl|contracts/factories/UniversalTokenFactory.sol:UniversalTokenFactory"
        "erc20_gateway_impl|contracts/gateways/ERC20Gateway.sol:ERC20Gateway"
        "native_gateway_impl|contracts/gateways/NativeGateway.sol:NativeGateway"
        "pegged_impl|contracts/tokens/ERC20PeggedToken.sol:ERC20PeggedToken"
        "weth_gateway_impl|contracts/gateways/WETHGateway.sol:WETHGateway"
    )
    local L2_PROXIES=(
        "bridge|bridge_impl"
        "factory|factory_impl"
        "erc20_gateway|erc20_gateway_impl"
        "native_gateway|native_gateway_impl"
        "weth_gateway_proxy|weth_gateway_impl"
    )
    # Plain (non-proxy) contracts deployed directly by scripts.
    local L2_PLAIN=(
        "l1_block_oracle|contracts/oracles/L1BlockOracle.sol:L1BlockOracle"
        "l1_gas_oracle|contracts/oracles/L1GasOracle.sol:L1GasOracle"
    )

    local row key path impl_key a
    for row in "${L2_IMPLS[@]}"; do
        key="${row%%|*}"; path="${row##*|}"
        matches "$key" || continue
        a=$(addr "$key")
        [[ -n "$a" ]] || { SKIP=$((SKIP + 1)); continue; }
        run "$key" $FLAGS "$a" "$path"
    done

    for row in "${L2_PROXIES[@]}"; do
        key="${row%%|*}"; impl_key="${row##*|}"
        matches "$key" || continue
        a=$(addr "$key")
        [[ -n "$a" ]] || { SKIP=$((SKIP + 1)); continue; }
        check_impl_drift L2 "$key" "$a" "$impl_key" "$(addr "$impl_key")" "$L2_RPC"
        run "$key (ERC1967Proxy)" $FLAGS "$a" "$PROXY_ARTIFACT" --guess-constructor-args
    done

    for row in "${L2_PLAIN[@]}"; do
        key="${row%%|*}"; path="${row##*|}"
        matches "$key" || continue
        a=$(addr "$key")
        [[ -n "$a" ]] || { SKIP=$((SKIP + 1)); continue; }
        run "$key" $FLAGS "$a" "$path" --guess-constructor-args
    done

    # weth_token on L2 is an off-repo WETH9 — only mention it.
    if matches weth_token && [[ "$ONLY" == *weth_token* ]]; then
        local wt=$(addr weth_token)
        [[ -n "$wt" ]] && echo "[weth_token] off-repo artifact; verify manually: $wt"
    fi
}

case "$LAYER" in
    l1)   verify_l1 ;;
    l2)   verify_l2 ;;
    both) verify_l1; verify_l2 ;;
    *) echo "Unknown --layer: $LAYER (expected l1|l2|both)" >&2; exit 1 ;;
esac

echo ""
echo "============================================================"
echo "DONE: $PASS passed, $FAIL failed, $SKIP skipped"
if ((${#WARNINGS[@]})); then
    echo ""
    echo "Manifest drift warnings:"
    for w in "${WARNINGS[@]}"; do echo "  - $w"; done
fi
echo "============================================================"
[[ "$FAIL" -eq 0 ]]
