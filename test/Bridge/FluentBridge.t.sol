// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IFluentBridge, IFluentBridgeErrors, IFluentBridgeEvents} from "../../contracts/interfaces/bridge/IFluentBridge.sol";
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

    /// @notice Case B2: first delivery reverts (status=Failed, no rollback emitted), then the L1
    ///         block oracle advances past the committed deadline. Retry at this point emits
    ///         `RollbackMessage` (first and only emission) + `RetriedFailedMessage(false, "")`.
    ///         This is the only refund path for messages that originally failed for a reason
    ///         other than expiry.
    function test_receiveFailedMessage_expiredAfterRevertEmitsRollbackMessage() public {
        RevertingReceiver receiver = new RevertingReceiver();
        bytes memory payload = abi.encodeCall(RevertingReceiver.fail, ());

        (bytes32 messageHash, uint256 nonce, uint256 sourceBlock) = _relayMessage(remoteBridge, address(receiver), 0, payload);
        assertEq(
            uint256(bridge.getReceivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "status after first delivery should be Failed"
        );

        // Advance L1 oracle past the committed validUntilBlockNumber (== sourceBlock).
        vm.prank(admin);
        oracle.updateL1BlockNumber(sourceBlock + 1);

        // Pre-register the receiver so the GatewayRegistered event from the helper does not
        // interleave with the strict expectEmit pair below. {_retryFailedMessage} keeps an
        // idempotent re-register call internally.
        _registerGateway(address(receiver));

        vm.expectEmit(true, true, true, true, address(bridge));
        emit IFluentBridgeEvents.RollbackMessage(messageHash, block.number);
        vm.expectEmit(true, true, true, true, address(bridge));
        emit IFluentBridgeEvents.RetriedFailedMessage(messageHash, false, "");

        _retryFailedMessage(remoteBridge, address(receiver), 0, sourceBlock, nonce, payload);

        assertEq(
            uint256(bridge.getReceivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "status after expired retry should stay Failed"
        );
    }

    /// @notice Case A double-emit non-regression: first `receiveMessage` hits expiry →
    ///         `RollbackMessage` in block N. Retry in a different block M also sees expiry →
    ///         `RollbackMessage` in block M. On L1 the double claim is blocked by dedup
    ///         (see `test_RevertIf_rollbackMessageWithProof_rollbackAlreadyDone`).
    function test_receiveFailedMessage_afterInitialExpiryReEmitsRollbackMessage() public {
        NoopReceiver receiver = new NoopReceiver();
        bytes memory payload = abi.encodeCall(NoopReceiver.handle, ());

        vm.prank(admin);
        oracle.updateL1BlockNumber(RECEIVE_DEADLINE + 100);

        uint256 firstBlock = block.number;
        bytes32 expectedHash = _bridgeMessageHash(
            remoteBridge,
            address(receiver),
            0,
            sourceChainId,
            nextSourceBlock,
            bridge.getReceivedNonce(),
            payload
        );

        // Pre-register so the GatewayRegistered event from the helper does not interleave
        // with the strict expectEmit below. {_relayMessage} re-registers idempotently.
        _registerGateway(address(receiver));

        vm.expectEmit(true, true, true, true, address(bridge));
        emit IFluentBridgeEvents.RollbackMessage(expectedHash, firstBlock);
        (bytes32 messageHash, uint256 nonce, uint256 sourceBlock) = _relayMessage(remoteBridge, address(receiver), 0, payload);

        assertEq(receiver.calls(), 0, "target must not be called on expiry path");
        assertEq(
            uint256(bridge.getReceivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "status after expired first delivery should be Failed"
        );

        // Advance the EVM block so the second RollbackMessage carries a different block.number.
        uint256 secondBlock = firstBlock + 7;
        vm.roll(secondBlock);

        vm.expectEmit(true, true, true, true, address(bridge));
        emit IFluentBridgeEvents.RollbackMessage(messageHash, secondBlock);
        vm.expectEmit(true, true, true, true, address(bridge));
        emit IFluentBridgeEvents.RetriedFailedMessage(messageHash, false, "");

        _retryFailedMessage(remoteBridge, address(receiver), 0, sourceBlock, nonce, payload);

        assertEq(
            uint256(bridge.getReceivedMessage(messageHash)),
            uint256(IFluentBridge.MessageStatus.Failed),
            "status after expired retry should stay Failed"
        );
    }
}
