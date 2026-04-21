// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20GatewayMetadataPinMigration} from "../ERC20GatewayMetadataPinMigration.sol";

/// @notice Fluent testnet (L2) — upgrades {ERC20Gateway} for origin-metadata pinning.
/// @dev Broadcast against L2 RPC. Manifest: `deployments/testnet/l2.json`.
contract MigrateERC20Gateway_MetadataPin_L2 is ERC20GatewayMetadataPinMigration {
    function run() external {
        _run("testnet", false);
    }
}
