// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
import {GatewayBase} from "../Gateway/Base.t.sol";
import {NoopReceiver, RevertingReceiver} from "./Base.t.sol";

contract FluentBridgeTest is GatewayBase {
    uint256 internal constant RECEIVE_DEADLINE = 10;

    function setUp() public override {
        super.setUp();
        _deployBridge(RECEIVE_DEADLINE);
    }

    function test_receiveMessage_transfersValueAndMarksSuccess() public {
        uint256 amount = 1 ether;
        uint256 balanceBefore = recipient.balance;
        (bytes32 messageHash, , ) = _relayMessage(remoteBridge, recipient, amount, "");

        assertEq(recipient.balance - balanceBefore, amount);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
    }

    function test_receiveMessage_afterDeadline_marksFailureWithoutExecutingTarget() public {
        NoopReceiver receiver = new NoopReceiver();
        bytes memory payload = abi.encodeCall(NoopReceiver.handle, ());

        vm.prank(admin);
        oracle.updateL1BlockNumber(RECEIVE_DEADLINE + 100);
        (bytes32 messageHash, , ) = _relayMessage(remoteBridge, address(receiver), 0, payload);

        assertEq(receiver.calls(), 0);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function test_receiveFailedMessage_retriesPreviouslyFailedCall() public {
        RevertingReceiver receiver = new RevertingReceiver();
        bytes memory payload = abi.encodeCall(RevertingReceiver.fail, ());

        (bytes32 messageHash, uint256 nonce, uint256 sourceBlock) = _relayMessage(remoteBridge, address(receiver), 0, payload);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));

        _retryFailedMessage(remoteBridge, address(receiver), 0, sourceBlock, nonce, payload);
        assertEq(uint256(bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    function testFuzz_receiveMessage_transfersExactRelayedValue(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 1, 10 ether);
        uint256 balanceBefore = recipient.balance;
        _relayMessage(remoteBridge, recipient, amount, "");
        assertEq(recipient.balance - balanceBefore, amount);
    }
}
