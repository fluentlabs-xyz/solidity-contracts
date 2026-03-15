// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RollupBase} from "./Base.t.sol";
import {L2BlockHeader, BatchStatus, BatchRecord} from "../../contracts/interfaces/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

contract FinalizeBatchesTest is RollupBase {
    // ============ finalizeBatches ============

    function test_finalizeBatches_singleBatch() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        _preconfirmBatch(batch1);
        vm.roll(block.number + FINALIZATION_DELAY + 1);

        uint256 finalized = rollup.finalizeBatches(batch1);
        assertEq(finalized, 1);
        assertTrue(rollup.isBatchFinalized(batch1));
    }

    function test_finalizeBatches_multipleBatches() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        _preconfirmBatch(batch1);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        bytes32 lastHash2 = rollup.lastBlockHashInBatch(batch2);
        uint256 batch3 = _acceptBatch(lastHash2, 0);
        _submitBlobs(batch3, 0);
        _preconfirmBatch(batch3);

        vm.roll(block.number + FINALIZATION_DELAY + 1);

        uint256 finalized = rollup.finalizeBatches(batch3);
        assertEq(finalized, 3);
        assertTrue(rollup.isBatchFinalized(batch1));
        assertTrue(rollup.isBatchFinalized(batch2));
        assertTrue(rollup.isBatchFinalized(batch3));
    }

    function test_finalizeBatches_stopsEarlyWhenNotEligible() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        _preconfirmBatch(batch1);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        vm.roll(block.number + FINALIZATION_DELAY + 1);

        bytes32 lastHash2 = rollup.lastBlockHashInBatch(batch2);
        uint256 batch3 = _acceptBatch(lastHash2, 0);
        _submitBlobs(batch3, 0);
        _preconfirmBatch(batch3);
        // batch3 accepted at current block — cooldown not passed

        uint256 finalized = rollup.finalizeBatches(batch3);
        assertEq(finalized, 2);
        assertTrue(rollup.isBatchFinalized(batch1));
        assertTrue(rollup.isBatchFinalized(batch2));
        assertFalse(rollup.isBatchFinalized(batch3));
    }

    function test_finalizeBatches_returnsZeroWhenNoneEligible() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        _preconfirmBatch(batch1);

        uint256 finalized = rollup.finalizeBatches(batch1);
        assertEq(finalized, 0);
    }

    function test_finalizeBatches_sequentialEnforcement() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        vm.roll(block.number + FINALIZATION_DELAY + 1);

        // batch1 is Accepted (not Preconfirmed) → finalizeBatches stops at batch1
        uint256 finalized = rollup.finalizeBatches(batch2);
        assertEq(finalized, 0);
    }

    function test_revert_finalizeBatches_invalidBatchIndex() public {
        // nextBatchIndex = 1 (no batches accepted yet). finalizeBatches requires
        // toBatchIndex < nextBatchIndex, so both args in the error are 1:
        // InvalidBatchIndex(providedBatchIndex=1, currentBatchIndex=1).
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchIndex.selector, uint256(1), uint256(1)));
        rollup.finalizeBatches(1);
    }

    function test_finalizeBatches_partialThenComplete() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        _preconfirmBatch(batch1);

        bytes32 lastHash1 = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        bytes32 lastHash2 = rollup.lastBlockHashInBatch(batch2);
        uint256 batch3 = _acceptBatch(lastHash2, 0);
        _submitBlobs(batch3, 0);
        _preconfirmBatch(batch3);

        vm.roll(block.number + FINALIZATION_DELAY + 1);

        uint256 finalized1 = rollup.finalizeBatches(batch1);
        assertEq(finalized1, 1);

        uint256 finalized2 = rollup.finalizeBatches(batch3);
        assertEq(finalized2, 2);
    }

    function test_finalizeBatches_alreadyFinalized() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        _preconfirmBatch(batch1);
        vm.roll(block.number + FINALIZATION_DELAY + 1);

        uint256 finalized1 = rollup.finalizeBatches(batch1);
        assertEq(finalized1, 1);

        // Call again — loop starts from lastFinalizedBatchIndex+1 = 2, toBatchIndex = 1
        // Loop condition: i <= 1 where i starts at 2 → does not execute
        uint256 finalized2 = rollup.finalizeBatches(batch1);
        assertEq(finalized2, 0);
    }

    // ============ finalizeWithProofs ============

    function test_finalizeWithProofs_allBlocksProven() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);

        L2BlockHeader[] memory headers = _makeBatch(lastHash);
        uint256 batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.acceptNextBatch(headers, 0);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        // Challenge and resolve each block sequentially to populate provenBlocks.
        // This works because resolveChallenge returns the batch to Preconfirmed after
        // each pair: batchChallengedBlocks.length == batchProvenBlocks.length after
        // each resolve, so the next challengeBlock sees Preconfirmed status.
        for (uint256 i = 0; i < headers.length; i++) {
            MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, i);
            vm.deal(challenger, CHALLENGE_DEPOSIT);
            vm.prank(challenger);
            rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[i], proof);

            vm.prank(prover);
            rollup.resolveChallenge(batchIndex, headers[i], proof, address(nitroVerifier), DUMMY_SIGNATURE, "");
        }

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Preconfirmed));

        // Finalize without cooldown via proofs
        rollup.finalizeWithProofs(batchIndex, headers);
        assertTrue(rollup.isBatchFinalized(batchIndex));
    }

    function test_revert_finalizeWithProofs_notPreconfirmed() public {
        L2BlockHeader[] memory headers = _makeBatch(GENESIS_HASH);
        uint256 batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.acceptNextBatch(headers, 0);

        vm.expectRevert(
            abi.encodeWithSelector(IRollupErrors.InvalidBatchStatus.selector, batchIndex, uint8(BatchStatus.HeadersSubmitted))
        );
        rollup.finalizeWithProofs(batchIndex, headers);
    }

    function test_revert_finalizeWithProofs_wrongSequentialOrder() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        _preconfirmBatch(batch1);

        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        uint256 batch2 = _acceptBatch(lastHash, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        L2BlockHeader[] memory headers2 = _makeBatch(lastHash);

        // batch2 = 2, lastFinalizedBatchIndex = 0, so expected = lastFinalizedBatchIndex+1 = 1.
        // batch1 == 1 here only because lastFinalizedBatchIndex starts at 0.
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchIndex.selector, batch2, batch1));
        rollup.finalizeWithProofs(batch2, headers2);
    }

    function test_revert_finalizeWithProofs_wrongHeaders() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);
        uint256 batchIndex = _acceptBatch(lastHash, 0);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        // Supply wrong headers
        L2BlockHeader[] memory wrongHeaders = _makeBatch(keccak256("wrong"));

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBlockProof.selector));
        rollup.finalizeWithProofs(batchIndex, wrongHeaders);
    }

    function test_revert_finalizeWithProofs_blockNotProven() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = rollup.lastBlockHashInBatch(batch1);

        L2BlockHeader[] memory headers = _makeBatch(lastHash);
        uint256 batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.acceptNextBatch(headers, 0);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        bytes32 commitment = _computeCommitment(headers[0]);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.BlockNotProven.selector, commitment));
        rollup.finalizeWithProofs(batchIndex, headers);
    }
}
