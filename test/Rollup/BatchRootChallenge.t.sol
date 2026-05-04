// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {RollupAssertions} from "./Base.t.sol";
import {L2BlockHeader, BlockDeposit, BatchStatus, ChallengeRecord} from "../../contracts/interfaces/rollup/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/rollup/IRollup.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract BatchRootChallengeTest is RollupAssertions {
    // ============ Helpers ============

    function _submittedBatchWithHeaders(bytes32 parentHash) internal returns (uint256 batchIndex, L2BlockHeader[] memory headers) {
        headers = _makeBatch(parentHash);
        batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.commitBatch(_computeBatchRoot(headers), parentHash, headers[headers.length - 1].blockHash, uint24(headers.length), new BlockDeposit[](0), 1);
        _submitBlobs(batchIndex, 0);
    }

    function _preconfirmedBatchWithHeaders(bytes32 parentHash) internal returns (uint256 batchIndex, L2BlockHeader[] memory headers) {
        (batchIndex, headers) = _submittedBatchWithHeaders(parentHash);
        _preconfirmBatch(batchIndex);
    }

    function _challengeBatchRoot(uint256 batchIndex) internal {
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.prank(challenger);
        rollup.challengeBatchRoot{value: CHALLENGE_DEPOSIT}(batchIndex);
    }

    function _slice(L2BlockHeader[] memory src, uint256 from, uint256 to) internal pure returns (L2BlockHeader[] memory out) {
        out = new L2BlockHeader[](to - from);
        for (uint256 i = from; i < to; ++i) {
            out[i - from] = src[i];
        }
    }

    function _genesisHeader() internal pure returns (L2BlockHeader memory) {
        return L2BlockHeader({
            previousBlockHash: bytes32(0),
            blockHash: GENESIS_HASH,
            withdrawalRoot: ZERO_BYTES_HASH,
            depositRoot: ZERO_BYTES_HASH,
            depositCount: 0
        });
    }

    function _emptyMerkleProof() internal pure returns (MerkleTree.MerkleProof memory) {
        return MerkleTree.MerkleProof({nonce: 0, proof: ""});
    }

    function _grantProverRole(address account) internal {
        bytes32 role = rollup.PROVER_ROLE();
        vm.prank(admin);
        rollup.grantRole(role, account);
    }

    // ============ challengeBatchRoot — happy paths ============

    function test_challengeBatchRoot_submitted_setsStatusAndRecords() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex,) = _submittedBatchWithHeaders(lastHash);

        _challengeBatchRoot(batchIndex);

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Challenged), "status should be Challenged");
        ChallengeRecord memory rec = rollup.getBatchRootChallenge(batchIndex);
        assertEq(rec.batchIndex, batchIndex, "challenge batchIndex mismatch");
        assertEq(rec.deposit, CHALLENGE_DEPOSIT, "challenge deposit mismatch");
        assertEq(rec.challenger, challenger, "challenge challenger mismatch");
    }

    function test_challengeBatchRoot_preconfirmed_setsStatusAndRecords() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex,) = _preconfirmedBatchWithHeaders(lastHash);

        _challengeBatchRoot(batchIndex);

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Challenged), "status should be Challenged");
        ChallengeRecord memory rec = rollup.getBatchRootChallenge(batchIndex);
        assertEq(uint8(rec.previousStatus), uint8(BatchStatus.Preconfirmed), "previousStatus should be Preconfirmed");
    }

    // ============ challengeBatchRoot — reverts ============

    function test_RevertIf_challengeBatchRoot_committed() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        uint256 batchIndex = _acceptBatch(lastHash, 0);

        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchStatus.selector, batchIndex, uint8(BatchStatus.Committed)));
        vm.prank(challenger);
        rollup.challengeBatchRoot{value: CHALLENGE_DEPOSIT}(batchIndex);
    }

    function test_RevertIf_challengeBatchRoot_genesisBatch() public {
        // Genesis batch lives at index 0 and is Finalized at init;
        // the status guard rejects it rather than a dedicated index check.
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchStatus.selector, uint256(0), uint8(BatchStatus.Finalized)));
        vm.prank(challenger);
        rollup.challengeBatchRoot{value: CHALLENGE_DEPOSIT}(0);
    }

    function test_challengeBatchRoot_firstRealBatch_succeeds() public {
        // Batch 1 is the first real sequencer commit — batch 0 is synthetic genesis.
        // Before the genesis-batch change this was rejected by `batchIndex > 1` guard.
        (uint256 batchIndex,) = _submittedBatchWithHeaders(GENESIS_HASH);
        assertEq(batchIndex, 1, "first real batch should be index 1");

        _challengeBatchRoot(batchIndex);

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Challenged), "status should be Challenged");
    }

    function test_finalizeBatchRootChallengeResolution_firstRealBatch_againstGenesis() public {
        // End-to-end: challenge batch 1 and resolve against the synthetic genesis batch
        // committed at index 0 during initialize.
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(GENESIS_HASH);
        assertEq(batchIndex, 1);

        _challengeBatchRoot(batchIndex);

        // Single-leaf Merkle tree (genesis numberOfBlocks=1) → proof is empty, nonce=0.
        // Relies on MerkleTree.verifyMerkleProof returning true when the leaf already
        // equals the root and no proof iterations are needed.
        _resolveBatchRootInOneChunk(batchIndex, headers, _genesisHeader(), _emptyMerkleProof());

        _assertProverWithdrawable(prover, CHALLENGE_DEPOSIT);
    }

    function test_RevertIf_challengeBatchRoot_incorrectDeposit() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex,) = _submittedBatchWithHeaders(lastHash);

        vm.deal(challenger, 0.5 ether);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.IncorrectChallengeDeposit.selector, CHALLENGE_DEPOSIT, 0.5 ether));
        vm.prank(challenger);
        rollup.challengeBatchRoot{value: 0.5 ether}(batchIndex);
    }

    function test_RevertIf_challengeBatchRoot_challengeTooLate() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex,) = _preconfirmedBatchWithHeaders(lastHash);

        uint256 acceptedAt = rollup.getBatch(batchIndex).acceptedAtBlock;
        vm.roll(acceptedAt + CHALLENGE_WINDOW);

        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ChallengeTooLate.selector, batchIndex));
        vm.prank(challenger);
        rollup.challengeBatchRoot{value: CHALLENGE_DEPOSIT}(batchIndex);
    }

    function test_RevertIf_challengeBatchRoot_alreadyChallenged() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex,) = _submittedBatchWithHeaders(lastHash);

        _challengeBatchRoot(batchIndex);

        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchStatus.selector, batchIndex, uint8(BatchStatus.Challenged)));
        vm.prank(challenger);
        rollup.challengeBatchRoot{value: CHALLENGE_DEPOSIT}(batchIndex);
    }

    function test_RevertIf_challengeBatchRoot_callerNotChallenger() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex,) = _submittedBatchWithHeaders(lastHash);

        vm.deal(user, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, rollup.CHALLENGER_ROLE()));
        vm.prank(user);
        rollup.challengeBatchRoot{value: CHALLENGE_DEPOSIT}(batchIndex);
    }

    // ============ finalizeBatchRootChallengeResolution — happy path ============

    function test_finalizeBatchRootChallengeResolution_provesRootAndRewardsProver() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        L2BlockHeader[] memory batch1Headers = _makeBatch(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);

        _challengeBatchRoot(batchIndex);
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Challenged));

        L2BlockHeader memory lastBlockInPrevBatch = batch1Headers[batch1Headers.length - 1];
        MerkleTree.MerkleProof memory lastBlockProof = _buildMerkleProof(batch1Headers, batch1Headers.length - 1);

        _resolveBatchRootInOneChunk(batchIndex, headers, lastBlockInPrevBatch, lastBlockProof);

        _assertProverWithdrawable(prover, CHALLENGE_DEPOSIT);
    }

    function test_finalizeBatchRootChallengeResolution_restoresPreviousStatus() public {
        // Verifies the previousStatus restore is correctly read BEFORE the challenge
        // record delete. Submitted-then-challenged batch must return to Submitted on resolve.
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        L2BlockHeader[] memory batch1Headers = _makeBatch(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        L2BlockHeader memory lastBlockInPrevBatch = batch1Headers[batch1Headers.length - 1];
        MerkleTree.MerkleProof memory lastBlockProof = _buildMerkleProof(batch1Headers, batch1Headers.length - 1);

        _resolveBatchRootInOneChunk(batchIndex, headers, lastBlockInPrevBatch, lastBlockProof);

        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Submitted), "status should be restored to Submitted");
    }

    // ============ Chunked happy path ============

    function test_appendBatchRootResolutionChunk_twoChunks_continuesLinkage() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        L2BlockHeader[] memory batch1Headers = _makeBatch(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        // BATCH_SIZE = 4 → split 2+2.
        _appendBatchRootChunk(batchIndex, _slice(headers, 0, 2));
        _appendBatchRootChunk(batchIndex, _slice(headers, 2, 4));

        L2BlockHeader memory prevHeader = batch1Headers[batch1Headers.length - 1];
        MerkleTree.MerkleProof memory prevProof = _buildMerkleProof(batch1Headers, batch1Headers.length - 1);
        _finalizeBatchRootResolution(batchIndex, prevHeader, prevProof);

        _assertProverWithdrawable(prover, CHALLENGE_DEPOSIT);
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Submitted), "status should be restored to Submitted");
    }

    // ============ append — reverts ============

    function test_RevertIf_appendBatchRootResolutionChunk_notChallenged() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchStatus.selector, batchIndex, uint8(BatchStatus.Submitted)));
        vm.prank(prover);
        rollup.appendBatchRootResolutionChunk(batchIndex, headers);
    }

    function test_RevertIf_appendBatchRootResolutionChunk_emptyHeaders() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex,) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        L2BlockHeader[] memory empty = new L2BlockHeader[](0);
        vm.expectRevert(IRollupErrors.EmptyHeadersChunk.selector);
        vm.prank(prover);
        rollup.appendBatchRootResolutionChunk(batchIndex, empty);
    }

    function test_RevertIf_appendBatchRootResolutionChunk_leavesExceedNumberOfBlocks() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        // Submit BATCH_SIZE headers, then attempt a 5th — the cumulative cap rejects it.
        _appendBatchRootChunk(batchIndex, headers);

        L2BlockHeader[] memory extra = new L2BlockHeader[](1);
        extra[0] = L2BlockHeader({
            previousBlockHash: headers[headers.length - 1].blockHash,
            blockHash: keccak256("extra"),
            withdrawalRoot: EXAMPLE_WITHDRAWAL_ROOT,
            depositRoot: ZERO_BYTES_HASH,
            depositCount: 0
        });

        uint256 numberOfBlocks = rollup.getBatch(batchIndex).numberOfBlocks;
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.LeavesExceedNumberOfBlocks.selector, numberOfBlocks + 1, numberOfBlocks));
        vm.prank(prover);
        rollup.appendBatchRootResolutionChunk(batchIndex, extra);
    }

    function test_RevertIf_appendBatchRootResolutionChunk_chainLinkageBetweenChunks() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        _appendBatchRootChunk(batchIndex, _slice(headers, 0, 2));

        // Second chunk's first header has a wrong previousBlockHash (does not match prior chunk's tail).
        // Cross-chunk linkage shares the per-iteration check with intra-chunk, so the error
        // is reported as `InvalidBlockSequence(0, ...)` from the second chunk's i=0 iteration.
        L2BlockHeader[] memory bad = _slice(headers, 2, 4);
        bytes32 priorHash = headers[1].blockHash;
        bytes32 wrongPrev = keccak256("not-the-prior-hash");
        bad[0].previousBlockHash = wrongPrev;

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBlockSequence.selector, uint256(0), priorHash, wrongPrev));
        vm.prank(prover);
        rollup.appendBatchRootResolutionChunk(batchIndex, bad);
    }

    function test_RevertIf_appendBatchRootResolutionChunk_intraChunkLinkage() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        // Break chain linkage at index 2 (within the single chunk).
        L2BlockHeader[] memory broken = headers;
        bytes32 expectedPrev = broken[1].blockHash;
        bytes32 wrongPrev = keccak256("broken");
        broken[2].previousBlockHash = wrongPrev;

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBlockSequence.selector, uint256(2), expectedPrev, wrongPrev));
        vm.prank(prover);
        rollup.appendBatchRootResolutionChunk(batchIndex, broken);
    }

    function test_RevertIf_appendBatchRootResolutionChunk_callerNotProver() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, rollup.PROVER_ROLE()));
        vm.prank(user);
        rollup.appendBatchRootResolutionChunk(batchIndex, headers);
    }

    // ============ finalize — reverts ============

    function test_RevertIf_finalizeBatchRootChallengeResolution_notChallenged() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        L2BlockHeader[] memory batch1Headers = _makeBatch(GENESIS_HASH);
        (uint256 batchIndex,) = _submittedBatchWithHeaders(lastHash1);

        L2BlockHeader memory prevHeader = batch1Headers[batch1Headers.length - 1];
        MerkleTree.MerkleProof memory prevProof = _buildMerkleProof(batch1Headers, batch1Headers.length - 1);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchStatus.selector, batchIndex, uint8(BatchStatus.Submitted)));
        vm.prank(prover);
        rollup.finalizeBatchRootChallengeResolution(batchIndex, prevHeader, prevProof);
    }

    function test_RevertIf_finalizeBatchRootChallengeResolution_leavesNotComplete() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        L2BlockHeader[] memory batch1Headers = _makeBatch(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        // Submit only the first half; finalize should reject.
        _appendBatchRootChunk(batchIndex, _slice(headers, 0, 2));

        uint256 numberOfBlocks = rollup.getBatch(batchIndex).numberOfBlocks;
        L2BlockHeader memory prevHeader = batch1Headers[batch1Headers.length - 1];
        MerkleTree.MerkleProof memory prevProof = _buildMerkleProof(batch1Headers, batch1Headers.length - 1);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ResolutionLeavesNotComplete.selector, uint256(2), numberOfBlocks));
        vm.prank(prover);
        rollup.finalizeBatchRootChallengeResolution(batchIndex, prevHeader, prevProof);
    }

    function test_RevertIf_finalizeBatchRootChallengeResolution_wrongPreviousBatchHeader() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        L2BlockHeader[] memory batch1Headers = _makeBatch(GENESIS_HASH);
        (uint256 batchIndex,) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        // Submit a self-consistent set of headers from a *different* parent — first chunk
        // succeeds (no cross-batch check yet) but finalize must reject the mismatched anchor.
        L2BlockHeader[] memory wrongHeaders = _makeBatch(keccak256("wrong"));
        _appendBatchRootChunk(batchIndex, wrongHeaders);

        L2BlockHeader memory prevHeader = batch1Headers[batch1Headers.length - 1];
        MerkleTree.MerkleProof memory prevProof = _buildMerkleProof(batch1Headers, batch1Headers.length - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRollupErrors.InvalidLastBlockHash.selector,
                wrongHeaders[0].previousBlockHash,
                prevHeader.blockHash
            )
        );
        vm.prank(prover);
        rollup.finalizeBatchRootChallengeResolution(batchIndex, prevHeader, prevProof);
    }

    function test_RevertIf_finalizeBatchRootChallengeResolution_wrongComputedRoot() public {
        // Headers chain correctly AND link to the previous batch correctly, but the
        // computed Merkle root differs from the stored one (e.g. mutated withdrawalRoot).
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        L2BlockHeader[] memory batch1Headers = _makeBatch(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        // Mutate one withdrawalRoot — chain linkage stays intact (it depends on
        // previousBlockHash/blockHash only) but commitments and root diverge.
        bytes32 storedRoot = rollup.getBatch(batchIndex).batchRoot;
        headers[2].withdrawalRoot = keccak256("mutated");
        _appendBatchRootChunk(batchIndex, headers);

        L2BlockHeader memory prevHeader = batch1Headers[batch1Headers.length - 1];
        MerkleTree.MerkleProof memory prevProof = _buildMerkleProof(batch1Headers, batch1Headers.length - 1);

        bytes32 mutatedRoot = _computeBatchRoot(headers);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchRoot.selector, storedRoot, mutatedRoot));
        vm.prank(prover);
        rollup.finalizeBatchRootChallengeResolution(batchIndex, prevHeader, prevProof);
    }

    function test_RevertIf_finalizeBatchRootChallengeResolution_callerNotProver() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        L2BlockHeader[] memory batch1Headers = _makeBatch(GENESIS_HASH);
        (uint256 batchIndex,) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        L2BlockHeader memory prevHeader = batch1Headers[batch1Headers.length - 1];
        MerkleTree.MerkleProof memory prevProof = _buildMerkleProof(batch1Headers, batch1Headers.length - 1);

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, rollup.PROVER_ROLE()));
        vm.prank(user);
        rollup.finalizeBatchRootChallengeResolution(batchIndex, prevHeader, prevProof);
    }

    // ============ discard ============

    function test_discardBatchRootResolution_clearsState_allowsRestart() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        L2BlockHeader[] memory batch1Headers = _makeBatch(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        // Append wrong headers, discard, then restart with the correct ones.
        L2BlockHeader[] memory wrongHeaders = _makeBatch(keccak256("wrong"));
        _appendBatchRootChunk(batchIndex, wrongHeaders);

        vm.prank(prover);
        rollup.discardBatchRootResolution(batchIndex);

        // After discard, append succeeds with the real headers (state is fresh).
        L2BlockHeader memory prevHeader = batch1Headers[batch1Headers.length - 1];
        MerkleTree.MerkleProof memory prevProof = _buildMerkleProof(batch1Headers, batch1Headers.length - 1);
        _resolveBatchRootInOneChunk(batchIndex, headers, prevHeader, prevProof);

        _assertProverWithdrawable(prover, CHALLENGE_DEPOSIT);
    }

    function test_RevertIf_discardBatchRootResolution_noState() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex,) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        // No append yet → leavesAccumulated == 0 → discard rejected.
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.ResolutionNotInProgress.selector, batchIndex));
        vm.prank(prover);
        rollup.discardBatchRootResolution(batchIndex);
    }

    function test_RevertIf_discardBatchRootResolution_callerNotProver() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex,) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, rollup.PROVER_ROLE()));
        vm.prank(user);
        rollup.discardBatchRootResolution(batchIndex);
    }

    // ============ Resolution-initiator ownership gate ============

    function test_RevertIf_appendBatchRootResolutionChunk_notInitiator() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        // Two distinct PROVER_ROLE holders. The first one starts the resolution;
        // the second must NOT be able to extend it.
        address otherProver = makeAddr("otherProver");
        _grantProverRole(otherProver);

        _appendBatchRootChunk(batchIndex, _slice(headers, 0, 2));

        L2BlockHeader[] memory rest = _slice(headers, 2, 4);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.NotResolutionInitiator.selector, prover));
        vm.prank(otherProver);
        rollup.appendBatchRootResolutionChunk(batchIndex, rest);
    }

    function test_RevertIf_finalizeBatchRootChallengeResolution_notInitiator() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        L2BlockHeader[] memory batch1Headers = _makeBatch(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        address otherProver = makeAddr("otherProver");
        _grantProverRole(otherProver);

        // Original prover submits the full set of chunks.
        _appendBatchRootChunk(batchIndex, headers);

        // A different PROVER_ROLE holder must not be able to claim the reward.
        L2BlockHeader memory prevHeader = batch1Headers[batch1Headers.length - 1];
        MerkleTree.MerkleProof memory prevProof = _buildMerkleProof(batch1Headers, batch1Headers.length - 1);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.NotResolutionInitiator.selector, prover));
        vm.prank(otherProver);
        rollup.finalizeBatchRootChallengeResolution(batchIndex, prevHeader, prevProof);
    }

    function test_RevertIf_discardBatchRootResolution_notInitiator() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);
        _challengeBatchRoot(batchIndex);

        address otherProver = makeAddr("otherProver");
        _grantProverRole(otherProver);

        _appendBatchRootChunk(batchIndex, _slice(headers, 0, 2));

        // Another prover cannot grief by discarding someone else's accumulator.
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.NotResolutionInitiator.selector, prover));
        vm.prank(otherProver);
        rollup.discardBatchRootResolution(batchIndex);
    }

    // ============ Mutual exclusion ============

    function test_RevertIf_challengeBlock_batchChallengedByBatchRoot() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _preconfirmedBatchWithHeaders(lastHash);

        _challengeBatchRoot(batchIndex);

        MerkleTree.MerkleProof memory proof = _buildMerkleProof(headers, 0);
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchStatus.selector, batchIndex, uint8(BatchStatus.Challenged)));
        vm.prank(challenger);
        rollup.challengeBlock{value: CHALLENGE_DEPOSIT}(batchIndex, headers[0], proof);
    }

    // ============ forceRevert interaction ============

    function test_forceRevert_refundsBatchRootChallenger() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex,) = _submittedBatchWithHeaders(lastHash);

        _challengeBatchRoot(batchIndex);
        _assertChallengerWithdrawable(challenger, 0);

        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee);
        vm.prank(admin);
        rollup.revertBatches{value: fee}(batchIndex);

        _assertChallengerWithdrawable(challenger, CHALLENGE_DEPOSIT + fee);
    }

    function test_revertBatches_clearsResolutionState() public {
        // Append partial state, force-revert, then submit a fresh batch reusing the same
        // index — its first append must start with leavesAccumulated == 1 (proves the
        // accumulator was wiped; otherwise stale peaks would corrupt the new resolution).
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash);
        _challengeBatchRoot(batchIndex);

        _appendBatchRootChunk(batchIndex, _slice(headers, 0, 2));

        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee);
        vm.prank(admin);
        rollup.revertBatches{value: fee}(batchIndex);

        // Re-create a batch at the same index. If the resolution state had leaked,
        // the accumulator from the previous attempt would still hold 2 leaves and
        // the next append would either revert on chain linkage or produce a wrong root.
        (uint256 newBatchIndex, L2BlockHeader[] memory newHeaders) = _submittedBatchWithHeaders(lastHash);
        assertEq(newBatchIndex, batchIndex, "expected reuse of the reverted batch index");
        _challengeBatchRoot(newBatchIndex);

        L2BlockHeader[] memory prevBatchHeaders = _makeBatch(GENESIS_HASH);
        L2BlockHeader memory prevHeader = prevBatchHeaders[prevBatchHeaders.length - 1];
        MerkleTree.MerkleProof memory prevProof = _buildMerkleProof(prevBatchHeaders, prevBatchHeaders.length - 1);
        _resolveBatchRootInOneChunk(newBatchIndex, newHeaders, prevHeader, prevProof);

        _assertProverWithdrawable(prover, CHALLENGE_DEPOSIT);
    }
}
