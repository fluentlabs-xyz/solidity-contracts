// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

// NOTE: challengeBlock requires Preconfirmed status and sets it to Challenged —
// only one active challenge per batch is possible through the public API.
// Multi-challenge partial resolution is therefore not testable.

import {RollupAssertions} from "./Base.t.sol";
import {L2BlockHeader, BlockDeposit, BatchStatus, ChallengeRecord} from "../../contracts/interfaces/rollup/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/rollup/IRollup.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {EthRejecter} from "../mocks/EthRejecter.sol";

contract ChallengeTest is RollupAssertions {
    function _preconfirmedBatchWithHeaders(bytes32 parentHash) internal returns (uint256 batchIndex, L2BlockHeader[] memory headers) {
        headers = _makeBatch(parentHash);
        batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.commitBatch(_computeBatchRoot(headers), headers[headers.length - 1].blockHash, uint24(headers.length), new BlockDeposit[](0), 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);
    }

    function _resolveBlockChallenge(uint256 batchIndex, L2BlockHeader memory header, MerkleTree.MerkleProof memory proof) internal {
        vm.prank(prover);
        rollup.resolveBlockChallenge(batchIndex, header, proof, "");
    }

    // ============ Challenge basics ============

    function test_challengeBlock_preconfirmed_setsStatusAndRecordsChallengeData() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
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

        assertEq(rollup.blockChallengeQueue().length, 1);
    }

    function test_RevertIf_challengeBlock_notPreconfirmed() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        L2BlockHeader[] memory headers = _makeBatch(GENESIS_HASH);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);

        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchStatus.selector, batchIndex, uint8(BatchStatus.Committed)));
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], proof);
    }

    function test_RevertIf_challengeBlock_submitted() public {
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batchIndex, 0);

        L2BlockHeader[] memory headers = _makeBatch(GENESIS_HASH);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);

        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchStatus.selector, batchIndex, uint8(BatchStatus.Submitted)));
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], proof);
    }

    function test_RevertIf_challengeBlock_incorrectDeposit() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);

        vm.deal(challenger, 0.5 ether);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.IncorrectChallengeDeposit.selector, CHALLENGE_DEPOSIT, 0.5 ether));
        vm.prank(challenger);
        rollup.challengeBlock{value: 0.5 ether}(batchIndex, headers[0], proof);
    }

    function test_RevertIf_challengeBlock_invalidBlockProof() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);

        MerkleTree.MerkleProof memory badProof = _buildMerkleProof(headers, 1);
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBlockProof.selector));
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], badProof);
    }

    function test_RevertIf_challengeBlock_blockAlreadyProven() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);

        _challengeBlock(batchIndex, headers[0], proof);
        _resolveBlockChallenge(batchIndex, headers[0], proof);
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Preconfirmed));

        bytes32 commitment = _computeCommitment(headers[0]);
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.BlockAlreadyProven.selector, commitment));
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], proof);
    }

    function test_RevertIf_challengeBlock_rollupCorrupted() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);

        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], proof);
    }

    function test_RevertIf_challengeBlock_challengeTooLate() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
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
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        _resolveBlockChallenge(batchIndex, headers[0], proof);

        bytes32 commitment = _computeCommitment(headers[0]);
        assertTrue(rollup.isBlockProven(commitment));
        assertEq(rollup.blockChallengeQueue().length, 0);
    }

    function test_resolveChallenge_returnsToPreconfirmed() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Challenged));

        _resolveBlockChallenge(batchIndex, headers[0], proof);

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Preconfirmed));
    }

    function test_resolveChallenge_awardsProverDeposit() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        _resolveBlockChallenge(batchIndex, headers[0], proof);

        _assertProverWithdrawable(prover, CHALLENGE_DEPOSIT);
    }

    function test_RevertIf_resolveChallenge_blockNotChallenged() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);

        bytes32 commitment = _computeCommitment(headers[0]);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.BlockNotChallenged.selector, commitment));
        _resolveBlockChallenge(batchIndex, headers[0], proof);
    }

    function test_RevertIf_resolveChallenge_alreadyResolved() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);
        _resolveBlockChallenge(batchIndex, headers[0], proof);

        bytes32 commitment = _computeCommitment(headers[0]);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.BlockNotChallenged.selector, commitment));
        _resolveBlockChallenge(batchIndex, headers[0], proof);
    }

    function test_RevertIf_resolveChallenge_callerNotProver() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, rollup.PROVER_ROLE()));
        vm.prank(user);
        rollup.resolveBlockChallenge(batchIndex, headers[0], proof, "");
    }

    // ============ Heap priority queue ============

    function test_heap_twoChallengeDifferentBlocks_peekReturnsEarlierDeadline() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);
        (uint256 batchA, L2BlockHeader[] memory headersA) = _preconfirmedBatchWithHeaders(lastHash1);

        // Roll before accepting batchB — so batchB gets a later acceptedAtBlock
        // and therefore a later deadline (acceptedAtBlock + CHALLENGE_WINDOW)
        vm.roll(block.number + 20);

        bytes32 lastHash2 = _lastBlockHash(lastHash1);
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
        assertEq(rollup.blockChallengeQueue().length, 2);
        assertEq(rollup.blockChallengeQueue()[0], commitmentA);
    }

    function test_heap_resolveEarlier_peekAdvancesToNext() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);

        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);
        (uint256 batchA, L2BlockHeader[] memory headersA) = _preconfirmedBatchWithHeaders(lastHash1);
        bytes32 lastHash2 = _lastBlockHash(lastHash1);
        (uint256 batchB, L2BlockHeader[] memory headersB) = _preconfirmedBatchWithHeaders(lastHash2);

        MerkleTree.MerkleProof memory proofA = _buildMerkleProof(headersA, 0);
        _challengeBlock(batchA, headersA[0], proofA);

        vm.roll(block.number + 20);

        MerkleTree.MerkleProof memory proofB = _buildMerkleProof(headersB, 0);
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchB, headersB[0], proofB);
        bytes32 commitmentB = _computeCommitment(headersB[0]);

        _resolveBlockChallenge(batchA, headersA[0], proofA);

        assertEq(rollup.blockChallengeQueue().length, 1);
        assertEq(rollup.blockChallengeQueue()[0], commitmentB);
    }

    function test_heap_forceRevert_clearsAllChallengesFromQueue() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        assertEq(rollup.blockChallengeQueue().length, 1);

        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee);
        vm.prank(admin);
        rollup.revertBatches{value: fee}(batchIndex);

        assertEq(rollup.blockChallengeQueue().length, 0);
    }

    function test_heap_expiredDeadline_corruptsRollup() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
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
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee);
        vm.prank(admin);
        rollup.revertBatches{value: fee}(batchIndex);

        _assertChallengerWithdrawable(challenger, CHALLENGE_DEPOSIT + fee);

        uint256 balBefore = challenger.balance;
        vm.prank(challenger);
        rollup.withdrawChallengerReward();

        assertEq(challenger.balance, balBefore + CHALLENGE_DEPOSIT + fee);
        _assertChallengerWithdrawable(challenger, 0);
    }

    function test_withdrawProofReward_afterResolve_paysDeposit() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);
        _resolveBlockChallenge(batchIndex, headers[0], proof);

        _assertProverWithdrawable(prover, CHALLENGE_DEPOSIT);

        uint256 balBefore = prover.balance;
        vm.prank(prover);
        rollup.withdrawProofReward();

        assertEq(prover.balance, balBefore + CHALLENGE_DEPOSIT);
        _assertProverWithdrawable(prover, 0);
    }

    function test_RevertIf_withdrawChallengerReward_nothingToWithdraw() public {
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.NothingToWithdraw.selector));
        vm.prank(challenger);
        rollup.withdrawChallengerReward();
    }

    function test_RevertIf_withdrawProofReward_nothingToWithdraw() public {
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.NothingToWithdraw.selector));
        vm.prank(prover);
        rollup.withdrawProofReward();
    }

    // ============ Additional revert tests ============

    function test_RevertIf_resolveChallenge_rollupCorrupted() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        bytes32 commitment = _computeCommitment(headers[0]);
        uint256 deadline = rollup.getChallenge(commitment).deadline;

        // Advance past the challenge deadline to corrupt the rollup
        vm.roll(deadline + 1);
        _assertRollupCorrupted();

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        _resolveBlockChallenge(batchIndex, headers[0], proof);
    }

    function test_RevertIf_resolveChallenge_resolutionTooLate() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        // batch2 stays Preconfirmed — acts as the first non-finalized batch so
        // _rollupCorrupted() sees Preconfirmed (no corruption check for that status).
        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        bytes32 lastHash2 = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash2);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        bytes32 commitment = _computeCommitment(headers[0]);
        uint256 deadline = rollup.getChallenge(commitment).deadline;

        // Advance past the per-challenge deadline; batch2 is Preconfirmed so
        // the corruption check does not inspect the challenge queue.
        vm.roll(deadline + 1);
        _assertRollupHealthy();

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ChallengeResolutionTooLate.selector, batchIndex, deadline, block.number));
        _resolveBlockChallenge(batchIndex, headers[0], proof);
    }

    function test_RevertIf_resolveChallenge_wrongBatchIndex() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        uint256 wrongBatchIndex = batchIndex + 1;
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchIndex.selector, wrongBatchIndex, batchIndex));
        _resolveBlockChallenge(wrongBatchIndex, headers[0], proof);
    }

    function test_RevertIf_withdrawChallengerReward_ethTransferFailed() public {
        EthRejecter rejecter = new EthRejecter();
        address rejecterAddr = address(rejecter);

        // Grant challenger role to the rejecter
        bytes32 challengerRole = rollup.CHALLENGER_ROLE();
        vm.prank(admin);
        rollup.grantRole(challengerRole, rejecterAddr);

        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        L2BlockHeader[] memory headers = _makeBatch(lastHash);
        uint256 batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.commitBatch(_computeBatchRoot(headers), headers[headers.length - 1].blockHash, uint24(headers.length), new BlockDeposit[](0), 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        MerkleTree.MerkleProof memory proof0 = _buildMerkleProof(headers, 0);
        vm.deal(rejecterAddr, CHALLENGE_DEPOSIT);
        vm.prank(rejecterAddr);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], proof0);

        // Force revert to credit the rejecter's challenger reward
        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee);
        vm.prank(admin);
        rollup.revertBatches{value: fee}(batchIndex);

        uint256 expectedReward = CHALLENGE_DEPOSIT + fee;
        assertEq(rollup.claimableChallengerReward(rejecterAddr), expectedReward);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.EthTransferFailed.selector, rejecterAddr, expectedReward));
        vm.prank(rejecterAddr);
        rollup.withdrawChallengerReward();
    }

    function test_RevertIf_withdrawProofReward_ethTransferFailed() public {
        EthRejecter rejecter = new EthRejecter();
        address rejecterAddr = address(rejecter);

        // Grant prover role to the rejecter
        bytes32 proverRole = rollup.PROVER_ROLE();
        vm.prank(admin);
        rollup.grantRole(proverRole, rejecterAddr);

        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        _challengeBlock(batchIndex, headers[0], proof);

        // Resolve challenge as the rejecter (acting as prover)
        vm.prank(rejecterAddr);
        rollup.resolveBlockChallenge(batchIndex, headers[0], proof, "");

        assertEq(rollup.claimableProofReward(rejecterAddr), CHALLENGE_DEPOSIT);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.EthTransferFailed.selector, rejecterAddr, CHALLENGE_DEPOSIT));
        vm.prank(rejecterAddr);
        rollup.withdrawProofReward();
    }
}
