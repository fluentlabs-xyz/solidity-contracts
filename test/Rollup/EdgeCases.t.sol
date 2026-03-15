// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RollupBase} from "./Base.t.sol";
import {L2BlockHeader, BatchStatus, BatchRecord} from "../../contracts/interfaces/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

contract ForceRevertTest is RollupBase {
    function test_forceRevert_cleansUpBlobHashes() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);

        vm.prank(admin);
        rollup.forceRevertBatch(batch1);

        bytes32[] memory blobsAfter = rollup.batchBlobHashes(batch1);
        assertEq(blobsAfter.length, 0, "blobHashes should be empty after revert");
    }

    function test_forceRevert_cleansUpLastBlockHash() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        bytes32 lastHashBefore = rollup.lastBlockHashInBatch(batch1);
        assertTrue(lastHashBefore != bytes32(0), "should have last block hash");

        vm.prank(admin);
        rollup.forceRevertBatch(batch1);

        bytes32 lastHashAfter = rollup.lastBlockHashInBatch(batch1);
        assertEq(lastHashAfter, bytes32(0), "lastBlockHash should be zero after revert");
    }

    function test_forceRevert_resubmissionChainsCorrectly() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 batch1LastHash = rollup.lastBlockHashInBatch(batch1);

        uint256 batch2 = _acceptBatch(batch1LastHash, 0);

        vm.prank(admin);
        rollup.forceRevertBatch(batch2);

        uint256 batch2Again = _acceptBatch(batch1LastHash, 0);
        assertEq(batch2Again, batch2, "re-submitted batch should have same index");
        _assertBatchRecord(batch2Again, BatchStatus.HeadersSubmitted, 0, rollup.getBatch(batch2Again).batchRoot);
    }

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

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.BatchAlreadyFinalized.selector, batch2));
        rollup.forceRevertBatch(batch2);

        vm.prank(admin);
        rollup.forceRevertBatch(batch4);
        assertEq(rollup.nextBatchIndex(), batch4, "nextBatchIndex should be reset");
    }

    function test_finalizeBatches_requiresSequentialOrder() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        _preconfirmBatch(batch1);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);


        vm.roll(block.number + FINALIZATION_DELAY + 1);

        // Both batches past cooldown now. finalizeBatches(2) finalizes both.
        uint256 finalized = rollup.finalizeBatches(batch2);
        assertEq(finalized, 2, "both batches should finalize sequentially");
        assertTrue(rollup.isBatchFinalized(batch1));
        assertTrue(rollup.isBatchFinalized(batch2));
    }

    function test_corruptedBatchBlocksNewAcceptance() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);

        _assertRollupCorrupted();

        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch = _makeBatch(lastHash);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch, 0);
    }

    function test_corruptedRecoveryViaForceRevert() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        vm.prank(admin);
        rollup.forceRevertBatch(batch1);

        _assertRollupHealthy();

        uint256 batch1Again = _acceptBatch(GENESIS_HASH, 0);
        assertEq(batch1Again, batch1, "should reuse reverted batch index");
    }

    function test_preconfirmDeadlineCorruption() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);

        vm.roll(block.number + PRECONFIRM_WINDOW + 1);

        _assertRollupCorrupted();
    }

    function test_forceRevert_refundsChallenger() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Commits = _makeBatch(lastHash1);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 0);
        uint256 batch2 = batch1 + 1;
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(batch2Commits, 0);
        _challengeBlock(batch2, batch2Commits[0], proof);

        _assertChallengerWithdrawable(challenger, 0);

        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee);
        vm.prank(admin);
        rollup.forceRevertBatch{value: fee}(batch2);

        _assertChallengerWithdrawable(challenger, CHALLENGE_DEPOSIT + fee);
    }

    function test_submitBlobs_revertsAfterDeadline() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        uint256 acceptedBlock = rollup.getBatch(batch1).acceptedAtBlock;

        vm.roll(acceptedBlock + SUBMIT_BLOBS_WINDOW + 1);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(sequencer);
        rollup.submitBlobs(batch1, 0);
    }

    function test_forceRevert_allowsReChallengeAfterResubmit() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Commits = _makeBatch(lastHash1);
        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 0);
        uint256 batch2 = batch1 + 1;
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(batch2Commits, 0);
        _challengeBlock(batch2, batch2Commits[0], proof);

        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee);
        vm.prank(admin);
        rollup.forceRevertBatch{value: fee}(batch2);

        vm.prank(sequencer);
        rollup.acceptNextBatch(batch2Commits, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        MerkleTree.MerkleProof memory proof2 = _buildMerkleProof(batch2Commits, 0);
        _challengeBlock(batch2, batch2Commits[0], proof2);

        assertEq(
            uint8(rollup.getBatch(batch2).status),
            uint8(BatchStatus.Challenged),
            "batch should be challenged after re-submit"
        );
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
        rollup.acceptNextBatch(batch2Commits, 0);
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
}
