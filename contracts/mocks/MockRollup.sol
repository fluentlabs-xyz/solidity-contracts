// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

import {BatchRecord} from "../interfaces/rollup/IRollupTypes.sol";

/**
 * @title MockRollup
 * @dev Read-path mock of the L1 Rollup for cert-follower smoke tests: serves
 *      the two trust-root getters (`lastFinalizedBatchIndex` + `getBatch`)
 *      with the SAME selectors and return layout as the real contract, with a
 *      permissionless setter pushing checkpoints. Deployed on the devnet L2
 *      itself — the follower's "L1 RPC" points at the devnet RPC, so the real
 *      client read path (selectors, struct decoding, finalized-tag call) is
 *      exercised while only the data source is mocked. Never deploy on a real
 *      network: the setter is intentionally unguarded.
 */
contract MockRollup {
    uint256 private _lastFinalizedBatchIndex;
    mapping(uint256 => BatchRecord) private _batches;

    /// @dev Push a checkpoint: records `toBlockHash` for `batchIndex` and
    ///      marks it the last finalized batch. Permissionless (test-only).
    function setCheckpoint(uint256 batchIndex, bytes32 toBlockHash) external {
        BatchRecord storage batch = _batches[batchIndex];
        batch.toBlockHash = toBlockHash;
        _lastFinalizedBatchIndex = batchIndex;
    }

    /// @dev Selector-identical to `RollupStorageLayout.lastFinalizedBatchIndex`.
    function lastFinalizedBatchIndex() public view returns (uint256) {
        return _lastFinalizedBatchIndex;
    }

    /// @dev Selector-identical to `RollupStorageLayout.getBatch`.
    function getBatch(uint256 batchIndex) public view returns (BatchRecord memory) {
        return _batches[batchIndex];
    }
}
