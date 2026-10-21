// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {RollupAssertions} from "./Base.t.sol";
import {L2BlockHeader, L2BlockHeaderV1, BlockDeposit, BatchStatus} from "../../contracts/interfaces/rollup/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/rollup/IRollup.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";

contract FinalizeBatchesTest is RollupAssertions {
    function _toV1(L2BlockHeader[] memory full) internal pure returns (L2BlockHeaderV1[] memory v1) {
        v1 = new L2BlockHeaderV1[](full.length);
        for (uint256 i = 0; i < full.length; ++i) {
            v1[i] = L2BlockHeaderV1({
                blockHash: full[i].blockHash,
                withdrawalRoot: full[i].withdrawalRoot,
                depositRoot: full[i].depositRoot
            });
        }
    }

    // ============ finalizeBatches — happy path ============

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

        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        bytes32 lastHash2 = _lastBlockHash(lastHash1);        uint256 batch3 = _acceptBatch(lastHash2, 0);
        _submitBlobs(batch3, 0);
        _preconfirmBatch(batch3);

        vm.roll(block.number + FINALIZATION_DELAY + 1);

        uint256 finalized = rollup.finalizeBatches(batch3);
        assertEq(finalized, 3);
        assertTrue(rollup.isBatchFinalized(batch1));
        assertTrue(rollup.isBatchFinalized(batch2));
        assertTrue(rollup.isBatchFinalized(batch3));
    }

    function test_finalizeBatches_partialThenComplete() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        _preconfirmBatch(batch1);

        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        bytes32 lastHash2 = _lastBlockHash(lastHash1);        uint256 batch3 = _acceptBatch(lastHash2, 0);
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

        // lastFinalizedBatchIndex = batch1 = 1, from = 2, toBatchIndex = 1
        // for (i = 2; i <= 1; ...) — loop body never executes
        uint256 finalized2 = rollup.finalizeBatches(batch1);
        assertEq(finalized2, 0);
    }

    // ============ finalizeBatches — early stop ============

    function test_finalizeBatches_returnsZeroWhenNoneEligible() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        _preconfirmBatch(batch1);

        // finalization delay not passed
        uint256 finalized = rollup.finalizeBatches(batch1);
        assertEq(finalized, 0);
    }

    function test_finalizeBatches_stopsEarlyWhenNotEligible() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        _preconfirmBatch(batch1);

        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        vm.roll(block.number + FINALIZATION_DELAY + 1);

        bytes32 lastHash2 = _lastBlockHash(lastHash1);        uint256 batch3 = _acceptBatch(lastHash2, 0);
        _submitBlobs(batch3, 0);
        _preconfirmBatch(batch3);
        // batch3 accepted at current block — finalization delay not passed

        uint256 finalized = rollup.finalizeBatches(batch3);
        assertEq(finalized, 2);
        assertTrue(rollup.isBatchFinalized(batch1));
        assertTrue(rollup.isBatchFinalized(batch2));
        assertFalse(rollup.isBatchFinalized(batch3));
    }

    function test_finalizeBatches_stopsWhenBatchNotPreconfirmed() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        // batch1 left in Accepted status intentionally — not preconfirmed

        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);        uint256 batch2 = _acceptBatch(lastHash1, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        vm.roll(block.number + FINALIZATION_DELAY + 1);

        // batch1 is Accepted (not Preconfirmed) — _tryFinalizeBatch returns false,
        // loop stops before reaching batch2
        uint256 finalized = rollup.finalizeBatches(batch2);
        assertEq(finalized, 0);
    }

    // ============ finalizeBatches — reverts ============

    function test_RevertIf_finalizeBatches_invalidBatchIndex() public {
        // nextBatchIndex = 1 (no batches accepted yet). finalizeBatches requires
        // toBatchIndex < nextBatchIndex, so both args in the error are 1:
        // InvalidBatchIndex(providedBatchIndex=1, currentBatchIndex=1).
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchIndex.selector, uint256(1), uint256(1)));
        rollup.finalizeBatches(1);
    }

    // ============ finalizeWithProofs — happy path ============

    function test_finalizeWithProofs_allBlocksProven() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        L2BlockHeader[] memory headers = _makeBatch(lastHash);
        uint256 batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.commitBatch(_computeBatchRoot(headers), lastHash, headers[headers.length - 1].blockHash, uint24(headers.length), new BlockDeposit[](0), 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        // Challenge and resolve each block sequentially to populate provenBlocks.
        // resolveChallenge returns the batch to Preconfirmed after each pair because
        // batchChallengedBlocks.length == batchProvenBlocks.length after each resolve,
        // so the next challengeBlock sees Preconfirmed status.
        for (uint256 i = 0; i < headers.length; i++) {
            MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, i);
            vm.deal(challenger, CHALLENGE_DEPOSIT);
            vm.prank(challenger);
            rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[i], proof);

            vm.prank(prover);
            rollup.resolveBlockChallenge(batchIndex, headers[i], proof, "");
        }

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Preconfirmed));

        rollup.finalizeWithProofs(batchIndex, _toV1(headers));
        assertTrue(rollup.isBatchFinalized(batchIndex));
    }

    // ============ finalizeWithProofs — reverts ============

    function test_RevertIf_finalizeWithProofs_notPreconfirmed() public {
        L2BlockHeader[] memory headers = _makeBatch(GENESIS_HASH);
        uint256 batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.commitBatch(_computeBatchRoot(headers), GENESIS_HASH, headers[headers.length - 1].blockHash, uint24(headers.length), new BlockDeposit[](0), 1);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchStatus.selector, batchIndex, uint8(BatchStatus.Committed)));
        rollup.finalizeWithProofs(batchIndex, _toV1(headers));
    }

    function test_RevertIf_finalizeWithProofs_wrongSequentialOrder() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        _preconfirmBatch(batch1);

        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);        uint256 batch2 = _acceptBatch(lastHash, 0);
        _submitBlobs(batch2, 0);
        _preconfirmBatch(batch2);

        // headers2 content does not matter — InvalidBatchIndex is checked before
        // batchRoot verification, so the revert fires regardless of header values
        L2BlockHeader[] memory headers2 = _makeBatch(lastHash);

        // batch2 = 2, lastFinalizedBatchIndex = 0 → expected = lastFinalizedBatchIndex+1 = 1
        // batch1 == 1 here only because lastFinalizedBatchIndex starts at 0
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchIndex.selector, batch2, batch1));
        rollup.finalizeWithProofs(batch2, _toV1(headers2));
    }

    function test_RevertIf_finalizeWithProofs_wrongHeaders() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);        uint256 batchIndex = _acceptBatch(lastHash, 0);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        L2BlockHeader[] memory wrongHeaders = _makeBatch(keccak256("wrong"));

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBlockProof.selector));
        rollup.finalizeWithProofs(batchIndex, _toV1(wrongHeaders));
    }

    function test_finalizeBatches_skipsAlreadyFinalizedBatch() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        _preconfirmBatch(batch1);
        vm.roll(block.number + FINALIZATION_DELAY + 1);

        uint256 finalized1 = rollup.finalizeBatches(batch1);
        assertEq(finalized1, 1);
        assertTrue(rollup.isBatchFinalized(batch1));

        // Second call returns 0 — already finalized, no-op
        uint256 finalized2 = rollup.finalizeBatches(batch1);
        assertEq(finalized2, 0);
        assertTrue(rollup.isBatchFinalized(batch1));
    }

    function test_RevertIf_preconfirmBatch_rollupCorrupted() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);        uint256 batch2 = _acceptBatch(lastHash, 0);
        _submitBlobs(batch2, 0);

        // Let batch1's submitBlobsWindow expire to corrupt the rollup
        vm.roll(block.number + SUBMIT_BLOBS_WINDOW + 1);
        _assertRollupCorrupted();

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.RollupCorrupted.selector));
        vm.prank(preconfirmer);
        rollup.preconfirmBatch(address(nitroVerifier), batch2, DUMMY_SIGNATURE);
    }

    function test_RevertIf_preconfirmBatch_wrongBatchStatus() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);

        // batch1 is in Committed status (blobs not submitted)
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchStatus.selector, batch1, uint8(BatchStatus.Committed)));
        vm.prank(preconfirmer);
        rollup.preconfirmBatch(address(nitroVerifier), batch1, DUMMY_SIGNATURE);
    }

    function test_RevertIf_finalizeWithProofs_blockNotProven() public {
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        L2BlockHeader[] memory headers = _makeBatch(lastHash);
        uint256 batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.commitBatch(_computeBatchRoot(headers), lastHash, headers[headers.length - 1].blockHash, uint24(headers.length), new BlockDeposit[](0), 1);
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        bytes32 commitment = _computeCommitment(headers[0]);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.BlockNotProven.selector, commitment));
        rollup.finalizeWithProofs(batchIndex, _toV1(headers));
    }

    // ============ finalizeBatches — challenge-window fast-path ============

    function test_finalizeBatches_finalizesAfterChallengeWindowWithoutChallenges() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        _preconfirmBatch(batch1);

        // Past challenge window, well before finalization delay.
        vm.roll(block.number + CHALLENGE_WINDOW + 1);

        uint256 finalized = rollup.finalizeBatches(batch1);
        assertEq(finalized, 1, "should finalize on fast-path");
        assertTrue(rollup.isBatchFinalized(batch1));
    }

    function test_finalizeBatches_finalizesAfterChallengeWindowWithAllChallengesResolved() public {
        bytes32 lastHash = GENESIS_HASH;
        L2BlockHeader[] memory headers = _makeBatch(lastHash);
        uint256 batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.commitBatch(
            _computeBatchRoot(headers),
            lastHash,
            headers[headers.length - 1].blockHash,
            uint24(headers.length),
            new BlockDeposit[](0),
            1
        );
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        // Challenge each block sequentially and resolve before opening the next, so the
        // status returns to Preconfirmed (matches test_finalizeWithProofs_allBlocksProven).
        for (uint256 i = 0; i < headers.length; ++i) {
            MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, i);
            vm.deal(challenger, CHALLENGE_DEPOSIT);
            vm.prank(challenger);
            rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[i], proof);
            vm.prank(prover);
            rollup.resolveBlockChallenge(batchIndex, headers[i], proof, "");
        }
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Preconfirmed));

        vm.roll(block.number + CHALLENGE_WINDOW + 1);

        uint256 finalized = rollup.finalizeBatches(batchIndex);
        assertEq(finalized, 1, "should finalize on fast-path with all challenges resolved");
        assertTrue(rollup.isBatchFinalized(batchIndex));
    }

    function test_finalizeBatches_doesNotFinalizeAtChallengeWindowBoundary() public {
        uint256 batch1 = _acceptBatch(GENESIS_HASH, 0);
        _submitBlobs(batch1, 0);
        _preconfirmBatch(batch1);

        // Exactly at acceptedAtBlock + CHALLENGE_WINDOW — strict-greater-than gate must reject.
        uint256 acceptedAtBlock = rollup.getBatch(batch1).acceptedAtBlock;
        vm.roll(acceptedAtBlock + CHALLENGE_WINDOW);

        uint256 finalized = rollup.finalizeBatches(batch1);
        assertEq(finalized, 0, "must not finalize at exact boundary");
        assertFalse(rollup.isBatchFinalized(batch1));
    }

    function test_finalizeBatches_finalizesAfterChallengeWindowWithBatchRootResolved() public {
        bytes32 lastHash = GENESIS_HASH;
        L2BlockHeader[] memory headers = _makeBatch(lastHash);
        uint256 batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.commitBatch(
            _computeBatchRoot(headers),
            lastHash,
            headers[headers.length - 1].blockHash,
            uint24(headers.length),
            new BlockDeposit[](0),
            1
        );
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        // Open a batch-root challenge — status flips Preconfirmed → Challenged.
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.prank(challenger);
        rollup.challengeBatchRoot{value: CHALLENGE_DEPOSIT}(batchIndex);
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Challenged));

        // Resolve — status restored unconditionally to previousStatus (= Preconfirmed).
        // Different code path from resolveBlockChallenge, which restores only after every
        // block challenge in the batch is proven.
        vm.prank(prover);
        rollup.resolveBatchRootChallenge(batchIndex, _toV1(headers));
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Preconfirmed));

        vm.roll(block.number + CHALLENGE_WINDOW + 1);

        uint256 finalized = rollup.finalizeBatches(batchIndex);
        assertEq(finalized, 1, "should finalize on fast-path with batch-root resolved");
        assertTrue(rollup.isBatchFinalized(batchIndex));
    }

    function test_finalizeBatches_doesNotFinalizeWhileBatchChallenged() public {
        bytes32 lastHash = GENESIS_HASH;
        L2BlockHeader[] memory headers = _makeBatch(lastHash);
        uint256 batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.commitBatch(
            _computeBatchRoot(headers),
            lastHash,
            headers[headers.length - 1].blockHash,
            uint24(headers.length),
            new BlockDeposit[](0),
            1
        );
        _submitBlobs(batchIndex, 0);
        _preconfirmBatch(batchIndex);

        // Open a challenge but do not resolve — status stays Challenged.
        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], proof);
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Challenged));

        // Past challenge window — but the batch is corrupted (Challenged + window expired).
        // _tryFinalizeBatch must reject on the status guard, not finalize.
        vm.roll(block.number + CHALLENGE_WINDOW + 1);
        uint256 finalized = rollup.finalizeBatches(batchIndex);
        assertEq(finalized, 0, "Challenged batch must not finalize via fast-path");
        assertFalse(rollup.isBatchFinalized(batchIndex));
    }
}
