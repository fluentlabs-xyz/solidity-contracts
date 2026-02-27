// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../Rollup/Base.t.sol";
import "./RollupHandler.t.sol";

contract RollupInvariantTest is MinimalTest {
    bytes32 internal constant MOCK_VK_KEY =
        0x00612f9d5a388df116872ff70e36bcb86c7e73b1089f32f68fc8e0d0ba7861b7;
    bytes32 internal constant MOCK_GENESIS_HASH =
        0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    Rollup internal rollup;
    Bridge internal bridge;
    VerifierMock internal verifierMock;
    RollupHandler internal handler;

    function setUp() public {
        handler = new RollupHandler();

        verifierMock = new VerifierMock();
        bridge = new Bridge(
            address(this),
            address(0),
            0,
            address(0x1111),
            address(0x2222)
        );
        rollup = new Rollup(
            address(handler),
            10000,
            5000,
            1,
            address(verifierMock),
            MOCK_VK_KEY,
            MOCK_GENESIS_HASH,
            address(bridge),
            1,
            100,
            0
        );

        handler.initialize(rollup);
        rollup.setDaCheck(false);
        rollup.transferOwnership(address(handler));
        handler.acceptRollupOwnership();

        vm.deal(address(handler), 1_000_000 ether);
    }

    function testFuzz_invariant_stateHoldsAfterRandomizedActions(
        uint256 seed,
        uint8 actionCount
    ) public {
        uint256 steps = uint256(actionCount % 64) + 1;
        for (uint256 i = 0; i < steps; i++) {
            uint256 op = uint256(keccak256(abi.encode(seed, i))) % 6;
            uint256 arg = uint256(keccak256(abi.encode(seed, i, "arg")));

            if (op == 0) {
                handler.stepAcceptBatch(arg);
            } else if (op == 1) {
                handler.stepChallenge(arg);
            } else if (op == 2) {
                handler.stepProve(arg);
            } else if (op == 3) {
                handler.stepForceRevert(arg);
            } else if (op == 4) {
                handler.stepWithdrawChallengeDeposit();
            } else {
                handler.stepWithdrawProofReward();
            }
        }

        _assertInvariants();
    }

    function test_invariant_challengedCommitmentHasDeadline() public view {
        _assertChallengedCommitmentsHaveDeadline();
    }

    function test_invariant_provenCommitmentHasNoActiveChallenger() public view {
        _assertProvenCommitmentsHaveNoActiveChallenger();
    }

    function test_invariant_nextBatchIndexNeverDecreasesOutsideForceRevert() public view {
        _assertNextBatchIndexNoIllegalDecrease();
    }

    function test_invariant_emptyQueueIsNotCorrupted() public view {
        _assertEmptyQueueNotCorrupted();
    }

    function test_invariant_challengeDepositAccountingConsistent() public view {
        _assertChallengeDepositAccountingConsistency();
    }

    function _assertInvariants() internal view {
        _assertChallengedCommitmentsHaveDeadline();
        _assertProvenCommitmentsHaveNoActiveChallenger();
        _assertNextBatchIndexNoIllegalDecrease();
        _assertEmptyQueueNotCorrupted();
        _assertChallengeDepositAccountingConsistency();
    }

    function _assertChallengedCommitmentsHaveDeadline() internal view {
        uint256 len = handler.commitmentsLength();
        for (uint256 i = 0; i < len; i++) {
            bytes32 commitmentHash = handler.commitmentHashAt(i);
            if (rollup.blockCommitmentChallenger(commitmentHash) != address(0)) {
                assertGt(
                    rollup.challengeDeadline(commitmentHash),
                    0,
                    "challenged commitment must have deadline"
                );
            }
        }
    }

    function _assertProvenCommitmentsHaveNoActiveChallenger() internal view {
        uint256 len = handler.commitmentsLength();
        for (uint256 i = 0; i < len; i++) {
            bytes32 commitmentHash = handler.commitmentHashAt(i);
            if (rollup.provenBlockCommitment(commitmentHash)) {
                assertEq(
                    rollup.blockCommitmentChallenger(commitmentHash),
                    address(0),
                    "proven commitment cannot keep active challenger"
                );
            }
        }
    }

    function _assertNextBatchIndexNoIllegalDecrease() internal view {
        assertEq(
            handler.illegalNextBatchDecreaseCount(),
            0,
            "nextBatchIndex decreased outside forceRevertBatch"
        );
    }

    function _assertEmptyQueueNotCorrupted() internal view {
        bytes32[] memory queue = rollup.getChallengeQueue();
        if (queue.length == 0) {
            assertEq(
                rollup.rollupCorrupted(),
                false,
                "rollupCorrupted must be false when queue is empty"
            );
        }
    }

    function _assertChallengeDepositAccountingConsistency() internal view {
        uint256 activeChallengeCount = 0;
        uint256 len = handler.commitmentsLength();
        for (uint256 i = 0; i < len; i++) {
            bytes32 commitmentHash = handler.commitmentHashAt(i);
            if (rollup.blockCommitmentChallenger(commitmentHash) != address(0)) {
                activeChallengeCount += 1;
            }
        }

        uint256 expectedLocked = activeChallengeCount * rollup.challengeDepositAmount();
        uint256 actualLocked = rollup.challengerDeposit(address(handler));
        assertEq(
            actualLocked,
            expectedLocked,
            "challengerDeposit inconsistent with active challenges"
        );
    }
}
