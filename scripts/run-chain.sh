#!/usr/bin/env bash
set -euo pipefail

# Run a Foundry script against a named chain. This is the safe entrypoint for
# deployments and migrations: choose CHAIN once, and this wrapper derives RPC,
# NETWORK, ENV, LAYER, and the manifest path consistently.
#
# Examples:
#   CHAIN=L2_MAINNET ./scripts/run-chain.sh scripts/migrations/MigrateStaking.s.sol:MigrateStaking
#   CHAIN=L2_MAINNET ./scripts/run-chain.sh --broadcast scripts/migrations/MigrateStaking.s.sol:MigrateStaking
#   CHAIN=L2_TESTNET ./scripts/run-chain.sh scripts/deploy/DeployGovernance.s.sol:DeployGovernance -- -vvvv
#
# Supported CHAIN values:
#   L1_MAINNET  -> MAINNET_RPC
#   L2_MAINNET  -> FLUENT_MAINNET_RPC or L2_MAINNET_RPC
#   L1_TESTNET  -> L1_TESTNET_RPC or SEPOLIA_RPC_URL or L1_RPC
#   L2_TESTNET  -> FLUENT_TESTNET_RPC_URL or L2_TESTNET_RPC or L2_RPC
#   LOCAL_L1    -> LOCAL_L1_RPC or L1_RPC or http://localhost:8545
#   LOCAL_L2    -> LOCAL_L2_RPC or L2_RPC or http://localhost:8546

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

CHAIN="${CHAIN:?CHAIN required, e.g. L2_MAINNET}"
DEPLOYER="${DEPLOYER:-}"
BROADCAST="${BROADCAST:-0}"
VERIFY="${VERIFY:-0}"

usage() {
    cat >&2 <<'EOF'
Usage: CHAIN=<name> [DEPLOYER=<wallet>] ./scripts/run-chain.sh [--broadcast] <script.sol[:Contract]> [-- <extra forge args>]

Example:
  CHAIN=L2_MAINNET DEPLOYER=deployer ./scripts/run-chain.sh --broadcast scripts/migrations/MigrateStaking.s.sol:MigrateStaking
EOF
    exit 2
}

[[ $# -ge 1 ]] || usage
if [[ "${1:-}" == "--broadcast" ]]; then
    BROADCAST=1
    shift
fi
SCRIPT_TARGET="${1:-}"
[[ -n "$SCRIPT_TARGET" ]] || usage
shift
if [[ "${1:-}" == "--" ]]; then
    shift
fi

rpc_from() {
    local value=""
    for name in "$@"; do
        value="${!name:-}"
        if [[ -n "$value" ]]; then
            printf '%s' "$value"
            return 0
        fi
    done
    return 1
}

case "$CHAIN" in
    L1_MAINNET)
        ENV_NAME=mainnet; LAYER=l1; NETWORK=mainnet/l1; FORGE_BIN=${L1_FORGE:-forge}
        RPC_URL="$(rpc_from MAINNET_RPC L1_MAINNET_RPC L1_RPC || true)"
        ;;
    L2_MAINNET)
        ENV_NAME=mainnet; LAYER=l2; NETWORK=mainnet/l2; FORGE_BIN=${L2_FORGE:-gblend}
        RPC_URL="$(rpc_from FLUENT_MAINNET_RPC L2_MAINNET_RPC L2_RPC || true)"
        ;;
    L1_TESTNET)
        ENV_NAME=testnet; LAYER=l1; NETWORK=testnet/l1; FORGE_BIN=${L1_FORGE:-forge}
        RPC_URL="$(rpc_from L1_TESTNET_RPC SEPOLIA_RPC_URL RPC_URL_SEPOLIA_ETH L1_RPC || true)"
        ;;
    L2_TESTNET)
        ENV_NAME=testnet; LAYER=l2; NETWORK=testnet/l2; FORGE_BIN=${L2_FORGE:-gblend}
        RPC_URL="$(rpc_from FLUENT_TESTNET_RPC_URL L2_TESTNET_RPC FLUENT_DEV_RPC_URL L2_RPC || true)"
        ;;
    LOCAL_L1)
        ENV_NAME=local; LAYER=l1; NETWORK=local/l1; FORGE_BIN=${L1_FORGE:-forge}
        RPC_URL="$(rpc_from LOCAL_L1_RPC L1_RPC || true)"; RPC_URL="${RPC_URL:-http://localhost:8545}"
        ;;
    LOCAL_L2)
        ENV_NAME=local; LAYER=l2; NETWORK=local/l2; FORGE_BIN=${L2_FORGE:-forge}
        RPC_URL="$(rpc_from LOCAL_L2_RPC L2_RPC || true)"; RPC_URL="${RPC_URL:-http://localhost:8546}"
        ;;
    *)
        echo "Unsupported CHAIN '$CHAIN'" >&2
        exit 2
        ;;
esac

[[ -n "$RPC_URL" ]] || { echo "No RPC env configured for CHAIN=$CHAIN" >&2; exit 2; }
[[ -f "scripts/config/${NETWORK}.json" ]] || { echo "Missing scripts/config/${NETWORK}.json" >&2; exit 2; }

expected_chain_id="$(python3 - <<PY
import json
print(json.load(open('scripts/config/${NETWORK}.json'))['chainId'])
PY
)"
actual_chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$actual_chain_id" != "$expected_chain_id" ]]; then
    echo "Wrong RPC for CHAIN=$CHAIN" >&2
    echo "  config: scripts/config/${NETWORK}.json chainId=$expected_chain_id" >&2
    echo "  rpc:    chainId=$actual_chain_id" >&2
    exit 1
fi

mkdir -p "deployments/${ENV_NAME}"

export CHAIN NETWORK ENV="$ENV_NAME" LAYER
if [[ "$BROADCAST" == "1" || "$BROADCAST" == "true" ]]; then
    export OUTPUT_PATH="${OUTPUT_PATH:-deployments/${NETWORK}.json}"
else
    export OUTPUT_PATH="${OUTPUT_PATH:-}"
fi

cmd=("$FORGE_BIN" script "$SCRIPT_TARGET" --rpc-url "$RPC_URL")
if [[ -n "$DEPLOYER" ]]; then
    cmd+=(--account "$DEPLOYER")
fi
if [[ "$BROADCAST" == "1" || "$BROADCAST" == "true" ]]; then
    [[ -n "$DEPLOYER" ]] || { echo "DEPLOYER required when BROADCAST=1" >&2; exit 2; }
    cmd+=(--broadcast)
    if [[ "$LAYER" == "l2" ]]; then
        cmd+=(--skip-simulation)
    fi
fi
if [[ "$VERIFY" == "1" || "$VERIFY" == "true" ]]; then
    cmd+=(--verify --retries 5 --delay 10)
fi
cmd+=("$@")

echo "CHAIN=$CHAIN NETWORK=$NETWORK ENV=$ENV_NAME LAYER=$LAYER"
echo "RPC chainId=$actual_chain_id manifest=$OUTPUT_PATH"
if [[ "$BROADCAST" == "1" || "$BROADCAST" == "true" ]]; then
    echo "Broadcast: enabled"
else
    echo "Broadcast: disabled (dry-run)"
fi
exec "${cmd[@]}"
