// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {IRollupErrors} from "../../contracts/interfaces/IRollup.sol";
import {RollupBase} from "./Base.t.sol";

contract MaliciousProverCallback {
    Rollup internal immutable rollup;
    bool internal callbackTriggered;
    bool internal callbackReentryAttempted;
    bool internal callbackReentrySucceeded;

    constructor(Rollup _rollup) {
        rollup = _rollup;
    }

    function prove(
        uint256 batchIndex,
        Rollup.BlockCommitment calldata commitment,
        bytes calldata proof,
        MerkleTree.MerkleProof calldata blockProof
    ) external {
        rollup.proofBlockCommitment(batchIndex, commitment, 0, proof, blockProof);
    }

    receive() external payable {
        callbackTriggered = true;
        callbackReentryAttempted = true;
        (bool ok,) = address(rollup).call(
            abi.encodeWithSelector(Rollup.withdrawChallengeDeposit.selector, payable(address(this)))
        );
        callbackReentrySucceeded = ok;
    }

    function wasCallbackTriggered() external view returns (bool) {
        return callbackTriggered;
    }

    function wasCallbackReentryAttempted() external view returns (bool) {
        return callbackReentryAttempted;
    }

    function wasCallbackReentrySucceeded() external view returns (bool) {
        return callbackReentrySucceeded;
    }
}

contract RollupSecurityEdgeCasesTest is RollupBase {
    function _buildSingleCommitmentBatch(bytes32 prevHash, bytes32 blockHash)
        internal
        pure
        returns (Rollup.BlockCommitment[] memory batch)
    {
        batch = new Rollup.BlockCommitment[](1);
        batch[0] = _buildCommitment(prevHash, blockHash, ZERO_HASH, ZERO_HASH);
    }

    function _acceptAndChallenge(uint256 batchIndex, bytes32 prevHash, bytes32 blockHash)
        internal
        returns (Rollup.BlockCommitment memory commitment, MerkleTree.MerkleProof memory blockProof)
    {
        Rollup.BlockCommitment[] memory batch = _buildSingleCommitmentBatch(prevHash, blockHash);

        vm.prank(SEQUENCER);
        // In tests we run with daCheck disabled, so blob index is ignored.
        rollup.acceptNextBatch(batchIndex, batch, new Rollup.DepositsInBlock[](0), 0);

        blockProof = _proofForSingleLeaf();
        vm.deal(CHALLENGER, 10000 ether);
        vm.prank(CHALLENGER);
        rollup.challengeBlockCommitment{value: 10000}(batchIndex, batch[0], blockProof);

        commitment = batch[0];
    }

    function _setupChallengeQueue(uint256 challengeCount)
        internal
        returns (Rollup.BlockCommitment memory firstCommitment, MerkleTree.MerkleProof memory firstProof)
    {
        bytes32 prevHash = MOCK_GENESIS_HASH;
        for (uint256 i = 1; i <= challengeCount; i++) {
            bytes32 blockHash = keccak256(abi.encodePacked("security-queue", i));
            (Rollup.BlockCommitment memory commitment, MerkleTree.MerkleProof memory blockProof) =
                _acceptAndChallenge(i, prevHash, blockHash);
            if (i == 1) {
                firstCommitment = commitment;
                firstProof = blockProof;
            }
            prevHash = blockHash;
        }
    }

    function _measureProofGasWithQueue(uint256 challengeCount) internal returns (uint256 gasUsed) {
        _deployMockRollup({
            batchSize_: 1,
            challengeDepositAmount_: 10000,
            challengeBlockCount_: 100,
            approveBlockCount_: 1,
            acceptDepositDeadline_: 100,
            incentiveFee_: 0
        });

        (Rollup.BlockCommitment memory commitment, MerkleTree.MerkleProof memory blockProof) =
            _setupChallengeQueue(challengeCount);

        uint256 beforeGas = gasleft();
        vm.prank(PROOF_PROVIDER);
        rollup.proofBlockCommitment(1, commitment, 0, hex"1234", blockProof);
        gasUsed = beforeGas - gasleft();
    }

    function test_poc_proofCallbackMustNotBeInvoked() public {
        _deployMockRollup({
            batchSize_: 1,
            challengeDepositAmount_: 10000,
            challengeBlockCount_: 1,
            approveBlockCount_: 1,
            acceptDepositDeadline_: 10,
            incentiveFee_: 0
        });

        (Rollup.BlockCommitment memory commitment, MerkleTree.MerkleProof memory blockProof) =
            _acceptAndChallenge(1, MOCK_GENESIS_HASH, keccak256("reentrancy-poc"));

        MaliciousProverCallback maliciousProver = new MaliciousProverCallback(rollup);
        maliciousProver.prove(1, commitment, hex"1234", blockProof);

        assertEq(maliciousProver.wasCallbackTriggered(), false, "proof callback should not be externally triggered");
    }

    function test_poc_acceptNextBatch_revertsWhenDaCheckEnabledWithoutDaInput() public {
        _deployMockRollup({
            batchSize_: 1,
            challengeDepositAmount_: 10000,
            challengeBlockCount_: 1,
            approveBlockCount_: 1,
            acceptDepositDeadline_: 10,
            incentiveFee_: 0
        });

        rollup.setDaCheck(true);

        Rollup.BlockCommitment[] memory batch =
            _buildSingleCommitmentBatch(MOCK_GENESIS_HASH, keccak256("da-fail-closed"));

        vm.expectRevert();
        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(1, batch, new Rollup.DepositsInBlock[](0), 0);
    }

    function test_poc_proofGasDoesNotScaleWithQueueLength() public {
        uint256 gasForSingleChallenge = _measureProofGasWithQueue(1);
        uint256 gasForFortyChallenges = _measureProofGasWithQueue(40);

        assertLe(
            gasForFortyChallenges,
            gasForSingleChallenge + 50_000,
            "proof gas should not scale with challenge queue size"
        );
    }

    function test_poc_repeatedProofMustRevert() public {
        _deployMockRollup({
            batchSize_: 1,
            challengeDepositAmount_: 10000,
            challengeBlockCount_: 1,
            approveBlockCount_: 1,
            acceptDepositDeadline_: 10,
            incentiveFee_: 0
        });

        (Rollup.BlockCommitment memory commitment, MerkleTree.MerkleProof memory blockProof) =
            _acceptAndChallenge(1, MOCK_GENESIS_HASH, keccak256("repeat-proof"));

        bytes32 commitmentHash = _commitmentHash(commitment);

        vm.prank(PROOF_PROVIDER);
        rollup.proofBlockCommitment(1, commitment, 0, hex"1234", blockProof);

        vm.expectRevert(abi.encodeWithSelector(IRollupErrors.BlockCommitmentAlreadyProofed.selector, commitmentHash));
        vm.prank(ATTACKER);
        rollup.proofBlockCommitment(1, commitment, 0, hex"1234", blockProof);
    }

    function test_characterization_anyoneCanFrontRunProofSubmission() public {
        _deployMockRollup({
            batchSize_: 1,
            challengeDepositAmount_: 10000,
            challengeBlockCount_: 1,
            approveBlockCount_: 1,
            acceptDepositDeadline_: 10,
            incentiveFee_: 0
        });

        (Rollup.BlockCommitment memory commitment, MerkleTree.MerkleProof memory blockProof) =
            _acceptAndChallenge(1, MOCK_GENESIS_HASH, keccak256("frontrun"));
        bytes32 commitmentHash = _commitmentHash(commitment);

        vm.prank(ATTACKER);
        rollup.proofBlockCommitment(1, commitment, 0, hex"1234", blockProof);

        assertEq(
            rollup.provenBlockCommitment(commitmentHash),
            true,
            "attacker should be able to front-run with valid proof calldata"
        );
    }
}
