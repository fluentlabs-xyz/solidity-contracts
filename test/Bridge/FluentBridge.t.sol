// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IFluentBridge, IFluentBridgeErrors} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
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

    function test_RevertIf_sendMessage_toSelf() public {
        vm.expectRevert(IFluentBridgeErrors.InvalidDestinationAddress.selector);
        bridge.sendMessage(address(bridge), "");
    }

    function test_RevertIf_sendMessage_toOtherBridge() public {
        address otherBridge = bridge.getOtherBridge();
        vm.expectRevert(IFluentBridgeErrors.InvalidDestinationAddress.selector);
        bridge.sendMessage(otherBridge, "");
    }

    function test_RevertIf_receiveFailedMessage_statusNotFailed() public {
        uint256 nonce = bridge.getReceivedNonce();
        vm.expectRevert(IFluentBridgeErrors.MessageNotFailed.selector);
        bridge.receiveFailedMessage(remoteBridge, recipient, 0, sourceChainId, 1, nonce, "");
    }

    function test_RevertIf_receiveMessage_selfCall() public {
        uint256 nonce = bridge.getReceivedNonce();
        vm.deal(address(bridge), 1 ether);
        vm.prank(relayer);
        vm.expectRevert(IFluentBridgeErrors.ForbiddenSelfCall.selector);
        bridge.receiveMessage(remoteBridge, address(bridge), 0, sourceChainId, 1, nonce, "");
    }
}
