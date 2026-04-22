// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ReleaseWethMigration} from "../ReleaseWethMigration.sol";

/// @title ReleaseWethTestnet
/// @author Fluent Labs
///
/// @notice Sepolia (L1) ↔ Fluent **testnet** (L2) release migration: upgrades
///         {ERC20Gateway} on both chains and {UniversalTokenFactory} on L2, then
///         deploys and wires {WETHGateway} end-to-end. Default `ENV=testnet`
///         (reads `deployments/testnet/{l1,l2}.json`).
///
/// @dev Five-step broadcast. Run each step against the right RPC in order:
///        1. `runL1Upgrade`              — L1 RPC (Sepolia).
///        2. `runL2Upgrade`              — L2 RPC (Fluent testnet).
///        3. `runL1DeployWethGateway`    — L1 RPC. Needs `L1_WETH_ADDRESS`.
///        4. `runL2DeployWethGateway`    — L2 RPC. Needs `WETH_GATEWAY_L1`, `L1_WETH_ADDRESS`.
///        5. `runL1WireWethGateway`      — L1 RPC. Needs `WETH_GATEWAY_L1`, `WETH_GATEWAY_L2`.
///
/// @dev Forge (example — step 1 on Sepolia):
///        forge script scripts/migrations/testnet/MigrateWETHGateway.s.sol:ReleaseWethTestnet \
///          --sig runL1Upgrade --rpc-url "$SEPOLIA_RPC_URL" --broadcast -vvvv
contract ReleaseWethTestnet is ReleaseWethMigration {
    function _defaultEnv() internal pure override returns (string memory) {
        return "testnet";
    }
}
