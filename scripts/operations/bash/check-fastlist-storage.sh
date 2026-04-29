#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# check-fastlist-storage.sh
#
# Inspects FastWithdrawalList proxy configuration and raw storage.
#
# What it prints:
#   1) Proxy admin/implementation slots (ERC-1967)
#   2) Role checks (DEFAULT_ADMIN_ROLE / CONSUMER_ROLE) for candidate addresses
#   3) For each token in TOKENS:
#        - alias / registration / limits / usage via contract getters
#        - raw mapping slots and decoded packed structs from storage
#
# Usage:
#   ./scripts/operations/bash/check-fastlist-storage.sh
#   FASTLIST=0x... L1_RPC=https://... ./scripts/operations/bash/check-fastlist-storage.sh
#   TOKENS="0xTokenA,0xTokenB" ./scripts/operations/bash/check-fastlist-storage.sh
#
# Env:
#   L1_RPC         (required unless MAINNET_RPC is set)
#   FASTLIST       (optional, default deployments/mainnet/l1.json.fast_withdrawal_list_proxy)
#   L1_MANIFEST    (optional, default deployments/mainnet/l1.json)
#   L1_CONFIG      (optional, default scripts/config/mainnet/l1.json)
#   TOKENS         (optional, comma-separated token addresses)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
cd "$PROJECT_ROOT"

[[ -f .env ]] && { set -a; source .env; set +a; }

L1_RPC="${L1_RPC:-${MAINNET_RPC:-}}"
[[ -n "$L1_RPC" ]] || { echo "L1_RPC (or MAINNET_RPC) required"; exit 1; }

L1_MANIFEST="${L1_MANIFEST:-deployments/mainnet/l1.json}"
L1_CONFIG="${L1_CONFIG:-scripts/config/mainnet/l1.json}"
[[ -f "$L1_MANIFEST" ]] || { echo "Manifest not found: $L1_MANIFEST"; exit 1; }
[[ -f "$L1_CONFIG" ]] || { echo "Config not found: $L1_CONFIG"; exit 1; }

FASTLIST="${FASTLIST:-$(jq -r '.fast_withdrawal_list_proxy // .deployment.fast_withdrawal_list_proxy // empty' "$L1_MANIFEST")}"
[[ -n "$FASTLIST" ]] || { echo "FASTLIST missing and not found in manifest"; exit 1; }

# FastWithdrawalList ERC-7201 storage base:
# bytes32 private constant FAST_WITHDRAWAL_LIST_STORAGE_LOCATION = 0x2943...5600;
FASTLIST_STORAGE_BASE="0x2943c2e1bda216c543e8ccb39c2af121ab582536e3918d127406cda20f2b5600"

# ERC-1967 slots
SLOT_IMPL="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
SLOT_ADMIN="0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"

ROLE_DEFAULT_ADMIN="0x0000000000000000000000000000000000000000000000000000000000000000"
ROLE_CONSUMER="$(cast keccak "CONSUMER_ROLE")"

NATIVE_LIMIT_KEY="0x0000012345678901234567890123456789012345"
WETH="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
WBTC="0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599"
USDC="0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
BLEND="0xd8A271974E8EdAE9D7b58e3370dc1669427503F4"
USDNR="0xD48e565561416dE59DA1050ED70b8d75e8eF28f9"

TOKENS="${TOKENS:-$NATIVE_LIMIT_KEY,$WETH,$WBTC,$USDC,$BLEND,$USDNR}"

l1_admin=$(jq -r '.roles.admin // empty' "$L1_CONFIG")
erc20_gateway=$(jq -r '.erc20_gateway // .deployment.erc20_gateway // empty' "$L1_MANIFEST")
native_gateway=$(jq -r '.native_gateway // .deployment.native_gateway // empty' "$L1_MANIFEST")
timelock=$(jq -r '.timelock // .deployment.timelock // empty' "$L1_MANIFEST")

strip_0x() { echo "${1#0x}" | tr '[:upper:]' '[:lower:]'; }
pad64() { printf "%064s" "$(strip_0x "$1")" | tr ' ' '0'; }

add_u256_hex() {
  python3 - "$1" "$2" <<'PY'
import sys
a = int(sys.argv[1], 16)
b = int(sys.argv[2])
print(f"0x{(a+b) & ((1<<256)-1):064x}")
PY
}

map_slot() {
  local key="$1"
  local root="$2"
  local concat_hex
  concat_hex="$(pad64 "$key")$(pad64 "$root")"
  cast keccak "0x$concat_hex"
}

decode_address_word() {
  python3 - "$1" <<'PY'
import sys
w = sys.argv[1].lower().replace("0x","").zfill(64)
print("0x" + w[-40:])
PY
}

decode_limit_word() {
  python3 - "$1" <<'PY'
import sys
w = int(sys.argv[1], 16)
registered = (w & 0xff) != 0
hourly = (w >> 8) & ((1<<96)-1)
daily = (w >> (8 + 96)) & ((1<<96)-1)
print(f"registered={str(registered).lower()} hourlyLimit={hourly} dailyLimit={daily}")
PY
}

decode_usage_word() {
  python3 - "$1" <<'PY'
import sys
w = int(sys.argv[1], 16)
hour_window = w & ((1<<32)-1)
day_window = (w >> 32) & ((1<<32)-1)
hour_used = (w >> 64) & ((1<<96)-1)
day_used = (w >> 160) & ((1<<96)-1)
print(f"hourWindow={hour_window} dayWindow={day_window} hourlyUsed={hour_used} dailyUsed={day_used}")
PY
}

echo "=== FastWithdrawalList storage/config check ==="
echo "rpc           : $L1_RPC"
echo "manifest      : $L1_MANIFEST"
echo "config        : $L1_CONFIG"
echo "fastlist proxy: $FASTLIST"
echo

proxy_impl_word=$(cast storage "$FASTLIST" "$SLOT_IMPL" --rpc-url "$L1_RPC")
proxy_admin_word=$(cast storage "$FASTLIST" "$SLOT_ADMIN" --rpc-url "$L1_RPC")
proxy_impl=$(decode_address_word "$proxy_impl_word")
proxy_admin=$(decode_address_word "$proxy_admin_word")

echo "--- ERC-1967 ---"
echo "implementation slot: $proxy_impl ($proxy_impl_word)"
echo "admin slot         : $proxy_admin ($proxy_admin_word)"
echo

echo "--- Role checks ---"
check_role_addr() {
  local label="$1"
  local addr="$2"
  [[ -n "$addr" && "$addr" != "0x0000000000000000000000000000000000000000" ]] || return 0
  local has_default has_consumer
  has_default=$(cast call "$FASTLIST" "hasRole(bytes32,address)(bool)" "$ROLE_DEFAULT_ADMIN" "$addr" --rpc-url "$L1_RPC")
  has_consumer=$(cast call "$FASTLIST" "hasRole(bytes32,address)(bool)" "$ROLE_CONSUMER" "$addr" --rpc-url "$L1_RPC")
  echo "$label ($addr): DEFAULT_ADMIN_ROLE=$has_default CONSUMER_ROLE=$has_consumer"
}
check_role_addr "config.roles.admin" "$l1_admin"
check_role_addr "manifest.erc20_gateway" "$erc20_gateway"
check_role_addr "manifest.native_gateway" "$native_gateway"
check_role_addr "manifest.timelock" "$timelock"
echo

limits_root="$FASTLIST_STORAGE_BASE"
usage_root="$(add_u256_hex "$FASTLIST_STORAGE_BASE" 1)"
aliases_root="$(add_u256_hex "$FASTLIST_STORAGE_BASE" 2)"

echo "--- Tokens ---"
IFS=',' read -r -a token_arr <<< "$TOKENS"
for raw in "${token_arr[@]}"; do
  token="$(echo "$raw" | xargs)"
  [[ -n "$token" ]] || continue

  echo
  echo "token: $token"

  alias_of=$(cast call "$FASTLIST" "getAlias(address)(address)" "$token" --rpc-url "$L1_RPC")
  is_reg=$(cast call "$FASTLIST" "isRegistered(address)(bool)" "$token" --rpc-url "$L1_RPC")
  resolved="$token"
  if [[ "$alias_of" != "0x0000000000000000000000000000000000000000" ]]; then
    resolved="$alias_of"
  fi

  echo "  getter.alias      : $alias_of"
  echo "  getter.registered : $is_reg (resolved key: $resolved)"

  if [[ "$is_reg" == "true" ]]; then
    limit_out=$(cast call "$FASTLIST" "getLimit(address)(uint256,uint256)" "$token" --rpc-url "$L1_RPC")
    usage_out=$(cast call "$FASTLIST" "getUsage(address)(uint256,uint256,uint256,uint256)" "$token" --rpc-url "$L1_RPC")
    echo "  getter.limit      : $limit_out"
    echo "  getter.usage      : $usage_out"
  fi

  slot_alias=$(map_slot "$token" "$aliases_root")
  slot_limit_resolved=$(map_slot "$resolved" "$limits_root")
  slot_usage_resolved=$(map_slot "$resolved" "$usage_root")

  raw_alias=$(cast storage "$FASTLIST" "$slot_alias" --rpc-url "$L1_RPC")
  raw_limit=$(cast storage "$FASTLIST" "$slot_limit_resolved" --rpc-url "$L1_RPC")
  raw_usage=$(cast storage "$FASTLIST" "$slot_usage_resolved" --rpc-url "$L1_RPC")

  echo "  storage.slot.alias[$token]         : $slot_alias"
  echo "  storage.raw.alias                  : $raw_alias (decoded $(decode_address_word "$raw_alias"))"
  echo "  storage.slot.limit[$resolved]      : $slot_limit_resolved"
  echo "  storage.raw.limit                  : $raw_limit"
  echo "  storage.decoded.limit              : $(decode_limit_word "$raw_limit")"
  echo "  storage.slot.usage[$resolved]      : $slot_usage_resolved"
  echo "  storage.raw.usage                  : $raw_usage"
  echo "  storage.decoded.usage              : $(decode_usage_word "$raw_usage")"
done

echo
echo "=== done ==="
