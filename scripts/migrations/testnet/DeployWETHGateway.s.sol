// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DeployWETHGatewayBase} from "../../deploy/DeployWETHGateway.s.sol";

/// @title DeployWETHGatewayTestnet
/// @author Fluent Labs
///
/// @notice Sepolia (L1) ↔ Fluent **testnet** (L2) stand-alone {WETHGateway} deploy with
///         cross-chain address parity via plain CREATE + aligned nonces.
///
/// @dev Reads `scripts/config/testnet/release_weth.json` and
///      `deployments/testnet/{l1,l2}.json`.
///
/// @dev Target nonce rationale:
///      Deployer EOA = `0x482582979C9125abAb5a06F0E196E8F4015bF77A` (owner of existing
///      proxies). Nonce snapshot at plan time: Sepolia = 37, Fluent testnet = 41. Target
///      is the higher of the two (41) so the lower-nonce chain burns the gap via {Nop}
///      deployments and both chains end up at nonce 41 when `new WETHGateway()` fires —
///      making the impl (CREATE at nonce 41) and the proxy (CREATE at nonce 42) land at
///      the same address on both chains.
///
///      If either chain's nonce advances past this value before execution, bump
///      `_targetNonce()` to at least the new max before broadcasting.
///
/// @dev Usage:
///        # Preview the CREATE-predicted addresses without touching any chain:
///        forge script scripts/migrations/testnet/DeployWETHGateway.s.sol:DeployWETHGatewayTestnet \
///          --sig "predict()" --rpc-url "$SEPOLIA_RPC_URL" \
///          --sender 0x482582979C9125abAb5a06F0E196E8F4015bF77A
///
///        # Simulate the deploy on each chain from the deployer key:
///        forge script scripts/migrations/testnet/DeployWETHGateway.s.sol:DeployWETHGatewayTestnet \
///          --sig "deployL1()" --rpc-url "$SEPOLIA_RPC_URL" \
///          --sender 0x482582979C9125abAb5a06F0E196E8F4015bF77A
///
///        forge script scripts/migrations/testnet/DeployWETHGateway.s.sol:DeployWETHGatewayTestnet \
///          --sig "deployL2()" --rpc-url "$FLUENT_TESTNET_RPC_URL" \
///          --sender 0x482582979C9125abAb5a06F0E196E8F4015bF77A
///
///        # Wire (run from the gateway_initial_owner / bridge-admin key):
///        forge script scripts/migrations/testnet/DeployWETHGateway.s.sol:DeployWETHGatewayTestnet \
///          --sig "wireL1()" --rpc-url "$SEPOLIA_RPC_URL" \
///          --sender 0x9ec3f0d76A6d3847d86374c791C6E170CAd9518D
contract DeployWETHGatewayTestnet is DeployWETHGatewayBase {
    function _deploymentManifestEnv() internal pure override returns (string memory) {
        return "testnet";
    }

    function _releaseConfigPath() internal pure override returns (string memory) {
        return "scripts/config/testnet/release_weth.json";
    }

    /// @dev See contract @dev note. Sepolia=37, Fluent testnet=41 → target 41.
    function _targetNonce() internal pure override returns (uint256) {
        return 41;
    }
}
