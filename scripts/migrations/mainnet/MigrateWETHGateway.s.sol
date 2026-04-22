// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {WETHGatewayMigration} from "../WETHGatewayMigration.sol";

/// @title MigrateWETHGatewayMainnet
/// @author Fluent Labs
///
/// @notice Ethereum **mainnet** L1 ↔ Fluent **mainnet** L2: deploy and wire {WETHGateway}.
///         Default `ENV=mainnet` when unset (reads `deployments/mainnet/l1.json` and `l2.json`).
///
/// @dev Canonical L1 WETH9 (reference only — still set `L1_WETH_ADDRESS` explicitly in env):
///        `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
///
/// @dev Same three-step broadcast as testnet; see {WETHGatewayMigration} for env vars:
///        `L1_WETH_ADDRESS`, `WETH_GATEWAY_L1`, `WETH_GATEWAY_L2`, optional `WETH_GATEWAY_INITIAL_OWNER`.
///
/// @dev Forge (example — step A on Ethereum mainnet):
///        forge script scripts/migrations/mainnet/MigrateWETHGateway.s.sol:MigrateWETHGatewayMainnet \
///          --sig runL1DeployWethGateway \
///          --rpc-url "$MAINNET_RPC" --broadcast -vvvv
///
///      Set `export L1_WETH_ADDRESS=0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` before step A on mainnet.
contract MigrateWETHGatewayMainnet is WETHGatewayMigration {
    function _defaultEnv() internal pure override returns (string memory) {
        return "mainnet";
    }
}
