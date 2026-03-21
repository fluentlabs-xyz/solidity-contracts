// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {L1FluentBridge} from "../../contracts/bridge/L1/L1FluentBridge.sol";
import {FluentBridgeStorageLayout} from "../../contracts/bridge/FluentBridgeStorageLayout.sol";
import {IL1FluentBridge} from "../../contracts/interfaces/bridge/IL1FluentBridge.sol";
import {MockRollup} from "../mocks/MockRollup.sol";
import {BridgeBase} from "./Base.t.sol";

contract L1FluentBridgeTest is BridgeBase {
    address internal otherBridge = makeAddr("otherBridge");
    address internal user = makeAddr("user");
    address internal receiver = makeAddr("receiver");
    address internal nonRollup = makeAddr("nonRollup");

    MockRollup internal rollup;

    function setUp() public override {
        rollup = new MockRollup();

        FluentBridgeStorageLayout.InitConfiguration memory cfg = FluentBridgeStorageLayout.InitConfiguration({
            adminRole: admin,
            pauserRole: pauser,
            relayerRole: relayer,
            otherBridge: otherBridge
        });

        L1FluentBridge impl = new L1FluentBridge();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(L1FluentBridge.initialize, (abi.encode(cfg), address(rollup))));
        l1Bridge = L1FluentBridge(payable(address(proxy)));
    }

    function test_sendMessage_enqueuesMessage() public {
        l1Bridge.sendMessage(receiver, hex"0102");

        vm.prank(address(rollup));
        (bytes32 msgHash, ) = l1Bridge.popSentMessage();

        assertTrue(msgHash != bytes32(0), "message hash should be queued");
    }

    function test_RevertIf_popSentMessage_queueEmpty() public {
        vm.prank(address(rollup));
        vm.expectRevert("Queue is empty");
        l1Bridge.popSentMessage();
    }

    function test_RevertIf_popSentMessage_callerNotRollup() public {
        vm.prank(nonRollup);
        vm.expectRevert(IL1FluentBridge.OnlyRollup.selector);
        l1Bridge.popSentMessage();
    }

    function test_RevertIf_setRollup_queueNotEmpty() public {
        l1Bridge.sendMessage(receiver, hex"deadbeef");

        vm.prank(admin);
        vm.expectRevert(IL1FluentBridge.QueueNotEmpty.selector);
        l1Bridge.setRollup(makeAddr("nextRollup"));
    }

    function test_RevertIf_receiveMessageWithProof_batchNotFinalized() public {
        rollup.setFinalized(false);

        vm.expectRevert(IL1FluentBridge.InvalidBlockProof.selector);
        l1Bridge.receiveMessageWithProof(
            7,
            _dummyHeader(),
            user,
            payable(receiver),
            0,
            block.chainid + 1,
            1,
            0,
            "",
            _dummyProof(),
            _dummyProof()
        );
    }

    function test_RevertIf_receiveMessageWithProof_sourceChainIsLocal() public {
        rollup.setFinalized(true);

        vm.expectRevert(IL1FluentBridge.ForbiddenReceiveRollbackMessage.selector);
        l1Bridge.receiveMessageWithProof(1, _dummyHeader(), user, payable(receiver), 0, block.chainid, 1, 0, "", _dummyProof(), _dummyProof());
    }

    function test_RevertIf_rollbackMessageWithProof_batchNotFinalized() public {
        rollup.setFinalized(false);

        vm.expectRevert(IL1FluentBridge.InvalidBlockProof.selector);
        l1Bridge.rollbackMessageWithProof(3, _dummyHeader(), user, receiver, 0, block.chainid + 1, 1, 0, "", _dummyProof(), _dummyProof());
    }

    function test_RevertIf_rollbackMessageWithProof_sourceChainIsLocal() public {
        rollup.setFinalized(true);

        vm.expectRevert(IL1FluentBridge.ForbiddenRollbackReceivedMessage.selector);
        l1Bridge.rollbackMessageWithProof(3, _dummyHeader(), user, receiver, 0, block.chainid, 1, 0, "", _dummyProof(), _dummyProof());
    }
}
