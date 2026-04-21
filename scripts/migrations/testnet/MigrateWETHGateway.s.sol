// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {WETHGatewayMigration} from "../WETHGatewayMigration.sol";

/// @title MigrateWETHGateway (testnet)
/// @notice Default `ENV=testnet` when unset. See `../WETHGatewayMigration.sol`.
contract MigrateWETHGateway is WETHGatewayMigration {
    function _defaultEnv() internal pure override returns (string memory) {
        return "testnet";
    }

    /// @dev Backwards-compatible entrypoint names from earlier migration docs.
    function runSepoliaDeployL1WethGateway() external {
        runL1DeployWethGateway();
    }

    function runFluentDeployL2WethGateway() external {
        runL2DeployWethGateway();
    }

    function runSepoliaWireL1WethGateway() external {
        runL1WireWethGateway();
    }
}
