// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {RollupBase} from "./Base.t.sol";
import {L2BlockHeader, BatchStatus, BatchRecord} from "../../contracts/interfaces/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

contract ForceRevertTest is RollupBase {
    // ============ Cleanup ============

    function test_forceRevert_cleansUpBlobHashes() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash, 0);
        _submitBlobs(batch2, 0);

        // forceRevertBatch(batch1) keeps batch1, reverts batch2
        vm.prank(admin);
        rollup.forceRevertBatch(batch1);

        assertEq(rollup.batchBlobHashes(batch2).length, 0, "blobHashes should be empty after revert");
    }

    function test_forceRevert_cleansUpLastBlockHash() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 batch1LastHash = rollup.lastBlockHashInBatch(batch1);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Headers = _makeBatch(lastHash1);
        uint256 batch2 = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Headers, 1);

        bytes32 expectedBatch2LastHash = batch2Headers[batch2Headers.length - 1].blockHash;
        assertEq(rollup.lastBlockHashInBatch(batch2), expectedBatch2LastHash, "batch2 lastBlockHash should match last header blockHash");

        // Revert batch2: keep batch1, remove batch2
        vm.prank(admin);
        rollup.forceRevertBatch(batch1);

        // batch2's hash cleared
        assertEq(rollup.lastBlockHashInBatch(batch2), bytes32(0), "batch2 lastBlockHash should be zero after revert");

        // batch1's hash preserved — required for correct re-chaining
        assertEq(rollup.lastBlockHashInBatch(batch1), batch1LastHash, "batch1 lastBlockHash must be preserved");
    }

    function test_forceRevert_cleansUpProvenBlocks() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Commits = _makeBatch(lastHash);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 1);
        uint256 batch2 = batch1 + 1;
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(batch2Commits, 0);
        _challengeBlock(batch2, batch2Commits[0], proof);
        vm.prank(prover);
        rollup.resolveChallenge(batch2, batch2Commits[0], proof, address(nitroVerifier), DUMMY_SIGNATURE, "");

        bytes32 commitment = _computeCommitment(batch2Commits[0]);
        assertTrue(rollup.isBlockProven(commitment), "should be proven before revert");

        // Revert batch2: keep batch1
        vm.prank(admin);
        rollup.forceRevertBatch(batch1);

        assertFalse(rollup.isBlockProven(commitment), "proven flag should be cleared after revert");
    }

    function test_forceRevert_multipleBatches_cleansAll() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        bytes32 lastHash2 = rollup.lastBlockHashInBatch(batch2);
        uint256 batch3 = _acceptBatch(lastHash2, 0);
        _submitBlobs(batch3, 0);
        _preconfirmBatch(batch3);

        assertEq(rollup.nextBatchIndex(), batch3 + 1);

        // Revert batch2 and batch3: keep batch1
        vm.prank(admin);
        rollup.forceRevertBatch(batch1);

        assertEq(rollup.nextBatchIndex(), batch1 + 1);
        assertEq(rollup.getBatch(batch2).batchRoot, bytes32(0), "batch2 should be deleted");
        assertEq(rollup.getBatch(batch3).batchRoot, bytes32(0), "batch3 should be deleted");
        assertEq(rollup.lastBlockHashInBatch(batch2), bytes32(0), "batch2 lastBlockHash should be cleared");
        assertEq(rollup.lastBlockHashInBatch(batch3), bytes32(0), "batch3 lastBlockHash should be cleared");
        assertEq(rollup.batchBlobHashes(batch2).length, 0, "batch2 blobHashes should be cleared");
        assertEq(rollup.batchBlobHashes(batch3).length, 0, "batch3 blobHashes should be cleared");
    }

    // ============ Resubmission ============

    function test_forceRevert_resubmissionChainsCorrectly() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 batch1LastHash = rollup.lastBlockHashInBatch(batch1);

        uint256 batch2 = _acceptBatch(batch1LastHash, 0);

        // Revert batch2: keep batch1
        vm.prank(admin);
        rollup.forceRevertBatch(batch1);

        uint256 batch2Again = _acceptBatch(batch1LastHash, 0);
        assertEq(batch2Again, batch2, "re-submitted batch should have same index");
        _assertBatchRecord(batch2Again, BatchStatus.HeadersSubmitted, 1, rollup.getBatch(batch2Again).batchRoot);
    }

    function test_forceRevert_allowsReChallengeAfterResubmit() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Commits = _makeBatch(lastHash1);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 1);
        uint256 batch2 = batch1 + 1;
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(batch2Commits, 0);
        _challengeBlock(batch2, batch2Commits[0], proof);

        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee);
        vm.prank(admin);
        rollup.forceRevertBatch{value: fee}(batch1);

        // Re-submit the same batch
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 1);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        MerkleTree.MerkleProof memory proof2 = _buildMerkleProof(batch2Commits, 0);
        _challengeBlock(batch2, batch2Commits[0], proof2);

        assertEq(uint8(rollup.getBatch(batch2).status), uint8(BatchStatus.Challenged), "batch should be challenged after re-submit");
    }

    // ============ Finalization guards ============

    function test_forceRevert_cannotRevertRangeContainingFinalized() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);

        bytes32 lastHash2 = rollup.lastBlockHashInBatch(batch2);
        uint256 batch3 = _acceptBatch(lastHash2, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);
        _submitBlobs(batch3, 0);
        _preconfirmBatch(batch3);

        vm.roll(block.number + FINALIZATION_DELAY + 1);
        assertTrue(_finalizeBatch(batch2));
        assertTrue(_finalizeBatch(batch3));

        bytes32 lastHash3 = rollup.lastBlockHashInBatch(batch3);
        uint256 batch4 = _acceptBatch(lastHash3, 0);

        // Trying to revert from batch1 (which would include finalized batch2) should fail
        // The loop goes from lastAccepted down to toBatchIndex+1, hitting finalized batch3 first
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.BatchAlreadyFinalized.selector, batch4 - 1));
        rollup.forceRevertBatch(batch1);

        // Reverting only batch4 (keep batch3) should succeed
        vm.prank(admin);
        rollup.forceRevertBatch(batch3);
        assertEq(rollup.nextBatchIndex(), batch3 + 1, "nextBatchIndex should be reset");
    }

    // ============ Corruption ============

    function test_corruptedBatchBlocksNewAcceptance() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch = _makeBatch(lastHash);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 1);
    }

    function test_corruptedRecoveryViaForceRevert() public {
        // Finalize batch1 first so we have a valid toBatchIndex > 0
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);

        uint256 batch2 = _acceptBatch(lastHash, 0);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        // Revert batch2: keep batch1
        vm.prank(admin);
        rollup.forceRevertBatch(batch1);

        _assertRollupHealthy();

        uint256 batch2Again = _acceptBatch(lastHash, 0);
        assertEq(batch2Again, batch2, "should reuse reverted batch index");
    }

    function test_preconfirmDeadlineCorruption() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);

        vm.roll(block.number + PRECONFIRM_WINDOW + 1);

        _assertRollupCorrupted();
    }

    function test_submitBlobs_revertsAfterDeadline() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        uint256 acceptedBlock = rollup.getBatch(batch1).acceptedAtBlock;

        vm.roll(acceptedBlock + SUBMIT_BLOBS_WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(sequencer);
        rollup.submitBlobs(batch1, 0);
    }

    function test_submitBlobs_revertsWhenCorrupted() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(sequencer);
        rollup.submitBlobs(batch2, 0);
    }

    function test_preconfirmBatch_revertsWhenCorrupted() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitBlobs(batch2, 0);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(preconfirmer);
        rollup.preconfirmBatch(address(nitroVerifier), batch2, DUMMY_SIGNATURE);
    }

    function test_challengeBlock_revertsWhenCorrupted() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Commits = _makeBatch(lastHash1);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 1);
        uint256 batch2 = batch1 + 1;
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(batch2Commits, 0);
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batch2, batch2Commits[0], proof);
    }

    // ============ Challenger rewards ============

    function test_forceRevert_refundsChallenger() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Commits = _makeBatch(lastHash1);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 1);
        uint256 batch2 = batch1 + 1;
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(batch2Commits, 0);
        _challengeBlock(batch2, batch2Commits[0], proof);

        _assertChallengerWithdrawable(challenger, 0);

        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee);
        vm.prank(admin);
        rollup.forceRevertBatch{value: fee}(batch1);

        _assertChallengerWithdrawable(challenger, CHALLENGE_DEPOSIT + fee);
    }

    function test_forceRevert_multipleChallengers_allRewarded() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Commits = _makeBatch(lastHash1);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 1);
        uint256 batch2 = batch1 + 1;
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        MerkleTree.MerkleProof memory proof2 = _buildMerkleProof(batch2Commits, 0);
        _challengeBlock(batch2, batch2Commits[0], proof2);

        address challenger2 = makeAddr("challenger2");
        bytes32 challengerRole = rollup.CHALLENGER_ROLE();
        vm.prank(admin);
        rollup.grantRole(challengerRole, challenger2);

        bytes32 lastHash2 = rollup.lastBlockHashInBatch(batch2);
        L2BlockHeader[] memory batch3Commits = _makeBatch(lastHash2);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch3Commits, 1);
        uint256 batch3 = batch2 + 1;
        _submitBlobs(batch3, 0);
        _preconfirmBatch(batch3);

        MerkleTree.MerkleProof memory proof3 = _buildMerkleProof(batch3Commits, 0);
        vm.deal(challenger2, CHALLENGE_DEPOSIT);
        vm.prank(challenger2);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batch3, batch3Commits[0], proof3);

        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee * 2);
        vm.prank(admin);
        rollup.forceRevertBatch{value: fee * 2}(batch1);

        assertEq(rollup.claimableChallengerReward(challenger), CHALLENGE_DEPOSIT + fee, "challenger reward mismatch");
        assertEq(rollup.claimableChallengerReward(challenger2), CHALLENGE_DEPOSIT + fee, "challenger2 reward mismatch");
    }

    function test_revert_forceRevert_insufficientIncentiveFee() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Commits = _makeBatch(lastHash);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 1);
        uint256 batch2 = batch1 + 1;
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(batch2Commits, 0);
        _challengeBlock(batch2, batch2Commits[0], proof);

        uint256 fee = rollup.incentiveFee();
        uint256 insufficient = fee - 1;
        vm.deal(admin, insufficient);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.NotEnoughValueIncentiveFee.selector, insufficient, fee));
        rollup.forceRevertBatch{value: insufficient}(batch1);
    }
}
