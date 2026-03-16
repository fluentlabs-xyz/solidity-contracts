#!/usr/bin/env bash
set -euo pipefail

if ! command -v anvil >/dev/null 2>&1; then
  echo "anvil is not installed or not in PATH"
  exit 1
fi

L1_PORT="${L1_PORT:-9545}"
L2_PORT="${L2_PORT:-9546}"
L1_CHAIN_ID="${L1_CHAIN_ID:-11155111}"
L2_CHAIN_ID="${L2_CHAIN_ID:-13371337}"
MNEMONIC="${MNEMONIC:-test test test test test test test test test test test junk}"

anvil --port "${L1_PORT}" --chain-id "${L1_CHAIN_ID}" --mnemonic "${MNEMONIC}" >/tmp/anvil-l1.log 2>&1 &
L1_PID=$!

anvil --port "${L2_PORT}" --chain-id "${L2_CHAIN_ID}" --mnemonic "${MNEMONIC}" >/tmp/anvil-l2.log 2>&1 &
L2_PID=$!

echo "L1 anvil: http://127.0.0.1:${L1_PORT} (pid=${L1_PID}, chainId=${L1_CHAIN_ID})"
echo "L2 anvil: http://127.0.0.1:${L2_PORT} (pid=${L2_PID}, chainId=${L2_CHAIN_ID})"
echo "Logs: /tmp/anvil-l1.log, /tmp/anvil-l2.log"

cleanup() {
  kill "${L1_PID}" "${L2_PID}" 2>/dev/null || true
}

trap cleanup EXIT INT TERM
wait
