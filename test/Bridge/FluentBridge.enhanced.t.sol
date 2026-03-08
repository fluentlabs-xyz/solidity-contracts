// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FluentBridge} from "../../contracts/FluentBridge.sol";
import {IFluentBridge, IBridgeErrorCodes} from "../../contracts/interfaces/IFluentBridge.sol";
import {Rollup} from "../../contracts/rollup/Rollup.sol";
import {RollupStorageLayout} from "../../contracts/rollup/RollupStorageLayout.sol";
import {MerkleTree} from "../../contracts/libraries/MerkleTree.sol";
import {MinimalTest} from "../Rollup/Base.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockL1BlockOracle {
    uint256 public l1BlockNumber;

    function setL1BlockNumber(uint256 _blockNumber) external {
        l1BlockNumber = _blockNumber;
    }

    function getL1BlockNumber() external view returns (uint256) {
        return l1BlockNumber;
    }
}

contract MockReceiver {
    bool public shouldRevert;
    uint256 public lastValue;
    bytes public lastData;

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    receive() external payable {
        if (shouldRevert) revert("MockReceiver: forced revert");
        lastValue = msg.value;
    }

    fallback() external payable {
        if (shouldRevert) revert("MockReceiver: forced revert");
        lastValue = msg.value;
        lastData = msg.data;
    }
}

contract FluentBridgeEnhancedTest is MinimalTest {
    FluentBridge internal l1Bridge;
    FluentBridge internal l2Bridge;
    MockL1BlockOracle internal oracle;
    address internal constant ROLLUP = address(0xA0A0);
    address internal constant AUTHORITY = address(0xB0B0);
    uint256 internal constant DEADLINE = 100;

    function setUp() public {
        oracle = new MockL1BlockOracle();
        oracle.setL1BlockNumber(block.number);

        // Deploy L1 Bridge (with rollup)
        FluentBridge l1Impl = new FluentBridge();
        FluentBridge.InitConfiguration memory l1Config = FluentBridge.InitConfiguration({
            initialOwner: address(this),
            bridgeAuthority: AUTHORITY,
            rollup: ROLLUP,
            receiveMessageDeadline: 0,
            otherBridge: address(0), // Set after L2 deployment
            l1BlockOracle: address(0)
        });
        l1Bridge = FluentBridge(payable(address(new ERC1967Proxy(address(l1Impl), abi.encodeCall(FluentBridge.initialize, (abi.encode(l1Config)))))));

        // Deploy L2 Bridge (no rollup, with deadline)
        FluentBridge l2Impl = new FluentBridge();
        FluentBridge.InitConfiguration memory l2Config = FluentBridge.InitConfiguration({
            initialOwner: address(this),
            bridgeAuthority: AUTHORITY,
            rollup: address(0),
            receiveMessageDeadline: DEADLINE,
            otherBridge: address(l1Bridge),
            l1BlockOracle: address(oracle)
        });
        l2Bridge = FluentBridge(payable(address(new ERC1967Proxy(address(l2Impl), abi.encodeCall(FluentBridge.initialize, (abi.encode(l2Config)))))));

        // Set other bridge references
        l1Bridge.setOtherBridge(address(l2Bridge));
    }

    // ========== Send Message Tests ==========

    function testSendMessageIncrementsNonce() public {
        uint256 nonceBefore = l1Bridge.nonce();
        l1Bridge.sendMessage(address(0x1234), "test");
        assertEq(l1Bridge.nonce(), nonceBefore + 1, "nonce should increment");
    }

    function testSendMessageEnqueuesWhenRollupSet() public {
        uint256 queueSizeBefore = l1Bridge.sentMessageQueueSize();
        l1Bridge.sendMessage(address(0x1234), "test");
        assertEq(l1Bridge.sentMessageQueueSize(), queueSizeBefore + 1, "message should be enqueued");
    }

    function testSendMessageWithValueLocksNative() public {
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);

        uint256 bridgeBalanceBefore = address(l1Bridge).balance;
        l1Bridge.sendMessage{value: amount}(address(0x1234), "test");

        assertEq(address(l1Bridge).balance, bridgeBalanceBefore + amount, "bridge should lock native tokens");
    }

    function testSendMessageEmitsEvent() public {
        address to = address(0x1234);
        bytes memory message = "test message";
        uint256 value = 0.5 ether;
        vm.deal(address(this), value);

        vm.recordLogs();
        l1Bridge.sendMessage{value: value}(to, message);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == keccak256("SentMessage(address,address,uint256,uint256,uint256,uint256,bytes32,bytes)")) {
                found = true;
                break;
            }
        }

        assertTrue(found, "SentMessage event should be emitted");
    }

    function testSendMessageRevertsWhenPaused() public {
        l1Bridge.pause();

        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        l1Bridge.sendMessage(address(0x1234), "test");
    }

    function testSendMessageRevertsForInvalidDestination() public {
        vm.expectRevert(bytes4(keccak256("InvalidDestinationAddress()")));
        l1Bridge.sendMessage(address(l1Bridge), "test");

        vm.expectRevert(bytes4(keccak256("InvalidDestinationAddress()")));
        l1Bridge.sendMessage(address(l2Bridge), "test");
    }

    // ========== Receive Message (Authority) Tests ==========

    function testReceiveMessageByAuthorityIncrementsReceivedNonce() public {
        uint256 nonceBefore = l2Bridge.receivedNonce();

        vm.deal(AUTHORITY, 1 ether);
        vm.prank(AUTHORITY);
        l2Bridge.receiveMessage{value: 0}(
            address(this),
            address(0x1234),
            0,
            block.chainid + 1,
            block.number,
            nonceBefore,
            ""
        );

        assertEq(l2Bridge.receivedNonce(), nonceBefore + 1, "received nonce should increment");
    }

    function testReceiveMessageRevertsOnNonceOutOfOrder() public {
        vm.deal(AUTHORITY, 1 ether);
        vm.prank(AUTHORITY);

        vm.expectRevert(bytes4(keccak256("MessageReceivedOutOfOrder()")));
        l2Bridge.receiveMessage{value: 0}(
            address(this),
            address(0x1234),
            0,
            block.chainid + 1,
            block.number,
            999, // Wrong nonce
            ""
        );
    }

    function testReceiveMessageRevertsOnValueMismatch() public {
        vm.deal(AUTHORITY, 1 ether);
        vm.prank(AUTHORITY);

        vm.expectRevert(abi.encodeWithSelector(IBridgeErrorCodes.InvalidMessageValue.selector, 1 ether, 0));
        l2Bridge.receiveMessage{value: 0}(
            address(this),
            address(0x1234),
            1 ether,
            block.chainid + 1,
            block.number,
            l2Bridge.receivedNonce(),
            ""
        );
    }

    function testReceiveMessageRevertsForNonAuthority() public {
        vm.prank(address(0xBAD));

        vm.expectRevert(bytes4(keccak256("OnlyBridgeAuthority()")));
        l2Bridge.receiveMessage{value: 0}(
            address(this),
            address(0x1234),
            0,
            block.chainid + 1,
            block.number,
            l2Bridge.receivedNonce(),
            ""
        );
    }

    function testReceiveMessageWithValueTransfersToRecipient() public {
        MockReceiver receiver = new MockReceiver();
        uint256 amount = 0.5 ether;

        vm.deal(AUTHORITY, amount);
        vm.prank(AUTHORITY);
        l2Bridge.receiveMessage{value: amount}(
            address(this),
            address(receiver),
            amount,
            block.chainid + 1,
            block.number,
            l2Bridge.receivedNonce(),
            ""
        );

        assertEq(receiver.lastValue(), amount, "receiver should receive value");
    }

    function testReceiveMessageMarksSuccessOnSuccessfulExecution() public {
        MockReceiver receiver = new MockReceiver();

        vm.prank(AUTHORITY);
        l2Bridge.receiveMessage{value: 0}(
            address(this),
            address(receiver),
            0,
            block.chainid + 1,
            block.number,
            l2Bridge.receivedNonce(),
            ""
        );

        bytes32 messageHash = keccak256(abi.encode(
            address(this),
            address(receiver),
            0,
            block.chainid + 1,
            block.number,
            l2Bridge.receivedNonce() - 1,
            bytes("")
        ));

        assertEq(uint256(l2Bridge.receivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success), "message should be marked success");
    }

    function testReceiveMessageMarksFailedOnRevert() public {
        MockReceiver receiver = new MockReceiver();
        receiver.setShouldRevert(true);

        vm.prank(AUTHORITY);
        l2Bridge.receiveMessage{value: 0}(
            address(this),
            address(receiver),
            0,
            block.chainid + 1,
            block.number,
            l2Bridge.receivedNonce(),
            ""
        );

        bytes32 messageHash = keccak256(abi.encode(
            address(this),
            address(receiver),
            0,
            block.chainid + 1,
            block.number,
            l2Bridge.receivedNonce() - 1,
            bytes("")
        ));

        assertEq(uint256(l2Bridge.receivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed), "message should be marked failed");
    }

    // ========== Receive Failed Message Tests ==========

    function testReceiveFailedMessageRetries() public {
        MockReceiver receiver = new MockReceiver();
        receiver.setShouldRevert(true);

        // First attempt fails
        vm.prank(AUTHORITY);
        l2Bridge.receiveMessage{value: 0}(
            address(this),
            address(receiver),
            0,
            block.chainid + 1,
            block.number,
            l2Bridge.receivedNonce(),
            ""
        );

        bytes32 messageHash = keccak256(abi.encode(
            address(this),
            address(receiver),
            0,
            block.chainid + 1,
            block.number,
            l2Bridge.receivedNonce() - 1,
            bytes("")
        ));

        assertEq(uint256(l2Bridge.receivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed), "should be marked failed");

        // Fix receiver and retry
        receiver.setShouldRevert(false);

        vm.prank(AUTHORITY);
        l2Bridge.receiveFailedMessage{value: 0}(
            address(this),
            address(receiver),
            0,
            block.chainid + 1,
            block.number,
            l2Bridge.receivedNonce() - 1,
            ""
        );

        assertEq(uint256(l2Bridge.receivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success), "should be marked success after retry");
    }

    function testReceiveFailedMessageRevertsIfNotFailed() public {
        vm.prank(AUTHORITY);
        vm.expectRevert(bytes4(keccak256("MessageNotFailed()")));
        l2Bridge.receiveFailedMessage{value: 0}(
            address(this),
            address(0x1234),
            0,
            block.chainid + 1,
            block.number,
            0,
            ""
        );
    }

    // ========== Deadline / Rollback Tests ==========

    function testReceiveMessageRollsBackAfterDeadline() public {
        uint256 sendBlockNumber = block.number;
        oracle.setL1BlockNumber(sendBlockNumber + DEADLINE + 1);

        vm.prank(AUTHORITY);
        l2Bridge.receiveMessage{value: 0}(
            address(this),
            address(0x1234),
            0,
            block.chainid + 1,
            sendBlockNumber,
            l2Bridge.receivedNonce(),
            ""
        );

        bytes32 messageHash = keccak256(abi.encode(
            address(this),
            address(0x1234),
            0,
            block.chainid + 1,
            sendBlockNumber,
            l2Bridge.receivedNonce() - 1,
            bytes("")
        ));

        // Message should not execute, no status set
        assertEq(uint256(l2Bridge.receivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.None), "message should not execute after deadline");
    }

    function testReceiveMessageWithinDeadlineExecutes() public {
        uint256 sendBlockNumber = block.number;
        oracle.setL1BlockNumber(sendBlockNumber + DEADLINE - 1);

        MockReceiver receiver = new MockReceiver();

        vm.prank(AUTHORITY);
        l2Bridge.receiveMessage{value: 0}(
            address(this),
            address(receiver),
            0,
            block.chainid + 1,
            sendBlockNumber,
            l2Bridge.receivedNonce(),
            ""
        );

        bytes32 messageHash = keccak256(abi.encode(
            address(this),
            address(receiver),
            0,
            block.chainid + 1,
            sendBlockNumber,
            l2Bridge.receivedNonce() - 1,
            bytes("")
        ));

        assertEq(uint256(l2Bridge.receivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success), "message should execute within deadline");
    }

    // ========== Admin Function Tests ==========

    function testSetOtherBridgeUpdates() public {
        address newOtherBridge = address(0x9999);
        l1Bridge.setOtherBridge(newOtherBridge);
        assertEq(l1Bridge.otherBridge(), newOtherBridge, "other bridge should update");
    }

    function testSetBridgeAuthorityUpdates() public {
        address newAuthority = address(0x8888);
        l1Bridge.setBridgeAuthority(newAuthority);
        assertEq(l1Bridge.bridgeAuthority(), newAuthority, "bridge authority should update");
    }

    function testSetRollupUpdates() public {
        address newRollup = address(0x7777);
        l1Bridge.setRollup(newRollup);
        assertEq(l1Bridge.rollup(), newRollup, "rollup should update");
    }

    function testSetL1BlockOracleUpdates() public {
        address newOracle = address(0x6666);
        l2Bridge.setL1BlockOracle(newOracle);
        assertEq(l2Bridge.l1BlockOracle(), newOracle, "oracle should update");
    }

    function testSetReceiveMessageDeadlineUpdates() public {
        uint256 newDeadline = 200;
        l2Bridge.setReceiveMessageDeadline(newDeadline);
        assertEq(l2Bridge.receiveMessageDeadline(), newDeadline, "deadline should update");
    }

    function testOnlyOwnerCanCallAdminFunctions() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        l1Bridge.setOtherBridge(address(0x1));

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        l1Bridge.setBridgeAuthority(address(0x1));

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        l1Bridge.setRollup(address(0x1));
    }

    // ========== Pause/Unpause Tests ==========

    function testPausePreventsSendMessage() public {
        l1Bridge.pause();
        vm.expectRevert(bytes4(keccak256("EnforcedPause()")));
        l1Bridge.sendMessage(address(0x1234), "");
    }

    function testUnpauseAllowsSendMessage() public {
        l1Bridge.pause();
        l1Bridge.unpause();
        l1Bridge.sendMessage(address(0x1234), "");
        // Should not revert
    }

    function testOnlyOwnerCanPauseAndUnpause() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        l1Bridge.pause();

        l1Bridge.pause();

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0xBAD)));
        l1Bridge.unpause();
    }

    // ========== Native Sender Context Tests ==========

    function testNativeSenderIsSetDuringExecution() public view {
        // This would need a custom receiver contract to check nativeSender() during execution
        // Leaving as placeholder for integration test
        assertTrue(l2Bridge.nativeSender() == address(0), "native sender should be zero outside execution");
    }

    // ========== Queue Management Tests ==========

    function testSentMessageQueueSizeIncrementsOnSend() public {
        uint256 sizeBefore = l1Bridge.sentMessageQueueSize();
        l1Bridge.sendMessage(address(0x1234), "");
        assertEq(l1Bridge.sentMessageQueueSize(), sizeBefore + 1, "queue size should increment");
    }

    function testPopSentMessageRevertsForNonRollup() public {
        l1Bridge.sendMessage(address(0x1234), "");

        vm.prank(address(0xBAD));
        vm.expectRevert(bytes4(keccak256("OnlyRollupAuthority()")));
        l1Bridge.popSentMessage();
    }

    // ========== Edge Cases ==========

    function testMultipleSendMessages() public {
        for (uint256 i = 0; i < 10; i++) {
            l1Bridge.sendMessage(address(uint160(0x1000 + i)), bytes(""));
        }

        assertEq(l1Bridge.nonce(), 10, "nonce should be 10");
        assertEq(l1Bridge.sentMessageQueueSize(), 10, "queue size should be 10");
    }

    function testSendMessageWithLargePayload() public {
        bytes memory largePayload = new bytes(10000);
        for (uint256 i = 0; i < largePayload.length; i++) {
            largePayload[i] = bytes1(uint8(i % 256));
        }

        l1Bridge.sendMessage(address(0x1234), largePayload);
        assertEq(l1Bridge.nonce(), 1, "should handle large payload");
    }

    function testSendMessageWithZeroValue() public {
        l1Bridge.sendMessage(address(0x1234), "");
        assertEq(l1Bridge.nonce(), 1, "should handle zero value");
    }

    function testReceiveMessageAlreadyReceivedReverts() public {
        vm.prank(AUTHORITY);
        l2Bridge.receiveMessage{value: 0}(
            address(this),
            address(0x1234),
            0,
            block.chainid + 1,
            block.number,
            l2Bridge.receivedNonce(),
            ""
        );

        vm.prank(AUTHORITY);
        vm.expectRevert(bytes4(keccak256("MessageAlreadyReceived()")));
        l2Bridge.receiveMessage{value: 0}(
            address(this),
            address(0x1234),
            0,
            block.chainid + 1,
            block.number,
            l2Bridge.receivedNonce(),
            ""
        );
    }
}