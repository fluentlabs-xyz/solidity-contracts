// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {BaseFlowNativeTest} from "./BaseFlowNative.t.sol";

import {IFluentBridge} from "../../contracts/interfaces/bridge/IFluentBridge.sol";

/// @notice L2 target for generic cross-chain calls (no gateway): bridge `call`s this with `message` as calldata.
contract CrossChainExecTarget {
    uint256 public pings;
    uint256 public lastEthReceived;

    function ping() external payable {
        pings++;
        lastEthReceived = msg.value;
    }
}

contract CrossChainExecAlwaysRevert {
    function boom() external pure {
        revert("CrossChainExecAlwaysRevert");
    }
}

/// @dev Fails until `armSuccess()` — used to exercise `receiveFailedMessage`.
contract CrossChainExecFlaky {
    bool public shouldFail = true;

    function armSuccess() external {
        shouldFail = false;
    }

    function exec() external payable {
        if (shouldFail) revert("flaky");
    }
}

/**
 * @notice L1 → L2 arbitrary contract execution via `sendMessage` / `receiveMessage` (TEST_CASES.md: contract execution without gateways).
 * @dev Requires `L1_RPC_URL` and `L2_RPC_URL` (two Anvil instances with different `--chain-id`).
 */
contract BridgeCrossChainExecutionTest is BaseFlowNativeTest {
    function _decodeFirstSentMessage(
        Vm.Log[] memory logs
    )
        internal
        view
        returns (
            address sentFrom,
            address sentTo,
            uint256 sentValue,
            uint256 sentChainId,
            uint256 sentBlockNumber,
            uint256 sentNonce,
            bytes memory sentData
        )
    {
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(l1Bridge)) continue;
            if (entry.topics.length != 3) continue;
            if (entry.topics[0] != SENT_MESSAGE_SIG) continue;

            sentFrom = address(uint160(uint256(entry.topics[1])));
            sentTo = address(uint160(uint256(entry.topics[2])));

            bytes32 _mh;
            (sentValue, sentChainId, sentBlockNumber, sentNonce, _mh, sentData) = abi.decode(
                entry.data,
                (uint256, uint256, uint256, uint256, bytes32, bytes)
            );
            return (sentFrom, sentTo, sentValue, sentChainId, sentBlockNumber, sentNonce, sentData);
        }
        revert("SentMessage not found in logs");
    }

    /// @notice Relayer delivers calldata to an L2 contract; execution succeeds and state updates.
    function test_happyPath_crossChainExecution_zeroValueOnL2() public {
        _selectL2();
        CrossChainExecTarget target = new CrossChainExecTarget();
        bytes memory message = abi.encodeCall(CrossChainExecTarget.ping, ());

        _selectL1();
        vm.recordLogs();
        vm.prank(l1Sender);
        l1Bridge.sendMessage(address(target), message);

        (
            address sentFrom,
            address sentTo,
            uint256 sentValue,
            uint256 sentChainId,
            uint256 sentBlockNumber,
            uint256 sentNonce,
            bytes memory sentData
        ) = _decodeFirstSentMessage(vm.getRecordedLogs());

        assertEq(sentFrom, l1Sender);
        assertEq(sentTo, address(target));
        assertEq(sentValue, 0);

        bytes32 messageHash = _messageHash(sentFrom, sentTo, sentValue, sentChainId, sentBlockNumber, sentNonce, sentData);

        _selectL2();
        vm.prank(relayer);
        l2Bridge.receiveMessage(sentFrom, sentTo, sentValue, sentChainId, sentBlockNumber, sentNonce, sentData);

        assertEq(uint256(l2Bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(target.pings(), 1);
        assertEq(target.lastEthReceived(), 0);
    }

    /// @notice Native locked on L1 is forwarded to the L2 callee when the relayer funds `receiveMessage`.
    function test_happyPath_crossChainExecution_withNativeForwardedToL2Target() public {
        _selectL2();
        CrossChainExecTarget target = new CrossChainExecTarget();
        bytes memory message = abi.encodeCall(CrossChainExecTarget.ping, ());

        uint256 locked = 0.2 ether;

        _selectL1();
        vm.deal(l1Sender, locked);
        vm.recordLogs();
        vm.prank(l1Sender);
        l1Bridge.sendMessage{value: locked}(address(target), message);

        (
            address sentFrom,
            address sentTo,
            uint256 sentValue,
            uint256 sentChainId,
            uint256 sentBlockNumber,
            uint256 sentNonce,
            bytes memory sentData
        ) = _decodeFirstSentMessage(vm.getRecordedLogs());

        assertEq(sentValue, locked);
        assertEq(address(l1Bridge).balance, locked);

        bytes32 messageHash = _messageHash(sentFrom, sentTo, sentValue, sentChainId, sentBlockNumber, sentNonce, sentData);

        _selectL2();
        vm.deal(relayer, locked);
        vm.deal(address(l2Bridge), locked);
        vm.prank(relayer);
        l2Bridge.receiveMessage(sentFrom, sentTo, sentValue, sentChainId, sentBlockNumber, sentNonce, sentData);

        assertEq(uint256(l2Bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
        assertEq(target.pings(), 1);
        assertEq(target.lastEthReceived(), locked);
    }

    /// @notice Calldata runs on L2 but the target reverts → `Failed`, no success state on target.
    function test_failedPath_receiveMessage_marksFailedWhenL2TargetReverts() public {
        _selectL2();
        CrossChainExecAlwaysRevert target = new CrossChainExecAlwaysRevert();
        bytes memory message = abi.encodeCall(CrossChainExecAlwaysRevert.boom, ());

        _selectL1();
        vm.recordLogs();
        vm.prank(l1Sender);
        l1Bridge.sendMessage(address(target), message);

        (
            address sentFrom,
            address sentTo,
            uint256 sentValue,
            uint256 sentChainId,
            uint256 sentBlockNumber,
            uint256 sentNonce,
            bytes memory sentData
        ) = _decodeFirstSentMessage(vm.getRecordedLogs());

        bytes32 messageHash = _messageHash(sentFrom, sentTo, sentValue, sentChainId, sentBlockNumber, sentNonce, sentData);

        _selectL2();
        vm.prank(relayer);
        l2Bridge.receiveMessage(sentFrom, sentTo, sentValue, sentChainId, sentBlockNumber, sentNonce, sentData);

        assertEq(uint256(l2Bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));
    }

    /// @notice After `Failed`, anyone can retry via `receiveFailedMessage` once the callee allows success.
    function test_failedPath_receiveFailedMessage_succeedsAfterCalleeArmed() public {
        _selectL2();
        CrossChainExecFlaky target = new CrossChainExecFlaky();
        bytes memory message = abi.encodeCall(CrossChainExecFlaky.exec, ());

        _selectL1();
        vm.recordLogs();
        vm.prank(l1Sender);
        l1Bridge.sendMessage(address(target), message);

        (
            address sentFrom,
            address sentTo,
            uint256 sentValue,
            uint256 sentChainId,
            uint256 sentBlockNumber,
            uint256 sentNonce,
            bytes memory sentData
        ) = _decodeFirstSentMessage(vm.getRecordedLogs());

        bytes32 messageHash = _messageHash(sentFrom, sentTo, sentValue, sentChainId, sentBlockNumber, sentNonce, sentData);

        _selectL2();
        vm.prank(relayer);
        l2Bridge.receiveMessage(sentFrom, sentTo, sentValue, sentChainId, sentBlockNumber, sentNonce, sentData);
        assertEq(uint256(l2Bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Failed));

        target.armSuccess();

        vm.prank(relayer);
        l2Bridge.receiveFailedMessage(sentFrom, sentTo, sentValue, sentChainId, sentBlockNumber, sentNonce, sentData);

        assertEq(uint256(l2Bridge.getReceivedMessage(messageHash)), uint256(IFluentBridge.MessageStatus.Success));
    }
}
