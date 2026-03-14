// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RollupBase} from "./Base.t.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorageLayout.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";

contract AcceptBatchTest is RollupBase {
    /// @dev Full lifecycle: Accepted → DAReady → PreConfirmed → Finalized
    function test_fullBatchLifecycle() public {
        // ── 1. Accept ──
        RollupStorageLayout.BlockCommitment[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 expectedRoot = _computeBatchRoot(batch);

        _expectBatchAccepted(1, expectedRoot);
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);

        _assertBatchRecord(batchIndex, RollupStorageLayout.BatchStatus.Accepted, 0, expectedRoot);
        assertEq(rollup.nextBatchIndex(), batchIndex + 1);
        _assertRollupHealthy();

        // ── 2. Submit DA ──
        _expectBatchDAReady(batchIndex);
        _submitDAProof(batchIndex, 0);

        _assertBatchRecord(batchIndex, RollupStorageLayout.BatchStatus.DAReady, 0, expectedRoot);

        // ── 3. PreConfirm ──
        _expectBatchPreConfirmed(batchIndex);
        _preconfirmBatch(batchIndex);

        _assertBatchRecord(batchIndex, RollupStorageLayout.BatchStatus.PreConfirmed, 0, expectedRoot);

        // ── 4. Finalize ──
        vm.roll(block.number + APPROVE_BLOCK_COUNT + 1);

        _expectBatchFinalized(batchIndex);
        bool finalized = _finalizeBatch(batchIndex);

        assertTrue(finalized);
        _assertBatchRecord(batchIndex, RollupStorageLayout.BatchStatus.Finalized, 0, expectedRoot);
        _assertLastFinalizedBatchIndex(batchIndex);
    }

    /// @dev Accept sets correct batch record fields
    function test_acceptSetsCorrectBatchRecord() public {
        RollupStorageLayout.BlockCommitment[] memory batch = _makeBatch(GENESIS_HASH);
        bytes32 expectedRoot = _computeBatchRoot(batch);

        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 3);

        _assertBatchRecord(batchIndex, RollupStorageLayout.BatchStatus.Accepted, 3, expectedRoot);
        assertEq(rollup.acceptedBlock(batchIndex), block.number);
    }

    /// @dev Multiple batches can be accepted sequentially
    function test_multipleBatchesSequential() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        assertEq(batch1, 1);

        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash, 0);
        assertEq(batch2, 2);

        _assertBatchRecord(batch1, RollupStorageLayout.BatchStatus.Accepted, 0, rollup.acceptedBatchRoot(batch1));
        _assertBatchRecord(batch2, RollupStorageLayout.BatchStatus.Accepted, 0, rollup.acceptedBatchRoot(batch2));
    }

    /// @dev Wrong parent hash reverts
    function test_revert_wrongParentHash() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        bytes32 wrongParent = keccak256("wrong");
        RollupStorageLayout.BlockCommitment[] memory batch = _makeBatch(wrongParent);

        bytes32 expectedParent = rollup.lastBlockHashInBatch(batch1);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.WrongPreviousBlockHash.selector, expectedParent, wrongParent));
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 0);
    }

    /// @dev Non-sequencer cannot accept batch
    function test_revert_nonSequencer() public {
        RollupStorageLayout.BlockCommitment[] memory batch = _makeBatch(GENESIS_HASH);

        vm.prank(user);
        vm.expectRevert();
        rollup.acceptNextBatch(batch, 0);
    }

    /// @dev submitDAProof reverts on wrong status
    function test_revert_submitDAProofWhenNotAccepted() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        _submitDAProof(batchIndex, 0);

        // batch is now DAReady (2) — calling again should fail
        vm.expectRevert(abi.encodeWithSelector(
            IRollupErrors.InvalidBatchStatus.selector, batchIndex, uint8(RollupStorageLayout.BatchStatus.DAReady)
        ));
        vm.prank(sequencer);
        rollup.submitDAProof(batchIndex, 0);
    }

    /// @dev commitPreConfirmation reverts when batch is not DAReady
    function test_revert_preconfirmWhenNotDAReady() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);

        // batch is Accepted (1), not DAReady
        vm.expectRevert(abi.encodeWithSelector(
            IRollupErrors.InvalidBatchStatus.selector, batchIndex, uint8(RollupStorageLayout.BatchStatus.Accepted)
        ));
        vm.prank(preconfirmer);
        rollup.commitPreConfirmation(address(nitroVerifier), batchIndex, DUMMY_SIGNATURE);
    }

    /// @dev ensureBatchFinalized returns false when not PreConfirmed
    function test_finalizeBatchReturnsFalseWhenNotReady() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);

        bool result = _finalizeBatch(batchIndex);
        assertFalse(result);
    }

    /// @dev ensureBatchFinalized returns false when not enough blocks passed
    function test_finalizeBatchReturnsFalseWhenTooEarly() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        _submitDAProof(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        // don't advance blocks
        bool result = _finalizeBatch(batchIndex);
        assertFalse(result);
    }

    /// @dev Accepting next batch auto-finalizes the previous one if eligible
    function test_acceptNextBatchAutoFinalizes() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitDAProof(batch1, 0);
        _preconfirmBatch(batch1);

        vm.roll(block.number + APPROVE_BLOCK_COUNT + 1);

        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash, 0);

        // batch1 should be auto-finalized by acceptNextBatch
        _assertBatchRecord(batch1, RollupStorageLayout.BatchStatus.Finalized, 0, rollup.acceptedBatchRoot(batch1));
        _assertBatchRecord(batch2, RollupStorageLayout.BatchStatus.Accepted, 0, rollup.acceptedBatchRoot(batch2));
    }
}
