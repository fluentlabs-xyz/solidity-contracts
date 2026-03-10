#!/usr/bin/env bash
# Send mock token from L1 (Sepolia) to L2 (Fluent Testnet). Relayer must be running to deliver the message.
# 1. Approve L1 gateway to spend token
# 2. Call sendTokens(token, recipient, amount) on L1 gateway
#
# Required: PRIVATE_KEY, RECIPIENT_ADDRESS (L2 address), AMOUNT (wei, e.g. 1000000000000000000 for 1 token)
# Optional: L1_RPC_URL, TOKEN_ADDRESS (default: mock token from L1 deployment config)
# Config: deployments/sepolia-l1-stack.json (flat) or deployments/sepolia.json (uses deployment.gateway, deployment.mock_token)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$PROJECT_ROOT"

command -v cast >/dev/null || { echo "cast required"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }

PRIVATE_KEY="${PRIVATE_KEY:-}"
RECIPIENT_ADDRESS="${RECIPIENT_ADDRESS:-}"
AMOUNT="${AMOUNT:-}"

[ -n "$PRIVATE_KEY" ] || { echo "PRIVATE_KEY required"; exit 1; }
[ -n "$RECIPIENT_ADDRESS" ] || { echo "RECIPIENT_ADDRESS required (L2 recipient)"; exit 1; }
[ -n "$AMOUNT" ] || { echo "AMOUNT required (wei, e.g. 1000000000000000000 for 1 token)"; exit 1; }

L1_RPC_URL="${L1_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
if [ -f deployments/sepolia-l1-stack.json ]; then
  L1_CONFIG="deployments/sepolia-l1-stack.json"
  GATEWAY_KEY="gateway"
  MOCK_TOKEN_KEY="mock_token"
elif [ -f deployments/sepolia.json ]; then
  L1_CONFIG="deployments/sepolia.json"
  GATEWAY_KEY="deployment.gateway"
  MOCK_TOKEN_KEY="deployment.mock_token"
else
  echo "No L1 config found (deployments/sepolia-l1-stack.json or deployments/sepolia.json)"; exit 1
fi

# Key can be "gateway" or "deployment.gateway" (dotted path)
read_json_key() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    d = json.load(f)
for k in sys.argv[2].split("."):
    d = (d or {}).get(k, "") or {}
out = d if isinstance(d, str) else ""
print(out)
PY
}

L1_GATEWAY="$(read_json_key "$L1_CONFIG" "$GATEWAY_KEY")"
TOKEN_ADDRESS="${TOKEN_ADDRESS:-$(read_json_key "$L1_CONFIG" "$MOCK_TOKEN_KEY")}"
[ -n "$TOKEN_ADDRESS" ] || { echo "TOKEN_ADDRESS not set and no mock_token in L1 stack"; exit 1; }

echo "Token:    $TOKEN_ADDRESS"
echo "Gateway:  $L1_GATEWAY"
echo "Recipient (L2): $RECIPIENT_ADDRESS"
echo "Amount:   $AMOUNT wei"
echo ""

echo "=== Step 1: Approve gateway to spend token ==="
cast send "$TOKEN_ADDRESS" "approve(address,uint256)" "$L1_GATEWAY" "$AMOUNT" \
  --rpc-url "$L1_RPC_URL" --private-key "$PRIVATE_KEY"

echo ""
echo "=== Step 2: Send tokens L1 -> L2 (relayer will deliver to L2) ==="
cast send "$L1_GATEWAY" "sendTokens(address,address,uint256)" "$TOKEN_ADDRESS" "$RECIPIENT_ADDRESS" "$AMOUNT" \
  --rpc-url "$L1_RPC_URL" --private-key "$PRIVATE_KEY"

echo ""
echo "Transfer initiated. Relayer will relay the message to L2; recipient will receive pegged tokens on L2."
