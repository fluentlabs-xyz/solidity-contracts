// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ReleaseWethMigration} from "../ReleaseWethMigration.sol";

/// @title ReleaseWethMainnet
/// @author Fluent Labs
///
/// @notice Ethereum **mainnet** (L1) ↔ Fluent **mainnet** (L2) WETH release. Reads
///         `scripts/config/mainnet/release_weth.json` and `deployments/mainnet/{l1,l2}.json`.
///
/// @dev Canonical L1 WETH9 default in `release_weth.json`:
///        `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
///
/// @dev Forge (example — first L1 pass on Ethereum mainnet):
///        forge script scripts/migrations/mainnet/MigrateWETHGateway.s.sol:ReleaseWethMainnet \
///          --sig deployL1 --rpc-url "$MAINNET_RPC" --broadcast -vvvv
contract ReleaseWethMainnet is ReleaseWethMigration {
    function _deploymentManifestEnv() internal pure override returns (string memory) {
        return "mainnet";
    }

    function _releaseConfigPath() internal pure override returns (string memory) {
        return "scripts/config/mainnet/release_weth.json";
    }
}
