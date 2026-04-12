// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {RollupAssertions} from "./Base.t.sol";
import {L2BlockHeader, BlockDeposit, BatchStatus, ChallengeRecord} from "../../contracts/interfaces/IRollupTypes.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract BatchRootChallengeTest is RollupAssertions {
    // ============ Helpers ============

    function _submittedBatchWithHeaders(bytes32 parentHash) internal returns (uint256 batchIndex, L2BlockHeader[] memory headers) {
        headers = _makeBatch(parentHash);
        batchIndex = rollup.nextBatchIndex();
        vm.prank(sequencer);
        rollup.commitBatch(_computeBatchRoot(headers), uint24(headers.length), new BlockDeposit[](0), 1);
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
        vm.deal(challenger, CHALLENGE_DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchIndex.selector, uint256(1), uint256(2)));
        vm.prank(challenger);
        rollup.challengeBatchRoot{value: CHALLENGE_DEPOSIT}(1);
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
