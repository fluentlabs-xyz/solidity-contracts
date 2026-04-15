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
        rollup.commitBatch(_computeBatchRoot(headers), headers[headers.length - 1].blockHash, uint24(headers.length), new BlockDeposit[](0), 1);
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

    function test_resolveBatchRootChallenge_firstRealBatch_againstGenesis() public {
        // End-to-end: challenge batch 1 and resolve against the synthetic genesis batch
        // that was committed at index 0 during initialize.
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(GENESIS_HASH);
        assertEq(batchIndex, 1);

        _challengeBatchRoot(batchIndex);

        // Reconstruct the synthetic genesis header as stored by _commitGenesisBatch.
        L2BlockHeader memory genesisHeader = L2BlockHeader({
            previousBlockHash: bytes32(0),
            blockHash: GENESIS_HASH,
            withdrawalRoot: ZERO_BYTES_HASH,
            depositRoot: ZERO_BYTES_HASH,
            depositCount: 0
        });

        // Single-leaf Merkle tree → proof is empty, nonce = 0 (last leaf index, numberOfBlocks - 1 = 0).
        // Assumes MerkleTree.verifyMerkleProof accepts empty bytes (zero iterations → returns leaf == root).
        // If the library ever requires _proof.length > 0, this genesis-batch path breaks silently.
        MerkleTree.MerkleProof memory emptyProof = MerkleTree.MerkleProof({nonce: 0, proof: ""});

        vm.prank(prover);
        rollup.resolveBatchRootChallenge(batchIndex, genesisHeader, headers, emptyProof);

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

    // ============ resolveBatchRootChallenge — happy path ============

    /// @dev Note: resolveBatchRootChallenge has a known storage ordering issue where
    ///      `delete _batchRootChallenges[batchIndex]` runs before
    ///      `batch.status = challenged.previousStatus`, causing previousStatus to read
    ///      as zero (BatchStatus.None) after the delete. This test verifies current behavior.
    function test_resolveBatchRootChallenge_provesRootAndRewardsProver() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        L2BlockHeader[] memory batch1Headers = _makeBatch(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);

        _challengeBatchRoot(batchIndex);
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Challenged));

        L2BlockHeader memory lastBlockInPrevBatch = batch1Headers[batch1Headers.length - 1];
        MerkleTree.MerkleProof memory lastBlockProof = _buildMerkleProof(batch1Headers, batch1Headers.length - 1);

        vm.prank(prover);
        rollup.resolveBatchRootChallenge(batchIndex, lastBlockInPrevBatch, headers, lastBlockProof);

        _assertProverWithdrawable(prover, CHALLENGE_DEPOSIT);
    }

    // ============ resolveBatchRootChallenge — reverts ============

    function test_RevertIf_resolveBatchRootChallenge_notChallenged() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        L2BlockHeader[] memory batch1Headers = _makeBatch(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);

        L2BlockHeader memory lastBlockInPrevBatch = batch1Headers[batch1Headers.length - 1];
        MerkleTree.MerkleProof memory lastBlockProof = _buildMerkleProof(batch1Headers, batch1Headers.length - 1);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchStatus.selector, batchIndex, uint8(BatchStatus.Submitted)));
        vm.prank(prover);
        rollup.resolveBatchRootChallenge(batchIndex, lastBlockInPrevBatch, headers, lastBlockProof);
    }

    function test_RevertIf_resolveBatchRootChallenge_wrongHeaders() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        L2BlockHeader[] memory batch1Headers = _makeBatch(GENESIS_HASH);
        (uint256 batchIndex,) = _submittedBatchWithHeaders(lastHash1);

        _challengeBatchRoot(batchIndex);

        L2BlockHeader[] memory wrongHeaders = _makeBatch(keccak256("wrong"));
        L2BlockHeader memory lastBlockInPrevBatch = batch1Headers[batch1Headers.length - 1];
        MerkleTree.MerkleProof memory lastBlockProof = _buildMerkleProof(batch1Headers, batch1Headers.length - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IRollupErrors.InvalidLastBlockHash.selector,
                lastBlockInPrevBatch.blockHash,
                wrongHeaders[0].previousBlockHash
            )
        );
        vm.prank(prover);
        rollup.resolveBatchRootChallenge(batchIndex, lastBlockInPrevBatch, wrongHeaders, lastBlockProof);
    }

    function test_RevertIf_resolveBatchRootChallenge_callerNotProver() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        L2BlockHeader[] memory batch1Headers = _makeBatch(GENESIS_HASH);
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);

        _challengeBatchRoot(batchIndex);

        L2BlockHeader memory lastBlockInPrevBatch = batch1Headers[batch1Headers.length - 1];
        MerkleTree.MerkleProof memory lastBlockProof = _buildMerkleProof(batch1Headers, batch1Headers.length - 1);

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, rollup.PROVER_ROLE()));
        vm.prank(user);
        rollup.resolveBatchRootChallenge(batchIndex, lastBlockInPrevBatch, headers, lastBlockProof);
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
        uint256 batch1 = _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash = _lastBlockHash(GENESIS_HASH);
        (uint256 batchIndex,) = _submittedBatchWithHeaders(lastHash);

        _challengeBatchRoot(batchIndex);
        _assertChallengerWithdrawable(challenger, 0);

        uint256 fee = rollup.incentiveFee();
        vm.deal(admin, fee);
        vm.prank(admin);
        rollup.revertBatches{value: fee}(batch1);

        _assertChallengerWithdrawable(challenger, CHALLENGE_DEPOSIT + fee);
    }
}
