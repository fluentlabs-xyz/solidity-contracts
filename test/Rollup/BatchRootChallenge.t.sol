// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {RollupAssertions} from "./Base.t.sol";
import {L2BlockHeader, L2BlockHeaderV1, BlockDeposit, BatchStatus, ChallengeRecord} from "../../contracts/interfaces/rollup/IRollupTypes.sol";
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

    /// @dev Project the full L2BlockHeader list onto the compact L2BlockHeaderV1 used by
    ///      `resolveBatchRootChallenge`. previousBlockHash + depositCount fields are
    ///      reconstructed/ignored on-chain, so they're stripped here.
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
        // that was committed at index 0 during initialize. With the V1-compact resolve,
        // the genesis tip comes straight from `previousBatch.toBlockHash` (= GENESIS_HASH),
        // so no separate prev-batch header / Merkle proof is passed.
        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(GENESIS_HASH);
        assertEq(batchIndex, 1);

        _challengeBatchRoot(batchIndex);

        vm.prank(prover);
        rollup.resolveBatchRootChallenge(batchIndex, _toV1(headers));

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

    function test_resolveBatchRootChallenge_provesRootAndRewardsProver() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);

        _challengeBatchRoot(batchIndex);
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Challenged));

        vm.prank(prover);
        rollup.resolveBatchRootChallenge(batchIndex, _toV1(headers));

        _assertProverWithdrawable(prover, CHALLENGE_DEPOSIT);
        // Pre-challenge status must be restored on a successful resolve.
        assertEq(uint8(rollup.getBatch(batchIndex).status), uint8(BatchStatus.Submitted), "status should be restored to Submitted");
    }

    // ============ resolveBatchRootChallenge — reverts ============

    function test_RevertIf_resolveBatchRootChallenge_notChallenged() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.InvalidBatchStatus.selector, batchIndex, uint8(BatchStatus.Submitted)));
        vm.prank(prover);
        rollup.resolveBatchRootChallenge(batchIndex, _toV1(headers));
    }

    function test_RevertIf_resolveBatchRootChallenge_wrongHeaders() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        (uint256 batchIndex,) = _submittedBatchWithHeaders(lastHash1);

        _challengeBatchRoot(batchIndex);

        // Headers from a different parent: chain reconstruction produces well-formed
        // commitments but the Merkle root differs from the stored one, so the resolve
        // reverts with `InvalidBatchRoot`.
        L2BlockHeader[] memory wrongHeaders = _makeBatch(keccak256("wrong"));

        vm.expectPartialRevert(IRollupErrors.InvalidBatchRoot.selector);
        vm.prank(prover);
        rollup.resolveBatchRootChallenge(batchIndex, _toV1(wrongHeaders));
    }

    function test_RevertIf_resolveBatchRootChallenge_callerNotProver() public {
        _fullyFinalizeBatch(GENESIS_HASH);
        bytes32 lastHash1 = _lastBlockHash(GENESIS_HASH);

        (uint256 batchIndex, L2BlockHeader[] memory headers) = _submittedBatchWithHeaders(lastHash1);

        _challengeBatchRoot(batchIndex);

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, rollup.PROVER_ROLE()));
        vm.prank(user);
        rollup.resolveBatchRootChallenge(batchIndex, _toV1(headers));
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
}
