#!/usr/bin/env bash
# Fix L1 PaymentGateway otherSideChainId to match L2's actual chain id (e.g. Fluent testnet 20994).
# Uses cast to call setOtherSideUniversal(L2_GATEWAY, L2_PEGGED_IMPL, L2_FACTORY, L2_CHAIN_ID).
#
# Required: .env with PRIVATE_KEY, SEPOLIA_RPC_URL (or set L1_RPC_URL).
# Optional: L2_RPC_URL (to fetch chain id via cast chain-id); otherwise uses 20994.
#
# Usage:
#   ./scripts/deploy/bash/fix-l1-gateway-chainid.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$PROJECT_ROOT"

command -v cast >/dev/null || { echo "cast is required"; exit 1; }
if command -v python3 >/dev/null; then PYTHON=python3; elif command -v python >/dev/null; then PYTHON=python; else echo "python3 or python required"; exit 1; fi

if [ -f .env ]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

PRIVATE_KEY="${PRIVATE_KEY:-}"
[ -n "$PRIVATE_KEY" ] || { echo "PRIVATE_KEY is required (set in .env or environment)"; exit 1; }

L1_RPC_URL="${L1_RPC_URL:-${SEPOLIA_RPC_URL:-}}"
[ -n "$L1_RPC_URL" ] || { echo "L1_RPC_URL or SEPOLIA_RPC_URL is required"; exit 1; }

DEPLOYMENT_JSON="$PROJECT_ROOT/scripts/deploy/deployment_json.py"
read_json_key() { "$PYTHON" "$DEPLOYMENT_JSON" get "$1" "$2"; }

SEPOLIA_JSON="${SEPOLIA_JSON:-deployments/sepolia.json}"
FLUENT_JSON="${FLUENT_JSON:-deployments/fluent_testnet.json}"
[ -f "$SEPOLIA_JSON" ] || { echo "Not found: $SEPOLIA_JSON"; exit 1; }
[ -f "$FLUENT_JSON" ] || { echo "Not found: $FLUENT_JSON"; exit 1; }

L1_GATEWAY="$(read_json_key "$SEPOLIA_JSON" gateway)"
L2_GATEWAY="$(read_json_key "$FLUENT_JSON" gateway)"
L2_FACTORY="$(read_json_key "$FLUENT_JSON" factory)"
L2_PEGGED_IMPL="0x0000000000000000000000000000000000520008"

[ -n "$L1_GATEWAY" ] || { echo "Could not read gateway from $SEPOLIA_JSON"; exit 1; }
[ -n "$L2_GATEWAY" ] || { echo "Could not read gateway from $FLUENT_JSON"; exit 1; }
[ -n "$L2_FACTORY" ] || { echo "Could not read factory from $FLUENT_JSON"; exit 1; }

# Prefer L2 chain id from RPC; fallback to 20994 (Fluent testnet)
L2_RPC_URL="${L2_RPC_URL:-${FLUENT_TESTNET_RPC_URL:-}}"
if [ -n "$L2_RPC_URL" ]; then
  L2_CHAIN_ID="$(cast chain-id --rpc-url "$L2_RPC_URL" 2>/dev/null)" || true
fi
L2_CHAIN_ID="${L2_CHAIN_ID:-20994}"

echo "L1 Gateway (Sepolia): $L1_GATEWAY"
echo "L2 Gateway:           $L2_GATEWAY"
echo "L2 Factory:            $L2_FACTORY"
echo "L2 Chain ID:           $L2_CHAIN_ID"
echo "Calling setOtherSideUniversal on L1 gateway..."
cast send "$L1_GATEWAY" \
  "setOtherSideUniversal(address,address,address,uint256)" \
  "$L2_GATEWAY" \
  "$L2_PEGGED_IMPL" \
  "$L2_FACTORY" \
  "$L2_CHAIN_ID" \
  --rpc-url "$L1_RPC_URL" \
  --private-key "$PRIVATE_KEY"

echo "Done. L1 gateway otherSideChainId is now $L2_CHAIN_ID."
