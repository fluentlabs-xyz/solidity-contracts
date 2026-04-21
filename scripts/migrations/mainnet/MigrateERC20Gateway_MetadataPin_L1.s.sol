// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20GatewayMetadataPinMigration} from "../ERC20GatewayMetadataPinMigration.sol";

/// @notice Ethereum mainnet (L1) — upgrades {ERC20Gateway} for origin-metadata pinning.
/// @dev Broadcast against L1 RPC. Manifest: `deployments/mainnet/l1.json`.
contract MigrateERC20Gateway_MetadataPin_L1 is ERC20GatewayMetadataPinMigration {
    function run() external {
        _run("mainnet", true);
    }
}
