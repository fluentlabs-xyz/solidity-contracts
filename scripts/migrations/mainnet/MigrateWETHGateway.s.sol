// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ReleaseWethMigration} from "../ReleaseWethMigration.sol";

/// @title ReleaseWethMainnet
/// @author Fluent Labs
///
/// @notice Ethereum **mainnet** (L1) ↔ Fluent **mainnet** (L2) release migration.
///         Upgrades {ERC20Gateway} on both chains and {UniversalTokenFactory} on L2,
///         then deploys and wires {WETHGateway} end-to-end. Default `ENV=mainnet`
///         (reads `deployments/mainnet/{l1,l2}.json`).
///
/// @dev Canonical L1 WETH9 (reference only — still set `L1_WETH_ADDRESS` explicitly in env):
///        `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
///
/// @dev Same five-step flow as testnet; see {ReleaseWethMigration} for env vars:
///        `L1_WETH_ADDRESS`, `WETH_GATEWAY_L1`, `WETH_GATEWAY_L2`, optional `WETH_GATEWAY_INITIAL_OWNER`.
///
/// @dev Forge (example — step 1 on Ethereum mainnet):
///        forge script scripts/migrations/mainnet/MigrateWETHGateway.s.sol:ReleaseWethMainnet \
///          --sig runL1Upgrade --rpc-url "$MAINNET_RPC" --broadcast -vvvv
contract ReleaseWethMainnet is ReleaseWethMigration {
    function _defaultEnv() internal pure override returns (string memory) {
        return "mainnet";
    }
}
