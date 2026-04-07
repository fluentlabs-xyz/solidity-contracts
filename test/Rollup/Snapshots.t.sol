// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {RollupAssertions} from "./Base.t.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {L2BlockHeader, BatchRecord, BatchStatus} from "../../contracts/interfaces/IRollupTypes.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

/// @dev Verifies that batch-lifecycle timing windows are frozen at {Rollup-acceptNextBatch}
///      and that admin updates to those windows do NOT retroactively affect in-flight batches.
contract RollupSnapshotTest is RollupAssertions {
    function test_acceptNextBatch_snapshotsCurrentBatchWindows() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        BatchRecord memory batch = rollup.getBatch(batchIndex);

        assertEq(batch.submitBlobsWindowSnapshot, SUBMIT_BLOBS_WINDOW, "submitBlobs window snapshot mismatch");
        assertEq(batch.challengeWindowSnapshot, CHALLENGE_WINDOW, "challenge window snapshot mismatch");
        assertEq(batch.finalizationDelaySnapshot, FINALIZATION_DELAY, "finalization delay snapshot mismatch");
    }

    // ============ submitBlobsWindow ============

    function test_submitBlobs_snapshotIgnoresLaterShorterWindow() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;

        // Shrink the global window AFTER acceptance. The old batch must keep its original snapshot.
        vm.prank(admin);
        rollup.setSubmitBlobsWindow(5);

        vm.roll(acceptedAt + 6);
        assertFalse(rollup.isRollupCorrupted(), "old batch should keep original submitBlobs snapshot");

        _submitBlobs(batchIndex, 0);
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Accepted), "blob submission should still succeed");
    }

    function test_submitBlobs_snapshotUsesUpdatedValueForNewBatch() public {
        // Shrink the global window BEFORE acceptance — new batch should pick up the new value.
        vm.prank(admin);
        rollup.setSubmitBlobsWindow(5);

        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        BatchRecord memory batch = rollup.getBatch(batchIndex);
        assertEq(batch.submitBlobsWindowSnapshot, 5, "new batch should snapshot the updated submitBlobs window");

        vm.roll(uint256(batch.acceptedAtBlock) + 6);
        assertTrue(rollup.isRollupCorrupted(), "new batch should use the shortened submitBlobs snapshot");
    }

    function test_submitBlobs_snapshotBoundaryAllowsAtExactDeadline() public {
        vm.prank(admin);
        rollup.setSubmitBlobsWindow(5);

        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;

        // Strict `>` in _rollupCorrupted — exact boundary block is still healthy.
        vm.roll(acceptedAt + 5);
        _submitBlobs(batchIndex, 0);

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Accepted), "exact submitBlobs boundary should succeed");
    }

    // ============ challengeWindow ============

    function test_challengeWindow_snapshotIgnoresLaterShorterWindow() public {
        L2BlockHeader[] memory headers = _makeBatch(GENESIS_HASH);
        uint256 batchIndex = rollup.nextBatchIndex();

        vm.prank(sequencer);
        rollup.acceptNextBatch(headers, 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;

        // Shrink the global window AFTER acceptance. The challenge deadline for this batch
        // must still derive from the snapshotted window, not the new global value.
        vm.prank(admin);
        rollup.setChallengeWindow(10);

        vm.roll(acceptedAt + 20);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        assertEq(
            rollup.getChallenge(_computeCommitment(headers[0])).deadline,
            acceptedAt + CHALLENGE_WINDOW,
            "challenge deadline should use the snapshotted window"
        );
    }

    function test_challengeWindow_snapshotBoundaryRevertsAtExactDeadline() public {
        vm.prank(admin);
        rollup.setChallengeWindow(10);

        L2BlockHeader[] memory headers = _makeBatch(GENESIS_HASH);
        uint256 batchIndex = rollup.nextBatchIndex();

        vm.prank(sequencer);
        rollup.acceptNextBatch(headers, 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;
        vm.roll(acceptedAt + 10);

        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ChallengeTooLate.selector, batchIndex));
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], _buildMerkleProof(headers, 0));
    }

    // ============ finalizationDelay ============

    function test_finalizationDelay_snapshotIgnoresLaterShorterDelay() public {
        // Shrink challengeWindow first so finalizationDelay can be reduced below it later
        vm.prank(admin);
        rollup.setChallengeWindow(5);

        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);
        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;

        // Shrink finalization delay AFTER acceptance. The old batch must keep its snapshot.
        vm.prank(admin);
        rollup.setFinalizationDelay(10);

        vm.roll(acceptedAt + 11);
        assertEq(rollup.finalizeBatches(batchIndex), 0, "old batch should keep original finalization delay snapshot");
    }

    function test_finalizationDelay_snapshotBoundaryFinalizesAfterDeadlineOnly() public {
        // Set both windows BEFORE acceptance so the new batch snapshots the reduced values.
        vm.prank(admin);
        rollup.setChallengeWindow(5);
        vm.prank(admin);
        rollup.setFinalizationDelay(10);

        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);
        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;

        // Finalization requires STRICT `>` (block.number - acceptedAt > delay) — exact boundary is not yet eligible.
        vm.roll(acceptedAt + 10);
        assertEq(rollup.finalizeBatches(batchIndex), 0, "exact finalization boundary should not finalize");

        vm.roll(acceptedAt + 11);
        assertEq(rollup.finalizeBatches(batchIndex), 1, "batch should finalize after the snapshotted delay elapses");
    }
}
