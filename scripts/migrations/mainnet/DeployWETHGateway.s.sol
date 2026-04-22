// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {DeployWETHGatewayBase} from "../../deploy/DeployWETHGateway.s.sol";

/// @title DeployWETHGatewayMainnet
/// @author Fluent Labs
///
/// @notice Ethereum mainnet (L1) ↔ Fluent mainnet (L2) stand-alone {WETHGateway} deploy
///         with cross-chain address parity via plain CREATE + aligned nonces.
///
/// @dev Reads `scripts/config/mainnet/release_weth.json` and
///      `deployments/mainnet/{l1,l2}.json`.
///
/// @dev Target nonce rationale:
///      Deployer EOA = `0x482582979C9125abAb5a06F0E196E8F4015bF77A`. Nonce snapshot at
///      plan time: Ethereum mainnet = 17, Fluent mainnet = 19. Target = 19 so the L1 side
///      burns two {Nop} deployments and both chains deploy impl at CREATE with nonce 19
///      / proxy at CREATE with nonce 20. Bump before execution if either chain's nonce
///      has advanced.
contract DeployWETHGatewayMainnet is DeployWETHGatewayBase {
    function _deploymentManifestEnv() internal pure override returns (string memory) {
        return "mainnet";
    }

    function _releaseConfigPath() internal pure override returns (string memory) {
        return "scripts/config/mainnet/release_weth.json";
    }

    /// @dev See contract @dev note. Ethereum=17, Fluent=19 → target 19.
    function _targetNonce() internal pure override returns (uint256) {
        return 19;
    }
}
