// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RollupBase} from "./Base.t.sol";
import {L2BlockHeader} from "../../contracts/interfaces/IRollupTypes.sol";
import {BatchStatus} from "../../contracts/interfaces/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";

import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

contract ForceRevertPaginatedTest is RollupBase {
    function _challengeThenResolve(uint256 batchIndex, L2BlockHeader memory header, MerkleTree.MerkleProof memory proof) internal {
        _challengeBlock(batchIndex, header, proof);
        vm.prank(prover);
        rollup.resolveChallenge(batchIndex, header, proof, address(nitroVerifier), DUMMY_SIGNATURE, "");
    }

    function _createPreconfirmedBatch(bytes32 parentHash) internal returns (uint256 batchIndex, L2BlockHeader[] memory headers) {
        batchIndex = _acceptBatch(parentHash, 0);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);
        headers = _makeBatch(parentHash);
    }

    function test_forceRevertBatchPaginated_refundsExcessOnEarlyReturn() public {
        // Create a preconfirmed batch.
        uint256 batchIndex = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        // Build batch headers for commitments/proofs.
        L2BlockHeader[] memory headers = _makeBatch(GENESIS_HASH);

        // Challenge header[0], then resolve it so it's in _batchChallengedBlocks but not active in _challenges.
        MerkleTree.MerkleProof memory proof0 = _buildMerkleProof(headers, 0);
        _challengeThenResolve(batchIndex, headers[0], proof0);

        // Challenge header[1] but do NOT resolve it. This is the "active" challenge that keeps the batch Challenged.
        MerkleTree.MerkleProof memory proof1 = _buildMerkleProof(headers, 1);
        _challengeBlock(batchIndex, headers[1], proof1);

        // Sanity: batch should be Challenged and claimable challenger reward should still be 0
        // because we only resolved the first challenge.
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Challenged));
        assertEq(rollup.claimableChallengerReward(challenger), 0);

        // Now call paginated force revert with tighter maxChallengesPerBatch so it early-returns
        // after processing only the already-resolved challengedBlocks[0].
        uint256 balBefore = address(rollup).balance;
        // expected incentive-fee consumed in this chunk is 0.
        uint256 overpay = 2 ether;
        vm.deal(admin, overpay);
        vm.prank(admin);
        rollup.forceRevertBatchPaginated{value: overpay}(batchIndex, 1, 1);

        // Surplus funding should be refunded, so the rollup balance must be unchanged.
        assertEq(address(rollup).balance, balBefore);

        // Emergency session should remain in progress (rollup treated as corrupted).
        assertTrue(rollup.isRollupCorrupted());
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Challenged));
    }

    function test_forceRevertBatchPaginated_revertsOnMismatchedSessionIndex() public {
        (uint256 batchA,) = _createPreconfirmedBatch(GENESIS_HASH);
        bytes32 lastHashA = rollup.lastBlockHashInBatch(batchA);
        (uint256 batchB,) = _createPreconfirmedBatch(lastHashA);

        // Start paginated emergency session from batchA.
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        rollup.forceRevertBatchPaginated{value: 1 ether}(batchA, 1, 1);

        // Calling with a different fromBatchIndex while a session is active must revert.
        vm.deal(admin, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchIndex.selector, batchB, batchA));
        vm.prank(admin);
        rollup.forceRevertBatchPaginated{value: 1 ether}(batchB, 1, 1);
    }

    function test_forceRevertBatchPaginated_refundsExcessOnProvenEarlyReturn() public {
        // Create a preconfirmed batch and resolve two challenges sequentially
        // so challenged/proven arrays both have length 2.
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _createPreconfirmedBatch(GENESIS_HASH);

        MerkleTree.MerkleProof memory proof0 = _buildMerkleProof(headers, 0);
        _challengeThenResolve(batchIndex, headers[0], proof0);

        MerkleTree.MerkleProof memory proof1 = _buildMerkleProof(headers, 1);
        _challengeThenResolve(batchIndex, headers[1], proof1);

        // First chunk: exits early in challenged phase (cursor 0 -> 1).
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        rollup.forceRevertBatchPaginated{value: 1 ether}(batchIndex, 1, 1);

        // Second chunk: challenged phase completes (cursor 1 -> 2),
        // then exits early in proven phase (cursor 0 -> 1).
        uint256 balBefore = address(rollup).balance;
        vm.deal(admin, 2 ether);
        vm.prank(admin);
        rollup.forceRevertBatchPaginated{value: 2 ether}(batchIndex, 1, 1);

        // No incentives consumed in this path, so overpay must be refunded.
        assertEq(address(rollup).balance, balBefore);
        assertTrue(rollup.isRollupCorrupted());
    }

    function test_forceRevertBatchPaginated_refundsExcessOnFullCompletion() public {
        // No challenges/proofs in this batch; one call can fully complete pagination.
        (uint256 batchIndex,) = _createPreconfirmedBatch(GENESIS_HASH);

        uint256 balBefore = address(rollup).balance;
        vm.deal(admin, 3 ether);
        vm.prank(admin);
        rollup.forceRevertBatchPaginated{value: 3 ether}(batchIndex, 10, 10);

        // Batch range fully reverted and excess value refunded.
        assertEq(address(rollup).balance, balBefore);
        assertEq(rollup.nextBatchIndex(), batchIndex);
    }
}
