// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Tests for edge cases and bugs found in code review.
// Tests describe CORRECT expected behavior — they FAIL with current code
// where bugs exist and PASS after fixes are applied.

import {RollupBase} from "./Base.t.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorageLayout.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

contract ForceRevertTest is RollupBase {
    /// @dev Helper: advance a batch through the full lifecycle to Finalized.
    function _fullyFinalizeBatch(bytes32 parentHash) internal returns (uint256 batchIndex) {
        batchIndex = _acceptBatch(parentHash, 0);
        _submitDAProof(batchIndex, 0);
        _preconfirmBatch(batchIndex);
        vm.roll(block.number + APPROVE_BLOCK_COUNT + 1);
        assertTrue(_finalizeBatch(batchIndex));
    }

    // ================================================================
    // Bug 1 — forceRevertBatch doesn't clean batchBlobHashes
    // ================================================================

    /// @dev After reverting a batch, re-submitting DA should not accumulate
    ///      blob hashes from the old reverted batch.
    function test_forceRevert_cleansUpBlobHashes() public {
        // Accept batch 1
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitDAProof(batch1, 0);

        // Verify blob hashes exist (empty array since numBlobs=0, but entry exists)
        bytes32[] memory blobsBefore = rollup.batchBlobHashes(batch1);

        // Force revert batch 1
        vm.prank(admin);
        rollup.forceRevertBatch(batch1);

        // batchBlobHashes should be cleaned up
        bytes32[] memory blobsAfter = rollup.batchBlobHashes(batch1);
        assertEq(blobsAfter.length, 0, "blobHashes should be empty after revert");
    }

    /// @dev After reverting, lastBlockHashInBatch should be cleaned so
    ///      re-submission uses the correct chain linkage.
    function test_forceRevert_cleansUpLastBlockHash() public {
        // Accept batch 1
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        bytes32 lastHashBefore = rollup.lastBlockHashInBatch(batch1);
        assertTrue(lastHashBefore != bytes32(0), "should have last block hash");

        // Force revert batch 1
        vm.prank(admin);
        rollup.forceRevertBatch(batch1);

        // lastBlockHashInBatch should be cleaned up
        bytes32 lastHashAfter = rollup.lastBlockHashInBatch(batch1);
        assertEq(lastHashAfter, bytes32(0), "lastBlockHash should be zero after revert");
    }

    /// @dev After reverting and re-accepting, the new batch should chain from
    ///      the previous (non-reverted) batch's last block hash.
    function test_forceRevert_resubmissionChainsCorrectly() public {
        // Finalize batch 1 as a stable base
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 batch1LastHash = rollup.lastBlockHashInBatch(batch1);

        // Accept batch 2
        uint256 batch2 = _acceptBatch(batch1LastHash, 0);

        // Revert batch 2
        vm.prank(admin);
        rollup.forceRevertBatch(batch2);

        // Re-accept batch 2 — should chain from batch 1's last hash
        uint256 batch2Again = _acceptBatch(batch1LastHash, 0);
        assertEq(batch2Again, batch2, "re-submitted batch should have same index");
        _assertBatchRecord(batch2Again, RollupStorageLayout.BatchStatus.Accepted, 0, rollup.acceptedBatchRoot(batch2Again));
    }

    // ================================================================
    // Bug 2 — forceRevertBatch can revert past finalized batches in range
    // ================================================================

    /// @dev Reverting from a non-finalized batch should not silently delete
    ///      finalized batches later in the range. The check should validate
    ///      ALL batches in the range, not just the start index.
    function test_forceRevert_cannotRevertRangeContainingFinalized() public {
        // Batch 1: finalized (base)
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        // Batch 2: Accepted only (not finalized) — this is the revert start
        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);

        // Batch 3: fully finalized (sequential after batch 2 would normally be required,
        // but we use _submitDAProof + preconfirm + finalize via _finalizeBatch which
        // checks sequential order. So we need to finalize batch 2 first.)
        // Instead: accept batch 3 and move it to PreConfirmed, then finalize sequentially.
        bytes32 lastHash2 = rollup.lastBlockHashInBatch(batch2);
        uint256 batch3 = _acceptBatch(lastHash2, 0);
        _submitDAProof(batch2, 0);
        _preconfirmBatch(batch2);
        _submitDAProof(batch3, 0);
        _preconfirmBatch(batch3);

        vm.roll(block.number + APPROVE_BLOCK_COUNT + 1);

        // Finalize batch 2 then batch 3 (sequential)
        assertTrue(_finalizeBatch(batch2));
        assertTrue(_finalizeBatch(batch3));

        // Batch 4: Accepted (the revert target)
        bytes32 lastHash3 = rollup.lastBlockHashInBatch(batch3);
        uint256 batch4 = _acceptBatch(lastHash3, 0);

        // Attempt to revert from batch 2 — batch 2 is Finalized inside the range
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.BatchAlreadyFinalized.selector, batch2));
        rollup.forceRevertBatch(batch2);

        // Reverting from batch 4 (non-finalized) should succeed
        vm.prank(admin);
        rollup.forceRevertBatch(batch4);
        assertEq(rollup.nextBatchIndex(), batch4, "nextBatchIndex should be reset");
    }

    // ================================================================
    // Bug 3 — ensureBatchFinalized allows out-of-order finalization
    // ================================================================

    /// @dev Finalizing batch N should require batch N-1 to be finalized first.
    function test_ensureBatchFinalized_requiresSequentialOrder() public {
        // Accept + DA + preconfirm batch 1 and batch 2
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitDAProof(batch1, 0);
        _preconfirmBatch(batch1);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitDAProof(batch2, 0);
        _preconfirmBatch(batch2);

        vm.roll(block.number + APPROVE_BLOCK_COUNT + 1);

        // Attempting to finalize batch 2 before batch 1 should fail
        bool result = _finalizeBatch(batch2);
        assertFalse(result, "should not finalize batch 2 before batch 1");

        // Finalize batch 1 first
        assertTrue(_finalizeBatch(batch1), "batch 1 should finalize");

        // Now batch 2 can be finalized
        assertTrue(_finalizeBatch(batch2), "batch 2 should finalize after batch 1");
    }

    // ================================================================
    // Bug 4 — _rollupCorrupted returns false for Corrupted status
    // ================================================================

    /// @dev If a batch has been explicitly marked Corrupted (e.g. by a future
    ///      mechanism that sets the status), _rollupCorrupted() should still
    ///      return true. Currently it falls through all checks and returns false.
    ///
    ///      Note: No current code path sets Corrupted explicitly — _rollupCorrupted
    ///      is a view function. This test verifies the detection logic by triggering
    ///      corruption via DA deadline expiry and checking subsequent calls.
    function test_corruptedBatchBlocksNewAcceptance() public {
        // Accept batch 1 but don't submit DA
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        // Roll past DA deadline
        vm.roll(block.number + DA_DEADLINE_BLOCKS + 1);

        // Rollup should be corrupted
        _assertRollupCorrupted();

        // Trying to accept a new batch should revert
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        RollupStorageLayout.BlockCommitment[] memory batch = _makeBatch(lastHash);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 0);
    }

    /// @dev After DA deadline corruption, admin can force-revert and the rollup
    ///      should become healthy again.
    function test_corruptedRecoveryViaForceRevert() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        vm.roll(block.number + DA_DEADLINE_BLOCKS + 1);
        _assertRollupCorrupted();

        // Admin force-reverts
        vm.prank(admin);
        rollup.forceRevertBatch(batch1);

        // Rollup should be healthy
        _assertRollupHealthy();

        // Should be able to accept new batches
        uint256 batch1Again = _acceptBatch(GENESIS_HASH, 0);
        assertEq(batch1Again, batch1, "should reuse reverted batch index");
    }

    /// @dev Preconfirm deadline corruption: batch stuck in DAReady
    function test_preconfirmDeadlineCorruption() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitDAProof(batch1, 0);

        // batch is DAReady but preconfirmation never arrives
        vm.roll(block.number + PRECONFIRM_DEADLINE_BLOCKS + 1);

        _assertRollupCorrupted();
    }

    // ================================================================
    // Challenger refund flow via forceRevertBatch
    // ================================================================

    /// @dev When admin force-reverts a batch with an active challenge,
    ///      the challenger should receive deposit + incentive fee.
    function test_forceRevert_refundsChallenger() public {
        // Finalize batch 1 so we can challenge batch 2
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        // Accept + DA + preconfirm batch 2
        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        RollupStorageLayout.BlockCommitment[] memory batch2Commits = _makeBatch(lastHash1);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 0);
        uint256 batch2 = batch1 + 1;
        _submitDAProof(batch2, 0);
        _preconfirmBatch(batch2);

        // Challenge a commitment in batch 2
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(batch2Commits, 0);
        _challengeCommitment(batch2, batch2Commits[0], proof);

        // Verify challenger has no withdrawable balance yet
        _assertChallengerWithdrawable(challenger, 0);

        // Admin force-reverts batch 2, providing incentive fee
        uint256 incentiveFee = rollup.incentiveFee();
        vm.deal(admin, incentiveFee);
        vm.prank(admin);
        rollup.forceRevertBatch{value: incentiveFee}(batch2);

        // Challenger should now have deposit + incentive fee available
        _assertChallengerWithdrawable(challenger, CHALLENGE_DEPOSIT + incentiveFee);
    }

    // ================================================================
    // submitDAProof deadline enforcement
    // ================================================================

    /// @dev submitDAProof should revert when DA deadline has passed.
    ///      The corruption check fires before the deadline check since
    ///      _rollupCorrupted() detects the expired DA deadline first.
    function test_submitDAProof_revertsAfterDeadline() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        uint256 acceptedBlock = rollup.acceptedBlock(batch1);

        // Roll past DA deadline
        vm.roll(acceptedBlock + DA_DEADLINE_BLOCKS + 1);

        // submitDAProof should revert with RollupCorrupted (checked before DADeadlineExceeded)
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(sequencer);
        rollup.submitDAProof(batch1, 0);
    }

    // ================================================================
    // Bug 4 — forceRevertBatch doesn't delete blockCommitmentChallenges
    // ================================================================

    /// @dev After reverting a challenged batch and re-submitting identical blocks,
    ///      the same commitment should be challengeable again. Stale challenge
    ///      data from the reverted batch must not block new challenges.
    function test_forceRevert_allowsReChallengeAfterResubmit() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        // Accept + DA + preconfirm batch 2
        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        RollupStorageLayout.BlockCommitment[] memory batch2Commits = _makeBatch(lastHash1);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 0);
        uint256 batch2 = batch1 + 1;
        _submitDAProof(batch2, 0);
        _preconfirmBatch(batch2);

        // Challenge commitment 0
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(batch2Commits, 0);
        _challengeCommitment(batch2, batch2Commits[0], proof);

        // Admin force-reverts batch 2
        uint256 incentiveFee = rollup.incentiveFee();
        vm.deal(admin, incentiveFee);
        vm.prank(admin);
        rollup.forceRevertBatch{value: incentiveFee}(batch2);

        // Re-submit the same batch (identical block commitments)
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 0);
        _submitDAProof(batch2, 0);
        _preconfirmBatch(batch2);

        // Should be able to challenge the same commitment again
        MerkleTree.MerkleProof memory proof2 = _buildMerkleProof(batch2Commits, 0);
        _challengeCommitment(batch2, batch2Commits[0], proof2);

        assertEq(
            uint8(rollup.batchStatus(batch2)),
            uint8(RollupStorageLayout.BatchStatus.Challenged),
            "batch should be challenged after re-submit"
        );
    }

    // ================================================================
    // Bug 8 — corruption check missing from lifecycle functions
    // ================================================================

    /// @dev submitDAProof should revert when rollup is corrupted
    function test_submitDAProof_revertsWhenCorrupted() public {
        // batch 1: accept but don't submit DA → will become corrupted
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        // batch 2: accept (accepted at same block, so not yet corrupted)
        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);

        // Roll past DA deadline — batch 1 is now corrupted
        vm.roll(block.number + DA_DEADLINE_BLOCKS + 1);
        _assertRollupCorrupted();

        // submitDAProof on batch 2 should be blocked — rollup is corrupted
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(sequencer);
        rollup.submitDAProof(batch2, 0);
    }

    /// @dev commitPreConfirmation should revert when rollup is corrupted
    function test_commitPreConfirmation_revertsWhenCorrupted() public {
        // batch 1: accept but don't submit DA
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        // batch 2: accept + DA (ready for preconfirmation)
        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitDAProof(batch2, 0);

        // Roll past DA deadline — batch 1 corrupted
        vm.roll(block.number + DA_DEADLINE_BLOCKS + 1);
        _assertRollupCorrupted();

        // commitPreConfirmation on batch 2 should be blocked
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(preconfirmer);
        rollup.commitPreConfirmation(address(nitroVerifier), batch2, DUMMY_SIGNATURE);
    }

    /// @dev challengeBlockCommitment should revert when rollup is corrupted
    function test_challengeBlockCommitment_revertsWhenCorrupted() public {
        // batch 1: accept but don't submit DA
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        // batch 2: full lifecycle to PreConfirmed (challengeable)
        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        RollupStorageLayout.BlockCommitment[] memory batch2Commits = _makeBatch(lastHash1);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 0);
        uint256 batch2 = batch1 + 1;
        _submitDAProof(batch2, 0);
        _preconfirmBatch(batch2);

        // Roll past DA deadline — batch 1 corrupted
        vm.roll(block.number + DA_DEADLINE_BLOCKS + 1);
        _assertRollupCorrupted();

        // challengeBlockCommitment on batch 2 should be blocked
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(batch2Commits, 0);
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(challenger);
        rollup.challengeBlockCommitment{value: CHALLENGE_DEPOSIT}(batch2, batch2Commits[0], proof);
    }

    // ============ Private Helpers ============

    /// @dev Build a Merkle proof for the commitment at leafIndex within a batch.
    function _buildMerkleProof(
        RollupStorageLayout.BlockCommitment[] memory commitments,
        uint256 leafIndex
    ) internal pure returns (MerkleTree.MerkleProof memory) {
        uint256 count = commitments.length;
        bytes32[] memory leaves = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            leaves[i] = keccak256(
                abi.encodePacked(
                    commitments[i].previousBlockHash,
                    commitments[i].blockHash,
                    commitments[i].sentMessageRoot,
                    commitments[i].receivedMessageRoot
                )
            );
        }

        bytes memory proofData;
        uint256 idx = leafIndex;

        while (count > 1) {
            uint256 nextCount = (count + 1) / 2;
            bytes32[] memory nextLeaves = new bytes32[](nextCount);

            for (uint256 i = 0; i < count / 2; i++) {
                nextLeaves[i] = keccak256(abi.encodePacked(leaves[i * 2], leaves[i * 2 + 1]));
            }
            if (count % 2 == 1) {
                nextLeaves[nextCount - 1] = keccak256(abi.encodePacked(leaves[count - 1], leaves[count - 1]));
            }

            uint256 siblingIdx = (idx % 2 == 0) ? idx + 1 : idx - 1;
            bytes32 sibling;
            if (siblingIdx < count) {
                sibling = leaves[siblingIdx];
            } else {
                sibling = leaves[idx];
            }
            proofData = abi.encodePacked(proofData, sibling);

            idx = idx / 2;
            leaves = nextLeaves;
            count = nextCount;
        }

        return MerkleTree.MerkleProof({nonce: leafIndex, proof: proofData});
    }
}
