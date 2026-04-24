#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# send-native-l2-to-l1.sh
#
# Fires N native withdrawals from Fluent L2 → L1 via L2 NativeGateway.
# Each call is a single `cast send` of:
#     NativeGateway.sendNativeTokens{value: AMOUNT_WEI + fee}(RECIPIENT)
# where `fee` is read from L2 FluentBridge.getSentMessageFee() once at start.
#
# Usage:
#   ./scripts/operations/bash/send-native-l2-to-l1.sh                 # real run
#   ./scripts/operations/bash/send-native-l2-to-l1.sh --simulate      # no broadcast
#   COUNT=30 AMOUNT_WEI=10000000000000 RECIPIENT=0x... ./...sh
#
# Required env (one of each pair):
#   L2_RPC | FLUENT_TESTNET_RPC_URL | FLUENT_DEV_RPC_URL
#   DEPLOYER (keystore alias)       OR   PRIVATE_KEY
# Optional env:
#   ENV          deployments/<ENV>/l2.json source (default: testnet)
#   COUNT        number of transfers (default: 30)
#   AMOUNT_WEI   amount to bridge per tx (default: 10000000000000 = 0.00001 ETH)
#   RECIPIENT    destination on L1 (default: derived from sender)
#   DELAY        seconds between sends (default: 0)
#   FEE_BUFFER   extra wei added on top of quoted fee (default: 0)
#   L2_MANIFEST  override manifest path
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$PROJECT_ROOT"

[[ -f .env ]] && { set -a; source .env; set +a; }

SIMULATE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --simulate|--dry-run) SIMULATE=true; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---- resolve RPC ------------------------------------------------------------
L2_RPC="${L2_RPC:-${FLUENT_TESTNET_RPC_URL:-${FLUENT_DEV_RPC_URL:-}}}"
[[ -n "$L2_RPC" ]] || { echo "L2_RPC (or FLUENT_TESTNET_RPC_URL / FLUENT_DEV_RPC_URL) required" >&2; exit 1; }

# ---- resolve signer ---------------------------------------------------------
SIGNER_FLAGS=()
SENDER=""
if [[ -n "${DEPLOYER:-}" ]]; then
    SIGNER_FLAGS=(--account "$DEPLOYER")
    SENDER=$(cast wallet address --account "$DEPLOYER")
elif [[ -n "${PRIVATE_KEY:-}" ]]; then
    SIGNER_FLAGS=(--private-key "$PRIVATE_KEY")
    SENDER=$(cast wallet address --private-key "$PRIVATE_KEY")
else
    if $SIMULATE; then
        echo "NOTE: no signer (set DEPLOYER or PRIVATE_KEY); simulation will pick a zero-funded dummy sender"
        SENDER="0x0000000000000000000000000000000000000000"
    else
        echo "DEPLOYER or PRIVATE_KEY required for broadcast" >&2; exit 1
    fi
fi

ENV="${ENV:-testnet}"
COUNT="${COUNT:-30}"
AMOUNT_WEI="${AMOUNT_WEI:-10000000000000}"   # 0.00001 ETH
DELAY="${DELAY:-0}"
FEE_BUFFER="${FEE_BUFFER:-0}"
L2_MANIFEST="${L2_MANIFEST:-deployments/${ENV}/l2.json}"

[[ -f "$L2_MANIFEST" ]] || { echo "manifest not found: $L2_MANIFEST" >&2; exit 1; }

l2_bridge=$(jq -r '.bridge // .deployment.bridge // empty'                    "$L2_MANIFEST")
l2_native_gw=$(jq -r '.native_gateway // .deployment.native_gateway // empty' "$L2_MANIFEST")
l2_chain_id=$(jq -r '.chainId // .deployment.chainId // empty'                "$L2_MANIFEST")

[[ -n "$l2_bridge" && -n "$l2_native_gw" ]] || {
    echo "manifest $L2_MANIFEST missing 'bridge' or 'native_gateway'" >&2; exit 1
}

RECIPIENT="${RECIPIENT:-$SENDER}"

# ---- quote fee (real call to production L2) ---------------------------------
FEE=$(cast call "$l2_bridge" 'getSentMessageFee()(uint256)' --rpc-url "$L2_RPC" | awk '{print $1}')
[[ "$FEE" =~ ^[0-9]+$ ]] || { echo "failed to parse fee: $FEE" >&2; exit 1; }

# Integer math via python3 to keep arbitrary-precision safety.
big_add() { python3 -c "import sys; print(sum(int(a) for a in sys.argv[1:]))" "$@"; }
big_mul() { python3 -c "import sys; print(int(sys.argv[1]) * int(sys.argv[2]))" "$@"; }
eth_str() { python3 -c "import sys; print(f'{int(sys.argv[1])/1e18:.9f}')" "$@"; }

VALUE=$(big_add "$AMOUNT_WEI" "$FEE" "$FEE_BUFFER")
TOTAL=$(big_mul "$VALUE" "$COUNT")

cat <<EOF
=== Fluent L2 → L1 native withdrawal batch ===
  mode          : $([[ $SIMULATE == true ]] && echo SIMULATE || echo BROADCAST)
  env           : $ENV
  L2 RPC        : $L2_RPC
  L2 chainId    : ${l2_chain_id:-?}
  L2 bridge     : $l2_bridge
  L2 nativeGW   : $l2_native_gw
  sender        : $SENDER
  recipient     : $RECIPIENT
  amount/tx     : $AMOUNT_WEI wei ($(eth_str "$AMOUNT_WEI") ETH)
  quoted fee    : $FEE wei ($(eth_str "$FEE") ETH)
  fee buffer    : $FEE_BUFFER wei
  value/tx      : $VALUE wei ($(eth_str "$VALUE") ETH)
  count         : $COUNT
  total value   : $TOTAL wei ($(eth_str "$TOTAL") ETH) (excludes L2 gas)
  delay         : ${DELAY}s
==============================================
EOF

# ---- sender balance check ---------------------------------------------------
BAL=$(cast balance "$SENDER" --rpc-url "$L2_RPC" 2>/dev/null || echo 0)
if [[ "$BAL" =~ ^[0-9]+$ ]]; then
    echo "sender L2 balance: $BAL wei ($(eth_str "$BAL") ETH)"
    SHORTFALL=$(python3 -c "import sys; v=int(sys.argv[1])-int(sys.argv[2]); print(v if v>0 else 0)" "$TOTAL" "$BAL")
    if [[ "$SHORTFALL" != "0" ]]; then
        echo "WARN: sender is short by $SHORTFALL wei for $COUNT txs (gas extra)"
    fi
fi

# ---- simulate one tx to catch reverts early --------------------------------
echo
echo "== simulating 1 call (eth_call) =="
if err=$(cast call "$l2_native_gw" 'sendNativeTokens(address)' "$RECIPIENT" \
            --value "${VALUE}wei" --from "$SENDER" --rpc-url "$L2_RPC" 2>&1); then
    echo "simulate: OK (no revert)"
else
    echo "simulate: REVERT"
    echo "$err" | sed 's/^/    /'
    echo
    echo "Aborting before any broadcast."
    exit 1
fi

echo "== estimating gas =="
GAS=$(cast estimate "$l2_native_gw" 'sendNativeTokens(address)' "$RECIPIENT" \
        --value "${VALUE}wei" --from "$SENDER" --rpc-url "$L2_RPC" 2>/dev/null || echo "?")
echo "gas/tx: $GAS"

if $SIMULATE; then
    echo
    echo "=== simulate complete: plan OK, no broadcast ==="
    exit 0
fi

# ---- broadcast loop ---------------------------------------------------------
OK=0; FAIL=0
TX_LOG="${TX_LOG:-out/native-withdraw-$(date +%Y%m%d-%H%M%S).log}"
mkdir -p "$(dirname "$TX_LOG")"
: > "$TX_LOG"

for i in $(seq 1 "$COUNT"); do
    printf '[%02d/%02d] ' "$i" "$COUNT"
    if out=$(cast send "$l2_native_gw" \
                'sendNativeTokens(address)' "$RECIPIENT" \
                --value "${VALUE}wei" \
                --rpc-url "$L2_RPC" \
                "${SIGNER_FLAGS[@]}" 2>&1); then
        tx=$(printf '%s' "$out" | awk '/^transactionHash[[:space:]]/ {print $2; exit}')
        [[ -n "$tx" ]] || tx="?"
        echo "OK tx=$tx"
        printf '%d\t%s\tOK\t%s\n' "$i" "$tx" "$RECIPIENT" >> "$TX_LOG"
        OK=$((OK + 1))
    else
        echo "FAIL"
        printf '%s\n' "$out" | sed 's/^/    /'
        printf '%d\t-\tFAIL\t%s\n' "$i" "$RECIPIENT" >> "$TX_LOG"
        FAIL=$((FAIL + 1))
    fi
    if (( i < COUNT )) && [[ "$DELAY" != "0" ]]; then
        sleep "$DELAY"
    fi
done

echo
echo "=== Done: $OK ok, $FAIL failed ==="
echo "log: $TX_LOG"
[[ "$FAIL" -eq 0 ]]
