// SPDX-License-Identifier: MIT
// E2E purpose: parity migration for bulk batch acceptance and proof processing.
// Flow direction: L2 -> L1 (proof path bulk), then L1 -> L2 (authority path bulk).
pragma solidity ^0.8.30;

import {ERC20PeggedToken} from "../../contracts/tokens/ERC20PeggedToken.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {MockERC20Token} from "../../contracts/mocks/MockERC20.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {IFluentBridge} from "../../contracts/interfaces/IFluentBridge.sol";
import {BaseDualFork, VmFork} from "./BaseDualFork.t.sol";

contract AcceptBatchParityTest is BaseDualFork {
    uint256 internal constant BATCH_SIZE = 4;
    uint256 internal constant MESSAGE_COUNT = 8;
    uint256 internal constant TRANSFER_AMOUNT = 10 ether;

    function setUp() public {
        _setUpDualForkWithL1BatchSize(BATCH_SIZE);
    }

    function test_bulkAcceptBatchAndProcessMessages_withProofs() public {
        // Step 1: Send 8 messages L2 -> L1 and collect withdrawal hashes.
        SentMessageData[] memory l2ToL1 = _sendBulkL2ToL1(MESSAGE_COUNT, TRANSFER_AMOUNT);

        // Step 2: Accept two withdrawal batches on L1 with DA enabled.
        (
            Rollup.BlockCommitment[] memory withdrawBatchA,
            Rollup.BlockCommitment[] memory withdrawBatchB,
            bytes32 lastHashAfterWithdrawals
        ) = _buildWithdrawalBatchesFromMessages(l2ToL1, MOCK_GENESIS_HASH);

        _switchToL1();
        _assertOnL1();
        _acceptBatchL1(1, withdrawBatchA, new Rollup.DepositsInBlock[](0));
        bytes32 expectedRootA = l1.rollup.calculateBatchRoot(withdrawBatchA);
        assertEq(l1.rollup.acceptedBatchHash(1), expectedRootA, "accepted root mismatch for batch A");

        _acceptBatchL1(2, withdrawBatchB, new Rollup.DepositsInBlock[](0));
        bytes32 expectedRootB = l1.rollup.calculateBatchRoot(withdrawBatchB);
        assertEq(l1.rollup.acceptedBatchHash(2), expectedRootB, "accepted root mismatch for batch B");
        assertEq(l1.rollup.nextBatchIndex(), 3, "nextBatchIndex must move after two withdrawal batches");

        // Step 3: Prove each withdrawal with block-proof index coverage (0..3 in each batch).
        _proveWithdrawalBatch(1, withdrawBatchA, l2ToL1, 0);
        _proveWithdrawalBatch(2, withdrawBatchB, l2ToL1, BATCH_SIZE);

        // Step 4: Send bulk pegged-token messages L1 -> L2 and execute by bridge authority.
        address l1PeggedTokenAddress = l1.gateway.computePeggedTokenAddress(address(l2.originToken));
        ERC20PeggedToken l1PeggedToken = ERC20PeggedToken(l1PeggedTokenAddress);
        assertEq(
            l1PeggedToken.balanceOf(USER_B),
            MESSAGE_COUNT * TRANSFER_AMOUNT,
            "unexpected minted pegged token balance on L1"
        );

        SentMessageData[] memory l1ToL2 =
            _sendBulkL1ToL2WithPeggedToken(l1PeggedTokenAddress, MESSAGE_COUNT, TRANSFER_AMOUNT);
        assertEq(l1.bridge.getQueueSize(), MESSAGE_COUNT, "L1 queue must hold one deposit per outbound message");

        _switchToL2();
        _assertOnL2();
        for (uint256 i = 0; i < l1ToL2.length; i++) {
            vm.prank(BRIDGE_AUTHORITY);
            l2.bridge.receiveMessage(
                l1ToL2[i].sender,
                l1ToL2[i].to,
                l1ToL2[i].value,
                l1ToL2[i].chainId,
                l1ToL2[i].blockNumber,
                l1ToL2[i].nonce,
                l1ToL2[i].data
            );
            assertEq(
                uint256(l2.bridge.receivedMessage(l1ToL2[i].messageHash)),
                uint256(IFluentBridge.MessageStatus.Success),
                "L2 message should be marked as success"
            );
        }

        // Step 5: Accept two deposit batches and consume full L1 queue.
        (Rollup.BlockCommitment[] memory depositBatchA, Rollup.BlockCommitment[] memory depositBatchB) =
            _buildDepositBatchesFromMessages(l1ToL2, lastHashAfterWithdrawals);
        (Rollup.DepositsInBlock[] memory depositsA, Rollup.DepositsInBlock[] memory depositsB) =
            _buildDepositsForBatches(depositBatchA, depositBatchB);

        _switchToL1();
        _assertOnL1();
        _acceptBatchL1(3, depositBatchA, depositsA);
        assertEq(l1.bridge.getQueueSize(), MESSAGE_COUNT - BATCH_SIZE, "queue should shrink after first deposit batch");
        _acceptBatchL1(4, depositBatchB, depositsB);
        assertEq(l1.bridge.getQueueSize(), 0, "queue should be fully consumed");

        assertEq(l1.rollup.nextBatchIndex(), 5, "unexpected final nextBatchIndex");
    }

    function test_bulkPath_preservesQueueAndConsumesDepositsCorrectly() public {
        // Step 1: Build direct L1-origin bulk messages to L2.
        _switchToL1();
        _assertOnL1();
        MockERC20Token l1OriginToken =
            new MockERC20Token("L1 Origin Token", "L1T", MESSAGE_COUNT * TRANSFER_AMOUNT, USER_B);

        vm.startPrank(USER_B);
        l1OriginToken.approve(address(l1.gateway), MESSAGE_COUNT * TRANSFER_AMOUNT);
        SentMessageData[] memory l1ToL2 = new SentMessageData[](MESSAGE_COUNT);
        for (uint256 i = 0; i < MESSAGE_COUNT; i++) {
            vm.recordLogs();
            l1.gateway.sendTokens(address(l1OriginToken), USER_A, TRANSFER_AMOUNT);
            VmFork.Log[] memory logs = vm.getRecordedLogs();
            l1ToL2[i] = _findSentMessage(logs, address(l1.bridge));
        }
        vm.stopPrank();
        assertEq(l1.bridge.getQueueSize(), MESSAGE_COUNT, "queue should contain all outbound L1 messages");

        // Step 2: Execute on L2 through bridge authority.
        _switchToL2();
        _assertOnL2();
        for (uint256 i = 0; i < l1ToL2.length; i++) {
            vm.prank(BRIDGE_AUTHORITY);
            l2.bridge.receiveMessage(
                l1ToL2[i].sender,
                l1ToL2[i].to,
                l1ToL2[i].value,
                l1ToL2[i].chainId,
                l1ToL2[i].blockNumber,
                l1ToL2[i].nonce,
                l1ToL2[i].data
            );
            assertEq(
                uint256(l2.bridge.receivedMessage(l1ToL2[i].messageHash)),
                uint256(IFluentBridge.MessageStatus.Success),
                "L2 message status mismatch"
            );
        }

        // Step 3: Accept two deposit batches and assert queue transitions 8 -> 4 -> 0.
        (Rollup.BlockCommitment[] memory depositBatchA, Rollup.BlockCommitment[] memory depositBatchB) =
            _buildDepositBatchesFromMessages(l1ToL2, MOCK_GENESIS_HASH);
        (Rollup.DepositsInBlock[] memory depositsA, Rollup.DepositsInBlock[] memory depositsB) =
            _buildDepositsForBatches(depositBatchA, depositBatchB);

        _switchToL1();
        _assertOnL1();
        _acceptBatchL1(1, depositBatchA, depositsA);
        bytes32 expectedRootA = l1.rollup.calculateBatchRoot(depositBatchA);
        assertEq(l1.rollup.acceptedBatchHash(1), expectedRootA, "accepted root mismatch for first deposit batch");
        assertEq(l1.bridge.getQueueSize(), MESSAGE_COUNT - BATCH_SIZE, "queue transition after first batch is wrong");

        _acceptBatchL1(2, depositBatchB, depositsB);
        bytes32 expectedRootB = l1.rollup.calculateBatchRoot(depositBatchB);
        assertEq(l1.rollup.acceptedBatchHash(2), expectedRootB, "accepted root mismatch for second deposit batch");
        assertEq(l1.bridge.getQueueSize(), 0, "queue should be empty");
        assertEq(l1.rollup.nextBatchIndex(), 3, "nextBatchIndex mismatch");
    }

    function _sendBulkL2ToL1(uint256 count, uint256 amount) internal returns (SentMessageData[] memory out) {
        // Side effect: locks L2 origin tokens and emits one outbound bridge message per send.
        _switchToL2();
        _assertOnL2();
        out = new SentMessageData[](count);

        vm.startPrank(USER_A);
        l2.originToken.approve(address(l2.gateway), count * amount);
        for (uint256 i = 0; i < count; i++) {
            vm.recordLogs();
            l2.gateway.sendTokens(address(l2.originToken), USER_B, amount);
            VmFork.Log[] memory logs = vm.getRecordedLogs();
            out[i] = _findSentMessage(logs, address(l2.bridge));
        }
        vm.stopPrank();
    }

    function _sendBulkL1ToL2WithPeggedToken(address peggedTokenAddress, uint256 count, uint256 amount)
        internal
        returns (SentMessageData[] memory out)
    {
        // Side effect: burns L1 pegged tokens and grows L1 deposit queue by `count`.
        _switchToL1();
        _assertOnL1();
        out = new SentMessageData[](count);

        ERC20PeggedToken peggedToken = ERC20PeggedToken(peggedTokenAddress);
        vm.startPrank(USER_B);
        peggedToken.approve(address(l1.gateway), count * amount);
        for (uint256 i = 0; i < count; i++) {
            vm.recordLogs();
            l1.gateway.sendTokens(peggedTokenAddress, USER_A, amount);
            VmFork.Log[] memory logs = vm.getRecordedLogs();
            out[i] = _findSentMessage(logs, address(l1.bridge));
        }
        vm.stopPrank();
    }

    function _buildWithdrawalBatchesFromMessages(SentMessageData[] memory messages, bytes32 initialPrevHash)
        internal
        pure
        returns (Rollup.BlockCommitment[] memory batchA, Rollup.BlockCommitment[] memory batchB, bytes32 lastHash)
    {
        // Side effect: prepares deterministic withdrawal commitments for two sequential batches.
        require(messages.length == MESSAGE_COUNT, "unexpected message count");
        batchA = new Rollup.BlockCommitment[](BATCH_SIZE);
        batchB = new Rollup.BlockCommitment[](BATCH_SIZE);

        bytes32 prevHash = initialPrevHash;
        for (uint256 i = 0; i < MESSAGE_COUNT; i++) {
            bytes32 blockHash = keccak256(abi.encodePacked("W", i));
            Rollup.BlockCommitment memory c = _buildCommitment(prevHash, blockHash, messages[i].messageHash, ZERO_HASH);
            if (i < BATCH_SIZE) {
                batchA[i] = c;
            } else {
                batchB[i - BATCH_SIZE] = c;
            }
            prevHash = blockHash;
        }
        lastHash = prevHash;
    }

    function _buildDepositBatchesFromMessages(SentMessageData[] memory messages, bytes32 initialPrevHash)
        internal
        pure
        returns (Rollup.BlockCommitment[] memory batchA, Rollup.BlockCommitment[] memory batchB)
    {
        // Side effect: prepares deterministic deposit commitments that consume queued L1 message hashes.
        require(messages.length == MESSAGE_COUNT, "unexpected message count");
        batchA = new Rollup.BlockCommitment[](BATCH_SIZE);
        batchB = new Rollup.BlockCommitment[](BATCH_SIZE);

        bytes32 prevHash = initialPrevHash;
        for (uint256 i = 0; i < MESSAGE_COUNT; i++) {
            bytes32 blockHash = keccak256(abi.encodePacked("D", i));
            bytes32 depositHash = keccak256(abi.encodePacked(messages[i].messageHash));
            Rollup.BlockCommitment memory c = _buildCommitment(prevHash, blockHash, ZERO_HASH, depositHash);
            if (i < BATCH_SIZE) {
                batchA[i] = c;
            } else {
                batchB[i - BATCH_SIZE] = c;
            }
            prevHash = blockHash;
        }
    }

    function _buildDepositsForBatches(Rollup.BlockCommitment[] memory batchA, Rollup.BlockCommitment[] memory batchB)
        internal
        pure
        returns (Rollup.DepositsInBlock[] memory depositsA, Rollup.DepositsInBlock[] memory depositsB)
    {
        // Side effect: binds each commitment block hash to one queue item for deposit validation.
        depositsA = new Rollup.DepositsInBlock[](batchA.length);
        depositsB = new Rollup.DepositsInBlock[](batchB.length);
        for (uint256 i = 0; i < batchA.length; i++) {
            depositsA[i] = Rollup.DepositsInBlock({blockHash: batchA[i].blockHash, depositCount: 1});
            depositsB[i] = Rollup.DepositsInBlock({blockHash: batchB[i].blockHash, depositCount: 1});
        }
    }

    function _proveWithdrawalBatch(
        uint256 batchIndex,
        Rollup.BlockCommitment[] memory batch,
        SentMessageData[] memory sourceMessages,
        uint256 sourceOffset
    ) internal {
        // Side effect: marks each proven withdrawal message as `Success` on L1 bridge.
        _switchToL1();
        _assertOnL1();

        vm.roll(block.number + 1);
        for (uint256 i = 0; i < batch.length; i++) {
            MerkleTree.MerkleProof memory blockProof = _buildBlockProof(batch, i);
            MerkleTree.MerkleProof memory withdrawalProof = _singleLeafProof();
            SentMessageData memory m = sourceMessages[sourceOffset + i];
            l1.bridge.receiveMessageWithProof(
                batchIndex,
                batch[i],
                m.sender,
                payable(m.to),
                m.value,
                m.chainId,
                m.blockNumber,
                m.nonce,
                m.data,
                withdrawalProof,
                blockProof
            );

            assertEq(
                uint256(l1.bridge.receivedMessage(m.messageHash)),
                uint256(IFluentBridge.MessageStatus.Success),
                "L1 message should be marked as success after proof"
            );
        }
    }
}
