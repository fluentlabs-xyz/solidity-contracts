// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {RollupAssertions} from "./Base.t.sol";
import {BlockDeposit} from "../../contracts/interfaces/rollup/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/rollup/IRollup.sol";
import {L2BlockHeader, BatchRecord, BatchStatus} from "../../contracts/interfaces/rollup/IRollupTypes.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

/// @dev Verifies that batch-lifecycle timing windows are frozen at {Rollup-commitBatch}
///      and that admin updates to those windows do NOT retroactively affect in-flight batches.
contract RollupSnapshotTest is RollupAssertions {
    function test_commitBatch_snapshotsCurrentBatchWindows() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        BatchRecord memory batch = rollup.getBatch(batchIndex);

        assertEq(batch.submitBlobsWindowSnapshot, SUBMIT_BLOBS_WINDOW, "submitBlobs window snapshot mismatch");
        assertEq(batch.challengeWindowSnapshot, CHALLENGE_WINDOW, "challenge window snapshot mismatch");
        assertEq(batch.finalizationDelaySnapshot, FINALIZATION_DELAY, "finalization delay snapshot mismatch");
        assertEq(batch.preconfirmationWindowSnapshot, PRECONFIRM_WINDOW, "preconfirm window snapshot mismatch");
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
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Submitted), "blob submission should still succeed");
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

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Submitted), "exact submitBlobs boundary should succeed");
    }

    // ============ challengeWindow ============

    function test_challengeWindow_snapshotIgnoresLaterShorterWindow() public {
        L2BlockHeader[] memory headers = _makeBatch(GENESIS_HASH);
        uint256 batchIndex = rollup.nextBatchIndex();

        vm.prank(sequencer);
        rollup.commitBatch(_computeBatchRoot(headers), GENESIS_HASH, headers[headers.length - 1].blockHash, uint24(headers.length), new BlockDeposit[](0), 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;

        // Shrink the global window AFTER acceptance. The challenge deadline for this batch
        // must still derive from the snapshotted window, not the new global value.
        vm.prank(admin);
        rollup.setChallengeWindow(7450);

        vm.roll(acceptedAt + 7460);

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
        rollup.setChallengeWindow(7450);

        L2BlockHeader[] memory headers = _makeBatch(GENESIS_HASH);
        uint256 batchIndex = rollup.nextBatchIndex();

        vm.prank(sequencer);
        rollup.commitBatch(_computeBatchRoot(headers), GENESIS_HASH, headers[headers.length - 1].blockHash, uint24(headers.length), new BlockDeposit[](0), 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;
        vm.roll(acceptedAt + 7450);

        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.prank(challenger);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ChallengeTooLate.selector, batchIndex));
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], _buildMerkleProof(headers, 0));
    }

    function test_challengeWindow_snapshotIgnoresLaterShorterWindowOnFinalize() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);
        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;

        // Shrink the global challenge window AFTER acceptance. The finalize fast-path
        // must derive its deadline from the snapshot, not the live admin value — otherwise
        // an admin update would let in-flight batches finalize earlier than promised.
        vm.prank(admin);
        rollup.setChallengeWindow(7450);

        // Past the live (shorter) window but still inside the original snapshot — must NOT finalize.
        vm.roll(acceptedAt + 7451);
        assertEq(rollup.finalizeBatches(batchIndex), 0, "old batch must use snapshotted challenge window");

        // Past the original snapshot — fast-path finalizes.
        vm.roll(acceptedAt + CHALLENGE_WINDOW + 1);
        assertEq(rollup.finalizeBatches(batchIndex), 1, "finalizes once snapshotted challenge window elapses");
    }

    // ============ preconfirmWindow ============

    function test_preconfirmWindow_snapshotIgnoresLaterShorterWindow() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batchIndex, 0);
        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;

        vm.prank(admin);
        rollup.setPreconfirmWindow(3750);

        vm.roll(acceptedAt + 3760);
        assertFalse(rollup.isRollupCorrupted(), "old batch should keep original preconfirm snapshot");

        _preconfirmBatch(batchIndex);
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Preconfirmed));
    }

}
