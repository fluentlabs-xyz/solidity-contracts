// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {IRollupRead, IRollupEmergency} from "../../contracts/interfaces/rollup/IRollup.sol";

/// @title MigrateRollup_ChunkedBatchRootResolution
/// @author Fluent Labs
///
/// @notice Upgrade an already-deployed Rollup UUPS proxy to the chunked
///         batch-root resolution implementation.
///
/// @dev Forge auto-deploys the {IncrementalMerkleTree} library when it sees
///      `new Rollup()` and links its address into the impl bytecode. The
///      library's deployed address is recorded in
///      `broadcast/<chainId>/run-latest.json` — read it from there if needed.
///
///      `UnsafeUpgrades` skips OZ's FFI validator (storage layout check +
///      external-library-linking guard). Storage layout safety was hand-verified
///      in this PR (append-only at end of `RollupStorage` + `__gap` shrink).
///      Same pattern as `scripts/migrations/MigrateL2_BridgeAndGateways.s.sol`.
///
/// @dev Operator note: **stop the sequencer backend before running**. The
///      pre/post sanity check below reads `nextBatchIndex` and
///      `lastFinalizedBatchIndex` and requires them to match across the upgrade;
///      a sequencer writing batches mid-script will cause the script to revert.
///
/// @dev Env: `ROLLUP_PROXY` — proxy address to upgrade.
contract MigrateRollup_ChunkedBatchRootResolution is Script {
    function run() external {
        address proxy = vm.envAddress("ROLLUP_PROXY");
        require(proxy.code.length > 0, "ROLLUP_PROXY has no code");

        uint256 nextBatchIdxBefore = IRollupRead(proxy).nextBatchIndex();
        uint256 lastFinalizedBefore = IRollupRead(proxy).lastFinalizedBatchIndex();
        bool corruptedBefore = IRollupEmergency(proxy).isRollupCorrupted();

        vm.startBroadcast();
        Rollup newImpl = new Rollup(); // Forge auto-deploys IncrementalMerkleTree
        UnsafeUpgrades.upgradeProxy(proxy, address(newImpl), "");
        vm.stopBroadcast();

        require(IRollupRead(proxy).nextBatchIndex() == nextBatchIdxBefore, "nextBatchIndex changed");
        require(IRollupRead(proxy).lastFinalizedBatchIndex() == lastFinalizedBefore, "lastFinalizedBatchIndex changed");
        require(IRollupEmergency(proxy).isRollupCorrupted() == corruptedBefore, "isRollupCorrupted changed");

        console2.log("=== Migration complete ===");
        console2.log("Proxy:    ", proxy);
        console2.log("New impl: ", address(newImpl));
        console2.log("Library address: see broadcast/<chainId>/run-latest.json");
    }
}
