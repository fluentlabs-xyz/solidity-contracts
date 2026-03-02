// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {RollupBase} from "./Base.t.sol";

contract RollupDepositDeadlineTest is RollupBase {
    uint256 internal constant ACCEPT_DEPOSIT_DEADLINE = 3;

    function setUp() public {
        _deployMockRollupWithLinkedBridgeQueue({
            batchSize_: 1,
            challengeDepositAmount_: 10000,
            challengeBlockCount_: 1,
            approveBlockCount_: 1,
            acceptDepositDeadline_: ACCEPT_DEPOSIT_DEADLINE,
            incentiveFee_: 0
        });
    }

    function _enqueueMessages(uint256 count) internal returns (bytes32[] memory messageHashes) {
        messageHashes = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            bytes memory payload = abi.encodePacked(bytes1(uint8(i + 1)));
            messageHashes[i] = _bridgeMessageHash(address(this), address(0x3333), 0, block.chainid, block.number, i, payload);
            bridge.sendMessage(address(0x3333), payload);
        }
    }

    function test_acceptNextBatch_withValidDeposit_consumesQueue() public {
        bytes32[] memory messageHashes = _enqueueMessages(1);
        bytes32 blockHash = keccak256("deposit-ok");

        Rollup.BlockCommitment[] memory batch = new Rollup.BlockCommitment[](1);
        batch[0] = _buildCommitment(MOCK_GENESIS_HASH, blockHash, ZERO_HASH, keccak256(abi.encodePacked(messageHashes[0])));

        Rollup.DepositsInBlock[] memory deposits = new Rollup.DepositsInBlock[](1);
        deposits[0] = Rollup.DepositsInBlock({blockHash: blockHash, depositCount: 1});

        assertEq(bridge.getQueueSize(), 1, "queue size before accept mismatch");

        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(1, batch, deposits);

        assertEq(bridge.getQueueSize(), 0, "queue must be fully consumed");
        assertEq(rollup.nextBatchIndex(), 2, "nextBatchIndex must increment");
    }

    function test_acceptNextBatch_revertsWhenDepositBlockHashMismatches() public {
        bytes32[] memory messageHashes = _enqueueMessages(1);
        bytes32 batchBlockHash = keccak256("deposit-block");
        bytes32 wrongDepositBlockHash = keccak256("deposit-wrong-block");

        Rollup.BlockCommitment[] memory batch = new Rollup.BlockCommitment[](1);
        batch[0] = _buildCommitment(MOCK_GENESIS_HASH, batchBlockHash, ZERO_HASH, keccak256(abi.encodePacked(messageHashes[0])));

        Rollup.DepositsInBlock[] memory deposits = new Rollup.DepositsInBlock[](1);
        deposits[0] = Rollup.DepositsInBlock({blockHash: wrongDepositBlockHash, depositCount: 1});

        vm.expectRevert(abi.encodeWithSelector(Rollup.BlockHashMismatch.selector, batchBlockHash, wrongDepositBlockHash));
        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(1, batch, deposits);
    }

    function test_acceptNextBatch_revertsWhenDepositHashMismatches() public {
        _enqueueMessages(1);
        bytes32 blockHash = keccak256("deposit-hash-mismatch");

        Rollup.BlockCommitment[] memory batch = new Rollup.BlockCommitment[](1);
        batch[0] = _buildCommitment(MOCK_GENESIS_HASH, blockHash, ZERO_HASH, keccak256("wrong-deposit-hash"));

        Rollup.DepositsInBlock[] memory deposits = new Rollup.DepositsInBlock[](1);
        deposits[0] = Rollup.DepositsInBlock({blockHash: blockHash, depositCount: 1});

        vm.expectRevert(abi.encodeWithSelector(Rollup.DepositVerificationFailed.selector, blockHash));
        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(1, batch, deposits);
    }

    function test_acceptNextBatch_revertsWhenDepositDeadlineExceeded() public {
        bytes32[] memory messageHashes = _enqueueMessages(2);

        bytes32 blockHash1 = keccak256("deadline-block-1");
        Rollup.BlockCommitment[] memory firstBatch = new Rollup.BlockCommitment[](1);
        firstBatch[0] = _buildCommitment(MOCK_GENESIS_HASH, blockHash1, ZERO_HASH, keccak256(abi.encodePacked(messageHashes[0])));

        Rollup.DepositsInBlock[] memory firstDeposits = new Rollup.DepositsInBlock[](1);
        firstDeposits[0] = Rollup.DepositsInBlock({blockHash: blockHash1, depositCount: 1});

        uint256 acceptedAtBlock = block.number;
        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(1, firstBatch, firstDeposits);

        assertEq(bridge.getQueueSize(), 1, "one deposit must remain pending");

        vm.roll(block.number + ACCEPT_DEPOSIT_DEADLINE + 1);

        Rollup.BlockCommitment[] memory secondBatch = new Rollup.BlockCommitment[](1);
        secondBatch[0] = _buildCommitment(blockHash1, keccak256("deadline-block-2"), ZERO_HASH, ZERO_HASH);

        vm.expectRevert(
            abi.encodeWithSelector(Rollup.AcceptDepositDeadlineExceeded.selector, acceptedAtBlock + ACCEPT_DEPOSIT_DEADLINE, block.number)
        );
        vm.prank(SEQUENCER);
        rollup.acceptNextBatch(2, secondBatch, new Rollup.DepositsInBlock[](0));
    }
}
