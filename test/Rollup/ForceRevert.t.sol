// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;
import {RollupAssertions} from "./Base.t.sol";
import {L2BlockHeader, BlockDeposit, BatchStatus} from "../../contracts/interfaces/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {MockDepositBridge} from "../mocks/MockDepositBridge.sol";
import {MockNitroVerifier} from "../mocks/MockNitroVerifier.sol";

contract ForceRevertTest is RollupAssertions {
    MockDepositBridge internal depositBridge;

    function setUp() public override {
        depositBridge = new MockDepositBridge();
        bridgeAddr = address(depositBridge);
        nitroVerifier = new MockNitroVerifier();
        rollup = _deployRollup(bridgeAddr);
    }

    // ============ Cleanup ============

    function test_forceRevert_cleansUpBlobHashes() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash, 0);
        _submitBlobs(batch2, 0);

        // revertBatches(batch1) keeps batch1, reverts batch2
        vm.prank(admin);
        rollup.revertBatches(batch1);

        assertEq(rollup.batchBlobHashes(batch2).length, 0, "blobHashes should be empty after revert");
    }

    function test_forceRevert_cleansUpLastBlockHash() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 batch1LastHash = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch1);

        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Headers = _makeBatch(lastHash1);
        uint256 batch2 = rollup.nextBatchIndex();
        _commitBatch(batch2Headers, new BlockDeposit[](0));

        // Revert batch2: keep batch1, remove batch2
        vm.prank(admin);
        rollup.revertBatches(batch1);
    }

    function test_forceRevert_cleansUpProvenBlocks() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Commits = _makeBatch(lastHash);
        _commitBatch(batch2Commits, new BlockDeposit[](0));
        uint256 batch2 = batch1 + 1;
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(batch2Commits, 0);
        _challengeBlock(batch2, batch2Commits[0], proof);
        vm.prank(prover);
        rollup.resolveBlockChallenge(batch2, batch2Commits[0], proof, address(nitroVerifier), DUMMY_SIGNATURE, "");

        bytes32 commitment = _computeCommitment(batch2Commits[0]);
        assertTrue(rollup.isBlockProven(commitment), "should be proven before revert");

        // Revert batch2: keep batch1
        vm.prank(admin);
        rollup.revertBatches(batch1);

        assertFalse(rollup.isBlockProven(commitment), "proven flag should be cleared after revert");
    }

    function test_forceRevert_multipleBatches_cleansAll() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        bytes32 lastHash2 = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch2);
        uint256 batch3 = _acceptBatch(lastHash2, 0);
        _submitBlobs(batch3, 0);
        _preconfirmBatch(batch3);

        assertEq(rollup.nextBatchIndex(), batch3 + 1);

        // Revert batch2 and batch3: keep batch1
        vm.prank(admin);
        rollup.revertBatches(batch1);

        assertEq(rollup.nextBatchIndex(), batch1 + 1);
        assertEq(rollup.getBatch(batch2).batchRoot, bytes32(0), "batch2 should be deleted");
        assertEq(rollup.getBatch(batch3).batchRoot, bytes32(0), "batch3 should be deleted");
        // lastBlockHashInBatch removed — chain linking is no longer stored
        assertEq(rollup.batchBlobHashes(batch2).length, 0, "batch2 blobHashes should be cleared");
        assertEq(rollup.batchBlobHashes(batch3).length, 0, "batch3 blobHashes should be cleared");
    }

    // ============ Resubmission ============

    function test_forceRevert_resubmissionChainsCorrectly() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 batch1LastHash = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch1);

        uint256 batch2 = _acceptBatch(batch1LastHash, 0);

        // Revert batch2: keep batch1
        vm.prank(admin);
        rollup.revertBatches(batch1);

        uint256 batch2Again = _acceptBatch(batch1LastHash, 0);
        assertEq(batch2Again, batch2, "re-submitted batch should have same index");
        _assertBatchRecord(batch2Again, BatchStatus.Committed, 1, rollup.getBatch(batch2Again).batchRoot);
    }

    function test_forceRevert_allowsReChallengeAfterResubmit() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Commits = _makeBatch(lastHash1);
        _commitBatch(batch2Commits, new BlockDeposit[](0));
        uint256 batch2 = batch1 + 1;
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(batch2Commits, 0);
        _challengeBlock(batch2, batch2Commits[0], proof);

        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee);
        vm.prank(admin);
        rollup.revertBatches{value: fee}(batch1);

        // Re-submit the same batch
        _commitBatch(batch2Commits, new BlockDeposit[](0));
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        MerkleTree.MerkleProof memory proof2 = _buildMerkleProof(batch2Commits, 0);
        _challengeBlock(batch2, batch2Commits[0], proof2);

        assertEq(uint8(rollup.getBatch(batch2).status), uint8(BatchStatus.Challenged), "batch should be challenged after re-submit");
    }

    // ============ Finalization guards ============

    function test_forceRevert_cannotRevertRangeContainingFinalized() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);

        bytes32 lastHash2 = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch2);
        uint256 batch3 = _acceptBatch(lastHash2, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);
        _submitBlobs(batch3, 0);
        _preconfirmBatch(batch3);

        vm.roll(block.number + FINALIZATION_DELAY + 1);
        assertTrue(_finalizeBatch(batch2));
        assertTrue(_finalizeBatch(batch3));

        bytes32 lastHash3 = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch3);
        uint256 batch4 = _acceptBatch(lastHash3, 0);

        // Trying to revert from batch1 (which would include finalized batch2) should fail
        // The loop goes from lastAccepted down to toBatchIndex+1, hitting finalized batch3 first
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.BatchAlreadyFinalized.selector, batch4 - 1));
        rollup.revertBatches(batch1);

        // Reverting only batch4 (keep batch3) should succeed
        vm.prank(admin);
        rollup.revertBatches(batch3);
        assertEq(rollup.nextBatchIndex(), batch3 + 1, "nextBatchIndex should be reset");
    }

    // ============ Corruption ============

    function test_corruptedRecoveryViaForceRevert() public {
        // Finalize batch1 first so we have a valid toBatchIndex > 0
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch1);

        uint256 batch2 = _acceptBatch(lastHash, 0);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        // Revert batch2: keep batch1
        vm.prank(admin);
        rollup.revertBatches(batch1);

        _assertRollupHealthy();

        uint256 batch2Again = _acceptBatch(lastHash, 0);
        assertEq(batch2Again, batch2, "should reuse reverted batch index");
    }

    // ============ Challenger rewards ============

    function test_forceRevert_refundsChallenger() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Commits = _makeBatch(lastHash1);
        _commitBatch(batch2Commits, new BlockDeposit[](0));
        uint256 batch2 = batch1 + 1;
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(batch2Commits, 0);
        _challengeBlock(batch2, batch2Commits[0], proof);

        _assertChallengerWithdrawable(challenger, 0);

        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee);
        vm.prank(admin);
        rollup.revertBatches{value: fee}(batch1);

        _assertChallengerWithdrawable(challenger, CHALLENGE_DEPOSIT + fee);
    }

    function test_forceRevert_multipleChallengers_allRewarded() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Commits = _makeBatch(lastHash1);
        _commitBatch(batch2Commits, new BlockDeposit[](0));
        uint256 batch2 = batch1 + 1;
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        MerkleTree.MerkleProof memory proof2 = _buildMerkleProof(batch2Commits, 0);
        _challengeBlock(batch2, batch2Commits[0], proof2);

        address challenger2 = makeAddr("challenger2");
        bytes32 challengerRole = rollup.CHALLENGER_ROLE();
        vm.prank(admin);
        rollup.grantRole(challengerRole, challenger2);

        L2BlockHeader[] memory batch3Commits = _makeBatch(_lastBlockHash(lastHash1));
        _commitBatch(batch3Commits, new BlockDeposit[](0));
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
        rollup.revertBatches{value: fee * 2}(batch1);

        assertEq(rollup.claimableChallengerReward(challenger), CHALLENGE_DEPOSIT + fee, "challenger reward mismatch");
        assertEq(rollup.claimableChallengerReward(challenger2), CHALLENGE_DEPOSIT + fee, "challenger2 reward mismatch");
    }

    function test_RevertIf_revertBatches_zeroBatchIndex() public {
        _acceptBatch(GENESIS_HASH, 0);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ZeroValueNotAllowed.selector, "toBatchIndex"));
        rollup.revertBatches(0);
    }

    function test_RevertIf_revertBatches_invalidBatchIndex() public {
        // Accept MAX_FORCE_REVERT_BATCH_SIZE + 2 batches so reverting from batch 1
        // exceeds the max revert batch size
        bytes32 lastHash = GENESIS_HASH;
        for (uint256 i = 0; i < MAX_FORCE_REVERT_BATCH_SIZE + 2; i++) {
            _acceptBatch(lastHash, 0);
            lastHash = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(rollup.nextBatchIndex() - 1);
        }

        uint256 lastAccepted = rollup.nextBatchIndex() - 1;

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchIndex.selector, uint256(1), lastAccepted));
        rollup.revertBatches(1);
    }

    function test_RevertIf_revertBatches_insufficientIncentiveFee() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch1);
        L2BlockHeader[] memory batch2Commits = _makeBatch(lastHash);
        _commitBatch(batch2Commits, new BlockDeposit[](0));
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
        rollup.revertBatches{value: insufficient}(batch1);
    }

    // ============ Deposit restoration ============

    /// @dev Reproduces the auditor-reported bug: deposits popped during `commitBatch`
    ///      must be restored to the bridge queue on `revertBatches`, in their original
    ///      order, so the sequencer can re-submit the same L2 blocks after recovery.
    ///
    ///      Under the cursor design, "restoration" is a single rewind of the bridge consume
    ///      cursor — verified by checking that the same hashes are returned by re-consuming
    ///      after the revert, and that any deposits enqueued between accept and revert do
    ///      NOT shift the original ones.
    function test_forceRevert_restoresDepositsToQueueInOriginalOrder() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch1);

        // Two deposits arrive and are consumed by batch2
        bytes32 depositA = keccak256("deposit-A");
        bytes32 depositB = keccak256("deposit-B");
        depositBridge.enqueue(depositA);
        depositBridge.enqueue(depositB);

        (L2BlockHeader[] memory batch2Headers, BlockDeposit[] memory deps) = _makeBatchWithDeposits(lastHash, 0, depositA, depositB);
        _commitBatch(batch2Headers, deps);

        assertEq(depositBridge.getSentMessageQueueSize(), 0, "both deposits consumed by commitBatch");

        // Between acceptance and force-revert, new deposits arrive in the queue.
        // The cursor-rewind approach must place the restored A, B back at the front,
        // and these new entries must remain at positions 2, 3.
        bytes32 depositC = keccak256("deposit-C");
        bytes32 depositD = keccak256("deposit-D");
        depositBridge.enqueue(depositC);
        depositBridge.enqueue(depositD);

        // Trigger corruption: DA deadline exceeded for batch2
        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        // Force-revert batch2
        vm.prank(admin);
        rollup.revertBatches(batch1);
        _assertRollupHealthy();

        // All four deposits must be present and consumable in original send order.
        assertEq(depositBridge.getSentMessageQueueSize(), 4, "restored deposits + new ones present");

        bytes32 popped0 = depositBridge.consumeNextSentMessage();
        bytes32 popped1 = depositBridge.consumeNextSentMessage();
        bytes32 popped2 = depositBridge.consumeNextSentMessage();
        bytes32 popped3 = depositBridge.consumeNextSentMessage();
        assertEq(popped0, depositA, "position 0 must be restored A");
        assertEq(popped1, depositB, "position 1 must be restored B");
        assertEq(popped2, depositC, "position 2 must be new C");
        assertEq(popped3, depositD, "position 3 must be new D");
    }

    /// @dev Verifies that BatchRecord.sentMessageCursorStart is captured correctly
    ///      regardless of whether the batch consumes deposits or not.
    function test_commitBatch_snapshotsBridgeCursorIntoBatchRecord() public {
        // Batch 1: no deposits
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        assertEq(rollup.getBatch(batch1).sentMessageCursorStart, 0, "no prior consumes");

        // Enqueue 3 deposits then accept batch 2 with all 3
        bytes32 d1 = keccak256("d1");
        bytes32 d2 = keccak256("d2");
        bytes32 d3 = keccak256("d3");
        depositBridge.enqueue(d1);
        depositBridge.enqueue(d2);
        depositBridge.enqueue(d3);

        bytes32 lastHash = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch1);
        (L2BlockHeader[] memory batch2Headers, BlockDeposit[] memory deps3) = _makeBatchWithDeposits3(lastHash, 0, d1, d2, d3);
        _commitBatch(batch2Headers, deps3);
        uint256 batch2 = batch1 + 1;

        // Snapshot was 0 (no prior consumes) — captured BEFORE the loop ran
        assertEq(rollup.getBatch(batch2).sentMessageCursorStart, 0, "snapshot taken before consumes");

        // Batch 3: snapshot must be 3 (the cursor after batch2 consumed all 3)
        bytes32 lastHash2 = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch2);
        uint256 batch3 = _acceptBatch(lastHash2, 0);
        assertEq(rollup.getBatch(batch3).sentMessageCursorStart, 3, "snapshot reflects accumulated cursor");
    }

    /// @dev Multi-batch revert: cursor must be rewound to the snapshot of the
    ///      OLDEST reverted batch, not the most recent.
    function test_forceRevert_multipleBatches_rewindsCursorToOldestSnapshot() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch1);

        // batch2 consumes 2 deposits
        bytes32 a = keccak256("a");
        bytes32 b = keccak256("b");
        depositBridge.enqueue(a);
        depositBridge.enqueue(b);
        (L2BlockHeader[] memory batch2Headers, BlockDeposit[] memory deps2) = _makeBatchWithDeposits(lastHash1, 0, a, b);
        _commitBatch(batch2Headers, deps2);
        uint256 batch2 = batch1 + 1;
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        // batch3 consumes 1 more deposit
        bytes32 c = keccak256("c");
        depositBridge.enqueue(c);
        bytes32 lastHash2 = _lastBlockHash(GENESIS_HASH); // was rollup.lastBlockHashInBatch(batch2);
        (L2BlockHeader[] memory batch3Headers, BlockDeposit[] memory deps3b) = _makeBatchWithDeposits1(lastHash2, 0, c);
        _commitBatch(batch3Headers, deps3b);

        // After both accepts: cursor at 3, queue size 0
        assertEq(depositBridge.getSentMessageCursor(), 3, "cursor advanced to 3");
        assertEq(depositBridge.getSentMessageQueueSize(), 0, "queue drained");

        // Revert batch2 AND batch3 in one call (keep only batch1)
        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee);
        vm.prank(admin);
        rollup.revertBatches{value: fee}(batch1);

        // Cursor must be back to 0 (snapshot of batch2, the oldest reverted batch)
        assertEq(depositBridge.getSentMessageCursor(), 0, "cursor rewound to oldest snapshot");
        assertEq(depositBridge.getSentMessageQueueSize(), 3, "all 3 deposits consumable again");

        // Re-consume in original order
        assertEq(depositBridge.consumeNextSentMessage(), a, "re-consume a");
        assertEq(depositBridge.consumeNextSentMessage(), b, "re-consume b");
        assertEq(depositBridge.consumeNextSentMessage(), c, "re-consume c");
    }

    /// @dev revertBatches with toBatchIndex == lastAcceptedBatchIndex is a no-op for
    ///      the cursor — must not call rewindSentMessageCursor at all.
    function test_forceRevert_noBatchesToRevert_doesNotRewindCursor() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        // lastAcceptedBatchIndex == batch1, toBatchIndex == batch1 → range is empty

        bytes32 d = keccak256("d");
        depositBridge.enqueue(d);
        // After enqueue, cursor is still 0 (nothing consumed)
        assertEq(depositBridge.getSentMessageCursor(), 0);

        vm.prank(admin);
        rollup.revertBatches(batch1);

        // Cursor unchanged — no rewind happened
        assertEq(depositBridge.getSentMessageCursor(), 0);
        assertEq(depositBridge.getSentMessageQueueSize(), 1, "deposit still in queue");
    }

    // ============ Helpers ============

    function _commitBatch(L2BlockHeader[] memory headers, BlockDeposit[] memory deposits) internal {
        vm.prank(sequencer);
        rollup.commitBatch(_computeBatchRoot(headers), uint24(headers.length), deposits, 1);
    }

    function _makeDeposits(bytes32[] memory ids) internal pure returns (BlockDeposit[] memory deposits) {
        deposits = new BlockDeposit[](1);
        deposits[0] = BlockDeposit({
            depositRoot: keccak256(abi.encodePacked(ids)),
            depositCount: uint16(ids.length)
        });
    }

    function _makeBatchWithDeposits(
        bytes32 parentHash,
        uint256,
        bytes32 depositA,
        bytes32 depositB
    ) internal pure returns (L2BlockHeader[] memory batch, BlockDeposit[] memory deposits) {
        batch = _makeBatch(parentHash);
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = depositA;
        ids[1] = depositB;
        deposits = _makeDeposits(ids);
    }

    function _makeBatchWithDeposits1(
        bytes32 parentHash,
        uint256,
        bytes32 deposit
    ) internal pure returns (L2BlockHeader[] memory batch, BlockDeposit[] memory deposits) {
        batch = _makeBatch(parentHash);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = deposit;
        deposits = _makeDeposits(ids);
    }

    function _makeBatchWithDeposits3(
        bytes32 parentHash,
        uint256,
        bytes32 d1,
        bytes32 d2,
        bytes32 d3
    ) internal pure returns (L2BlockHeader[] memory batch, BlockDeposit[] memory deposits) {
        batch = _makeBatch(parentHash);
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = d1;
        ids[1] = d2;
        ids[2] = d3;
        deposits = _makeDeposits(ids);
    }
}
