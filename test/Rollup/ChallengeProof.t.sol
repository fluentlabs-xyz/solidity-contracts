// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {RollupBase} from "./Base.t.sol";

contract RollupChallengeProofTest is RollupBase {
    function setUp() public {
        _deployMockRollup({
            batchSize_: 2,
            challengeDepositAmount_: 10000,
            challengeBlockCount_: 1,
            approveBlockCount_: 1,
            acceptDepositDeadline_: 10,
            incentiveFee_: 0
        });
    }

    function _acceptChallengeableBatch()
        internal
        returns (Rollup.BlockCommitment[] memory batch, MerkleTree.MerkleProof memory blockProofForFirst, bytes32 firstCommitmentHash)
    {
        batch = new Rollup.BlockCommitment[](2);
        bytes32 blockHash1 = keccak256("challenge-batch-1");
        bytes32 blockHash2 = keccak256("challenge-batch-2");

        batch[0] = _buildCommitment(MOCK_GENESIS_HASH, blockHash1, ZERO_HASH, ZERO_HASH);
        batch[1] = _buildCommitment(blockHash1, blockHash2, ZERO_HASH, ZERO_HASH);

        vm.prank(SEQUENCER);
        // In tests we run with daCheck disabled, so blob index is ignored.
        rollup.acceptNextBatch(batch, new Rollup.DepositsInBlock[](0), 0);

        bytes32 firstLeaf = _commitmentHash(batch[0]);
        bytes32 secondLeaf = _commitmentHash(batch[1]);

        firstCommitmentHash = firstLeaf;
        blockProofForFirst = _proofForTwoLeaves(0, secondLeaf);
    }

    function test_challengeAndProof_clearsQueueAndMarksProven() public {
        (
            Rollup.BlockCommitment[] memory batch,
            MerkleTree.MerkleProof memory blockProofForFirst,
            bytes32 firstCommitmentHash
        ) = _acceptChallengeableBatch();

        vm.deal(CHALLENGER, 10000);
        vm.prank(CHALLENGER);
        rollup.challengeBlockCommitment{value: 10000}(1, batch[0], blockProofForFirst);

        bytes32[] memory queueAfterChallenge = rollup.getChallengeQueue();
        assertEq(queueAfterChallenge.length, 1, "challenge queue must contain one item");
        assertEq(queueAfterChallenge[0], firstCommitmentHash, "wrong challenged hash");

        vm.prank(PROOF_PROVIDER);
        rollup.proofBlockCommitment(1, batch[0], 0, hex"1234", blockProofForFirst);

        bytes32[] memory queueAfterProof = rollup.getChallengeQueue();
        assertEq(queueAfterProof.length, 0, "challenge queue should be empty");
        assertEq(rollup.provenBlockCommitment(firstCommitmentHash), true, "commitment not marked as proven");
    }

    function test_proofReward_usesPullPayment() public {
        (
            Rollup.BlockCommitment[] memory batch,
            MerkleTree.MerkleProof memory blockProofForFirst,
            bytes32 ignoredCommitmentHash
        ) = _acceptChallengeableBatch();
        ignoredCommitmentHash;

        vm.deal(CHALLENGER, 10000);
        vm.prank(CHALLENGER);
        rollup.challengeBlockCommitment{value: 10000}(1, batch[0], blockProofForFirst);

        vm.deal(PROOF_PROVIDER, 1);
        uint256 proofProviderBefore = PROOF_PROVIDER.balance;

        vm.prank(PROOF_PROVIDER);
        rollup.proofBlockCommitment(1, batch[0], 0, hex"1234", blockProofForFirst);

        assertEq(PROOF_PROVIDER.balance, proofProviderBefore, "proof should not push ETH immediately");
        assertEq(rollup.proverReadyForWithdrawal(PROOF_PROVIDER), 10000, "proof reward not accrued");

        vm.prank(PROOF_PROVIDER);
        rollup.withdrawProofReward();

        assertEq(PROOF_PROVIDER.balance, proofProviderBefore + 10000, "withdraw did not transfer proof reward");
        assertEq(rollup.proverReadyForWithdrawal(PROOF_PROVIDER), 0, "proof reward should be cleared after withdrawal");
    }

    function test_rollupCorrupted_thenForceRevert_resetsState() public {
        (
            Rollup.BlockCommitment[] memory batch,
            MerkleTree.MerkleProof memory blockProofForFirst,
            bytes32 ignoredCommitmentHash
        ) = _acceptChallengeableBatch();
        ignoredCommitmentHash;

        vm.deal(CHALLENGER, 10000);
        vm.prank(CHALLENGER);
        rollup.challengeBlockCommitment{value: 10000}(1, batch[0], blockProofForFirst);

        assertEq(rollup.rollupCorrupted(), false, "must not be corrupted before deadline");

        vm.roll(block.number + 2);
        assertEq(rollup.rollupCorrupted(), true, "must be corrupted after deadline");

        rollup.forceRevertBatch(1);

        assertEq(rollup.nextBatchIndex(), 1, "nextBatchIndex not reverted");
        assertEq(rollup.rollupCorrupted(), false, "corruption state must be cleared");
        assertEq(rollup.acceptedBatchHash(1), bytes32(0), "accepted batch hash must be cleared");
    }

    function test_challenge_revertsWhenDepositTooLow() public {
        (
            Rollup.BlockCommitment[] memory batch,
            MerkleTree.MerkleProof memory blockProofForFirst,
            bytes32 ignoredCommitmentHash
        ) = _acceptChallengeableBatch();
        ignoredCommitmentHash;

        vm.deal(CHALLENGER, 9999);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InsufficientChallengeDeposit.selector, 10000, 9999));
        vm.prank(CHALLENGER);
        rollup.challengeBlockCommitment{value: 9999}(1, batch[0], blockProofForFirst);
    }

    function test_challenge_revertsWhenDepositTooHigh() public {
        (
            Rollup.BlockCommitment[] memory batch,
            MerkleTree.MerkleProof memory blockProofForFirst,
            bytes32 ignoredCommitmentHash
        ) = _acceptChallengeableBatch();
        ignoredCommitmentHash;

        vm.deal(CHALLENGER, 10001);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ExcessiveChallengeDeposit.selector, 10000, 10001));
        vm.prank(CHALLENGER);
        rollup.challengeBlockCommitment{value: 10001}(1, batch[0], blockProofForFirst);
    }

    function test_withdrawProofReward_revertsWhenNothingToWithdraw() public {
        vm.expectRevert(IRollupErrors.NothingToWithdraw.selector);
        vm.prank(PROOF_PROVIDER);
        rollup.withdrawProofReward();
    }
}
