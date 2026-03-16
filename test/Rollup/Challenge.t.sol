// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// NOTE: challengeBlock requires Preconfirmed status and sets it to Challenged —
// only one active challenge per batch is possible through the public API.
// Multi-challenge partial resolution is therefore not testable.

import {RollupBase} from "./Base.t.sol";
import {L2BlockHeader, BatchStatus, BatchRecord, ChallengeRecord} from "../../contracts/interfaces/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

contract ChallengeTest is RollupBase {
    function _preconfirmedBatchWithHeaders(bytes32 parentHash) internal returns (uint256 batchIndex, L2BlockHeader[] memory headers) {
        headers = _makeBatch(parentHash);
        batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.acceptNextBatch(headers, 0);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);
    }

    function _resolveChallenge(uint256 batchIndex, L2BlockHeader memory header, MerkleTree.MerkleProof memory proof) internal {
        vm.prank(prover);
        rollup.resolveChallenge(batchIndex, header, proof, address(nitroVerifier), DUMMY_SIGNATURE, "");
    }

    // ============ Challenge basics ============

    function test_challengeBlock_preconfirmed_setsStatusAndRecordsChallengeData() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);

        uint256 expectedDeadline = block.number + CHALLENGE_WINDOW;
        _challengeBlock(batchIndex, headers[0], proof);

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Challenged));

        bytes32 commitment = _computeCommitment(headers[0]);
        ChallengeRecord memory rec = rollup.getChallenge(commitment);
        assertEq(rec.batchIndex, batchIndex);
        assertEq(rec.deposit, CHALLENGE_DEPOSIT);
        assertEq(rec.challenger, challenger);
        assertEq(rec.deadline, expectedDeadline);

        bytes32[] memory challenged = rollup.batchChallengedBlocks(batchIndex);
        assertEq(challenged.length, 1);
        assertEq(challenged[0], commitment);

        assertEq(rollup.challengeQueue().length, 1);
    }

    function test_revert_challengeBlock_notPreconfirmed_InvalidBatchStatus() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        L2BlockHeader[] memory headers = _makeBatch(GENESIS_HASH);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);

        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchStatus.selector, batchIndex, uint8(BatchStatus.HeadersSubmitted)));
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], proof);
    }

    function test_revert_challengeBlock_wrongDeposit_IncorrectChallengeDeposit() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);

        vm.deal(challenger, 0.5 ether);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.IncorrectChallengeDeposit.selector, CHALLENGE_DEPOSIT, 0.5 ether));
        vm.prank(challenger);
        rollup.challengeBlock{value: 0.5 ether}(batchIndex, headers[0], proof);
    }

    function test_revert_challengeBlock_invalidProof_InvalidBlockProof() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);

        MerkleTree.MerkleProof memory badProof = _buildMerkleProof(headers, 1);
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBlockProof.selector));
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], badProof);
    }

    function test_revert_challengeBlock_provenBlock_BlockAlreadyProven() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);

        _challengeBlock(batchIndex, headers[0], proof);
        _resolveChallenge(batchIndex, headers[0], proof);
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Preconfirmed));

        bytes32 commitment = _computeCommitment(headers[0]);
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.BlockAlreadyProven.selector, commitment));
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], proof);
    }

    function test_revert_challengeBlock_corrupted_RollupCorrupted() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], proof);
    }

    function test_revert_challengeBlock_tooLate_ChallengeTooLate() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);

        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;
        // ChallengeTooLate fires when block.number >= acceptedAtBlock + challengeWindow
        vm.roll(acceptedAt + CHALLENGE_WINDOW);

        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ChallengeTooLate.selector, batchIndex));
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], proof);
    }

    // ============ Resolve challenge ============

    function test_resolveChallenge_provesBlock() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        _resolveChallenge(batchIndex, headers[0], proof);

        bytes32 commitment = _computeCommitment(headers[0]);
        assertTrue(rollup.isBlockProven(commitment));
        assertEq(rollup.challengeQueue().length, 0);
    }

    function test_resolveChallenge_returnsToPreconfirmed() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Challenged));

        _resolveChallenge(batchIndex, headers[0], proof);

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Preconfirmed));
    }

    function test_resolveChallenge_awardsProverDeposit() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        _resolveChallenge(batchIndex, headers[0], proof);

        _assertProverWithdrawable(prover, CHALLENGE_DEPOSIT);
    }

    function test_revert_resolveChallenge_unchallenged_BlockNotChallenged() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);

        bytes32 commitment = _computeCommitment(headers[0]);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.BlockNotChallenged.selector, commitment));
        _resolveChallenge(batchIndex, headers[0], proof);
    }

    function test_revert_resolveChallenge_afterResolve_BlockNotChallenged() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);
        _resolveChallenge(batchIndex, headers[0], proof);

        bytes32 commitment = _computeCommitment(headers[0]);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.BlockNotChallenged.selector, commitment));
        _resolveChallenge(batchIndex, headers[0], proof);
    }

    // ============ Heap priority queue ============

    function test_heap_twoChallengeDifferentBlocks_peekReturnsEarlierDeadline() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchA, L2BlockHeader[] memory headersA) = _preconfirmedBatchWithHeaders(lastHash1);

        // Roll before accepting batchB — so batchB gets a later acceptedAtBlock
        // and therefore a later deadline (acceptedAtBlock + CHALLENGE_WINDOW)
        vm.roll(block.number + 20);

        bytes32 lastHash2 = rollup.lastBlockHashInBatch(batchA);
        (uint256 batchB, L2BlockHeader[] memory headersB) = _preconfirmedBatchWithHeaders(lastHash2);

        MerkleTree.MerkleProof memory proofA = _buildMerkleProof(headersA, 0);
        _challengeBlock(batchA, headersA[0], proofA);
        bytes32 commitmentA = _computeCommitment(headersA[0]);
        uint256 deadlineA = rollup.getChallenge(commitmentA).deadline;

        MerkleTree.MerkleProof memory proofB = _buildMerkleProof(headersB, 0);
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchB, headersB[0], proofB);
        bytes32 commitmentB = _computeCommitment(headersB[0]);
        uint256 deadlineB = rollup.getChallenge(commitmentB).deadline;

        assertTrue(deadlineA < deadlineB);
        assertEq(rollup.challengeQueue().length, 2);
        assertEq(rollup.challengeQueue()[0], commitmentA);
    }

    function test_heap_resolveEarlier_peekAdvancesToNext() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchA, L2BlockHeader[] memory headersA) = _preconfirmedBatchWithHeaders(lastHash1);
        bytes32 lastHash2 = rollup.lastBlockHashInBatch(batchA);
        (uint256 batchB, L2BlockHeader[] memory headersB) = _preconfirmedBatchWithHeaders(lastHash2);

        MerkleTree.MerkleProof memory proofA = _buildMerkleProof(headersA, 0);
        _challengeBlock(batchA, headersA[0], proofA);

        vm.roll(block.number + 20);

        MerkleTree.MerkleProof memory proofB = _buildMerkleProof(headersB, 0);
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchB, headersB[0], proofB);
        bytes32 commitmentB = _computeCommitment(headersB[0]);

        _resolveChallenge(batchA, headersA[0], proofA);

        assertEq(rollup.challengeQueue().length, 1);
        assertEq(rollup.challengeQueue()[0], commitmentB);
    }

    function test_heap_forceRevert_clearsAllChallengesFromQueue() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        assertEq(rollup.challengeQueue().length, 1);

        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee);
        vm.prank(admin);
        rollup.forceRevertBatch{value: fee}(batchIndex);

        assertEq(rollup.challengeQueue().length, 0);
    }

    function test_heap_expiredDeadline_corruptsRollup() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        uint256 deadline = rollup.getChallenge(_computeCommitment(headers[0])).deadline;

        _assertRollupHealthy();

        vm.roll(deadline + 1);

        _assertRollupCorrupted();
    }

    // ============ Reward withdrawals ============

    function test_withdrawChallengerReward_afterForceRevert_paysDepositPlusIncentive() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee);
        vm.prank(admin);
        rollup.forceRevertBatch{value: fee}(batchIndex);

        _assertChallengerWithdrawable(challenger, CHALLENGE_DEPOSIT + fee);

        uint256 balBefore = challenger.balance;
        vm.prank(challenger);
        rollup.withdrawChallengerReward();

        assertEq(challenger.balance, balBefore + CHALLENGE_DEPOSIT + fee);
        _assertChallengerWithdrawable(challenger, 0);
    }

    function test_withdrawProofReward_afterResolve_paysDeposit() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);
        _resolveChallenge(batchIndex, headers[0], proof);

        _assertProverWithdrawable(prover, CHALLENGE_DEPOSIT);

        uint256 balBefore = prover.balance;
        vm.prank(prover);
        rollup.withdrawProofReward();

        assertEq(prover.balance, balBefore + CHALLENGE_DEPOSIT);
        _assertProverWithdrawable(prover, 0);
    }

    function test_revert_withdrawChallengerReward_noBalance_NothingToWithdraw() public {
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.NothingToWithdraw.selector));
        vm.prank(challenger);
        rollup.withdrawChallengerReward();
    }

    function test_revert_withdrawProofReward_noBalance_NothingToWithdraw() public {
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.NothingToWithdraw.selector));
        vm.prank(prover);
        rollup.withdrawProofReward();
    }
}
