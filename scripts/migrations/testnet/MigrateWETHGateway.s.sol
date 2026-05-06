// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ReleaseWethMigration} from "../ReleaseWethMigration.sol";

/// @title ReleaseWethTestnet
/// @author Fluent Labs
///
/// @notice Sepolia (L1) ↔ Fluent **testnet** (L2) WETH release. Reads
///         `scripts/config/testnet/release_weth.json` and `deployments/testnet/{l1,l2}.json`.
///
/// @dev Run on the correct RPC with `--broadcast`:
///        1. `deployL1` — L1 (Sepolia): first pass upgrades + L1 WETH gateway; after updating JSON,
///           second pass wires L2 peer.
///        2. `deployL2` — L2 (Fluent testnet): upgrades + Universal WETH + L2 gateway + registration.
///
/// @dev Example:
///        forge script scripts/migrations/testnet/MigrateWETHGateway.s.sol:ReleaseWethTestnet \
///          --sig deployL1 --rpc-url "$SEPOLIA_RPC_URL" --broadcast -vvvv
contract ReleaseWethTestnet is ReleaseWethMigration {
    function _deploymentManifestEnv() internal pure override returns (string memory) {
        return "testnet";
    }

    function _releaseConfigPath() internal pure override returns (string memory) {
        return "scripts/config/testnet/release_weth.json";
    }
}
