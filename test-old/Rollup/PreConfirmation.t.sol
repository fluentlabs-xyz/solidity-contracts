// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorageLayout.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {NitroEnclaveVerifierMock} from "../../contracts/mocks/NitroEnclaveVerifierMock.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {RollupBase} from "./Base.t.sol";

/**
 * @title Tests for the two-verifier flow: Accepted → PreConfirmed (Nitro) → Finalized (approveBlockCount).
 */
contract RollupPreConfirmationTest is RollupBase {
    NitroEnclaveVerifierMock internal nitroMock;

    function setUp() public {
        _deployMockRollup({
            batchSize_: 2,
            challengeDepositAmount_: 10000,
            challengeBlockCount_: 1,
            approveBlockCount_: 2,
            acceptDepositDeadline_: 10,
            incentiveFee_: 0
        });
        nitroMock = new NitroEnclaveVerifierMock();
        rollup.setNitroVerifier(address(nitroMock));
    }

    function test_acceptThenPreConfirmThenFinalize_fullFlow() public {
        RollupStorageLayout.BlockCommitment[] memory batch = _buildLinkedBatch(MOCK_GENESIS_HASH);

        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(batch, new RollupStorageLayout.DepositsInBlock[](0), 0);

        assertEq(uint256(rollup.batchStatus(1)), uint256(RollupStorageLayout.BatchStatus.Accepted), "batch should be Accepted");

        MerkleTree.MerkleProof memory proofForFirstBlock =
            _proofForTwoLeaves(0, _commitmentHash(batch[1]));

        rollup.commitPreConfirmation(1, batch[0], "nitro-signature", proofForFirstBlock);

        assertEq(uint256(rollup.batchStatus(1)), uint256(RollupStorageLayout.BatchStatus.PreConfirmed), "batch should be PreConfirmed");
        assertEq(false, rollup.approvedBatch(1), "not yet finalized");

        vm.roll(block.number + 3);
        bool approved = rollup.ensureBatchApproved(1);
        assertTrue(approved, "ensureBatchApproved should return true");
        assertEq(uint256(rollup.batchStatus(1)), uint256(RollupStorageLayout.BatchStatus.Finalized), "batch should be Finalized");
        assertTrue(rollup.approvedBatch(1), "batch should be approved");
    }

    function test_finalize_revertsWhenNitroSetButNotPreConfirmed() public {
        RollupStorageLayout.BlockCommitment[] memory batch = _buildLinkedBatch(MOCK_GENESIS_HASH);

        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(batch, new RollupStorageLayout.DepositsInBlock[](0), 0);

        vm.roll(block.number + 3);
        bool approved = rollup.ensureBatchApproved(1);
        assertEq(false, approved, "batch must not be approved without PreConfirmed when Nitro is set");
        assertEq(uint256(rollup.batchStatus(1)), uint256(RollupStorageLayout.BatchStatus.Accepted), "status stays Accepted");
    }

    function test_finalize_revertsAfterChallengeResolutionWithoutNitroPreConfirmation() public {
        RollupStorageLayout.BlockCommitment[] memory batch = _buildLinkedBatch(MOCK_GENESIS_HASH);

        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(batch, new RollupStorageLayout.DepositsInBlock[](0), 0);

        MerkleTree.MerkleProof memory proofForFirstBlock = _proofForTwoLeaves(0, _commitmentHash(batch[1]));

        vm.deal(CHALLENGER, 10000);
        vm.prank(CHALLENGER);
        rollup.challengeBlockCommitment{value: 10000}(1, batch[0], proofForFirstBlock);

        vm.prank(PROOF_PROVIDER);
        rollup.proofBlockCommitment(1, batch[0], 0, hex"1234", proofForFirstBlock);

        assertEq(uint256(rollup.batchStatus(1)), uint256(RollupStorageLayout.BatchStatus.Accepted), "status should return to Accepted");

        vm.roll(block.number + 3);
        bool approved = rollup.ensureBatchApproved(1);
        assertEq(false, approved, "must not finalize without explicit Nitro pre-confirmation");
        assertEq(uint256(rollup.batchStatus(1)), uint256(RollupStorageLayout.BatchStatus.Accepted), "status remains Accepted");
    }

    function test_commitPreConfirmation_revertsWhenNotAccepted() public {
        RollupStorageLayout.BlockCommitment[] memory batch = _buildLinkedBatch(MOCK_GENESIS_HASH);
        MerkleTree.MerkleProof memory proof = _proofForTwoLeaves(0, _commitmentHash(batch[1]));

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.BatchNotAccepted.selector, 1));
        rollup.commitPreConfirmation(1, batch[0], "sig", proof);
    }

    function test_commitPreConfirmation_revertsWhenNitroNotSet() public {
        // Deploy a rollup that never has Nitro set (don't call setNitroVerifier).
        _deployMockRollup({
            batchSize_: 2,
            challengeDepositAmount_: 10000,
            challengeBlockCount_: 1,
            approveBlockCount_: 2,
            acceptDepositDeadline_: 10,
            incentiveFee_: 0
        });
        RollupStorageLayout.BlockCommitment[] memory batch = _buildLinkedBatch(MOCK_GENESIS_HASH);

        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(batch, new RollupStorageLayout.DepositsInBlock[](0), 0);

        MerkleTree.MerkleProof memory proof = _proofForTwoLeaves(0, _commitmentHash(batch[1]));
        vm.expectRevert(IRollupErrors.NitroVerifierNotSet.selector);
        rollup.commitPreConfirmation(1, batch[0], "sig", proof);
    }

    function test_commitPreConfirmation_revertsWhenWrongMerkleProof() public {
        RollupStorageLayout.BlockCommitment[] memory batch = _buildLinkedBatch(MOCK_GENESIS_HASH);

        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(batch, new RollupStorageLayout.DepositsInBlock[](0), 0);

        bytes32 wrongSibling = keccak256("wrong-sibling");
        MerkleTree.MerkleProof memory badProof = _proofForTwoLeaves(0, wrongSibling);

        vm.expectRevert(IRollupErrors.InvalidBlockProof.selector);
        rollup.commitPreConfirmation(1, batch[0], "sig", badProof);
    }

    /// @dev When Nitro is not set, batches can finalize after approveBlockCount without pre-confirmation (SP1-only path).
    function test_finalize_withoutNitro_acceptThenWaitThenFinalize() public {
        _deployMockRollup({
            batchSize_: 2,
            challengeDepositAmount_: 10000,
            challengeBlockCount_: 1,
            approveBlockCount_: 2,
            acceptDepositDeadline_: 10,
            incentiveFee_: 0
        });
        // Do not set nitroVerifier

        RollupStorageLayout.BlockCommitment[] memory batch = _buildLinkedBatch(MOCK_GENESIS_HASH);
        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(batch, new RollupStorageLayout.DepositsInBlock[](0), 0);

        assertEq(uint256(rollup.batchStatus(1)), uint256(RollupStorageLayout.BatchStatus.Accepted), "batch should be Accepted");

        vm.roll(block.number + 3);
        bool approved = rollup.ensureBatchApproved(1);
        assertTrue(approved, "ensureBatchApproved should succeed without PreConfirmed when Nitro is not set");
        assertEq(uint256(rollup.batchStatus(1)), uint256(RollupStorageLayout.BatchStatus.Finalized), "batch should be Finalized");
    }
}
